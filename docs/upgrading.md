# Upgrading from chartroom's predecessor

## After an upgrade that retired the web dashboard

The [app](app.md) replaces the old web dashboard. After upgrading, in each home:

- `chartroom dashboard stop` ends an old dashboard server still running from before (or
  `chartroom sweep --apply`, which ends it too). In a client home, `dashboard stop` also ends the
  old tunnel to the brain's dashboard.
- Run `chartroom install-skills` again, so the XO's skills send you to the app (Needs me, a
  task's ticket, Fleet, Usage) instead of the dashboard.
- `chartroom dashboard` now opens the app; set the app up on the brain first
  ([docs/app.md](app.md#run-it-on-the-brain)). `chartroom board` is the lanes in the terminal.
- A `CHARTROOM_DASHBOARD_PORT`, `_THEME` or `_HOST` line in a config does nothing now and can go.

# A home from before chartroom

A home made by chartroom's predecessor (`~/.captain`, with `captain.md`, "Captain's intent"
briefs and `codex` / `herdr-claude` / `herdr-codex` backends) works as is. On each machine
that has one:

1. Point chartroom at it, and keep its old defaults if you want new tasks to look like the old
   ones, in `~/.config/chartroom/config`:

   ```
   CHARTROOM_HOME=~/.captain
   CHARTROOM_WORKSPACE=captain-crew
   CHARTROOM_BRANCH_PREFIX=cap/
   CHARTROOM_PROJECT_ROOTS=~/code
   CHARTROOM_HARNESS=claude
   ```

2. Move any older copies of the `captain`, `bearings`, `dashboard` and `continue` skills out of
   your agents' skill directories (`install-skills` never replaces a real directory), then run
   `chartroom install-skills`. It also links a `captain` skill: the chartroom skill under its old
   name, so `/captain` and a home whose `AGENTS.md` asks for it keep working.
3. Briefs already handed to workers name the old helper's path. Leave an executable at that
   path that hands over to chartroom, so running workers can still report:

   ```bash
   #!/usr/bin/env bash
   export CHARTROOM_HOME="${CAP_HOME:-$HOME/.captain}"
   exec "$(command -v chartroom || echo "$HOME/.local/bin/chartroom")" "$@"
   ```

   (`chartroom dashboard` with no arguments opens the app, so the helper needs no special case
   for it.)

4. Check: `chartroom status` lists the old tasks with their states, and `chartroom board`
   shows them in its lanes.
5. Optional: move hand-written preferences into the rulings ledger (see Concepts).
   `chartroom rule draft > map.tsv` lists each bullet with a guessed topic and its date. Edit
   the topics so rulings that replace each other share one, set a row's topic to `keep` to
   leave that bullet as hand-written text, and rewrite a row's text if the winner has to stand
   alone. Then `chartroom rule import map.tsv` (a dry run) and `--apply`, which backs the file
   up under `records/`, appends the rulings, removes the imported bullets and renders the block.
