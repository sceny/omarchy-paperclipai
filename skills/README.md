# Skills for the doctor session

`bin/omarchy-paperclip-doctor` does not only run `paperclipai doctor`. It opens
an AI session that can read logs, edit config and install packages — the things
a fixed list of repair steps cannot do. These are the skills that session gets.

Two directories make the set, and the second one wins:

| Directory | What it is |
| --- | --- |
| `<plugin>/skills/` | shipped with the plugin |
| `~/.config/omarchy/paperclipai/skills/` | the user's own |

A directory with the same name in both replaces the shipped one, so a user can
change the shipped `paperclip-doctor` skill without editing the plugin. Any
other name is added to the set.

The shipped set is `paperclip-doctor` plus the Paperclip agent skills listed in
`upstream.list`. Those are copied unchanged from the Paperclip repo; refresh
them with `dev/sync-skills`, never by hand.

Each skill is a directory with a `SKILL.md` in it. The session also keeps the
user's global skills (`~/.claude/skills`), because the agent reads those too.

Add a skill:

```
mkdir -p ~/.config/omarchy/paperclipai/skills/my-skill
$EDITOR ~/.config/omarchy/paperclipai/skills/my-skill/SKILL.md
```

Check what a session would get:

```
bin/omarchy-paperclip-agent --list-skills
```
