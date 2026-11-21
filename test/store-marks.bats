#!/usr/bin/env bats
# remove, restore and done (lib/marks.sh): items of work leave every view at once, in bulk, by a
# mark in the store; nothing an item is made of is ever written, file-born or store-born.

load test_helper

setup() {
  common_setup
  unset CHARTROOM_STORE # (these tests turn the switch on and off in the home's own config)
  command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null || skip "no python3 with sqlite3"
  export CHARTROOM_DB="$BATS_TEST_TMPDIR/state/chartroom/chartroom.db"
  cr init >/dev/null
}

store_on() { printf 'CHARTROOM_STORE=sqlite\n' >>"$CHARTROOM_HOME/config"; }

@test "remove: old file items and store items leave every view in one call, and no file changes" {
  # From before the store: a task with a dirty worktree and an unlanded commit, an inbox line, an artifact.
  old="$(TITLE="old work" new_task)"
  wt="$(cr worktree "$old")"
  echo change >"$wt/f.txt"; git -C "$wt" add f.txt; git -C "$wt" commit -qm "unlanded"; echo dirty >"$wt/dirty.txt"
  item="$(cr inbox add --project proj "an old question")"
  ref="$(printf 'draft\n' | cr artifact add "$old" --kind note --title "Old note" -)"
  # Born in the store: a task and an inbox item.
  store_on
  new="$(TITLE="new work" new_task)"
  nitem="$(cr inbox add "a new question")"
  before="$(snapshot "$CHARTROOM_HOME/tasks" "$wt" "$CHARTROOM_HOME/inbox.md")"
  branch_before="$(git -C "$PROJECT" rev-parse "chartroom/$old")"
  run cr remove "$old" "$item" "$ref" "$new" "$nitem" --why "no longer relevant"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^removed ' <<<"$output")" = 5 ]
  # Out of every view.
  [ "$(cr status --json --all | jq length)" = 0 ]
  [ "$(cr inbox list --json | jq '.waiting | length')" = 0 ]
  [ "$(cr artifact list --json --all | jq length)" = 0 ]
  [ "$(cr board --json | jq '[.lanes[][]?] | length')" = 0 ]
  # Nothing they are made of was written: records, worktree, inbox.md, the unlanded branch.
  [ "$(snapshot "$CHARTROOM_HOME/tasks" "$wt" "$CHARTROOM_HOME/inbox.md")" = "$before" ]
  [ "$(git -C "$PROJECT" rev-parse "chartroom/$old")" = "$branch_before" ]
  [ -f "$wt/dirty.txt" ]
  # Listed, and back with one restore.
  run cr removed --json
  [ "$(jq length <<<"$output")" = 5 ]
  [ "$(jq -r '.[0].why' <<<"$output")" = "no longer relevant" ]
  run cr restore "$old" "$item" "$ref" "$new" "$nitem"
  [ "$status" -eq 0 ]
  [ "$(cr status --json --all | jq -r 'map(.id) | sort | join(" ")')" = "$(printf '%s\n' "$new" "$old" | sort | paste -sd' ' -)" ]
  [ "$(cr inbox list --json | jq '.waiting | length')" = 2 ]
  [ "$(cr artifact list --json | jq length)" = 1 ]
  [ "$(snapshot "$CHARTROOM_HOME/tasks" "$wt" "$CHARTROOM_HOME/inbox.md")" = "$before" ]
}

@test "a batch applies every ref it can and reports the rest by ref (exit 1)" {
  a="$(TITLE=a new_task)"; b="$(TITLE=b new_task)"
  run cr remove "$a" nope-1234 "$b" i-ffff --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.applied | map(.ref) | sort | join(" ")' <<<"$output")" = "$(printf '%s\n' "$a" "$b" | sort | paste -sd' ' -)" ]
  [ "$(jq -r '.failed | map(.ref) | join(" ")' <<<"$output")" = "nope-1234 i-ffff" ]
  [ "$(cr status --json | jq length)" = 0 ]
  # Again: both already removed, each said so; nothing else changes.
  run cr remove "$a" "$b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$a: already removed"*"$b: already removed"* ]]
  run cr restore "$a" "$a"
  [ "$status" -eq 0 ]; [ "$output" = "restored $a" ]
}

@test "done marks inbox items and artifacts done in bulk; a task is not marked; todo done marks too" {
  id="$(new_task)"
  i1="$(cr inbox add "first")"; i2="$(cr inbox add "second")"
  r1="$(printf 'x\n' | cr artifact add "$id" --kind message --title "Send this" -)"
  store_on
  i3="$(cr inbox add "third, in the store")"
  before="$(cat "$CHARTROOM_HOME/inbox.md")"
  run cr done "$i1" "$r1" "$i3" "$id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"done $i1"*"done "*"done $i3"* ]]
  [[ "$output" == *"$id: a task is done by accept"* ]]
  [ "$(cr inbox list --json | jq -r '[.waiting[].short_id] | join(" ")')" = "$i2" ]
  [ "$(cr artifact list --json | jq length)" = 0 ]
  [ "$(cr artifact list --json --all | jq -r '.[0].done != null')" = true ]
  run cr todo done "$i2"
  [ "$status" -eq 0 ]; [ "$output" = "done $i2: second" ]
  [ "$(cr inbox list --json | jq '.waiting | length')" = 0 ]
  [ "$(cat "$CHARTROOM_HOME/inbox.md")" = "$before" ]
}

@test "remove refuses a live worker unless --stop, which ends it and leaves its worktree" {
  id="$(new_task --backend command --command "STUB_SLEEP=30 $STUB {id}")"
  cr dispatch "$id" >/dev/null
  wt="$(meta_of "$id" worktree)"
  run cr remove "$id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"its worker is running (--stop ends it first"* ]]
  [ "$(cr status --json | jq length)" = 1 ]
  run cr remove "$id" --stop
  [ "$status" -eq 0 ]; [ "$output" = "removed $id" ]
  pid="$(meta_of "$id" pid)"
  ! kill -0 "$pid" 2>/dev/null
  [ -d "$wt" ]
  [ "$(cr status --json | jq length)" = 0 ]
}

@test "a removed task wakes no one; its events are still kept" {
  store_on
  id="$(new_task)"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  cr remove "$id" >/dev/null
  cr event "$id" decision "nobody asked" >/dev/null
  run cr watch --once --timeout 3
  [ "$status" -eq 124 ]
  [[ "$output" != *"nobody asked"* ]]
  events "$id" | grep -q 'decision: nobody asked'
}

@test "accept and close take several ids; each is checked on its own" {
  store_on
  a="$(TITLE=a new_task)"; b="$(TITLE=b new_task)"; c="$(TITLE=c new_task)"
  for t in "$a" "$b" "$c"; do set_meta "$t" '.dispatched = "2026-01-02T10:00:00Z"'; done
  cr event "$a" done "a ready" >/dev/null; cr event "$b" done "b ready" >/dev/null
  run cr accept "$a" "$b" "$c"
  [ "$status" -eq 1 ]
  [[ "$output" == *"accepted $a"*"accepted $b"* ]]
  [[ "$output" == *"$c: $c is working, not awaiting review"* ]]
  [ "$(cr status --json | jq -r --arg a "$a" '.[] | select(.id == $a) | .state')" = done ]
  wt="$(cr worktree "$c")"; echo dirty >"$wt/x"
  cr worktree "$a" >/dev/null
  run cr close "$a" "$c"
  [ "$status" -eq 1 ]
  [[ "$output" == *"closed $a"* ]]
  [[ "$output" == *"refusing to close $c"* ]]
  [ -n "$(meta_of "$a" closed)" ]; [ -z "$(meta_of "$c" closed)" ]; [ -f "$wt/x" ]
}

@test "restore refuses past the 30 days; sweep purges what nothing needs, and keeps a daily backup" {
  store_on
  id="$(new_task)"; gone="$(TITLE=gone new_task)"
  item="$(cr inbox add "an old store item")"
  cr remove "$id" "$item" "$gone" >/dev/null
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("update marks set removed_at = ?", ("2020-01-01T00:00:00Z",)); c.commit()' "$CHARTROOM_DB"
  run cr restore "$id"
  [ "$status" -eq 1 ]; [[ "$output" == *"past the 30 days"* ]]
  # (one store task's directory gone by hand: its record stays, and so does its mark)
  rm -rf "${CHARTROOM_HOME:?}/tasks/$gone"
  cr sweep --apply >/dev/null
  # The store inbox item is gone for good; the tasks, their events and their marks stay.
  [ "$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("select count(*) from inbox").fetchone()[0], c.execute("select count(*) from tasks").fetchone()[0], c.execute("select count(*) from marks where kind = \"task\"").fetchone()[0], c.execute("select count(*) > 0 from events").fetchone()[0])' "$CHARTROOM_DB")" = "0 2 2 1" ]
  ls "$BATS_TEST_TMPDIR/state/chartroom/backups/" | grep -qE '^chartroom-[0-9]{4}-[0-9]{2}-[0-9]{2}\.db$'
  grep -q 'store purge: {"inbox": 1' "$CHARTROOM_HOME/sweep.log"
  [ "$(cr status --json --all | jq length)" = 0 ]
}

@test "focus lives in the store once the switch is on; focus.json from before goes at the first write" {
  printf '{"schema":1,"projects":["old"],"scope":[],"since":"2026-01-01T00:00:00Z","until":null}\n' >"$CHARTROOM_HOME/focus.json"
  store_on
  [ "$(cr focus --json | jq -r '.projects[0]')" = old ]
  cr focus proj >/dev/null 2>&1 || true
  [ ! -e "$CHARTROOM_HOME/focus.json" ]
  [ "$(cr focus --json | jq -r '.projects[0]')" = proj ]
  cr focus off >/dev/null
  [ "$(cr focus --json | jq -r .on)" = false ]
}

@test "store inbox items: the text verbatim, a project, a relabel, a resolve; inbox.md untouched" {
  store_on
  before="$(cat "$CHARTROOM_HOME/inbox.md")"
  id="$(cr inbox add --project "$PROJECT" 'use C:\new\tdir & "quotes"?')"
  [[ "$id" =~ ^i-[0-9a-f]{4}$ ]]
  [ "$(cr inbox list --json | jq -c --arg i "$id" '.waiting[] | select(.short_id == $i) | [.project, .text]')" = '["proj","use C:\\new\\tdir & \"quotes\"?"]' ]
  run cr inbox project "$id" webapp
  [ "$status" -eq 0 ]; [[ "$output" == *"[$id]"*"[webapp] use C:"* ]]
  [ "$(cr resolve "$id")" = "$id" ]
  [[ "$(cr status)" == *"inbox: 1 waiting on the commander"* ]]
  [ "$(cat "$CHARTROOM_HOME/inbox.md")" = "$before" ]
}
