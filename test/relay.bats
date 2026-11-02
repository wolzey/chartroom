#!/usr/bin/env bats
# Relays between homes (lib/relay.sh): `chartroom relay` appends one record to another home's
# mailbox and nothing else; that home's watch wakes on it exactly once; ack and reply; the views
# (inbox list, status, the board, --all-homes); and the refusals.

load test_helper
setup() {
  common_setup
  A="$BATS_TEST_TMPDIR/acme"; B="$BATS_TEST_TMPDIR/globex"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$B" cr init --name globex >/dev/null
}

in_a() { CHARTROOM_HOME="$A" cr "$@"; }
in_b() { CHARTROOM_HOME="$B" cr "$@"; }

@test "relay appends one record to the other home's mailbox, keeps a copy, and writes nothing else" {
  task="$(CHARTROOM_HOME="$B" cr new --project "$PROJECT" --title "look around" --kind scout | sed -n 's/^id=//p')"
  before_a="$(snapshot "$A")"; before_b="$(snapshot "$B")"
  run in_a relay globex --project shop "which region does staging use?"
  [ "$status" -eq 0 ]
  id="$output"
  [[ "$id" =~ ^rl-[0-9a-f]{4}$ ]]
  rec="$(cat "$B/relays/inbox.ndjson")"
  [ "$(jq -c '[.schema, .kind, .id, .from, .to, .text, .re, .project]' <<<"$rec")" = "[1,\"relay\",\"$id\",\"acme\",\"globex\",\"which region does staging use?\",null,\"shop\"]" ]
  [[ "$(jq -r .at <<<"$rec")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # the target: its mailbox is the one new file, its tasks untouched; the sender: its outbox
  [ "$(snapshot "$B" | grep -vF " $B/relays/inbox.ndjson")" = "$before_b" ]
  [ "$(find "$B/relays" -type f | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(cat "$A/relays/outbox.ndjson")" = "$rec" ]
  [ "$(snapshot "$A" | grep -vF " $A/relays/outbox.ndjson")" = "$before_a" ]
  [ "$(cat "$B/tasks/$task/events.log" | grep -c relay)" -eq 0 ]
  # a project path is reduced to its name; - reads the message from stdin
  run bash -c 'printf "from stdin\nline two" | CHARTROOM_HOME="$1" "$2" relay globex --project "$3" -' _ "$A" "$CHARTROOM" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$B/relays/inbox.ndjson" | jq -c '[.text, .project]')" = '["from stdin\nline two","proj"]' ]
}

@test "watch wakes once per relay: --once keeps its cursor, a stream sees one within seconds" {
  run in_b watch --once --timeout 1
  [ "$status" -eq 124 ]
  id="$(in_a relay globex --project shop "two lines
of text, café")"
  run in_b watch --once --timeout 5
  [ "$status" -eq 0 ]
  [ "$output" = "[relay $id] [from acme] [shop] two lines of text, café" ]
  # exactly once
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  # several, while nobody watched (multi-byte text on the way): each once, in order
  i2="$(in_a relay globex "naïve — second")"; i3="$(in_a relay globex "third")"
  run in_b watch --once --timeout 5
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "[relay $i2] [from acme] naïve — second" ]
  [ "${lines[1]}" = "[relay $i3] [from acme] third" ]
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  grep -qx "@relays	$(wc -c <"$B/relays/inbox.ndjson" | tr -d ' ')" "$B/.watch-cursor"
  # a running stream (`watch` without --once) starts at the end, then wakes within seconds
  CHARTROOM_HOME="$B" "$CHARTROOM" watch >"$BATS_TEST_TMPDIR/stream" 2>&1 3>&- &
  pid=$!
  sleep 3
  i4="$(in_a relay globex "live one")"
  for _ in $(seq 1 40); do grep -q "$i4" "$BATS_TEST_TMPDIR/stream" && break; sleep 0.25; done
  kill "$pid"; wait "$pid" 2>/dev/null || true
  [ "$(cat "$BATS_TEST_TMPDIR/stream")" = "[relay $i4] [from acme] live one" ]
}

@test "watch reads whole records only, skips what is not one, and never replays a rewritten mailbox" {
  run in_b watch --once --timeout 1
  [ "$status" -eq 124 ]
  mkdir -p "$B/relays"
  # a record still being written is not read, nor skipped: it wakes once it is whole
  rec='{"schema":1,"kind":"relay","id":"rl-00aa","from":"acme","to":"globex","at":"2026-01-02T03:04:05Z","text":"half\u001b[31m done","re":null,"project":null}'
  printf '%s' "${rec:0:40}" >>"$B/relays/inbox.ndjson"
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  printf '%s\nnot a record\n{"kind":"relay","id":"bad id","from":"x","text":"y"}\n' "${rec:40}" >>"$B/relays/inbox.ndjson"
  run in_b watch --once --timeout 5
  [ "$status" -eq 0 ]
  # control characters in the text never reach the terminal
  [ "$output" = "[relay rl-00aa] [from acme] half [31m done" ]
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  # a NUL byte left by a foreign writer neither shifts the cursor nor reaches the output
  printf 'junk\000junk\n' >>"$B/relays/inbox.ndjson"
  id="$(in_a relay globex "after the junk")"
  run in_b watch --once --timeout 5
  [ "$status" -eq 0 ]
  [ "$output" = "[relay $id] [from acme] after the junk" ]
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  grep -qx "@relays	$(wc -c <"$B/relays/inbox.ndjson" | tr -d ' ')" "$B/.watch-cursor"
  printf '' >"$B/relays/inbox.ndjson"
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  id="$(in_a relay globex "after the rewrite")"
  run in_b watch --once --timeout 5
  [ "$output" = "[relay $id] [from acme] after the rewrite" ]
}

@test "ack marks a relay handled: it leaves the lists, and one acked before the watch saw it never wakes" {
  run in_b watch --once --timeout 1
  id="$(in_a relay globex --project shop "please check the cert")"
  run in_b relay list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Relays from other homes:" ]
  [[ "${lines[1]}" == "- [$id] "*"Z — [from acme] [shop] please check the cert" ]]
  run in_b relay ack "[${id^^}]"
  [ "$status" -eq 0 ]; [ "$output" = "acked $id" ]
  [ "$(tail -1 "$B/relays/inbox.ndjson" | jq -c '[.kind, .id]')" = "[\"ack\",\"$id\"]" ]
  run in_b relay ack "$id"
  [ "$status" -eq 0 ]; [ "$output" = "$id was already acked" ]
  run in_b relay list
  [ "$output" = "relays: nothing open" ]
  run in_b relay list --all --json
  [ "$(jq -c '[.[] | [.id, .direction, .acked]]' <<<"$output")" = "[[\"$id\",\"in\",true]]" ]
  # acked before any watch read it: no wake
  run in_b watch --once --timeout 2
  [ "$status" -eq 124 ]
  # only a relay this home received can be acked
  run in_a relay ack "$id"
  [ "$status" -ne 0 ]; [[ "$output" == *"no relay $id received in this home"* ]]
  run in_b relay ack nope
  [ "$status" -ne 0 ]; [[ "$output" == *"not a relay id"* ]]
}

@test "a reply goes back to the sender's home the same way, and only between the two homes" {
  CHARTROOM_HOME="$BATS_TEST_TMPDIR/initech" cr init --name initech >/dev/null
  run in_a watch --once --timeout 1
  id="$(in_a relay globex "can you confirm the region?")"
  run in_b relay acme --re "$id" "yes: us-east-2"
  [ "$status" -eq 0 ]; reply="$output"
  [ "$(jq -c '[.from, .to, .re]' "$A/relays/inbox.ndjson")" = "[\"globex\",\"acme\",\"$id\"]" ]
  run in_a watch --once --timeout 5
  [ "$status" -eq 0 ]
  [ "$output" = "[relay $reply] [from globex] [re $id] yes: us-east-2" ]
  # the thread, from either side
  run in_a relay list --all
  [[ "$output" == *"[$reply] "*"[from globex] yes: us-east-2 (re $id)"*"Sent:"*"[$id] "*"[to globex] can you confirm the region?"* ]]
  # a reply does not ack the original
  [ "$(in_b relay list --json | jq -r '.[0].id')" = "$id" ]
  # a follow-up on one's own relay works too; the id must belong to the two homes
  run in_a relay globex --re "$id" "also: which zone?"
  [ "$status" -eq 0 ]
  run in_b relay initech --re "$id" "not yours"
  [ "$status" -ne 0 ]; [[ "$output" == *"no relay $id between this home and initech"* ]]
  run in_b relay acme --re rl-ffff "unknown"
  [ "$status" -ne 0 ]
  run in_b relay acme --re bogus "unknown"
  [ "$status" -ne 0 ]; [[ "$output" == *"--re takes a relay id"* ]]
}

@test "relays show in inbox list, status, the board and the --all-homes views; never as cards or todo items" {
  id="$(in_a relay globex --project shop "heads up: the shared bucket moves on Friday")"
  run in_b inbox list
  [ "${lines[0]}" = "Relays from other homes (for the XO to weigh):" ]
  [[ "${lines[1]}" == "- [$id] "*"[from acme] [shop] heads up: the shared bucket moves on Friday" ]]
  [ "$(in_b inbox list --json | jq -c '.relays | map([.id, .from, .project])')" = "[[\"$id\",\"acme\",\"shop\"]]" ]
  run in_b status
  [[ "$output" == *"relays: 1 open from other homes (chartroom relay list)"* ]]
  run in_a status
  [[ "$output" != *relays:* ]]
  board="$(in_b board --json)"
  [ "$(jq -c '.inbox.relays | map(.id)' <<<"$board")" = "[\"$id\"]" ]
  [ "$(jq '[.lanes[][]] | length' <<<"$board")" -eq 0 ]
  [ "$(jq '.todo.items | length' <<<"$board")" -eq 0 ]
  # the umbrella view: every home's open relays, labelled, read-only
  before="$(snapshot "$A" "$B")"
  run in_a inbox list --all-homes
  [ "$status" -eq 0 ]
  [[ "$output" == *"== acme · $A (this home)"*"inbox: nothing open"*"== globex · $B"*"[$id]"*"[from acme] [shop] heads up"* ]]
  [ "$(in_a inbox list --all-homes --json | jq -c '[.[] | [.home, (.result.relays | length)]]')" = '[["acme",0],["globex",1]]' ]
  run in_a relay list --all-homes
  [[ "$output" == *"== acme"*"relays: nothing open"*"== globex"*"[$id]"* ]]
  run in_a status --all-homes
  [[ "$output" == *"== globex"*"relays: 1 open from other homes"* ]]
  [ "$(snapshot "$A" "$B")" = "$before" ]
  run in_a relay ack "$id" --all-homes
  [ "$status" -ne 0 ]
}

@test "relay refuses: an unknown home, this home, an unregistered sender, a non-home, another home's name, a bad flag" {
  run in_a relay initech "hello"
  [ "$status" -ne 0 ]; [[ "$output" == *"no home named initech"*"registered home"* ]]
  run in_a relay acme "hello"
  [ "$status" -ne 0 ]; [[ "$output" == *"acme is this home"* ]]
  run in_a relay globex --from globex "hello"
  [ "$status" -ne 0 ]; [[ "$output" == *"in this home's name only (this home is acme)"* ]]
  run in_a relay globex --from acme "hello"
  [ "$status" -eq 0 ]
  run in_a relay globex --bogus "hello"
  [ "$status" -ne 0 ]; [[ "$output" == *"unknown flag --bogus"* ]]
  run in_a relay globex "   "
  [ "$status" -ne 0 ]; [[ "$output" == *"empty"* ]]
  run in_a relay globex
  [ "$status" -ne 0 ]; [[ "$output" == *"usage: chartroom relay"* ]]
  # a message that only looks like a flag is a message
  run in_a relay globex "-5 degrees at the office, --all-homes still fine"
  [ "$status" -eq 0 ]
  # a registered directory that is not a chartroom home is never written in
  mkdir -p "$BATS_TEST_TMPDIR/plain"; in_a homes add plain "$BATS_TEST_TMPDIR/plain" >/dev/null
  run in_a relay plain "hello"
  [ "$status" -ne 0 ]; [[ "$output" == *"is not a chartroom home"* ]]
  [ -z "$(find "$BATS_TEST_TMPDIR/plain" -mindepth 1)" ]
  # an unregistered home cannot send: a reply could not find it
  cr init >/dev/null
  run cr relay globex "hello"
  [ "$status" -ne 0 ]; [[ "$output" == *"is not registered, so a reply could not find it"* ]]
}

@test "relay caps the size and never stores a secret" {
  run in_a relay globex "$(printf 'x%.0s' $(seq 1 2001))"
  [ "$status" -ne 0 ]; [[ "$output" == *"2001 bytes; a relay holds at most 2000"* ]]
  run in_a relay globex "$(printf 'x%.0s' $(seq 1 2000))"
  [ "$status" -eq 0 ]
  # within the text cap, but past one append once quotes are escaped
  run in_a relay globex "$(printf '"%.0s' $(seq 1 1990))"
  [ "$status" -ne 0 ]; [[ "$output" == *"bytes once written"*"at most 4000"* ]]
  n="$(wc -l <"$B/relays/inbox.ndjson")"
  for s in "the key is AKIA""ABCDEFGHIJKLMNOP" "use ghp_""aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789" \
           "-----BEGIN OPENSSH ""PRIVATE KEY-----" "token: xoxb-""1234567890-abcdefghij" \
           "PASSWORD = ""hunter2hunter2" "sk-ant-""api03-abcdefghijklmnopqrstuvwxyz"; do
    run in_a relay globex "$s"
    [ "$status" -ne 0 ]
    [[ "$output" == *"relay refused: the message looks like it holds"*"nothing was sent"* ]]
    [[ "$output" != *"$s"* ]]
  done
  [ "$(wc -l <"$B/relays/inbox.ndjson")" -eq "$n" ]
  # talking about a secret is fine
  run in_a relay globex "the deploy token lives in the team vault; ask before rotating it"
  [ "$status" -eq 0 ]
}
