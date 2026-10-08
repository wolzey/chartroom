#!/usr/bin/env bats
# Backend selection, fallback and each runner's argument building, driven by fake
# binaries (test/fakes). Nothing real is launched.

load test_helper
setup() { common_setup; }

@test "doctor exits 0 with only bash, jq and git" {
  run cr doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"herdr:claude"*"herdr not on PATH"* ]]
  [[ "$output" == *"headless:codex"*"codex not on PATH"* ]]
  [[ "$output" == *"subagent"*"only inside Claude Code"* ]]
  run cr doctor --json
  [ "$(jq -r .auto <<<"$output")" = null ]
  # Git Bash: herdr stays off unless opted in (test_helper opts in for the other tests)
  case "${OSTYPE:-}" in msys*|cygwin*)
    CHARTROOM_HERDR_ANY_OS="" run cr doctor --json
    [ "$(jq -r '.backends[]|select(.backend=="herdr:claude").reason' <<<"$output")" = "herdr on Windows is unverified (CHARTROOM_HERDR_ANY_OS=1 to try it)" ] ;;
  esac
}

@test "doctor: CI disables session runners; harness=claude enables subagent" {
  use_fake tmux claude
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="tmux:claude").available' <<<"$output")" = true ]
  CI=true run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="tmux:claude").reason' <<<"$output")" = "CI=true: session runners disabled" ]
  [ "$(jq -r '.backends[]|select(.backend=="headless:claude").available' <<<"$output")" = true ]
  CHARTROOM_HARNESS=claude run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="subagent").available' <<<"$output")" = true ]
}

@test "doctor: old tmux and an unreachable herdr are reported, not fatal" {
  use_fake tmux herdr claude
  FAKE_TMUX_VERSION=2.9 run cr doctor --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.backends[]|select(.backend=="tmux:claude").reason' <<<"$output")" == "tmux >= 3.0 required"* ]]
  [[ "$(jq -r '.backends[]|select(.backend=="herdr:claude").reason' <<<"$output")" == "herdr server not reachable"* ]]
}

@test "auto selection falls back down the order and records a note" {
  export CHARTROOM_BACKEND_ORDER="herdr:claude tmux:claude command"
  id="$(new_task --command "$STUB {id}")"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  # (tmux may exist on a CI image; then tmux:claude is skipped because claude is missing)
  [[ "$output" == *"backend fallback: herdr:claude unavailable (herdr not on PATH) tmux:claude unavailable ("*"); using command (steering: between-runs)"* ]]
  [ "$(meta_of "$id" backend)" = command ]
  events "$id" | grep -q "note: backend fallback"
}

@test "an explicit backend that is unavailable fails loudly with the next viable option" {
  export CHARTROOM_BACKEND_ORDER="herdr:claude command"
  export CHARTROOM_COMMAND="$STUB {id}"
  id="$(new_task --backend herdr:claude)"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backend herdr:claude was chosen explicitly but is unavailable: herdr not on PATH (next viable: command"* ]]
  [ -z "$(meta_of "$id" dispatched)" ]
}

@test "no backend at all: a clear error pointing at doctor" {
  export CHARTROOM_BACKEND_ORDER="herdr:claude tmux:claude headless:codex"
  id="$(new_task)"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backend available"*"chartroom doctor"* ]]
}

@test "headless:codex: argv, sandbox per kind, thread id, steer only between runs" {
  use_fake codex
  export FAKE_CODEX_SLEEP=3
  id="$(new_task --backend headless:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"thread th-fake-1"* ]]
  [ "$(meta_of "$id" thread_id)" = th-fake-1 ]
  grep -q -- "exec --json -C $(meta_of "$id" worktree) -s danger-full-access -o $CHARTROOM_HOME/tasks/$id/final.md Read the brief" "$FAKE_LOG"
  run cr steer "$id" "more"
  [ "$status" -ne 0 ]; [[ "$output" == *"mid-run"* ]]
  wait_event "$id" ' exited: codex process ended \(exit 0\)'
  FAKE_CODEX_SLEEP=0 run cr steer "$id" "more please"
  [ "$status" -eq 0 ]
  wait_event "$id" 'steered: more please'
  sleep 1
  grep -q -- "resume th-fake-1 more please" "$FAKE_LOG"
  run cr peek "$id"
  [[ "$output" == *"msg: fake codex ran"* ]]
}

@test "headless:codex scout gets workspace-write with the task record added" {
  use_fake codex
  id="$(new_task --backend codex --kind scout)"
  cr dispatch "$id" >/dev/null
  grep -q -- "-s workspace-write -c sandbox_workspace_write.network_access=true --add-dir $CHARTROOM_HOME/tasks/$id" "$FAKE_LOG"
}

@test "headless:claude: pre-assigned session, live steer over the FIFO, resume after exit" {
  case "${OSTYPE:-}" in msys*|cygwin*) skip "Git Bash steers headless claude between runs (test/windows.bats)" ;; esac
  use_fake claude
  export FAKE_TURN=8
  id="$(new_task --backend headless:claude)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"steering: live"* ]]
  sid="$(meta_of "$id" session_id)"
  [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]
  grep -q -- "-p --input-format stream-json --output-format stream-json --verbose --replay-user-messages --permission-mode acceptEdits --add-dir $CHARTROOM_HOME/tasks/$id --allowedTools Bash" "$FAKE_LOG"
  grep -q -- "--session-id $sid" "$FAKE_LOG"
  sleep 1
  run cr steer "$id" "live note"
  [ "$status" -eq 0 ]
  [[ "$output" == "delivered (live)" ]]
  wait_event "$id" ' exited: claude process ended' 30
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/final.md")" = "fake result" ]
  FAKE_TURN=0 run cr steer "$id" "after exit"
  [ "$status" -eq 0 ]
  [[ "$output" == "delivered (resumed session $sid)" ]]
  grep -q -- "--resume $sid" "$FAKE_LOG"
  run cr peek "$id"
  [[ "$output" == *"user: live note"* ]]
}

@test "headless:claude that ignores stdin EOF is ended by chartroom after its final result" {
  use_fake claude
  export FAKE_TURN=0 FAKE_NO_EXIT=1
  id="$(new_task --backend headless:claude)"
  cr dispatch "$id" >/dev/null
  wait_event "$id" ' exited: claude process ended \(exit [0-9]+, ended by chartroom after its final result\)' 20
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/final.md")" = "fake result" ]
}

@test "tmux:claude: window per task, hooks settings, trust left alone without one, confirmed delivery" {
  use_fake tmux claude
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"
  id="$(new_task --backend tmux:claude)"
  export FAKE_TMUX_TASK="$id"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" tmux_pane)" = "%1" ]
  grep -q "new-session -d -s chartroom-crew -n $id -c $(meta_of "$id" worktree)" "$FAKE_TMUX_DIR/calls.log"
  grep -q "pipe-pane -o -t %1 cat >> $CHARTROOM_HOME/tasks/$id/pane.log" "$FAKE_TMUX_DIR/calls.log"
  grep -q -- "send-keys -t %1 -l -- Read the brief at" "$FAKE_TMUX_DIR/calls.log"
  grep -q -- "--settings $CHARTROOM_HOME/tasks/$id/claude-settings.json" "$CHARTROOM_HOME/tasks/$id/launch.sh"
  jq -e '.hooks.Stop[0].hooks[0].command | test("hook '"$id"' stop$")' "$CHARTROOM_HOME/tasks/$id/claude-settings.json"
  events "$id" | grep -q "agent: prompt-received"
  [ "$(cr status --json | jq -r '.[0].live')" = working ]
  cr hook "$id" stop
  [ "$(cr status --json | jq -r '.[0].state')" = stopped-silent ]
  run cr steer "$id" "keep going"
  [ "$status" -eq 0 ]
  [ "$(cr status --json | jq -r '.[0].live')" = working ]
  # a second task reuses the session with a new window
  id2="$(new_task --backend tmux:claude)"
  FAKE_TMUX_TASK="$id2" cr dispatch "$id2" >/dev/null
  grep -q "new-window -d -t =chartroom-crew: -n $id2" "$FAKE_TMUX_DIR/calls.log"
  run cr close "$id"
  [ "$status" -eq 0 ]
  grep -q "kill-pane -t %1" "$FAKE_TMUX_DIR/calls.log"
}

@test "tmux:claude steer: delivered only when the hook's prompt matches the full text" {
  use_fake tmux claude
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"
  id="$(new_task --backend tmux:claude)"
  export FAKE_TMUX_TASK="$id"
  cr dispatch "$id" >/dev/null
  # the brief's prompt was confirmed by its signature
  sig="$(printf '%s' "Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md and follow it exactly. Your task id is $id." | (source "$REPO_ROOT/lib/core.sh"; text_sig))"
  events "$id" | grep -q "agent: prompt-received sig=$sig len="
  # a full match
  run cr steer "$id" "rebase on main, then rerun the tests"
  [ "$status" -eq 0 ]
  [ "$output" = "delivered (the agent received the full text)" ]
  # a fragment once: logged, input cleared, retyped, then confirmed
  FAKE_TMUX_DROP=5 run cr steer "$id" "use the staging database for this run"
  [ "$status" -eq 0 ]
  [ "$output" = "delivered (the agent received the full text)" ]
  events "$id" | grep -q "note: delivery mismatch: the agent received other text (sig=[0-9a-f]* len=32; expected sig=[0-9a-f]* len=37)"
  grep -q -- "send-keys -t %1 C-u" "$FAKE_TMUX_DIR/calls.log"
  # a prompt the session makes itself, arriving first, is not a mismatch and causes no retype
  : >"$FAKE_TMUX_DIR/calls.log"
  FAKE_TMUX_NOISE=1 run cr steer "$id" "notify-proof message"
  [ "$status" -eq 0 ]
  [ "$output" = "delivered (the agent received the full text)" ]
  [ "$(grep -c -- '-l -- notify-proof message' "$FAKE_TMUX_DIR/calls.log")" -eq 1 ]
  [ "$(events "$id" | grep -c 'delivery mismatch')" -eq 1 ]
  # fragments every time: it fails loudly and never says delivered
  rm -f "$FAKE_TMUX_DIR/drops"
  FAKE_TMUX_DROP=3 FAKE_TMUX_DROP_TIMES=99 run cr steer "$id" "ship it after the review"
  [ "$status" -ne 0 ]
  [[ "$output" != *delivered* ]]
  [[ "$output" == *"received only part of it"* ]]
  [ "$(events "$id" | grep -c 'delivery mismatch')" -ge 4 ]
}

@test "tmux:claude steer: a long or multi-line message goes via a file and a short pointer" {
  use_fake tmux claude
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"
  id="$(new_task --backend tmux:claude)"
  export FAKE_TMUX_TASK="$id"
  cr dispatch "$id" >/dev/null
  long="$(printf 'step %s; ' $(seq 1 80))"
  run cr steer "$id" "$long"
  [ "$status" -eq 0 ]
  [[ "$output" == "delivered (the agent received the full one-line pointer; the message is in $CHARTROOM_HOME/tasks/$id/messages/)" ]]
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/messages/1.md")" = "$long" ]
  grep -q -- "-l -- Message from the XO (${#long} characters, in a file so nothing is cut): read $CHARTROOM_HOME/tasks/$id/messages/1.md and act on it." "$FAKE_TMUX_DIR/calls.log"
  events "$id" | grep -qF "steered: $long"
  run cr steer "$id" "two
lines"
  [ "$status" -eq 0 ]
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/messages/2.md")" = $'two\nlines' ]
  # the event log stays one line per event
  events "$id" | grep -q "steered: two lines$"
}

@test "tmux: a trust dialog is answered only for chartroom's own worktree" {
  use_fake tmux claude
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  printf ' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n' >"$FAKE_TMUX_DIR/screen"
  id="$(new_task --backend tmux:claude)"
  export FAKE_TMUX_TASK="$id"
  # the fake screen never changes, so delivery cannot be confirmed by the screen; the hook confirms it
  run cr dispatch "$id"
  grep -q "send-keys -t %1 Down" "$FAKE_TMUX_DIR/calls.log"
  events "$id" | grep -q "note: accepted workspace trust for its own worktree"
  # a task whose worktree chartroom did not create: no keys, a wake instead
  id2="$(new_task --backend tmux:claude)"
  cr worktree "$id2" >/dev/null
  jq '.worktree_created="0"' "$CHARTROOM_HOME/tasks/$id2/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id2/meta.json"
  : >"$FAKE_TMUX_DIR/calls.log"
  FAKE_TMUX_TASK="$id2" run cr dispatch "$id2"
  ! grep -q "send-keys -t %2 Down" "$FAKE_TMUX_DIR/calls.log"
  events "$id2" | grep -q "agent: awaiting-input: trust dialog for a folder chartroom did not create"
}

@test "trust answer keys per agent" {
  source "$REPO_ROOT/lib/core.sh"; source "$REPO_ROOT/lib/agents.sh"
  [ "$(trust_answer_keys claude $' ❯ No, exit\n   Yes, I trust this folder')" = "down enter" ]
  [ "$(trust_answer_keys claude $'   No, exit\n ❯ Yes, I trust this folder')" = "enter" ]
  [ "$(trust_answer_keys codex $'Trust this folder?\n› 1. Trust and continue\n  2. Quit')" = "enter" ]
  [ -z "$(trust_answer_keys codex $'Trust this folder?\n  1. Trust and continue\n› 2. Quit')" ]
}

@test "tmux:codex uses notify for turn ends and the codex sandbox flags" {
  use_fake tmux codex
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  echo "Working (3s • esc to interrupt)" >"$FAKE_TMUX_DIR/screen"
  id="$(new_task --backend tmux:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  l="$CHARTROOM_HOME/tasks/$id/launch.sh"
  grep -q -- "check_for_update_on_startup=false -s danger-full-access" "$l"
  eval "args=( $(sed -n 4p "$l") )"
  printf '%s\n' "${args[@]}" | grep -qxF "notify=[\"$CHARTROOM\",\"hook\",\"$id\",\"codex-notify\"]"
}

@test "cmux:claude (stub cmux): workspace once, surface per task, keys forced, close" {
  use_fake cmux claude
  export CHARTROOM_CMUX_ANY_OS=1 FAKE_CMUX_DIR="$BATS_TEST_TMPDIR/cmux"
  id="$(new_task --backend cmux:claude)"
  export FAKE_CMUX_TASK="$id"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmux claude worker running"* ]]
  [ "$(meta_of "$id" cmux_workspace)" = ws-1 ]
  [ "$(meta_of "$id" cmux_surface)" = sf-1 ]
  grep -q -- "--json --id-format uuids workspace create --name chartroom-crew --cwd $(meta_of "$id" worktree) --command bash $CHARTROOM_HOME/tasks/$id/launch.sh" "$FAKE_CMUX_DIR/calls.log"
  grep -q -- "send --workspace ws-1 --surface sf-1 -- Read the brief at" "$FAKE_CMUX_DIR/calls.log"
  grep -q -- "send-key --force --workspace ws-1 --surface sf-1 enter" "$FAKE_CMUX_DIR/calls.log"
  events "$id" | grep -q "agent: prompt-received"
  id2="$(new_task --backend cmux:claude)"
  FAKE_CMUX_TASK="$id2" cr dispatch "$id2" >/dev/null
  grep -q -- "new-surface --workspace ws-1 --working-directory $(meta_of "$id2" worktree)" "$FAKE_CMUX_DIR/calls.log"
  [ "$(meta_of "$id2" cmux_surface)" = sf-2 ]
  run cr steer "$id" "next"
  [ "$status" -eq 0 ]
  run cr close "$id"
  [ "$status" -eq 0 ]
  grep -q -- "close-surface --workspace ws-1 --surface sf-1 --force" "$FAKE_CMUX_DIR/calls.log"
  [ "$(cr status --json | jq -r --arg i "$id" 'map(select(.id==$i))|length')" = 0 ]
}

@test "cmux probe: macOS only, app must answer ping" {
  use_fake cmux claude
  export FAKE_CMUX_DIR="$BATS_TEST_TMPDIR/cmux"
  if [[ "$(uname -s)" != Darwin ]]; then
    run cr doctor --json
    [ "$(jq -r '.backends[]|select(.backend=="cmux:claude").reason' <<<"$output")" = "cmux is macOS-only" ]
  fi
  export CHARTROOM_CMUX_ANY_OS=1
  FAKE_CMUX_DOWN=1 run cr doctor --json
  [[ "$(jq -r '.backends[]|select(.backend=="cmux:claude").reason' <<<"$output")" == "cmux socket refused (mode cmuxOnly)"* ]]
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="cmux:claude").available' <<<"$output")" = true ]
}

@test "default order is herdr, cmux, tmux, headless, command" {
  run cr doctor --json
  [ "$(jq -r '.order|join(" ")' <<<"$output")" = "herdr:claude cmux:claude tmux:claude headless:codex headless:claude command" ]
}

@test "legacy backend names still work on old records" {
  use_fake codex
  id="$(new_task --backend codex)"
  jq '.backend="codex" | del(.backend_source)' "$CHARTROOM_HOME/tasks/$id/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id/meta.json"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" backend)" = headless:codex ]
}

@test "subagent prints the Agent call and only works for harness=claude" {
  id="$(new_task --backend subagent --kind scout)"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  CHARTROOM_HARNESS=claude run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_in_background: true"* ]]
  [ "$(cr status --json | jq -r '.[0].live')" = in-session ]
}

@test "herdr claude workers get only the prompt hook; tmux/cmux get all three" {
  use_fake claude
  id="$(new_task --backend herdr:claude)"
  run bash -c "source '$REPO_ROOT/lib/core.sh'; source '$REPO_ROOT/lib/agents.sh'; CR_BIN='$CHARTROOM'; load_config; interactive_argv '$id' claude prompt"
  [[ "$output" == *"--settings"* ]]
  [ "$(jq -c '.hooks|keys' "$CHARTROOM_HOME/tasks/$id/claude-settings.json")" = '["UserPromptSubmit"]' ]
  run bash -c "source '$REPO_ROOT/lib/core.sh'; source '$REPO_ROOT/lib/agents.sh'; CR_BIN='$CHARTROOM'; load_config; interactive_argv '$id' claude 1"
  [ "$(jq -c '.hooks|keys' "$CHARTROOM_HOME/tasks/$id/claude-settings.json")" = '["Notification","Stop","UserPromptSubmit"]' ]
}
