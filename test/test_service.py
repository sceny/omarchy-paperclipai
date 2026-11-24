"""bin/omarchy-paperclip-service: what the panel's Start and Stop actually run.

    python3 test/test_service.py

The script runs against a loopback health endpoint that answers only while a
flag file exists, with recording stubs for `systemctl`, the Paperclip CLI and
the terminal launcher. Nothing touches a real unit, a real instance or a real
terminal. Pinned here: Stop and Start go to the CLI (and fall back to systemd),
Stop with no background service refuses in a sentence, Start on a running
instance does nothing, a terminal start opens a terminal, and `--quiet` leaves
stdout empty.

The bar builds one copy of the plugin per screen, so `ScreensShareOneStop`
runs the script as several copies (same session id, same state directory):
a stop through one is honoured by the others, a stop recorded for a unit
stopped from a terminal is not undone, racing copies make one `service start`,
and an explicit Start or a new shell session ends the stop.
"""

import http.server
import os
import time
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "bin", "omarchy-paperclip-service")
sys.dont_write_bytecode = True


def stub(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w") as handle:
        handle.write("#!/bin/bash\n" + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class Harness(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        self.up = os.path.join(self.dir, "up")
        self.calls = os.path.join(self.dir, "calls.log")
        open(self.calls, "w").close()

        up = self.up

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                if os.path.exists(up):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"status":"ok"}')
                else:
                    self.send_response(503)
                    self.end_headers()

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]

        log = self.calls
        # `service start` brings the instance up; `service stop` takes it down.
        stub(self.bin, "paperclipai", 'echo "paperclipai $*" >>"%s"\n'
             '[[ $1 == service && $2 == start ]] && touch "%s"\n'
             '[[ $1 == service && $2 == stop ]] && rm -f "%s"\nexit 0\n' % (log, up, up))
        stub(self.bin, "omarchy-launch-terminal", 'echo "terminal $*" >>"%s"\ntouch "%s"\n' % (log, up))
        self.unit("loaded")

    def unit(self, load_state):
        stub(self.bin, "systemctl", 'echo "systemctl $*" >>"%s"\n'
             '[[ $* == *show* ]] && echo "LoadState=%s"\nexit 0\n' % (self.calls, load_state))

    def script_env(self, **extra):
        env = {
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "HOME": self.dir,
            "XDG_STATE_HOME": self.dir,
            "PAPERCLIP_OMARCHY_API_BASE": self.base,
        }
        env.update(extra)
        return env

    def run_script(self, *args, **env):
        return subprocess.run([SCRIPT, *args], env=self.script_env(**env), capture_output=True,
                              text=True, timeout=90)

    def recorded(self):
        with open(self.calls) as handle:
            return handle.read()


class ServiceScript(Harness):
    def test_stop_asks_the_cli_to_stop_the_service(self):
        open(self.up, "w").close()
        run = self.run_script("stop", "--quiet")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn("paperclipai service stop", self.recorded())
        self.assertFalse(os.path.exists(self.up))

    def test_stop_without_a_background_service_refuses_in_a_sentence(self):
        self.unit("not-found")
        open(self.up, "w").close()
        run = self.run_script("stop", "--quiet")
        self.assertEqual(run.returncode, 1)
        self.assertIn("terminal", run.stderr)
        self.assertNotIn("service stop", self.recorded())
        self.assertTrue(os.path.exists(self.up), "an instance in a terminal is left running")

    def test_start_on_a_running_instance_does_nothing(self):
        open(self.up, "w").close()
        run = self.run_script("start", "--quiet")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertEqual(self.recorded(), "")

    def test_start_runs_the_service_and_waits_for_the_answer(self):
        run = self.run_script("start", "--quiet")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertIn("paperclipai service start", self.recorded())
        self.assertNotIn("terminal", self.recorded())
        self.assertTrue(os.path.exists(self.up))

    def test_start_without_a_service_opens_a_terminal(self):
        self.unit("not-found")
        run = self.run_script("start", "--quiet")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("terminal", self.recorded())
        self.assertIn("run", self.recorded())
        self.assertNotIn("service start", self.recorded())

    def test_stop_falls_back_to_systemd_when_the_cli_cannot(self):
        stub(self.bin, "paperclipai", 'echo "paperclipai $*" >>"%s"\nexit 1\n' % self.calls)
        open(self.up, "w").close()
        run = self.run_script("stop", "--quiet")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("systemctl --user stop paperclipai.service", self.recorded())


class ScreensShareOneStop(Harness):
    """Several copies of the plugin, one session, one state directory."""

    SESSION = "shell-one"

    def setUp(self):
        super().setUp()
        self.state = os.path.join(self.dir, "omarchy", "paperclipai")
        self.marker = os.path.join(self.state, "stopped-by-user")

    def copy(self, verb, session=None, **env):
        return self.run_script(verb, "--quiet", "--session", session or self.SESSION, **env)

    def starts(self):
        return self.recorded().count("paperclipai service start")

    def slow_start(self):
        # A start that takes long enough for a second copy to arrive.
        stub(self.bin, "paperclipai", 'echo "paperclipai $*" >>"%s"\n'
             '[[ $1 == service && $2 == start ]] && { sleep 1; touch "%s"; }\n'
             '[[ $1 == service && $2 == stop ]] && rm -f "%s"\nexit 0\n' % (self.calls, self.up, self.up))

    def test_a_stop_through_one_copy_is_not_undone_by_another(self):
        open(self.up, "w").close()
        self.assertEqual(self.copy("stop").returncode, 0)
        self.assertTrue(os.path.exists(self.marker))
        self.assertFalse(os.path.exists(self.up))
        other = self.copy("autostart")
        self.assertEqual(other.returncode, 0, other.stderr)
        self.assertEqual(self.starts(), 0)
        self.assertFalse(os.path.exists(self.up))

    def test_a_stop_from_a_terminal_is_not_undone_once_it_is_recorded(self):
        # The plugin sees the unit go cleanly inactive and records the stop.
        self.assertEqual(self.copy("mark-stopped").returncode, 0)
        self.assertEqual(self.copy("autostart").returncode, 0)
        self.assertEqual(self.starts(), 0)

    def test_without_a_stop_the_guarded_start_starts_it(self):
        run = self.copy("autostart")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.starts(), 1)
        self.assertTrue(os.path.exists(self.up))

    def test_copies_racing_make_one_start(self):
        self.slow_start()
        procs = [subprocess.Popen([SCRIPT, "autostart", "--quiet", "--session", self.SESSION],
                                  env=self.script_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for _ in range(4)]
        for proc in procs:
            proc.communicate(timeout=90)
            self.assertEqual(proc.returncode, 0)
        self.assertEqual(self.starts(), 1)

    def test_an_explicit_start_waits_for_a_start_in_flight(self):
        self.slow_start()
        auto = subprocess.Popen([SCRIPT, "autostart", "--quiet", "--session", self.SESSION],
                                env=self.script_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.4)
        explicit = self.copy("start")
        auto.communicate(timeout=90)
        self.assertEqual(explicit.returncode, 0, explicit.stderr)
        self.assertEqual(self.starts(), 1)

    def test_one_automatic_attempt_per_ten_minutes_for_every_copy(self):
        self.assertEqual(self.copy("autostart").returncode, 0)
        os.remove(self.up)
        self.assertEqual(self.copy("autostart").returncode, 0)
        self.assertEqual(self.starts(), 1, "the second copy waits out the ten minutes")
        self.assertEqual(self.copy("autostart", PAPERCLIP_AUTO_START_GAP="0").returncode, 0)
        self.assertEqual(self.starts(), 2)

    def test_an_explicit_start_ends_the_stop(self):
        open(self.up, "w").close()
        self.copy("stop")
        self.assertTrue(os.path.exists(self.marker))
        self.assertEqual(self.copy("start").returncode, 0)
        self.assertFalse(os.path.exists(self.marker))
        os.remove(self.up)
        self.assertEqual(self.copy("autostart", PAPERCLIP_AUTO_START_GAP="0").returncode, 0)
        self.assertEqual(self.starts(), 2)

    def test_a_start_with_no_session_still_ends_the_stop(self):
        self.copy("stop")
        self.assertEqual(self.run_script("start", "--quiet").returncode, 0)
        self.assertFalse(os.path.exists(self.marker))

    def test_a_shell_restart_ends_the_stop(self):
        open(self.up, "w").close()
        self.copy("stop")
        self.assertEqual(self.copy("autostart", session="shell-two").returncode, 0)
        self.assertEqual(self.starts(), 1)
        self.assertFalse(os.path.exists(self.marker), "the old session's marker is removed")

    def test_a_stop_by_hand_with_no_session_holds_until_start(self):
        open(self.up, "w").close()
        self.assertEqual(self.run_script("stop", "--quiet").returncode, 0)
        self.assertEqual(self.copy("autostart", session="shell-two").returncode, 0)
        self.assertEqual(self.starts(), 0)

    def test_a_stop_that_fails_leaves_no_marker(self):
        stub(self.bin, "paperclipai", "exit 1\n")
        stub(self.bin, "systemctl", '[[ $* == *show* ]] && echo "LoadState=loaded"\n'
             '[[ $* == *" stop "* ]] && exit 1\nexit 0\n')
        open(self.up, "w").close()
        self.assertEqual(self.copy("stop").returncode, 1)
        self.assertFalse(os.path.exists(self.marker))

    def test_a_stop_with_no_background_service_leaves_no_marker(self):
        self.unit("not-found")
        open(self.up, "w").close()
        self.assertEqual(self.copy("stop").returncode, 1)
        self.assertFalse(os.path.exists(self.marker))

    def test_the_guarded_start_never_opens_a_terminal(self):
        self.unit("not-found")
        self.assertEqual(self.copy("autostart").returncode, 0)
        self.assertNotIn("terminal", self.recorded())
        self.assertEqual(self.starts(), 0)

    def test_the_marker_is_private(self):
        self.copy("mark-stopped")
        self.assertEqual(stat.S_IMODE(os.stat(self.marker).st_mode), 0o600)

    def test_a_session_id_is_a_word(self):
        self.copy("mark-stopped", session="a b;c")
        with open(self.marker) as handle:
            self.assertEqual(handle.read(), "\n")


if __name__ == "__main__":
    unittest.main()
