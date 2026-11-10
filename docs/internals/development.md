[Paperclip](../../README.md) › Internals › Development

# Development

Read [AGENTS.md](../../AGENTS.md) first: the rules the plugin is built to, and
the steps for changes and releases.

## The sandbox

All development and testing happens in `dev/sandbox`, a rootless podman container
with no home, no credentials, no network and no host socket (`dev/sandbox` is in
[sceny/omarchy-devices](https://github.com/sceny/omarchy-devices), where
`docs/internals/development.md` describes it). This repository has an image of
its own, with Hyprland, Quickshell, Omarchy's shell, the Paperclip CLI and
Postgres, and nothing of Android. The rig runs only inside it. Run `dev/sandbox`
from a Devices checkout; two modes:

```sh
# Your own working tree: one container kept until `dev stop` or its TTL.
dev/sandbox dev start --repo sceny/omarchy-paperclipai    # prints the session id
dev/sandbox dev sync --tree <this checkout>               # tracked files in; `git add` a new file first
dev/sandbox dev exec -- bash test/run_all.sh              # the unit checks
dev/sandbox dev rig selftest                              # the rig's lease and reap logic
dev/sandbox dev up                                        # the rig, hidden (a few minutes)
dev/sandbox dev rig check                                 # every check against it
dev/sandbox dev rig seed                                  # rows to look at
dev/sandbox dev shot NAME                                 # a screenshot of the rig
dev/sandbox dev pull --out DIR                            # screenshots out, as data
dev/sandbox dev --session <id> stop && dev/sandbox verify-clean

# One exact commit (40 hex): read-only, one container per unit, deleted after.
dev/sandbox run sceny/omarchy-paperclipai <sha>           # pc-tests, pc-selftest, qml-parse, manifest, rig-ci
dev/sandbox run sceny/omarchy-paperclipai <sha> --steps tests
dev/sandbox run sceny/omarchy-paperclipai <sha> --steps script --script qa.sh   # your script, with the rig up
```

With more than one session, `--session ID` goes before the verb; `--timeout S`
(default 600) goes there too. This repository's rig has no `record` verb. Panel
QA's regression and the cold install run as `run ... --steps script`
(`docs/internals/releasing.md`).

The rig (`README.md`, *Testing the plugin*) runs only inside the sandbox. A
session ends with `dev stop` or its TTL, and `dev/sandbox verify-clean` proves
nothing is left. The owner looks at screenshots and recordings, never at a live
rig.

Contributor code goes through `dev/sandbox run` only, after the owner's go for
that head (`AGENTS.md`, rule 9); never `dev`, never the host.
