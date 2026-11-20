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
  [ "$(jq -r '[.homes[].snapshot.counts.needs] | add' "$BATS_TEST_TMPDIR/state")" -eq 9 ]
}

@test "writes: only from the app (its header, JSON, same origin)" {
  start --no-auth
  state
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}')" = 403 ]
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}' -H 'X-Chartroom-App: 1' -H 'Sec-Fetch-Site: cross-site')" = 403 ]
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi"}' -H 'X-Chartroom-App: 1' -H 'Origin: http://evil.example')" = 403 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Chartroom-App: 1' -H 'Content-Type: text/plain' -d hi "http://127.0.0.1:$PORT/api/v1/homes/acme/tell")" = 403 ]
  [ ! -s "$CHARTROOM_HOME/relays/inbox.ndjson" ]
  [ "$(post /api/v1/homes/acme/tell '{"text":"hi from the app","re":"i-1234"}' -H 'X-Chartroom-App: 1' -H "Origin: http://127.0.0.1:$PORT")" = 200 ]
  [ "$(cr tell list --json | jq -r '.[0] | "\(.via) \(.re) \(.text)"')" = "app i-1234 hi from the app" ]
}

@test "writes: an answer runs ask answer in that home; a second answer is refused" {
  start --no-auth
  state
  card="$(jq -r '.homes[] | select(.name == "globex") | .snapshot.needs[] | select(.title | test("Rate limits")) | .card' "$BATS_TEST_TMPDIR/state")"
  [ "$(post /api/v1/homes/globex/answer "{\"card\":\"$card\",\"answers\":[{\"q\":1,\"choice\":\"Per partner\"}]}" -H 'X-Chartroom-App: 1')" = 200 ]
  [ -f "$BATS_TEST_TMPDIR/h/globex/questions/$card.answer.json" ]
  [ "$(post /api/v1/homes/globex/answer "{\"card\":\"$card\",\"answers\":[{\"q\":1,\"note\":\"x\"}]}" -H 'X-Chartroom-App: 1')" = 409 ]
  [[ "$(jq -r .error "$BATS_TEST_TMPDIR/body")" == *"already answered"* ]]
  # a card id that is not one is refused before anything runs
  [ "$(post /api/v1/homes/globex/answer '{"card":"../../etc"}' -H 'X-Chartroom-App: 1')" = 400 ]
}

@test "writes: snooze, accept and mark done go through their verbs" {
  start --no-auth
  state
  ref="$(jq -r '.homes[0].snapshot.needs[] | select(.title | test("Gift cards")) | .ref' "$BATS_TEST_TMPDIR/state")"
  [ "$(post /api/v1/homes/acme/snooze "{\"ref\":\"$ref\",\"for\":\"1h\"}" -H 'X-Chartroom-App: 1')" = 200 ]
  [ "$(cr snooze list --json | jq -r --arg r "$ref" '.[$r] != null')" = true ]
  task="$(jq -r '.homes[0].snapshot.needs[] | select(.kind == "review") | .task' "$BATS_TEST_TMPDIR/state")"
  [ "$(post /api/v1/homes/acme/accept "{\"task\":\"$task\"}" -H 'X-Chartroom-App: 1')" = 200 ]
  grep -q ' note: accepted' "$CHARTROOM_HOME/tasks/$task/events.log"
  inbox="$(jq -r '.homes[0].snapshot.needs[] | select(.kind == "inbox") | .ref' "$BATS_TEST_TMPDIR/state")"
  [ "$(post /api/v1/homes/acme/done "{\"ref\":\"$inbox\"}" -H 'X-Chartroom-App: 1')" = 200 ]
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
  run cr app open --no-auth
  [ "$status" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "app open: http://127.0.0.1:"* ]]
}
