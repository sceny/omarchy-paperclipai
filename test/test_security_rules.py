"""The per-pull-request security list, checked against the tree.

    python3 -m unittest test/test_security_rules.py

Three things are pinned here:

  * no tracked text file contains a NUL byte;
  * every Text/Label in QML says textFormat: Text.PlainText;
  * docs/internals/releasing.md ("Every pull request") and test/ agree: each
    line links a check that exists, or is marked pending, and AGENTS.md points
    at both documents and at paths that exist.
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
