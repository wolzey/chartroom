# Build your own fleet

A fleet is one always-on machine, the **brain**, that holds your homes and runs your crew. Around
it are a laptop you talk to the XO from, other Macs that report to the brain, and your phone.
This guide sets one up from scratch, with the network we run ourselves: Tailscale.

Everything here past a single machine is **experimental**. It works and has tests, and its
commands and settings may still change in a minor release. Start with the
[Quickstart](../README.md#quickstart) on one machine. Come back when you want a second.

```
  laptop (client home)          ── ssh ──▶  brain: an always-on Mac
    XO session, a copy of the                 homes (~/chartroom/<name>), the workers,
    records                                   the app on 127.0.0.1:4516
                                                   ▲            ▲
  phone ── HTTPS (Tailscale Serve, your login) ─────┘            │ HTTPS heartbeats,
                                                                 │ every 15 s
  other Macs (devices): chartroom's device agent ────────────────┘ (the brain never reaches out)
```

What each part does today:

| Part | What it gives you | Status |
|---|---|---|
| Brain | one place where the records live and the workers run | stable (it is just a machine with homes) |
| Client home on a laptop | the same XO conversation from the laptop; every command runs on the brain over ssh | experimental, step 1 of 5: it reports a brain it cannot reach, and has no offline mode yet |
| Devices | other machines show on the brain's Fleet and in `chartroom nodes` with their load, memory, disk and tools | experimental: a task you pin to a device with `--node` runs there, its record kept on the brain; nothing spreads work by itself yet |
| The app on your phone | Needs me, the board and the fleet, answered from anywhere on your tailnet, with push | experimental |
| Permission cards | a Claude worker's permission prompts reach you as cards instead of waiting in a terminal | stable, on for every Claude worker |

## 1. The network: Tailscale

We recommend [Tailscale](https://tailscale.com) on every machine and your phone, all signed in
to the same account. It gives you three things chartroom relies on:

- **MagicDNS names** as ssh targets (`desk`, `mini`), so a client home and `chartroom nodes`
  reach each machine by a name that does not change when its address does.
- **Tailscale Serve** puts the brain's app on HTTPS (which the app and push need) at
  `https://<brain>.<tailnet>.ts.net`, and adds the signed-in person to each request
  (`Tailscale-User-Login`). The app lets in only you.
- **Your tailnet's access rules** decide who can reach the brain at all.

Set up once, in the Tailscale admin console:

1. Keep MagicDNS on (the default) and turn on **HTTPS certificates** (DNS page). Serve needs them.
2. If you share the tailnet with anyone, limit who reaches the brain. A minimal policy, for
   `you@example.com` and machines you tagged `tag:fleet`:

   ```json
   {
     "tagOwners": { "tag:fleet": ["you@example.com"] },
     "acls": [
       { "action": "accept", "src": ["you@example.com"], "dst": ["tag:fleet:22,443"] },
       { "action": "accept", "src": ["tag:fleet"], "dst": ["tag:fleet:443"] }
     ]
   }
   ```

   This is an example, not a policy chartroom tests. Port 22 is ssh, used by client homes.
   Port 443 is the app, and the devices' heartbeats. Tag only the brain and the devices, never
   the phone or laptop you open the app from: a tagged machine carries no user login, and the
   app lets in only yours.

Then check from the laptop that the brain answers ssh with no prompt. Client homes use ssh in
batch mode and never ask for a password:

```bash
ssh -o BatchMode=yes desk true && echo ok
```

Use a key in your ssh agent, or Tailscale SSH. Use the same user name on every machine. The
guide assumes the same `~/chartroom/<name>` layout everywhere, so a path the brain prints opens
on the laptop too.

### Without Tailscale

| Part | Without Tailscale |
|---|---|
| Brain, homes, workers | Work. Nothing on one machine needs a network. |
| Client home on a laptop | Works over any ssh you can reach with no prompt (a LAN, a VPN, a jump host). |
| The app off the brain | Does not work. The app trusts only Tailscale Serve's login header. `--no-auth` serves this machine's own browser at 127.0.0.1 and nothing else. |
| Devices | `device join` takes only an `https://` brain URL, or `http://127.0.0.1` on the brain itself. Another HTTPS reverse proxy in front of the app could carry the device routes, which a device token alone opens, but nobody has tried it. |
| Phone push | Needs the app, so needs Tailscale. |

## 2. The brain

Pick a Mac that stays on and awake, plugged in: a desktop, or a laptop that never leaves the
desk. Set it never to sleep in System Settings (Energy), and stay logged in at its screen. The
device agent and the login keychain live in the login session.

```bash
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash
chartroom doctor                   # the backends that can run here; the "auto:" line is the default
chartroom install-skills --claude  # Codex or Gemini: --agents
```

Make a home for each company or client you work for (or keep the one `~/.chartroom` the
installer made):

```bash
CHARTROOM_HOME=~/chartroom/acme chartroom init --name acme   # its own workspace
chartroom homes                                               # every home on this machine
cd ~/chartroom/acme && claude                                 # that home's XO, here on the brain
```

The app and client homes find a home by its registered name. `init --name` registers it.
To register the default `~/.chartroom` too, run `chartroom homes add main ~/.chartroom`.

## 3. The app, and your phone

On the brain, name the one person the app lets in: your Tailscale login, in
`~/.config/chartroom/config`. Then start it:

```bash
mkdir -p ~/.config/chartroom && echo 'CHARTROOM_APP_USER=you@example.com' >> ~/.config/chartroom/config
chartroom app serve --daemon      # 127.0.0.1:4516; it needs at least one registered home
chartroom app doctor              # the server, who may come in, push, and the Serve command to run
```

On macOS, `chartroom app service on` runs it as a LaunchAgent instead, so it starts at login and
comes back after a reboot (`app service off` undoes it).

Put it on your tailnet, once. It is the standard Tailscale CLI. On a Mac with the App Store
Tailscale, the binary is `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

```bash
tailscale serve --bg --https=443 http://127.0.0.1:4516
tailscale serve status            # https://<brain>.<tailnet>.ts.net (tailnet only) → 127.0.0.1:4516
```

On the phone, open `https://<brain>.<tailnet>.ts.net/` with Tailscale on, and add it to the home
screen (Safari: Share, Add to Home Screen; Chrome: Install). Turn on notifications from the app's
menu. Notifications for a **closed** app need Web Push, which is off by default:

```bash
echo 'CHARTROOM_APP_PUSH=on' >> ~/.config/chartroom/config   # needs node on the brain
chartroom app stop && chartroom app serve --daemon
chartroom app doctor                                         # "push: on (node v…)"
```

Push goes through the push service of your browser's maker (Apple, Google, Mozilla),
encrypted end to end. The XO answers first: a worker's card reaches your phone only if it is
still open after two minutes (`CHARTROOM_APP_PUSH_HOLD`). On iPhone, push reaches only the
installed app, on iOS 16.4 or later. [docs/app.md](app.md) has the details.

## 4. A laptop as a client home

A client home keeps talking to an XO on the laptop, while its records and workers stay on the
brain. Every chartroom command there runs on the brain over ssh.

```bash
# on the laptop, after the same install.sh
CHARTROOM_HOME=~/chartroom/acme chartroom init --name acme   # an empty home, the same name as on the brain
cd ~/chartroom/acme && chartroom brain link desk             # desk: the brain's ssh target
chartroom brain status                                       # contact, the copy, pending edits
cd ~/chartroom/acme && claude                                # the XO, on the laptop
```

- `brain link` refuses a home that already has tasks: moving records is not built yet. Link a
  new, empty home.
- The brain finds the home by its registered name (`--as <name>` when it differs there).
- `chartroom dashboard open` on the laptop opens the brain's app at its tailnet address
  (step 3), so the laptop must be on the tailnet. Nothing is tunnelled.
- `chartroom brain unlink` makes the home local again. The copy stays, as a snapshot.

[docs/client-homes.md](client-homes.md) has the wire, the copy, and what runs where.

## 5. Other Macs as devices

A device reports to the brain. The brain never reaches out to it, holds no key to it, and asks
it to open no port. On the brain, make a one-time code:

```bash
chartroom node init                  # once: the brain is a node too
chartroom node add --name mini       # a code, single use, valid for 10 minutes
```

On the device:

```bash
curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash -s -- --device
chartroom device join https://<brain>.<tailnet>.ts.net <code>
chartroom device status              # joined …; agent: running; last: ok
```

`install.sh --device` makes no home: a device runs only the work the brain pins to it. On macOS, `join`
loads a LaunchAgent (`dev.chartroom.device`), and the agent makes the join itself, in your login
session, so the token goes into the login keychain. That works from an ssh session too, as long
as you are logged in at the device's screen. Back on the brain:

```bash
chartroom nodes                      # every machine: contact, load, memory, disk, tools
```

The app's Fleet tab shows the same.

### Work on your devices

`chartroom dispatch` sends each new task to the machine with the most room, the brain included.
Each machine has two limits, the share of its CPU and of its memory in use above which it takes
nothing new; `chartroom node limits` shows them all, and sets one:

```bash
chartroom node limits                 # use against limits, and whether each takes work
chartroom node limits mini 80/70      # at 80% CPU or 70% memory in use, mini takes no new task
chartroom node limits mini off        # mini takes no new work at all (on: it does again)
chartroom node limits mini --clone on # mini may clone a GitHub project it lacks, and set it up once
chartroom dispatch <id> --dry-run     # where a task would go, and why
```

A device needs the project checked out inside its node's project roots, and hc with Claude Code,
Codex or agy signed in: only hc:claude, hc:codex and hc:agy run on a device (hc:agy only where the
device's own chartroom knows agy, and agy is signed in there). A task that needs more of a machine
says so (`new --needs docker`, or `needs=docker` on the project's line in `projects.md`), and never lands on
one without it. On the device, once:

```bash
chartroom node init --force --project-roots ~/src   # the directories that hold your checkouts, colon-separated
```

`device join` wrote that node file with no project roots, so `--force` rewrites it; it keeps the
device's id, and the brain's `chartroom nodes` then counts its checkouts.

To choose the machine yourself, pin it:

```bash
chartroom new --project ~/src/app --title "…" --backend hc:claude --node mini
chartroom set <id> node=here                 # before dispatch: run it on the brain (node=mini pins it again; node=any: wherever there is room)
chartroom dispatch <id>                      # the device runs it; its events, report and cards come back here
```

The record stays on the brain, so the board and the app show the task as any other, with its
machine, and `status` shows its runner as `node:claude`. Steer, stop, peek and `close` go to the device over its connection, and
`close` brings the branch to the brain before the device deletes its copy. A running task never
moves. A pinned one whose device is away waits for it. When no machine has room, dispatch says so
with each one's numbers, and the task stays undispatched (`--over-limit` sends it all the same).
[docs/multi-machine.md §12](multi-machine.md#pinned-dispatch-built) has the protocol.

## 6. Permission cards

There is nothing to install. Every Claude worker chartroom launches carries the hooks, on every
backend. The policy answers routine work inside the worker's worktree, and whatever its brief
grants. Anything else becomes a card: it wakes the XO, shows in the app, and waits up to 15
minutes (`CHARTROOM_PERMIT_WAIT_SECONDS`) before the call is denied.

```bash
chartroom permit ls                          # open cards
chartroom permit answer <p-id> once          # (or <task>/<p-id>) or: always (this pattern, until the task closes), deny --note "…"
chartroom permit grant <task-id> push-branch # what a task may do without asking: push-branch, open-pr, merge-auto, comment-pr, prod-read
```

The XO passes on your answers. It never answers a card on its own judgment, and a worker's own
shell refuses to run `chartroom permit answer` or `permit grant`: you or the XO run them, in the
XO's session or a terminal of your own. In the app, the
card has Allow once, Always for this task, and Deny. Codex workers are not covered yet.
[docs/permits.md](permits.md) has the policy and the audit trail.

## 7. Day two

### The laptop leaves, and comes back

Nothing to do. While the brain is out of reach, every command in the client home fails and says
so, and runs nothing:

```
chartroom: the brain (desk) is unreachable (last contact …): ssh: connect to host desk port 22: …
This home lives there; nothing was run. Offline mode is not built yet
```

The workers keep running on the brain. The XO's `watch` reports the outage once, and again when
the brain is back. The next command picks up where it left off. `chartroom brain status` shows
`UNREACHABLE since …` while it lasts.

### A device's key: rotate, revoke, rename

```bash
chartroom node rotate mini           # a new token on its next heartbeat; the old one works 10 more minutes
chartroom node revoke mini           # its next request gets 401 and its agent stops; nothing on it is touched
chartroom node add --replace mini    # a code that enrols that machine again; the old entry is revoked when it joins
chartroom node rename mini mini-2    # names are display only; the old one stays an alias
```

On the device itself, `chartroom device leave` stops the agent and deletes the token there.
Revoke it on the brain as well.

### A second home

```bash
# on the brain
CHARTROOM_HOME=~/chartroom/globex chartroom init --name globex
# on the laptop, if it should be a client of it too
CHARTROOM_HOME=~/chartroom/globex chartroom init --name globex
cd ~/chartroom/globex && chartroom brain link desk
```

The app shows a newly registered home within a minute, with no restart. Homes, and how their
XOs talk to each other: [docs/homes.md](homes.md).

### Updating

Re-run the installer on the brain and the laptop (it fast-forwards the checkout), then
`chartroom doctor`. On the brain, restart the app with `chartroom app stop && chartroom app serve --daemon`.
Devices follow the brain over their connection: `chartroom node update --all` on the brain moves
each one to the brain's commit, and `chartroom node ping mini` checks the round trip.
`chartroom brain status` on a laptop shows the brain's chartroom version.

### Where the logs are

| What | Where |
|---|---|
| A task: its events, and a headless or command worker's output | `<home>/tasks/<id>/events.log`, `<home>/tasks/<id>/output.log` |
| The app server (and push) | `~/.config/chartroom/app.log`, beside the config file |
| A device's agent | `~/.local/state/chartroom/device/agent.log` on the device (`$XDG_STATE_HOME`) |
| What a client home last heard from the brain | `chartroom brain status` |

## Several machines: nodes

A **node** is a machine that can take crew work: this one, any device that reports to the brain,
and any other you reach over ssh. `chartroom nodes` reads what each has room for and what it can
run; `dispatch` places work by it ([placement](multi-machine.md#5-placement)).

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

- **Which machines.** An enrolled device's row is its last heartbeat (below). Machines not
  enrolled come from `CHARTROOM_NODES` (`label[=ssh-target] ...`, or `none`), else the radar's
  list: `CHARTROOM_RADAR_MACHINES`, else herdr's enabled saved machines. This machine is always
  first. `--ssh` reads the ssh list alone.
- **A node opts in.** `chartroom node init`, run on that machine, writes its limits to
  `~/.config/chartroom/node` (`CHARTROOM_NODE_CONFIG` moves it): the share of its CPU and memory that may
  be in use, whether it may work on battery, the priority its workers will get, and where
  its project checkouts are. It makes no home: a node has no XO. Without that file a machine is
  listed as "not a node" and will never be given work. `CHARTROOM_NODE_ACCEPT=off` in it
  withdraws the machine at once.
- **Read-only, over ssh.** For a machine read over ssh, the only thing that runs there is the
  probe itself, `lib/nodeprobe.sh`, sent over `ssh -o BatchMode=yes <target> 'bash -s'`: it needs
  nothing installed there (not even chartroom), writes nothing, and runs on a Mac's own bash 3.2.
  Each machine is probed side by side, and one that does not answer within
  `CHARTROOM_NODES_TIMEOUT` seconds (45) reads `timeout` (its ssh is ended; the probe there stops
  by its own bounds, at most about 90 seconds). ssh's own failures read `unreachable`, or `auth`
  when ssh would need you (a key, a host key, a Tailscale check).
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

## Devices: machines that report to the brain

A device runs chartroom's device agent, which sends its probe to the brain's app server every 15
seconds (setting one up: [step 5](#5-other-macs-as-devices)). The brain never reaches out to it,
holds no key to it, and asks it to open no port. Its row in `nodes` and Fleet is its last
heartbeat.

- **Its own revocable token.** Only the token's sha256 is kept on the brain. On macOS the agent is a
  LaunchAgent in the login session, and the token is in the login keychain; elsewhere a 0600
  file. A token opens that device's routes only, never the app.
- **Commands** reach a device by long-poll: its agent holds one request open to the brain's app
  server and runs what comes, one at a time; the brain still opens nothing to it. That carries
  pinned work ([Work on your devices](#work-on-your-devices)), steer, stop, peek and close, and
  `node update`, which fast-forwards the device's chartroom to the brain's commit (only along its
  own `origin/main`) and restarts its agent onto it.
- **Status:** `online`, `stale` (no heartbeat for 45 s), `lost` (10 minutes, counted only while
  the brain's app server is up), `new`, `revoked`. `chartroom doctor` lists the devices on the
  brain, and the join and the agent on a device.

The protocol is in [docs/multi-machine.md §12](multi-machine.md#12-devices-the-brain-never-reaches-out).

## The fleet radar

`chartroom radar` lists every open task on every home of one machine, in six sectors by state,
plus each home's XO (from herdr, marked "untracked: no events"). It is a terminal view, and the
Herdr app's Tasks panel reads its JSON. The app's Fleet shows every session on every machine.

```bash
chartroom radar                             # this machine: each sector, then its tasks
chartroom radar --json                      # one machine's records
chartroom radar --machine mini --ssh mini   # another machine's, read-only over ssh
chartroom radar machines                    # the machines it reads, and how they were found
```

| Sector | States | |
|---|---|---|
| **Decision** | `decision` | asked for your call |
| **Blocked** | `blocked`, `awaiting-input` | the worker said it cannot proceed, or the agent is stopped at a permission or question prompt |
| **Adrift** | `overdue`, `stopped-silent`, `lost` | waited past its window; stopped without reporting; its session is gone |
| **Under way** | `working` | working (marked uncertain when its backend could not be checked) |
| **Holding** | `waiting` | its own `waiting` report, inside its window; or, marked *inferred*, a last message that says it waits on someone |
| **Docked** | `review`, `done`, `failed` | a report to read (`review`: a worker's done, awaiting your accept or close); a failure |

Telling *blocked* from *waiting* is the point: a worker waiting inside its own window needs
nothing, and one that is blocked needs someone.

**Machines.** Every record names its machine.

- **This machine.** Its label is `CHARTROOM_MACHINE_NAME`, set in the environment, the home's
  config or the config file. Without it, the label is the host name. This machine's homes are
  read with the same `status --json` the CLI uses.
- **Other machines.** `radar machines` lists them: `CHARTROOM_RADAR_MACHINES`
  (`label[=ssh-target] ...`, or `none`), else herdr's enabled saved machines (`herdr machine
  list`). One is read over `ssh -o BatchMode=yes` with `chartroom status --json --all-homes`, and
  its XOs come from `herdr --machine <m> agent list`.
- **Read-only, always.** Nothing ever runs on another machine except that status call, its
  `chartroom peek <id>`, and `cat` of one of the task files (`brief.md`, `report.md`, `plan.md`,
  `final.md`, `events.log`). Each is built only from ids and home paths that machine reported.
  (`chartroom nodes` adds one more, also read-only: its probe script, [above](#several-machines-nodes).)
- **An older chartroom** ignores `--all-homes` and answers for its default home only. The radar
  tells this from the shape of the answer, since the version string may not have changed, and
  says so.
- **An unreachable machine** reads `unreachable`, with ssh's own message.

A state the table does not know lands in Adrift, never hidden. `drafting` and closed tasks are not
listed.

## How this guide was checked

Each command in steps 1 to 7 was run before it went in, except those named at the end of this
section. The reference sections after Day two (nodes, devices, the fleet radar) moved here from
the retired dashboard's page and were not run again for this guide. Most ran in throwaway homes on one Mac: a brain,
a device and a laptop home, each with its own empty `HOME`. The app server ran on a spare port.
The device kept its token in a 0600 file and loaded no LaunchAgent (`CHARTROOM_KEYCHAIN=none`,
`CHARTROOM_LAUNCHCTL=none`, then `chartroom device run --once`). The laptop reached the brain
through the test suite's loopback ssh. The keychain, LaunchAgent and Tailscale Serve steps were
checked, read-only, on a real fleet: a brain whose app is on Tailscale Serve with push on, and
two Macs joined as devices, each running its agent with its token in the keychain. The
admin-console steps, the phone's own steps and the access-rule example were not run. Neither
were `chartroom dashboard open` from a client home (which now opens the brain's app at its
tailnet address) or turning push on: push was
only read, already on, on the real fleet. Pinning (`node init --force --project-roots` on a joined
device, `new --node`, `set node=here`) was run in the throwaway homes. `dispatch` to a device,
`node update` and `node ping` need the device's agent running as a service with hc signed in, so
they were not run here: they ran on a real device in the change that built them, and
test/device.bats covers them. `app service on` loads a LaunchAgent, so it was not run either; no
test covers it. The
`chartroom permit` commands were not run by hand either: chartroom's guard refuses them to a
worker, and the test suite (test/permit.bats, test/app-permit.bats) runs them instead.
