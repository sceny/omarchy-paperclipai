"""dev/develop-sync in a throwaway repository with its own origin, as the release run
uses it: after a fast-forward release, after a release head (develop has commits main
does not), when develop moved on after the candidate, when main is already in
develop, and on a conflict. The release workflow pushes what it prints, after the
commit's public-text status, and has no path that only warns."""

import os
import re
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "dev", "develop-sync")
WORKFLOW = os.path.join(HERE, "..", ".github", "workflows", "release.yml")
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", GIT_CONFIG_GLOBAL="/dev/null")


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True, check=True).stdout.strip()


class DevelopSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.origin = os.path.join(root, "origin.git")
        self.work = os.path.join(root, "work")
        git(root, "init", "--bare", "-b", "main", self.origin)
        git(root, "clone", "-q", self.origin, self.work)
        git(self.work, "switch", "-q", "-c", "main")
        self.commit("a.txt", "one\n", "Plugin 0.8.2")
        git(self.work, "push", "-q", "origin", "main", "main:develop")
        git(self.work, "switch", "-q", "-c", "develop", "origin/develop")
        self.commit("a.txt", "one\ntwo\n", "A change")
        self.commit("CHANGELOG.md", "## 0.9.0\n", "Release 0.9.0")
        self.push("develop")

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, file, text, message):
        with open(os.path.join(self.work, file), "w") as handle:
            handle.write(text)
        git(self.work, "add", file)
        git(self.work, "commit", "-q", "-m", message)

    def push(self, branch):
        git(self.work, "push", "-q", "origin", branch)
        git(self.work, "fetch", "-q", "origin")

    def release_head(self):
        """What dev/release-head and its merge leave on main: one commit with develop's
        tree on main, merged with a merge commit."""
        tree = git(self.work, "rev-parse", "origin/develop^{tree}")
        head = git(self.work, "commit-tree", tree, "-p", "origin/main", "-m", "Release 0.9.0")
        git(self.work, "switch", "-q", "main")
        git(self.work, "merge", "-q", "--no-ff", "-m", "Merge pull request: Release 0.9.0", head)
        self.push("main")
        return git(self.work, "rev-parse", "main")

    def sync(self, sha):
        return subprocess.run([SCRIPT, sha, "0.9.0"], cwd=self.work, env=ENV, capture_output=True, text=True)

    def assert_level(self, sha, done, develop_tree):
        self.assertEqual(done.returncode, 0, done.stderr)
        out = done.stdout.strip()
        subprocess.run(["git", "merge-base", "--is-ancestor", sha, out], cwd=self.work, check=True)
        subprocess.run(["git", "merge-base", "--is-ancestor", "origin/develop", out], cwd=self.work, check=True)
        self.assertEqual(git(self.work, "rev-parse", out + "^{tree}"), develop_tree)
        return out

    def test_fast_forward(self):
        git(self.work, "switch", "-q", "main")
        git(self.work, "merge", "-q", "--no-ff", "-m", "Merge develop", "origin/develop")
        self.push("main")
        sha = git(self.work, "rev-parse", "main")
        out = self.assert_level(sha, self.sync(sha), git(self.work, "rev-parse", "main^{tree}"))
        self.assertEqual(out, sha)

    def test_release_head_merges_main_into_develop(self):
        develop = git(self.work, "rev-parse", "origin/develop")
        sha = self.release_head()
        out = self.assert_level(sha, self.sync(sha), git(self.work, "rev-parse", "origin/develop^{tree}"))
        self.assertEqual(git(self.work, "rev-list", "--parents", "-n", "1", out).split()[1:], [develop, sha])
        self.assertEqual(git(self.work, "log", "-1", "--format=%s", out), "Release 0.9.0: develop brought level with main")
        self.assertEqual(git(self.work, "status", "--porcelain"), "")

    def test_develop_moved_after_the_candidate(self):
        sha = self.release_head()
        git(self.work, "switch", "-q", "develop")
        self.commit("b.txt", "later\n", "A later change")
        self.push("develop")
        self.assert_level(sha, self.sync(sha), git(self.work, "rev-parse", "origin/develop^{tree}"))

    def test_main_already_in_develop(self):
        sha = self.release_head()
        git(self.work, "switch", "-q", "develop")
        git(self.work, "merge", "-q", "--no-ff", "-m", "Merge main", sha)
        self.push("develop")
        done = self.sync(sha)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), git(self.work, "rev-parse", "origin/develop"))

    def test_conflict_fails_and_prints_nothing(self):
        git(self.work, "switch", "-q", "main")
        self.commit("a.txt", "one\nurgent\n", "An urgent fix on main")
        self.push("main")
        sha = git(self.work, "rev-parse", "main")
        done = self.sync(sha)
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "")
        self.assertIn("does not merge into develop", done.stderr)

    def test_refuses(self):
        self.assertNotEqual(self.sync("no-such-commit").returncode, 0)
        git(self.work, "update-ref", "-d", "refs/remotes/origin/develop")
        done = self.sync(git(self.work, "rev-parse", "origin/main"))
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("git fetch origin develop", done.stderr)

    def test_workflow_pushes_what_the_script_prints(self):
        with open(WORKFLOW) as handle:
            text = handle.read()
        step = re.search(r"- name: Bring develop level with main\n(.*?)(?=\n      - name: )", text, re.S).group(1)
        self.assertIn('sync=$(dev/develop-sync "$GITHUB_SHA" "$VERSION")', step)
        self.assertIn('"$sync:refs/heads/develop"', step)
        # the status needs the commit on GitHub, and develop needs the status
        staged = step.index('push "$sync:$staging"')
        status = step.index('statuses/$sync')
        self.assertLess(staged, status)
        self.assertLess(status, step.index('push "$sync:refs/heads/develop"'))
        self.assertNotIn("::warning::", step)
        self.assertNotRegex(step, r"\|\| *true")


if __name__ == "__main__":
    unittest.main()
