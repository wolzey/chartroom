#!/usr/bin/env bats
# `chartroom dashboard`: lane classification from hand-written task records, and the
# loopback-only server (start/stop, ports, endpoints). No network, no real gh.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
  PY="$(type -P python3 || true)"
}

teardown() {
  cr dashboard stop >/dev/null 2>&1 || true
  [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true
}

ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# fixture <id> <backend> [key=value ...]: a task record written directly (no dispatch).
# Keys: dispatched=<secs ago>|"" closed=<secs ago> pid=N project=P. Events come on stdin as
# "<secs ago> <kind>: <text>" lines.
fixture() {
  local id="$1" backend="$2" d kv k v dispatched=7200 closed="" pid="" project="/srv/code/todo-cli"
  shift 2
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in dispatched) dispatched="$v" ;; closed) closed="$v" ;; pid) pid="$v" ;; project) project="$v" ;; esac
  done
  d="$CHARTROOM_HOME/tasks/$id"; mkdir -p "$d"
  jq -n --arg id "$id" --arg b "$backend" --arg p "$project" --arg c "$(ago 9000)" \
    --arg disp "$([[ -n "$dispatched" ]] && ago "$dispatched")" --arg closed "$([[ -n "$closed" ]] && ago "$closed")" --arg pid "$pid" \
    '{schema:1,id:$id,title:("Task " + $id),kind:"ship",backend:$b,project:$p,branch:("chartroom/" + $id),created:$c,updated:$c}
     + (if $disp != "" then {dispatched:$disp} else {} end)
     + (if $closed != "" then {closed:$closed} else {} end)
     + (if $pid != "" then {pid:$pid} else {} end)' >"$d/meta.json"
  : >"$d/events.log"
  [[ -n "$dispatched" ]] && printf '%s note: dispatched via %s\n' "$(ago "$dispatched")" "$backend" >>"$d/events.log"
  local secs rest
  while read -r secs rest; do
    [[ -n "$secs" ]] && printf '%s %s\n' "$(ago "$secs")" "$rest" >>"$d/events.log"
  done
  return 0
}

lane_ids() { jq -r --arg l "$1" '.lanes[$l] | map(.id) | join(" ")' <<<"$BOARD"; }
card() { jq -c --arg id "$1" '[.lanes[][] | select(.id == $id)][0]' <<<"$BOARD"; }

build_fleet() {
  fixture t-decision subagent <<<"600 decision: pick option A or B (recommend A)"
  fixture t-blocked subagent <<<"6000 blocked: need staging credentials"
  fixture t-failed subagent <<<"300 failed: tests do not build"
  fixture t-working subagent <<<"120 progress: parser rewritten, running tests"
  fixture t-waiting subagent <<<"200 progress: waiting on the design team to confirm the copy"
  fixture t-silent command pid=2147480000 <<<"500 progress: halfway"
  fixture t-report subagent <<<"400 done: findings in report.md"
  echo "# Report" >"$CHARTROOM_HOME/tasks/t-report/report.md"
  fixture t-pr subagent <<'EOF'
900 progress: opened https://github.com/acme/todo-cli/pull/7 (draft)
800 done: PR https://github.com/acme/todo-cli/pull/7 ready
EOF
  printf 'See https://github.com/acme/todo-cli/pull/7 and https://gitlab.example.com/acme/todo-cli/-/merge_requests/3.\n' \
    >"$CHARTROOM_HOME/tasks/t-pr/report.md"
  fixture t-closed-recent subagent closed=7200 <<<"7300 done: merged"
  fixture t-closed-old subagent closed=432000 <<<"432100 done: shipped long ago"
  fixture t-draft subagent dispatched= </dev/null
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF'
# Inbox

## Waiting on the commander
- 2026-01-02 — merge the parser PR?
- which region for staging?

## Approvals given in chat, not yet in a brief
- 2026-01-03 — ok to rotate the test key

## Notes
- a note is not an open item
EOF
}

@test "lanes: every state lands in the right lane, needs-you ordered by priority" {
  build_fleet
  BOARD="$(cr dashboard --json)"
  [ "$(lane_ids needs_you)" = "t-decision t-blocked t-failed inbox-0 inbox-1" ]
  [ "$(lane_ids in_progress)" = "t-working t-draft" ]
  [ "$(lane_ids on_hold)" = "t-waiting t-silent" ]
  [ "$(lane_ids ready)" = "t-report t-pr" ]
  [ "$(lane_ids recent)" = "t-closed-recent" ]
  # counts are the lane lengths
  [ "$(jq -c .counts <<<"$BOARD")" = '{"needs_you":5,"in_progress":2,"on_hold":2,"ready":2,"recent":1}' ]
  # reasons
  [ "$(card t-silent | jq -r .reason)" = "stopped without reporting" ]
  [ "$(card t-waiting | jq -r .reason)" = "waiting on someone" ]
  [ "$(card t-report | jq -r .reason)" = "report to read" ]
  [ "$(card t-pr | jq -r .reason)" = "PR to review" ]
  [ "$(card t-draft | jq -r .reason)" = "drafting the brief" ]
}

@test "lanes: cards carry title, project, last event, PR links and files" {
  build_fleet
  BOARD="$(cr dashboard --json)"
  local c; c="$(card t-pr)"
  [ "$(jq -r .title <<<"$c")" = "Task t-pr" ]
  [ "$(jq -r .project <<<"$c")" = "todo-cli" ]
  [ "$(jq -r .last_event <<<"$c")" = "done: PR https://github.com/acme/todo-cli/pull/7 ready" ]
  # PR links from events.log and report.md, de-duplicated, state unknown without gh
  [ "$(jq -c '[.prs[].url]' <<<"$c")" = '["https://github.com/acme/todo-cli/pull/7","https://gitlab.example.com/acme/todo-cli/-/merge_requests/3"]' ]
  [ "$(jq -r '.prs[0].state' <<<"$c")" = "UNKNOWN" ]
  [ "$(jq -c .files <<<"$c")" = '["report.md","events.log"]' ]
  # the inbox question text is the card title; the date is split off
  [ "$(card inbox-0 | jq -r .title)" = "merge the parser PR?" ]
  [ "$(card inbox-0 | jq -r .date)" = "2026-01-02" ]
  [ "$(card inbox-1 | jq -r .title)" = "which region for staging?" ]
  [ "$(jq -r '.inbox.approvals[0].text' <<<"$BOARD")" = "ok to rotate the test key" ]
  [ "$(jq -r .home <<<"$BOARD")" = "$CHARTROOM_HOME" ]
}

@test "lanes: gh PR states move done tasks to on hold (in review) or recently finished (merged)" {
  fixture t-review subagent <<<"100 done: https://github.com/acme/todo-cli/pull/8"
  fixture t-merged subagent <<<"100 done: https://github.com/acme/todo-cli/pull/9"
  fixture t-approved subagent <<<"100 done: https://github.com/acme/todo-cli/pull/10"
  cat >"$BATS_TEST_TMPDIR/prs.json" <<'EOF'
{"https://github.com/acme/todo-cli/pull/8": {"state": "OPEN", "reviewDecision": "REVIEW_REQUIRED", "isDraft": false},
 "https://github.com/acme/todo-cli/pull/9": {"state": "MERGED", "reviewDecision": "APPROVED", "isDraft": false},
 "https://github.com/acme/todo-cli/pull/10": {"state": "OPEN", "reviewDecision": "APPROVED", "isDraft": false}}
EOF
  BOARD="$(cr dashboard --json --pr-states "$BATS_TEST_TMPDIR/prs.json")"
  [ "$(lane_ids on_hold)" = "t-review" ]
  [ "$(card t-review | jq -r .reason)" = "PR awaiting review" ]
  [ "$(lane_ids recent)" = "t-merged" ]
  [ "$(card t-merged | jq -r .reason)" = "merged" ]
  [ "$(lane_ids ready)" = "t-approved" ]
  # an unreadable states file is ignored, not fatal
  echo 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  BOARD="$(cr dashboard --json --pr-states "$BATS_TEST_TMPDIR/bad.json")"
  [ "$(jq .counts.ready <<<"$BOARD")" -eq 3 ]
}

@test "lanes: the recent window follows CHARTROOM_DASHBOARD_RECENT_HOURS" {
  fixture t-closed subagent closed=7200 <<<"7300 done: ok"
  BOARD="$(cr dashboard --json)"; [ "$(lane_ids recent)" = "t-closed" ]
  BOARD="$(CHARTROOM_DASHBOARD_RECENT_HOURS=1 cr dashboard --json)"; [ "$(lane_ids recent)" = "" ]
  [ "$(jq .recent_hours <<<"$BOARD")" -eq 1 ]
  run env CHARTROOM_DASHBOARD_RECENT_HOURS=soon "$CHARTROOM" dashboard --json
  [ "$status" -eq 1 ]
}

@test "lanes: legacy home (captain.md, 'Waiting on the captain', old backend names, CAP_HOME)" {
  local legacy="$BATS_TEST_TMPDIR/legacy"
  mkdir -p "$legacy/tasks/old-one"
  echo "# Captain" >"$legacy/captain.md"
  printf '# Inbox\n\n## Waiting on the captain\n- 2026-02-01 — approve the rollout?\n' >"$legacy/inbox.md"
  # a meta.json written by the private predecessor: no schema, no backend_source
  jq -n --arg c "$(ago 3600)" '{id:"old-one",title:"Old one",kind:"scout",backend:"herdr-claude",project:"/srv/code/todo-cli",
    base:"main",branch:"",plan_gate:0,worktree:"",created:$c,updated:$c,dispatched:$c}' >"$legacy/tasks/old-one/meta.json"
  printf '%s progress: still going\n' "$(ago 60)" >"$legacy/tasks/old-one/events.log"
  BOARD="$(unset CHARTROOM_HOME; CAP_HOME="$legacy" cr dashboard --json)"
  [ "$(jq -r .home <<<"$BOARD")" = "$legacy" ]
  [ "$(lane_ids in_progress)" = "old-one" ]
  [ "$(card inbox-0 | jq -r .title)" = "approve the rollout?" ]
}

@test "status --json keeps its fields and adds the dashboard's" {
  fixture t-working subagent <<<"120 progress: going"
  run cr status --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | [.id,.state,.live,.project,.last]' <<<"$output")" = '["t-working","working","in-session","todo-cli","progress: going"]' ]
  [ "$(jq -r '.[0] | has("last_at") and has("closed") and has("has_report") and has("branch")' <<<"$output")" = true ]
}

# ---------------------------------------------------------------- server

need_python() { [[ -n "$PY" ]] || skip "python3 not available"; ln -sf "$PY" "$BIN/python3"; }
get() { curl -s --max-time 10 "$@"; }
code() { curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$@"; }
start_daemon() {
  run cr dashboard --daemon --port 0 "$@"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard running: http://127.0.0.1:"* ]]
  read -r SRV_PID PORT <"$CHARTROOM_HOME/.dashboard.pid"
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -gt 0 ]]
  URL="http://127.0.0.1:$PORT"
}

@test "server: daemon start, endpoints, read-only, then stop" {
  need_python
  build_fleet
  start_daemon --no-gh
  kill -0 "$SRV_PID"
  [ "$(get "$URL/healthz")" = "ok" ]
  # the JSON endpoint is the CLI's board plus the enrichment status
  local j; j="$(get "$URL/api/dashboard")"
  [ "$(jq -r '.lanes | keys | join(",")' <<<"$j")" = "in_progress,needs_you,on_hold,ready,recent" ]
  [ "$(jq -c .counts <<<"$j")" = '{"needs_you":5,"in_progress":2,"on_hold":2,"ready":2,"recent":1}' ]
  [ "$(jq -r .pr_enrichment.enabled <<<"$j")" = false ]
  [ "$(jq -r '.lanes.needs_you[0] | [.id,.title,.project,.last_event] | join("|")' <<<"$j")" = "t-decision|Task t-decision|todo-cli|decision: pick option A or B (recommend A)" ]
  # the page: self-contained, no external scripts, styles or fonts
  local page; page="$(get "$URL/")"
  [[ "$page" == *"<title>chartroom</title>"* ]]
  [ -z "$(grep -Ei '(src|href)=["'"'"']?(https?:)?//|@import|url\(https?:' <<<"$page" || true)" ]
  [[ "$(curl -sI "$URL/" | tr -d '\r')" == *"Content-Security-Policy: default-src 'none'"* ]]
  # task files are served as text; nothing else is
  [ "$(get "$URL/task/t-report/report.md")" = "# Report" ]
  [ "$(code "$URL/task/t-report/meta.json")" = 404 ]
  [ "$(code --path-as-is "$URL/task/../inbox.md")" = 404 ]
  [ "$(code --path-as-is "$URL/task/t-report/../../inbox.md")" = 404 ]
  [ "$(code "$URL/task/nope/brief.md")" = 404 ]
  [ "$(code -X POST "$URL/api/dashboard")" = 405 ]
  # DNS-rebinding guard: a foreign Host header is refused
  [ "$(code -H "Host: attacker.example:$PORT" "$URL/")" = 403 ]
  [ "$(code -H "Host: localhost:$PORT" "$URL/healthz")" = 200 ]
  # status, refusing a second server, stop, stop again
  run cr dashboard status
  [ "$status" -eq 0 ]; [[ "$output" == *"http://127.0.0.1:$PORT"* ]]
  run cr dashboard --daemon --port 0
  [ "$status" -eq 1 ]; [[ "$output" == *"already running"* ]]
  run cr dashboard stop
  [ "$status" -eq 0 ]; [[ "$output" == *"dashboard stopped (pid $SRV_PID"* ]]
  run kill -0 "$SRV_PID"; [ "$status" -ne 0 ]
  [ ! -e "$CHARTROOM_HOME/.dashboard.pid" ]
  run cr dashboard stop
  [ "$status" -eq 0 ]; [[ "$output" == "dashboard not running" ]]
  run cr dashboard status
  [ "$status" -eq 1 ]
}

@test "server: binds 127.0.0.1 only" {
  need_python
  start_daemon --no-gh
  grep -q "chartroom dashboard: http://127.0.0.1:$PORT/" "$CHARTROOM_HOME/.dashboard.log"
  # the listening socket itself, where a tool to show it exists
  if command -v lsof >/dev/null 2>&1 || [[ -x /usr/sbin/lsof ]]; then
    local l; l="$(PATH="$PATH:/usr/sbin" lsof -nP -a -p "$SRV_PID" -iTCP -sTCP:LISTEN 2>/dev/null || true)"
    [[ -z "$l" ]] || { [[ "$l" == *"127.0.0.1:$PORT (LISTEN)"* ]] && [[ "$l" != *"*:$PORT"* ]]; }
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -q "127.0.0.1:$PORT "
    [ -z "$(ss -ltn | grep -E "(\*|0\.0\.0\.0|\[::\]):$PORT " || true)" ]
  fi
  # and there is no flag or setting that changes the host
  run cr dashboard --host 0.0.0.0
  [ "$status" -eq 1 ]; [[ "$output" == *"unknown arg --host"* ]]
}

@test "server: --port picks the port; bad and busy ports fail clearly" {
  need_python
  local p; p="$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  run cr dashboard --daemon --port "$p" --no-gh
  [ "$status" -eq 0 ]; [[ "$output" == *"http://127.0.0.1:$p "* ]]
  read -r SRV_PID _ <"$CHARTROOM_HOME/.dashboard.pid"
  [ "$(get "http://127.0.0.1:$p/healthz")" = ok ]
  # a second home cannot take the same port
  run env CHARTROOM_HOME="$BATS_TEST_TMPDIR/other" "$CHARTROOM" dashboard --daemon --port "$p" --no-gh
  [ "$status" -eq 1 ]; [[ "$output" == *"cannot listen on 127.0.0.1:$p"* ]]
  run cr dashboard --port 70000
  [ "$status" -eq 1 ]; [[ "$output" == *"--port must be 0-65535"* ]]
  run cr dashboard --port http
  [ "$status" -eq 1 ]
}

@test "server: a stale pid file never makes stop signal an unrelated process" {
  sleep 60 &
  local other=$!
  echo "$other 4517" >"$CHARTROOM_HOME/.dashboard.pid"
  run cr dashboard status
  [ "$status" -eq 1 ]
  run cr dashboard stop
  [ "$status" -eq 0 ]; [ "$output" = "dashboard not running" ]
  kill -0 "$other"
  [ ! -e "$CHARTROOM_HOME/.dashboard.pid" ]
  kill "$other"
  run cr dashboard --port
  [ "$status" -eq 1 ]; [[ "$output" == *"--port needs a value"* ]]
}

@test "server: foreground mode serves until stopped" {
  need_python
  # in a subshell so the server is not our child: a killed child would linger as a zombie
  ( "$CHARTROOM" dashboard --port 0 --no-gh >"$BATS_TEST_TMPDIR/fg.log" 2>&1 & )
  local i
  for i in $(seq 1 50); do [[ -s "$CHARTROOM_HOME/.dashboard.pid" ]] && break; sleep 0.1; done
  read -r SRV_PID PORT <"$CHARTROOM_HOME/.dashboard.pid"
  [ "$(get "http://127.0.0.1:$PORT/healthz")" = ok ]
  run cr dashboard stop
  [ "$status" -eq 0 ]
  run kill -0 "$SRV_PID"; [ "$status" -ne 0 ]
}

@test "server: PR states come from gh when present, and its absence is reported, not fatal" {
  need_python
  use_fake gh
  fixture t-review subagent <<<"100 done: https://github.com/acme/todo-cli/pull/8"
  export FAKE_GH_STATES="$BATS_TEST_TMPDIR/gh.json"
  echo '{"https://github.com/acme/todo-cli/pull/8": {"state":"OPEN","reviewDecision":"REVIEW_REQUIRED","isDraft":false}}' >"$FAKE_GH_STATES"
  start_daemon
  local j i
  for i in $(seq 1 40); do
    j="$(get "$URL/api/dashboard")"
    [[ "$(jq -r '.lanes.on_hold[0].id // empty' <<<"$j")" == t-review ]] && break
    sleep 0.25
  done
  [ "$(jq -r '.lanes.on_hold[0].prs[0].state' <<<"$j")" = OPEN ]
  [ "$(jq -r .pr_enrichment.enabled <<<"$j")" = true ]
  grep -q "gh pr view https://github.com/acme/todo-cli/pull/8" "$FAKE_LOG"
  cr dashboard stop >/dev/null
  # no gh: still serves, says why (CI images ship a real gh, so name one that does not exist)
  CHARTROOM_GH=gh-not-installed start_daemon
  j="$(get "$URL/api/dashboard")"
  [ "$(jq -r .pr_enrichment.error <<<"$j")" = "gh not on PATH" ]
  [ "$(jq -r '.lanes.ready[0].id' <<<"$j")" = t-review ]
}
