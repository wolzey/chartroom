#!/usr/bin/env bats
# Windows code paths (Git Bash = msys, WSL), exercised on macOS/Linux by forcing
# CHARTROOM_PLATFORM and putting fakes for the Windows tools on PATH: cygpath, cmd, taskkill,
# powershell.exe, wslview and a CRLF-writing jq.exe. On Windows the whole suite runs for real.

load test_helper

setup() {
  case "${OSTYPE:-}" in msys*|cygwin*) skip "emulates Windows elsewhere; on Windows the suite runs for real" ;; esac
  common_setup
  PY="$(type -P python3 || true)"
}

teardown() { cr dashboard stop >/dev/null 2>&1 || true; }

msys() { export CHARTROOM_PLATFORM=msys; use_fake cygpath cmd taskkill powershell.exe; }
need_python() { [[ -n "$PY" ]] || skip "python3 not available"; link_tool "$PY" python3; }
get() { curl -s --max-time 10 "$@"; }

@test "platform: posix adds nothing to doctor; CHARTROOM_PLATFORM overrides and is checked" {
  run cr doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq 'has("platform") or has("notes")' <<<"$output")" = false ]
  run cr doctor
  [[ "$output" != *"platform:"* && "$output" != *"note:"* ]]
  CHARTROOM_PLATFORM=wsl run cr doctor
  [[ "$output" == *"platform: Windows Subsystem for Linux (wsl)"* ]]
  [[ "$output" == *"note: WSL: install the agents (claude, codex) inside WSL"* ]]
  CHARTROOM_PLATFORM=dos run cr doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHARTROOM_PLATFORM must be posix, wsl or msys (got dos)"* ]]
}

@test "msys: a native jq.exe's CRLF output is turned off with --binary" {
  REAL_JQ="$(readlink "$BIN/jq")"; export REAL_JQ
  rm "$BIN/jq"; ln -s "$REPO_ROOT/test/fakes/jq-crlf" "$BIN/jq"
  [ "$(jq -n 1)" = $'1\r' ]
  # without the guard every captured value keeps a CR: the project path no longer exists
  CHARTROOM_PLATFORM=posix
  export CHARTROOM_PLATFORM
  id="$(new_task)"
  run cr worktree "$id"
  [ "$status" -ne 0 ]
  # with it, the same steps work and nothing chartroom prints carries a CR
  msys
  id="$(new_task)"
  run cr worktree "$id"
  [ "$status" -eq 0 ]
  git -C "$PROJECT" rev-parse --verify --quiet "chartroom/$id"
  run cr status --json
  [[ "$output" != *$'\r'* ]]
  [ "$("$REAL_JQ" -r --arg i "$id" '.[] | select(.id == $i) | .kind' <<<"$output")" = ship ]
  run cr doctor
  [[ "$output" == *"note: jq runs with --binary (a native jq.exe would otherwise write CRLF)"* ]]
}

@test "msys: jq gets --arg values as written and file operands as Windows paths" {
  REAL_JQ="$(readlink "$BIN/jq")"; export REAL_JQ FAKE_JQ_LOG="$BATS_TEST_TMPDIR/jq.log"
  rm "$BIN/jq"; ln -s "$REPO_ROOT/test/fakes/jq-crlf" "$BIN/jq"
  msys
  id="$(new_task)"
  [ "$("$REAL_JQ" -r .project "$CHARTROOM_HOME/tasks/$id/meta.json")" = "$PROJECT" ]
  # every call runs with MSYS's argument conversion off (but the CRLF probe, which has none)...
  [ -z "$(grep -v '^\*|' "$FAKE_JQ_LOG" | grep -vx '|-b -n 1')" ]
  # ...a path-looking --arg value (the project) reaches jq untouched, never through cygpath...
  grep -qF -- "--arg project $PROJECT " "$FAKE_JQ_LOG"
  [ -z "$(grep '^cygpath' "$FAKE_LOG" | grep -F -- "$PROJECT")" ]
  # ...and a file operand goes through cygpath -m
  grep -qF -- "cygpath -m -- $CHARTROOM_HOME/tasks/$id/meta.json" "$FAKE_LOG"
}

@test "config: a CRLF config file (saved by a Windows editor) gives clean values" {
  printf 'CHARTROOM_WORKSPACE=fleet\r\nCHARTROOM_BRANCH_PREFIX="win/"\r\n' >"$CHARTROOM_CONFIG"
  id="$(new_task)"
  [ "$(meta_of "$id" branch)" = "win/$id" ]
}

@test "msys: a Windows-form CHARTROOM_HOME is used in its /c/ form" {
  msys
  CHARTROOM_HOME='C:\chartroom\home' run cr doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .home <<<"$output")" = /c/chartroom/home ]
  CHARTROOM_HOME='D:/fleet' run cr doctor --json
  [ "$(jq -r .home <<<"$output")" = /d/fleet ]
}

@test "msys: herdr is off unless opted in; headless:claude steers between runs" {
  msys
  use_fake herdr claude
  run cr doctor --json
  [ "$(jq -r '.platform' <<<"$output")" = msys ]
  [ "$(jq -r '.backends[]|select(.backend=="herdr:claude").reason' <<<"$output")" = "herdr on Windows is unverified (CHARTROOM_HERDR_ANY_OS=1 to try it)" ]
  [ "$(jq -r '.backends[]|select(.backend=="headless:claude").steering' <<<"$output")" = between-runs ]
  [[ "$(jq -r '.notes[0]' <<<"$output")" == "Git Bash: herdr, cmux and tmux sessions are unavailable"* ]]
  CHARTROOM_HERDR_ANY_OS=1 run cr doctor --json
  [[ "$(jq -r '.backends[]|select(.backend=="herdr:claude").reason' <<<"$output")" == "herdr server not reachable"* ]]
  CHARTROOM_PLATFORM=posix run cr doctor --json
  [ "$(jq -r '.backends[]|select(.backend=="headless:claude").steering' <<<"$output")" = live ]
}

@test "msys: install-skills links with junctions, re-runs, and uninstalls through rmdir" {
  msys
  run cr install-skills --dir "$HOME/skills"
  [ "$status" -eq 0 ]
  [[ "$output" == *"link $HOME/skills/chartroom -> $REPO_ROOT/skills/chartroom"* ]]
  grep -q "cmd //c mklink //J $HOME/skills/chartroom $REPO_ROOT/skills/chartroom" "$FAKE_LOG"
  [ -f "$HOME/skills/chartroom/SKILL.md" ]
  run cr install-skills --dir "$HOME/skills"
  [[ "$output" == *"ok   $HOME/skills/chartroom"* ]]
  run cr install-skills --dir "$HOME/skills" --uninstall
  [[ "$output" == *"removed $HOME/skills/chartroom"* ]]
  grep -q "cmd //c rmdir $HOME/skills/chartroom" "$FAKE_LOG"
  [ ! -e "$HOME/skills/chartroom" ]
  [ -f "$REPO_ROOT/skills/chartroom/SKILL.md" ]
}

@test "msys: where no junction can be made, skills are marked copies that refresh and uninstall" {
  msys
  export FAKE_JUNCTION_FAIL=1
  run cr install-skills --dir "$HOME/skills"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copy $HOME/skills/chartroom <- $REPO_ROOT/skills/chartroom (links are unavailable here"* ]]
  [ ! -L "$HOME/skills/chartroom" ]
  [ "$(cat "$HOME/skills/chartroom/.chartroom-copy")" = "$REPO_ROOT/skills/chartroom" ]
  echo stale >"$HOME/skills/chartroom/SKILL.md"
  run cr install-skills --dir "$HOME/skills"
  [[ "$output" == *"refresh $HOME/skills/chartroom (a copy of $REPO_ROOT/skills/chartroom)"* ]]
  cmp "$HOME/skills/chartroom/SKILL.md" "$REPO_ROOT/skills/chartroom/SKILL.md"
  # a directory chartroom did not copy is never touched
  rm -rf "$HOME/skills/bearings"; mkdir "$HOME/skills/bearings"
  run cr install-skills --dir "$HOME/skills" --uninstall
  [[ "$output" == *"removed $HOME/skills/chartroom"* ]]
  [[ "$output" == *"skip $HOME/skills/bearings (not a chartroom link)"* ]]
  [ ! -e "$HOME/skills/chartroom" ]
  [ -d "$HOME/skills/bearings" ]
}

@test "install.sh: where ln -s copies, it writes a launcher, rewrites it, and refuses other files" {
  src="$BATS_TEST_TMPDIR/src"
  git clone -q --no-local "$REPO_ROOT" "$src"
  git -C "$src" checkout -q -B main
  export CHARTROOM_REPO="$src" CHARTROOM_REF=main
  ln -sf "$REPO_ROOT/test/fakes/ln-copy" "$BIN/ln"
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote launcher $HOME/.local/bin/chartroom (symlinks are unavailable here)"* ]]
  [ ! -L "$HOME/.local/bin/chartroom" ]
  grep -qx '# chartroom launcher, written by install.sh' "$HOME/.local/bin/chartroom"
  run "$HOME/.local/bin/chartroom" version
  [ "$status" -eq 0 ]; [[ "$output" == "chartroom "* ]]
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updating"*"wrote launcher"* ]]
  echo 'echo mine' >"$HOME/.local/bin/chartroom"
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exists and is not a symlink; not replacing it"* ]]
}

@test "msys: headless:claude reads a pipe, not a FIFO, and takes steering between runs" {
  msys
  use_fake claude
  export FAKE_TURN=3
  id="$(new_task --backend headless:claude)"
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"steering: between-runs"* ]]
  d="$CHARTROOM_HOME/tasks/$id"; sid="$(meta_of "$id" session_id)"
  [ ! -e "$d/stdin.fifo" ]
  grep -q "cygpath -m $d" "$FAKE_LOG"
  run cr steer "$id" "too early"
  [ "$status" -ne 0 ]
  [[ "$output" == *"takes input only between runs"* ]]
  wait_event "$id" ' exited: claude process ended' 30
  [ "$(cat "$d/final.md")" = "fake result" ]
  grep -q '"content":"Read the brief at '"$d"'/brief.md' "$d/claude.jsonl"
  FAKE_TURN=0 run cr steer "$id" "after exit"
  [ "$status" -eq 0 ]
  [[ "$output" == "delivered (resumed session $sid)" ]]
  for i in $(seq 1 60); do [ "$(grep -c ' exited: ' "$d/events.log")" -ge 2 ] && break; sleep 0.25; done
  [ "$(grep -c ' exited: ' "$d/events.log")" -eq 2 ]
  grep -q '"content":"after exit"' "$d/claude.jsonl"
}

@test "msys: stop still ends a worker whose Windows pid cannot be found, and says so" {
  msys
  use_fake claude
  export FAKE_TURN=30
  id="$(new_task --backend headless:claude)"
  cr dispatch "$id" >/dev/null
  pid="$(meta_of "$id" pid)"
  kill -0 "$pid"
  run cr stop "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not end the Windows process tree of pid $pid"* ]]
  for i in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  run kill -0 "$pid"; [ "$status" -ne 0 ]
}

@test "msys: the dashboard gets Windows paths and bash, and is found and stopped by its Windows pid" {
  need_python
  msys
  run cr dashboard --daemon --port 0 --no-gh
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard running: http://127.0.0.1:"* ]]
  read -r SRV_PID PORT <"$CHARTROOM_HOME/.dashboard.pid"
  local cmdline; cmdline="$(ps -p "$SRV_PID" -o command=)"
  [[ "$cmdline" == *"dashboard/server.py --port 0 --pidfile $CHARTROOM_HOME/.dashboard.pid --bin $CHARTROOM --bash "*"--theme chartroom"* ]]
  grep -q "cygpath -m $CHARTROOM_HOME" "$FAKE_LOG"
  # the board comes through bash, as a native python on Windows needs
  [ "$(get "http://127.0.0.1:$PORT/api/dashboard" | jq -r '.lanes | keys | length')" = 5 ]
  run cr dashboard status
  [ "$status" -eq 0 ]; [[ "$output" == *"http://127.0.0.1:$PORT (pid $SRV_PID)"* ]]
  grep -q "ProcessId=$SRV_PID" "$FAKE_LOG"
  run cr dashboard stop
  [ "$status" -eq 0 ]; [[ "$output" == *"dashboard stopped (pid $SRV_PID"* ]]
  grep -q "taskkill //F //PID $SRV_PID" "$FAKE_LOG"
  for i in $(seq 1 40); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.25; done
  run kill -0 "$SRV_PID"; [ "$status" -ne 0 ]
  [ ! -e "$CHARTROOM_HOME/.dashboard.pid" ]
}

@test "dashboard open: Git Bash uses start; WSL uses wslview, then PowerShell" {
  need_python
  ! command -v xdg-open >/dev/null || skip "xdg-open is installed here, and it rightly wins"
  use_fake uname # not Darwin, so macOS's `open` is not chosen
  msys
  run cr dashboard open --port 0 --no-gh
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard open: http://127.0.0.1:"* ]]
  grep -qE 'cmd //c start +http://127\.0\.0\.1:[0-9]+/' "$FAKE_LOG"
  cr dashboard stop >/dev/null
  export CHARTROOM_PLATFORM=wsl
  use_fake wslview
  run cr dashboard open --port 0 --no-gh
  [ "$status" -eq 0 ]
  grep -qE '^wslview http://127\.0\.0\.1:[0-9]+/$' "$FAKE_LOG"
  cr dashboard stop >/dev/null
  rm "$BIN/wslview"
  run cr dashboard open --port 0 --no-gh
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard open: http://127.0.0.1:"* ]]
  grep -qE "powershell\.exe -NoProfile -NonInteractive -Command Start-Process 'http://127\.0\.0\.1:[0-9]+/'" "$FAKE_LOG"
}
