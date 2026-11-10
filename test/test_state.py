"""State is private and does not pile up.

    python3 -m unittest test/test_state.py

Pinned here: the state directory is 0700 and what is created in it 0600, a
token file others can read is not used (and the report says why), and doctor and
agent sessions older than seven days are removed on the next start.
"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STATUS = os.path.join(ROOT, "bin", "omarchy-paperclip-status")
COMMON = os.path.join(ROOT, "lib", "common.sh")
DAY = 86400

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_loader("paperclip_status", importlib.machinery.SourceFileLoader("paperclip_status", STATUS))
status = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(status)


def mode(path):
    return os.stat(path).st_mode & 0o777


def age(path, days):
    then = time.time() - days * DAY
    os.utime(path, (then, then))


class StateHome(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = self._tmp.name
        self.state = os.path.join(self.home, "omarchy", "paperclipai")
        self.env = {"PATH": os.environ["PATH"], "HOME": self.home, "XDG_STATE_HOME": self.home}

    def bash(self, script):
        return subprocess.run(["bash", "-c", 'source "$1"; ' + script, "bash", COMMON],
                              env=self.env, capture_output=True, text=True, check=True).stdout


class TokenFile(StateHome):
    def write(self, name, body, file_mode):
        os.makedirs(self.state, exist_ok=True)
        path = os.path.join(self.state, name)
        with open(path, "w") as handle:
            handle.write(body)
        os.chmod(path, file_mode)

    def check(self):
        old = {k: os.environ.get(k) for k in ("XDG_STATE_HOME", "PAPERCLIP_OMARCHY_TOKEN")}
        os.environ["XDG_STATE_HOME"] = self.home
        os.environ.pop("PAPERCLIP_OMARCHY_TOKEN", None)
        try:
            return status.read_token_checked()
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_a_private_token_file_is_used(self):
        self.write("token", "secret-a\n", 0o600)
        self.assertEqual(self.check(), ("secret-a", ""))

    def test_a_token_file_others_can_read_is_not_used(self):
        for loose in (0o640, 0o644, 0o604, 0o660, 0o666, 0o601):
            self.write("token", "secret-b\n", loose)
            token, problem = self.check()
            self.assertEqual(token, "", oct(loose))
            self.assertEqual(problem, "token file is readable by others; chmod 600 it", oct(loose))

    def test_the_second_file_name_is_checked_the_same_way(self):
        self.write("board-token", "secret-c\n", 0o644)
        self.assertEqual(self.check()[0], "")
        os.chmod(os.path.join(self.state, "board-token"), 0o400)
        self.assertEqual(self.check(), ("secret-c", ""))

    def test_the_report_carries_the_problem_and_never_the_token(self):
        self.write("token", "secret-d\n", 0o644)
        env = dict(self.env, PAPERCLIP_OMARCHY_API_BASE="http://127.0.0.1:1")
        out = subprocess.run([sys.executable, STATUS, "--compact", "--timeout", "1"],
                             env=env, capture_output=True, text=True).stdout
        self.assertNotIn("secret-d", out)
        report = json.loads(out)
        self.assertIn("token file is readable by others; chmod 600 it", report["problems"])
        self.write("token", "secret-d\n", 0o600)
        report = json.loads(subprocess.run([sys.executable, STATUS, "--compact", "--timeout", "1"],
                                           env=env, capture_output=True, text=True).stdout)
        self.assertNotIn("token file is readable by others; chmod 600 it", report["problems"])


class Modes(StateHome):
    def test_the_state_directory_is_0700_even_when_it_was_made_wider(self):
        os.makedirs(self.state, mode=0o755)
        os.chmod(self.state, 0o755)
        self.bash("pc_state_dir >/dev/null")
        self.assertEqual(mode(self.state), 0o700)

    def test_a_new_state_directory_and_what_is_created_in_it_are_private(self):
        self.bash('d=$(pc_state_dir); mkdir "$d/doctor-1"; echo x > "$d/doctor-1/bundle.log"')
        self.assertEqual(mode(self.state), 0o700)
        self.assertEqual(mode(os.path.join(self.state, "doctor-1")), 0o700)
        self.assertEqual(mode(os.path.join(self.state, "doctor-1", "bundle.log")), 0o600)

    def test_the_snooze_file_is_private(self):
        subprocess.run(["bash", os.path.join(ROOT, "bin", "omarchy-paperclip-snooze"), "set", "1h", "5", "0"],
                       env=self.env, capture_output=True, check=True)
        self.assertEqual(mode(os.path.join(self.state, "snooze.json")), 0o600)

    def test_the_python_scripts_set_the_umask(self):
        for name in ("omarchy-paperclip-status", "omarchy-paperclip-inbox"):
            with open(os.path.join(ROOT, "bin", name), encoding="utf-8") as handle:
                self.assertIn("os.umask(0o077)", handle.read(), name)


class Retention(StateHome):
    def test_sessions_older_than_seven_days_are_removed(self):
        os.makedirs(self.state)
        keep = ["doctor-20260101-000000", "session-20260101-000000", "token", "snooze.json", "notes"]
        gone = ["doctor-20250101-000000", "session-20250101-000000"]
        for name in ("doctor-20260101-000000", "session-20260101-000000", "notes"):
            os.mkdir(os.path.join(self.state, name))
        for name in gone:
            os.makedirs(os.path.join(self.state, name, ".claude", "skills"))
            with open(os.path.join(self.state, name, "prompt.txt"), "w") as handle:
                handle.write("x")
        for name in ("token", "snooze.json"):
            with open(os.path.join(self.state, name), "w") as handle:
                handle.write("x")
        for name in gone + ["notes", "token", "snooze.json"]:
            age(os.path.join(self.state, name), 9)
        age(os.path.join(self.state, "doctor-20260101-000000"), 6)
        self.bash("pc_prune_sessions")
        self.assertEqual(sorted(os.listdir(self.state)), sorted(keep))

    def test_doctor_and_agent_prune_when_they_start_their_own_session(self):
        for name in ("omarchy-paperclip-doctor", "omarchy-paperclip-agent"):
            with open(os.path.join(ROOT, "bin", name), encoding="utf-8") as handle:
                self.assertIn("pc_prune_sessions", handle.read(), name)

    def test_a_session_given_by_the_caller_is_not_the_scripts_to_delete(self):
        with open(os.path.join(ROOT, "bin", "omarchy-paperclip-doctor"), encoding="utf-8") as handle:
            text = handle.read()
        branch = text.split("if [[ -z $session ]]; then", 1)[1].split("fi", 1)[0]
        self.assertIn("pc_prune_sessions", branch)


if __name__ == "__main__":
    unittest.main()
