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

# The owner's live Paperclip instance. Off limits as a test target, and named
# here only so the guards can refuse to point at it.
RIG_HOST_PAPERCLIP_DIR="$RIG_HOST_HOME/.paperclip"
RIG_FORBIDDEN_PORTS=(3100 3101 54329)

# Read-only Omarchy install the nested shell runs from. The rig never writes
# inside it.
RIG_OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

# ------------------------------------------------------------- locations ----

RIG_TMP_ROOT=${RIG_TMP_ROOT:-${TMPDIR:-/tmp}/omarchy-plugin-rig}
RIG_SESSION_LINK="$RIG_TMP_ROOT/$RIG_PLUGIN_ID.current"

rig_new_session_dir() {
  local stamp
  stamp=$(date -u +%Y%m%d-%H%M%S)
  printf '%s/%s.%s.%s\n' "$RIG_TMP_ROOT" "$RIG_PLUGIN_ID" "$stamp" "$$"
}

rig_session_dir() {
  # The active session, or nothing.
  [[ -L $RIG_SESSION_LINK ]] || return 1
  local target
  target=$(readlink -f "$RIG_SESSION_LINK" 2>/dev/null) || return 1
  [[ -d $target ]] || return 1
  printf '%s\n' "$target"
}

# --------------------------------------------------------------- sandbox ----

rig_define_paths() {
  # Every path the rig owns, derived from one session dir.
  RIG_SESSION=$1
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
  # name, so the rig runtime dir gets a deliberately ugly short name next to
  # the host's, not a descriptive one under TMPDIR. `opr` is this rig.
  local tag=${RIG_SESSION##*.}
  RIG_RUNTIME_DIR="$RIG_HOST_RUNTIME_DIR/opr.${tag: -6}"
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
  mkdir -p "$RIG_RUNTIME_DIR"
  chmod 700 "$RIG_RUNTIME_DIR" "$RIG_SESSION"
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
  unset XDG_SESSION_ID XDG_SESSION_TYPE XDG_SESSION_DESKTOP
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

rig_guard_sandbox() {
  [[ -n ${RIG_HOME:-} ]] || rig_die "guard: no sandbox home"
  [[ $RIG_HOME != "$RIG_HOST_HOME" ]] ||
    rig_die "guard: sandbox HOME is the owner's home"
  [[ $RIG_HOME == "$RIG_TMP_ROOT"/* ]] ||
    rig_die "guard: sandbox HOME ($RIG_HOME) is outside $RIG_TMP_ROOT"
  [[ $RIG_RUNTIME_DIR != "$RIG_HOST_RUNTIME_DIR" ]] ||
    rig_die "guard: rig runtime dir is the host runtime dir"
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
    for forbidden in "${RIG_FORBIDDEN_PORTS[@]}"; do
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
  # rig_state_set KEY VALUE
  local key=$1 value=$2 tmp
  tmp=$(mktemp "$RIG_SESSION/.state.XXXXXX")
  if [[ -f $RIG_STATE_FILE ]]; then
    grep -v "^$key=" "$RIG_STATE_FILE" >"$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$RIG_STATE_FILE"
}

rig_state_get() {
  [[ -f $RIG_STATE_FILE ]] || return 1
  local line
  line=$(grep "^$1=" "$RIG_STATE_FILE" | tail -n1) || return 1
  printf '%s\n' "${line#*=}"
}

rig_load_state() {
  # Re-create the shell variables for an already-running session.
  local session
  session=$(rig_session_dir) || return 1
  rig_define_paths "$session"
  RIG_HTTP_PORT=$(rig_state_get http_port || echo "")
  RIG_PG_PORT=$(rig_state_get pg_port || echo "")
  RIG_INSTANCE_ID=$(rig_state_get instance_id || echo "$RIG_DEFAULT_INSTANCE_ID")
  RIG_MODE=$(rig_state_get mode || echo headless)
  RIG_SHELL_PID=$(rig_state_get shell_pid || echo "")
  RIG_HYPR_PID=$(rig_state_get hypr_pid || echo "")
  RIG_PARENT_PID=$(rig_state_get parent_pid || echo "")
  RIG_INSTANCE_PID=$(rig_state_get instance_pid || echo "")
  RIG_NESTED_DISPLAY=$(rig_state_get nested_display || echo "")
  return 0
}

# ---------------------------------------------------- nested compositor ----

rig_write_hypr_conf() {
  # A config of our own. The owner's ~/.config/hypr is never read: Hyprland
  # gets -c explicitly, and HOME points elsewhere anyway.
  # Hyprland's parser does not accept a nested category on one line, and it
  # paints a red error overlay across the top of every output when a key is
  # wrong — which would land in every screenshot the rig takes. So: one key per
  # line, nested categories spelled out, and nothing speculative.
  cat >"$RIG_HYPR_CONF" <<CONF
# Generated by dev/rig. Throwaway.
monitor = , ${RIG_OUTPUT_WIDTH}x${RIG_OUTPUT_HEIGHT}@60, 0x0, 1

general {
  gaps_in = 0
  gaps_out = 0
  border_size = 1
}

decoration {
  rounding = 0

  blur {
    enabled = false
  }

  shadow {
    enabled = false
  }
}

animations {
  enabled = false
}

misc {
  disable_hyprland_logo = true
  disable_splash_rendering = true
  force_default_wallpaper = 0
  disable_autoreload = true
}

input {
  follow_mouse = 1
}

# No autostart, no portals, no session wiring. The rig starts exactly what it
# wants to test and nothing else.
ecosystem {
  no_update_news = true
  no_donation_nag = true
}
CONF

  # A config error would be a red banner over the bar in every screenshot, so
  # catch it here where it can be read, not there where it hides the evidence.
  local problems
  problems=$(Hyprland --verify-config -c "$RIG_HYPR_CONF" 2>&1 |
    grep -i "config error" || true)
  [[ -z $problems ]] || rig_die "the rig Hyprland config is not clean:
$problems"
}

# --------------------------------------------------- headless parent ----
#
# Hyprland cannot run on its own without an output. Its headless backend is a
# fallback only: with neither a parent Wayland socket nor a DRM device,
# aquamarine's CBackend::create() throws and Hyprland aborts. Verified on
# Hyprland 0.56.2 / aquamarine 0.15.0.
#
# So "headless" here means "nest inside a headless parent compositor" rather
# than "no compositor". The rig will not reach for DRM: on a developer box the
# owner's session already holds DRM master, and a second DRM backend is exactly
# the blast radius this rig exists to avoid.

RIG_HEADLESS_PARENT_PACKAGES="weston (extra/weston) or cage (extra/cage)"

rig_headless_parent_command() {
  # Print the command that starts a headless Wayland parent, or nothing.
  if command -v weston >/dev/null 2>&1; then
    printf '%s\n' "weston --backend=headless --width=$RIG_OUTPUT_WIDTH --height=$RIG_OUTPUT_HEIGHT --socket=$RIG_PARENT_SOCKET"
  elif command -v wlheadless-run >/dev/null 2>&1; then
    printf '%s\n' "wlheadless-run -- sleep infinity"
  elif command -v cage >/dev/null 2>&1; then
    # cage is wlroots-based, so WLR_BACKENDS picks the backend for it.
    printf '%s\n' "cage -- sleep infinity"
  fi
}

rig_start_headless_parent() {
  RIG_PARENT_SOCKET="wayland-rig"
  local command log="$RIG_LOGS/parent-compositor.log"
  command=$(rig_headless_parent_command)
  [[ -n $command ]] || rig_die \
    "headless mode needs a headless Wayland parent compositor, and none is installed.
     Install one of: $RIG_HEADLESS_PARENT_PACKAGES — a host package install, so it needs
     the owner's go-ahead, and on the self-hosted runner pool it belongs in the runner image.
     Until then use 'dev/rig up --nested' inside a desktop session.
     The rig will not fall back to the DRM backend: the owner's session holds DRM master."

  rig_step "headless parent: $command"
  # shellcheck disable=SC2086 # the command is built above, deliberately split
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    WLR_HEADLESS_OUTPUTS=1 nohup $command >"$log" 2>&1 &
  RIG_PARENT_PID=$!
  rig_state_set parent_pid "$RIG_PARENT_PID"

  local deadline=$((SECONDS + 30)) socket=""
  while ((SECONDS < deadline)); do
    kill -0 "$RIG_PARENT_PID" 2>/dev/null ||
      rig_die "the headless parent compositor died; see $log"
    for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
      [[ -S $socket ]] && break 2
    done
    socket=""
    sleep 0.5
  done
  [[ -n $socket ]] || rig_die "the headless parent never opened a socket; see $log"
  rig_ok "headless parent up (pid $RIG_PARENT_PID, socket $socket)"
  printf '%s\n' "$socket"
}

rig_start_compositor() {
  rig_write_hypr_conf
  rig_guard_socket_path
  local log="$RIG_LOGS/compositor.log" parent=""

  if [[ $RIG_MODE == nested ]]; then
    [[ -n $RIG_HOST_WAYLAND_DISPLAY ]] ||
      rig_die "nested mode needs a Wayland session; set WAYLAND_DISPLAY or use --headless"
    parent=$RIG_HOST_WAYLAND_DISPLAY
    [[ $parent == /* ]] || parent="$RIG_HOST_RUNTIME_DIR/$parent"
    [[ -S $parent ]] || rig_die "no parent Wayland socket at $parent"
    rig_step "nested mode: a window inside the owner's session (parent $parent)"
  else
    rig_step "headless mode: nested inside a headless parent compositor"
    parent=$(rig_start_headless_parent) || exit 1
  fi

  # An absolute WAYLAND_DISPLAY is how the nested compositor reaches a parent
  # socket that lives in a runtime dir it no longer has. Either way the shell
  # under test sees only the socket the rig gives it.
  WAYLAND_DISPLAY="$parent" nohup Hyprland -c "$RIG_HYPR_CONF" >"$log" 2>&1 &
  RIG_HYPR_PID=$!
  rig_state_set hypr_pid "$RIG_HYPR_PID"

  local deadline=$((SECONDS + 40)) sig=""
  while ((SECONDS < deadline)); do
    kill -0 "$RIG_HYPR_PID" 2>/dev/null ||
      rig_die "the nested compositor died; see $log"
    sig=$(rig_hypr_signature) && [[ -n $sig ]] && break
    sleep 0.5
  done
  [[ -n $sig ]] || rig_die "the nested compositor never opened its socket; see $log"

  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  rig_state_set hypr_signature "$sig"

  # The nested compositor's own socket is a *second* wayland-N in this runtime
  # dir when a headless parent put one there first, so pick by exclusion.
  RIG_NESTED_DISPLAY=$(rig_nested_wayland_display "$parent") ||
    rig_die "the nested compositor exposed no Wayland socket"
  export WAYLAND_DISPLAY="$RIG_NESTED_DISPLAY"
  rig_state_set nested_display "$RIG_NESTED_DISPLAY"

  # A socket is not an output. The shell and grim both need one, and in nested
  # mode it appears only once the parent has mapped the window.
  deadline=$((SECONDS + 30))
  until [[ $(hyprctl monitors -j 2>/dev/null | jq 'length' 2>/dev/null) -ge 1 ]] 2>/dev/null; do
    kill -0 "$RIG_HYPR_PID" 2>/dev/null ||
      rig_die "the nested compositor died; see $log"
    ((SECONDS < deadline)) ||
      rig_die "the nested compositor never got an output; see $log"
    sleep 0.5
  done
  rig_ok "nested compositor up (pid $RIG_HYPR_PID, display $RIG_NESTED_DISPLAY)"
}

rig_hypr_signature() {
  local dir
  for dir in "$XDG_RUNTIME_DIR"/hypr/*/; do
    [[ -S $dir/.socket.sock ]] || continue
    dir=${dir%/}
    printf '%s\n' "${dir##*/}"
    return 0
  done
  return 1
}

rig_nested_wayland_display() {
  # rig_nested_wayland_display [parent-socket-to-ignore]
  local skip=${1:-} socket
  for socket in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
    [[ -S $socket ]] || continue
    [[ -n $skip && $socket == "$skip" ]] && continue
    printf '%s\n' "${socket##*/}"
    return 0
  done
  return 1
}

# ------------------------------------------------------------------ grim ----
#
# A nested compositor only gets frame callbacks while the host shows its
# window. On a workspace nobody is looking at, grim waits for a frame forever.
# So every grim call in the rig has a deadline and says why it ran out.

RIG_GRIM_TIMEOUT=${RIG_GRIM_TIMEOUT:-15}

rig_grim() {
  # rig_grim <file.png> — one capture, bounded. Exit 124 means "no frame".
  local out=$1 status=0
  timeout --kill-after=3 "$RIG_GRIM_TIMEOUT" grim -t png "$out" || status=$?
  if ((status == 124 || status == 137)); then
    rig_fail "grim got no frame in ${RIG_GRIM_TIMEOUT}s: the rig window is not on a visible workspace of the host session. Switch the host to the workspace that holds the rig window and run it again."
    return 124
  fi
  return "$status"
}

rig_grim_wait() {
  # rig_grim_wait <file.png> — grim says "no wl_output" until the output is
  # advertised, so retry fast failures for up to 20 seconds. A timeout is not
  # retried: it will not get better by waiting.
  local out=$1 deadline=$((SECONDS + 20)) status=0
  while :; do
    rig_grim "$out" && return 0
    status=$?
    ((status == 124)) && return 124
    ((SECONDS < deadline)) || return "$status"
    sleep 0.5
  done
}

# --------------------------------------------------------- nested shell ----

rig_start_shell() {
  local log="$RIG_LOGS/shell.log"
  rig_step "starting the Omarchy shell from $OMARCHY_PATH/shell"
  printf -- '--- shell start %s ---\n' "$(date -u +%H:%M:%S)" >>"$log"
  nohup quickshell -p "$OMARCHY_PATH/shell" >>"$log" 2>&1 &
  RIG_SHELL_PID=$!
  rig_state_set shell_pid "$RIG_SHELL_PID"

  local deadline=$((SECONDS + 60))
  while ((SECONDS < deadline)); do
    kill -0 "$RIG_SHELL_PID" 2>/dev/null ||
      rig_die "the nested shell died; see $log"
    if [[ $(omarchy-shell shell ping 2>/dev/null) == *ok* ]] ||
      omarchy-shell shell ping >/dev/null 2>&1; then
      rig_guard_nested_shell
      rig_ok "nested Omarchy shell answering IPC (pid $RIG_SHELL_PID)"
      return 0
    fi
    sleep 1
  done
  rig_die "the nested shell never answered IPC; see $log"
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
  # stop), then the shell, then the compositor, then the filesystem.
  local keep_evidence=${1:-}

  rig_say "Tearing down"

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

  if [[ -n ${RIG_SHELL_PID:-} ]]; then
    rig_step "stopping the nested shell (pid $RIG_SHELL_PID)"
    rig_kill_tree "$RIG_SHELL_PID" TERM
    rig_wait_gone "$RIG_SHELL_PID" 10 || rig_kill_tree "$RIG_SHELL_PID" KILL
  fi

  if [[ -n ${RIG_HYPR_PID:-} ]]; then
    rig_step "stopping the nested compositor (pid $RIG_HYPR_PID)"
    rig_kill_tree "$RIG_HYPR_PID" TERM
    rig_wait_gone "$RIG_HYPR_PID" 10 || rig_kill_tree "$RIG_HYPR_PID" KILL
  fi

  if [[ -n ${RIG_PARENT_PID:-} ]]; then
    rig_step "stopping the headless parent compositor (pid $RIG_PARENT_PID)"
    rig_kill_tree "$RIG_PARENT_PID" TERM
    rig_wait_gone "$RIG_PARENT_PID" 10 || rig_kill_tree "$RIG_PARENT_PID" KILL
  fi

  # Anything else still rooted in the session dir, whatever started it.
  local stray
  for stray in $(pgrep -f -- "$RIG_SESSION" 2>/dev/null); do
    [[ $stray == "$$" ]] && continue
    rig_step "killing stray process in the session tree (pid $stray)"
    kill -KILL "$stray" 2>/dev/null || true
  done

  if [[ -n $keep_evidence && -d ${RIG_EVIDENCE:-} ]]; then
    local out="$keep_evidence"
    mkdir -p "$out"
    cp -r "$RIG_EVIDENCE/." "$out/" 2>/dev/null || true
    cp -r "$RIG_LOGS" "$out/logs" 2>/dev/null || true
    rig_ok "evidence kept in $out"
  fi

  [[ -n ${RIG_RUNTIME_DIR:-} && $RIG_RUNTIME_DIR == "$RIG_HOST_RUNTIME_DIR"/opr.* ]] &&
    rm -rf "$RIG_RUNTIME_DIR"
  [[ -n ${RIG_SESSION:-} && $RIG_SESSION == "$RIG_TMP_ROOT"/* ]] &&
    rm -rf "$RIG_SESSION"
  rm -f "$RIG_SESSION_LINK"

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

  if [[ -e $RIG_SESSION_LINK ]]; then
    rig_fail "session pointer still present: $RIG_SESSION_LINK"
    problems=$((problems + 1))
  else
    rig_ok "session pointer gone"
  fi

  for port in ${RIG_HTTP_PORT:-} ${RIG_PG_PORT:-}; do
    [[ -n $port ]] || continue
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

  if [[ -n ${RIG_SESSION:-} ]] && pgrep -f -- "$RIG_SESSION" >/dev/null 2>&1; then
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
  for path in "${RIG_PACKAGE_PATHS[@]}"; do
    if [[ -e "$RIG_PLUGIN_SRC_ABS/$path" ]]; then
      cp -r "$RIG_PLUGIN_SRC_ABS/$path" "$RIG_PKG_REPO/"
    else
      rig_warn "package path missing in checkout, skipped: $path"
    fi
  done
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
