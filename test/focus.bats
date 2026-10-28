#!/usr/bin/env bats
# Focus mode: one project (or a few) at a time. Other projects' questions and results are held,
# counted everywhere, and still wake the XO marked [held]; a breaking report never is.

load test_helper
setup() { common_setup; cr init >/dev/null; }

# A dispatched task in project <name> (a repo of that name), its state set by one event.
task_in() { # <project> <kind> [--breaking] <text>
  local p="$BATS_TEST_TMPDIR/$1" id; shift
  [[ -d "$p/.git" ]] || { git init -q "$p"; git -C "$p" commit -q --allow-empty -m init; }
  id="$(PROJECT="$p" new_task --backend command --command "$STUB {id}")"
  jq '.dispatched = "2026-01-01T00:00:00Z"' "$CHARTROOM_HOME/tasks/$id/meta.json" >"$BATS_TEST_TMPDIR/m" &&
    mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id/meta.json"
  cr event "$id" "$@"
  printf '%s' "$id"
}

@test "focus: on, show, change, off; names are checked" {
  run cr focus
  [ "$output" = "focus: off" ]
  run cr focus shop
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "focus on: shop" ]]
  [[ "$output" == *"nothing open is in shop yet"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "🎯 focus: shop · 0 held (since "*")" ]]
  [ "$(jq -c .projects "$CHARTROOM_HOME/focus.json")" = '["shop"]' ]
  run cr focus Shop,BILLING --for 2h
  [[ "${lines[0]}" == "focus on: shop, billing until "*" (was shop)" ]]
  [ "$(jq -r '.until | fromdateiso8601 - now | . > 7100 and . <= 7200' "$CHARTROOM_HOME/focus.json")" = true ]
  # durations, pinned well inside their buckets so a slow run cannot change them
  jq '.since = (now - 3 * 86400 - 2.5 * 3600 | floor | todate) | .until = (now + 2 * 86400 + 3.5 * 3600 | floor | todate)' \
    "$CHARTROOM_HOME/focus.json" >"$BATS_TEST_TMPDIR/f" && mv "$BATS_TEST_TMPDIR/f" "$CHARTROOM_HOME/focus.json"
  run cr focus
  [[ "$output" == "🎯 focus: shop, billing · 0 held (since 3d2h, 2d3h left)" ]]
  run cr focus 'no/slash'
  [ "$status" -ne 0 ]
  run cr focus shop --for soon
  [ "$status" -ne 0 ]
  run cr focus off
  [[ "$output" == "focus off: shop, billing, on for 3d2h. Nothing was held." ]]
  [ ! -e "$CHARTROOM_HOME/focus.json" ]
  run cr focus off
  [ "$output" = "focus: already off" ]
}

@test "held: other projects' questions and results, plus their inbox items; shop covers shop-api" {
  a="$(task_in shop decision "pick A or B")"
  b="$(task_in shop-api done "shipped")"
  c="$(task_in shopify blocked "needs a token")"
  d="$(task_in billing done "report ready")"
  e="$(task_in billing progress "halfway")"
  f="$(task_in billing failed --breaking "production is down")"
  cr inbox add --project shop "shop question" >/dev/null
  cr inbox add --project billing "billing question" >/dev/null 2>&1
  cr inbox add "unlabelled question" >/dev/null 2>&1
  run cr focus shop
  [[ "${lines[0]}" == "focus on: shop (covers shop, shop-api, 1 inbox item)" ]]
  [[ "$output" == *"🎯 focus: shop · 4 held (since "* ]]
  # held: shopify's blocker, billing's result, two inbox items. Not: shop, shop-api, a
  # progressing task, a breaking failure.
  run cr status --json
  [ "$(jq -c '[.[] | select(.held) | .id] | sort' <<<"$output")" = "$(jq -cn --arg c "$c" --arg d "$d" '[$c, $d] | sort')" ]
  [ "$(jq -r --arg f "$f" '.[] | select(.id == $f) | [.breaking, .in_focus, .held] | @csv' <<<"$output")" = "true,true,false" ]
  [ "$(jq -r --arg e "$e" '.[] | select(.id == $e) | [.in_focus, .held] | @csv' <<<"$output")" = "false,false" ]
  run cr status
  [[ "${lines[0]}" == "🎯 focus: shop · 4 held (since "* ]]
  BOARD="$(cr board --json)"
  [ "$(jq '.focus.held' <<<"$BOARD")" -eq 4 ]
  [ "$(jq -r '.lanes.needs_you[0].id' <<<"$BOARD")" = "$f" ] # a breaking report leads Needs you
  [ "$(jq -c '[.lanes.needs_you[] | select(.type == "inbox") | .held]' <<<"$BOARD")" = '[false,true,true]' ]
  [ "$(jq -c '[.lanes.needs_you[] | select(.type == "inbox") | .in_focus]' <<<"$BOARD")" = '[true,false,false]' ]
  [ "$(jq -r --arg c "$c" '.lanes[][] | select(.id == $c) | [.in_focus, .held] | @csv' <<<"$BOARD")" = "false,true" ]
  run cr board --no-color
  [[ "${lines[0]}" == "🎯 focus: shop · 4 held (since "* ]]
  [[ "$output" == *"Needs you (8, 4 held)"* ]]
  grep -qE '\[shopify\] .*\[blocked · held\]' <<<"$output"
  run cr focus --json
  [ "$(jq -r '[.on, .held, (.items | length)] | @csv' <<<"$output")" = "true,4,4" ]
  run cr focus off
  [[ "${lines[0]}" == "focus off: shop, on for "*". 4 held, now back in view:" ]]
  [[ "$output" == *"[shopify] stub task  [blocked]"* ]]
  run cr status --json
  [ "$(jq '[.[] | select(.held)] | length' <<<"$output")" -eq 0 ]
  [ "$(cr board --json | jq '.focus')" = null ]
}

@test "watch marks wakes from projects out of focus [held]; a breaking one is never held" {
  run cr watch --once --timeout 1
  a="$(task_in shop progress "starting")"
  b="$(task_in billing progress "starting")"
  cr focus shop >/dev/null
  cr event "$a" decision "shop question"
  cr event "$b" decision "billing question"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  grep -qE "^\[$a\] \[shop\] [^ ]+ decision: shop question$" <<<"$output"
  grep -qE "^\[$b\] \[billing\] \[held\] [^ ]+ decision: billing question$" <<<"$output"
  cr event "$b" blocked --breaking "customer data exposed"
  run cr watch --once --timeout 5
  grep -qE "^\[$b\] \[billing\] [^ ]+ blocked: \[breaking\] customer data exposed$" <<<"$output"
  run cr event "$b" done --breaking "x"
  [ "$status" -ne 0 ]
}

@test "inbox add says when focus holds the item; --breaking is never held" {
  cr focus shop >/dev/null
  run cr inbox add --project billing "which region?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"held: focus is on shop"* ]]
  run cr inbox add --project billing --breaking "keys leaked"
  [[ "$output" != *"held:"* ]]
  grep -q '— \[billing\] \[breaking\] keys leaked$' "$CHARTROOM_HOME/inbox.md"
  [ "$(cr board --json | jq '.focus.held')" -eq 1 ]
  # unlabelled: "[breaking]" is not read as a project, and labelling it later keeps the mark
  id="$(cr inbox add --breaking "token in a public log")"
  [ "$(cr board --json | jq -c --arg id "$id" '.lanes.needs_you[] | select(.short_id == $id) | [.project, .breaking, .held]')" = '[null,true,false]' ]
  cr inbox project "$id" billing >/dev/null
  grep -q "^- \[$id\] [0-9-]* — \[billing\] \[breaking\] token in a public log$" "$CHARTROOM_HOME/inbox.md"
}

@test "focus --for runs out by itself: past its end, nothing is held" {
  task_in billing decision "pick one" >/dev/null
  cr focus shop --for 1h >/dev/null
  [ "$(cr board --json | jq '.focus.held')" -eq 1 ]
  jq '.until = "2026-01-01T00:00:00Z"' "$CHARTROOM_HOME/focus.json" >"$BATS_TEST_TMPDIR/f" && mv "$BATS_TEST_TMPDIR/f" "$CHARTROOM_HOME/focus.json"
  run cr focus
  [ "$output" = "focus: off (shop ran out at 2026-01-01T00:00:00Z)" ]
  [ "$(cr board --json | jq '.focus')" = null ]
  [ "$(cr status --json | jq '.[0].held')" = false ]
  run cr status
  [[ "${lines[0]}" == ID* ]]
}

@test "--scope narrows a focus to the items that mention it: a task's title or id, an inbox item's text" {
  run cr watch --once --timeout 1
  a="$(TITLE="IR-006 containment checklist" task_in shop progress "starting")"
  b="$(TITLE="Checkout copy" task_in shop progress "starting")"
  c="$(TITLE="IR-0061 is another incident" task_in shop done "done")"
  d="$(TITLE="IR-006 billing check" task_in billing done "done")"
  cr inbox add --project shop "ir-006: confirm the backlog is clear" >/dev/null
  cr inbox add --project shop "which copy for checkout?" >/dev/null
  run cr focus shop --scope IR-006
  [[ "${lines[0]}" == "focus on: shop (IR-006) (covers 1 task, 1 inbox item in shop)" ]]
  [ "$(jq -c '[.schema, .projects, .scope]' "$CHARTROOM_HOME/focus.json")" = '[1,["shop"],["IR-006"]]' ]
  cr event "$a" decision "restore the job?"
  cr event "$b" decision "which copy?"
  run cr status
  [[ "${lines[0]}" == "🎯 focus: shop (IR-006) · 4 held (since "* ]]   # b, c, d and the checkout question
  run cr status --json
  [ "$(jq -r --arg a "$a" '.[] | select(.id == $a) | [.in_focus, .held] | @csv' <<<"$output")" = "true,false" ]
  run cr watch --once --timeout 5
  grep -qE "^\[$a\] \[shop\] [^ ]+ decision: restore the job\?$" <<<"$output"
  grep -qE "^\[$b\] \[shop\] \[held\] [^ ]+ decision: which copy\?$" <<<"$output"
  run cr focus shop --scope NOPE
  [[ "$output" == *"nothing open in shop mentions NOPE yet"* ]]
}
