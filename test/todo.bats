#!/usr/bin/env bats
# `chartroom todo`: the commander's next steps from the inbox, the artifacts and the tasks waiting
# on them; its order; ticking items off; and how it follows focus mode's marks.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
}

ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# task <id> <secs ago> <kind: text>: a dispatched task record whose last event is that line.
task() {
  local d="$CHARTROOM_HOME/tasks/$1"
  mkdir -p "$d"
  jq -n --arg id "$1" --arg c "$(ago 9000)" --arg disp "$(ago 7200)" \
    '{schema:1,id:$id,title:("Task " + $id),kind:"ship",backend:"subagent",project:"/srv/code/shop",created:$c,updated:$c,dispatched:$disp}' >"$d/meta.json"
  printf '%s note: dispatched via subagent\n%s %s\n' "$(ago 7200)" "$(ago "$2")" "$3" >"$d/events.log"
}

@test "todo: what the commander owes, breaking first, then dates in the text, then oldest" {
  # a date 30 days ahead (`ago` of a negative age), so it is a due date on any day
  local due; due="$(ago -2592000)"; due="${due:0:10}"
  task t-decision 600 "decision: pick A or B before $due (recommend A)"
  task t-blocked 6000 "blocked: [breaking] prod is down, need the DB password"
  task t-ready 400 "done: PR https://github.com/acme/shop/pull/7 ready"
  task t-failed 300 "failed: tests do not build"
  task t-working 120 "progress: halfway"
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF'
# Inbox

## Waiting on the commander
- [i-0a01] 2026-01-02 — [shop] merge the parser PR?
- [i-0a02] 2026-01-05 — renew the cert asap
- [i-0a03] 2026-01-06 — [legal] sign the NDA, not before 2026-10-22 09:00Z
- [i-0a04] 2026-01-07 — this one is not urgent (asked 2026-01-07, after 2026-01-02)

## Approvals given in chat, not yet in a brief
- 2026-01-03 — ok to rotate the test key
EOF
  cr artifact add t-ready --kind message --title "Reply to the review" - <<<"thanks" >/dev/null
  cr artifact add i-0a01 --kind runbook --title "Merge steps" - <<<"git merge" >/dev/null
  cr artifact add t-ready --kind note --title "Just a note" - <<<"fyi" >/dev/null
  # the runbook is older than the ready task's last event, the message newer
  local m="$CHARTROOM_HOME/inbox/i-0a01/artifacts/merge-steps.json"
  jq '.created = "2026-01-03T00:00:00Z"' "$m" >"$m.tmp" && mv "$m.tmp" "$m"
  run cr todo --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.items[].ref] | join(" ")' <<<"$output")" = \
    "i-0a02 t-blocked i-0a03 t-decision i-0a01 i-0a01/merge-steps i-0a04 t-ready t-ready/reply-to-the-review" ]
  [ "$(jq -c '[.count, .held, .focus]' <<<"$output")" = '[9,0,null]' ]
  [ "$(jq -c '[.items[] | [.kind, .label]][0:4]' <<<"$output")" = \
    '[["inbox","renew the cert asap"],["blocked","blocked: prod is down, need the DB password"],["inbox","sign the NDA, not before 2026-10-22 09:00Z"],["decision","decide: pick A or B before '"$due"' (recommend A)"]]' ]
  [ "$(jq -c '[.items[] | select(.due) | [.ref, .due]]' <<<"$output")" = \
    '[["i-0a03","2026-10-22T09:00:00Z"],["t-decision","'"$due"'T00:00:00Z"]]' ]
  [ "$(jq -c '[.items[] | select(.breaking) | .ref]' <<<"$output")" = '["i-0a02","t-blocked"]' ]
  [ "$(jq -c '[.items[] | select(.type != "inbox") | [.ref, .owner, .tickable]]' <<<"$output")" = \
    '[["t-blocked","t-blocked",false],["t-decision","t-decision",false],["i-0a01/merge-steps","i-0a01",true],["t-ready","t-ready",false],["t-ready/reply-to-the-review","t-ready",true]]' ]
  [ "$(jq -r '.items[] | select(.kind == "ready") | .label' <<<"$output")" = "PR to review: Task t-ready" ]
  # the board carries the same list, for the crew views and the dashboard
  [ "$(cr board --json | jq -c '[.todo.items[].ref]')" = "$(jq -c '[.items[].ref]' <<<"$output")" ]
  run cr todo --no-color
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
  [[ "${lines[0]}" == "☐ i-0a02 "*" renew the cert asap  breaking  "* ]]
  [[ "${lines[2]}" == "☐ i-0a03 "*"[legal] sign the NDA, not before 2026-10-22 09:00Z  due 2026-10-22 09:00Z  "* ]]
}

@test "todo done removes an inbox line or marks an artifact done; a task is never ticked; add" {
  task t-decision 600 "decision: pick A or B"
  local a b ref
  a="$(cr todo add --project shop "renew the cert")"
  b="$(cr todo add "call the bank")"
  [[ "$a" =~ ^i-[0-9a-f]{4}$ ]]
  grep -qE "^- \[$a\] [0-9-]{10} — \[shop\] renew the cert$" "$CHARTROOM_HOME/inbox.md"
  ref="$(cr artifact add "$b" --kind message --title "Note to the bank" - <<<"hello")"
  [ "$(cr todo --json | jq -c '[.items[].ref] | sort')" = "$(jq -nc --arg a "$a" --arg b "$b" --arg r "$ref" '[$a, $b, $r, "t-decision"] | sort')" ]

  run cr todo done "$a"
  [ "$status" -eq 0 ]; [ "$output" = "done $a: [shop] renew the cert" ]
  run cr todo done "$ref"
  [ "$status" -eq 0 ]; [ "$output" = "done $ref: Note to the bank" ]
  # the last Waiting line gone, the section reads "(none)" again, as the template has it
  run cr todo done "$b"
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^## Waiting/,/^## Approvals/p' "$CHARTROOM_HOME/inbox.md")" = $'## Waiting on the commander\n- (none)\n\n## Approvals given in chat, not yet in a brief' ]
  run cr todo done "$b"
  [ "$status" -ne 0 ]; [[ "$output" == *"unknown id '$b'"* ]]
  # a decision clears when the XO relays the answer, so it stays
  run cr todo done t-decision
  [ "$status" -ne 0 ]
  [[ "$output" == *"t-decision waits on your decision: it clears when the XO relays your answer (/continue t-decision)"* ]]
  [ "$(cr todo --json | jq -c '[.items[].ref]')" = '["t-decision"]' ]
}

@test "todo follows focus mode's marks: held items counted apart, an artifact as its owner's card" {
  # The board as focus mode (lib/focus.sh) leaves it: held/in_focus on the cards, .focus on top.
  local board artifacts out
  board='{"focus": {"projects": ["shop"], "scope": ["IR-6"], "since": "2026-10-19T09:00:00Z", "until": null, "held": 2},
    "lanes": {"needs_you": [
      {"type": "task", "id": "t-in", "short_id": "t-in", "project": "shop", "title": "IR-6 containment", "state": "decision",
       "last_event": "decision: roll back?", "last_at": "2026-10-19T10:00:00Z", "in_focus": true, "held": false},
      {"type": "task", "id": "t-out", "short_id": "t-out", "project": "api", "title": "Risk triage", "state": "blocked",
       "last_event": "blocked: need creds", "last_at": "2026-10-19T08:00:00Z", "in_focus": false, "held": true},
      {"type": "task", "id": "t-brk", "short_id": "t-brk", "project": "api", "title": "Outage", "state": "blocked",
       "last_event": "blocked: [breaking] prod down", "last_at": "2026-10-19T11:00:00Z", "in_focus": true, "held": false, "breaking": true},
      {"type": "inbox", "id": "inbox-0", "short_id": "i-0b01", "project": "legal", "title": "sign the NDA",
       "last_at": "2026-10-18T00:00:00Z", "in_focus": false, "held": true}],
    "in_progress": [], "on_hold": [], "ready": [], "recent": []}}'
  artifacts='[
    {"ref": "i-0b01/reply", "owner_type": "inbox", "owner": "i-0b01", "slug": "reply", "title": "Reply to legal", "kind": "message", "project": "legal", "created": "2026-10-18T12:00:00Z", "path": "/x/reply.md"},
    {"ref": "t-in/steps", "owner_type": "task", "owner": "t-in", "slug": "steps", "title": "Rollback steps", "kind": "runbook", "project": "shop", "created": "2026-10-19T10:30:00Z", "path": "/x/steps.md"},
    {"ref": "t-gone/a", "owner_type": "task", "owner": "t-gone", "slug": "a", "title": "IR-6 status note", "kind": "message", "project": "shop", "created": "2026-10-17T00:00:00Z", "path": "/x/a.md"},
    {"ref": "t-gone/b", "owner_type": "task", "owner": "t-gone", "slug": "b", "title": "Unrelated", "kind": "message", "project": "shop", "created": "2026-10-17T00:00:01Z", "path": "/x/b.md"}]'
  # focus_item as focus mode defines it, cut down: the project, and a scope word in the title
  out="$(jq -c --argjson artifacts "$artifacts" "$(printf '%s\n%s' \
    'def focus_item($f): (.project == $f.projects[0]) and ((.title // "") | test($f.scope[0])); ' \
    "$(cat "$REPO_ROOT/lib/todo.jq")")" <<<"$board" | jq -c '.todo')"
  [ "$(jq -c '[.count, .held, .focus.projects]' <<<"$out")" = '[4,4,["shop"]]' ]
  [ "$(jq -c '[.items[] | [.ref, .held]]' <<<"$out")" = \
    '[["t-brk",false],["t-gone/a",false],["t-gone/b",true],["i-0b01",true],["i-0b01/reply",true],["t-out",true],["t-in",false],["t-in/steps",false]]' ]
}
