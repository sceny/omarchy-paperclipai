#!/usr/bin/env bash
# The plugin's own checks for dev/regression, run in the candidate's tree after
# `dev/rig up` with SANDBOX_OUT set. Writes script/features.tsv and its evidence
# under $SANDBOX_OUT/script. Every row is measured here; none is assumed.

out="$SANDBOX_OUT/script"
mkdir -p "$out"
tsv="$out/features.tsv"
printf 'feature\trule\thow\tresult\tevidence\n' >"$tsv"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$tsv"; }

state="$work/state"
snooze="$state/omarchy/paperclipai/snooze.json"
fixture=test/fixtures/snooze-v0.2.0.json
mkdir -p "$(dirname "$snooze")"
cp "$fixture" "$snooze"
before=$(sha256sum "$snooze")

dev/rig exec -- env XDG_STATE_HOME="$state" bin/omarchy-paperclip-snooze get >"$out/snooze-get.out" 2>"$out/snooze-get.err"
get_status=$?
if [[ $get_status == 0 ]] && cmp -s "$out/snooze-get.out" "$fixture"; then
  read_back=pass
else
  read_back=fail
fi
row "Snooze from the live tag" "A state the live tag wrote reads back unchanged" \
  "snooze get on the v0.2.0 writer's file" "$read_back" "snooze-get.out"

dev/rig exec -- env XDG_STATE_HOME="$state" bin/omarchy-paperclip-snooze get >/dev/null 2>&1
after=$(sha256sum "$snooze")
if [[ $before == "$after" ]]; then unchanged=pass; else unchanged=fail; fi
row "Snooze read is not a write" "Reading the state writes nothing" \
  "file hash before and after two reads" "$unchanged" "snooze-get.out"

cold="$work/cold-home"
mkdir -p "$cold"
cold_env=(env HOME="$cold" XDG_CONFIG_HOME="$cold/.config" XDG_DATA_HOME="$cold/.local/share"
  XDG_STATE_HOME="$cold/.local/state" XDG_CACHE_HOME="$cold/.cache")
timeout 600 dev/rig exec -- "${cold_env[@]}" bin/omarchy-paperclip-setup --yes \
  --no-service --no-webapp --no-widget --no-skills </dev/null >"$out/setup.log" 2>&1
setup_status=$?
dev/rig exec -- "${cold_env[@]}" bin/omarchy-paperclip-snooze get >"$out/cold-snooze.out" 2>&1
if [[ $setup_status == 0 ]] && [[ $(cat "$out/cold-snooze.out") == '{"step":"","until":0,"focusUntil":0}' ]]; then
  cold_result=pass
else
  cold_result=fail
fi
row "Cold install" "A cold computer's setup finishes and reads no snooze as an error" \
  "setup --yes in an empty HOME, service, web app, widget and skills off" "$cold_result" "setup.log"

dev/rig exec -- dev/loaded-code >"$out/loaded-code.log" 2>&1
if (($? == 0)); then loaded=pass; else loaded=fail; fi
row "Panel runs the files" "The running shell has the plugin's IPC functions of the files" \
  "dev/loaded-code" "$loaded" "loaded-code.log"
