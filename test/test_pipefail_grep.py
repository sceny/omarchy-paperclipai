"""A pipe into a grep that stops reading early, under `pipefail`.

    python3 test/test_pipefail_grep.py

`grep -q` (and `-m`, `--quiet`, `--max-count`, or GNU grep writing to
/dev/null) exits at its first match. A command still writing into the pipe then
dies of SIGPIPE, and under `set -o pipefail` the pipeline fails: a match reads
as "not found", at random, depending on whether the writer's next write came
before or after grep left. Bash line-buffers its own output, so a shell function
writes once per line and loses that race now and then. That is how the rig
selftest's "ps shows rig B" failed once and passed on rerun.

The scripts in `bin/`, `lib/` and `dev/` run under `pipefail` or are sourced by
one that does, so none of them pipes into such a grep. They write
`grep -q PATTERN < <(command)`: grep's status is the only one tested, and an
empty output stays empty (a here-string would add a line `grep -v` matches).
Comment lines are not read.
"""

import os
import re
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOLDERS = ("bin", "lib", "dev")

# `| grep` with -q/-m in any short-flag group, --quiet/--silent/--max-count, or
# its output sent to /dev/null, before the next pipe or the end of the command.
EARLY_GREP = re.compile(
    r"\|\s*(?:\S*/)?grep\b[^|;&)]*?"
    r"(?:\s-[A-Za-z]*[qm]|\s--(?:quiet|silent|max-count)\b|>\s*/dev/null)")


def shell_files():
    for folder in FOLDERS:
        for base, _, names in os.walk(os.path.join(ROOT, folder)):
            for name in names:
                path = os.path.join(base, name)
                try:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                except (UnicodeDecodeError, OSError):
                    continue
                first = text.split("\n", 1)[0]
                if name.endswith(".sh") or re.match(r"#!.*\b(?:ba)?sh\b", first):
                    yield os.path.relpath(path, ROOT), text


def findings(text):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if EARLY_GREP.search(line):
            out.append(n)
    return out


def bash(script):
    return subprocess.run(["bash", "-c", "set -o pipefail\n" + script],
                          capture_output=True, text=True).returncode


# The writer matches first, then writes again after grep has had time to leave.
WRITER = 'w() { echo want; sleep 0.2; echo more; }\n'


class PipefailGrep(unittest.TestCase):
    def test_no_script_pipes_into_an_early_grep(self):
        bad = [f"{path}:{n}" for path, text in shell_files() for n in findings(text)]
        self.assertEqual(bad, [], "pipe into grep -q under pipefail; write "
                         "`grep -q PAT < <(command)` instead")

    def test_the_lint_sees_each_spelling(self):
        for line in ('cmd_ps | grep -q "$1"', "x | grep -qvx $$", "x | grep -Fq a",
                     "x | grep -m1 a", "x | grep --quiet a", "x | /usr/bin/grep -q a",
                     "x | grep a >/dev/null", "! x | grep -q a; y"):
            self.assertEqual(findings(line), [1], line)
        for line in ("grep -q a < <(x)", "x | grep a | sort", "x | grep -c a",
                     "# x | grep -q a", "x | grep -v a > out"):
            self.assertEqual(findings(line), [], line)

    def test_the_mechanism(self):
        # The pipe fails although the line is there: the writer's second write
        # meets a closed pipe.
        self.assertNotEqual(bash(WRITER + "w | grep -q want"), 0)
        # The form the scripts use finds it, and does not find what is absent.
        self.assertEqual(bash(WRITER + "grep -q want < <(w)"), 0)
        self.assertNotEqual(bash(WRITER + "grep -q absent < <(w)"), 0)
        # Empty output stays empty, so -v finds nothing in it.
        self.assertNotEqual(bash("grep -qv x < <(true)"), 0)


if __name__ == "__main__":
    unittest.main()
