# Changelog

All notable changes to chartroom. Versions follow SemVer. Before 1.0, minor versions may
change CLI flags. The event-log line format, the brief protocol, and `meta.json` `schema` 1
are stable from 0.1.0.

## [Unreleased]

### Added
- `chartroom-panel`, a Claude Code mod (`mods/chartroom-panel`): the commander's live Chartroom
  fleet in a read-only pane beside the chat, the sibling of the Pi panel. It reads
  `chartroom status --json` only and shows the unfinished tasks — a row drops off when its `state`
  is `done`/`closed` or its `closed` field is non-null, and is kept otherwise, including a
  `state: decision` row whose worker is `live: done` (the filter never looks at `live`); an
  unknown unfinished state stays visible. Input-needed states (`decision`, `blocked`,
  `awaiting-input`, `waiting-overdue`) draw yellow, being-worked-on (`working`/`running`,
  `drafting`) green, quiet states (`stopped-silent`, `waiting`, `failed`, `lost`) dim. It
  auto-shows when the session is interactive and the cwd is the home (resolved through
  `chartroom doctor --json`), and never in a crew worker's session (`CHARTROOM_TASK` set or a
  `worktrees` path), nor in a `-p` run. It refreshes every 5 s on a timer with no model call,
  keeps the last tasks visibly STALE on any failure (never an empty fleet on error), and never
  runs `chartroom watch`. `/chartroom-panel [on|off|toggle|refresh|next|prev|pick <id>]` controls
  it (it never shadows `/chartroom`); the pane takes the keyboard on demand, the arrows walk the
  tasks and Enter brings one into the chat by pre-filling `/continue <short_id>` (never
  submitting), Esc hands the keys back. The pane opens with a transparent background, so it blends
  with the chat transcript instead of sitting in the engine's default grey docked-pane surface (a
  theme-safe choice: transparent shows the terminal's own background in a dark or light theme
  alike). While the pane is focused, single-letter keys act on the highlighted task (inert while
  typing in chat): `c` closes it with a two-press confirm (`chartroom close <id>`, keeping the
  branch, never `--discard`; the CLI's exact refusal is surfaced and success never faked; on
  success the task drops on re-poll), and `s` pre-fills a non-mutating recap request into the chat
  prompt. Close is the only mutation; everything else is read-only. The footer lists the keys in
  both states (`Ctrl+X Tab to select` when unfocused; the full `c close · s recap · ↑↓ · Enter ·
  Esc` legend when focused). Auto-show is on by default, and a durable per-home setting can turn it
  off across sessions: `/chartroom-panel default on|off` writes `autoshow=on|off` to a harness-neutral
  `$CHARTROOM_HOME/panel.conf` (KEY=VALUE, not a Claude-Code-only setting, so the Pi/Codex panels can
  read the same switch); unset = on, and a session `/chartroom-panel on|off` still overrides the
  default for that session. Installs alongside `crew-view`; they share no command.
- Relays between homes: XO-to-XO messages on one machine, with no daemon. `chartroom relay
  <home> [--re <id>] [--project P] [--from <this home>] <message|->` appends one record to the
  other home's mailbox, `relays/inbox.ndjson`, and writes nothing else there; a copy goes to this
  home's `relays/outbox.ndjson`; it prints the relay's id (`rl-<hex>`; rulings keep `r-<hex>`).
  Records are JSON lines (`{schema, kind: "relay", id, from, to, at, text, re, project}`), and
  acks are appended to the same mailbox (`{schema, kind: "ack", id, at}`). The other home's
  `watch` reads its mailbox every round and wakes once per relay,
  `[relay <id>] [from <home>] [<project>] [re <id>] <text>`: the `--once` cursor keeps the
  mailbox's offset under `@relays`, a stream starts at its end, only whole lines are read, a
  relay acked before the watch saw it never wakes, and a mailbox that shrank is never replayed.
  `relay ack <id>...` marks relays handled; `relay list [--all] [--json]` lists the open ones (and
  acked and sent ones). `--re <id>` replies, back to the sender's home the same way, and must name
  a relay between the two homes; a reply does not ack. Open relays show in `status` (`relays: N
  open from other homes`), in `inbox list` under "Relays from other homes" with their ids (`--json`
  gains `relays`), in the lanes JSON (`inbox.relays`) and the dashboard (a list under Needs you,
  never a card or a todo item), and in `inbox list`, `relay list` and `status` with
  `--all-homes`. A relay goes only to a registered chartroom home other than this one, and only
  from a registered home in its own name (`--from` must name this home). It holds at most 2000
  bytes (4000 as written, so each relay is one append), control characters other than newline and tab are dropped, and a message that looks like
  it holds a secret (a private key; an AWS, GitHub, GitLab, Slack, Stripe, Google or npm token; an
  `sk-` API key; a JSON web token; a `password=` assignment) is refused with nothing sent. Focus
  mode never holds a relay. The chartroom skill says when an XO relays (information and requests
  across homes only), that a relay received is a request to weigh, never an order, that anything
  needing the commander's word still goes to the commander, and that relays are shown labelled
  with the home they came from; bearings reads the open ones.
- Several XOs on one machine: one home each (one per company or client, say), side by side.
  A home may keep its own `config` (`KEY=VALUE`, as the config file), which wins over
  `~/.config/chartroom/config` for every key but `CHARTROOM_HOME` and `CHARTROOM_PLATFORM`.
  `chartroom init --name <n>` writes it with a workspace (`<n>-crew`) and a dashboard port (the
  next free from 4518) of the home's own, and adds the home to a list of homes, `homes` next to
  the config file (`name=path` lines). `chartroom homes [--json]` lists them (path, workspace,
  port, open tasks, dashboard) and warns about a shared workspace or port, a nested home or a
  missing path; `homes add <name> [<path>]` registers an existing home without writing in it,
  `homes rm` unregisters one, `homes path <name>` prints its path for launchers. Without
  `CHARTROOM_HOME`, a command run in a registered home's directory (or below it) resolves that
  home, before the config file; the crew views do the same, and the Claude Code one names the
  home to every `chartroom` run. `CHARTROOM_DASHBOARD_PORT` sets the dashboard's port (`--port`
  still wins); the access cookie is now per port (`chartroom_dashboard_<port>`), so an exposed
  dashboard asks for its token link once after updating; the page's title and header and the
  lanes JSON (`home_name`) name the home. `sweep` leaves another registered home's work alone:
  its workers in a shared project's `.worktrees/`, its orphaned loops and its listeners are
  neither freed nor listed. `status`, `board`, `todo` and the new `inbox list [--json]` take
  `--all-homes`: the command, read-only, in every registered home with that home's own
  settings, one `== <home> · <path>` section each (`--json`: an array of `{home, path,
  current, result}`). `doctor` shows the home's name, its own config, the workspace and the
  dashboard port. The chartroom skill checks at session start that `doctor` names the
  directory it started in, keeps work in its own home and only reads the others; bearings reads
  every home when asked to or when the home oversees the others; join finds a home by its
  registered name.
- Focus mode: one project, or a few, at a time, with a held count so it is never left on by
  accident. `chartroom focus <project>[,<project>...] [--for 30m|4h|1d]` writes `focus.json` in
  the home and says what it covers; `chartroom focus [--json]` shows it; `chartroom focus off`
  ends it and lists what was held. A project is in focus when it equals a name or starts with
  `<name>-` (case-insensitive); `--scope <word>[,...]` narrows that to the items mentioning a
  word (a task's title or id, an inbox item's text), for one incident inside a project. The file
  is a small stable contract other tools can follow: `{"schema": 1, "projects", "scope",
  "since", "until"}`, absent (or past `until`) when off. While a focus is on, an item of another project is held when it
  would ask something of the commander: a task in `decision`, `blocked`, `failed`,
  `awaiting-input` or `done`, or a "Waiting on the commander" inbox item. `status` and `board`
  lead with `🎯 focus: <projects> · N held (since 2h)`, `board` marks held items and each lane's
  held count, and `watch` marks a wake from a project out of focus `[<id>] [<project>] [held]
  <event>` (still a wake: the XO does the routine work silently). `inbox add` says on stderr when
  focus holds the new item. `--for` ends the focus by itself: past its end every reader treats
  it as off, with no process to run, and `focus` says when it ran out. `status --json` rows and
  the lanes JSON's cards gain `breaking`, `in_focus` and `held` (in focus and not held while
  focus is off), and the lanes JSON a top-level `focus` (`{projects, scope, since, until, held}`, null
  while off); nothing else in either changes. The dashboard shows a focus strip with the held
  count, counts only what is in focus in its gauges, alert and tab title (which adds `🎯 N
  held`), dims other projects' cards and keeps them out of the ship's log; the strip's button
  hides them instead, remembered in that browser. The chartroom skill has the XO surface only
  focused projects, end each reply with the held line, and break focus only for a production
  outage, an active security exposure or data loss, labelled as breaking focus; `bearings`
  leads with the focus line, covers only what is in focus, and after `focus off` walks the held
  items first.
- Breaking reports: `chartroom event <id> decision|blocked|failed --breaking <text>` and
  `chartroom inbox add --breaking` start the text with `[breaking] ` (the event line format is
  unchanged). Focus mode never holds such an item, its wake is never marked held, and it leads
  Needs you. Every brief's protocol now tells the worker to use it only for a production outage,
  an active security exposure or data loss.
- crew-view 0.4.0: while focus mode is on, the band leads with `🎯 <projects> · N held` (never
  cut for width) and counts only what is in focus; the `/crew` pane adds the focus line under
  the legend and dims the rows out of focus. The pi crew view shares the code, so it shows the
  same.
- `chartroom todo`: your next steps, one list of what you owe the crew, made from the records
  chartroom already keeps: open "Waiting on the commander" inbox items, open `message` and
  `runbook` artifacts, and tasks in `decision`, `blocked` or `ready`. Breaking first (a
  `[breaking]` or `[urgent]` mark, a breaking card, or the word urgent or asap), then by the
  earliest date in the text, then oldest. `todo done <ref>` removes the inbox line (restoring
  `- (none)` when the section empties) or marks the artifact done; a task is never ticked, it
  clears when the XO relays the answer. `todo add [--project P] <text>` keeps your own item as an
  inbox item. `--all` shows what focus mode holds, `--json` the list. `lib/todo.jq` computes it
  from the board, and `board --json` (so the dashboard's JSON) carries it as `todo`; nothing else
  in the board changes. It reads focus mode's marks (each card's `held`, `in_focus`, `breaking`,
  the board's `focus`) and never decides a hold: urgency only orders the list.
- crew-view 0.4.0: your todo list under the band, built-in todo style (the first three items not
  held, `+N more`, the focus and its held count), and a `/todo` pane of all of it where the row
  with the ring takes `c` (copy), `d` (done, pressed twice), `o` (`/continue <id>`) and `a` (the
  held items). `/todo off` hides the list, `/todo add` and `/todo done` run the CLI's. `/crew todo`
  is the same command, and the way in where the person's own `/todo` command or skill holds the
  name. One chartroom pane at a time: opening the todo pane closes the crew pane and the other way
  around, so `/crew todo` with the crew pane open switches to the list (0.3.0 read `todo` there as
  an item id). A stat of `focus.json` and `inbox.md` every 3 s reads the board at once
  when either changes, so focus mode turning on or off shows without a restart. Registering a
  command no longer stops the mod's start when Claude Code refuses it.
- The pi crew view gains the same list under its band and a `/todo` browser (`o` puts
  `/skill:continue <id>` in the editor); `/todo off` is kept across `/reload`.
- The dashboard shows a "Your next steps" strip above the lanes: the first five items not held,
  each with its short id (a click copies `/continue <id>`) and due date, and the focus with its
  held count.
- Artifacts: drafts that outlive the chat. `chartroom artifact add <id> --kind message|runbook|note
  --title T <file|->` keeps text the XO drafted for the commander (a message to send, commands to
  run, a note) with a task (`tasks/<id>/artifacts/<slug>.md`, plus a `.json` with title, kind,
  project, created, updated, done) or an open inbox item (`inbox/<i-xxxx>/artifacts/`, which
  outlives the item's line; anything else a worker keeps in `artifacts/` is never listed or
  overwritten). Refs are `<id>/<slug>` with the dashboard's short id or inbox tag
  (the id alone when it has one open artifact); adding the same slug again overwrites. `artifact
  list [<id>] [--all] [--json]`, `show <ref> [--path]`, `copy <ref>` (`CHARTROOM_CLIPBOARD`, else
  `pbcopy`, `wl-copy`, `xclip`, `xsel`, else it prints) and `done <ref>`. Dashboard cards (task and
  inbox) show a chip per open artifact that copies the text and opens it in one click, and the
  server serves `/task/<id>/artifacts/<slug>.md` and `/inbox/<i-xxxx>/artifacts/<slug>.md`
  (read-only, the `.md` only). The lanes JSON gains `artifacts` on every card (`[]` when none) and
  a top-level `artifacts` count by kind; nothing else in it changes. `board` prints an item's
  artifact refs on its line, and `board` and `status` end with a count. The chartroom skill has
  the XO save whatever it drafts for the commander to send or run as an artifact and give the
  ref, never the text in chat alone; `bearings` lists open messages and runbooks under Needs
  you, and `continue` names an item's artifacts.
- `chartroom show <id> [--json]`: one item in detail, by any id `resolve` takes (a short id, an
  inbox tag, a full id). The board's card for it, plus what only the task's files say: the
  first lines of the commander's intent, the last five worker events, the outcome (the newest
  `done` or `failed`), the report's path and summary (its "Outcome" section, else its first
  lines), PRs, the open artifacts (as the board lists them, with their refs), the
  worktree and branch, and where the worker runs with the command that takes you there
  (`chartroom attach <id>`), all from disk. `--json` only adds fields to the card's. A task
  closed past the recent window still shows, from its record. It builds a one-task board, and
  `status_rows --id` now reads only that task's record, so a lookup is under a second on a home
  of 160 tasks (and `board` forks once less per task).
- crew-view 0.2.0: the `/crew` pane browses the items, the dashboard's equivalent inside Claude
  Code. Each row is a Button (Tab or the arrows walk them, Enter opens one) and opens into the
  item's detail from `chartroom show --json`, with one-letter actions: `c` puts
  `/continue <id>` in the prompt (Enter runs it; a draft is kept and the line copied instead),
  `y` copies the id, `p` a PR URL, `a` an artifact's text, `r` reads the report in the pane,
  `b` goes back. `/crew <id>` opens an item directly. The band, the XO-only scope and the
  inert-until-the-skill-loads behaviour are unchanged.
- `mods/crew-view-pi`, the same band and browser for pi (0.87 or newer), gated the same way
  (`/skill:captain` or `/skill:chartroom`, or the model reading either skill, in the XO's
  session in the chartroom home); `c` puts `/skill:continue <id>` in the editor. It shares the
  Claude Code mod's lane, band and detail code. Install with
  `pi install <checkout>/mods/crew-view-pi`.
- crew-view 0.3.0: the `/crew` pane closes. Every view's first row reads `q: close`; `q` or Esc
  closes it from any view (Esc also from an idle, empty prompt, where it used to only hand the
  keys back), bare `/crew` toggles it, and a closed pane opens next on the lanes with the ring on
  the row last opened. `/crew off` hides the band (and closes the pane) for the session, and
  `/crew on` brings it back; the 15 s board read rests while neither shows. The pi crew view
  gains the same header, `q` closing from every view, and `/crew off`/`/crew on`, kept across
  `/reload`.
- `chartroom sweep`, and a `sweep` skill (linked by `install-skills`): an audit of what the crew
  left running, and with `--apply` freeing the safe part of it. It finds sessions of finished
  tasks, done tasks safe to close (worktree clean, every commit in the base ref), orphaned
  `watch`/`listen` loops and second dashboards, and dev servers, watchers and daemons running from
  a closed task's worktree or a chartroom worktree path that no longer exists (by working
  directory and argv, whatever the program), with age, CPU time, %CPU, RSS and machine load.
  A dry run by default. `--apply` closes through `chartroom close`, stops closed tasks' sessions
  (a herdr tab or pane only when herdr places it in the task's own tab or worktree), kills the
  rest (TERM, then KILL after 5s, only if the pid still runs what was planned), and logs each act
  to `sweep.log` and the task's events. It never touches in-flight work, never `--discard`s,
  never closes uncommitted, unpushed or unmerged work, and never treats a joined session's
  directory as a worktree; anything else is listed under "needs a human" with the reason, once
  the task has been idle `--idle-hours` (default 24). The default output is one summary line
  plus one short line per item that needs a human (at most 10), so an agent spends few tokens
  on it; `--verbose` lists the safe set item by item, `--json` has everything. All detection
  and rules are code (`lib/sweep.sh`, `lib/sweep.jq`). The chartroom skill runs it at session
  start and when the fleet goes quiet; bearings folds its needs-a-human items into "Needs you".
  macOS and Linux (POSIX `ps` columns; `/proc` or `lsof` for working directories); not on Git
  Bash. New config: `CHARTROOM_SWEEP_IDLE_HOURS` (24), `CHARTROOM_SWEEP_SETTLE_MINUTES` (60).
- `mods/crew-view`, a Claude Code mod: the crew live in the XO's session, as a one-line band
  above the prompt with one emoji per lane and each needs-you item's project
  (`⚓ 🏃 3 · 🙋 2 [shop] 108a, [billing] 9c1e · 💤 1 · ✅ 1 · ❌ 1`, emoji counted as two
  columns so it never overflows) and a `/crew` pane with the legend and the board's lanes,
  polling `chartroom board --json` every 15 s. It wakes only once the session loads the
  `captain` or `chartroom` skill, and only in the XO's session; it stays inert in every other
  (workers, `claude -p`, worktrees), detected from env and files without running a process.
  Listed in the marketplace: `/plugin install crew-view@chartroom`.
- Every question carries its project. `chartroom inbox add --project P <text>` writes
  `- [i-xxxx] <date> — [P] <text>` (a repo path is reduced to its directory name; any other
  name, such as `multi`, is kept), and `chartroom inbox project <i-xxxx> <P>` labels an
  existing item. Inbox items in `dashboard --json` / `board --json` and `resolve --json` gain a
  `project` field (`null` on an unlabelled line, so older inboxes read as before; nothing else in
  the JSON changes). `board` prints `[project]` after the short id on every line, the dashboard
  shows the project above the title on Needs you cards (and next to chat approvals), `status`
  puts the PROJECT column right after ID, and every `watch` wake reads
  `[<id>] [<project>] <event>`. The chartroom, bearings and continue skills make it a hard rule:
  every question, decision or approval the XO puts to the commander leads with
  `**[project]**` (or `**[project · short id]**`, `**[multi]**`, `**[chartroom]**`), and a
  structured question tool's header (AskUserQuestion's chip) is the project name, never a
  generic word.
- The dashboard on the network: `chartroom dashboard --host ADDR` binds another IPv4 address
  and `--expose` every interface (`CHARTROOM_DASHBOARD_HOST` sets the default; it stays
  `127.0.0.1`). Beyond loopback every request but `/healthz` needs an access token
  (`.dashboard.token` in the home, random, `0600`): `?token=` once, then an `HttpOnly` cookie,
  compared in constant time. Starting it prints a warning naming the bound address and one URL
  per interface address, with the token; `--no-token` serves without one (the `Host` guard
  stays). `doctor` shows the bind address, whether a token exists and where a running dashboard
  listens. Read-only as before.
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
- Windows. WSL2 works as Linux does. Git Bash (Git for Windows) runs the core, the
  `headless`, `command` and `subagent` backends and the dashboard:
  - `install.sh` writes a launcher script where `ln -s` copies.
  - `install-skills` links with directory junctions.
  - A native `jq.exe` gets its arguments unconverted (MSYS would rewrite a path-looking
    `--arg` value into `C:/...`), with file operands passed as Windows paths, and its CRLF
    output is turned off with `--binary`.
  - `headless:claude` reads a pipe and steers between runs.
  - `stop` ends the worker's Windows process tree.
  - The dashboard runs under a native python (`python3`, `python` or `py -3`, never the
    Microsoft Store stub). It gets Windows paths and bash, and is tracked by its Windows pid.
    `--host` and `--expose` work there too: it asks Windows for its addresses (no `ifconfig`),
    and its log is LF.
  - `dashboard open` uses `start`, or on WSL `wslview` or PowerShell.

  herdr is off on Git Bash unless `CHARTROOM_HERDR_ANY_OS=1`, and `chartroom join` is off there
  (a native agent is outside Git Bash's process tree; WSL2 joins). `doctor` prints the platform and
  notes on Windows only (`--json` adds `platform` and `notes` there); macOS and Linux output is
  unchanged. `CHARTROOM_PLATFORM` overrides the detection. README: a Windows section. CI: a
  windows-latest job (Git Bash: bats, install, and a native-process smoke test).
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
- herdr dispatch no longer dies on Claude's "trust this folder" dialog. `herdr agent start`
  answers `agent_not_ready` while it is up; chartroom now answers it (only for a worktree it
  created, as before) and delivers the brief. A folder it did not create stops dispatch with a
  message naming the tab. Dispatching again after a start that died closes the stale agent
  that held the task's name (`agent_name_taken`), but only in the tab chartroom recorded for
  the task and never while it is working.
- The dashboard on phones and tablets: the header no longer overlaps itself at tablet widths
  (768px), lane-count labels wrap instead of being cut, no text is under 12px below 1100px,
  every control is a 44px tap target on touch screens, and a card's last event shows up to
  three lines on a phone instead of one cut line.
- A running dashboard shows an updated page. The server read `index.html` once, at start, so
  after `install.sh` updated chartroom it kept serving the old page until restarted; a dashboard
  started before the "every question carries its project" change still showed Needs you inbox
  cards with no project. It now reads the page on each load (keeping the last good one if the
  file is missing or half-written mid-update). A dashboard already running needs one restart to
  pick this up.
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
- Short ids no longer fail under `nullglob` in a home with no tasks (a latent bug the artifact
  commands hit first).

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

### Fixed
- Checkouts are LF whatever `core.autocrlf` says (`.gitattributes`). Git for Windows' default
  CRLF checkout stopped `bin/chartroom` at its first line.
- A config file with CRLF line endings, saved by a Windows editor, no longer leaves a CR on
  every value.
- The dashboard's compiled python cache is no longer tracked.

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
