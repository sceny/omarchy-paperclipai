[Paperclip](README.md) › What's new

# What's new

Each version, newest first, grouped by what it touches. `omarchy plugin
update sceny.paperclipai` brings the latest; each is a tag (`vX.Y.Z`) and a
GitHub release with these notes.

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
- [#7](https://github.com/sceny/omarchy-paperclipai/pull/7), [#34](https://github.com/sceny/omarchy-paperclipai/pull/34), [#41](https://github.com/sceny/omarchy-paperclipai/pull/41) API clients and scripts: no redirects, no request to a foreign listener on Paperclip's port
- [#9](https://github.com/sceny/omarchy-paperclipai/pull/9) Open only urls on the instance's own origin
- [#11](https://github.com/sceny/omarchy-paperclipai/pull/11) Notifications: text goes over D-Bus, not argv
- [#10](https://github.com/sceny/omarchy-paperclipai/pull/10), [#12](https://github.com/sceny/omarchy-paperclipai/pull/12), [#33](https://github.com/sceny/omarchy-paperclipai/pull/33), [#43](https://github.com/sceny/omarchy-paperclipai/pull/43) CI workflow and class lints: private text on argv, clipboard reads, shell strings in scripts
- [#13](https://github.com/sceny/omarchy-paperclipai/pull/13), [#15](https://github.com/sceny/omarchy-paperclipai/pull/15), [#16](https://github.com/sceny/omarchy-paperclipai/pull/16) Release tooling and the release template: CHANGELOG, release workflow, `dev/release-prepare`, marketplace check, the contributor code rule
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
