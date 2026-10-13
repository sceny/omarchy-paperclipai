"""Two class lints, written against the sink and not against the case that was reported.

    python3 -m unittest test/test_private_text.py

C1  Private text on a command line. `/proc/<pid>/cmdline` is readable by every
    local user, so nothing a person or an agent wrote (a title, a reason, a name)
    may be an element of an argv the QML starts. The scan finds every place QML
    builds an argv and every element that is not a string literal. Each such
    element must be on ALLOWED below, with the reason it is not private text. A
    new expression fails the build until a reviewer reads it and adds it.

C2  The clipboard read without a paste by the user. Qt reads the clipboard in
    QQuickTextInput, so no `*.qml` may use a type built on it, and nothing may
    reach the clipboard by another path. A future text field follows the
    Devices plugin's PanelField: a plain-text TextEdit, never toggled read-only.
"""

import glob
import os
import re
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (file, normalised expression) -> why it is not text a person or an agent wrote.
ALLOWED = {
    # A local vector. Every assignment to a variable named `argv`, and every
    # `argv.push(...)`, is scanned in the same file, so what it holds is checked.
    ("Service.qml", "argv"): "local vector; every assignment to it is scanned",
    ("Service.qml", "_job.argv"): "the queue holds only vectors built by inboxArgv(); enqueue() is scanned",
    # Paths of the plugin's own scripts, set from the plugin directory.
    ("Service.qml", "statusScript"): "plugin script path",
    ("Service.qml", "serviceScript"): "plugin script path",
    ("Service.qml", "snoozeScript"): "plugin script path",
    ("Service.qml", "inboxScript"): "plugin script path",
    ("Service.qml", "openScript"): "plugin script path",
    ("Service.qml", "setupScript"): "plugin script path",
    ("Service.qml", "doctorScript"): "plugin script path",
    ("Service.qml", "webappScript"): "plugin script path",
    # Settings the user typed into the bar's own configuration, not instance text.
    ("Service.qml", "instance"): "the user's own `instance` setting (a name of their choosing)",
    ("Service.qml", "apiBase"): "the user's own `apiBase` setting (their own address)",
    # Fixed choices.
    ("Service.qml", 'panelOpen ? "60" : "20"'): "two literals",
    ("Service.qml", "inboxFilter"): "a plugin enum (needs-me / all), normalised by Model.inboxFilterSetting",
    ("Service.qml", 'quiet.bypass ? "omarchy-action" : "Paperclip"'): "two literals",
    ("Service.qml", 'String(item.urgency || "normal")'): "Model.js sets urgency to low / normal / critical",
    ("Service.qml", 'String(item.glyph || Model.stateGlyph(root.instanceState))'): "an icon glyph from Model.js",
    ('Service.qml', 'next.step === "" ? "none" : next.step'): "a snooze step chosen from Model.js constants",
    ("Service.qml", "String(next.until)"): "a timestamp",
    ("Service.qml", "String(next.focusUntil)"): "a timestamp",
    ("Service.qml", "String(key)"): "a setting name the plugin passes as a literal",
    ("Service.qml", "clean"): "setSetting() strips it to [A-Za-z0-9._-]",
    ("Service.qml", "newWindow === true"): "a boolean",
    # Ids. They are opaque identifiers the API minted, never a title or a reason.
    ("Service.qml", "member.companyId"): "an id",
    ("Service.qml", "member.itemKey"): "an item key (kind and id)",
    ("Service.qml", "member.issueId"): "an id",
    ("Service.qml", "member.actionId"): "an id",
    ("Service.qml", "member.agentId"): "an id",
    ("Service.qml", "member.runId"): "an id",
    ("Service.qml", "company"): "a company id, taken from the rows' companyId",
    ("Service.qml", "String(_retryBudget)"): "a count",
    ("Service.qml", "verb"): "a literal chosen two lines above: restore or dismiss",
    # The page to open. omarchy-paperclip-open opens it only on the instance's own
    # origin; the value is a path or url the server built (an issue path or a
    # run path), never the title or the reason.
    ("Service.qml", 'String(item.url || "")'): "a page path or url, opened only on the instance's own origin",
    ("Service.qml", "String(url)"): "a page path or url, opened only on the instance's own origin",
    ("Service.qml", 'url || ""'): "a page path or url, opened only on the instance's own origin",
    ("Service.qml", "url"): "a page path or url, opened only on the instance's own origin",
    ("Service.qml", 'String(item.action || "open")'): "a verb from Model.js: open, url, setup, doctor, start, webapp",
    ("Service.qml", "action"): "the vector actionArgv() returned, or a verb from Model.js; its returns are scanned",
    ("Service.qml", "args"): "inboxArgv()'s parameter; every call to inboxArgv() is scanned",
}

# Instances of the class that exist today. Each is a bug with a task of its own
# and is NOT reviewed-and-fine: the test fails when an entry stops matching, so the
# fix has to delete it. Nothing may be added here to make a new case pass.
OPEN = {
    ("Service.qml", 'Model.notificationSummary(item.summary || "Paperclip")'): "SCE-615",
    ("Service.qml", 'Model.notificationBody(item.body || "")'): "SCE-615",
}

# An allowlist entry that names one of these is text from the instance.
TEXT_WORDS = re.compile(r"\b(summary|body|title|detail|details|whyNow|label|text|name|description|message|reason)\b")

SINK_CALL = re.compile(r"(?<![\w.])(?:Util\.execArgv|Quickshell\.execDetached|execDetached)\s*\(|"
                       r"(?<![\w.])enqueue\s*\(")
ARGV_CALL = re.compile(r"\b(\w*[Aa]rgv)\s*\(")
ARGV_ASSIGN = re.compile(r"(?<![\w.])argv\s*=(?![=>])")
ARGV_PUSH = re.compile(r"(?<![\w.])argv\.push\s*\(")
COMMAND_ASSIGN = re.compile(r"(?:\.command\s*=(?!=)|(?<![\w.])command\s*:)")
ARGV_FUNCTION = re.compile(r"function\s+(\w*[Aa]rgv)\s*\(")

FORBIDDEN_TYPES = ["TextInput", "TextField", "TextArea", "NumberField", "MultiSelect", "SearchableDropdown"]
CLIPBOARD_WORDS = re.compile(r"clipboardText|wl-paste|cliphist")
UI_DIR = "/usr/share/omarchy/shell/Ui"


# ---------------------------------------------------------------- lexical helpers


def strip_comments(src):
    """Remove // and /* */ comments, keep strings and line structure."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def skip_string(s, i):
    q = s[i]
    j = i + 1
    while j < len(s) and s[j] != q:
        j += 2 if s[j] == "\\" else 1
    return j


def top_level(s, chars):
    """Indexes of the given characters outside strings and brackets."""
    found, depth, i = [], 0, 0
    while i < len(s):
        c = s[i]
        if c in "\"'`":
            i = skip_string(s, i)
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c in chars:
            found.append(i)
        i += 1
    return found


def split_top(s, ch):
    parts, last = [], 0
    for i in top_level(s, ch):
        parts.append(s[last:i])
        last = i + 1
    parts.append(s[last:])
    return parts


def closing(s, i):
    """Index of the bracket that closes the one at s[i]."""
    depth, j = 0, i
    while j < len(s):
        c = s[j]
        if c in "\"'`":
            j = skip_string(s, j)
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return len(s) - 1


def norm(expr):
    return re.sub(r"\s+", " ", expr).strip()


def is_literal(s):
    s = s.strip()
    return bool(re.fullmatch(r"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|-?\d+(?:\.\d+)?|true|false", s))


def statement(src, start):
    """The expression that begins at src[start], up to the end of its statement."""
    i, depth = start, 0
    while i < len(src):
        c = src[i]
        if c in "\"'`":
            i = skip_string(src, i)
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and c == ";":
            break
        elif depth == 0 and c == "\n":
            rest = src[i + 1:].lstrip()
            here = src[start:i].rstrip()
            if not (re.match(r"[?:.]|\|\||&&|\+", rest) or re.search(r"([?:,+]|\|\||&&)$", here)):
                break
        i += 1
    return src[start:i]


# ------------------------------------------------------------------ the argv parse


def leaves(expr):
    """The non-literal elements of an argv expression, as normalised text."""
    s = expr.strip()
    if s == "" or is_literal(s):
        return []
    qs = top_level(s, "?")
    if qs:
        rest = s[qs[0] + 1:]
        colons = top_level(rest, ":")
        if colons:
            return leaves(rest[:colons[0]]) + leaves(rest[colons[0] + 1:])
    if re.fullmatch(r"\w*[Aa]rgv\s*\(.*\)", s, re.S) and closing(s, s.index("(")) == len(s) - 1:
        return []
    if s.startswith("["):
        end = closing(s, 0)
        out = []
        for element in split_top(s[1:end], ","):
            element = element.strip()
            if element and not is_literal(element):
                out.append(norm(element))
        return out + chain(s[end + 1:])
    if ".concat(" in s and top_level_concat(s):
        k = top_level_concat(s)[0]
        return leaves(s[:k]) + chain(s[k:])
    return [norm(s)]


def top_level_concat(s):
    return [m.start() for m in re.finditer(r"\.concat\s*\(", s) if bracket_depth(s, m.start()) == 0]


def bracket_depth(s, pos):
    depth, i = 0, 0
    while i < pos:
        c = s[i]
        if c in "\"'`":
            i = skip_string(s, i)
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        i += 1
    return depth


def chain(tail):
    out = []
    for m in re.finditer(r"\.concat\s*\(", tail):
        if bracket_depth(tail, m.start()) != 0:
            continue
        out += leaves(tail[m.end():closing(tail, m.end() - 1)])
    return out


def sites(src):
    """Yield (line, expression) for every place an argv is built."""
    code = strip_comments(src)

    def line_of(pos):
        return code.count("\n", 0, pos) + 1

    for m in COMMAND_ASSIGN.finditer(code):
        yield line_of(m.end()), statement(code, m.end())
    for m in ARGV_ASSIGN.finditer(code):
        yield line_of(m.end()), statement(code, m.end())
    for m in ARGV_PUSH.finditer(code):
        end = closing(code, m.end() - 1)
        yield line_of(m.end()), code[m.end():end]
    for m in SINK_CALL.finditer(code):
        end = closing(code, m.end() - 1)
        args = split_top(code[m.end():end], ",")
        if m.group(0).lstrip().startswith("enqueue"):
            args = args[2:3]
        for arg in args:
            yield line_of(m.end()), arg
    for m in ARGV_CALL.finditer(code):
        before = code[:m.start()].rstrip()
        if before.endswith("function") or before.endswith("."):
            continue
        end = closing(code, m.end() - 1)
        for arg in split_top(code[m.end():end], ","):
            yield line_of(m.end()), arg
    for m in ARGV_FUNCTION.finditer(code):
        open_brace = code.find("{", m.end())
        close_brace = closing(code, open_brace)
        body = code[open_brace:close_brace]
        for r in re.finditer(r"\breturn\b", body):
            yield line_of(open_brace + r.end()), statement(body, r.end())


def c1_violations(name, src, allowed=None, open_=None):
    """Every argv element in src that is neither a literal nor allowed. Returns (bad, used_open)."""
    allowed = ALLOWED if allowed is None else allowed
    open_ = OPEN if open_ is None else open_
    bad, used = [], set()
    for line, expr in sites(src):
        for leaf in leaves(expr):
            if (name, leaf) in open_:
                used.add((name, leaf))
            elif (name, leaf) not in allowed:
                bad.append("%s:%d  %s" % (name, line, leaf))
    return sorted(set(bad)), used


def c2_violations(name, src, forbidden=None):
    code = strip_comments(src)
    forbidden = FORBIDDEN_TYPES if forbidden is None else forbidden
    bad = []
    for word in forbidden:
        for m in re.finditer(r"\b%s\b" % re.escape(word), code):
            bad.append("%s:%d  %s" % (name, code.count("\n", 0, m.start()) + 1, word))
    for m in CLIPBOARD_WORDS.finditer(code):
        bad.append("%s:%d  %s" % (name, code.count("\n", 0, m.start()) + 1, m.group(0)))
    return bad


def ui_wrappers_of_textinput():
    """Names of qs.Ui components that are, or contain, a QQuickTextInput."""
    if not os.path.isdir(UI_DIR):
        return set()
    files = {}
    for path in glob.glob(os.path.join(UI_DIR, "*.qml")):
        with open(path, encoding="utf-8") as handle:
            files[os.path.basename(path)[:-4]] = strip_comments(handle.read())
    found = {n for n, code in files.items() if re.search(r"\b(TextInput|TextField|TextArea)\b", code)}
    grew = True
    while grew:
        grew = False
        for n, code in files.items():
            if n not in found and any(re.search(r"\b%s\b" % w, code) for w in found):
                found.add(n)
                grew = True
    return found


# --------------------------------------------------------------------------- tests


def tracked():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True).stdout.decode()
    return [n for n in out.split("\0") if n and os.path.isfile(os.path.join(ROOT, n))]


def read(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as handle:
        return handle.read()


def qml_files():
    return [n for n in tracked() if n.endswith(".qml") and not n.startswith("test/")]


class C1NoPrivateTextOnArgv(unittest.TestCase):
    def test_every_argv_element_is_a_literal_or_reviewed(self):
        bad, seen = [], 0
        for name in qml_files():
            found, _ = c1_violations(name, read(name))
            bad += found
            seen += len(list(sites(read(name))))
        self.assertGreater(seen, 10, "found no argv sites; the scan is broken")
        self.assertEqual(bad, [], "an argv element that is not a literal and not on ALLOWED. "
                         "If it can hold a title, a reason or any text from the instance, "
                         "it must not be on a command line: pass it on stdin or over D-Bus. "
                         "Otherwise add it to ALLOWED with the reason.")

    def test_open_entries_still_match(self):
        used = set()
        for name in qml_files():
            used |= c1_violations(name, read(name))[1]
        stale = sorted(set(OPEN) - used)
        self.assertEqual(stale, [], "the instance these entries record is gone; delete them from OPEN")

    def test_allowlist_holds_no_instance_text(self):
        for (name, expr), why in ALLOWED.items():
            self.assertFalse(TEXT_WORDS.search(expr), "ALLOWED names instance text: %s %s" % (name, expr))
            self.assertTrue(why.strip(), "no reason for %s %s" % (name, expr))
        for key in OPEN:
            self.assertNotIn(key, ALLOWED, "an open instance must not also be allowed")

    def test_planted_cases_fail(self):
        cases = {
            "new verb carrying text": 'function f(t) { Quickshell.execDetached(["notify-send", t.title, t.body]) }',
            "execArgv of a title": 'function f(item) { Util.execArgv(["x", item.title]) }',
            "process command": 'Process { command: ["sh", "-c", row.detail] }',
            "command assignment": 'function f() { p.command = ["echo", reason] }',
            "argv push": 'function f(row) { var argv = ["a"]; argv.push(row.whyNow) }',
            "argv concat": 'function f(row) { var argv = ["a"]; argv = argv.concat(["--t", row.label]) }',
            "ternary branch": 'function f(r) { var argv = r ? ["a", r.title] : ["b"] }',
            "builder returns text": 'function noteArgv(item) { return ["omarchy-osd", item.title] }',
            "builder called with text": 'function f(row) { Util.execArgv(openArgv(row.title, false)) }',
            "a vector from an unknown function": 'function f(row) { Util.execArgv(titleCommand(row)) }',
            "the notification text": ('function n(item) { var argv = ["send", Model.notificationSummary(item.summary)] '
                                      'Util.execArgv(argv) }'),
        }
        for label, src in cases.items():
            bad, _ = c1_violations("planted.qml", src)
            self.assertTrue(bad, "planted case passed the scan: " + label)

    def test_literals_and_reviewed_elements_pass(self):
        allowed = {("p.qml", "script"): "path", ("p.qml", "id"): "an id"}
        src = 'function f() { Util.execArgv(["omarchy", "x", script].concat(["--id", id]).concat(["a"])) }'
        self.assertEqual(c1_violations("p.qml", src, allowed, {})[0], [])
        self.assertEqual(sorted(c1_violations("p.qml", src, {}, {})[0]), ["p.qml:1  id", "p.qml:1  script"])

    def test_comments_do_not_hide_or_add_elements(self):
        src = 'function f() {\n  var argv = ["a", // item.title\n    "b", /* t */ x]\n}'
        self.assertEqual(c1_violations("p.qml", src, {}, {})[0], ["p.qml:2  x"])


class C2NoClipboardRead(unittest.TestCase):
    def test_no_text_input_type_and_no_clipboard_path(self):
        bad = []
        for name in qml_files():
            bad += c2_violations(name, read(name))
        for name in tracked():
            if name.startswith(("bin/", "lib/", "dev/")) or name == "Model.js":
                bad += c2_violations(name, read(name), forbidden=[])
        self.assertGreater(len(qml_files()), 0)
        self.assertEqual(bad, [], "a type built on QQuickTextInput, or a clipboard read. "
                         "Qt reads the clipboard in a text input without a paste. A text field "
                         "is a plain-text TextEdit, as the Devices plugin's PanelField.")

    def test_no_omarchy_wrapper_over_a_text_input_is_used(self):
        wrappers = ui_wrappers_of_textinput()
        if not wrappers:
            self.skipTest("no Omarchy shell on this machine (%s)" % UI_DIR)
        for name in ("NumberField", "MultiSelect", "SearchableDropdown"):
            self.assertIn(name, wrappers, "the scan of %s no longer finds %s; update FORBIDDEN_TYPES" % (UI_DIR, name))
        missing = sorted(wrappers - set(FORBIDDEN_TYPES))
        used = []
        for name in qml_files():
            used += c2_violations(name, read(name), forbidden=missing)
        self.assertEqual(used, [], "a qs.Ui component built on a text input; add it to FORBIDDEN_TYPES: " + ", ".join(missing))

    def test_planted_cases_fail(self):
        cases = {
            "NumberField": "NumberField { }",
            "SearchableDropdown": "SearchableDropdown { model: [] }",
            "MultiSelect": "MultiSelect { }",
            "TextInput": "Item { TextInput { } }",
            "TextField": "TextField { }",
            "TextArea": "TextArea { }",
            "clipboardText": "function f() { return Quickshell.clipboardText }",
            "wl-paste": 'Process { command: ["wl-paste"] }',
            "cliphist": 'Process { command: ["cliphist", "list"] }',
        }
        for label, src in cases.items():
            self.assertTrue(c2_violations("planted.qml", src), "planted case passed the scan: " + label)

    def test_a_comment_or_a_longer_name_is_not_a_hit(self):
        src = "// TextField is forbidden\nNumberAnimation { }\nTextFormat: Text.PlainText"
        self.assertEqual(c2_violations("p.qml", src), [])


if __name__ == "__main__":
    unittest.main()
