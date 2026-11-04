#!/usr/bin/env bats
# The doorbell (lib/core.sh): watch and listen wait on a FIFO of their own, and whatever writes
# a record rings it, so a wake comes at once instead of at the next round. Each watch here runs
# with a 30 s fallback round, so only a ring can wake it within the test's 2 s.

load test_helper
setup() {
  common_setup
  A="$BATS_TEST_TMPDIR/acme"; B="$BATS_TEST_TMPDIR/globex"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$B" cr init --name globex >/dev/null
  export CHARTROOM_HOME="$B"
}
teardown() { [[ -z "${STOPPED:-}" ]] || kill -CONT "$STOPPED" 2>/dev/null || true; }

# A home's FIFOs named <name>-<pid>.fifo, one path per line.
fifos() { ls "$CHARTROOM_RUNTIME_DIR"/chartroom-*/bells/"$(basename "$1")"-*/"$2"-*.fifo 2>/dev/null || true; }
# Wait until a listener of that name is armed in the home; prints its pid.
armed() { # <home> <name>
  local f
  for _ in $(seq 1 100); do
    f="$(fifos "$1" "$2" | head -1)"
    [[ -n "$f" ]] && { f="${f%.fifo}"; echo "${f##*-}"; return 0; }
    sleep 0.1
  done
  echo "no $2 armed in $1" >&2; return 1
}
# Fails unless the process ends within <secs>, killing it then.
ends_within() { # <pid> <secs>
  for _ in $(seq 1 $(($2 * 10))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  kill -9 "$1" 2>/dev/null; echo "pid $1 still running after $2s" >&2; return 1
}

@test "event wakes a watch --once within 2 s, long before its fallback round" {
  id="$(new_task --backend command --command "$STUB {id}")"
  CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 20 >"$BATS_TEST_TMPDIR/w" 2>&1 3>&- &
  w=$!
  armed "$B" watch
  sleep 1 # its first full round is over: from here only a ring or the round in 30 s wakes it
  cr event "$id" decision "pick A or B"
  ends_within "$w" 2
  wait "$w"
  [ "$(grep -c . "$BATS_TEST_TMPDIR/w")" -eq 1 ]
  grep -q "^\[$id\] \[proj\] .* decision: pick A or B$" "$BATS_TEST_TMPDIR/w"
  [ -z "$(fifos "$B" watch)" ]
  # a stream too, for every rung event; stopping it removes its FIFO
  CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch >"$BATS_TEST_TMPDIR/s" 2>&1 3>&- &
  s=$!
  armed "$B" watch
  sleep 1
  cr event "$id" blocked "needs a token"
  cr event "$id" decision "and a name"
  for _ in $(seq 1 20); do [ "$(grep -c . "$BATS_TEST_TMPDIR/s")" -ge 2 ] && break; sleep 0.1; done
  kill "$s"; wait "$s" 2>/dev/null || true
  [ "$(grep -c . "$BATS_TEST_TMPDIR/s")" -eq 2 ]
  grep -q 'blocked: needs a token$' "$BATS_TEST_TMPDIR/s"
  grep -q 'decision: and a name$' "$BATS_TEST_TMPDIR/s"
  [ -z "$(fifos "$B" watch)" ]
}

@test "a relay wakes the other home's watch within 2 s" {
  CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 20 >"$BATS_TEST_TMPDIR/w" 2>&1 3>&- &
  w=$!
  armed "$B" watch
  sleep 1
  rid="$(CHARTROOM_HOME="$A" cr relay globex "the shared bucket moves on Friday")"
  ends_within "$w" 2
  wait "$w"
  [ "$(cat "$BATS_TEST_TMPDIR/w")" = "[relay $rid] [from acme] the shared bucket moves on Friday" ]
}

@test "a raw append to events.log, which rings nothing, is still seen by the fallback round" {
  id="$(new_task --backend command --command "$STUB {id}")"
  CHARTROOM_WATCH_INTERVAL=2 "$CHARTROOM" watch --once --timeout 20 >"$BATS_TEST_TMPDIR/w" 2>&1 3>&- &
  w=$!
  armed "$B" watch
  sleep 0.5
  printf '%s decision: written by hand\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$B/tasks/$id/events.log"
  ends_within "$w" 5
  wait "$w"
  grep -q "^\[$id\] \[proj\] .* decision: written by hand$" "$BATS_TEST_TMPDIR/w"
}

@test "a killed listener's FIFO: a ring into its home removes it at once; a relay from another home leaves it" {
  id="$(new_task --backend command --command "$STUB {id}")"
  CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 20 >/dev/null 2>&1 3>&- &
  w=$!
  p="$(armed "$B" watch)"
  kill -9 "$p"; wait "$w" 2>/dev/null || true
  [ -n "$(fifos "$B" watch)" ]
  # another home only rings: it never removes what is not its own
  CHARTROOM_HOME="$A" "$CHARTROOM" relay globex "anyone home?" >/dev/null 3>&- &
  r=$!
  ends_within "$r" 5
  [ -n "$(fifos "$B" watch)" ]
  # the home's own ringer sees the listener is gone, removes its FIFO, and never waits on it
  "$CHARTROOM" event "$id" progress "ring a dead bell" 3>&- &
  e=$!
  ends_within "$e" 2
  wait "$e"
  [ -z "$(fifos "$B" watch)" ]
}

@test "a stopped listener never blocks a ringer, even with its FIFO full; it wakes once continued" {
  command -v perl >/dev/null || skip "perl fills the FIFO"
  id="$(new_task --backend command --command "$STUB {id}")"
  CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 30 >"$BATS_TEST_TMPDIR/w" 2>&1 3>&- &
  w=$!
  p="$(armed "$B" watch)"
  sleep 1
  kill -STOP "$p"; STOPPED="$p"
  # Fill the stopped listener's FIFO to the brim (no ring coalesces like this): a ringer that
  # wrote without looking would now block for good.
  f="$(fifos "$B" watch)"
  n="$(perl -MFcntl -e 'sysopen(my $f, $ARGV[0], O_RDWR | O_NONBLOCK) or die; my $n = 0;
    while (defined(my $w = syswrite($f, "." x 512))) { $n += $w } print $n' "$f")"
  [ "$n" -gt 0 ]
  # many rings through the library, and real events
  bash -c 'source "$1/lib/core.sh"; load_config; for i in $(seq 1 500); do bell_ring "" watch; done' _ "$REPO_ROOT" 3>&- &
  r=$!
  ends_within "$r" 20
  for i in 1 2 3; do
    "$CHARTROOM" event "$id" progress "ring $i while it is stopped" 3>&- &
    e=$!
    ends_within "$e" 5
  done
  "$CHARTROOM" event "$id" decision "asked while it was stopped" 3>&- &
  e=$!
  ends_within "$e" 5
  kill -CONT "$p"; STOPPED=""
  ends_within "$w" 10
  wait "$w"
  grep -q 'decision: asked while it was stopped$' "$BATS_TEST_TMPDIR/w"
}

@test "listen returns within 2 s of steer, through its doorbell" {
  export CLAUDECODE=1 CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=sess-1 CHARTROOM_JOIN_ACK_WAIT=5
  id="$(cd "$PROJECT" && cr join --title mail | sed -n 's/^id=//p')"
  "$CHARTROOM" listen "$id" >"$BATS_TEST_TMPDIR/l" 2>&1 3>&- &
  l=$!
  armed "$B" "listen-$id"
  [ -n "$(fifos "$B" "listen-$id")" ]
  "$CHARTROOM" steer "$id" "please rebase" >"$BATS_TEST_TMPDIR/s" 3>&- &
  s=$!
  ends_within "$l" 2
  wait "$l"
  grep -q '^please rebase$' "$BATS_TEST_TMPDIR/l"
  wait "$s"
  [ "$(cat "$BATS_TEST_TMPDIR/s")" = "delivered (message #1 read by the agent)" ]
  [ -z "$(fifos "$B" "listen-$id")" ]
}

@test "the full round reads every task's meta.json with one jq, not several per task" {
  real_jq="$(readlink "$BIN/jq")" # (the test PATH's jq is a link to it; replaced, never written through)
  for i in 1 2 3 4 5 6 7 8; do ids+=("$(new_task --backend command --command "$STUB {id}")"); done
  # two closed tasks, and one whose meta.json is not JSON (it sorts first, so every task after
  # it is read the old way: one jq per key)
  cr close "${ids[6]}" >/dev/null; cr close "${ids[7]}" >/dev/null
  mkdir -p "$B/tasks/a-broken"; echo '{"id": "a-br' >"$B/tasks/a-broken/meta.json"; : >"$B/tasks/a-broken/events.log"
  rm "$BIN/jq"
  printf '#!/bin/sh\necho call >>"%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/jq.calls" "$real_jq" >"$BIN/jq"; chmod +x "$BIN/jq"
  run env CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 1
  [ "$status" -eq 124 ]
  slow="$(wc -l <"$BATS_TEST_TMPDIR/jq.calls")"
  rm "$B/tasks/a-broken/meta.json" "$BATS_TEST_TMPDIR/jq.calls"
  run env CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 1
  [ "$status" -eq 124 ]
  fast="$(wc -l <"$BATS_TEST_TMPDIR/jq.calls")"
  # startup, then a round on each side of the 1 s wait: one jq each, whatever the task count
  [ "$fast" -le 3 ]
  [ "$slow" -gt $((fast + 8)) ]
  # what the round decides is unchanged: an open task wakes, a closed one never does
  rm "$BIN/jq"; ln -s "$real_jq" "$BIN/jq"
  cr event "${ids[7]}" decision "from a closed task"
  cr event "${ids[0]}" decision "from an open task"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == "[${ids[0]}] [proj] "*"decision: from an open task" ]]
}
