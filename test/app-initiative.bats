#!/usr/bin/env bats
# Initiatives (the app's slice 4): create and shape, stories proposed and approved (ready ones
# dispatched, dependent ones held), the plan's comments and proposed edits, numbered decisions
# from answered cards, closing; and the app's route. Invented data only.

load test_helper
load app_fixture

setup() {
  common_setup
  export CHARTROOM="$REPO_ROOT/bin/chartroom" CHARTROOM_TAILSCALE=none
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
}

teardown() { cr app stop >/dev/null 2>&1 || true; }

last_told() { cr tell list --json | jq -r '.[-1].text'; }

@test "new: an initiative starts shaping, with a round on goal, criteria, scope and non-goals, and the XO is told" {
  id="$(cr initiative new --name "Gift cards everywhere" --intent "Every store sells gift cards" --target 2026-03-01 --via app)"
  [[ "$id" =~ ^in-[0-9a-f]{4}$ ]]
  j="$(cr initiative show "$id" --json)"
  [ "$(jq -r '"\(.status) \(.target)"' <<<"$j")" = "shaping 2026-03-01" ]
  card="$(jq -r .card <<<"$j")"
  [ "$(cr ask show "$card" --json | jq -r '[.questions[].text] | length')" -eq 4 ]
  [ "$(cr ask show "$card" --json | jq -r .initiative)" = "$id" ]
  [[ "$(last_told)" == "New initiative $id: Gift cards everywhere. Intent: Every store sells gift cards."* ]]
  run cr initiative new --name ""
  [ "$status" -ne 0 ]
}

@test "approve: the checklist's order, edits, drops and additions; ready stories dispatched, dependent ones held" {
  id="$(cr initiative new --name "Checkout v2")"
  # a story already linked to a task, which the checklist does not cover: it stays
  done_st="$(cr initiative story add "$id" --title "Already running")"
  cr initiative story link "$id" "$done_st" "$(cr status --json | jq -r '.[0].id')" >/dev/null
  a="$(cr initiative story add "$id" --title "Address form" --project proj)"
  b="$(cr initiative story add "$id" --title "Payment step" --project proj)"
  c="$(cr initiative story add "$id" --title "Old flow cleanup")"
  run cr initiative story add "$id" --title "x" --after st-0000
  [ "$status" -ne 0 ]
  jq -n --arg a "$a" --arg b "$b" --arg c "$c" '{stories: [{id: $b, title: "Payment step (cards)", after: [$a]}, {id: $a}, {id: $c, drop: true}, {title: "Measure drop-off"}, {title: "Launch mail"}]}' |
    cr initiative approve "$id" - --via app
  j="$(cr initiative show "$id" --json)"
  [ "$(jq -r '[.stories[] | "\(.title):\(.state)"] | join("|")' <<<"$j")" = "Already running:approved|Payment step (cards):held|Address form:approved|Old flow cleanup:dropped|Measure drop-off:approved|Launch mail:approved" ]
  # the added stories got distinct ids
  [ "$(jq -r '[.stories[].id] | unique | length' <<<"$j")" -eq 6 ]
  [ "$(jq -r .status <<<"$j")" = active ]
  t="$(last_told)"
  [[ "$t" == *"- dispatch now: $a Address form [proj]"* ]]
  [[ "$t" == *"- hold until done: $b Payment step (cards), after $a (Address form)"* ]]
  [[ "$t" == *"- dropped: $c Old flow cleanup"* ]]
}

@test "link: a story follows its task, and the task carries the initiative; progress counts it" {
  id="$(cr initiative new --name "Fast search")"
  s="$(cr initiative story add "$id" --title "Pick a cache")"
  task="$(cr status --json | jq -r '.[] | select(.title | test("stock badge")) | .id')"
  cr initiative story link "$id" "$s" "$task" >/dev/null
  [ "$(jq -r .initiative "$CHARTROOM_HOME/tasks/$task/meta.json")" = "$id" ]
  [ "$(cr initiative show "$id" --json | jq -r '.stories[0] | "\(.state) \(.status)"')" = "approved review" ]
  cr accept "$task" >/dev/null
  [ "$(cr initiative show "$id" --json | jq -r '"\(.progress.done)/\(.progress.total)"')" = "1/1" ]
}

@test "decisions: an answered card of the initiative is one, numbered; the XO's own can supersede it" {
  id="$(cr initiative new --name "Fast search")"
  card="$(cr initiative show "$id" --json | jq -r .card)"
  cr ask answer "$card" --via app - <<<'{"answers":[{"q":1,"note":"fast"},{"q":2,"note":"p95 300ms"},{"q":3,"note":"storefront"},{"q":4,"note":"admin"}]}' >/dev/null
  cr initiative decide "$id" "Use an in-process LRU" >/dev/null
  cr initiative decide "$id" --supersedes 2 "Use Redis after all" >/dev/null
  j="$(cr initiative show "$id" --json)"
  [ "$(jq -r '[.decisions[] | "\(.n):\(.card // "-"):\(.supersedes // "-")"] | join(" ")' <<<"$j")" = "1:$card:- 2:-:- 3:-:2" ]
}

@test "plan: a comment and a proposed edit reach the XO; the plan itself is the XO's to change" {
  id="$(cr initiative new --name "Fast search")"
  printf '## Intent\n\nFast.\n' >"$CHARTROOM_HOME/initiatives/$id/plan.md"
  cr initiative comment "$id" --section "Intent" --via app "Say for which stores" >/dev/null
  [ "$(last_told)" = "Comment on the plan of $id, section \"Intent\": Say for which stores" ]
  printf '## Intent\n\nFast, for every store.\n' | cr initiative propose "$id" - --via app >/dev/null
  [ "$(cat "$CHARTROOM_HOME/initiatives/$id/plan.md")" = "$(printf '## Intent\n\nFast.')" ]
  [[ "$(last_told)" == "I edited the plan of $id: apply it to initiatives/$id/plan.md"*"+Fast, for every store."* ]]
  [ "$(ls "$CHARTROOM_HOME/initiatives/$id/proposals" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "close: the XO proposes with a wrap-up; only the commander's confirm closes it" {
  id="$(cr initiative new --name "Fast search")"
  cr initiative close "$id" --propose "Shipped the index and the box; follow-up: metrics" >/dev/null
  [ "$(cr initiative show "$id" --json | jq -r '"\(.status) \(.wrapup)"')" = "closing Shipped the index and the box; follow-up: metrics" ]
  cr initiative close "$id" --confirm --via app >/dev/null
  [ "$(cr initiative show "$id" --json | jq -r .status)" = closed ]
  [ "$(cr initiative list --json | jq --arg id "$id" '[.[] | select(.id == $id)] | length')" -eq 0 ]
}

@test "snapshot and app: proposed stories are a Needs me item; the page reads the initiative; approve runs through the queue" {
  s="$(cr app snapshot --json)"
  iid="$(jq -r '.initiatives[0].id' <<<"$s")"
  [ "$(jq -r --arg i "$iid" '.needs[] | select(.initiative == $i and .type == "initiative") | "\(.kind) \(.group)"' <<<"$s")" = "stories approve" ]
  run cr app serve --daemon --port 0 --no-auth
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -e '[.homes[] | select(.snapshot)] | length == 2' >/dev/null && break; sleep 0.2; done
  [ "$(curl -s "http://127.0.0.1:$PORT/api/v1/homes/acme/initiatives/$iid" | jq -r .name)" = "Fast search" ]
  ids="$(curl -s "http://127.0.0.1:$PORT/api/v1/homes/acme/initiatives/$iid" | jq -c '[.stories[] | select(.state == "proposed") | {id}]')"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' -H 'X-Chartroom-Action: a-ini-00001' \
    -d "{\"id\":\"$iid\",\"stories\":$ids}" "http://127.0.0.1:$PORT/api/v1/homes/acme/initiative-approve")"
  [ "$code" = 202 ]
  for _ in $(seq 1 100); do [ "$(curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -r '.actions["a-ini-00001"].state')" = "done" ] && break; sleep 0.1; done
  [ "$(cr initiative show "$iid" --json | jq -r '[.stories[] | select(.state == "proposed")] | length')" -eq 0 ]
}
