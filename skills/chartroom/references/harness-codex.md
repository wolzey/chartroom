# Running the XO in Codex CLI

Codex has no background monitor and no subagents, so the XO waits in the foreground and uses
session or headless backends only.

## Waiting for wakes

When work is in flight and you have nothing else to do, block on one batch of wakes:

```bash
chartroom watch --once --timeout 1500
```

- Exit 0: it printed one or more wakes. Handle them, then wait again.
- Exit 124: nothing happened in that window. Wait again (or report to the commander if they
  asked to be told when you are idle).

`--once` remembers its place in `$CHARTROOM_HOME/.watch-cursor`, so nothing is missed between
calls. Keep each wait shorter than your shell tool's timeout.

## Invocation

`$chartroom` loads the skill, `$bearings` gives the digest. Install with
`chartroom install-skills --agents` (links into `~/.agents/skills`, which Codex reads).
