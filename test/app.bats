#!/usr/bin/env bats
# The app's CLI half: `tell` (the commander's words to the XO), `ask` (question cards, the first
# answer winning), `snooze`, and `app snapshot` (Needs me and the seven statuses, from the records).
# Invented data only (test/app_fixture.bash).

load test_helper
load app_fixture

setup() {
  common_setup
  export CHARTROOM="$REPO_ROOT/bin/chartroom"
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
}

snap() { cr app snapshot --json; }
# a streaming watch for 3 seconds, then stopped; its output
stream3() { local p; "$CHARTROOM" watch 3>&- & p=$!; sleep 3; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true; }
item() { snap | jq -c --arg t "$1" '[.needs[] | select(.title | test($t))][0]'; }

@test "tell: the commander's words wake the XO's watch, and relay list never shows them" {
  run cr tell --re i-1234 --project shop "Start the sale on Wednesday"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^cm-[0-9a-f]{4}$ ]]
  id="$output"
  run cr watch --once --timeout 5
  [[ "$output" == *"[commander $id] [via terminal] [shop] [re i-1234] Start the sale on Wednesday"* ]]
  run cr relay list --json
  [ "$(jq length <<<"$output")" -eq 0 ]
  run cr tell list --json
  [ "$(jq -r '.[0].acked' <<<"$output")" = false ]
  cr tell ack "$id"
  run cr tell list --json
  [ "$(jq length <<<"$output")" -eq 0 ]
}

@test "tell: refuses an empty message and one that holds a secret" {
  run cr tell "   "
  [ "$status" -ne 0 ]
  run cr tell "the key is ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub token"* ]]
  run grep -q ghp_ "$CHARTROOM_HOME/relays/inbox.ndjson"
  [ "$status" -ne 0 ]
}

@test "ask: the first answer wins; the second is refused and names the first" {
  id="$(cr ask --title "Ship on Friday?" --option yes --option no --recommend 1)"
  run cr ask answer "$id" --via app --pick 2 --note "after the freeze"
  [ "$status" -eq 0 ]
  [[ "$output" == "answered $id (told the XO: cm-"* ]]
  run cr ask answer "$id" --pick 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"already answered (by app at "* ]]
  [ "$(jq -r '.answers[0].choice' "$CHARTROOM_HOME/questions/$id.answer.json")" = no ]
  # the XO hears it as the commander's words, linked to the card
  run cr tell list --json
  [ "$(jq -r '.[-1].re' <<<"$output")" = "$id" ]
  [[ "$(jq -r '.[-1].text' <<<"$output")" == *"Ship on Friday? → no. Note: after the freeze"* ]]
}

@test "ask: a round needs every question answered, with choices among its options" {
  id="$(cr ask list --json | jq -r '.[] | select(.title | test("good looks like")) | .id')"
  run cr ask answer "$id" --via app - <<<'{"answers":[{"q":1,"choice":"Shoppers"}]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"question(s) 2, 3 not answered"* ]]
  run cr ask answer "$id" --via app - <<<'{"answers":[{"q":1,"choice":"Robots"},{"q":2,"choice":"p95 under 300ms"},{"q":3,"note":"no"}]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"question(s) 1: the choice is not one of its options"* ]]
  [ ! -e "$CHARTROOM_HOME/questions/$id.answer.json" ]
  run cr ask answer "$id" --via app - <<<'{"answers":[{"q":1,"choice":"Shoppers"},{"q":2,"choice":"p95 under 300ms"},{"q":3,"note":"admin search"}]}'
  [ "$status" -eq 0 ]
}

@test "ask: a worker's decision is a card by its event's offset; any other offset is refused" {
  it="$(item "Pick a cache")"
  card="$(jq -r .card <<<"$it")"
  [[ "$card" =~ ^ev-pick-a-cache-for-the-sea-[0-9a-f]{4}-[0-9]+$ ]]
  [ "$(jq -r .kind <<<"$it")" = decide ]
  task="$(jq -r .task <<<"$it")"
  run cr ask answer "ev-$task-1" --note x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no open card"* ]]
  run cr ask answer "$card" --via app - <<<'{"answers":[{"q":1,"choice":"An in-process LRU","note":"keep it simple"}]}'
  [ "$status" -eq 0 ]
  run cr tell list --json
  [ "$(jq -r '.[-1].re' <<<"$output")" = "$task" ]
  [[ "$(jq -r '.[-1].text' <<<"$output")" == "Answer to $task's decision ("*"): An in-process LRU. Note: keep it simple" ]]
  # the item moves from Needs me to sent
  [ "$(item "Pick a cache" | jq -r '.sent.via')" = app ]
}

@test "ask: requesting changes to a plan needs a note" {
  card="$(item "Checkout" | jq -r .card)"
  run cr ask answer "$card" --via app - <<<'{"action":"changes"}'
  [ "$status" -ne 0 ]
  run cr ask answer "$card" --via app - <<<'{"action":"changes","note":"keep the old form for a month"}'
  [ "$status" -eq 0 ]
  [[ "$(cr tell list --json | jq -r '.[-1].text')" == "Requested changes to "*"'s plan: keep the old form for a month"* ]]
}

@test "ask withdraw: the XO takes a card back, and it leaves Needs me" {
  id="$(cr ask --title "Rename the shop?" --option yes --option no)"
  cr ask withdraw "$id" "answered in the meeting"
  run cr ask answer "$id" --pick 1
  [ "$status" -ne 0 ]
  [ "$(item "Rename the shop" | jq -r .sent.withdrawn)" = true ]
}

@test "snapshot: Needs me groups every kind, and tasks carry the seven statuses" {
  s="$(snap)"
  kinds="$(jq -r '[.needs[] | "\(.kind)/\(.group)"] | sort | join(" ")' <<<"$s")"
  [ "$kinds" = "approve/approve blocked/unblock decide/decide decide/decide inbox/decide inbox/decide review/read round/decide" ]
  [ "$(jq -r '.tasks[] | select(.title | test("stock badge")) | .status' <<<"$s")" = review ]
  [ "$(jq -r '.tasks[] | select(.title | test("Pick a cache")) | .status' <<<"$s")" = needs ]
  [ "$(jq -r '.tasks[] | select(.title | test("Pick a cache")) | .intent' <<<"$s")" = "Search feels slow on big catalogues; make it fast." ]
  [ "$(jq -r '.counts.needs' <<<"$s")" -eq 8 ]
}

@test "ask: a round a worker asked is answered whole, each answer naming its question" {
  card="$(item "Search index" | jq -r .card)"
  task="$(item "Search index" | jq -r .task)"
  run cr ask answer "$card" --via app - <<<'{"answers":[{"q":1,"question":"Options","choice":"One index per store"},{"q":2,"question":"Storage","note":""}]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"every question needs a choice or a note"* ]]
  run cr ask answer "$card" --via app - <<<'{"answers":[{"q":1,"question":"Options","choice":"One index per store"},{"q":2,"question":"Storage","choice":"A SQLite sidecar","note":"for now"}]}'
  [ "$status" -eq 0 ]
  text="$(cr tell list --json | jq -r '.[-1].text')"
  [[ "$text" == "Answers to $task's decision ("* ]]
  [[ "$text" == *$'\n1. Options → One index per store'* ]]
  [[ "$text" == *$'\n2. Storage → A SQLite sidecar. Note: for now'* ]]
}

@test "snapshot: a worker at a prompt is the XO's to handle, never a card in Needs me" {
  # the state comes from a live backend (a prompt up in its terminal): a status row says so
  s="$(jq -n -c '{home: "/h", home_name: "acme", machine: "m", version: "x", inbox: {waiting: [], approvals: []}, artifacts: [],
    cards: [], answers: {}, tells: [], snoozes: {}, focus: null, requests: [],
    rows: [{id: "t-prompt", short_id: "abcd", title: "At a prompt", state: "awaiting-input", live: "blocked", prs: [],
            ask: {id: "ev-t-prompt-0", kind: "awaiting-input", line: "2026-01-01T00:00:00Z agent: awaiting-input: hc: prompt"}},
           {id: "t-decide", short_id: "efgh", title: "A decision", state: "decision", live: "working", prs: [],
            ask: {id: "ev-t-decide-0", kind: "decision", line: "2026-01-01T00:00:00Z decision: which?"}}]}' |
    jq -c -f "$REPO_ROOT/lib/app/snapshot.jq")"
  [ "$(jq -r '[.needs[].task] | join(" ")' <<<"$s")" = "t-decide" ]
  [ "$(jq -r '.tasks[] | select(.id == "t-prompt") | "\(.status) | \(.warning)"' <<<"$s")" = "working | at a prompt in its terminal, for the XO to handle" ]
}

@test "snooze: an item leaves Needs me until its time; off brings it back" {
  ref="$(item "Gift cards" | jq -r .ref)"
  cr snooze "$ref" --for 2h
  [ "$(snap | jq -r .counts.snoozed)" -eq 1 ]
  [ "$(item "Gift cards" | jq -r '.snoozed_until != null')" = true ]
  cr snooze off "$ref"
  [ "$(snap | jq -r .counts.snoozed)" -eq 0 ]
  run cr snooze "$ref" --for 0h
  [ "$status" -ne 0 ]
  run cr snooze "$ref" --until 2001-01-01T00:00:00Z
  [ "$status" -ne 0 ]
}

@test "app: a client home refuses it; the app runs on the brain" {
  printf 'CHARTROOM_BRAIN=studio\n' >>"$CHARTROOM_HOME/config"
  run cr app snapshot --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"the app runs there"* ]]
}

@test "ask: a worker's ask that moved on cannot be answered from an old view" {
  card="$(item "Pick a cache" | jq -r .card)"
  task="$(item "Pick a cache" | jq -r .task)"
  # the XO answered it in the terminal, and the worker asked something newer
  cr event "$task" decision "Which TTL for the cache?" >/dev/null
  run cr ask answer "$card" --via app --note "the LRU"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has moved on since that question"*"newer ask"* ]]
  [ ! -e "$CHARTROOM_HOME/questions/$card.answer.json" ]
  # the newest ask, once the XO has answered it in the terminal (steer logs "steered:"), is closed too
  card="$(item "Pick a cache" | jq -r .card)"
  printf '%s steered: use a 5 minute TTL\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$CHARTROOM_HOME/tasks/$task/events.log"
  run cr ask answer "$card" --via app --note "10 minutes"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has moved on since that question (it is working now)"* ]]
}

@test "ask: an answer the XO could not be told is not recorded either" {
  id="$(cr ask --title "Which key?" --option a --option b)"
  run cr ask answer "$id" --via app --pick 1 --note "use ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  [ "$status" -ne 0 ]
  [ ! -e "$CHARTROOM_HOME/questions/$id.answer.json" ]
  run cr ask answer "$id" --via app --pick 1
  [ "$status" -eq 0 ]
}

@test "mailbox: an append waits for a live writer's lock and takes over a dead one's" {
  mkdir -p "$CHARTROOM_HOME/relays/inbox.ndjson.lock"
  sleep 30 & holder=$!
  echo "$holder" >"$CHARTROOM_HOME/relays/inbox.ndjson.lock/pid"
  ( sleep 1; rm -rf "$CHARTROOM_HOME/relays/inbox.ndjson.lock" ) &
  start=$SECONDS
  cr tell "after the lock" >/dev/null
  (( SECONDS - start >= 1 ))
  kill "$holder" 2>/dev/null || true
  # a lock left by a writer that died
  mkdir -p "$CHARTROOM_HOME/relays/inbox.ndjson.lock"
  echo 2147480000 >"$CHARTROOM_HOME/relays/inbox.ndjson.lock/pid"
  cr tell "past a dead lock" >/dev/null
  [ "$(cr tell list --json | jq -r '[.[].text] | join("|")')" = "after the lock|past a dead lock" ]
  [ ! -e "$CHARTROOM_HOME/relays/inbox.ndjson.lock" ]
}

@test "tell: what the commander said while no XO watched wakes the next watch, fresh or --once" {
  cr relay list >/dev/null # the mailbox exists before anyone told anything
  mkdir -p "$CHARTROOM_HOME/relays"; : >>"$CHARTROOM_HOME/relays/inbox.ndjson"
  id="$(cr tell --via app "said while nobody watched")"
  # a first --once (it makes its cursor at the end of the mailbox) still wakes with it
  run cr watch --once --timeout 3
  [[ "$output" == *"[commander $id] [via app] said while nobody watched"* ]]
  # a fresh stream too, until the XO acks it
  stream3 >"$BATS_TEST_TMPDIR/w1"
  grep -qF "[commander $id]" "$BATS_TEST_TMPDIR/w1"
  [[ "$(cr status)" == *"told: 1 unread from the commander"* ]]
  cr tell ack "$id" >/dev/null
  stream3 >"$BATS_TEST_TMPDIR/w2"
  run grep -qF "[commander $id]" "$BATS_TEST_TMPDIR/w2"
  [ "$status" -ne 0 ]
  [[ "$(cr status)" != *"told:"* ]]
}

@test "request: new work from the composer reaches the XO, sits in Drafting, and leaves it once briefed" {
  id="$(cr request --title "Gift wrap at checkout" --project shop --priority high --via app - <<<"Shoppers ask for it every December.")"
  [[ "$id" =~ ^rq-[0-9a-f]{4}$ ]]
  run cr watch --once --timeout 5
  [[ "$output" == *"[commander cm-"*"] [via app] [shop] [re $id] New task request $id: Gift wrap at checkout (project shop) [priority high] Shoppers ask for it every December."* ]]
  [ "$(snap | jq -r --arg id "$id" '.requests[] | select(.id == $id) | .title')" = "Gift wrap at checkout" ]
  run cr request --title "Bad" --priority extreme
  [ "$status" -ne 0 ]
  cr request "done" "$id" --task "$(cr status --json | jq -r '.[0].id')" >/dev/null
  [ "$(snap | jq '.requests | length')" -eq 0 ]
  [ "$(cr request list --all --json | jq -r '.[0].task != null')" = true ]
}
