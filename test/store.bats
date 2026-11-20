#!/usr/bin/env bats
# The store (lib/store.sh, lib/store.py): with CHARTROOM_STORE=sqlite in a home's config, every
# task born after that lives in one SQLite database; tasks born before stay files, read as files.

load test_helper

setup() {
  common_setup
  command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null || skip "no python3 with sqlite3"
  export CHARTROOM_DB="$BATS_TEST_TMPDIR/state/chartroom/chartroom.db"
  cr init >/dev/null
}

store_on() { printf 'CHARTROOM_STORE=sqlite\n' >>"$CHARTROOM_HOME/config"; }
store_off() { sed -i.bak '/^CHARTROOM_STORE=/d' "$CHARTROOM_HOME/config"; }
db() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); [print("|".join(map(str,r))) for r in c.execute(sys.argv[2])]' "$CHARTROOM_DB" "$1"; }

@test "switch off: tasks are files, no database and no home id appear" {
  id="$(new_task)"
  cr event "$id" progress "hello" >/dev/null
  cr status --json >/dev/null
  [ -f "$CHARTROOM_HOME/tasks/$id/meta.json" ]
  [ -f "$CHARTROOM_HOME/tasks/$id/events.log" ]
  [ ! -e "$CHARTROOM_DB" ]
  [ ! -e "$CHARTROOM_HOME/.home-id" ]
}

@test "switch on: a new task is a row, its directory keeps only the files that stay files" {
  store_on
  id="$(new_task)"
  d="$CHARTROOM_HOME/tasks/$id"
  [ ! -e "$d/meta.json" ]
  [ ! -e "$d/events.log" ]
  [ -f "$d/brief.md" ]
  [ -s "$CHARTROOM_HOME/.home-id" ]
  # The brief's fallback appends to the spool, not to an events.log.
  grep -qF ">> $d/events.spool" "$d/brief.md"
  cr event "$id" progress "first step" >/dev/null
  events "$id" | grep -qE '^[0-9T:Z-]+ note: created \(ship via auto\)$'
  events "$id" | grep -qE '^[0-9T:Z-]+ progress: first step$'
  [ "$(meta_of "$id" title)" = "stub task" ]
  [ "$(db "select count(*) from events where task = '$id'")" = 2 ]
  run cr status --json
  [ "$(jq -r '.[0].id' <<<"$output")" = "$id" ]
  [ "$(jq -r '.[0].state' <<<"$output")" = drafting ]
  [ "$(jq -r '.[0].last' <<<"$output")" = "progress: first step" ]
}

@test "store task end to end on the command backend: dispatch, wake, review, accept, close" {
  store_on
  id="$(STUB_COMMIT=1 new_task --backend command --command "STUB_COMMIT=1 $STUB {id}")"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  run cr watch --once --timeout 15
  [ "$status" -eq 0 ]
  [[ "$output" == *"[$id]"*"done: stub finished"* ]]
  # The wrapper's `exited` line goes to the spool, and the store takes it in.
  wait_event "$id" ' exited: command ended \(exit 0\)'
  [ "$(db "select src from events where task = '$id' and kind = 'exited'")" = spool ]
  run cr status --json
  [ "$(jq -r '.[0].state' <<<"$output")" = review ]
  [ "$(jq -r '.[0].live' <<<"$output")" = stopped ]
  run cr accept "$id"
  [ "$status" -eq 0 ]
  wt="$(meta_of "$id" worktree)"
  [ -d "$wt" ]
  run cr close "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch chartroom/$id kept (1 commit(s) ahead"* ]]
  [ ! -d "$wt" ]
  [ -n "$(meta_of "$id" closed)" ]
  run cr status
  [[ "$output" == "no open tasks" ]]
  [ ! -e "$CHARTROOM_HOME/tasks/$id/meta.json" ]
}

@test "a store task's decision wakes the watch, and its steer re-runs the worker" {
  store_on
  id="$(new_task --backend command --command "STUB_MODE=decision $STUB {id}")"
  cr dispatch "$id" >/dev/null
  run cr watch --once --timeout 15
  [[ "$output" == *"decision: pick A or B"* ]]
  wait_event "$id" ' exited: '
  [ "$(cr status --json | jq -r '.[0].state')" = decision ]
  run cr steer "$id" "go with A"
  [ "$status" -eq 0 ]
  run cr watch --once --timeout 15
  [[ "$output" == *"done: finished after steer: go with A"* ]]
}

@test "fixed at birth: a file task stays files after the switch, new tasks go to the store, one list" {
  old="$(TITLE="zz old" new_task --id zz-old)"
  store_on
  new="$(TITLE="aa new" new_task --id aa-new)"
  cr event "$old" progress "still a file task" >/dev/null
  cr event "$new" progress "a store task" >/dev/null
  grep -q 'progress: still a file task' "$CHARTROOM_HOME/tasks/$old/events.log"
  [ "$(db "select count(*) from tasks where id = '$old'")" = 0 ]
  [ ! -e "$CHARTROOM_HOME/tasks/$new/events.log" ]
  # One list, in id order, whatever each task's place.
  [ "$(cr status --json | jq -r 'map(.id) | join(" ")')" = "aa-new zz-old" ]
  # An id lives in one place: neither kind can be born again under the other's id.
  run cr new --project "$PROJECT" --title x --id zz-old
  [ "$status" -ne 0 ]; [[ "$output" == *"already exists"* ]]
  store_off
  rm -rf "${CHARTROOM_HOME:?}/tasks/$new"
  run cr new --project "$PROJECT" --title x --id aa-new
  [ "$status" -ne 0 ]; [[ "$output" == *"already exists"* ]]
}

@test "the spool: lines appended with printf are taken in once, in order, with their own times" {
  store_on
  id="$(new_task)"
  s="$CHARTROOM_HOME/tasks/$id/events.spool"
  printf '2026-01-02T10:00:00Z progress: from the fallback\n' >>"$s"
  printf 'not an event line\n' >>"$s"
  printf '2026-01-02T10:00:05Z exited: agent session ended (exit 0)\n2026-01-02T10:00:06Z blocked: half a li' >>"$s"
  # Two readers at once take each whole line in exactly once; the cut-off line waits.
  cr store events "$id" >/dev/null & cr store events "$id" >/dev/null; wait
  run events "$id"
  [ "$(grep -c 'from the fallback' <<<"$output")" = 1 ]
  [[ "$output" == *$'2026-01-02T10:00:00Z progress: from the fallback\n'*'note: unparsed spool line: not an event line'*$'\n2026-01-02T10:00:05Z exited: agent session ended (exit 0)'* ]]
  [[ "$output" != *"half a li"* ]]
  printf 'ne\n' >>"$s"
  events "$id" | grep -qx '2026-01-02T10:00:06Z blocked: half a line'
  [ "$(db "select count(*) from events where task = '$id' and src = 'spool'")" = 4 ]
}

@test "many writers at once: 50 event processes x 20 lose nothing and number every event once" {
  store_on
  ids=()
  for i in 1 2 3 4 5; do ids+=("$(TITLE="t$i" new_task)"); done
  for w in $(seq 1 50); do
    ( id="${ids[$((w % 5))]}"
      for n in $(seq 1 20); do "$CHARTROOM" event "$id" progress "w$w n$n" 3>&- || echo "FAILED w$w n$n" >>"$BATS_TEST_TMPDIR/fail"; done ) &
  done
  wait
  [ ! -e "$BATS_TEST_TMPDIR/fail" ]
  [ "$(db "select count(*), count(distinct seq) from events where kind = 'progress'")" = "1000|1000" ]
  for id in "${ids[@]}"; do [ "$(events "$id" | grep -c ' progress: ')" = 200 ]; done
  [ ! -e "$CHARTROOM_HOME/tasks/${ids[0]}/events.spool" ]
}

@test "many writers while a watch runs: every decision wakes exactly once" {
  store_on
  ids=()
  for i in 1 2 3 4 5; do ids+=("$(TITLE="t$i" new_task)"); done
  cr watch --once --timeout 1 >/dev/null 2>&1 || true # its cursor, at the end of every log
  for w in $(seq 1 20); do
    ( id="${ids[$((w % 5))]}"
      for n in 1 2 3 4 5; do "$CHARTROOM" event "$id" progress "w$w n$n" 3>&-; done
      "$CHARTROOM" event "$id" decision "q from w$w" 3>&- ) &
  done
  wait
  out=""
  for i in $(seq 1 10); do
    o="$(cr watch --once --timeout 2 2>/dev/null || true)"; out+="$o"$'\n'
    [ "$(grep -c 'decision: q from w' <<<"$out")" -ge 20 ] && break
  done
  [ "$(grep -c 'decision: q from w' <<<"$out")" = 20 ]
  [ "$(grep 'decision: q from w' <<<"$out" | sed 's/.*decision: //' | sort -u | wc -l | tr -d ' ')" = 20 ]
  [[ "$out" != *"progress:"* ]]
}

@test "the store refusing an event: it waits in the spool, then is taken in, never lost" {
  store_on
  id="$(new_task)"
  chmod 444 "$CHARTROOM_DB"
  run cr event "$id" decision "while the store was read-only"
  chmod 644 "$CHARTROOM_DB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waits in tasks/$id/events.spool"* ]]
  grep -q 'decision: while the store was read-only' "$CHARTROOM_HOME/tasks/$id/events.spool"
  events "$id" | grep -q 'decision: while the store was read-only'
  [ "$(cr status --json | jq -r '.[0].state')" = drafting ]
}

@test "set: a store task's settings, and only the known keys" {
  store_on
  id="$(new_task)"
  run cr set "$id" model=opus effort=high
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" model)" = opus ]
  [ "$(meta_of "$id" effort)" = high ]
  run cr set "$id" worktree=/tmp/x
  [ "$status" -ne 0 ]; [[ "$output" == *"not a setting"* ]]
  # The same verb on a file task writes its meta.json.
  store_off
  f="$(new_task)"
  cr set "$f" model=sonnet >/dev/null
  [ "$(jq -r .model "$CHARTROOM_HOME/tasks/$f/meta.json")" = sonnet ]
}

@test "store on without python's sqlite3: refused loudly, nothing born" {
  store_on
  run env CHARTROOM_PYTHON="$BATS_TEST_TMPDIR/no-python" "$CHARTROOM" new --project "$PROJECT" --title "no python" --id nopy
  [ "$status" -ne 0 ]
  [ ! -e "$CHARTROOM_HOME/tasks/nopy" ]
}

@test "store doctor, check and legacy" {
  TITLE=old new_task >/dev/null
  store_on
  new_task >/dev/null
  run cr store doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"store: sqlite for new work in this home"* ]]
  [[ "$output" == *"schema 1, wal, ok"* ]]
  [[ "$output" == *"this home: 1 task(s) in the store, 1 open"* ]]
  run cr store check
  [ "$output" = "store: no problems" ]
  run cr store legacy --json
  [ "$(jq -c . <<<"$output")" = '{"tasks":1,"open_tasks":1}' ]
}
