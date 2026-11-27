#!/usr/bin/env bash
# The plugin's own checks for dev/regression, run in the candidate's tree after
# `dev/rig up` with SANDBOX_OUT set. Writes $SANDBOX_OUT/features.tsv and each
# row's evidence beside it. Every row is measured here; none is assumed.
# `dev/regression.sh --self-check` runs the verdicts on planted states, without a rig.

set -u

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

fixture=test/fixtures/snooze-v0.2.0.json

# verdict_read_back GET OUT: pass when GET prints the fixture's exact bytes.
verdict_read_back() {
  local get=$1 out=$2
  if "$get" >"$out" 2>"$out.err" && [[ $(sha256sum <"$out") == "$(sha256sum <"$fixture")" ]]; then
    echo pass
  else
    echo fail
  fi
}

# verdict_read_only GET STATE: pass when two reads leave STATE's bytes unchanged.
verdict_read_only() {
  local get=$1 state_file=$2 before
  before=$(sha256sum <"$state_file")
  if "$get" >/dev/null 2>&1 && "$get" >/dev/null 2>&1 &&
    [[ -n $before && $before == "$(sha256sum <"$state_file")" ]]; then
    echo pass
  else
    echo fail
  fi
}

self_check() {
  local state_file="$work/self/omarchy/paperclipai/snooze.json" bad=0
  mkdir -p "$(dirname "$state_file")"

  changed_get() { jq '.until += 1' "$fixture"; }
  rewriting_get() { printf ' ' >>"$state_file"; cat "$fixture"; }
  reading_get() { cat "$fixture"; }
  expect() {
    if [[ $2 == "$1" ]]; then
      echo "ok     $3"
    else
      echo "WRONG  $3: want $1, got $2" >&2
      bad=1
    fi
  }

  cp "$fixture" "$state_file"
  expect fail "$(verdict_read_back changed_get "$work/changed.out")" "a changed value fails read back"
  expect pass "$(verdict_read_back reading_get "$work/read.out")" "the fixture passes read back"
  expect fail "$(verdict_read_only rewriting_get "$state_file")" "a read that rewrites the file fails read only"
  cp "$fixture" "$state_file"
  expect pass "$(verdict_read_only reading_get "$state_file")" "a read that writes nothing passes read only"
  return "$bad"
}

if [[ ${1:-} == --self-check ]]; then
  self_check
  exit $?
fi

OUT_DIR="${SANDBOX_OUT:?SANDBOX_OUT is set by dev/sandbox run}"
mkdir -p "$OUT_DIR"
TSV="$OUT_DIR/features.tsv"
printf 'feature\trule\thow\tresult\tevidence\n' >"$TSV"

failed=0

# The sandbox brings the rig up with no owner, so the rig is found by its id.
RIG_SELECT=$(dev/rig ps --json | jq -r '.rigs[0].id') || exit 1
[[ -n $RIG_SELECT && $RIG_SELECT != null ]] || { echo "no rig is up" >&2; exit 1; }
export RIG_SELECT

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$TSV"; }

state="$work/state"
snooze="$state/omarchy/paperclipai/snooze.json"
mkdir -p "$(dirname "$snooze")"
cp "$fixture" "$snooze"

snooze_get() {
  dev/rig exec -- env XDG_STATE_HOME="$state" bin/omarchy-paperclip-snooze get
}

read_back=$(verdict_read_back snooze_get "$OUT_DIR/snooze-get.out")
[[ $read_back == pass ]] || failed=1
row "Snooze from the v0.2.0 fixture" "A state the v0.2.0 writer wrote reads back unchanged" \
  "snooze get on the v0.2.0 writer's file (test/fixtures)" "$read_back" "snooze-get.out"

unchanged=$(verdict_read_only snooze_get "$snooze")
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

# The rig's own HOME and state directory, where its shell installs and writes.
installed="$(dev/rig exec -- printenv HOME)/.config/omarchy/plugins/sceny.paperclipai"
version_of() { jq -r '.version // empty' "$1/manifest.json" 2>/dev/null; }

# The upgrade a user makes: the live tag installed as a user installs it, its
# own panel writing its state, then `omarchy plugin update` to the candidate.
# SANDBOX_BASE is the live tag's tree (`dev/sandbox run --base`, which
# dev/regression passes when dev/regression.json asks for it).
if [[ -n ${SANDBOX_BASE:-} && -f $SANDBOX_BASE/manifest.json ]]; then
  base_version=$(version_of "$SANDBOX_BASE")
  base_name="v$base_version (${SANDBOX_BASE_SHA:0:12})"
  live_state="$(dev/rig exec -- printenv XDG_STATE_HOME)/omarchy/paperclipai/snooze.json"

  live_install=pass
  {
    [[ ! -e $live_state ]] || { echo "a snooze state is there before the install: $live_state"; false; }
  } >"$OUT_DIR/live-install.log" 2>&1 || live_install=fail
  dev/rig install --tree "$SANDBOX_BASE" >>"$OUT_DIR/live-install.log" 2>&1 || live_install=fail
  dev/rig restart-shell >>"$OUT_DIR/live-install.log" 2>&1 || live_install=fail
  [[ -n $base_version && $(version_of "$installed") == "$base_version" ]] || live_install=fail
  [[ $live_install == pass ]] || failed=1
  row "Live tag installs" "The live tag installs as a user installs it and is on the bar" \
    "dev/rig install --tree with $base_name, restart the shell, the installed manifest is its version" \
    "$live_install" "live-install.log"

  # The live tag's own panel writes the state, through its own IPC and writer.
  live_write=fail
  mode=$(dev/rig exec -- timeout 5 omarchy-shell paperclip snooze 2>"$OUT_DIR/live-snooze.err")
  for _ in $(seq 20); do [[ -s $live_state ]] && break; sleep 0.5; done
  cp "$live_state" "$OUT_DIR/live-snooze.json" 2>/dev/null
  if [[ $mode == plugin ]] && jq -e '.step == "1h" and .until > 0' "$live_state" >/dev/null 2>&1; then
    live_write=pass
  fi
  [[ $live_write == pass ]] || failed=1
  row "Live tag writes its state" "The live tag's panel snoozes and its writer keeps the state" \
    "omarchy-shell paperclip snooze on $base_name: mode '$mode', snooze.json a one-hour snooze" \
    "$live_write" "live-snooze.json"
  before=$(sha256sum <"$live_state" 2>/dev/null)

  upgrade=pass
  dev/rig upgrade >"$OUT_DIR/upgrade.log" 2>&1 || upgrade=fail
  dev/rig restart-shell >>"$OUT_DIR/upgrade.log" 2>&1 || upgrade=fail
  [[ $(version_of "$installed") == "$(version_of .)" ]] || upgrade=fail
  [[ $upgrade == pass ]] || failed=1
  row "Upgrade from the live tag" "omarchy plugin update takes the live tag's install to the candidate" \
    "dev/rig upgrade from $base_name (the candidate as the package's next commit, omarchy plugin update --yes), restart the shell, the installed manifest is the candidate's version" \
    "$upgrade" "upgrade.log"

  kept=fail
  [[ -n $before && $before == "$(sha256sum <"$live_state" 2>/dev/null)" ]] && kept=pass
  [[ $kept == pass ]] || failed=1
  row "Upgrade keeps the state" "The upgrade and the candidate's start leave the live tag's state as it was" \
    "snooze.json's hash before the upgrade and after the shell restart" "$kept" "live-snooze.json"

  # Focus with Omarchy awake only answers the mode and writes nothing, so it is
  # asked until the candidate's panel has read the state at its start.
  read_state=fail
  dev/rig exec -- "$installed/bin/omarchy-paperclip-snooze" get >"$OUT_DIR/upgrade-snooze-get.out" 2>"$OUT_DIR/upgrade-snooze-get.err"
  mode=""
  for _ in $(seq 15); do
    mode=$(dev/rig exec -- timeout 5 omarchy-shell paperclip focus 2>/dev/null)
    [[ $mode == plugin ]] && break
    sleep 1
  done
  printf 'panel mode: %s\n' "$mode" >>"$OUT_DIR/upgrade-snooze-get.out"
  if [[ $(head -1 "$OUT_DIR/upgrade-snooze-get.out") == "$(jq -c . "$OUT_DIR/live-snooze.json" 2>/dev/null)" ]] &&
    [[ $mode == plugin && $before == "$(sha256sum <"$live_state" 2>/dev/null)" ]]; then
    read_state=pass
  fi
  [[ $read_state == pass ]] || failed=1
  row "Candidate reads the live tag's state" "The upgraded writer and panel read the snooze the live tag wrote, and write nothing" \
    "the installed snooze get prints the live tag's file; the panel's mode is 'plugin'; the hash is unchanged" \
    "$read_state" "upgrade-snooze-get.out"
else
  failed=1
  row "Upgrade from the live tag" "omarchy plugin update takes the live tag's install to the candidate" \
    "needs the live tag's tree in SANDBOX_BASE (dev/sandbox run --base)" "fail" "features.tsv"

  install_result=pass
  dev/rig install >"$OUT_DIR/install.log" 2>&1 || install_result=fail
  dev/rig restart-shell >>"$OUT_DIR/install.log" 2>&1 || install_result=fail
  [[ $install_result == pass ]] || failed=1
  row "Plugin installs and enables" "The plugin is added and on the bar in the rig" \
    "dev/rig install, then restart the shell" "$install_result" "install.log"
fi

loaded=pass
dev/rig exec -- dev/loaded-code "$installed" >"$OUT_DIR/loaded-code.log" 2>&1 || loaded=fail
[[ $loaded == pass ]] || failed=1
row "Panel runs the files" "The running shell has the IPC functions of the installed plugin's files" \
  "dev/loaded-code on the installed folder" "$loaded" "loaded-code.log"

exit "$failed"
