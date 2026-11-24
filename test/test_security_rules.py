"""The per-pull-request security list, checked against the tree.

    python3 -m unittest test/test_security_rules.py

Three things are pinned here:

  * no tracked text file contains a NUL byte;
  * every Text/Label in QML says textFormat: Text.PlainText;
  * docs/internals/releasing.md ("Every pull request") and test/ agree: each
    line links a check that exists, or is marked pending, and AGENTS.md points
    at both documents and at paths that exist;
  * docs/security.md ("Assets and the tests that hold them") agrees with
    test/: each asset has a test or a `manual:` line, every file, class and
    test a row names exists, and a gap links an issue.
"""

import os
import re
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pyc"}
RELEASING = "docs/internals/releasing.md"
MIN_RULES = 6


def tracked():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True,
                         capture_output=True).stdout.decode()
    return [name for name in out.split("\0") if name and os.path.isfile(os.path.join(ROOT, name))]


def read(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as handle:
        return handle.read()


def qml_blocks(source):
    """Yield (line number, type, body) for each Text or Label item."""
    lines = source.split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)(Text|Label)\s*\{", line)
        if not m:
            continue
        indent = m.group(1)
        j = i + 1
        while j < len(lines) and not re.match("^" + indent + r"\}", lines[j]):
            j += 1
        yield i + 1, m.group(2), "\n".join(lines[i:j])


def every_pull_request_items():
    text = read(RELEASING)
    section = text.split("## Every pull request", 1)[1].split("\n## ", 1)[0]
    parts = re.split(r"(?m)^(?=\d+\. )", section)
    return [part for part in parts if re.match(r"\d+\. ", part)]


ASSETS_HEADING = "## Assets and the tests that hold them"
SECURITY = "docs/security.md"
GAP_LINK = re.compile(r"/issues/\d+\b")
PENDING = "pending: tracked privately"


def asset_rows(text):
    """(asset, held by, manual, gap) for each row of the assets table."""
    section = text.split(ASSETS_HEADING, 1)[1].split("\n## ", 1)[0]
    rows = []
    for line in section.split("\n"):
        if not line.startswith("|") or line.startswith("|---") or line.startswith("| Asset"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        rows.append(tuple(cells) + ("",) * (4 - len(cells)))
    return rows


def asset_problems(text, exists, source):
    """Why the assets table is wrong. exists(path) says a file is there; source(path) reads it."""
    found = []
    rows = asset_rows(text)
    if not rows:
        return ["the assets table has no rows"]
    for asset, held, manual, gap in rows:
        name = re.sub(r"[*]|\s*\(.*", "", asset)[:40]
        tokens = re.findall(r"`([^`]+)`", held)
        if not tokens and not manual.startswith("manual:"):
            found.append("%s: no test and no `manual:` line" % name)
        if gap and PENDING not in gap and not GAP_LINK.search(gap):
            found.append("%s: a gap without an issue" % name)
        current = None
        for token in tokens:
            if "/" in token and re.search(r"\.(py|mjs|js|sh)$", token):
                current = token
                if not exists(token):
                    found.append("%s: missing file %s" % (name, token))
                    current = None
            elif current and re.fullmatch(r"test_\w+", token):
                if "def %s(" % token not in source(current):
                    found.append("%s: %s has no test %s" % (name, current, token))
            elif current and re.fullmatch(r"[A-Z]\w+", token):
                if not re.search(r"^class %s\b" % token, source(current), re.M):
                    found.append("%s: %s has no class %s" % (name, current, token))
    return found


class NoNulBytes(unittest.TestCase):
    def test_no_tracked_text_file_has_a_nul_byte(self):
        bad = []
        for name in tracked():
            if os.path.splitext(name)[1].lower() in BINARY_EXTENSIONS:
                continue
            with open(os.path.join(ROOT, name), "rb") as handle:
                if b"\0" in handle.read():
                    bad.append(name)
        self.assertEqual(bad, [], "NUL byte in a tracked text file; write an escape such as \\u0000")


class QmlTextIsPlain(unittest.TestCase):
    def test_every_text_and_label_is_plain_text(self):
        seen = 0
        bad = []
        for name in tracked():
            if not name.endswith(".qml"):
                continue
            for line, kind, body in qml_blocks(read(name)):
                seen += 1
                if not re.search(r"textFormat:\s*Text\.PlainText\b", body):
                    bad.append("%s:%d %s" % (name, line, kind))
        self.assertGreater(seen, 0, "found no Text items; the scan is broken")
        self.assertEqual(bad, [], "Text without textFormat: Text.PlainText")


class ListMatchesTests(unittest.TestCase):
    def test_the_list_has_every_required_line(self):
        self.assertGreaterEqual(len(every_pull_request_items()), MIN_RULES)

    def test_each_line_links_an_existing_check_or_is_pending(self):
        for item in every_pull_request_items():
            title = item.split("\n", 1)[0][:60]
            links = re.findall(r"\]\(\.\./\.\./(test/[^)#\s]+)\)", item)
            pending = re.search(r"Check:\s*pending \(SCE-\d+\)", item)
            self.assertTrue(links or pending, "no check and not pending: " + title)
            for link in links:
                self.assertTrue(os.path.isfile(os.path.join(ROOT, link)), "missing check %s for: %s" % (link, title))
                self.assertIn(link, [t for t in tracked()], "check %s is not tracked" % link)

    def test_run_all_runs_every_linked_check(self):
        runner = read("test/run_all.sh")
        for item in every_pull_request_items():
            for link in re.findall(r"\]\(\.\./\.\./(test/[^)#\s]+)\)", item):
                self.assertIn(link, runner, link + " is linked but test/run_all.sh does not run it")


class AssetsAreHeld(unittest.TestCase):
    def check(self, text):
        return asset_problems(text, lambda path: os.path.isfile(os.path.join(ROOT, path)),
                              lambda path: read(path))

    def test_the_shipped_table_names_tests_that_exist(self):
        found = self.check(read(SECURITY))
        self.assertEqual(found, [], "\n".join(found))

    def test_the_table_has_the_threat_models_assets(self):
        assets = " ".join(row[0] for row in asset_rows(read(SECURITY)))
        for needed in ("API token", "Inbox text", "state directory", "repair session", "clipboard", "shared shell"):
            self.assertIn(needed, assets)

    def table(self, *rows):
        return ASSETS_HEADING + "\n\n| Asset | Held by | Manual | Gap |\n|---|---|---|---|\n" + "\n".join(rows) + "\n"

    def test_a_row_with_no_test_and_no_manual_line_fails(self):
        found = self.check(self.table("| **Planted** | | | |"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("no test and no `manual:` line", found[0])

    def test_a_manual_line_alone_passes(self):
        self.assertEqual(self.check(self.table("| **Planted** | | manual: a person reads it | |")), [])

    def test_a_row_naming_a_missing_file_class_or_test_fails(self):
        for held, why in (("`test/test_nothing_here.py` `Whatever`", "missing file"),
                          ("`test/test_state.py` `NoSuchClass`", "no class"),
                          ("`test/test_state.py` `Modes` (`test_no_such_test`)", "no test")):
            found = self.check(self.table("| **Planted** | %s | | |" % held))
            self.assertEqual(len(found), 1, (held, found))
            self.assertIn(why, found[0])

    def test_a_gap_needs_an_issue_or_the_pending_mark(self):
        row = "| **Planted** | `test/test_state.py` `Modes` | | %s |"
        self.assertEqual(len(self.check(self.table(row % "something leaks"))), 1)
        self.assertEqual(self.check(self.table(row % "[#1](https://github.com/o/r/issues/1)")), [])
        self.assertEqual(self.check(self.table(row % PENDING)), [])


class AgentsFile(unittest.TestCase):
    def test_agents_points_at_both_documents(self):
        agents = read("AGENTS.md")
        self.assertIn("docs/security.md", agents)
        self.assertIn(RELEASING, agents)

    def test_every_path_in_the_file_map_exists(self):
        agents = read("AGENTS.md")
        section = agents.split("## File map", 1)[1]
        paths = re.findall(r"^\| `([^`]+)` \|", section, re.M)
        self.assertGreater(len(paths), 10)
        for path in paths:
            self.assertTrue(os.path.exists(os.path.join(ROOT, path.rstrip("/"))), "file map names a missing path: " + path)

    def test_the_documents_exist(self):
        for name in ("docs/security.md", RELEASING):
            self.assertTrue(os.path.isfile(os.path.join(ROOT, name)), name)


if __name__ == "__main__":
    unittest.main()
