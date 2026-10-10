#!/bin/bash
# Sandbox, guards, compositor and teardown for the Omarchy plugin test rig.
# Sourced by dev/rig, never run directly.
#
# The one invariant this file exists to hold: nothing the rig starts can see
# the owner's session, the owner's config, or the owner's Paperclip instance.
# Everything else here is bookkeeping in service of that.
#
# shellcheck shell=bash

# ----------------------------------------------------------------- output ----

rig_say() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
rig_step() { printf '\033[36m  ·\033[0m %s\n' "$*" >&2; }
rig_ok() { printf '\033[32m  ✓\033[0m %s\n' "$*" >&2; }
rig_warn() { printf '\033[33m  !\033[0m %s\n' "$*" >&2; }
rig_fail() { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; }
rig_die() {
  rig_fail "$*"
  exit 1
}

# ------------------------------------------------------------ host facts ----
#
# Captured once, before the sandbox exists, so every guard below can compare
# against the real thing instead of against whatever the environment became.

RIG_HOST_HOME=$HOME
RIG_HOST_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
RIG_HOST_WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
RIG_HOST_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
RIG_HOST_HYPR_SIG=${HYPRLAND_INSTANCE_SIGNATURE:-}

# The owner's live Paperclip instance. Off limits as a test target, and named
# here only so the guards can refuse to point at it.
RIG_HOST_PAPERCLIP_DIR="$RIG_HOST_HOME/.paperclip"
RIG_FORBIDDEN_PORTS=(3100 3101 54329)

# Read-only Omarchy install the nested shell runs from. The rig never writes
# inside it.
RIG_OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

# ------------------------------------------------------------- locations ----

# A fixed root, deliberately NOT $TMPDIR: an agent run gets a private TMPDIR, and
# a registry that moves with it would hide one run's rig from `dev/rig ps` and
# `dev/rig reap` in every other run.
RIG_TMP_ROOT=${RIG_TMP_ROOT:-/tmp/omarchy-plugin-rig-$(id -u)}

# Where the rigs' private XDG_RUNTIME_DIRs go. Short on purpose (see
# rig_define_paths) and never the owner's /run/user/<uid>.
RIG_RUNTIME_ROOT=${RIG_RUNTIME_ROOT:-/tmp}

rig_new_session_dir() {
  # <plugin>.<utc stamp>.<6 hex>. The last part names the runtime dir too, so
  # two rigs started in the same second still get different everything.
  local stamp tag dir
  stamp=$(date -u +%Y%m%d-%H%M%S)
  while :; do
    tag=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    dir="$RIG_TMP_ROOT/$RIG_PLUGIN_ID.$stamp.$tag"
    [[ -e $dir || -e "$RIG_RUNTIME_ROOT/opr.$tag" ]] || break
  done
  printf '%s\n' "$dir"
}

# --------------------------------------------------------------- sandbox ----

rig_define_paths() {
  # Every path the rig owns, derived from one session dir.
  RIG_SESSION=$1
  RIG_ID=${RIG_SESSION##*/}
  RIG_HOME="$RIG_SESSION/home"
  RIG_LOGS="$RIG_SESSION/logs"
  RIG_EVIDENCE="$RIG_SESSION/evidence"
  RIG_STUB_BIN="$RIG_SESSION/stub-bin"
  RIG_PKG_REPO="$RIG_SESSION/package.git"
  RIG_STATE_FILE="$RIG_SESSION/rig.state"
  RIG_HYPR_CONF="$RIG_SESSION/hyprland.conf"
  RIG_PLUGINS_DIR="$RIG_HOME/.config/omarchy/plugins"
  RIG_PAPERCLIP_DATA="$RIG_HOME/.paperclip"

  # Wayland and Hyprland sockets live in a sun_path-sized world — 108 bytes,
  # total. Hyprland's own instance directory eats 63 of them before the socket
  # name, so the rig runtime dir gets a deliberately ugly short name directly
  # under RIG_RUNTIME_ROOT, not a descriptive one under the long session dir.
  # It is never inside the owner's /run/user/<uid>: that is the owner's session.
  # `opr` is this rig.
  RIG_RUNTIME_DIR="$RIG_RUNTIME_ROOT/opr.${RIG_SESSION##*.}"
  RIG_LOCK_FILE="$RIG_TMP_ROOT/$RIG_ID.lock"
}

rig_guard_socket_path() {
  # Fail here with an explanation rather than inside Hyprland with
  # "Socket2 path is too long. IPC will not work." and no IPC.
  local worst=$((${#RIG_RUNTIME_DIR} + ${#RIG_HYPR_SOCKET_BUDGET}))
  ((worst <= 107)) || rig_die \
    "guard: $RIG_RUNTIME_DIR leaves no room for a Hyprland IPC socket ($worst > 107 bytes). Set RIG_TMP_ROOT and XDG_RUNTIME_DIR somewhere shorter."
}

# "/hypr/" + a 40-char commit sha + "_" + a 10-digit stamp + "_" + a 9-digit
# nonce + "/.socket2.sock". Measured, not guessed.
RIG_HYPR_SOCKET_BUDGET="/hypr/0000000000000000000000000000000000000000_0000000000_000000000/.socket2.sock"

rig_create_sandbox() {
  mkdir -p "$RIG_HOME" "$RIG_LOGS" "$RIG_EVIDENCE" "$RIG_STUB_BIN" \
    "$RIG_HOME/.config/omarchy" "$RIG_PLUGINS_DIR" \
    "$RIG_HOME/.local/share" "$RIG_HOME/.local/state" "$RIG_HOME/.cache"
  # No -p and no reuse: a runtime dir that already exists is somebody else's
  # (or a leak), and sharing it would share their sockets.
  [[ ! -e $RIG_RUNTIME_DIR ]] ||
    rig_die "guard: $RIG_RUNTIME_DIR already exists; run 'dev/rig reap' or 'dev/rig verify-clean'"
  install -d -m 700 "$RIG_RUNTIME_DIR" ||
    rig_die "could not create the private runtime dir $RIG_RUNTIME_DIR"
  chmod 700 "$RIG_SESSION"
}

# First-party shell services that have no business running in a test rig. The
# idle service locks the session after five minutes; the lock screen then dies
# in a nested compositor ("lockscreen app died") and the window stays locked
# until `dev/rig down`. Both are switched off through shell.json's
# disabledPlugins, the same record `omarchy plugin disable` writes.
RIG_SHELL_DISABLED_PLUGINS=(omarchy.idle omarchy.lock)

rig_seed_omarchy_config() {
  # A fresh home has no Omarchy config at all, which is the point: cold-start
  # truth. The shell needs shell.json to exist, so seed it from the shipped
  # defaults — the same file a brand new Omarchy user starts from — plus the
  # disabled services above, and nothing else.
  local defaults="$RIG_OMARCHY_PATH/config/omarchy/shell.json"
  local target="$RIG_HOME/.config/omarchy/shell.json" disabled
  if [[ ! -r $defaults ]]; then
    defaults="$RIG_SESSION/.shell-fallback.json"
    printf '%s\n' '{"version":1,"bar":{"layout":{"left":[],"center":[],"right":[]}},"plugins":[]}' >"$defaults"
  fi
  disabled=$(printf '%s\n' "${RIG_SHELL_DISABLED_PLUGINS[@]}" | jq -R . | jq -sc .)
  jq --argjson off "$disabled" '.disabledPlugins = (((.disabledPlugins // []) + $off) | unique)' \
    "$defaults" >"$target.tmp" || rig_die "could not seed $target"
  install -m 600 "$target.tmp" "$target"
  rm -f "$target.tmp" "$RIG_SESSION/.shell-fallback.json"
}

rig_write_stubs() {
  # The scripts under test end in "open a browser" or "open a terminal". A rig
  # has neither, and a check that spawns Brave proves nothing about the plugin.
  # These stubs record the arguments instead, so a check can assert the URL the
  # plugin computed. They are recording stubs, not fakes that always succeed:
  # the real browser launch is Panel QA's step, and the README says so.
  local name
  for name in omarchy-launch-webapp omarchy-launch-browser xdg-open; do
    cat >"$RIG_STUB_BIN/$name" <<STUB
#!/bin/bash
printf '%s %s\n' "\${0##*/}" "\$*" >>"\$RIG_STUB_LOG"
exit 0
STUB
    chmod +x "$RIG_STUB_BIN/$name"
  done

  # A terminal spawn would detach a process the rig cannot reap.
  for name in omarchy-launch-terminal xdg-terminal-exec; do
    cat >"$RIG_STUB_BIN/$name" <<STUB
#!/bin/bash
printf '%s %s\n' "\${0##*/}" "\$*" >>"\$RIG_STUB_LOG"
exit 0
STUB
    chmod +x "$RIG_STUB_BIN/$name"
  done
}

rig_export_env() {
  # The sandbox. Exported into every command the rig runs, and nothing else.
  export HOME="$RIG_HOME"
  export XDG_CONFIG_HOME="$RIG_HOME/.config"
  export XDG_DATA_HOME="$RIG_HOME/.local/share"
  export XDG_STATE_HOME="$RIG_HOME/.local/state"
  export XDG_CACHE_HOME="$RIG_HOME/.cache"
  export XDG_RUNTIME_DIR="$RIG_RUNTIME_DIR"
  export OMARCHY_PATH="$RIG_OMARCHY_PATH"

  # The tag every process of this rig carries in its environment. Children
  # inherit it, daemons included, so `ps`, `reap` and teardown can find the
  # whole tree by what it is instead of by what it is called or who forked it.
  export OPR_RIG_ID="$RIG_ID"

  # No core dumps from anything the rig starts. A throwaway compositor that
  # fails must leave a log line, not a core file and a crash notice on the
  # owner's desktop. Limits are inherited, so this covers every child.
  rig_no_cores

  # No seat for the nested compositor, ever. Without this, Hyprland's DRM
  # backend asks logind to hand it the owner's session ("Could not take control
  # of session: Device or resource busy" in its log is that request being
  # refused because the owner's Hyprland holds it). Pointing libseat at a
  # socket that does not exist turns the attempt into a clean "no seat", and
  # the compositor falls through to its Wayland parent.
  export LIBSEAT_BACKEND=seatd
  export SEATD_SOCK="$RIG_RUNTIME_DIR/.no-seat"

  # BASH_ENV is sourced by every non-interactive bash, and the file it names is
  # free to rewrite PATH. A CI runner or an agent harness that sets it would
  # silently put the host's tools back in front of the rig's recording stubs,
  # which is how a check ends up launching a real browser while reporting that
  # it did not. The rig decides its own PATH, so BASH_ENV goes.
  unset BASH_ENV ENV
  export PATH="$RIG_STUB_BIN:$PATH"
  export RIG_STUB_LOG="$RIG_LOGS/stub-calls.log"
  : >"$RIG_STUB_LOG"

  # No session bus means `systemctl --user` cannot reach the owner's units.
  # That is deliberate: the plugin must never be able to start, stop or
  # install paperclipai.service while under test.
  unset DBUS_SESSION_BUS_ADDRESS
  unset DBUS_SYSTEM_BUS_ADDRESS
  unset XDG_SESSION_ID XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_VTNR
  unset NOTIFY_SOCKET

  # The display, and only the rig's. Every tool that reaches a compositor —
  # `omarchy plugin enable` through `qs ipc`, `hyprctl`, `grim` — picks its
  # target out of these two variables, so inheriting the owner's values would
  # quietly aim the whole suite at the owner's bar. Before the rig's own
  # compositor exists there is no display at all, which is also correct.
  local nested signature
  nested=$(rig_state_get nested_display) || nested=""
  signature=$(rig_state_get hypr_signature) || signature=""
  if [[ -n $nested ]]; then
    export WAYLAND_DISPLAY="$nested"
  else
    unset WAYLAND_DISPLAY
  fi
  if [[ -n $signature ]]; then
    export HYPRLAND_INSTANCE_SIGNATURE="$signature"
  else
    unset HYPRLAND_INSTANCE_SIGNATURE
  fi

  # The plugin reads these. Point them at the throwaway instance.
  export PAPERCLIP_OMARCHY_INSTANCE="$RIG_INSTANCE_ID"
  export PAPERCLIP_OMARCHY_API_BASE="http://127.0.0.1:$RIG_HTTP_PORT"
  export PAPERCLIP_PLUGIN_ID="$RIG_PLUGIN_ID"

  # Quickshell must not hot-reload the shell out from under a check.
  export QS_DISABLE_FILE_WATCHER=1
  export QS_NO_RELOAD_POPUP=1
}

# ---------------------------------------------------------------- guards ----
#
# Blast radius first. Each of these answers "what can this run damage?" with
# "nothing of the owner's", and exits if it cannot.

# ----------------------------------------------------------------- cores ----
#
# `ulimit -c 0` is not enough on a host whose core_pattern pipes into
# systemd-coredump: the kernel ignores a limit of 0 for pipes, still runs the
# handler, and the abort lands in `coredumpctl` and the crash notice. A limit of
# exactly 1 byte is the value the kernel refuses to pipe, so nothing is recorded
# at all. bash cannot say "1 byte" (ulimit -c counts 1 KiB blocks); prlimit can.

rig_core_limits() {
  # Prints "<soft> <hard>" in bytes, or "unlimited unlimited".
  prlimit --pid $$ --core --noheadings --raw --output SOFT,HARD 2>/dev/null
}

rig_no_cores() {
  command -v prlimit >/dev/null 2>&1 ||
    rig_die "prlimit (util-linux) is needed to switch core dumps off; refusing to start compositors"
  prlimit --pid $$ --core=1:1 2>/dev/null && return 0
  local soft hard
  read -r soft hard < <(rig_core_limits)
  if [[ $soft == 0 ]]; then
    # The caller already ran `ulimit -c 0`, which lowered the hard limit and
    # cannot be raised again. No core file is stored, but systemd-coredump
    # still logs the event.
    rig_warn "core limit is already 0 (hard); no core file will be stored, but an abort is still logged by systemd-coredump. Start the rig from a shell without 'ulimit -c 0' for a fully silent run."
    return 0
  fi
  rig_die "cannot lower the core limit (soft=$soft hard=$hard); refusing to start compositors"
}

rig_hyprland_version() {
  # Never `Hyprland --version`: it initialises the compositor and aborts when
  # its environment is wrong.
  pacman -Q hyprland 2>/dev/null || echo "hyprland (version unknown: pacman -Q failed)"
}

rig_guard_sandbox() {
  [[ -n ${RIG_HOME:-} ]] || rig_die "guard: no sandbox home"
  [[ $RIG_HOME != "$RIG_HOST_HOME" ]] ||
    rig_die "guard: sandbox HOME is the owner's home"
  [[ $RIG_HOME == "$RIG_TMP_ROOT"/* ]] ||
    rig_die "guard: sandbox HOME ($RIG_HOME) is outside $RIG_TMP_ROOT"
  [[ $RIG_RUNTIME_DIR != "$RIG_HOST_RUNTIME_DIR" && $RIG_RUNTIME_DIR != "$RIG_HOST_RUNTIME_DIR"/* ]] ||
    rig_die "guard: rig runtime dir ($RIG_RUNTIME_DIR) is, or is inside, the owner's runtime dir"
  [[ $RIG_PLUGINS_DIR != "$RIG_HOST_CONFIG_HOME/omarchy/plugins" ]] ||
    rig_die "guard: rig would install into the owner's plugin directory"
  [[ $RIG_PAPERCLIP_DATA != "$RIG_HOST_PAPERCLIP_DIR" ]] ||
    rig_die "guard: rig would write to the owner's Paperclip data directory"
}

rig_guard_ports() {
  local port forbidden
  for port in "$RIG_HTTP_PORT" "$RIG_PG_PORT"; do
    for forbidden in "${RIG_FORBIDDEN_PORTS[@]}"; do
      ((port != forbidden)) ||
        rig_die "guard: port $port belongs to the owner's instance"
    done
  done
}

rig_guard_stubs() {
  # The recording stubs only work if they win PATH resolution, including inside
  # the sub-shells the checks spawn. Prove it rather than hope: a shadowed stub
  # turns "the plugin computed the right URL" into "a real browser started".
  local resolved
  resolved=$(bash -c 'command -v omarchy-launch-webapp' 2>/dev/null)
  [[ $resolved == "$RIG_STUB_BIN/"* ]] ||
    rig_die "guard: host tools shadow the rig stubs (omarchy-launch-webapp resolves to '$resolved')"
}

rig_guard_nested_display() {
  # grim, hyprctl and qs ipc all aim at WAYLAND_DISPLAY. If it still names the
  # owner's compositor, a screenshot would show the owner's desktop and an
  # enable would move the owner's bar — so refuse rather than produce evidence
  # about the wrong machine.
  [[ -n ${WAYLAND_DISPLAY:-} ]] ||
    rig_die "guard: no nested display; the rig compositor is not up"
  # Compare sockets, not names: every compositor's first socket is wayland-1
  # in its own runtime dir, so the names can match while the sockets differ.
  [[ $XDG_RUNTIME_DIR != "$RIG_HOST_RUNTIME_DIR" ]] ||
    rig_die "guard: the rig runtime dir is the owner's ($RIG_HOST_RUNTIME_DIR)"
  [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] ||
    rig_die "guard: $WAYLAND_DISPLAY is not a socket in the rig runtime dir"
}

rig_guard_nested_shell() {
  # The hard one. `omarchy plugin enable` is an IPC call into *a* running
  # Omarchy shell, and quickshell resolves the target by config path — which is
  # identical for the host shell and the nested one. The separate
  # XDG_RUNTIME_DIR is what keeps them apart; this proves it did, by checking
  # that the instance the IPC would reach is the process the rig started.
  local pid dir
  for dir in "$XDG_RUNTIME_DIR"/quickshell/by-pid/*; do
    [[ -e $dir ]] || continue
    pid=${dir##*/}
    [[ $pid == "$RIG_SHELL_PID" ]] && return 0
  done
  rig_die "guard: the only reachable Omarchy shell is not the rig's (pid $RIG_SHELL_PID)"
}

rig_guard_no_host_systemd() {
  # Prove the plugin cannot reach the owner's user units from in here.
  if systemctl --user show paperclipai.service --property=LoadState >/dev/null 2>&1; then
    rig_die "guard: systemctl --user still reaches the owner's session bus"
  fi
  return 0
}

# ----------------------------------------------------------------- ports ----

rig_free_port() {
  # rig_free_port <low> <high> — a port nothing is listening on.
  local low=$1 high=$2 attempt port
  for attempt in $(seq 1 200); do
    port=$((low + RANDOM % (high - low)))
    local skip=0 forbidden
    for forbidden in "${RIG_FORBIDDEN_PORTS[@]}" ${RIG_PORTS_TAKEN:-}; do
      ((port == forbidden)) && skip=1
    done
    ((skip)) && continue
    ss -ltnH "sport = :$port" 2>/dev/null | grep -q . || {
      printf '%s\n' "$port"
      return 0
    }
  done
  return 1
}

# ------------------------------------------------------------ state file ----

rig_state_set() {
  # rig_state_set KEY VALUE — locked, because the keeper and the command that
  # started it both write here.
  local key=$1 value=$2 tmp
  (
    flock 9
    tmp=$(mktemp "$RIG_SESSION/.state.XXXXXX")
    if [[ -f $RIG_STATE_FILE ]]; then
      grep -v "^$key=" "$RIG_STATE_FILE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv "$tmp" "$RIG_STATE_FILE"
  ) 9>"$RIG_SESSION/.state.lock"
}

rig_state_get() {
  rig_state_read "$RIG_STATE_FILE" "$1"
}

rig_state_read() {
  # rig_state_read <state-file> <key> — another rig's value, for ps and reap.
  [[ -f $1 ]] || return 1
  local line
  line=$(grep "^$2=" "$1" | tail -n1) || return 1
  printf '%s\n' "${line#*=}"
}

rig_load_state() {
  # Re-create the shell variables for an already-running rig.
  # rig_load_state <session-dir>
  local session=${1:-}
  [[ -d $session ]] || return 1
  rig_define_paths "$session"
  [[ -f $RIG_STATE_FILE ]] || return 1
  RIG_HTTP_PORT=$(rig_state_get http_port || echo "")
  RIG_PG_PORT=$(rig_state_get pg_port || echo "")
  RIG_INSTANCE_ID=$(rig_state_get instance_id || echo "$RIG_DEFAULT_INSTANCE_ID")
  RIG_VIEW=$(rig_state_get view || echo hidden)
  RIG_SHELL_PID=$(rig_state_get shell_pid || echo "")
  RIG_HYPR_PID=$(rig_state_get hypr_pid || echo "")
  RIG_PARENT_PID=$(rig_state_get parent_pid || echo "")
  RIG_INSTANCE_PID=$(rig_state_get instance_pid || echo "")
  RIG_NESTED_DISPLAY=$(rig_state_get nested_display || echo "")
  return 0
}

# -------------------------------------------------------------- teardown ----
#
# Written before the checks, and run by `down`, by a failed `up`, and on any
# signal. A rig that leaks is a defect.

rig_kill_tree() {
  # rig_kill_tree <pid> [signal] — the process and everything it started.
  local pid=$1 signal=${2:-TERM}
  [[ -n $pid ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    rig_kill_tree "$child" "$signal"
  done
  kill "-$signal" "$pid" 2>/dev/null || true
}

rig_wait_gone() {
  # rig_wait_gone <pid> <seconds>
  local pid=$1 deadline=$((SECONDS + ${2:-10}))
  [[ -n $pid ]] || return 0
  while ((SECONDS < deadline)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  return 1
}

rig_teardown() {
  # Order matters: the instance first (it owns a database that wants a clean
  # stop), then the display (shell, compositor, headless parent), then
  # whatever else carries the rig's tag, then the filesystem. One teardown of a
  # rig at a time: the keeper, `down` and `reap` can all arrive together.
  local keep_evidence=${1:-}

  rig_say "Tearing down"
  if ! rig_lock 120; then
    rig_warn "another teardown of $RIG_ID holds the lock and did not finish"
    return 1
  fi
  if [[ ! -d ${RIG_SESSION:-/nonexistent} ]]; then
    rig_unlock
    rig_ok "already gone"
    return 0
  fi

  if [[ -n ${RIG_INSTANCE_PID:-} ]]; then
    rig_step "stopping the throwaway Paperclip instance (pid $RIG_INSTANCE_PID)"
    rig_kill_tree "$RIG_INSTANCE_PID" TERM
    rig_wait_gone "$RIG_INSTANCE_PID" 25 || rig_kill_tree "$RIG_INSTANCE_PID" KILL
    rig_wait_gone "$RIG_INSTANCE_PID" 10 || rig_warn "instance pid $RIG_INSTANCE_PID will not die"
  fi

  # Embedded Postgres is started by the instance but survives it often enough
  # that the first rig I wrote leaked one. Match it by its own data directory,
  # which is inside the session, so this can never hit the owner's database.
  if [[ -n ${RIG_PAPERCLIP_DATA:-} ]]; then
    local pg
    for pg in $(pgrep -f -- "-D $RIG_PAPERCLIP_DATA" 2>/dev/null); do
      rig_step "stopping leftover embedded Postgres (pid $pg)"
      kill -TERM "$pg" 2>/dev/null || true
      rig_wait_gone "$pg" 15 || kill -KILL "$pg" 2>/dev/null || true
    done
  fi

  rig_stop_display

  # Everything else with the rig's tag, whoever started it, wherever it went.
  rig_sweep_tagged "$RIG_ID" || rig_warn "some processes of $RIG_ID will not die"

  if [[ -n $keep_evidence && -d ${RIG_EVIDENCE:-} ]]; then
    local out="$keep_evidence"
    mkdir -p "$out"
    cp -r "$RIG_EVIDENCE/." "$out/" 2>/dev/null || true
    cp -r "$RIG_LOGS" "$out/logs" 2>/dev/null || true
    cp "$RIG_RUNTIME_DIR"/hypr/*/hyprland.log "$out/logs/hyprland.log" 2>/dev/null || true
    rig_ok "evidence kept in $out"
  fi

  [[ -n ${RIG_RUNTIME_DIR:-} && $RIG_RUNTIME_DIR == "$RIG_RUNTIME_ROOT"/opr.* ]] &&
    rm -rf "$RIG_RUNTIME_DIR"
  [[ -n ${RIG_SESSION:-} && $RIG_SESSION == "$RIG_TMP_ROOT"/* ]] &&
    rm -rf "$RIG_SESSION"
  rig_unlock

  rig_ok "teardown done"
}

rig_verify_clean() {
  # Teardown is a feature, so it gets its own check instead of a claim.
  # Prints a report and returns non-zero on anything left behind.
  local problems=0 port pid

  rig_say "Verifying the rig left nothing behind"

  if [[ -e ${RIG_SESSION:-/nonexistent} ]]; then
    rig_fail "session dir still present: $RIG_SESSION"
    problems=$((problems + 1))
  else
    rig_ok "session dir gone: ${RIG_SESSION:-<none>}"
  fi

  if [[ -e ${RIG_RUNTIME_DIR:-/nonexistent} ]]; then
    rig_fail "runtime dir still present: $RIG_RUNTIME_DIR"
    problems=$((problems + 1))
  else
    rig_ok "runtime dir gone: ${RIG_RUNTIME_DIR:-<none>}"
  fi

  for port in ${RIG_HTTP_PORT:-} ${RIG_PG_PORT:-}; do
    [[ -n $port && $port != 0 ]] || continue
    if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
      rig_fail "port $port still listening"
      problems=$((problems + 1))
    else
      rig_ok "port $port free"
    fi
  done

  for pid in ${RIG_INSTANCE_PID:-} ${RIG_SHELL_PID:-} ${RIG_HYPR_PID:-} ${RIG_PARENT_PID:-}; do
    [[ -n $pid ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      rig_fail "pid $pid still alive"
      problems=$((problems + 1))
    else
      rig_ok "pid $pid gone"
    fi
  done

  local tagged
  tagged=$(rig_tagged_pids "${RIG_ID:-none}")
  if [[ -n $tagged ]]; then
    rig_fail "processes of the rig are still running:"
    for pid in $tagged; do ps -o pid=,comm=,args= -p "$pid" >&2; done
    problems=$((problems + 1))
  else
    rig_ok "no process carries the rig tag ${RIG_ID:-<none>}"
  fi

  if [[ -n ${RIG_SESSION:-} ]] && pgrep -f -- "$RIG_SESSION" 2>/dev/null | grep -qvx "$$"; then
    rig_fail "processes still reference the session tree:"
    pgrep -af -- "$RIG_SESSION" >&2
    problems=$((problems + 1))
  else
    rig_ok "no process references the session tree"
  fi

  # The rig never installs a unit; this proves it did not.
  if systemctl --user list-unit-files 2>/dev/null | grep -q 'omarchy-plugin-rig'; then
    rig_fail "a rig systemd unit survives"
    problems=$((problems + 1))
  else
    rig_ok "no rig systemd units"
  fi

  if ((problems)); then
    rig_fail "$problems leak(s)"
    return 1
  fi
  rig_ok "nothing left behind"
  return 0
}

# ---------------------------------------------------------- plugin paths ----

rig_build_package_repo() {
  # Package parity: a real user runs `omarchy plugin add <git-url>`, which
  # clones, validates, then moves the clone into place. So the rig installs
  # from a git repo too — a local one built out of the checkout, so the same
  # clone/validate/move path runs without needing anything published.
  rm -rf "$RIG_PKG_REPO"
  mkdir -p "$RIG_PKG_REPO"
  local path
  if git -C "$RIG_PLUGIN_SRC_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # In a git checkout the package is what the repo ships: every tracked or
    # not-ignored file, symlinks kept as symlinks. A hand-picked list hid a
    # symlink that `omarchy plugin add` refuses; this cannot.
    git -C "$RIG_PLUGIN_SRC_ABS" ls-files -z --cached --others --exclude-standard |
      tar -C "$RIG_PLUGIN_SRC_ABS" --null --ignore-failed-read -T - -cf - 2>/dev/null |
      tar -C "$RIG_PKG_REPO" -xf - ||
      rig_die "could not copy the git-tracked tree of $RIG_PLUGIN_SRC_ABS"
  else
    for path in "${RIG_PACKAGE_PATHS[@]}"; do
      if [[ -e "$RIG_PLUGIN_SRC_ABS/$path" ]]; then
        cp -r "$RIG_PLUGIN_SRC_ABS/$path" "$RIG_PKG_REPO/"
      else
        rig_warn "package path missing in checkout, skipped: $path"
      fi
    done
  fi
  [[ -f $RIG_PKG_REPO/manifest.json ]] ||
    rig_die "no manifest.json in the package built from $RIG_PLUGIN_SRC_ABS"

  (
    cd "$RIG_PKG_REPO" || exit 1
    git init -q -b main
    git -c user.email=rig@localhost -c user.name=rig add -A
    git -c user.email=rig@localhost -c user.name=rig \
      commit -q -m "rig package of $RIG_PLUGIN_ID"
  ) >>"$RIG_LOGS/package.log" 2>&1 || rig_die "could not build the package repo"

  rig_ok "package repo built: $RIG_PKG_REPO"
}

rig_plugin_installed() {
  [[ -e "$RIG_PLUGINS_DIR/$RIG_PLUGIN_ID" ]]
}

rig_plugin_json() {
  omarchy plugin list --json 2>/dev/null |
    jq -c --arg id "$RIG_PLUGIN_ID" '.[] | select(.id == $id)' 2>/dev/null
}
