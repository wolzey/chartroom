# chartroom

**Run a crew of coding agents from one agent session.**

You talk to one agent, the **XO**. You are the **commander**. The XO turns what you ask for
into briefs and hands each one to a **crew** member: a Claude Code or Codex worker in its own
git worktree. It supervises them and comes back with outcomes, real decisions, and evidence.
You don't juggle tabs.

chartroom has two parts: a small bash CLI (`chartroom`) that does the exact work (task
records, worktrees, launching, steering, liveness, a wake stream), and Agent Skills
(`chartroom`, `bearings`, `dashboard` to open the board, `continue` to jump to one item by its
short id, `captain`, the chartroom skill under its older name, `join`, which lets an
agent session you started yourself join the crew, and `sweep`, which frees what finished work
left running) that tell your agent how to be the XO. State is plain files under `~/.chartroom`. There is no daemon (an optional local
dashboard can show the fleet in a browser).

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

## Design

- **It installs into your existing setup instead of being one.** chartroom is a CLI on your PATH
  plus a few skills linked into the agents you already use. Your home directory, config and other
  skills stay as they are.
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
herdr, cmux (macOS), tmux ≥ 3.0, the `claude` and/or `codex` CLIs. On Windows, see
[Windows](#windows).

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
| Claude Code | `chartroom install-skills --claude`, **or** `/plugin marketplace add wolzey/chartroom` then `/plugin install chartroom@chartroom` (skills only; the CLI still comes from install.sh) | `Monitor` running `chartroom watch` |
| Codex CLI | `chartroom install-skills --agents` (`~/.agents/skills`) | loop on `chartroom watch --once --timeout 1500` |
| Gemini CLI | `chartroom install-skills --agents` (Gemini reads `~/.agents/skills`), or `gemini skills link <checkout>/skills/chartroom` | same as Codex |
| pi | `chartroom install-skills --pi` (and, for the crew view, `pi install <checkout>/mods/crew-view-pi`) | same as Codex |
| opencode, Cursor, Amp, Copilot, others | paste [`adapters/agents-md/AGENTS.md`](adapters/agents-md/AGENTS.md) into the agent's instructions, or start it in `~/.chartroom` (its `AGENTS.md` points at the skill) | same as Codex |

### A live crew view in Claude Code (and pi)

`mods/crew-view` is a Claude Code mod (verified on Claude Code 2.1.302, the todo list on 2.1.303) that draws the crew inside the XO's
session: a one-line band above the prompt (`⚓ 🏃 3 · 🙋 2 [shop] 108a, [billing] 9c1e · ✅ 1`,
one emoji per lane, every item that needs you labelled with its project) and a `/crew` pane that
browses the board's items, the dashboard inside Claude Code. Tab or the arrows walk the items,
Enter opens one: its state, the commander's intent, the last events, the report's summary or the
outcome, PRs, artifacts and where the worker runs. From there, `c` puts `/continue <id>` in the
prompt (Enter runs it), `y` copies the id, `p` a PR URL, `a` an artifact, `r` reads the report,
`b` goes back; `/crew <id>` opens an item directly. `q` or Esc closes the pane, `/crew` toggles
it, and `/crew off` hides the band for the session. While [focus mode](#focus-mode-one-project-at-a-time)
is on, the band leads with `🎯 <project> · N held` and counts only what is in focus. It polls
`chartroom board --json` every 15 seconds and reads an item with `chartroom show <id> --json`.

Under the band sits [your todo list](#your-next-steps-the-todo-list), styled like Claude Code's
own: the first three things you owe the crew (`☐ [legal] i-7f3a sign the NDA · due 10-22`),
`+N more`, and while focus mode is on, the focus and how many items it holds. `/todo` opens a
pane of all of it, where the row with the ring takes `c` (copy an artifact's text), `d` (done,
pressed twice), `o` (`/continue <id>` into the prompt) and `a` (show the held items too); `/todo
off` hides the list. `/crew todo` is the same command (and the way in where your own `/todo`
command or skill already has the name). Install it at user scope:

```
/plugin install crew-view@chartroom
```

It stays inert (no command, timer, process or drawing) until the session loads the `captain` or
`chartroom` skill, and in every session but the XO's: an interactive one whose working directory
is the chartroom home, not under `worktrees/`, with no `CHARTROOM_TASK`. Installed from a local checkout (`claude plugin marketplace add <checkout>`),
`/reload-plugins` picks up edits. See [mods/crew-view/README.md](mods/crew-view/README.md).

`mods/crew-view-pi` is the same band, browser and todo list (`/todo`) for [pi](https://pi.dev) (0.87 or newer), gated
the same way (`/skill:captain` or `/skill:chartroom` wakes it): `pi install <checkout>/mods/crew-view-pi`,
for example `pi install ~/.local/share/chartroom/mods/crew-view-pi`. See
[mods/crew-view-pi/README.md](mods/crew-view-pi/README.md).

### Windows

chartroom is bash, so on Windows it runs in WSL2 or in Git Bash. It doesn't run in
PowerShell or cmd.

- **WSL2 (recommended): everything works, as on Linux.** Install chartroom, the agents
  (`claude`, `codex`) and your repositories inside WSL, and run the XO there. Keep the
  repositories on the WSL filesystem (`~/code`), not under `/mnt/c`. A Windows-side
  `claude.exe` isn't used, and skills installed in WSL are seen by WSL agents only. For
  `dashboard open`, install `wslu` (`wslview`); without it chartroom falls back to PowerShell's
  `Start-Process`. The Windows browser reaches the dashboard through WSL's localhost forwarding,
  which is on by default. Other devices reach a `dashboard --expose` in WSL only with WSL's
  mirrored networking (`networkingMode=mirrored` in `.wslconfig`); in the default NAT mode it is
  reachable from this Windows machine alone.
- **Git Bash (Git for Windows): the core, `headless:claude`, `headless:codex`, `command`,
  `subagent` and the dashboard.** There are no session runners: Git for Windows has no tmux,
  cmux is macOS-only, and herdr's Windows build is a preview that chartroom leaves off unless
  `CHARTROOM_HERDR_ANY_OS=1`. Install jq and Python (`winget install jqlang.jq Python.Python.3.12`),
  run the installer from Git Bash, and add `~/.local/bin` to your PATH in `~/.bashrc`. Some
  things differ from macOS and Linux:
  - The checkout is LF whatever `core.autocrlf` says (`.gitattributes`).
  - `~/.local/bin/chartroom` is a small launcher script, because Git Bash's `ln -s` copies.
  - `install-skills` links with directory junctions, which need no Developer Mode, into
    `%USERPROFILE%\.claude\skills` and the others.
  - A native `jq.exe`'s CRLF output is turned off with `--binary`.
  - `headless:claude` takes steering between runs, by resuming the session, not live.
  - `stop` ends the worker's whole Windows process tree.
  - `dashboard open` uses `start`.
  - `dashboard --expose` and `--host` work under the native python, token and all. The first
    time, Windows Defender Firewall asks whether Python may accept connections: allow it on the
    networks you mean to use, or other devices cannot connect. NTFS has no `0600` mode, so
    `.dashboard.token` and `.dashboard.log` are kept private by the home folder's ACL, which
    under `%USERPROFILE%` only you, SYSTEM and Administrators can read.
  - `chartroom join` is unavailable: it finds the session by its process tree, and a native
    Windows agent is outside Git Bash's. Join a running session from WSL2.
  - Workers that chartroom launches inherit its `jq`: an exported bash function that runs
    `jq.exe` with `--binary` and passes its arguments unconverted (file operands become Windows
    paths). It is harmless for ordinary use; `command jq` runs `jq.exe` itself.

  `chartroom doctor` lists these under `note:`. The Windows CI job runs the test suite in Git
  Bash.
- **PowerShell / cmd:** not supported. To install from PowerShell, hand over to Git Bash:
  `& "$env:ProgramFiles\Git\bin\bash.exe" -lc "curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash"`.

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
  holds the checkouts themselves. Never sync `tasks/`, `worktrees/`, `inbox.md`, `inbox/`, `.watch-cursor`
  or `.dashboard.*` between machines.
- **Write the config before installing.** `install.sh` runs `chartroom init` on whichever home
  the config names, and `init` never overwrites an existing file.

### A home from before chartroom

A home made by chartroom's predecessor (`~/.captain`, with `captain.md`, "Captain's intent"
briefs and `codex` / `herdr-claude` / `herdr-codex` backends) works as is. On each machine
that has one:

1. Point chartroom at it, and keep its old defaults if you want new tasks to look like the old
   ones, in `~/.config/chartroom/config`:

   ```
   CHARTROOM_HOME=~/.captain
   CHARTROOM_WORKSPACE=captain-crew
   CHARTROOM_BRANCH_PREFIX=cap/
   CHARTROOM_PROJECT_ROOTS=~/code
   CHARTROOM_HARNESS=claude
   ```

2. Move any older copies of the `captain`, `bearings`, `dashboard` and `continue` skills out of
   your agents' skill directories (`install-skills` never replaces a real directory), then run
   `chartroom install-skills`. It also links a `captain` skill: the chartroom skill under its old
   name, so `/captain` and a home whose `AGENTS.md` asks for it keep working.
3. Briefs already handed to workers name the old helper's path. Leave an executable at that
   path that hands over to chartroom, so running workers can still report:

   ```bash
   #!/usr/bin/env bash
   export CHARTROOM_HOME="${CAP_HOME:-$HOME/.captain}"
   [[ "${1:-}" == dashboard ]] && { shift; set -- dashboard open "$@"; }
   exec "$(command -v chartroom || echo "$HOME/.local/bin/chartroom")" "$@"
   ```

4. Check: `chartroom status` lists the old tasks with their states, and `chartroom board`
   shows the same lanes as the dashboard.
5. Optional: move hand-written preferences into the rulings ledger (see Concepts).
   `chartroom rule draft > map.tsv` lists each bullet with a guessed topic and its date. Edit
   the topics so rulings that replace each other share one, set a row's topic to `keep` to
   leave that bullet as hand-written text, and rewrite a row's text if the winner has to stand
   alone. Then `chartroom rule import map.tsv` (a dry run) and `--apply`, which backs the file
   up under `records/`, appends the rulings, removes the imported bullets and renders the block.

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
| **Needs you** | tasks in `decision`, `blocked`, `failed` or `awaiting-input` (in that order), then the "Waiting on ..." items in `inbox.md` with their question text; every card leads with its project |
| **In progress** | `working` and `drafting` tasks, and `waiting` ones: a worker that ended its turn right after a `waiting` event, inside its window (the card shows what it waits on and until when) |
| **On hold** | `stopped-silent` and `waiting-overdue` tasks; tasks whose last event (other than their own `waiting` event) says they wait on a person ("waiting on/for", "awaiting review", "pending approval", "on hold"); done tasks whose open PR still needs someone's review |
| **Ready for you** | `done` tasks that are not closed: a PR to review or a report to read |
| **Recently finished** | tasks closed in the last 48 hours (`CHARTROOM_DASHBOARD_RECENT_HOURS`), and done tasks whose PRs are all merged |

Each card shows the title, project (above the title on a Needs you card, so you can tell which
project a question is for at a glance), age, the last worker event, PR/MR links found in
`events.log` and `report.md`, and links that open the task's brief, report, plan and event log
as plain text. A task or inbox card with open [artifacts](#artifacts-drafts-that-outlive-the-chat)
(drafts for you to send or run) shows a chip for each: one click copies the text and opens it,
with a copy button beside it; a [page](#pages-reports-to-read-and-print)'s chip opens it in the
viewer instead. The header's **pages** link lists every page. Approvals given in chat but not yet in a brief are listed under
Needs you, and so are open [relays from other homes](#talking-between-homes) (for the XO to
weigh; they are not cards). Above the lanes, a "Your next steps" strip shows [your todo list](#your-next-steps-the-todo-list):
the first five items, each with its short id (a click copies `/continue <id>`).

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
  nothing else ever runs a page.
- **Same answer as the CLI.** The lanes come from `chartroom dashboard --json`, built from the
  rows `chartroom status` uses, so the page and the terminal never disagree.
- **PR states are optional.** If `gh` is on your PATH, the server looks up the state of the PR
  links it found (cached, refreshed every 5 minutes) to move a merged PR to Recently finished and
  one awaiting review to On hold. That is the only network traffic, and it is GitHub's API with
  your own `gh` login. `--no-gh` turns it off; without `gh`, or offline, the page just shows the
  links.
- `--daemon` writes `.dashboard.pid` (pid and port) and `.dashboard.log` in the home. One
  dashboard per home; `--port 0` picks a free port. The page is read on each load, so after an
  update a reload shows the new page without restarting the server.
- `dashboard open` reuses this home's dashboard if it answers on its port; otherwise it
  replaces a stale pid file (or a server that stopped answering), starts one with `--daemon`
  and waits for it. Then it opens the URL with `CHARTROOM_OPENER`, else `open` (macOS) or
  `xdg-open`; on WSL, `wslview` or PowerShell's `Start-Process`; on Git Bash, `start`. It prints
  the URL either way. A lock in the home (holding its owner's pid; taken over only when that pid is gone) keeps two calls from starting two
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

### On the network: other devices

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

### Optional: a local hostname

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

## Focus mode: one project at a time

When one project needs all of you, the rest of the crew can wait without being forgotten:

```bash
chartroom focus webapp          # or a few: webapp,billing; --for 4h ends it by itself
chartroom focus webapp --scope INC-42   # narrower: only webapp's items that mention INC-42
chartroom focus                 # 🎯 focus: webapp · 7 held (since 2h)
chartroom focus off             # ends it and lists what was held
```

- **What is held.** While a focus is on, an item of a project out of focus is held when it would
  ask something of you: a task in `decision`, `blocked`, `failed`, `awaiting-input` or `done`, or
  a "Waiting on the commander" inbox item. The count is exactly that, read from disk, so
  `status`, `board`, the dashboard and the crew views always agree. Workers in other projects
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
  `board` marks each held item `[<state> · held]` and each lane's held count. The dashboard
  shows a focus strip with the held count, counts only what is in focus in its gauges and tab
  title (which adds `🎯 7 held`), and dims other projects' cards (the strip's button hides them
  instead, remembered in that browser). The crew views' band leads with `🎯 webapp · 7 held` and
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
  dashboard shows them (a full task id works too), and a slug of the title (`--slug` picks
  another). The id alone works when it has one open artifact. Adding the same slug again
  replaces the text and opens it again; there are no older versions.
- **Where they show.** A chip on the card in the dashboard (one click copies and opens it), the
  refs on the item's line in `chartroom board`, a count at the end of `board` and `status`, and
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
one HTML file, kept with its task, that you read in the dashboard and print to PDF, instead of
a Claude artifact:

```bash
chartroom artifact add 21ba --kind page --title "Login audit" --description "What we found" audit.html
chartroom artifact open 21ba/login-audit        # the dashboard's viewer, in the browser
chartroom artifact pdf 21ba/login-audit --out ~/Desktop/login-audit.pdf   # --paper a4, --landscape
chartroom artifact export 21ba/login-audit --out ~/Desktop   # the .html itself
chartroom artifact template --body              # the sample body: the classes the default page styles
```

- **What `add` keeps.** One self-contained file, `tasks/<id>/artifacts/<slug>.html`, beside the
  usual sidecar (which also holds the description and the task). A fragment (no `<html>` or
  doctype) is wrapped in the default page (`templates/page.html` and `templates/page.css`): your
  title, description, project and date on top; light and dark, following the reader's setting;
  print styles with page margins, table headers repeated on each page, rows never split and code
  wrapped rather than cut; components such as callouts, badges and a row of key numbers. A whole
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
- **In the dashboard.** The header's **pages** link lists every page (newest first; read ones,
  marked `done`, on request), and a card's page chip opens it in the viewer: the page in a
  sandboxed frame, with **Download PDF** and **open alone**. See [the dashboard](#dashboard)
  for how it is served.
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
- tasks waiting on your word: a `decision`, a `blocked` worker, finished work to land (`ready`).

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
  finished work when it lands.
- **Focus mode.** While `chartroom focus` is on, the list shows only what focus mode does not
  hold, and the focus line says how many items it holds (`--all` shows them). Focus mode alone
  decides what is held: urgency only orders the list. An artifact follows its owner's card. The
  list counts its own items, artifacts included, so its held count can differ from `status`'s.
- **Where it shows.** `board --json` (and the dashboard's JSON) carries it as `todo`, so the
  [crew views](#a-live-crew-view-in-claude-code-and-pi) draw it under their band with no second
  poll, and the dashboard shows a "Your next steps" strip above the lanes.

## Several XOs on one machine

One home is one XO with one crew. When your work splits cleanly, say one home per company or
client, give each its own home: its own projects, preferences and rulings, inbox, tasks and
crew, dashboard and agent memory, and its own XO session. Nothing of one home's leaks into
another's digest, and a question is never answered in the wrong company's terms.

```bash
CHARTROOM_HOME=~/chartroom/acme   chartroom init --name acme     # workspace acme-crew, dashboard port 4518
CHARTROOM_HOME=~/chartroom/globex chartroom init --name globex   # workspace globex-crew, dashboard port 4519
chartroom homes                                                   # the list, and anything that would collide
```

`init --name` writes the home's own settings to `<home>/config` (the same `KEY=VALUE` format as
`~/.config/chartroom/config`, and it wins over it), only for keys it does not set yet: a
workspace of its own (`CHARTROOM_WORKSPACE`), so its workers' tabs never mix with another
home's, and a dashboard port of its own (`CHARTROOM_DASHBOARD_PORT`, the next free one from
4518). Add anything else that should differ, such as `CHARTROOM_PROJECT_ROOTS` narrowed to that
client's repositories, so `chartroom project` only finds theirs. It also adds the home to
`~/.config/chartroom/homes`, one `name=path` line each. `chartroom homes add <name> <path>`
registers an existing home without writing anything in it, and `homes rm` unregisters one
without touching it.

**Starting an XO.** Start the agent in the home's directory, as for any home. In a registered
home that is enough: chartroom resolves the home from the directory it runs in (after
`CHARTROOM_HOME`, before the config file), and so does the crew view. A one-word launcher in
your shell rc keeps it short, and keeps your own alias for the agent:

```zsh
# xo <home>: an XO session in that home; `xo` alone lists the homes.
xo() {
  [[ -n "$1" ]] || { chartroom homes; return; }
  local h; h="$(chartroom homes path "$1")" || return
  (cd "$h" && CHARTROOM_HOME="$h" claude "${@:2}")
}
```

The chartroom skill starts by checking that `chartroom doctor` names the directory it started
in, and stops if it does not, so a session never drives another home by mistake.

**What each home keeps to itself, and what they share.**

| Per home | Shared by every home on the machine |
|---|---|
| `tasks/`, `worktrees/`, `inbox.md`, `commander.md`, `rulings.log`, `projects.md`, `focus.json`, `relays/` | the install, the skills and the crew view |
| the workspace its workers' tabs open in | `~/.config/chartroom/config` (harness, branch prefix, backend order), under each home's own `config` |
| the dashboard (`.dashboard.*`, its port, its page title) and its access cookie | the list of homes |
| the `watch` cursor and wake stream | herdr agent names (task ids, unique per machine) |
| what `sweep` frees: another registered home's workers, loops and listeners are neither freed nor listed | a project two homes both work in (its `.worktrees/` holds both homes' worktrees, by task id) |

**Reading across homes.** `status`, `board`, `todo`, `inbox list` and `relay list` take `--all-homes`: the
same command, read-only, run in every registered home with that home's own settings, one
`== <home> · <path>` section each (`--json`: an array of `{home, path, current, result}`). A home
that oversees the others, for errands that belong to no project, uses it for its bearings. It
reads; it never steers, closes or dispatches another home's work. That belongs to the home's
own XO, which another XO can still [tell or ask something](#talking-between-homes).

**Splitting an existing home.** Make the new homes, copy each one its lines from `projects.md`
and its live lines from `rulings.log` (verbatim: the ids stay the same, and `chartroom rule
render` rebuilds `commander.md`'s block), and leave the old home's tasks to finish where they
are. Nothing has to move.

## Talking between homes

Homes keep to themselves, but now and then one XO has something for another: a heads-up (the
shared staging cluster is down, a vendor's API changes on Friday), or a request only the other
home can answer. `chartroom relay` carries it, with no daemon:

```bash
chartroom relay globex --project shop "heads up: the shared bucket moves on Friday; does anything of yours still read it?"
# rl-3f2a
```

It appends one record to the other home's mailbox, `relays/inbox.ndjson`, and writes nothing else
there; this home keeps a copy in its own `relays/outbox.ndjson`. The other home's `chartroom
watch` reads its mailbox every round, so its XO session gets a wake within seconds, the same way
it hears from its workers:

```
[relay rl-3f2a] [from acme] [shop] heads up: the shared bucket moves on Friday; does anything of yours still read it?
```

The `watch --once` cursor covers the mailbox, so each relay wakes once. One that arrives while
no watch runs is still in view: `chartroom status` says `relays: 1 open from other homes`,
`chartroom inbox list` lists it with its id under "Relays from other homes", the dashboard lists
it under Needs you (a list, never a card or a todo item: it is for the XO, not for you), and
every `--all-homes` view shows each home's, so a home that oversees the others sees them all.

The other XO answers with `--re`, which goes back the same way, and acks the relay once it has
dealt with it (a reply alone does not ack):

```bash
chartroom relay acme --re rl-3f2a "nothing of ours reads it; go ahead"
chartroom relay ack rl-3f2a
chartroom relay list [--all] [--json]   # the open relays received here (--all: acked and sent ones too)
```

- **A relay never makes anything happen by itself.** chartroom only delivers it. The receiving
  XO weighs it under its own home's preferences and authority: its text is data, not
  instructions, and anything that needs your word still comes to you, labelled with the home it
  came from.
- **Registered homes only.** It goes to a registered home that is a chartroom home, never to
  this one, and only in this home's name: the sender must be registered too (a reply has to
  find its way back), and `--from`, if given, must name this home.
- **Short, and never a secret.** At most 2000 bytes (and 4000 as written, where quotes,
  backslashes and line breaks count twice, so a relay is always one append); for more, write a
  file the other XO can read and relay its path (`-` reads the message from stdin). A message that looks like it holds a
  secret (a private key, an AWS, GitHub, GitLab, Slack, Stripe, Google or npm token, an `sk-`
  API key, a JSON web token, a `password=` assignment) is refused, and nothing is sent.
- **Focus mode never holds a relay**: it is for the XO. Whatever the XO brings to you from it goes
  into the inbox, where focus applies as usual.
- A home named `ack` or `list` cannot be relayed to (those are `relay`'s own subcommands).

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

- closes done tasks whose worktree is clean and whose commits are all in the base ref (as of the
  last fetch: it never fetches), through `chartroom close`, which still refuses a dirty worktree.
  A task that reported done less than `CHARTROOM_SWEEP_SETTLE_MINUTES` ago waits, so the XO sees
  its report first;
- stops the sessions of closed tasks (a herdr tab or pane only when herdr places it in the task's
  own tab or worktree; otherwise the processes);
- kills orphaned chartroom loops: a `watch` run from this home whose session is gone (its nearest
  real parent is init), a `listen` of a closed task, a second dashboard for the home;
- kills processes left in a closed task's worktree, or in a chartroom worktree path that no
  longer exists.

Kills are TERM, then KILL after 5 seconds, and only if the pid still runs what the plan saw. Every
act is logged to `sweep.log` in the home and, when it belongs to a task, to its `events.log`.

It never touches in-flight work (anything but done, failed, stopped-silent or closed), never
`--discard`s, never closes a task with uncommitted, unpushed or unmerged work, never treats a
joined session's own directory as a worktree, and never kills a process with a terminal outside
a task's session (someone may be using it). Whatever it is not sure about is listed under "needs
a human" with the reason: a done task that has not landed, a failed or silently stopped task whose
session is still open, a long-running process in an open task's worktree, an orphaned loop from
another home. Those are raised only once the task has been idle for `--idle-hours`
(`CHARTROOM_SWEEP_IDLE_HOURS`, default 24), so fresh work is not nagged about.

The `sweep` skill has the XO run `chartroom sweep --apply` at session start, when the fleet goes
quiet, and when you say the machine is hot or slow; it relays the summary line and asks you only
about what needs a human. There is no daemon: a harness that can schedule (Claude Code's `/loop`,
cron) can run `chartroom sweep --apply` now and then. Not on Git Bash (its `ps` has no working
directories or argv); WSL2 works.

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
| `joined:<agent>` | a session you started yourself, that ran `chartroom join` | `peek`; `attach` if it is in tmux/herdr/cmux | mailbox | the `join` skill in that session | verified (Claude Code 2.1.293 in tmux) |

Default automatic order: `herdr:claude cmux:claude tmux:claude headless:codex headless:claude command`
(`CHARTROOM_BACKEND_ORDER`). When a backend is chosen automatically and the first choice isn't
available, chartroom uses the next one and records `note: backend fallback: herdr:claude
unavailable (herdr not on PATH); using tmux:claude (steering: live)`. When you name a backend
explicitly, it never silently downgrades. Dispatch fails and names the next viable option.
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
  .dashboard.pid  .dashboard.log    only while `chartroom dashboard --daemon` runs
  .dashboard.token                  the dashboard's access token (0600), once it has been on the network
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
| `note` | chartroom (created, dispatched, worktree, fallback, closed, `waiting overdue`) | no |
| `steered` | chartroom (`steer`) | no |
| `exited` | process wrappers (`... (exit N)`) | yes, unless the worker reported first |
| `agent` | hooks: `turn-ended`, `awaiting-input: <why>`, `prompt-received` | `turn-ended` without a report, and `awaiting-input` |

`chartroom event <id> decision|blocked|failed --breaking <text>` writes the text as
`[breaking] <text>` (the line format is unchanged): focus mode never holds such a report.

A worker whose newest report is `waiting` and whose session has stopped shows as `waiting` in
`status` (not `stopped-silent`) until its until-time plus `CHARTROOM_WAITING_GRACE_MINUTES`, or,
with no until-time, `CHARTROOM_WAITING_MAX_MINUTES` after the event; then `waiting-overdue`.
Any later report, steer or dispatch closes the wait. `status --json` rows carry `waiting_on`,
`waiting_until` and `waiting_since` (null without an open wait), and focus mode's `breaking`,
`in_focus` and `held` (in focus and not held while focus is off); so do the lanes JSON's cards.

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
- A relay from another home is delivered, never acted on: chartroom runs nothing because one
  arrived, and the XO treats its text as data to weigh.
- A page is crew-written HTML, so it is treated as untrusted everywhere: kept with a policy that
  runs no scripts and fetches nothing, served sandboxed and framed only by the dashboard, and
  printed with scripts blocked in a throwaway browser profile. `add` refuses one that looks like
  it holds a secret, and nothing uploads a page (`publish` refuses until hosting is built).

## Configuration

Environment variables win. Then the home's own `config`, if it has one (several homes on one
machine), then `~/.config/chartroom/config` (`KEY=VALUE`, no shell evaluation;
`CHARTROOM_CONFIG` overrides the path). The home's `config` can set every key but
`CHARTROOM_HOME` and `CHARTROOM_PLATFORM`. The homes on the machine are listed in `homes`, next
to the config file.

| Key | Default | |
|---|---|---|
| `CHARTROOM_HOME` | `~/.chartroom` | read in this order: the environment, legacy `CAP_HOME`, the registered home the current directory is (or lies in), the config file, then an existing `~/.captain` |
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
| `CHARTROOM_DASHBOARD_PORT` | `4517` | the port `dashboard` and `dashboard open` use (`--port` overrides); each home on a machine needs its own |
| `CHARTROOM_DASHBOARD_RECENT_HOURS` | `48` | how far back the dashboard's Recently finished lane reaches |
| `CHARTROOM_DASHBOARD_THEME` | `chartroom` | the dashboard's default theme: `chartroom` or `hud` (`--theme` overrides) |
| `CHARTROOM_DASHBOARD_HOST` | `127.0.0.1` | the IPv4 address the dashboard binds; `0.0.0.0` is every interface (`--host` / `--expose` override). Beyond loopback it needs the access token |
| `CHARTROOM_GH` | `gh` | the gh binary the dashboard uses for PR states |
| `CHARTROOM_OPENER` | `open` / `xdg-open` (WSL: `wslview`, PowerShell; Git Bash: `start`) | command `dashboard open` runs with the URL |
| `CHARTROOM_CLIPBOARD` | `pbcopy` / `wl-copy` / `xclip` / `xsel`, whichever is there | command `artifact copy` pipes the text into (split on spaces); `-` prints it instead |
| `CHARTROOM_CHROME` | the first of `google-chrome`, `chromium`, `chrome`, `msedge` (and kin) on PATH, else the usual app locations | the Chrome or Chromium `artifact pdf` prints with: a path or a command name; when set, nothing else is tried |
| `CHARTROOM_PDF_PAPER` | `letter` | the paper `artifact pdf` prints on: `letter`, `legal`, `ledger`, `tabloid`, `a3`, `a4`, `a5`, `b4`, `b5` (`--paper` overrides) |
| `CHARTROOM_PDF_TIMEOUT` | `60` | seconds `artifact pdf` waits for Chrome before giving up |
| `CHARTROOM_PLATFORM` | *(detected)* | `posix`, `wsl` or `msys` (Git Bash); override only if detection is wrong |
| `CHARTROOM_HERDR_ANY_OS` | *(unset)* | `1` offers herdr on Git Bash, where its Windows preview is unverified |
| `CHARTROOM_WAITING_GRACE_MINUTES` | `15` | a `waiting` worker turns `waiting-overdue` this long after its until-time |
| `CHARTROOM_WAITING_MAX_MINUTES` | `120` | ... or this long after the event, when it names no until-time |
| `CHARTROOM_SWEEP_IDLE_HOURS` | `24` | `sweep` raises a finished-but-open task's leftovers (and its own long-running processes) only after this long idle (`--idle-hours` overrides) |
| `CHARTROOM_SWEEP_SETTLE_MINUTES` | `60` | `sweep --apply` closes a done task only this long after its `done` report, so the XO sees it first |
| `CHARTROOM_BASH_SEARCH` | see Install | environment only: colon-separated dirs searched for a bash ≥ 4 when started under an older one (PATH is always searched first) |
| `CHARTROOM_PATH_APPEND` | `/opt/homebrew/bin:/usr/local/bin` on macOS, else empty | environment only: dirs appended to PATH when they exist and are missing; empty turns it off |

`CAP_PROJECT_ROOTS`, `CAP_CREW_WORKSPACE` and `CAP_WATCH_INTERVAL` are read as legacy fallbacks.

## FAQ

**Does it work without herdr or tmux?** Yes. In a plain terminal it uses tmux if it's installed,
otherwise headless workers. Over SSH or in CI it runs headless or command workers only.
`chartroom doctor` tells you which.

**Does it work on Windows?** Yes, in WSL2 (everything) or Git Bash (headless, command and
subagent workers, and the dashboard). See [Windows](#windows).

**Can a worker be something other than Claude or Codex?** Yes: `--backend command --command
'your-agent --prompt {prompt} --cwd {worktree}'`. The worker reports by appending event lines
(the brief tells it how).

**Where do I watch a worker?** `chartroom attach <id>` (tmux, herdr or cmux), or `chartroom peek <id>`.

**Can an agent I already started be supervised?** Yes: tell it "join chartroom" (the `join`
skill, installed by `install-skills`). See "Joining a running session" under Backends.

**Does it push or open PRs?** Only when you tell the XO to, for that task. The worker does it
through your forge's CLI.

## Contributing

```bash
shellcheck -x -S warning bin/chartroom lib/*.sh lib/backends/*.sh install.sh scripts/*.sh test/stub-agent test/windows-smoke.sh test/fakes/*
bats test/                 # no herdr/tmux/cmux/claude/codex needed: fakes and a stub agent
CHARTROOM_TEST_REAL_CHROME=1 bats test/pages.bats   # also print one page with a real Chrome (opt-in: the rest use a fake)
scripts/privacy-gate.sh    # no personal data in tracked files
claude plugin test mods/crew-view   # the Claude Code mod's tests (verified on Claude Code 2.1.302 and 2.1.303)
```

Maintainers: merge by fast-forward pushing `main` from a local clone whose commits use the
GitHub noreply identity as both author and committer. Never merge through the GitHub web UI:
squash, rebase and merge-commit merges all stamp the merging account's name and primary email
on the commit, which the privacy gate (rightly) rejects on `main`. The PR shows as merged once
its commits land on `main`.

## License

MIT. See [LICENSE](LICENSE).
