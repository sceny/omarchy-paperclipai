"""Two class lints, written against the sink and not against the case that was reported.

    python3 -m unittest test/test_private_text.py

C1  Private text on a command line. `/proc/<pid>/cmdline` is readable by every
    local user, so nothing a person or an agent wrote (a title, a reason, a name)
    may be an element of an argv the QML starts. The scan finds every place QML
    builds an argv and every element that is not a string literal. Each such
    element must be on ALLOWED below, with the reason it is not private text. A
    new expression fails the build until a reviewer reads it and adds it.

    A function whose parameter is one of those allowed bare names is trusted at
    its use, so every call of it is read too: each value it is given is a
    literal, an expression allowed in the caller's file, or listed in ASSIGNED
    under (caller's file, parameter, expression).

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
    ("Service.qml", "notifyScript"): "plugin script path; the notification text goes to it on stdin",
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
}

# An allowlist entry that names one of these is text from the instance.
TEXT_WORDS = re.compile(r"\b(summary|body|title|detail|details|whyNow|label|text|name|description|message|reason)\b")

SINK_CALL = re.compile(r"(?<![\w.])(?:Util\.execArgv|Quickshell\.execDetached|execDetached)\s*\(|"
                       r"(?<![\w.])enqueue\s*\(|\.exec\s*\(")
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


def strip_shell_comments(src):
    """Remove shell comments: a `#` that begins a word, outside quotes, braces
    and heredocs, to the end of the line. A glob (`"$d"/*/`) or an expansion
    (`${host#*://}`, `$#`) is not a comment; quotes may span lines."""
    out, i, n = [], 0, len(src)
    heredocs, quote, brace = [], "", 0
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == "\\" and quote != "'" and i + 1 < n:
                out.append(src[i + 1]); i += 2; continue
            if c == quote:
                quote = ""
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(src[i:i + 2]); i += 2; continue
        if c in "\"'":
            quote = c
        elif src.startswith("${", i):
            brace += 1
            out.append("${"); i += 2; continue
        elif c == "}" and brace:
            brace -= 1
        elif c == "#" and not brace and (i == 0 or src[i - 1] in " \t\n;&|("):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        elif src.startswith("<<", i) and not src.startswith("<<<", i):
            m = re.match(r"<<-?\s*(['\"]?)(\w+)\1", src[i:])
            if m:
                heredocs.append((m.group(2), src[i + 2:i + 3] == "-"))
        if c == "\n" and heredocs:
            out.append(c); i += 1
            for word, tabs in heredocs:
                while i < n:
                    j = src.find("\n", i)
                    j = n if j < 0 else j
                    line = src[i:j]
                    out.append(src[i:j + 1]); i = j + 1
                    if (line.lstrip("\t") if tabs else line) == word:
                        break
            heredocs = []
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_python_comments(src):
    """Remove Python comments, with the tokenizer, so a `#` in a string stays."""
    import io
    import tokenize
    lines = src.split("\n")
    for tok in reversed(list(tokenize.generate_tokens(io.StringIO(src).readline))):
        if tok.type == tokenize.COMMENT:
            row, col = tok.start[0] - 1, tok.start[1]
            lines[row] = lines[row][:col] + " " * len(tok.string) + lines[row][col + len(tok.string):]
    return "\n".join(lines)


def strip_comments_of(name, src):
    """The file's own comment rules: QML and JavaScript, Python or shell."""
    if name.endswith((".qml", ".js")):
        return strip_comments(src)
    if re.match(r"#!.*python", src):
        return strip_python_comments(src)
    return strip_shell_comments(src)


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
            if arg.strip().startswith("{"):
                # the object form: its `command:` is a site of its own; any other key is not an argv
                continue
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


# ----------------------------------------------- an allowed bare name holds what it is given

# ALLOWED matches the text of an expression, so `verb` is allowed wherever a
# variable is called `verb`. Every value an allowed bare name is given in its
# file (`var X =`, `X =`, `property T X:`, `for (X of`, `X.push(`) is therefore
# read too: a literal, another allowed name, a function parameter (its call
# sites are read), or an expression listed here with the reason it is not
# text from the instance.  (file, name, expression) -> why.
ASSIGNED = {
    ("Service.qml", "statusScript", "pluginDir + \"/bin/omarchy-paperclip-status\""): "the plugin's own script, in its folder",
    ("Service.qml", "inboxScript", "pluginDir + \"/bin/omarchy-paperclip-inbox\""): "the plugin's own script, in its folder",
    ("Service.qml", "setupScript", "pluginDir + \"/bin/omarchy-paperclip-setup\""): "the plugin's own script, in its folder",
    ("Service.qml", "doctorScript", "pluginDir + \"/bin/omarchy-paperclip-doctor\""): "the plugin's own script, in its folder",
    ("Service.qml", "serviceScript", "pluginDir + \"/bin/omarchy-paperclip-service\""): "the plugin's own script, in its folder",
    ("Service.qml", "webappScript", "pluginDir + \"/bin/omarchy-paperclip-webapp\""): "the plugin's own script, in its folder",
    ("Service.qml", "openScript", "pluginDir + \"/bin/omarchy-paperclip-open\""): "the plugin's own script, in its folder",
    ("Service.qml", "snoozeScript", "pluginDir + \"/bin/omarchy-paperclip-snooze\""): "the plugin's own script, in its folder",
    ("Service.qml", "notifyScript", "pluginDir + \"/bin/omarchy-paperclip-notify\""): "the plugin's own script, in its folder",
    ("Service.qml", "instance", "String(setting(\"instance\", \"\"))"): "the user's own `instance` setting",
    ("Service.qml", "apiBase", "String(setting(\"apiBase\", \"\"))"): "the user's own `apiBase` setting",
    ("Service.qml", "inboxFilter", "Model.normalizeInboxFilter(setting(\"inboxFilter\", Model.INBOX_NEEDS_ME))"): "a plugin enum (needs-me / all), normalised by Model.normalizeInboxFilter",
    ("Service.qml", "clean", "String(value).replace(/[^A-Za-z0-9._-]/g, \"\")"): "setSetting() strips it to [A-Za-z0-9._-]",
    ("Service.qml", "company", "_retryCompanies[0]"): "a company id, taken from the rows' companyId (retryAll)",
    # What callers pass a function whose parameter is an allowed name.
    ("Panel.qml", "action", "action.id"): "a verb from Model.js: open, url, setup, doctor, start, webapp",
    ("Panel.qml", "action", "root.action.id"): "a verb from Model.js: open, url, setup, doctor, start, webapp",
    ("Panel.qml", "url", "row.url"): "a page path or url the server built, opened only on the instance's own origin",
    ("Panel.qml", "url", "rowItem.row.url"): "a page path or url the server built, opened only on the instance's own origin",
}

BARE = re.compile(r"[A-Za-z_]\w*")


def assignments(code, name):
    """(index, expression) for every value `name` is given in the file."""
    word = re.escape(name)
    found = []
    for m in re.finditer(r"(?<![\w.])(?:(?:var|let|const)\s+)?%s\s*=(?![=>])\s*" % word, code):
        found.append((m.start(), statement(code, m.end())))
    for m in re.finditer(r"\bproperty\s+[\w<>]+\s+%s\s*:\s*" % word, code):
        found.append((m.start(), statement(code, m.end())))
    for m in re.finditer(r"\bfor\s*\(\s*(?:var|let|const)?\s*%s\s+(?:in|of)\s+" % word, code):
        found.append((m.start(), code[m.end():closing(code, code.index("(", m.start()))]))
    for m in re.finditer(r"(?<![\w.])%s\.push\s*\(" % word, code):
        found.append((m.start(), code[m.end():closing(code, m.end() - 1)]))
    return found


def value_parts(expr):
    """What a value can be, through parentheses, ternaries, || && ??."""
    s = expr.strip()
    while s.startswith("(") and closing(s, 0) == len(s) - 1:
        s = s[1:-1].strip()
    qs = top_level(s, "?")
    if qs:
        rest = s[qs[0] + 1:]
        colons = top_level(rest, ":")
        if colons:
            return value_parts(rest[:colons[0]]) + value_parts(rest[colons[0] + 1:])
    for op in ("||", "&&", "??"):
        depth_ok = [i for i in range(len(s)) if s.startswith(op, i) and bracket_depth(s, i) == 0 and not in_string(s, i)]
        if depth_ok:
            out, last = [], 0
            for i in depth_ok:
                out += value_parts(s[last:i])
                last = i + len(op)
            return out + value_parts(s[last:])
    return [norm(s)]


def in_string(s, pos):
    i = 0
    while i < pos:
        if s[i] in "\"'`":
            j = skip_string(s, i)
            if j >= pos:
                return True
            i = j
        i += 1
    return False


def functions(code):
    """(start, end, name, parameters, keyword index) of every function, nested ones too."""
    out = []
    for m in re.finditer(r"\bfunction\b\s*(\w*)\s*\(", code):
        close = closing(code, m.end() - 1)
        params = [re.split(r"[\s:=]", p.strip(), maxsplit=1)[0] for p in split_top(code[m.end():close], ",") if p.strip()]
        body = code.find("{", close)
        out.append((body + 1, closing(code, body), m.group(1), params, m.start()))
    return out


def call_sites(name, sources):
    """(file, line, arguments) of every call of a function by its name."""
    out = []
    for fname, src in sources.items():
        code = strip_comments(src)
        for m in re.finditer(r"(?<!\w)(?:[\w.]+\.)?%s\s*\(" % re.escape(name), code):
            if code[:m.start()].rstrip().endswith("function"):
                continue
            end = closing(code, m.end() - 1)
            out.append((fname, code.count("\n", 0, m.start()) + 1, split_top(code[m.end():end], ",")))
    return out


def laundered(name, src, allowed=None, assigned=None, sources=None, used=None):
    """Values an allowed bare name is given that nobody has read."""
    allowed = ALLOWED if allowed is None else allowed
    assigned = ASSIGNED if assigned is None else assigned
    sources = {name: src} if sources is None else sources
    code = strip_comments(src)
    names = {e for (f, e) in allowed if f == name and BARE.fullmatch(e) and e != "argv"}
    funcs = functions(code)
    out = []

    def judge(var, where, part, line):
        if (name, var, part) in assigned:
            if used is not None:
                used.add((name, var, part))
            return
        if is_literal(part) or part in names:
            return
        inner = [f for f in funcs if f[0] <= where < f[1]]
        fn = min(inner, key=lambda f: f[1] - f[0]) if inner else None
        if fn and BARE.fullmatch(part) and part in fn[3]:
            if not fn[2]:
                out.append("%s:%d  %s is given the parameter %s of a function with no name" % (name, line, var, part))
                return
            at = fn[3].index(part)
            for cfile, cline, args in call_sites(fn[2], sources):
                if at >= len(args):
                    continue
                given = args[at].strip()
                elements = split_top(given[1:-1], ",") if given.startswith("[") and given.endswith("]") else [given]
                for arg in [part for element in elements if element.strip() for part in value_parts(element)]:
                    if (cfile, part, arg) in assigned and used is not None:
                        used.add((cfile, part, arg))
                    if not (is_literal(arg) or (cfile, part, arg) in assigned):
                        out.append("%s:%d  %s is given %s by %s(), which %s receives" % (cfile, cline, var, arg, fn[2], part))
            return
        out.append("%s:%d  %s is given %s" % (name, line, var, part))

    for var in sorted(names):
        for index, expr in assignments(code, var):
            for part in value_parts(expr):
                judge(var, index, part, code.count("\n", 0, index) + 1)
    return sorted(set(out))


def allowed_in(allowed, name):
    """Every expression allowed on some command line of a file."""
    return {e for (f, e) in allowed if f == name}


def parameters_given(name, src, allowed=None, assigned=None, sources=None, used=None):
    """A parameter that is an allowed bare name and reaches a command line is
    trusted at its use, so what every caller passes it is read: a literal, an
    expression allowed in the caller's file, or an expression in ASSIGNED under
    (caller's file, parameter, expression)."""
    allowed = ALLOWED if allowed is None else allowed
    assigned = ASSIGNED if assigned is None else assigned
    sources = {name: src} if sources is None else sources
    code = strip_comments(src)
    names = {e for (f, e) in allowed if f == name and BARE.fullmatch(e) and e != "argv"}
    lines = [(line, set(leaves(expr))) for line, expr in sites(src)]
    out = []
    for start, end, fname, params, at_keyword in functions(code):
        first, last = code.count("\n", 0, start) + 1, code.count("\n", 0, end) + 1
        for param in params:
            if param not in names or not any(first <= line <= last and param in leaf for line, leaf in lines):
                continue
            if not fname:
                source = re.search(r"([\w.]+)\.(?:forEach|map|filter|some|every)\(\s*$", code[:at_keyword])
                if source and (name, param, source.group(1)) in assigned:
                    if used is not None:
                        used.add((name, param, source.group(1)))
                elif source:
                    out.append("%s:%d  %s is given the items of %s" % (name, first, param, source.group(1)))
                else:
                    out.append("%s:%d  %s is a parameter of a function with no name and reaches a command line" % (name, first, param))
                continue
            at = params.index(param)
            for cfile, cline, args in call_sites(fname, sources):
                if at >= len(args):
                    continue
                given = args[at].strip()
                elements = split_top(given[1:-1], ",") if given.startswith("[") and given.endswith("]") else [given]
                for arg in [part for element in elements if element.strip() for part in value_parts(element)]:
                    if (cfile, param, arg) in assigned:
                        if used is not None:
                            used.add((cfile, param, arg))
                        continue
                    if is_literal(arg) or arg in allowed_in(allowed, cfile):
                        continue
                    out.append("%s:%d  %s() is given %s for %s, which reaches a command line" % (cfile, cline, fname, arg, param))
    return sorted(set(out))


def c2_violations(name, src, forbidden=None):
    code = strip_comments_of(name, src)
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

    def test_exec_on_any_receiver_is_a_sink(self):
        for label, src in {
            "array form": 'function f(n) { someProc.exec(["x", n.title]) }',
            "object form": 'function f(n) { someProc.exec({ command: ["x", n.title] }) }',
            "Quickshell.exec": 'function f(n) { Quickshell.exec(["x", n.title]) }',
            "a variable": 'function f(n) { var v = n.title; proc.exec([v]) }',
        }.items():
            self.assertTrue(c1_violations("planted.qml", src, {}, {})[0], label)
        self.assertEqual(c1_violations("planted.qml", 'function f() { someProc.exec(["x", "y"]) }', {}, {})[0], [])

    def test_an_allowed_name_is_given_only_what_was_read(self):
        sources = {n: read(n) for n in qml_files()}
        bad = [v for n in sources for v in laundered(n, sources[n], sources=sources)]
        self.assertEqual(bad, [], "an allowed bare name is given a value nobody reviewed: add it to ASSIGNED "
                         "with the reason it is not text from the instance, or do not give it that value")

    def test_reviewed_assignments_are_still_used(self):
        sources = {n: read(n) for n in qml_files()}
        used = set()
        for n in sources:
            laundered(n, sources[n], sources=sources, used=used)
            parameters_given(n, sources[n], sources=sources, used=used)
        self.assertEqual(sorted(set(ASSIGNED) - used), [], "the assignment is gone; delete it from ASSIGNED")
        for key, why in ASSIGNED.items():
            self.assertTrue(why.strip(), "no reason for %s" % (key,))

    def test_an_allowed_name_that_is_given_text_fails(self):
        allowed = {("p.qml", n): "x y z" for n in ("verb", "url", "action", "args", "company", "clean", "instance", "id")}
        cases = {
            "verb": 'function f(item) { var verb = item.title; Util.execArgv(["x", verb]) }',
            "url": 'function f(item) { var url = item.title; Util.execArgv(["x", url]) }',
            "action": 'function f(item) { let action = item.reason; Util.execArgv(["x", action]) }',
            "args": 'function f(item) { args = item.body; Util.execArgv(["x", args]) }',
            "company": 'function f(item) { var company = item.name; Util.execArgv(["x", company]) }',
            "clean": 'function f(item) { const clean = item.label; Util.execArgv(["x", clean]) }',
            "instance": 'function f(item) { var instance = item.whyNow; Util.execArgv(["x", instance]) }',
            "a property binding": 'Item { property string verb: row.title }',
            "a loop": 'function f(rows) { for (var id of rows.titles) Util.execArgv(["x", id]) }',
            "a ternary": 'function f(row) { var verb = ok ? "open" : row.title }',
            "a parameter passed text": 'function f(x) { var verb = x; Util.execArgv(["x", verb]) }\nfunction g(row) { f(row.title) }',
        }
        for label, src in cases.items():
            self.assertTrue(laundered("p.qml", src, allowed, {}), "planted case passed the scan: " + label)
        fine = {
            "literals": 'function f() { var verb = ok ? "open" : "close"; Util.execArgv(["x", verb]) }',
            "another allowed name": 'function f() { var url = verb; Util.execArgv(["x", url]) }',
            "a parameter passed literals": 'function f(x) { var verb = x; Util.execArgv(["x", verb]) }\nfunction g() { f("open") }',
        }
        for label, src in fine.items():
            self.assertEqual(laundered("p.qml", src, allowed, {}), [], label)
        self.assertEqual(laundered("p.qml", cases["verb"], allowed, {("p.qml", "verb", "item.title"): "a made-up reviewed value"}), [])

    def test_a_parameter_that_is_an_allowed_name_is_given_only_what_was_read(self):
        sources = {n: read(n) for n in qml_files()}
        bad = [v for n in sources for v in parameters_given(n, sources[n], sources=sources)]
        self.assertEqual(bad, [], "a function whose parameter is an allowed name is given a value nobody reviewed: "
                         "add it to ASSIGNED with the reason it is not text from the instance, or do not pass it")
        allowed = {("p.qml", n): "x y z" for n in ("verb", "url", "args")}
        define = 'function f(url) { Util.execArgv(["x", url]) }\n'
        cases = {
            "a field of an item": define + "function g(item) { f(item.title) }",
            "an element of an array": 'function h(args) { Util.execArgv(["x"].concat(args)) }\nfunction g(item) { h(["a", item.body]) }',
            "items of a list": "function g(list) { list.forEach(function(url) { Util.execArgv([\"x\", url]) }) }",
            "a function with no name": "function g(item) { setTimeout(function(url) { Util.execArgv([\"x\", url]) }, 1) }",
        }
        for label, src in cases.items():
            self.assertTrue(parameters_given("p.qml", src, allowed, {}), label)
        fine = {
            "a literal": define + 'function g() { f("open") }',
            "an allowed name": define + "function g() { f(verb) }",
            "an array of literals and allowed names": 'function h(args) { Util.execArgv(["x"].concat(args)) }\nfunction g() { h(["a", verb]) }',
        }
        for label, src in fine.items():
            self.assertEqual(parameters_given("p.qml", src, allowed, {}), [], label)
        self.assertEqual(parameters_given("p.qml", cases["a field of an item"], allowed,
                                          {("p.qml", "url", "item.title"): "a made-up reviewed value"}), [])

    def test_a_planted_call_of_an_allowed_parameter_in_the_real_files_fails(self):
        sources = {n: read(n) for n in qml_files()}
        self.assertEqual(parameters_given("Service.qml", sources["Service.qml"], sources=sources), [])
        line = "function planted(item) { service.openUrl(item.title) }"
        sources["Panel.qml"] = sources["Panel.qml"] + "\n" + line
        found = parameters_given("Service.qml", sources["Service.qml"], sources=sources)
        self.assertTrue(any("openUrl() is given item.title" in v for v in found), found)

    def test_a_planted_case_in_the_real_service_fails(self):
        real = read("Service.qml")
        sources = {"Service.qml": real}
        self.assertEqual(c1_violations("Service.qml", real)[0], [])
        self.assertEqual(laundered("Service.qml", real, sources=sources), [])
        line = 'function demo(item) { someProc.exec(["x", item.title]) }'
        self.assertTrue(c1_violations("Service.qml", real + "\n" + line)[0], line)
        for line in ('function demo(item) { var verb = item.title; Util.execArgv(["x", verb]) }',
                     'function demo(item) { var url = item.title; Util.execArgv(["x", url]) }'):
            self.assertTrue(laundered("Service.qml", real + "\n" + line, sources=sources), line)

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

    def test_a_shell_glob_or_expansion_does_not_hide_the_rest_of_the_file(self):
        for label, head in {
            "a glob": 'for d in "$source_dir"/*/; do echo "$d"; done\n',
            "a prefix removal": 'host="${url#*://}"\n',
            "the argument count": 'if [ $# -gt 0 ]; then shift; fi\n',
            "a length": 'echo "${#list[@]}"\n',
            "an escaped hash": 'echo \\# not a comment; true\n',
            "a hash in quotes": "echo '# not a comment'\n",
            "a heredoc": "cat <<'EOF'\ndon't # stop\nEOF\n",
        }.items():
            for tool in ("cliphist list >/dev/null", "wl-paste"):
                src = "#!/bin/bash\n" + head + tool + "\n"
                self.assertTrue(c2_violations("planted.sh", src, forbidden=[]), "%s then %s passed the scan" % (label, tool))
        # a quote that spans lines: the `#` line is the string, the code after it is code
        src = '#!/bin/bash\necho "line one\n# still the string"; cliphist list\n'
        self.assertTrue(c2_violations("planted.sh", src, forbidden=[]))

    def test_shell_and_python_comments_are_not_hits(self):
        for name, src in {
            "planted.sh": "#!/bin/bash\n# wl-paste is forbidden\necho ok # cliphist\n(  # wl-paste\n)\n",
            "planted": "#!/usr/bin/env python3\n# wl-paste\nx = 1  # cliphist\ny = '#'\n",
        }.items():
            self.assertEqual(c2_violations(name, src, forbidden=[]), [], name)
        self.assertTrue(c2_violations("planted", "#!/usr/bin/env python3\nx = '#'; subprocess.run(['cliphist'])\n", forbidden=[]))
        self.assertTrue(c2_violations("planted", '#!/usr/bin/env python3\n"""doc # x"""; subprocess.run(["wl-paste"])\n', forbidden=[]))

    def test_a_planted_tool_at_the_end_of_each_real_script_fails(self):
        scripts = [n for n in tracked() if n.startswith(("bin/", "lib/", "dev/"))]
        self.assertGreater(len(scripts), 10)
        for name in scripts:
            src = read(name)
            self.assertEqual(c2_violations(name, src, forbidden=[]), [], name)
            tail = "\nsubprocess.run(['cliphist', 'list'])\n" if src.startswith("#!/usr/bin/env python") else "\ncliphist list >/dev/null\n"
            self.assertTrue(c2_violations(name, src + tail, forbidden=[]), name + " hides a planted cliphist")

    def test_a_comment_or_a_longer_name_is_not_a_hit(self):
        src = "// TextField is forbidden\nNumberAnimation { }\nTextFormat: Text.PlainText"
        self.assertEqual(c2_violations("p.qml", src), [])


if __name__ == "__main__":
    unittest.main()
