#!/usr/bin/env bats
# A store task's status row (lib/store.py rows) and a file task's (status_rows' own reads of
# events.log) follow the same rules: the same events, with the same times, give the same row.

load test_helper

setup() {
  common_setup
  command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null || skip "no python3 with sqlite3"
  export CHARTROOM_DB="$BATS_TEST_TMPDIR/state/chartroom/chartroom.db"
  cr init >/dev/null
}

# Two tasks, one of each kind, dispatched on a command that ends at once, then the same event
# lines (with their own times) appended to each: the file task's events.log, the store task's
# spool. Sets F and S.
twin() {
  F="$(TITLE=file new_task --backend command --command true)"
  printf 'CHARTROOM_STORE=sqlite\n' >>"$CHARTROOM_HOME/config"
  S="$(TITLE=store new_task --backend command --command true)"
  sed -i.bak '/^CHARTROOM_STORE=/d' "$CHARTROOM_HOME/config"
  cr dispatch "$F" >/dev/null; cr dispatch "$S" >/dev/null
  wait_event "$F" ' exited: '; wait_event "$S" ' exited: '
  local l
  for l in "$@"; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
}

# The row without what differs by birth: id, title, times of the record (closed too), branch.
row() { cr status --json --all | jq -c --arg id "$1" '.[] | select(.id == $id) | del(.id, .short_id, .title, .created, .updated, .dispatched, .closed, .branch)'; }

same() {
  local f s
  f="$(row "$F")"; s="$(row "$S")"
  [ -n "$f" ]
  if [ "$f" != "$s" ]; then printf 'file:  %s\nstore: %s\n' "$f" "$s" >&2; return 1; fi
  printf '%s' "$f"
}

@test "parity: a report, a decision, a breaking blocker" {
  twin '2026-03-01T10:00:00Z progress: half way'
  [ "$(same | jq -r .state)" = stopped-silent ]
  for l in '2026-03-01T10:01:00Z decision: A or B? Options: (1) A (2) B RECOMMENDED' \
           '2026-03-01T10:02:00Z blocked: [breaking] prod is down'; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"; printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
  out="$(same)"
  [ "$(jq -r '[.state, .breaking, .last] | @tsv' <<<"$out")" = $'blocked\ttrue\tblocked: [breaking] prod is down' ]
}

@test "parity: done is review, accepted is done, a steer reopens it" {
  twin '2026-03-01T10:00:00Z done: PR ready'
  [ "$(same | jq -r .state)" = review ]
  for l in '2026-03-01T10:05:00Z note: accepted'; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"; printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
  [ "$(same | jq -r .state)" = done ]
  for l in '2026-03-01T10:06:00Z steered: one more thing'; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"; printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
  [ "$(same | jq -r .state)" = stopped-silent ]
}

@test "parity: waiting with an until, past and future, and a report that closes the wait" {
  twin '2026-03-01T10:00:00Z waiting: CI on PR 12 until 2099-01-05T15:30Z'
  out="$(same)"
  [ "$(jq -r '[.state, .waiting_until, .waiting_since] | @tsv' <<<"$out")" = $'waiting\t2099-01-05T15:30:00Z\t2026-03-01T10:00:00Z' ]
  for l in '2026-03-01T10:10:00Z waiting: review from a person until 2026-03-01T11:00:00Z'; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"; printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
  [ "$(same | jq -r .state)" = waiting-overdue ]
  for l in '2026-03-01T10:20:00Z decision: merge it?' '2026-03-01T10:21:00Z waiting: still on CI'; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"; printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
  # A decision since the dispatch outranks a later waiting: the task stays in decision.
  out="$(same)"
  [ "$(jq -c '[.state, .waiting_on]' <<<"$out")" = '["decision",null]' ]
}

@test "parity: a waiting with no until runs out after the max, and mentions name the other open task" {
  other="$(TITLE=other new_task)"
  # (A line with " note: " in it is never the last line shown, whatever its kind.)
  twin "2026-03-01T10:00:00Z waiting: on $other to land" "2026-03-01T10:01:00Z progress: note: see $other-x, not $other"
  out="$(same)"
  [ "$(jq -c '[.state, .waiting_on, .last, .mentions]' <<<"$out")" = '["stopped-silent",null,"waiting: on '"$other"' to land",["'"$other"'"]]' ]
  for l in '2026-03-01T10:02:00Z waiting: nothing named'; do
    printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$F/events.log"; printf '%s\n' "$l" >>"$CHARTROOM_HOME/tasks/$S/events.spool"
  done
  [ "$(same | jq -c '[.state, .waiting_until]')" = '["waiting-overdue",null]' ]
}

@test "parity: closed tasks, with --all and the board's --since window" {
  twin '2026-03-01T10:00:00Z done: shipped'
  cr close "$F" >/dev/null; cr close "$S" >/dev/null
  out="$(same)"
  [ "$(jq -r '[.state, .live, .last] | @tsv' <<<"$out")" = $'closed\t-\tdone: shipped' ]
  [ "$(cr status --json | jq length)" = 0 ]
}
