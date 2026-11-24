"""Nothing private in the tree: no tokens, instance ids, host names, home paths or
personal addresses, held by a test that names file:line instead of by a reviewer
reading every diff. `public-text` reads a pull request's words; this reads every
tracked text file.

    python3 test/test_tree_data.py

What fails, on any tracked text file:

  token       a JWT, a `Bearer` followed by a literal, a prefixed key (`pcp_`,
              `ghp_`, `github_pat_`, `sk-`, `AKIA`) or a private key block
  id          a UUID that is not made up (at most four distinct digits) and is
              not on UUID_ALLOWED
  host        a tailnet or LAN name (`*.ts.net`, `*.home.arpa`, `*.lan`,
              `*.internal`, `*.local`) that is not on HOST_ALLOWED
  home path   `/home/<name>` or `/Users/<name>` where the name is not a
              placeholder
  email       an address outside EMAIL_ALLOWED and the reserved example domains

A made-up value passes. The lint runs on planted text as well as on the tree
(`PlantedCases`), and this file is left out of the scan because it plants them.
"""

import os
import re
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF = "test/test_tree_data.py"
BINARY = re.compile(r"\.(png|jpe?g|gif|webp|ico|svg|ttf|otf|woff2?|pdf|zip|gz|pyc)$", re.I)

EMAIL_ALLOWED = {"noreply@paperclip.ing", "noreply@anthropic.com", "noreply@github.com"}
EMAIL_RESERVED_TLDS = {"example", "invalid", "test", "localhost"}
EMAIL_RESERVED_DOMAINS = {"example.com", "example.org", "example.net"}
# `name@autostart.service` is a systemd unit, not a mailbox.
NOT_A_TLD = {"service", "socket", "target", "timer", "path", "mount", "slice", "scope"}
# The skills are synced from upstream; this is an approval id in its worked example.
UUID_ALLOWED = {"ca6ba09d-b558-4a53-a552-e7ef87e54a1b"}
HOST_ALLOWED = {"settings.local"}
HOME_PLACEHOLDERS = {"someone", "user", "you", "me", "name", "username", "example", "alice", "bob", "x", "$user"}

EMAIL = re.compile(r"(?<![\w.%+-])[\w.%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.([A-Za-z]{2,}))\b")
UUID = re.compile(r"(?<![0-9A-Za-z])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Za-z])")
HOST = re.compile(r"(?<![\w.-])([A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.(?:ts\.net|home\.arpa|lan|internal|local))(?![\w-])", re.I)
HOME = re.compile(r"(?<![\w/])/(?:home|Users)/([A-Za-z0-9_.$-]+)")
TOKEN_SHAPES = (
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")),
    ("Bearer value", re.compile(r"\bBearer\s+(?![$<{(\[%*.]|token\b|TOKEN\b|YOUR|xxx|\.\.\.)[A-Za-z0-9._~+/=-]{20,}")),
    ("prefixed key", re.compile(r"\b(?:pcp_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})\b")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
)


def made_up_id(value):
    """An id of at most four distinct digits is a fixture's (`1111…`, `aaaa…`)."""
    return len(set(re.sub(r"[^0-9A-Fa-f]", "", value).lower())) <= 4


def line_problems(line):
    found = []
    for kind, pattern in TOKEN_SHAPES:
        for m in pattern.finditer(line):
            found.append("token (%s): keep secrets out of the tree" % kind)
    for m in UUID.finditer(line):
        if not made_up_id(m.group(0)) and m.group(0).lower() not in UUID_ALLOWED:
            found.append("id %s: use a made-up id" % m.group(0))
    for m in HOST.finditer(line):
        if m.group(1).lower() not in HOST_ALLOWED:
            found.append("host name %s: use a placeholder" % m.group(1))
    for m in HOME.finditer(line):
        if m.group(1).lower() not in HOME_PLACEHOLDERS:
            found.append("home path %s: use /home/someone" % m.group(0))
    for m in EMAIL.finditer(line):
        address, domain, tld = m.group(0), m.group(1).lower(), m.group(2).lower()
        if tld in NOT_A_TLD or tld in EMAIL_RESERVED_TLDS or domain in EMAIL_RESERVED_DOMAINS \
                or address.lower() in EMAIL_ALLOWED:
            continue
        found.append("email %s: use an example.invalid address" % address)
    return found


def text_problems(name, text):
    found = []
    for number, line in enumerate(text.split("\n"), 1):
        for why in line_problems(line):
            found.append("%s:%d: %s" % (name, number, why))
    return found


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True).stdout.decode()
    return sorted(n for n in out.split("\0")
                  if n and n != SELF and not BINARY.search(n) and os.path.isfile(os.path.join(ROOT, n)))


def tree_problems():
    found = []
    for name in tracked_files():
        try:
            with open(os.path.join(ROOT, name), encoding="utf-8") as handle:
                text = handle.read()
        except UnicodeDecodeError:
            continue
        found += text_problems(name, text)
    return found


class NothingPrivateInTheTree(unittest.TestCase):
    def test_the_tree_holds_only_made_up_values(self):
        found = tree_problems()
        self.assertEqual(found, [], "\n".join(found))

    def test_the_tree_is_read(self):
        names = tracked_files()
        for expected in ("Service.qml", "manifest.json", "test/test_security_rules.py"):
            self.assertIn(expected, names)


class PlantedCases(unittest.TestCase):
    def reasons(self, line):
        return [w.split(" ")[0] for w in line_problems(line)]

    def test_a_token_fails_and_a_placeholder_passes(self):
        for line in ("key eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcd1234",
                     "Authorization: Bearer abcDEF123456abcDEF123456",
                     "token pcp_0123456789abcdef0123",
                     "token ghp_0123456789abcdefghijklmnopqrstuvwxyz",
                     "-----BEGIN OPENSSH PRIVATE KEY-----"):
            self.assertEqual(self.reasons(line), ["token"], line)
        for line in ('Authorization: Bearer $PAPERCLIP_API_KEY', "Authorization: Bearer <token>",
                     "Bearer ${TOKEN}", "send a Bearer token", "Bearer YOUR_API_KEY_GOES_HERE"):
            self.assertEqual(self.reasons(line), [], line)

    def test_a_real_id_fails_and_a_made_up_one_passes(self):
        self.assertEqual(self.reasons("id 11111111-1111-4111-8111-111111111111"), [])
        self.assertEqual(self.reasons("id ca6ba09d-b558-4a53-a552-e7ef87e54a1b"), [])
        self.assertEqual(self.reasons("id 4d1e2b9a-7c3f-45a0-8b6d-19e0f2a7c354"), ["id"])

    def test_a_host_name_fails_and_a_placeholder_passes(self):
        self.assertEqual(self.reasons("open settings.local and host.example"), [])
        for line in ("ssh laptop.tail1a2b3.ts.net", "ssh desk.lan", "http://nas.home.arpa:3100", "curl box.local"):
            self.assertEqual(self.reasons(line), ["host"], line)

    def test_a_home_path_fails_and_a_placeholder_passes(self):
        self.assertEqual(self.reasons("cd /home/someone/work and /home/user and /Users/you and ~/work"), [])
        for line in ("cd /home/jo/work", "open /Users/Jo.Doe/Desktop"):
            self.assertEqual(self.reasons(line), ["home"], line)

    def test_an_address_outside_the_allowlist_fails(self):
        self.assertEqual(self.reasons("a@example.invalid b@example.com c@evil.example noreply@paperclip.ing"), [])
        self.assertEqual(self.reasons("app-org.kde.kdeconnect.daemon@autostart.service"), [])
        self.assertEqual(self.reasons("write to jo.doe@gmail.com"), ["email"])
        self.assertEqual(self.reasons("write to someone@example.invalid.net"), ["email"])

    def test_a_problem_names_file_and_line(self):
        found = text_problems("docs/x.md", "fine\ncd /home/jo/work\n")
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith("docs/x.md:2: home path"), found)


if __name__ == "__main__":
    unittest.main()
