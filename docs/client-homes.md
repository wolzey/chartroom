# Client homes: one brain

A **client home** is a home whose records live on another machine, the **brain**, and whose every
chartroom command runs there over ssh. You keep talking to an XO on your laptop as before. The
tasks, briefs, plans, inbox, rulings and artifacts are the brain's, and its workers run there.
When you sit at the brain and open the same home, nothing has changed.

This is step 1 of a five-step design:

1. **forwarding mode** (this document);
2. migrating the laptop's homes to the brain;
3. a conn lease and on-demand resident XOs on the brain;
4. remote dispatch to every node (docs/multi-machine.md);
5. offline local mode with reconnect sync.

Step 1 forwards, keeps a copy of the records here, and reports a brain it cannot reach. It never
moves records, places work, or works offline.

```
 laptop: XO session in ~/chartroom/acme           brain: ~/chartroom/acme (the record)
   chartroom <cmd> ──ssh (one ControlMaster)──▶  chartroom brain gate ──▶ chartroom <cmd>
   ~/chartroom/acme/ (a copy at the same paths) ◀── rsync (pull only) ───  tasks/, inbox.md, ...
   edits to the copy ──── put (applied by the brain if unchanged) ──▶
   watch --once ◀── wakes, then "end"; the client acks; the cursor moves ──
   dashboard open ── asks the brain for its app's address ──▶ opens https://<brain>.<tailnet>.ts.net/ here
```

## Making a home a client

```bash
cd ~/chartroom/acme           # an empty home here; the brain has a registered home "acme"
chartroom brain link desk   # ssh target of the brain; --as NAME if it is named differently there
chartroom brain status        # contact, the copy, pending edits, attach
chartroom brain fetch tasks/<id>/pane.log          # one file the copy leaves out
chartroom brain git <id> log --oneline main..HEAD  # read-only git in a task's worktree there
chartroom brain unlink        # local again (the copy stays, as a snapshot)
```

- **The marker.** `CHARTROOM_BRAIN=<ssh target>` in the home's **own** `config`, and nowhere
  else. An environment variable or the machine-wide config file would turn every home, and every
  worker's shell, into a client. Homes move one at a time.
- **`brain link` refuses a home that has any task.** Moving records is the migration (step 2).
- **The brain finds the home by its registered name,** `CHARTROOM_BRAIN_HOME`, which defaults to
  this home's registered name here, else its directory name. The client never sends a path. The
  brain refuses a name it has not registered, and a home that is itself a client ("a brain never
  forwards").
- **Paths are the brain's.** With the same user and the same `~/chartroom/<name>` layout on both
  machines (the setup this design assumes), they are identical, so every printed path opens here.
  `doctor` and `brain status` warn when they differ.

| Setting (the home's `config`) | Meaning | Default |
|---|---|---|
| `CHARTROOM_BRAIN` | the brain's ssh target; makes the home a client | unset |
| `CHARTROOM_BRAIN_HOME` | the home's registered name on the brain | this home's name |
| `CHARTROOM_BRAIN_BIN` | chartroom on the brain | `chartroom`, after `CHARTROOM_RADAR_REMOTE_PATH` |
| `CHARTROOM_BRAIN_KEY` | an ssh identity (for a forced-command key, below) | ssh's default |
| `CHARTROOM_BRAIN_HC_MACHINE` | the brain's name in this machine's `hc machine ls` | the one whose target is `CHARTROOM_BRAIN` |
| `CHARTROOM_BRAIN_CONNECT_TIMEOUT` | ssh's ConnectTimeout, seconds | 5 |
| `CHARTROOM_BRAIN_OUTAGE_SECONDS` | how long `watch` waits before it says the brain is away | 60 |

## What runs where

| Class | Commands |
|---|---|
| on the brain | `new`, `dispatch`, `worktree`, `steer`, `stop`, `park`, `accept`, `close`, `peek`, `show`, `resolve`, `status`/`ls`, `board`, `todo`, `inbox`, `relay`, `rule`, `focus`, `event`, `listen`, `project`, `init`, `sweep`, `radar`, `nodes`; `--all-homes` (the brain's homes) |
| on the brain, with a part here | `watch`, `attach`, `dashboard`, `artifact open/copy/export/pdf/add <file>`, `rule import <map>`, `doctor` |
| here | `version`, `help`, `homes`, `node probe/init`, `install-skills`, `brain …` |
| refused | `join`, `hook`: a session joined from this machine would be a worker here, with liveness and hooks read on the brain. Join it on the brain until remote dispatch exists |

A command from a client runs in an ssh session on the brain, outside its login session, where a
Mac's keychain is locked. So the gate marks every runner that would start a worker in that
session as unavailable:

- `headless` and `command` are always refused;
- `tmux` is refused unless its server already runs;
- `hc` and `herdr` are fine, because their servers already run in the login session and hc
  never starts a core.

Automatic fallback then lands on hc or herdr. An explicit `--backend headless:claude` fails loudly
instead of starting a worker that cannot log in. Steering a running headless or command worker is
refused the same way.

## The wire

```
ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    -o ControlMaster=auto -o ControlPath=<runtime dir>/ssh/%C -o ControlPersist=600 \
    -- <target> 'PATH="<CHARTROOM_RADAR_REMOTE_PATH>:$PATH" exec <brain bin> brain gate'
stdin: {"v":1,"verb":"exec","home":"acme","argv":[...],"client":{"machine":...,"pid":...,"session":...},
        "env":{"CHARTROOM_HARNESS":"claude"},"token":"<brain epoch>"}
       then the command's own stdin (only for artifact add - and relay ... -), or an upload's tar
```

- **The shell line is constant.** It holds a validated PATH prefix and a validated binary path,
  and zsh and bash read it the same way. Arguments travel only in the JSON header. The gate
  decodes them into an array and runs chartroom with it: no `eval`, no word splitting.
- **Only `CHARTROOM_HARNESS` comes from the client.** It is a fact about the client XO: the
  `subagent` backend runs in the client's own session.
- **The gate's framed lines.** It writes control lines starting with ASCII RS (`\036`) to stderr,
  and the client strips them:
  - `CRB hello <protocol> <version>`: the gate ran;
  - `CRB home <path>`;
  - `CRB sync <token> all|-|[home] <id>...`: what in the copy changed since the client's last
    token, on the brain's clock.
- **Exit codes** pass through exactly (124, 1, …).
- **Exit 75 before the hello:** "the brain is unreachable … nothing was run".
- **Exit 75 after the hello** (the link dropped mid-call): "may or may not have taken effect".
  The message names how to check.
- **Exit 76:** the brain answered but refused: an unregistered home, another protocol, or a
  command a client may not run.
- **The ControlMaster socket** sits under the doorbell's runtime dir (short, ours, mode 700),
  because macOS caps a socket path at 104 bytes.

**Verbs:**

| Verb | What it does |
|---|---|
| `hello` | the protocol, version and home path |
| `exec` | runs a forwarded command (refuses `homes add/rm`, `init NAME`, `node`, `install-skills`, `brain`, `join`, `hook`, a plain `watch`, and an `attach` without `--prepare`) |
| `put` | applies an edit (below) |
| `cat` | reads one file inside the home (never `config` or the dashboard's files) |
| `git` | read-only git in a task's worktree |
| `watch1` | one acked watch round |
| `rsync` | the server side of a pull, `--server --sender` only, of a registered home's path |

Step 3's seam is `gate_client_seen`, which every call passes through with its client (machine,
pid, XO session). The conn lease and the client XOs' heartbeats will be recorded there.

## The copy

A copy of the brain's records sits **at the same paths** in the client home, so every path the
brain prints (a brief, a plan, a report) opens here, in a Read tool or in a link the commander
clicks.

**What the copy holds:**

- the home's own files, but not `worktrees/`, `config` or dotfiles (`.changed` is kept, for the
  crew views);
- each task's top-level files, plus `artifacts/` and `messages/`.

**What it leaves out:**

- every other directory inside a task, because workers leave clones and `node_modules` there;
- `pane.log`, `hooks.log`, launchers, Claude settings, locks and temp files;
- any file over 4 MB.

`chartroom brain fetch <path>` brings one file it leaves out. The rsync filter is `brain_filter`
and the matching local walk is `BRAIN_WALK_PL` (lib/brain.sh).

**Keeping it fresh:**

- Every gate call ends with the sync trailer, and the client then pulls only the tasks it names
  (about 0.1 s).
- `doctor` and `init`, which the XO runs at session start, do a full pull. `brain pull` forces
  one.
- Wakes pull their task before they print.

**Edits go to the brain; nothing syncs two ways.** The XO edits a brief, `inbox.md`,
`commander.md` or a note in the copy, as it always has. Before the next forwarded command, the
client finds the files changed since its last pull (against `.brain/manifest`) and proposes each
to the brain as a `put` with the version it pulled (mtime and size, or "new"):

- The brain applies the put only if its own file is still that version.
- Otherwise the edit is kept as `<file>.client-conflict-<time>`, the brain's version comes back,
  and the command does not run.
- The brain never takes a put of a record chartroom owns:
  - `config`, `rulings.log`, `focus.json`;
  - `relays/`, `worktrees/`;
  - a task's `meta.json`, `events.log`, `artifacts/` or `messages/`;
  - logs and launchers;
  - a dotfile, a symlink, anything outside the home, or a file over 4 MB.
- A refused edit stays as `<file>.client-refused-<time>`.

That keeps the brain the only writer of every home, and it is the shape step 5's queued actions
need: a queued put is the same verb, replayed only if its target is unchanged.

## watch

`watch --once`, the XO's loop in Claude Code, is delivered **at least once**:

1. The gate runs `watch --once` against a private copy of the home's `.watch-cursor` and streams
   the wakes, then `end <rc>`.
2. The client pulls the tasks they name, prints them, and answers `ack`.
3. Only then does the gate move the cursor. A link that drops before the ack replays the same
   wakes on the next call.
4. A heartbeat every 15 s, and the client's stdin closing, end a gate whose client is gone, so no
   watch is left running on the brain (`sweep` remains the backstop).

The home's cursor is shared with an XO at the brain, so two live XOs of one home split its
wakes, as two `--once` loops on one machine already do. Step 3's conn lease settles who handles
them. A streaming `watch` is the same in a loop, against a cursor of the client's own that starts
at the end of each log.

**When the brain is away** (the lid closes, Wi-Fi drops):

- The client watch reconnects quietly, with backoff.
- After `CHARTROOM_BRAIN_OUTAGE_SECONDS` (60) it wakes once:
  `[brain] desk unreachable since <T>: <ssh's message>; this home lives there …`.
- When the brain is back it wakes once more: `[brain] desk back after 12m`.
- Step 5's "switch to local mode?" question goes where the first line is printed.

## attach, peek, dashboard, artifacts

- **`peek`** runs on the brain (hc and herdr answer over ssh).
- **`attach <id>`:**
  1. The brain runs `attach <id> --prepare`: it resumes a parked worker and prints where the
     worker runs, as JSON, without showing anything on the brain's screen.
  2. This machine shows the worker:
     - for hc: through its own hc machine link (`hc machine ls`, asked only of a core that already
       answers): `herdr-app do agent.focus --terminal <machine>/<t>`, else a Herdr tab running
       `hc attach <machine>/<t>`, else `hc attach` in a terminal;
     - for herdr: `herdr --remote <target>`;
     - for tmux: `ssh -t … tmux attach`;
     - cmux is not shown from here.
- **`dashboard open` and `artifact open`:**
  - The brain prints its app's address (its Tailscale Serve URL, with `#/p/...` for a page),
    and opens no browser there. The client opens that address here, so this machine must be on
    the tailnet. Nothing is tunnelled, and nothing new listens on this machine.
  - The brain's app must be running and on Tailscale Serve; otherwise the brain says why
    (`chartroom app doctor` there says what it needs).
  - A brain that answers with its own loopback address (`http://127.0.0.1:...`) gets a clear
    error, because only its own browser could open that: it runs an older chartroom (the retired
    web dashboard), or its app runs without Tailscale Serve. Update chartroom there, then run
    `chartroom app doctor` there.
  - `dashboard url` and `dashboard status` print the brain's app address, or why there is none.
  - `dashboard stop` ends only a tunnel an older chartroom kept here for the retired dashboard
    (`.brain/tunnel`); `brain status` and `sweep` say when one still runs.
- **`artifact copy`** copies to this machine's clipboard.
- **`artifact export`/`pdf`** are made on the brain and written here.
- **`artifact add <file>`** uploads the file, with the images beside it that it names.

## Security

- **What a client can run.** The gate serves only homes registered on the brain and only the
  verbs above, with validated arguments. Without more, the client's ssh key is still a full shell
  on the brain, so the gate is about correctness, not containment.
- **To contain it, pin a dedicated key** (`CHARTROOM_BRAIN_KEY`) in the brain's `authorized_keys`:

  ```
  command="chartroom brain gate",no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAA... client
  ```

  The gate then reads `SSH_ORIGINAL_COMMAND` (the rsync pulls come through it too). The client
  no longer forwards a port, so the key needs no `permitopen` (`no-port-forwarding` here is not
  tried). The hc machine link keeps its own key, since `attach` through hc needs a pty.
- **Data.** Credentials never move. The copy holds records and artifacts only: no worktrees,
  `config` or dotfiles.

## Not built here

- moving existing records (step 2);
- the conn lease and resident XOs (step 3);
- placing work on other machines (step 4);
- offline local mode and reconnect sync (step 5).

The copy (a snapshot at the home's own layout), `.brain/` (last contact, outage start, token,
manifest), `brain_route` and `brain_unreachable` are the seams those steps build on.
