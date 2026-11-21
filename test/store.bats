#!/usr/bin/env bats
# The store (lib/store.sh, lib/store.py): with CHARTROOM_STORE=sqlite in a home's config, every
# task born after that lives in one SQLite database; tasks born before stay files, read as files.

load test_helper

setup() {
  common_setup
  unset CHARTROOM_STORE # (these tests turn the switch on and off in the home's own config)
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

@test "the app reads a store task: its ticket, its ask, its events file; set takes its properties" {
  store_on
  id="$(new_task)"
  set_meta "$id" '.dispatched = "2026-01-02T10:00:00Z"'
  cr event "$id" decision "which way? (a) left (b) right" >/dev/null
  run cr set "$id" priority=high labels=bug,ui initiative=in-abc1 model=opus
  [ "$status" -eq 0 ]
  [ "$(cr store meta "$id" | jq -c '[.priority, .labels, .initiative, .model]')" = '["high",["bug","ui"],"in-abc1","opus"]' ]
  cr set "$id" priority=none labels= initiative=none >/dev/null
  [ "$(cr store meta "$id" | jq -c '[has("priority"), has("labels"), has("initiative")]')" = '[false,false,false]' ]
  run cr set "$id" labels='Not OK'
  [ "$status" -ne 0 ]
  j="$(cr app task "$id" --json)"
  [ "$(jq -r .status <<<"$j")" = needs ]
  # The ask's id is the decision line's byte offset in the rendered events.log, and answers it.
  ask="$(jq -r .ask.id <<<"$j")"
  off="${ask##*-}"
  [ "$(cr store events "$id" | tail -c +"$((off + 1))" | head -n 1 | cut -d' ' -f2-)" = "decision: which way? (a) left (b) right" ]
  [ "$(jq -r '.events | map(select(test("decision: which way"))) | length' <<<"$j")" = 1 ]
  [ "$(cr app snapshot --json | jq -r --arg id "$id" '.needs[] | select(.task == $id) | .card')" = "$ask" ]
  run cr ask answer "$ask" --note "right"
  [ "$status" -eq 0 ]
  [ "$(cr app task "$id" --json | jq -r '.answer.answers[0].note')" = right ]
  [ ! -e "$CHARTROOM_HOME/tasks/$id/meta.json" ]; [ ! -e "$CHARTROOM_HOME/tasks/$id/events.log" ]
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
  [[ "$output" == *"schema 3, wal, ok"* ]]
  [[ "$output" == *"this home: 1 task(s) in the store, 1 open"* ]]
  run cr store check
  [ "$output" = "store: no problems" ]
  run cr store legacy --json
  [ "$(jq -c . <<<"$output")" = '{"tasks":1,"open_tasks":1,"inbox_lines":0,"artifacts":0}' ]
}

@test "a running watch hears a store task's event at its next light round, not the next full one" {
  store_on
  id="$(new_task)"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true # (its cursor)
  export CHARTROOM_WATCH_HC_INTERVAL=600 # nothing dispatched: the next full round is ten minutes away
  start=$SECONDS
  cr watch --once --timeout 30 >"$BATS_TEST_TMPDIR/out" 2>&1 &
  sleep 2
  cr event "$id" decision "heard between rounds" >/dev/null
  wait
  grep -q "\[$id\].*decision: heard between rounds" "$BATS_TEST_TMPDIR/out"
  (( SECONDS - start < 15 ))
}

@test "seams: the app's records (cards, answers, snoozes, the mailbox) are read only by their own modules" {
  # Each record has a file half from before the store and a store half: lib/ask.sh (cards and
  # answers), lib/snooze.sh, lib/tell.sh and lib/relay.sh (the mailbox) own both, and every other
  # reader goes through their functions, so none misses a store-born record.
  cd "$REPO_ROOT"
  shopt -s nullglob
  out="$(grep -nE '(^|[^a-z_])(ask_dir|ask_answer_file|snooze_file|relay_dir)|\.answer\.json|snoozes\.ndjson|inbox\.ndjson|outbox\.ndjson' \
      bin/chartroom lib/*.sh lib/*/*.sh lib/*.jq lib/*/*.jq lib/*/*.py |
    grep -vE '^lib/(ask|snooze|relay|tell|store)\.sh:' |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    grep -vE '^bin/chartroom:[0-9]+:[[:space:]]{20,}' |
    grep -vE '^lib/app/server\.py:.*for rel in \("\.changed", ' |
    cat || true)"
  if [ -n "$out" ]; then printf 'outside their modules:\n%s\n' "$out" >&2; return 1; fi
}

@test "a home keeps the database it was born in, whatever XDG_STATE_HOME says later" {
  unset CHARTROOM_DB
  store_on
  id="$(new_task)"
  first="$BATS_TEST_TMPDIR/state/chartroom/chartroom.db"
  [ -f "$first" ]
  [ "$(sed -n 2p "$CHARTROOM_HOME/.home-id")" = "$first" ]
  # Another context with another state dir (an ssh session, a GUI launcher) reads the same store.
  XDG_STATE_HOME="$BATS_TEST_TMPDIR/elsewhere" cr event "$id" progress "from elsewhere" >/dev/null
  events "$id" | grep -q 'progress: from elsewhere'
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/chartroom/chartroom.db" ]
}

@test "seams: no code outside lib/store.sh names a task's meta.json or events.log, but the known places" {
  # A read of tasks/<id>/meta.json or events.log of its own misses every store task: it must go
  # through meta_path, events_path or task_meta_files (lib/store.sh). The places allowed are the
  # seams' own file halves, names in lists, and the file-task loops the watch keeps.
  cat >"$BATS_TEST_TMPDIR/allowed" <<'PATTERNS'
^[^:]+:[0-9]+:[[:space:]]*#
^lib/store\.sh:
\$\{m%/meta\.json\}
CR_(DASHBOARD|RADAR)_FILES=
TASK_FILES = \(
# <id> .*<events\.log offset
\|tasks/\*/meta\.json\|tasks/\*/events\.log\|
files\+=\(events\.log\)
"\$file" == events\.log
name == "events\.log"
parts\[3\] == "events\.log"
has no events\.log of its own
^lib/core\.sh:.*\$\{META_PATH:-\$CR_HOME/tasks/\$1/meta\.json\}
^lib/core\.sh:.*meta_cache_load\(\) \{ # \[meta\.json files
^lib/core\.sh:.*f="\$\(tdir "\$1"\)/meta\.json"
^lib/core\.sh:.*>>"\$\(tdir "\$1"\)/events\.log"; fi
^bin/chartroom:.*for f in "\$CR_HOME"/tasks/\*/events\.log; do
^bin/chartroom:.*d="\$\{f%/events\.log\}"
^bin/chartroom:.*\[\[ -f "\$d/meta\.json" \]\] \|\| continue
^bin/chartroom:.*for f in "\$CR_HOME"/tasks/\*/meta\.json; do \[\[ "\$f" -ot
^lib/dashboard/server\.py:.*glob\.glob\(os\.path\.join\(base, "events\.log"\)\)
^lib/app/server\.py:.*GET  /api/v1/homes/<home>/tasks/<id>/files/
^lib/app/server\.py:.*FILE_RECORD = "meta\.json"
^lib/permit\.jq:.*def control_files\(\$R\): \[\$R\.task_dir \+ "/meta\.json"
PATTERNS
  cd "$REPO_ROOT"
  shopt -s nullglob
  # (every sh, jq and python file chartroom runs: the app's too, once it lands)
  out="$(grep -nE 'meta\.json|events\.log' bin/chartroom lib/*.sh lib/*/*.sh lib/*.jq lib/*/*.jq lib/*/*.py |
    grep -vE -f "$BATS_TEST_TMPDIR/allowed" || true)"
  if [ -n "$out" ]; then printf 'outside the seams:\n%s\n' "$out" >&2; return 1; fi
}
