# Board and the retired dashboard

The web dashboard is retired: its server, its pages (the board, a page per task, the pages list,
the `/radar` page), its themes and its network mode behind an access token are gone. The
[chartroom app](app.md) replaces it. That is one PWA for every home on the brain, reached over
your tailnet: Needs me, the board, a ticket per task with its pages, drafts and terminal, Fleet
and Usage. What stays is the board in the terminal, the lanes JSON the crew views read, and the
fleet radar in the terminal.

```bash
chartroom board                      # the lanes in the terminal, one line per item
chartroom board --json               # the lanes JSON (also: chartroom dashboard --json)
chartroom show 21ba                  # one item in detail (--json for the crew views)
chartroom resolve 21ba               # a short id back to its task or inbox item
chartroom radar                      # every agent on this machine, by sector (see below)
chartroom dashboard                  # opens the app, as chartroom app open does
```

## What `chartroom dashboard` does now

- **`chartroom dashboard`** (or `dashboard open`) opens the app in this machine's browser, as
  `chartroom app open` does. It starts the app's server if none runs, and opens its Tailscale
  Serve address, or `http://127.0.0.1:<port>/` when the server runs with `--no-auth`. It takes
  no flags. The `dashboard` skill (`/dashboard`) runs exactly this. Setting the app up (its one
  user, Tailscale Serve) is in [docs/app.md](app.md#run-it-on-the-brain).
- **From a client home** it asks the brain for its app's address and opens that here, over the
  tailnet. Nothing is tunnelled. See [docs/client-homes.md](client-homes.md#attach-peek-dashboard-artifacts).
- **`chartroom dashboard url`** prints the app's address. **`dashboard status`** prints it, or
  why there is none, and says when an old web dashboard still runs.
- **`chartroom dashboard stop`** ends only an old web dashboard left running from before the
  upgrade, and in a client home an old tunnel to the brain's. `chartroom app stop` stops the app.
  `chartroom sweep --apply` also ends a leftover dashboard server.
- **`chartroom dashboard --json`** is the board's lanes, the same as `board --json`.
- **`chartroom artifact open <ref>`** opens a page in the app's page viewer,
  `<app url>#/p/<home>/<task|inbox>/<owner>/<slug>`. The app shows registered homes only
  (`chartroom homes add <name> <path>`).
- **`chartroom init --dashboard-port`** is ignored, with a warning. Homes no longer get a port of
  their own.

## The board

`chartroom board` prints five lanes, one line per item: short id, `[project]`, title, state, the
refs of its open [artifacts](../README.md#artifacts-drafts-that-outlive-the-chat) and a snippet of
the last event, then the artifact count. Color is used only on a terminal (`--color`,
`--no-color`). `--json` is the lanes JSON that the crew views and the Claude Code panel poll,
with [your todo list](../README.md#your-next-steps-the-todo-list) as `todo`. `--all-homes` reads
every registered home.

| Lane | What lands there |
|---|---|
| **Needs you** | tasks in `decision`, `blocked`, `failed`, `awaiting-input` or `review` (in that order; `review` is a worker's finished work awaiting your look: a PR to review, a merged PR or a report to read), then the "Waiting on ..." items in `inbox.md` with their question text; every item leads with its project |
| **In progress** | `working` and `drafting` tasks, and `waiting` ones: a worker that ended its turn right after a `waiting` event, inside its window (the item shows what it waits on and until when) |
| **On hold** | `stopped-silent` and `waiting-overdue` tasks; tasks whose last event (other than their own `waiting` event) says they wait on a person ("waiting on/for", "awaiting review", "pending approval", "on hold"); done tasks whose open PR still needs someone's review |
| **Ready for you** | `done` tasks (ones you accepted) that are not closed yet |
| **Recently finished** | tasks closed in the last 48 hours (`CHARTROOM_DASHBOARD_RECENT_HOURS`), and done tasks whose PRs are all merged |

The two rules that go by a PR's state (an open PR awaiting review, every PR merged) need PR
states from `gh`. `chartroom board` looks none up, so there a PR's state is unknown and those two
rules do not apply. The app's tickets show each PR's state and checks.

While [focus mode](../README.md#focus-mode-one-project-at-a-time) is on, the board leads with the
focus line, each lane's count says how many it holds, and a held item reads `[<state> · held]`.
Approvals given in chat but not yet in a brief, and open
[relays from other homes](homes.md#talking-between-homes), are in the lanes JSON too.

`chartroom show <id>` is one item in detail: its line on the board plus the commander's intent,
the last events, the outcome, the report's summary, PRs, artifacts and where the worker runs.
`--json` adds those fields to the board's, which stay unchanged.

A legacy home works the same: `CHARTROOM_HOME=~/.captain chartroom board`.

## Short ids

Each item has a short id: a task's 4-hex suffix (`21ba`, grown to the shortest unique suffix
such as `n-21ba` when two open tasks share one), or an inbox item's `i-7f3a` tag. Paste
`/continue <id>` into the XO session and the `continue` skill takes you straight to what the item
needs from you. `chartroom resolve <id>` maps any short or full id back. Inbox items get their
tag from `chartroom inbox add [--project P] <text>` (or `chartroom inbox tag` for lines written by
hand); it never changes as other items come and go.

## Every question carries its project

`chartroom inbox add --project webapp "which region?"` writes
`- [i-7f3a] 2026-01-02 — [webapp] which region?`. `--project` takes a name (`multi` for a
question that spans projects) or a repo path (its directory name). The board, `resolve --json`
and the lanes JSON (`project` on inbox items, `null` on a line without a label) all show it.
`chartroom inbox project i-7f3a webapp` labels an item that has none. `status` puts the project
right after the id, and every `watch` wake reads `[<id>] [<project>] <event>`, so the XO relays a
decision already labelled. The skills have it lead every question it puts to you with
`**[project]**` (and, in Claude Code, use the project as the question's header).

## The fleet radar

`chartroom radar` lists every open task on every home of a machine by sector (Decision, Blocked,
Adrift, Under way, Holding, Docked), with each home's XO. The Herdr app's Tasks panel reads it.
Its sectors, the machines it reads and its read-only rules are in
[docs/fleet.md](fleet.md#the-fleet-radar). The page that drew it as robots on a scope is retired
with the dashboard; the app's Fleet shows every session on every machine instead.

## Readable events

The parser that sets a worker's event as a readable note now lives in `app/shared/eventfmt.js`,
and the app uses it. See [docs/app.md](app.md#readable-events).
