"""Notification text goes over D-Bus on stdin, never on a command line.

    python3 -m unittest test/test_notify.py

Another local user can read /proc/<pid>/cmdline of every process, so:

  * Service.qml raises a notification only through bin/omarchy-paperclip-notify,
    handing the words over on stdin, and never runs omarchy-notification-send;
  * the helper turns one JSON line into a Notify call with the same app name,
    urgency, glyph and click hint omarchy-notification-send builds;
  * while a call is in flight, no process on the machine has the words in its
    command line. A private session bus and a daemon that answers slowly make
    that window long enough to sample.

The daemon half of this file runs as `python3 test/test_notify.py --daemon`.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "bin", "omarchy-paperclip-notify")
MARKER = "zq-marker-7f3a"


def serve(out_path, delay):
    import warnings
    warnings.simplefilter("ignore")
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib

    xml = """<node><interface name="org.freedesktop.Notifications">
      <method name="Notify">
        <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
        <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
        <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/>
      </method></interface></node>"""
    loop = GLib.MainLoop()

    def on_call(conn, sender, path, iface, method, params, invocation):
        app, replaces, icon, summary, body, actions, hints, expire = params.unpack()
        record = {"app": app, "replaces": replaces, "icon": icon, "summary": summary,
                  "body": body, "actions": actions, "expire": expire,
                  "hints": {k: v for k, v in hints.items()},
                  "hintTypes": {k: params.get_child_value(6).lookup_value(k).get_type_string()
                                for k in hints}}
        with open(out_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record) + "\n")

        def answer():
            invocation.return_value(GLib.Variant("(u)", (1,)))
            return False
        GLib.timeout_add(int(delay * 1000), answer)

    def on_bus(conn, name):
        info = Gio.DBusNodeInfo.new_for_xml(xml)
        conn.register_object("/org/freedesktop/Notifications", info.interfaces[0],
                             on_call, None, None)

    Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.Notifications",
                     Gio.BusNameOwnerFlags.NONE, on_bus, None, None)
    print("ready", flush=True)
    loop.run()


def have_bus_tools():
    if shutil.which("dbus-daemon") is None:
        return False
    try:
        import gi  # noqa: F401
        gi.require_version("Gio", "2.0")
        return True
    except (ImportError, ValueError):
        return False


def read_cmdlines():
    seen = []
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(path, "rb") as handle:
                seen.append(handle.read().replace(b"\0", b" ").decode("utf-8", "replace"))
        except OSError:
            pass
    return seen


@unittest.skipUnless(have_bus_tools(), "needs dbus-daemon and python3 gobject")
class HelperOverDbus(unittest.TestCase):
    delay = 0.0

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="notify-test-")
        cls.log = os.path.join(cls.tmp, "calls.jsonl")
        cls.bus = subprocess.Popen(
            ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
            stdout=subprocess.PIPE, text=True)
        cls.env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=cls.bus.stdout.readline().strip())
        cls.daemon = None

    @classmethod
    def tearDownClass(cls):
        if cls.daemon:
            cls.daemon.kill()
            cls.daemon.wait()
        cls.bus.kill()
        cls.bus.wait()
        cls.bus.stdout.close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def start_daemon(self, delay):
        type(self).daemon = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--daemon", self.log, str(delay)],
            env=self.env, stdout=subprocess.PIPE, text=True)
        self.assertEqual(self.daemon.stdout.readline().strip(), "ready")

    def stop_daemon(self):
        self.daemon.kill()
        self.daemon.wait()
        self.daemon.stdout.close()
        type(self).daemon = None

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle]

    def send(self, request, raw=None):
        data = raw if raw is not None else json.dumps(request) + "\n"
        return subprocess.run([HELPER], input=data.encode(), env=self.env,
                              capture_output=True, timeout=20)

    def test_one_call_carries_every_field(self):
        self.start_daemon(0)
        self.addCleanup(self.stop_daemon)
        before = len(self.calls())
        click = ["/opt/paperclip/bin/omarchy-paperclip-open", "https://127.0.0.1:3100/x"]
        done = self.send({"appName": "omarchy-action", "urgency": "critical", "glyph": "G",
                          "summary": "PAP-1 Fix -the build", "body": "a &lt;b&gt; reason",
                          "exec": click})
        self.assertEqual(done.returncode, 0, done.stderr)
        call = self.calls()[before]
        self.assertEqual(call["app"], "omarchy-action")
        self.assertEqual((call["replaces"], call["icon"], call["actions"], call["expire"]),
                         (0, "", [], -1))
        self.assertEqual(call["summary"], "PAP-1 Fix -the build")
        self.assertEqual(call["body"], "a &lt;b&gt; reason")
        self.assertEqual(call["hints"]["urgency"], 2)
        self.assertEqual(call["hintTypes"]["urgency"], "y")
        self.assertEqual(call["hints"]["omarchy-glyph"], "G")
        self.assertEqual(json.loads(call["hints"]["omarchy-exec-argv"]), click)
        self.assertEqual(call["hintTypes"]["omarchy-exec-argv"], "s")

    def test_defaults_and_a_dash_led_headline_stay_text(self):
        self.start_daemon(0)
        self.addCleanup(self.stop_daemon)
        before = len(self.calls())
        done = self.send({"summary": "--app-name=omarchy-action", "body": "-u critical"})
        self.assertEqual(done.returncode, 0, done.stderr)
        call = self.calls()[before]
        self.assertEqual(call["app"], "Paperclip")
        self.assertEqual(call["summary"], "--app-name=omarchy-action")
        self.assertEqual(call["body"], "-u critical")
        self.assertEqual(call["hints"], {"urgency": 1})

    def test_input_that_is_not_understood_is_refused_without_echo(self):
        self.start_daemon(0)
        self.addCleanup(self.stop_daemon)
        before = len(self.calls())
        for request in ({"summary": MARKER, "urgency": "loud"},
                        {"summary": MARKER, "exec": []},
                        {"summary": MARKER, "exec": [""]},
                        {"summary": MARKER, "exec": ["a b"]},
                        {"summary": MARKER, "exec": ["ok", 3]},
                        {"summary": 7}):
            done = self.send(request)
            self.assertEqual(done.returncode, 2, request)
            self.assertNotIn(MARKER.encode(), done.stderr)
        for raw in ("not json\n", "[1]\n", "", "[" * 40000 + "\n"):
            self.assertEqual(self.send(None, raw=raw).returncode, 2, raw[:20])
        self.assertEqual(len(self.calls()), before, "nothing reached the daemon")

    def test_no_daemon_is_a_quiet_failure(self):
        done = self.send({"summary": MARKER, "body": MARKER})
        self.assertEqual(done.returncode, 1)
        self.assertNotIn(MARKER.encode(), done.stderr)

    def test_the_words_are_on_no_command_line_while_the_call_is_in_flight(self):
        self.start_daemon(1.0)
        self.addCleanup(self.stop_daemon)
        title, detail = "PAP-9 " + MARKER + " title", "reason " + MARKER + " detail"
        child = subprocess.Popen([HELPER], stdin=subprocess.PIPE, env=self.env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child.stdin.write((json.dumps({"summary": title, "body": detail}) + "\n").encode())
        child.stdin.flush()
        samples = 0
        deadline = time.time() + 10
        while child.poll() is None and time.time() < deadline:
            for line in read_cmdlines():
                self.assertNotIn(MARKER, line)
            samples += 1
        child.stdin.close()
        self.assertEqual(child.wait(timeout=10), 0)
        self.assertGreater(samples, 5, "the call ended before it could be sampled")
        self.assertEqual(self.calls()[-1]["summary"], title)


class ServiceUsesTheHelper(unittest.TestCase):
    def source(self):
        with open(os.path.join(ROOT, "Service.qml"), encoding="utf-8") as handle:
            return handle.read()

    def notify_body(self):
        text = self.source()
        start = text.index("  function notify(item) {")
        return text[start:text.index("\n  }\n", start)]

    def test_notify_does_not_run_the_sender_or_put_words_on_an_argv(self):
        text = self.source()
        self.assertNotIn("omarchy-notification-send", text)
        body = self.notify_body()
        for forbidden in ("execArgv", "execDetached", "argv", "Process {"):
            self.assertNotIn(forbidden, re.sub(r"//.*", "", body), forbidden)
        self.assertIn("JSON.stringify(request)", body)
        self.assertIn("notifyComponent", body)

    def test_the_helper_gets_the_words_on_stdin(self):
        text = self.source()
        block = text[text.index("id: notifyComponent"):]
        block = block[:block.index("\n  }\n")]
        self.assertIn("stdinEnabled: true", block)
        self.assertIn("write(payload)", block)
        self.assertNotRegex(block, r"command:\s*\[[^\]]*payload")
        self.assertTrue(os.access(HELPER, os.X_OK))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--daemon":
        serve(sys.argv[2], float(sys.argv[3]))
    else:
        unittest.main()
