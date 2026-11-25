#!/usr/bin/env bats
# The permission card in Needs me (the permission broker's cards, lib/permit.sh): built from the
# broker's rows by lib/app/snapshot.jq, and answered through the app with
# `chartroom permit answer <p-id> once|always|deny --by app`. The snapshot rules are tested on their
# own; the end-to-end tests need the broker (`chartroom permit`) and skip without it.

load test_helper
load app_fixture

setup() {
  common_setup
  export CHARTROOM="$REPO_ROOT/bin/chartroom" CHARTROOM_TAILSCALE=none
}

teardown() { cr app stop >/dev/null 2>&1 || true; }

has_broker() { cr help 2>/dev/null | grep -q 'chartroom permit'; }

# Answers go through the app server, as the commander's do. (A `permit answer` run straight from a
# worker's session, as this suite may be, is refused by the broker itself.)
serve() {
  run cr app serve --daemon --port 0 --no-auth
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -e '[.homes[] | select(.snapshot)] | length == 2' >/dev/null && break; sleep 0.2; done
}
post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' -H "X-Chartroom-Action: $1" -d "$2" "http://127.0.0.1:$PORT/api/v1/homes/acme/permit"; }
outcome() { curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -r --arg a "$1" '.actions[$a] | "\(.state)\t\(.error // "")"'; }
settle() { for _ in $(seq 1 100); do [[ "$(outcome "$1")" == done* || "$(outcome "$1")" == failed* ]] && break; sleep 0.1; done; }

# A card as the broker writes it (permit_card in lib/permit.sh), in <home>/permits/<task>/<p-id>.json
write_card() { # <home> <task> <p-id> <blocking true|false> <expires in s>
  local now; now="$(date +%s)"
  mkdir -p "$1/permits/$2"
  jq -n --arg id "$3" --arg task "$2" --argjson b "$4" --argjson now "$now" --argjson exp "$5" \
    '{id: $id, task: $task, created: ($now | todate), created_epoch: $now, expires_epoch: ($now + $exp), event: "PreToolUse",
      blocking: $b, tool: "Bash", input: {command: "git push origin feature/gift-cards", description: "Push the gift-card branch"},
      sig: ("sig-" + $id), desc: "Bash \"git push origin feature/gift-cards\"", cwd: "/work/shop", why: "Push the gift-card branch",
      rule: "commander:outward", reason: "git-push", pattern: "git push:*", reason_denied: (if $b then null else "[Unsanctioned Communication]" end),
      session_id: null, transcript: null, transcript_off: 0}' >"$1/permits/$2/$3.json"
}

@test "snapshot: a card first, with the call, why and the always pattern; it replaces the task's bare decision; retry, missed and a closed task's" {
  now="$(date +%s)"
  s="$(jq -n --argjson now "$now" '
    def card($id; $task; $b; $exp; $state): {id: $id, task: $task, created: "2026-01-01T00:00:00Z", created_epoch: $now, expires_epoch: ($now + $exp),
      blocking: $b, tool: "Bash", input: {command: "git push origin main"}, desc: "Bash \"git push origin main\"", cwd: "/w", why: "Push it",
      rule: "commander:outward", reason: "git-push", pattern: "git push:*", reason_denied: null, state: $state, answer: null, late: null};
    {home: "/h/acme", home_name: "acme", machine: "m", version: "x", inbox: {}, artifacts: [], cards: [], answers: {}, tells: [],
     snoozes: {}, focus: null, requests: [], initiatives: [],
     rows: [{id: "t-push", short_id: "abcd", title: "Ship gift cards", project: "shop", state: "decision", live: "working", prs: [],
             ask: {id: "ev-t-push-0", kind: "decision", line: "2025-12-31T00:00:00Z decision: an older question"}},
            {id: "t-other", short_id: "efgh", title: "Sitemap", project: "shop", state: "working", live: "working", prs: []},
            {id: "t-gone", short_id: "ijkl", title: "Old", project: "shop", state: "closed", live: null, prs: []}],
     permits: [card("p-aaaa"; "t-push"; true; 600; "open"), card("p-bbbb"; "t-other"; false; 0; "open"),
               card("p-cccc"; "t-other"; true; -60; "expired"), card("p-dddd"; "t-gone"; true; 600; "open"),
               card("p-eeee"; "t-push"; true; 120; "open")]}' | jq -c -f "$REPO_ROOT/lib/app/snapshot.jq")"
  # the live blocking ones first, nearest expiry first; then the rest
  [ "$(jq -r '[.needs[] | .permit // .id] | join(" ")' <<<"$s")" = "p-eeee p-aaaa p-bbbb p-cccc" ]
  [ "$(jq -r '.needs[1] | "\(.kind) \(.group) \(.task) \(.title) \(.command) | \(.cwd) | \(.why) | \(.reason) (\(.rule)) | \(.pattern) | \(.ref)"' <<<"$s")" = \
    "permission decide t-push Ship gift cards git push origin main | /w | Push it | git-push (commander:outward) | git push:* | null" ]
  [ "$(jq -r '[.needs[] | select(.permit == "p-bbbb", .permit == "p-cccc") | "\(.blocking):\(.missed)"] | join(" ")' <<<"$s")" = "false:false true:true" ]
  # no bare "decision" item for t-push, and nothing for a closed task
  [ "$(jq -r '[.needs[] | select(.type == "task")] | length' <<<"$s")" -eq 0 ]
  [ "$(jq -r '.counts.needs' <<<"$s")" -eq 4 ]
}

@test "snapshot: without the broker, no permission items and nothing breaks" {
  has_broker && skip "this chartroom has the broker"
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  t="$(cr status --json | jq -r '.[0].id')"
  write_card "$CHARTROOM_HOME" "$t" p-1a2b true 600
  [ "$(cr app snapshot --json | jq '[.needs[] | select(.kind == "permission")] | length')" -eq 0 ]
}

@test "the app answers a card through the broker: once by app; a second answer is refused and says who won" {
  has_broker || skip "needs the permission broker (chartroom permit)"
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  t="$(cr status --json | jq -r '.[] | select(.title | test("stock badge")) | .id')"
  write_card "$CHARTROOM_HOME" "$t" p-1a2b true 600
  [ "$(cr app snapshot --json | jq -r '.needs[0] | "\(.kind) \(.permit) \(.task)"')" = "permission p-1a2b $t" ]
  serve
  [ "$(post a-perm-00000 '{"id":"q-1234","answer":"once"}')" = 400 ]
  [ "$(post a-perm-00000 '{"id":"p-1a2b","answer":"sure"}')" = 400 ]
  [ "$(post a-perm-00001 '{"id":"p-1a2b","answer":"once","note":"ok, \nbut only this once"}')" = 202 ]
  settle a-perm-00001
  [[ "$(outcome a-perm-00001)" == done* ]]
  [ "$(cr permit show p-1a2b | jq -r '"\(.state) \(.answer.answer) \(.answer.by) \(.answer.via) \(.answer.note)"')" = "answered once app app ok, but only this once" ]
  [ "$(post a-perm-00002 '{"id":"p-1a2b","answer":"deny"}')" = 202 ]
  settle a-perm-00002
  [[ "$(outcome a-perm-00002)" == *"already answered: once by app via app"*"(the first answer wins)"* ]]
  # the app names the card's task: another task's card of the same id is not the one it answers
  t2="$(cr status --json | jq -r --arg t "$t" '[.[] | select(.id != $t and .closed != true)][0].id')"
  write_card "$CHARTROOM_HOME" "$t2" p-5c5c true 600; write_card "$CHARTROOM_HOME" "$t" p-5c5c true 600
  [ "$(post a-perm-00003 "{\"id\":\"p-5c5c\",\"task\":\"../$t\",\"answer\":\"once\"}")" = 400 ]
  [ "$(post a-perm-00004 "{\"id\":\"p-5c5c\",\"task\":\"$t\",\"answer\":\"once\"}")" = 202 ]
  settle a-perm-00004
  [[ "$(outcome a-perm-00004)" == done* ]]
  [ -f "$CHARTROOM_HOME/permits/$t/p-5c5c.answer.json" ]; [ ! -e "$CHARTROOM_HOME/permits/$t2/p-5c5c.answer.json" ]
  rm "$CHARTROOM_HOME/permits/$t2/p-5c5c.json"
  # answered, it is out of Needs me
  [ "$(cr app snapshot --json | jq '[.needs[] | select(.kind == "permission")] | length')" -eq 0 ]
}

@test "a card the broker's hook raises shows in Needs me, and the app's allow reaches the waiting call" {
  has_broker || skip "needs the permission broker (chartroom permit)"
  export CHARTROOM_PERMIT_WAIT_SECONDS=30
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  t="$(cr status --json | jq -r '.[] | select(.title | test("sitemap")) | .id')"
  serve
  # the prompt Claude would show for an outward call, as its PermissionRequest hook gets it
  jq -cn --arg cwd "$PROJECT" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD", description: "Push the sitemap branch"},
    cwd: $cwd, session_id: "s-1"}' >"$BATS_TEST_TMPDIR/p.json"
  "$CHARTROOM" hook "$t" permission <"$BATS_TEST_TMPDIR/p.json" >"$BATS_TEST_TMPDIR/hook.out" 3>&- &
  hp=$!
  for _ in $(seq 1 100); do
    p="$(curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -r --arg t "$t" '[.homes[].snapshot.needs[]? | select(.kind == "permission" and .task == $t)][0].permit // empty')"
    [[ -n "$p" ]] && break; sleep 0.2
  done
  [[ "$p" =~ ^p-[0-9a-f]+$ ]]
  [ "$(curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -r --arg p "$p" '.homes[].snapshot.needs[]? | select(.permit == $p) | "\(.group) \(.blocking) \(.command)"')" = "decide true git push origin HEAD" ]
  [ "$(post a-perm-00010 "{\"id\":\"$p\",\"answer\":\"once\"}")" = 202 ]
  settle a-perm-00010
  [[ "$(outcome a-perm-00010)" == done* ]]
  wait "$hp"
  [ "$(jq -r '.hookSpecificOutput.decision.behavior' "$BATS_TEST_TMPDIR/hook.out")" = allow ]
  events "$t" | grep -qF "allowed $p once"
}

@test "a missed card stays for a late allow (the worker is told to retry); its deny is refused" {
  has_broker || skip "needs the permission broker (chartroom permit)"
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  t="$(cr status --json | jq -r '.[] | select(.title | test("stock badge")) | .id')"
  write_card "$CHARTROOM_HOME" "$t" p-3c4d true -30
  jq -n '{answer: "expired", by: "chartroom", via: "", note: "", at: (now - 30 | todate)}' >"$CHARTROOM_HOME/permits/$t/p-3c4d.answer.json"
  [ "$(cr app snapshot --json | jq -r '.needs[] | select(.permit == "p-3c4d") | "\(.missed) \(.state_permit)"')" = "true expired" ]
  serve
  [ "$(post a-perm-00003 '{"id":"p-3c4d","answer":"deny"}')" = 202 ]
  settle a-perm-00003
  [[ "$(outcome a-perm-00003)" == failed*"already answered: expired by chartroom"* ]]
  [ "$(post a-perm-00004 '{"id":"p-3c4d","answer":"once"}')" = 202 ]
  settle a-perm-00004
  [[ "$(outcome a-perm-00004)" == done* ]]
  [ "$(cr permit show p-3c4d | jq -r '"\(.late.answer) \(.late.by)"')" = "once app" ]
  # recorded as a late allow (the broker then tells the worker to run it again), and out of Needs me
  events "$t" | grep -qF "allowed p-3c4d once (late, after it expired) by app"
  [ "$(cr app snapshot --json | jq '[.needs[] | select(.permit == "p-3c4d")] | length')" -eq 0 ]
}
