#!/usr/bin/env bats
# Joined tasks: an agent session chartroom did not launch runs `chartroom join` itself and
# is steered through a mailbox. The "session" here is the test shell (CLAUDE_PID=$$).

load test_helper
setup() {
  common_setup
  cr init >/dev/null
  export CLAUDECODE=1 CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=sess-1
  export CHARTROOM_JOIN_ACK_WAIT=3
}

# Run join from the project directory; prints its output.
join_here() { (cd "$PROJECT" && cr join "$@"); }
joined_id() { sed -n 's/^id=//p' <<<"$1"; }

@test "join records the running session in its own directory, no worktree, and never dispatches it" {
  run join_here --title "fix the login page"
  [ "$status" -eq 0 ]
  id="$(joined_id "$output")"
  [[ "$id" == fix-the-login-page-* ]]
  [[ "$output" == *"brief=$CHARTROOM_HOME/tasks/$id/brief.md"* ]]
  [[ "$output" == *"listen $id"* && "$output" == *"run_in_background"* ]]
  [[ "$output" == *"terminal: none recorded"* ]]
  [ "$(meta_of "$id" backend)" = joined:claude ]
  [ "$(meta_of "$id" worktree)" = "$(cd "$PROJECT" && pwd -P)" ]
  [ "$(meta_of "$id" branch)" = main ]
  [ "$(meta_of "$id" pid)" = "$$" ]
  [ "$(meta_of "$id" session_id)" = sess-1 ]
  [ -z "$(meta_of "$id" worktree_created)" ]
  [ ! -d "$CHARTROOM_HOME/worktrees" ] || [ -z "$(ls "$CHARTROOM_HOME/worktrees")" ]
  [ "$(git -C "$PROJECT" worktree list | wc -l)" -eq 1 ]
  grep -q 'note: dispatched via joined:claude' "$CHARTROOM_HOME/tasks/$id/events.log"
  grep -q "listen $id" "$CHARTROOM_HOME/tasks/$id/brief.md"
  grep -q "never removes or cleans this directory" "$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr status
  [[ "$output" == *"$id"*"working"*"joined:claude"* ]]
  run cr dispatch "$id"
  [ "$status" -ne 0 ]; [[ "$output" == *"never dispatched"* ]]
  run cr new --project "$PROJECT" --title x --backend joined:claude
  [ "$status" -ne 0 ]
}

@test "joining again from the same session reuses the task; another session gets its own" {
  id="$(joined_id "$(join_here --title one)")"
  run join_here --title two
  [ "$(joined_id "$output")" = "$id" ]
  [[ "$output" == *"already joined"* ]]
  [ "$(ls "$CHARTROOM_HOME/tasks" | wc -l)" -eq 1 ]
  grep -q 'note: re-joined' "$CHARTROOM_HOME/tasks/$id/events.log"
  CLAUDE_CODE_SESSION_ID=sess-2 run join_here --title three
  [ "$(joined_id "$output")" != "$id" ]
  [ "$(ls "$CHARTROOM_HOME/tasks" | wc -l)" -eq 2 ]
}

@test "join refuses a missing home and a session the XO launched" {
  CHARTROOM_HOME="$BATS_TEST_TMPDIR/nope" run join_here
  [ "$status" -ne 0 ]; [[ "$output" == *"no chartroom home at"* ]]
  export CHARTROOM_COMMAND="$STUB {id}"
  launched="$(new_task --backend command)"
  CHARTROOM_TASK="$launched" run join_here
  [ "$status" -ne 0 ]; [[ "$output" == *"already chartroom task $launched"* ]]
  run cr listen "$launched" --check
  [ "$status" -ne 0 ]; [[ "$output" == *"not joined"* ]]
}

@test "a tmux pane is recorded only when the session really runs in it" {
  use_fake tmux
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR/panes"; echo %1 >"$FAKE_TMUX_DIR/panes/1"
  export TMUX="$BATS_TEST_TMPDIR/sock,1,0" TMUX_PANE=%1
  FAKE_TMUX_PANE_PID=999999 run join_here --title elsewhere
  [[ "$output" == *"terminal: none recorded"* ]]
  [ -z "$(meta_of "$(joined_id "$output")" tmux_pane)" ]
  CLAUDE_CODE_SESSION_ID=sess-2 FAKE_TMUX_PANE_PID=$$ run join_here --title here
  id="$(joined_id "$output")"
  [[ "$output" == *"terminal: tmux pane %1"* ]]
  [ "$(meta_of "$id" tmux_pane)" = %1 ]
  [ "$(meta_of "$id" tmux_socket)" = "$BATS_TEST_TMPDIR/sock" ]
  run cr peek "$id"
  [[ "$output" == *"== pane (recent)"* ]]
  run cr stop "$id"
  [ "$status" -eq 0 ]
  grep -q -- "send-keys -t %1 Escape" "$FAKE_TMUX_DIR/calls.log"
}

@test "steer: delivered once the armed listener reads it; queued, not yet read, without one" {
  id="$(joined_id "$(join_here --title mail)")"
  cr listen "$id" >"$BATS_TEST_TMPDIR/listen.out" &
  lp=$!
  for _ in $(seq 1 20); do [ -f "$CHARTROOM_HOME/tasks/$id/mail/listener.pid" ] && break; sleep 0.1; done
  [ "$(jq -r .live <<<"$(cr status --json | jq '.[0]')")" = listening ]
  run cr steer "$id" "please rebase"
  [ "$status" -eq 0 ]
  [[ "$output" == "delivered (message #1 read by the agent)" ]]
  wait "$lp"
  grep -q '^please rebase$' "$BATS_TEST_TMPDIR/listen.out"
  grep -q "re-arm: chartroom listen $id" "$BATS_TEST_TMPDIR/listen.out"
  wait_event "$id" 'steered: please rebase'
  wait_event "$id" 'agent: prompt-received mail #1'
  [ ! -f "$CHARTROOM_HOME/tasks/$id/mail/listener.pid" ]
  # No listener: the message waits, and steer says so.
  run cr steer "$id" "second
with two lines"
  [[ "$output" == "queued, not yet read (message #2): no listener is armed"* ]]
  run cr peek "$id"
  [[ "$output" == *"2 message(s), 1 unread; listener not armed"* ]]
  run cr listen "$id" --check
  [[ "$output" == *"== message #2 from the XO"*"second"*"with two lines"* ]]
  run cr listen "$id" --check
  [ "$output" = "no new messages" ]
  run cr listen "$id" --timeout 1
  [ "$status" -eq 124 ]
}

@test "the join skill's hooks find the task by session id; idle prompts are not news" {
  id="$(joined_id "$(join_here --title hooked)")"
  reg="$XDG_STATE_HOME/chartroom/sessions/sess-1"
  [ "$(cut -f1 "$reg")" = "$CHARTROOM_HOME" ]
  [ "$(cut -f2 "$reg")" = "$id" ]
  [ "$(cut -f3 "$reg")" = "$CHARTROOM" ]
  # The hook runs with no CHARTROOM_HOME of its own: the registry supplies it.
  echo '{"session_id":"sess-1"}' | CHARTROOM_HOME= cr hook --session stop
  echo '{"session_id":"sess-1","notification_type":"idle_prompt","message":"Claude is waiting"}' | cr hook --session notification
  echo '{"session_id":"sess-1","notification_type":"permission_prompt","message":"Allow Bash?"}' | cr hook --session notification
  echo '{"session_id":"other"}' | cr hook --session stop
  run events "$id"
  [[ "$output" == *"agent: turn-ended"* ]]
  [[ "$output" == *"agent: awaiting-input: Allow Bash?"* ]]
  [[ "$output" != *"Claude is waiting"* ]]
  # The skill's own hook command, run the way Claude Code runs it.
  cmd="$(sed -n "s/^ *command: '\(.*hook --session prompt-submit.*\)'$/\1/p" "$REPO_ROOT/skills/join/SKILL.md")"
  [ -n "$cmd" ]
  echo '{"session_id":"sess-1"}' | sh -c "$cmd"
  wait_event "$id" 'agent: prompt-received$'
}

@test "watch: a joined turn ending with its listener armed is at rest; without one it wakes" {
  id="$(joined_id "$(join_here --title resting)")"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  # Run the binary itself in the background, so $! is the listener (not a subshell).
  "$CHARTROOM" listen "$id" >/dev/null &
  lp=$!
  for _ in $(seq 1 20); do [ -f "$CHARTROOM_HOME/tasks/$id/mail/listener.pid" ] && break; sleep 0.1; done
  echo '{"session_id":"sess-1"}' | cr hook --session stop
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  [[ "$output" != *"stopped its turn"* ]]
  kill "$lp"; wait "$lp" 2>/dev/null || true
  [ ! -f "$CHARTROOM_HOME/tasks/$id/mail/listener.pid" ]
  echo '{"session_id":"sess-1"}' | cr hook --session stop
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"[$id]"*"agent: turn-ended (stopped its turn without reporting)"* ]]
}

@test "close marks a joined task closed and never touches its directory" {
  id="$(joined_id "$(join_here --title closing)")"
  echo wip >"$PROJECT/wip.txt"
  cr listen "$id" >"$BATS_TEST_TMPDIR/listen.out" &
  lp=$!
  run cr close "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left $(cd "$PROJECT" && pwd -P) as it is"*"uncommitted changes"* ]]
  [ -f "$PROJECT/wip.txt" ] && [ -f "$PROJECT/README" ]
  [ "$(meta_of "$id" closed)" != "" ]
  [ ! -f "$XDG_STATE_HOME/chartroom/sessions/sess-1" ]
  wait "$lp"
  grep -q "task $id is closed; stop listening" "$BATS_TEST_TMPDIR/listen.out"
  # A new join from the same session starts a fresh task.
  run join_here --title again
  [ "$(joined_id "$output")" != "$id" ]
}

@test "watch: the joined agent's process ending is recorded once and wakes the XO" {
  id="$(joined_id "$(join_here --title vanishing)")"
  sleep 30 & dead=$!; kill "$dead"; wait "$dead" 2>/dev/null || true
  jq --arg p "$dead" '.pid=$p' "$CHARTROOM_HOME/tasks/$id/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id/meta.json"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"[$id]"*"exited: joined agent session ended (pid $dead gone)"* ]]
  [ "$(grep -c ' exited: ' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 1 ]
  run cr status --json
  [ "$(jq -r '.[0].live' <<<"$output")" = stopped ]
  [ "$(jq -r '.[0].state' <<<"$output")" = stopped-silent ]
}

@test "doctor lists joined backends with their steering, as not dispatchable" {
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="joined:claude").steering' <<<"$output")" = "mailbox (wakes an idle session)" ]
  [ "$(jq -r '.backends[]|select(.backend=="joined:codex").steering' <<<"$output")" = "mailbox (read between steps)" ]
  [ "$(jq -r '.backends[]|select(.backend=="joined:codex").available' <<<"$output")" = false ]
}
