"""dev/release-prepare in a throwaway repository with its own origin, and the
release workflow's notes extraction run on what it wrote."""

import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "dev", "release-prepare")
RELEASE_NOTES = os.path.join(HERE, "..", "dev", "release-notes")

MANIFEST = '{\n  "id": "sceny.test",\n  "version": "%s",\n  "schemaVersion": 1\n}\n'
HEAD = "# What's new\n\nIntro.\n\n"
OLD = "## 0.8.2 — 2026-10-11\n\n### Highlights\n\n- Old.\n"
UNRELEASED = "## Unreleased\n\n### Highlights\n\n- New thing.\n\n"
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", GIT_CONFIG_GLOBAL="/dev/null")


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True, check=True).stdout


def notes_of(work):
    """The release workflow's own extraction (dev/release-notes) on the repository."""
    with tempfile.TemporaryDirectory() as out:
        notes = os.path.join(out, "notes.md")
        subprocess.run([RELEASE_NOTES, notes], cwd=work, env=ENV, capture_output=True, text=True, check=True)
        with open(notes) as handle:
            return handle.read().strip()


class ReleasePrepare(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.origin = os.path.join(root, "origin.git")
        self.work = os.path.join(root, "work")
        git(root, "init", "--bare", "-b", "main", self.origin)
        git(root, "clone", "-q", self.origin, self.work)
        git(self.work, "switch", "-c", "main")
        self.commit("main", MANIFEST % "0.8.2", HEAD + OLD)
        git(self.work, "tag", "-a", "v0.8.2", "-m", "0.8.2")
        git(self.work, "push", "-q", "origin", "main", "v0.8.2")
        git(self.work, "switch", "-q", "-c", "develop")
        self.commit("develop", MANIFEST % "0.8.2", HEAD + UNRELEASED + OLD)
        git(self.work, "push", "-q", "origin", "develop")
        git(self.work, "switch", "-q", "main")

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, name, manifest, changelog):
        for file, text in (("manifest.json", manifest), ("CHANGELOG.md", changelog)):
            with open(os.path.join(self.work, file), "w") as handle:
                handle.write(text)
        git(self.work, "add", ".")
        git(self.work, "commit", "-q", "-m", name)

    def run_script(self, *args):
        return subprocess.run(["python3", SCRIPT, *args], cwd=self.work, env=ENV, capture_output=True, text=True)

    def read(self, file):
        with open(os.path.join(self.work, file)) as handle:
            return handle.read()

    def test_release_from_develop(self):
        done = self.run_script("0.9.0", "--date", "2026-10-20")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(git(self.work, "branch", "--show-current").strip(), "release-0.9.0")
        self.assertIn('"version": "0.9.0"', self.read("manifest.json"))
        changelog = self.read("CHANGELOG.md")
        self.assertIn("## 0.9.0 — 2026-10-20", changelog)
        self.assertNotIn("Unreleased", changelog)
        self.assertEqual(notes_of(self.work), "### Highlights\n\n- New thing.")
        self.assertEqual(git(self.work, "status", "--porcelain").strip(), "")
        self.assertEqual(git(self.work, "log", "-1", "--format=%s").strip(), "Release 0.9.0: CHANGELOG and manifest version")
        self.assertEqual(git(self.work, "rev-parse", "HEAD~1"), git(self.work, "rev-parse", "origin/develop"))

    def test_fix_from_main(self):
        done = self.run_script("0.8.3", "--from", "main", "--note", "One.", "--note", "Two.", "--date", "2026-10-20")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(git(self.work, "branch", "--show-current").strip(), "fix-0.8.3")
        self.assertIn('"version": "0.8.3"', self.read("manifest.json"))
        changelog = self.read("CHANGELOG.md")
        self.assertEqual(notes_of(self.work), "### Fixes\n\n- One.\n- Two.")
        self.assertLess(changelog.index("## 0.8.3 "), changelog.index("## 0.8.2 "))
        self.assertTrue(changelog.startswith(HEAD))

    def test_no_commit_leaves_the_edits_staged(self):
        done = self.run_script("0.9.0", "--no-commit")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(git(self.work, "log", "-1", "--format=%s").strip(), "develop")
        self.assertIn("M  manifest.json", git(self.work, "status", "--porcelain"))

    def test_refuses(self):
        cases = {
            "tagged": (["0.8.2", "--from", "main", "--note", "x"], "already tagged"),
            "not above": (["0.8.1"], "not above"),
            "not a version": (["0.9"], "not X.Y.Z"),
            "unicode digits": (["\u0660.\u0669.\u0661"], "not X.Y.Z"),
            "fix without a note": (["0.8.3", "--from", "main"], "--note"),
            "note from develop": (["0.9.0", "--note", "x"], "--note is for a fix"),
            "bad date": (["0.9.0", "--date", "yesterday"], "YYYY-MM-DD"),
        }
        for name, (args, message) in cases.items():
            with self.subTest(name):
                done = self.run_script(*args)
                self.assertNotEqual(done.returncode, 0)
                self.assertIn(message, done.stderr)
                self.assertEqual(git(self.work, "branch", "--show-current").strip(), "main")

    def test_tag_only_on_origin_is_refused(self):
        other = os.path.join(self.tmp.name, "other")
        git(self.tmp.name, "clone", "-q", self.origin, other)
        git(other, "tag", "-a", "v0.8.3", "-m", "x")
        git(other, "push", "-q", "origin", "v0.8.3")
        done = self.run_script("0.8.3", "--from", "main", "--note", "x")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("already tagged", done.stderr)

    def test_empty_unreleased_is_refused(self):
        git(self.work, "switch", "-q", "develop")
        self.commit("empty", MANIFEST % "0.8.2", HEAD + "## Unreleased\n\n" + OLD)
        git(self.work, "push", "-q", "origin", "develop")
        done = self.run_script("0.9.0")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("no entries", done.stderr)

    def test_unreleased_with_only_headings_is_refused(self):
        git(self.work, "switch", "-q", "develop")
        self.commit("headings", MANIFEST % "0.8.2", HEAD + "## Unreleased\n\n### Highlights\n\n" + OLD)
        git(self.work, "push", "-q", "origin", "develop")
        done = self.run_script("0.9.0")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("no entries", done.stderr)

    def test_existing_branch_and_dirty_tree_are_refused(self):
        git(self.work, "branch", "release-0.9.0", "main")
        done = self.run_script("0.9.0")
        self.assertIn("already exists", done.stderr)
        git(self.work, "branch", "-q", "-D", "release-0.9.0")
        with open(os.path.join(self.work, "manifest.json"), "a") as handle:
            handle.write("\n")
        done = self.run_script("0.9.0")
        self.assertIn("tracked changes", done.stderr)


if __name__ == "__main__":
    unittest.main()
