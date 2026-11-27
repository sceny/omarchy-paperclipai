[Paperclip](README.md) › What's new

# What's new

Each version, newest first, grouped by what it touches. `omarchy plugin
update sceny.paperclipai` brings the latest; each is a tag (`vX.Y.Z`) and a
GitHub release with these notes.

## 0.3.1 — 2026-11-27

### Highlights

- **Quieter on a busy instance**: the widget reads Paperclip once a minute
  (every 20 seconds with the panel open), and the closed bar asks for the
  open inbox only.
- **Toasts only for what is new and needs you**: `Needs-me` raises a toast
  for pending decisions alone, and an outage, turning notifications back on,
  opening the panel or a row snoozed in Paperclip no longer replays the inbox.
- **Hardening**: a whole answer from the instance has a deadline, ids and
  urls are checked before they are used, and the status report stays small
  whatever the instance sends.

### Fixes

- **Turning notifications back on no longer replays the meantime.** What
  arrived while *Desktop notifications* was `Off` is marked seen, as it is
  while the plugin is snoozed, so switching to `Needs-me` or `Everything`
  raises a toast only for what arrives after.
- **Opening the panel no longer toasts rows that were already waiting**: with
  more than 20 rows in the inbox, the first open listed the rest and raised
  "N things need you" for them. A row the widget never listed now toasts only
  if it moved after the shell started (#127).
- **A row snoozed in Paperclip stays out of the plugin** until its snooze ends:
  it is not listed, counted or toasted, under either inbox filter, and Retry
  all leaves it alone. The `All` filter now adds only the rows you cleared;
  they raise no toast and are not in the bar's count. A row whose snooze ran
  out, or that moved after you cleared it, is open again and toasts once.
- **A short outage no longer replays the inbox as toasts**: when Paperclip
  stopped answering for one poll, the next answer raised a toast for every row
  again. Now nothing is replayed; at `Everything` only the stop and the start
  are announced. The same holds for a missing token, an inbox or run list the
  instance did not send, and closing the panel.
- **A slow answer no longer holds the probe**: the request timeout (6 seconds
  by default) now bounds the whole answer, connection and body together. A
  listener that sent a byte every few seconds kept one read going for as long
  as it liked.
- **No *Create the web app* at an address that is not your Paperclip**: when
  another program holds Paperclip's address, the panel shows the problem and
  offers nothing that opens or creates something there.
- **The browser starts with your session's umask**: a page or task opened
  from the panel started the browser with the plugin's own `077`, so its
  downloads and profile files were readable by you alone. The plugin's own
  files stay private.
- **Keep Paperclip running restarts a crash after a start from a terminal**:
  a stop recorded earlier now ends when the plugin sees Paperclip answering
  again, however it was started. Until now `systemctl --user start` from a
  terminal left the stop in place, and a later crash was not restarted until
  the shell restarted.

### Security

- **A url with a control character in it is not opened**: a newline, tab or
  other control character after the instance's address is refused before the
  browser sees it.
- **An id goes into a request only in the server's own shape**: a company,
  agent or task id holding `/`, `?`, `#`, `..` or any other character outside
  letters, digits, `-` and `_` is refused before anything is sent, so a
  request cannot reach another endpoint of the instance.
- **The status report stays small whatever the instance answers**: every
  name is cut at 80 characters, and an id, key or link longer than its limit
  is left out rather than passed on. A report with thousands of rows or
  megabyte names is at most the capped rows of short text.

### Upgrading

- **The widget reads Paperclip once a minute** (was every 20 seconds), and
  at least every 20 seconds while the panel is open (was 10). Each read asks
  the server for every company's inbox, which is heavy on a busy instance.
  The new default applies only where *Refresh interval* was never set; an
  interval you chose is kept. An action you take still refreshes the panel
  right after it. With the panel closed, the `All` filter reads only the open
  inbox, one query per company: the rows you cleared are fetched when the
  panel opens.
- **Desktop notifications at `Needs-me` are for pending decisions only**: an
  approval, a question or confirmation an agent asked, a join request. Reviews,
  blockers, budget alerts, failed runs and the instance stopping no longer
  raise a toast at this level; they stay in the panel and the bar count, and
  `Everything` still announces them. The stored setting is unchanged.

### Issues

- [#120](https://github.com/sceny/omarchy-paperclipai/issues/120) Notifications: Needs-me should toast pending decisions only
- [#123](https://github.com/sceny/omarchy-paperclipai/issues/123) Notifications: a moment's outage replays every inbox row as a toast
- [#124](https://github.com/sceny/omarchy-paperclipai/issues/124), [#130](https://github.com/sceny/omarchy-paperclipai/issues/130) The snooze-over count and the bar's count under the All filter include snoozed and cleared rows
- [#126](https://github.com/sceny/omarchy-paperclipai/issues/126) Turning notifications back on replays what arrived while they were Off
- [#127](https://github.com/sceny/omarchy-paperclipai/issues/127) Opening the panel for the first time toasts the rows past the bar's short list
- [#132](https://github.com/sceny/omarchy-paperclipai/issues/132), [#134](https://github.com/sceny/omarchy-paperclipai/issues/134) Read the attention feed less often, and once per company under either filter
- [#99](https://github.com/sceny/omarchy-paperclipai/issues/99), [#131](https://github.com/sceny/omarchy-paperclipai/issues/131) Regression and self-test rows that could not fail, or failed once
- [#100](https://github.com/sceny/omarchy-paperclipai/issues/100), [#107](https://github.com/sceny/omarchy-paperclipai/issues/107) The process-list check: more tools, argv lists and prefix commands
- [#108](https://github.com/sceny/omarchy-paperclipai/issues/108), [#110](https://github.com/sceny/omarchy-paperclipai/issues/110), [#137](https://github.com/sceny/omarchy-paperclipai/issues/137), [#140](https://github.com/sceny/omarchy-paperclipai/issues/140), [#141](https://github.com/sceny/omarchy-paperclipai/issues/141) The `public-text` check: its rules, drift from Devices, and its runs on `develop`
- [#139](https://github.com/sceny/omarchy-paperclipai/issues/139), [#148](https://github.com/sceny/omarchy-paperclipai/issues/148), [#149](https://github.com/sceny/omarchy-paperclipai/issues/149) develop-notice: a merge-queue push assigns its notice

### Pull requests without an issue

- [#125](https://github.com/sceny/omarchy-paperclipai/pull/125) Notifications: a row snoozed in Paperclip stays out of the plugin
- [#146](https://github.com/sceny/omarchy-paperclipai/pull/146) After 0.3.0: probe deadline, untrusted-address action, browser umask, stop marker, hardening
- [#97](https://github.com/sceny/omarchy-paperclipai/pull/97), [#111](https://github.com/sceny/omarchy-paperclipai/pull/111), [#118](https://github.com/sceny/omarchy-paperclipai/pull/118), [#122](https://github.com/sceny/omarchy-paperclipai/pull/122), [#142](https://github.com/sceny/omarchy-paperclipai/pull/142), [#145](https://github.com/sceny/omarchy-paperclipai/pull/145) Releasing: the reviewer, the release head, the owner's folder, bringing `develop` level with `main`
- [#102](https://github.com/sceny/omarchy-paperclipai/pull/102), [#105](https://github.com/sceny/omarchy-paperclipai/pull/105), [#106](https://github.com/sceny/omarchy-paperclipai/pull/106), [#112](https://github.com/sceny/omarchy-paperclipai/pull/112), [#114](https://github.com/sceny/omarchy-paperclipai/pull/114), [#116](https://github.com/sceny/omarchy-paperclipai/pull/116), [#143](https://github.com/sceny/omarchy-paperclipai/pull/143), [#144](https://github.com/sceny/omarchy-paperclipai/pull/144), [#147](https://github.com/sceny/omarchy-paperclipai/pull/147), [#152](https://github.com/sceny/omarchy-paperclipai/pull/152) The `public-text` and develop-notice checks, and the rig's pipe into `grep -q`

## 0.3.0 — 2026-11-05

### Highlights

- **Start and stop Paperclip from the panel**: a row under the title shows
  whether the instance is running, starting, stopping or stopped, with one
  button (key `v`) for Start or Stop. Stopping an instance with agents at work
  asks once. A change made outside the panel shows in the row within a poll.
  *Keep Paperclip running* respects a stop on every screen and from a terminal,
  and starts Paperclip once for the whole shell, not once per screen.
- **Clicking an inbox row opens that item**: a row opens its page in the
  browser. Only the board itself raises the Paperclip web app window, because a
  raised window takes no address from outside and the click showed nothing.
- **Panel and bar polish**: the summary cards filter the lists (the view only;
  the inbox setting and the bar count stay as they are), the loading line has
  its own row, the version is in the subtitle, and the bar mark and its bubble
  are sized from the bar. A count has a lane of its own beside the mark, in a
  ring of the bar's colour, with larger digits, so a two-digit count reads at
  a glance and never sits on the mark.
- **Follow `develop`** (maintainers): a user timer keeps the installed plugins
  on `develop` current, validates each update, rolls back on a failure and
  restarts the shell afterwards.
- **Made by Sceny**: the README names Sceny near the top and links to the
  Learning Sceny beta, a study app whose memory links fade as you learn.

### Fixes

- **The panel's footer stays in view**: when the list reached the panel's
  height cap, the footer was cut off
  ([#18](https://github.com/sceny/omarchy-paperclipai/issues/18)).
- **No script pipes a download into a shell**: the health and Node checks no
  longer do, which the marketplace's baseline flagged
  ([#25](https://github.com/sceny/omarchy-paperclipai/issues/25)).

### Security

- **The doctor bundle keeps the service's state only**: in 0.2.0 the bundle
  could carry the service's process command lines, agents' keys included, and
  the `--redacted` status check's failure report could carry the server's text.
  The bundle now keeps the service unit's state fields only, and the failure
  report names only the error's type
  ([#93](https://github.com/sceny/omarchy-paperclipai/pull/93)).
  **If you shared a doctor bundle made with 0.2.0, treat the agent keys in it
  as exposed and rotate them.**
- **Urls open only on the instance's own origin**: a url from the instance
  that points anywhere else is not opened.
- **API clients are boxed in**: no redirect is followed, and nothing is sent,
  token or not, except to an `https` address or to a loopback listener that
  belongs to your user. The service, setup, doctor and web app scripts follow
  the same rule: a program another user runs on Paperclip's port cannot make
  them believe Paperclip is up, and cannot supply the launcher icon.
- **Nothing a person or an agent wrote reaches an AI session**: the doctor
  bundle leaves inbox text out, and the session is told its files are
  untrusted data.
- **Private text stays off command lines and the clipboard**: checks on every
  pull request fail on a text from the instance placed on a command line, and
  on any use of the clipboard.

### For contributors

- The isolated rig (`dev/rig`) runs hidden by default, with one owner and a
  lease, so it leaves no stray process behind.
- CI runs every check that needs no desktop on each push and pull request.
- `main` is protected: a ruleset, a `release` environment the owner approves,
  a read-only default token, and a release version check
  ([#94](https://github.com/sceny/omarchy-paperclipai/pull/94)).

### Upgrading

- No setting is added or removed, and no default changes.
- **Keep Paperclip running respects a stop**: a stop from the panel,
  `systemctl` or the CLI now keeps Paperclip stopped until you press Start or
  the shell restarts; before, the setting started it again within ten
  minutes. Turn the setting Off to keep it stopped across restarts.

### Issues

- [#52](https://github.com/sceny/omarchy-paperclipai/issues/52) Panel: start and stop the Paperclip service
- [#55](https://github.com/sceny/omarchy-paperclipai/issues/55) Bar count lane: check one digit, the busy dot and a larger font scale
- [#18](https://github.com/sceny/omarchy-paperclipai/issues/18) Panel footer is cut off when the list reaches the height cap
- [#25](https://github.com/sceny/omarchy-paperclipai/issues/25) Marketplace baseline: curl-pipe-shell finding in `lib/common.sh`
- [#37](https://github.com/sceny/omarchy-paperclipai/issues/37) Lint: no tokens, instance ids, host names or personal data in the tree
- [#38](https://github.com/sceny/omarchy-paperclipai/issues/38) Turn on secret scanning, push protection and Dependabot security updates
- [#39](https://github.com/sceny/omarchy-paperclipai/issues/39) Threat model: each asset names the tests that hold it, with a meta-check
- [#40](https://github.com/sceny/omarchy-paperclipai/issues/40) Releasing: a class is named by its mechanism first; a pass carries forward only on an identical tree
- [#22](https://github.com/sceny/omarchy-paperclipai/issues/22) Release list: collect open needs-owner-setup issues into the owner's-setup list
- [#29](https://github.com/sceny/omarchy-paperclipai/issues/29) Port `dev/loaded-code` from Devices
- [#36](https://github.com/sceny/omarchy-paperclipai/issues/36) Release regression as one committed command, shared with Devices (`dev/regression`)
- [#75](https://github.com/sceny/omarchy-paperclipai/issues/75) Rig: the teardown's stop of the instance and Postgres is not in its timing log
- [#79](https://github.com/sceny/omarchy-paperclipai/issues/79) develop-notice: verify the push trigger and issue creation on a real red push
- [#80](https://github.com/sceny/omarchy-paperclipai/issues/80), [#84](https://github.com/sceny/omarchy-paperclipai/issues/84) public-text failed on develop

### Pull requests without an issue

- [#3](https://github.com/sceny/omarchy-paperclipai/pull/3) Clicking an inbox row opens that item
- [#5](https://github.com/sceny/omarchy-paperclipai/pull/5) Panel and bar layout polish: filter cards, loading bar row, version, bar icon height
- [#67](https://github.com/sceny/omarchy-paperclipai/pull/67) Keep Paperclip running respects a stop on every screen and starts once
- [#2](https://github.com/sceny/omarchy-paperclipai/pull/2), [#4](https://github.com/sceny/omarchy-paperclipai/pull/4), [#47](https://github.com/sceny/omarchy-paperclipai/pull/47) Follow develop: a user timer keeps installed plugins current and restarts the shell after an update
- [#6](https://github.com/sceny/omarchy-paperclipai/pull/6) Doctor bundle: keep inbox text out of the agent session
- [#93](https://github.com/sceny/omarchy-paperclipai/pull/93) Doctor bundle: the service unit's state fields only; `--redacted` failures name only the error type
- [#7](https://github.com/sceny/omarchy-paperclipai/pull/7), [#34](https://github.com/sceny/omarchy-paperclipai/pull/34), [#41](https://github.com/sceny/omarchy-paperclipai/pull/41) API clients and scripts: no redirects, no request to a foreign listener on Paperclip's port
- [#9](https://github.com/sceny/omarchy-paperclipai/pull/9) Open only urls on the instance's own origin
- [#11](https://github.com/sceny/omarchy-paperclipai/pull/11) Notifications: text goes over D-Bus, not argv
- [#10](https://github.com/sceny/omarchy-paperclipai/pull/10), [#12](https://github.com/sceny/omarchy-paperclipai/pull/12), [#33](https://github.com/sceny/omarchy-paperclipai/pull/33), [#43](https://github.com/sceny/omarchy-paperclipai/pull/43) CI workflow and class lints: private text on argv, clipboard reads, shell strings in scripts
- [#13](https://github.com/sceny/omarchy-paperclipai/pull/13), [#15](https://github.com/sceny/omarchy-paperclipai/pull/15), [#16](https://github.com/sceny/omarchy-paperclipai/pull/16) Release tooling and the release template: CHANGELOG, release workflow, `dev/release-prepare`, marketplace check, the contributor code rule
- [#94](https://github.com/sceny/omarchy-paperclipai/pull/94) Protect `main`: rulesets, release environment, read-only token, release version check
- [#32](https://github.com/sceny/omarchy-paperclipai/pull/32), [#64](https://github.com/sceny/omarchy-paperclipai/pull/64), [#66](https://github.com/sceny/omarchy-paperclipai/pull/66), [#81](https://github.com/sceny/omarchy-paperclipai/pull/81), [#83](https://github.com/sceny/omarchy-paperclipai/pull/83), [#86](https://github.com/sceny/omarchy-paperclipai/pull/86), [#87](https://github.com/sceny/omarchy-paperclipai/pull/87) The `public-text` check and the merge queue on `develop`
- [#1](https://github.com/sceny/omarchy-paperclipai/pull/1), [#8](https://github.com/sceny/omarchy-paperclipai/pull/8), [#14](https://github.com/sceny/omarchy-paperclipai/pull/14), [#48](https://github.com/sceny/omarchy-paperclipai/pull/48), [#56](https://github.com/sceny/omarchy-paperclipai/pull/56), [#63](https://github.com/sceny/omarchy-paperclipai/pull/63), [#71](https://github.com/sceny/omarchy-paperclipai/pull/71), [#72](https://github.com/sceny/omarchy-paperclipai/pull/72), [#74](https://github.com/sceny/omarchy-paperclipai/pull/74) Rig and sandbox: hidden by default, a private session bus, seeding, start and teardown evidence
- [#70](https://github.com/sceny/omarchy-paperclipai/pull/70), [#82](https://github.com/sceny/omarchy-paperclipai/pull/82), [#88](https://github.com/sceny/omarchy-paperclipai/pull/88) README and AGENTS.md: Sceny and Learning Sceny, reviews as pull-request reviews

## 0.2.0 — 2026-10-09

### Highlights

- **A paperclip in the bar for your Paperclip instance**: it turns urgent when
  something needs you, carries a light while agents work, and opens a panel
  with an inbox of what is waiting. A bubble on the mark counts it, and
  desktop notifications follow the same inbox.
- **Snooze and focus**: snooze for an hour or until 09:00 from the panel, the
  bar or `omarchy-shell paperclip snooze`; follow Omarchy's Do Not Disturb;
  focus lets the notifications through while Omarchy is snoozed.
- **Setup that keeps the instance running**: scripts that start, stop and
  check the instance, run first-run setup, open the web app or a page in it,
  and repair what is broken (`omarchy-paperclip-doctor`), handing the rest to
  an AI session.
- **Paperclip skills**: the plugin installs the Paperclip agent skills for your
  AI tools, takes back only what it put there, and keeps them level with
  upstream.

### Fixes

- The published repository installs: `omarchy plugin add` refuses symlinks in
  a plugin folder, so the agent links are no longer tracked.
