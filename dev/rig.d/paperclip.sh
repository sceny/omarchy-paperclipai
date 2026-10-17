#!/bin/bash
# The throwaway Paperclip instance the rig tests against.
# Sourced by dev/rig, never run directly.
#
# Only loaded when RIG_NEEDS_PAPERCLIP=1 in dev/rig.conf, so a plugin that does
# not talk to Paperclip pays nothing for this file.
#
# shellcheck shell=bash

rig_pc_cli() {
  # Whatever can run the Paperclip CLI, preferring a real binary. Resolved
  # against the *host* PATH on purpose: the CLI is a tool the rig uses, not a
  # thing under test, and a fresh HOME has no npm cache to install into.
  if [[ -n ${RIG_PAPERCLIP_CLI:-} ]]; then
    printf '%s\n' "$RIG_PAPERCLIP_CLI"
  elif command -v paperclipai >/dev/null 2>&1; then
    command -v paperclipai
  elif [[ -x $RIG_HOST_HOME/.local/bin/paperclipai ]]; then
    printf '%s\n' "$RIG_HOST_HOME/.local/bin/paperclipai"
  else
    return 1
  fi
}

rig_pc_instance_dir() {
  printf '%s/instances/%s\n' "$RIG_PAPERCLIP_DATA" "$RIG_INSTANCE_ID"
}

rig_pc_write_config() {
  # Write a complete, valid config BEFORE anything can start a server.
  #
  # This ordering is the whole safety story. `paperclipai onboard -y` and
  # `paperclipai run` both bring a server up as part of bootstrapping, and a
  # config they generate themselves defaults to port 3100 and embedded
  # Postgres 54329 — the owner's live ports. Seeding the config first means the
  # rig never opens a window in which it could bind them.
  local dir
  dir=$(rig_pc_instance_dir)
  mkdir -p "$dir"
  jq -n \
    --argjson http "$RIG_HTTP_PORT" \
    --argjson pg "$RIG_PG_PORT" \
    --arg dir "$dir" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{
      "$meta": { version: 1, updatedAt: $now, source: "onboard" },
      database: {
        mode: "embedded-postgres",
        embeddedPostgresDataDir: ($dir + "/db"),
        embeddedPostgresPort: $pg,
        backup: { enabled: false, intervalMinutes: 60, retentionDays: 1, dir: ($dir + "/data/backups") }
      },
      logging: { mode: "file", logDir: ($dir + "/logs") },
      server: {
        deploymentMode: "local_trusted",
        exposure: "private",
        bind: "loopback",
        host: "127.0.0.1",
        port: $http,
        allowedHostnames: [],
        serveUi: true
      },
      telemetry: { enabled: false },
      updates: { checkEnabled: false },
      auth: { baseUrlMode: "auto", disableSignUp: false },
      storage: {
        provider: "local_disk",
        localDisk: { baseDir: ($dir + "/data/storage") },
        s3: { bucket: "paperclip", region: "us-east-1", prefix: "", forcePathStyle: false }
      },
      secrets: {
        provider: "local_encrypted",
        strictMode: false,
        localEncrypted: { keyFilePath: ($dir + "/secrets/master.key") }
      }
    }' >"$dir/config.json"

  # Belt and braces: assert on disk what the guard assumes in memory.
  local on_disk_http on_disk_pg
  on_disk_http=$(jq -r '.server.port' "$dir/config.json")
  on_disk_pg=$(jq -r '.database.embeddedPostgresPort' "$dir/config.json")
  [[ $on_disk_http == "$RIG_HTTP_PORT" && $on_disk_pg == "$RIG_PG_PORT" ]] ||
    rig_die "the seeded config does not carry the rig ports"
  rig_ok "instance config seeded: http $RIG_HTTP_PORT, postgres $RIG_PG_PORT"
}

rig_pc_api_base() {
  printf 'http://127.0.0.1:%s\n' "$RIG_HTTP_PORT"
}

rig_pc_healthy() {
  curl -fsS --max-time 4 "$(rig_pc_api_base)/api/health" 2>/dev/null |
    jq -e '.status == "ok"' >/dev/null 2>&1
}

rig_pc_start() {
  rig_pc_healthy && {
    rig_ok "throwaway instance already answering on $(rig_pc_api_base)"
    return 0
  }

  local cli log
  cli=$(rig_pc_cli) || rig_die "no Paperclip CLI on PATH; install it or set RIG_PAPERCLIP_CLI"
  log="$RIG_LOGS/instance.log"

  rig_step "starting the throwaway instance ($cli run)"
  # PORT is belt to the config's braces: if anything ever regenerates the
  # config, the listen port still cannot fall back to the owner's 3100.
  # nohup rather than setsid: nohup execs, so $! is the instance itself and
  # teardown has a pid it can actually kill. setsid forks and hands back the
  # wrong one.
  (cd "$RIG_SESSION" && PORT="$RIG_HTTP_PORT" exec nohup \
    "$cli" run -d "$RIG_PAPERCLIP_DATA" -i "$RIG_INSTANCE_ID" >>"$log" 2>&1) &
  RIG_INSTANCE_PID=$!
  rig_state_set instance_pid "$RIG_INSTANCE_PID"

  local deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    kill -0 "$RIG_INSTANCE_PID" 2>/dev/null || {
      rig_fail "the throwaway instance exited; last lines of $log:"
      tail -20 "$log" >&2
      rig_die "instance did not start"
    }
    rig_pc_healthy && {
      rig_ok "throwaway instance answering on $(rig_pc_api_base) (pid $RIG_INSTANCE_PID)"
      return 0
    }
    sleep 3
  done
  rig_fail "no health after 180s; last lines of $log:"
  tail -20 "$log" >&2
  rig_die "instance never became healthy"
}

rig_pc_stop() {
  # Used by the instance-is-down check as well as teardown, so it has to leave
  # the data directory intact and restartable.
  [[ -n ${RIG_INSTANCE_PID:-} ]] || return 0
  rig_step "stopping the throwaway instance (pid $RIG_INSTANCE_PID)"
  rig_kill_tree "$RIG_INSTANCE_PID" TERM
  rig_wait_gone "$RIG_INSTANCE_PID" 30 || rig_kill_tree "$RIG_INSTANCE_PID" KILL
  rig_wait_gone "$RIG_INSTANCE_PID" 10 || true

  local pg
  for pg in $(pgrep -f -- "-D $RIG_PAPERCLIP_DATA" 2>/dev/null); do
    kill -TERM "$pg" 2>/dev/null || true
    rig_wait_gone "$pg" 15 || kill -KILL "$pg" 2>/dev/null || true
  done

  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    rig_pc_healthy || {
      rig_ok "throwaway instance is down"
      RIG_INSTANCE_PID=""
      rig_state_set instance_pid ""
      return 0
    }
    sleep 1
  done
  rig_die "the throwaway instance is still answering after a stop"
}

rig_pc_assert_isolated() {
  # Cold-start truth, and the hard rule in one check: the instance the plugin
  # is about to talk to must be ours, and the owner's must be untouched.
  local base dir
  base=$(rig_pc_api_base)
  dir=$(rig_pc_instance_dir)

  [[ $base != "http://127.0.0.1:3100" ]] ||
    rig_die "guard: the rig API base is the owner's instance"
  [[ $dir == "$RIG_HOME"/* ]] ||
    rig_die "guard: the rig instance directory is outside the sandbox"

  # The plugin resolves its own API base. Make it prove it lands on ours.
  local resolved
  resolved=$(python3 "$RIG_PLUGIN_SRC_ABS/bin/omarchy-paperclip-status" \
    --compact 2>/dev/null | jq -r '.apiBase // empty')
  [[ $resolved == "$base" ]] ||
    rig_die "guard: the plugin resolved '$resolved', not the rig's '$base'"
  rig_ok "the plugin resolves the rig instance ($resolved)"
}

# ------------------------------------------------------------------ seed ----
#
# A busy panel in the throwaway instance: RIG_SEED_WORKERS agents with a live
# run each (the "working" card and the agent list) and at least
# RIG_SEED_MIN_ROWS inbox rows (a two-digit bar bubble and a scrolling list),
# with every kind a panel check needs: failed_run, review,
# issue_thread_interaction, blocker_attention (and the agent_error_alert a
# failed agent brings with it). Everything goes through the
# instance's own API except one row: the inbox lists a failed run only after a
# "Bounded retry exhausted" lifecycle event, which the server writes after
# several scheduled retries, far longer than a check can wait. That event is
# inserted into the rig's own Postgres, on the rig's own port.

RIG_SEED_COMPANY="Rig Co"
RIG_SEED_AGENT="Rig Runner"
# Agents that run for as long as the rig lives, so the panel has live runs.
RIG_SEED_WORKERS=(
  "Rig Worker One|Rig: long-running task one"
  "Rig Worker Two|Rig: long-running task two"
)
# Open items of each kind, on top of the one failed run: 4 blocked + 4 review
# + 4 questions + the failed run and its agent alert is at least 13 rows.
RIG_SEED_PER_KIND=4
RIG_SEED_MIN_ROWS=10

rig_pc_api() {
  # rig_pc_api <METHOD> <path> [json-body] — the body on stdout, failure on HTTP errors.
  local method=$1 path=$2 body=${3:-}
  local args=(-fsS --max-time 30 -X "$method" -H "Origin: $(rig_pc_api_base)")
  [[ -n $body ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$(rig_pc_api_base)$path"
}

rig_seed_issue() {
  # rig_seed_issue <company-id> <title> <json-fields> — the issue id, created once.
  local company=$1 title=$2 fields=$3 id
  id=$(rig_pc_api GET "/api/companies/$company/issues?limit=100" |
    jq -r --arg t "$title" '[.[] | select(.title == $t)][0].id // empty') || return 1
  if [[ -z $id ]]; then
    id=$(rig_pc_api POST "/api/companies/$company/issues" \
      "$(jq -nc --arg t "$title" --argjson f "$fields" '{title: $t} + $f')" | jq -r '.id') || return 1
  fi
  printf '%s\n' "$id"
}

rig_pc_live_runs() {
  rig_pc_api GET "/api/companies/$1/heartbeat-runs?limit=40" |
    jq -r '[.[] | select(.status == "running")] | length'
}

rig_pc_seed_workers() {
  # Each worker is a process agent that sleeps for an hour, so its run is live
  # for as long as the rig is. Assigning its task wakes it. A task that
  # already has a live run is left alone, which keeps a second seed quiet.
  local company=$1 spec name title agent task
  for spec in "${RIG_SEED_WORKERS[@]}"; do
    name=${spec%%|*}
    title=${spec#*|}
    agent=$(rig_pc_api GET "/api/companies/$company/agents" | jq -r --arg n "$name" '[.[] | select(.name == $n)][0].id // empty') ||
      rig_die "seed: could not list agents"
    [[ -n $agent ]] ||
      agent=$(rig_pc_api POST "/api/companies/$company/agents" "$(jq -nc --arg n "$name" '{
        name: $n, role: "engineer", adapterType: "process",
        adapterConfig: {command: "sleep", args: ["3600"], timeoutSec: 0},
        runtimeConfig: {heartbeat: {enabled: false}}}')" | jq -r '.id') ||
      rig_die "seed: could not create agent $name"
    task=$(rig_seed_issue "$company" "$title" \
      "$(jq -nc --arg a "$agent" '{status: "todo", assigneeAgentId: $a}')") ||
      rig_die "seed: could not create task '$title'"
  done

  local deadline=$((SECONDS + 90))
  while ((SECONDS < deadline)); do
    (($(rig_pc_live_runs "$company") >= ${#RIG_SEED_WORKERS[@]})) && return 0
    sleep 2
  done
  rig_die "seed: the worker agents have no live run after 90s"
}

rig_pc_seed() {
  rig_pc_healthy || rig_die "seed: the throwaway instance is not answering on $(rig_pc_api_base)"
  rig_guard_ports
  command -v psql >/dev/null 2>&1 || rig_die "seed: psql is needed for the failed-run row (Arch: postgresql package)"

  local company agent task review blocked question
  rig_say "Seeding the throwaway instance at $(rig_pc_api_base)"

  company=$(rig_pc_api GET /api/companies | jq -r --arg n "$RIG_SEED_COMPANY" '[.[] | select(.name == $n)][0].id // empty') ||
    rig_die "seed: could not list companies"
  [[ -n $company ]] ||
    company=$(rig_pc_api POST /api/companies "$(jq -nc --arg n "$RIG_SEED_COMPANY" '{name: $n}')" | jq -r '.id') ||
    rig_die "seed: could not create the company"

  # `false` exits 1, so every run of this agent fails. Heartbeats stay off so
  # nothing else wakes it.
  agent=$(rig_pc_api GET "/api/companies/$company/agents" | jq -r --arg n "$RIG_SEED_AGENT" '[.[] | select(.name == $n)][0].id // empty') ||
    rig_die "seed: could not list agents"
  [[ -n $agent ]] ||
    agent=$(rig_pc_api POST "/api/companies/$company/agents" "$(jq -nc --arg n "$RIG_SEED_AGENT" '{
      name: $n, role: "engineer", adapterType: "process",
      adapterConfig: {command: "false"},
      runtimeConfig: {heartbeat: {enabled: false}}}')" | jq -r '.id') ||
    rig_die "seed: could not create the agent"

  # The failing task: assigning it wakes the agent and the run fails.
  task=$(rig_seed_issue "$company" "Rig: failing task" \
    "$(jq -nc --arg a "$agent" '{status: "todo", assigneeAgentId: $a}')") ||
    rig_die "seed: could not create the failing task"
  local n
  for ((n = 1; n <= RIG_SEED_PER_KIND; n++)); do
    blocked=$(rig_seed_issue "$company" "Rig: blocked on you $n" \
      '{"status":"blocked","unblockDescriptor":{"owner":"board","action":"Rig seed: pick the next step for this task."}}') ||
      rig_die "seed: could not create blocked task $n"
    review=$(rig_seed_issue "$company" "Rig: waiting for review $n" \
      '{"status":"in_review","assigneeUserId":"local-board"}') ||
      rig_die "seed: could not create review task $n"
    question=$(rig_seed_issue "$company" "Rig: needs an answer $n" \
      '{"status":"todo","assigneeUserId":"local-board"}') ||
      rig_die "seed: could not create question task $n"
    rig_pc_api POST "/api/issues/$question/interactions" "$(jq -nc --arg k "rig-seed:question:$n" --arg p "Rig question $n: which option?" '{
      kind: "ask_user_questions", idempotencyKey: $k, continuationPolicy: "none",
      payload: {version: 1,
        questionSet: {schema: "paperclip.question_set.v1", questions: [
          {id: "detail", prompt: $p, answerMode: "text", required: true}]},
        questions: [{id: "detail", prompt: $p, selectionMode: "single",
          required: true, options: [{id: "text", label: "Your answer", freeText: true}]}]}}')" >/dev/null ||
      rig_die "seed: could not create interaction $n"
  done

  rig_pc_seed_workers "$company"

  local deadline=$((SECONDS + 120)) run=""
  while ((SECONDS < deadline)); do
    run=$(rig_pc_api GET "/api/companies/$company/heartbeat-runs?limit=40" |
      jq -r --arg a "$agent" '[.[] | select(.agentId == $a and (.status == "failed" or .status == "timed_out"))][0].id // empty')
    [[ -n $run ]] && break
    sleep 2
  done
  [[ -n $run ]] || rig_die "seed: the failing agent has no failed run after 120s"

  local pg="postgres://paperclip:paperclip@127.0.0.1:$RIG_PG_PORT/paperclip"
  psql "$pg" -v ON_ERROR_STOP=1 -qAt -v run="$run" <<'SQL' >/dev/null || rig_die "seed: could not write the retry-exhausted event"
insert into heartbeat_run_events (company_id, run_id, agent_id, seq, event_type, level, message, payload)
select r.company_id, r.id, r.agent_id,
       coalesce((select max(seq) from heartbeat_run_events e where e.run_id = r.id), 0) + 1,
       'lifecycle', 'warn',
       'Bounded retry exhausted after 3 scheduled attempts; no further automatic retry will be queued',
       '{"rigSeed": true}'::jsonb
from heartbeat_runs r
where r.id = :'run'
  and not exists (select 1 from heartbeat_run_events e
                  where e.run_id = r.id and e.message like 'Bounded retry exhausted%');
SQL

  local counts kind missing=0
  counts=$(rig_pc_api GET "/api/companies/$company/attention?limit=100" | jq -c '.countsBySourceKind') ||
    rig_die "seed: could not read the inbox back"
  for kind in failed_run review issue_thread_interaction blocker_attention; do
    if [[ $(jq -r --arg k "$kind" '.[$k] // 0' <<<"$counts") -ge 1 ]]; then
      rig_ok "inbox has a $kind row"
    else
      rig_fail "inbox has no $kind row"
      missing=$((missing + 1))
    fi
  done
  ((missing == 0)) || rig_die "seed: $missing inbox kind(s) missing; counts: $counts"

  local rows live
  rows=$(jq -r '.total // (.items | length) // 0' < <(rig_pc_api GET "/api/companies/$company/attention?limit=100")) ||
    rig_die "seed: could not count the inbox rows"
  ((rows >= RIG_SEED_MIN_ROWS)) ||
    rig_die "seed: $rows inbox rows, need $RIG_SEED_MIN_ROWS; counts: $counts"
  rig_ok "inbox has $rows rows (need $RIG_SEED_MIN_ROWS)"
  live=$(rig_pc_live_runs "$company")
  ((live >= ${#RIG_SEED_WORKERS[@]})) ||
    rig_die "seed: $live live run(s), need ${#RIG_SEED_WORKERS[@]}"
  rig_ok "$live agents have a live run"
  rig_ok "seeded company '$RIG_SEED_COMPANY' ($company): $(jq -c 'with_entries(select(.value > 0))' <<<"$counts")"
}
