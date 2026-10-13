# Pull requests and releases

`develop` is where work lands; `main` is what users get. Every change is a
short-lived branch from `develop` and a pull request into it. Releases, `main`
and the marketplace are the plugin manager's, not the author's.

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
   They follow no redirects, cap response size, and send the token only to an
   own-uid loopback listener or over https.
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

A line marked `pending` has no check yet; the task named there adds it and
changes the line. `test/test_security_rules.py` fails when a line has neither a
check that exists nor a `pending` mark, so the list and `test/` cannot drift
apart.

## A release

- Plugin DevOps runs the mechanics; the plugin manager decides the release.
- Every release, a patch included, gets the Plugin Security Reviewer's
  whole-plugin threat-model review on the release branch. A FAIL rejects the
  candidate: it is fixed and re-reviewed on the new head, or the release does
  not happen.
- Nothing private goes in a commit, an issue or a pull request: no tokens,
  instance ids, host names, owner data, and no description of an unfixed
  vulnerability.
