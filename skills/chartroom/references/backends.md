# Backends

A backend is `<runner>:<agent>`: **where** the worker runs × **which** agent runs. Runners are
`hc`, `herdr`, `cmux`, `tmux` (session runners: a terminal you can watch), `headless` (no terminal),
`command` (any CLI) and `subagent` (the host harness), plus `joined`, which is never
dispatched: a running session joins itself (see the last section). Agents are `claude` and `codex`. Old
names still work: `codex` = `headless:codex`, `herdr-claude` = `herdr:claude`,
`herdr-codex` = `herdr:codex`.

`chartroom doctor` shows every backend, whether it can run here, why not, and how it steers.
Last verified against: claude 2.1.289 (joined: 2.1.293; hc: 2.1.314), codex-cli 0.158.0, herdr 0.9.1,
hc (herdr-core) 0.1.14 with herdr-app 0.1.9 (hc:codex: hc 0.1.16), tmux 3.x (October 2026).
cmux is implemented against its documented CLI but **unverified on a real cmux install**.

## Selection and fallback

- `chartroom new` without `--backend` (or `--backend auto`) picks at dispatch time: the first
  available entry in `CHARTROOM_BACKEND_ORDER` (default
  `hc:claude herdr:claude cmux:claude tmux:claude headless:codex headless:claude command`). Skipping
  the first entry writes a `note: backend fallback: ...` event and prints it, because falling
  from a session runner to headless changes what the commander can watch and steer.
- An explicit `--backend` never downgrades. If it is unavailable, dispatch exits non-zero with
  the reason and the next viable backend.
- `CI=true` disables session runners. hc needs a running herdr-core (a live socket, checked
  without starting one); herdr needs its server reachable; cmux needs macOS and a
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
  into wakes. A line written through `chartroom event` (or a hook) rings `watch`, which wakes
  within a fraction of a second; a line appended any other way, a launcher's `exited` among them,
  is read within `CHARTROOM_WATCH_INTERVAL` (3 s), by the light round that looks, without a fork,
  at every log and task record changed since the last scan.
- New worktrees have no `node_modules` or other build products. The worker installs
  dependencies itself. Say so in the spec when it matters.

## Steering modes

| Mode | Backends | What `steer` does |
|---|---|---|
| live | hc, herdr, cmux, tmux, headless:claude | Delivers now and confirms it was taken: Claude in hc/herdr/tmux/cmux by the prompt hook's signature of the submitted text, headless:claude by the replayed message, herdr without the hook by its agent state or the text on screen; Codex sessions report `submitted, not verified` |
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

Codex then shows "Hooks need review" for any hook it has not seen: a project's `.codex/hooks.json`,
in each new worktree (it trusts by path), and a per-run `-c hooks...` too. chartroom never trusts
one, because hooks run outside the sandbox. By default it raises `agent: awaiting-input`, and
`CHARTROOM_CODEX_HOOKS_DIALOG=skip` takes Esc instead, in a worktree chartroom created (the agent
starts without those hooks; the log says so).

**The brief is never typed at a dialog.** The text is dropped and Enter answers the dialog
(verified on tmux, codex-cli 0.158.0). Dispatch exits 0 and says the worker is waiting. hc passes
the brief as the agent's first prompt, which waits behind the dialog (verified: a skipped dialog,
and the brief ran about 4 s later). tmux, cmux and herdr leave meta `brief_pending`, and the
watch's next look delivers the brief once the dialog has gone: `note: the brief went in once the
dialog cleared`, or `agent: awaiting-input: ...` if the agent does not confirm it.

## Stuck workers (lib/stuck.sh)

Each task the watch's full round covers gets a look at most every `CHARTROOM_LOOK_INTERVAL` (60 s):
one read of its terminal, or the size of its output file, plus a few small forks. The look raises
what the agent does not report itself, delivers a brief that waited behind a dialog, and runs the
stall watchdog.

| Stuck state | hc:claude | hc:codex | herdr | tmux, cmux | headless:*, command |
|---|---|---|---|---|---|
| Approval prompt | hc's `blocked`, at once | terminal title, pushed by `hc events`, at once | herdr's `blocked` (Codex: its own title rule) | Claude: `Notification` hook. Codex: title (tmux) or screen, within a look | cannot occur: no terminal |
| Question | hc's `blocked` | a turn end (Codex asks in prose; `request_user_input` was not offered in the default mode) | herdr's `blocked` | Claude: hook. Codex: a turn end | a turn end or `exited` |
| Trust or hooks dialog | at dispatch; later, the screen, within a look | same | at dispatch (herdr reads the hooks dialog as idle); later, the screen, within a look | at dispatch; Codex later, the screen, within a look | none shown |
| Idle with no event | a turn end, then `stalled` | notify's turn end, then `stalled` | a turn end, then `stalled` | hook or notify, then `stalled` | `exited`, or `stalled` |
| Wedged process | `stalled` | `stalled` | `stalled` | `stalled` | `stalled` |

- **Prompts** log `agent: awaiting-input: <what>`, which wakes through the event scan, and
  `agent: prompt-cleared` once gone, so status, the dashboard and a restarted or `--once` watch all
  read the same record. Codex sets its terminal title to `[ . ] Action Required | ...` and
  `[ ! ] ...` in turn while an approval is up (verified on codex-cli 0.158.0). `hc events` carries each
  title change, many a second under its spinner, so the stream's jq reduces them to the one fact
  that matters. Only an overlay's own footer on a screen's last lines counts, never the same words in a
  transcript. A `PermissionRequest` hook also fires at once (verified), but a per-run hook raises
  the "Hooks need review" dialog itself, at every dispatch, unless the commander trusts it, so
  chartroom does not use one.
- **`steer` refuses a Codex worker at a prompt.** Typed text and Enter at its approval overlay
  approve the command (verified through `hc send`, which does not refuse because hc does not
  know Codex is blocked).
- **Stalled**: a task whose state is `working`, with no open `waiting`, not parked, not at a prompt
  already raised, whose output and non-note events have not changed for `CHARTROOM_STALL_MINUTES`
  (10; `0` turns it off), wakes once as `stalled: no output or events for N min ... Last output:
  ...`, recorded as a `note`, like `waiting overdue`. New output or an event re-arms it, and
  `tasks/<id>/.stall` keeps its place across restarts. What ticks by itself does not count as
  output: elapsed times, a clock, spinner glyphs, Claude's rotating verb and tip, and any working line
  with `esc to interrupt`. Claude's token count does count, since it moves when the model does.
  A real Codex waiting on a background command prints a new line about once a minute (verified), so
  it does not stall.
- **A long command**: from the point the stall is due, the CPU of what runs under the agent (its
  tools; not the agent's own processes) is sampled per look. At 10% of a core or more, it is at
  work and the wake waits, up to `CHARTROOM_STALL_BUSY_MAX_MINUTES` (60), when it fires anyway and
  says `still using CPU`. A command that is idle (a `sleep`, a hung network call) fires on time.
  cmux cannot name a root process, so it has no such check.
- Not covered: `joined` (the commander's own session) and `subagent` (the host's).

## hc:<agent> (the Herdr app; first in the default order)

The Herdr desktop app (`herdr-app`) shows only terminals run by herdr-core (`hc`), a different
program from the `herdr` CLI/server below; workers on `herdr:*` never appear in it.

- One hc terminal per task, named after the task id, started with `hc run --bg --no-parent
  --no-notify --cwd <worktree>`. `--no-parent`: the worker outlives the XO's session (a child
  ends with its parent unless `--outlive-parent`), and never hangs off whatever terminal
  `HC_TERMINAL_ID` names: that variable leaks into processes started from an hc terminal, and
  into herdr panes, so it can name another home's XO. With no parent hc types no notes into
  the XO's input; chartroom's own wake stream reports the same things (`--no-notify` says so too).
- hc gives a terminal the core's environment, not the caller's (verified: no
  `/opt/homebrew/bin` on its PATH), so the terminal runs `tasks/<id>/launch.sh` as tmux does
  (chartroom's PATH, `CHARTROOM_HOME`, `CHARTROOM_TASK`; `exited` when the agent ends). The
  brief's one line is `hc run`'s task argument, which the launcher hands to the agent as its
  first prompt: nothing is typed into a booting agent. For a program that is not an hc
  template, hc's task argument is just that: the program's last argument (verified).
- **Visible in the app through labels**: each terminal carries `herdr.space=<id>` of the space
  named `$CHARTROOM_WORKSPACE`, `herdr.tab=<a fresh id>` of its own, and `chartroom.workspace`
  / `chartroom.task`. The space id comes from a live worker's labels (hc's own record, so it
  holds with the window closed), else from `herdr-app ls` by name, else a new `sp<32 hex>`.
  The app adopts a labelled terminal at once: an id it does not know becomes a new space or
  tab with that very id (unnamed: the space is called after the folder, the tab by its number),
  and the person's focus does not move (verified). chartroom then names them with
  `herdr-app do space.rename` and `tab.rename` (tab: `<short id> · <title>`). It never uses
  `space.new`, which shows the new space and focuses its pane at once (verified).
- **Window closed** (`herdr-app ls` answers "no Herdr window"): dispatch still works on labels
  alone and notes it; the worker appears when the app opens, under the app's default names
  until the next dispatch or `chartroom attach` names them.
- The brief's delivery is confirmed by Claude's `UserPromptSubmit` hook, which fires for a first
  prompt given as an argument too (verified), so claude gets only that hook (`prompt` mode, as on
  herdr). Codex gets `--no-daemon` (hc's manual: otherwise its commands run outside hc) and keeps
  its `notify` hook for turn ends: hc reports no status and no turns for Codex (verified on hc
  0.1.16 and codex-cli 0.158.0; a program reports its state itself, and Codex does not). Its brief
  counts as taken once an agent event arrives or its screen shows it working. Codex's own
  title-generator thread fires notify too, with a first input message of "Generate a concise,
  single-line task title": chartroom ignores it, as neither a turn end nor the worker's thread.
- Trust dialog: the same policy as every session runner (screen from `hc read`, keys from
  `hc keys`). hc reports no status while the dialog is up. A dialog chartroom will not answer,
  Codex's "Hooks need review" among them, leaves the worker waiting with its brief queued as its
  first prompt (Claude and Codex run it once the dialog is answered, verified): dispatch says so
  and exits 0, and the `awaiting-input` event wakes the XO. Dispatch keeps looking for a dialog
  until the brief is taken, so one that comes up late, or right after the one it answered, is
  caught too.
- `steer` = `hc send` (paste, Enter once nobody is typing), confirmed by the prompt hook's
  signature as for tmux; without the hook, hc's `started` flag or a `working` status. A blocked
  agent (a permission or question dialog) is never typed into: hc refuses without `--force`,
  and chartroom never passes it. hc does not know a Codex is blocked, so chartroom refuses
  that itself, from its title or screen.
- `peek` = `hc read`; `stop` = `hc interrupt` (Esc, and hc reports what happened); `attach` =
  `herdr-app do agent.focus --terminal <t>` (with no window: `hc attach <t>` in a terminal);
  `close` saves the screen to `pane.log`, then `hc kill` and `hc rm`. The app drops a pane whose
  terminal ends and a tab whose last pane goes, window open or not (verified); a space goes with
  its last tab, and the next dispatch makes it again.
- Wakes come from hc's own agent state: `blocked` (as `agent: awaiting-input: hc: ...`), `error`,
  a turn ending (`idle`/`done`) without a report, whether or not `watch` saw it `working` (hc counts
  turns), and the terminal gone (`lost`; an agent that exited on its own wakes through the
  launcher's `exited` instead). hc's states come from the agent itself (OSC 7501); Claude Code
  2.1.314 reports them unprompted (verified). Codex reports none: its turn end wakes through its
  notify event, and its approval prompts through its terminal title (see Stuck workers), which reads
  as `blocked` while up.
- hc pushes that state. While `watch` runs it keeps one `hc events --json --label
  chartroom.workspace=<workspace>`: a snapshot of the workspace's terminals, then a line per
  change (`status`, `turn`, `created`, `lost` then `restarted` or `finished`, `removed`; verified
  with hc 0.1.16 and Claude Code 2.1.318, `blocked` with its `kind` included). The watch reads
  the lines between rounds without a fork and compares only the tasks whose terminal changed, so
  a turn end or a prompt wakes as fast as the line arrives. Its full round asks `hc get` only for
  a terminal the stream does not carry (one started before chartroom labelled them) and while
  the stream is down; once the stream carries every open task, that round runs every
  `CHARTROOM_WATCH_HC_INTERVAL` (60 s) instead of every 3 s, and asks hc about the streamed
  terminals too. So a terminal that vanishes with no event at all wakes within that interval,
  the one wake that can come later than before. When the stream ends (the core stopped or
  restarted, `hc update`), a full round runs at once and the watch polls every
  `CHARTROOM_WATCH_INTERVAL` until a new stream's snapshot is in. It starts a stream only when
  the core answers, never a core. Without a doorbell there is no stream: it polls.
- A lost agent is not a working one: the app turns on hc's keep for every terminal it adopts,
  and keep puts the user's shell in place of a program that dies by a signal or with the core,
  under the same address and name, still live, with no status (verified). chartroom checks that
  the terminal still runs this task's launcher; one that does not is `gone` in `status`, wakes
  `lost: ... hc put a shell in its place`, refuses `steer`, and is ended by `close` or a
  re-dispatch.
- `doctor`: hc on PATH (or `~/.local/bin/hc`), and a core that answers on its socket
  (`$HC_SOCKET`, else the path in `$XDG_STATE_HOME/herdr-core/<session>/core.lock`). The socket
  is checked by connecting to it before any `hc` command runs, because every `hc` command, even
  `hc ls` or `hc server status`, starts a core when none answers (verified, also over a stale
  socket a killed core left behind).
- **Parking (hc:claude).** Each dispatch starts claude under a session id chartroom picks
  (`--session-id`, meta `session_id`, fresh per dispatch); the prompt hook records the id Claude
  reports, which wins. A worker whose agent is at rest (hc status `idle`/`done`, nothing prompted
  since) for `CHARTROOM_PARK_AFTER_MINUTES` (60) is parked by the watch; `accept` and
  `chartroom park <id>` park one at once, `sweep --apply` the ones due. Parking saves the screen
  to `pane.log`, sets meta `parked` and logs `note: parked (session <id>; ...)` **before** it
  ends the terminal (`hc kill`, `hc rm`; the app drops the tab), so the launcher's `exited` that
  follows is not news. Live idle workers measured 4 processes and 1.06–1.11 GB each (launcher,
  claude, its MCP servers); a parked one, none.
  - Never parked: a turn under way or a prompt taken after its turn ended, an agent blocked at a
    dialog, a joined session, a tool command still running under the agent (Claude Code runs
    every tool command, background ones too, in a shell sourcing one of its shell snapshots;
    any shell under the agent counts), no recorded session id, or no transcript for it under
    `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR`). A worker from before ids were recorded is
    recognised from Claude Code's own `sessions/<pid>.json`, only when that session's
    transcript holds the task's brief line. A refusal is kept in `tasks/<id>/.park-check` (one
    look per grace) and noted when its reason changes.
  - `steer` on a parked worker resumes it: a fresh `hc run` in the worktree with the same labels
    (`herdr.space`, the recorded `herdr.tab`) and launcher settings, running
    `claude --resume <id>` with the message (or its one-line pointer) as its first prompt,
    confirmed by the prompt hook's signature and session id, then `note: revived (...)`.
    `attach` (and the Herdr panel's Open worker, which runs it) resumes with no prompt, then
    shows it. Verified on claude 2.1.318: the message is taken 1.06 s after `hc run`, the prompt
    box is up in 1.1–2.1 s for 4–75 MB transcripts, context kept, no trust dialog. An unknown id
    exits 1 ("No conversation found"); a revive that fails logs `note: revive failed: ...`, the
    one wake for it, and the task stays parked. `dispatch` starts a parked task afresh (a new
    session). Park, steer and attach of a parkable worker share a per-task lock, so no park ends
    a worker while a message goes in.
  - The watch never probes a parked worker (`live: parked`), and starts its turn count from 0, so
    a resumed worker's first finished turn counts. `waiting` and `waiting-overdue` hold while
    parked. Its first turn after a resume re-caches the conversation (measured: 33k of 53k
    tokens read from cache, 20 s after parking), which a live worker steered after the prompt
    cache's lifetime pays as well. hc:codex never parks yet. Under hc, Codex's notify fires and
    carries `thread-id`, which chartroom records as `thread_id` (verified on codex-cli 0.158.0),
    but hc reports no status or turns for Codex, so its at-rest check would have to come from
    the notify events, and its revive (`codex resume <thread>`) is not built.
- Untested here: other machines (`hc run --on`).
  `sweep` and the radar still read herdr only (sweep's parking excepted).

## herdr:<agent> (first class)

- All workers share one herdr workspace labelled `$CHARTROOM_WORKSPACE` (default
  `chartroom-crew`), one unfocused tab per task; the herdr agent name is the task id.
- A brand-new pane is briefly not an "available shell", so `agent start` is retried on
  `agent_pane_busy`. Extra agent flags (sandbox, model, `--add-dir`) are passed after `--`.
- A prompt sent while Claude's startup splash is still up is dropped. chartroom waits for idle,
  then confirms delivery (status `working`, or the text visible) and retries up to 4 times.
- Wakes come from herdr's own agent state: `blocked` (prompt up, as `agent: awaiting-input:
  herdr: ...`), a `working` agent going `idle`/`done` without a report, and an agent that is
  `gone`. Each round asks once, `herdr agent list`, for every herdr task (a herdr without it:
  `agent get` per task). herdr 0.9.5's rules read Codex's approval overlay as `blocked` and its
  "Hooks need review" dialog as `idle` (verified with `herdr agent explain` on real screens), so
  that dialog is told from the screen.
- No server, no herdr command: chartroom looks for herdr's socket in bash first
  (`$HERDR_SOCKET_PATH`, else `$XDG_CONFIG_HOME/herdr/sessions/<HERDR_SESSION>/herdr.sock`, else
  `~/.config/herdr/herdr.sock`, as herdr 0.9.5 reports them). Without it every herdr agent is
  `gone` in `status`, wakes `lost` once, and costs the watch, the radar and `sweep` nothing after
  that; with it a herdr task keeps the watch's full round at `CHARTROOM_WATCH_INTERVAL`.
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
  `-c notify=[chartroom, hook, <id>, codex-notify]`.
- Delivery to Claude (tmux and cmux) is confirmed against the text actually submitted: the
  `UserPromptSubmit` hook logs `agent: prompt-received sig=<12 hex> len=<n>` (sha256 of the
  prompt, whitespace collapsed), and `steer` says `delivered` only when that matches what it
  typed. If another signature arrives and ours does not within `CHARTROOM_DELIVER_WAIT`, it logs
  `note: delivery mismatch ...`, clears the input (Ctrl-U per wrapped line), retypes, and after
  3 mismatches fails loudly. A prompt the session makes itself (a background task's
  completion notice) arriving first is not a mismatch. Verified on Claude Code 2.1.293,
  including a message sent mid-turn (the hook fires when Claude takes the queued message).
- Messages longer than `CHARTROOM_STEER_INLINE_MAX` (default 300) characters, or with a
  newline, are not typed: they go to `tasks/<id>/messages/<n>.md` and the agent gets a one-line
  pointer ("Message from the XO ...: read <file> and act on it."). Typing them was where text got
  cut (a newline submits early; a long paste races Enter). The confirmation then covers the
  pointer, not the agent's reading of the file.
- Codex's prompt-submitted hook would need a review like any other (see the dialogs above), so for
  Codex sessions delivery confirmation reads the screen ("esc to interrupt") and cannot check the
  text: `steer` says `submitted, not verified`, never `delivered`. Its approval prompts come from
  the pane's title and screen, within a look (see Stuck workers). This is weaker than Claude, and
  Codex may report an intermediate turn end while it is still working.
- `attach` = `tmux attach` (or `switch-client` inside tmux). `close` kills the window.

## cmux:<agent> (macOS; implemented, unverified on real cmux)

- manaflow-ai/cmux. One cmux workspace titled `$CHARTROOM_WORKSPACE`, one surface (tab) per
  task (`workspace create --cwd --command`, then `new-surface`), created unfocused.
- Same launcher, hooks and confirmation as tmux; a Codex prompt is told from the screen alone
  (no title to read). Keys go through `send-key --force` so a trust dialog can be answered. `peek` reads the screen (`read-screen --scrollback`); there is no
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
- The wrapper appends `exited: … (exit N)`; a process that dies without one is reported `lost`. A
  run whose `codex.jsonl` stops growing wakes as `stalled` (`claude.jsonl` for headless:claude).

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
- A run whose `output.log` stops growing wakes as `stalled`, with its last lines; one still using
  CPU waits, up to the cap (see Stuck workers).
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
  The agent keeps `chartroom listen <id>` armed; it blocks until a message lands (`steer` rings
  it, so at once), prints it, marks it read, logs `agent: prompt-received mail #n` and exits. `steer` writes the message and
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
  A joined session's `idle_prompt` notification is ignored, and `watch` raises no "stopped its
  turn without reporting" wake while its listener is armed: idling on the listener is normal.
  With no listener armed, a silent turn end wakes the XO as for any worker.
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
