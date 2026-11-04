#!/usr/bin/env bats
# Parking idle hc:claude workers and resuming them (lib/park.sh), on the fake hc and herdr-app
# (test/fakes). The agent's process tree is a stand-in table (CHARTROOM_PS_FILE), and its
# transcript a file where Claude Code keeps one, under this test's HOME.

load test_helper
setup() {
  common_setup
  use_fake hc herdr-app claude
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc" FAKE_HERDR_APP_DIR="$BATS_TEST_TMPDIR/app"
  export CHARTROOM_PS_FILE="$BATS_TEST_TMPDIR/ps" FAKE_HC_EXITED=1
  mkdir -p "$FAKE_HC_DIR" "$FAKE_HERDR_APP_DIR"; : >"$CHARTROOM_PS_FILE"
}
teardown() {
  [[ -f "$BATS_TEST_TMPDIR/core.pid" ]] && kill "$(cat "$BATS_TEST_TMPDIR/core.pid")" 2>/dev/null
  [[ -n "${CORE_DIR:-}" ]] && rm -rf "$CORE_DIR"
  return 0
}

core_up() { # a listening socket where the core's lock file says (as in hc.bats)
  local d="$XDG_STATE_HOME/herdr-core/default" i
  CORE_DIR="$(mktemp -d /tmp/crpk.XXXXXX)"; SOCK="$CORE_DIR/s"
  mkdir -p "$d"; printf '%s\n' "$SOCK" >"$d/core.lock"
  perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die "$!"; while (my $c = $s->accept) { close $c }' "$SOCK" 3>&- &
  echo $! >"$BATS_TEST_TMPDIR/core.pid"
  for i in $(seq 1 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  return 1
}
refute() { if "$@"; then echo "expected to fail: $*" >&2; return 1; fi; }
hc_calls() { cat "$FAKE_HC_DIR/calls.log"; }
term() { jq -r "$2" "$FAKE_HC_DIR/terms/$1.json"; }
set_term() { local t="$1" f; shift; f="$FAKE_HC_DIR/terms/$t.json"; jq "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
set_meta() { local f="$CHARTROOM_HOME/tasks/$1/meta.json"; jq --arg k "$2" --arg v "$3" '.[$k] = $v' "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
live_of() { cr status --json | jq -r --arg i "$1" '.[] | select(.id == $i) | .live'; }
state_of() { cr status --json | jq -r --arg i "$1" '.[] | select(.id == $i) | .state'; }
watch_after() { # `watch --once` in the background; runs <change> once it has taken its first look
  cr watch --once --timeout "${WATCH_AFTER_TIMEOUT:-8}" >"$BATS_TEST_TMPDIR/wake" 2>&1 &
  local w=$!; sleep 1.5; "$@"; wait "$w" || true
}
transcript() { # <id> [session id]: the path Claude Code keeps its session's transcript at
  local wt sid; wt="$(meta_of "$1" worktree)"; sid="${2:-$(meta_of "$1" session_id)}"
  printf '%s/.claude/projects/%s/%s.jsonl' "$HOME" "${wt//[^A-Za-z0-9]/-}" "$sid"
}
# A dispatched hc:claude worker that reported <kind> and is at rest: its transcript, and its
# process tree (the launcher, claude, its MCP servers) in the stand-in table. Prints the id.
worker() { # <kind> <text>
  local id t pid
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  cr event "$id" "$1" "$2"
  t="$(meta_of "$id" hc_terminal)"; pid="$(term "$t" .pid)"
  mkdir -p "$(dirname "$(transcript "$id")")"
  printf '{"type":"user","message":{"content":"%s"}}\n' "Read the brief and follow it exactly. Your task id is $id." >"$(transcript "$id")"
  printf '%s 1 bash %s\n%s %s %s --session-id %s\n%s %s npm exec rea-agents@6.8.0 mcp\n%s %s node /x/rea mcp\n%s %s caffeinate -i -t 300\n' \
    "$pid" "$CHARTROOM_HOME/tasks/$id/launch.sh" "$((pid + 500))" "$pid" "$BIN/claude" "$(meta_of "$id" session_id)" \
    "$((pid + 501))" "$((pid + 500))" "$((pid + 502))" "$((pid + 501))" "$((pid + 503))" "$((pid + 500))" >>"$CHARTROOM_PS_FILE"
  # A first look, so a later --once watch starts after this history (home init leaves an
  # empty cursor, from which every log is read from its start).
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  printf '%s' "$id"
}
ago() { date -u -v-"$1"M "+$2" 2>/dev/null || date -u -d "$1 minutes ago" "+$2"; } # <minutes> <format>
at_rest_long() { # <id>: its history 90 minutes old, its agent at rest for 80 (a waiting window is still open)
  local f="$CHARTROOM_HOME/tasks/$1/events.log"
  sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/$(ago 90 %Y-%m-%dT%H:%M:%SZ)/" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  touch -t "$(date -v-90M +%Y%m%d%H%M 2>/dev/null || date -d '90 minutes ago' +%Y%m%d%H%M)" "$f"
  set_term "$(meta_of "$1" hc_terminal)" --argjson ms "$(( ($(date +%s) - 4800) * 1000 ))" '.status_ms = $ms'
}

@test "park: a dispatch gives claude a session id; the prompt hook records Claude's own" {
  core_up
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  sid="$(meta_of "$id" session_id)"
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
  grep -q -- "--session-id $sid " "$CHARTROOM_HOME/tasks/$id/launch.sh"
  refute grep -q "session id is now" "$CHARTROOM_HOME/tasks/$id/events.log"
  # Claude's word wins, with a note
  jq -cn '{prompt: "x", session_id: "11111111-1111-4111-8111-111111111111"}' | cr hook "$id" prompt-submit
  [ "$(meta_of "$id" session_id)" = 11111111-1111-4111-8111-111111111111 ]
  events "$id" | grep -q "note: session id is now 11111111-1111-4111-8111-111111111111 (was $sid)"
  # a worker started before chartroom chose ids gets its id at its next prompt
  set_meta "$id" session_id ""
  jq -cn '{prompt: "y", session_id: "22222222-2222-4222-8222-222222222222"}' | cr hook "$id" prompt-submit
  [ "$(meta_of "$id" session_id)" = 22222222-2222-4222-8222-222222222222 ]
  [ "$(grep -c 'session id is now' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 1 ]
}

@test "park: a worker at rest parks: screen kept, terminal ended and removed, live parked, no wake" {
  core_up
  id="$(worker done "finished; report.md")"; sid="$(meta_of "$id" session_id)"
  echo "the worker's last screen" >"$FAKE_HC_DIR/screen"
  watch_after cr park "$id"
  refute grep -q "^\[$id\]" "$BATS_TEST_TMPDIR/wake"
  hc_calls | grep -qx "kill t1"
  hc_calls | grep -qx "rm t1"
  [ ! -f "$FAKE_HC_DIR/terms/t1.json" ]
  grep -q "the worker's last screen" "$CHARTROOM_HOME/tasks/$id/pane.log"
  [ -n "$(meta_of "$id" parked)" ]
  # the park is on record before the launcher's exited line
  p="$(grep -n "note: parked (session $sid; review" "$CHARTROOM_HOME/tasks/$id/events.log" | cut -d: -f1)"
  e="$(grep -n "exited: agent session ended" "$CHARTROOM_HOME/tasks/$id/events.log" | cut -d: -f1)"
  [ -n "$p" ] && [ -n "$e" ] && [ "$p" -lt "$e" ]
  [ "$(live_of "$id")" = parked ]
  [ "$(state_of "$id")" = review ]
  run cr peek "$id"
  [[ "$output" == *"== parked since "*"(session $sid): steer or attach resumes it"* ]]
  [[ "$output" == *"the worker's last screen"* ]]
  run cr park "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not parked: it is already parked"* ]]
}

@test "park: never mid-turn, blocked, after a fresh prompt, with a tool command running, or without its session" {
  core_up
  id="$(worker decision "which colour?")"; t="$(meta_of "$id" hc_terminal)"; sid="$(meta_of "$id" session_id)"
  claude_pid="$(( $(term "$t" .pid) + 500 ))"
  set_term "$t" '.status.state = "working"'
  run cr park "$id"; [ "$status" -ne 0 ]; [[ "$output" == *"not parked: its agent is working"* ]]
  set_term "$t" '.status.state = "blocked"'
  run cr park "$id"; [[ "$output" == *"not parked: its agent is blocked"* ]]
  set_term "$t" '.status.state = "idle"'
  # a prompt that went in after its turn ended
  at_rest_long "$id"
  printf '%s steered: one more thing\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$CHARTROOM_HOME/tasks/$id/events.log"
  run cr park "$id"; [[ "$output" == *"not parked: a prompt went in after its turn ended"* ]]
  set_term "$t" --argjson ms "$(( ($(date +%s) + 5) * 1000 ))" '.status_ms = $ms'
  # a tool command still running under the agent (a dev server in the background), or any shell
  cp "$CHARTROOM_PS_FILE" "$BATS_TEST_TMPDIR/ps.clean"
  printf '%s %s /bin/zsh -c source %s/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval '"'"'npm run dev'"'"' < /dev/null && pwd -P >| /tmp/cwd\n9001 9000 node vite\n' \
    9000 "$claude_pid" "$HOME" >>"$CHARTROOM_PS_FILE"
  run cr park "$id"; [[ "$output" == *"not parked: a tool command is still running under its agent: npm run dev (pid 9000)"* ]]
  cp "$BATS_TEST_TMPDIR/ps.clean" "$CHARTROOM_PS_FILE"; printf '9002 %s bash -c sleep 600\n' "$claude_pid" >>"$CHARTROOM_PS_FILE"
  run cr park "$id"; [[ "$output" == *"a tool command is still running under its agent: bash -c sleep 600 (pid 9002)"* ]]
  cp "$BATS_TEST_TMPDIR/ps.clean" "$CHARTROOM_PS_FILE"
  # no transcript for its session
  mv "$(transcript "$id")" "$BATS_TEST_TMPDIR/tr"
  run cr park "$id"; [[ "$output" == *"not parked: no transcript for its session $sid"* ]]
  mv "$BATS_TEST_TMPDIR/tr" "$(transcript "$id")"
  # no recorded id, and no record of Claude Code's own that is this task's
  set_meta "$id" session_id ""
  run cr park "$id"; [[ "$output" == *"not parked: no session id is recorded for it"* ]]
  mkdir -p "$HOME/.claude/sessions"; other=33333333-3333-4333-8333-333333333333
  jq -cn --arg s "$other" '{sessionId: $s}' >"$HOME/.claude/sessions/$claude_pid.json"
  echo '{"type":"user","message":{"content":"another task"}}' >"$(transcript "$id" "$other")"
  run cr park "$id"; [[ "$output" == *"not parked: no session id is recorded for it"* ]]
  # ... while one whose transcript is this task's is taken, once, and noted
  jq -cn --arg s "$sid" '{sessionId: $s}' >"$HOME/.claude/sessions/$claude_pid.json"
  run cr park "$id"
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" session_id)" = "$sid" ]
  events "$id" | grep -q "note: session id $sid recorded from Claude Code's own session record"
  # not while the commander may be reading or typing into it: its tab is the one on screen
  id3="$(worker done "finished")"; meta_of "$id3" hc_tab >"$FAKE_HERDR_APP_DIR/shown"
  run cr park "$id3"; [[ "$output" == *"not parked: it is on screen in Herdr"* ]]
  rm -f "$FAKE_HERDR_APP_DIR/shown"
  # nor while Claude Code calls its session busy (work in its own process, a background agent)
  jq -cn '{status: "busy"}' >"$HOME/.claude/sessions/$(( $(term "$(meta_of "$id3" hc_terminal)" .pid) + 500 )).json"
  run cr park "$id3"; [[ "$output" == *"not parked: Claude Code reports its session busy"* ]]
  # nothing but hc:claude parks
  id2="$(new_task --backend hc:codex)"
  run cr park "$id2"; [[ "$output" == *"not parked: only hc:claude workers can be parked and resumed (this is hc:codex)"* ]]
}

@test "park: the watch parks a worker at rest for the grace, not one under it; a waiting one stays waiting" {
  core_up
  a="$(worker waiting "CI on the branch")"; at_rest_long "$a"
  b="$(worker done "finished")"; at_rest_long "$b"
  set_term "$(meta_of "$b" hc_terminal)" --argjson ms "$(( ($(date +%s) - 600) * 1000 ))" '.status_ms = $ms'
  c="$(worker done "finished just now")"
  run cr watch --once --timeout 4
  [ "$status" -eq 124 ]
  [ -n "$(meta_of "$a" parked)" ]
  [ "$(live_of "$a")" = parked ]
  [ "$(state_of "$a")" = waiting ]
  # b's log is old but its agent finished a turn 10 minutes ago: refused once, noted once
  [ -z "$(meta_of "$b" parked)" ]
  [ "$(grep -c 'note: not parked: at rest less than 60m' "$CHARTROOM_HOME/tasks/$b/events.log")" -eq 1 ]
  [ -z "$(meta_of "$c" parked)" ]
  run cr watch --once --timeout 3
  [ "$(grep -c 'note: not parked' "$CHARTROOM_HOME/tasks/$b/events.log")" -eq 1 ]
  # off at 0
  d="$(worker done "finished")"; at_rest_long "$d"
  CHARTROOM_PARK_AFTER_MINUTES=0 run cr watch --once --timeout 3
  [ -z "$(meta_of "$d" parked)" ]
}

@test "park: with hc's event stream up, the watch's park sees the terminal end from hc and stays parked" {
  core_up
  # The stream says nothing after the snapshot (the fake writes no line for a kill): its view of
  # the terminal stays live through the round, so only hc itself can say the terminal ended.
  export FAKE_HC_EVENTS=1 CHARTROOM_WATCH_HC_INTERVAL=30
  a="$(worker done "finished")"; at_rest_long "$a"
  t="$(meta_of "$a" hc_terminal)"
  : >"$FAKE_HC_DIR/calls.log"
  run cr watch --once --timeout 8
  [ "$status" -eq 124 ]
  hc_calls | grep -q '^events '
  [ -n "$(meta_of "$a" parked)" ]
  [ "$(live_of "$a")" = parked ]
  refute grep -q 'park undone' "$CHARTROOM_HOME/tasks/$a/events.log"
  hc_calls | grep -qx "kill $t"
  hc_calls | grep -qx "rm $t"
  [ ! -f "$FAKE_HC_DIR/terms/$t.json" ]
}

@test "park: steer resumes a parked worker in a fresh terminal: --resume, its tab, the message first" {
  core_up
  id="$(worker decision "which colour?")"; sid="$(meta_of "$id" session_id)"; tab="$(meta_of "$id" hc_tab)"
  cr park "$id" >/dev/null
  run cr steer "$id" "blue, then carry on"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resumed the parked session $sid (hc terminal t2)"* ]]
  [[ "$output" == *"delivered (the agent received the full text)"* ]]
  [ "$(term t2 .name)" = "$id" ]
  [ "$(term t2 '.labels["herdr.tab"]')" = "$tab" ]
  [ "$(term t2 '.argv[-1]')" = "blue, then carry on" ]
  grep -q -- "--resume $sid " "$CHARTROOM_HOME/tasks/$id/launch.sh"
  refute grep -q -- "--session-id" "$CHARTROOM_HOME/tasks/$id/launch.sh"
  [ -z "$(meta_of "$id" parked)" ]
  [ "$(meta_of "$id" hc_terminal)" = t2 ]
  events "$id" | grep -q "note: revived (session $sid, hc terminal t2) for steer"
  [ "$(live_of "$id")" = done ]
}

@test "park: attach resumes a parked worker with no prompt, then shows it" {
  core_up
  id="$(worker done "finished")"; sid="$(meta_of "$id" session_id)"
  cr park "$id" >/dev/null
  n="$(grep -c 'prompt-received' "$CHARTROOM_HOME/tasks/$id/events.log")"
  run cr attach "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resumed the parked session $sid (hc terminal t2)"* ]]
  [[ "$output" == *"showing $id in Herdr"* ]]
  [ "$(term t2 '.argv[-1]')" = "$CHARTROOM_HOME/tasks/$id/launch.sh" ]
  [ "$(grep -c 'prompt-received' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq "$n" ]
  grep -q "agent.focus --terminal t2" "$FAKE_HERDR_APP_DIR/calls.log"
  events "$id" | grep -q "note: revived (session $sid, hc terminal t2) for attach"
  [ "$(state_of "$id")" = review ]
}

@test "park: a revive that fails wakes the XO once and leaves the worker parked" {
  core_up
  id="$(worker decision "which colour?")"; sid="$(meta_of "$id" session_id)"
  cr park "$id" >/dev/null
  steer_fails() { FAKE_HC_RESUME_FAIL=1 cr steer "$id" "blue" >"$BATS_TEST_TMPDIR/out" 2>&1 && echo 0 >"$BATS_TEST_TMPDIR/rc" || echo $? >"$BATS_TEST_TMPDIR/rc"; }
  # (A resume that fails takes about 6 s to say so, which left about a second of the usual 8 here.
  # The watch ends at its first wake, so the longer limit costs nothing unless the wake never comes.)
  WATCH_AFTER_TIMEOUT=30 watch_after steer_fails
  [ "$(cat "$BATS_TEST_TMPDIR/rc")" -ne 0 ]
  grep -q "could not resume the parked worker of $id: claude --resume did not come up in hc terminal t2 (finished, exit 1): No conversation found with session ID: $sid" "$BATS_TEST_TMPDIR/out"
  # one wake, from the note; the dead resume's exited line is not news
  [ "$(grep -c "^\[$id\]" "$BATS_TEST_TMPDIR/wake")" -eq 1 ]
  grep -q "^\[$id\] .*note: revive failed: claude --resume did not come up" "$BATS_TEST_TMPDIR/wake"
  [ "$(grep -c 'exited: agent session ended (exit 1)' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 1 ]
  [ -n "$(meta_of "$id" parked)" ]
  [ ! -f "$FAKE_HC_DIR/terms/t2.json" ]
  [ "$(live_of "$id")" = parked ]
  # a gone worktree fails before any terminal starts
  mv "$(meta_of "$id" worktree)" "$BATS_TEST_TMPDIR/moved"
  run cr attach "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"its worktree $(meta_of "$id" worktree) is gone"* ]]
  mv "$BATS_TEST_TMPDIR/moved" "$(meta_of "$id" worktree)"
}

@test "park: after a revive, a steered turn ending without a report wakes, and a vanished terminal is lost" {
  core_up
  id="$(worker decision "which colour?")"
  cr park "$id" >/dev/null
  watch_after cr steer "$id" "blue"
  grep -q "^\[$id\] .*hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  watch_after rm -f "$FAKE_HC_DIR/terms/t2.json"
  grep -q "^\[$id\] .*lost: hc terminal t2 is no longer running" "$BATS_TEST_TMPDIR/wake"
}

@test "park: accept parks at once; dispatch starts a parked task afresh; close ends a parked one" {
  core_up
  id="$(worker done "finished")"; sid="$(meta_of "$id" session_id)"
  run cr accept "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"parked its worker (session $sid): steer or attach resumes it"* ]]
  [ "$(live_of "$id")" = parked ]
  [ "$(state_of "$id")" = done ]
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  events "$id" | grep -q "note: the parked session $sid is left behind: a dispatch starts a fresh worker"
  [ -z "$(meta_of "$id" parked)" ]
  [ "$(meta_of "$id" session_id)" != "$sid" ]
  id2="$(worker done "finished")"
  cr park "$id2" >/dev/null
  run cr close "$id2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed $id2"* ]]
}

@test "park: sweep lists a worker at rest as one to park, and --apply parks it" {
  core_up
  id="$(worker done "finished")"; at_rest_long "$id"
  run cr sweep --json
  [ "$status" -eq 0 ]
  [ "$(jq -c .parkable <<<"$output")" = "[\"$id\"]" ]
  [ -z "$(meta_of "$id" parked)" ]
  run cr sweep
  [[ "$output" == *"1 idle worker(s) to park"* ]]
  run cr sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 idle worker(s) parked"* ]]
  [ -n "$(meta_of "$id" parked)" ]
  grep -q "parked: $id" "$CHARTROOM_HOME/sweep.log"
}
