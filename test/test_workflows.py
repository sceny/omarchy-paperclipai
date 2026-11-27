"""The GitHub Actions workflows, read and checked against the rules.

    python3 -m unittest test/test_workflows.py

Every file in .github/workflows/ fails on:

  * a pull_request_target or workflow_run trigger;
  * a top-level permissions block that is not read-only;
  * a job write permission that is not on REVIEWED_WRITES, with its reason;
  * ${{ github.event.* }}, ${{ github.head_ref }} or ${{ inputs.* }} in a run: line
    (such a value goes through env:, never into the script text);
  * an action pinned by a branch instead of a tag or a commit.

The files use block mappings, list items and block scalars only, so the reader
is line based: it reads the indentation, not a YAML parser.
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")

REVIEWED_WRITES = {
    ("release.yml", "publish", "contents"):
        "tags the merged commit, publishes its release, then pushes develop level with main",
    ("release.yml", "publish", "statuses"):
        "writes the public-text status on the commit it pushes to develop",
    ("develop-notice.yml", "notice", "issues"):
        "opens the issue that tells the pusher a push to develop failed public-text",
}

FORBIDDEN_TRIGGERS = ("pull_request_target", "workflow_run")
EXPRESSION = re.compile(r"\$\{\{[^}]*\b(github\.event\.|github\.head_ref\b|inputs\.)")
PINNED_COMMIT = re.compile(r"[0-9a-f]{40}")
PINNED_TAG = re.compile(r"v\d+(\.\d+){0,2}")
USES = re.compile(r"^\s*(?:- +)?uses:\s*['\"]?([^\s'\"#]+)")
RUN = re.compile(r"^(\s*)(- +)?run:\s*(.*)$")


def is_comment(line):
    return line.lstrip().startswith("#")


def children(lines, start, indent):
    """The lines under lines[start] that sit deeper than indent."""
    out = []
    for line in lines[start + 1:]:
        if line.strip() and not is_comment(line) and len(line) - len(line.lstrip(" ")) <= indent:
            break
        out.append(line)
    return out


def top_level(lines, key):
    for i, line in enumerate(lines):
        if re.match(r"%s:" % key, line):
            return line, children(lines, i, 0)
    return None, []


def scope_values(lines, indent):
    """(scope, value) for each mapping entry at exactly this indentation."""
    pairs = []
    for line in lines:
        if not line.strip() or is_comment(line):
            continue
        if len(line) - len(line.lstrip(" ")) != indent:
            continue
        m = re.match(r"\s*([\w-]+):\s*(\S+)?", line)
        if m:
            pairs.append((m.group(1), m.group(2) or ""))
    return pairs


def jobs(lines):
    _, body = top_level(lines, "jobs")
    found = {}
    for i, line in enumerate(body):
        m = re.match(r"^  ([\w-]+):\s*$", line)
        if m:
            found[m.group(1)] = children(body, i, 2)
    return found


def trigger_problems(lines):
    head, block = top_level(lines, "on")
    found = []
    for line in [head or ""] + block:
        if is_comment(line):
            continue
        for name in FORBIDDEN_TRIGGERS:
            if re.search(r"(^|[\s\[,{])%s\b" % name, line):
                found.append("the trigger %s" % name)
    return found


def permission_problems(name, lines):
    head, block = top_level(lines, "permissions")
    if head is None:
        return ["no top-level permissions block"]
    inline = head[len("permissions:"):].strip()
    if inline:
        return [] if inline == "read-all" else ["top-level permissions %s" % inline]
    return [
        "top-level permissions give %s %s" % (scope, value)
        for scope, value in scope_values(block, 2)
        if value not in ("read", "none")
    ]


def job_write_problems(name, lines):
    found = []
    for job, body in jobs(lines).items():
        for i, line in enumerate(body):
            if not re.match(r"^    permissions:", line):
                continue
            inline = line[len("    permissions:"):].strip()
            if inline:
                if inline != "read-all":
                    found.append("job %s permissions %s" % (job, inline))
                continue
            for scope, value in scope_values(children(body, i, 4), 6):
                if value == "write" and (name, job, scope) not in REVIEWED_WRITES:
                    found.append("job %s writes %s, which is not reviewed" % (job, scope))
    return found


def run_problems(lines):
    found = []
    for i, line in enumerate(lines):
        m = RUN.match(line)
        if not m or is_comment(line):
            continue
        key_indent = len(m.group(1)) + len(m.group(2) or "")
        value = m.group(3)
        if value in ("", "|", ">", "|-", ">-", "|+", ">+"):
            script = children(lines, i, key_indent)
        else:
            script = [value]
        for text in script:
            if EXPRESSION.search(text):
                found.append("line %d: a run: line reads %s" % (i + 1, EXPRESSION.search(text).group(0)))
    return found


def pin_problems(lines):
    found = []
    for i, line in enumerate(lines):
        m = USES.match(line)
        if not m or is_comment(line):
            continue
        ref = m.group(1)
        if ref.startswith("./") or ref.startswith("docker://"):
            continue
        pin = ref.partition("@")[2]
        if not (PINNED_COMMIT.fullmatch(pin) or PINNED_TAG.fullmatch(pin)):
            found.append("line %d: %s is not pinned to a tag or a commit" % (i + 1, ref))
    return found


def workflow_problems(name, text):
    lines = text.split("\n")
    found = trigger_problems(lines) + permission_problems(name, lines)
    found += job_write_problems(name, lines) + run_problems(lines) + pin_problems(lines)
    return ["%s: %s" % (name, problem) for problem in found]


def workflow_files():
    return sorted(
        os.path.join(WORKFLOWS, name)
        for name in os.listdir(WORKFLOWS)
        if os.path.isfile(os.path.join(WORKFLOWS, name))
    )


BASE = """name: planted
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: Run
        env:
          TITLE: ${{ github.event.pull_request.title }}
        run: test/run_all.sh "$TITLE"
"""


class EveryWorkflowPasses(unittest.TestCase):
    def test_every_file_in_the_workflows_directory_passes(self):
        found = []
        for path in workflow_files():
            with open(path, encoding="utf-8") as f:
                found += workflow_problems(os.path.basename(path), f.read())
        self.assertEqual(found, [])

    def test_the_directory_has_workflows(self):
        self.assertTrue(workflow_files())


class PlantedWorkflows(unittest.TestCase):
    def assertCaught(self, text, needle):
        found = workflow_problems("planted.yml", text)
        self.assertTrue(any(needle in problem for problem in found), "%s not caught: %s" % (needle, found))

    def test_the_base_passes(self):
        self.assertEqual(workflow_problems("planted.yml", BASE), [])

    def test_a_pull_request_target_trigger_fails(self):
        self.assertCaught(BASE.replace("on:\n  pull_request:", "on:\n  pull_request_target:"), "pull_request_target")

    def test_a_workflow_run_trigger_fails(self):
        self.assertCaught(BASE.replace("on:\n  pull_request:", "on:\n  workflow_run:"), "workflow_run")

    def test_a_top_level_write_fails(self):
        self.assertCaught(BASE.replace("permissions:\n  contents: read", "permissions:\n  contents: write"),
                          "top-level permissions give contents write")

    def test_a_job_write_not_on_the_list_fails(self):
        planted = BASE.replace("    runs-on: ubuntu-latest\n",
                               "    runs-on: ubuntu-latest\n    permissions:\n      contents: write\n")
        self.assertCaught(planted, "job test writes contents, which is not reviewed")

    def test_a_reviewed_write_is_only_reviewed_in_its_own_file_and_job(self):
        planted = BASE.replace("    runs-on: ubuntu-latest\n",
                               "    runs-on: ubuntu-latest\n    permissions:\n      contents: write\n")
        self.assertCaught(planted.replace("test:", "publish:", 1), "job publish writes contents")

    def test_an_event_expression_in_a_run_line_fails(self):
        self.assertCaught(BASE.replace("run: test/run_all.sh \"$TITLE\"",
                                       "run: echo \"${{ github.event.pull_request.title }}\""),
                          "github.event.")

    def test_a_head_ref_in_a_run_block_fails(self):
        planted = BASE.replace("        run: test/run_all.sh \"$TITLE\"",
                               "        run: |\n          git switch ${{ github.head_ref }}")
        self.assertCaught(planted, "github.head_ref")

    def test_an_input_in_a_run_line_fails(self):
        self.assertCaught(BASE.replace("run: test/run_all.sh \"$TITLE\"", "run: test/run_all.sh ${{ inputs.commit }}"),
                          "inputs.")

    def test_an_expression_in_env_passes(self):
        self.assertEqual(workflow_problems("planted.yml", BASE), [])

    def test_an_action_pinned_by_a_branch_fails(self):
        self.assertCaught(BASE.replace("actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2",
                                       "actions/checkout@main"), "actions/checkout@main is not pinned")

    def test_an_action_pinned_by_a_tag_passes(self):
        self.assertEqual(workflow_problems("planted.yml", BASE.replace("@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2", "@v4.2.2")), [])


if __name__ == "__main__":
    unittest.main()
