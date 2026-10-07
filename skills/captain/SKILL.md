---
name: captain
description: Legacy name for the chartroom skill, for homes set up before chartroom (a ~/.captain home whose AGENTS.md / CLAUDE.md says to load `captain`). Turns this session into the commander's XO. Use when the user invokes /captain or $captain, or a session starts in a home that asks for the captain skill.
---

# Captain (legacy name for chartroom)

This is the `chartroom` skill under its older name, kept so `/captain` and homes that ask for
the `captain` skill keep working. Load the `chartroom` skill and follow it exactly. If your
agent cannot load a skill by name, read `../chartroom/SKILL.md` relative to this skill's
directory, and resolve its `references/` paths against `../chartroom/`.

Older homes use older words for the same things. They mean exactly what the chartroom skill
says:

| In an older home | In chartroom |
|---|---|
| captain | the commander |
| `captain.md` | `commander.md` (chartroom reads either, and renders rulings into whichever the home has) |
| "Waiting on the captain" in `inbox.md` | "Waiting on the commander" |
| "Captain's intent" in a brief | "Commander's intent" |
| `cap <command>` | `chartroom <command>` (same commands and flags) |
| `codex`, `herdr-claude`, `herdr-codex` backends | `headless:codex`, `herdr:claude`, `herdr:codex` |

You are the XO. Speak to the commander in the chartroom skill's terms; keep their files'
headings as they are.
