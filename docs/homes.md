# Several homes on one machine

One machine can carry several homes, each with its own XO and crew. This page covers making them, and how their XOs talk to each other.

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
there; this home keeps a copy in its own `relays/outbox.ndjson`. The relay rings the other home's
`chartroom watch` (its doorbell, under [the contract](../README.md#state-format-and-event-protocol-the-contract)),
so its XO session gets a wake at once, the same way it hears from its workers:

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
