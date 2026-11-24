#!/usr/bin/env bash
# The plugin's own checks for dev/regression, run in the candidate's tree after
# `dev/rig up` with SANDBOX_OUT set. Writes $SANDBOX_OUT/features.tsv and each
# row's evidence beside it. Every row is measured here; none is assumed.

set -u

OUT_DIR="${SANDBOX_OUT:?SANDBOX_OUT is set by dev/sandbox run}"
mkdir -p "$OUT_DIR"
TSV="$OUT_DIR/features.tsv"
printf 'feature\trule\thow\tresult\tevidence\n' >"$TSV"
work=$(mktemp -d)
cold_pid=""

stop_cold() {
  if [[ -n $cold_pid ]]; then
    kill -TERM -- "-$cold_pid" 2>/dev/null
    wait "$cold_pid" 2>/dev/null
    cold_pid=""
  fi
}
cleanup() {
  stop_cold
  rm -rf "$work"
}
trap cleanup EXIT

failed=0

# The sandbox brings the rig up with no owner, so the rig is found by its id.
RIG_SELECT=$(dev/rig ps --json | jq -r '.rigs[0].id') || exit 1
[[ -n $RIG_SELECT && $RIG_SELECT != null ]] || { echo "no rig is up" >&2; exit 1; }
export RIG_SELECT

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$TSV"; }

state="$work/state"
snooze="$state/omarchy/paperclipai/snooze.json"
fixture=test/fixtures/snooze-v0.2.0.json
mkdir -p "$(dirname "$snooze")"
cp "$fixture" "$snooze"

snooze_get() {
  dev/rig exec -- env XDG_STATE_HOME="$state" bin/omarchy-paperclip-snooze get
}

read_back=fail
if snooze_get >"$OUT_DIR/snooze-get.out" 2>"$OUT_DIR/snooze-get.err" &&
  [[ $(sha256sum <"$OUT_DIR/snooze-get.out") == "$(sha256sum <"$fixture")" ]]; then
  read_back=pass
fi
[[ $read_back == pass ]] || failed=1
row "Snooze from the live tag" "A state the live tag wrote reads back unchanged" \
  "snooze get on the v0.2.0 writer's file" "$read_back" "snooze-get.out"

before=$(sha256sum <"$snooze")
unchanged=fail
if snooze_get >/dev/null 2>&1 && snooze_get >/dev/null 2>&1 &&
  [[ -n $before && $before == "$(sha256sum <"$snooze")" ]]; then
  unchanged=pass
fi
[[ $unchanged == pass ]] || failed=1
row "Snooze read is not a write" "Reading the state writes nothing" \
  "the file's hash before and after two reads" "$unchanged" "snooze-get.out"

# A known-bad state: the comparison above must tell it apart from the fixture,
# or the rows before it prove nothing.
planted="$work/planted"
mkdir -p "$planted/omarchy/paperclipai"
jq '.until += 1' "$fixture" >"$planted/omarchy/paperclipai/snooze.json"
caught=fail
if dev/rig exec -- env XDG_STATE_HOME="$planted" bin/omarchy-paperclip-snooze get \
  >"$OUT_DIR/planted-snooze.out" 2>"$OUT_DIR/planted-snooze.err" &&
  [[ $(sha256sum <"$OUT_DIR/planted-snooze.out") != "$(sha256sum <"$fixture")" ]]; then
  caught=pass
fi
[[ $caught == pass ]] || failed=1
row "Planted failure is caught" "A state with one value changed does not read back as the fixture" \
  "snooze get on the v0.2.0 file with until plus one, compared with the fixture" "$caught" "planted-snooze.out"

# Setup runs the server in the foreground under --no-service, so it is started
# in its own process group and stopped once its health answers.
cold="$work/cold-home"
mkdir -p "$cold"
cold_env=(env HOME="$cold" XDG_CONFIG_HOME="$cold/.config" XDG_DATA_HOME="$cold/.local/share"
  XDG_STATE_HOME="$cold/.local/state" XDG_CACHE_HOME="$cold/.cache")
set -m
dev/rig exec -- "${cold_env[@]}" bin/omarchy-paperclip-setup --yes \
  --no-service --no-webapp --no-widget --no-skills </dev/null >"$OUT_DIR/setup.log" 2>&1 &
cold_pid=$!
set +m

cold_port() { jq -r '.server.port // empty' "$cold"/.paperclip/instances/*/config.json 2>/dev/null; }
healthy=0
deadline=$((SECONDS + 600))
while ((SECONDS < deadline)) && kill -0 "$cold_pid" 2>/dev/null; do
  port=$(cold_port)
  if [[ -n $port ]] && curl -fsS --max-time 4 "http://127.0.0.1:$port/api/health" 2>/dev/null |
    jq -e '.status == "ok"' >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
stop_cold

cold_snooze=fail
if dev/rig exec -- "${cold_env[@]}" bin/omarchy-paperclip-snooze get \
  >"$OUT_DIR/cold-snooze.out" 2>"$OUT_DIR/cold-snooze.err" &&
  [[ $(cat "$OUT_DIR/cold-snooze.out") == '{"step":"","until":0,"focusUntil":0}' ]]; then
  cold_snooze=pass
fi
cold_result=fail
if ((healthy == 1)) && [[ $cold_snooze == pass ]]; then cold_result=pass; fi
[[ $cold_result == pass ]] || failed=1
row "Cold install" "A cold computer's setup brings Paperclip up and reads no snooze as an error" \
  "setup --yes in an empty HOME, service, web app, widget and skills off; health answers before it is stopped" \
  "$cold_result" "setup.log"

install_result=pass
dev/rig install >"$OUT_DIR/install.log" 2>&1 || install_result=fail
dev/rig restart-shell >>"$OUT_DIR/install.log" 2>&1 || install_result=fail
[[ $install_result == pass ]] || failed=1
row "Plugin installs and enables" "The plugin is added and on the bar in the rig" \
  "dev/rig install, then restart the shell" "$install_result" "install.log"

loaded=pass
dev/rig exec -- dev/loaded-code . >"$OUT_DIR/loaded-code.log" 2>&1 || loaded=fail
[[ $loaded == pass ]] || failed=1
row "Panel runs the files" "The running shell has the plugin's IPC functions of the files" \
  "dev/loaded-code" "$loaded" "loaded-code.log"

exit "$failed"
