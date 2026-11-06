"""C4, a list of processes or their command lines put where an AI session reads it.

    python3 test/test_process_lists.py

Every agent Paperclip starts runs under its service, and so does every
command an agent runs. Their command lines carry agent keys (`--mcp-config`
with an `Authorization` header, `curl -H ...`) and the text an agent is
sending (`-d '{"body": ...}'`, `gh ... --body`, `git commit -m`). A tool that
prints processes prints all of that: `systemctl status` (its cgroup tree, each
line in full when stdout is a pipe), `systemd-cgls`, `loginctl user-status`
and `session-status` (the session's process tree, the same way), `ps`,
`pgrep -a`, `top` (any way it is run: `-c` only reverses what the user's
`toprc` remembers), `/proc/<pid>/cmdline` and `environ`, and `ss -p` /
`netstat -p`, which name a socket's process by a name any process can set.
Each is caught as the call, however it is spelled: a shell line, after a
prefix that runs it (`sudo top`, `timeout 5 top`), or as an argv list
(`subprocess.run(["ps", "aux"])`).
What the scripts in `bin/` and `lib/` print goes into the doctor bundle, and
what `skills/` say to run goes into the session itself. A line that uses one
is listed in ALLOWED with the reason its output reaches no AI session and holds
no command line, or the build fails naming file:line. Comment lines are not
read."""

import os
import re
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOLDERS = ("bin", "lib", "skills")

# A list item in quotes: argv[0] of `subprocess.run([...])`, `execvp(...)`, or a
# word after a prefix in the same list (`["sudo", "top"]`).
ARGV = r"[\[(,]\s*[\"']%s[\"']\s*[,\])]"
# What runs the next word as the command: `sudo top`, `timeout 5 top`,
# `nice -n 10 top`, `env TERM=dumb top`.
PREFIX = (r"\b(?:sudo|doas|exec|command|nohup|setsid|env|nice|ionice|timeout|stdbuf|runuser)"
          r"(?:\s+-\S+(?:\s+[^\s-]\S*)?|\s+\S+=\S*|\s+\d\S*)*\s+")
# Between a command and its next argument: a space, or the end of one quoted
# list item and the start of the next.
SEP = r"(?:\s+|[\"']\s*,\s*[\"'])"

PROCESS_LISTS = [re.compile(p) for p in (
    r"\bsystemctl\b.*[\s\"']status\b",
    r"\bsystemd-cgls\b",
    r"\bloginctl\b.*[\s\"'](?:user|session)-status\b",
    r"(?:^|[\s;|&(`$\"'])ps\s+[-a-z]|" + ARGV % "ps",
    r"\bpgrep\b.*[\s\"']-(?:[A-Za-z]*[al][A-Za-z]*\b|-list-(?:full|name)\b)",
    r"(?:^|[\s;|&(`$\"'])top(?:\s+-|\s*\d*[<>]|\s*[;|&)`])|(?:^\s*|[;|&(`$]\s*)top\s*$|"
    + PREFIX + r"top\b(?![-.\w])|" + ARGV % "top",
    r"/proc/\S*/(?:cmdline|environ)\b",
    r"\b(?:ss|netstat)" + SEP + r"-[A-Za-z]*p",
)]

# (file, the line, spaces collapsed) -> why what it prints reaches no AI session
# and holds no command line. A changed line is read again.
ALLOWED = {
    ("skills/paperclip/scripts/paperclip-upload-artifact.sh",
     'ps -p "$pid" -o lstart= 2>/dev/null | tr -s \'[:space:]\' \' \' | sed \'s/^ //;s/ $//\''):
        "prints one process's start time only (`-o lstart=`), never its command line; copied unchanged from upstream",
}


def squash(line):
    return re.sub(r"\s+", " ", line.strip())


def process_lists(root=ROOT, allowed=None):
    """(the uses not in `allowed`, the allowed entries that were met)."""
    allowed = ALLOWED if allowed is None else allowed
    found, met = [], set()
    for top in FOLDERS:
        for folder, _, names in os.walk(os.path.join(root, top)):
            for name in sorted(names):
                path = os.path.join(folder, name)
                try:
                    with open(path) as f:
                        lines = f.read().splitlines()
                except (UnicodeDecodeError, OSError):
                    continue
                rel = os.path.relpath(path, root)
                for number, line in enumerate(lines, 1):
                    if line.lstrip().startswith(("#", "//")) or not any(r.search(line) for r in PROCESS_LISTS):
                        continue
                    key = (rel, squash(line))
                    if key in allowed:
                        met.add(key)
                    else:
                        found.append("%s:%d: lists processes or their command lines (`%s`) and the line is not in ALLOWED"
                                     % (rel, number, key[1][:80]))
    return found, met


class NoProcessListsForTheSession(unittest.TestCase):
    def test_nothing_lists_processes(self):
        found, _ = process_lists()
        self.assertEqual(found, [], "\n" + "\n".join(found))

    def test_every_allowed_line_is_still_there(self):
        _, met = process_lists()
        stale = sorted(k for k in ALLOWED if k not in met)
        self.assertEqual(stale, [], "taken out of the code, take out of ALLOWED")

    def test_every_allowed_line_says_why(self):
        for key, why in ALLOWED.items():
            self.assertGreater(len(why.split()), 3, key)
            self.assertNotIn("\n", why, key)

    def test_each_kind_of_process_list_fails(self):
        planted = {
            "systemctl status": "systemctl --user status paperclipai.service --no-pager -n 0",
            "systemd-cgls": "systemd-cgls --user-unit paperclipai.service",
            "ps": "ps aux | grep node",
            "ps -ef": "out=$(ps -ef)",
            "pgrep -a": "pgrep -af paperclip",
            "pgrep --list-full": "pgrep --list-full node",
            "loginctl user-status": "loginctl user-status --no-pager",
            "loginctl session-status": 'loginctl session-status "$XDG_SESSION_ID" >>"$bundle"',
            "top": "top",
            "top -c": "top -c",
            "top -bc": "out=$(top -bcn1)",
            "top -b ... -c": "top -b -n 1 -c | head -40",
            "top -bn1": "top -bn1 | head -5",
            "top --cmdline-toggle": "top -b --cmdline-toggle",
            "top into a file": 'top -b -n 1 >"$bundle"',
            "cmdline": 'tr "\\0" " " </proc/$pid/cmdline',
            "environ": "open('/proc/%d/environ' % pid)",
            "ss -p": "ss -ltnp",
            "netstat -p": "netstat -ltnp",
            "a skill's command": "systemctl --user status paperclipai.service",
            "systemctl status as argv": 'subprocess.run(["systemctl", "--user", "status", unit])',
            "systemd-cgls as argv": "subprocess.run(['systemd-cgls', '--no-pager'])",
            "loginctl user-status as argv": 'check_output(["loginctl", "user-status"])',
            "loginctl session-status as argv": "run(['loginctl', 'session-status', sid])",
            "ps as argv": 'subprocess.run(["ps", "aux"], capture_output=True)',
            "ps alone as argv": 'check_output(["ps"])',
            "pgrep -a as argv": 'subprocess.run(["pgrep", "-a", "node"])',
            "top as argv": 'subprocess.run(["top", "-b", "-n", "1"])',
            "top after a prefix as argv": 'subprocess.run(["timeout", "5", "top", "-b"])',
            "ss -p as argv": 'subprocess.run(["ss", "-ltnp"])',
            "netstat -p as argv": "run(['netstat', '-ltnp'])",
            "sudo top": "sudo top",
            "sudo -u top": "sudo -u someone top",
            "timeout top": "timeout 5 top",
            "nice top": "nice -n 10 top",
            "env top": "env TERM=dumb top",
            "top redirected before its options": "top 2>/dev/null -b",
            "top fed from /dev/null": "top </dev/null",
        }
        for what, line in planted.items():
            with tempfile.TemporaryDirectory() as d:
                os.makedirs(os.path.join(d, "skills", "x"))
                with open(os.path.join(d, "skills", "x", "SKILL.md"), "w") as f:
                    f.write("Run this:\n%s\n" % line)
                found, _ = process_lists(d, allowed={})
                self.assertEqual(len(found), 1, what)
                self.assertIn("skills/x/SKILL.md:2:", found[0], what)

    def test_fixed_fields_and_plain_words_pass(self):
        for line in ("systemctl --user show paperclipai.service --property=ActiveState,MainPID",
                     "systemctl --user is-active paperclipai.service",
                     "pgrep -f 'quickshell' >/dev/null", "ss -ltn", "netstat -ltn",
                     "loginctl show-user \"$USER\" --property=Linger", "loginctl list-sessions",
                     "the top of the list", "stop -c", "top-level `url`",
                     "at the top.", "htop -c",
                     "paperclipai service status --json", "the steps it takes",
                     "open('/proc/net/tcp')",
                     'subprocess.run(["systemctl", "--user", "show", unit, "--property=ActiveState"])',
                     "subprocess.run(['pgrep', '-f', 'quickshell'])", 'run(["ss", "-ltn"])',
                     'run(["loginctl", "show-user", user])', 'run(["htop"])', 'run(["pstree"])',
                     '{"position": "top", "margin": 0}', "align: 'top',",
                     "sudo is not needed at the top", "timeout is set at the top.",
                     "env top-level keys", "the top 10 items", "the status of the top"):
            with tempfile.TemporaryDirectory() as d:
                os.makedirs(os.path.join(d, "bin"))
                with open(os.path.join(d, "bin", "tool"), "w") as f:
                    f.write(line + "\n")
                self.assertEqual(process_lists(d, allowed={})[0], [], line)

    def test_comments_are_not_read(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "lib"))
            with open(os.path.join(d, "lib", "tool.sh"), "w") as f:
                f.write("# systemctl status is what this does not do\n"
                        "# nor loginctl user-status, loginctl session-status or top -bc\n")
            self.assertEqual(process_lists(d, allowed={})[0], [])

    def test_a_planted_process_list_in_the_real_tree_fails(self):
        with tempfile.TemporaryDirectory() as d:
            for top in FOLDERS:
                if os.path.isdir(os.path.join(ROOT, top)):
                    shutil.copytree(os.path.join(ROOT, top), os.path.join(d, top))
            self.assertEqual(process_lists(d)[0], [])
            with open(os.path.join(d, "bin", "omarchy-paperclip-doctor"), "a") as f:
                f.write('\nsystemctl --user status paperclipai.service --no-pager -n 0 >>"$bundle"\n')
            found = process_lists(d)[0]
            self.assertEqual(len(found), 1)
            self.assertIn("bin/omarchy-paperclip-doctor:", found[0])


if __name__ == "__main__":
    unittest.main()
