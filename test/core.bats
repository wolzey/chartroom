#!/usr/bin/env bats
# Core lifecycle against the `command` backend + stub agent. No AI CLI, no multiplexer.

load test_helper
setup() { common_setup; }

@test "version and help" {
  run cr version
  [ "$status" -eq 0 ]
  [[ "$output" == "chartroom $(cat "$REPO_ROOT/VERSION") (state schema 1)" ]]
  run cr help
  [[ "$output" == *"chartroom doctor"* ]]
}

@test "refuses bash 3 with an install hint" {
  [[ -x /bin/bash ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]' || skip "/bin/bash is not bash 3"
  run /bin/bash "$CHARTROOM" version
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 4 required"* ]]
}

@test "init creates a generic home" {
  run cr init
  [ "$status" -eq 0 ]
  for f in commander.md projects.md inbox.md AGENTS.md CLAUDE.md; do [ -f "$CHARTROOM_HOME/$f" ]; done
  grep -q chartroom "$CHARTROOM_HOME/AGENTS.md"
  grep -q '^## Waiting on the commander' "$CHARTROOM_HOME/inbox.md"
  [[ "$output" == *"No project roots set"* ]]
}

@test "init never overwrites an existing inbox" {
  cr init >/dev/null
  echo "- 2026-01-01 — kept across init" >>"$CHARTROOM_HOME/inbox.md"
  cp "$CHARTROOM_HOME/inbox.md" "$BATS_TEST_TMPDIR/before"
  run cr init
  [ "$status" -eq 0 ]
  cmp "$CHARTROOM_HOME/inbox.md" "$BATS_TEST_TMPDIR/before"
}

@test "status counts open inbox items; json shape is unchanged" {
  cr init >/dev/null
  run cr status
  [ "$status" -eq 0 ]
  [[ "$output" != *"inbox:"* ]] # the empty template has nothing open
  cat >"$CHARTROOM_HOME/inbox.md" <<'EOF'
# Inbox

## Waiting on the commander
- 2026-01-01 — merge the parser PR?
- 2026-01-02 — which region for staging?

## Approvals given in chat, not yet in a brief
- 2026-01-02 — ok to rotate the test key

## Notes
- a note is not an open item
EOF
  run cr status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no open tasks"* ]]
  [[ "$output" == *"inbox: 2 waiting on the commander, 1 approval not yet in a brief"* ]]
  [ "$(cr status --json | jq length)" -eq 0 ]
  new_task --backend codex >/dev/null
  run cr status
  [[ "${lines[0]}" == ID* ]]
  [[ "${lines[${#lines[@]}-1]}" == "inbox: 2 waiting"* ]]
  [ "$(cr status --json | jq 'type')" = '"array"' ]
}

@test "home resolution: env, legacy CAP_HOME, legacy ~/.captain, default" {
  unset CHARTROOM_HOME
  run cr doctor --json
  [ "$(jq -r .home <<<"$output")" = "$HOME/.chartroom" ]
  mkdir -p "$HOME/.captain"
  run cr doctor --json
  [ "$(jq -r .home <<<"$output")" = "$HOME/.captain" ]
  [ "$(jq -r .home_source <<<"$output")" = "legacy ~/.captain" ]
  mkdir -p "$HOME/.chartroom"
  run cr doctor --json
  [ "$(jq -r .home <<<"$output")" = "$HOME/.chartroom" ]
  CAP_HOME="$BATS_TEST_TMPDIR/old" run cr doctor --json
  [ "$(jq -r .home <<<"$output")" = "$BATS_TEST_TMPDIR/old" ]
  CHARTROOM_HOME="$BATS_TEST_TMPDIR/new" CAP_HOME="$BATS_TEST_TMPDIR/old" run cr doctor --json
  [ "$(jq -r .home <<<"$output")" = "$BATS_TEST_TMPDIR/new" ]
}

@test "config file is read, env wins" {
  printf 'CHARTROOM_WORKSPACE=from-file\nCHARTROOM_BACKEND_ORDER="command"\n' >"$CHARTROOM_CONFIG"
  run cr doctor --json
  [ "$(jq -r '.order|join(" ")' <<<"$output")" = "command" ]
  CHARTROOM_BACKEND_ORDER="headless:codex" run cr doctor --json
  [ "$(jq -r '.order|join(" ")' <<<"$output")" = "headless:codex" ]
}

@test "new: schema, aliases, validation" {
  id="$(new_task --backend codex)"
  [ "$(meta_of "$id" schema)" = 1 ]
  [ "$(meta_of "$id" backend)" = headless:codex ]
  [ "$(meta_of "$id" backend_source)" = explicit ]
  [ "$(meta_of "$id" branch)" = "chartroom/$id" ]
  id2="$(new_task)"
  [ "$(meta_of "$id2" backend_source)" = auto ]
  run cr new --project "$PROJECT" --title x --backend warp:claude
  [ "$status" -ne 0 ]; [[ "$output" == *"unknown backend"* ]]
  run cr new --project "$PROJECT" --title x --backend command
  [ "$status" -ne 0 ]; [[ "$output" == *"--command"* ]]
  run cr new --project "$PROJECT" --title x --kind nope
  [ "$status" -ne 0 ]
}

@test "dispatch refuses a brief without the commander's intent" {
  out="$(cr new --project "$PROJECT" --title x --backend command --command "$STUB {id}")"
  id="$(sed -n 's/^id=//p' <<<"$out")"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no commander's intent"* ]]
}

@test "command backend end to end: dispatch, watch --once, status, close keeps branch" {
  id="$(STUB_COMMIT=1 new_task --backend command --command "STUB_COMMIT=1 $STUB {id}")"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"steering: between-runs"* ]]
  run cr watch --once --timeout 15
  [ "$status" -eq 0 ]
  [[ "$output" == *"[$id]"*"done: stub finished"* ]]
  wait_event "$id" ' exited: command ended \(exit 0\)'
  run cr status --json
  [ "$(jq -r '.[0].state' <<<"$output")" = done ]
  [ "$(jq -r '.[0].live' <<<"$output")" = stopped ]
  wt="$(meta_of "$id" worktree)"
  [ "$(git -C "$wt" log --oneline -1 --format=%s)" = "feat: stub change" ]
  run cr close "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch chartroom/$id kept (1 commit(s) ahead"* ]]
  [ ! -d "$wt" ]
  run cr status
  [[ "$output" == "no open tasks" ]]
}

@test "decision, then steer between runs re-runs with the answer" {
  id="$(new_task --backend command --command "STUB_MODE=decision $STUB {id}")"
  cr dispatch "$id" >/dev/null
  run cr watch --once --timeout 15
  [[ "$output" == *"decision: pick A or B"* ]]
  wait_event "$id" ' exited: '
  [ "$(cr status --json | jq -r '.[0].state')" = decision ]
  run cr steer "$id" "go with A"
  [ "$status" -eq 0 ]
  run cr watch --once --timeout 15
  [[ "$output" == *"done: finished after steer: go with A"* ]]
  grep -q "steer: go with A" "$CHARTROOM_HOME/tasks/$id/report.md"
}

@test "steer refuses a mid-run command worker; --inbox appends" {
  id="$(new_task --backend command --command "STUB_SLEEP=5 $STUB {id}")"
  cr dispatch "$id" >/dev/null
  run cr steer "$id" "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mid-run"* ]]
  run cr steer "$id" --inbox "hello there"
  [ "$status" -eq 0 ]
  grep -q "hello there" "$CHARTROOM_HOME/tasks/$id/inbox.md"
  cr stop "$id"
}

@test "an exit after the worker reported is not a wake; a silent exit is" {
  id="$(new_task --backend command --command "STUB_MODE=silent $STUB {id}")"
  cr dispatch "$id" >/dev/null
  run cr watch --once --timeout 15
  [[ "$output" == *"exited: command ended (exit 0)"* ]]
  [ "$(cr status --json | jq -r '.[0].state')" = stopped-silent ]
}

@test "waiting: an exit right after waiting is not a wake; the status is waiting with its window" {
  id="$(new_task --backend command --command "STUB_MODE=waiting STUB_WAITING='CI on PR 12 until 2099-01-01T10:30Z' $STUB {id}")"
  cr dispatch "$id" >/dev/null
  wait_event "$id" ' exited: '
  run cr watch --once --timeout 3
  [ "$status" -eq 124 ]
  [[ "$output" != *"exited"* ]]
  run cr status --json
  [ "$(jq -c '.[0] | [.state,.waiting_on,.waiting_until]' <<<"$output")" = '["waiting","CI on PR 12 until 2099-01-01T10:30Z","2099-01-01T10:30:00Z"]' ]
  [ "$(jq -r '.[0].waiting_since' <<<"$output")" != null ]
  # a later report closes the wait
  cr event "$id" progress "CI green, merging"
  [ "$(cr status --json | jq -c '.[0] | [.state,.waiting_on]')" = '["stopped-silent",null]' ]
}

@test "waiting: the window running out wakes once (waiting overdue), and is recorded" {
  id="$(new_task --backend command --command "STUB_MODE=waiting STUB_WAITING='review from the docs team' $STUB {id}")"
  cr dispatch "$id" >/dev/null
  wait_event "$id" ' exited: '
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # no until-time: the window is CHARTROOM_WAITING_MAX_MINUTES past the event
  export CHARTROOM_WAITING_MAX_MINUTES=0
  [ "$(cr status --json | jq -r '.[0].state')" = waiting-overdue ]
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"[$id] waiting overdue: review from the docs team (since "* ]]
  grep -q ' note: waiting overdue: review from the docs team' "$CHARTROOM_HOME/tasks/$id/events.log"
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  [[ "$output" != *"overdue"* ]]
  # an until-time is honoured plus CHARTROOM_WAITING_GRACE_MINUTES
  unset CHARTROOM_WAITING_MAX_MINUTES
  cr event "$id" waiting "a timer until $(jq -rn 'now - 600 | floor | todate')"
  [ "$(cr status --json | jq -r '.[0].state')" = waiting ]
  [ "$(CHARTROOM_WAITING_GRACE_MINUTES=5 cr status --json | jq -r '.[0].state')" = waiting-overdue ]
}

@test "watch --once times out with 124 and keeps its cursor between calls" {
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  id="$(new_task --backend command --command "$STUB {id}")"
  # The event lands while nobody is watching; the next --once call must still see it.
  cr event "$id" decision "asked while nobody watched"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ] # a task newer than the cursor is read from its start
  [[ "$output" == *"decision: asked while nobody watched"* ]]
  [[ "$output" != *"created"* ]]
  cr event "$id" blocked "needs a token"
  sleep 1
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked: needs a token"* ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
}

@test "event validates kinds" {
  id="$(new_task --backend command --command "$STUB {id}")"
  run cr event "$id" bogus "x"
  [ "$status" -ne 0 ]
  run cr event "$id" progress "fine"
  [ "$status" -eq 0 ]
  run cr event "$id" waiting "CI on PR 3 until 2026-01-05T15:30:00Z"
  [ "$status" -eq 0 ]
  run cr event nope progress "x"
  [ "$status" -ne 0 ]
}

@test "hooks: a turn end without a report wakes; after a report it does not; prompts always wake" {
  id="$(new_task --backend command --command "$STUB {id}")"
  cr event "$id" note "dispatched via tmux:claude"
  run cr watch --once --timeout 1
  cr hook "$id" stop
  run cr watch --once --timeout 5
  [[ "$output" == *"agent: turn-ended (stopped its turn without reporting)"* ]]
  cr event "$id" done "finished"
  cr hook "$id" stop
  run cr watch --once --timeout 5
  [[ "$output" == *"done: finished"* ]]
  [[ "$output" != *"without reporting"* ]]
  echo '{"message":"Claude needs your permission to use Bash"}' | cr hook "$id" notification
  run cr watch --once --timeout 5
  [[ "$output" == *"awaiting-input: Claude needs your permission to use Bash"* ]]
  cr hook "$id" codex-notify '{"type":"agent-turn-complete","turn-id":"1"}'
  run cr watch --once --timeout 3
  [[ "$output" != *"turn-ended (stopped"* ]] # reported already (awaiting-input is not a report, but done was)
  # a turn ending right after `waiting` is not news; once the worker resumes, it is again
  cr event "$id" steered "carry on"
  cr event "$id" waiting "CI on PR 3"
  cr hook "$id" stop
  run cr watch --once --timeout 3
  [[ "$output" != *"without reporting"* ]]
  cr event "$id" progress "CI green"
  cr hook "$id" stop
  run cr watch --once --timeout 5
  [[ "$output" == *"turn-ended (stopped its turn without reporting)"* ]]
  # hooks never fail the agent, even for unknown tasks
  run cr hook no-such-task stop
  [ "$status" -eq 0 ]
}

@test "close refuses a dirty worktree (exit 2) and --discard removes it" {
  id="$(new_task --backend command --command "$STUB {id}")"
  wt="$(cr worktree "$id")"
  echo dirty >"$wt/dirty.txt"
  run cr close "$id"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to close"* ]]
  [ -d "$wt" ]
  run cr close "$id" --discard
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
  events "$id" | grep -q "discarded on commander's order"
}

@test "scout worktrees are detached; worktree_created is recorded" {
  id="$(new_task --backend command --command "$STUB {id}" --kind scout)"
  wt="$(cr worktree "$id")"
  [ -z "$(git -C "$wt" branch --show-current)" ]
  [ "$(meta_of "$id" worktree_created)" = 1 ]
  [ "$(cr worktree "$id")" = "$wt" ]
}

@test "project resolves by path, and by name under roots" {
  run cr project "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proj"*"none"*"main"* ]]
  run cr project proj
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHARTROOM_PROJECT_ROOTS is unset"* ]]
  CHARTROOM_PROJECT_ROOTS="$BATS_TEST_TMPDIR" run cr project proj
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJECT"* ]]
}

@test "init keeps a legacy captain.md instead of adding commander.md" {
  mkdir -p "$CHARTROOM_HOME"; echo "# old prefs" >"$CHARTROOM_HOME/captain.md"
  cr init >/dev/null
  [ ! -f "$CHARTROOM_HOME/commander.md" ]
  grep -q "old prefs" "$CHARTROOM_HOME/captain.md"
}

@test "dispatch accepts a legacy Captain's intent heading" {
  id="$(new_task --backend command --command "$STUB {id}")"
  sed -i.bak "s/## Commander's intent/## Captain's intent/" "$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
}

@test "the brief carries the protocol with the event helper path" {
  id="$(new_task --backend command --command "$STUB {id}")"
  b="$CHARTROOM_HOME/tasks/$id/brief.md"
  grep -q "CHARTROOM_HOME=$CHARTROOM_HOME $CHARTROOM event $id" "$b"
  grep -q "Do NOT push" "$b"
}

@test "dispatch returns at once even when its output is captured (worker detached)" {
  id="$(new_task --backend command --command "STUB_SLEEP=6 $STUB {id}")"
  s=$(date +%s)
  out="$(cr dispatch "$id")"
  [ $(( $(date +%s) - s )) -lt 3 ]
  [[ "$out" == *"command worker running"* ]]
  cr stop "$id" >/dev/null
}

# A bare task record (no project or dispatch needed): <id> [closed]
bare_task() {
  local d="$CHARTROOM_HOME/tasks/$1"; mkdir -p "$d"
  jq -n --arg id "$1" --arg c "${2:-}" '{schema:1,id:$id,title:("T " + $id),kind:"ship",backend:"subagent",project:"/srv/p",created:"2026-01-01T00:00:00Z"}
    + (if $c != "" then {closed:$c} else {} end)' >"$d/meta.json"
  : >"$d/events.log"
}
shorts() { cr status --all --json | jq -r 'map("\(.id)=\(.short_id)") | join(" ")'; }

@test "short ids: the 4-hex suffix; a shared suffix grows until unique; closed never shadow open" {
  cr init >/dev/null
  bare_task fix-login-21ba
  bare_task docs-7f3a
  bare_task custom
  [ "$(shorts)" = "custom=custom docs-7f3a=7f3a fix-login-21ba=21ba" ]
  # a second open task with the same suffix: both extend to the shortest unique suffix
  bare_task add-flag-21ba
  [ "$(shorts)" = "add-flag-21ba=g-21ba custom=custom docs-7f3a=7f3a fix-login-21ba=n-21ba" ]
  # a closed task does not change an open one's short id, and takes a longer one itself
  bare_task old-7f3a 2026-01-02T00:00:00Z
  [ "$(cr status --all --json | jq -r '.[] | select(.id == "docs-7f3a") | .short_id')" = 7f3a ]
  [ "$(cr status --all --json | jq -r '.[] | select(.id == "old-7f3a") | .short_id')" = d-7f3a ]
  # every short id is distinct
  [ "$(cr status --all --json | jq '[.[].short_id] | (unique | length) == length')" = true ]
  # status --json keeps every existing field and only adds short_id
  [ "$(cr status --json | jq -c '.[0] | keys')" = '["backend","branch","closed","created","dispatched","has_report","id","kind","last","last_at","live","project","short_id","state","title","updated","waiting_on","waiting_since","waiting_until"]' ]
}

@test "short ids: an id whose suffix would start with a dash grows past it" {
  cr init >/dev/null
  bare_task a-b-21ba
  bare_task c-b-21ba
  [ "$(shorts)" = "a-b-21ba=a-b-21ba c-b-21ba=c-b-21ba" ]
  bare_task q-21ba
  [ "$(shorts)" = "a-b-21ba=a-b-21ba c-b-21ba=c-b-21ba q-21ba=q-21ba" ]
}

@test "resolve: full id, short id, suffix; ambiguous and unknown fail" {
  cr init >/dev/null
  bare_task fix-login-21ba
  bare_task add-flag-21ba
  bare_task docs-7f3a
  bare_task old-7f3a 2026-01-02T00:00:00Z
  [ "$(cr resolve fix-login-21ba)" = fix-login-21ba ]
  [ "$(cr resolve n-21ba)" = fix-login-21ba ]
  [ "$(cr resolve 7f3a)" = docs-7f3a ]       # the open task wins over a closed one
  [ "$(cr resolve d-7f3a)" = old-7f3a ]
  [ "$(cr resolve ' [DOCS-7F3A] ')" = docs-7f3a ]
  [ "$(cr resolve login-21ba)" = fix-login-21ba ]   # a unique suffix still works
  run cr resolve 21ba
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambiguous id '21ba': add-flag-21ba fix-login-21ba"* ]]
  run cr resolve 9999
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown id '9999'"* ]]
  run cr resolve
  [ "$status" -ne 0 ]
  run cr resolve 7f3a --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '"\(.type) \(.id) \(.short_id) \(.state)"' <<<"$output")" = "task docs-7f3a 7f3a drafting" ]
}

@test "inbox ids: add and tag write stable ids; resolve finds items; ids survive edits" {
  cr init >/dev/null
  run cr inbox add "which region for staging?"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^i-[0-9a-f]{4}$ ]]
  local a="$output"
  grep -qx -- "- \[$a\] $(date +%F) — which region for staging?" "$CHARTROOM_HOME/inbox.md"
  ! grep -q -- '- (none)' <(sed -n '/^## Waiting/,/^## Approvals/p' "$CHARTROOM_HOME/inbox.md")
  local b; b="$(cr inbox add "merge the parser PR?")"
  [ "$a" != "$b" ]
  # a hand-written line gets an id from `inbox tag`; tagging again changes nothing
  perl -0pi -e 's/(## Approvals)/- 2026-01-03 — hand written\n\n$1/' "$CHARTROOM_HOME/inbox.md"
  run cr inbox tag
  [[ "$output" =~ ^tagged\ (i-[0-9a-f]{4}):\ 2026-01-03\ —\ hand\ written$ ]]
  local c="${BASH_REMATCH[1]}"
  cp "$CHARTROOM_HOME/inbox.md" "$BATS_TEST_TMPDIR/before"
  [ -z "$(cr inbox tag)" ]
  cmp "$CHARTROOM_HOME/inbox.md" "$BATS_TEST_TMPDIR/before"
  # the sections and their order survive; approvals and notes are never tagged
  [ "$(grep '^## ' "$CHARTROOM_HOME/inbox.md" | tr '\n' '|')" = "## Waiting on the commander|## Approvals given in chat, not yet in a brief|## Notes|" ]
  [ "$(grep -c '^- \[i-' "$CHARTROOM_HOME/inbox.md")" -eq 3 ]
  # removing an item and adding another leaves the others' ids alone
  sed -i.bak "/\[$a\]/d" "$CHARTROOM_HOME/inbox.md"
  cr inbox add "a newer question" >/dev/null
  [ "$(cr resolve "$b")" = "$b" ]
  [ "$(cr resolve "$c" --json | jq -r '"\(.type) \(.date) \(.text)"')" = "inbox 2026-01-03 hand written" ]
  [ "$(cr resolve "$b" --json | jq -r .text)" = "merge the parser PR?" ]
  run cr resolve "$a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown id '$a'"* ]]
  # the inbox line count is unaffected by the tags
  [[ "$(cr status)" == *"inbox: 3 waiting on the commander"* ]]
}

@test "inbox add: creates the Waiting section when the file has none" {
  cr init >/dev/null
  printf '# Inbox\n\n## Notes\n- n\n' >"$CHARTROOM_HOME/inbox.md"
  id="$(cr inbox add "first question")"
  [ "$(sed -n '/^## Waiting/,$p' "$CHARTROOM_HOME/inbox.md" | sed -n 2p)" = "- [$id] $(date +%F) — first question" ]
  grep -q '^- n$' "$CHARTROOM_HOME/inbox.md"
}
