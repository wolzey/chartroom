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
  for f in captain.md projects.md AGENTS.md CLAUDE.md; do [ -f "$CHARTROOM_HOME/$f" ]; done
  grep -q chartroom "$CHARTROOM_HOME/AGENTS.md"
  [[ "$output" == *"No project roots set"* ]]
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

@test "dispatch refuses a brief without the captain's intent" {
  out="$(cr new --project "$PROJECT" --title x --backend command --command "$STUB {id}")"
  id="$(sed -n 's/^id=//p' <<<"$out")"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no captain's intent"* ]]
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
  events "$id" | grep -q "discarded on captain's order"
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
