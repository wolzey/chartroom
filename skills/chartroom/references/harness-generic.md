# Running the XO in any other agent

Gemini CLI, pi, opencode, Cursor, Amp, Copilot, or anything that can run a shell command and
read a Markdown file works. You need no special tools: chartroom is a CLI plus files.

## Loading the skill

- **Agent Skills directories**: `chartroom install-skills --agents` links the skills into
  `~/.agents/skills` (read by Codex and Gemini CLI); `--pi` into `~/.pi/agent/skills`; `--dir <d>`
  for any other skills directory your agent reads.
- **No skills support**: start the agent in `$CHARTROOM_HOME`; `chartroom init` writes an
  `AGENTS.md` there that tells it to read this skill. Or paste
  `adapters/agents-md/AGENTS.md` into the agent's global instructions.

## Waiting for wakes

Same as Codex: block on `chartroom watch --once --timeout <seconds>` (shorter than your shell
tool's timeout). Exit 0 means wakes were printed; exit 124 means nothing happened. Repeat while
work is in flight. If your agent can run a background process and get notified on output,
`chartroom watch` (a stream) works too.

## No subagents

The `subagent` backend is hidden. Use session runners (`herdr`, `cmux`, `tmux`) for work the
commander may want to watch, and `headless:*` or `command` for everything else.
