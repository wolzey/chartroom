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
