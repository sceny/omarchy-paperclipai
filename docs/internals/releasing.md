# Pull requests and releases

`develop` is where work lands; `main` is what users get. Every change is a
short-lived branch from `develop` and a pull request into it. The steps for a
release are in [AGENTS.md](../../AGENTS.md), *Releasing*. This page holds the
chain every release follows, the checks that close one, and their templates.
Releasing a version to Omarchy is always the owner's call: releases, `main` and
the marketplace are the plugin manager's to run, never the author's.

Nothing private goes in a commit, an issue or a pull request: no tokens,
instance ids, host names, owner data, and no description of an unfixed
vulnerability.

| Check | Who | When |
|---|---|---|
| Review with a security check | Panel QA | every pull request |
| Regression in the rig | Panel QA | before every release |
| Cold install and upgrade | Plugin DevOps runs, Panel QA passes | before every release |
| Marketplace check by hand | Plugin DevOps | before every release, on the candidate |
| Security review | the Plugin Security Reviewer | every release, patch included, opened with the regression |
| Go | the owner | before anything touches `main` or the marketplace |

## The release template

Every release is the same chain of tasks, created together when the release is
started. Nothing is added by hand later: a task found missing is a change to
this template. `X.Y.Z` is the version.

| Kind | When | Branch | Pull request into |
|---|---|---|---|
| **minor** | a new feature on `develop` | `release-X.Y.Z` from `develop` | `develop`, then `develop` into `main` |
| **patch** | fixes only on `develop` | the same as minor | the same as minor |
| **urgent** | a fix users need now, or a maintainer's finding on the marketplace issue; only after the owner's go for it | `fix-X.Y.Z` from `main` | `main`, then `main` into `develop` |

| # | Task | Role | After | Done when |
|---|---|---|---|---|
| R0 | the release (holds the status page) | the plugin manager | R1 to R7 | the freeze check is clean, the release is published, the marketplace issue is filed or not needed, both trackers are closed |
| R1 | prepare: `dev/release-prepare X.Y.Z` (version, CHANGELOG section, branch); for urgent, the fix itself is on this pull request | Panel Engineer | | the head has the version and its CHANGELOG section (`dev/release-notes` prints it); `test` is green on the first push |
| R2 | review with security check (the regular pull-request review) | Panel QA | R1 | PASS on the candidate SHA; for minor and patch, merged into `develop` |
| R3 | regression in the rig, cold install, upgrade from the live tag, marketplace check by hand | Plugin DevOps runs, Panel QA gives the verdict | R2 | the regression record is PASS on the candidate SHA, with the *needs the owner's setup* list, which holds every open `needs-owner-setup` issue; the marketplace check passed on the candidate |
| R4 | release security review: the whole plugin, plus `last-tag..candidate` | the Plugin Security Reviewer | R2 | PASS on the candidate SHA; a FAIL rejects the candidate |
| R5 | the owner's machine on the candidate | Plugin DevOps | R3, R4 | the owner's folder is at the SHA and the shell is restarted after (*The owner's request*) |
| R6 | the owner's go: the status page and nothing else | the chief of staff carries it to the owner | R5 | the owner said go or no for that SHA |
| R7 | merge, tag, publish, back to `develop` (*Releasing* steps 2 and 3; the owner's machine back to `develop`) | Plugin DevOps | R6 | tag `vX.Y.Z` on a merge commit, never a squash; the release is published; `develop` is level with `main` |

On R0, the plugin manager then files or edits the marketplace issue and opens
the `marketplace-review` tracking issue (*Releasing* step 4) and runs the
freeze check. A step only the owner's account can do on the marketplace issue
is a named step for the chief of staff, once, in this chain.

- **The candidate is the head of R1's pull request when R2 passes.** R3 and R4
  start only then. A new commit on it voids R2 to R6: each runs again on the
  new head, and no task is created.
- **R4 is always the full review.** Its kind is never decided per release.
- **R6 is asked only when the status page reads PASS for R2, R3, R4 and R5, all
  on one SHA.**
- **A maintainer's finding** starts an urgent chain for the next Z. Its R1
  fixes the class (*Every pull request*), not only the case.
- **The `release` and `marketplace-check` workflows run on a pull request into
  `main`.** For minor and patch that pull request opens at *Releasing* step 2,
  after the go, so the status page cannot hold their result: R3 runs the
  marketplace check on the candidate by hand, and `dev/release-notes` in R1
  shows the CHANGELOG section the `release` workflow will read. Both workflows
  must then be green on the pull request before it is merged. An urgent
  chain's R1 is a pull request into `main`, so all three run on its first push.

## The release status page

One page holds the state of a release and is kept current on R0: the owner
and the team read it, and the go request is this page and a link to it. It
changes when a check's verdict or the candidate changes, never because time
passed. It holds nothing private beyond what the tasks already hold.

```markdown
# Paperclip X.Y.Z: <minor | patch | urgent>

**Candidate:** `<full SHA>` (head of <pull request link>)  ·  **Freeze:** none | marketplace #<n> open
**Why this release:** <one line; for urgent, the finding, linked>

## Pre-go checks (all PASS on the candidate SHA before the go request)

| Check | Task | Verdict | On SHA |
|---|---|---|---|
| CI (`test`) | <pull request checks link> | green / red | `<sha>` |
| Release notes (`dev/release-notes`) | R1 | section found / missing | `<sha>` |
| Review with security check | R2 | PASS / FAIL / not yet | `<sha>` |
| Regression in the rig | R3 | PASS / FAIL / not yet | `<sha>` |
| Cold install, upgrade from vLAST | R3 | PASS / FAIL / not yet | `<sha>` |
| Marketplace check by hand | R3 | PASS / FAIL / not yet | `<sha>` |
| Release security review | R4 | PASS / FAIL / not yet | `<sha>` |
| Owner's machine on the candidate | R5 | done / not yet | `<sha>` |

## Needs the owner's setup (for the owner)
- <item>, or *none*
- <every open issue labelled `needs-owner-setup`: one line with its link>, or *none*

## Outside findings this release answers
- <finding, link>, then <fix pull request>, then <its class test or lint>

## Next
- **<step>**, <role>, <after which task>
```

A row on another SHA than the candidate counts as not done. Nothing in the
table is removed or shortened for any kind.

## Preparing the branch: `dev/release-prepare`

A release pull request has its version and CHANGELOG section from the first
push. The `release` check on a pull request into `main` needs them: the version
in `manifest.json` has a `## X.Y.Z — YYYY-MM-DD` section in `CHANGELOG.md` with
entries and no tag yet. The script makes a branch that passes it before
anything is pushed.

```bash
dev/release-prepare 0.3.0                                         # release-0.3.0 from origin/develop
dev/release-prepare 0.2.1 --from main --note "What the fix does"  # fix-0.2.1 from origin/main
```

- From `develop`, `## Unreleased` becomes the version's section (it must have
  entries). From `main` there is no Unreleased section: the section is added
  above the newest version with each `--note` under *Fixes* (at least one).
- It sets `"version"`, commits both files (`--no-commit` leaves them staged, uncommitted)
  and prints the next step. Write the section's remaining groups after it.
- It refuses a version already tagged (here or on origin), one not above the
  base's version, one the base's CHANGELOG already has, an empty Unreleased
  section, an existing branch and a tree with tracked changes.
- Tested in `test/test_release_prepare.py`, which runs `dev/release-notes`,
  the `release` workflow's own extraction, on what the script wrote.

The release pull request into `main` is merged with a merge commit. GitHub has
no per-pull-request check of the merge method, so the pull request's `release`
check prints a reminder and the `release` run on `main` fails, after tagging
and publishing, when the tagged commit has one parent. Merge `main` into
`develop` meanwhile and use a merge commit for the next release.

## Every pull request

Run the checks with `test/run_all.sh`. A pull request that breaks one is not
merged. The reviewer (Panel QA) reads this list against the diff, and the author
never certifies their own change. The promises behind the list are in
[`docs/security.md`](../security.md).

1. **Values from outside never reach a command as an option or a page as markup.**
   Every value from the API or from agents (titles, details, names, `whyNow`)
   passed to a CLI is neutralised against option parsing (no leading `-`), and
   is escaped wherever it is rendered as markup. A url from the API opens only
   on the API's own origin (scheme, host and port). A notification's words go
   to the daemon over D-Bus from stdin, not on a command line.
   Check: [`test/test_model.mjs`](../../test/test_model.mjs) (notification text),
   [`test/test_notify.py`](../../test/test_notify.py) (notification over D-Bus),
   [`test/test_open.mjs`](../../test/test_open.mjs) (window match, own origin),
   [`test/test_security_rules.py`](../../test/test_security_rules.py) (plain QML text).
2. **Nothing a person or an agent wrote reaches an AI session.**
   Nothing a person or an agent wrote goes into the doctor bundle, `AGENTS.md`,
   `prompt.txt` or any other AI-session input. The session is told that its
   files are untrusted data.
   Check: [`test/test_doctor_session.mjs`](../../test/test_doctor_session.mjs).
3. **HTTP clients are boxed in.**
   They follow no redirects, cap response size, and send nothing, token or not,
   except to an own-uid loopback listener or over https.
   Check: [`test/test_transport.py`](../../test/test_transport.py),
   [`test/test_transport.mjs`](../../test/test_transport.mjs).
4. **State is private and does not pile up.**
   Files under the state directory are created with umask 077. Private text has
   a retention limit; a token file others can read is not used.
   Check: [`test/test_state.py`](../../test/test_state.py).
5. **Diffs stay reviewable.**
   No tracked text file contains a NUL byte.
   Check: [`test/test_security_rules.py`](../../test/test_security_rules.py).
6. **QML text is plain unless the plugin wrote it.**
   A new `Text`/`Label` in QML uses `textFormat: Text.PlainText` unless it
   renders only plugin-owned strings. The check is strict: it takes every
   `Text` and `Label` in `*.qml`, so a plugin-owned string gets the line too.
   Check: [`test/test_security_rules.py`](../../test/test_security_rules.py).
7. **Private text never reaches a command line.**
   `/proc/<pid>/cmdline` is readable by every local user. No title, reason,
   name or other text from the instance or an agent is an element of an argv
   the QML starts (`Util.execArgv`, `command:`, `.command =`). Every argv element
   that is not a string literal is on a reviewed allowlist in the test, with the
   reason it is not private text; a new one fails until a reviewer adds it. The
   notification text goes to `bin/omarchy-paperclip-notify` on stdin. A function
   whose parameter is an allowed bare name has every call of it read the same way.
   A value given by a compound assignment (`argv += x`, `id ||= x`) is read like one given by `=`.
   No script in `bin/`, `lib/` or `dev/` builds a shell string (`shell=True`,
   `os.system`, `bash -c`, `sh -c`) unless the line is on the allowlist with a reason.
   Check: [`test/test_private_text.py`](../../test/test_private_text.py),
   [`test/test_shell_argv.py`](../../test/test_shell_argv.py).
8. **Nothing reads the clipboard without a paste by the user.**
   No `*.qml` uses `TextInput`, `TextField`, `TextArea`, or an Omarchy `qs.Ui`
   component built on one (`NumberField`, `MultiSelect`, `SearchableDropdown`):
   Qt reads the clipboard in them by itself. No `clipboardText`, `wl-paste` or
   `cliphist` anywhere. A future text field is a plain-text `TextEdit`, never
   toggled read-only, as the Devices plugin's `PanelField`.
   Check: [`test/test_private_text.py`](../../test/test_private_text.py).

A line marked `pending` has no check yet; the task named there adds it and
changes the line. `test/test_security_rules.py` fails when a line has neither a
check that exists nor a `pending` mark, so the list and `test/` cannot drift
apart.


## Public text of a pull request

`dev/public-text-check` holds the rules in `dev/public-text-rules.json` and
fails the `public-text` check on a pull request whose body, comment, review or
review comment: names the setup (`public-text-environment`: the tools, paths,
test counts, task numbers); says something is left with no issue reference in
its bullet or paragraph (`open-item-no-owner`); or names another repository's
issue without its owner (`unlinked-reference`). The failure names the text's
URL, the check and the matched words; the author or reviewer edits the text and
the check runs again on the edit. Every run reads all the pull request's text
through the API, so a plain comment is read on the next run of any event.

- Paperclip is this plugin's product: only the words for the tracker that
  runs our work (`Paperclip task`, `board`, `ticket`, `heartbeat`) fail.
- A pull request about a tool may name it (`allowed_when_changed`); a pattern
  that catches a product word gets an exception in the rules file and a case
  in `test/test_public_text.py`, which holds a failing example of every class.
- The same rules check the standing texts (`AGENTS.md`, `docs/internals/`) for
  task numbers, dates and the owner's words as history, in the unit tests
  (`dev/public-text-check --standing`).
- `public-text` is a required status check on `develop` (a repository ruleset,
  no bypass). A direct push to `develop` is refused, so the `release` workflow
  posts a `public-text` success status on the `main` commit it brings
  `develop` level with (a push to `main` has no pull request text).
- The checker and its rules are the same files as in `sceny/omarchy-devices`;
  a change to a class goes to both repositories.

## Every pull request into `main`: the marketplace's checks

The `marketplace-check` job runs the marketplace's own validation and
security baseline (the two steps of its *Validate plugin update* workflow,
taken from `omacom/omarchy-plugin-marketplace` `main`, not copied) on the
pull request's head commit, so their answer reaches us before the bots'.
`dev/marketplace-check.mjs` only gives those scripts that commit. The job
summary holds the bots' two reports, word for word. The job fails when the
validation fails, the baseline says it needs fixes, or the check cannot
complete (a change in the marketplace's scripts shows up here first). A
baseline that needs a maintainer's review passes, with a warning naming any
capability new since the listed snapshot.

Paperclip is not on the marketplace yet, so there is no listing to update. The
job validates the commit's manifest and files and runs the baseline as a
submission, and the job summary says so. Once the plugin is listed, the same
file takes the update path.

Run it on any commit (a candidate) by hand, as R3 does:

```bash
git clone --depth 1 https://github.com/omacom/omarchy-plugin-marketplace /tmp/mp
(cd /tmp/mp && npm ci)
GITHUB_TOKEN=$(gh auth token) MARKETPLACE_DIR=/tmp/mp node dev/marketplace-check.mjs <full-sha> /tmp/reports
```

Exit 0: both ran. 1: the marketplace would answer *needs fixes*. 2: the check
could not complete. *Run workflow* on the `marketplace-check` workflow does the
same for any commit once the workflow is on `main`.

## Regression in the rig

Panel QA runs the whole plugin in the rig (`dev/rig ci`, or `dev/rig up`, then
`dev/rig check`, `dev/rig seed` and `dev/rig screenshot`), on the candidate: the
head of `develop` after the release pull request is merged. Every feature gets
one pass or fail against its rule in `AGENTS.md`, not only what changed: the
bar mark and count, each panel list and its filter cards, a row opening its
item, snooze and focus, notifications, the setup, service and doctor scripts.

The rig has its own HOME, shell and throwaway instance (`README.md`, *Testing
the plugin*). Nothing runs against the owner's desktop or their instance. The
panel is looked at, not only measured.

The record is a document on the release task:

| Feature | Rule (AGENTS.md) | How checked | Pass/fail | Evidence |
|---|---|---|---|---|
| Panel: filter cards | 2, the instance is the truth | `dev/rig seed`, click each card, `dev/rig screenshot` | pass | `filter-1.png`..`filter-3.png` |

- *Rule* names the rule by its number.
- *How checked* is a command or IPC call someone else can repeat.
- *Evidence* is a screenshot, a log line or a test name, from the rig only.
- A fail is a GitHub issue, fixed on `develop`, and the row is checked again
  on the new head. A release does not go with a fail.

### Needs the owner's setup

What the rig cannot judge goes in a separate list on the same document, not in
the record as a pass: the owner's own notification daemon and Do Not Disturb
settings, their bar and monitors, a board token on a real remote instance, the
web app window in their browser.

| What | Why the rig cannot | What the owner does | Result |
|---|---|---|---|

The list also holds every open issue with the label `needs-owner-setup`
(`gh issue list --label needs-owner-setup --state open`), one row each with
its link. That label marks a check that only a real Omarchy session can run;
put it on the issue when you file one. The row comes from the issue, not from
the regression, so a fix verified only headless does not reach `main` without
its real-session check asked for. After the owner's go, each such issue is
closed with the result commented, or stays open, for the next list, if it was
not run.

The plugin manager sends the list to the owner as one request (*The owner's
request*) that says exactly what to do and why. An item stays open until the
owner has done it or waived it, and the go waits for it.

## Cold install and upgrade

Both start from the tag that is live now (`git tag`, the latest `vX.Y.Z` on
`main`). Plugin DevOps runs them in the rig and Panel QA passes them.

**Cold install.** The rig starts with an empty HOME, no state directory, no
token and none of the plugin's skills: that is a cold computer. Run
`omarchy-paperclip-setup` in it. Every step finishes by itself or stops at the
user's one step, and no package is asked for twice. Each step is a row with its
evidence, and what the rig cannot prove goes on the *needs the owner's setup*
list.

**Upgrade.** Install the live tag in the rig with a state directory that holds
a snooze state, then move to the candidate. The old state reads back unchanged,
nothing is written until the user changes something, and the shell answers over
IPC after the restart: a QML error takes the whole widget off the bar, and it
can be logged after a quick log check has already passed.

Both results go into the regression record as rows.

## Security review of the release

Every release, patch included, gets a pass over the whole plugin against its
threat model (`docs/security.md`), with `git diff <last-tag>..<candidate>` on
top. The task opens with the regression, when the release branch is prepared,
and the verdict is given on the candidate once the regression has passed. The
review goes beyond the per-pull-request list, which is assumed already run: it
looks for faults nobody has met yet. It traces untrusted input through the
whole code path, unchanged code included.

The attackers:

- Another local user or process: `/proc`, file modes in the state directory,
  ports on `127.0.0.1`, the session D-Bus, logs.
- Text from the instance, written by a person or an agent: titles, details,
  names and urls, wherever the plugin shows, passes or stores them, and every
  input of an AI session the plugin opens.
- The token: where it is read, where it is sent, what could redirect it.
- A listener or server on the other end of a request: a redirect, a huge
  answer, a slow one, a loopback port another user holds.
- Supply chain and CI: packages, workflows, copied skills, what the
  marketplace bots report.
- Data on disk and in logs: caches, temporary files, repair logs, retention.
- Input with no size or time limit: a cap before the shell, a bound on
  processes.
- Work at rest: the panel closed, hidden or folded.

The review also lists the capabilities the marketplace bot will report, for the
maintainer's review.

- A finding is reproduced where possible.
- Every finding gets a search for the same class across the plugin.
- An unfixed vulnerability stays off public GitHub (issues, commits, pull
  request text) until its fix is released.

The verdict is a document on the release task: pass, or findings with file
and line. Findings are fixed on `develop`; a fix changes the candidate, so the
changed head is regressed again where the fix reaches.

A FAIL from the Plugin Security Reviewer rejects the candidate. It is fixed and
re-reviewed on the new head, or the release does not happen. Nobody downgrades
or waives it; only the owner can.

When anyone outside finds a security issue in a released version, the Plugin
Security Reviewer writes on the release task why the review missed it and what
class is added to the threat model and to the per-pull-request list above.

## The owner's request

The owner is asked for the owner's-setup checks and the go once per release,
and only when nothing an agent can check is left open. This is the standing
rule for every release closing, not for one version.

- **One exact SHA.** Every agent check of the release (the pull-request
  reviews, the full regression, the cold install, the upgrade, the marketplace
  check, the security review) has passed on the same candidate SHA. The request
  names that SHA.
- **A new commit voids.** A commit on the candidate voids every check and any
  open request. The checks run again on the new head before anyone asks.
- **The owner's machine runs the SHA.** Before the request, its plugin folder
  is at the SHA (`git rev-parse HEAD` in it) and the shell is restarted after
  the folder changed (`omarchy-restart-shell`; a rescan does not reload a
  loaded plugin), and the panel answers over IPC. This repository has no
  `dev/loaded-code` yet; when it has, R5 runs it and it must exit 0. Plugin
  DevOps does this, never a command the owner pastes and runs.
- **Back to `develop`.** After the checks, the owner's machine goes back to
  `develop` the same way, so `dev/follow-develop` follows it again.
- **Once, with every item.** The request holds the regression record, the
  security verdict and the whole *needs the owner's setup* list. The owner
  installs and runs nothing; they only use their desktop and answer.

## The owner's go

The owner answers go or not for this release on that request.

- Until the go, nothing is merged into `main`, tagged or released, and
  nothing is filed on or edited in the Omarchy marketplace.
- A go covers one release. The next release asks again.
- An urgent fix for users is a release: it asks for its own go, with a
  shorter record that names what the fix touches.
- The first marketplace submission is a request of its own on the go: the
  owner confirms the five statements of the submission checklist, and sees the
  issue's title and body before it is created.

Then *Releasing* steps 2 to 6 run as written.

## Questions from outside

The maintainer's comments on a marketplace issue, replies on an open upstream
report, and new issues and pull requests on the plugin repository are
answered or routed the day they arrive. The plugin manager runs a daily check
over all three. An answer that needs the owner goes to the owner through the
chief of staff, once, with a recommendation. A finding from a maintainer is a
fix in the plugin before it is a reply.
