# Worker backends

What `chartroom` does for each backend, and the facts behind it. They were last verified against codex-cli 0.158 and herdr 0.9.1. Codex changed sandbox semantics between 0.157 and 0.160
within an hour of that verification, so re-verify after any upgrade.

## Common to all

- Every ship task gets its own git worktree on branch `chartroom/<id>`, branched from the base
  ref's commit at `chartroom new` time. Scouts get a detached worktree (codex/herdr) or none
  (subagent). The worktree lives at `<repo>/.worktrees/cap_<id>` when the repo gitignores
  `.worktrees`. Otherwise it lives at `~/.chartroom/worktrees/<repo>/<id>`.
- The worker gets one line: "Read the brief at … and follow it exactly." The brief carries
  the worker protocol: events, report, stop at decisions, no push.
- Workers write `~/.chartroom/tasks/<id>/events.log`. `chartroom watch` turns the lines that need a
  wake into notifications.
- New worktrees have no `node_modules` or other build products. The worker installs
  dependencies itself (network is allowed). Say so in the spec when it matters.

## codex: headless `codex exec`

- Launched detached (`nohup`) with `--json`, `-C <worktree>`, and `-o final.md`, plus a sandbox
  chosen per task (the `sandbox` key in `meta.json` wins):
  - **scout** defaults to `workspace-write`, with network on and `--add-dir <task record>`.
    Writes outside the worktree and the task record fail.
  - **ship** defaults to `danger-full-access`. From 0.160, `workspace-write` refuses *every* `.git`
    write (verified: a worktree's `.git/worktrees/<name>/index.lock` and a plain clone's own
    `.git/index.lock` are both denied), so a sandboxed worker cannot commit. The brief's worktree-only rule is the control.
  - Herdr Codex sessions get the same flags, plus `-c check_for_update_on_startup=false`.
    Interactive Codex otherwise self-updates on launch and exits, which loses the brief.
- The thread id comes from the first `thread.started` event in `codex.jsonl` and is stored in
  `meta.json`.
- A headless run can't take input mid-run. `chartroom steer` refuses while it is running. Once it has
  stopped, `chartroom steer` runs `codex exec … resume <thread> "<message>"`, which keeps the full
  conversation (verified).
- When the process ends, the wrapper appends `exited: … (exit N)`. If the process dies with no
  record, `chartroom watch` reports `lost`.
- `chartroom peek` summarises the JSON stream: agent messages, commands with exit codes, and file edits.
- Optional per task: `model` and `effort` keys in `meta.json` map to `-m` and `model_reasoning_effort`.

## herdr-claude / herdr-codex: a full interactive session in Herdr

- All workers share one Herdr workspace labelled `captain-crew` (override with
  `CAP_CREW_WORKSPACE`). It is created unfocused, with one tab per task labelled by task id.
  The agent name is the task id.
- A brand-new pane is not an "available shell" for a moment, so `chartroom` retries `agent start`
  on `agent_pane_busy`. Herdr reports errors on stderr with a nonzero exit.
- Claude shows a workspace-trust dialog for a never-seen folder, with the cursor on "No, exit".
  `chartroom` answers it (`down`, `enter`) only for the worktree it just created for this task.
  It never edits `~/.claude.json`.
- A prompt sent while Claude's startup splash is still up is silently dropped. `chartroom` waits for
  idle, then confirms delivery (status `working`, or the text visible in the pane) and retries
  up to 4 times.
- herdr-codex passes the same sandbox flags as headless codex after `--`, and turns off the update check.
- Steering is a typed prompt (`chartroom steer`). Interrupt with `chartroom stop` (sends `esc`).
- Herdr lifecycle states: `idle`/`done` mean the turn ended, `blocked` means an approval or
  question UI is up, and `unknown` is not proof of completion. `chartroom watch` reports transitions
  into `blocked`, a `working` agent going `idle` or `done`, and an agent that is `gone`.
- The captain can watch or take over any tab. Typing there directly is authoritative.

## subagent: the Agent tool in this session

- `chartroom dispatch` records the task and prints the Agent call. Make it with
  `run_in_background: true` and `name: <id>`, and prefer a specialist `subagent_type` that fits.
- Completion arrives as a task notification. Steer with `SendMessage` to `<id>`. Stop it with `TaskStop`.
- It dies with this session, so the brief and record survive and a restarted first mate re-dispatches it.
- Best for read-only scouts. For ship work, the printed prompt names the worktree, but the
  subagent shares this session's permissions. Prefer codex or herdr for ship work.
