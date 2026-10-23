"""bin/omarchy-paperclip-service: what the panel's Start and Stop actually run.

    python3 test/test_service.py

The script runs against a loopback health endpoint that answers only while a
flag file exists, with recording stubs for `systemctl`, the Paperclip CLI and
the terminal launcher. Nothing touches a real unit, a real instance or a real
terminal. Pinned here: Stop and Start go to the CLI (and fall back to systemd),
Stop with no background service refuses in a sentence, Start on a running
instance does nothing, a terminal start opens a terminal, and `--quiet` leaves
stdout empty.
"""

import http.server
import os
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


class ServiceScript(unittest.TestCase):
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

    def run_script(self, *args):
        env = {
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "HOME": self.dir,
            "XDG_STATE_HOME": self.dir,
            "PAPERCLIP_OMARCHY_API_BASE": self.base,
        }
        return subprocess.run([SCRIPT, *args], env=env, capture_output=True, text=True, timeout=90)

    def recorded(self):
        with open(self.calls) as handle:
            return handle.read()

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


if __name__ == "__main__":
    unittest.main()
