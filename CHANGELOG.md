# Changelog

All notable changes to chartroom. Versions follow SemVer. Before 1.0, minor versions may
change CLI flags. The event-log line format, the brief protocol, and `meta.json` `schema` 1
are stable from 0.1.0.

## [Unreleased]

### Added
- Joining a running session. Tell an agent session you started yourself "join chartroom" (the
  new `join` skill, linked by `install-skills`) and it becomes a supervised worker of the home:
  `chartroom join` records it as a `joined:<agent>` task in its own directory and branch (no
  new worktree; `close` only marks it closed and never removes or cleans the directory), the
  agent writes its own brief, and re-running join in the same session returns the same task.
  Steering goes through a mailbox: `chartroom listen <id>` blocks until the XO's next message,
  prints it and marks it read, and `steer` reports `delivered` only once it was read, else
  `queued, not yet read`. In Claude Code the listener runs as a background command, so an idle
  session wakes when a message lands (verified on 2.1.293); Codex and other agents use
  `listen --check` between steps. tmux and herdr panes are recorded only when verified as the
  session's own (by process ancestry), for peek, attach and stop. The skill's session-scoped
  hooks report turn ends and prompts through `chartroom hook --session`, found by session id
  in `${XDG_STATE_HOME:-~/.local/state}/chartroom/sessions`; the agent's pid ending is recorded
  once as `exited` and wakes `watch`. `doctor` lists `joined:claude` and `joined:codex` with
  their steering. New config: `CHARTROOM_JOIN_ACK_WAIT` (seconds `steer` waits for the read,
  default 20).
- A rulings ledger. `chartroom rule add --topic <slug> "<text>"` appends the commander's
  lasting preference to `rulings.log` (`<ts> [r-xxxx] topic=... supersedes=... src=... :: text`,
  append-only); the newest ruling in a topic wins and records the one it supersedes, and the
  live set is rendered into a generated block in `commander.md` (or a legacy `captain.md`),
  leaving hand-written text alone. `rule retire`, `rule list [--all] [--json]` (with supersede
  chains) and `rule render` round it out. `rule draft` and `rule import <map> [--apply]` move an
  existing file's hand-written bullets into the ledger once: a dry run by default, and a backup
  under `records/` before anything changes. The chartroom, bearings and continue skills record
  preferences with `rule add` instead of editing `commander.md`, and the template gains the
  empty block.
- README: an optional local hostname for the dashboard (`http://chartroom/`), a Caddy
  reverse proxy on its own loopback address that rewrites `Host` past the rebinding guard.
- A `captain` skill: the chartroom skill under its older name, with a table of the older
  words (captain, `captain.md`, `cap`, the old backend names). `install-skills` links it with
  the others, so `/captain` and a legacy home whose `AGENTS.md` asks for it keep working.
- README: updating chartroom, running it on several machines (what to share, what stays per
  machine), and moving a home from before chartroom (config, skills, a helper shim for briefs
  already handed out).
- Dashboard themes: `chartroom` (the default) and `hud`, a machine-vision look in red and
  amber with scanlines, a header radar and a reticle that locks onto cards. Same lanes and
  cards in both, each with light and dark variants and reduced-motion support. Pick the
  server's default with `chartroom dashboard --theme NAME` or `CHARTROOM_DASHBOARD_THEME` (env
  or config file). A theme menu in the page overrides it per browser, next to a light/dark/auto
  toggle.
- Short ids. Every task has one: its 4-hex suffix (`fix-login-21ba` -> `21ba`), grown to the
  shortest unique suffix when two open tasks share it (`n-21ba`, `g-21ba`); an id given with
  `new --id` is its own short id. Items under "Waiting on the commander" in `inbox.md` carry a
  stable `[i-7f3a]` tag right after the bullet, written once by `chartroom inbox add <text>` or
  `chartroom inbox tag` (for hand-written lines; idempotent), so adding or removing items never
  moves them. `chartroom resolve <id> [--json]` maps a full or short id back to the task or
  inbox item and fails on an unknown or ambiguous one. `status --json` rows and every
  dashboard card gain `short_id` (existing fields unchanged); the dashboard shows it on each
  card's top-right corner and copies `/continue <id>` on click (with a brief "copied").
- `chartroom board [--json] [--color|--no-color]`: the dashboard's lanes in the terminal, built
  from the same `dashboard --json`, one line per item (short id, title, state, last event),
  colored only when stdout is a terminal and `NO_COLOR` is unset.
- A `continue` skill (`/continue <id>`): the XO resolves the id and takes the commander
  straight to the point: the pending question (asked with the agent's question tool,
  recommendation first), the outcome and landing options, or a one-line status.
  `install-skills` links it with the others.
- A `waiting` worker event: a worker records it right before ending a turn to wait on
  something (CI, a review, a timer, a person), with an optional `until <UTC time>`. A stopped
  worker whose newest report is `waiting` is `waiting` in `status` (In progress on the
  dashboard, with what it waits on and until when) instead of `stopped-silent`; past its window
  (until-time + `CHARTROOM_WAITING_GRACE_MINUTES`, default 15, or `CHARTROOM_WAITING_MAX_MINUTES`,
  default 120, without one) it is `waiting-overdue` (On hold). `watch` no longer wakes on a turn
  end or exit right after `waiting`, and wakes once, as `waiting overdue: ...` (recorded as a
  note), when the window runs out. `status --json` rows gain `waiting_on`, `waiting_until` and
  `waiting_since`. The brief protocol documents the new kind.
- `chartroom dashboard open`: reuse this home's dashboard if it answers, else start it as a
  daemon (replacing a stale pid file), then open it in the browser (`CHARTROOM_OPENER`, `open`,
  `xdg-open`, or print the URL). A new `dashboard` skill (`/dashboard`) runs it, and
  `install-skills` links it with the others.
- `chartroom dashboard [--port N] [--open] [--daemon] [--no-gh]`, `dashboard stop|status`, and
  `dashboard --json`: a local, read-only web page of the fleet in five lanes (needs you, in
  progress, on hold, ready for you, recently finished) with counts, last events, PR links and
  the task files. A Python standard-library server bound to 127.0.0.1 only, with a Host-header
  check, inline CSS/JS and no external requests; optional PR states from `gh`, cached, and
  harmless when `gh` is missing or offline. Works on a legacy `~/.captain` home.
- `chartroom status --json` rows also carry `last_at`, `updated`, `dispatched`, `closed`,
  `branch` and `has_report` (existing fields unchanged).
- `inbox.md` in the home: questions waiting on the commander and approvals given in chat
  that are not yet in a brief, so they survive a compaction or restart. `chartroom init`
  creates it (never overwrites), `chartroom status` prints a one-line count of open items,
  the XO skill keeps it current, and `bearings` folds its waiting items into "Needs you".

### Fixed
- The dashboard on phones and tablets: the header no longer overlaps itself at tablet widths
  (768px), lane-count labels wrap instead of being cut, no text is under 12px below 1100px,
  every control is a 44px tap target on touch screens, and a card's last event shows up to
  three lines on a phone instead of one cut line.
- `steer` to a Claude session worker (tmux, cmux, herdr) no longer says `delivered` when only a
  fragment of the message was submitted. The UserPromptSubmit hook now records a signature of
  the submitted prompt (`agent: prompt-received sig=<12 hex> len=<n>`) and delivery is confirmed
  only when it matches the text typed; on a mismatch chartroom clears the input, retypes (at most
  3 times) and then fails. herdr Claude workers get that one hook (prompt mode) for this. Codex
  sessions have no prompt hook and now report `submitted, not verified` instead of `delivered`.
- Messages longer than `CHARTROOM_STEER_INLINE_MAX` (default 300) characters, or with a newline,
  are written to `tasks/<id>/messages/<n>.md` and the agent gets a one-line pointer to it, instead
  of being typed into the TUI where a newline submitted early or a long paste raced Enter.
- Event lines stay one per line: a newline in an event's text (a multi-line steer) is written as
  a space.
- `watch` no longer raises "stopped its turn without reporting" for a joined session that ends a
  turn with its listener armed, its normal resting state; it still does when no listener is armed.
- chartroom works when a GUI app (Claude Desktop, an IDE) launches the agent. Those start a
  login, non-interactive shell, where `env bash` is often macOS's bash 3.2 and Homebrew's dirs
  are missing or come after `/bin`. `bin/chartroom` now finds a bash >= 4 (on PATH, then in
  `/opt/homebrew/bin`, `/usr/local/bin`, `brew --prefix`, Nix profiles and MacPorts'
  `/opt/local/bin`; `CHARTROOM_BASH_SEARCH` replaces that list) and re-runs itself under it,
  with a guard so it cannot loop; with none found, the error names where it looked and how to
  fix it. On macOS it also appends Homebrew's bin dirs to PATH when they exist and are missing,
  after the user's own entries, so backends and the workers they spawn find herdr, tmux, gh and
  jq (`CHARTROOM_PATH_APPEND` replaces the list; empty turns it off). `doctor` shows the bash it
  runs under, what it was re-run from, and a thin PATH (`bash` and `path` in `--json`).
  `install.sh` applies the same search. The `join` skill's hooks read the session id with `sed`
  instead of `jq`, since they run in the launching shell before chartroom can fix its PATH.

### Changed
- README reads on its own: the comparison with another project is gone; the differences that
  matter are listed under Design.
- Skills: the `chartroom` skill points at the dashboard and `board`; `continue` appends the
  commander's words to the brief's intent when it relays an answer.
- The dashboard page moves: working tasks show a heartbeat, a wake and ticking timers, waiting
  ones ride at anchor with a countdown, needs-you cards glow, cards glide between lanes, new
  events wash in, and counts tick. A ship's log strip shows the newest events. Cards are keyed
  by id instead of rebuilt on every poll. `prefers-reduced-motion` turns the motion off. The
  JSON API is unchanged.

## [0.1.0] - 2026-10-05

First public cut, extracted from a private tool and generalized.

### Added
- `chartroom` CLI: `init`, `doctor`, `project`, `new`, `worktree`, `dispatch`, `steer`
  (`--inbox`), `stop`, `attach`, `event`, `hook`, `status`, `peek`, `watch` (`--once`,
  `--timeout`, persistent cursor), `close` (`--discard`), `install-skills`, `version`.
- Backends as `<runner>:<agent>`:
  - `herdr:{claude,codex}`: first class, verified on herdr 0.9.1.
  - `cmux:{claude,codex}` (manaflow-ai/cmux, macOS): **implemented against the documented CLI,
    unverified on a real cmux install**. Covered by bats with a stub `cmux`.
  - `tmux:{claude,codex}`: one window per task, pipe-pane log, `attach`.
  - `headless:claude`: pre-assigned session id, live steering over a stream-json FIFO,
    `--resume` after the run.
  - `headless:codex`: `codex exec --json`, `exec resume` between runs.
  - `command`: any CLI from a template. `subagent`: Claude Code only.
- Automatic fallback down `CHARTROOM_BACKEND_ORDER`
  (herdr → cmux → tmux → headless → command), recorded as a `note` event. Explicit choices
  never silently downgrade.
- Agent-native wakes: Claude Code `Stop` / `Notification` / `UserPromptSubmit` hooks and Codex
  `notify` become `agent:` events.
- One trust-dialog policy across runners: answered only for worktrees chartroom created.
- Harness adapters: Claude Code plugin manifest, `references/harness-{claude,codex,generic}.md`,
  an AGENTS.md snippet, and `install-skills` for `~/.claude/skills`, `~/.agents/skills`
  (Codex, Gemini) and `~/.pi/agent/skills`.
- `install.sh`, config file `~/.config/chartroom/config`, `CHARTROOM_*` settings with `CAP_*`
  and `~/.captain` legacy fallbacks, a state `schema` field in `meta.json`.
- Commander / XO / crew persona; `commander.md` (a legacy `captain.md` is kept and read).
- bats suite (no AI CLI or multiplexer needed), shellcheck, and a no-personal-data gate in CI.

### Fixed (relative to the private tool)
- `dispatch` no longer holds the caller's stdout open until a headless or command worker exits.
- `claude -p` with stream-json input doesn't exit on a late stdin EOF; the wrapper ends it
  after its final result.
- Requires bash ≥ 4 explicitly, with a clear error on macOS's bash 3.2.
- The privacy gate also scans symlink targets and every commit's metadata.
