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

@test "auto selection never falls back to headless or commands" {
  export CHARTROOM_BACKEND_ORDER="herdr:claude tmux:claude command"
  id="$(new_task --command "$STUB {id}")"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"automatic work needs a signed-in agent in hc or herdr"* ]]
  [ -z "$(meta_of "$id" dispatched)" ]
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

@test "a home's default Codex and agy model goes to a task that names none; the task's own wins; Claude's is untouched" {
  use_fake codex claude
  mkdir -p "$CHARTROOM_HOME"
  printf 'CHARTROOM_CODEX_MODEL=gpt-6-astra\nCHARTROOM_AGY_MODEL=gemini-fake-high\n' >"$CHARTROOM_HOME/config"
  id="$(new_task --backend headless:codex)"
  cr dispatch "$id" >/dev/null
  wait_event "$id" ' exited: codex process ended'
  grep -q -- "exec --json -C $(meta_of "$id" worktree) -s danger-full-access -m gpt-6-astra " "$FAKE_LOG"
  : >"$FAKE_LOG"
  id2="$(new_task --backend headless:codex --model gpt-6-sol)"
  cr dispatch "$id2" >/dev/null
  wait_event "$id2" ' exited: codex process ended'
  grep -q -- " -m gpt-6-sol " "$FAKE_LOG"
  refute() { if "$@"; then return 1; fi; }
  refute grep -q -- "gpt-6-astra" "$FAKE_LOG"
  # the argv of an interactive Codex and agy worker, and of a Claude one (no default of chartroom's)
  source_cr() { CHARTROOM_HOME="$CHARTROOM_HOME" bash -c 'source "$1/lib/core.sh"; source "$1/lib/homes.sh"; source "$1/lib/agents.sh"; load_config; shift; "$@"' _ "$REPO_ROOT" "$@"; }
  id3="$(new_task --backend tmux:codex)"; id4="$(new_task --backend tmux:claude)"
  [ "$(source_cr codex_model_args "$id3" | paste -sd' ' -)" = "-m gpt-6-astra" ]
  [ "$(source_cr task_model "$id4" claude)" = "" ]
  [ "$(source_cr task_model "$id" agy)" = "gemini-fake-high" ]
  run cr doctor
  [ "$status" -eq 0 ]
}

@test "a device's guest Claude worker gets its task folder in its settings file, not by --add-dir (no dialog)" {
  use_fake tmux claude
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  id="$(new_task --backend tmux:claude)"
  export FAKE_TMUX_TASK="$id"
  CHARTROOM_GUEST=1 cr dispatch "$id" >/dev/null 2>&1 || true
  launcher="$(ls "$CHARTROOM_HOME/tasks/$id"/*launch* 2>/dev/null | head -1)"
  [ -n "$launcher" ]
  ! grep -q -- '--add-dir' "$launcher"
  grep -q -- "--settings $CHARTROOM_HOME/tasks/$id/claude-settings.json" "$launcher"
  jq -e --arg d "$CHARTROOM_HOME/tasks/$id" '.permissions.additionalDirectories == [$d] and (.hooks.PreToolUse | length) == 1' "$CHARTROOM_HOME/tasks/$id/claude-settings.json"
  # a worker on this machine keeps --add-dir (sweep knows its session by it)
  id2="$(new_task --backend tmux:claude)"
  FAKE_TMUX_TASK="$id2" cr dispatch "$id2" >/dev/null 2>&1 || true
  grep -q -- "--add-dir $CHARTROOM_HOME/tasks/$id2" "$(ls "$CHARTROOM_HOME/tasks/$id2"/*launch* | head -1)"
  jq -e '.permissions == null' "$CHARTROOM_HOME/tasks/$id2/claude-settings.json"
}

@test "headless:codex scout gets workspace-write with the task record added" {
  use_fake codex
  id="$(new_task --backend codex --kind scout)"
  cr dispatch "$id" >/dev/null
  grep -q -- "-s workspace-write -c sandbox_workspace_write.network_access=true --add-dir $CHARTROOM_HOME/tasks/$id" "$FAKE_LOG"
}

@test "headless:claude: pre-assigned session, live steer over the FIFO, resume after exit" {
  use_fake claude
  export FAKE_TURN=8
  id="$(new_task --backend headless:claude)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"steering: live"* ]]
  sid="$(meta_of "$id" session_id)"
  [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]
  # The fake logs its argv once it runs, which can be just after dispatch returns.
  for _ in $(seq 1 50); do grep -q -- "--session-id $sid" "$FAKE_LOG" 2>/dev/null && break; sleep 0.1; done
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
  b="$CHARTROOM_HOME/tasks/$id"
  sig="$(printf '%s' "Read the brief at $b/brief.md and follow it exactly. Your task id is $id." | (source "$REPO_ROOT/lib/core.sh"; text_sig))"
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
  set_meta "$id2" '.worktree_created="0"'
  : >"$FAKE_TMUX_DIR/calls.log"
  FAKE_TMUX_TASK="$id2" run cr dispatch "$id2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog chartroom will not answer"* ]]
  ! grep -q "send-keys -t %2" "$FAKE_TMUX_DIR/calls.log" # no keys, and no brief typed at the dialog
  [ "$(meta_of "$id2" brief_pending)" = 1 ]
  events "$id2" | grep -q "agent: awaiting-input: trust dialog for a folder chartroom did not create"
}

@test "tmux: Claude's dialog to add a folder is answered only for the task's own folder" {
  use_fake tmux claude
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  id="$(new_task --backend tmux:claude)"
  # as Claude 2.1 asks on a machine where the task's folder is new to it (a device's guest home)
  printf ' Adding a new directory:\n %s\n This session hasn'"'"'t worked here before. Is this a directory you created or one you trust?\n ❯ No, exit\n   Yes, add it\n Enter to confirm · Esc to cancel\n' \
    "$CHARTROOM_HOME/tasks/$id" >"$FAKE_TMUX_DIR/screen"
  export FAKE_TMUX_TASK="$id"
  run cr dispatch "$id"
  grep -q "send-keys -t %1 Down" "$FAKE_TMUX_DIR/calls.log"
  events "$id" | grep -q "note: added its own folder $CHARTROOM_HOME/tasks/$id when claude asked (chartroom made it)"
  # a folder chartroom did not make: no keys, a wake that says which
  id2="$(new_task --backend tmux:claude)"
  printf ' Adding a new directory:\n /srv/other/secrets\n Is this a directory you created or one you trust?\n ❯ No, exit\n   Yes, add it\n' >"$FAKE_TMUX_DIR/screen"
  : >"$FAKE_TMUX_DIR/calls.log"
  FAKE_TMUX_TASK="$id2" run cr dispatch "$id2"
  [[ "$output" == *"waiting at a startup dialog chartroom will not answer"* ]]
  ! grep -q "send-keys -t %2 Down" "$FAKE_TMUX_DIR/calls.log"
  events "$id2" | grep -q "agent: awaiting-input: a dialog to add /srv/other/secrets, a folder chartroom did not make; a human must answer it"
  # on a short terminal the dialog's header has scrolled off: the folder is read from the history
  id3="$(new_task --backend tmux:claude)"
  printf ' Adding a new directory:\n %s\n' "$CHARTROOM_HOME/tasks/$id3" >"$FAKE_TMUX_DIR/history"
  printf ' This session hasn'"'"'t worked here before.\n ❯ No, exit\n   Yes, add it\n Enter to confirm · Esc to cancel\n' >"$FAKE_TMUX_DIR/screen"
  : >"$FAKE_TMUX_DIR/calls.log"
  FAKE_TMUX_TASK="$id3" run cr dispatch "$id3"
  grep -q "send-keys -t %3 Down" "$FAKE_TMUX_DIR/calls.log"
  events "$id3" | grep -q "note: added its own folder $CHARTROOM_HOME/tasks/$id3 when claude asked"
  # and with nothing to read it from, a human is asked, saying so
  id4="$(new_task --backend tmux:claude)"
  rm -f "$FAKE_TMUX_DIR/history"; : >"$FAKE_TMUX_DIR/calls.log"
  FAKE_TMUX_TASK="$id4" run cr dispatch "$id4"
  ! grep -q "send-keys -t %4 Down" "$FAKE_TMUX_DIR/calls.log"
  events "$id4" | grep -q "agent: awaiting-input: a dialog to add a folder chartroom could not read; a human must answer it"
}

@test "herdr watch --once: a turn that ended while nobody watched wakes the next call, once" {
  use_fake herdr claude
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  id="$(new_task --backend herdr:claude)"
  export FAKE_HERDR_TASK="$id"
  cr dispatch "$id" >/dev/null
  agent_status() { local p t s; read -r p t s <"$FAKE_HERDR_DIR/agents/$id"; echo "$p $t $1" >"$FAKE_HERDR_DIR/agents/$id"; }
  agent_status working
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  agent_status idle
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [ "$output" = "[$id] [proj] herdr: agent stopped its turn without reporting" ]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
}

@test "herdr: with no server (no socket) the watch, status, the radar and sweep run no herdr command; a lost agent wakes once" {
  use_fake herdr claude
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  id="$(new_task --backend herdr:claude)"
  export FAKE_HERDR_TASK="$id"
  cr dispatch "$id" >/dev/null
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # the server goes, and its socket with it
  rm -f "$HOME/.config/herdr/herdr.sock"; : >"$FAKE_HERDR_DIR/calls.log"
  run cr watch --once --timeout 5
  [ "$output" = "[$id] [proj] lost: herdr agent is no longer running" ]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  [ "$(cr status --json | jq -r '.[0].live')" = gone ]
  CHARTROOM_RADAR_MACHINES=none cr radar --json >/dev/null
  cr sweep --json >/dev/null
  [ ! -s "$FAKE_HERDR_DIR/calls.log" ]
}

herdr_trust_screen() {
  printf ' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n' >"$FAKE_HERDR_DIR/screen"
}

@test "herdr: a start blocked by the trust dialog is answered, then the brief is delivered" {
  use_fake herdr claude
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up; herdr_trust_screen
  id="$(new_task --backend herdr:claude)"
  export FAKE_HERDR_TASK="$id"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"herdr claude worker running"* ]]
  [ "$(grep -c "^agent start $id " "$FAKE_HERDR_DIR/calls.log")" -eq 1 ]
  grep -q "^agent send-keys $id down$" "$FAKE_HERDR_DIR/calls.log"
  grep -q "^agent send-keys $id enter$" "$FAKE_HERDR_DIR/calls.log"
  grep -q "^agent prompt $id Read the brief at" "$FAKE_HERDR_DIR/calls.log"
  events "$id" | grep -q "note: herdr: agent blocked at startup; checking for a trust dialog"
  events "$id" | grep -q "note: accepted workspace trust for its own worktree"
  events "$id" | grep -q "agent: prompt-received"
}

@test "herdr:agy: herdr starts agy with its flags, its trust dialog is answered, and a steer never types into its dialogs" {
  use_fake herdr agy
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  printf 'Do you trust the contents of this project?\n\n> Yes, I trust this folder\n  No, exit\n\n  ↑/↓ Navigate · enter Confirm\n                         auto · Gemini 4 Neon · high\n' >"$FAKE_HERDR_DIR/screen"
  id="$(new_task --backend herdr:agy)"
  export FAKE_HERDR_PROMPT_STATUS=working
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"herdr agy worker running"* ]]
  grep -qF "agent start $id --kind agy --pane " "$FAKE_HERDR_DIR/calls.log"
  grep -qF -- "-- --add-dir $(cd "$CHARTROOM_HOME/tasks/$id" && pwd -P)" "$FAKE_HERDR_DIR/calls.log"
  grep -q "^agent send-keys $id enter$" "$FAKE_HERDR_DIR/calls.log"
  refute() { if "$@"; then return 1; fi; }
  refute grep -q "^agent send-keys $id down$" "$FAKE_HERDR_DIR/calls.log"
  grep -q "^agent prompt $id Read the brief at" "$FAKE_HERDR_DIR/calls.log"
  events "$id" | grep -q "note: accepted workspace trust for its own worktree"
  # an approval on its screen: the steer is refused before anything is typed
  printf '/w/report.md  +1\nReason: outside workspace\n\nAllow creation of this file?\n> 1. Yes, allow creation\n  2. Yes, and always allow non-workspace access\n  3. No, deny creation\n\n  ↑/↓ Navigate · f full diff\nesc to cancel                 auto · Gemini 4 Neon · high\n' >"$FAKE_HERDR_DIR/screen"
  : >"$FAKE_HERDR_DIR/calls.log"
  run cr steer "$id" "yes"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked at a dialog (agy approval prompt: Allow creation of this file?)"* ]]
  refute grep -q "^agent prompt" "$FAKE_HERDR_DIR/calls.log"
  # nothing on screen: it goes in, taken but unchecked
  rm -f "$FAKE_HERDR_DIR/screen"
  run cr steer "$id" "also list the tests folder"
  [ "$status" -eq 0 ]
  [[ "$output" == "submitted, not verified"* ]]
}

@test "herdr: a stale agent from an earlier start is closed only when it is this task's own" {
  use_fake herdr claude
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR/agents"; herdr_sock_up
  echo chartroom-crew >"$FAKE_HERDR_DIR/ws"
  id="$(new_task --backend herdr:claude)"
  export FAKE_HERDR_TASK="$id"
  # an earlier start died at the trust dialog: its agent still holds the name in its recorded tab
  set_meta "$id" '.herdr_tab="w1:t9"'
  echo "w1:p9 w1:t9 blocked" >"$FAKE_HERDR_DIR/agents/$id"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  grep -q "^tab close w1:t9$" "$FAKE_HERDR_DIR/calls.log"
  [ "$(grep -c "^tab create " "$FAKE_HERDR_DIR/calls.log")" -eq 1 ]
  [ "$(meta_of "$id" herdr_tab)" != "w1:t9" ]
  events "$id" | grep -q "note: closed the stale herdr tab w1:t9 left by an earlier start (blocked)"
  events "$id" | grep -q "agent: prompt-received"
  # a same-named agent in a tab chartroom did not record for the task is never closed
  id2="$(new_task --backend herdr:claude)"
  echo "w1:p8 w1:t8 idle" >"$FAKE_HERDR_DIR/agents/$id2"
  : >"$FAKE_HERDR_DIR/calls.log"
  FAKE_HERDR_TASK="$id2" run cr dispatch "$id2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already runs in tab w1:t8, which chartroom did not record"* ]]
  ! grep -q "^tab close" "$FAKE_HERDR_DIR/calls.log"
  ! grep -q "^agent start" "$FAKE_HERDR_DIR/calls.log"
  # nor is this task's own agent while it is mid-turn
  set_meta "$id2" '.herdr_tab="w1:t8"'
  echo "w1:p8 w1:t8 working" >"$FAKE_HERDR_DIR/agents/$id2"
  FAKE_HERDR_TASK="$id2" run cr dispatch "$id2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already working in tab w1:t8"* ]]
  ! grep -q "^tab close" "$FAKE_HERDR_DIR/calls.log"
  # nor is a worker whose launch finished, even idle: re-dispatch is not a way to steer it
  [ "$(meta_of "$id" herdr_launched)" = 1 ]
  : >"$FAKE_HERDR_DIR/calls.log"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the worker for $id is live in herdr tab"* ]]
  ! grep -q "^tab close" "$FAKE_HERDR_DIR/calls.log"
}

@test "herdr: a blocked start in a folder chartroom did not create is never auto-trusted" {
  use_fake herdr claude
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up; herdr_trust_screen
  id="$(new_task --backend herdr:claude)"
  export FAKE_HERDR_TASK="$id"
  cr worktree "$id" >/dev/null
  set_meta "$id" '.worktree_created="0"'
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog chartroom will not answer: answer it in herdr tab"*"the watch delivers its brief once it clears"* ]]
  ! grep -q "^agent send-keys" "$FAKE_HERDR_DIR/calls.log"
  ! grep -q "^agent prompt" "$FAKE_HERDR_DIR/calls.log"
  events "$id" | grep -q "agent: awaiting-input: trust dialog for a folder chartroom did not create"
  [ "$(meta_of "$id" brief_pending)" = 1 ]
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
  # the pattern kill guard, as a per-run hook whose text names no task (Codex trusts it once by its text)
  guard="$(printf '%s\n' "${args[@]}" | grep '^hooks.PreToolUse=')"
  [[ "$guard" == 'hooks.PreToolUse=[{matcher="Bash",hooks=[{type="command",command="CHARTROOM_HOME='*" $CHARTROOM hook - guard\"}]}]" ]]
  [[ "$guard" != *"$id"* ]]
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

@test "default order is hc, herdr, cmux, tmux (every agent's), then headless, command" {
  run cr doctor --json
  [ "$(jq -r '.order|join(" ")' <<<"$output")" = "hc:claude hc:codex hc:agy hc:grok herdr:claude herdr:codex herdr:agy herdr:grok cmux:claude cmux:codex tmux:claude tmux:codex headless:codex headless:claude command" ]
}

@test "legacy backend names still work on old records" {
  use_fake codex
  id="$(new_task --backend codex)"
  set_meta "$id" '.backend="codex" | del(.backend_source)'
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

@test "herdr claude workers get the prompt hook and the Bash guard; tmux/cmux get all four" {
  use_fake claude
  id="$(new_task --backend herdr:claude)"
  run bash -c "source '$REPO_ROOT/lib/core.sh'; source '$REPO_ROOT/lib/agents.sh'; CR_BIN='$CHARTROOM'; load_config; interactive_argv '$id' claude prompt"
  [[ "$output" == *"--settings"* ]]
  [ "$(jq -c '.hooks|keys' "$CHARTROOM_HOME/tasks/$id/claude-settings.json")" = '["PermissionDenied","PermissionRequest","PreToolUse","UserPromptSubmit"]' ]
  run bash -c "source '$REPO_ROOT/lib/core.sh'; source '$REPO_ROOT/lib/agents.sh'; CR_BIN='$CHARTROOM'; load_config; interactive_argv '$id' claude 1"
  [ "$(jq -c '.hooks|keys' "$CHARTROOM_HOME/tasks/$id/claude-settings.json")" = '["Notification","PermissionDenied","PermissionRequest","PreToolUse","Stop","UserPromptSubmit"]' ]
}
