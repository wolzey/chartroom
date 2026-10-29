# chartroom-panel

A small Claude Code mod (function hooks; built and verified on Claude Code 2.1.312) that shows
the commander's live Chartroom board in a **pane beside the chat**. It mirrors `chartroom board`
and the dashboard exactly: the same five lanes, in the same order, under the same names, each card
with the board's own reason. From the focused pane the commander can **complete** (accept) or
**close** a task, through the same CLI the XO uses.

```
┌ Chartroom ─────────────────────────────┐
│ Chartroom · 2 need you                  │
│ Live · updated 9:41:12 AM               │
│                                         │
│ Needs you (2)                           │   ← yellow
│ 3363 Pick a cache                       │
│   decision · proj                       │
│ f436 Fix login redirect                 │
│   awaiting review · proj                │   ← a worker's done, waiting on you
│ In progress (1)                         │   ← green
│ f357 Add billing export                 │
│   in-session · proj                     │
│ On hold (0)                             │   ← dim
│ Ready for you (0)                       │
│ Recently finished (0)                   │   ← dim
│ 1–3 of 3 · page 1/1                     │
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

The one source of truth is `chartroom board --json`, the board the dashboard and `chartroom board`
draw (its lanes come from `lib/dashboard/lanes.jq`). The panel reads it and nothing else: it never
reads a task file or decides a lane of its own, so it can never disagree with the dashboard.

- **Header** (bold, accent): `Chartroom · N need you` — N is the Needs you lane's count.
- **Status** (dim): `Live · updated H:MM:SS AM`, the local time of the last successful read. On a
  failure it reads `STALE: …` (the last board stays on screen) or, before the first read,
  `Unavailable: …`.
- **The lanes, every one, in the board's order**, each headed as `chartroom board` heads it, with
  its total count (and how many focus mode holds): `Needs you (3, 1 held)`, `In progress (1)`,
  `On hold (0)`, `Ready for you (0)`, `Recently finished (2)`. A lane's header shows even when it
  is empty or its cards are on another page.

  | lane | colour | what the board puts there |
  | --- | --- | --- |
  | Needs you | yellow | decision, blocked, failed, awaiting-input, **review** (a worker's done, awaiting your look), inbox questions |
  | In progress | green | working, drafting, waiting inside its window |
  | On hold | dim | stopped silent, overdue, waiting on a person or a PR review |
  | Ready for you | plain | done (accepted), not closed yet |
  | Recently finished | dim | closed lately, or done with its PRs merged |

- **Each card, two lines**: `{short_id} {title…}` (short id in a subtle colour, title truncated
  to fit), then the board's reason (`decision`, `PR to review`, `awaiting review`, `accepted`,
  `closed`, …), `held` when focus mode holds it, and the project. Inbox questions are cards too,
  as on the board.
- **Footer**: `{first}–{last} of {total} · page {p}/{pages}` over the cards, then
  `/chartroom-panel next|prev|off`.

## Activation & scope

Installed at user scope the mod loads in every Claude Code session but does nothing — no command,
no timer, no process, no pane — unless the session is **interactive** and not a crew worker. It
**auto-shows by intent**: when the session becomes the XO — i.e. when the `/chartroom` (or legacy
`/captain`) skill is invoked, whether by the slash command, the Skill tool or a preload — **in any
directory**. This is deliberately not tied to the working directory: the commander runs the XO from
project repos, so a cwd check would miss the real case. Three hooks catch the intent and share a
once-only guard, because no single one is reliable: `skill.prompt`, the `prompt.submit` of the
`/chartroom`/`/captain` command, and the `Skill` tool call. (A builtin plugin's `skill.prompt`
handler can run first and send the event on past ours — `cc-plugin-sec-default` does — so the
prompt-submit and tool-call triggers cover that case.) The home used to read `chartroom board` is
resolved separately, through `chartroom doctor --json`, so the panel still shows the right fleet
wherever it is run.

A crew worker's session never auto-shows and stays fully inert (no command, no pane): it is skipped
when `CHARTROOM_TASK` is set or the path has a `worktrees` segment, and in any non-interactive
(`-p`) run.

`/chartroom-panel` turns the panel on **anywhere** (any directory, any eligible session). It never
shadows the `/chartroom` skill command.

### Default auto-show (durable, per home)

Auto-show is on by default. To turn it off durably — across every session — set the home's config:

```
/chartroom-panel default off     # stop auto-showing on session start (for this home)
/chartroom-panel default on      # restore the default auto-show
/chartroom-panel default         # report the current default
```

This writes a single, harness-neutral setting in the **Chartroom home**, not in Claude Code
settings, so the Pi panel and a future Codex panel can read the **same** switch:

```
# $CHARTROOM_HOME/panel.conf
autoshow=off
```

`panel.conf` is plain `KEY=VALUE` lines; the panel reads `autoshow` (unset or any value other than
`off`/`false`/`0`/`no` means on). Edit the file by hand or use the command above. When the default
is off, `/chartroom-panel on` still opens the panel for the current session, and an explicit session
`on`/`off` always overrides the default for that session.

## Commands

```
/chartroom-panel                 toggle: open-and-focus when hidden, close when shown
/chartroom-panel toggle          same as the bare command
/chartroom-panel focus           open the pane and take the keyboard (never closes)
/chartroom-panel on | off        show / hide for the session (off also stops the refresh)
/chartroom-panel refresh         read the board now
/chartroom-panel next | prev     page through the cards
/chartroom-panel pick <short_id> bring that task into the chat (see below)
/chartroom-panel default on|off  the durable, per-home auto-show default (see below)
```

The pane is never focused at the moment you type a command (the composer holds the keys then), so
the bare command can't "close a focused pane" — it closes a *shown* one and opens-and-focuses a
hidden one. To take the keyboard of a pane that is already shown (e.g. the auto-shown one), press
**ctrl+x tab** (the engine's own focus chord) or run `/chartroom-panel focus`. Closing the pane by
hand (the frame's ✕ or **ctrl+x x**) turns the panel off for the session, exactly as `off` does.

## Picking a task into the chat

`/chartroom-panel` hands the keyboard to the pane: the arrows walk the cards and **Enter**
brings the highlighted task (or inbox question) into the chat — it **runs** `/continue {short_id}` (the existing
Chartroom continue skill) in one press and returns focus to the chat. It uses `$.command.run`, which
dispatches the slash command *as if the commander typed it* — not `$.prompt.submit`, which only
submits the text and does not re-parse it as a command (so the continue skill never actually ran).
`/continue` only navigates, so auto-running it is safe; the commander does not press Enter twice.
**Esc** hands the keys back and leaves the pane open; normal typing is never captured. The command
is its own turn and never touches the composer, so a draft is left intact. (`pick <short_id>` does
the same from the command line.)

## Action keys on the highlighted task (focused only)

While the pane holds the keyboard, single-letter keys act on the highlighted row. They fire **only**
while the pane is focused — never while you are typing in the chat — and the footer legend lists
them:

- **`a` — complete (two-press confirm).** The first `a` arms it and shows `Complete <id> (accept
  it as done)? press a again to confirm` (it resets after a few seconds); a second `a` on the same
  row runs `chartroom accept <id>`: a task in review (its worker reported done) becomes `done`, and
  nothing is removed (its worktree and branch stay). On the next read the board moves it to Ready
  for you. Any other state is refused by the CLI, and the panel shows its exact words.
- **`c` — close (two-press confirm).** The first `c` arms it and shows `Close <id>? press c again
  to confirm`; a second `c` on the same row runs `chartroom close <id>` against the home, **keeping
  the branch — it never passes `--discard`**. It relies on `chartroom close`'s own guard: if the
  close is refused (a dirty or unlanded worktree, or any error) the panel shows the CLI's exact
  message and does **not** claim success. On success the board re-polls and the task moves to
  Recently finished.
- Complete and close are the **only** changes the panel makes, each through the CLI with the
  task's full id. Arming one disarms the other (the confirm takes the same key on the same row),
  moving to another row disarms it, and an inbox question or an already closed task is refused
  without running anything. There is no discard/remove key.
- **`s` — recap (non-mutating).** Pre-fills the chat prompt with
  `Recap <short_id> (<title>): where it stands and what's pending` (same `$.prompt.fill` as Enter,
  never submitted) for the commander to send; the XO answers. No jump, no mutation.
- Plus the existing `↑/↓` (move), **Enter** (run `/continue <id>`), **Esc** (back to chat).

The footer makes the keys discoverable in both states: unfocused it shows `Ctrl+X Tab to select`
beside `/chartroom-panel next|prev|off`; focused it shows the full legend
`a: complete  c: close  s: recap  ↑↓ move · Enter /continue · Esc chat`, truncated gracefully on a
narrow pane.

## Refresh, safety, resilience

The board refreshes every 5 seconds on a timer, with **no model call**, idle or streaming. Reads
are bounded (a 20 s timeout for the board, which reads every task, the inbox and the artifacts;
8 s for an action) and never overlap; turning the panel off stops the refresh work. The
mod **never runs `chartroom watch`** — that stream belongs to the XO's supervision. A
command-not-found, a timeout, a malformed payload or a transient failure all keep the last known
board on screen, marked `STALE`; an error is never drawn as an empty board.

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

`hooks/model.ts` holds the pure parts (the board parse, the lanes and their tones, width-safe
text and paging), tested directly in `tests/model.test.ts`; `hooks/register.tsx` the hooks (activation, the
timer poll, the command, the pane), driven through the test kit in `tests/panel.test.ts`;
`types/index.d.ts` the `$.state` contract.

## Relationship to `crew-view`

`crew-view` is the full XO cockpit — a band above the prompt, a `/crew` board browser and the
todo list — and wakes on the `chartroom`/`captain` skill. `chartroom-panel` is deliberately
narrower: one pane that mirrors the board (the same `chartroom board --json` crew-view's browser
reads), with complete and close on the highlighted task. Install whichever fits; they share no
command name, so both can load, each drawing its own pane.
