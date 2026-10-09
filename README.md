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
Paperclip instance. It needs `Hyprland`, `quickshell`, `omarchy`, `hyprctl`,
`grim`, `jq`, `curl`, `git`, `python3`, `ss` and the Paperclip CLI.

```sh
dev/rig ci --nested            # up, run every check, tear down, verify. One command.
dev/rig ci --headless          # same, with no visible window (see "CI" below)

dev/rig up --nested            # bring the rig up and leave it running
dev/rig check                  # run the checks against the running rig
dev/rig screenshot shot.png    # capture the nested shell
dev/rig exec -- omarchy plugin list    # run any command inside the sandbox
dev/rig logs shell             # shell | compositor | instance | stubs
dev/rig status                 # what is running, and where
dev/rig down                   # tear it down and prove nothing is left
```

`ci` writes its evidence (one log per check, plus `nested-shell.png`) to
`.rig-evidence/` and exits non-zero if any check or the teardown proof fails.
`up` and `ci` need `WAYLAND_DISPLAY` to name a running session when run in
`--nested` mode.

### What it isolates

| What                | How                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------- |
| Desktop             | The shell under test runs in its own nested Hyprland, with its own `XDG_RUNTIME_DIR`. The host Hyprland, bar and shell are never restarted or reconfigured. |
| Config and data     | Throwaway `HOME` and `XDG_*` under `$TMPDIR/omarchy-plugin-rig`. The plugin is installed into that, never into `~/.config`. |
| Paperclip           | A separate instance directory, HTTP port and Postgres port, created and destroyed by the rig. The ports of the default instance are refused. |
| systemd, D-Bus      | No session bus in the sandbox, so the plugin cannot reach your user units.                  |
| Browser and terminal | Recording stubs. A check asserts the URL the plugin computed; it never launches Brave.      |

The rig refuses to start, or stops, if a guard fails: sandbox `HOME` outside the
temp root, the host runtime dir, the host plugin directory, a forbidden port, a
`WAYLAND_DISPLAY` socket that is not in the rig's runtime dir, or an Omarchy
shell that is not the one the rig started. Every run also checks that the host
config, host shell and host Paperclip data are untouched.

### What it checks

Manifest validation; cold install from an empty config; a repeat install
(refused, files intact); enable; a screenshot of the nested shell; every
`bin/` script with the instance up and with it down; disable (twice); enable
again; remove (twice); reinstall after remove; enable after reinstall.

`omarchy plugin add` and `remove` return once the shell has been asked to
rescan. For a moment after that `omarchy plugin enable` can answer
"omarchy-shell is not responding" or "plugin ... is not known". The enable
checks retry only on those two answers, for at most 30 seconds, and the number
of attempts is recorded in the check's log. Any other failure fails at once.

### Teardown

`dev/rig down` stops the Paperclip instance, the nested shell and the nested
compositor, deletes the session and runtime directories, then proves it: the
directories are gone, the Paperclip HTTP and Postgres ports are free, the
recorded PIDs are gone, no process references the session tree, and no rig
systemd units exist. `dev/rig verify-clean` repeats the proof for the last
session. A failed `up` tears down whatever it started; so does `ci`.

### CI

`--headless` nests the rig inside a headless Wayland parent compositor, which
needs `weston` or `cage` installed. Without one it stops and says so; it will
not fall back to the DRM backend, because that would take the owner's display.
On a self-hosted runner, the parent compositor belongs in the runner image.

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
rig up with `dev/rig up --nested`, and the nested window is theirs to drive.
