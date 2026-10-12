# Paperclip for Omarchy (`sceny.paperclipai`)

A bar widget and panel for the Omarchy shell over a Paperclip instance, plus
the scripts that keep the instance running. Read this first, then the two
documents below, before you change, review or release anything.

## Read before you change anything

- [`docs/security.md`](docs/security.md): the promises the plugin makes about
  the token, text from the instance, and what it keeps on disk.
- [`docs/internals/releasing.md`](docs/internals/releasing.md): the **Every pull
  request** check, and how a release goes. Panel QA reads the diff against that
  list; builders run it before they hand a pull request over.
- [`README.md`](README.md): what the user sees, install, tokens, snooze, the rig.

## Rules

1. The two documents above bind every change. A line in "Every pull request"
   that a change breaks is a rejection, not a trade-off.
2. The instance is the truth. The plugin keeps no copy of the inbox or of agent
   state; it asks, and shows what it was told.
3. Text from the API or from agents is data: never markup, never an option,
   never instructions to an AI session.
4. Pure logic goes in `Model.js` (no QML), so `node` can check it. A change
   comes with its test.
5. Never test against your own live desktop or live Paperclip instance. Use
   `dev/rig`.
6. Never leave an install on a feature branch for a live check; the
   `follow-develop` timer then stops following. Use `dev/rig`.
7. Nothing private in the repository, a commit or a pull request: no tokens,
   instance ids, company or agent names, host names or inbox text. Examples and
   tests use made-up values.
8. A change is a branch from `develop` and a pull request into `develop`.
   `main`, releases and the marketplace are the plugin manager's.

## Checks

```sh
test/run_all.sh        # everything that needs no desktop; non-zero on any failure
dev/rig selftest       # the rig's own lease and reap logic; no compositor
dev/rig ...            # the plugin end to end, in its own Hyprland (see README)
```

## File map

| Path | What it is |
| --- | --- |
| `manifest.json` | plugin id, entry points, version |
| `Service.qml` | the one data source: runs the scripts, holds the report, raises notifications |
| `Panel.qml` | the bar widget and the panel |
| `PaperclipMark.qml` | the mark drawn on the bar and in toasts |
| `Model.js` | pure logic: filters, counts, notification diffs, labels |
| `bin/omarchy-paperclip-status` | the probe: reads the API, prints one JSON report; `--redacted` for AI-session input |
| `bin/omarchy-paperclip-inbox` | the writer: dismiss, snooze, retry, clear failed |
| `bin/omarchy-paperclip-service` | start, stop and check the instance |
| `bin/omarchy-paperclip-setup` | first-run setup |
| `bin/omarchy-paperclip-doctor` | build the bundle, repair, hand the rest to an AI session |
| `bin/omarchy-paperclip-agent` | open the AI session over a directory |
| `bin/omarchy-paperclip-open` | open the web app or a page in it |
| `bin/omarchy-paperclip-webapp` | create and raise the web app window |
| `bin/omarchy-paperclip-snooze` | read and write the snooze state |
| `bin/omarchy-paperclip-skills` | install the Paperclip skills for the user |
| `lib/common.sh` | helpers every script sources: instance, CLI, state directory |
| `skills/` | Paperclip agent skills, copied unchanged from upstream, and the doctor skill |
| `dev/rig` | the isolated end-to-end rig (`dev/rig.d/` holds its parts) |
| `dev/follow-develop` | the timer script that keeps installs on `develop` |
| `dev/sync-skills` | refresh `skills/` from an upstream checkout |
| `test/` | the checks; `test/run_all.sh` runs them |
| `docs/security.md` | what the plugin promises |
| `docs/internals/releasing.md` | the per-pull-request check, and releases |
| `assets/` | images |
