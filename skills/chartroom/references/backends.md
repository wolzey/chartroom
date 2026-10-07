# Backends

A backend is `<runner>:<agent>`: **where** the worker runs × **which** agent runs. Runners are
`herdr`, `cmux`, `tmux` (session runners: a terminal you can watch), `headless` (no terminal),
`command` (any CLI) and `subagent` (the host harness), plus `joined`, which is never
dispatched: a running session joins itself (see the last section). Agents are `claude` and `codex`. Old
names still work: `codex` = `headless:codex`, `herdr-claude` = `herdr:claude`,
`herdr-codex` = `herdr:codex`.

`chartroom doctor` shows every backend, whether it can run here, why not, and how it steers.
Last verified against: claude 2.1.289 (joined: 2.1.293), codex-cli 0.158.0, herdr 0.9.1, tmux 3.x (October 2026).
cmux is implemented against its documented CLI but **unverified on a real cmux install**.

## Selection and fallback

- `chartroom new` without `--backend` (or `--backend auto`) picks at dispatch time: the first
  available entry in `CHARTROOM_BACKEND_ORDER` (default
  `herdr:claude cmux:claude tmux:claude headless:codex headless:claude command`). Skipping
  the first entry writes a `note: backend fallback: ...` event and prints it, because falling
  from a session runner to headless changes what the commander can watch and steer.
- An explicit `--backend` never downgrades. If it is unavailable, dispatch exits non-zero with
  the reason and the next viable backend.
- `CI=true` disables session runners. herdr needs its server reachable; cmux needs macOS and a
  running app that accepts our socket connection; tmux needs tmux ≥ 3.0; `subagent` needs
  `CHARTROOM_HARNESS=claude`; `command` needs a template.

## Common to all

- Every ship task gets its own git worktree on branch `chartroom/<id>` (prefix:
  `CHARTROOM_BRANCH_PREFIX`), branched from the base ref's commit at `new` time. Scouts get
  a detached worktree, or none for `subagent`. The worktree lives at
  `<repo>/.worktrees/chartroom_<id>` when the repo gitignores `.worktrees`, otherwise at
  `$CHARTROOM_HOME/worktrees/<repo>/<id>`.
- The worker gets one line: "Read the brief at … and follow it exactly." The brief carries
  the protocol: events, report, stop at decisions, no push.
- Workers append to `tasks/<id>/events.log`; `chartroom watch` turns the lines that need you
  into wakes.
- New worktrees have no `node_modules` or other build products. The worker installs
  dependencies itself. Say so in the spec when it matters.

## Steering modes

| Mode | Backends | What `steer` does |
|---|---|---|
| live | herdr, cmux, tmux, headless:claude | Delivers now and confirms it was taken (agent hook, replayed message, or screen state) |
| between-runs | headless:codex, command | Refuses while running; afterwards resumes (`codex exec resume`) or re-runs the template with the message. `command` also has `steer --inbox` (best effort) |
| host | subagent | Records it; you deliver it with your harness's message tool |
| mailbox | joined:<agent> | Writes to the joined session's mailbox; "delivered" only once its listener (or `listen --check`) read it, else "queued, not yet read" |

## First-launch trust dialogs

Claude Code and Codex both gate a never-seen folder behind a "trust this folder" dialog in
interactive mode. Policy, identical on every session runner: chartroom reads the dialog and
answers it **only** for a worktree it created itself for this task (`worktree_created=1` in
meta). Claude's cursor starts on "No, exit" (answer: Down, Enter); Codex's on "1. Trust and
continue" (answer: Enter). Any other dialog, or any folder chartroom did not create, is left
alone and raised as `agent: awaiting-input`. chartroom never edits `~/.claude.json` or
`~/.codex/config.toml` to pre-trust a path. (Verified on codex 0.158: a per-run
`-c projects."<path>".trust_level="trusted"` override does **not** suppress the dialog.)
Headless runs (`claude -p`, `codex exec`) show no dialog.

## herdr:<agent> (first class)

- All workers share one herdr workspace labelled `$CHARTROOM_WORKSPACE` (default
  `chartroom-crew`), one unfocused tab per task; the herdr agent name is the task id.
- A brand-new pane is briefly not an "available shell", so `agent start` is retried on
  `agent_pane_busy`. Extra agent flags (sandbox, model, `--add-dir`) are passed after `--`.
- A prompt sent while Claude's startup splash is still up is dropped. chartroom waits for idle,
  then confirms delivery (status `working`, or the text visible) and retries up to 4 times.
- Wakes come from herdr's own agent state: `blocked` (prompt up), a `working` agent going
  `idle`/`done` without a report, and an agent that is `gone`.
- `stop` sends Esc; `close` closes the tab; `attach` focuses it.

## tmux:<agent>

- One tmux session `$CHARTROOM_WORKSPACE`, one window per task, running
  `tasks/<id>/launch.sh` (cd into the worktree, exec the agent, record `exited` when it ends).
  `CHARTROOM_TMUX_SOCKET=<name>` uses a separate tmux server (`tmux -L`).
- Output is piped to `tasks/<id>/pane.log` from the start (`pipe-pane`); `peek` shows the live
  screen, or the log once the window is gone.
- Turn ends and prompts come from the agent, not the screen: Claude is launched with
  `--settings tasks/<id>/claude-settings.json` adding `Stop`, `Notification` and
  `UserPromptSubmit` hooks that run `chartroom hook`; Codex gets
  `-c notify=[chartroom, hook, <id>, codex-notify]`. Delivery is confirmed by the
  `prompt-received` hook (Claude) or Codex's "esc to interrupt" working line.
- Codex has no prompt-submitted or approval hook, so for Codex sessions delivery confirmation
  reads the screen, and approval prompts are not signalled. This is weaker than Claude, and
  Codex may report an intermediate turn end while it is still working.
- `attach` = `tmux attach` (or `switch-client` inside tmux). `close` kills the window.

## cmux:<agent> (macOS; implemented, unverified on real cmux)

- manaflow-ai/cmux. One cmux workspace titled `$CHARTROOM_WORKSPACE`, one surface (tab) per
  task (`workspace create --cwd --command`, then `new-surface`), created unfocused.
- Same launcher, hooks and confirmation as tmux. Keys go through `send-key --force` so a
  trust dialog can be answered. `peek` reads the screen (`read-screen --scrollback`); there is no
  pipe-pane, so `close` snapshots the scrollback into `pane.log` before closing the surface.
- cmux's default socket mode only accepts commands from processes started inside cmux. If
  the XO runs elsewhere, enable automation mode (cmux Settings, or
  `automation.socketControlMode` in `~/.config/cmux/cmux.json`). `doctor` reports a refused socket.

## headless:codex

- Detached (`nohup`) `codex exec --json -C <worktree> -o final.md`, plus the sandbox per task:
  scouts `workspace-write` with network on and `--add-dir <task record>`; ship tasks
  `$CHARTROOM_CODEX_SHIP_SANDBOX` (default `danger-full-access`, because `workspace-write`
  refuses `.git` writes in recent codex, so a sandboxed worker cannot commit). The `sandbox`
  key in `meta.json` wins.
- Thread id from the first `thread.started` event; `steer` after the run runs
  `codex exec … resume <thread> "<message>"` with the full conversation (verified).
- `model` / `effort` in meta map to `-m` and `model_reasoning_effort`.
- The wrapper appends `exited: … (exit N)`; a process that dies without one is reported `lost`.

## headless:claude

- Detached `claude -p --input-format stream-json --output-format stream-json --verbose
  --replay-user-messages --session-id <uuid>` (the id is pre-assigned and stored in meta), with
  `--permission-mode` (default `acceptEdits`), `--allowedTools` (`CHARTROOM_CLAUDE_ALLOWED_TOOLS`)
  and `--add-dir <task record>`.
- stdin is a FIFO the wrapper holds open, so `steer` mid-run writes another user message; it
  counts as delivered when claude replays it on stdout (verified; a message queued mid-turn is
  folded into that turn). When the stream ends on a `result` with nothing new for 3s, the
  wrapper closes stdin. claude 2.1.289 does not exit on that late EOF, so after 5s the wrapper
  ends it (`exited: … ended by chartroom after its final result`). The session is already saved:
  a later `steer` runs `claude -p --resume <uuid>` (verified to keep context).
- `final.md` gets the last `result` text; `peek` summarises messages, tool calls and results.

## command

- `meta.command` (or `CHARTROOM_COMMAND`) with `{brief} {prompt} {worktree} {task_dir} {id}`
  placeholders, shell-quoted. Runs detached in the worktree with `CHARTROOM_HOME`,
  `CHARTROOM_TASK`, `CHARTROOM_BIN` exported; output in `output.log`; `exited (exit N)` at the end.
- `steer` re-runs it with `{prompt}` = the message and `CHARTROOM_STEER` set.
  `steer --inbox` appends to `inbox.md` while it runs; the brief tells workers to read it after
  each milestone, but nothing guarantees they do.
- This is also the test backend: `test/stub-agent` drives the whole lifecycle with no AI.

## subagent

- Only when `CHARTROOM_HARNESS=claude`. `dispatch` records the task and prints the call to make
  (`run_in_background: true`, `name: <id>`). It dies with your session; the brief and record
  survive, so a restarted XO re-dispatches it. Best for read-only scouts: it shares your
  session's permissions.

## joined:<agent> (a running session that joined itself)

Not a dispatch backend. An agent session the commander started themselves (Claude Code in any
terminal, an IDE or the desktop app; Codex; inside or outside herdr/tmux/cmux) is told "join
chartroom" and runs the `join` skill. The connection starts from the agent's side, so chartroom
never has to reach into its terminal.

- `chartroom join --title T [--kind ship|scout] [--agent A]`, run by the agent from its own
  directory, records the task: project from the cwd's repo, the current checkout and branch as
  the "worktree" as they are (no new worktree, `worktree_created` unset), backend
  `joined:<agent>`, `dispatched` set at once. It prints the id, the brief and the protocol; the
  agent fills the brief's intent and spec itself. Re-running it in the same session (same Claude
  session id, else same agent pid, else same directory) returns the same open task.
- **Steering is a mailbox**: `tasks/<id>/mail/<n>.txt`, read up to the number in `mail/read`.
  The agent keeps `chartroom listen <id>` armed; it blocks until a message lands, prints it,
  marks it read, logs `agent: prompt-received mail #n` and exits. `steer` writes the message and
  reports `delivered` only once it is read (within `CHARTROOM_JOIN_ACK_WAIT`, default 20s),
  otherwise `queued, not yet read` and whether a listener is armed. It never types into the
  agent's terminal.
- **Handles are verified, never trusted from the env**: a tmux pane (`$TMUX_PANE`, on the
  socket from `$TMUX`) or herdr pane (`$HERDR_PANE_ID`) is recorded only if its shell is an
  ancestor of the join command, because nested multiplexers leak stale variables (a tmux server
  started from one herdr pane carries that pane's id into every window). A cmux surface is
  recorded only when no other multiplexer is in the env. Handles serve `peek`, `attach` and
  `stop` (Esc); with none, those fall back to events and mailbox (`attach` explains).
- **Liveness**: the agent's pid (Claude Code's `CLAUDE_PID`, else the nearest ancestor named
  after a known agent). `live` is `listening` while the listener is armed and the agent is not
  mid-turn, `working`/`idle`/`blocked` from hooks or herdr's pane state, `stopped` once the pid
  is gone. `watch` records the pid ending once as `exited: joined agent session ended` and wakes
  on it unless the worker had reported.
- **Hooks (Claude Code)**: the join skill declares Stop, Notification and UserPromptSubmit
  hooks in its frontmatter; Claude Code registers them when the skill is invoked and keeps them
  for the rest of the session. They are static, so they look the task up by the payload's
  `session_id` in `${XDG_STATE_HOME:-~/.local/state}/chartroom/sessions/<id>` (home, task,
  chartroom binary; written by `join`, removed by `close`) and call `chartroom hook --session`.
  A joined session's `idle_prompt` notification is ignored: idling on the listener is normal.
- **close** marks the task closed and removes the session registry entry. It never removes or
  cleans the directory and never refuses on uncommitted work (it says there is some). The
  listener sees the close and exits with "stop listening".

What works where (Claude Code verified on 2.1.293 in tmux, October 2026; the rest by design):

| Agent / where | Wakes on `steer` when idle | Turn ends, prompts | peek / attach / stop |
|---|---|---|---|
| Claude Code in tmux | yes: the background listener exits and Claude Code re-invokes the session (verified) | skill hooks (verified: Stop) | pane capture / switch to the pane / Esc |
| Claude Code in herdr | yes (same mechanism) | skill hooks; herdr pane state | herdr pane read / focus tab / Esc |
| Claude Code elsewhere (plain terminal, IDE, desktop) | yes (same mechanism) | skill hooks | events + mailbox only; no attach |
| Codex, other agents | no: `listen --check` between steps and before each turn ends, best effort | none (no session-scoped hooks); pid liveness only | as above per terminal |

Gaps: an agent with no background wake reads messages only when it checks; a session that
ends without the skill's hooks (or a non-Claude agent) is noticed only when its pid disappears.
Background commands keep running while the session lives; if the listener is killed (e.g. the
user stops it), `steer` reports `queued, not yet read ... no listener is armed`.
