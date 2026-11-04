# crew-view

A Claude Code mod (function hooks; built and verified on Claude Code 2.1.302, the todo list on 2.1.303) that shows the chartroom crew
live inside the XO's session:

- **A band above the prompt**, one line, one emoji per lane with its count, every item that
  needs you labelled with its project:

  ```
  ⚓ 🏃 3 · 🙋 2 [shop] 108a, [billing] 9c1e · 💤 1 · ✅ 1 · ❌ 1                [ crew ]
  ```

  | | lane |
  | --- | --- |
  | 🏃 | running |
  | 🙋 | needs you (a decision, a blocker, an inbox item) |
  | 💤 | on hold |
  | ✅ | landed |
  | ❌ | failed |

  While focus mode is on (`chartroom focus`), the band leads with the focus and its held
  count, which never give way, and counts only what is in focus:

  ```
  ⚓ 🎯 shop · 3 held · 🏃 1 · 🙋 1 [shop] 108a                                  [ crew ]
  ```

  A lane appears only when something is in it. Each emoji is wide on its own code point (no
  variation selector, so no `⏸️`), and the band counts it as two columns. A narrow terminal cuts the needs-you list to
  `+N more`, never mid-item. `[ crew ]` (or its hotkey `c` once the band has focus: ctrl+x tab or a
  click) opens the pane. If `chartroom` is missing or fails, the band shows one dim error line.
- **A `/crew` pane that browses the items**, the web dashboard's equivalent inside Claude Code.
  It leads with the emoji legend, then the board's lanes (needs you, running, on hold, landed,
  failed), one row per item: `[project] short_id title state age-of-last-event`, sized to the
  pane. While focus mode is on, the focus line (`🎯 focus: shop · 3 held (since 2h)`) follows
  the legend and the rows out of focus are dim. `/crew` opens it with the keyboard: Tab or the arrows walk the rows, Enter opens one.
  `/crew <id>` opens that item straight away.

  Every view's first row reads `q: close`. `q` or Esc closes the pane from any view, and so does
  Esc at an idle, empty prompt once the keys are back there. `/crew` toggles the pane, and a
  closed pane opens next on the lanes. `/crew off` hides the band, and closes the pane, for the
  rest of the session (`/crew` still opens the pane); `/crew on` brings the band back. The todo
  list under it stays until `/todo off`.

  An item opens into its detail:

  ```
  q: close  Esc closes too · b back to the lanes
  108a  [shop] Auth project-manager
  🙋 decision · needs you · live running · herdr:claude
  c: continue  y: copy id  p: copy PR  r: report  a: copy artifact  b: back
  INTENT
    Make login use passkeys. Keep the old flow behind a flag.
  LAST EVENTS
     12m decision: pick A or B (recommend A)
  REPORT  ~/.chartroom/tasks/auth-project-manager-108a/report.md
    PR 7 is open.
  PRS
    https://github.com/acme/shop/pull/7
  ARTIFACTS
    108a/note-for-chris  Note for Chris (message)
  WORKER
    herdr tab w1:t2 · chartroom attach auth-project-manager-108a
  ```

  An inbox item shows its question in full. Each action has a one-letter hotkey:

  | key | action |
  | --- | --- |
  | `c` | continue: puts `/continue <id>` in an empty prompt and hands it the keys, so Enter runs it. A draft in the prompt is never replaced: the line is copied instead, and the pane says so |
  | `y` | copy the short id |
  | `p` | copy the (first) PR URL; Enter on a PR line copies that one |
  | `r` | read the report in the pane, rendered as markdown (`b` comes back) |
  | `a` | copy the (first) open artifact's text (`chartroom artifact show <ref>`); Enter on an artifact line copies that one |
  | `b` | back to the lanes (from the report, back to the item) |
  | `q`, Esc | close the pane |

  The line under the actions says what the last one did (copied, in the prompt, or why not).
  There are no write actions beyond these: nothing merges, steers or closes a task from the pane.

- **Your todo list under the band**, styled like Claude Code's own todo list: what you owe the
  crew (`chartroom todo`: open inbox items, open messages and runbooks to send or run, tasks
  waiting on your word), breaking first, then by due date, then oldest:

  ```
  ⚓ 🏃 3 · 🙋 2 [shop] 108a, [billing] 9c1e · ✅ 1                              [ crew ]
  ☐ [billing] 9c1e blocked: prod is down, need the DB password                   [ todo ]
  ☐ [legal] i-7f3a sign the NDA by 2026-10-22 · due 10-22
  ☐ [shop] 108a decide: pick A or B (recommend A)
    +2 more · 🎯 shop (IR-6) · 4 held
  ```

  The first three items show, then `+N more`; a breaking one is red, and a due date stays in
  view however narrow the terminal. While focus mode is on, only what it does not hold shows,
  and the last line names the focus and how many items it holds (that line alone when nothing
  in focus is waiting on you). With nothing owed and focus off, nothing is drawn. `[ todo ]`
  (hotkey `t` once the band has the keys) opens the pane.
- **A `/todo` pane of all of it.** Tab or the arrows walk the rows, and the row with the ring
  (marked `▸`; Enter on a row selects it too) takes the actions:

  | key | action |
  | --- | --- |
  | `c` | copy: an artifact's text (`chartroom artifact show <ref>`), an inbox item's text, a task's id |
  | `d` | done, pressed twice (the first says what the second ticks off): `chartroom todo done <ref>` removes the inbox line or marks the artifact done, and the ring moves to the next row. A task cannot be ticked: the pane says it clears when the XO relays your answer |
  | `o` | continue: `/continue <id>` into an empty prompt (a draft is kept and the line copied) |
  | `a` | show or hide the items focus mode holds (under HELD BY FOCUS) |
  | `q`, Esc | close the pane |

  `/todo` toggles the pane, `/todo off` hides the list above the prompt for the session (`/todo
  on` brings it back), and `/todo add [--project P] <text>` and `/todo done <ref>` run the CLI's.
  `/crew todo` is the same command, with the same `off`, `on`, `add` and `done`. One chartroom
  pane shows at a time: opening the todo pane (`/todo`, `/crew todo`, `[ todo ]`) closes the crew
  pane, and opening the crew pane (`/crew`, `/crew <id>`, `[ crew ]`) closes the todo pane. **Where your own
  `/todo` command or skill already has the name** (Claude Code refuses a plugin's command that
  would shadow it), `/crew todo` is the way in, your `/todo` passes by untouched, and the pane's
  header says `/crew todo`.

It reads `chartroom board --json` (chartroom on PATH, else `~/.local/bin/chartroom`) when it
wakes, whenever a pane opens or a `/todo` command changes something, and otherwise **only when
something changed**: every 15 seconds it stats the home's change stamp, `<home>/.changed` (no
process), which chartroom rewrites after each write of what the board shows (an event, a hook's
line, a steer, `new`, `dispatch`, `accept`, `close`, an inbox or focus change, an artifact, a
relay; [the contract](../../README.md#state-format-and-event-protocol-the-contract)). When the
stamp's mtime differs from the one the last read began with, it reads the board; when it does
not, the round runs no process. It also reads at least every 5 minutes, stamp or not: that keeps
ages and `waiting` windows current and catches what writes without chartroom (a worker's
`printf >>` fallback for events, a hand edit), so the band lags such a change by 5 minutes at
most. An idle home costs one board run per 5 minutes, where it was one per 15 seconds. A failed
read is tried again the next round. A home without a stamp (an older chartroom, or one nothing
has written to since the update) is read only by the 5-minute refresh until its first write.

The todo list rides in the same JSON (`.todo`), so it costs no second read. Every 3 seconds the
mod also stats `focus.json` and `inbox.md` in the home (no process), and reads the board at once
when either changed: focus mode turning on or off, an item added or ticked off elsewhere, shows
within seconds, without a restart, and so does a hand edit of `inbox.md`. It reads `chartroom
show <id> --json` when an item opens, and again with each board read while it is open. With the
band and the list both off and both panes closed, nothing is read.

### What this Claude Code build supports

Checked against Claude Code 2.1.302: its API declarations (`.claude-plugin/types/`), the test kit
(`claude plugin test`), and a live session in a terminal. Live, a `/crew` pane opened with
`focus` takes the keyboard; the arrows walk its Buttons and Enter presses one; a Button's
one-letter `hotkey` presses it while the pane holds the keys; `$.ui.focus` moves the ring
(back to the row you came from); `$.prompt.fill` puts `/continue <id>` in the prompt and hands
the keys to it; a `Markdown` element draws the report; a hot reload keeps the session awake.
The mod does not submit `/continue` itself (`$.command.run` could): you see the line and press
Enter. Copying goes through `$.ui.copy` (the terminal's clipboard tool, or OSC 52); the tests
check what is copied, not a terminal's clipboard. By the API's own rules a pane opened from the
band's `[ crew ]` button does not take the keyboard (the band holds it); `/crew` does.

Closing, checked live on the same build: a Button with `hotkey="q"` and `role="dismiss"` calls
`$.ui.close`; the pane opens with `closeOnEscape`, so Esc closes it from the pane, and from an idle,
empty prompt after typing handed the keys back; `autoFocus` puts the ring on the first row
instead of on `q: close` (and, in the test kit, on the row last opened). In the test kit, the mod's own `$.ui.close` does not
reach its own `ui.close` hook, so `q` and `/crew` reset the pane themselves and the hook handles
the person's closes. The frame's close mark (`✕`, a mouse click) is the person's close too; it
was not clicked in the live check.

The todo list, checked live on Claude Code 2.1.303 (a throwaway home, the mod from
`--plugin-dir`): the band draws the list under the crew line; `/todo` and `/crew todo` open and
close the pane, and switch with the crew pane in both directions (one frame, no tabs; the pane
switched to holds the keys); `$.command.register` refuses `/todo` where the person's own `todo` skill holds
it ("it is the user's /todo"), and the mod starts anyway, `/crew todo` reaching the list; the
`ui.focus` event follows the ring as the arrows move it, so `d` and
`c` act on the row it is on; `d` twice removed the inbox line and moved the ring to the next row;
`o` put `/continue <id>` in the prompt; an item added from another terminal, and focus mode
turning off and on (with the focus-mode work laid over this branch), showed in the band within
four seconds. `c` was not pressed live (it writes the machine's clipboard); the tests cover it.

## XO only, once the skill is loaded

Installed at user scope, the mod loads in every Claude Code session, crew workers' included. It
does nothing (no command, no timer, no process, no drawing) until the session loads the
`captain` or `chartroom` skill (`/captain`, `/chartroom`, or the Skill tool; the `skill.prompt`
event), and then only if all of these hold:

1. the session is interactive (not `claude -p`);
2. `CHARTROOM_TASK` is unset;
3. the working directory has no `worktrees` path segment;
4. the working directory is the chartroom home, resolved as the CLI resolves it:
   `$CHARTROOM_HOME`, `$CAP_HOME`, the registered home the working directory is (the `homes`
   file next to the config file, with several homes on one machine), `CHARTROOM_HOME=` in the
   config file (`$CHARTROOM_CONFIG` or `${XDG_CONFIG_HOME:-~/.config}/chartroom/config`), then
   `~/.chartroom` (or a pre-existing `~/.captain`). Every `chartroom` run of the mod's then names
   that home (`CHARTROOM_HOME`), so the band shows this session's home.

The check reads environment variables and files only; it never runs a process. Once awake the
mod stays awake for the session (kept in `$.state`, so a hot reload keeps it). If a resumed session
(`claude --resume`) comes back without the band, load the skill again.

## Install

At a Claude Code prompt:

```
/plugin install crew-view@chartroom
```

(`/plugin marketplace add wolzey/chartroom` first if you have not added the marketplace.)
Choose the user scope, so it is there whenever you start the XO in your home.

To run it from a checkout instead, so edits take effect without reinstalling:

```bash
claude plugin marketplace add ~/.local/share/chartroom   # or your clone
claude plugin install crew-view@chartroom
```

A marketplace that is a folder is read from that folder: after an edit (or a `git pull`), run
`/reload-plugins` in the session. To try it for one session without installing:
`cd ~/.chartroom && claude --plugin-dir <checkout>/mods/crew-view`.

## Develop

```bash
claude plugin validate mods/crew-view
claude plugin test mods/crew-view
tsc -p mods/crew-view      # needs .claude-plugin/types/, which Claude Code lays at each load
```

Claude Code writes `.claude-plugin/types/` (the API's declarations, git-ignored) when it loads
the mod from a folder it watches (`claude --plugin-dir` in an interactive session). Before that,
copy the declarations the plugin-authoring skill names into
`.claude-plugin/types/claude-code/index.d.ts`.

`hooks/crew.ts` holds the pure parts (home resolution, board and detail parsing, band, pane
and detail text, the actions); `hooks/todo.ts` the todo list's (parsing the board's `.todo`, the
band's rows, the pane's rows, its actions); `hooks/register.tsx` the hooks; `types/index.d.ts`
the `$.state` contract. `mods/crew-view-pi` imports `hooks/crew.ts` and `hooks/todo.ts` too, so a
change there changes both.

The todo list lives in this mod, not a sibling one, because it needs everything this one already
has: the XO-only gating and the wake on the skill, the board poll (the list rides in its JSON),
the chartroom runner, the clipboard and `/continue` helpers, and the same `$.state`. A sibling
plugin installs as a folder of its own, so it could not import these; it would carry a copy of
the gating and run a second board poll of its own.
