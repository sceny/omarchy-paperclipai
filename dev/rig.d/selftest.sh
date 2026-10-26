#!/bin/bash
# Self-test of the rig's lease, keeper, ps and reap. Sourced by dev/rig
# (`dev/rig selftest`). Needs no compositor, no Paperclip and no desktop, so it
# runs anywhere, CI included.
#
# It builds stand-in rigs: a session dir, a state file, a lease, a keeper and a
# few tagged `sleep` processes, one of them detached into its own session the
# way a daemon is. Then it ends owners the hard ways and checks the rig is gone.
# Everything happens under a private registry and a private runtime dir; the
# real registry and the owner's runtime dir are never read or written.
#
# shellcheck shell=bash

st_pass=0
st_fail=0

st_check() {
  # st_check <name> <command...>
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    rig_ok "$name"
    st_pass=$((st_pass + 1))
  else
    rig_fail "$name"
    st_fail=$((st_fail + 1))
  fi
}

st_wait() {
  # st_wait <seconds> <command...> — until the command succeeds.
  local deadline=$((SECONDS + $1))
  shift
  while ((SECONDS < deadline)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

st_fake_rig() {
  # st_fake_rig <owner pid|none> <ttl> — prints the rig id. Two tagged
  # sleeps: one plain child, one in a session of its own.
  (
    session=$(rig_new_session_dir)
    rig_define_paths "$session"
    RIG_VIEW=hidden RIG_HTTP_PORT=0 RIG_PG_PORT=0 RIG_TTL=$2 RIG_OWNER_DESC=selftest
    rig_create_sandbox
    rig_state_set plugin_id "$RIG_PLUGIN_ID"
    rig_state_set view hidden
    rig_lease_init "$1" "$2"
    export OPR_RIG_ID=$RIG_ID
    rig_keeper_start >/dev/null 2>&1
    # Their stdout must not be the $(...) pipe, or the caller waits for them.
    sleep 600 >/dev/null 2>&1 &
    setsid sleep 600 >/dev/null 2>&1 &
    printf '%s\n' "$RIG_ID"
  )
}

st_expr() { eval "$1"; }
st_none_of() { st_wait 5 st_no_tagged "$1"; }
st_no_tagged() { [[ -z $(rig_tagged_pids "$1") ]]; }
st_some_of() { [[ -n $(rig_tagged_pids "$1") ]]; }
st_gone() { [[ ! -e $RIG_TMP_ROOT/$1 && ! -e $RIG_RUNTIME_ROOT/opr.${1##*.} ]]; }
st_listed() { cmd_ps | grep -q "$1"; }
st_lease() { [[ $(rig_lease_state "$RIG_TMP_ROOT/$1") == "$2" ]]; }
st_nested_teardown() {
  # st_nested_teardown <rig id> — a teardown started while this process holds the lock returns at once.
  (
    RIG_SELECT=$1
    rig_select && rig_lock 5 || exit 1
    local t=$SECONDS
    rig_teardown >/dev/null 2>&1 && exit 1
    ((SECONDS - t < 5))
  )
}
st_unlock_keeps_stderr() {
  # The unlock must leave the shell's stderr as it was: teardown reports there.
  local out
  out=$( (RIG_LOCK_FILE=$RIG_TMP_ROOT/unlock-probe.lock; rig_lock 5 && rig_unlock; echo kept >&2) 2>&1 )
  [[ $out == *kept* ]]
}
st_state_busy() {
  # A state file another process holds is given up on, not waited for forever.
  (
    RIG_SELECT=$1
    rig_select || exit 1
    exec 8>"$RIG_SESSION/.state.lock"
    flock -x 8
    local t=$SECONDS
    rig_state_set probe busy >/dev/null 2>&1 && exit 1
    ((SECONDS - t < 40))
  )
}

st_instance_start() {
  # st_instance_start <scratch> <health secs> <fake instance script> — the real
  # rig_pc_start against a stand-in instance, in a session of its own. Prints
  # the session dir; the exit status is rig_pc_start's.
  local scratch=$1 secs=$2 fake=$3 port
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  (
    rig_define_paths "$scratch/session.$RANDOM"
    mkdir -p "$RIG_LOGS" "$RIG_EVIDENCE" "$(rig_pc_instance_dir)/logs"
    printf '%s\n' "$RIG_SESSION" >"$scratch/last-session"
    RIG_HTTP_PORT=$port RIG_PG_PORT=1 RIG_INSTANCE_ID=rig
    RIG_PAPERCLIP_CLI=$fake RIG_PC_HEALTH_SECS=$secs
    rig_pc_start >/dev/null 2>&1
  )
}
st_fake_instance() {
  # st_fake_instance <path> <behaviour> — a script that stands in for `paperclipai run`.
  cat >"$1" <<FAKE
#!/bin/bash
echo "fake instance: $2"
case "$2" in
silent) exec sleep 30 ;;
exits) exit 3 ;;
late) exec timeout 40 python3 - <<'PY'
import http.server, os, time
time.sleep(4)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"status":"ok"}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY
;;
esac
FAKE
  chmod +x "$1"
}
st_evidence_has() { grep -q -- "$2" "$(<"$1/last-session")/evidence/$3"; }
st_instance_cases() {
  local scratch=$1
  st_fake_instance "$scratch/silent" silent
  st_fake_instance "$scratch/exits" exits
  st_fake_instance "$scratch/late" late

  rig_say "An instance that never answers health leaves its evidence"
  st_check "a silent instance fails the start" st_expr '! st_instance_start "$scratch" 4 "$scratch/silent"'
  st_check "the timing file says when the start was sent" st_evidence_has "$scratch" 'start sent' instance-timing.log
  st_check "the timing file says why it failed" st_evidence_has "$scratch" 'failed: no health after 4s' instance-timing.log
  st_check "the instance log is kept" st_evidence_has "$scratch" 'fake instance: silent' instance-start-failed/instance.log
  st_check "the machine's load and pressure are kept" st_evidence_has "$scratch" 'loadavg' instance-start-failed/machine.txt

  rig_say "An instance that exits is told apart from one that is slow"
  st_check "an exiting instance fails the start" st_expr '! st_instance_start "$scratch" 20 "$scratch/exits"'
  st_check "the timing file says it exited" st_evidence_has "$scratch" 'failed: the instance exited' instance-timing.log

  rig_say "A slow start that ends healthy is timed, not failed"
  st_check "a late instance starts" st_instance_start "$scratch" 30 "$scratch/late"
  st_check "its first health answer is in the timing file" st_evidence_has "$scratch" 'first health answer' instance-timing.log
  st_check "no failure evidence for it" st_expr '[[ ! -e $(<"$scratch/last-session")/evidence/instance-start-failed ]]'
}

cmd_selftest() {
  local scratch
  scratch=$(mktemp -d "${PAPERCLIP_SCRATCH_DIR:-${TMPDIR:-/tmp}}/rig-selftest.XXXXXX")
  chmod 700 "$scratch"
  RIG_TMP_ROOT="$scratch/registry"
  RIG_RUNTIME_ROOT="$scratch/run"
  mkdir -p -m 700 "$RIG_RUNTIME_ROOT"
  rig_ensure_root
  RIG_KEEPER_INTERVAL=1
  export RIG_TMP_ROOT RIG_RUNTIME_ROOT RIG_KEEPER_INTERVAL

  local owner_a owner_b owner_c a b c d
  rig_say "Selftest: lease, keeper, ps and reap (private registry $RIG_TMP_ROOT)"

  sleep 600 &
  owner_a=$!
  sleep 600 &
  owner_b=$!

  a=$(st_fake_rig "$owner_a" 600)
  b=$(st_fake_rig "$owner_b" 600)
  st_check "two rigs get different ids and runtime dirs" \
    st_expr '[[ $a != "$b" && ${a##*.} != "${b##*.}" ]]'
  st_check "rig A has tagged processes" st_some_of "$a"
  st_check "rig B has tagged processes" st_some_of "$b"
  st_check "the two rigs' process sets do not overlap" \
    st_expr '! comm -12 <(rig_tagged_pids "$a" | sort) <(rig_tagged_pids "$b" | sort) | grep -q .'
  st_check "ps shows rig A" st_listed "$a"
  st_check "ps shows rig B" st_listed "$b"
  st_check "rig A lease is live" st_lease "$a" live
  st_check "reap leaves live rigs alone" \
    st_expr 'cmd_reap >/dev/null 2>&1; [[ -d $RIG_TMP_ROOT/$a && -d $RIG_TMP_ROOT/$b ]]'

  rig_say "Owner of A is killed with SIGKILL"
  kill -9 "$owner_a"
  wait "$owner_a" 2>/dev/null || true
  st_check "the keeper tears rig A down on its own" st_wait 20 st_gone "$a"
  st_check "no process of rig A is left (plain or detached)" st_none_of "$a"
  st_check "rig B is untouched" st_expr '[[ -d $RIG_TMP_ROOT/$b ]]'
  st_check "rig B processes still run" st_some_of "$b"
  st_check "ps no longer lists rig A" st_expr '! cmd_ps | grep -q "$a"'

  rig_say "TTL runs out"
  owner_c=$owner_b
  c=$(st_fake_rig "$owner_c" 3)
  st_check "a 3 second TTL is reaped by the keeper" st_wait 20 st_gone "$c"
  st_check "its processes are gone too" st_none_of "$c"

  rig_say "Keeper and owner both die (a reboot, an OOM kill)"
  sleep 600 &
  owner_a=$!
  d=$(st_fake_rig "$owner_a" 600)
  kill -9 "$(<"$RIG_TMP_ROOT/$d/keeper.pid")"
  kill -9 "$owner_a"
  wait "$owner_a" 2>/dev/null || true
  st_check "ps calls the rig orphaned" st_wait 5 st_expr 'cmd_ps | grep -q orphaned'
  st_check "reap runs" st_expr 'cmd_reap >/dev/null 2>&1'
  st_check "its directories are gone" st_gone "$d"
  st_check "its processes are gone" st_none_of "$d"

  rig_say "A tagged process whose rig directory is gone"
  (
    export OPR_RIG_ID=leaked.20000101-000000.abcdef
    setsid sleep 600 &
  )
  st_check "ps reports it as leaked" st_wait 5 st_expr 'cmd_ps | grep -q "leaked processes"'
  st_check "verify-clean fails while it exists" st_expr '! cmd_verify_clean'
  st_check "reap ends it" \
    st_expr 'cmd_reap >/dev/null 2>&1; [[ -z $(rig_tagged_pids leaked.20000101-000000.abcdef) ]]'

  rig_say "Teardown never waits on itself"
  e=$(st_fake_rig none 600)
  st_check "a teardown inside a running teardown returns at once" st_nested_teardown "$e"
  st_check "an unlock leaves the shell's stderr alone" st_unlock_keeps_stderr
  st_check "a state file held by another process is given up on" st_state_busy "$e"
  (
    RIG_SELECT=$e
    rig_select && rig_teardown >/dev/null 2>&1
  )
  st_check "rig E is gone after teardown" st_gone "$e"
  st_check "rig E's processes are gone" st_none_of "$e"

  rig_say "Down of a live rig leaves nothing"
  (
    RIG_SELECT=$b
    rig_select && rig_teardown >/dev/null 2>&1
  )
  st_check "rig B is gone after teardown" st_gone "$b"
  st_check "rig B's processes are gone" st_none_of "$b"
  st_check "verify-clean passes with no rigs" cmd_verify_clean

  st_instance_cases "$scratch"

  # The stand-in owners and anything else this test started.
  kill "$owner_a" "$owner_b" 2>/dev/null || true
  cmd_reap --all >/dev/null 2>&1
  rm -rf "$scratch"
  st_check "the test registry is removed" st_expr '[[ ! -e $scratch ]]'

  if ((st_fail)); then
    rig_fail "selftest: $st_pass passed, $st_fail failed"
    return 1
  fi
  rig_ok "selftest: $st_pass passed, 0 failed"
}
