#!/usr/bin/env bats
# The app's server (lib/app/server.py): loopback only, the owner's Tailscale identity or nothing,
# no cross-site writes, every write a chartroom verb, every home on the machine, and the stream.
# Invented data only (test/app_fixture.bash). Needs python3 and curl.

load test_helper
load app_fixture

setup() {
  common_setup
  PY="$(type -P python3 || true)"
  [[ -n "$PY" ]] || skip "python3 not available"
  link_tool "$PY" python3
  export CHARTROOM="$REPO_ROOT/bin/chartroom"
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  export CHARTROOM_TAILSCALE=none CHARTROOM_OPENER=echo
}

teardown() { cr app stop >/dev/null 2>&1 || true; }

start() { # [serve args...]: start on a free port; sets PORT
  run cr app serve --daemon --port 0 "$@"
  echo "$output"
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  [[ "$PORT" =~ ^[0-9]+$ ]]
}
get() { curl -s -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' "$@"; }
post() { # <path> <json> [curl args...]
  local p="$1" j="$2"; shift 2
  curl -s -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$j" "$@" "http://127.0.0.1:$PORT$p"
}
# act <home> <action> <json> [action-id]: a write as the app makes it; prints the HTTP code
act() {
  curl -s -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' \
    ${4:+-H "X-Chartroom-Action: $4"} -d "$3" "http://127.0.0.1:$PORT/api/v1/homes/$1/$2"
}
# outcome <action-id>: waits for the action to finish; prints done or failed, then its error
outcome() {
  local i st
  for i in $(seq 1 150); do
    st="$(curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -r --arg id "$1" '.actions[$id] | if . == null then "unknown" else "\(.state)\t\(.error // "")" end')"
    case "$st" in done*|failed*) printf '%s\n' "$st"; return 0 ;; esac
    sleep 0.1
  done
  echo "timeout $st"; return 1
}
state() { # waits for both homes' first snapshot
  local i
  for i in $(seq 1 100); do
    curl -s "http://127.0.0.1:$PORT/api/v1/state" >"$BATS_TEST_TMPDIR/state"
    jq -e '[.homes[] | select(.snapshot != null)] | length == 2' "$BATS_TEST_TMPDIR/state" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  cat "$BATS_TEST_TMPDIR/state"; return 1
}

@test "serve: without CHARTROOM_APP_USER it refuses to start, unless --no-auth" {
  run cr app serve --daemon --port 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHARTROOM_APP_USER"* ]]
  start --no-auth
  [ "$(get "http://127.0.0.1:$PORT/healthz")" = 200 ]
}

@test "auth: only the configured Tailscale login gets in; /healthz needs nobody" {
  printf 'CHARTROOM_APP_USER=owner@example.com\n' >"$CHARTROOM_CONFIG"
  start
  [ "$(get "http://127.0.0.1:$PORT/healthz")" = 200 ]
  [ "$(get "http://127.0.0.1:$PORT/api/v1/state")" = 403 ]
  [ "$(get -H 'Tailscale-User-Login: someone@example.com' "http://127.0.0.1:$PORT/api/v1/state")" = 403 ]
  [ "$(get -H 'Tailscale-User-Login: Owner@Example.com' "http://127.0.0.1:$PORT/")" = 200 ]
  grep -q '<title>Chartroom</title>' "$BATS_TEST_TMPDIR/body"
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}' -H 'X-Chartroom-App: 1')" = 403 ]
}

@test "auth: --no-auth serves only requests made straight to 127.0.0.1, never through a proxy" {
  start --no-auth
  [ "$(get "http://127.0.0.1:$PORT/api/v1/state")" = 200 ]
  [ "$(get "http://localhost:$PORT/api/v1/state")" = 200 ]
  [ "$(get -H 'X-Forwarded-For: 100.64.0.9' "http://127.0.0.1:$PORT/api/v1/state")" = 403 ]
  [ "$(get -H 'Tailscale-User-Login: owner@example.com' "http://127.0.0.1:$PORT/api/v1/state")" = 403 ]
  [ "$(get -H 'Host: studio.example.ts.net' "http://127.0.0.1:$PORT/api/v1/state")" = 403 ]
}

@test "state: every home on the machine, a client home left out" {
  mkdir -p "$BATS_TEST_TMPDIR/h/client"
  CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/client" cr init >/dev/null
  printf 'CHARTROOM_BRAIN=studio\n' >>"$BATS_TEST_TMPDIR/h/client/config"
  cr homes add client "$BATS_TEST_TMPDIR/h/client" >/dev/null
  start --no-auth
  state
  [ "$(jq -r '[.homes[].name] | join(" ")' "$BATS_TEST_TMPDIR/state")" = "acme globex" ]
  [ "$(jq -r '[.homes[].snapshot.counts.needs] | add' "$BATS_TEST_TMPDIR/state")" -eq 13 ]
}

@test "writes: only from the app (its header, JSON, same origin)" {
  start --no-auth
  state
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}')" = 403 ]
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}' -H 'X-Chartroom-App: 1' -H 'Sec-Fetch-Site: cross-site')" = 403 ]
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}' -H 'X-Chartroom-App: 1' -H 'Origin: http://evil.example')" = 403 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Chartroom-App: 1' -H 'Content-Type: text/plain' -d hi "http://127.0.0.1:$PORT/api/v1/homes/acme/tell")" = 403 ]
  [ "$(cr tell list --all --json | jq '[.[] | select(.text == "hi")] | length')" -eq 0 ]
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi from the app","re":"i-1234"}' -H 'X-Chartroom-App: 1' -H 'X-Chartroom-Action: a-test-0001' -H "Origin: http://127.0.0.1:$PORT")" = 202 ]
  [ "$(outcome a-test-0001)" = "done	" ]
  [ "$(cr tell list --json | jq -r '.[0] | "\(.via) \(.re) \(.text)"')" = "app i-1234 hi from the app" ]
}

@test "writes: an answer runs ask answer in that home; a second answer is refused" {
  start --no-auth
  state
  card="$(jq -r '.homes[] | select(.name == "globex") | .snapshot.needs[] | select(.title | test("Rate limits")) | .card' "$BATS_TEST_TMPDIR/state")"
  [ "$(act globex answer "{\"card\":\"$card\",\"answers\":[{\"q\":1,\"choice\":\"Per partner\"}]}" a-test-0002)" = 202 ]
  [ "$(outcome a-test-0002)" = "done	" ]
  [ -f "$BATS_TEST_TMPDIR/h/globex/questions/$card.answer.json" ]
  [ "$(act globex answer "{\"card\":\"$card\",\"answers\":[{\"q\":1,\"note\":\"x\"}]}" a-test-0003)" = 202 ]
  [[ "$(outcome a-test-0003)" == "failed	"*"already answered"* ]]
  # a card id that is not one is refused before anything runs
  [ "$(post /api/v1/homes/globex/answer '{"card":"../../etc"}' -H 'X-Chartroom-App: 1')" = 400 ]
}

@test "writes: snooze, accept and mark done go through their verbs" {
  start --no-auth
  state
  ref="$(jq -r '.homes[0].snapshot.needs[] | select(.title | test("Gift cards")) | .ref' "$BATS_TEST_TMPDIR/state")"
  [ "$(act acme snooze "{\"ref\":\"$ref\",\"for\":\"1h\"}" a-test-0004)" = 202 ]
  [ "$(outcome a-test-0004)" = "done	" ]
  [ "$(cr snooze list --json | jq -r --arg r "$ref" '.[$r] != null')" = true ]
  task="$(jq -r '.homes[0].snapshot.needs[] | select(.kind == "review") | .task' "$BATS_TEST_TMPDIR/state")"
  [ "$(act acme accept "{\"task\":\"$task\"}" a-test-0005)" = 202 ]
  [ "$(outcome a-test-0005)" = "done	" ]
  events "$task" | grep -q ' note: accepted'
  inbox="$(jq -r '[.homes[0].snapshot.needs[] | select(.kind == "inbox") | .ref] | first' "$BATS_TEST_TMPDIR/state")"
  [ "$(act acme "done" "{\"ref\":\"$inbox\"}" a-test-0006)" = 202 ]
  [ "$(outcome a-test-0006)" = "done	" ]
  run grep -q "$inbox" "$CHARTROOM_HOME/inbox.md"
  [ "$status" -ne 0 ]
  [ "$(post /api/v1/homes/acme/close '{"task":"--discard"}' -H 'X-Chartroom-App: 1')" = 400 ]
}

@test "files: the app's own files and a task's records; nothing outside them" {
  start --no-auth
  state
  [ "$(get "http://127.0.0.1:$PORT/app/src/model.js")" = 200 ]
  [ "$(get "http://127.0.0.1:$PORT/shared/eventfmt.js")" = 200 ]
  [ "$(get --path-as-is "http://127.0.0.1:$PORT/app/../lib/app/server.py")" = 404 ]
  [ "$(get "http://127.0.0.1:$PORT/app/%2e%2e/lib/app/server.py")" = 404 ]
  [ "$(get "http://127.0.0.1:$PORT/shared/server.py")" = 404 ]
  task="$(jq -r '.homes[0].snapshot.tasks[0].id' "$BATS_TEST_TMPDIR/state")"
  [ "$(get "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$task/files/brief.md")" = 200 ]
  [ "$(get "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$task/files/meta.json")" = 404 ]
  # its events, from its events.log or (a store task's) from the store
  [ "$(get "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$task/files/events.log")" = 200 ]
  grep -q ' note: created' "$BATS_TEST_TMPDIR/body"
  plain="$(jq -r '.homes[0].snapshot.tasks[] | select(.title | test("Pick a cache")) | .id' "$BATS_TEST_TMPDIR/state")"
  [ "$(get "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$plain/files/report.md")" = 204 ]
  [ "$(get "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/..%2F..%2Fx/files/brief.md")" = 404 ]
}

@test "stream: a write in a home reaches the stream as a new version" {
  start --no-auth
  state
  v0="$(jq -r .version "$BATS_TEST_TMPDIR/state")"
  ( curl -s -N --max-time 8 "http://127.0.0.1:$PORT/api/v1/stream" >"$BATS_TEST_TMPDIR/sse" 3>&- & )
  sleep 0.5
  cr tell "a new note" >/dev/null
  for _ in $(seq 1 40); do
    v="$(grep '^data: ' "$BATS_TEST_TMPDIR/sse" | tail -1 | sed 's/^data: //')"
    [[ -n "$v" && "$v" -gt "$v0" ]] && break
    sleep 0.2
  done
  [[ -n "$v" && "$v" -gt "$v0" ]]
}

@test "sweep: the app server is not a daemon for sweep to reap, wherever it was started" {
  # started from a task's worktree: sweep reaps what still runs there once the task closes
  task="$(cr status --json | jq -r '.[] | select(.title | test("stock badge")) | .id')"
  wt="$(cr worktree "$task" | tail -1)"
  cd "$wt"
  start --no-auth
  pid="$(awk '{print $1}' "$BATS_TEST_TMPDIR/app.pid")"
  cd "$BATS_TEST_TMPDIR"
  cr close "$task" >/dev/null
  run cr sweep --json
  [ "$status" -eq 0 ]
  [ "$(jq --argjson p "$pid" '[.items[] | select((.pids // [.pid]) | index($p))] | length' <<<"$output")" -eq 0 ]
}

@test "open: this machine's browser gets 127.0.0.1 only from a --no-auth server; otherwise Serve's URL" {
  printf 'CHARTROOM_APP_USER=owner@example.com\n' >"$CHARTROOM_CONFIG"
  start
  run cr app open
  [ "$status" -ne 0 ]
  [[ "$output" == *"not pointed at it yet"* ]]
  # a fake Serve pointed at the app
  printf '#!/bin/sh\nprintf "https://brain.example.ts.net (tailnet only)\\n|-- / proxy http://127.0.0.1:%%s\\n" "%s"\n' "$PORT" >"$BIN/fake-ts"
  chmod +x "$BIN/fake-ts"
  CHARTROOM_TAILSCALE="$BIN/fake-ts" run cr app open
  [ "$status" -eq 0 ]
  [ "$output" = "app open: https://brain.example.ts.net" ]
  CHARTROOM_TAILSCALE="$BIN/fake-ts" run cr app doctor
  [[ "$output" == *"tailscale serve: on: https://brain.example.ts.net"* ]]
  cr app stop >/dev/null
  run cr app open --no-auth --port 0
  [ "$status" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "app open: http://127.0.0.1:"* ]]
}

@test "actions: accepted at once and run in the background; the same id never runs twice, even after a restart" {
  start --no-auth
  state
  # accepted before the verb has run: the answer is 202 and the action is queued or running
  [ "$(act acme tell '{"text":"one"}' a-dedupe-0001)" = 202 ]
  [[ "$(jq -r .state "$BATS_TEST_TMPDIR/body")" =~ ^(queued|running|done)$ ]]
  [ "$(outcome a-dedupe-0001)" = "done	" ]
  # a retry of the same action (the page lost the answer, say) is the same action
  [ "$(act acme tell '{"text":"one"}' a-dedupe-0001)" = 202 ]
  [ "$(jq -r .state "$BATS_TEST_TMPDIR/body")" = "done" ]
  [ "$(cr tell list --json | jq '[.[] | select(.text == "one")] | length')" -eq 1 ]
  # the journal keeps it across a restart
  cr app stop >/dev/null
  start --no-auth
  state
  [ "$(act acme tell '{"text":"one"}' a-dedupe-0001)" = 202 ]
  [ "$(jq -r .state "$BATS_TEST_TMPDIR/body")" = "done" ]
  [ "$(cr tell list --json | jq '[.[] | select(.text == "one")] | length')" -eq 1 ]
  # a failure is reported, not hidden
  [ "$(act acme close '{"task":"no-such-task-0000"}' a-fail-0001)" = 202 ]
  [[ "$(outcome a-fail-0001)" == "failed	"*"no-such-task-0000"* ]]
}

@test "actions: one accepted but never run (the server stopped first) runs when the server starts again" {
  start --no-auth
  state
  cr app stop >/dev/null
  printf '%s\n' '{"id":"a-replay-0001","home":"acme","action":"tell","argv":["tell","--via","app","-"],"stdin":"left in the journal","cleanup":null,"state":"queued","error":null,"at":"2026-01-01T00:00:00Z","done_at":null}' >>"$BATS_TEST_TMPDIR/app-actions.ndjson"
  start --no-auth
  state
  [ "$(outcome a-replay-0001)" = "done	" ]
  [ "$(cr tell list --json | jq '[.[] | select(.text == "left in the journal")] | length')" -eq 1 ]
}

@test "bulk close: one entry per item; a task with work it cannot keep refuses on its own and says why" {
  ok_task="$(cr status --json | jq -r '.[] | select(.title | test("stock badge")) | .id')"
  dirty="$(cr status --json | jq -r '.[] | select(.title | test("Gift cards")) | .id')"
  wt="$(cr worktree "$dirty" | tail -1)"
  echo "unsaved work" >"$wt/notes.txt"
  start --no-auth
  state
  [ "$(act acme close "{\"task\":\"$ok_task\"}" a-bulk-0001)" = 202 ]
  [ "$(act acme close "{\"task\":\"$dirty\"}" a-bulk-0002)" = 202 ]
  [ "$(outcome a-bulk-0001)" = "done	" ]
  out="$(outcome a-bulk-0002)"
  [[ "$out" == "failed	refusing to close $dirty: uncommitted work in "* ]]
  [ -f "$wt/notes.txt" ]
  [ -z "$(meta_of "$dirty" closed)" ]
}

@test "delivery: the state says when the XOs' own chartroom cannot read what the app sends" {
  # an older chartroom: no tell, so no XO would ever wake on an answer from the app
  printf '#!/bin/sh\necho "usage: chartroom new ... chartroom relay ..."\n' >"$BIN/old-chartroom"
  chmod +x "$BIN/old-chartroom"
  CHARTROOM_XO_BIN="$BIN/old-chartroom" start --no-auth
  state
  [ "$(jq -r '.xo.reads_app' "$BATS_TEST_TMPDIR/state")" = false ]
  cr app stop >/dev/null
  CHARTROOM_XO_BIN="$CHARTROOM" start --no-auth
  state
  [ "$(jq -r '.xo.reads_app' "$BATS_TEST_TMPDIR/state")" = true ]
}
