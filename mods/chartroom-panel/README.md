# chartroom-panel

A small Claude Code mod (function hooks; built and verified on Claude Code 2.1.312) that shows
the commander's live Chartroom fleet in a **read-only pane beside the chat**, the sibling of the
Pi panel (`adapters/pi-panel`). Completed work drops off; everything still open stays, with the
tasks needing the commander's input set apart from the ones being worked on.

```
┌ Chartroom ─────────────────────────────┐
│ Chartroom · 5 unfinished                │
│ Live · updated 9:41:12 AM               │
│                                         │
│ 108a Autoscale claims-svc workers…      │
│   decision · monolog                    │   ← yellow: needs you
│ 7c2f Passkey login flow                 │
│   working · shop                        │   ← green: being worked on
│ 05f6 Busy-season capacity readiness     │
│   stopped silent · monolog              │   ← dim: quiet/attention
│ …                                       │
│ 1–5 of 5 · page 1/1                     │
│ /chartroom-panel next|prev|off          │
└─────────────────────────────────────────┘
```

The frame, the title and the right-hand dock are the engine's: Claude Code docks a pane beside
the transcript in fullscreen (from 110 columns), so the "right-anchored bordered box" is the dock
itself — the mod draws the contents, never its own border. The pane opens with a **transparent
background** (`$.ui.open({ backgroundColor: 'transparent' })`), so the whole body — header through
footer, and the empty area below the rows — blends with the chat transcript instead of sitting in
the engine's default grey docked-pane surface. Transparent is theme-safe: it shows the terminal's
own background in a dark or a light theme alike, with no hardcoded colour to break either.

## What it shows

The one source of truth is `chartroom status --json`. The panel reads it and nothing else; it
never reads a task file, derives state of its own, or writes anything.

- **Header** (bold, accent): `Chartroom · N unfinished` — N is the count of visible tasks.
- **Status** (dim): `Live · updated H:MM:SS AM`, the local time of the last successful read. On a
  failure it reads `STALE: …` (the last tasks stay on screen) or, before the first read,
  `Unavailable: …`.
- **Each task, two lines**: `{short_id} {title…}` (short id in a subtle colour, title truncated
  to fit), then `{state} · {project}`, the state coloured by urgency:

  | states | colour | meaning |
  | --- | --- | --- |
  | `decision`, `blocked`, `awaiting-input`, `waiting-overdue` | yellow | needs you |
  | `working`/`running`, `drafting` | green | being worked on |
  | `stopped-silent` (shown `stopped silent`), `waiting`, `failed`, `lost` | dim | quiet / attention |
  | any other unfinished state | plain | kept visible, never dimmed away |

- **Footer**: `{first}–{last} of {total} · page {p}/{pages}`, then `/chartroom-panel next|prev|off`.

### Filtering (the heart of it)

A row is **hidden** when its `state` is `done` or `closed`, **or** its `closed` field is non-null
(a finished/closed row). It is **kept** otherwise — including a `state: decision` row whose worker
reports `live: done`, which is routine: the filter keys on `state`/`closed` and **never** on
`live`. An unfinished state the mod has never seen stays visible. There is no completed/history
section. (This is exactly the Pi panel's filter, so the two siblings hide and keep the same rows.)

## Activation & scope

Installed at user scope the mod loads in every Claude Code session but does nothing — no command,
no timer, no process, no pane — unless the session is **interactive**. When the working directory
is the configured Chartroom home (resolved through `chartroom doctor --json`) it **auto-shows**,
without taking the keyboard. A crew worker's session never auto-shows: it is skipped when
`CHARTROOM_TASK` is set or the path has a `worktrees` segment, and in any non-interactive (`-p`)
run. The home check reads two env vars and one file (`commander.md`) before it ever spawns
`chartroom doctor`, so an unrelated session costs nothing.

`/chartroom-panel` turns the panel on anywhere (manual activation away from the home is fine). It
never shadows the `/chartroom` skill command.

## Commands

```
/chartroom-panel                 toggle: open-and-focus when hidden, close when shown
/chartroom-panel toggle          same as the bare command
/chartroom-panel focus           open the pane and take the keyboard (never closes)
/chartroom-panel on | off        show / hide for the session (off also stops the refresh)
/chartroom-panel refresh         read the fleet now
/chartroom-panel next | prev     page through the tasks
/chartroom-panel pick <short_id> bring that task into the chat (see below)
```

The pane is never focused at the moment you type a command (the composer holds the keys then), so
the bare command can't "close a focused pane" — it closes a *shown* one and opens-and-focuses a
hidden one. To take the keyboard of a pane that is already shown (e.g. the auto-shown one), press
**ctrl+x tab** (the engine's own focus chord) or run `/chartroom-panel focus`. Closing the pane by
hand (the frame's ✕ or **ctrl+x x**) turns the panel off for the session, exactly as `off` does.

## Picking a task into the chat

`/chartroom-panel` hands the keyboard to the pane: the arrows walk the task rows and **Enter**
brings the highlighted task into the chat as the next prompt's focus — it pre-fills the prompt
with `/continue {short_id}` (the existing Chartroom continue skill) and stops there; nothing is
submitted, so the commander edits or adds before sending. **Esc** hands the keys back to the chat
and leaves the pane open; normal typing is never captured. If the prompt already holds a draft it
is never replaced — the `/continue` line is copied instead, with a note. (`pick <short_id>` does
the same from the command line.)

## Refresh, safety, resilience

The fleet refreshes every 5 seconds on a timer, with **no model call**, idle or streaming. Reads
are bounded (an 8 s timeout) and never overlap; turning the panel off stops the refresh work. The
mod **never runs `chartroom watch`** — that stream belongs to the XO's supervision. A
command-not-found, a timeout, a malformed payload or a transient failure all keep the last known
tasks on screen, marked `STALE`; an error is never drawn as an empty fleet.

## Install

Try it for one session without installing (from a checkout):

```bash
cd ~/.chartroom && claude --plugin-dir <checkout>/mods/chartroom-panel
```

Install it from the marketplace so it is there whenever you start the XO in your home:

```
/plugin marketplace add wolzey/chartroom   # once, if not already added
/plugin install chartroom-panel@chartroom
```

Choose the **user** scope. Reload a checkout after an edit with `/reload-plugins`.

The panel seats itself only when there is room: a pane opened unasked waits below 144 columns
(110 once you have opened it yourself), where `/chartroom-panel` still opens it. Widen the
terminal, or run the command, to bring it in.

## Develop

```bash
claude plugin validate mods/chartroom-panel
claude plugin test mods/chartroom-panel
tsc -p mods/chartroom-panel      # needs .claude-plugin/types/, which Claude Code lays at each load
```

Claude Code writes `.claude-plugin/types/` (the API declarations, git-ignored) when it loads the
mod from a folder it watches (`claude --plugin-dir`). Before that, copy the declarations the
`plugin-authoring` skill names into `.claude-plugin/types/claude-code.d.ts`.

`hooks/model.ts` holds the pure parts (the filter, the state→tone map, width-safe text and
paging), tested directly in `tests/model.test.ts`; `hooks/register.tsx` the hooks (activation, the
timer poll, the command, the pane), driven through the test kit in `tests/panel.test.ts`;
`types/index.d.ts` the `$.state` contract.

## Relationship to `crew-view`

`crew-view` is the full XO cockpit — a band above the prompt, a `/crew` board browser and the
todo list — and wakes on the `chartroom`/`captain` skill. `chartroom-panel` is deliberately
narrower: one read-only status pane that matches the Pi panel, auto-shows at the home, and reads
`chartroom status --json` rather than `board --json`. Install whichever fits; they share no
command name, so both can load, each drawing its own pane.
