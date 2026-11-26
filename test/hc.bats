#!/usr/bin/env bats
# The hc runner (herdr-core terminals shown in the Herdr app), driven by the fake hc and
# herdr-app (test/fakes). The fake core is a listening socket where its lock file says, as
# doctor looks for one before it runs any hc command (every one would start a core).

load test_helper
setup() {
  common_setup
  use_fake hc herdr-app claude
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc" FAKE_HERDR_APP_DIR="$BATS_TEST_TMPDIR/app"
  mkdir -p "$FAKE_HC_DIR" "$FAKE_HERDR_APP_DIR"
}
teardown() {
  [[ -f "$BATS_TEST_TMPDIR/core.pid" ]] && kill "$(cat "$BATS_TEST_TMPDIR/core.pid")" 2>/dev/null
  [[ -n "${CORE_DIR:-}" ]] && rm -rf "$CORE_DIR"
  return 0
}

# A listening socket (a short path: socket paths are limited to ~100 bytes) in the core's lock file.
core_up() {
  local d="$XDG_STATE_HOME/herdr-core/default" i
  CORE_DIR="$(mktemp -d /tmp/crhc.XXXXXX)"; SOCK="$CORE_DIR/s"
  mkdir -p "$d"; printf '%s\n' "$SOCK" >"$d/core.lock"
  perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die "$!"; while (my $c = $s->accept) { close $c }' "$SOCK" 3>&- &
  echo $! >"$BATS_TEST_TMPDIR/core.pid"
  for i in $(seq 1 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  return 1
}
hc_calls() { cat "$FAKE_HC_DIR/calls.log"; }
# A negative check that fails the test (bats ignores a bare `! cmd` before the last line).
refute() { if "$@"; then echo "expected to fail: $*" >&2; return 1; fi; }
app_calls() { cat "$FAKE_HERDR_APP_DIR/calls.log" 2>/dev/null || true; }
term() { jq -r "$2" "$FAKE_HC_DIR/terms/$1.json"; }
set_term() { local t="$1" f; shift; f="$FAKE_HC_DIR/terms/$t.json"; jq "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
brief_sig() {
  local b="$CHARTROOM_HOME/tasks/$1"
  printf '%s' "Read the brief at $b/brief.md and follow it exactly. Your task id is $1." | (source "$REPO_ROOT/lib/core.sh"; text_sig)
}
# `watch --once` in the background; runs <change> once it has taken its first look.
watch_after() { # <change...>
  cr watch --once --timeout 8 >"$BATS_TEST_TMPDIR/wake" 2>&1 &
  local w=$!; sleep 1.5; "$@"; wait "$w" || true
}

@test "hc doctor: available only with a live core socket, not merely hc on PATH; first in the order" {
  rm -f "$BIN/hc"
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:claude").reason' <<<"$output")" = "hc (herdr-core) not on PATH" ]
  use_fake hc
  run cr doctor --json
  [[ "$(jq -r '.backends[]|select(.backend=="hc:claude").reason' <<<"$output")" == "herdr-core not running (no live socket"* ]]
  # a socket file nothing listens on (a crashed core's) is not a running core either
  mkdir -p "$XDG_STATE_HOME/herdr-core/default"; echo "$BATS_TEST_TMPDIR/dead.sock" >"$XDG_STATE_HOME/herdr-core/default/core.lock"
  : >"$BATS_TEST_TMPDIR/dead.sock"
  run cr doctor --json
  [[ "$(jq -r '.backends[]|select(.backend=="hc:codex").reason' <<<"$output")" == "herdr-core not running (no live socket at $BATS_TEST_TMPDIR/dead.sock"* ]]
  # none of that ran hc, which would have started a core
  [ ! -s "$FAKE_HC_DIR/calls.log" ]
  core_up
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:claude").available' <<<"$output")" = true ]
  [ "$(jq -r '.backends[]|select(.backend=="hc:claude").steering' <<<"$output")" = live ]
  [ "$(jq -r '.order[0]' <<<"$output")" = hc:claude ]
  [ "$(jq -r .auto <<<"$output")" = hc:claude ]
  [ "$(hc_calls | sort -u)" = "server status --json" ]
  # without claude, hc:claude is out and the order falls through
  rm -f "$BIN/claude"
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:claude").reason' <<<"$output")" = "claude not on PATH" ]
}

@test "hc:claude: one labelled terminal per task, the brief as run's task, named in the app, never space.new" {
  core_up
  id="$(new_task --backend hc:claude)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc claude worker running (space chartroom-crew, tab "*" · stub task, terminal t1)"* ]]
  wt="$(meta_of "$id" worktree)"; sp="$(meta_of "$id" hc_space)"; tb="$(meta_of "$id" hc_tab)"
  [ "$(meta_of "$id" hc_terminal)" = t1 ]
  [[ "$sp" =~ ^sp[0-9a-f]{32}$ && "$tb" =~ ^tb[0-9a-f]{32}$ ]]
  hc_calls | grep -qF -- "run --bg --json --no-parent --no-notify --name $id --cwd $wt --label herdr.space=$sp --label herdr.tab=$tb --label chartroom.workspace=chartroom-crew --label chartroom.task=$id -- "
  # the launcher carries chartroom's env and hands its own argument (the brief's line) to claude
  [ "$(term t1 '.argv[1]')" = "$CHARTROOM_HOME/tasks/$id/launch.sh" ]
  [ "$(term t1 '.argv[2]')" = "Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md and follow it exactly. Your task id is $id." ]
  l="$CHARTROOM_HOME/tasks/$id/launch.sh"
  grep -q "CHARTROOM_TASK=$id" "$l"
  grep -qF -- "--settings $CHARTROOM_HOME/tasks/$id/claude-settings.json \"\$@\"" "$l"
  [ "$(jq -c '.hooks|keys' "$CHARTROOM_HOME/tasks/$id/claude-settings.json")" = '["PermissionDenied","PermissionRequest","PreToolUse","UserPromptSubmit"]' ]
  events "$id" | grep -q "agent: prompt-received sig=$(brief_sig "$id") len="
  events "$id" | grep -q "note: hc: new space $sp for chartroom-crew"
  refute grep -q '^send' "$FAKE_HC_DIR/calls.log"
  # named through the app, which already showed both
  app_calls | grep -qxF "do space.rename --id $sp --name chartroom-crew"
  app_calls | grep -qF "do tab.rename --id $tb --name "
  refute grep -q 'space.new' "$FAKE_HERDR_APP_DIR/calls.log"
  [ "$(herdr-app ls | jq -r --arg s "$sp" '.spaces[]|select(.id==$s)|.name')" = chartroom-crew ]
  # a second task joins the same space (found from the first one's labels) with its own tab
  id2="$(new_task --backend hc:claude)"
  cr dispatch "$id2" >/dev/null
  [ "$(meta_of "$id2" hc_space)" = "$sp" ]
  [ "$(meta_of "$id2" hc_tab)" != "$tb" ]
  [ "$(app_calls | grep -c 'space.rename')" -eq 1 ]
  [ "$(herdr-app ls | jq -r --arg s "$sp" '[.spaces[]|select(.id==$s)|.tabs[]]|length')" -eq 2 ]
  run cr status --json
  [ "$(jq -r --arg i "$id" '.[]|select(.id==$i).live' <<<"$output")" = done ]
  run cr show "$id" --json
  [[ "$output" == *"hc terminal t1 (Herdr)"* ]]
  # steer, peek, stop
  run cr steer "$id" "rebase on main, then rerun the tests"
  [ "$status" -eq 0 ]
  [ "$output" = "delivered (the agent received the full text)" ]
  hc_calls | grep -qxF "send t1 --json rebase on main, then rerun the tests"
  run cr peek "$id"
  [[ "$output" == *"== terminal (recent)"* ]]
  cr stop "$id" >/dev/null
  hc_calls | grep -qx "interrupt t1 --json"
  events "$id" | grep -q "note: hc interrupt: stopped"
  # close: the screen kept, the terminal ended and removed (the app drops its tab)
  run cr close "$id"
  [ "$status" -eq 0 ]
  hc_calls | grep -qx "kill t1"
  hc_calls | grep -qx "rm t1"
  [ -f "$CHARTROOM_HOME/tasks/$id/pane.log" ]
  [ ! -f "$FAKE_HC_DIR/terms/t1.json" ]
  [ "$(herdr-app ls | jq -r --arg t "$tb" '[.spaces[].tabs[]|select(.id==$t)]|length')" -eq 0 ]
}

@test "hc: with the window closed the labels place the worker; attach names it later" {
  core_up
  unset FAKE_HERDR_APP_DIR
  id="$(new_task --backend hc:claude)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  events "$id" | grep -q "note: hc: no Herdr window answers; the labels place the worker in chartroom-crew"
  events "$id" | grep -q "agent: prompt-received sig=$(brief_sig "$id")"
  sp="$(meta_of "$id" hc_space)"
  # a second worker finds the space from hc's labels alone
  id2="$(new_task --backend hc:claude)"
  cr dispatch "$id2" >/dev/null
  [ "$(meta_of "$id2" hc_space)" = "$sp" ]
  # no window and no terminal to attach in: how to get there
  run cr attach "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Herdr window answers"*"hc attach t1"* ]]
  # the window opens: attach names the space and the tab, then shows the worker
  export FAKE_HERDR_APP_DIR="$BATS_TEST_TMPDIR/app"
  run cr attach "$id"
  [ "$status" -eq 0 ]
  app_calls | grep -qxF "do space.rename --id $sp --name chartroom-crew"
  app_calls | grep -qF "do tab.rename --id $(meta_of "$id" hc_tab) --name "
  app_calls | grep -qx "do agent.focus --terminal t1"
}

@test "hc: a space already named for the workspace is used as it is" {
  core_up
  echo '[{"id": "sp-crew", "name": "chartroom-crew"}]' >"$FAKE_HERDR_APP_DIR/spaces.json"
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  [ "$(meta_of "$id" hc_space)" = sp-crew ]
  hc_calls | grep -qF -- "--label herdr.space=sp-crew "
  refute grep -q 'space.rename' "$FAKE_HERDR_APP_DIR/calls.log"
  refute bash -c 'grep -q "new space" <<<"$1"' _ "$(events "$id")"
}

@test "hc steer: a fragment is retried, a blocked agent is never typed into" {
  core_up
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  FAKE_HC_DROP=5 run cr steer "$id" "use the staging database for this run"
  [ "$status" -eq 0 ]
  [ "$output" = "delivered (the agent received the full text)" ]
  events "$id" | grep -q "note: delivery mismatch: the agent received other text (sig=[0-9a-f]* len=32; expected sig=[0-9a-f]* len=37)"
  hc_calls | grep -qx "keys t1 ctrl+u"
  # an XO inside an hc terminal: chartroom sends as itself, so hc adds no <hc from=...> tag
  HC_TERMINAL_ID=t99 run cr steer "$id" "from inside Herdr"
  [ "$status" -eq 0 ]
  [ "$output" = "delivered (the agent received the full text)" ]
  # more text than was sent (hc's tag) is not a fragment: never sent twice
  : >"$FAKE_HC_DIR/calls.log"
  FAKE_HC_WRAP=1 run cr steer "$id" "run the migration once"
  [ "$status" -eq 0 ]
  [[ "$output" == "submitted, not verified"* ]]
  [ "$(grep -c '^send' "$FAKE_HC_DIR/calls.log")" -eq 1 ]
  events "$id" | grep -q "note: delivery unverified: the agent received a longer text (sig=[0-9a-f]* len=41; expected sig=[0-9a-f]* len=22); not sent again"
  set_term t1 '.status.state = "blocked"'
  : >"$FAKE_HC_DIR/calls.log"
  run cr steer "$id" "carry on"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked at a dialog"*"chartroom attach $id"* ]]
  refute grep -q -- "--force" "$FAKE_HC_DIR/calls.log"
  [ "$(cr status --json | jq -r '.[0].state')" = awaiting-input ]
}

@test "hc:codex: --no-daemon and notify; the brief taken but unverified, by hc or by the screen" {
  use_fake codex
  core_up
  export FAKE_HC_NO_HOOK=1
  id="$(new_task --backend hc:codex)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc codex worker running"* ]]
  l="$CHARTROOM_HOME/tasks/$id/launch.sh"
  grep -qF -- "-s danger-full-access" "$l"
  grep -qF -- "--no-daemon \"\$@\"" "$l"
  eval "args=( $(sed -n 4p "$l") )"
  printf '%s\n' "${args[@]}" | grep -qxF "notify=[\"$CHARTROOM\",\"hook\",\"$id\",\"codex-notify\"]"
  events "$id" | grep -q "note: the agent took a prompt, but its text could not be checked (codex has no prompt hook)"
  run cr steer "$id" "next"
  [ "$status" -eq 0 ]
  [[ "$output" == "submitted, not verified"* ]]
  # a turn end comes from codex's notify, not from hc (no second wake)
  watch_after bash -c 'f="$1"; jq ".status.state = \"idle\" | .turn += 1" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; "$2" hook "$3" codex-notify "{\"type\":\"agent-turn-complete\"}"' _ \
    "$FAKE_HC_DIR/terms/t1.json" "$CHARTROOM" "$id"
  [ "$(grep -c "^\[$id\]" "$BATS_TEST_TMPDIR/wake")" -eq 1 ]
  grep -q "agent: turn-ended (stopped its turn without reporting)" "$BATS_TEST_TMPDIR/wake"
  # an agent hc sees no state from: its working screen shows it took the brief
  echo "Working (3s • esc to interrupt)" >"$FAKE_HC_DIR/screen"
  id2="$(new_task --backend hc:codex)"
  FAKE_HC_NO_STATUS=1 run cr dispatch "$id2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc codex worker running"* ]]
  [ "$(cr status --json | jq -r --arg i "$id2" '.[]|select(.id==$i).live')" = working ]
}

# agy's folder trust dialog, as agy 1.5.17 draws it (verified in hc 0.1.21).
agy_trust() {
  printf 'Accessing workspace:\n\n%s\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit\n\n  ↑/↓ Navigate · enter Confirm\n                                        auto · Gemini 4 Neon · high\n' "$1" >"$FAKE_HC_DIR/screen"
}

@test "hc:agy: the brief as agy -i past its trust dialog; live steer, peek, stop and close" {
  use_fake agy
  core_up
  export FAKE_HC_NO_HOOK=1 # (agy gets no prompt hook: hc reads its state itself)
  id="$(new_task --backend hc:agy --model gemini-fake-high)"
  agy_trust "/some/worktree"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc agy worker running"* ]]
  # agy's own argv: its model, the task folder by its real path, and -i before the brief's line
  l="$CHARTROOM_HOME/tasks/$id/launch.sh"
  grep -qF -- "--model gemini-fake-high --add-dir $(cd "$CHARTROOM_HOME/tasks/$id" && pwd -P) -i \"\$@\"" "$l"
  refute grep -q -- "--settings\|notify=\|--no-daemon" "$l"
  # its one chartroom hook, the pattern kill guard, in the task folder's .agents (never the worktree)
  jq -e --arg c "hook $id guard" '."chartroom-guard".PreToolUse[0] | .matcher == "run_command" and (.hooks[0].command | endswith($c))' \
    "$CHARTROOM_HOME/tasks/$id/.agents/hooks.json"
  [ "$(term t1 '.argv[2]')" = "Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md and follow it exactly. Your task id is $id." ]
  # the trust dialog of its own worktree: Enter on "> Yes, I trust this folder", never Down
  hc_calls | grep -qx "keys t1 enter"
  refute grep -qx "keys t1 down" "$FAKE_HC_DIR/calls.log"
  events "$id" | grep -q "note: accepted workspace trust for its own worktree"
  events "$id" | grep -q "note: the agent took a prompt, but its text could not be checked (agy has no prompt hook)"
  [ "$(cr status --json | jq -r '.[0].live')" = done ]
  # steer types into it live: taken, not checked against its text
  run cr steer "$id" "also list the tests folder"
  [ "$status" -eq 0 ]
  [[ "$output" == "submitted, not verified"*"agy: no prompt hook"* ]]
  hc_calls | grep -qxF "send t1 --json also list the tests folder"
  run cr peek "$id"
  [[ "$output" == *"== terminal (recent)"* ]]
  cr stop "$id" >/dev/null
  hc_calls | grep -qx "interrupt t1 --json"
  run cr close "$id"
  [ "$status" -eq 0 ]
  hc_calls | grep -qx "kill t1"
  hc_calls | grep -qx "rm t1"
  [ ! -f "$FAKE_HC_DIR/terms/t1.json" ]
}

@test "hc:agy watch: a prompt wakes with agy's own words and is never typed into; a turn ended unreported wakes; never parked" {
  use_fake agy
  core_up
  export FAKE_HC_NO_HOOK=1
  id="$(new_task --backend hc:agy)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  [ "$(cr status --json | jq -r '.[0].live')" = working ]
  # blocked at an approval: hc carries agy's kind and words, and the XO is woken with them
  watch_after set_term t1 '.status = {app: "antigravity", state: "blocked", kind: "permission", msg: "Approve Edit: Write: /w/report.md"}'
  grep -q "^\[$id\] .*awaiting-input: hc: agy is waiting on a permission: Approve Edit: Write: /w/report.md" "$BATS_TEST_TMPDIR/wake"
  [ "$(cr status --json | jq -r '.[0].state')" = awaiting-input ]
  # a steer then is refused, and hc is never asked to type through the dialog
  : >"$FAKE_HC_DIR/calls.log"
  run cr steer "$id" "carry on"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked at a dialog"*"chartroom attach $id"* ]]
  refute grep -q -- "--force" "$FAKE_HC_DIR/calls.log"
  # answered (working again), then the turn ends with no report from the worker
  set_term t1 '.status = {app: "antigravity", state: "working"}'
  watch_after set_term t1 '.status = {app: "antigravity", state: "done"} | .turn += 1'
  grep -q "^\[$id\] .*hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  # at rest, it is still never parked: chartroom cannot resume an agy session
  run cr park "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only hc:claude workers can be parked"* ]]
}

@test "hc:agy on a device: its prompts and unreported turns become the log lines the brain's watch wakes on" {
  use_fake agy
  core_up
  export FAKE_HC_NO_HOOK=1
  id="$(new_task --backend hc:agy)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  log="$CHARTROOM_HOME/tasks/$id/events.log"
  # only in a guest home: on the brain its own watch looks
  run cr node agy-look
  [ "$status" -ne 0 ]
  export CHARTROOM_GUEST=1
  cr node agy-look # (the first look only notes where it is)
  refute grep -q " agent: " "$log"
  set_term t1 '.status = {app: "antigravity", state: "blocked", kind: "permission", msg: "Run this command? ls -la"}'
  cr node agy-look
  cr node agy-look # (once per prompt, not per look)
  [ "$(grep -c " agent: awaiting-input: hc: agy is waiting on a permission: Run this command? ls -la$" "$log")" = 1 ]
  set_term t1 '.status = {app: "antigravity", state: "working"}'
  cr node agy-look
  set_term t1 '.status = {app: "antigravity", state: "done"} | .turn += 1'
  cr node agy-look
  [ "$(grep -c " agent: turn-ended$" "$log")" = 1 ]
  # a turn that ends after the worker reported is not news
  set_term t1 '.status = {app: "antigravity", state: "working"}'
  cr node agy-look
  cr event "$id" done "Listed the docs"
  set_term t1 '.status = {app: "antigravity", state: "done"} | .turn += 1'
  cr node agy-look
  [ "$(grep -c " agent: turn-ended$" "$log")" = 1 ]
  # and the brain's watch wakes on these lines, as they arrive relayed: the prompt with agy's words,
  # the unreported turn (and the worker's own done, which is news anyway)
  unset CHARTROOM_GUEST
  watch_after true
  grep -q "^\[$id\] .*agent: awaiting-input: hc: agy is waiting on a permission: Run this command? ls -la$" "$BATS_TEST_TMPDIR/wake"
  grep -q "^\[$id\] .*agent: turn-ended (stopped its turn without reporting)$" "$BATS_TEST_TMPDIR/wake"
}

@test "hc:agy: not signed in, or not a session runner, it never starts; doctor says why and what agy lacks" {
  use_fake agy
  core_up
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:agy").available' <<<"$output")" = true ]
  [ "$(jq -r '.backends[]|select(.backend=="herdr:agy").reason' <<<"$output")" = "herdr not on PATH" ]
  [ "$(jq -r '.agents.agy.version' <<<"$output")" = "1.5.17-fake" ]
  [ "$(jq -r '.agents.agy.signed_in' <<<"$output")" = true ]
  [[ "$(jq -r '.agents.agy.limits' <<<"$output")" == *"no permission cards"*"never parked"* ]]
  run cr doctor
  [[ "$output" == *"agy:      1.5.17-fake at $BIN/agy, signed in; runs as hc:agy, herdr:agy, node"* ]]
  # signed out: doctor says so, and a dispatch refuses before it starts a terminal
  FAKE_AGY_SIGNED_OUT=1 run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:agy").available' <<<"$output")" = false ]
  [[ "$(jq -r '.backends[]|select(.backend=="hc:agy").reason' <<<"$output")" == "agy is not signed in here"* ]]
  id="$(new_task --backend hc:agy)"
  : >"$FAKE_HC_DIR/calls.log"
  FAKE_AGY_SIGNED_OUT=1 run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agy is not signed in here (run agy once in a terminal and finish its Google sign-in)"* ]]
  refute grep -q "^run" "$FAKE_HC_DIR/calls.log"
  # never headless, tmux or cmux
  for b in headless:agy tmux:agy cmux:agy; do
    run cr new --project "$PROJECT" --title x --backend "$b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"agy runs only as a full session"* ]]
  done
  # gone from PATH: said so
  rm -f "$BIN/agy"
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:agy").reason' <<<"$output")" = "agy not on PATH" ]
  [ "$(jq -r '.agents.agy.path' <<<"$output")" = null ]
}

@test "hc:agy from an ssh session (a client home's command): its sign-in is asked in the hc core; with none, a Mac says it cannot tell" {
  use_fake agy
  core_up
  export FAKE_AGY_KEYCHAIN_CLOSED=1 # signed in, but this session cannot read the keychain
  SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22" run cr doctor --json
  [ "$(jq -r '.agents.agy.signed_in' <<<"$output")" = true ]
  [ "$(jq -r '.backends[]|select(.backend=="hc:agy").available' <<<"$output")" = true ]
  grep -q "^exec .*agy models" "$FAKE_HC_DIR/calls.log"
  CHARTROOM_GATE=1 run cr doctor --json
  [ "$(jq -r '.agents.agy.signed_in' <<<"$output")" = true ]
  # signed out for real: the core says so too
  FAKE_AGY_SIGNED_OUT=1 SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22" run cr doctor --json
  [[ "$(jq -r '.agents.agy.why' <<<"$output")" == "agy is not signed in here"* ]]
  # no core answering: a Mac cannot tell from an ssh session, and says so instead of "not signed in"
  kill "$(cat "$BATS_TEST_TMPDIR/core.pid")"; rm -f "$BATS_TEST_TMPDIR/core.pid" "$SOCK"
  printf '#!/bin/sh\necho Darwin\n' >"$BIN/uname"; chmod +x "$BIN/uname"
  SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22" run cr doctor --json
  [ "$(jq -r '.agents.agy.signed_in' <<<"$output")" = false ]
  [[ "$(jq -r '.agents.agy.why' <<<"$output")" == "agy's sign-in cannot be read from an ssh session (macOS keeps the login keychain closed there)"* ]]
  # elsewhere (no keychain), it is asked in the session itself
  printf '#!/bin/sh\necho Linux\n' >"$BIN/uname"
  unset FAKE_AGY_KEYCHAIN_CLOSED
  SSH_CONNECTION="192.0.2.1 50000 192.0.2.2 22" run cr doctor --json
  [ "$(jq -r '.agents.agy.signed_in' <<<"$output")" = true ]
}

@test "hc:grok: only when named; the brief as its first prompt with --trust; a guard outside the worktree for chartroom's workers alone; steer, peek, stop, close" {
  use_fake grok
  core_up
  export FAKE_HC_NO_HOOK=1 # (grok gets no prompt hook: hc reads its state itself)
  # never picked on its own: no default order names it, so a machine with grok alone picks nothing
  rm -f "$BIN/claude"
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:grok").available' <<<"$output")" = true ]
  [ "$(jq -r '.order | map(select(endswith(":grok"))) | length' <<<"$output")" = 0 ]
  [ "$(jq -r .auto <<<"$output")" = null ]
  [ "$(jq -r '.agents.grok.automatic' <<<"$output")" = false ]
  use_fake claude
  id="$(new_task --backend hc:grok --model grok-fake)"
  cr set "$id" effort=high permission=acceptEdits >/dev/null
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc grok worker running"* ]]
  # grok's own argv: model, effort, mode, --trust (its own worktree), the task folder by its real path, then the brief
  l="$CHARTROOM_HOME/tasks/$id/launch.sh"
  grep -qF -- "-m grok-fake --reasoning-effort high --permission-mode acceptEdits --trust --add-dir $(cd "$CHARTROOM_HOME/tasks/$id" && pwd -P) \"\$@\"" "$l"
  refute grep -q -- "--settings\|notify=\|--no-daemon\| -i " "$l"
  [ "$(term t1 '.argv[2]')" = "Read the brief at $CHARTROOM_HOME/tasks/$id/brief.md and follow it exactly. Your task id is $id." ]
  events "$id" | grep -q "note: the agent took a prompt, but its text could not be checked (grok has no prompt hook)"
  # the guard: one file in grok's own hooks folder, nothing in the worktree
  g="$HOME/.grok/hooks/chartroom-guard.json"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$g")" = run_terminal_command ]
  refute ls -A "$(meta_of "$id" worktree)/.grok" 2>/dev/null
  c="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$g")"
  kill_call='{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"pkill -f node"}}'
  # in chartroom's worker (the launcher exports CHARTROOM_TASK) a pattern kill is denied, in grok's words
  out="$(CHARTROOM_TASK="$id" sh -c "$c" <<<"$kill_call")"
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" = deny ]
  events "$id" | grep -q "note: blocked a pattern kill: pkill -f node"
  [ -z "$(CHARTROOM_TASK="$id" sh -c "$c" <<<'{"toolName":"run_terminal_command","toolInput":{"command":"kill 4242"}}')" ]
  # the commander's own grok sessions (no CHARTROOM_TASK) are untouched
  [ -z "$(env -u CHARTROOM_TASK sh -c "$c" <<<"$kill_call")" ]
  # steer types into it live, taken but not checked against its text
  run cr steer "$id" "also list the tests folder"
  [ "$status" -eq 0 ]
  [[ "$output" == "submitted, not verified"*"grok: no prompt hook"* ]]
  hc_calls | grep -qxF "send t1 --json also list the tests folder"
  run cr peek "$id"
  [[ "$output" == *"== terminal (recent)"* ]]
  cr stop "$id" >/dev/null
  hc_calls | grep -qx "interrupt t1 --json"
  run cr close "$id"
  [ "$status" -eq 0 ]
  hc_calls | grep -qx "kill t1"
  [ ! -f "$FAKE_HC_DIR/terms/t1.json" ]
}

@test "hc:grok: its prompts wake with grok's words and are never typed into; signed out it never starts; never headless; doctor says why" {
  use_fake grok
  core_up
  export FAKE_HC_NO_HOOK=1
  run cr doctor
  [[ "$output" == *"grok:     1.0.92-fake (fake) at $BIN/grok, signed in; runs as hc:grok, herdr:grok, node"*"only when a task names it"*"no permission cards"*"never parked"* ]]
  id="$(new_task --backend hc:grok)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  # blocked at an approval: hc carries grok's kind and words, and the XO is woken with them
  watch_after set_term t1 '.status = {app: "grok", state: "blocked", kind: "permission", msg: "Run ls -la?"}'
  grep -q "^\[$id\] .*awaiting-input: hc: grok is waiting on a permission: Run ls -la?" "$BATS_TEST_TMPDIR/wake"
  : >"$FAKE_HC_DIR/calls.log"
  run cr steer "$id" "carry on"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked at a dialog"*"chartroom attach $id"* ]]
  refute grep -q "^send" "$FAKE_HC_DIR/calls.log"
  # answered, then the turn ends with no report: that wakes too
  set_term t1 '.status = {app: "grok", state: "working"}'
  watch_after set_term t1 '.status = {app: "grok", state: "done"} | .turn += 1'
  grep -q "^\[$id\] .*hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  # signed out: doctor says what to run, and a dispatch refuses before any terminal (grok would open a browser sign-in)
  FAKE_GROK_SIGNED_OUT=1 run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:grok").available' <<<"$output")" = false ]
  [ "$(jq -r '.agents.grok.why' <<<"$output")" = "grok is not signed in here (run grok login in a terminal on this machine and finish the browser sign-in (over ssh: grok login --device-auth))" ]
  id2="$(new_task --backend hc:grok)"
  : >"$FAKE_HC_DIR/calls.log"
  FAKE_GROK_SIGNED_OUT=1 run cr dispatch "$id2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"grok is not signed in here"* ]]
  refute grep -q "^run" "$FAKE_HC_DIR/calls.log"
  # never headless, tmux or cmux
  for b in headless:grok tmux:grok cmux:grok; do
    run cr new --project "$PROJECT" --title x --backend "$b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"grok runs only as a full session"* ]]
  done
  rm -f "$BIN/grok"
  run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="hc:grok").reason' <<<"$output")" = "grok not on PATH" ]
  [ "$(jq -r '.agents.grok.path' <<<"$output")" = null ]
}

@test "default order: every agent's full sessions before any headless run, so codex without claude runs in hc" {
  use_fake codex
  rm -f "$BIN/claude"
  core_up
  run cr doctor --json
  [ "$(jq -r '.order|join(" ")' <<<"$output")" = "hc:claude hc:codex hc:agy herdr:claude herdr:codex herdr:agy cmux:claude cmux:codex tmux:claude tmux:codex headless:codex headless:claude command" ]
  [ "$(jq -r .auto <<<"$output")" = hc:codex ]
  id="$(new_task)"
  FAKE_HC_NO_HOOK=1 run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" backend)" = hc:codex ]
  [[ "$output" == *"hc codex worker running"* ]]
  # (the legacy `codex` name on an old record still reads as it always did)
  id2="$(new_task --backend codex)"
  [ "$(meta_of "$id2" backend)" = headless:codex ]
}

@test "hc: a trust dialog is answered only for chartroom's own worktree" {
  core_up
  trust() { printf ' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n' >"$FAKE_HC_DIR/screen"; }
  trust
  id="$(new_task --backend hc:claude)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  hc_calls | grep -qx "keys t1 down"
  hc_calls | grep -qx "keys t1 enter"
  events "$id" | grep -q "note: accepted workspace trust for its own worktree"
  # the brief, held behind the dialog, went in once it was answered
  events "$id" | grep -q "agent: prompt-received sig=$(brief_sig "$id")"
  # a folder chartroom did not make: no keys, a wake, and the worker left waiting with its brief
  trust
  id2="$(new_task --backend hc:claude)"
  cr worktree "$id2" >/dev/null
  set_meta "$id2" '.worktree_created="0"'
  : >"$FAKE_HC_DIR/calls.log"
  run cr dispatch "$id2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting at a startup dialog chartroom will not answer: answer it in Herdr (chartroom attach $id2)"* ]]
  refute grep -q "^keys" "$FAKE_HC_DIR/calls.log"
  events "$id2" | grep -q "agent: awaiting-input: trust dialog for a folder chartroom did not create"
  [ "$(meta_of "$id2" hc_launched)" = 1 ]
  [ "$(cr status --json | jq -r --arg i "$id2" '.[]|select(.id==$i).state')" = awaiting-input ]
}

@test "hc: a live terminal of the task's name is ended only when it is this task's stale start" {
  core_up
  id="$(new_task --backend hc:claude)"
  mkdir -p "$FAKE_HC_DIR/terms"; echo 9 >"$FAKE_HC_DIR/n"
  jq -n --arg n "$id" --arg l "$CHARTROOM_HOME/tasks/$id/launch.sh" '{address: "t9", name: $n, argv: ["bash", $l], state: "live", status: {state: "idle"}, turn: 0, labels: {}}' >"$FAKE_HC_DIR/terms/t9.json"
  # recorded for this task by a start that never finished: ended, then a fresh start
  set_meta "$id" '.hc_terminal="t9"'
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  hc_calls | grep -qx "kill t9"
  hc_calls | grep -qx "rm t9"
  events "$id" | grep -q "note: ended the stale hc terminal t9 left by an earlier start (idle)"
  [ "$(meta_of "$id" hc_terminal)" = t10 ]
  # a launched worker is never ended by a re-dispatch
  : >"$FAKE_HC_DIR/calls.log"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the worker for $id is live in hc terminal t10"* ]]
  refute grep -q "^kill" "$FAKE_HC_DIR/calls.log"
  # nor is a same-named terminal chartroom did not record for the task
  id2="$(new_task --backend hc:claude)"
  jq -n --arg n "$id2" '{address: "t8", name: $n, state: "live", status: null, turn: 0, labels: {}}' >"$FAKE_HC_DIR/terms/t8.json"
  run cr dispatch "$id2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"an hc terminal named $id2 (t8) already runs, which chartroom did not record"* ]]
  refute grep -q "^kill" "$FAKE_HC_DIR/calls.log"
  refute grep -q "^run" "$FAKE_HC_DIR/calls.log"
}

@test "hc watch: blocked, a turn ended without a report (seen or between looks), lost; quiet after a report" {
  core_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  [ "$(cr status --json | jq -r '.[0].live')" = working ]
  watch_after set_term t1 '.status.state = "idle"'
  grep -q "^\[$id\] .*hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  watch_after set_term t1 '.status.state = "blocked"'
  grep -q "^\[$id\] .*hc: agent is waiting on an approval or question prompt" "$BATS_TEST_TMPDIR/wake"
  # a whole turn between two looks (idle before and after, the turn count moved) still wakes
  set_term t1 '.status.state = "idle"'
  watch_after set_term t1 '.turn += 1'
  grep -q "hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  # after the worker reported, a turn ending is not news
  cr event "$id" waiting "CI on the branch until 2099-01-01T00:00:00Z"
  watch_after set_term t1 '.turn += 1'
  refute grep -q "stopped its turn" "$BATS_TEST_TMPDIR/wake"
  # the terminal vanishing is
  watch_after rm -f "$FAKE_HC_DIR/terms/t1.json"
  grep -q "^\[$id\] .*lost: hc terminal t1 is no longer running" "$BATS_TEST_TMPDIR/wake"
  [ "$(cr status --json | jq -r '.[0].live')" = gone ]
}

@test "hc watch --once: what changed while nobody watched wakes the next call, once" {
  core_up
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  # The cursor has never seen the task (new writes it first): it starts from no state, as a task
  # dispatched mid-stream does, so a prompt it is already blocked on wakes, once.
  set_term t1 '.status.state = "blocked"'
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == "[$id] [proj] "*" agent: awaiting-input: hc: agent is waiting on an approval or question prompt" ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  grep -qx "@state:$id"$'\t'"blocked"$'\t'"1" "$CHARTROOM_HOME/.watch-cursor"
  # each change lands between two calls
  set_term t1 '.status.state = "working"'
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  set_term t1 '.status.state = "idle"'
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]
  [ "$output" = "[$id] [proj] hc: agent stopped its turn without reporting" ]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # a whole turn (idle before and after, the turn count moved)
  set_term t1 '.turn += 1'
  run cr watch --once --timeout 5
  [ "$output" = "[$id] [proj] hc: agent stopped its turn without reporting" ]
  set_term t1 '.status.state = "blocked"'
  run cr watch --once --timeout 5
  [[ "$output" == "[$id] [proj] "*" agent: awaiting-input: hc: agent is waiting on an approval or question prompt" ]]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # a cursor from before it kept agent state (no @state lines) starts from the state now: a
  # turn that ended before this call is not replayed
  grep -v '^@state:' "$CHARTROOM_HOME/.watch-cursor" >"$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$CHARTROOM_HOME/.watch-cursor"
  set_term t1 '.status.state = "idle" | .turn += 1'
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  rm -f "$FAKE_HC_DIR/terms/t1.json"
  run cr watch --once --timeout 5
  [ "$output" = "[$id] [proj] lost: hc terminal t1 is no longer running" ]
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
}

@test "hc watch: an agent that exited on its own wakes once, from the launcher's exited event" {
  core_up
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  watch_after bash -c 'printf "%s exited: agent session ended (exit 0)\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$1"; f="$2"; jq ".state = \"finished\"" "$f" >"$f.tmp" && mv "$f.tmp" "$f"' _ \
    "$(log_of "$id")" "$FAKE_HC_DIR/terms/t1.json"
  grep -q "exited: agent session ended" "$BATS_TEST_TMPDIR/wake"
  refute grep -q "lost:" "$BATS_TEST_TMPDIR/wake"
  [ "$(cr status --json | jq -r '.[0].live')" = stopped ]
}

@test "hc: an agent hc replaced with a shell (its program lost) is lost, not working" {
  core_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  # hc's keep (on for every terminal the app adopts) puts the user's shell in place of a lost
  # program: same address, same name, still live, no status
  watch_after set_term t1 '.argv = ["/bin/zsh"] | .status = null'
  grep -q "^\[$id\] .*lost: the agent in hc terminal t1 is gone (hc put a shell in its place); chartroom close $id ends it" "$BATS_TEST_TMPDIR/wake"
  [ "$(cr status --json | jq -r '.[0].live')" = gone ]
  run cr steer "$id" "are you there"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the hc terminal for $id is gone; re-dispatch it"* ]]
  refute grep -q "^send" "$FAKE_HC_DIR/calls.log"
  # dispatching again ends the shell and starts afresh
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  hc_calls | grep -qx "kill t1"
  events "$id" | grep -q "note: ended the stale hc terminal t1 left by an earlier start (a shell in place of its lost agent)"
  [ "$(meta_of "$id" hc_terminal)" = t2 ]
  # the launcher's path spelled another way (a symlinked home) is still this task's own
  set_term t2 --arg l "/elsewhere/tasks/$id/launch.sh" '.argv = ["bash", $l, "Read the brief"]'
  [ "$(cr status --json | jq -r '.[0].live')" = done ]
  # close ends a replaced terminal too
  set_term t2 '.argv = ["/bin/zsh"] | .status = null'
  cr close "$id" >/dev/null
  hc_calls | grep -qx "kill t2"
  hc_calls | grep -qx "rm t2"
}

# ---- the watch's hc event stream (FAKE_HC_EVENTS: the fake's `hc events`)
stream_up() { export FAKE_HC_EVENTS=1 CHARTROOM_WATCH_HC_INTERVAL=30; }
# One of hc's event lines for <terminal>, its term file changed first by <jq> so `hc get` agrees.
hc_event() { # <terminal> <type> <data json> [jq update of the term file]
  local n; n=$(( $(cat "$FAKE_HC_DIR/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE_HC_DIR/seq"
  [[ -z "${4:-}" ]] || set_term "$1" "$4"
  jq -cn --arg t "$1" --arg ty "$2" --argjson d "$3" --argjson s "$n" \
    '{jsonrpc: "2.0", method: "event", params: {data: $d, seq: $s, terminal: $t, type: $ty}}' >>"$FAKE_HC_DIR/events.ndjson"
}
# Claude Code ending a turn: the status leaves working, then hc counts the turn.
turn_ends() {
  hc_event t1 status '{"status":{"app":"claude-code","state":"done"}}' '.status = {app: "claude-code", state: "done"}'
  hc_event t1 turn "$(jq -c '{state: "done", turn: (.turn + 1)}' "$FAKE_HC_DIR/terms/t1.json")" '.turn += 1'
}
# hc's keep putting a shell in place of a lost agent: lost, then restarted with the shell's argv.
agent_replaced() {
  hc_event t1 status '{"status":null}' '.status = null'
  hc_event t1 lost '{"exit_code":null,"finished_ms":null,"reason":"signaled","signal":9}'
  set_term t1 '.argv = ["/bin/zsh", "-l"]'
  hc_event t1 restarted "$(cat "$FAKE_HC_DIR/terms/t1.json")"
}
wakes() { grep -c . "$BATS_TEST_TMPDIR/wake" || true; }

@test "hc events: a turn ended without a report, a prompt and a replaced agent wake from the stream, once each, with no hc get" {
  core_up; stream_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  : >"$FAKE_HC_DIR/calls.log"
  watch_after turn_ends
  grep -qx "\[$id\] \[proj\] hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  [ "$(wakes)" -eq 1 ]
  hc_calls | grep -q "^events --json --label chartroom.workspace=chartroom-crew"
  refute grep -q '^get' "$FAKE_HC_DIR/calls.log"
  # the next call starts from its cursor and the stream's snapshot: the same turn is not news again
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
  # a prompt waiting for an answer (awaiting input)
  watch_after hc_event t1 status '{"status":{"app":"claude-code","kind":"permission","state":"blocked"}}' '.status = {app: "claude-code", state: "blocked"}'
  grep -qE "^\[$id\] \[proj\] [^ ]+ agent: awaiting-input: hc: agent is waiting on an approval or question prompt$" "$BATS_TEST_TMPDIR/wake"
  [ "$(wakes)" -eq 1 ]
  # lost, then a shell in its place: one wake, as replaced (lost alone is held for what follows)
  watch_after agent_replaced
  grep -qx "\[$id\] \[proj\] lost: the agent in hc terminal t1 is gone (hc put a shell in its place); chartroom close $id ends it" "$BATS_TEST_TMPDIR/wake"
  [ "$(wakes)" -eq 1 ]
  refute grep -q '^get' "$FAKE_HC_DIR/calls.log"
}

@test "hc events: a terminal that vanishes with no event at all is lost by the slow round's own look" {
  core_up; stream_up
  export CHARTROOM_WATCH_HC_INTERVAL=3
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  watch_after rm -f "$FAKE_HC_DIR/terms/t1.json"
  grep -qx "\[$id\] \[proj\] lost: hc terminal t1 is no longer running" "$BATS_TEST_TMPDIR/wake"
  [ "$(wakes)" -eq 1 ]
}

@test "hc events: when the stream ends the watch asks hc at once and every round, then takes the stream back" {
  core_up; stream_up
  id="$(new_task --backend hc:claude)"
  FAKE_HC_STATUS=working cr dispatch "$id" >/dev/null
  : >"$FAKE_HC_DIR/calls.log"
  # (chartroom itself, not the cr function, so kill reaches the watch and not a subshell)
  "$CHARTROOM" watch >"$BATS_TEST_TMPDIR/wake" 2>&1 3>&- &
  local w=$! i
  sleep 1.5
  refute grep -q '^get' "$FAKE_HC_DIR/calls.log"
  # the core goes away: the stream ends, and a new one cannot start yet
  touch "$FAKE_HC_DIR/events.off"; echo EOF >>"$FAKE_HC_DIR/events.ndjson"
  for i in $(seq 1 20); do grep -q '^get t1' "$FAKE_HC_DIR/calls.log" && break; sleep 0.1; done
  grep -q '^get t1' "$FAKE_HC_DIR/calls.log"
  # a change with no event at all is seen by polling
  set_term t1 '.status.state = "idle"'
  for i in $(seq 1 30); do grep -q "stopped its turn" "$BATS_TEST_TMPDIR/wake" && break; sleep 0.1; done
  grep -qx "\[$id\] \[proj\] hc: agent stopped its turn without reporting" "$BATS_TEST_TMPDIR/wake"
  # the stream can start again: the watch takes it back (its retries back off from 1 s) and
  # stops asking
  : >"$FAKE_HC_DIR/calls.log"; rm -f "$FAKE_HC_DIR/events.off"
  for i in $(seq 1 100); do grep -q '^events' "$FAKE_HC_DIR/calls.log" && break; sleep 0.1; done
  grep -q '^events' "$FAKE_HC_DIR/calls.log"
  sleep 1; : >"$FAKE_HC_DIR/calls.log"
  hc_event t1 status '{"status":{"app":"claude-code","state":"blocked"}}' '.status = {app: "claude-code", state: "blocked"}'
  for i in $(seq 1 30); do grep -q "waiting on an approval" "$BATS_TEST_TMPDIR/wake" && break; sleep 0.1; done
  # a watch that is killed takes its stream with it
  kill "$w"; wait "$w" || true
  for i in $(seq 1 20); do pgrep -f "$BIN/hc events" >/dev/null || break; sleep 0.1; done
  refute pgrep -f "$BIN/hc events"
  grep -qE "^\[$id\] \[proj\] [^ ]+ agent: awaiting-input: hc: agent is waiting on an approval or question prompt$" "$BATS_TEST_TMPDIR/wake"
  refute grep -q '^get' "$FAKE_HC_DIR/calls.log"
  [ "$(wakes)" -eq 2 ]
}

@test "hc events: a terminal already gone when the stream starts is asked about once; a waiting window running out between slow rounds wakes on time" {
  core_up; stream_up
  export CHARTROOM_WAITING_GRACE_MINUTES=0
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  other="$(TITLE="other task" new_task --backend hc:claude)"
  cr dispatch "$other" >/dev/null
  rm -f "$FAKE_HC_DIR/terms/t2.json"
  : >"$FAKE_HC_DIR/calls.log"
  local u; TZ=UTC printf -v u '%(%Y-%m-%dT%H:%M:%SZ)T' $((EPOCHSECONDS + 4))
  cr event "$id" waiting "CI on the branch until $u"
  run cr watch --once --timeout 15
  [ "$status" -eq 0 ]
  [[ "$output" == "[$id] [proj] waiting overdue: CI on the branch until $u (since "* ]]
  # the stream carries t1, so hc was asked only about t2, once, and never again
  [ "$(grep -c '^get' "$FAKE_HC_DIR/calls.log")" -eq 1 ]
  grep -qx 'get t2 --json' "$FAKE_HC_DIR/calls.log"
}
