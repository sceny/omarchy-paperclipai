#!/bin/bash
# Every check that needs no desktop. This is the build: the command exits
# non-zero if any of them does.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

failed=0
run() {
  printf '== %s\n' "$*"
  "$@" || { printf '!! FAILED: %s\n' "$*" >&2; failed=1; }
}

run node test/test_model.mjs
run node test/test_inbox.mjs
run node test/test_open.mjs
run node test/test_transport.mjs
run node test/test_doctor_session.mjs
run python3 -m unittest test/test_transport.py test/test_security_rules.py test/test_private_text.py test/test_state.py
run bash test/test_follow_develop.sh

exit "$failed"
