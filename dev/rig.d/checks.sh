#!/bin/bash
# The checks the rig runs. Sourced by dev/rig, never run directly.
#
# Every check captures its command, exit code and output into
# $RIG_EVIDENCE/<name>.log so a failure can be pasted into an issue without
# re-running anything. A check that cannot prove its thing fails; it never
# lowers its bar to pass.
#
# shellcheck shell=bash

RIG_CHECK_PASS=0
RIG_CHECK_FAIL=0
RIG_CHECK_NAMES=()
RIG_CHECK_RESULTS=()

rig_record() {
  # rig_record <name> <expected-exit> <command...>
  # Runs the command, writes the evidence, returns the command's exit code.
  local name=$1 expected=$2
  shift 2
  local log="$RIG_EVIDENCE/$name.log" status=0

  {
    printf '$ %s\n' "$*"
    printf -- '---\n'
  } >"$log"
  "$@" >>"$log" 2>&1 || status=$?
  printf -- '---\nexit=%s (expected %s)\n' "$status" "$expected" >>"$log"

  if [[ $status == "$expected" ]]; then
    rig_ok "$name (exit $status)"
    RIG_CHECK_PASS=$((RIG_CHECK_PASS + 1))
    RIG_CHECK_NAMES+=("$name")
    RIG_CHECK_RESULTS+=("pass exit=$status")
    return 0
  fi
  rig_fail "$name (exit $status, expected $expected) — see $log"
  tail -15 "$log" >&2
  RIG_CHECK_FAIL=$((RIG_CHECK_FAIL + 1))
  RIG_CHECK_NAMES+=("$name")
  RIG_CHECK_RESULTS+=("FAIL exit=$status expected=$expected")
  return 1
}

rig_record_settled() {
  # rig_record_settled <name> <expected-exit> <command...>
  # Like rig_record, for commands that talk to the shell right after an add or
  # remove. Omarchy's add/remove return once the shell has been asked to rescan
  # and reload the plugin, and for a moment after that the shell either does
  # not answer IPC ("not responding") or has not yet seen the plugin ("not
  # known"). Only those two answers are retried, for at most 30 seconds, and
  # every attempt stays in the evidence. Any other failure fails at once.
  local name=$1 expected=$2
  shift 2
  local log="$RIG_EVIDENCE/$name.log" status=0 attempt=1
  local deadline=$((SECONDS + 30))

  printf '$ %s\n---\n' "$*" >"$log"
  while :; do
    status=0
    local out
    out=$("$@" 2>&1) || status=$?
    printf '[attempt %s] exit=%s\n%s\n' "$attempt" "$status" "$out" >>"$log"
    [[ $status == "$expected" ]] && break
    [[ $out == *"omarchy-shell is not responding"* || $out == *"is not known"* ]] || break
    ((SECONDS < deadline)) || break
    attempt=$((attempt + 1))
    sleep 1
  done
  printf -- '---\nexit=%s (expected %s) after %s attempt(s)\n' "$status" "$expected" "$attempt" >>"$log"

  if [[ $status == "$expected" ]]; then
    rig_ok "$name (exit $status, $attempt attempt(s))"
    RIG_CHECK_PASS=$((RIG_CHECK_PASS + 1))
    RIG_CHECK_NAMES+=("$name")
    RIG_CHECK_RESULTS+=("pass exit=$status attempts=$attempt")
    return 0
  fi
  rig_fail "$name (exit $status, expected $expected) — see $log"
  tail -15 "$log" >&2
  RIG_CHECK_FAIL=$((RIG_CHECK_FAIL + 1))
  RIG_CHECK_NAMES+=("$name")
  RIG_CHECK_RESULTS+=("FAIL exit=$status expected=$expected")
  return 1
}

rig_assert() {
  # rig_assert <name> <message> <command...> — a condition, not a captured run.
  local name=$1 message=$2
  shift 2
  if "$@" >/dev/null 2>&1; then
    rig_ok "$name"
    RIG_CHECK_PASS=$((RIG_CHECK_PASS + 1))
    RIG_CHECK_NAMES+=("$name")
    RIG_CHECK_RESULTS+=("pass")
    return 0
  fi
  rig_fail "$name — $message"
  RIG_CHECK_FAIL=$((RIG_CHECK_FAIL + 1))
  RIG_CHECK_NAMES+=("$name")
  RIG_CHECK_RESULTS+=("FAIL $message")
  return 1
}

rig_assert_eventually() {
  # rig_assert_eventually <name> <seconds> <message> <command...>
  # For conditions the shell reaches asynchronously. `omarchy plugin add`
  # returns as soon as it has asked the shell to rescan, so "the shell lists
  # it" is true a moment later, not immediately.
  local name=$1 budget=$2 message=$3
  shift 3
  local deadline=$((SECONDS + budget))
  while ((SECONDS < deadline)); do
    if "$@" >/dev/null 2>&1; then
      rig_ok "$name"
      RIG_CHECK_PASS=$((RIG_CHECK_PASS + 1))
      RIG_CHECK_NAMES+=("$name")
      RIG_CHECK_RESULTS+=("pass")
      return 0
    fi
    sleep 0.5
  done
  rig_fail "$name — $message (still false after ${budget}s)"
  RIG_CHECK_FAIL=$((RIG_CHECK_FAIL + 1))
  RIG_CHECK_NAMES+=("$name")
  RIG_CHECK_RESULTS+=("FAIL $message")
  return 1
}

# ------------------------------------------------------------- the checks ----

rig_check_manifest() {
  rig_say "Manifest"
  rig_record manifest-validate 0 omarchy plugin validate "$RIG_PKG_REPO"
  rig_record manifest-id 0 bash -c \
    "jq -e --arg id '$RIG_PLUGIN_ID' '.id == \$id' '$RIG_PKG_REPO/manifest.json'"
}

rig_check_cold_install() {
  # Cold-start truth: nothing installed, nothing enabled, fresh config.
  rig_say "Cold install"
  rig_assert cold-start-empty "the plugin was already installed before the cold install" \
    bash -c "! test -e '$RIG_PLUGINS_DIR/$RIG_PLUGIN_ID'"

  rig_record cold-install 0 omarchy plugin add "file://$RIG_PKG_REPO" --yes
  rig_assert cold-install-landed "plugin directory missing after add" \
    test -d "$RIG_PLUGINS_DIR/$RIG_PLUGIN_ID"
  rig_assert_eventually cold-install-discovered 15 "the nested shell does not list the plugin" \
    bash -c "omarchy plugin list --json | jq -e --arg id '$RIG_PLUGIN_ID' 'any(.[]; .id == \$id)'"
  rig_record cold-install-list 0 omarchy plugin list
}

rig_check_repeat_install() {
  # Idempotent install: the second add must refuse, clearly, without damaging
  # the first one. Omarchy's own contract is "already installed; update it",
  # so a non-zero exit here is the correct behaviour.
  rig_say "Repeat install"
  rig_record repeat-install-refused 1 omarchy plugin add "file://$RIG_PKG_REPO" --yes
  rig_assert repeat-install-intact "the repeat add damaged the installed plugin" \
    test -f "$RIG_PLUGINS_DIR/$RIG_PLUGIN_ID/manifest.json"
  rig_assert repeat-install-no-staging "a staging directory leaked into the plugins dir" \
    bash -c "! compgen -G '$RIG_PLUGINS_DIR/.add.tmp.*' > /dev/null"
}

rig_check_enable() {
  rig_say "Enable"
  # The bar before the plugin is on it, kept for a human to compare against the
  # screenshot afterwards. Not asserted: the clock and toasts change on their own.
  rig_guard_nested_display
  RIG_GRIM_TIMEOUT=5 rig_grim "$RIG_EVIDENCE/nested-shell-before-enable.png" 2>/dev/null || true
  rig_record_settled enable 0 omarchy plugin enable "$RIG_PLUGIN_ID" "$RIG_BAR_SECTION"
  rig_assert enable-reported "the shell does not report the plugin as enabled" \
    bash -c "omarchy plugin list --json | jq -e --arg id '$RIG_PLUGIN_ID' 'any(.[]; .id == \$id and .enabled == true)'"
  rig_assert enable-in-config "shell.json does not place the plugin in the bar" \
    bash -c "jq -e --arg id '$RIG_PLUGIN_ID' '[.bar.layout[]?[]?] | any(. == \$id or (type == \"object\" and .id == \$id))' '$RIG_HOME/.config/omarchy/shell.json'"

  # A panel that will not load is the failure this rig exists to catch, and the
  # shell reports it on stderr rather than in the plugin list.
  rig_assert enable-no-load-failure "the shell logged a plugin load failure" \
    bash -c "! grep -iE 'pluginLoadFailed|Plugin .*failed to load|$RIG_PLUGIN_ID.*(error|Error)' '$RIG_LOGS/shell.log'"
  cp "$RIG_LOGS/shell.log" "$RIG_EVIDENCE/shell-after-enable.log" 2>/dev/null || true
}

rig_check_disable() {
  rig_say "Disable"
  rig_record disable 0 omarchy plugin disable "$RIG_PLUGIN_ID"
  rig_assert disable-reported "the shell still reports the plugin as enabled" \
    bash -c "omarchy plugin list --json | jq -e --arg id '$RIG_PLUGIN_ID' 'any(.[]; .id == \$id and .enabled == false)'"
  # Idempotent disable.
  rig_record disable-twice 0 omarchy plugin disable "$RIG_PLUGIN_ID"
  rig_assert disable-kept-files "disable removed the installed files" \
    test -f "$RIG_PLUGINS_DIR/$RIG_PLUGIN_ID/manifest.json"
  # And back on, so remove is exercised from the enabled state a user is in.
  rig_record_settled re-enable 0 omarchy plugin enable "$RIG_PLUGIN_ID" "$RIG_BAR_SECTION"
}

rig_check_remove() {
  rig_say "Remove"
  rig_record remove 0 omarchy plugin remove "$RIG_PLUGIN_ID" --yes
  rig_assert remove-gone "the plugin directory survived remove" \
    bash -c "! test -e '$RIG_PLUGINS_DIR/$RIG_PLUGIN_ID'"
  rig_assert_eventually remove-unlisted 15 "the shell still lists the removed plugin" \
    bash -c "! omarchy plugin list --json | jq -e --arg id '$RIG_PLUGIN_ID' 'any(.[]; .id == \$id)'"
  # Idempotent remove: a second one must refuse, not crash or delete something
  # else.
  rig_record remove-twice-refused 1 omarchy plugin remove "$RIG_PLUGIN_ID" --yes
  # And reinstall after remove, because an upgrade is a remove plus an add.
  rig_record reinstall-after-remove 0 omarchy plugin add "file://$RIG_PKG_REPO" --yes
  rig_record_settled reinstall-enable 0 omarchy plugin enable "$RIG_PLUGIN_ID" "$RIG_BAR_SECTION"
}

rig_check_screenshot() {
  rig_say "Screenshot"
  rig_guard_nested_display
  local out="$RIG_EVIDENCE/nested-shell.png"
  # Let the bar settle: the widget's first poll is what puts content in it.
  sleep 6
  # rig_grim_wait retries the "no wl_output" start-up answer, and gives up with
  # an explanation when grim gets no frame at all.
  if rig_record screenshot 0 rig_grim_wait "$out"; then
    rig_assert screenshot-not-empty "grim produced an empty file" \
      bash -c "test -s '$out'"
    rig_step "screenshot: $out"
  fi
}

rig_check_host_untouched() {
  # The hard rules, as a check rather than a promise. Each of these would be a
  # defect in the rig, not in the plugin.
  rig_say "Host isolation"
  rig_assert host-config-untouched "the rig wrote into the owner's plugin directory" \
    bash -c "! test -e '$RIG_HOST_CONFIG_HOME/omarchy/plugins/$RIG_PLUGIN_ID'"
  rig_assert host-shell-alive "the owner's Omarchy shell is no longer running" \
    bash -c "pgrep -u \"\$(id -u)\" -f 'quickshell.*-p ' | grep -qv '^$RIG_SHELL_PID\$'"
  rig_assert host-systemd-unreachable "the sandbox can still reach the owner's user units" \
    bash -c "! systemctl --user show paperclipai.service --property=LoadState >/dev/null 2>&1"
  rig_assert host-paperclip-untouched "the rig's data directory is not inside the sandbox" \
    bash -c "[[ '$RIG_PAPERCLIP_DATA' == '$RIG_HOME'/* ]]"
}

rig_no_rig_client_on_host() { [[ -z $(rig_host_rig_clients) ]]; }

rig_check_hidden() {
  # The default view must leave no trace on the owner's desktop. The hard part
  # is asserted; whether the desktop is byte-for-byte the same is reported,
  # because the owner may be using it while the rig runs.
  rig_say "Hidden view"
  if [[ $RIG_VIEW == hidden ]]; then
    rig_assert hidden-no-host-window "a window of the rig is on the owner's desktop" \
      rig_no_rig_client_on_host
  else
    rig_warn "the rig is visible on request; the hidden checks do not apply"
  fi

  local before="$RIG_EVIDENCE/host-before.json" after="$RIG_EVIDENCE/host-after-check.json" diff_out
  if [[ ! -s $before ]] || ! jq -e '.available' "$before" >/dev/null 2>&1; then
    rig_warn "no desktop session to compare against (CI or SSH login); host snapshot skipped"
    return 0
  fi
  rig_host_snapshot "$after" || true
  if diff_out=$(rig_host_compare "$before" "$after"); then
    rig_ok "the owner's windows, workspaces and focus are as they were"
  else
    rig_warn "the owner's desktop differs from before the rig came up (the owner may have been using it):"
    printf '%s\n' "$diff_out" >&2
    printf '%s\n' "$diff_out" >"$RIG_EVIDENCE/host-diff.txt"
  fi
}

rig_check_shell_services_off() {
  # The nested shell must not run its own idle/lock services: a lock inside the
  # rig covers the window and ends the run.
  rig_say "Shell services"
  local id
  for id in "${RIG_SHELL_DISABLED_PLUGINS[@]}"; do
    rig_record "service-off-$id" 0 bash -c \
      "omarchy plugin list --json | jq -e --arg id '$id' 'any(.[]; .id == \$id and .enabled == false)'"
  done
}

rig_check_lease() {
  rig_say "Lease"
  local keeper
  keeper=$(<"$RIG_SESSION/keeper.pid") 2>/dev/null || keeper=""
  rig_assert lease-keeper-alive "no live lease keeper for this rig" \
    bash -c "[[ -n '$keeper' ]] && kill -0 '$keeper'"
  rig_assert lease-state-live "the rig's own lease is not live" \
    rig_lease_is_live
  rig_assert lease-ports-unique "another rig reserved one of this rig's ports" \
    rig_ports_are_unique
  rig_assert lease-runtime-dir-own "the runtime dir is shared with another rig" \
    bash -c "[[ '$RIG_RUNTIME_DIR' == '$RIG_RUNTIME_ROOT'/opr.* ]]"
}

rig_lease_is_live() { [[ $(rig_lease_state "$RIG_SESSION") == live ]]; }

rig_ports_are_unique() {
  local dir mine=0 port
  for dir in $(rig_session_dirs); do
    [[ ${dir##*/} == "$RIG_ID" ]] && continue
    for port in http_port pg_port; do
      [[ $(rig_state_read "$dir/rig.state" "$port" 2>/dev/null) == "$RIG_HTTP_PORT" ||
        $(rig_state_read "$dir/rig.state" "$port" 2>/dev/null) == "$RIG_PG_PORT" ]] && mine=1
    done
  done
  ((mine == 0))
}

rig_check_plugin_scripts_up() {
  rig_say "Plugin scripts, instance up"
  rig_pc_assert_isolated
  local entry name index=0
  for entry in "${RIG_SMOKE_COMMANDS[@]}"; do
    index=$((index + 1))
    name=$(printf 'up-%02d-%s' "$index" "$(basename "${entry%% *}")")
    # shellcheck disable=SC2086 # the config line is a command with arguments
    rig_record "$name" 0 bash -c "cd '$RIG_PLUGIN_SRC_ABS' && $entry"
  done

  # -open must compute a URL and hand it to a launcher. The rig's recording
  # stub is what catches it, so assert the URL rather than the exit code.
  rig_assert open-targets-rig-instance "-open did not hand the rig URL to a launcher" \
    bash -c "grep -q 'http://127.0.0.1:$RIG_HTTP_PORT' '$RIG_STUB_LOG'"
  cp "$RIG_STUB_LOG" "$RIG_EVIDENCE/launcher-calls.log" 2>/dev/null || true

  # The refusal path: a url that is not http(s) must not reach a launcher.
  rig_record open-refuses-non-http 1 bash -c \
    "cd '$RIG_PLUGIN_SRC_ABS' && bin/omarchy-paperclip-open file:///etc/passwd"

  # The web app launcher the plugin creates must land in the sandbox.
  rig_assert webapp-in-sandbox "the web app launcher is not in the sandbox" \
    bash -c "compgen -G '$RIG_HOME/.local/share/applications/*.desktop' > /dev/null"
  rig_record webapp-remove 0 bash -c \
    "cd '$RIG_PLUGIN_SRC_ABS' && bin/omarchy-paperclip-webapp remove"
}

rig_check_plugin_scripts_down() {
  # The path that actually breaks: the instance is gone and the scripts have to
  # say so instead of hanging or dying.
  rig_say "Plugin scripts, instance down"
  rig_pc_stop
  rig_assert down-confirmed "the instance is still answering" \
    bash -c "! curl -fsS --max-time 3 '$(rig_pc_api_base)/api/health' >/dev/null 2>&1"

  local entry name index=0
  for entry in "${RIG_SMOKE_COMMANDS_DOWN[@]}"; do
    index=$((index + 1))
    name=$(printf 'down-%02d-%s' "$index" "$(basename "${entry%% *}")")
    rig_record "$name" 0 bash -c "cd '$RIG_PLUGIN_SRC_ABS' && timeout 120 $entry"
  done

  rig_assert down-status-says-down "-status does not report a down instance" \
    bash -c "cd '$RIG_PLUGIN_SRC_ABS' && bin/omarchy-paperclip-status --compact | jq -e '.state != \"ok\" and .state != null'"

  # `-service start` has no systemd and no terminal in here, so it must fail
  # loudly rather than silently claiming success.
  rig_record down-service-start-fails 1 bash -c \
    "cd '$RIG_PLUGIN_SRC_ABS' && timeout 180 bin/omarchy-paperclip-service start"

  rig_pc_start
  rig_assert back-up "the instance did not come back after the down check" \
    rig_pc_healthy
}

rig_check_summary() {
  local index=0
  rig_say "Results"
  for index in "${!RIG_CHECK_NAMES[@]}"; do
    printf '  %-34s %s\n' "${RIG_CHECK_NAMES[$index]}" "${RIG_CHECK_RESULTS[$index]}" >&2
  done
  printf '\n' >&2
  if ((RIG_CHECK_FAIL)); then
    rig_fail "$RIG_CHECK_PASS passed, $RIG_CHECK_FAIL failed"
    return 1
  fi
  rig_ok "$RIG_CHECK_PASS passed, 0 failed"
  return 0
}

rig_write_summary_file() {
  local out="$RIG_EVIDENCE/summary.txt" index
  {
    printf 'rig summary for %s\n' "$RIG_PLUGIN_ID"
    printf 'view=%s http_port=%s pg_port=%s instance=%s\n' \
      "$RIG_VIEW" "$RIG_HTTP_PORT" "$RIG_PG_PORT" "$RIG_INSTANCE_ID"
    printf 'omarchy=%s\n\n' "$RIG_OMARCHY_PATH"
    for index in "${!RIG_CHECK_NAMES[@]}"; do
      printf '%-34s %s\n' "${RIG_CHECK_NAMES[$index]}" "${RIG_CHECK_RESULTS[$index]}"
    done
    printf '\n%s passed, %s failed\n' "$RIG_CHECK_PASS" "$RIG_CHECK_FAIL"
  } >"$out"
}
