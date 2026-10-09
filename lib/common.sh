#!/bin/bash
# Shared helpers for the omarchy-paperclip-* scripts. Sourced, never run.
#
# Everything here answers one of four questions: where is the instance, how do
# I call the CLI, how do I tell the user, and where do I keep state.

# shellcheck shell=bash

PAPERCLIP_PLUGIN_DIR=${PAPERCLIP_PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
PAPERCLIP_PLUGIN_ID=${PAPERCLIP_PLUGIN_ID:-sceny.paperclipai}
PAPERCLIP_WEBAPP_NAME=${PAPERCLIP_OMARCHY_WEBAPP_NAME:-Paperclip}
PAPERCLIP_INSTANCE=${PAPERCLIP_OMARCHY_INSTANCE:-default}
PAPERCLIP_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/paperclipai

pc_state_dir() {
  mkdir -p "$PAPERCLIP_STATE_DIR"
  printf '%s\n' "$PAPERCLIP_STATE_DIR"
}

pc_status() {
  # One JSON object describing the instance. Callers pass jq filters to read it.
  python3 "$PAPERCLIP_PLUGIN_DIR/bin/omarchy-paperclip-status" --compact "$@" 2>/dev/null
}

pc_status_field() {
  # pc_status_field '.state' [status-json]
  local filter=$1 json=${2:-}
  [[ -n $json ]] || json=$(pc_status)
  printf '%s' "$json" | jq -r "$filter // empty" 2>/dev/null
}

pc_api_base() {
  if [[ -n ${PAPERCLIP_OMARCHY_API_BASE:-} ]]; then
    printf '%s\n' "${PAPERCLIP_OMARCHY_API_BASE%/}"
    return 0
  fi
  local info=$HOME/.paperclip/instances/$PAPERCLIP_INSTANCE/runtime-info.json
  local url=""
  if [[ -r $info ]]; then
    url=$(jq -r '.dashboardUrl // empty' "$info" 2>/dev/null)
  fi
  printf '%s\n' "${url:-http://127.0.0.1:3100}"
}

pc_health_ok() {
  # Is the instance answering right now?
  local base
  base=$(pc_api_base)
  curl -fsS --max-time 4 "$base/api/health" 2>/dev/null | jq -e '.status == "ok"' >/dev/null 2>&1
}

pc_wait_for_health() {
  # pc_wait_for_health [seconds]
  local deadline=$((SECONDS + ${1:-90}))
  while ((SECONDS < deadline)); do
    pc_health_ok && return 0
    sleep 2
  done
  return 1
}

pc_webapp_window_address() {
  # The address of the Paperclip web app window that is already open, or
  # nothing when there is none.
  #
  # A browser web app window carries the instance host in its window class
  # (brave-127.0.0.1__-Default). That is what tells it apart from an ordinary
  # browser window on the same machine. The window title is the second signal,
  # because every Paperclip page ends in the app name. A window with both wins,
  # so a second web app on the same host cannot catch the click.
  command -v hyprctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local host
  host=$(pc_api_base)
  host=${host#*://}
  host=${host%%/*}
  host=${host%%:*}
  [[ -n $host ]] || return 1

  hyprctl clients -j 2>/dev/null |
    jq -r --arg host "$host" --arg name "$PAPERCLIP_WEBAPP_NAME" '
      def lower: ascii_downcase;
      [ .[]
        | select(.mapped != false)
        | {
            address,
            host: (((.class // "") | lower) | contains($host | lower)),
            name: ((((.class // "") + " " + (.title // "")) | lower) | contains($name | lower))
          }
      ]
      | (map(select(.host and .name)) + map(select(.host)) + map(select(.name)))
      | first.address // empty
    '
}

pc_focus_webapp_window() {
  # Raise the Paperclip web app window that is already open. Fails when there
  # is none, so the caller can open one.
  local address answer
  address=$(pc_webapp_window_address) || return 1
  [[ -n $address ]] || return 1

  answer=$(hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" 2>/dev/null)
  [[ $answer == ok* ]] && return 0
  answer=$(hyprctl dispatch focuswindow "address:$address" 2>/dev/null)
  [[ $answer == ok* ]]
}

pc_cli() {
  # Print the command words that run the Paperclip CLI, or nothing when there
  # is no way to run it. A managed install wins; npx is the documented
  # fallback and needs no install step of its own.
  if command -v paperclipai >/dev/null 2>&1; then
    printf '%s\n' paperclipai
  elif [[ -x $HOME/.local/bin/paperclipai ]]; then
    printf '%s\n' "$HOME/.local/bin/paperclipai"
  elif command -v npx >/dev/null 2>&1; then
    printf '%s\n%s\n%s\n' npx -y paperclipai@latest
  fi
}

pc_run_cli() {
  # pc_run_cli doctor --repair --yes
  local -a cli=()
  mapfile -t cli < <(pc_cli)
  if ((${#cli[@]} == 0)); then
    echo "Paperclip CLI not found, and npx is unavailable. Install Node.js 24.11+ first." >&2
    return 127
  fi
  "${cli[@]}" "$@"
}

pc_notify() {
  # pc_notify <urgency> <glyph> <headline> <body> [--exec prog args...]
  local urgency=$1 glyph=$2 headline=$3 body=$4
  shift 4
  command -v omarchy-notification-send >/dev/null 2>&1 || return 0
  omarchy-notification-send --app-name "$PAPERCLIP_WEBAPP_NAME" \
    -u "$urgency" -g "$glyph" "$headline" "$body" "$@"
}

pc_node_ok() {
  # Paperclip needs Node 24.11 or newer.
  local version major minor
  command -v node >/dev/null 2>&1 || return 1
  version=$(node --version 2>/dev/null)
  version=${version#v}
  major=${version%%.*}
  minor=${version#*.}
  minor=${minor%%.*}
  [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
  ((major > 24)) && return 0
  ((major == 24 && minor >= 11)) && return 0
  return 1
}

pc_say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
pc_warn() { printf '\033[33m==>\033[0m %s\n' "$*" >&2; }
pc_fail() { printf '\033[31m==>\033[0m %s\n' "$*" >&2; }
