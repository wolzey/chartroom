#!/usr/bin/env bats
# A worker must never sit stuck unnoticed (lib/stuck.sh): a prompt or dialog nothing reports, a
# brief behind a dialog, a worker gone quiet. Screens are real ones, from codex-cli 0.158.0.

load test_helper
setup() {
  common_setup
  use_fake hc herdr-app claude codex
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc" FAKE_HERDR_APP_DIR="$BATS_TEST_TMPDIR/app"
  mkdir -p "$FAKE_HC_DIR" "$FAKE_HERDR_APP_DIR"
  export CHARTROOM_LOOK_INTERVAL=1
}
teardown() {
  [[ -f "$BATS_TEST_TMPDIR/core.pid" ]] && kill "$(cat "$BATS_TEST_TMPDIR/core.pid")" 2>/dev/null
  [[ -n "${CORE_DIR:-}" ]] && rm -rf "$CORE_DIR"
  return 0
}
stop_worker() { cr stop "$1" >/dev/null 2>&1 || true; }

core_up() {
  local d="$XDG_STATE_HOME/herdr-core/default" i
  CORE_DIR="$(mktemp -d /tmp/crst.XXXXXX)"; SOCK="$CORE_DIR/s"
  mkdir -p "$d"; printf '%s\n' "$SOCK" >"$d/core.lock"
  perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die "$!"; while (my $c = $s->accept) { close $c }' "$SOCK" 3>&- &
  echo $! >"$BATS_TEST_TMPDIR/core.pid"
  for i in $(seq 1 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  return 1
}
hc_calls() { cat "$FAKE_HC_DIR/calls.log"; }
refute() { if "$@"; then echo "expected to fail: $*" >&2; return 1; fi; }
set_term() { local t="$1" f; shift; f="$FAKE_HC_DIR/terms/$t.json"; jq "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
state_of_task() { cr status --json | jq -r --arg i "$1" '.[]|select(.id==$i).state'; }
watch_after() { # <change...>: `watch --once` in the background; <change> runs once it has looked
  cr watch --once --timeout 8 >"$BATS_TEST_TMPDIR/wake" 2>&1 &
  local w=$!; sleep 1.5; "$@"; wait "$w" || true
}
wakes() { grep -c . "$BATS_TEST_TMPDIR/wake" || true; }
stream_up() { export FAKE_HC_EVENTS=1 CHARTROOM_WATCH_HC_INTERVAL=30; }
# hc's event line for a terminal; with a jq filter, the same change in `hc get`'s record too.
hc_event() { # <address> <type> <data json> [jq filter]
  local n; n=$(( $(cat "$FAKE_HC_DIR/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE_HC_DIR/seq"
  [[ -z "${4:-}" ]] || set_term "$1" "$4"
  jq -cn --arg t "$1" --arg ty "$2" --argjson d "$3" --argjson s "$n" \
    '{jsonrpc: "2.0", method: "event", params: {data: $d, seq: $s, terminal: $t, type: $ty}}' >>"$FAKE_HC_DIR/events.ndjson"
}
title_event() { hc_event "$1" title "$(jq -cn --arg t "$2" '{title: $t}')" "$(printf '.title = %s' "$(jq -cn --arg t "$2" '$t')")"; }

codex_approval() {
  cat <<'EOF'
› Run this exact shell command: touch $HOME/.probe

• I'll request approval to run the same command outside the sandbox.

• Running touch $HOME/.probe


  Would you like to run the following command?

  Environment: local

  Reason: Do you want to allow creating this file in your home directory outside the sandbox?

  $ touch $HOME/.probe

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `touch $HOME/.probe` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel

EOF
}
codex_hooks_dialog() {
  cat <<'EOF'

  Hooks need review

  1 hook is new or changed.

  Hooks can run outside the sandbox after you trust them.

› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)

  enter confirm · esc skip

EOF
}
codex_trust_dialog() {
  cat <<'EOF'
  Folder access

  /some/where

  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.

› 1. Trust and continue
  2. Quit

  enter continue · esc quit
EOF
}
# The composer is up, with every dialog's words higher up in the transcript: no dialog at all.
codex_transcript_of_dialogs() {
  cat <<'EOF'
• Ran cat lib/stuck.sh
  └ Hooks need review
    Trust this folder?
    Would you like to run the following command?
    enter confirm · esc skip
    enter continue · esc quit
    Press enter to confirm or esc to cancel

• Working (3m 43s • esc to interrupt)
  └ Tip: Use /hooks to view and manage lifecycle hooks.


› Ask Codex to do anything

  GPT-6-Astra default · ~/work/proj · Review brief
  ? for shortcuts
EOF
}

# ---------------------------------------------------------------- what a screen shows

@test "screen_prompt: each dialog by its own footer, never by words in a transcript" {
  source "$REPO_ROOT/lib/core.sh"; source "$REPO_ROOT/lib/stuck.sh"; source "$REPO_ROOT/lib/agents.sh"
  meta() { echo 1; } # worktree_created
  [ "$(screen_prompt x codex "$(codex_approval)")" = 'Codex approval prompt: $ touch $HOME/.probe' ]
  [[ "$(screen_prompt x codex "$(codex_hooks_dialog)")" == 'Codex "Hooks need review" dialog: 1 hook is new or changed. Esc continues without those hooks;'* ]]
  [ "$(screen_prompt x codex "$(codex_trust_dialog)")" = 'trust dialog came up after the dispatch; a human must answer it' ]
  [ -z "$(screen_prompt x codex "$(codex_transcript_of_dialogs)")" ]
  # hc's own note under the screen changes nothing
  [ "$(screen_prompt x codex "$(codex_approval; echo '[hc] incomplete: older output may be missing')")" = 'Codex approval prompt: $ touch $HOME/.probe' ]
  [ -n "$(screen_prompt x claude $' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n')" ]
  [ -z "$(screen_prompt x claude "$(codex_approval)")" ]
  [ -z "$(screen_prompt x claude $'● trust this folder, it said\n\n❯ \n')" ]
}

@test "screen_norm: what ticks by itself compares equal, what the agent did does not" {
  source "$REPO_ROOT/lib/stuck.sh"
  n() { screen_norm <<<"$1"; }
  [ "$(n $'• Ran ls\n• Working (3m 43s • esc to interrupt)\n  └ Tip: a\n› ')" = "$(n $'• Ran ls\n• Working (3m 44s • esc to interrupt)\n  └ Tip: b\n› ')" ]
  # Claude's verb and elapsed time move by themselves; its token count moves when the model does
  [ "$(n $'✽ Fluttering… (22m 57s · ↓ 91.5k tokens)')" = "$(n $'✻ Pondering… (23m 3s · ↓ 91.5k tokens)')" ]
  [ "$(n $'✽ Fluttering… (22m 57s · ↓ 91.5k tokens)')" != "$(n $'✽ Fluttering… (22m 58s · ↓ 91.6k tokens)')" ]
  [ "$(n $'• Running npm test (1h 2m 3s)')" = "$(n $'• Running npm test (1h 2m 4s)')" ]
  [ "$(n $'  7:10 AM')" = "$(n $'  7:11 AM')" ]
  [ "$(n $'• Ran ls')" != "$(n $'• Ran ls -la')" ]
  [ "$(n $'+12 tool uses')" != "$(n $'+13 tool uses')" ]
  [ "$(n $'wrote 3m.txt')" != "$(n $'wrote 4m.txt')" ]
}

# ---------------------------------------------------------------- Codex's notify

@test "codex notify: its title-generator thread is no turn of the worker's, and not its thread" {
  id="$(TITLE=t new_task --command 'true' --backend command)"
  cr hook "$id" codex-notify '{"type":"agent-turn-complete","thread-id":"th-title","input-messages":["Generate a concise, single-line task title of at most 36 characters.\n\nUser prompt:\nRead the brief"],"last-assistant-message":"{\"title\":\"Read brief\"}"}'
  refute grep -q 'agent: turn-ended' "$CHARTROOM_HOME/tasks/$id/events.log"
  [ -z "$(meta_of "$id" thread_id)" ]
  grep -q 'th-title' "$CHARTROOM_HOME/tasks/$id/hooks.log" # the raw record keeps it
  cr hook "$id" codex-notify '{"type":"agent-turn-complete","thread-id":"th-real","input-messages":["Read the brief"]}'
  grep -q 'agent: turn-ended' "$CHARTROOM_HOME/tasks/$id/events.log"
  [ "$(meta_of "$id" thread_id)" = th-real ]
}

# ---------------------------------------------------------------- an approval prompt, hc:codex

# hc sends a title line per spinner frame, many a second per Codex: each fact here rings the watch.
@test "hc stream filter: titles become one fact per Action Required going on or off, and nothing else" {
  source "$REPO_ROOT/lib/backends/hc.sh"
  ev() { jq -cn --arg t "$1" --argjson n "$2" '{jsonrpc: "2.0", method: "event", params: {data: {title: $t}, seq: $n, terminal: "t1", type: "title"}}'; }
  run bash -c 'jq -R -n -r --unbuffered "$1" | tr "\037" "~"' _ "$HC_STREAM_JQ" < <(
    jq -cn '{channel: null, seq: 0, terminals: [
      {address: "t1", argv: ["bash", "/h/tasks/a/launch.sh"], state: "live", status: null, turn: 0, name: "a", title: "⠋ x | repo"},
      {address: "t2", argv: ["bash", "/h/tasks/b/launch.sh"], state: "live", status: null, turn: 0, name: "b", title: "[ ! ] Action Required | y | repo"}]}'
    ev '⠙ x | repo' 1
    ev '⠹ x | repo' 2
    ev 'Review Action Required banner | repo' 3 # a thread may be called anything
    ev '⠼ x | repo' 4
    ev '[ . ] Action Required | x | repo' 5
    ev '[ ! ] Action Required | x | repo' 6
    ev '[ . ] Action Required | x | repo' 7
    ev '⠸ x | repo' 8
    ev 'x | repo' 9
  )
  [ "$status" -eq 0 ]
  [ "$output" = $'S~0\nT~t1~live~~0~a~ a ~0\nT~t2~live~~0~b~ b ~1\nE\nA~t1~1\nA~t1~0' ]
  # the same reading of a title where there is no stream (tmux)
  source "$REPO_ROOT/lib/stuck.sh"
  codex_title_prompt '[ . ] Action Required | x | repo'
  codex_title_prompt '[ ! ] Action Required | x | repo'
  refute codex_title_prompt 'Review Action Required banner | repo'
}

@test "hc:codex events: the title's Action Required wakes as awaiting-input, once, without a look per spinner frame" {
  core_up; stream_up
  export CHARTROOM_STALL_MINUTES=0 CHARTROOM_LOOK_INTERVAL=60 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  prompt_up() {
    : >"$FAKE_HC_DIR/calls.log" # (the watch has taken its first look)
    # the spinner, many a second: nothing to hear about
    for f in '⠋ Review brief | repo' '⠙ Review brief | repo' 'Review Action Required banner | repo'; do title_event t1 "$f"; done
    codex_approval >"$FAKE_HC_DIR/screen"
    title_event t1 '[ . ] Action Required | Review brief | repo'
    title_event t1 '[ ! ] Action Required | Review brief | repo'
    title_event t1 '[ . ] Action Required | Review brief | repo'
  }
  watch_after prompt_up
  grep -qE "^\[$id\] \[proj\] [0-9TZ:-]+ agent: awaiting-input: Codex approval prompt: \\$ touch \\\$HOME/\.probe$" "$BATS_TEST_TMPDIR/wake"
  [ "$(wakes)" -eq 1 ]
  # from the stream: no hc get, and the screen read once, for the wake's own words
  refute grep -q '^get' "$FAKE_HC_DIR/calls.log"
  [ "$(grep -c '^read' "$FAKE_HC_DIR/calls.log")" -eq 1 ]
  [ "$(state_of_task "$id")" = awaiting-input ]
  # the next call does not repeat it
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # answered: nothing to wake for, and the task reads as working again
  answered() { echo 'Working (9s • esc to interrupt)' >"$FAKE_HC_DIR/screen"; title_event t1 '⠋ Review brief | repo'; }
  watch_after answered
  refute grep -q '^\[' "$BATS_TEST_TMPDIR/wake"
  grep -q 'agent: prompt-cleared' "$CHARTROOM_HOME/tasks/$id/events.log"
  [ "$(state_of_task "$id")" = working ]
  # the next approval is news of its own
  second() { codex_approval | sed 's/\.probe/.again/' >"$FAKE_HC_DIR/screen"; title_event t1 '[ . ] Action Required | Review brief | repo'; }
  watch_after second
  grep -q 'awaiting-input: Codex approval prompt: \$ touch \$HOME/\.again$' "$BATS_TEST_TMPDIR/wake"
}

@test "hc:codex with no stream: the title from hc get wakes the same, once; --once keeps its place" {
  core_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  codex_approval >"$FAKE_HC_DIR/screen"
  set_term t1 '.title = "[ ! ] Action Required | Review brief | repo"'
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: awaiting-input: Codex approval prompt: \$ touch \$HOME/.probe" ]]
  [ "$(cr status --json | jq -r '.[0].live')" = blocked ]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  [ "$(grep -c 'awaiting-input' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 1 ]
}

@test "hc:codex with its title turned off (tui.terminal_title): the screen alone raises the prompt, and its end" {
  core_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  codex_approval >"$FAKE_HC_DIR/screen"
  run cr watch --once --timeout 5
  [[ "$output" == *"agent: awaiting-input: Codex approval prompt: \$ touch \$HOME/.probe" ]]
  [ "$(cr status --json | jq -r '.[0].live')" = blocked ]
  echo 'Working (9s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  [ "$(cr status --json | jq -r '.[0].live')" = working ]
}

@test "hc:codex: a streaming watch started with an approval already up raises it at its first look, once" {
  core_up; stream_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  cr dispatch "$id" >/dev/null
  codex_approval >"$FAKE_HC_DIR/screen"
  set_term t1 '.title = "[ . ] Action Required | Review brief | repo"'
  # no cursor: a stream starts at the logs' end and seeds each agent's state from now
  # (Not through `cr`: a function in the background is a subshell, and $! would not be the watch.)
  "$CHARTROOM" watch >"$BATS_TEST_TMPDIR/wake" 2>&1 3>&- &
  local w=$!; sleep 4; kill "$w" 2>/dev/null; wait "$w" || true
  grep -q 'agent: awaiting-input: Codex approval prompt: \$ touch \$HOME/\.probe$' "$BATS_TEST_TMPDIR/wake"
  [ "$(wakes)" -eq 1 ]
  [ "$(grep -c 'awaiting-input' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 1 ]
}

@test "hc:codex: a second approval while the title never went off is news of its own, at the next look" {
  core_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  codex_approval >"$FAKE_HC_DIR/screen"
  set_term t1 '.title = "[ . ] Action Required | Review brief | repo"'
  run cr watch --once --timeout 5
  [[ "$output" == *'Codex approval prompt: $ touch $HOME/.probe' ]]
  codex_approval | sed 's/\.probe/.again/' >"$FAKE_HC_DIR/screen"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *'Codex approval prompt: $ touch $HOME/.again' ]]
}

@test "hc:claude: its own blocked state wakes as awaiting-input too" {
  core_up
  export CHARTROOM_STALL_MINUTES=0
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  set_term t1 '.status.state = "blocked"'
  run cr watch --once --timeout 5
  [[ "$output" == *"agent: awaiting-input: hc: agent is waiting on an approval or question prompt" ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # a title that happens to say so means nothing while the agent reports its own state
  set_term t1 '.status.state = "working" | .title = "[ . ] Action Required | x"'
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # the log's account of the prompt ends when the agent moves on
  events "$id" | grep -q 'agent: prompt-cleared'
}

@test "herdr: its own blocked state wakes as awaiting-input, and leaving it is recorded" {
  export CHARTROOM_STALL_MINUTES=0
  use_fake herdr
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  id="$(new_task --backend herdr:claude)"
  export FAKE_HERDR_TASK="$id"
  cr dispatch "$id" >/dev/null
  a="$FAKE_HERDR_DIR/agents/$id"; read -r pane tab _ <"$a"
  echo "$pane $tab working" >"$a"
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  echo "$pane $tab blocked" >"$a"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: awaiting-input: herdr: agent is waiting on an approval or question prompt" ]]
  echo "$pane $tab working" >"$a"
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  events "$id" | grep -q 'agent: prompt-cleared'
}

@test "stall: a prompt answered long ago does not hold back a later stall (hc:claude)" {
  export CHARTROOM_STALL_MINUTES=0.05
  core_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  set_term t1 '.status.state = "blocked"'
  run cr watch --once --timeout 5
  [[ "$output" == *"agent: awaiting-input"* ]]
  # at the prompt: told once, and no stall on top of it
  run cr watch --once --timeout 5
  [ "$status" -eq 124 ]
  # answered, then the agent wedges
  set_term t1 '.status.state = "working"'
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"stalled: no output or events for"* ]]
}

@test "stall: a frozen blank screen is still a screen" {
  export CHARTROOM_STALL_MINUTES=0.05
  core_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  printf '\n\n' >"$FAKE_HC_DIR/screen"
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"stalled: no output or events for 0 min. Last output: (none)" ]]
}

# Enter at the overlay takes its highlighted "Yes, proceed": chartroom must never type there.
@test "steer refuses a Codex at a prompt, whatever shows it, and never sends a key (hc)" {
  core_up
  export FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  cr dispatch "$id" >/dev/null
  # by its title
  set_term t1 '.title = "[ . ] Action Required | Review brief | repo"'
  : >"$FAKE_HC_DIR/calls.log"
  run cr steer "$id" "carry on"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked at a dialog"*"chartroom attach $id"* ]]
  refute grep -qE '^(send|keys)' "$FAKE_HC_DIR/calls.log"
  refute grep -q 'steered: carry on' "$CHARTROOM_HOME/tasks/$id/events.log"
  # by its screen alone (a dialog sets no title)
  set_term t1 '.title = "repo"'
  codex_hooks_dialog >"$FAKE_HC_DIR/screen"
  run cr steer "$id" "carry on"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Hooks need review"*"chartroom attach $id"* ]]
  refute grep -qE '^(send|keys)' "$FAKE_HC_DIR/calls.log"
  # no dialog: as ever
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  run cr steer "$id" "carry on"
  [ "$status" -eq 0 ]
  grep -q '^send' "$FAKE_HC_DIR/calls.log"
}

# ---------------------------------------------------------------- an approval prompt, elsewhere

tmux_codex() {
  use_fake tmux
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  echo "Working (3s • esc to interrupt)" >"$FAKE_TMUX_DIR/screen"
  id="$(new_task --backend tmux:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
}

@test "tmux:codex: the pane's title wakes as awaiting-input, the screen where it says more; cleared when gone" {
  export CHARTROOM_STALL_MINUTES=0
  tmux_codex
  # by the title alone: an overlay the screen patterns do not know
  echo '[ . ] Action Required | Review brief | repo' >"$FAKE_TMUX_DIR/title"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: awaiting-input: Codex approval prompt (its terminal title says Action Required)" ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  [ "$(cr status --json | jq -r '.[0].live')" = blocked ]
  rm "$FAKE_TMUX_DIR/title"
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  grep -q 'agent: prompt-cleared' "$CHARTROOM_HOME/tasks/$id/events.log"
  [ "$(cr status --json | jq -r '.[0].live')" = working ]
  # by the screen
  codex_approval >"$FAKE_TMUX_DIR/screen"
  run cr watch --once --timeout 5
  [[ "$output" == *"agent: awaiting-input: Codex approval prompt: \$ touch \$HOME/.probe" ]]
  # and a steer never reaches it
  : >"$FAKE_TMUX_DIR/calls.log"
  run cr steer "$id" "carry on"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked at a dialog"* ]]
  refute grep -q 'send-keys' "$FAKE_TMUX_DIR/calls.log"
}

@test "cmux:codex: the screen wakes as awaiting-input (no title to read)" {
  export CHARTROOM_STALL_MINUTES=0 CHARTROOM_CMUX_ANY_OS=1 FAKE_CMUX_DIR="$BATS_TEST_TMPDIR/cmux"
  use_fake cmux; mkdir -p "$FAKE_CMUX_DIR"
  echo "Working (3s • esc to interrupt)" >"$FAKE_CMUX_DIR/screen"
  id="$(new_task --backend cmux:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  codex_approval >"$FAKE_CMUX_DIR/screen"
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: awaiting-input: Codex approval prompt: \$ touch \$HOME/.probe" ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
}

# ---------------------------------------------------------------- the brief behind a dialog

@test "hc:codex dispatch: a hooks dialog is raised, nothing is answered, and it starts on the brief once it clears" {
  core_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  codex_hooks_dialog >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog chartroom will not answer: answer it in Herdr (chartroom attach $id); it starts on the brief once answered"* ]]
  [[ "$output" != *"did not take the brief"* ]]
  events "$id" | grep -qE 'agent: awaiting-input: Codex "Hooks need review" dialog: 1 hook is new or changed'
  # no key reached the dialog, and no copy of the brief was typed at it
  refute grep -qE '^(send|keys)' "$FAKE_HC_DIR/calls.log"
  [ "$(meta_of "$id" hc_launched)" = 1 ]
  [ "$(state_of_task "$id")" = awaiting-input ]
  # the wake, once; the brief is the launcher's first prompt, so nothing is left to deliver
  run cr watch --once --timeout 5
  [[ "$output" == *'agent: awaiting-input: Codex "Hooks need review" dialog'* ]]
  [ "$(grep -c 'Hooks need review' <<<"$output")" -eq 1 ]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  events "$id" | grep -q 'agent: prompt-cleared'
  [ "$(state_of_task "$id")" = working ]
  refute grep -qE '^(send|keys)' "$FAKE_HC_DIR/calls.log"
}

@test "hc dispatch: a transcript holding a dialog's words is not a dialog: no key is sent" {
  core_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  # a worker reading chartroom's own tests, with its composer up: no key may reach it
  { printf ' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n'; codex_transcript_of_dialogs; } >"$BATS_TEST_TMPDIR/s"
  source "$REPO_ROOT/lib/core.sh"; source "$REPO_ROOT/lib/stuck.sh"; source "$REPO_ROOT/lib/agents.sh"
  meta() { echo 1; }
  [ -z "$(screen_prompt x codex "$(cat "$BATS_TEST_TMPDIR/s")")" ]
  [ -z "$(screen_prompt x claude "$(cat "$BATS_TEST_TMPDIR/s")")" ]
}

@test "hc:codex dispatch: a dialog that comes up later than the first look is caught too" {
  core_up
  export CHARTROOM_STALL_MINUTES=0 FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  printf '› Ask Codex to do anything\n' >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  ( sleep 4; codex_hooks_dialog >"$FAKE_HC_DIR/screen" ) 3>&- &
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog"* ]]
  events "$id" | grep -q 'agent: awaiting-input: Codex "Hooks need review" dialog'
}

@test "CHARTROOM_CODEX_HOOKS_DIALOG=skip: Esc in chartroom's own worktree, said in the log; never trust; never elsewhere" {
  core_up
  export CHARTROOM_CODEX_HOOKS_DIALOG=skip FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  codex_hooks_dialog >"$FAKE_HC_DIR/screen"
  id="$(new_task --backend hc:codex)"
  run cr dispatch "$id"
  hc_calls | grep -qx "keys t1 esc"
  refute grep -qE '^keys t1 (enter|down)' "$FAKE_HC_DIR/calls.log"
  events "$id" | grep -q "note: continued past Codex's \"Hooks need review\" dialog without those hooks"
  refute grep -q 'awaiting-input' "$CHARTROOM_HOME/tasks/$id/events.log"
  # a folder chartroom did not create is not its to answer
  codex_hooks_dialog >"$FAKE_HC_DIR/screen"
  id2="$(new_task --backend hc:codex)"
  cr worktree "$id2" >/dev/null
  jq '.worktree_created="0"' "$CHARTROOM_HOME/tasks/$id2/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id2/meta.json"
  : >"$FAKE_HC_DIR/calls.log"
  run cr dispatch "$id2"
  [ "$status" -eq 0 ]
  refute grep -q '^keys' "$FAKE_HC_DIR/calls.log"
  events "$id2" | grep -q 'agent: awaiting-input: Codex "Hooks need review" dialog'
  CHARTROOM_CODEX_HOOKS_DIALOG=sure run cr status
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be ask or skip"* ]]
}

@test "tmux:codex dispatch: the brief is never typed at a dialog; the watch delivers it once it clears" {
  export CHARTROOM_STALL_MINUTES=0
  use_fake tmux
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  codex_hooks_dialog >"$FAKE_TMUX_DIR/screen"
  id="$(new_task --backend tmux:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux codex worker waiting at a startup dialog chartroom will not answer: answer it (chartroom attach $id); the watch delivers its brief once it clears"* ]]
  [[ "$output" != *"worker running"* ]]
  refute grep -q 'send-keys' "$FAKE_TMUX_DIR/calls.log"
  [ "$(meta_of "$id" brief_pending)" = 1 ]
  events "$id" | grep -q 'agent: awaiting-input: Codex "Hooks need review" dialog'
  # still up: the wake, and still no typing
  run cr watch --once --timeout 5
  [[ "$output" == *'Hooks need review'* ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  refute grep -q 'send-keys' "$FAKE_TMUX_DIR/calls.log"
  # answered: the brief goes in, once
  echo "Working (3s • esc to interrupt)" >"$FAKE_TMUX_DIR/screen"
  run cr watch --once --timeout 3
  grep -qF "send-keys -t %1 -l -- Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md" "$FAKE_TMUX_DIR/calls.log"
  [ -z "$(meta_of "$id" brief_pending)" ]
  events "$id" | grep -q 'note: the brief went in once the dialog cleared'
  events "$id" | grep -q 'agent: prompt-cleared'
  : >"$FAKE_TMUX_DIR/calls.log"
  run cr watch --once --timeout 2
  refute grep -qF -- '-l --' "$FAKE_TMUX_DIR/calls.log"
}

@test "tmux:codex and herdr:codex dispatch: a hooks dialog right after the trust dialog chartroom answered still holds the brief" {
  export CHARTROOM_STALL_MINUTES=0
  use_fake tmux herdr
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux" FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_TMUX_DIR" "$FAKE_HERDR_DIR"; herdr_sock_up
  # The trust dialog is on screen until its Enter; the hooks dialog replaces it.
  next_dialog() { # <screen file> <calls log> <the call that answers it>
    ( for _ in $(seq 1 100); do grep -q "$3" "$2" 2>/dev/null && { codex_hooks_dialog >"$1"; exit 0; }; sleep 0.1; done ) 3>&- &
  }
  codex_trust_dialog >"$FAKE_TMUX_DIR/screen"
  next_dialog "$FAKE_TMUX_DIR/screen" "$FAKE_TMUX_DIR/calls.log" 'send-keys -t %1 Enter'
  id="$(new_task --backend tmux:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog"* ]]
  events "$id" | grep -q 'note: accepted workspace trust for its own worktree'
  events "$id" | grep -q 'agent: awaiting-input: Codex "Hooks need review" dialog'
  refute grep -qF -- ' -l -- ' "$FAKE_TMUX_DIR/calls.log"
  [ "$(meta_of "$id" brief_pending)" = 1 ]
  codex_trust_dialog >"$FAKE_HERDR_DIR/screen"
  next_dialog "$FAKE_HERDR_DIR/screen" "$FAKE_HERDR_DIR/calls.log" '^agent send-keys .* enter'
  id2="$(new_task --backend herdr:codex)"
  run cr dispatch "$id2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog"* ]]
  events "$id2" | grep -q 'agent: awaiting-input: Codex "Hooks need review" dialog'
  refute grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
}

@test "herdr: a start blocked at a dialog nobody can name is never prompted through; raised; delivered once herdr says it cleared" {
  export CHARTROOM_STALL_MINUTES=0
  use_fake herdr
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  id="$(new_task --backend herdr:codex)"
  # The fake blocks a start only at its trust dialog, whose Enter chartroom sends; herdr then still says blocked.
  codex_trust_dialog >"$FAKE_HERDR_DIR/screen"
  ( for _ in $(seq 1 100); do [[ -f "$FAKE_HERDR_DIR/agents/$id" ]] && grep -q '^agent send-keys .* enter' "$FAKE_HERDR_DIR/calls.log" 2>/dev/null && { read -r p t _ <"$FAKE_HERDR_DIR/agents/$id"; echo "$p $t blocked" >"$FAKE_HERDR_DIR/agents/$id"; printf 'Some dialog nobody has seen\n' >"$FAKE_HERDR_DIR/screen"; exit 0; }; sleep 0.1; done ) 3>&- &
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog"* ]]
  events "$id" | grep -q 'agent: awaiting-input: herdr: the agent is blocked at a startup dialog'
  refute grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
  [ "$(meta_of "$id" brief_pending)" = 1 ]
  # still blocked: nothing typed
  run cr watch --once --timeout 3
  refute grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
  read -r p t _ <"$FAKE_HERDR_DIR/agents/$id"; echo "$p $t idle" >"$FAKE_HERDR_DIR/agents/$id"
  printf '› Ask Codex to do anything\n%s\n' "Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md" >"$FAKE_HERDR_DIR/screen"
  run cr watch --once --timeout 3
  grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
  [ -z "$(meta_of "$id" brief_pending)" ]
}

@test "CHARTROOM_CODEX_HOOKS_DIALOG=skip on tmux: Esc after the trust dialog too, then the brief is typed, in the same dispatch" {
  export CHARTROOM_STALL_MINUTES=0 CHARTROOM_CODEX_HOOKS_DIALOG=skip
  use_fake tmux
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  codex_hooks_dialog >"$FAKE_TMUX_DIR/screen"
  ( for _ in $(seq 1 100); do grep -q 'send-keys -t %1 Escape' "$FAKE_TMUX_DIR/calls.log" 2>/dev/null && { echo "Working (3s • esc to interrupt)" >"$FAKE_TMUX_DIR/screen"; exit 0; }; sleep 0.1; done ) 3>&- &
  id="$(new_task --backend tmux:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux codex worker running"* ]]
  events "$id" | grep -q "note: continued past Codex's \"Hooks need review\" dialog without those hooks"
  grep -qF "send-keys -t %1 -l -- Read the brief at" "$FAKE_TMUX_DIR/calls.log"
  [ -z "$(meta_of "$id" brief_pending)" ]
}

@test "tmux: a delivery that fails once the dialog clears is raised, never silently dropped" {
  export CHARTROOM_STALL_MINUTES=0 CHARTROOM_DELIVER_WAIT=1
  use_fake tmux
  export FAKE_TMUX_DIR="$BATS_TEST_TMPDIR/tmux"; mkdir -p "$FAKE_TMUX_DIR"
  codex_hooks_dialog >"$FAKE_TMUX_DIR/screen"
  id="$(new_task --backend tmux:codex)"
  cr dispatch "$id" >/dev/null
  cr watch --once --timeout 2 >/dev/null 2>&1 || true
  printf '› Ask Codex to do anything\n' >"$FAKE_TMUX_DIR/screen" # up, and no sign it took anything
  run cr watch --once --timeout 25
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: awaiting-input: the dialog cleared, but the agent did not confirm the brief; check: chartroom peek $id"* ]]
  [ -z "$(meta_of "$id" brief_pending)" ]
}

@test "herdr:codex dispatch: herdr reads the dialog as idle, so it is told from the screen; the watch delivers the brief" {
  export CHARTROOM_STALL_MINUTES=0
  use_fake herdr
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  codex_hooks_dialog >"$FAKE_HERDR_DIR/screen"
  id="$(new_task --backend herdr:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"herdr codex worker waiting at a startup dialog chartroom will not answer: answer it in herdr tab"*"the watch delivers its brief once it clears"* ]]
  refute grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
  [ "$(meta_of "$id" brief_pending)" = 1 ]
  run cr watch --once --timeout 5
  [[ "$output" == *'agent: awaiting-input: Codex "Hooks need review" dialog'* ]]
  refute grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
  printf '› Ask Codex to do anything\n%s\n' "Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md" >"$FAKE_HERDR_DIR/screen"
  run cr watch --once --timeout 3
  grep -q '^agent prompt' "$FAKE_HERDR_DIR/calls.log"
  [ -z "$(meta_of "$id" brief_pending)" ]
  events "$id" | grep -q 'note: the brief went in once the dialog cleared'
}

# ---------------------------------------------------------------- the stall watchdog

stall_fast() { export CHARTROOM_STALL_MINUTES=0.05 CHARTROOM_LOOK_INTERVAL=1; } # 3 s

@test "stall: a silent worker wakes once with its last output; output re-arms it; the state survives a restart" {
  stall_fast
  id="$(new_task --backend command --command 'echo first line; echo last line; sleep 60; echo end')"
  cr dispatch "$id" >/dev/null
  # one watch call that gives up before the stall is due: the next carries on from the same start
  run cr watch --once --timeout 1
  [ "$status" -eq 124 ]
  [ -s "$CHARTROOM_HOME/tasks/$id/.stall" ]
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == "[$id] [proj] stalled: no output or events for 0 min (a command is running, idle: "*"Last output: first line | last line" ]]
  events "$id" | grep -q 'note: stalled: no output or events for'
  # once per stall, restarts included
  run cr watch --once --timeout 6
  [ "$status" -eq 124 ]
  [ "$(grep -c 'note: stalled' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 1 ]
  # new output is a new chance to stall
  echo "more" >>"$CHARTROOM_HOME/tasks/$id/output.log"
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"stalled: no output or events for"*"more" ]]
  [ "$(grep -c 'note: stalled' "$CHARTROOM_HOME/tasks/$id/events.log")" -eq 2 ]
  stop_worker "$id"
}

@test "stall: a worker reporting or printing is not stalled" {
  stall_fast
  id="$(new_task --backend command --command 'sleep 60')"
  cr dispatch "$id" >/dev/null
  ( for i in 1 2 3 4 5 6; do "$CHARTROOM" event "$id" progress "step $i" 3>&-; sleep 1; done ) 3>&- &
  run cr watch --once --timeout 5
  [ "$status" -eq 124 ]
  wait $! || true
  id2="$(new_task --backend command --command 'for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 1; done; sleep 60')"
  cr dispatch "$id2" >/dev/null
  run cr watch --once --timeout 6
  [[ "$output" != *"$id2"* ]]
  stop_worker "$id2"
  stop_worker "$id"
}

@test "stall: a note is not a sign of life" {
  stall_fast
  id="$(new_task --backend command --command 'sleep 60')"
  cr dispatch "$id" >/dev/null
  ( for i in 1 2 3 4 5 6 7 8; do "$CHARTROOM" event "$id" note "bookkeeping $i" 3>&-; sleep 1; done ) 3>&- &
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"[$id] [proj] stalled: no output or events for"* ]]
  wait $! || true
  stop_worker "$id"
}

@test "stall: never for a task waiting, at a decision, or finished" {
  stall_fast
  # waiting by its own word
  a="$(new_task --backend command --command 'sleep 60')"
  cr dispatch "$a" >/dev/null; cr event "$a" waiting "CI on the branch until 2099-01-01T00:00:00Z"
  # a decision the XO has been told of
  b="$(new_task --backend command --command 'sleep 60')"
  cr dispatch "$b" >/dev/null; cr event "$b" decision "pick A or B"
  # finished, awaiting review
  c="$(new_task --backend command --command 'sleep 60')"
  cr dispatch "$c" >/dev/null; cr event "$c" done "finished"
  # the wakes of the reports themselves, then nothing more
  run cr watch --once --timeout 2
  run cr watch --once --timeout 6
  [ "$status" -eq 124 ]
  refute grep -l 'note: stalled' "$CHARTROOM_HOME/tasks/$a/events.log" "$CHARTROOM_HOME/tasks/$b/events.log" "$CHARTROOM_HOME/tasks/$c/events.log"
  for t in "$a" "$b" "$c"; do stop_worker "$t"; done
}

@test "stall: with the setting at 0 nothing looks" {
  export CHARTROOM_STALL_MINUTES=0
  d="$(new_task --backend command --command 'sleep 60')"
  cr dispatch "$d" >/dev/null
  run cr watch --once --timeout 5
  [ "$status" -eq 124 ]
  [ ! -e "$CHARTROOM_HOME/tasks/$d/.stall" ]
  stop_worker "$d"
}

@test "stall: never for a prompt the XO has been told of, nor a parked worker" {
  stall_fast
  core_up
  export FAKE_HC_NO_STATUS=1 FAKE_HC_NO_HOOK=1
  echo 'Working (1s • esc to interrupt)' >"$FAKE_HC_DIR/screen"
  e="$(new_task --backend hc:codex)"
  cr dispatch "$e" >/dev/null
  codex_approval >"$FAKE_HC_DIR/screen"
  set_term t1 '.title = "[ . ] Action Required | Review brief | repo"'
  run cr watch --once --timeout 5
  [[ "$output" == *"agent: awaiting-input"* ]]
  run cr watch --once --timeout 6
  [ "$status" -eq 124 ]
  refute grep -q 'note: stalled' "$CHARTROOM_HOME/tasks/$e/events.log"
  jq --arg t "$(date -u +%FT%TZ)" '.parked = $t' "$CHARTROOM_HOME/tasks/$e/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$e/meta.json"
  rm -f "$CHARTROOM_HOME/tasks/$e/.stall"
  run cr watch --once --timeout 3
  [ ! -e "$CHARTROOM_HOME/tasks/$e/.stall" ]
}

@test "stall: a command still using CPU is at work, up to the cap, which says so" {
  stall_fast
  export CHARTROOM_STALL_BUSY_MAX_MINUTES=0.2 # 12 s
  id="$(new_task --backend command --command 'end=$((SECONDS+40)); while ((SECONDS<end)); do :; done')"
  cr dispatch "$id" >/dev/null
  run cr watch --once --timeout 8
  [ "$status" -eq 124 ]
  run cr watch --once --timeout 12
  [ "$status" -eq 0 ]
  [[ "$output" == *"stalled: no output or events for 0 min (still using CPU: "* ]]
  stop_worker "$id"
}

@test "stall_tree: its tools count, the agent's own processes do not, and a shell there names the command" {
  source "$REPO_ROOT/lib/stuck.sh"
  export CHARTROOM_STALL_PS_FILE="$BATS_TEST_TMPDIR/ps"
  cat >"$CHARTROOM_STALL_PS_FILE" <<'EOF'
  100     1   0:00.01 bash /srv/x/tasks/t/launch.sh
  101   100   9:00.00 node /opt/homebrew/bin/codex -s workspace-write
  102   101   5:00.00 /opt/homebrew/lib/vendor/bin/codex -s workspace-write
  103   102   0:00.50 node mcp-server.js
  104   102   0:00.10 /bin/zsh -lc npm test
  105   104   1:02.00 node jest
  999     1  10:00.00 /bin/zsh -lc someone-elses
EOF
  [ "$(stall_tree 100 codex)" = $'6260\t/bin/zsh -lc npm test' ]
  # Linux's hh:mm:ss and dd-hh:mm:ss, with no agent to leave out
  cat >"$CHARTROOM_STALL_PS_FILE" <<'EOF'
  200     1 00:00:01 bash -c worker
  201   200 01:00:00 python train.py
  202   200 1-00:00:00 python other.py
EOF
  [ "$(stall_tree 200 "")" = $'9000000\t' ]
  [ "$(stall_tree 12345 codex)" = $'0\t' ]
}

@test "stall: hc: a ticking timer is no sign of life, real output is; it reads the screen for what it reports" {
  stall_fast
  core_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  ( for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      printf '● Ran the tests\n✻ Pondering… (%sm %ss · ↓ 1.2k tokens)\n  ⎿  Tip: %s\n───\n❯ \n───\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n' "$i" "$i" "$i" >"$FAKE_HC_DIR/screen"
      sleep 1
    done ) 3>&- &
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == "[$id] [proj] stalled: no output or events for 0 min. Last output: ● Ran the tests | ✻ Pondering…"* ]]
  [[ "$output" != *"shift+tab"* ]]
  wait $! || true
}

@test "stall: headless: its stream is its output" {
  stall_fast
  export FAKE_CODEX_SLEEP=30
  id="$(new_task --backend headless:codex)"
  cr dispatch "$id" >/dev/null
  run cr watch --once --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == "[$id] [proj] stalled: no output or events for"* ]]
  stop_worker "$id"
}

@test "stall: a bad setting is refused by the watch" {
  CHARTROOM_STALL_MINUTES=soon run cr watch --once --timeout 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHARTROOM_STALL_MINUTES and CHARTROOM_STALL_BUSY_MAX_MINUTES must be minutes"* ]]
}
