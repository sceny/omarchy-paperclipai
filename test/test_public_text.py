"""dev/public-text-check: the company's rules for public text, with a bad and a
good example of every class, so a pattern that stops matching or starts to
match a product word fails the build.

The examples are written for the test: no real pull request, person or device."""

import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
SCRIPT = os.path.join(ROOT, "dev", "public-text-check")

_loader = importlib.machinery.SourceFileLoader("public_text_check", SCRIPT)
_spec = importlib.util.spec_from_loader("public_text_check", _loader)
ptc = importlib.util.module_from_spec(_spec)
_loader.exec_module(ptc)

RULES = ptc.load_rules()
ENV, OPEN, UNLINKED = (RULES[k]["check"] for k in ("environment", "open_item", "unlinked_reference"))


def problems(text, files=()):
    """[(check, rule id)] of one text."""
    return [(check, rule) for check, rule, _ in ptc.check_text(RULES, text, files)]


def checks(text, files=()):
    return {check for check, _ in problems(text, files)}


class Environment(unittest.TestCase):
    BAD = {
        "sandbox-tool": "Checked with dev/sandbox on this head.",
        "sandbox": "Everything passes in the sandbox.",
        "rig": "The rig check is clean.",
        "emulator": "The emulator cannot judge this.",
        "podman": "A podman run of the suite is green.",
        "container": "Started a container and opened the panel.",
        "paperclip": "Tracked on the Paperclip board.",
        "task-id": "Task SCE-123 has the details.",
        "home-path": "Logs are in /home/someone/logs.",
        "dot-path": "The state is under ~/.config/thing.",
        "tmp-path": "Output in /tmp/run-1/out.txt.",
        "runtime-dir": "Stills in $XDG_RUNTIME_DIR/other/.",
        "test-count-passed": "92 passed, 0 failed.",
        "test-count": "The suite ran 380 tests.",
    }

    def test_every_class_fails(self):
        for rule, text in self.BAD.items():
            with self.subTest(rule=rule):
                self.assertIn((ENV, rule), problems(text))

    def test_every_pattern_has_a_bad_example(self):
        self.assertEqual({p["id"] for p in RULES["environment"]["patterns"]}, set(self.BAD))

    def test_product_words_pass(self):
        for text in [
            "The panel lists the Paperclip inbox; an agent's run shows its status.",
            "Paperclip tokens are kept in the plugin's own file.",
            "A picture is decoded in a sandbox, never by the shell.",
            "Thumbnails are decoded in a sandbox with no network.",
            "The skills are in `~/.config/omarchy/paperclipai/skills` and stills live in $XDG_RUNTIME_DIR/sceny.paperclipai/.",
            "The QML container item keeps the row's width.",
            "The container keeps its width.",
            "Adds 3 tests for the new key. Counts are in test/test_model.mjs.",
            "Adds 4 new tests and writes 2 more tests for the fold.",
            "Pictures are decoded with glycin in a sandbox, then drawn.",
            "See [the tool](https://github.com/sceny/omarchy-paperclipai/blob/main/dev/rig) for how it works.",
            "```\ndev/rig up\n```",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_a_pull_request_about_a_tool_may_name_it(self):
        text = "dev/sandbox now takes --session; the rig starts in the container."
        self.assertIn(ENV, checks(text))
        self.assertNotIn(ENV, checks(text, ["dev/sandbox", "dev/sandbox.d/x"]))
        self.assertIn(ENV, checks("Task SCE-1", ["dev/sandbox"]))

    def test_the_rules_own_pull_request_may_quote_the_words(self):
        text = "It never holds the sandbox, the rig, an emulator or SCE-5."
        self.assertIn(ENV, checks(text))
        for rules_file in ("dev/public-text-check", "dev/public-text-rules.json", "test/test_public_text.py"):
            with self.subTest(file=rules_file):
                self.assertEqual(checks(text, [rules_file]), set())

    def test_the_rules_own_pull_request_may_not_name_anything_else(self):
        files = ["dev/public-text-rules.json"]
        for rule, text in [
            ("home-path", "Logs are in /home/someone/logs."),
            ("dot-path", "The state is under ~/.config/thing."),
            ("tmp-path", "Output in /tmp/run-1/out.txt."),
            ("runtime-dir", "Stills in $XDG_RUNTIME_DIR/other/."),
            ("test-count-passed", "92 passed, 0 failed."),
            ("test-count", "The suite ran 380 tests."),
        ]:
            with self.subTest(rule=rule):
                self.assertIn((ENV, rule), problems(text, files))

    def test_the_sandbox_and_the_container_are_exempt_only_in_the_sentence_that_needs_them(self):
        for rule, text in [
            ("sandbox", "Verified in the sandbox: the picture matches."),
            ("sandbox", "The image is fine; verified in the sandbox."),
            ("sandbox", "Thumbnails look right. Checked in the sandbox."),
            ("sandbox", "Pictures are decoded; the panel was checked in the sandbox."),
            ("container", "Ran the checks in a container; the QML item is fine."),
            ("container", "The row is fine - ran it in a container."),
            ("container", "Started a container and opened the panel."),
        ]:
            with self.subTest(text=text):
                self.assertIn((ENV, rule), problems(text))
        for text in [
            "Pictures are decoded in a sandbox. The panel loads them.",
            "A file with no recorded type is sent around the sandbox.",
            "A picture is not opened with no sandbox.",
            "The QML item is placed in a container row.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])

    def test_a_container_that_is_not_the_place_we_ran_in_passes(self):
        for text in [
            "The container keeps its width.",
            "A container for the pinned row grows with its content.",
            "Containers hold the shortcuts.",
        ]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])
        for text in [
            "Ran it inside a rootless container.",
            "A fresh container per run.",
            "The container image is rebuilt.",
        ]:
            with self.subTest(text=text):
                self.assertIn((ENV, "container"), problems(text))

    def test_a_count_of_tests_a_change_adds_is_not_a_run(self):
        for text in ["Adds 3 tests.", "Added 12 new tests for the key.", "Includes 2 tests for the order."]:
            with self.subTest(text=text):
                self.assertEqual(problems(text), [])
        for text in ["Adds a case. The suite ran 380 tests.", "Adds 3 tests; 380 tests pass.", "Adds 3 tests, 92 passed."]:
            with self.subTest(text=text):
                self.assertTrue(checks(text), text)


class OpenItems(unittest.TestCase):
    def test_bad(self):
        for text in [
            "Not checked in the panel.",
            "The reconnect path was not tested.",
            "The edge is untested.",
            "Left for later.",
            "A follow-up covers the fold.",
            "We can do it later.",
            "I will look at it later and decide then.",
            "Looked at it later, no change.",
            "Fix this later, once the key exists.",
            "Handled in a later release.",
            "TODO: the second page.",
            "Out of scope here.",
            "- Fine.\n- The fold is not covered.\n- Fine too.",
            "Verdict: pass.\n\nNot blocking, for later: the ellipsis re-flows.",
        ]:
            with self.subTest(text=text):
                self.assertIn(OPEN, checks(text))

    def test_a_reference_in_the_same_bullet_or_paragraph_passes(self):
        for text in [
            "Not blocking, for later: the ellipsis re-flows (#246).",
            "A follow-up is tracked in sceny/omarchy-paperclipai#246.",
            "- The fold is not covered: https://github.com/sceny/omarchy-paperclipai/issues/12",
            "Not checked in the panel.\nIt is tracked in #9.",
            "- Left for later\n  - the ellipsis (#4)",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))

    def test_a_reference_in_another_bullet_does_not_count(self):
        self.assertIn(OPEN, checks("- Not tested here.\n- Another thing (#7)."))

    def test_a_lead_line_asks_it_of_the_bullets_under_it(self):
        self.assertEqual(checks("**Not checked:**\n\n- the fold (#1)\n- the page (#2)"), set())
        text = "**Not checked:**\n\n- the fold (#1)\n- the page"
        self.assertEqual(len([p for p in problems(text) if p[0] == OPEN]), 1)
        self.assertIn(OPEN, checks("## Follow-ups\n\n- the page"))
        self.assertNotIn(OPEN, checks("## Follow-ups\n\n- the page (#3)"))

    def test_words_that_are_not_a_leftover_pass(self):
        for text in [
            "A later change keeps the old keys.",
            "The later head is read again.",
            "Not checked in a running shell: the merge waits for someone to check it there.",
            "All of it is checked.",
            "`TODO` in code is shown as code.",
            "```\n# TODO later\n```",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(OPEN, checks(text))


class UnlinkedReferences(unittest.TestCase):
    def test_bad(self):
        for text, rule in [
            ("Upstream is omarchy#8753.", "repo-without-owner"),
            ("See kdeconnect-kde#99 for the fault.", "repo-without-owner"),
            ("It is the marketplace's #10096.", "named-upstream-bare-number"),
            ("Reported upstream #42.", "named-upstream-bare-number"),
            ("KDE Connect #7 has the report.", "named-upstream-bare-number"),
            ("See ab#12.", "repo-without-owner"),
        ]:
            with self.subTest(text=text):
                self.assertIn((UNLINKED, rule), problems(text))

    def test_good(self):
        for text in [
            "Upstream is omacom/omarchy#8753.",
            "Tracked in [sceny/omarchy-paperclipai#246](https://github.com/sceny/omarchy-paperclipai/issues/246).",
            "This repository's own #195 and #194 stay bare.",
            "See https://github.com/omacom/omarchy/issues/8753#issuecomment-1 and docs/x.md#12.",
            "Inline `omarchy#8753` is code.",
            "The C#5 sample compiles.",
        ]:
            with self.subTest(text=text):
                self.assertNotIn(UNLINKED, checks(text))


class WholePullRequest(unittest.TestCase):
    def doc(self, *bodies, files=()):
        return {"changed_files": list(files), "texts": [
            {"url": "https://example.test/c/%d" % i, "body": body} for i, body in enumerate(bodies)]}

    def test_every_kind_of_text_is_read_and_named_by_its_url(self):
        found = ptc.check_pull_request(RULES, self.doc("Clean.", "Ran it in the rig.", None, "Not tested."))
        self.assertEqual([(url, check) for url, check, _, _ in found],
                         [("https://example.test/c/1", ENV), ("https://example.test/c/3", OPEN)])

    def test_a_clean_pull_request_passes(self):
        self.assertEqual(ptc.check_pull_request(RULES, self.doc("Adds a button for #194.", "Pass. Checked the fold.")), [])

    def run_cli(self, doc):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(doc, handle)
        try:
            return subprocess.run([sys.executable, SCRIPT, "--fixture", handle.name], capture_output=True, text=True)
        finally:
            os.unlink(handle.name)

    def test_exit_codes_and_output(self):
        self.assertEqual(self.run_cli(self.doc("Fine.")).returncode, 0)
        long = "word " * 200 + "Verified in the sandbox. " + "tail " * 200
        result = self.run_cli(self.doc(long))
        self.assertEqual(result.returncode, 1)
        self.assertIn("public-text-environment", result.stdout)
        self.assertIn("https://example.test/c/0", result.stdout)
        self.assertIn("sandbox", result.stdout)
        self.assertNotIn("tail tail", result.stdout)
        self.assertLess(len(result.stdout), 400)

    def test_every_class_fails_the_command(self):
        examples = {ENV: "Ran it in the rig.", OPEN: "Not checked in the panel.", UNLINKED: "Upstream is omarchy#8753."}
        for check, text in examples.items():
            with self.subTest(check=check):
                result = self.run_cli(self.doc(text))
                self.assertEqual(result.returncode, 1)
                self.assertIn(check, result.stdout)

    def test_output_has_no_control_characters_or_workflow_commands(self):
        evil = "::error::x\r\nSCE-1\x1b[31m"
        result = self.run_cli(self.doc(evil))
        for line in result.stdout.split("\n"):
            self.assertFalse(line.startswith("::"), line)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\r", result.stdout)

    def test_unreadable_input_is_not_a_pass(self):
        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_TOKEN", "GH_TOKEN", "GITHUB_EVENT_PATH")}
        result = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 2)


class Standing(unittest.TestCase):
    def test_the_standing_texts_pass(self):
        found = ptc.check_standing(RULES)
        self.assertEqual(found, [], "\n".join("%s %s %s" % (w, r, m) for w, _, r, m in found))

    def test_history_in_a_standing_text_fails(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "docs", "internals"))
            with open(os.path.join(root, "AGENTS.md"), "w") as handle:
                handle.write("A rule.\nThe owner decided it on 2026-01-02 (SCE-12).\nThe owner asked for it.\n"
                             "Done when the owner said go for that SHA.\n```\nSCE-9 in code\n```\n")
            found = ptc.check_standing(RULES, root)
            self.assertEqual(sorted((w, r) for w, _, r, _ in found),
                             [("AGENTS.md:2", "date-as-history"), ("AGENTS.md:2", "owner-said"),
                              ("AGENTS.md:2", "task-id"), ("AGENTS.md:3", "owner-said")])


class Rules(unittest.TestCase):
    def test_every_pattern_compiles_and_has_an_id(self):
        patterns = (RULES["environment"]["patterns"] + RULES["open_item"]["markers"] +
                    RULES["unlinked_reference"]["patterns"] + RULES["standing"]["patterns"])
        for pat in patterns:
            re.compile(pat["regex"])
            for key in ("unless_sentence", "unless_before", "unless_match"):
                if key in pat:
                    re.compile(pat[key])
        re.compile(RULES["open_item"]["reference"])


class Workflow(unittest.TestCase):
    PATH = os.path.join(ROOT, ".github", "workflows", "public-text.yml")

    def setUp(self):
        with open(self.PATH) as handle:
            self.text = handle.read()

    def test_it_runs_on_the_events_that_carry_public_text(self):
        for event in ("pull_request:", "pull_request_review:", "pull_request_review_comment:"):
            self.assertIn("\n  " + event, self.text)

    def test_it_reads_with_a_read_only_token(self):
        self.assertIn("pull-requests: read", self.text)
        self.assertNotRegex(self.text, r"(?m)^\s+(contents|pull-requests|issues|statuses|checks): write")

    def test_no_text_from_the_event_reaches_a_shell(self):
        for expression in re.findall(r"\$\{\{(.*?)\}\}", self.text):
            self.assertNotRegex(expression, r"\.(body|title|head\.ref|head\.label|message|name)\b", expression)


if __name__ == "__main__":
    unittest.main()
