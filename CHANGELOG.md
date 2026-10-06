# Changelog

All notable changes to chartroom. Versions follow SemVer. Before 1.0, minor versions may
change CLI flags. The event-log line format, the brief protocol, and `meta.json` `schema` 1
are stable from 0.1.0.

## [Unreleased]

### Added
- Short ids. Every task has one: its 4-hex suffix (`fix-login-21ba` -> `21ba`), grown to the
  shortest unique suffix when two open tasks share it (`n-21ba`, `g-21ba`); an id given with
  `new --id` is its own short id. Items under "Waiting on the commander" in `inbox.md` carry a
  stable `[i-7f3a]` tag right after the bullet, written once by `chartroom inbox add <text>` or
  `chartroom inbox tag` (for hand-written lines; idempotent), so adding or removing items never
  moves them. `chartroom resolve <id> [--json]` maps a full or short id back to the task or
  inbox item and fails on an unknown or ambiguous one. `status --json` rows and every
  dashboard card gain `short_id` (existing fields unchanged); the dashboard shows it on each
  card and copies `/continue <id>` on click.
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
