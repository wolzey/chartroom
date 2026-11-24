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
    records, the dashboard tunnel             the app on 127.0.0.1:4516
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
| Dashboard from another device | Works on a LAN, bound to one address of the machine and opened with its access token. See [docs/dashboard.md](dashboard.md#on-the-network-other-devices). |
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
CHARTROOM_HOME=~/chartroom/acme chartroom init --name acme   # its own workspace and dashboard port
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
- `chartroom dashboard open` on the laptop opens the brain's dashboard through an ssh tunnel.
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
chartroom dispatch <id> --dry-run     # where a task would go, and why
```

A device needs the project checked out inside its node's project roots, and hc with Claude Code or
Codex signed in: only hc:claude and hc:codex run on a device. A task that needs more of a machine
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
chartroom permit answer <p-id> once          # or: always (this pattern, until the task closes), deny --note "…"
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
| The dashboard | `<home>/.dashboard.log` |
| The app server (and push) | `~/.config/chartroom/app.log`, beside the config file |
| A device's agent | `~/.local/state/chartroom/device/agent.log` on the device (`$XDG_STATE_HOME`) |
| What a client home last heard from the brain | `chartroom brain status` |

## How this guide was checked

Each command above was run before it went in, except those named at the end of this section. Most ran in throwaway homes on one Mac: a brain,
a device and a laptop home, each with its own empty `HOME`. The app server ran on a spare port.
The device kept its token in a 0600 file and loaded no LaunchAgent (`CHARTROOM_KEYCHAIN=none`,
`CHARTROOM_LAUNCHCTL=none`, then `chartroom device run --once`). The laptop reached the brain
through the test suite's loopback ssh. The keychain, LaunchAgent and Tailscale Serve steps were
checked, read-only, on a real fleet: a brain whose app is on Tailscale Serve with push on, and
two Macs joined as devices, each running its agent with its token in the keychain. The
admin-console steps, the phone's own steps and the access-rule example were not run. Neither
were `chartroom dashboard open` from a client home (its ssh tunnel) or turning push on: push was
only read, already on, on the real fleet. Pinning (`node init --force --project-roots` on a joined
device, `new --node`, `set node=here`) was run in the throwaway homes. `dispatch` to a device,
`node update` and `node ping` need the device's agent running as a service with hc signed in, so
they were not run here: they ran on a real device in the change that built them, and
test/device.bats covers them. `app service on` loads a LaunchAgent, so it was not run either; no
test covers it. The
`chartroom permit` commands were not run by hand either: chartroom's guard refuses them to a
worker, and the test suite (test/permit.bats, test/app-permit.bats) runs them instead.
