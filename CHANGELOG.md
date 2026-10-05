# Changelog

All notable changes to chartroom. Versions follow SemVer. Before 1.0, minor versions may
change CLI flags. The event-log line format, the brief protocol, and `meta.json` `schema` 1
are stable from 0.1.0.

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
