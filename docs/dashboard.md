# Dashboard

```bash
chartroom dashboard                  # http://127.0.0.1:4517, Ctrl-C to stop
chartroom dashboard --daemon --open  # in the background, and open the browser
chartroom dashboard open             # reuse the running one (or start it), then open the browser
chartroom dashboard --theme hud      # start with the HUD theme as the default
chartroom dashboard --daemon --expose  # on the network too, behind an access token (see below)
chartroom dashboard stop             # (or: status)
chartroom dashboard --json           # the same lanes, no server
chartroom board                      # the same lanes in the terminal, one line per item
chartroom show 21ba                  # one item in detail (--json for the crew views)
```

A one-page, read-only view of the fleet that refreshes every 5 seconds, so you can see what
to pull from. It works on phones and tablets (lanes stack, nothing scrolls sideways, text is
12px or larger and every control is a 44px tap target) and follows your light/dark setting (or a
light/dark toggle in the header). Work in progress visibly moves, changes animate, and
`prefers-reduced-motion` turns all motion off. It has five lanes, each with a count in the
header:

| Lane | What lands there |
|---|---|
| **Needs you** | tasks in `decision`, `blocked`, `failed`, `awaiting-input` or `review` (in that order; `review` is a worker's finished work awaiting your look: a PR to review, a merged PR or a report to read), then the "Waiting on ..." items in `inbox.md` with their question text; every card leads with its project |
| **In progress** | `working` and `drafting` tasks, and `waiting` ones: a worker that ended its turn right after a `waiting` event, inside its window (the card shows what it waits on and until when) |
| **On hold** | `stopped-silent` and `waiting-overdue` tasks; tasks whose last event (other than their own `waiting` event) says they wait on a person ("waiting on/for", "awaiting review", "pending approval", "on hold"); done tasks whose open PR still needs someone's review |
| **Ready for you** | `done` tasks (ones you accepted) that are not closed yet |
| **Recently finished** | tasks closed in the last 48 hours (`CHARTROOM_DASHBOARD_RECENT_HOURS`), and done tasks whose PRs are all merged |

Each card shows the title, project (above the title on a Needs you card, so you can tell which
project a question is for at a glance), age, the last worker event, PR/MR links found in
`events.log` and `report.md`, and links that open the task's brief, report, plan and event log
as plain text. A task or inbox card with open [artifacts](../README.md#artifacts-drafts-that-outlive-the-chat)
(drafts for you to send or run) shows a chip for each: one click copies the text and opens it,
with a copy button beside it; a [page](../README.md#pages-reports-to-read-and-print)'s chip opens it in the
viewer instead. The header's **pages** link lists every page. Approvals given in chat but not yet in a brief are listed under
Needs you, and so are open [relays from other homes](homes.md#talking-between-homes) (for the XO to
weigh; they are not cards). Above the lanes, a "Your next steps" strip shows [your todo list](../README.md#your-next-steps-the-todo-list):
the first five items, each with its short id (a click copies `/continue <id>`). When subscription
usage readings exist (`chartroom usage`), a **Subscription usage** panel above the lanes shows
one row per agent (split per machine when machines differ): plan/account, percent used and left
per window with a fill bar, reset countdown, reading age (and stale badge), live worker count,
and clear out-of-usage or near-limit markers, readable on both phones and desktops.

How it is built, and what it promises:

- **Loopback by default, read-only always.** A Python standard-library server (`python3`,
  nothing to install) bound to `127.0.0.1` unless you put it on the network (below). It answers
  `GET` only, serves just the page, the lanes JSON (`/api/dashboard`), the five task files
  above, artifact texts and pages (the pages list and viewer at `/pages`, and its JSON at
  `/api/pages`), and has no endpoint that changes anything. On loopback it refuses requests whose
  `Host` is not `127.0.0.1` or `localhost` (DNS rebinding) and needs no auth, because nothing
  off the machine can reach it.
- **No external requests from the page.** CSS and JS are inline; no CDNs, fonts or analytics.
- **Pages are untrusted.** A page is HTML a worker wrote, so it is served only from its own
  route (`/task/<id>/artifacts/<slug>.html`, and only when its sidecar says it is a page), under
  its own policy: `sandbox` (no scripts, an opaque origin, even when opened alone), nothing
  fetched (`default-src 'none'`, inline styles and `data:` images only), and framed only by the
  dashboard itself (`frame-ancestors 'self'`). The viewer frames it with the `sandbox` attribute
  too, so its links open in a new tab and nothing in it can reach the dashboard. Its PDF
  (`.../<slug>.pdf`) is printed on request by `chartroom artifact pdf`, one at a time, and
  never for a request another site's page makes (a browser's `Sec-Fetch-Site` says so); nothing
  else ever runs a page.
- **Same answer as the CLI.** The lanes come from `chartroom dashboard --json`, built from the
  rows `chartroom status` uses, so the page and the terminal never disagree.
- **PR states are optional.** If `gh` is on your PATH, the server looks up the state of the PR
  links it found (cached, refreshed every 5 minutes): a task in `review` says whether its PR is
  merged or still to review; an accepted (`done`) one moves to Recently finished once merged, or
  to On hold while its PR awaits someone's review. That is the only network traffic, and it is GitHub's API with
  your own `gh` login. `--no-gh` turns it off; without `gh`, or offline, the page just shows the
  links.
- `--daemon` writes `.dashboard.pid` (pid and port) and `.dashboard.log` in the home. One
  dashboard per home; `--port 0` picks a free port. The page is read on each load, so after an
  update a reload shows the new page without restarting the server.
- `dashboard open` reuses this home's dashboard if it answers on its port; otherwise it
  replaces a stale pid file (or a server that stopped answering), starts one with `--daemon`
  and waits for it. Then it opens the URL with `CHARTROOM_OPENER`, else `open` (macOS) or
  `xdg-open`. It prints the URL either way. A lock in the home (holding its owner's pid; taken over only when that pid is gone) keeps two calls from starting two
  servers. The `dashboard` skill (`/dashboard`) runs exactly this.
- **Themes.** `chartroom` (a nautical chart table) and `hud` (machine vision: red and amber,
  scanlines, a header radar, a reticle that locks onto cards). Both keep the same lanes and
  cards, a light and a dark variant, and the reduced-motion behaviour. The server's default is
  `--theme NAME`, else `CHARTROOM_DASHBOARD_THEME` (env or config file), else `chartroom`. The
  theme menu in the header overrides it for that browser only ("default" goes back to the
  server's). The default is set when the server starts: restart a running dashboard to change it.
- A legacy home works the same: `CHARTROOM_HOME=~/.captain chartroom dashboard`.
- **Short ids.** Each card shows a short id: a task's 4-hex suffix (`21ba`, grown to the
  shortest unique suffix such as `n-21ba` when two open tasks share one), or an inbox item's
  `i-7f3a` tag. Clicking it copies `/continue <id>`; paste that into the XO session and the
  `continue` skill takes you straight to what the item needs from you.
  `chartroom resolve <id>` maps any short or full id back. `chartroom board` prints the same
  lanes in the terminal (short id, `[project]`, title, state, last event; color only on a
  terminal, `--json` for the lanes JSON), and `chartroom show <id>` one item in detail: its card
  plus the commander's intent, the last events, the outcome, the report's summary, PRs,
  artifacts and where the worker runs (`--json` adds those fields to the card's, the board's
  fields unchanged). Inbox items get their tag from
  `chartroom inbox add [--project P] <text>` (or `chartroom inbox tag` for lines written by
  hand); it never changes as other items come and go.
- **Every question carries its project.** `chartroom inbox add --project webapp "which region?"`
  writes `- [i-7f3a] 2026-01-02 — [webapp] which region?`; `--project` takes a name (`multi`
  for a question that spans projects) or a repo path (its directory name). The board, the
  dashboard, `resolve --json` and the lanes JSON (`project` on inbox items, `null` on a line
  without a label) all show it. `chartroom inbox project i-7f3a webapp` labels an item that has
  none. `status` puts the project right after the id, and every `watch` wake reads
  `[<id>] [<project>] <event>`, so the XO relays a decision already labelled; the skills have
  it lead every question it puts to you with `**[project]**` (and, in Claude Code, use the
  project as the question's header).

## The fleet radar: every agent on every machine

`/radar` on the same dashboard (the **radar →** link in the board's header) shows every open
task on every home of this machine, and of your other machines, as a small robot on a dark scope,
in six sectors by state. The robot itself shows the state: eyes lit and antenna blinking while it
works, an hourglass in hand while it waits, a red "!" sign when blocked, a "?" bubble at a
decision, dimmed and asleep ("zz") when silent, a broken outline when lost, docked with a check
when done or in review, tipped over when it failed. Click a robot, or tab to it and press Enter,
for a side panel with:

- its details and the reason for its state
- what it waits on and until when, with a live countdown
- its last event, written out as a note (see [Readable events](#readable-events-and-a-page-per-task))
- the recent events as a timeline, and the last lines of its terminal (`chartroom peek`, every 10s)
- links to the task's report (rendered), plan, brief and events, and to its full page

Each home's XO sits on a bridge above the sectors: a bigger robot with a captain's cap. It comes
from herdr and is marked "untracked: no events".

**Stacks.** Related tasks stand in one stack: the robot of the one that needs you most, the
others in a row behind it, and a count. Click it (or press Enter) to fan them out over the map;
`Esc` folds it. Two tasks are related when they share a ticket key (`ENG-2752`, from the title,
the id or the branch), when one's brief or events name the other's id (a handoff, a follow-up),
when one was cut from the other's branch, or when they share a project and a title but for a
trailing number ("QA dashboard T1", "T2"). A stack sits in its most urgent member's sector, and
the grouping depends only on the set of tasks, so it holds from one poll to the next.

**Active only.** The default view leaves out what is over: a docked task (review, done, failed)
quiet for `CHARTROOM_RADAR_DONE_HOURS` (24), and a task whose session is gone and that has been
quiet for `CHARTROOM_RADAR_STALE_DAYS` (3), decisions and blockers included. They fold into an
**archive (N)** chip beside each machine; one click (or `a`) shows them, and the browser remembers
the choice. The header counts both: "N active · M archived". A `--breaking` report is never
archived.

```bash
chartroom radar                      # the same, in the terminal (this machine)
chartroom radar --json               # one machine's records, as the page reads them
chartroom radar machines             # the machines it reads, and how often
```

| Sector | States | |
|---|---|---|
| **Decision** | `decision` | asked for your call |
| **Blocked** | `blocked`, `awaiting-input` | the worker said it cannot proceed, or the agent is stopped at a permission or question prompt |
| **Adrift** | `overdue`, `stopped-silent`, `lost` | waited past its window; stopped without reporting; its session is gone |
| **Under way** | `working` | working; a hollow "?" hull when its backend could not be checked |
| **Holding** | `waiting` | its own `waiting` report, inside its window (a ring counts down to the until-time); or, marked *inferred*, a last message that says it waits on someone |
| **Docked** | `review`, `done`, `failed` | a report to read (`review`: a worker's done, awaiting your accept or close); a wreck for a failure |

Telling *blocked* from *waiting* is the point. The view keeps itself honest in these ways:

- A robot moves only when its state changes it to another sector, flying to its new slot. The
  comms log records the change.
- A sonar ping means a real new event.
- Nothing drifts or bobs to look busy. A working robot's antenna blinks because it is working.
- A robot keeps its slot while it stays in its sector. A stack fans out over the map, not into
  it, so nothing else moves.
- With `prefers-reduced-motion`, robots are placed without flights, pings or blinks, and the log
  still records every change.

Arrow keys move between agents, `t` shows the same data as a table, `m` splits the map by
machine, `a` toggles active only, and `/` filters. It works at phone width, where the panel
becomes a bottom sheet.

**Machines.** Every robot and table row names its machine. Each machine has a chip in the header
showing when it was last read, or why it could not be.

- **This machine.** Its label is `CHARTROOM_MACHINE_NAME`, set in the environment, the home's
  config or the config file. Without it, the label is the host name. This machine's homes are
  read with the same `status --json` the CLI uses.
- **Other machines.** They come from `CHARTROOM_RADAR_MACHINES` (`label[=ssh-target] ...`, or
  `none`), else herdr's enabled saved machines (`herdr machine list`). Each is read over
  `ssh -o BatchMode=yes` with `chartroom status --json --all-homes`. Its XOs come from
  `herdr --machine <m> agent list`.
- **Read-only, always.** Nothing ever runs on another machine except that status call, its
  `chartroom peek <id>`, and `cat` of one of the five task files. Each is built only from ids and
  home paths that machine reported. (`chartroom nodes` adds one more, also read-only: its probe
  script, [below](#several-machines-nodes).)
- **An older chartroom** ignores `--all-homes` and answers for its default home only. The radar
  tells this from the shape of the answer, since the version string may not have changed, and
  says so on the machine's chip.
- **An unreachable machine** keeps its last robots, dimmed and marked stale, and the chip says
  "no contact" with ssh's own message. A machine never read shows no robots at all.

**Cost.** The server reads in the background, never on a page request, and only while a radar
page has asked in the last 90 seconds. An idle dashboard runs nothing and reaches no other
machine.

- **This machine** is re-read when its task files or herdr's agent states change. That happens
  at most every `CHARTROOM_RADAR_LOCAL_MIN_SECONDS` (15), and at least every
  `CHARTROOM_RADAR_LOCAL_MAX_SECONDS` (60).
- **Other machines** are re-read every `CHARTROOM_RADAR_REMOTE_SECONDS` (60), backing off up to
  5 minutes after failures.
- **Every call is bounded.** Each runs in its own process group, which is killed after 90
  seconds (25 for a peek), so no ssh outlives it. ssh reuses one connection per machine, while
  its control socket's path is short enough for a socket.
- **Same lock as the board.** On the network, the radar and its peeks sit behind the same access
  token.

## Several machines: nodes

A **node** is a machine that can take crew work: this one, and any other you reach over ssh.
Placing workers on them by itself is being built in stages ([docs/multi-machine.md](multi-machine.md));
today chartroom reads what each machine has room for and what it can run.

```bash
chartroom nodes                      # every node, this machine first
chartroom nodes --project ~/src/shop # ... and which of them have a checkout of that project
chartroom nodes --json
chartroom node init --cpu 100 --battery allow   # on a machine: make it a node, with its own limits
chartroom node probe [--json]        # this machine's facts, as `nodes` reads them
```

```
NODE         CONTACT    ROLE  CPU USED    MEM USED    SIZE          DISK      POWER              IDLE  CREW        LOGINS                    TOOLS                      CHECKOUTS  UTIL
desk (here)  ok         node  31% of 80%  64% of 75%  28 cores 96G  22% free  AC                 2m    4 +3 other  claude:ok codex:ok gh:ok  13 ok                      42         0.88
mini         online 4s  node  6% of 90%   22% of 75%  16 cores 48G  26% free  AC (battery 100%)  1h    0           claude:ok codex:ok gh:ok  11 ok error:node down:docker  131      0.34
mini: node is broken: /opt/homebrew/bin/node: dyld[812]: Library not loaded: /opt/homebrew/opt/simdjson/lib/libsimdjson.34.dylib
a node at either limit (the % after "of") takes no new task; chartroom node limits <name|here> 80/70 sets its CPU/memory limits. UTIL: how full it would be with one more worker
```

- **Which machines.** `CHARTROOM_NODES` (`label[=ssh-target] ...`, or `none`), else the radar's
  list: `CHARTROOM_RADAR_MACHINES`, else herdr's enabled saved machines. This machine is always first.
- **A node opts in.** `chartroom node init`, run on that machine, writes its limits to
  `~/.config/chartroom/node` (`CHARTROOM_NODE_CONFIG` moves it): the share of its CPU and memory that may
  be in use, whether it may work on battery, the priority its workers will get, and where
  its project checkouts are. It makes no home: a node has no XO. Without that file a machine is
  listed as "not a node" and will never be given work. `CHARTROOM_NODE_ACCEPT=off` in it
  withdraws the machine at once.
- **Read-only, always.** The only thing that runs on another machine is the probe itself,
  `lib/nodeprobe.sh`, sent over `ssh -o BatchMode=yes <target> 'bash -s'`: it needs nothing installed
  there (not even chartroom), writes nothing, and runs on a Mac's own bash 3.2. Each machine is
  probed side by side, and one that does not answer within `CHARTROOM_NODES_TIMEOUT` seconds (45) reads
  `timeout` (its ssh is ended; the probe there stops by its own bounds, at most about 90 seconds). ssh's own failures read `unreachable`, or `auth` when ssh would need you (a key, a
  host key, a Tailscale check).
- **Tools and logins are checked where a worker would run.** A tool counts when it works, not
  when its binary is there (`docker` needs its daemon to answer), and a broken one is named with
  its binary and the first line it printed. Tools are looked up on the PATH of your interactive
  login shell (`$SHELL -lic`: version managers such as mise set theirs up only there), the one a
  worker launched there gets, not the thin PATH of an ssh session; `path_source` says which was
  used (`CHARTROOM_LOGIN_SHELL` names another shell, or `none`). On a Mac, an ssh session cannot
  read the login keychain, so claude, codex and gh would all read logged out: the probe runs those
  checks inside the machine's hc core (`hc exec`), which runs in the login session, and only when
  that core already answers (it never starts one). With no core, logins read `unknown` over ssh.
- **CPU USED and MEM USED** are measured, against the node's two limits (`64% of 80%`): the busy share of
  all cores over the last minute, and Activity Monitor's Memory Used. A node at or over either
  takes no new task. `chartroom node limits` shows them, and `chartroom node limits <name|here> 80/70`
  sets a node's ([how they are measured](multi-machine.md#5-placement)).
- **CREW** is chartroom's own workers there (hc terminals carrying a task), for information. An XO or
  your own agent session is shown apart (`+3 other`).
- **UTIL** is how full the node would be with one more worker, against its own limits: the larger of
  (CPU used + `CHARTROOM_WORKER_CPU` cores) / CPU limit and (memory used + `CHARTROOM_WORKER_MEM_GB`) /
  memory limit. `dispatch` sends each new task where it is lowest.
- **On macOS, limits are admission control,** not hard caps: there are no cgroups. A worker's own
  builds can still push a node past its share; placement then sends new work elsewhere.

### Devices: machines that report to the brain

A machine can instead **report** to the brain: it runs chartroom's device agent, which sends its
probe to the brain's app server every 15 seconds. The brain never reaches out to it, holds no key
to it, and asks it to open no port. Its row in `nodes` and Fleet is its last heartbeat. `dispatch` sends
new tasks to the machine with the most room, devices included, and you can pin one
([docs/multi-machine.md §12](multi-machine.md#12-devices-the-brain-never-reaches-out)).

```bash
chartroom node add --name mini                      # on the brain: a one-time code (10 minutes)
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash -s -- --device
chartroom device join https://<brain>.ts.net <code> # on the device: enrol and start its agent
chartroom device status                             # on the device: joined to what, its last heartbeat
chartroom node rename mini mini-2                   # on the brain: names are display only
chartroom node rotate mini | node revoke mini       # a new token; or none (its agent stops)
chartroom node ping mini                            # a round trip over the connection
chartroom node update --all                         # each device moves to this brain's commit, over the connection
```

- **Its own revocable token.** Only the token's sha256 is kept on the brain. On macOS the agent is a
  LaunchAgent in the login session, and the token is in the login keychain; elsewhere a 0600
  file. A token opens that device's routes only, never the app.
- **Pinned work.** `chartroom new ... --node mini` (or `chartroom set <id> node=mini`, before dispatch)
  pins a task to a device. `dispatch` sends it there: the device runs it in a guest home of its
  own chartroom, on its own hc, claude/codex, git and gh logins. Its event lines, report and plan
  come back to the brain as the worker writes them, so the watch, the board and the app see it as
  any task, with its machine. Steer, stop and peek go to it as commands, and a permission card
  its worker raises is answered here and reaches it there. `close` brings the branch to the brain
  first (a git bundle, fast-forward only into the task's own branch); only once the brain holds
  that very commit does the device close its copy. Only hc:claude, hc:codex and hc:agy run on a device,
  and a pinned task never moves by itself; one whose device is away waits for it.
- **Commands** reach a device by long-poll: its agent holds one request open to the brain's app
  server and runs what comes, one at a time; the brain still opens nothing to it. `node update`
  fast-forwards the device's chartroom to the brain's commit (only along its own `origin/main`)
  and its agent restarts onto it.
- **Status:** `online`, `stale` (no heartbeat for 45 s), `lost` (10 minutes, counted only while
  the brain's app server is up), `new`, `revoked`. `chartroom doctor` lists the devices on the
  brain, and the join and the agent on a device.

## Client homes: one brain

A home can live on another machine, the **brain** (an always-on desktop), while you keep talking
to an XO on your laptop. Its every chartroom command then runs on the brain over ssh, its workers
run there, and a copy of its records sits in the laptop's home at the same paths, so briefs,
plans and reports open as before. At the brain itself the same home is just a home.

```bash
cd ~/chartroom/acme && chartroom brain link desk   # this (empty) home now lives on "desk"
chartroom brain status                               # contact, the copy, pending edits, the tunnel
chartroom brain fetch tasks/<id>/pane.log            # one file the copy leaves out
chartroom brain git <id> log --oneline main..HEAD    # read-only git in a task's worktree there
chartroom brain unlink                               # local again
```

- **The marker** is `CHARTROOM_BRAIN=<ssh target>` in that home's own `config`. The brain finds
  the home by its registered name (`CHARTROOM_BRAIN_HOME`), never by a path the client sends.
  `brain link` refuses a home that already has tasks: moving them is a migration of its own.
- **Edits to the copy** (a brief, `inbox.md`, `commander.md`) go to the brain before the next
  command. The brain applies one only if its own file is unchanged since it was copied;
  otherwise the edit is kept as `<file>.client-conflict-<time>` and the command does not run.
  The records chartroom owns (`meta.json`, `events.log`, rulings, relays, artifacts) are never
  taken from a client.
- **`watch --once`** is delivered at least once: the brain moves its cursor only after the
  laptop has the wakes. While the brain is away it waits quietly, then wakes once
  (`[brain] desk unreachable since …`) and once more when the brain is back. Every other command
  exits 75 and says nothing was run.
- **`attach`** resumes the worker on the brain and shows it here, through this machine's hc link
  to the brain (`hc machine ls`). **`dashboard open`** opens the brain's dashboard through an
  ssh tunnel, so nothing new listens on the network. **`artifact copy`** uses this machine's
  clipboard.
- **What runs on the brain is fixed:** one constant ssh command line (`chartroom brain gate`),
  the arguments as JSON on stdin, and only registered homes and client-safe commands. Workers
  never start from the ssh session (no headless or command runner from a client), because a
  Mac's keychain is locked there.

The protocol, the copy's filter, the failure table and an optional forced-command key are in
[docs/client-homes.md](client-homes.md).

## Readable events and a page per task

A worker's event is one line in `events.log`, often a long one. The radar's panel and the task
page set it as a note rather than a wall of text, in a proportional face at a reading width, with
monospace kept for ids, SHAs, paths and commands:

- the kind as a badge, and `[breaking]` as a red tag;
- a **headline**: the first sentence or clause, up to the first ":" or ".";
- labelled parts (`Cause:`, `Options:`, `Need:`, `Recommend:`, `Report:` and the like) as small
  headed blocks;
- numbered options (`(1) ... (2)`, `(A) ... (B)`, `1) ... 2)`) as a list, the recommended one
  highlighted;
- several `; `-separated facts as bullets;
- a task file's path as a link to that task's page (a report path opens its report), and a URL in
  a new tab.

The parser (`lib/dashboard/eventfmt.js`) only adds structure: whatever it cannot place stays the
worker's words as paragraphs, and every word comes back in order (its tests hold it to that,
garbage included). Nothing it renders is HTML: markup in an event is shown as text.

A task's events read as a timeline, newest first, with relative times (the exact time on hover)
and a filter by kind. A decision or blocker, the XO's steers answering it ("XO → worker", set
apart from the worker's own reports) and the worker's follow-up form one thread, collapsed to its
latest line until clicked; a run of progress reports collapses to the newest; agent noise
(prompts received, turns ended, records) folds into an "N system events" toggle.

`/task/<home>/<id>` (`?m=<machine>` for another machine's) is the task on a page of its own,
linked from the radar's panel and from each card on the board. It has the title, project, home,
machine, state, what it waits on and last activity on top, then the latest decision or blocker,
the commander's intent from the brief, every event, `report.md` rendered as Markdown (tables
included, raw HTML shown as text, links only to http(s)), its artifacts and pages, its live pane
(read-only), and a `/continue <id>` copy button. It prints with every thread opened, and fits a
phone. Another machine's task is read the radar's way, over the same read-only calls; a task the
radar does not draw (closed, drafting) shows from its own home's dashboard.

**Better events in the first place.** The brief asks workers for a headline first (at most ~140
characters: what happened and what is needed), then the labelled parts, and the long part in
report.md. `chartroom event <id> <kind> --detail "<the rest>" "<headline>"` writes the rest as
the headline's `Details:` part on the same line, so the log format does not change.

## On the network: other devices

To open the board from a phone, a tablet or another computer, bind it beyond loopback:

```bash
chartroom dashboard --daemon --expose          # every interface (0.0.0.0)
chartroom dashboard --daemon --host 100.64.0.7 # one address of this machine only
chartroom dashboard status                     # print the URLs again
chartroom dashboard stop                       # off the network again
```

`CHARTROOM_DASHBOARD_HOST` (env or config file) sets the default bind address; `--host` and
`--expose` override it, and `--host 127.0.0.1` goes back to loopback. Only IPv4 addresses are
accepted. Starting it prints a warning naming the bound address, then one URL per address
other devices can use (one per non-loopback interface, VPN and overlay interfaces included),
each with the access token:

```
dashboard running: http://127.0.0.1:4517/?token=… (pid 4242; log ~/.chartroom/.dashboard.log; …)
WARNING: listening on 0.0.0.0:4517 (every interface), beyond this machine; the access token is the only lock
on the network: http://192.168.1.20:4517/?token=…
on the network: http://100.64.0.7:4517/?token=…
```

- **Access token, on by default.** Bound beyond loopback, every request except `/healthz` needs
  the token in `$CHARTROOM_HOME/.dashboard.token` (random, made on first use, mode `0600`). Open
  a printed URL once: the server checks `?token=` (in constant time), sets it as an `HttpOnly`,
  `SameSite=Lax` cookie for 30 days, and redirects to the same page without the token, so it
  leaves the address bar. Anything else gets `401`. The token survives restarts, so devices stay
  signed in; to revoke every device, delete the file and restart the dashboard (it makes a new
  one). With the token on, any name for the machine works in the URL (a DNS name, a LAN name),
  since a rebinding page never has the cookie.
- **`--no-token`** turns the token off, for networks where everyone who can reach the port may
  read the board. It says so in the warning, and the `Host` guard stays on: the URL must use one
  of the machine's addresses or its host name.
- **What it shows.** The board shows the commander's inbox and every task's title, last event,
  brief, report, plan and event log, and local file paths. It never serves environment
  variables, config, tokens or any file outside those. Anyone with the token (or anyone on the
  network, with `--no-token`) can read all of that, so treat the token like a password and
  expose the board only on networks you trust.
- **Plain HTTP.** The server does not do TLS, so on a shared LAN the token and the page cross
  the network in the clear. A VPN or overlay network encrypts that hop: for example, with
  [Tailscale](https://tailscale.com) on both devices, `--host <this machine's tailnet IP>`
  makes the board reachable only over the tailnet, whose access rules then decide who can
  reach it at all. Or put a TLS reverse proxy in front of a loopback dashboard (below).
- `chartroom doctor` shows the configured bind address, whether a token exists, and where a
  running dashboard listens. `.dashboard.log` (which holds the URLs) is `0600` too.

## Optional: a local hostname

To open the dashboard at `http://chartroom/` (or `https://chartroom/`) instead of a port, put
a reverse proxy in front of it on a loopback address of its own, so nothing else on
`127.0.0.1` changes. The server itself stays as it is. On macOS, with [Caddy](https://caddyserver.com):

1. Map the name to a second loopback address: add `127.0.0.2 chartroom` to `/etc/hosts`, and
   alias it with `sudo ifconfig lo0 alias 127.0.0.2 up` (a LaunchDaemon that runs this command
   at load keeps it across reboots; Linux routes all of `127.0.0.0/8` already).
2. Point Caddy at the dashboard, bound only to that address. On loopback the dashboard answers only
   `Host: 127.0.0.1:<port>` or `localhost:<port>` (its DNS-rebinding guard, above), so the
   proxy must present the upstream's own address:

   ```caddyfile
   {
   	default_bind 127.0.0.2
   	admin "unix//var/run/chartroom-caddy.sock|0600"
   	skip_install_trust
   }

   http://chartroom, https://chartroom {
   	tls internal
   	reverse_proxy 127.0.0.1:4517 {
   		header_up Host {upstream_hostport}
   	}
   }
   ```

   Naming both schemes serves plain HTTP too instead of redirecting. `admin` keeps Caddy's
   admin API off `localhost:2019`, on a socket only root can use.
3. Run Caddy as root (a LaunchDaemon with `KeepAlive`): macOS lets other users bind ports
   below 1024 only on all interfaces, not on one address. Give it a root-owned copy of the
   binary and the Caddyfile, not files your account can rewrite.
4. `sudo caddy trust --config <Caddyfile> --adapter caddyfile` adds Caddy's local CA to the
   System keychain, which Safari, Chrome and curl use (Firefox keeps its own store). Then flush
   the DNS cache: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.

Type the trailing slash (`chartroom/`) or the scheme, or the browser may search for the word.
Undo by reversing each step: remove the hosts line, the LaunchDaemons and the alias
(`sudo ifconfig lo0 -alias 127.0.0.2`), and `caddy untrust`.
