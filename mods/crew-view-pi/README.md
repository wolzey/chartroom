# crew-view for pi

A [pi](https://pi.dev) extension (pi 0.87 or newer), the pair of [`mods/crew-view`](../crew-view)
for Claude Code: chartroom's crew, live inside the XO's pi session.

- **A band above the editor**, one line, one emoji per lane with its count, every item that
  needs you labelled with its project:

  ```
  ⚓ 🏃 3 · 🙋 2 [shop] 108a, [billing] 9c1e · 💤 1 · ✅ 1 · ❌ 1  /crew
  ```

  While focus mode is on (`chartroom focus`), it leads with the focus and its held count and
  counts only what is in focus (`⚓ 🎯 shop · 3 held · 🏃 1 · 🙋 1 [shop] 108a`); the browser adds
  the focus line and dims the rows out of focus.

- **`/crew`, a browser of the items.** It takes over the editor's place until you close it:
  the board's lanes, ↑/↓ (or `j`/`k`) to move, Enter to open an item. Every view's first line
  reads `q: close`: `q` closes the browser from any view, and Esc closes it from the lanes (from
  an item or its report, Esc steps back). `/crew <id>` opens that item straight away. While the
  browser is open it holds the keyboard, so `/crew` always opens it; `q` is the close. An item shows its state, the commander's intent,
  the last events, the report's summary or the outcome, PRs, artifacts and where the worker
  runs, with the same one-letter actions as the Claude Code pane:

  | key | action |
  | --- | --- |
  | `c` | continue: closes the browser and puts `/skill:continue <id>` (pi's spelling of `/continue`) in an empty editor; a draft is kept and the line copied instead |
  | `y` | copy the short id |
  | `p` | copy the first PR URL |
  | `r` | read the report, rendered as markdown (`b` or Esc comes back, `q` closes) |
  | `a` | copy the first artifact's text (`chartroom artifact show <ref>`), once the CLI has artifacts |
  | `b`, Esc | back to the lanes |
  | `q` | close the browser |

- **Your todo list under the band**, the same as the Claude Code mod's: the first three things you
  owe the crew (`chartroom todo`), `+N more`, and while focus mode is on, the focus and how many
  items it holds:

  ```
  ☐ [billing] 9c1e blocked: prod is down, need the DB password  /todo
  ☐ [legal] i-7f3a sign the NDA by 2026-10-22 · due 10-22
  ☐ [shop] 108a decide: pick A or B (recommend A)
    +2 more · 🎯 shop (IR-6) · 4 held
  ```

  **`/todo`** opens a browser of all of it: ↑/↓ (or `j`/`k`) move the `▸`, and the row it is on
  takes `c` (copy an artifact's text, an inbox item's, a task's id), `d` (done, pressed twice:
  `chartroom todo done`; a task says it clears when the XO relays your answer), `o` (closes the
  browser and puts `/skill:continue <id>` in an empty editor) and `a` (show the held items too);
  `q` or Esc closes it. `/todo off` hides the list (kept across `/reload`, as `/crew off` is),
  `/todo on` brings it back, and `/todo add [--project P] <text>` and `/todo done <ref>` run the
  CLI's. A change to `focus.json` or `inbox.md` reads the board within 3 seconds. Checked live on
  pi 0.87.1: the list under the band, the browser, `d` twice on an inbox item, `d` on a decision,
  `o`, `/todo off` and `on`, and an item added from another terminal showing within seconds.
- **`/crew off`** hides the band for the rest of the session and **`/crew on`** brings it back;
  a session entry keeps the choice across `/reload`. `/crew` still opens the browser. While the
  band and the todo list are off and no browser is open, nothing reads the board.

It reads `chartroom board --json` (chartroom on PATH, else `~/.local/bin/chartroom`) when it
wakes, and after that only when the home's change stamp (`<home>/.changed`, stat'ed every 15
seconds, no process) moved since the last read began, or at least every 5 minutes; the todo list
rides in the same JSON. The rules are the Claude Code mod's (its README, "It reads `chartroom
board --json`"), from the same helper (`boardDue`). It reads `chartroom show <id> --json` when an
item opens. The lane, band, detail and todo text come from the Claude Code mod's
own helpers (`../crew-view/hooks/crew.ts`, `../crew-view/hooks/todo.ts`), so the two views never
disagree.

## XO only, once the skill is loaded

Installed for your user, it loads in every pi session. It does nothing (no command, no timer,
no process, no drawing) until the session loads the `captain` or `chartroom` skill
(`/skill:captain`, `/skill:chartroom`, or the model reading either skill's `SKILL.md`), and then
only if all of these hold:

1. the session is pi's interactive TUI (not `pi -p`, JSON or RPC mode);
2. `CHARTROOM_TASK` is unset;
3. the working directory has no `worktrees` path segment;
4. the working directory is the chartroom home, resolved as the CLI resolves it
   (`$CHARTROOM_HOME`, `$CAP_HOME`, the config file, then `~/.chartroom` or a pre-existing
   `~/.captain`).

The check reads environment variables and files only. Once awake it stays awake for the
session: a session entry records it, so `/reload` and a resumed session wake again by themselves.

## Install

The skills first (`chartroom install-skills --pi`), then the extension, as a local pi package
read from your chartroom checkout (nothing is copied, so a `git pull` there updates it; `/reload`
in a running session):

```bash
pi install ~/.local/share/chartroom/mods/crew-view-pi    # or <your clone>/mods/crew-view-pi
pi remove ~/.local/share/chartroom/mods/crew-view-pi     # to take it out again
```

To try it for one session: `cd ~/.chartroom && pi -e <checkout>/mods/crew-view-pi`.

It imports `../crew-view/hooks/crew.ts`, so it runs from a chartroom checkout as above, not as a
package published on its own.

## Develop

pi loads TypeScript directly (jiti), so there is no build step. To type-check, point `tsc` at
pi's own declarations: a tsconfig with `"moduleResolution": "bundler"`, `"types": ["node"]`, and
`paths` mapping `@earendil-works/*` to the directory pi is installed in (for a bun global
install, `~/.bun/install/global/node_modules/@earendil-works/*`). The shared logic is tested
with the Claude Code mod (`claude plugin test mods/crew-view`).
