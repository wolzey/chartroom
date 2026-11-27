#!/usr/bin/env bats
# The board (`chartroom board`, `board --json`, lib/lanes.jq): lane classification from
# hand-written task records; and `chartroom dashboard`, which opens the app now that the web
# dashboard is retired. No network, no real gh.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
  PY="$(type -P python3 || true)"
}

teardown() {
  cr app stop >/dev/null 2>&1 || true
  [[ -n "${OLD_PID:-}" ]] && kill "$OLD_PID" 2>/dev/null || true
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
700 note: accepted
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
  # a worker's done is review (awaiting the commander): needs you, after awaiting-input
  [ "$(lane_ids needs_you)" = "t-decision t-blocked t-failed t-report inbox-0 inbox-1" ]
  [ "$(lane_ids in_progress)" = "t-working t-draft" ]
  [ "$(lane_ids on_hold)" = "t-waiting t-silent" ]
  # done is the commander's accept: ready for them to land or close, off needs-you
  [ "$(lane_ids ready)" = "t-pr" ]
  [ "$(lane_ids recent)" = "t-closed-recent" ]
  # counts are the lane lengths
  [ "$(jq -c .counts <<<"$BOARD")" = '{"needs_you":6,"in_progress":2,"on_hold":2,"ready":1,"recent":1}' ]
  [ "$(card t-report | jq -r .state)" = review ]
  [ "$(card t-pr | jq -r .state)" = done ]
  # reasons
  [ "$(card t-silent | jq -r .reason)" = "stopped without reporting" ]
  [ "$(card t-waiting | jq -r .reason)" = "waiting on someone" ]
  [ "$(card t-report | jq -r .reason)" = "report to read" ]
  [ "$(card t-pr | jq -r .reason)" = "accepted" ]
  [ "$(card t-draft | jq -r .reason)" = "drafting the brief" ]
}

@test "lanes: a stopped worker inside its waiting window is in progress; past it, on hold" {
  local until; until="$(jq -rn 'now + 1800 | floor | todate')"
  fixture t-wait command pid=2147480000 <<<"300 waiting: CI on PR 7 until $until"
  fixture t-wait-old command pid=2147480000 <<<"9000 waiting: sign-off from legal"
  fixture t-wait-past command pid=2147480000 <<<"7000 waiting: a timer until $(jq -rn 'now - 3600 | floor | todate')"
  fixture t-wait-live subagent <<<"100 waiting: waiting on CI for PR 9"
  fixture t-resumed command pid=2147480000 <<'EOF'
900 waiting: CI on PR 8
600 progress: CI green, merging
EOF
  # a decision/blocked/done since the last dispatch or steer outranks a later `waiting`
  fixture t-asked command pid=2147480000 <<'EOF'
500 decision: ship A or B? (recommend A)
400 waiting: the commander's answer
EOF
  fixture t-shipped command pid=2147480000 <<'EOF'
500 done: PR opened
400 waiting: review on the PR
EOF
  BOARD="$(cr dashboard --json)"
  [ "$(card t-asked | jq -c '[.state,.lane,.waiting_on]')" = '["decision","needs_you",null]' ]
  [ "$(card t-shipped | jq -c '[.state,.waiting_on]')" = '["review",null]' ]
  [ "$(lane_ids in_progress)" = "t-wait-live t-wait" ]
  [ "$(lane_ids on_hold)" = "t-resumed t-wait-past t-wait-old" ]
  [ "$(card t-wait | jq -c '[.state,.reason,.waiting_on,.waiting_until]')" = "[\"waiting\",\"waiting\",\"CI on PR 7 until $until\",\"$until\"]" ]
  [ "$(card t-wait-old | jq -c '[.state,.reason,.waiting_on,.waiting_until]')" = '["waiting-overdue","waiting overdue","sign-off from legal",null]' ]
  [ "$(card t-wait-past | jq -r .state)" = waiting-overdue ]
  # a live session that said `waiting` is still working (its own wording is not "on hold")
  [ "$(card t-wait-live | jq -c '[.state,.reason,.waiting_on]')" = '["working","in-session","waiting on CI for PR 9"]' ]
  [ "$(card t-resumed | jq -c '[.state,.reason,.waiting_on]')" = '["stopped-silent","stopped without reporting",null]' ]
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
  local n
  for n in review:8 merged:9 approved:10; do
    fixture "t-${n%%:*}" subagent <<<"100 done: https://github.com/acme/todo-cli/pull/${n#*:}"
    printf '%s\n' "100 done: https://github.com/acme/todo-cli/pull/${n#*:}" "50 note: accepted" | fixture "t-${n%%:*}-ok" subagent
  done
  cat >"$BATS_TEST_TMPDIR/prs.json" <<'EOF'
{"https://github.com/acme/todo-cli/pull/8": {"state": "OPEN", "reviewDecision": "REVIEW_REQUIRED", "isDraft": false},
 "https://github.com/acme/todo-cli/pull/9": {"state": "MERGED", "reviewDecision": "APPROVED", "isDraft": false},
 "https://github.com/acme/todo-cli/pull/10": {"state": "OPEN", "reviewDecision": "APPROVED", "isDraft": false}}
EOF
  BOARD="$(cr dashboard --json --pr-states "$BATS_TEST_TMPDIR/prs.json")"
  # in review (not yet accepted), every one needs the commander, merged or not
  [ "$(lane_ids needs_you | tr ' ' '\n' | sort | tr '\n' ' ')" = "t-approved t-merged t-review " ]
  [ "$(card t-review | jq -r .reason)" = "PR to review" ]
  [ "$(card t-merged | jq -r .reason)" = "PR merged" ]
  # accepted (done): the PR's state places it
  [ "$(lane_ids on_hold)" = "t-review-ok" ]
  [ "$(card t-review-ok | jq -r .reason)" = "PR awaiting review" ]
  [ "$(lane_ids recent)" = "t-merged-ok" ]
  [ "$(card t-merged-ok | jq -r .reason)" = "merged" ]
  [ "$(lane_ids ready)" = "t-approved-ok" ]
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

@test "board: a task closed before the recent window is never read on its own, and status skips every closed one" {
  build_fleet
  # A jq that logs its arguments: a read of one task's record ends with that task's meta.json.
  mv "$BIN/jq" "$BIN/jq.real"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/jq.log" "$BIN/jq.real" >"$BIN/jq"
  chmod +x "$BIN/jq"
  own() { grep -cE "/tasks/$1/+meta\.json$" "$BATS_TEST_TMPDIR/jq.log" || true; }
  BOARD="$(cr board --json)"
  [ "$(lane_ids recent)" = "t-closed-recent" ]
  [ "$(own t-closed-old)" -eq 0 ]
  [ "$(own t-closed-recent)" -gt 0 ]
  # its record is still there for show
  [ "$(cr show t-closed-old --json | jq -c '[.state, .lane]')" = '["closed",null]' ]
  : >"$BATS_TEST_TMPDIR/jq.log"
  [ "$(cr status --json | jq -r 'map(.id) | index("t-closed-recent")')" = null ]
  [ "$(own t-closed-old)" -eq 0 ]; [ "$(own t-closed-recent)" -eq 0 ]
  [ "$(own t-working)" -gt 0 ]
  # status --all still reads and lists every task
  [ "$(cr status --json --all | jq -r 'map(.id) | index("t-closed-old") != null')" = true ]
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

@test "status --json keeps its fields and adds the board's" {
  fixture t-working subagent <<<"120 progress: going"
  run cr status --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | [.id,.state,.live,.project,.last]' <<<"$output")" = '["t-working","working","in-session","todo-cli","progress: going"]' ]
  [ "$(jq -r '.[0] | has("last_at") and has("closed") and has("has_report") and has("branch")' <<<"$output")" = true ]
}

@test "short ids: every card carries short_id; inbox items their tag; existing fields unchanged" {
  fixture fix-login-21ba subagent <<<"600 decision: pick A or B"
  fixture add-flag-21ba subagent <<<"120 progress: going"
  fixture docs-7f3a subagent closed=3600 <<<"3700 done: shipped"
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF2'
# Inbox

## Waiting on the commander
- [i-7f3a] 2026-01-02 — merge the parser PR?
- which region for staging?

## Approvals given in chat, not yet in a brief
- 2026-01-03 — ok to rotate the test key
EOF2
  BOARD="$(cr dashboard --json)"
  [ "$(card fix-login-21ba | jq -r .short_id)" = n-21ba ]
  [ "$(card add-flag-21ba | jq -r .short_id)" = g-21ba ]
  [ "$(card docs-7f3a | jq -r .short_id)" = 7f3a ]
  # inbox cards keep their positional id and gain the tag (null when the line has none)
  [ "$(card inbox-0 | jq -c '[.short_id, .title, .date]')" = '["i-7f3a","merge the parser PR?","2026-01-02"]' ]
  [ "$(card inbox-1 | jq -c '[.short_id, .title]')" = '[null,"which region for staging?"]' ]
  [ "$(jq -r '.inbox.approvals[0].text' <<<"$BOARD")" = "ok to rotate the test key" ]
  # the short id a card shows resolves back to its task / item
  [ "$(cr resolve "$(card fix-login-21ba | jq -r .short_id)")" = fix-login-21ba ]
  [ "$(cr resolve i-7f3a)" = i-7f3a ]
  # a closed task's 4-hex suffix is the same as an inbox tag's hex, but i- keeps them apart
  [ "$(cr resolve 7f3a)" = docs-7f3a ]
}

@test "board: the lanes in the terminal, short id first; plain when piped; --json is the board" {
  build_fleet
  fixture fix-login-21ba subagent <<<"60 decision: pick A or B (recommend A)"
  perl -0pi -e 's/- 2026-01-02 — merge/- [i-7f3a] 2026-01-02 — merge/' "$CHARTROOM_HOME/inbox.md"
  run cr board
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e['* ]]   # piped: no color
  # the same lanes, counts and order as dashboard --json
  [ "$(grep -E '^[A-Z]' <<<"$output" | tr '\n' '|')" = "Needs you (7)|In progress (2)|On hold (2)|Ready for you (1)|Recently finished (1)|" ]
  local want got
  want="$(cr dashboard --json | jq -r '.lanes[][] | .short_id // "-"' | tr '\n' ' ')"
  got="$(grep -E '^  [^ ]' <<<"$output" | grep -v '^  none$' | awk '{print $1}' | tr '\n' ' ')"
  [ "$got" = "$want" ]
  grep -qE '^  21ba +\[todo-cli\] Task fix-login-21ba  \[decision\]  decision: pick A or B \(recommend A\)$' <<<"$output"
  grep -qE '^  i-7f3a +merge the parser PR\?  \[waiting on you \(inbox\)\]  since 2026-01-02$' <<<"$output"
  grep -qE '^  - +which region for staging\?' <<<"$output"   # an untagged inbox line has no id yet
  # color on request
  [[ "$(cr board --color)" == *$'\e[1;31mNeeds you'* ]]
  [ "$(NO_COLOR=1 cr board | grep -c $'\e')" -eq 0 ]
  # --json is the dashboard's JSON
  [ "$(cr board --json | jq -c '[.counts, [.lanes[][] | .short_id]]')" = "$(cr dashboard --json | jq -c '[.counts, [.lanes[][] | .short_id]]')" ]
  run cr board --bogus
  [ "$status" -ne 0 ]
}

@test "projects: inbox cards carry their [project]; board and needs-you lead with it; JSON only adds" {
  fixture fix-login-21ba subagent <<<"600 decision: pick A or B"
  fixture api-9c1d subagent project=/srv/code/billing-api/ <<<"300 blocked: need staging credentials"
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF2'
# Inbox

## Waiting on the commander
- [i-7f3a] 2026-01-02 — [webapp] merge the parser PR?
- [i-1b2c] 2026-01-03 — which region for staging?
- [multi] untagged and undated

## Approvals given in chat, not yet in a brief
- 2026-01-04 — [billing] ok to rotate the test key
EOF2
  BOARD="$(cr dashboard --json)"
  [ "$(card inbox-0 | jq -c '[.short_id, .project, .title, .date]')" = '["i-7f3a","webapp","merge the parser PR?","2026-01-02"]' ]
  [ "$(card inbox-1 | jq -c '[.project, .title]')" = '[null,"which region for staging?"]' ]
  [ "$(card inbox-2 | jq -c '[.short_id, .project, .title, .date]')" = '[null,"multi","untagged and undated",null]' ]
  [ "$(card api-9c1d | jq -r .project)" = billing-api ]
  [ "$(jq -c '.inbox.approvals[0] | [.project, .text, .date]' <<<"$BOARD")" = '["billing","ok to rotate the test key","2026-01-04"]' ]
  # backward compatible: an inbox card has every key it had before, plus project, artifacts and
  # focus mode's breaking, in_focus, held
  [ "$(card inbox-1 | jq -c 'keys - ["project", "artifacts", "breaking", "in_focus", "held"]')" = '["date","files","id","lane","last_at","prs","reason","short_id","state","title","type"]' ]
  run cr board --no-color
  grep -qE '^  21ba +\[todo-cli\] Task fix-login-21ba  \[decision\]' <<<"$output"
  grep -qE '^  9c1d +\[billing-api\] Task api-9c1d  \[blocked\]  blocked: need staging credentials$' <<<"$output"
  grep -qE '^  i-7f3a +\[webapp\] merge the parser PR\?  \[waiting on you \(inbox\)\]  since 2026-01-02$' <<<"$output"
  grep -qE '^  i-1b2c +which region for staging\?  \[waiting on you' <<<"$output"   # no label, no brackets
  grep -qE '^  - +\[multi\] untagged and undated' <<<"$output"
}

@test "artifacts: every card carries its open artifacts" {
  fixture t-report subagent <<<"400 done: findings in report.md"
  fixture t-plain subagent <<<"120 progress: going"
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF2'
# Inbox

## Waiting on the commander
- [i-7f3a] 2026-01-02 — [webapp] send the release note?
EOF2
  printf 'Hello,\nthe release is out.\n' >"$BATS_TEST_TMPDIR/note.md"
  [ "$(cr artifact add t-report --kind message --title "Reply to the reviewer" "$BATS_TEST_TMPDIR/note.md")" = t-report/reply-to-the-reviewer ]
  [ "$(cr artifact add i-7f3a --kind runbook --title "Publish" - <<<"make publish")" = i-7f3a/publish ]
  BOARD="$(cr dashboard --json)"
  [ "$(card t-report | jq -c '.artifacts | map([.ref, .owner_type, .owner, .slug, .kind, .title])')" = \
    '[["t-report/reply-to-the-reviewer","task","t-report","reply-to-the-reviewer","message","Reply to the reviewer"]]' ]
  [ "$(card t-plain | jq -c .artifacts)" = '[]' ]
  [ "$(card inbox-0 | jq -c '.artifacts | map([.ref, .owner_type, .owner, .slug])')" = '[["i-7f3a/publish","inbox","i-7f3a","publish"]]' ]
  [ "$(jq -c .artifacts <<<"$BOARD")" = '{"open":2,"message":1,"runbook":1,"note":0,"page":0}' ]
}

@test "dashboard: the board names its home, from the list of homes" {
  [ "$(cr dashboard --json | jq -r .home_name)" = null ]
  cr homes add acme >/dev/null
  [ "$(cr dashboard --json | jq -r .home_name)" = acme ]
}

# ---------------------------------------------------------------- dashboard: the app now

need_python() { PY="$(type -P python3 || true)"; [[ -n "$PY" ]] || skip "python3 not available"; link_tool "$PY" python3; }
app_port() { cr app status | sed -nE 's#^app running: http://127\.0\.0\.1:([0-9]+).*#\1#p'; }

@test "dashboard: opens the app (its URL printed), says why when there is none, and never opens a browser for a client" {
  need_python
  export CHARTROOM_TAILSCALE=none
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/opened"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/opener"; chmod +x "$BATS_TEST_TMPDIR/opener"
  export CHARTROOM_OPENER="$BATS_TEST_TMPDIR/opener"
  # no app yet: where it would be, and how to start it (open starts it, as app open does: here it needs a user)
  run cr dashboard url
  [ "$status" -ne 0 ]; [[ "$output" == *"the app is not running"*"chartroom app serve --daemon"* ]]
  run cr dashboard status
  [ "$status" -ne 0 ]; [[ "$output" == "app: the app is not running"* ]]
  run cr dashboard open
  [ "$status" -ne 0 ]; [[ "$output" == *"CHARTROOM_APP_USER"* ]]
  cr app serve --daemon --port 0 --no-auth >/dev/null
  local port; port="$(app_port)"; [[ "$port" =~ ^[0-9]+$ ]]
  [ "$(cr dashboard url)" = "http://127.0.0.1:$port/" ]
  [ "$(cr dashboard status)" = "app: http://127.0.0.1:$port/" ]
  run cr dashboard
  [ "$status" -eq 0 ]; [ "$output" = "app open: http://127.0.0.1:$port/" ]
  [ "$(cat "$BATS_TEST_TMPDIR/opened")" = "http://127.0.0.1:$port/" ]
  # through a brain's gate (a client asked): the address only, in the line older clients read too
  rm -f "$BATS_TEST_TMPDIR/opened"
  run env CHARTROOM_GATE=1 "$CHARTROOM" dashboard open
  [ "$status" -eq 0 ]; [ "$output" = "dashboard running: http://127.0.0.1:$port/" ]
  [ ! -e "$BATS_TEST_TMPDIR/opened" ]
  # doctor names it
  [ "$(cr doctor --json | jq -r .app.url)" = "http://127.0.0.1:$port/" ]
  cr doctor | grep -qx "app:      http://127.0.0.1:$port/"
  # the old server's flags are refused, saying what replaced it
  for a in --daemon "--port 4517" --expose "open --theme hud" bogus; do
    # shellcheck disable=SC2086 # one or two words each
    run cr dashboard $a
    [ "$status" -ne 0 ]; [[ "$output" == *"retired"* ]]
  done
}

@test "dashboard stop: ends an old web dashboard left running from before, and never another process" {
  need_python
  # an old dashboard's server, as it ran: python on lib/dashboard/server.py, its pid in .dashboard.pid
  mkdir -p "$BATS_TEST_TMPDIR/old/lib/dashboard"
  printf 'import time\ntime.sleep(300)\n' >"$BATS_TEST_TMPDIR/old/lib/dashboard/server.py"
  "$PY" "$BATS_TEST_TMPDIR/old/lib/dashboard/server.py" --pidfile "$CHARTROOM_HOME/.dashboard.pid" >/dev/null 2>&1 &
  OLD_PID=$!
  printf '%s 4517 127.0.0.1\n' "$OLD_PID" >"$CHARTROOM_HOME/.dashboard.pid"
  sleep 0.3
  run cr dashboard status
  [[ "$output" == *"old web dashboard: still running (pid $OLD_PID, port 4517)"* ]]
  [ "$(cr doctor --json | jq -r .app.old_dashboard)" = "$OLD_PID" ]
  run cr dashboard stop
  [ "$status" -eq 0 ]; [[ "$output" == "stopped the old web dashboard (pid $OLD_PID, port 4517)"* ]]
  wait "$OLD_PID" 2>/dev/null || true
  ! kill -0 "$OLD_PID" 2>/dev/null
  [ ! -e "$CHARTROOM_HOME/.dashboard.pid" ]
  # a stale pid file whose pid is now something else: that process is left alone
  sleep 300 &
  OLD_PID=$!
  printf '%s 4517 127.0.0.1\n' "$OLD_PID" >"$CHARTROOM_HOME/.dashboard.pid"
  run cr dashboard stop
  [ "$status" -eq 0 ]; [[ "$output" == "no old web dashboard runs for this home"* ]]
  kill -0 "$OLD_PID"
}

@test "dashboard: --json is the board; a named home gets no dashboard port, and homes lists none" {
  [ "$(cr dashboard --json | jq -c '[.counts, .home]')" = "$(cr board --json | jq -c '[.counts, .home]')" ]
  run cr init --name acme --dashboard-port 4600
  [ "$status" -eq 0 ]; [[ "$output" == *"--dashboard-port is no longer used"* ]]
  ! grep -q DASHBOARD_PORT "$CHARTROOM_HOME/config"
  grep -q '^CHARTROOM_WORKSPACE=acme-crew$' "$CHARTROOM_HOME/config"
  run cr homes
  [ "$status" -eq 0 ]
  [[ "$(head -1 <<<"$output")" =~ ^NAME\ +PATH\ +WORKSPACE\ +OPEN$ ]]
  [ "$(cr homes --json | jq -c '.[0] | has("port") or has("dashboard")')" = false ]
}
