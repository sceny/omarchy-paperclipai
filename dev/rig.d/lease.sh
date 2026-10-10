#!/bin/bash
# Ownership, leases and reaping for the rig. Sourced by dev/rig, never run
# directly. Generic: nothing in here knows about Paperclip or any one plugin.
#
# The rule: every rig has exactly one owner, a process the caller names (or
# the rig works out), and a time to live. When the owner is gone, or the TTL
# is up, the whole rig goes: compositor, shell, instance, database, temp dirs.
# Three things enforce it, so one failing is not a leak:
#
#   1. the keeper, a small detached process that watches the lease and tears
#      the rig down within a few seconds of the owner dying (even by kill -9);
#   2. `dev/rig reap`, which does the same sweep by hand;
#   3. `dev/rig up`, which reaps dead rigs before it starts a new one.
#
# Every process a rig starts carries OPR_RIG_ID=<rig id> in its environment.
# Children inherit it, daemons included, so the rig finds its whole tree by
# what it is, not by what it is called, who forked it or which process group
# it ended up in. Postgres and the Paperclip server both survive being
# orphaned; the tag is how they are still found.
#
# shellcheck shell=bash

RIG_DEFAULT_TTL=${RIG_DEFAULT_TTL:-5400}
RIG_CI_TTL=${RIG_CI_TTL:-1800}
RIG_KEEPER_INTERVAL=${RIG_KEEPER_INTERVAL:-2}

# ------------------------------------------------------------ the registry ----

rig_ensure_root() {
  mkdir -p -m 700 "$RIG_TMP_ROOT" ||
    rig_die "cannot create $RIG_TMP_ROOT"
  [[ -O $RIG_TMP_ROOT ]] ||
    rig_die "$RIG_TMP_ROOT belongs to another user; set RIG_TMP_ROOT"
}

rig_session_dirs() {
  # Every session directory of every plugin that uses this registry.
  local dir
  for dir in "$RIG_TMP_ROOT"/*.*.*; do
    [[ -d $dir ]] && printf '%s\n' "$dir"
  done
}

# ---------------------------------------------------------------- processes ----

rig_proc_start() {
  # rig_proc_start <pid> — field 22 of /proc/<pid>/stat (start time in ticks).
  # Together with the pid it names one process for the life of the machine.
  local stat
  { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
  stat=${stat##*) } # comm may hold spaces and parens; everything after the last ")" is fixed
  [[ ${stat%% *} != [ZX] ]] || return 1 # a zombie is dead; its owner is not coming back
  # shellcheck disable=SC2086
  set -- $stat
  printf '%s\n' "${20}"
}

rig_proc_comm() { cat "/proc/$1/comm" 2>/dev/null; }

rig_pid_is() {
  # rig_pid_is <pid> <start> — that very process is still running.
  local now
  [[ -n ${1:-} && -n ${2:-} ]] || return 1
  now=$(rig_proc_start "$1") || return 1
  [[ $now == "$2" ]]
}

rig_ppid() {
  local stat
  { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
  stat=${stat##*) }
  # shellcheck disable=SC2086
  set -- $stat
  printf '%s\n' "$2"
}

rig_tag_scan() {
  # rig_tag_scan [rig-id] — "<rig id> <pid>" for every process of this user
  # that carries a rig tag. The caller and its ancestors are left out, so a
  # teardown never kills the process that is running it.
  python3 - "${1:-}" <<'PY'
import os, sys
want = sys.argv[1]
skip, pid = set(), os.getpid()
while pid > 1:
    skip.add(pid)
    try:
        with open("/proc/%d/stat" % pid) as f:
            stat = f.read()
        pid = int(stat[stat.rindex(")") + 2:].split()[1])
    except Exception:
        break
key = b"OPR_RIG_ID="
for entry in os.listdir("/proc"):
    if not entry.isdigit() or int(entry) in skip:
        continue
    try:
        with open("/proc/%s/environ" % entry, "rb") as f:
            env = f.read()
    except Exception:
        continue
    for item in env.split(b"\0"):
        if item.startswith(key):
            tag = item[len(key):].decode("utf-8", "replace")
            if not want or tag == want:
                print(tag, entry)
            break
PY
}

rig_tagged_pids() {
  # rig_tagged_pids <rig-id> — pids only. No pipeline here: its reader would be
  # a tagged sibling of the scanner when the keeper itself is sweeping.
  local out line
  out=$(rig_tag_scan "$1")
  while read -r _ line; do
    [[ -n $line ]] && printf '%s\n' "$line"
  done <<<"$out"
}

rig_sweep_tagged() {
  # rig_sweep_tagged <rig-id> — end every process of the rig. TERM first, so a
  # database gets to stop cleanly, then KILL, twice over because the dying
  # may fork on the way out.
  local id=$1 pid round deadline
  for round in 1 2; do
    mapfile -t pids < <(rig_tagged_pids "$id")
    ((${#pids[@]})) || return 0
    for pid in "${pids[@]}"; do
      ((round == 1)) && rig_step "ending process $pid ($(rig_proc_comm "$pid"))"
      kill -TERM "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
      [[ -z $(rig_tagged_pids "$id") ]] && return 0
      sleep 0.5
    done
    for pid in $(rig_tagged_pids "$id"); do
      kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 0.5
  done
  [[ -z $(rig_tagged_pids "$id") ]]
}

# ------------------------------------------------------------------- owner ----

# Wrappers that run a command for somebody else and are never the owner.
RIG_TRANSPARENT_COMMANDS=" env timeout nice ionice setsid sudo xargs nohup script stdbuf flock time unbuffer rig "

rig_is_transparent() {
  # A shell started with -c is a wrapper (an agent's Bash tool, ssh host cmd,
  # make); so are env, timeout and the like. An interactive shell or a script
  # is not.
  local pid=$1 comm args arg
  comm=$(rig_proc_comm "$pid") || return 0
  [[ $RIG_TRANSPARENT_COMMANDS == *" $comm "* ]] && return 0
  case $comm in
  bash | sh | zsh | dash | fish | ksh)
    mapfile -d '' args <"/proc/$pid/cmdline" 2>/dev/null || return 0
    for arg in "${args[@]:1}"; do
      case $arg in
      --*) ;;
      -*c*) return 0 ;;
      -*) ;;
      *) return 1 ;;
      esac
    done
    ;;
  esac
  return 1
}

rig_resolve_owner() {
  # Prints the owner pid, or "none". The caller can say so: RIG_OWNER_PID, or
  # --owner on `up`. Otherwise it is the nearest ancestor that is not a
  # wrapper. For an agent run that is the agent process: it lives for the run
  # and is gone when the run ends, crashes or is killed, which is exactly the
  # lifetime a rig should have. For a person it is their login shell.
  if [[ -n ${RIG_OWNER_PID:-} ]]; then
    printf '%s\n' "$RIG_OWNER_PID"
    return 0
  fi
  local pid=$$ first="" depth=0
  while ((depth++ < 25)); do
    pid=$(rig_ppid "$pid") || break
    ((pid > 1)) || break
    [[ -n $first ]] || first=$pid
    rig_is_transparent "$pid" || {
      printf '%s\n' "$pid"
      return 0
    }
  done
  # Nothing but wrappers up to init: the direct parent is the best there is.
  printf '%s\n' "${first:-none}"
}

# ------------------------------------------------------------------- lease ----

rig_lease_init() {
  # rig_lease_init <owner pid|none> <ttl seconds>
  local owner=$1 ttl=$2 start="" name=""
  if [[ $owner != none ]]; then
    start=$(rig_proc_start "$owner") ||
      rig_die "owner pid $owner is not running"
    name=$(rig_proc_comm "$owner")
  else
    owner=""
  fi
  rig_state_set owner_pid "$owner"
  rig_state_set owner_start "$start"
  rig_state_set owner_name "$name"
  rig_state_set created "$(date +%s)"
  rig_state_set ttl "$ttl"
}

rig_lease_state() {
  # rig_lease_state <session> — prints live | orphaned | expired | starting.
  local session=$1 state="$1/rig.state" owner start created ttl now
  if [[ ! -f $state ]]; then
    # A session that never wrote a state file is an `up` that died early, or
    # one that is about to. Give it two minutes.
    now=$(date +%s)
    if ((now - $(stat -c %Y "$session") > 120)); then echo orphaned; else echo starting; fi
    return 0
  fi
  owner=$(rig_state_read "$state" owner_pid) || owner=""
  start=$(rig_state_read "$state" owner_start) || start=""
  created=$(rig_state_read "$state" created) || created=""
  ttl=$(rig_state_read "$state" ttl) || ttl=0
  now=$(date +%s)
  if [[ -z $created ]]; then
    if ((now - $(stat -c %Y "$session") > 120)); then echo orphaned; else echo starting; fi
    return 0
  fi
  if [[ -n $owner ]] && ! rig_pid_is "$owner" "$start"; then
    echo orphaned
  elif ((ttl > 0 && now - created > ttl)); then
    echo expired
  else
    echo live
  fi
}

rig_fmt_duration() {
  local s=$1
  ((s < 0)) && s=0
  if ((s >= 3600)); then
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif ((s >= 60)); then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# -------------------------------------------------------------------- lock ----

rig_lock() {
  # rig_lock <seconds> — one teardown of a rig at a time. The lock file sits
  # beside the session, not in it, because the session is what teardown removes.
  exec {RIG_LOCK_FD}>"$RIG_LOCK_FILE" || return 1
  flock -w "$1" "$RIG_LOCK_FD"
}

rig_unlock() {
  [[ -n ${RIG_LOCK_FD:-} ]] || return 0
  flock -u "$RIG_LOCK_FD" 2>/dev/null || true
  exec {RIG_LOCK_FD}>&- 2>/dev/null || true
  rm -f "$RIG_LOCK_FILE"
  RIG_LOCK_FD=""
}

# ------------------------------------------------------------ port reserve ----

rig_ports_taken() {
  # Every port another rig has reserved, so two rigs coming up in the same
  # second cannot pick the same "free" port before either has bound it.
  local dir port
  for dir in $(rig_session_dirs); do
    for port in http_port pg_port; do
      rig_state_read "$dir/rig.state" "$port" 2>/dev/null || true
    done
  done
}

rig_reserve_ports() {
  # Picks and records the rig's ports under one lock.
  exec {RIG_PORTS_FD}>"$RIG_TMP_ROOT/.ports.lock" || return 1
  flock -w 30 "$RIG_PORTS_FD" || return 1
  RIG_PORTS_TAKEN=$(rig_ports_taken | tr '\n' ' ')
  RIG_HTTP_PORT=$(rig_free_port 3400 3499) || { exec {RIG_PORTS_FD}>&-; return 1; }
  RIG_PORTS_TAKEN="$RIG_PORTS_TAKEN $RIG_HTTP_PORT"
  RIG_PG_PORT=$(rig_free_port 54400 54499) || { exec {RIG_PORTS_FD}>&-; return 1; }
  rig_state_set http_port "$RIG_HTTP_PORT"
  rig_state_set pg_port "$RIG_PG_PORT"
  exec {RIG_PORTS_FD}>&-
}

# ------------------------------------------------------------------ keeper ----

rig_keeper_start() {
  # A detached watcher. setsid gives it a session of its own, so killing the
  # owner's process group, or the owner's whole session, does not take it too.
  nohup setsid "$RIG_DIR/rig" _keeper "$RIG_SESSION" \
    </dev/null >>"$RIG_LOGS/keeper.log" 2>&1 &
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    [[ -s $RIG_SESSION/keeper.pid ]] && {
      rig_ok "lease: owner ${RIG_OWNER_DESC}, ttl $(rig_fmt_duration "$RIG_TTL"), keeper pid $(<"$RIG_SESSION/keeper.pid")"
      return 0
    }
    sleep 0.2
  done
  rig_die "the lease keeper did not start; see $RIG_LOGS/keeper.log"
}

cmd_keeper() {
  # Internal. dev/rig _keeper <session-dir>
  local session=${1:?}
  rig_load_state "$session" || exit 0
  export OPR_RIG_ID="$RIG_ID"
  printf '%s\n' "$$" >"$session/keeper.pid"
  while [[ -d $session ]]; do
    local state
    state=$(rig_lease_state "$session")
    if [[ $state == orphaned || $state == expired ]]; then
      printf '%s keeper: lease %s, tearing down %s\n' "$(date -u +%H:%M:%S)" "$state" "$RIG_ID"
      rig_reap_session "$session" "$state"
      exit 0
    fi
    sleep "$RIG_KEEPER_INTERVAL"
  done
}

# ---------------------------------------------------------------- reap one ----

rig_reap_session() {
  # rig_reap_session <session-dir> <why> — tear one rig down from outside it.
  # A subshell: teardown calls exit on a guard failure, and one broken rig must
  # not stop a sweep over the others.
  (
    rig_load_state "$1" || true
    rig_define_paths "$1"
    rig_say "Reaping $RIG_ID ($2)"
    rig_teardown
    rig_verify_clean
  )
}

# -------------------------------------------------------------------- ps ----

cmd_ps() {
  local json=0
  while (($#)); do
    case $1 in
    --json) json=1 ;;
    *) rig_die "ps: unknown option $1" ;;
    esac
    shift
  done

  local dir id plugin view owner_pid owner_name created ttl state age left owner_desc keeper
  local now rows=() found=0 json_rows=()
  now=$(date +%s)
  for dir in $(rig_session_dirs); do
    found=1
    id=${dir##*/}
    plugin=$(rig_state_read "$dir/rig.state" plugin_id 2>/dev/null) || plugin=${id%%.*}
    view=$(rig_state_read "$dir/rig.state" view 2>/dev/null) || view="?"
    owner_pid=$(rig_state_read "$dir/rig.state" owner_pid 2>/dev/null) || owner_pid=""
    owner_name=$(rig_state_read "$dir/rig.state" owner_name 2>/dev/null) || owner_name=""
    created=$(rig_state_read "$dir/rig.state" created 2>/dev/null) || created=$now
    ttl=$(rig_state_read "$dir/rig.state" ttl 2>/dev/null) || ttl=0
    state=$(rig_lease_state "$dir")
    age=$((now - created))
    if ((ttl > 0)); then left=$(rig_fmt_duration $((ttl - age))); else left="-"; fi
    if [[ -z $owner_pid ]]; then owner_desc="none"; else owner_desc="$owner_name($owner_pid)"; fi
    keeper=$(<"$dir/keeper.pid") 2>/dev/null || keeper=""
    if [[ $state == live && -n $keeper && ! -d /proc/$keeper ]]; then state="live (keeper gone)"; fi
    if ((json)); then
      json_rows+=("$(jq -nc --arg id "$id" --arg plugin "$plugin" --arg view "$view" --arg owner "$owner_pid" \
        --arg state "$state" --argjson age "$age" --argjson ttl "${ttl:-0}" \
        '{id:$id,plugin:$plugin,view:$view,owner_pid:$owner,state:$state,age_seconds:$age,ttl_seconds:$ttl}')")
    else
      rows+=("$(printf '%-34s %-12s %-8s %-18s %-8s %-8s %s' \
        "$id" "$plugin" "$view" "$owner_desc" "$(rig_fmt_duration "$age")" "$left" "$state")")
    fi
  done

  # Tagged processes whose rig directory is gone are leaks, and ps says so.
  local tag pid leaks=()
  while read -r tag pid; do
    [[ -n $tag ]] || continue
    [[ -d $RIG_TMP_ROOT/$tag ]] || leaks+=("$tag $pid $(rig_proc_comm "$pid")")
  done < <(rig_tag_scan)

  if ((json)); then
    printf '%s\n' "${json_rows[@]:-}" | jq -sc --argjson leaks "$(printf '%s\n' "${leaks[@]:-}" | jq -R . | jq -sc 'map(select(. != ""))')" \
      '{rigs: map(select(. != null)), leaked_processes: $leaks}'
    return 0
  fi

  if ((found)); then
    printf '%-34s %-12s %-8s %-18s %-8s %-8s %s\n' RIG PLUGIN VIEW OWNER AGE TTL-LEFT STATE
    printf '%s\n' "${rows[@]}"
  else
    echo "no rigs"
  fi
  if ((${#leaks[@]})); then
    echo
    echo "leaked processes (their rig directory is gone; 'dev/rig reap' ends them):"
    printf '  %s\n' "${leaks[@]}"
  fi
  return 0
}

# ------------------------------------------------------------------ reap ----

cmd_reap() {
  local dry=0 all=0 max_age=""
  while (($#)); do
    case $1 in
    -n | --dry-run) dry=1 ;;
    --all) all=1 ;;
    --older-than)
      max_age=${2:?--older-than needs seconds}
      shift
      ;;
    *) rig_die "reap: unknown option $1" ;;
    esac
    shift
  done

  local dir id state reaped=0 now age created
  now=$(date +%s)
  for dir in $(rig_session_dirs); do
    id=${dir##*/}
    state=$(rig_lease_state "$dir")
    if [[ $state == live && -n $max_age ]]; then
      created=$(rig_state_read "$dir/rig.state" created 2>/dev/null) || created=$now
      age=$((now - created))
      ((age > max_age)) && state="older than ${max_age}s"
    fi
    # --all is the owner's tool: every rig, live or not. It is never the default.
    if ((all)); then state=${state/live/forced}; fi
    case $state in
    live | starting) rig_step "$id: $state, left alone" ;;
    *)
      if ((dry)); then
        rig_step "$id: $state, would reap"
      else
        rig_reap_session "$dir" "$state" || rig_warn "$id: reap reported leftovers"
      fi
      reaped=$((reaped + 1))
      ;;
    esac
  done

  # Tagged processes with no session directory, and runtime dirs with no
  # session: what a crash between "dir removed" and "process ended" leaves.
  local tag pid ids=()
  while read -r tag pid; do
    [[ -n $tag && ! -d $RIG_TMP_ROOT/$tag ]] || continue
    [[ " ${ids[*]:-} " == *" $tag "* ]] || ids+=("$tag")
  done < <(rig_tag_scan)
  for tag in "${ids[@]:-}"; do
    [[ -n $tag ]] || continue
    if ((dry)); then
      rig_step "leaked processes of $tag, would end"
    else
      rig_step "ending leaked processes of $tag"
      rig_sweep_tagged "$tag" || rig_warn "some processes of $tag will not die"
    fi
    reaped=$((reaped + 1))
  done

  local rt suffix
  for rt in "$RIG_RUNTIME_ROOT"/opr.*; do
    [[ -d $rt ]] || continue
    suffix=${rt##*opr.}
    compgen -G "$RIG_TMP_ROOT/*.$suffix" >/dev/null && continue
    if ((dry)); then
      rig_step "runtime dir $rt has no rig, would remove"
    else
      rm -rf "$rt"
      rig_step "removed orphan runtime dir $rt"
    fi
    reaped=$((reaped + 1))
  done

  ((reaped)) || rig_ok "nothing to reap"
  return 0
}

reap_dead_rigs_quietly() {
  # `up` calls this first, so an owner who never reaps still never accumulates.
  local dir state
  for dir in $(rig_session_dirs); do
    state=$(rig_lease_state "$dir")
    case $state in
    orphaned | expired) rig_reap_session "$dir" "$state" >&2 || true ;;
    esac
  done
}

# ---------------------------------------------------------------- selecting ----

rig_select() {
  # Finds the rig a command should act on and loads it. Never "the only rig":
  # another run's rig is not this run's to stop.
  #   --rig ID / RIG_SELECT   an explicit rig (a unique part of the id is enough)
  #   OPR_RIG_ID              inside `dev/rig exec`, the rig that exec belongs to
  #   otherwise               the rig of this plugin that this owner started
  local want=${RIG_SELECT:-${OPR_RIG_ID:-}} matches=() dir
  if [[ -n $want ]]; then
    for dir in $(rig_session_dirs); do
      [[ ${dir##*/} == *"$want"* ]] && matches+=("$dir")
    done
    if ((${#matches[@]} == 1)); then
      rig_load_state "${matches[0]}"
      return
    fi
    ((${#matches[@]})) && rig_fail "'$want' matches ${#matches[@]} rigs; be more specific (dev/rig ps)"
    return 1
  fi

  local owner
  owner=$(rig_resolve_owner)
  [[ $owner != none ]] || return 1
  for dir in $(rig_session_dirs); do
    [[ $(rig_state_read "$dir/rig.state" plugin_id 2>/dev/null) == "$RIG_PLUGIN_ID" ]] || continue
    [[ $(rig_state_read "$dir/rig.state" owner_pid 2>/dev/null) == "$owner" ]] || continue
    matches+=("$dir")
  done
  case ${#matches[@]} in
  0) return 1 ;;
  1) rig_load_state "${matches[0]}" ;;
  *)
    rig_fail "this owner has ${#matches[@]} rigs; pick one with --rig <id>:"
    printf '     %s\n' "${matches[@]##*/}" >&2
    return 1
    ;;
  esac
}
