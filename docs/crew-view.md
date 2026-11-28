# The crew view and the Herdr panel

Optional views of the crew beside the [app](app.md) and `chartroom board`: a band and pane inside the XO's own Claude Code (or pi) session, and a side panel for the Herdr app.

## A live crew view in Claude Code (and pi)

`mods/crew-view` is a Claude Code mod (verified on Claude Code 2.1.302, the todo list on 2.1.303) that draws the crew inside the XO's
session: a one-line band above the prompt (`⚓ 🏃 3 · 🙋 2 [shop] 108a, [billing] 9c1e · ✅ 1`,
one emoji per lane, every item that needs you labelled with its project) and a `/crew` pane that
browses the board's items inside Claude Code. Tab or the arrows walk the items,
Enter opens one: its state, the commander's intent, the last events, the report's summary or the
outcome, PRs, artifacts and where the worker runs. From there, `c` puts `/continue <id>` in the
prompt (Enter runs it), `y` copies the id, `p` a PR URL, `a` an artifact, `r` reads the report,
`b` goes back; `/crew <id>` opens an item directly. `q` or Esc closes the pane, `/crew` toggles
it, and `/crew off` hides the band for the session. While [focus mode](../README.md#focus-mode-one-project-at-a-time)
is on, the band leads with `🎯 <project> · N held` and counts only what is in focus. It reads
`chartroom board --json` only when the home's change stamp (`.changed`, below) moved, which it
stats every 15 seconds without a process, and at least every 5 minutes; an item it reads with
`chartroom show <id> --json`.

Under the band sits [your todo list](../README.md#your-next-steps-the-todo-list), styled like Claude Code's
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
`/reload-plugins` picks up edits. See [mods/crew-view/README.md](../mods/crew-view/README.md).

`mods/crew-view-pi` is the same band, browser and todo list (`/todo`) for [pi](https://pi.dev) (0.87 or newer), gated
the same way (`/skill:captain` or `/skill:chartroom` wakes it): `pi install <checkout>/mods/crew-view-pi`,
for example `pi install ~/.local/share/chartroom/mods/crew-view-pi`. See
[mods/crew-view-pi/README.md](../mods/crew-view-pi/README.md).

## A Tasks panel in the Herdr app

`mods/herdr-chartroom` is a side panel for the Herdr app (`herdr-app`) listing every home's open
tasks in the radar's sectors, from `chartroom radar --json`. Clicking a task passes it to its
home's XO: it types `/continue <id>` into the agent running in that home's folder and brings the
XO's tab to the front. It never types into a blocked XO (it brings that XO forward so you can
answer its question) or a bare shell, and never starts an XO; when it can't send, it says why. The chevron opens the details, with PRs and **Open worker**.
Install it by copying its files into `~/.config/herdr-app/mods/chartroom` (not a symlink: the app
doesn't hot-reload one), then place it in a layout. See
[mods/herdr-chartroom/README.md](../mods/herdr-chartroom/README.md).
