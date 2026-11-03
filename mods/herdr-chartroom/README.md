# Tasks panel for the Herdr app

A side panel for the [Herdr app](https://herdr.dev) (`herdr-app`) that lists every open
chartroom task on this machine, from every home, in the radar's sectors (Decision, Blocked,
Adrift, Holding, Underway, Docked), most urgent first. Click a task to hand it to its XO.

Verified on herdr-app 0.1.12 with herdr-core (`hc`) 0.1.16.

## What it does

- **The list.** It runs `chartroom radar --json` once a minute while the panel is shown (the
  refresh button reads it at once). What needs you starts open; the other sectors start folded,
  and a click on a sector's name folds or opens it (remembered per panel).
- **Click a task: pass it to its XO.** The panel finds the XO of *that task's* home and types
  `/continue <full task id>` into it (`$continue <id>` for a Codex XO), then shows that XO's tab
  so you see the answer. The XO is the agent session running in the home's own folder: a live
  terminal on this machine, from the app's `terminals()`, whose folder is the task's
  `home_path`. Workers sit in worktrees, so they never match. If several match, one running
  Claude Code or Codex wins, then one the app shows, then the one whose status changed last.
  The radar's XO list is not used (it reads the old herdr server, not herdr-core).
  It types with `hc send` (paste, then Enter once nobody is typing) and shows the XO with
  `agent.focus`. It never starts an XO, and nothing is typed when:
  - the task is on another machine;
  - no terminal sits in the home's folder;
  - the only terminals there run a shell (an XO that has exited leaves its prompt behind);
  - the XO is blocked on a question or a permission prompt. hc refuses those without
    `--force`, and the panel never passes it: answer the prompt in the XO, then click again.

  A line under the header says what happened, or why nothing was sent. Click it to dismiss it.
  A second click while a send is still on its way sends nothing.
- **The chevron** opens a task's details: why it is where it is, its last event, its PRs (from
  `chartroom show --json`, in the task's own home), and **Open worker** when the worker can be
  shown. An `hc:*` worker opens through `chartroom attach <id>` (run with that task's
  `CHARTROOM_HOME`), which shows its terminal in this app. A `herdr:*` worker opens as a tab
  attached to its herdr agent (`herdr agent attach <id>`), because `chartroom attach` would focus
  it in herdr's own window instead.

## Install

The app loads mods from `~/.config/herdr-app/mods/<name>/`, and this one must be named
`chartroom`: its icons are referenced as `mods/chartroom/...`, and it finds its own block in the
layout by that name to know whether it is on screen. Install it by **copying** the
files, and copy again after you update chartroom (the app reloads a mod when its files change):

```sh
mkdir -p ~/.config/herdr-app/mods/chartroom
cd ~/.local/share/chartroom/mods/herdr-chartroom   # or your checkout's mods/herdr-chartroom
cp main.js xo.js mod.json compass.svg refresh.svg ~/.config/herdr-app/mods/chartroom/
herdr-app check ~/.config/herdr-app/mods/chartroom
```

Don't symlink the folder. On herdr-app 0.1.12 the app loads a symlinked mod folder but never
hot-reloads it: an edit only shows after the panel is closed and opened again, while a copied
folder reloads within a second. (Checked with a throwaway mod opened as an overlay. After an edit
through the symlink it kept showing its first version until it was reopened; the same mod as a
real folder picked up each edit while open.)

The app writes `gpui-kit.d.ts` (its API types) and a `jsconfig.json` into the folder; both are
kept out of git here, and copying over an installed panel leaves them in place.

## Put it in a layout

`mod.json` says `"place": "none"`, so the app never docks it by itself: a layout places it.
In a clone of a shipped layout (`herdr-app do layout.clone '{"name":"main","as":"my-layout"}'`),
add a block for it, for example as one more child of a right-hand panel stack:

```json
{ "id": "panel-body", "type": "stack", "active": "files",
  "children": [
    { "id": "files", "type": "block", "content": { "mod": "files" } },
    { "id": "changes", "type": "block", "content": { "mod": "changes" } },
    { "id": "chartroom", "type": "block", "content": { "mod": "chartroom" } } ] }
```

It reads the radar only while that block is on screen. A button that shows and hides the panel
belongs in the tab bar, which means a clone of the shipped `tabs` mod
(`herdr-app do mod.clone '{"name":"tabs","as":"tabs-chartroom"}'`) that runs
`layout.select {stack: "panel-body", child: "chartroom"}` and `layout.show {id: "panel"}`. That
clone is part of the layout, not this mod, and isn't included here. `compass.svg` is here for it.

## Files

| File | What it is |
|---|---|
| `main.js` | the panel |
| `xo.js` | which terminal is a home's XO and what to type into it: pure, unit-tested by `test/js/herdr-xo.test.js` (`bats test/dashboard-js.bats`) |
| `mod.json` | `place: none`, the title |
| `refresh.svg`, `compass.svg` | the refresh button; the tab bar button's icon |

`herdr-app check <folder>` loads it once and reports errors; `herdr-app status` shows a running
copy's errors.
