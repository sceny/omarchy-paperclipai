#!/bin/bash
# Where the rig's compositor lives: hidden (the default) or visible (on request).
# Sourced by dev/rig, never run directly.
#
#   hidden    Hyprland runs inside `labwc`, which runs on wlroots' headless
#             backend. Nothing is ever mapped on any host monitor, so there is
#             no window to move, retile or focus, and nothing for the owner's
#             workspaces to notice. Frames still tick, so grim works.
#   visible   Hyprland runs as a window of the owner's session. Only
#             `dev/rig show` or `dev/rig up --visible` does that, and agents
#             do not call either on their own (see rig_refuse_unrequested_visible).
#
# shellcheck shell=bash

RIG_HEADLESS_PACKAGES="labwc (extra/labwc) and wtype (extra/wtype)"

# ------------------------------------------------------------- host facts ----
#
# Read-only questions to the owner's Hyprland ("which windows are there, which
# workspace is active"). Never a dispatch, never a keyword, never a reload.

rig_host_hyprctl() {
  # rig_host_hyprctl <hyprctl args...> — against the owner's compositor only.
  local sig
  sig=$(rig_host_sig) || return 1
  env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$RIG_HOST_RUNTIME_DIR" \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl "$@"
}

rig_host_sig() {
  # The owner's Hyprland instance signature, or failure when there is no
  # desktop session to look at (a CI runner, an SSH login).
  local sig=${RIG_HOST_HYPR_SIG:-}
  if [[ -n $sig ]] && env XDG_RUNTIME_DIR="$RIG_HOST_RUNTIME_DIR" \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl version >/dev/null 2>&1; then
    printf '%s\n' "$sig"
    return 0
  fi
  # Not in the environment (an agent run has none): ask for the live instances
  # of the host runtime dir and take the newest.
  sig=$(env XDG_RUNTIME_DIR="$RIG_HOST_RUNTIME_DIR" hyprctl instances -j 2>/dev/null |
    jq -r 'sort_by(.time) | reverse | .[0].instance // empty' 2>/dev/null)
  [[ -n $sig ]] || return 1
  printf '%s\n' "$sig"
}

rig_host_wayland_socket() {
  # The owner's Wayland socket, for the visible view only.
  local socket=$RIG_HOST_WAYLAND_DISPLAY candidates=()
  if [[ -z $socket ]]; then
    for socket in "$RIG_HOST_RUNTIME_DIR"/wayland-[0-9]*; do
      [[ -S $socket ]] && candidates+=("$socket")
    done
    ((${#candidates[@]} == 1)) || return 1
    socket=${candidates[0]}
  fi
  [[ $socket == /* ]] || socket="$RIG_HOST_RUNTIME_DIR/$socket"
  [[ -S $socket ]] || return 1
  printf '%s\n' "$socket"
}

rig_host_snapshot() {
  # rig_host_snapshot <out.json> — what the owner's desktop looks like now:
  # every window with its workspace, place and size, the active workspace, the
  # focused window. Stable key order, so two snapshots can be diffed.
  local out=$1 clients workspaces active window
  if ! clients=$(rig_host_hyprctl clients -j 2>/dev/null) ||
    ! workspaces=$(rig_host_hyprctl workspaces -j 2>/dev/null) ||
    ! active=$(rig_host_hyprctl activeworkspace -j 2>/dev/null) ||
    ! window=$(rig_host_hyprctl activewindow -j 2>/dev/null); then
    printf '{"available":false}\n' >"$out"
    return 1
  fi
  jq -S -n --argjson clients "$clients" --argjson workspaces "$workspaces" \
    --argjson active "$active" --argjson window "$window" '{
      available: true,
      active_workspace: {id: $active.id, name: $active.name, windows: $active.windows, monitor: $active.monitor},
      focused_window: ($window.address // null),
      workspaces: ($workspaces | map({id, name, windows, monitor}) | sort_by(.id)),
      clients: ($clients | map({address, workspace: .workspace.id, at, size, floating, pid, class, focusHistoryID}) | sort_by(.address))
    }' >"$out"
}

rig_host_compare() {
  # rig_host_compare <before.json> <after.json> — 0 when the desktop is the
  # same, 1 with a diff on stdout when it is not, 2 when there was nothing to
  # compare (no desktop session).
  local before=$1 after=$2
  jq -e '.available' "$before" >/dev/null 2>&1 || return 2
  jq -e '.available' "$after" >/dev/null 2>&1 || return 2
  diff -u --label before --label after "$before" "$after"
}

rig_host_rig_clients() {
  # Host windows that belong to this rig: any client whose pid carries the
  # rig's tag. Empty output is the only acceptable answer for a hidden rig.
  local clients pids
  clients=$(rig_host_hyprctl clients -j 2>/dev/null) || return 0
  pids=$(rig_tagged_pids "$RIG_ID" | jq -R 'tonumber' | jq -sc .)
  jq -r --argjson pids "$pids" \
    '.[] | select(.pid as $p | $pids | index($p)) | "pid \(.pid) class \(.class) workspace \(.workspace.name)"' \
    <<<"$clients"
}

rig_guard_hidden() {
  # A hidden rig that shows up on the owner's desktop is a defect, so this is
  # asserted, not assumed. A no-op for a visible rig and when there is no
  # desktop to look at.
  [[ ${RIG_VIEW:-hidden} == hidden ]] || return 0
  local leaked
  leaked=$(rig_host_rig_clients)
  [[ -z $leaked ]] ||
    rig_die "guard: a hidden rig has a window on the owner's desktop:
$leaked"
}

rig_refuse_unrequested_visible() {
  # The owner asks for the window; an agent never decides to open one. The
  # owner asking an agent to open it is a request, and RIG_ALLOW_VISIBLE=1 is
  # how that request is passed on.
  [[ ${RIG_ALLOW_VISIBLE:-} == 1 ]] && return 0
  if [[ -n ${PAPERCLIP_AGENT_ID:-}${PAPERCLIP_RUN_ID:-}${CLAUDECODE:-}${CI:-}${GITHUB_ACTIONS:-} ]]; then
    rig_die "refusing to put the rig on the owner's screen from an agent or CI run.
     Only the owner asks for that. When they have, run it again with RIG_ALLOW_VISIBLE=1."
  fi
}

# -------------------------------------------------------------- compositor ----

rig_write_hypr_conf() {
  # A config of our own. The owner's ~/.config/hypr is never read: Hyprland
  # gets -c explicitly, and HOME points elsewhere anyway.
  # Hyprland's parser does not accept a nested category on one line, and it
  # paints a red error overlay across the top of every output when a key is
  # wrong — which would land in every screenshot the rig takes. So: one key per
  # line, nested categories spelled out, and nothing speculative.
  # Hidden: labwc configures a window it has not mapped yet with 0x0, so the
  # nested output has no preferred mode and Hyprland gives up on it. Asking for
  # the headless output's own size (1280x720) gives it a custom mode, it draws,
  # labwc maps it, and the maximize rule keeps the two sizes equal.
  local mode=preferred
  [[ $RIG_VIEW == visible ]] || mode=1280x720@60
  cat >"$RIG_HYPR_CONF" <<CONF
# Generated by dev/rig. Throwaway.
monitor = , $mode, 0x0, 1

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
  disable_watchdog_warning = true
  disable_xdg_env_checks = true
}

input {
  follow_mouse = 1
}

# No autostart, no portals, no session wiring. The rig starts exactly what it
# wants to test and nothing else.
debug {
  disable_logs = false
  suppress_errors = true
}

ecosystem {
  no_update_news = true
  no_donation_nag = true
}
CONF
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
  # rig_nested_wayland_display <signature> — the Wayland socket the nested
  # Hyprland serves its clients on. Hyprland knows it; a headless parent has
  # put a socket of its own in the same directory, so scanning would guess.
  local sig=$1 socket
  socket=$(hyprctl instances -j 2>/dev/null |
    jq -r --arg sig "$sig" '.[] | select(.instance == $sig) | .wl_socket // empty' 2>/dev/null)
  [[ -n $socket && -S "$XDG_RUNTIME_DIR/$socket" ]] || return 1
  printf '%s\n' "$socket"
}

rig_guard_compositor_env() {
  # A Hyprland that is started without a usable runtime dir does not fail, it
  # aborts, and the abort is a core dump and a crash notice on the owner's
  # desktop. So every Hyprland the rig runs, a compositor or `--verify-config`,
  # gets proof of its environment first, and a failure is a message.
  local dir=${XDG_RUNTIME_DIR:-}
  [[ -n $dir ]] ||
    rig_die "guard: XDG_RUNTIME_DIR is not set; Hyprland would abort. Run it through dev/rig."
  [[ $dir == /* && -d $dir ]] ||
    rig_die "guard: XDG_RUNTIME_DIR ($dir) is not an existing absolute directory; Hyprland would abort"
  [[ $dir != "$RIG_HOST_RUNTIME_DIR" && $dir != "$RIG_HOST_RUNTIME_DIR"/* && $dir != /run/user/* ]] ||
    rig_die "guard: XDG_RUNTIME_DIR ($dir) is the owner's session runtime dir"
  [[ -O $dir && $(stat -c %a "$dir") == 700 ]] ||
    rig_die "guard: XDG_RUNTIME_DIR ($dir) is not a private (0700) directory of this user"
  [[ $HOME != "$RIG_HOST_HOME" ]] ||
    rig_die "guard: HOME is the owner's home; Hyprland would write its crash report there"
  local soft hard
  read -r soft hard < <(rig_core_limits)
  [[ $soft == 0 || $soft == 1 ]] ||
    rig_die "guard: core dumps are enabled (core limit soft=$soft hard=$hard); a failed compositor would dump core on the host"
}

rig_guard_launch_env() {
  rig_guard_compositor_env
  [[ -r $RIG_HYPR_CONF ]] || rig_die "guard: no compositor config at $RIG_HYPR_CONF"
}

rig_check_config_errors() {
  # Asked of the running compositor. `Hyprland --verify-config` would be
  # simpler and is not safe: Hyprland aborts, rather than fails, whenever its
  # environment is not what it expects.
  local errors
  errors=$(hyprctl configerrors 2>/dev/null | grep -v '^$' || true)
  [[ -z $errors ]] || rig_die "the rig Hyprland config has errors (a red banner in every screenshot):
$errors"
}

rig_require_headless_parent() {
  command -v labwc >/dev/null 2>&1 && command -v wtype >/dev/null 2>&1 || rig_die \
    "the hidden view needs a headless Wayland parent, and none is installed.
     Install: $RIG_HEADLESS_PACKAGES. That is a host package install, so it needs the owner's go-ahead,
     and on the self-hosted runner pool it belongs in the runner image.
     The rig will not quietly open a window on the owner's desktop instead, and it will not use
     the DRM backend: the owner's session holds the GPU and the keyboard."
}

rig_wake_parent() {
  # A headless labwc has no input devices and so sends its clients no events,
  # and the nested Hyprland (Aquamarine) only flushes its requests when an
  # event wakes it: its output window is created but never delivered, or its
  # first buffer reaches labwc before the first configure ("xdg_surface has
  # never been configured") and labwc drops the connection. A virtual key press
  # on the parent's own seat is the event, so the rig sends one every few
  # hundred milliseconds while the compositor starts. The parent is the oldest
  # socket in the rig's private runtime dir; it never touches the owner's seat.
  local sock
  sock=$(ls -tr "$RIG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)
  [[ -S $sock ]] || return 0
  WAYLAND_DISPLAY="${sock##*/}" timeout 5 wtype -M shift -m shift >/dev/null 2>&1 || true
}

rig_wake_parent_start() {
  # Wake the parent without a pause from the moment its socket exists until the
  # first frame is proven: Aquamarine's first request is flushed by the first
  # event it receives, and every event that comes later loses the race to
  # labwc's first configure. Bounded, so nothing outlives a failed start.
  local deadline=$((SECONDS + 15))
  until [[ -n $(ls "$RIG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$') ]]; do
    ((SECONDS < deadline)) || return 0
    sleep 0.02
  done
  (
    deadline=$((SECONDS + 25))
    while ((SECONDS < deadline)); do rig_wake_parent; done
  ) >/dev/null 2>&1 &
  RIG_WAKER_PID=$!
}

rig_wake_parent_stop() {
  [[ -n ${RIG_WAKER_PID:-} ]] || return 0
  kill "$RIG_WAKER_PID" 2>/dev/null || true
  wait "$RIG_WAKER_PID" 2>/dev/null || true
  RIG_WAKER_PID=""
}

rig_render_node() {
  # The GPU render node the headless parent draws with. Hyprland nests only in a
  # parent that offers dmabuf, and that needs a GL renderer, so a render node
  # is required; with two GPUs the NVIDIA EGL path fails, so the first node wins
  # unless RIG_RENDER_NODE says otherwise.
  local node=${RIG_RENDER_NODE:-}
  if [[ -z $node ]]; then
    for node in /dev/dri/renderD*; do
      [[ -c $node ]] && break
    done
  fi
  [[ -c $node ]] || rig_die "the hidden view needs a GPU render node (/dev/dri/renderD*), and there is none. Set RIG_RENDER_NODE."
  printf '%s\n' "$node"
}

rig_mesa_egl_vendor() {
  # GLVND picks the NVIDIA EGL vendor first on a two-GPU box, and it fails on
  # the Intel render node. Mesa's vendor file is always right for a render node.
  local f=/usr/share/glvnd/egl_vendor.d/50_mesa.json
  [[ -r $f ]] && printf '%s\n' "$f"
}

rig_write_parent_conf() {
  # labwc's own config dir, inside the rig session. The owner's ~/.config/labwc
  # is never read. No decorations, and the one client (Hyprland) fills the output.
  RIG_PARENT_CONF="$RIG_SESSION/labwc"
  mkdir -p "$RIG_PARENT_CONF"
  cat >"$RIG_PARENT_CONF/rc.xml" <<'CONF'
<?xml version="1.0"?>
<labwc_config>
  <core><gap>0</gap></core>
  <windowRules>
    <windowRule identifier="*">
      <serverDecoration>no</serverDecoration>
      <action name="Maximize"/>
    </windowRule>
  </windowRules>
</labwc_config>
CONF
}

rig_start_compositor() {
  # The hidden start can lose a race inside Aquamarine (see rig_start_compositor_once);
  # it is cheap to try again, so it does, a bounded number of times.
  local attempt status=0 max=20
  [[ $RIG_VIEW == visible ]] && max=1
  for ((attempt = 1; attempt <= max; attempt++)); do
    rig_start_compositor_once "$attempt" && return 0
    status=$?
    ((status == 75)) || return "$status"
    rig_stop_display
    ((attempt < max)) && rig_step "the parent dropped the compositor's window; starting again ($((attempt + 1))/$max)"
  done
  rig_die "the hidden compositor lost the start-up race $max times in a row; see $RIG_LOGS/compositor.log"
}

rig_start_compositor_once() {
  rig_write_hypr_conf
  rig_guard_socket_path
  rig_guard_launch_env
  local log="$RIG_LOGS/compositor.log" parent=""
  : >>"$log"
  local log_from=$(($(wc -l <"$log") + 1))
  printf -- '--- compositor start %s (%s) ---\n' "$(date -u +%H:%M:%S)" "$RIG_VIEW" >>"$log"

  if [[ $RIG_VIEW == visible ]]; then
    parent=$(rig_host_wayland_socket) ||
      rig_die "the visible view needs the owner's Wayland session, and there is none to nest in. Set WAYLAND_DISPLAY."
    rig_step "visible: a window in the owner's session (parent $parent)"
    # An absolute WAYLAND_DISPLAY is how the compositor reaches a parent socket
    # that lives in a runtime dir it no longer has.
    WAYLAND_DISPLAY="$parent" nohup Hyprland -c "$RIG_HYPR_CONF" >>"$log" 2>&1 &
    RIG_HYPR_PID=$!
    RIG_PARENT_PID=""
  else
    rig_require_headless_parent
    rig_step "hidden: Hyprland inside a headless labwc (nothing is mapped on the host)"
    # labwc runs Hyprland as its session command (-S: labwc ends when Hyprland
    # does), so the compositor's Wayland parent is labwc's own socket, in the
    # rig's runtime dir, and nothing else.
    rig_write_parent_conf
    local node
    node=$(rig_render_node) || return 1
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1 \
      WLR_RENDER_DRM_DEVICE="$node" \
      __EGL_VENDOR_LIBRARY_FILENAMES=$(rig_mesa_egl_vendor) \
      nohup labwc -C "$RIG_PARENT_CONF" -S "Hyprland -c $RIG_HYPR_CONF" >>"$log" 2>&1 &
    RIG_PARENT_PID=$!
    RIG_HYPR_PID=""
    rig_wake_parent_start
  fi
  rig_state_set parent_pid "$RIG_PARENT_PID"

  local deadline=$((SECONDS + 40)) sig=""
  while ((SECONDS < deadline)); do
    kill -0 "${RIG_PARENT_PID:-$RIG_HYPR_PID}" 2>/dev/null ||
      rig_die "the compositor died (no core dump: cores are off for the rig); last log lines of $log:
$(tail -n 8 "$log" 2>/dev/null)"
    sig=$(rig_hypr_signature) && [[ -n $sig ]] && break
    [[ -n $RIG_PARENT_PID ]] && rig_wake_parent
    sleep 0.25
  done
  [[ -n $sig ]] || rig_die "the compositor never opened its socket; see $log"

  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  rig_state_set hypr_signature "$sig"

  local tries=0
  while [[ -z $RIG_HYPR_PID ]] && ((tries++ < 40)); do
    RIG_HYPR_PID=$(hyprctl instances -j 2>/dev/null |
      jq -r --arg sig "$sig" '.[] | select(.instance == $sig) | .pid // empty' 2>/dev/null) || RIG_HYPR_PID=""
    [[ -n $RIG_HYPR_PID ]] || sleep 0.25
  done
  [[ -n $RIG_HYPR_PID ]] || rig_die "could not find the pid of the rig's Hyprland"
  rig_state_set hypr_pid "$RIG_HYPR_PID"

  deadline=$((SECONDS + 20))
  RIG_NESTED_DISPLAY=""
  while ((SECONDS < deadline)); do
    RIG_NESTED_DISPLAY=$(rig_nested_wayland_display "$sig") && break
    [[ -n $RIG_PARENT_PID ]] && rig_wake_parent
    sleep 0.25
  done
  [[ -n $RIG_NESTED_DISPLAY ]] || rig_die "the compositor exposed no Wayland socket"
  export WAYLAND_DISPLAY="$RIG_NESTED_DISPLAY"
  rig_state_set nested_display "$RIG_NESTED_DISPLAY"

  # A socket is not an output. The shell and grim both need one, and in the
  # visible view it appears only once the parent has mapped the window.
  deadline=$((SECONDS + 30))
  until [[ $(hyprctl monitors -j 2>/dev/null | jq 'length' 2>/dev/null) -ge 1 ]] 2>/dev/null; do
    kill -0 "$RIG_HYPR_PID" 2>/dev/null ||
      rig_die "the compositor died; see $log"
    ((SECONDS < deadline)) ||
      rig_die "the compositor never got an output; see $log"
    [[ -n $RIG_PARENT_PID ]] && rig_wake_parent
    sleep 0.25
  done
  if [[ -n $RIG_PARENT_PID ]]; then
    # Aquamarine, the nested Hyprland's backend, loses a start-up race against
    # the parent about half the time: it commits its first buffer before the
    # parent's first configure ("xdg_surface has never been configured", and
    # wlroots ends the connection), or it stops dispatching and never draws.
    # Neither is a fault of the plugin under test, and a fresh start is cheap,
    # so prove that a frame comes out and start again when it does not.
    local i
    for i in 1 2 3 4 5 6; do
      rig_wake_parent
      sleep 0.25
    done
    if tail -n "+$log_from" "$log" | grep -q 'has never been configured'; then
      rig_wake_parent_stop
      return 75
    fi
    rig_wake_parent
    timeout --kill-after=2 6 grim -t ppm /dev/null >/dev/null 2>&1 || {
      rig_wake_parent_stop
      return 75
    }
    rig_wake_parent_stop
  fi
  rig_check_config_errors
  rig_ok "compositor up ($RIG_VIEW; pid $RIG_HYPR_PID, display $RIG_NESTED_DISPLAY)"
  rig_guard_hidden
}

rig_stop_display() {
  # The shell, then the compositor, then its parent. Used by teardown and by
  # show/hide, which swap the compositor and leave everything else running.
  rig_wake_parent_stop
  if [[ -n ${RIG_SHELL_PID:-} ]]; then
    rig_step "stopping the nested shell (pid $RIG_SHELL_PID)"
    rig_kill_tree "$RIG_SHELL_PID" TERM
    rig_wait_gone "$RIG_SHELL_PID" 10 || rig_kill_tree "$RIG_SHELL_PID" KILL
    rig_state_set shell_pid ""
    RIG_SHELL_PID=""
  fi

  if [[ -n ${RIG_HYPR_PID:-} ]]; then
    rig_step "stopping the compositor (pid $RIG_HYPR_PID)"
    rig_kill_tree "$RIG_HYPR_PID" TERM
    rig_wait_gone "$RIG_HYPR_PID" 10 || rig_kill_tree "$RIG_HYPR_PID" KILL
    rig_state_set hypr_pid ""
    RIG_HYPR_PID=""
  fi

  if [[ -n ${RIG_PARENT_PID:-} ]]; then
    rig_step "stopping the headless parent (pid $RIG_PARENT_PID)"
    rig_kill_tree "$RIG_PARENT_PID" TERM
    rig_wait_gone "$RIG_PARENT_PID" 10 || rig_kill_tree "$RIG_PARENT_PID" KILL
    rig_state_set parent_pid ""
    RIG_PARENT_PID=""
  fi

  # A restart must not find the old compositor's address in the state.
  rig_state_set nested_display ""
  rig_state_set hypr_signature ""
  RIG_NESTED_DISPLAY=""
  unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
}

# ------------------------------------------------------------------ grim ----
#
# In the hidden view the headless parent keeps producing frames, so grim always
# gets one. In the visible view a nested compositor only gets frame callbacks
# while the host shows its window; on a workspace nobody is looking at, grim
# waits for a frame forever. So every grim call in the rig has a deadline and
# says why it ran out.

RIG_GRIM_TIMEOUT=${RIG_GRIM_TIMEOUT:-15}

rig_grim() {
  # rig_grim <file.png> — one capture, bounded. Exit 124 means "no frame".
  local out=$1 status=0
  timeout --kill-after=3 "$RIG_GRIM_TIMEOUT" grim -t png "$out" || status=$?
  if ((status == 124 || status == 137)); then
    if [[ ${RIG_VIEW:-hidden} == visible ]]; then
      rig_fail "grim got no frame in ${RIG_GRIM_TIMEOUT}s: the rig window is not on a visible workspace of the host session. Switch to the workspace that holds it, or run 'dev/rig hide'."
    else
      rig_fail "grim got no frame in ${RIG_GRIM_TIMEOUT}s from a hidden rig; see $RIG_LOGS/compositor.log"
    fi
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
