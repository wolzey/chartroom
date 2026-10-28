#!/usr/bin/env bats
# `chartroom show`: one item in detail, the board's card plus what the task's files say.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
}

# A dispatched task in a herdr tab: a decision with a PR link, then done, with a report.
dispatched_task() {
  local id d
  id="$(TITLE="Fix login" new_task --backend herdr:claude)"
  d="$CHARTROOM_HOME/tasks/$id"
  jq '. + {dispatched: "2026-01-02T10:00:00Z", herdr_workspace: "w1", herdr_tab: "w1:t2", herdr_pane: "w1:p2", worktree: "/srv/wt/fix-login"}' "$d/meta.json" >"$d/m" && mv "$d/m" "$d/meta.json"
  cr event "$id" progress "parser rewritten" >/dev/null
  cr event "$id" decision "pick A or B (recommend A), see https://github.com/acme/todo-cli/pull/7" >/dev/null
  cr event "$id" done "PR ready" >/dev/null
  printf '# Report\n\n## Outcome\n\nPR 7 is open.\nNot merged.\n\n## What changed\n\n- parser\n' >"$d/report.md"
  printf '%s' "$id"
}

@test "show --json: the board's card, plus intent, events, outcome, report, PRs and where the worker runs" {
  local id short detail
  id="$(dispatched_task)"
  short="$(cr resolve "$id" --json | jq -r .short_id)"
  detail="$(cr show "$short" --json)"
  [ "$(jq -r '[.type, .id, .title, .state, .lane, .reason] | join("|")' <<<"$detail")" = "task|$id|Fix login|review|needs_you|PR to review" ]
  [ "$(jq -r .intent <<<"$detail")" = "Please do the thing." ]
  [ "$(jq -c '[.events[] | .kind]' <<<"$detail")" = '["progress","decision","done"]' ]
  [ "$(jq -r '.events[1].text' <<<"$detail")" = "pick A or B (recommend A), see https://github.com/acme/todo-cli/pull/7" ]
  [ "$(jq -c '[.outcome.kind, .outcome.text]' <<<"$detail")" = '["done","PR ready"]' ]
  [ "$(jq -r .report.path <<<"$detail")" = "$CHARTROOM_HOME/tasks/$id/report.md" ]
  [ "$(jq -r .report.summary <<<"$detail")" = $'PR 7 is open.\nNot merged.' ]
  [ "$(jq -c '[.prs[].url]' <<<"$detail")" = '["https://github.com/acme/todo-cli/pull/7"]' ]
  [ "$(jq -c .attach <<<"$detail")" = "{\"where\":\"herdr tab w1:t2\",\"command\":\"chartroom attach $id\"}" ]
  [ "$(jq -r .worktree <<<"$detail")" = /srv/wt/fix-login ]
  [ "$(jq -c .artifacts <<<"$detail")" = '[]' ]
  # an open artifact comes through with the board's ref, which `artifact show` takes
  printf 'Thanks for the review.\n' | cr artifact add "$short" --kind message --title "Reply to review" - >/dev/null
  detail="$(cr show "$short" --json)"
  [ "$(jq -c '[.artifacts[] | [.ref, .title, .kind]]' <<<"$detail")" = "[[\"$short/reply-to-review\",\"Reply to review\",\"message\"]]" ]
  [ "$(cr artifact show "$(jq -r '.artifacts[0].ref' <<<"$detail")")" = "Thanks for the review." ]
  # it only adds to the card: every field the board has, with the board's values
  [ "$(jq -c 'del(.intent, .events, .outcome, .report, .brief, .worktree, .branch, .attach)' <<<"$detail")" = \
    "$(cr board --json | jq -c --arg id "$id" '.lanes[][] | select(.id == $id)')" ]
  # the same through the full id, and as text
  [ "$(cr show "$id" --json | jq -r .id)" = "$id" ]
  run cr show "$short"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$short  [proj] Fix login" ]
  [[ "$output" == *$'intent:\n  Please do the thing.'* ]]
  [[ "$output" == *"done: PR ready"* ]]
  [[ "$output" == *"worker: herdr tab w1:t2 (chartroom attach $id)"* ]]
}

@test "show: an inbox item by its tag; a task off the board; unknown ids fail" {
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF'
# Inbox

## Waiting on the commander
- [i-7f3a] 2026-01-02 — [webapp] merge the parser PR?
EOF
  run cr show i-7f3a --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.type, .short_id, .project, .text, .date, .lane, .attach, .events, .artifacts]' <<<"$output")" = \
    '["inbox","i-7f3a","webapp","merge the parser PR?","2026-01-02","needs_you",null,[],[]]' ]
  run cr show i-7f3a
  [ "${lines[0]}" = "i-7f3a  [webapp] merge the parser PR?" ]
  [ "${lines[2]}" = "since: 2026-01-02" ]
  # closed long ago: on no lane, still shown from its record
  local id d
  id="$(new_task)"; d="$CHARTROOM_HOME/tasks/$id"
  jq '. + {dispatched: "2025-01-01T00:00:00Z", closed: "2025-01-02T00:00:00Z"}' "$d/meta.json" >"$d/m" && mv "$d/m" "$d/meta.json"
  [ "$(cr show "$id" --json | jq -c '[.state, .lane, .attach.where, .attach.command]')" = '["closed",null,"closed",null]' ]
  run cr show nope-zzzz
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown id 'nope-zzzz'"* ]]
  run cr show
  [ "$status" -ne 0 ]
}
