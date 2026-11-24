#!/usr/bin/env python3
"""dev/loaded-code against a fake `qs ipc show`: no shell, no desktop."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "dev" / "loaded-code"

SHOW_MATCH = """target paperclip
  function open(): void
  function status(): string
"""

QML = """import QtQuick
Item {{
  IpcHandler {{
    target: "paperclip"
    function open(): void {{ }}
{extra}  }}
}}
"""


def run(plugin_dir, show, *extra_args):
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(show)
    env = dict(os.environ, LOADED_CODE_SHOW_CMD=f"cat {handle.name}")
    done = subprocess.run([sys.executable, str(SCRIPT), str(plugin_dir), *extra_args],
                          capture_output=True, text=True, env=env, timeout=30)
    os.unlink(handle.name)
    return done


def main():
    failures = 0

    def check(name, ok, detail=""):
        nonlocal failures
        print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
        failures += 0 if ok else 1

    with tempfile.TemporaryDirectory() as tmp:
        plugin = Path(tmp)
        (plugin / "Panel.qml").write_text(QML.format(
            extra="    function status(): string { return \"\" }\n"))

        done = run(plugin, SHOW_MATCH)
        check("matching shell exits 0", done.returncode == 0, done.stdout + done.stderr)

        (plugin / "Panel.qml").write_text(QML.format(
            extra="    function status(): string { return \"\" }\n"
                  "    function board(): string { return \"ok\" }\n"))
        done = run(plugin, SHOW_MATCH)
        check("a function added to the files exits 1", done.returncode == 1,
              done.stdout + done.stderr)
        check("the added function is named", "board" in done.stdout, done.stdout)

        done = run(plugin, "target other\n  function open(): void\n")
        check("a shell without the target exits 2", done.returncode == 2,
              done.stdout + done.stderr)

        done = run(plugin, SHOW_MATCH, "--target", "other")
        check("--target names the target to read", done.returncode == 2,
              done.stdout + done.stderr)

    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
