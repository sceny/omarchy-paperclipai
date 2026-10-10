# Paperclip for Omarchy (`sceny.paperclipai`)

A bar widget for the Omarchy shell that shows what your Paperclip agents are
doing and what is waiting for you, plus helper scripts that keep a Paperclip
instance running.

## Install

```sh
omarchy plugin add https://github.com/sceny/omarchy-paperclipai --yes
omarchy plugin enable sceny.paperclipai right
```

Upgrade: `omarchy plugin remove sceny.paperclipai --yes`, then add it again.
Disable keeps the files; remove deletes them. Both survive being run twice.

The shell side lives in `bin/`: `omarchy-paperclip-status`, `-service`,
`-setup`, `-doctor`, `-open`, `-webapp`, `-agent`, `-inbox` and `-skills`.

## Following `develop` (maintainers)

`omarchy plugin update` fetches the default branch, `main`, so it never brings
merged work from `develop`. The owner's installs of `sceny.devices` and
`sceny.paperclipai` are git checkouts on `develop`, and a user timer keeps them
there with no agent run:

```sh
dev/follow-develop install     # copies the script to ~/.local/share/sceny-plugins/
                               # and enables sceny-plugins-follow-develop.timer
dev/follow-develop status      # next run, last log lines
dev/follow-develop uninstall   # timer and script gone
```

Every 5 minutes (and 2 minutes after login) it fetches `origin/develop` for
each plugin, fast-forwards the install, runs `omarchy-plugin-validate`, rolls
back if that fails, and restarts the shell (`omarchy-restart-shell`) once if
anything changed. A rescan is not enough: `rescanPlugins` finds added and
removed plugins but does not reload the QML of one that is already loaded, so
the files were new and the screen stayed old (SCE-441). When nothing changed it
does not restart. When the session is locked the restart is refused; the pass
logs `restart-deferred` and tries again on the next run. So a merge into
`develop` is live within about five minutes, and running it needs no manual
step. After a change to `dev/follow-develop` itself, run
`dev/follow-develop install` again: the timer runs the copy in
`~/.local/share/sceny-plugins/`. The record is one JSON
line per plugin per pass in `~/.local/state/sceny-plugins/follow-develop.jsonl`,
also in `journalctl --user -u sceny-plugins-follow-develop`.

- It only moves a checkout that is clean and on `develop`. A feature branch,
  local changes, a symlink (`sceny.diction`) or a non-git copy is left alone and
  logged as `skipped`. Other plugins are not in its list (`FOLLOW_PLUGINS`).
- **Never leave an install on a feature branch for a live check.** The timer
  skips it, so it silently stops following. Use `dev/rig`.
- A pass that cannot fast-forward or fails validation exits non-zero, so
  `systemctl --user --failed` shows it.
- `test/test_follow_develop.sh` tests it against throwaway repos.

## Snooze and focus

Four states, shown in the panel's strip and on the bar icon (a zzz replaces the
bubble and the buttons go away). The strip is hidden while awake.

| State | How you get there | Toasts | Icon |
| --- | --- | --- | --- |
| Awake | default | yes | bubble |
| Snoozed by the plugin | `z` (1 hour) or `Z` / Shift+click (until 09:00) | no | zzz |
| Snoozed by Omarchy | Omarchy's Do Not Disturb is on | no (Omarchy keeps them in its history) | zzz |
| Focus | `p`, only while Omarchy is snoozed | yes, they bypass Omarchy's snooze | normal |

- A plugin snooze wins over focus. Focus only lifts Omarchy's snooze, and ends
  when Omarchy wakes, after four hours at most.
- A timed snooze ends by itself, with one toast. It never replays the backlog,
  and the panel still lists everything while you sleep.
- State lives in `$PAPERCLIP_STATE_DIR/snooze.json` (read and written by
  `bin/omarchy-paperclip-snooze get|set`). An unreadable file means awake.
- Omarchy's Do Not Disturb is polled every 3 seconds with
  `omarchy-shell notifications dndState`, because a third-party bar widget is
  not given the shell's notification service.
- Focus toasts are sent under Omarchy's `omarchy-action` app name, the only one
  Do Not Disturb lets through. Omarchy does not keep those in its history.
- To see the bubble but get no desktop toasts, set "Desktop notifications" to Off.
- From a script: `omarchy-shell paperclip snooze`, `snoozeUntilMorning`, `focus`.

## Paperclip skills

The plugin ships the Paperclip agent skills (`paperclip`, `paperclip-board`,
`paperclip-converting-plans-to-tasks`, `paperclip-create-agent`,
`para-memory-files`), copied unchanged from
[paperclipai/paperclip](https://github.com/paperclipai/paperclip) (MIT). The
commit is in `skills/upstream.list`.

- **On your machine:** setup runs `omarchy-paperclip-skills install`, which
  copies them into `~/.claude/skills` and `~/.agents/skills`. A skill directory
  the plugin did not create is left alone. `status` shows what is installed;
  `remove` takes back only what the plugin put there. Skip it with
  `omarchy-paperclip-setup --no-skills`.
- **In this repo:** `.claude/skills/` links to the same files, so an agent
  working on the plugin decides with the same Paperclip rules it installs.
- **Doctor session:** gets them too, next to `paperclip-doctor`
  (see `skills/README.md`).
- **Refresh:** `dev/sync-skills [path-to-paperclip-checkout]`, then review the
  diff.

## Testing the plugin

`dev/rig` tests the plugin end to end without touching your desktop or your
Paperclip instance. It needs `Hyprland`, `labwc` and `wtype` (the hidden view), `quickshell`,
`omarchy`, `hyprctl`, `grim`, `jq`, `curl`, `git`, `python3`, `ss`, `flock`,
`setsid`, `prlimit` and the Paperclip CLI. `dev/rig seed` also needs `psql` (the
`postgresql` package; the rig only uses the client).

```sh
dev/rig ci                     # up, run every check, tear down, verify. One command.

dev/rig up                     # bring the rig up, hidden, and leave it running
dev/rig check                  # run the checks against the running rig
dev/rig screenshot shot.png    # capture the nested shell (works hidden)
dev/rig seed                   # one inbox row each of failed_run, review, interaction, blocker
dev/rig restart-shell          # restart only the nested shell; needed after a .js change
dev/rig exec -- omarchy plugin list    # run any command inside the sandbox
dev/rig logs shell             # shell | compositor | instance | keeper | stubs
dev/rig status                 # what is running, and where
dev/rig down                   # tear it down and prove nothing is left

dev/rig show                   # you only: put the rig on your screen as a window
dev/rig hide                   # take it off again
dev/rig ps                     # every rig: owner, age, time left
dev/rig reap                   # end every rig whose owner is gone or whose TTL is up
dev/rig selftest               # test the lease, keeper, ps and reap; needs no compositor
```

`ci` writes its evidence (one log per check, plus `nested-shell.png`) to
`.rig-evidence/` and exits non-zero if any check or the teardown proof fails.

### Hidden by default

`up`, `ci`, `check`, `seed` and `screenshot` never put a window on your
workspaces, never move or retile your windows and never take focus. The rig's
Hyprland runs as the only client of a private, headless `labwc`
(`WLR_BACKENDS=headless`, one 1280x720 output, no input devices, private
`XDG_RUNTIME_DIR`), so there is no output of yours for it to appear on. The
hidden view is always 1280x720. `grim` and the shell's IPC talk to the rig's own sockets, so screenshots and
driving the shell work the same hidden. Every `up`, `down` and `check` snapshots
your session (`hyprctl clients`, `workspaces`, `activeworkspace`, `activewindow`,
read-only) before and after and prints whether anything changed.

`labwc` and `wtype` are one-time host packages (`sudo pacman -S --needed labwc
wtype`). Without them the rig stops and says so. It does not fall back to a
window on your desktop or to the DRM backend, which would take your GPU and
input devices. `RIG_RENDER_NODE` picks the render node (default: the first
`/dev/dri/renderD*` whose Mesa EGL initialises).

Start-up note: Hyprland's nested backend sometimes loses a race against the
parent on its first frame (the parent drops it, or it never draws). The rig
wakes the parent with a virtual key press (`wtype`, on the rig's private socket
only), checks that a frame can be captured, and starts the compositor again if
not, up to 20 times, so `up` can take a few extra seconds. A failed `up` keeps
its logs in `$RIG_TMP_ROOT/last-failed-up`.

To look at the rig yourself, run `dev/rig show` (or `dev/rig up --visible`). The
compositor moves into a nested window in your session; `dev/rig hide` moves it
back. HOME, the installed plugin and the Paperclip instance stay as they are.
Agents and CI never open the window by themselves: with `PAPERCLIP_AGENT_ID`,
`PAPERCLIP_RUN_ID`, `CLAUDECODE`, `CI` or `GITHUB_ACTIONS` set, `show` and
`--visible` refuse unless the owner asked and `RIG_ALLOW_VISIBLE=1` says so.

### Owner, lease and no zombies

Every rig has one owner, a process named by pid and start time, and a TTL (time
to live): 90 minutes for `up`, 30 for `ci`, changed with `--ttl SECONDS`. The
owner defaults to the nearest ancestor of `dev/rig` that is not a wrapper (an
agent run, or your login shell); `--owner PID` or `RIG_OWNER_PID` names another,
`--owner none` leaves the TTL as the only limit, and `dev/rig adopt` hands a
running rig to a new owner with a fresh TTL.

When the owner ends, crashes or is killed with `kill -9`, or the TTL is up, the
whole rig goes: compositor, `labwc`, shell, Paperclip instance, Postgres and the
temp and runtime directories. Three things enforce it, so one failing is not a
leak:

- A **keeper**, a small detached process per rig, checks the lease every 2 seconds
  and tears the rig down.
- **`dev/rig reap`** does the same sweep by hand (`--dry-run` only lists), also
  for processes that carry a rig's tag after its directory is gone.
- **`dev/rig up`** reaps dead rigs before it starts a new one.

Every process a rig starts has `OPR_RIG_ID=<rig id>` in its environment, so
teardown finds daemons too (the embedded Postgres, a server that outlived its
parent) by what they are, not by name. `dev/rig ps` shows each rig with owner,
view, age and time left, and flags leaked processes; `--json` is for scripts.

Two rigs at once share nothing: separate session and runtime directories,
sockets, process tags and ports (reserved under a lock, each rig excluding the
other's). One owner can have one rig; give a second its own `--owner`. The
registry is `/tmp/omarchy-plugin-rig-<uid>` (not `$TMPDIR`, so `ps` and `reap`
see every run's rigs).

### What it isolates

| What                | How                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------- |
| Desktop             | The shell under test runs in its own Hyprland with its own private `XDG_RUNTIME_DIR` (`/tmp/opr.<tag>`, mode 0700, never under `/run/user`). The host Hyprland, bar and shell are never restarted or reconfigured. |
| Config and data     | Throwaway `HOME` and `XDG_*` under the rig's session directory. The plugin is installed into that, never into `~/.config`. |
| Paperclip           | A separate instance directory, HTTP port and Postgres port, created and destroyed by the rig. The ports of the default instance are refused. |
| systemd, D-Bus      | No session bus in the sandbox, so the plugin cannot reach your user units.                  |
| Browser and terminal | Recording stubs. A check asserts the URL the plugin computed; it never launches Brave.      |
| Seat and input      | `LIBSEAT_BACKEND=seatd` with no socket: the compositor cannot take your session, GPU or keyboard. |

The rig refuses to start, or stops, if a guard fails: sandbox `HOME` outside the
registry, the host runtime dir or anything inside it, the host plugin
directory, a forbidden port, a `WAYLAND_DISPLAY` socket that is not in the rig's
runtime dir, or an Omarchy shell that is not the one the rig started. Every run
also checks that the host config, host shell, host Paperclip data and the
visible state of your session are untouched.

### What it checks

Manifest validation; the lease; the shell services (`omarchy.idle` and
`omarchy.lock` stay off); cold install from an empty config; a repeat install
(refused, files intact); enable; a screenshot of the nested shell; that
nothing is mapped on the host; every `bin/` script with the instance up and with
it down; disable (twice); enable again; remove (twice); reinstall after remove;
enable after reinstall.

`omarchy plugin add` and `remove` return once the shell has been asked to
rescan. For a moment after that `omarchy plugin enable` can answer
"omarchy-shell is not responding" or "plugin ... is not known". The enable
checks retry only on those two answers, for at most 30 seconds, and the number
of attempts is recorded in the check's log. Any other failure fails at once.

### Working in a running rig

- **After a `.js` change, run `dev/rig restart-shell`.** Quickshell reloads QML
  on its own but keeps the JS modules it has already imported. `restart-shell`
  stops and starts only the nested shell: the compositor, the Paperclip
  instance, the installed plugin and its bar placement stay as they are.
- **The nested shell never locks itself.** The sandbox's `shell.json` ships
  with `omarchy.idle` and `omarchy.lock` disabled; left on, the idle timer would
  lock the session after 5 minutes and the lock screen would cover the window.
  `dev/rig check` asserts both stay disabled (`RIG_SHELL_DISABLED_PLUGINS` in
  `dev/rig.d/lib.sh`).
- **`dev/rig screenshot` does not need a window.** It captures the rig's own
  output while hidden. In the visible view `grim` only gets a frame while the
  window is on a workspace you are showing; otherwise it stops after 15 seconds
  (`RIG_GRIM_TIMEOUT`) and says so. The rig never switches your workspaces.
- **`dev/rig seed` fills the inbox.** It adds a company "Rig Co" to the
  throwaway instance with a failing agent and tasks, so the attention feed has
  one row each of `failed_run`, `review`, `issue_thread_interaction` and
  `blocker_attention` (plus the `agent_error_alert` and `recovery_action` rows
  a failed agent brings), then reads the feed back and fails if a kind is
  missing. It is safe to run twice. Everything goes through the instance's API
  except one row: the inbox lists a failed run only after a `Bounded retry
  exhausted` lifecycle event, which the server writes after a long retry
  schedule, so the helper inserts that one event into the rig's own Postgres.
  It refuses to run if the instance is not the rig's.

### Core dumps and the compositor

A throwaway Hyprland that fails to start does not exit: it aborts (`SIGABRT`).
It does that when `XDG_RUNTIME_DIR` is not set, and when it has no usable
parent to nest in. On a host with `systemd-coredump` that is a core dump and a
crash notice on your desktop. The rig therefore:

- **Switches cores off.** The core limit is exactly 1 byte (`prlimit
  --core=1:1`). `ulimit -c 0` is not enough: when `core_pattern` is a pipe (the
  default on Arch) the kernel ignores a limit of 0 and still runs the handler;
  only 1 makes it refuse the pipe. Do not run `ulimit -c 0` before the rig: it
  lowers the hard limit so `prlimit` can no longer set 1 (the rig warns and goes
  on, but the abort is then still logged).
- **Uses a private runtime dir.** Every Hyprland gets `XDG_RUNTIME_DIR=/tmp/opr.<tag>`
  (0700; short because of the 108-byte socket path limit; `RIG_RUNTIME_ROOT`
  moves the root). The rig refuses `/run/user/*` and your own dir.
- **Checks before launch.** Before any `Hyprland` call: `XDG_RUNTIME_DIR` is set,
  absolute, yours, mode 0700 and not the host's; `HOME` is not your home;
  cores are off. A failed check is an ordinary rig error, not an abort.
- **Reads the version with `pacman -Q hyprland`** (`dev/rig status` shows it).
  Never run `Hyprland --version` by hand: it initialises the compositor.

For an ad-hoc command that needs the same safety, use
`dev/rig probe -- <command...>`: a throwaway `HOME` and `XDG_*` dirs under
`/tmp/opr-p.*`, cores off, no host display or session bus, removed afterwards.
`Hyprland` is allowed only with `--verify-config`, `--help` or `-h`.

To prove a change crashed nothing: `coredumpctl list /usr/bin/Hyprland --since
<start time>` must say "No coredumps found."

### Teardown

`dev/rig down` stops the Paperclip instance, the shell, the compositor and
`labwc`, ends anything else that carries the rig's tag, deletes the session and
runtime directories, then proves it: the directories are gone, the Paperclip
HTTP and Postgres ports are free, the recorded PIDs are gone, no process carries
the tag or references the session tree, and no rig systemd units exist. It then
prints your session's `hyprctl` snapshot next to the one from before `up`.
`dev/rig verify-clean` repeats the proof for every rig. A failed `up` tears down
whatever it started; so does `ci`.

### CI

`dev/rig ci` runs hidden, so it works on a headless runner as well as under a
desktop session. It needs `labwc` and `wtype`; on a self-hosted runner that belongs in the
runner image. `ci` owns its rig: if the job is killed, the keeper ends the rig
within seconds, and the TTL (30 minutes) is the backstop.

### Pointing the rig at another plugin

Copy the whole `dev/` directory into the other plugin repo and edit
`dev/rig.conf`. It is the only file that changes:

- `RIG_PLUGIN_ID`: the id in that plugin's `manifest.json`.
- `RIG_PLUGIN_SRC`: where the plugin source is, relative to `dev/`.
- `RIG_BAR_SECTION`: `left`, `center` or `right`.
- `RIG_PACKAGE_PATHS`: what a release ships; the rig builds its install repo from this, so `dev/` stays out.
- `RIG_NEEDS_PAPERCLIP`: `0` for a plugin that never talks to Paperclip (no throwaway instance is started).
- `RIG_SMOKE_COMMANDS` and `RIG_SMOKE_COMMANDS_DOWN`: the plugin commands to run, as `<script> <args...>`.

### What the rig does not judge

It proves install, enable, disable, remove, script behaviour and that the shell
loads the plugin. How the panel looks and behaves is Panel QA's call: bring the
rig up with `dev/rig up` and, when they want to look, `dev/rig show`. The window is theirs to drive.
