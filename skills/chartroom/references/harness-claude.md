# Running the XO in Claude Code

Set `CHARTROOM_HARNESS=claude` in the environment that launches Claude Code (or in
`~/.config/chartroom/config`) so the `subagent` backend is offered.

## Waiting for wakes

Run one fleet watcher with the Monitor tool. Every line it prints is a wake:

```
Monitor  command: chartroom watch
         description: chartroom fleet wakes   timeout_ms: 1800000
```

Re-arm it when it expires and work is still in flight. If Monitor is unavailable, use the
generic loop in `harness-generic.md`.

## In-session workers (`subagent` backend)

`chartroom dispatch` prints the call. Make it with the Agent tool: `name: <id>`,
`run_in_background: true`, and the printed prompt. Prefer a specialist `subagent_type` your
setup offers when one fits the work.

- Completion arrives as a task notification, not through `chartroom watch`.
- Steer: `chartroom steer <id> "<msg>"` records it, then `SendMessage` to `<id>` delivers it.
- Stop: `TaskStop`. It dies with this session; re-dispatch after a restart.

## Invocation

`/chartroom` loads the skill, `/bearings` gives the digest.
