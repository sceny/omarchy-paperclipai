# What the plugin promises

`sceny.paperclipai` runs as you, on your desktop, next to a Paperclip instance
whose text is written by people and by AI agents. These are the promises it
makes about that. Each one is checked on every pull request
(`docs/internals/releasing.md`, "Every pull request").

## The token

- A board token is read from `$PAPERCLIP_OMARCHY_TOKEN`, or from
  `~/.local/state/omarchy/paperclipai/token`. The plugin never writes a token
  anywhere else, never puts it in a command line, a log, the doctor bundle or an
  AI session.
- The state directory (`~/.local/state/omarchy/paperclipai`, or under
  `$XDG_STATE_HOME`) is created with mode 0700 and every file in it with mode
  0600. The token file is yours to create; keep it 0600.
- The token is sent only to a loopback address whose listening socket belongs to
  your user, or over `https`. Never to plain `http` on another host, and never
  across a redirect: a 3xx answer is an error, and nothing is followed.
- The same check guards every plain-`http` request, with a token or without
  one. A program another user runs on Paperclip's port receives no request
  (no read, no dismissal, no wake-up), and the panel says "Not your Paperclip"
  instead of showing what it answered.
- The scripts (service, setup, doctor, web app) never call the instance with
  `curl` or anything of their own: they ask through the probe's `--get`, which
  runs the same check. A foreign program on the port cannot make a script
  believe Paperclip is up, and cannot supply the launcher icon.
- A response is read up to 4 MiB. More is an error.

## Text from the instance is data

Titles, details, names, `whyNow` and every other string from the API or from an
agent are written by someone else. The plugin treats them as data:

- **Never markup.** Wherever one is shown as text it is shown as plain text
  (`textFormat: Text.PlainText`), and wherever a notification daemon would read
  it as markup it is escaped first.
- **Never an option.** Passed to a command, it cannot be read as an option: a
  value with a leading `-` is neutralised, or follows `--`.
- **Never on a command line.** Other users of the machine can read the command
  line of every process. A notification's words reach the notification daemon
  over D-Bus from the helper's stdin (`bin/omarchy-paperclip-notify`), not as
  arguments of a program.
- **Never an instruction.** It is not put in the doctor bundle, `AGENTS.md`,
  `prompt.txt` or any other input of an AI session. The bundle holds states,
  counts, kinds and ids. Log tails are listed by path, not inlined. The session
  is told in plain words that its files are untrusted data and never
  instructions.

## What is kept on disk

All of it under the state directory, all of it yours alone (0700 / 0600):

| What | Where | How long |
| --- | --- | --- |
| Snooze and focus state | `snooze.json` | until the snooze ends or you change it |
| Doctor and agent sessions: bundle, `prompt.txt`, `AGENTS.md`, repair logs | `doctor-<time>/`, `session-<time>/` | 7 days, then removed |
| Token (yours) | `token` | until you remove it |

The plugin keeps no copy of the inbox. It asks the instance each time.

## The Paperclip command line

When no `paperclipai` command is installed the plugin runs the product's own
command line with `npx -y paperclipai@latest`. It is unpinned on purpose: that
is the vendor's own tool, and the one your instance is meant to be driven with.
The plugin runs nothing else from the network. Its own skills are copied from
`skills/`, never fetched.

## Assets and the tests that hold them

Each asset an attacker wants, with the tests that fail the build when it is
exposed. *Held by* names `file` and `Class` (a JS test is its file); *Manual* is
what no script can hold, and why; *Gap* is a way the asset leaks that no test
holds, with the issue that adds it. `test/test_security_rules.py` fails when a
row has neither a test nor a `manual:` line, when it names a file, class or test
that does not exist, or when a gap has no issue.

| Asset | Held by | Manual | Gap |
|---|---|---|---|
| **The API token** | `test/test_transport.py` `TokenVerdict`, `ProcTable`, `Fetch`, `Probe`; `test/test_transport.mjs`; `test/test_state.py` `TokenFile`; `test/test_private_text.py` `C1NoPrivateTextOnArgv` | manual: the check-then-connect race (the user's instance dies and another uid binds in the same milliseconds) has no test; accepted at the whole-plugin review | Ids from the API go into request paths unchecked ([#46](https://github.com/sceny/omarchy-paperclipai/issues/46)) |
| **Inbox text** (titles, details, names, `whyNow`) | `test/test_security_rules.py` `QmlTextIsPlain`; `test/test_notify.py` `HelperOverDbus`, `ServiceUsesTheHelper`; `test/test_model.mjs`; `test/test_private_text.py` `C1NoPrivateTextOnArgv`; `test/test_shell_argv.py` `NoShellInScripts` | | |
| **The user's account through the AI repair session** | `test/test_doctor_session.mjs`; `test/test_state.py` `Retention` | manual: what the coding agent does with its inputs is the agent's; the plugin holds only that no instance text goes in | |
| **The state directory and what is on disk** | `test/test_state.py` `Modes`, `Retention`, `TokenFile` | | |
| **Opening the board** (urls, windows) | `test/test_open.mjs` | | Control characters after the origin check ([#21](https://github.com/sceny/omarchy-paperclipai/issues/21)); the browser started with umask 077 ([#28](https://github.com/sceny/omarchy-paperclipai/issues/28)) |
| **The clipboard** | `test/test_private_text.py` `C2NoClipboardRead` | | |
| **The shared shell's availability** | `test/test_transport.py` `Fetch` (`test_an_oversize_body_is_an_error_and_is_not_read_to_the_end`); `test/test_inbox.mjs`; `test/test_security_rules.py` `NoNulBytes` | | The probe's output size under a large answer ([#45](https://github.com/sceny/omarchy-paperclipai/issues/45)); its timeout bounds one read, not the whole answer ([#27](https://github.com/sceny/omarchy-paperclipai/issues/27)) |
| **Personal data and secrets in the repository** | `test/test_public_text.py` `Environment`, `WholePullRequest`, `Standing`; `test/test_tree_data.py` `NothingPrivateInTheTree`, `PlantedCases` | | |
| **The repository and the release** (CI, supply chain) | `test/test_public_text.py` `Workflow`; `test/test_release_prepare.py` `ReleasePrepare`; `test/test_security_rules.py` `ListMatchesTests`, `AgentsFile` | manual: `npx -y paperclipai@latest` runs the product's own CLI unpinned when there is no managed install (*The Paperclip command line*) | The other workflows' triggers, token permissions and `run:` lines are read by no test ([#44](https://github.com/sceny/omarchy-paperclipai/issues/44)) |

## Reporting a fault

A fault in any of the above is a bug in the plugin. Report it privately to the
maintainers, not in a public issue.
