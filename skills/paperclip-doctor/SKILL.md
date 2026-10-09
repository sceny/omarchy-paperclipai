---
name: paperclip-doctor
description: Repair the local Paperclip AI instance on an Omarchy machine. Use when Paperclip does not answer, the Paperclip bar widget shows a problem, the board asks for a token, the background service will not start, agent runs keep failing, or `paperclipai doctor --repair` did not fix it. Triggers - paperclip, paperclipai, paperclip.ing, Paperclip bar widget, instance will not start, nothing on port 3100.
---

# Repair the local Paperclip instance

Paperclip (https://docs.paperclip.ing) runs AI agents on a board. On this
machine it is one local instance: a Node service that answers on an HTTP port,
a state directory with the user's work in it, and an Omarchy bar widget that
shows the instance.

Your job is to get the instance answering again, then show the user it is back.

## Read the evidence before you touch anything

1. `./doctor.status` — one word from the repair that ran in the background:
   `running`, `fixed`, `still-broken`, `healthy`, `no-cli`, `skipped`.
   `skipped` means the user declined the built-in repair, so nothing ran.
2. `./doctor.log` — the output of `paperclipai doctor --repair`.
3. `./bundle.log` — versions, the status probe, service state, service logs,
   instance files, listening sockets. Start here for anything you do not know.

If `doctor.status` still says `running`, the repair is not finished. Tell the
user, and read the log again after a few seconds instead of starting a second
repair.

## The one source of truth

```
<plugin>/bin/omarchy-paperclip-status          # one JSON object, never fails loudly
<plugin>/bin/omarchy-paperclip-status --compact
```

`state` is one of `needs-you`, `working`, `idle`, `stopped`, `not-installed`,
`needs-auth`, `probe-failed`. `problems` is the list of what is wrong. Read
this instead of guessing from log lines.

## Commands

```
paperclipai doctor --repair --yes         # the built-in repairs
paperclipai service status --json         # the background service
paperclipai service logs                  # its logs
paperclipai service restart
paperclipai run                            # run in the foreground to see the real error
omarchy-shell shell rescanPlugins          # reload the bar widget
systemctl --user status paperclipai.service
journalctl --user -u paperclipai.service -n 100 --no-pager
```

The CLI is `paperclipai`, or `npx -y paperclipai@latest` when nothing is
installed. Paperclip needs Node 24.11 or newer; an older Node is a common
cause of an instance that starts and dies at once.

## Where things live

```
~/.paperclip/instances/<instance>/              state, logs, runtime-info.json
~/.paperclip/instances/<instance>/runtime-info.json   dashboardUrl, the real port
~/.config/omarchy/paperclipai/skills/           the user's own skills for this session
<plugin>/bin/                                   status, setup, service, doctor, open
```

## Order of work

1. Name the fault in one sentence from the probe and the bundle.
2. Say what you will change, and why, before you change it.
3. Make the smallest change that can fix that fault. One change at a time.
4. Check: `curl -fsS <apiBase>/api/health` must answer `{"status":"ok"}`.
5. When it is back, run `omarchy-shell shell rescanPlugins` so the bar widget
   shows it, and tell the user what the fault was.

## Rules

- Never delete anything under `~/.paperclip`. It holds the user's work.
- Do not reinstall or reset the instance to clear a fault you have not named.
- Explain each change before you make it.
- Stop and report if the fix needs a password, a token, or a paid account.
- The user is at the keyboard. Ask them when a choice is theirs to make.
