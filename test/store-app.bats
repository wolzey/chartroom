#!/usr/bin/env bats
# The app's own records on the store (stage d): snoozes, cards and answers, the mailbox. With the
# switch on, new records are store docs; the files from before are still read, nothing is moved.

load test_helper

setup() {
  common_setup
  unset CHARTROOM_STORE # (these tests turn the switch on and off in the home's own config)
  command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null || skip "no python3 with sqlite3"
  export CHARTROOM_DB="$BATS_TEST_TMPDIR/state/chartroom/chartroom.db"
  cr init >/dev/null
}

store_on() { printf 'CHARTROOM_STORE=sqlite\n' >>"$CHARTROOM_HOME/config"; }
db() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); [print("|".join(map(str,r))) for r in c.execute(sys.argv[2])]' "$CHARTROOM_DB" "$1"; }

@test "snooze: a store row once the switch is on; the newest per ref wins across the file and the store" {
  cr snooze i-aaaa --for 2h >/dev/null
  cr snooze i-bbbb --for 2h >/dev/null
  before="$(cat "$CHARTROOM_HOME/snoozes.ndjson")"
  store_on
  sleep 1 # (a record's time is to the second; the store's wins a tie anyway)
  # A snooze off in the store ends the file's snooze of i-aaaa; i-bbbb's still holds.
  cr snooze off i-aaaa >/dev/null
  cr snooze i-cccc --until 2099-01-01T00:00:00Z >/dev/null
  [ "$(cr snooze list --json | jq -c 'keys')" = '["i-bbbb","i-cccc"]' ]
  [ "$(cr snooze list --all --json | jq -c '[.["i-aaaa"], .["i-cccc"]]')" = '[null,"2099-01-01T00:00:00Z"]' ]
  [ "$(cat "$CHARTROOM_HOME/snoozes.ndjson")" = "$before" ]
  [ "$(db "select count(*) from docs where kind = 'snooze'")" = 2 ]
  # One row per ref: a second snooze of i-cccc replaces the first.
  cr snooze i-cccc --until 2098-01-01T00:00:00Z >/dev/null
  [ "$(db "select count(*) from docs where kind = 'snooze'")" = 2 ]
  [ "$(cr snooze list --json | jq -r '.["i-cccc"]')" = 2098-01-01T00:00:00Z ]
}

@test "schema 3 beside an older chartroom: a newer database it may still use is not refused" {
  store_on
  new_task >/dev/null
  [ "$(db 'pragma user_version')" = 3 ]
  [ "$(db 'select min_reader from compat')" = 2 ]
  # A later schema that only adds tables keeps min_reader: this chartroom (3) still uses it.
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("pragma user_version = 9"); c.commit()' "$CHARTROOM_DB"
  run cr status --json
  [ "$status" -eq 0 ]
  # One that raises min_reader past 3 is refused, loudly.
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("update compat set min_reader = 9"); c.commit()' "$CHARTROOM_DB"
  run cr status --json
  # (the crew is not shown as empty: the command fails, and so do the board and the app's snapshot)
  [[ "$output" != *"[]"* ]]
  run cr board --json
  [ "$status" -ne 0 ]
  run cr app snapshot --json
  [ "$status" -ne 0 ]
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer than this chartroom (3): update chartroom"* ]]
}

@test "cards: a new card is a store doc; its answer too, the first one winning; withdraw and list" {
  store_on
  q="$(cr ask --title "Which cache?" --option LRU --option Redis --recommend 1)"
  [[ "$q" =~ ^q-[0-9a-f]{4}$ ]]
  [ ! -e "$CHARTROOM_HOME/questions/$q.json" ]
  [ "$(cr ask list --json | jq -r '.[0] | "\(.id) \(.questions | length)"')" = "$q 1" ]
  run cr ask answer "$q" --pick 2
  [ "$status" -eq 0 ]
  run cr ask answer "$q" --pick 1
  [ "$status" -ne 0 ]; [[ "$output" == *"$q was already answered (by terminal at "* ]]
  [ "$(cr ask show "$q" --json | jq -r '.answer.answers[0].choice')" = Redis ]
  [ "$(cr ask list --json | jq length)" = 0 ]
  [ "$(cr ask list --all --json | jq -r '.[0].answer.via')" = terminal ]
  w="$(cr ask --title "Still needed?" --option yes --option no)"
  cr ask withdraw "$w" "settled in chat" >/dev/null
  run cr ask answer "$w" --pick 1
  [ "$status" -ne 0 ]; [[ "$output" == *"withdrawn"* ]]
  [ ! -d "$CHARTROOM_HOME/questions" ] || [ -z "$(ls -A "$CHARTROOM_HOME/questions")" ]
  [ "$(db "select count(*) from docs where kind = 'card'") $(db "select count(*) from docs where kind = 'answer'")" = "2 2" ]
}

@test "cards: an answer lives where its card does; two first answers at once, one wins, in either place" {
  old="$(cr ask --title "Old card?" --option a --option b)" # (born a file, before the switch)
  store_on
  new="$(cr ask --title "New card?" --option a --option b)"
  for q in "$old" "$new"; do
    for p in 1 2; do (rc=0; cr ask answer "$q" --pick "$p" >"$BATS_TEST_TMPDIR/$q.$p" 2>&1 || rc=$?; echo "$rc" >"$BATS_TEST_TMPDIR/$q.$p.rc") & done
    wait
    [ "$(cat "$BATS_TEST_TMPDIR/$q.1.rc" "$BATS_TEST_TMPDIR/$q.2.rc" | sort | tr '\n' ' ')" = "0 1 " ]
  done
  # The old card's answer is its file; the new card's a store doc; neither has both.
  [ -f "$CHARTROOM_HOME/questions/$old.answer.json" ]
  [ ! -e "$CHARTROOM_HOME/questions/$new.answer.json" ]
  [ "$(db "select group_concat(id) from docs where kind = 'answer'")" = "$new" ]
  [ "$(cr ask list --all --json | jq -r 'map(select(.answer != null)) | length')" = 2 ]
}

@test "a worker's ask and an inbox item: the answer follows the task or the item; the app's snapshot sees it" {
  ft="$(TITLE="file task" new_task)"; set_meta "$ft" '.dispatched = "2026-01-02T10:00:00Z"'
  cr event "$ft" decision "file task: left or right?" >/dev/null
  fi="$(cr inbox add "a question from before")"
  store_on
  st="$(TITLE="store task" new_task)"; set_meta "$st" '.dispatched = "2026-01-02T10:00:00Z"'
  cr event "$st" decision "store task: up or down?" >/dev/null
  si="$(cr inbox add "a question in the store")"
  card_of() { cr app snapshot --json | jq -r --arg t "$1" '.needs[] | select(.task == $t) | .card'; }
  fc="$(card_of "$ft")"; sc="$(card_of "$st")"
  [[ "$fc" == ev-$ft-* && "$sc" == ev-$st-* ]]
  n0="$(cr app snapshot --json | jq '.counts.needs')"
  cr ask answer "$fc" --note left >/dev/null
  cr ask answer "$sc" --note up >/dev/null
  cr ask answer "$fi" --note "yes" >/dev/null
  cr ask answer "$si" --note "no" >/dev/null
  [ -f "$CHARTROOM_HOME/questions/$fc.answer.json" ]; [ -f "$CHARTROOM_HOME/questions/$fi.answer.json" ]
  [ "$(db "select id from docs where kind = 'answer' order by id" | tr '\n' ' ')" = "$sc $si " ]
  # Answered in the terminal: the app's snapshot shows each item as sent, from both places.
  snap="$(cr app snapshot --json)"
  for c in "$fc" "$sc" "$fi" "$si"; do [ "$(jq -r --arg c "$c" '.needs[] | select(.card == $c) | .sent.via' <<<"$snap")" = terminal ]; done
  [ "$(jq '.counts.needs' <<<"$snap")" -eq $((n0 - 4)) ]
  [ "$(cr app task "$st" --json | jq -r '.answer.answers[0].note')" = up ]
}

@test "tell: a store row once the switch is on; the watch wakes once; ack; nothing written to the mailbox file" {
  store_on
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  id="$(cr tell --via app --re q-1234 "ship it after lunch")"
  [[ "$id" =~ ^cm-[0-9a-f]{4}$ ]]
  [ ! -e "$CHARTROOM_HOME/relays/inbox.ndjson" ]
  [ "$(db "select kind || ' ' || id from mail")" = "commander $id" ]
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"[commander $id] [via app] [re q-1234] ship it after lunch"* ]]
  run cr watch --once --timeout 1
  [ "$status" -eq 124 ]
  [ "$(cr tell list --json | jq -r '.[0].id')" = "$id" ]
  [[ "$(cr status)" == *"told: 1 unread from the commander"* ]]
  cr tell ack "$id" >/dev/null
  [ "$(cr tell list --json | jq length)" = 0 ]
  [ "$(db "select group_concat(kind) from mail")" = "commander,ack" ]
}

@test "the mailbox's two halves: an old file's records and acks, a store's, a file an older sender still grows" {
  cr init --name here >/dev/null 2>&1 || true
  old="$(cr tell "from before the switch")"
  store_on
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  # An ack written after the switch (a store row) acks the file's record.
  cr tell ack "$old" >/dev/null
  [ "$(cr tell list --json | jq length)" = 0 ]
  [ "$(cr tell list --all --json | jq -r '.[0].acked')" = true ]
  # A line an older chartroom appends to the file, and a store row: one watch wakes on each, once.
  printf '{"schema":1,"kind":"commander","id":"cm-0dd1","at":"2026-01-01T00:00:00Z","text":"appended by an older chartroom","via":"app","re":null,"project":null}\n' >>"$CHARTROOM_HOME/relays/inbox.ndjson"
  new="$(cr tell "after the switch")"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"[commander cm-0dd1]"*"appended by an older chartroom"* ]]
  [[ "$output" == *"[commander $new]"*"after the switch"* ]]
  [[ "$output" != *"$old"* ]]
  grep -q '^@mail	' "$CHARTROOM_HOME/.watch-cursor"; grep -q '^@relays	' "$CHARTROOM_HOME/.watch-cursor"
  run cr watch --once --timeout 1
  [ "$status" -eq 124 ]
}

@test "relay between homes: born where the receiving home's switch says, in the database its .home-id names" {
  unset CHARTROOM_DB
  A="$BATS_TEST_TMPDIR/acme"; B="$BATS_TEST_TMPDIR/globex"; C="$BATS_TEST_TMPDIR/initech"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$B" cr init --name globex >/dev/null
  CHARTROOM_HOME="$C" cr init --name initech >/dev/null
  printf 'CHARTROOM_STORE=sqlite\n' >>"$A/config"; printf 'CHARTROOM_STORE=sqlite\n' >>"$B/config"
  # globex was born in a database of its own (another state directory, as a GUI launcher's).
  XDG_STATE_HOME="$BATS_TEST_TMPDIR/stateB" CHARTROOM_HOME="$B" cr new --project "$PROJECT" --title "b's first" >/dev/null
  dbA="$BATS_TEST_TMPDIR/state/chartroom/chartroom.db"; dbB="$BATS_TEST_TMPDIR/stateB/chartroom/chartroom.db"
  [ "$(sed -n 2p "$B/.home-id")" = "$dbB" ]
  CHARTROOM_HOME="$B" cr watch --once --timeout 1 >/dev/null 2>&1 || true
  # acme (on) to globex (on): a row in globex's own database, a sent doc in acme's.
  r1="$(CHARTROOM_HOME="$A" cr relay globex "to an on home")"
  [ "$(CHARTROOM_DB="$dbB" python3 -c 'import sqlite3,os; c=sqlite3.connect(os.environ["CHARTROOM_DB"]); print(c.execute("select id from mail").fetchone()[0])')" = "$r1" ]
  [ ! -e "$B/relays/inbox.ndjson" ]; [ ! -e "$A/relays/outbox.ndjson" ]
  # the record as the file would hold it, and the sender's copy the same
  [ "$(mail_of "$B" | jq -c '[.schema, .kind, .id, .from, .to, .text, .re, .project]')" = "[1,\"relay\",\"$r1\",\"acme\",\"globex\",\"to an on home\",null,null]" ]
  [ "$(CHARTROOM_HOME="$A" cr relay list --all --json | jq -r '.[0] | "\(.direction) \(.id)"')" = "out $r1" ]
  run env CHARTROOM_HOME="$B" "$CHARTROOM" watch --once --timeout 5
  [ "$status" -eq 0 ]; [[ "$output" == *"[relay $r1] [from acme] to an on home"* ]]
  # acme (on) to initech (off): its file, as today, and no store for it.
  r2="$(CHARTROOM_HOME="$A" cr relay initech "to an off home")"
  [ "$(jq -r .id "$C/relays/inbox.ndjson")" = "$r2" ]
  [ ! -e "$C/.home-id" ]
  # initech (off) to acme (on): acme's store; a reply threads; acme lists it and acks it.
  r3="$(CHARTROOM_HOME="$C" cr relay acme --re "$r2" "back to an on home")"
  [ ! -e "$A/relays/inbox.ndjson" ]
  [ "$(CHARTROOM_HOME="$A" cr relay list --json | jq -r '.[0] | "\(.id) \(.re)"')" = "$r3 $r2" ]
  CHARTROOM_HOME="$A" cr relay ack "$r3" >/dev/null
  [ "$(CHARTROOM_HOME="$A" cr relay list --json | jq length)" = 0 ]
}

@test "a running watch hears its home's first store mail at once, though the home had no store id when it started" {
  A="$BATS_TEST_TMPDIR/acme"; B="$BATS_TEST_TMPDIR/globex"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$B" cr init --name globex >/dev/null
  printf 'CHARTROOM_STORE=sqlite\n' >>"$B/config"
  [ ! -e "$B/.home-id" ]
  CHARTROOM_HOME="$B" CHARTROOM_WATCH_INTERVAL=30 "$CHARTROOM" watch --once --timeout 20 >"$BATS_TEST_TMPDIR/w" 2>&1 3>&- &
  w=$!
  for _ in $(seq 1 50); do [ -f "$B/.watch-cursor" ] && break; sleep 0.1; done
  sleep 1
  rid="$(CHARTROOM_HOME="$A" cr relay globex "the first store record of this home")"
  [ -s "$B/.home-id" ]
  for _ in $(seq 1 40); do kill -0 "$w" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$w" 2>/dev/null || { kill -9 "$w"; false; }
  wait "$w" || true
  [ "$(cat "$BATS_TEST_TMPDIR/w")" = "[relay $rid] [from acme] the first store record of this home" ]
}
