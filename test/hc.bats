#!/usr/bin/env bats
# The hc runner (herdr-core terminals shown in the Herdr app), driven by the fake hc and
# herdr-app (test/fakes). The fake core is a listening socket where its lock file says, as
# doctor looks for one before it runs any hc command (every one would start a core).

load test_helper
setup() {
  common_setup
  case "${OSTYPE:-}" in msys*|cygwin*) skip "hc is unverified on Git Bash (its guard: windows.bats)" ;; esac
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
  [ "$(jq -c '.hooks|keys' "$CHARTROOM_HOME/tasks/$id/claude-settings.json")" = '["UserPromptSubmit"]' ]
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
  refute grep -q "new space" "$CHARTROOM_HOME/tasks/$id/events.log"
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
  jq '.worktree_created="0"' "$CHARTROOM_HOME/tasks/$id2/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id2/meta.json"
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
  jq '.hc_terminal="t9"' "$CHARTROOM_HOME/tasks/$id/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id/meta.json"
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

@test "hc watch: an agent that exited on its own wakes once, from the launcher's exited event" {
  core_up
  id="$(new_task --backend hc:claude)"
  cr dispatch "$id" >/dev/null
  watch_after bash -c 'printf "%s exited: agent session ended (exit 0)\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$1"; f="$2"; jq ".state = \"finished\"" "$f" >"$f.tmp" && mv "$f.tmp" "$f"' _ \
    "$CHARTROOM_HOME/tasks/$id/events.log" "$FAKE_HC_DIR/terms/t1.json"
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
