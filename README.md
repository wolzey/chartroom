# chartroom

**Run a crew of coding agents from one agent session.**

You talk to one agent, the **XO**. You are the **commander**. The XO turns what you ask for
into briefs and hands each one to a **crew** member: a Claude Code or Codex worker in its own
git worktree. It supervises them and comes back with outcomes, real decisions, and evidence.
You don't juggle tabs.

chartroom has two parts: a small bash CLI (`chartroom`) that does the exact work (task
records, worktrees, launching, steering, liveness, a wake stream), and Agent Skills
(`chartroom`, `bearings`, `dashboard` to open the app, `continue` to jump to one item by its
short id, `captain`, the chartroom skill under its older name, `join`, which lets an
agent session you started yourself join the crew, and `sweep`, which frees what finished work
left running) that tell your agent how to be the XO. State is plain files under `~/.chartroom`. There is no daemon (the optional
[app](docs/app.md) shows every home in a browser and on your phone).

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

## Quickstart

You need macOS or Linux, bash 4 or newer (macOS: `brew install bash`), `jq`, `git`, and an
agent CLI you are already signed in to: Claude Code or Codex. With tmux, each worker gets a
window you can watch. Without it, workers run headless.

```bash
# 1. install: the CLI in ~/.local/bin, and your home (the XO's records) in ~/.chartroom
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash
# 2. what can run here; the "auto:" line is the backend your first worker gets
chartroom doctor
# 3. teach your agent to be the XO (Codex or Gemini: --agents; pi: --pi)
chartroom install-skills --claude
# 4. start the XO in the home
cd ~/.chartroom && claude
```

Then, at the XO's prompt, ask for something in a repository you have:

> In ~/code/todo-cli, add a --json flag to `list`, and separately find out why the test suite
> takes four minutes.

The XO resolves the project, writes two briefs (one **ship**, one **scout**), dispatches each
to a worker in its own git worktree, and goes quiet until something needs you. Ask
*"bearings"* at any time for a digest: needs you, ready, under way, trouble. To look for
yourself:

```bash
chartroom board                       # the lanes: needs you, in progress, on hold, ready, finished
chartroom status                      # every task, one row each
chartroom attach <id>                 # a worker's own terminal (tmux, herdr, cmux, hc)
```

For a browser or your phone, [the chartroom app](#the-chartroom-app) shows every home once it is
set up; `chartroom dashboard` then opens it.

When a worker is done, the XO reviews it and closes the task. `chartroom close <id>` removes
the worktree, refuses while it holds uncommitted work, and deletes the branch only once its
work has landed (merged, or on origin at that commit).

- `install-skills` with no flag links into the agents whose config directories it finds. On a
  machine where the agent has never run, there are none yet: pass the flag.
- `chartroom project <name>` finds a repository by name once `CHARTROOM_PROJECT_ROOTS` (in
  `~/.config/chartroom/config`) names the directories that hold your checkouts. Until then,
  give the XO a path.

**What a clean account has run.** The four steps above, then a first task on the `command` backend
(a stub worker) through dispatch, commit and close, were run in an empty
`HOME` that had only bash, jq, git, tmux, python3, curl and the claude CLI on its PATH (chartroom
0.2.0). A Claude XO and a real Claude worker have **not** been run from such a pristine home,
because Claude Code needs its own sign-in there. Both run every day on machines that have
been signed in to for a while.

## What is new since 0.1.0

| Feature | Status | Default | Read |
|---|---|---|---|
| Branch cleanup: `close` deletes a branch once its work has landed; `sweep` prunes landed leftovers | stable | on | [Housekeeping](#housekeeping-sweep) |
| Permission cards: a Claude worker's permission prompts become cards the XO or you answer | stable | on for every Claude worker | [Permission cards](#permission-cards-no-prompt-only-a-terminal-can-answer), [docs/permits.md](docs/permits.md) |
| The hc runner: workers in the Herdr app's terminals | experimental (`hc:codex` not run against a real codex) | first in the automatic order, skipped when `hc` is absent | [Backends](#backends) |
| Parked workers: an idle hc:claude worker's session ends and resumes on the next message | experimental | on after 60 minutes, hc:claude only | [Idle workers park](#idle-workers-park) |
| The app: one PWA for every home on a machine, over Tailscale | experimental | off until `chartroom app serve` | [docs/app.md](docs/app.md) |
| Phone push for the app (Web Push, encrypted end to end) | experimental | off (`CHARTROOM_APP_PUSH=on`) | [docs/app.md](docs/app.md#on-the-phone-and-notifications) |
| Brain and client homes: a laptop's home whose records and workers live on an always-on machine | experimental (step 1 of 5: no offline mode) | off until `chartroom brain link` | [docs/client-homes.md](docs/client-homes.md) |
| Devices join a brain: other machines enrol with a one-time code and send heartbeats | experimental (a task runs on a device only when you pin it there with `--node`; nothing spreads work by itself yet) | off until `node add` / `device join` | [docs/multi-machine.md](docs/multi-machine.md#12-devices-the-brain-never-reaches-out) |
| The SQLite store for task records | experimental (stage 1) | off (`CHARTROOM_STORE=sqlite`) | [docs/store.md](docs/store.md) |

Experimental means it works and has tests, but its commands, settings or files may still
change in a minor release. The full list is in [CHANGELOG.md](CHANGELOG.md).

## Documentation

- [docs/fleet.md](docs/fleet.md): build your own fleet: an always-on brain, a laptop, other
  Macs, the app on your phone, and permission cards, with Tailscale as the recommended network;
  and `chartroom nodes`, devices and the fleet radar.
- [docs/dashboard.md](docs/dashboard.md): the board in the terminal, short ids, and what
  `chartroom dashboard` does now that the app replaces the web dashboard.
- [docs/app.md](docs/app.md), [docs/permits.md](docs/permits.md),
  [docs/client-homes.md](docs/client-homes.md), [docs/multi-machine.md](docs/multi-machine.md):
  the app, permission cards, client homes and devices in depth.
- [docs/homes.md](docs/homes.md): several homes (and XOs) on one machine, and how they talk.
- [docs/crew-view.md](docs/crew-view.md): the crew inside Claude Code or pi, and the Herdr panel.
- [docs/store.md](docs/store.md): the SQLite store.
- [docs/upgrading.md](docs/upgrading.md): a home from chartroom's predecessor, and what to run
  after the upgrade that retired the web dashboard.
- [skills/chartroom/references/backends.md](skills/chartroom/references/backends.md): every
  backend, and how each confirms delivery.

## Design

- **It installs into your existing setup instead of being one.** chartroom is a CLI on your PATH
  plus a few skills linked into the agents you already use. Your home directory, config and other
  skills stay as they are.
- **Full sessions for automatic work.** New work spreads across signed-in Codex, agy and
  Claude agents in hc or herdr. Other runners remain available through an explicit backend.
- **Agent-native signals instead of screen scraping.** Turn ends, approval prompts and prompt
  receipt come from Claude Code hooks and Codex `notify`, not from pattern-matching the TUI.
- **Small surface.** Bash with `jq` and `git` (about 13,000 lines across `bin/` and `lib/`), plus
  Python's standard library for the app server. No `gh` required, no worktree
  manager, no Node (only the app's optional phone push uses it).
- **The contract is files.** Briefs, an append-only event log with a documented line format, and
  reports. Any worker in any language can take part with `printf >>`.

## Install

chartroom runs on macOS and Linux only.

Requirements: bash ≥ 4 (macOS: `brew install bash`), `jq`, `git`. Optional, per backend:
the Herdr app (herdr-core, `hc`), herdr, cmux (macOS), tmux ≥ 3.0, the `claude` and/or `codex` CLIs.
`python3` for the app, `curl` on a device that joins a brain.

```bash
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash
chartroom doctor            # what can run here, and why not
chartroom install-skills    # link the skills into the agents it finds (--claude, --agents, --pi, --dir D)
```

The installer clones into `~/.local/share/chartroom`, links `~/.local/bin/chartroom`, and runs
`chartroom init`. Re-running it updates the checkout (fast-forward only).

**GUI launchers** (Claude Desktop, IDEs) start the agent from a login, non-interactive shell,
which skips your interactive rc file: on macOS `bash` there is usually the system's 3.2 and
Homebrew's dirs may be missing. chartroom handles this itself, with no dotfile changes: it
re-runs under a bash ≥ 4 found on PATH or in the usual install dirs (`/opt/homebrew/bin`,
`/usr/local/bin`, `brew --prefix`, Nix profiles, `/opt/local/bin`), and on macOS appends
Homebrew's bin dirs to PATH when they exist and are missing, after your own entries, so workers
inherit them too. `chartroom doctor` shows the bash it runs under and flags a thin PATH. A bash
elsewhere: set `CHARTROOM_BASH_SEARCH` to its directory.

Per agent:

| Agent | How it loads chartroom | How the XO waits for wakes |
|---|---|---|
| Claude Code | `chartroom install-skills --claude`, **or** `/plugin marketplace add wolzey/chartroom` then `/plugin install chartroom@chartroom` (skills only; the CLI still comes from install.sh) | `chartroom watch --once` as a background Bash command (`run_in_background`), started again after each batch |
| Codex CLI | `chartroom install-skills --agents` (`~/.agents/skills`) | loop on `chartroom watch --once --timeout 1500` |
| Gemini CLI | `chartroom install-skills --agents` (Gemini reads `~/.agents/skills`), or `gemini skills link <checkout>/skills/chartroom` | same as Codex |
| pi | `chartroom install-skills --pi` (and, for the crew view, `pi install <checkout>/mods/crew-view-pi`) | same as Codex |
| opencode, Cursor, Amp, Copilot, others | paste [`adapters/agents-md/AGENTS.md`](adapters/agents-md/AGENTS.md) into the agent's instructions, or start it in `~/.chartroom` (its `AGENTS.md` points at the skill) | same as Codex |

### The crew view and the Herdr panel (optional)

`/plugin install crew-view@chartroom` at a Claude Code prompt draws the crew in the XO's own
session: a band above the prompt, a `/crew` pane and your todo list. `mods/crew-view-pi` does
the same for pi, and `mods/herdr-chartroom` is a Tasks panel for the Herdr app. See
[docs/crew-view.md](docs/crew-view.md).

### Updating, and running on several machines

Each machine has its own install and its own home. To set one up, or to update it:

```bash
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash   # update = re-run
chartroom install-skills --claude --agents   # once; the links follow the checkout, so updates need no re-link
chartroom doctor
```

- **Share settings, not state.** `~/.config/chartroom/config` (home path, project roots,
  workspace name, branch prefix, harness) and your standing preferences (`commander.md`,
  `rulings.log`, `projects.md`) are safe to keep in your dotfiles. Everything else in the home is per machine:
  `tasks/` records hold local worktree paths, process ids and session handles, and `worktrees/`
  holds the checkouts themselves. Never sync `tasks/`, `worktrees/`, `inbox.md`, `inbox/` or
  `.watch-cursor` between machines.
- **Write the config before installing.** `install.sh` runs `chartroom init` on whichever home
  the config names, and `init` never overwrites an existing file.

### A home from before chartroom

A `~/.captain` home made by chartroom's predecessor works as is. [docs/upgrading.md](docs/upgrading.md)
says what to set so that new tasks look like the old ones.

## The chartroom app

One app for every home on a machine (experimental). It opens on **Needs me**, one inbox of
every decision, plan to approve, blocker and report across every home, answered in place. It is
a PWA served on 127.0.0.1 by `chartroom app serve`, and Tailscale Serve puts it on your phone
over HTTPS for your own Tailscale login only. A task opens as a ticket, with its pages, drafts
and the worker's terminal; Fleet shows every machine, and Usage what each subscription has left.
See [docs/app.md](docs/app.md), and [docs/fleet.md](docs/fleet.md) for the setup.

## The board, and the retired dashboard

```bash
chartroom board                      # the lanes in the terminal, one line per item
chartroom show 21ba                  # one item in detail
chartroom dashboard                  # opens the app (as chartroom app open)
```

The old web dashboard is retired, and the app replaces it. `chartroom dashboard` opens the app,
`dashboard url` prints its address, and `dashboard stop` ends an old dashboard still running from
before the upgrade. `chartroom board` and `chartroom radar` stay in the terminal. See
[docs/dashboard.md](docs/dashboard.md).

## Focus mode: one project at a time

When one project needs all of you, the rest of the crew can wait without being forgotten:

```bash
chartroom focus webapp          # or a few: webapp,billing; --for 4h ends it by itself
chartroom focus webapp --scope INC-42   # narrower: only webapp's items that mention INC-42
chartroom focus                 # 🎯 focus: webapp · 7 held (since 2h)
chartroom focus off             # ends it and lists what was held
```

- **What is held.** While a focus is on, an item of a project out of focus is held when it would
  ask something of you: a task in `decision`, `blocked`, `failed`, `awaiting-input` or `review`, or
  a "Waiting on the commander" inbox item. The count is exactly that, read from disk, so
  `status`, `board`, the app and the crew views always agree. Workers in other projects
  keep working: focus changes what reaches you, not what runs.
- **Which projects.** The names `status` prints, comma-separated. A project is in focus when it
  equals a name or starts with `<name>-` (case-insensitive), so `webapp` covers `webapp-api` but
  not `webapps`. `chartroom focus <name>` says what it covers, and warns when nothing open
  matches (a typo, or a project with no work yet).
- **Narrower than a project.** `--scope <word>[,<word>...]` (an incident or ticket id) keeps in
  focus only the focused projects' items that mention a scope word, as a whole word and
  case-insensitively: a task in its title or id, an inbox item in its text. To bring an item into
  the scope, name the word there (`chartroom new --title "INC-42: restore the job"`, `chartroom
  inbox add --project webapp "INC-42: confirm the backlog is clear"`). Everything else in the
  project is held like any other project's.
- **Hard to miss.** `status` and `board` lead with `🎯 focus: webapp · 7 held (since 2h)`, and
  `board` marks each held item `[<state> · held]` and each lane's held count. The app says how
  many items focus mode holds in each home. The crew views' band leads with `🎯 webapp · 7 held` and
  counts only what is in focus; their pane adds the focus line and dims the rest.
- **The XO.** `watch` still wakes the XO for other projects, as `[<id>] [<project>] [held]
  <event>`, so it does the routine work silently (verifying, nudging, technical answers within
  the brief) and puts what would go to you in the inbox, where it is held too. It ends each
  reply with the held line, and `bearings` covers only the focus, plus the count. After `focus
  off`, `bearings` walks the held items first.
- **Breaking focus.** A production outage, an active security exposure or data loss is never
  held. A worker reports one with `chartroom event <id> blocked --breaking "<what>"` (decision,
  blocked or failed), and the XO can mark an inbox item with `inbox add --breaking`. The text
  then starts with `[breaking] `: the item stays in view and leads Needs you, and its wake is not
  marked held.
- **`--for 30m|4h|1d`** gives the focus an end. Past it the focus is off (nothing runs to end it:
  every reader checks the time), everything is back in view, and `chartroom focus` says when it
  ran out. An end that turns itself off was chosen over a reminder because the risk is leaving
  focus on: it cannot be forgotten, and the held items come back on every view the moment it
  passes.
- **On disk**, one small file that other tools may read to follow focus live: `focus.json` in
  the home,
  `{"schema": 1, "projects": ["webapp"], "scope": ["INC-42"], "since": "<UTC>", "until": "<UTC>"|null}`
  (`scope` is `[]` without one; projects are lowercase). Focus is on while the file exists and
  `until` is null or in the future; `focus off` removes it, and a new `focus` replaces it whole
  (written to a temporary file, then renamed). For which items are in focus or held, read
  `in_focus` and `held` from `chartroom board --json` rather than re-implementing the rules.

## Artifacts: drafts that outlive the chat

The XO often drafts something for you to act on: a message to send, commands to run, notes.
In chat, that text scrolls away or is compacted, and you have to ask for it again. An artifact
keeps it with the task or inbox item it belongs to, until you say it is done:

```bash
chartroom artifact add 21ba --kind message --title "Reply to the review" reply.md   # prints 21ba/reply-to-the-review
echo 'make release' | chartroom artifact add i-7f3a --kind runbook --title "Cut the release" -
chartroom artifact list                    # open ones, newest first (--all: done too; --json)
chartroom artifact show 21ba/reply-to-the-review
chartroom artifact copy 21ba/reply-to-the-review   # onto the clipboard
chartroom artifact done 21ba/reply-to-the-review   # sent: it stops showing as open
```

- **Kinds.** `message` is text to send, `runbook` is commands to run (written ready to paste),
  `note` is anything else worth keeping, and `page` is a report to read, as HTML ([below](#pages-reports-to-read-and-print)).
- **Refs** are `<id>/<slug>`: the task's short id or the inbox item's `i-xxxx` tag, as the
  board shows them (a full task id works too), and a slug of the title (`--slug` picks
  another). The id alone works when it has one open artifact. Adding the same slug again
  replaces the text and opens it again; there are no older versions.
- **Where they show.** Under "Pages and drafts" on the item in the app (a draft unfolds with
  its text and a Copy button), the refs on the item's line in `chartroom board`, a count at the
  end of `board` and `status`, and
  the `bearings` digest, which lists open messages and runbooks under Needs you.
- **Clipboard.** `copy` uses `CHARTROOM_CLIPBOARD` if set (a command that reads the text on
  stdin; `-` prints instead), else `pbcopy` (macOS), `wl-copy` (Wayland), `xclip` or `xsel`
  (X11). Without any it prints the text.
- **On disk.** The text is `tasks/<id>/artifacts/<slug>.md`, verbatim, beside a small
  `<slug>.json` (title, kind, project, created, updated, done). An inbox item's artifacts live
  in `inbox/<i-xxxx>/artifacts/`, so they outlive its line in `inbox.md`; `add` needs the item
  to be open, the other commands do not. A task's events log notes each add and done. A worker
  may keep files of its own in `artifacts/`: only a sidecar `add` wrote, with its text beside
  it, counts, and `add` refuses a slug that names someone else's file.

The chartroom skill has the XO save anything it drafts for you to send or run as an artifact
before showing it, and give you the ref, never the text in chat alone.

### Pages: reports to read and print

A long report (findings, a review, an audit) reads badly in a terminal. A page is that report as
one HTML file, kept with its task, that you read in the app and print to PDF, instead of
a Claude artifact:

```bash
chartroom artifact add 21ba --kind page --title "Login audit" --description "What we found" audit.html
chartroom artifact open 21ba/login-audit        # the app's page viewer, in the browser
chartroom artifact pdf 21ba/login-audit --out ~/Desktop/login-audit.pdf   # --paper a4, --landscape
chartroom artifact export 21ba/login-audit --out ~/Desktop   # the .html itself
chartroom artifact template --body              # the sample body: the classes the default page styles
```

- **What `add` keeps.** One self-contained file, `tasks/<id>/artifacts/<slug>.html`, beside the
  usual sidecar (which also holds the description and the task). A fragment (no `<html>` or
  doctype) is wrapped in the default page (`templates/page.html` and `templates/page.css`): your
  title, description, project and date on top; light and dark, following the reader's setting;
  print styles with page margins, table headers repeated on each page, rows never split, table cells
  wrapping between words (code, the long runs, anywhere) and code wrapped rather than cut; components such as callouts, badges and a row of key numbers. A whole
  document is kept as written. Either way the page policy goes first in it: no scripts, nothing
  fetched, inline styles and `data:` images only. Images given as files beside the source
  (`<img src="chart.png">`) are inlined as `data:` URIs; `add` says what it could not inline,
  and warns about scripts or references to other sites, which would neither run nor load.
- **Never a secret.** A page that looks like it holds one (a private key, a token, a
  `password=` assignment) is refused and nothing is saved; `--no-secret-check` is only for a
  false alarm. Pages may be shared or hosted later, so the brief tells workers to say where a
  secret is kept instead.
- **Who writes them.** The brief's protocol tells a worker to make a page when you will read the
  result yourself, and to name its ref in its `done` event; `report.md` stays the record the XO
  reads, the page its readable view. The XO makes one the same way when it writes something
  long for you.
- **In the app.** A ticket's "Pages and drafts" (and ⌘K, under "Pages") opens a page in the
  viewer, `#/p/<home>/<task|inbox>/<owner>/<slug>`: the page in a sandboxed frame, with
  **Download PDF** and **Open alone**. `artifact open` opens the same address (the home must be
  registered). See [the app](docs/app.md#pages-drafts-and-the-terminal) for how it is served.
- **PDF.** `pdf` prints with headless Chrome, Chromium or Edge: `CHARTROOM_CHROME` if set (a path
  or a command name), else the first on `PATH`, else the usual app locations (`chartroom doctor`
  says which, or why there is none). It prints a copy of the page with the policy first and
  scripts blocked, in a throwaway profile, on letter paper unless `--paper` or
  `CHARTROOM_PDF_PAPER` says otherwise, and replaces `--out` only once a PDF came out (default:
  `<slug>.pdf` in the current directory). The viewer's button runs the same command.
- **Hosting, later.** `chartroom artifact publish <ref> --to <provider>` is the one interface for
  putting a page online (Vercel, or a link service of our own). Nothing is built yet: it refuses
  with "publishing is not configured" and uploads nothing. A provider would upload the page's
  single file and nothing else, check it for secrets again, record `{provider, url, at}` under
  `published` in its sidecar, note it in the task's events and print the link; publishing stays
  the commander's call (an outward-facing step, so a `decision` for a worker).

## Your next steps: the todo list

What you owe the crew, in one list, made from the records chartroom already keeps, so nothing is
typed in twice:

- open inbox items under "Waiting on the commander" (the XO's questions, and your own items);
- open artifacts to send (`message`) or run (`runbook`); notes are not on it;
- tasks waiting on your word: a `decision`, a `blocked` worker, finished work in `review` (`ready`).

```bash
chartroom todo                        # the list (--json for the views; --all with focus mode's held items)
chartroom todo done i-7f3a            # removes the inbox line
chartroom todo done 21ba/reply-to-the-review   # marks the artifact done
chartroom todo add --project shop "renew the cert by 2026-10-22"   # your own item, kept as an inbox item
```

```
☐ 9c1e    [billing] blocked: prod is down, need the DB password  breaking  2h
☐ i-7f3a  [legal] sign the NDA by 2026-10-22  due 2026-10-22  1d
☐ 108a    [shop] decide: pick A or B (recommend A)  3d
☐ 21ba/reply-to-the-review  [shop] send: Reply to the review  5h
```

- **Order.** Breaking first (a `[breaking]` or `[urgent]` mark, a `--breaking` report, or the word
  urgent or asap), then by the earliest date in the text still ahead of the item (`2026-10-22`,
  `not before 2026-10-19 06:00Z`; a date on or before the day the item was written, such as
  `(asked 2026-10-17)`, is a record, not a due date), then oldest first.
- **Ticking off.** `todo done` changes the record the item came from: it removes the inbox line
  (the section reads `- (none)` again once it is empty) or marks the artifact done. An inbox
  item's artifacts outlive its line, so a message to send stays on the list after its question is
  answered. A task is never ticked here: a decision clears when the XO relays your answer, and
  finished work when you accept (`chartroom accept`) or close it.
- **Focus mode.** While `chartroom focus` is on, the list shows only what focus mode does not
  hold, and the focus line says how many items it holds (`--all` shows them). Focus mode alone
  decides what is held: urgency only orders the list. An artifact follows its owner's card. The
  list counts its own items, artifacts included, so its held count can differ from `status`'s.
- **Where it shows.** `board --json` carries it as `todo`, so the
  [crew views](docs/crew-view.md#a-live-crew-view-in-claude-code-and-pi) draw it under their band with no second
  poll.

## Several XOs on one machine

One home is one XO with one crew. Give each company or client a home of its own:

```bash
CHARTROOM_HOME=~/chartroom/acme chartroom init --name acme   # its own workspace
chartroom homes                                               # the list, and anything that would collide
cd ~/chartroom/acme && claude                                 # that home's XO
```

What each home keeps to itself, reading across homes, and how one home's XO tells or asks
another's: [docs/homes.md](docs/homes.md).

## Moving a home to another machine

`chartroom migrate-home` moves a home from another machine (the client) into this one (the brain),
one home at a time. It runs on the brain, which reads the client over `ssh -o BatchMode=yes`. Paths
are the same on both machines (same user, same layout), so a moved worker resumes its own Claude
or Codex conversation in the same worktree path.

```bash
chartroom migrate-home triage   --from laptop --home acme   # read-only: every open task in a bucket
chartroom migrate-home snapshot --from laptop --all         # tar.gz of every home, on both machines
chartroom migrate-home freeze   --from laptop --home acme   # client: no new work, live workers parked
chartroom migrate-home settle   --from laptop --home acme   # the commander's decisions (decisions.tsv)
chartroom migrate-home move     --from laptop --home acme [--dry-run]
chartroom migrate-home verify   --from laptop --home acme   # the brain's home = the union of both
chartroom migrate-home finish   --from laptop --home acme --brain desk   # client: rename, fresh stub
chartroom migrate-home rollback --from laptop --home acme   # undoes move (and finish)
```

- **Triage first.** Each open task on the client lands in a bucket:
  - **(a)** landed (a PR merged at its exact HEAD, or every PR closed, and nothing local): close in place;
  - **(b)** waiting on the commander (review, done, decision, blocked, failed, drafted, a scout
    report unread): accept, close or keep;
  - **(c)** stale (waiting overdue or idle a week) with unlanded work: bundled and closed;
  - **(d)** live or recently active: a live worker moves with its worktree; a recently active one is kept, and its worktree is rebuilt on first use.

  `~/.local/state/chartroom/migrate/<from>-<home>/decisions.tsv` (outside the home, so a client copy never carries it) holds one prefilled line per task; edit its action
  column (`accept`, `close`, `keep`, `bundle`, `move`). Git facts it cannot read count as work, so
  nothing unread is ever closed as landed. `close` refuses a dirty worktree, and the task is kept:
  migrate-home never runs `--discard`.
  `accept` and `close` both close the task on the client, which removes its clean worktree **with its
  git-ignored files**, and a landed local branch: copy out any ignored file worth keeping first.
- **What moves.** Every record, closed ones too, as records only: top-level files, artifacts and
  messages of each task (at most 4 MB a file, except artifacts and messages). Clones, `node_modules` and every other
  subfolder of a task dir stay behind in the client's archive (`skipped.tsv` lists the oversized files). A login's token
  cache (`gke_gcloud_auth_plugin_cache`) and the home's `permits/` (a task's grants) are never copied.

  For each open task that moves:
  - its Claude transcript (with its dir and file history) or Codex rollout;
  - its branch, by `git fetch` from the client's checkout (read-only there), into
    `refs/chartroom/migrate/<id>` when the brain has another commit under that name;
  - its staged, unstaged and untracked changes, as patches under `tasks/<id>/migrate/`.

  A `move` task's worktree is rebuilt at once. A kept task's is rebuilt when its worker is first
  resumed: hc's revive calls `migrate-home materialize <id>`. A moved Claude task lands parked on
  `hc:claude` with its session id, so `steer` or `attach` resumes the same conversation here.
- **Some of it now: `--except ID`** (repeatable; `triage`, `move`, `verify`, `status`). The named tasks and
  the client home stay in use and untouched: no freeze, settle or finish, nothing written there. The other
  tasks, `rulings.log` and the inbox come over. It refuses while another task is live, keeps its own state
  (`<from>-<home>.partial`), and the full move later brings the rest.
- **File records only.** A home with tasks in the SQLite store (it has a `.home-id`), on either machine,
  is refused before anything is read or written: its store tasks would be left behind.
- **What merges, for a home both machines have.**

  | What | Rule |
  |---|---|
  | `rulings.log` | union, by timestamp, so the newest ruling per topic wins |
  | `commander.md` | the client's is the base; the brain's extra lines are appended for review |
  | `inbox.md`, `inbox/`, artifacts and relays | unioned; a clashing id is renamed on the brain's side |
  | `config` | the brain's keys win (its own workspace), plus the client's other keys |
  | the XO's Claude project dir | sessions and memory unioned |

  Every brain file a merge replaces is backed up under the state dir first.
- **Safe to stop at any step.**
  - Each step is idempotent, and `move` refuses without a freeze, or when the disk would drop
    under 15% free.
  - A frozen home refuses `new`, `dispatch`, `steer` and `attach`.
  - The brain's watch reads a moved log from where the client left it, so a task's history never
    wakes the XO again.
  - `verify` checks every client record is here, with the same log bytes and state; branch heads,
    rebuilt worktrees and transcripts equal to the client's; the brain's own tasks untouched; and
    the merged files holding both sides.
  - `finish` locks the client's worktrees, renames its home to `.migrated/<home>-<stamp>`, and
    leaves a fresh stub (linked with `chartroom brain link` where that is installed).
  - `rollback` is a rename back. `reap --apply`, after 14 days and on the commander's word,
    removes the client's clean worktrees and the renamed home.
- `CHARTROOM_MIGRATE_PATH_MAP=<from>=<to>` maps a path prefix where the two machines differ.
  `--from local` takes a client on this machine.

## Housekeeping: sweep

Finished work leaves things running: the agent sessions of done tasks, a `chartroom watch` whose
XO session ended, dev servers and daemons (Nx, `tsc --watch`, vite, esbuild, rails, ...) started
in a worktree that has since been closed. `chartroom sweep` finds them and frees the part that is
safe to free:

```bash
chartroom sweep              # dry run: one summary line, then what needs a human
chartroom sweep --apply      # free the safe set; prints the same summary of what it did
chartroom sweep --verbose    # the safe set item by item: processes, age, CPU time, %CPU, RSS
chartroom sweep --json       # everything, for tools
```

```
sweep (dry run): safe to free 1 done task(s) to close, 4 session(s), 2 dev process tree(s) = 18 proc(s), 1.1G RSS, 0.2% CPU; needs a human: 1; left alone: 30 proc(s) of live work; load 2.88 2.86 3.06 on 18 CPUs
  [remove-creds-1670] done 2d3h ago, not closeable: 5 commit(s) not in origin/main (unpushed or unmerged) (holds 2 proc(s), 420M)
```

What it looks at: this user's processes (`ps`, plus each one's working directory from `/proc` or
`lsof`) against the home's task records. A process belongs to a task when its argv names the
task's directory (the agent session: `claude --add-dir`, a launcher, `codex -o`), or when it runs
in the task's worktree (by working directory or argv, whatever the program is), or descends from
either. herdr's agent and pane lists add the sessions it hosts. All the rules live in
`lib/sweep.jq`, in one place; the agent running it never has to reason over process lists.

`--apply` acts only on the safe set:

- closes done tasks (ones you accepted: a task still in `review` is never closed by sweep) whose
  worktree is clean and whose commits are all in the base ref (as of the
  last fetch: it never fetches), through `chartroom close`, which still refuses a dirty worktree.
  A task that reported done less than `CHARTROOM_SWEEP_SETTLE_MINUTES` ago waits, so the XO sees
  its report first;
- parks the hc:claude workers at rest for `CHARTROOM_PARK_AFTER_MINUTES` (see
  [Idle workers park](#idle-workers-park)): their sessions resume on steer or attach;
- stops the sessions of closed tasks (a herdr tab or pane only when herdr places it in the task's
  own tab or worktree; otherwise the processes);
- kills orphaned chartroom loops: a `watch` run from this home whose session is gone (its nearest
  real parent is init), a `listen` of a closed task, and the retired web dashboard's server for
  the home, still running from before the upgrade (the app replaces it);
- kills processes left in a closed task's worktree, or in a chartroom worktree path that no
  longer exists;
- deletes the branches of closed tasks whose work has landed since they closed (a pull request
  merged the day after, say), first removing the task's worktree if it is still there and clean.
  An unlanded branch, a worktree with changes in it, and any branch no task record names are
  never touched. This one fetches origin (once per project) and asks `gh` about merged PRs.

Kills are TERM, then KILL after 5 seconds, and only if the pid still runs what the plan saw. Every
act is logged to `sweep.log` in the home and, when it belongs to a task, to its `events.log`.

It never touches in-flight work (anything but review, done, failed, stopped-silent or closed), never
`--discard`s, never closes a task with uncommitted, unpushed or unmerged work, never treats a
joined session's own directory as a worktree, and never kills a process with a terminal outside
a task's session (someone may be using it). Whatever it is not sure about is listed under "needs
a human" with the reason: a task in review with its session still open, a done task that has not landed, a failed or silently stopped task whose
session is still open, a long-running process in an open task's worktree, an orphaned loop from
another home. Those are raised only once the task has been idle for `--idle-hours`
(`CHARTROOM_SWEEP_IDLE_HOURS`, default 24), so fresh work is not nagged about.

The `sweep` skill has the XO run `chartroom sweep --apply` at session start, when the fleet goes
quiet, and when you say the machine is hot or slow; it relays the summary line and asks you only
about what needs a human. There is no daemon: a harness that can schedule (Claude Code's `/loop`,
cron) can run `chartroom sweep --apply` now and then.

## Stuck workers wake the XO

A worker must not sit stuck with nobody knowing. Where the agent reports a prompt itself, the
wake comes from that report. For what it does not report, the watch looks at each task at most once
a minute (`CHARTROOM_LOOK_INTERVAL`), with one read of its terminal or output file:

- **A prompt or dialog** wakes as `agent: awaiting-input: <what>`, on every live backend. That is
  a Codex approval prompt too (Codex reports no state to hc, and its notify fires only at a turn's
  end): chartroom reads the `Action Required` it sets in its terminal title, at once on hc, and
  from the screen where there is no title to read.
- **`steer` refuses a Codex worker at a prompt**, because text and Enter there would approve the command.
- **A startup dialog never loses the brief.** Dispatch says the worker is waiting, exits 0 and
  raises the dialog; the brief starts once it clears. Codex's "Hooks need review" is never trusted
  for you: answer it, or set `CHARTROOM_CODEX_HOOKS_DIALOG=skip` to take Esc in worktrees chartroom
  created, so those hooks do not run for those workers. The first Codex worker on a machine shows it
  once for chartroom's own pattern kill guard; trust that one, and later workers start without it.
- **A worker gone quiet** wakes once as `stalled: no output or events for 10 min ... Last output:
  ...`: a task in flight, not `waiting`, not parked, not at a prompt already raised, whose output and
  events have not changed for `CHARTROOM_STALL_MINUTES` (`0` turns it off). New output or an event
  re-arms it. What ticks by itself (a timer, a spinner) is not output, and a command still using CPU
  holds the wake back for up to `CHARTROOM_STALL_BUSY_MAX_MINUTES`.

`skills/chartroom/references/backends.md` has the table of each stuck state per backend. A joined
session (your own) and a subagent (the host's) are not looked at.

## Permission cards: no prompt only a terminal can answer

A Claude worker's permission prompts come to chartroom. Every Claude worker carries
`PreToolUse`, `PermissionRequest` and `PermissionDenied` hooks.

- **The policy answers routine calls.** One file, `lib/permit.jq`, holds the rules. It allows work
  inside the worktree, and what the task's grants (`new --grant push-branch|open-pr|merge-auto|comment-pr|prod-read`)
  let through.
- **Everything else becomes a card.** That covers production, secrets, feature flags, money,
  anything outward-facing without a grant, and other places or machines. The card wakes the XO
  as `permit: asks p-xxxx: <call> (<rule>)`. The worker's call waits up to 15 minutes, then is
  denied, and the worker posts a `decision`.
- **Answering.** `chartroom permit answer <p-id> once|always|deny [--note ...]`: the first answer
  wins. "always" lasts until the task closes, and a late allow is kept as a one-time pre-approval.
- **Auto mode's refusals** are recorded too, with a card that can allow a retry.
- **The audit trail.** Each outcome is a `permit:` line in the task's events.
- **A worker cannot answer its own card or forge an allow.** The record lives outside its
  directories, and the verbs refuse a worker.

[docs/permits.md](docs/permits.md) has the details and the limits.

## Idle workers park

A Claude Code worker that has finished its turn still holds its agent and that agent's MCP
servers: about 1.1 GB and four processes each, measured on idle workers, doing nothing until the
next message. So an hc:claude worker at rest is **parked**: chartroom ends its terminal and
keeps its Claude session id, and `steer`, `attach` (and the Herdr panel's Open worker) resume
that session in a fresh terminal in the same worktree, with the same tab name, in a second or two
(`claude --resume <id>`, the message as its first prompt). Nothing is lost: the agent picks up
with its whole conversation.

- **When.** The watch parks a worker whose agent has been at rest (its turn over, nothing
  prompted since) for `CHARTROOM_PARK_AFTER_MINUTES` (default 60), whatever the task is waiting
  on: review, a decision, a blocker, a `waiting` window, a plan awaiting approval. `accept` parks
  one at once, `chartroom park <id>` parks one now, and `sweep --apply` parks the ones due.
  The first turn after a resume re-caches the conversation. With a grace at least as long as
  the prompt cache lasts, a live worker steered as late pays the same. That is an hour for the
  Claude Code sessions here; the API's default is 5 minutes.
- **Never** a worker mid-turn, one blocked at a dialog, a joined session, one running a tool
  command (a dev server, a monitor, a background wait: it would die with the agent), or one with
  no recorded session or transcript. A refusal says why, once, as a `note: not parked: ...`.
- **Seeing it.** `status`, the board and the panel show `live: parked`, and the
  task keeps its state (a parked `waiting` task is still `waiting`). `peek` shows the screen saved
  when it parked. Its Herdr tab goes while it is parked.
- **Wakes.** A parked worker costs the watch nothing: it is not probed. A resume that fails
  (the session is gone, the worktree moved) wakes the XO once with `note: revive failed: ...`,
  and the task stays parked.

hc:claude only, for now. Each launch gives claude a session id of chartroom's choosing
(`--session-id`), and the prompt hook records the one Claude reports. A worker started before
that is recognised from Claude Code's own session record when its transcript is the task's.

## Concepts

- **Commander / XO / crew.** You, the coordinating agent, the workers. The crew never talks to you
  directly. Everything goes through the XO.
- **Brief** (`tasks/<id>/brief.md`): the commander's intent (verbatim), a spec, explicit authority,
  and the worker protocol. `dispatch` refuses a brief with no intent.
- **Ship vs scout.** Ship tasks commit on `chartroom/<id>` in their own worktree. Scouts produce a
  report and no commits.
- **Plan gate** (`new --plan-gate`): the worker writes `plan.md`, raises a decision and stops
  until you approve.
- **Rulings** (`rulings.log`): the commander's lasting preferences, one append-only line each
  with a topic, the ruling it supersedes and where it came from. The newest ruling in a topic
  wins. `chartroom rule add --topic <slug> "<text>"` records one and rewrites a generated block
  in `commander.md` with the live set, so a preference that changed three times reads as one
  line, and `rule list --all` still shows the whole chain. Text outside the block stays yours.
- **Review, done, closed.** A worker's `done` report never marks the task done: it puts it in
  `review` (finished, awaiting your look), and it stays on `status`, the board's Needs you
  lane, the app's Needs me and the panel until you say so. `chartroom close <id>` closes it (removing a clean
  worktree); `chartroom accept <id>` marks it `done` and keeps everything (a `note: accepted`
  event). A task from before `review` existed reads the same way: its `done` event is `review`
  until accepted. The state is derived from the log; nothing is rewritten.
- **Authority is explicit.** Workers never push, open PRs, merge, or delete branches unless the
  brief grants it for that task. `close` refuses a dirty worktree, and **chartroom never deletes
  unlanded work**: a task's branch is deleted at close only once its work has landed (merged
  into its base, on origin at that very commit, or a merged pull request at it, which `gh` is
  asked about to catch a squash merge; without `gh` such a branch is kept), and close says which
  it did and why. A branch checked out elsewhere is kept.

## Backends

A backend is `<runner>:<agent>`, where the agent is `claude`, `codex` or `agy` (Antigravity CLI; full sessions
only: `hc:agy`, `herdr:agy`, or `node:agy` on a device where agy is signed in).

| Backend | Runs in | Watch | Steering | Needs | Status |
|---|---|---|---|---|---|
| `hc:<agent>` | an herdr-core terminal, in its own tab of the Herdr app's `$CHARTROOM_WORKSPACE` space | yes (`chartroom attach`, or the app) | live | herdr-core running (the Herdr app, or `hc server start`); the window may be closed | `hc:claude` verified (hc 0.1.14, herdr-app 0.1.9, Claude Code 2.1.314); `hc:codex` implemented, not yet run against a real codex |
| `hc:agy` | an herdr-core terminal running `agy -i <brief>` | yes | live (taken, not checked against its text) | agy signed in (`chartroom doctor` says) | verified (agy 1.5.17 and 1.5.18, hc 0.1.21). Only the pattern-kill guard hook: no permission cards or grants, never parked |
| `herdr:<agent>` | a herdr tab (first class) | yes | live | herdr running | verified (herdr 0.9.1); `herdr:agy` built to the same rules, not run against a signed-in agy |
| `cmux:<agent>` | a cmux tab (macOS) | yes | live | cmux app, automation socket mode if the XO runs outside cmux | **implemented, unverified on real cmux** |
| `tmux:<agent>` | a tmux window | yes (`chartroom attach`) | live | tmux ≥ 3.0 | verified (tmux 3.x) |
| `headless:claude` | `claude -p`, stream-json in/out | `peek` | live (stdin stream), resume after | claude CLI | verified (2.1.289) |
| `headless:codex` | `codex exec --json` | `peek` | between runs (`exec resume`) | codex CLI | verified (0.158.0) |
| `command` | any CLI from a template (`{brief} {prompt} {worktree} {task_dir} {id}`) | `peek` | between runs (+ best-effort inbox) | nothing | tested with the stub agent |
| `subagent` | the host harness's subagent | no | host | Claude Code only | carried over, not re-verified |
| `joined:<agent>` | a session you started yourself, that ran `chartroom join` | `peek`; `attach` if it is in tmux/herdr/cmux | mailbox | the `join` skill in that session | verified (Claude Code 2.1.293 in tmux) |

Without `--backend`, dispatch first chooses a machine, then the agent with the fewest live tasks
in this home among those signed in and usable there. Ties go to **Codex, agy, Claude**, in that
order. Automatic work uses **hc or herdr full sessions only**; it never falls back to headless,
tmux, cmux, or command. An explicit `--backend` wins and never silently downgrades.
Drafts with an assigned backend and unfinished workers count toward the spread; review, done,
failed and closed tasks do not. Existing workers keep their assignment.

Use `--needs mcp` or `--needs browser`, or a brief line `Needs: mcp`, `Needs: browser`, or
`Needs: claude`, when the work needs browser or MCP tools available only to Claude.
These requirements keep the task on this machine and select Claude unless an explicit backend
overrides the agent. A remote pin must be changed to `node=here` before dispatch. Name the requirement
explicitly: merely mentioning a tool in prose does not force an agent. A machine pin still allows
automatic agent selection on that machine. The agent choice occurs at dispatch so edits to the
brief and current node availability are included.

`chartroom status` prints live counts and review outcomes per agent; `status --spread --json`
returns just those counters. Both support `--all-homes`. `board --json --all-homes` (also
`dashboard --json --all-homes`) includes them for each home, and `board --all-homes` without JSON
prints a board for each home. `doctor` reports local agent sign-ins
and full-session usability, subscription usage and exhaustion, plus each enrolled node's last reported agent availability.

### Subscription usage and moving exhausted work

```bash
chartroom usage                      # per-agent (and per-machine where they differ) usage table
chartroom usage --refresh --json     # force fresh reads from each agent's real source
chartroom move <id>                  # move a stuck task to another agent, keeping branch & edits
chartroom move <id> --agent codex    # move to a specific agent (--dry-run previews; --force overrides)
```

- **Real sources only.** chartroom reads actual quota/rate-limit windows from each agent's own
  mechanism (`claude` OAuth usage endpoint using the active macOS Keychain or `.credentials.json`
  credential verified against `claude auth status`, plus optional `statusLine` input via
  `chartroom usage record claude`; `codex` live `codex app-server` `account/rateLimits/read` with
  fallback to `token_count` `rate_limits` events under `~/.codex/sessions/`; `agy`
  `agy --output-format json -p=/usage`; `grok` reports `unknown` with the CLI's reason until a
  real daemon-route capture verifies its JSON shape) and never guesses or estimates numbers. Only
  active account-wide limiting windows mark an agent out (never model-scoped side buckets or
  disabled extra-usage spend). Readings refresh automatically during `watch` (and on enrolled
  nodes during device heartbeats) every `CHARTROOM_USAGE_REFRESH_MINUTES` (5). Where no number
  exists, it reports `unknown` and why. Readings are stored under `$CHARTROOM_HOME/usage/` with
  sample time, machine, plan, and a non-identifying account label (an optional
  `CHARTROOM_USAGE_ACCOUNT_<AGENT>` alias, or `<provider> #<6-hex>` hashed in memory from the
  account/org ID so distinct subscriptions split cleanly across machines) — never tokens, cookies,
  emails, or raw org/account IDs. Readings older than `CHARTROOM_USAGE_STALE_MINUTES` (30) are
  flagged stale with their age. An enrolled node sends its readings in every heartbeat, with
  model-only windows marked and the agent's own limit flags and worker stops intact, so the brain
  judges a node's agent exactly as the node does.
- **Exhausted agents are skipped.** Once any active window reaches `CHARTROOM_USAGE_LIMIT_PCT`
  (default 95%; warning at `CHARTROOM_USAGE_WARN_PCT`, 80%), the agent itself allows no more use
  (Codex's spend cap or block), or a worker hits a usage-limit error,
  automatic dispatch (`spread_pick`), automatic re-dispatch, node placement, and fallback skip
  that agent until its `resets_at` passes; an explicit `--backend` for an exhausted agent prints a
  warning with its reset time. `chartroom doctor`, `chartroom nodes`, and the app's **Usage**
  page (Fleet → Usage, `#/usage`, or ⌘K "Usage"; [docs/app.md](docs/app.md#what-it-does)) all show
  exhausted and near-limit agents with their reset times.
- **Detecting stops and moving work.** During `watch` (and on enrolled nodes via guest checks),
  chartroom detects anchored usage-limit stop banners on idle/stopped workers (`claude`, `codex`,
  `agy`, `grok`) — ignoring mid-turn output, prose, and tool output — marks only that machine's
  agent out, and wakes the XO once per stop with `agent: out-of-usage: <agent> resets <time>; available: ...`
  (a worker that resumes and stops again raises a new wake).
  Run `chartroom move <id>` to stop the old worker and re-dispatch onto an available agent while
  keeping the exact brief, branch, worktree, commits, and uncommitted changes; tasks with
  Claude-only needs (`mcp`/`browser`/`claude`) refuse automatic moves off Claude unless `--agent`
  or `--force` is given, and `--node <device>` refuses started tasks with local work so unpushed
  commits or edits are never stranded (use `--node here` to recall remote node work home).

During the trial, `CHARTROOM_REVIEW_NON_CLAUDE=opus` (default) gates new Codex and agy ship
tasks. Scouts and tasks created before the gate are exempt. A `done` event marks review pending;
the watch creates and dispatches a linked **hc:claude, claude-opus-5-5** cold review in the
background. Keep the watch running for reviews and retries. The reviewer receives a copy of the
brief and `chartroom git <id> diff <base-sha>...`, never the worker's report. It writes findings
ranked P0–P3 and posts a clear Clean or Rework verdict; case and ordinary punctuation do not matter.
A leading `Clean`, `Rework`, or `Not clean` (optionally after `Verdict:`) takes precedence over
explanatory prose. A completion with no verdict is consumed once and keeps acceptance blocked
until the reviewer posts a verdict. If no review task exists, accept names the review-sync command
and the watch as ways to start it.
The original stays in review; accept and ordinary close wait for that verdict. A finished review
does not automatically accept the work: the commander still decides. `accept <id> --skip-review`
explicitly bypasses the gate for that task and records the decision.
If hc:claude or the worker's Git is unavailable, the review shows blocked and the watch retries.
A repeated completion reuses its review when the captured diff is unchanged; a changed diff gets
a new review. The tally counts reviewed original tasks, including closed tasks, by their latest
review result, rather than counting review rounds. Set `CHARTROOM_REVIEW_NON_CLAUDE=off` in the
home's config to end the trial gate.

`CI=true` disables session runners. Details, including how each one confirms delivery:
[skills/chartroom/references/backends.md](skills/chartroom/references/backends.md).

**Joining a running session.** An agent session you started yourself, anywhere (any terminal,
an IDE, the desktop app, inside or outside herdr/tmux), can join the crew: say "join chartroom"
in it (or `/join`, with a home path or name if you have more than one). The `join` skill runs
`chartroom join` from that session's directory, which records it as a task using the directory
and branch as they are (no new worktree; `close` never removes or cleans it), has the agent write
its own brief from what you asked it, and arms a mailbox listener. `chartroom steer` writes to
the mailbox and says `delivered` only once the agent read it. In Claude Code the listener runs
as a background command, so an idle session wakes up when a message arrives; Codex and other
agents read their mailbox between steps. Details per agent and terminal:
[backends.md](skills/chartroom/references/backends.md#joinedagent-a-running-session-that-joined-itself).

**First-launch trust dialogs.** Claude Code and Codex ask before working in a never-seen
folder. chartroom answers that dialog only for a worktree it created itself for the task, and
only after reading which option the cursor is on. Anything else is left for a human and
raised as a wake. It never edits your agent config to pre-trust paths.

## State format and event protocol (the contract)

```
$CHARTROOM_HOME/                    default ~/.chartroom
  commander.md  projects.md         standing preferences, per-project overrides
  rulings.log                       commander rulings, one line each; rendered into commander.md
  focus.json                        focus mode's projects, scope, since and until (only while it is on)
  inbox.md                          questions waiting on the commander, chat approvals not yet in a brief
  AGENTS.md  CLAUDE.md              "a session here is the XO"
  tasks/<id>/meta.json              {"schema":1, id, kind, backend, project, base_sha, branch, worktree, ...}
  tasks/<id>/brief.md  report.md  plan.md  final.md
  tasks/<id>/events.log             one line per event
  tasks/<id>/artifacts/<slug>.md    a draft for the commander (message, runbook, note), verbatim,
  tasks/<id>/artifacts/<slug>.html  or a page (kind page): one self-contained HTML file,
  tasks/<id>/artifacts/<slug>.json  with its title, kind, description, task, project, created, updated and done
  inbox/<i-xxxx>/artifacts/         the same, for an inbox item
  relays/inbox.ndjson               relays from other homes' XOs, and this home's acks, one JSON record per line
  relays/outbox.ndjson              the relays this home sent
  usage/<machine>--<agent>.json     subscription usage readings (plan, windows, resets_at, sample time; zero secrets)
  .changed                          the change stamp: rewritten after each write of what the board shows (its mtime is what counts)
  sweep.log                         what `chartroom sweep --apply` closed, stopped and killed, one line each
  worktrees/<repo>/<id>/            task worktrees (unless the repo ignores .worktrees/)
```

Ruling lines are `<ISO-8601 UTC> [r-xxxx] topic=<slug> supersedes=<r-xxxx|-> src=<token> :: <text>`,
append-only. The live set is the newest ruling of each topic, minus any ruling a later line
names in `supersedes=` and any topic whose newest text starts with `(retired)`. It is
rendered between `<!-- chartroom:rulings ... -->` and `<!-- /chartroom:rulings -->` in
`commander.md` (or a legacy `captain.md` when there is no `commander.md`).

Relay records are one JSON object per line, append-only:
`{"schema":1,"kind":"relay","id":"rl-3f2a","from":"acme","to":"globex","at":"<ISO-8601 UTC>","text":"...","re":"rl-1b2c"|null,"project":"shop"|null}`,
and `{"schema":1,"kind":"ack","id":"rl-3f2a","at":"<ISO-8601 UTC>"}` once the receiving home acks
one. A relay is open until its ack. `watch`'s cursor keeps the mailbox's offset under `@relays`.

Event lines are `<ISO-8601 UTC> <kind>: <text>`. They are append-only, and any process may
write them:

| Kind | Written by | Wakes the XO |
|---|---|---|
| `progress` | worker | no |
| `waiting` | worker, right before ending a turn to wait on CI, a review, a timer or a person: what, and until when (`... until 2026-01-05T15:30:00Z`) if known | no; once, as `waiting overdue: ...`, if the worker is still stopped when the window runs out |
| `decision` `blocked` `done` `failed` | worker | yes |
| `note` | chartroom (created, dispatched, worktree, fallback, accepted, closed, `waiting overdue`, `stalled`) | no |
| `steered` | chartroom (`steer`) | no |
| `exited` | process wrappers (`... (exit N)`) | yes, unless the worker reported first |
| `agent` | hooks and the watch: `turn-ended`, `awaiting-input: <why>`, `prompt-cleared`, `prompt-received`, `out-of-usage: <agent> resets <time>; available: ...` | `turn-ended` without a report, `awaiting-input`, and `out-of-usage` |

`watch` waits on a doorbell: whatever chartroom records (`chartroom event`, a hook's line, a
relay) rings it once the line is on disk, and it wakes within a fraction of a second, reading
only the logs that changed. Every `CHARTROOM_WATCH_INTERVAL` seconds (default 3) it looks, without
a fork, at every log and task record changed since its last scan, which is how it sees a line
appended with `printf >>` or a launcher's or wrapper's `exited`. Its full round (every task, the
backends' own state, overdue waits) runs at that interval while a worker's state must be polled
(herdr, a worker's pid). hc pushes its agents' state through `hc events`, so with every open task
on hc (or on runners with nothing to poll) the full round runs every
`CHARTROOM_WATCH_HC_INTERVAL` seconds (default 60) instead. `listen` waits on its own, which `steer` rings. A
ring carries no data, so the files stay the only truth. The doorbell is a FIFO per listener
outside the home, in `/tmp/chartroom-<uid>/bells/` (`CHARTROOM_RUNTIME_DIR` moves it); on Git
Bash, or where no FIFO can be made, `watch` and `listen` poll as before.

`.changed`, the home's change stamp, is for views that poll the board (crew-view's band; the
app's server watches it too): chartroom rewrites it after each write of what the
board shows, once that write is on disk. That covers a task's `events.log` (`chartroom event`, a
hook's line, a steer, chartroom's notes) and `meta.json` (`new`, `dispatch`, `accept`, `close`, a
runner's handles), `inbox.md` (`inbox add|project|tag`, `todo done`), `focus.json`, an artifact
(`artifact add|done`, an inbox item's included), and a relay into the home and its ack (`relay`
rewrites the target home's stamp). Nothing that only reads writes it. The contract is its path
and its mtime: a reader stats it and reads the board again when the mtime moved; what the file
holds means nothing (one byte, so the write moves the mtime on every filesystem, without a fork).
It does not move for what writes without chartroom (a line appended with `printf >>`, a
launcher's or wrapper's `exited`, a hand edit), for what moves with the clock alone (ages, a
`waiting` window running out, a focus whose `--for` ends) or for a backend's state (a worker's
terminal ending), so a reader keeps a slow refresh as well (crew-view's is 5 minutes). A home
without one has an older chartroom, or nothing written since the update.

`chartroom event <id> decision|blocked|failed --breaking <text>` writes the text as
`[breaking] <text>` (the line format is unchanged): focus mode never holds such a report.

A worker whose newest report is `waiting` and whose session has stopped shows as `waiting` in
`status` (not `stopped-silent`) until its until-time plus `CHARTROOM_WAITING_GRACE_MINUTES`, or,
with no until-time, `CHARTROOM_WAITING_MAX_MINUTES` after the event; then `waiting-overdue`.
Any later report, steer or dispatch closes the wait. `status --json` rows carry `waiting_on`,
`waiting_until` and `waiting_since` (null without an open wait), and focus mode's `breaking`,
`in_focus` and `held` (in focus and not held while focus is off); so do the lanes JSON's cards.

### The store (stage 1, off by default)

With `CHARTROOM_STORE=sqlite` in a home's own `config`, tasks born after that keep their record
and events in one SQLite database per machine instead of `meta.json` and `events.log`. The
contract above still holds for every other file. See [docs/store.md](docs/store.md).

## Safety model

- Workers get the worktree, the brief, and the authority the brief grants: nothing else.
- Headless workers can't ask for permission, so their permissions are set before dispatch.
  Codex scouts are sandboxed (`workspace-write`). Codex ship tasks default to
  `danger-full-access`, because current Codex can't commit inside its sandbox. Claude headless
  uses `acceptEdits` plus an allowed-tools list that includes Bash. These are real sharp edges.
  Tighten them with `CHARTROOM_CODEX_SHIP_SANDBOX`, `CHARTROOM_CLAUDE_ALLOWED_TOOLS`,
  `CHARTROOM_CLAUDE_HEADLESS_PERMISSION`, or per task with `new --permission` / `meta.sandbox`.
- Interactive workers use your agent's own settings unless the task sets `--permission`.
- A Claude worker's permission prompts go through chartroom's policy and cards (see Permission
  cards): routine calls inside its worktree are allowed, grants are enforced by name, and the rest
  waits on the commander, then is denied. The worker cannot answer its own cards. This is layered
  defence against the same Unix user, not a sandbox.
- A relay from another home is delivered, never acted on: chartroom runs nothing because one
  arrived, and the XO treats its text as data to weigh.
- A page is crew-written HTML, so it is treated as untrusted everywhere: kept with a policy that
  runs no scripts and fetches nothing, served sandboxed and framed only by the app, and
  printed with scripts blocked in a throwaway browser profile. `add` refuses one that looks like
  it holds a secret, and nothing uploads a page (`publish` refuses until hosting is built).

## Configuration

Environment variables win. Then the home's own `config`, if it has one (several homes on one
machine), then `~/.config/chartroom/config` (`KEY=VALUE`, no shell evaluation;
`CHARTROOM_CONFIG` overrides the path). The home's `config` can set every key but
`CHARTROOM_HOME`. The homes on the machine are listed in `homes`, next to the config file.

| Key | Default | |
|---|---|---|
| `CHARTROOM_HOME` | `~/.chartroom` | read in this order: the environment, legacy `CAP_HOME`, the registered home the current directory is (or lies in), the config file, then an existing `~/.captain` |
| `CHARTROOM_PROJECT_ROOTS` | *(empty)* | colon-separated dirs searched by `chartroom project <name>` |
| `CHARTROOM_WORKSPACE` | `chartroom-crew` | Herdr app space / herdr workspace / cmux workspace / tmux session name |
| `CHARTROOM_BACKEND_ORDER` | diagnostic backend order | space- or comma-separated; does not override automatic full-session balancing |
| `CHARTROOM_HARNESS` | `generic` | `claude` enables the `subagent` backend |
| `CHARTROOM_BRANCH_PREFIX` | `chartroom/` | |
| `CHARTROOM_TMUX_SOCKET` | *(default server)* | run the crew on `tmux -L <name>` |
| `CHARTROOM_COMMAND` | *(empty)* | default template for the `command` backend |
| `CHARTROOM_CODEX_SHIP_SANDBOX` / `_SCOUT_SANDBOX` | `danger-full-access` / `workspace-write` | |
| `CHARTROOM_REVIEW_NON_CLAUDE` | `opus` | cold review gate; `off` disables it |
| `CHARTROOM_CODEX_MODEL` / `CHARTROOM_AGY_MODEL` | (the agent's own) | the model a Codex or agy worker gets when its task names none (`new --model` wins); usually in a home's `config`. A task on a device carries it there |
| `CHARTROOM_CLAUDE_PERMISSION` | *(agent default)* | interactive Claude `--permission-mode` |
| `CHARTROOM_CLAUDE_HEADLESS_PERMISSION` | `acceptEdits` | |
| `CHARTROOM_CLAUDE_ALLOWED_TOOLS` | `Bash Read Edit Write Glob Grep WebFetch WebSearch` | headless Claude |
| `CHARTROOM_WATCH_INTERVAL` | `3` | seconds between `watch`'s looks at what does not ring its doorbell, and between its full rounds (every task, backend state, overdue waits) while a worker's state must be polled |
| `CHARTROOM_WATCH_HC_INTERVAL` | `60` | seconds between `watch`'s full rounds while hc's event stream carries every open task: how late a terminal that vanishes with no event at all can wake |
| `CHARTROOM_DASHBOARD_RECENT_HOURS` | `48` | how far back the board's Recently finished lane reaches (the name is from the retired dashboard) |
| `CHARTROOM_APP_PORT` | `4516` | the port the [app](docs/app.md#the-chartroom-app) listens on, on 127.0.0.1 only (`--port` overrides) |
| `CHARTROOM_APP_USER` | *(none)* | the one Tailscale login the app lets in; `app serve` refuses to start without it, unless `--no-auth` |
| `CHARTROOM_APP_PUSH` | `off` | `on`: the app sends new Needs me items by Web Push (through the browser maker's push service, encrypted end to end) to the devices that turned it on; needs node on the brain |
| `CHARTROOM_APP_PUSH_SUBJECT` | `mailto:chartroom@example.com` | the VAPID contact the push services see (a `mailto:` or `https:` URL) |
| `CHARTROOM_GH` | `gh` | the gh binary for PR states: the app's tickets, and whether a branch's work has landed |
| `CHARTROOM_MACHINE_NAME` | the host name | this machine's label on the [fleet radar](docs/fleet.md#the-fleet-radar) |
| `CHARTROOM_RADAR_MACHINES` | herdr's saved machines | the other machines the radar reads, read-only over ssh: `label[=ssh-target] ...`, or `none` |
| `CHARTROOM_NODES` | the radar's list | the other machines `chartroom nodes` reads: `label[=ssh-target] ...`, or `none` ([nodes](docs/fleet.md#several-machines-nodes)) |
| `CHARTROOM_NODES_TIMEOUT` | `45` | seconds `chartroom nodes` waits for a machine's probe |
| `CHARTROOM_BRAIN_URL` | the app's Tailscale Serve URL | the URL `chartroom node add` tells a device to join ([devices](docs/fleet.md#devices-machines-that-report-to-the-brain)) |
| `CHARTROOM_NODE_STALE_SECONDS` / `CHARTROOM_NODE_LOST_MINUTES` | `45` / `10` | a device's heartbeat older than this is `stale`; silent this long while the brain's app server is up, `lost` |
| `CHARTROOM_DEVICE_HEARTBEAT` | `15` | on a device: seconds between its agent's heartbeats |
| `CHARTROOM_KEYCHAIN` / `CHARTROOM_LAUNCHCTL` | `/usr/bin/security` / `/bin/launchctl` on macOS | on a device: where its token is kept and how its agent is run; `none` for a 0600 file and an agent you run yourself (`chartroom device run`) |
| `CHARTROOM_FLEET_DIR` | `fleet/` beside the config file | environment only: the brain's device registry (beside the app server's own state) |
| `CHARTROOM_LOGIN_SHELL` | `$SHELL` | the shell whose interactive login PATH (`-lic`) the probe checks tools on and what the brain's gate runs gets; `none` keeps the caller's PATH (`CHARTROOM_BRAIN_LOGIN_SHELL` still counts) |
| `CHARTROOM_WORKER_CPU` / `CHARTROOM_WORKER_MEM_GB` | `1.5` / `1.5` | a worker's assumed cost in cores and GB: in a node's UTIL, and for each worker just placed |
| `CHARTROOM_PLACEMENT` | `spread` | where `dispatch` sends a task: `spread` (the node with the most room), `pack` (the fullest with room) or `local` (this machine, always) ([placement](docs/multi-machine.md#5-placement)) |
| `CHARTROOM_PLACE_HOLD_SECONDS` | `180` | how long a worker just placed counts at its assumed cost, on top of what its node measures |
| `CHARTROOM_CPU_SAMPLER` | `on` | `off`: the app server and a device's agent do not keep the minute's CPU use |
| `CHARTROOM_NODE_CONFIG` | `~/.config/chartroom/node` | environment only: this machine's node file (`chartroom node init`), with `CHARTROOM_NODE_CPU_BUDGET`, `_MEM_BUDGET` (its limits, percent in use: `chartroom node limits`), `_ON_BATTERY` (`pause`/`allow`), `_PRIORITY` (`normal`/`nice`/`background`), `_PROJECT_ROOTS`, `_ACCEPT` (`on`/`off`) and `_CLONE` (`on`: it may clone a project it has no checkout of; off at first) |
| `CHARTROOM_RADAR_REMOTE_PATH` | `$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin` | put first on PATH on another machine (its non-interactive ssh shell lacks them) |
| `CHARTROOM_RADAR_LOCAL_MIN_SECONDS` / `_LOCAL_MAX_SECONDS` / `_REMOTE_SECONDS` / `_DONE_HOURS` / `_STALE_DAYS` | `15` / `60` / `60` / `24` / `3` | how often the retired web radar re-read, and what its archive folded away; `radar machines` still lists and checks them, and nothing else reads them |
| `CHARTROOM_OPENER` | `open` / `xdg-open` | command `dashboard open`, `app open` and `artifact open` run with the URL |
| `CHARTROOM_CLIPBOARD` | `pbcopy` / `wl-copy` / `xclip` / `xsel`, whichever is there | command `artifact copy` pipes the text into (split on spaces); `-` prints it instead |
| `CHARTROOM_CHROME` | the first of `google-chrome`, `chromium`, `chrome`, `msedge` (and kin) on PATH, else the usual app locations | the Chrome or Chromium `artifact pdf` prints with: a path or a command name; when set, nothing else is tried |
| `CHARTROOM_PDF_PAPER` | `letter` | the paper `artifact pdf` prints on: `letter`, `legal`, `ledger`, `tabloid`, `a3`, `a4`, `a5`, `b4`, `b5` (`--paper` overrides) |
| `CHARTROOM_PDF_TIMEOUT` | `60` | seconds `artifact pdf` waits for Chrome before giving up |
| `CHARTROOM_WAITING_GRACE_MINUTES` | `15` | a `waiting` worker turns `waiting-overdue` this long after its until-time |
| `CHARTROOM_WAITING_MAX_MINUTES` | `120` | ... or this long after the event, when it names no until-time |
| `CHARTROOM_SWEEP_IDLE_HOURS` | `24` | `sweep` raises a finished-but-open task's leftovers (and its own long-running processes) only after this long idle (`--idle-hours` overrides) |
| `CHARTROOM_SWEEP_SETTLE_MINUTES` | `60` | `sweep --apply` closes a done task only this long after its `done` report, so the XO sees it first |
| `CHARTROOM_PARK_AFTER_MINUTES` | `60` | the watch (and `sweep --apply`) parks an hc:claude worker at rest this long; `0` never parks on its own ([Idle workers park](#idle-workers-park)) |
| `CHARTROOM_LOOK_INTERVAL` | `60` | seconds between the watch's looks at one task: its screen or output, for a prompt nothing reports, a brief behind a dialog, and a stall ([Stuck workers wake the XO](#stuck-workers-wake-the-xo)) |
| `CHARTROOM_STALL_MINUTES` | `10` | a task in flight with no new output or event for this long wakes once as `stalled`; `0` turns it off |
| `CHARTROOM_STALL_BUSY_MAX_MINUTES` | `60` | a quiet command still using CPU holds the `stalled` wake back for up to this long |
| `CHARTROOM_USAGE_LIMIT_PCT` / `CHARTROOM_USAGE_WARN_PCT` | `95` / `80` | percent used at which an agent is treated as out of usage (skipped on dispatch) or near limit |
| `CHARTROOM_USAGE_STALE_MINUTES` / `_REFRESH_MINUTES` / `_COOLDOWN_MINUTES` | `30` / `5` / `60` | age after which a usage reading is marked stale; cache refresh interval; fallback lockout when a limit error has no parseable reset time |
| `CHARTROOM_USAGE_ACCOUNT_<AGENT>` | *(auto hash)* | optional non-identifying label (e.g. `work`, `personal`) for `CLAUDE`/`CODEX`/`AGY`/`GROK` readings; defaults to `<provider> #<6-hex>` hashed in memory from org/account ID |
| `CHARTROOM_CODEX_HOOKS_DIALOG` | `ask` | Codex's "Hooks need review" dialog at startup: `ask` wakes the XO; `skip` takes Esc in a worktree chartroom created, so those hooks do not run for that worker. Never trusts a hook |
| `CHARTROOM_BASH_SEARCH` | see Install | environment only: colon-separated dirs searched for a bash ≥ 4 when started under an older one (PATH is always searched first) |
| `CHARTROOM_PATH_APPEND` | `/opt/homebrew/bin:/usr/local/bin` on macOS, else empty | environment only: dirs appended to PATH when they exist and are missing; empty turns it off |
| `CHARTROOM_STORE` | `files` | `sqlite`: tasks born from now on live in the store ([The store](docs/store.md#the-store-stage-1-off-by-default)); set it in the home's own `config` |
| `CHARTROOM_DB` | `${XDG_STATE_HOME:-~/.local/state}/chartroom/chartroom.db` | environment only: the store's database |
| `CHARTROOM_PYTHON` | `python3` on PATH | environment only: the Python (with its `sqlite3` module) the store runs on |
| `CHARTROOM_RUNTIME_DIR` | `/tmp` | environment only: where `watch` and `listen` keep their doorbell FIFOs (`chartroom-<uid>/bells/`); every process of every home on the machine must agree on it |

`CAP_PROJECT_ROOTS`, `CAP_CREW_WORKSPACE` and `CAP_WATCH_INTERVAL` are read as legacy fallbacks.

## FAQ

**Does it work without herdr or tmux?** Yes. In a plain terminal it uses tmux if it's installed,
otherwise headless workers. Over SSH or in CI it runs headless or command workers only.
`chartroom doctor` tells you which.

**Can a worker be something other than Claude or Codex?** Yes: `--backend command --command
'your-agent --prompt {prompt} --cwd {worktree}'`. The worker reports by appending event lines
(the brief tells it how).

**Where do I watch a worker?** `chartroom attach <id>` (the Herdr app, tmux, herdr or cmux), or `chartroom peek <id>`.
An `hc:*` worker also simply appears in the Herdr app, in the `$CHARTROOM_WORKSPACE` space,
one tab per task. (Workers on `herdr:*` run in the separate `herdr` server and never show there.)

**Can an agent I already started be supervised?** Yes: tell it "join chartroom" (the `join`
skill, installed by `install-skills`). See "Joining a running session" under Backends.

**Does it push or open PRs?** Only when you tell the XO to, for that task. The worker does it
through your forge's CLI.

## Contributing

```bash
shellcheck -x -S warning bin/chartroom lib/*.sh lib/backends/*.sh install.sh scripts/*.sh test/stub-agent test/fakes/*
bats test/                 # no hc/herdr/tmux/cmux/claude/codex needed: fakes and a stub agent
CHARTROOM_TEST_REAL_CHROME=1 bats test/pages.bats   # also print one page with a real Chrome (opt-in: the rest use a fake)
scripts/privacy-gate.sh    # no personal data in tracked files or commits; only the owner's (or a listed collaborator's) noreply email in history
claude plugin test mods/crew-view   # the Claude Code mod's tests (verified on Claude Code 2.1.302 and 2.1.303)
```

Maintainers: merge by fast-forward pushing `main` from a local clone whose commits use the
GitHub noreply identity as both author and committer. Never merge through the GitHub web UI:
squash, rebase and merge-commit merges all stamp the merging account's name and primary email
on the commit, which the privacy gate (rightly) rejects on `main`: every author and committer
email in history must be the owner's GitHub noreply address (`owner_email` in the gate) or a
listed collaborator's (`collaborators`), and an email in a trailer such as Co-Authored-By must be
on its short allowlist (`trailer_ok`: those addresses and `noreply@anthropic.com`). The PR
shows as merged once its commits land on `main`.

## License

MIT. See [LICENSE](LICENSE).
