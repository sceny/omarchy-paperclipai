"""dev/release-head in a throwaway repository with its own origin. A commit on develop
trips public-text and is not on main: the release head's range leaves it out, and
the range from develop reads it."""

import json
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "dev", "release-head")
CHECK = os.path.join(HERE, "..", "dev", "public-text-check")

MANIFEST = '{\n  "id": "sceny.test",\n  "version": "%s",\n  "schemaVersion": 1\n}\n'
HEAD = "# What's new\n\nIntro.\n\n"
OLD = "## 0.8.2 — 2026-10-11\n\n### Highlights\n\n- Old.\n"
NEW = "## 0.9.0 — 2026-10-20\n\n### Highlights\n\n- New thing.\n\n"
TMP_PATH_MESSAGE = "Rig: keep the run output under /tmp/opr.rig in the test"
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", GIT_CONFIG_GLOBAL="/dev/null")


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True, check=True).stdout


class ReleaseHead(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.origin = os.path.join(root, "origin.git")
        self.work = os.path.join(root, "work")
        git(root, "init", "--bare", "-b", "main", self.origin)
        git(root, "clone", "-q", self.origin, self.work)
        git(self.work, "switch", "-c", "main")
        self.commit("Plugin 0.8.2", MANIFEST % "0.8.2", HEAD + OLD)
        git(self.work, "tag", "-a", "v0.8.2", "-m", "0.8.2")
        git(self.work, "push", "-q", "origin", "main", "v0.8.2")
        git(self.work, "switch", "-q", "-c", "develop")
        self.commit(TMP_PATH_MESSAGE, MANIFEST % "0.8.2", HEAD + OLD + "\n")
        self.commit("Release 0.9.0: CHANGELOG and manifest version", MANIFEST % "0.9.0", HEAD + NEW + OLD)
        git(self.work, "push", "-q", "origin", "develop")
        git(self.work, "switch", "-q", "main")

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, message, manifest, changelog):
        for file, text in (("manifest.json", manifest), ("CHANGELOG.md", changelog)):
            with open(os.path.join(self.work, file), "w") as handle:
                handle.write(text)
        git(self.work, "add", ".")
        git(self.work, "commit", "-q", "-m", message)

    def run_script(self, *args):
        return subprocess.run(["python3", SCRIPT, *args], cwd=self.work, env=ENV, capture_output=True, text=True)

    def public_text(self, rev_range):
        """dev/public-text-check on the commits of a range, read as a pull request reads them."""
        messages = git(self.work, "log", "--reverse", "--format=%H%x1f%B%x1e", rev_range).split("\x1e")
        texts = [{"url": "https://example.invalid/commit/" + sha, "body": body.strip(), "kind": "commit"}
                 for sha, body in (part.strip("\n").split("\x1f", 1) for part in messages if part.strip())]
        files = [line for line in git(self.work, "diff", "--name-only", rev_range.split("..")[0], rev_range.split("..")[1]).split("\n") if line]
        fixture = os.path.join(self.tmp.name, "fixture.json")
        with open(fixture, "w") as handle:
            json.dump({"changed_files": files, "texts": texts}, handle)
        return subprocess.run(["python3", CHECK, "--fixture", fixture], cwd=self.work, env=ENV, capture_output=True, text=True)

    def test_release_head_passes_where_develop_fails(self):
        self.assertNotEqual(self.public_text("origin/main..origin/develop").returncode, 0)

        done = self.run_script("0.9.0")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(git(self.work, "branch", "--show-current").strip(), "main")
        self.assertEqual(git(self.work, "rev-parse", "release-head-0.9.0^"), git(self.work, "rev-parse", "origin/main"))
        self.assertEqual(git(self.work, "rev-parse", "release-head-0.9.0^{tree}"), git(self.work, "rev-parse", "origin/develop^{tree}"))
        self.assertEqual(len(git(self.work, "rev-list", "origin/main..release-head-0.9.0").split()), 1)
        self.assertEqual(self.public_text("origin/main..release-head-0.9.0").returncode, 0)

    def test_refuses(self):
        cases = {
            "version not on develop": (["0.9.1"], "has version"),
            "not a version": (["0.9"], "not X.Y.Z"),
        }
        for name, (args, message) in cases.items():
            with self.subTest(name):
                done = self.run_script(*args)
                self.assertNotEqual(done.returncode, 0)
                self.assertIn(message, done.stderr)
        git(self.work, "branch", "release-head-0.9.0", "origin/main")
        done = self.run_script("0.9.0")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("already exists", done.stderr)


if __name__ == "__main__":
    unittest.main()
