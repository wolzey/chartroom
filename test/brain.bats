#!/usr/bin/env bats
# Client homes (one brain, step 1; lib/brain.sh): a home whose every command runs on another
# machine, the brain, over ssh. The brain here is a second HOME on this machine, reached through
# the fake ssh's loopback mode, which runs the remote command in a real shell (zsh when there is
# one, as on a Mac) with that HOME, its own config and its own registered homes.

load test_helper

setup() {
  common_setup
  command -v rsync >/dev/null 2>&1 || skip "rsync is not installed"
  command -v perl >/dev/null 2>&1 || skip "perl is not installed"
  use_fake ssh
  export FAKE_SSH_DIR="$BATS_TEST_TMPDIR/ssh"; mkdir -p "$FAKE_SSH_DIR/studio"
  BH="$BATS_TEST_TMPDIR/brainhome"; mkdir -p "$BH/.config/chartroom"
  echo "$BH" >"$FAKE_SSH_DIR/studio/brain"
  # The brain's PATH: only this test's bin (never the real machine's hc or herdr).
  export CHARTROOM_RADAR_REMOTE_PATH="$BIN" CHARTROOM_BRAIN_BIN="$CHARTROOM"
  # The brain's login shell, whose PATH what the gate runs gets: this test's PATH plus a marker
  # (never the real machine's shell and rc files).
  printf '#!/bin/sh\nprintf "\\036%%s:/login-shell-bin\\036" "$PATH"\n' >"$BIN/loginsh"; chmod +x "$BIN/loginsh"
  export CHARTROOM_BRAIN_LOGIN_SHELL="$BIN/loginsh"
  BRAIN="$BH/chartroom/acme"
  brain_cr init --name acme >/dev/null
  cr brain link studio --as acme >/dev/null 2>&1
}

teardown() {
  brain_cr dashboard stop >/dev/null 2>&1 || true
  [[ -f "$CHARTROOM_HOME/.brain/tunnel" ]] && kill "$(cut -d' ' -f1 "$CHARTROOM_HOME/.brain/tunnel")" 2>/dev/null
  return 0
}

# Run something as the brain machine (its HOME, config and homes).
on_brain() { ( export HOME="$BH" CHARTROOM_CONFIG="$BH/.config/chartroom/config"; unset CHARTROOM_HOME; "$@" 3>&- ); }
brain_cr() { on_brain env CHARTROOM_HOME="$BRAIN" "$CHARTROOM" "$@"; }
# A task's record and events on the brain, wherever it lives there (a store task has no files).
brain_meta() { brain_cr store meta "$1" | jq -r "$2"; }
brain_events() { brain_cr store events "$1"; }
brain_set_meta() { ( export HOME="$BH" CHARTROOM_CONFIG="$BH/.config/chartroom/config" CHARTROOM_HOME="$BRAIN"; set_meta "$@" ); }
# A gate call by hand: a header line (JSON), then whatever follows on stdin.
gate() { on_brain "$CHARTROOM" brain gate; }
header() { jq -cn --arg verb "$1" --argjson x "${2:-"{}"}" '{v: 1, verb: $verb, home: "acme", client: {machine: "test"}} + $x'; }
calls() { cat "$FAKE_SSH_DIR/calls.log" 2>/dev/null; }
new_remote() { # a task made through the client; prints its id
  local id
  id="$(cr new --project "$PROJECT" --title "${TITLE:-remote task}" "$@" | sed -n 's/^id=//p')"
  printf '%s' "$id"
}

@test "every command of the dispatcher is classified for a client home" {
  local cmds c bad=""
  cmds="$(grep -E '^  [a-z|-]+\) "cmd_\$cmd" "\$@" ;;' "$CHARTROOM" | sed -E 's/^  ([^)]*)\).*/\1/' | tr '|' ' ')"
  [[ "$cmds" == *watch* && "$cmds" == *dispatch* ]]
  for c in $cmds install-skills ls show todo; do
    case "$(cr brain class "$c")" in forward|hybrid|local|refuse) ;; *) bad+=" $c" ;; esac
    grep -qE "^    [^)]*\\b$c\\b[^)]*\) echo (forward|hybrid|local|refuse)" "$REPO_ROOT/lib/brain.sh" || bad+=" $c(unlisted)"
  done
  [ -z "$bad" ] || { echo "unclassified:$bad"; false; }
}

@test "brain link makes an empty home a client: the key in its config, the brain's records copied at the same paths" {
  grep -qx 'CHARTROOM_BRAIN=studio' "$CHARTROOM_HOME/config"
  grep -qx 'CHARTROOM_BRAIN_HOME=acme' "$CHARTROOM_HOME/config"
  [ -f "$CHARTROOM_HOME/commander.md" ] && [ -f "$CHARTROOM_HOME/inbox.md" ]
  [ "$(cat "$CHARTROOM_HOME/.brain/path")" = "$(cd "$BRAIN" && pwd -P)" ]
  run cr brain status
  [ "$status" -eq 0 ]
  [[ "$output" == *"this home lives on the brain: studio (home acme there"* ]]
  [[ "$output" == *"contact:  ok"* ]]
  run cr homes
  [[ "$output" == *"lives on the brain studio"* ]] || [[ "$output" == *"no homes registered"* ]]
}

@test "brain link refuses a home with tasks, an unregistered name, and a brain home that is itself a client" {
  local h="$BATS_TEST_TMPDIR/full"
  mkdir -p "$h/tasks/old-1a2b"
  run env CHARTROOM_HOME="$h" "$CHARTROOM" brain link studio --as acme
  [ "$status" -ne 0 ]; [[ "$output" == *"has 1 task(s): moving them to the brain is the migration"* ]]
  [ ! -f "$h/config" ]
  h="$BATS_TEST_TMPDIR/other"
  run env CHARTROOM_HOME="$h" "$CHARTROOM" brain link studio --as nosuch
  [ "$status" -eq 76 ]; [[ "$output" == *"no home named nosuch is registered"* ]]
  [ ! -f "$h/config" ]
  on_brain env CHARTROOM_HOME="$BH/chartroom/loop" "$CHARTROOM" init --name loop >/dev/null
  echo "CHARTROOM_BRAIN=elsewhere" >>"$BH/chartroom/loop/config"
  run env CHARTROOM_HOME="$h" "$CHARTROOM" brain link studio --as loop
  [ "$status" -eq 76 ]; [[ "$output" == *"is itself a client of elsewhere; a brain never forwards"* ]]
}

@test "new runs on the brain and its brief is readable here at the same relative path" {
  local id; id="$(new_remote)"
  [ -n "$id" ]
  brain_meta "$id" .id >/dev/null
  [ -f "$CHARTROOM_HOME/tasks/$id/brief.md" ]
  cmp "$BRAIN/tasks/$id/brief.md" "$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr status
  [ "$status" -eq 0 ]; [[ "$output" == *"$id"* ]]
  grep -q "exec $CHARTROOM brain gate" "$FAKE_SSH_DIR/calls.log"
  # the shell line is constant: nothing the commander typed is on it
  ! grep -q 'remote task' "$FAKE_SSH_DIR/calls.log"
}

@test "arguments reach the brain exactly, whatever they hold, through zsh or bash" {
  local sh hostile big
  hostile=$'it\'s "quoted" $(touch /tmp/pwned-cr) `id` ; | & * ?[a] \\ ~ \n second line\ttab é → ✓'
  big="$(head -c 100000 /dev/zero | tr '\0' 'x')" # (Linux caps one argument at 128 KB)
  brain_cr init --name other >/dev/null 2>&1 || on_brain env CHARTROOM_HOME="$BH/chartroom/other" "$CHARTROOM" init --name other >/dev/null
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    export FAKE_SSH_SHELL="$(command -v "$sh")"
    run cr relay other "$hostile"
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$BH/chartroom/other/relays/inbox.ndjson" | jq -r .text)" = "$hostile" ]
    local id; TITLE="--title -x '\$HOME'" id="$(new_remote)"
    [ "$(brain_meta "$id" .title)" = "--title -x '\$HOME'" ]
    run cr event "$id" progress "$big"
    [ "$status" -eq 0 ]
    [ "$(brain_events "$id" | tail -1 | wc -c)" -gt 100000 ]
    run cr event "$id" progress ""
  done
  [ ! -e /tmp/pwned-cr ]
}

@test "an edit to the copy goes to the brain before the next command; CHARTROOM_HARNESS goes along" {
  local id; id="$(new_remote --backend subagent)"
  perl -0pi -e "s/(## Commander's intent\n\n)/\$1Please do the thing.\n/" "$CHARTROOM_HOME/tasks/$id/brief.md"
  ! grep -q 'Please do the thing' "$BRAIN/tasks/$id/brief.md"
  CHARTROOM_HARNESS=claude run cr dispatch "$id"
  [ "$status" -eq 0 ]
  grep -q 'Please do the thing' "$BRAIN/tasks/$id/brief.md"
  [ -n "$(brain_meta "$id" '.dispatched // empty')" ]
}

@test "a forwarded dispatch never starts a worker in the ssh session: headless and command are refused" {
  local id; id="$(new_remote --backend headless:claude)"
  perl -0pi -e "s/(## Commander's intent\n\n)/\$1Please do the thing.\n/" "$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"would start in the ssh session"* ]]
  [ -z "$(brain_meta "$id" '.dispatched // empty')" ]
}

@test "an edit that crosses a change on the brain stops the command and keeps both versions" {
  local id; id="$(new_remote)"
  echo "brain's line" >>"$BRAIN/tasks/$id/brief.md"
  echo "client's line" >>"$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr steer "$id" hello
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed on the brain before your edit reached it"* ]]
  [[ "$output" == *"nothing was run"* ]]
  ! brain_events "$id" | grep -q steered
  grep -q "client's line" "$CHARTROOM_HOME/tasks/$id/brief.md".client-conflict-*
  grep -q "brain's line" "$CHARTROOM_HOME/tasks/$id/brief.md"
  ! grep -q "client's line" "$BRAIN/tasks/$id/brief.md"
}

@test "an edit not yet sent survives a pull a wake makes, and goes up with the next command" {
  local id; id="$(new_remote)"
  echo "- an approval given in chat" >>"$CHARTROOM_HOME/inbox.md"
  mkdir -p "$CHARTROOM_HOME/drafts"; echo "a note" >"$CHARTROOM_HOME/drafts/x.md"
  "$CHARTROOM" watch --once >"$BATS_TEST_TMPDIR/w.out" 2>&1 3>&- &
  local wpid=$!
  sleep 2
  echo "brain line" >>"$BRAIN/inbox.md"     # the brain changes the same file meanwhile
  brain_cr event "$id" decision "look" >/dev/null
  wait "$wpid"
  grep -q 'decision: look' "$BATS_TEST_TMPDIR/w.out"
  grep -q 'an approval given in chat' "$CHARTROOM_HOME/inbox.md"   # not overwritten by the pull
  [ -f "$CHARTROOM_HOME/drafts/x.md" ]
  run cr status   # the next command sends them: the new file goes up, the crossed one conflicts
  [ "$status" -eq 1 ]; [[ "$output" == *"inbox.md changed on the brain"* ]]
  [ "$(cat "$BRAIN/drafts/x.md")" = "a note" ]
  grep -q 'an approval given in chat' "$CHARTROOM_HOME"/inbox.md.client-conflict-*
  run cr status
  [ "$status" -eq 0 ]
}

@test "a put leaves the copy clean: the same edit is never sent twice, nor taken for a conflict" {
  local id; id="$(new_remote)"
  echo "more intent" >>"$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr status; [ "$status" -eq 0 ]
  grep -q 'more intent' "$BRAIN/tasks/$id/brief.md"
  local before; before="$(ls -lT "$BRAIN/tasks/$id/brief.md" 2>/dev/null || stat -c '%y %s' "$BRAIN/tasks/$id/brief.md")"
  sleep 1
  run cr status; [ "$status" -eq 0 ]; [[ "$output" != *conflict* ]]
  [ "$(ls -lT "$BRAIN/tasks/$id/brief.md" 2>/dev/null || stat -c '%y %s' "$BRAIN/tasks/$id/brief.md")" = "$before" ] # no second put
  echo "and more" >>"$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr status; [ "$status" -eq 0 ]
  grep -q 'and more' "$BRAIN/tasks/$id/brief.md"
}

@test "brain link refuses a home with files of its own, and takes one made by init alone" {
  local h="$BATS_TEST_TMPDIR/notes"
  mkdir -p "$h"; echo "r-1 topic x" >"$h/rulings.log"
  run env CHARTROOM_HOME="$h" "$CHARTROOM" brain link studio --as acme
  [ "$status" -ne 0 ]; [[ "$output" == *"holds 1 file(s) of its own (rulings.log)"* ]]
  [ ! -f "$h/config" ] && [ "$(cat "$h/rulings.log")" = "r-1 topic x" ]
  h="$BATS_TEST_TMPDIR/fresh"
  CHARTROOM_HOME="$h" cr init >/dev/null
  rmdir "$h/tasks" "$h/worktrees"
  run env CHARTROOM_HOME="$h" "$CHARTROOM" brain link studio --as acme
  [ "$status" -eq 0 ]
}

@test "what the gate runs has the brain's login PATH, not the ssh session's" {
  run bash -c "printf '%s\n' \"\$1\" | HOME='$BH' CHARTROOM_CONFIG='$BH/.config/chartroom/config' CHARTROOM_HOME= '$CHARTROOM' brain gate 2>/dev/null" _ "$(header hello)"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .login_path <<<"$output")" == *":/login-shell-bin" ]]
}

@test "records chartroom owns are never taken from the copy" {
  local id before; id="$(new_remote)"
  before="$(snapshot "$BRAIN/tasks/$id")"
  echo '{"hacked": true}' >"$CHARTROOM_HOME/tasks/$id/meta.json"
  echo "x note: forged" >>"$CHARTROOM_HOME/tasks/$id/events.log"
  run cr status
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not take tasks/$id/meta.json"* ]]
  [ "$(snapshot "$BRAIN/tasks/$id")" = "$before" ]
  ls "$CHARTROOM_HOME/tasks/$id/" | grep -q 'meta.json.client-refused-'
  # the brain's record is back (a store task's record is in the brain's store: never in the copy)
  if [[ -f "$BRAIN/tasks/$id/meta.json" ]]; then jq -e '.id' "$CHARTROOM_HOME/tasks/$id/meta.json" >/dev/null
  else [ ! -e "$CHARTROOM_HOME/tasks/$id/meta.json" ]; fi
}

@test "the gate's put refuses paths out of the home, symlinks, and chartroom's own records" {
  local p
  ln -s /etc "$BRAIN/link"
  for p in ../escape config rulings.log relays/inbox.ndjson worktrees/x .watch-cursor link/passwd tasks/x/meta.json tasks/x/artifacts/a.md tasks/x/junk/deep.md; do
    run bash -c "{ printf '%s\n' \"\$1\"; echo data; } | HOME='$BH' CHARTROOM_CONFIG='$BH/.config/chartroom/config' CHARTROOM_HOME= '$CHARTROOM' brain gate" _ "$(header put "$(jq -cn --arg p "$p" '{path: $p, base: null}')")"
    [ "$status" -eq 76 ] || { echo "put $p: $status $output"; false; }
  done
  [ ! -e "$BH/escape" ]
  run bash -c "{ printf '%s\n' \"\$1\"; echo hello; } | HOME='$BH' CHARTROOM_CONFIG='$BH/.config/chartroom/config' CHARTROOM_HOME= '$CHARTROOM' brain gate" _ "$(header put '{"path": "drafts/note.md", "base": null}')"
  [ "$status" -eq 0 ]
  [ "$(cat "$BRAIN/drafts/note.md")" = hello ]
}

@test "a task's scratch never reaches the copy; brain fetch brings one file" {
  local id; id="$(new_remote)"
  mkdir -p "$BRAIN/tasks/$id/clone/node_modules"
  echo big >"$BRAIN/tasks/$id/clone/node_modules/x.js"
  echo pane >"$BRAIN/tasks/$id/pane.log"
  echo "# report" >"$BRAIN/tasks/$id/report.md"
  mkdir -p "$BRAIN/tasks/$id/artifacts"; echo art >"$BRAIN/tasks/$id/artifacts/a.md"
  run cr show "$id"
  [ "$status" -eq 0 ]
  [ -f "$CHARTROOM_HOME/tasks/$id/report.md" ]
  [ -f "$CHARTROOM_HOME/tasks/$id/artifacts/a.md" ]
  [ ! -e "$CHARTROOM_HOME/tasks/$id/clone" ]
  [ ! -e "$CHARTROOM_HOME/tasks/$id/pane.log" ]
  run cr brain fetch "tasks/$id/pane.log"
  [ "$status" -eq 0 ]
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/pane.log")" = pane ]
  run cr brain fetch config
  [ "$status" -eq 76 ]
  run cr status   # a fetched file is not an edit: never sent back
  [ "$status" -eq 0 ]; [[ "$output" != *refused* ]]
}

@test "exit codes pass through; an unreachable brain runs nothing (75); a cut call may have run (75)" {
  local id before; id="$(new_remote)"
  run cr show nosuch-0000
  [ "$status" -eq 1 ]; [[ "$output" == *"nosuch-0000"* ]]
  run cr watch --once --timeout 1
  [ "$status" -eq 124 ]
  touch "$FAKE_SSH_DIR/studio/down"
  before="$(snapshot "$BRAIN")"
  run cr steer "$id" hi
  [ "$status" -eq 75 ]
  [[ "$output" == *"the brain (studio) is unreachable"* && "$output" == *"nothing was run"* ]]
  [ "$(snapshot "$BRAIN")" = "$before" ]
  rm "$FAKE_SSH_DIR/studio/down"; touch "$FAKE_SSH_DIR/studio/drop-after-hello"
  run cr status
  [ "$status" -eq 75 ]
  [[ "$output" == *"may or may not have taken effect"* ]]
}

@test "join and hook are refused in a client home; local commands stay local" {
  run cr join --title x
  [ "$status" -ne 0 ]; [[ "$output" == *"join is refused in a client home"* ]]
  run cr hook claude-stop
  [ "$status" -ne 0 ]; [[ "$output" == *"hook is refused"* ]]
  touch "$FAKE_SSH_DIR/studio/down"
  run cr version
  [ "$status" -eq 0 ]; [[ "$output" == chartroom* ]]
}

@test "the gate refuses what a client may not run" {
  local a
  for a in '["homes","add","x"]' '["brain","gate"]' '["init","--name","x"]' '["join"]' '["hook","x"]' '["watch","--once"]' '["attach","x"]' '["install-skills"]' '["node","init"]'; do
    run bash -c "printf '%s\n' \"\$1\" | HOME='$BH' CHARTROOM_CONFIG='$BH/.config/chartroom/config' CHARTROOM_HOME= '$CHARTROOM' brain gate" _ "$(header exec "{\"argv\": $a}")"
    [ "$status" -eq 76 ] || { echo "$a: $status $output"; false; }
  done
  run bash -c "printf '%s\n' '{\"v\": 9, \"verb\": \"exec\", \"home\": \"acme\"}' | HOME='$BH' CHARTROOM_CONFIG='$BH/.config/chartroom/config' CHARTROOM_HOME= '$CHARTROOM' brain gate"
  [ "$status" -eq 76 ]; [[ "$output" == *"speaks protocol 1"* ]]
}

@test "watch --once pulls a wake's task before printing it, and acks it" {
  local id; id="$(new_remote)"
  cr watch --once >"$BATS_TEST_TMPDIR/w.out" 2>&1 3>&- &
  local wpid=$!
  sleep 2
  echo "# the plan" >"$BRAIN/tasks/$id/plan.md"
  brain_cr event "$id" decision "plan ready for approval" >/dev/null
  wait "$wpid"
  grep -q "\[$id\].*decision: plan ready for approval" "$BATS_TEST_TMPDIR/w.out"
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/plan.md")" = "# the plan" ]
  # acked: the next round does not replay it
  run cr watch --once --timeout 2
  [ "$status" -eq 124 ]
}

@test "a wake the client never acked is replayed; the gate's watch ends when its client goes" {
  local id out; id="$(new_remote)"
  run cr watch --once --timeout 1   # makes the cursor
  brain_cr event "$id" blocked "need a key" >/dev/null
  # a client that reads the wake and vanishes before its ack
  out="$({ header watch1; sleep 4; } | on_brain "$CHARTROOM" brain gate 2>/dev/null)" || true
  [[ "$out" == *"blocked: need a key"* ]]
  [[ "$out" != *committed* ]]
  run cr watch --once --timeout 5
  [ "$status" -eq 0 ]; [[ "$output" == *"blocked: need a key"* ]]
  # a watch with no wakes, whose client closes stdin: no watch is left behind
  ( header watch1 | on_brain "$CHARTROOM" brain gate >/dev/null 2>&1 ) &
  sleep 2
  ! pgrep -f "watch --once --cursor $(cd "$BRAIN" && pwd -P)/.watch-cursor.gate" >/dev/null
}

@test "a streaming watch on a client starts at the end of each log and prints what comes after" {
  local id; id="$(new_remote)"
  brain_cr event "$id" decision "old news" >/dev/null
  "$CHARTROOM" watch >"$BATS_TEST_TMPDIR/s.out" 2>&1 3>&- &
  local wpid=$!
  sleep 3
  brain_cr event "$id" blocked "fresh news" >/dev/null
  local i; for i in $(seq 1 50); do grep -q 'fresh news' "$BATS_TEST_TMPDIR/s.out" && break; sleep 0.2; done
  kill "$wpid"; wait "$wpid" 2>/dev/null || true
  grep -q "blocked: fresh news" "$BATS_TEST_TMPDIR/s.out"
  ! grep -q "old news" "$BATS_TEST_TMPDIR/s.out"
  ls "$BRAIN"/.watch-cursor.client-* >/dev/null
  # the client is gone, so the brain's side of its round ends too
  for i in $(seq 1 50); do pgrep -f "watch --once --cursor .*$(basename "$BH")" >/dev/null || break; sleep 0.2; done
  ! pgrep -f "watch --once --cursor .*$(basename "$BH")/chartroom/acme" >/dev/null
}

@test "watch --once while the brain is away: one wake after the outage, silence, then one when it is back" {
  export CHARTROOM_BRAIN_OUTAGE_SECONDS=1
  touch "$FAKE_SSH_DIR/studio/down"
  run cr watch --once
  [ "$status" -eq 0 ]
  [[ "$output" == "[brain] studio unreachable since "*"Operation timed out; this home lives there"* ]]
  [ "$(grep -c . <<<"$output")" -eq 1 ]
  run cr watch --once --timeout 3
  [ "$status" -eq 124 ]; [ -z "$output" ]
  rm "$FAKE_SSH_DIR/studio/down"
  run cr watch --once
  [ "$status" -eq 0 ]; [[ "$output" == "[brain] studio back after "* ]]
}

@test "attach: the brain prepares, this machine shows the worker through its hc link" {
  local id; id="$(new_remote --backend hc:claude)"
  brain_set_meta "$id" '.dispatched = "2026-01-01T00:00:00Z" | .hc_terminal = "t9"'
  run brain_cr attach "$id" --prepare
  [ "$status" -eq 0 ]; [ "$(jq -r .runner <<<"$output")" = hc ]; [ "$(jq -r .hc_terminal <<<"$output")" = t9 ]
  use_fake herdr-app
  export FAKE_HERDR_APP_DIR="$BATS_TEST_TMPDIR/app" CHARTROOM_BRAIN_HC_MACHINE=studio
  mkdir -p "$FAKE_HERDR_APP_DIR"
  echo '{"spaces": [{"id": "sp1", "name": "mine", "machine": null, "tabs": [{"id": "tb1", "name": "1", "terminals": [{"terminal": "t1"}]}]},
    {"id": "sp2", "name": "acme-crew", "machine": "studio", "tabs": [{"id": "tb2", "name": "9", "terminals": [{"terminal": "studio/t9"}]}]}]}' >"$FAKE_HERDR_APP_DIR/ls.json"
  echo tb1 >"$FAKE_HERDR_APP_DIR/shown"
  run cr attach "$id"
  [ "$status" -eq 0 ]; [[ "$output" == *"showing $id in Herdr (terminal t9 on studio)"* ]]
  grep -q 'do space.select --id sp2' "$FAKE_HERDR_APP_DIR/calls.log"
  [ "$(cat "$FAKE_HERDR_APP_DIR/shown")" = tb2 ]
  # a window that does not hold that terminal: a tab attached to it instead (the fake refuses
  # terminal.open, so with no terminal here attach says what to run)
  echo '{"spaces": []}' >"$FAKE_HERDR_APP_DIR/ls.json"
  run cr attach "$id"
  [ "$status" -ne 0 ]; [[ "$output" == *"hc attach studio/t9"* ]]
  grep -q 'do terminal.open' "$FAKE_HERDR_APP_DIR/calls.log"
  unset FAKE_HERDR_APP_DIR CHARTROOM_BRAIN_HC_MACHINE
  run cr attach "$id"
  [ "$status" -ne 0 ]; [[ "$output" == *"ssh -t studio hc attach t9"* ]]
}

@test "dashboard open: the brain's dashboard through a tunnel, opened here; stop leaves the brain's up" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
  local bp
  bp="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  echo "CHARTROOM_DASHBOARD_PORT=$bp" >>"$BRAIN/config"
  printf '#!/usr/bin/env bash\necho "$1" >>%q\n' "$BATS_TEST_TMPDIR/opened" >"$BIN/opener"; chmod +x "$BIN/opener"
  export CHARTROOM_OPENER="$BIN/opener" CHARTROOM_BRAIN_TUNNEL_WAIT=0
  run cr dashboard open
  [ "$status" -eq 0 ]
  [[ "$output" == *"the brain's dashboard, through a tunnel"* ]]
  # the brain's port is taken on this (shared) test machine, so the tunnel takes the next free one
  grep -q "studio tunnel $((bp + 1)):127.0.0.1:$bp" "$FAKE_SSH_DIR/calls.log"
  grep -q "^http://127.0.0.1:$((bp + 1))/" "$BATS_TEST_TMPDIR/opened"
  run brain_cr dashboard status
  [ "$status" -eq 0 ]
  run cr dashboard stop
  [[ "$output" == *"stopped the tunnel"* ]]
  run brain_cr dashboard status
  [ "$status" -eq 0 ]
}

@test "artifacts: copy to this clipboard, export here, add a local page with its image" {
  local id f; id="$(new_remote)"
  printf 'send this\n' | brain_cr artifact add "$id" --kind message --title "Hello there" - >/dev/null
  printf '#!/usr/bin/env bash\ncat >%q\n' "$BATS_TEST_TMPDIR/clip" >"$BIN/clip"; chmod +x "$BIN/clip"
  CHARTROOM_CLIPBOARD="$BIN/clip" run cr artifact copy "${id: -4}/hello-there"
  [ "$status" -eq 0 ]; [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "send this" ]
  mkdir -p "$BATS_TEST_TMPDIR/out"
  run cr artifact export "${id: -4}/hello-there" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]; [ "$(cat "$BATS_TEST_TMPDIR/out/hello-there.md")" = "send this" ]
  f="$BATS_TEST_TMPDIR/page"; mkdir -p "$f"
  printf '\x89PNG\r\n\x1a\nfake' >"$f/dot.png"
  printf '<h1>Findings</h1><img src="dot.png">\n' >"$f/page.html"
  run cr artifact add "$id" --kind page --title "Findings page" "$f/page.html"
  [ "$status" -eq 0 ]
  grep -q 'data:image/png;base64' "$BRAIN/tasks/$id/artifacts/findings-page.html"
  [ -f "$CHARTROOM_HOME/tasks/$id/artifacts/findings-page.html" ]
}

@test "--all-homes from a client home is the brain's view; doctor names the brain" {
  new_remote >/dev/null
  run cr status --all-homes --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].home' <<<"$output")" = acme ]
  run cr doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"client:   this home lives on the brain: studio (home acme there"* ]]
  [[ "$output" == *"home:     $(cd "$BRAIN" && pwd -P)"* || "$output" == *"home:     $BRAIN"* ]]
  [ "$(cr doctor --json 2>/dev/null | jq -r .client.brain)" = studio ]
}

@test "brain git reads a task's worktree on the brain, read-only" {
  local id; id="$(new_remote)"
  brain_cr worktree "$id" >/dev/null
  run cr brain git "$id" log --oneline -1
  [ "$status" -eq 0 ]; [[ "$output" == *init* ]]
  run cr brain git "$id" diff --output=/tmp/x
  [ "$status" -eq 76 ]
  run cr brain git "$id" commit -m x
  [ "$status" -eq 76 ]
}

@test "unlink makes the home local again and leaves the copy; the radar does not count a client home" {
  local id; id="$(new_remote)"
  cr homes add here >/dev/null
  run cr radar --json
  [ "$status" -eq 0 ]
  run cr brain unlink
  [ "$status" -eq 0 ]
  ! grep -q CHARTROOM_BRAIN "$CHARTROOM_HOME/config"
  [ -f "$CHARTROOM_HOME/tasks/$id/brief.md" ]
  touch "$FAKE_SSH_DIR/studio/down"
  run cr version
  [ "$status" -eq 0 ]
}
