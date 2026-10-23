[Paperclip](README.md) › What's new

# What's new

Each version, newest first, grouped by what it touches. `omarchy plugin
update sceny.paperclipai` brings the latest; each is a tag (`vX.Y.Z`) and a
GitHub release with these notes.

## Unreleased

### Highlights

- **Start and stop Paperclip from the panel**: a row under the title shows
  whether the instance is running, starting, stopping or stopped, with one
  button (key `v`) for Start or Stop. Stopping an instance with agents at work
  asks once. A change made outside the panel shows in the row within a poll.
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
