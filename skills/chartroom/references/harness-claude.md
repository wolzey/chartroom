# Running the XO in Claude Code

Set `CHARTROOM_HARNESS=claude` in the environment that launches Claude Code (or in
`~/.config/chartroom/config`) so the `subagent` backend is offered.

## Waiting for wakes

Wait on one batch of wakes at a time, as a background Bash command, with no `--timeout`:

```
Bash  command: chartroom watch --once
      description: chartroom fleet wakes   run_in_background: true
```

It blocks until something needs you, prints the wake(s), one per line, and exits 0; Claude Code
wakes you when it exits. Handle the batch, then start the next one the same way. Keep exactly
one running for the whole session: the same stream carries relays from other homes' XOs
(`[relay <id>] [from <home>] ...`), so there is no second watcher to run. Starting it again is
never news: no "restarted the watcher" or "nothing new" lines; a quiet fleet stays silent.

`--once` keeps its own cursor, `$CHARTROOM_HOME/.watch-cursor`, so no logged event or relay is
missed between calls. The streaming `chartroom watch` never moves it, so in a home that has used
one, the first `--once` can replay wakes already handled (everything since the cursor was
written, and the whole log of a task created after it). Check `chartroom status` before relaying
anything from that first batch, and don't re-report what is already handled.

## In-session workers (`subagent` backend)

`chartroom dispatch` prints the call. Make it with the Agent tool: `name: <id>`,
`run_in_background: true`, and the printed prompt. Prefer a specialist `subagent_type` your
setup offers when one fits the work.

- Completion arrives as a task notification, not through `chartroom watch`.
- Steer: `chartroom steer <id> "<msg>"` records it, then `SendMessage` to `<id>` delivers it.
- Stop: `TaskStop`. It dies with this session; re-dispatch after a restart.

## Invocation

`/chartroom` loads the skill, `/bearings` gives the digest.
