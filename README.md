# chartroom

**Run a crew of coding agents from one agent session.**

You talk to one agent, the **XO**. You are the **commander**. The XO turns what you ask for
into briefs and hands each one to a **crew** member: a Claude Code or Codex worker in its own
git worktree. It supervises them and comes back with outcomes, real decisions, and evidence.
You don't juggle tabs.

chartroom has two parts: a small bash CLI (`chartroom`) that does the exact work (task
records, worktrees, launching, steering, liveness, a wake stream), and Agent Skills
(`chartroom`, `bearings`, and `dashboard` to open the board) that tell your agent how to be the XO. State is plain files under
`~/.chartroom`. There is no daemon (an optional local dashboard can show the fleet in a browser).

```
            you (commander)
                 │  "fix the flaky login test, and find out why CI is slow"
                 ▼
        XO  (Claude Code / Codex / Gemini / any agent, running the chartroom skill)
                 │  chartroom new / dispatch / watch / steer / close
     ┌───────────┼─────────────────────┬──────────────────────┐
     ▼           ▼                     ▼                      ▼
 herdr tab   cmux tab / tmux window   headless claude -p     codex exec / any CLI
 (watchable, live steering)            (live steering)        (steer between runs)
     └────── each in its own git worktree; events → ~/.chartroom/tasks/<id>/events.log
```

## Why another one?

[kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) solves the same problem with
a similar metaphor and is much further along. It supports more harnesses, more session
backends, secondmates on other hosts, Relay, Gerrit/GitLab flows, and has a larger community.
**If you want the full-featured system, use firstmate.**

chartroom is the small one. The differences that are real:

- **It installs into your existing setup instead of being one.** firstmate is an "agent distro":
  you clone it and launch your agent inside it. chartroom is a CLI on your PATH plus three skills
  linked into the agents you already use. Your home directory, config and other skills stay as
  they are.
- **No multiplexer required.** Headless workers (`claude -p` with live steering over a stream,
  `codex exec` with resume) are first-class backends. So are plain commands: any CLI can be a
  worker through a template. It degrades from herdr to cmux to tmux to headless to a command,
  writes down every fallback, and never fails just because herdr isn't there.
- **Agent-native signals instead of screen scraping.** Turn ends, approval prompts and prompt
  receipt come from Claude Code hooks and Codex `notify`, not from pattern-matching the TUI.
- **Small surface.** About 1,600 lines of bash across a few files, with `jq` and `git`. No `gh`
  required, no worktree manager, no Node.
- **The contract is files.** Briefs, an append-only event log with a documented line format, and
  reports. Any worker in any language can take part with `printf >>`.

## Install

Requirements: bash ≥ 4 (macOS: `brew install bash`), `jq`, `git`. Optional, per backend:
herdr, cmux (macOS), tmux ≥ 3.0, the `claude` and/or `codex` CLIs.

```bash
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash
chartroom doctor            # what can run here, and why not
chartroom install-skills    # link the skills into the agents it finds (--claude, --agents, --pi, --dir D)
```

The installer clones into `~/.local/share/chartroom`, links `~/.local/bin/chartroom`, and runs
`chartroom init`. Re-running it updates the checkout (fast-forward only).

Per agent:

| Agent | How it loads chartroom | How the XO waits for wakes |
|---|---|---|
| Claude Code | `chartroom install-skills --claude`, **or** `/plugin marketplace add wolzey/chartroom` then `/plugin install chartroom@chartroom` (skills only; the CLI still comes from install.sh) | `Monitor` running `chartroom watch` |
| Codex CLI | `chartroom install-skills --agents` (`~/.agents/skills`) | loop on `chartroom watch --once --timeout 1500` |
| Gemini CLI | `chartroom install-skills --agents` (Gemini reads `~/.agents/skills`), or `gemini skills link <checkout>/skills/chartroom` | same as Codex |
| pi | `chartroom install-skills --pi` | same as Codex |
| opencode, Cursor, Amp, Copilot, others | paste [`adapters/agents-md/AGENTS.md`](adapters/agents-md/AGENTS.md) into the agent's instructions, or start it in `~/.chartroom` (its `AGENTS.md` points at the skill) | same as Codex |

## Quickstart

```bash
chartroom init
cd ~/.chartroom && claude        # or codex, gemini, pi ...
```

Then talk to it: *"In ~/code/todo-cli, add a --json flag to `list`, and separately find out
why the test suite takes four minutes."* The XO resolves the project, writes two briefs (one
**ship**, one **scout**), dispatches them on the best available backends, and goes quiet until
something needs you. Ask *"bearings"* at any time for a four-part digest: needs you, ready,
under way, trouble.

## Dashboard

```bash
chartroom dashboard                  # http://127.0.0.1:4517, Ctrl-C to stop
chartroom dashboard --daemon --open  # in the background, and open the browser
chartroom dashboard open             # reuse the running one (or start it), then open the browser
chartroom dashboard stop             # (or: status)
chartroom dashboard --json           # the same lanes, no server
```

A one-page, read-only view of the fleet that refreshes every 5 seconds, so you can see what
to pull from. It works on a phone-width window and follows your light/dark setting. It has
five lanes, each with a count in the header:

| Lane | What lands there |
|---|---|
| **Needs you** | tasks in `decision`, `blocked`, `failed` or `awaiting-input` (in that order), then the "Waiting on ..." items in `inbox.md` with their question text |
| **In progress** | `working` and `drafting` tasks, and `waiting` ones: a worker that ended its turn right after a `waiting` event, inside its window (the card shows what it waits on and until when) |
| **On hold** | `stopped-silent` and `waiting-overdue` tasks; tasks whose last event (other than their own `waiting` event) says they wait on a person ("waiting on/for", "awaiting review", "pending approval", "on hold"); done tasks whose open PR still needs someone's review |
| **Ready for you** | `done` tasks that are not closed: a PR to review or a report to read |
| **Recently finished** | tasks closed in the last 48 hours (`CHARTROOM_DASHBOARD_RECENT_HOURS`), and done tasks whose PRs are all merged |

Each card shows the title, project, age, the last worker event, PR/MR links found in
`events.log` and `report.md`, and links that open the task's brief, report, plan and event log
as plain text. Approvals given in chat but not yet in a brief are listed under Needs you.

How it is built, and what it promises:

- **Loopback only, read-only.** A Python standard-library server (`python3`, nothing to
  install) bound to `127.0.0.1`, with no setting to change that. It answers `GET` only, serves
  just the page, the lanes JSON (`/api/dashboard`) and the five task files above, and refuses
  requests whose `Host` is not `127.0.0.1` or `localhost` (DNS rebinding). No auth, because
  nothing off the machine can reach it.
- **No external requests from the page.** CSS and JS are inline; no CDNs, fonts or analytics.
- **Same answer as the CLI.** The lanes come from `chartroom dashboard --json`, built from the
  rows `chartroom status` uses, so the page and the terminal never disagree.
- **PR states are optional.** If `gh` is on your PATH, the server looks up the state of the PR
  links it found (cached, refreshed every 5 minutes) to move a merged PR to Recently finished and
  one awaiting review to On hold. That is the only network traffic, and it is GitHub's API with
  your own `gh` login. `--no-gh` turns it off; without `gh`, or offline, the page just shows the
  links.
- `--daemon` writes `.dashboard.pid` (pid and port) and `.dashboard.log` in the home. One
  dashboard per home; `--port 0` picks a free port.
- `dashboard open` reuses this home's dashboard if it answers on its port; otherwise it
  replaces a stale pid file (or a server that stopped answering), starts one with `--daemon`
  and waits for it. Then it opens the URL with `CHARTROOM_OPENER`, else `open` (macOS) or
  `xdg-open`, and prints it either way. A lock in the home (holding its owner's pid; taken over only when that pid is gone) keeps two calls from starting two
  servers. The `dashboard` skill (`/dashboard`) runs exactly this.
- A legacy home works the same: `CHARTROOM_HOME=~/.captain chartroom dashboard`.

## Concepts

- **Commander / XO / crew.** You, the coordinating agent, the workers. The crew never talks to you
  directly. Everything goes through the XO.
- **Brief** (`tasks/<id>/brief.md`): the commander's intent (verbatim), a spec, explicit authority,
  and the worker protocol. `dispatch` refuses a brief with no intent.
- **Ship vs scout.** Ship tasks commit on `chartroom/<id>` in their own worktree. Scouts produce a
  report and no commits.
- **Plan gate** (`new --plan-gate`): the worker writes `plan.md`, raises a decision and stops
  until you approve.
- **Authority is explicit.** Workers never push, open PRs, merge, or delete branches unless the
  brief grants it for that task. `close` refuses a dirty worktree, and branches are never deleted.

## Backends

A backend is `<runner>:<agent>`, where the agent is `claude` or `codex`.

| Backend | Runs in | Watch | Steering | Needs | Status |
|---|---|---|---|---|---|
| `herdr:<agent>` | a herdr tab (first class) | yes | live | herdr running | verified (herdr 0.9.1) |
| `cmux:<agent>` | a cmux tab (macOS) | yes | live | cmux app, automation socket mode if the XO runs outside cmux | **implemented, unverified on real cmux** |
| `tmux:<agent>` | a tmux window | yes (`chartroom attach`) | live | tmux ≥ 3.0 | verified (tmux 3.x) |
| `headless:claude` | `claude -p`, stream-json in/out | `peek` | live (stdin stream), resume after | claude CLI | verified (2.1.289) |
| `headless:codex` | `codex exec --json` | `peek` | between runs (`exec resume`) | codex CLI | verified (0.158.0) |
| `command` | any CLI from a template (`{brief} {prompt} {worktree} {task_dir} {id}`) | `peek` | between runs (+ best-effort inbox) | nothing | tested with the stub agent |
| `subagent` | the host harness's subagent | no | host | Claude Code only | carried over, not re-verified |

Default automatic order: `herdr:claude cmux:claude tmux:claude headless:codex headless:claude command`
(`CHARTROOM_BACKEND_ORDER`). When a backend is chosen automatically and the first choice isn't
available, chartroom uses the next one and records `note: backend fallback: herdr:claude
unavailable (herdr not on PATH); using tmux:claude (steering: live)`. When you name a backend
explicitly, it never silently downgrades. Dispatch fails and names the next viable option.
`CI=true` disables session runners. Details, including how each one confirms delivery:
[skills/chartroom/references/backends.md](skills/chartroom/references/backends.md).

**First-launch trust dialogs.** Claude Code and Codex ask before working in a never-seen
folder. chartroom answers that dialog only for a worktree it created itself for the task, and
only after reading which option the cursor is on. Anything else is left for a human and
raised as a wake. It never edits your agent config to pre-trust paths.

## State format and event protocol (the contract)

```
$CHARTROOM_HOME/                    default ~/.chartroom
  commander.md  projects.md         standing preferences, per-project overrides
  inbox.md                          questions waiting on the commander, chat approvals not yet in a brief
  AGENTS.md  CLAUDE.md              "a session here is the XO"
  tasks/<id>/meta.json              {"schema":1, id, kind, backend, project, base_sha, branch, worktree, ...}
  tasks/<id>/brief.md  report.md  plan.md  final.md
  tasks/<id>/events.log             one line per event
  .dashboard.pid  .dashboard.log    only while `chartroom dashboard --daemon` runs
  worktrees/<repo>/<id>/            task worktrees (unless the repo ignores .worktrees/)
```

Event lines are `<ISO-8601 UTC> <kind>: <text>`. They are append-only, and any process may
write them:

| Kind | Written by | Wakes the XO |
|---|---|---|
| `progress` | worker | no |
| `waiting` | worker, right before ending a turn to wait on CI, a review, a timer or a person: what, and until when (`... until 2026-01-05T15:30:00Z`) if known | no; once, as `waiting overdue: ...`, if the worker is still stopped when the window runs out |
| `decision` `blocked` `done` `failed` | worker | yes |
| `note` | chartroom (created, dispatched, worktree, fallback, closed, `waiting overdue`) | no |
| `steered` | chartroom (`steer`) | no |
| `exited` | process wrappers (`... (exit N)`) | yes, unless the worker reported first |
| `agent` | hooks: `turn-ended`, `awaiting-input: <why>`, `prompt-received` | `turn-ended` without a report, and `awaiting-input` |

A worker whose newest report is `waiting` and whose session has stopped shows as `waiting` in
`status` (not `stopped-silent`) until its until-time plus `CHARTROOM_WAITING_GRACE_MINUTES`, or,
with no until-time, `CHARTROOM_WAITING_MAX_MINUTES` after the event; then `waiting-overdue`.
Any later report, steer or dispatch closes the wait. `status --json` rows carry `waiting_on`,
`waiting_until` and `waiting_since` (null without an open wait).

The event line format, the brief protocol and `meta.json`'s `schema` field are stable from 0.1.
CLI flags may change before 1.0.

## Safety model

- Workers get the worktree, the brief, and the authority the brief grants: nothing else.
- Headless workers can't ask for permission, so their permissions are set before dispatch.
  Codex scouts are sandboxed (`workspace-write`). Codex ship tasks default to
  `danger-full-access`, because current Codex can't commit inside its sandbox. Claude headless
  uses `acceptEdits` plus an allowed-tools list that includes Bash. These are real sharp edges.
  Tighten them with `CHARTROOM_CODEX_SHIP_SANDBOX`, `CHARTROOM_CLAUDE_ALLOWED_TOOLS`,
  `CHARTROOM_CLAUDE_HEADLESS_PERMISSION`, or per task with `new --permission` / `meta.sandbox`.
- Interactive workers use your agent's own settings unless the task sets `--permission`.

## Configuration

Environment variables win. Otherwise chartroom reads `~/.config/chartroom/config`
(`KEY=VALUE`, no shell evaluation; `CHARTROOM_CONFIG` overrides the path).

| Key | Default | |
|---|---|---|
| `CHARTROOM_HOME` | `~/.chartroom` | legacy: `CAP_HOME`, then an existing `~/.captain` |
| `CHARTROOM_PROJECT_ROOTS` | *(empty)* | colon-separated dirs searched by `chartroom project <name>` |
| `CHARTROOM_WORKSPACE` | `chartroom-crew` | herdr workspace / cmux workspace / tmux session name |
| `CHARTROOM_BACKEND_ORDER` | see above | space- or comma-separated |
| `CHARTROOM_HARNESS` | `generic` | `claude` enables the `subagent` backend |
| `CHARTROOM_BRANCH_PREFIX` | `chartroom/` | |
| `CHARTROOM_TMUX_SOCKET` | *(default server)* | run the crew on `tmux -L <name>` |
| `CHARTROOM_COMMAND` | *(empty)* | default template for the `command` backend |
| `CHARTROOM_CODEX_SHIP_SANDBOX` / `_SCOUT_SANDBOX` | `danger-full-access` / `workspace-write` | |
| `CHARTROOM_CLAUDE_PERMISSION` | *(agent default)* | interactive Claude `--permission-mode` |
| `CHARTROOM_CLAUDE_HEADLESS_PERMISSION` | `acceptEdits` | |
| `CHARTROOM_CLAUDE_ALLOWED_TOOLS` | `Bash Read Edit Write Glob Grep WebFetch WebSearch` | headless Claude |
| `CHARTROOM_WATCH_INTERVAL` | `3` | seconds |
| `CHARTROOM_DASHBOARD_RECENT_HOURS` | `48` | how far back the dashboard's Recently finished lane reaches |
| `CHARTROOM_GH` | `gh` | the gh binary the dashboard uses for PR states |
| `CHARTROOM_OPENER` | `open` / `xdg-open` | command `dashboard open` runs with the URL |
| `CHARTROOM_WAITING_GRACE_MINUTES` | `15` | a `waiting` worker turns `waiting-overdue` this long after its until-time |
| `CHARTROOM_WAITING_MAX_MINUTES` | `120` | ... or this long after the event, when it names no until-time |

`CAP_PROJECT_ROOTS`, `CAP_CREW_WORKSPACE` and `CAP_WATCH_INTERVAL` are read as legacy fallbacks.

## FAQ

**Does it work without herdr or tmux?** Yes. In a plain terminal it uses tmux if it's installed,
otherwise headless workers. Over SSH or in CI it runs headless or command workers only.
`chartroom doctor` tells you which.

**Can a worker be something other than Claude or Codex?** Yes: `--backend command --command
'your-agent --prompt {prompt} --cwd {worktree}'`. The worker reports by appending event lines
(the brief tells it how).

**Where do I watch a worker?** `chartroom attach <id>` (tmux, herdr or cmux), or `chartroom peek <id>`.

**Does it push or open PRs?** Only when you tell the XO to, for that task. The worker does it
through your forge's CLI.

## Contributing

```bash
shellcheck -x -S warning bin/chartroom lib/*.sh lib/backends/*.sh install.sh scripts/*.sh test/stub-agent test/fakes/*
bats test/                 # no herdr/tmux/cmux/claude/codex needed: fakes and a stub agent
scripts/privacy-gate.sh    # no personal data in tracked files
```

Maintainers: merge by fast-forward pushing `main` from a local clone whose commits use the
GitHub noreply identity as both author and committer. Never merge through the GitHub web UI:
squash, rebase and merge-commit merges all stamp the merging account's name and primary email
on the commit, which the privacy gate (rightly) rejects on `main`. The PR shows as merged once
its commits land on `main`.

## License

MIT. See [LICENSE](LICENSE).
