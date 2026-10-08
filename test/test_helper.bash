# Shared setup: every test gets a private HOME, CHARTROOM_HOME and PATH, so nothing
# touches the real machine and no real herdr/tmux/cmux/claude/codex is ever invoked.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CHARTROOM="$REPO_ROOT/bin/chartroom"

common_setup() {
  local real_bash real_jq real_git
  real_bash="$(type -P bash)"; real_jq="$(type -P jq)"; real_git="$(type -P git)"
  # Git Bash: the minimal PATH below drops the Windows python, so find a working one now.
  case "${OSTYPE:-}" in msys*|cygwin*)
    local c; CR_TEST_PYTHON=""
    for c in python3 python; do
      c="$(type -P "$c")" && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null && { CR_TEST_PYTHON="$c"; break; }
    done ;;
  esac
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/chartroom"
  export CHARTROOM_CONFIG="$BATS_TEST_TMPDIR/no-config"
  export CHARTROOM_BIN="$CHARTROOM"
  export CHARTROOM_WATCH_INTERVAL=1
  export CHARTROOM_DELIVER_WAIT=2
  unset CAP_HOME CAP_PROJECT_ROOTS CAP_CREW_WORKSPACE CAP_WATCH_INTERVAL CHARTROOM_HARNESS CHARTROOM_BACKEND_ORDER CHARTROOM_COMMAND
  unset CHARTROOM_PLATFORM CHARTROOM_HERDR_ANY_OS CHARTROOM_OPENER WSL_DISTRO_NAME
  unset CI TMUX HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH
  # Minimal PATH: bash>=4, jq, git and the base system. Fakes are added per test.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  link_tool "$real_bash" bash; link_tool "$real_jq" jq; link_tool "$real_git" git
  # Git Bash: the tests' own jq calls run with --binary too, as chartroom's do, so a native
  # jq.exe gives them LF.
  case "${OSTYPE:-}" in msys*|cygwin*)
    if "$real_jq" -b -n 1 >/dev/null 2>&1; then printf '#!/bin/sh\nexec %q -b "$@"\n' "$real_jq" >"$BIN/jq"; chmod +x "$BIN/jq"; fi ;;
  esac
  export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  # Git Bash: chartroom's Windows paths need cmd, taskkill, tasklist and powershell.exe, and
  # git its own helpers (git-upload-pack for a local clone). herdr's code paths run against
  # the fake herdr here too; its default-off guard is asserted in backends.bats.
  case "${OSTYPE:-}" in msys*|cygwin*)
    local w; w="$(cygpath -u "${SYSTEMROOT:-C:\Windows}")"
    PATH="$PATH:$w/System32:$w/System32/WindowsPowerShell/v1.0:$(dirname "$real_git"):$(cygpath -u "$("$real_git" --exec-path)")"
    export CHARTROOM_HERDR_ANY_OS=1 ;;
  esac
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global user.name test; git config --global user.email test@example.invalid
  git config --global init.defaultBranch main
  # A throwaway project repo.
  PROJECT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT"; echo hi >"$PROJECT/README"; git -C "$PROJECT" add README; git -C "$PROJECT" commit -qm init
  STUB="$REPO_ROOT/test/stub-agent"
}

# Put a real tool on the test PATH: a symlink, or on Git Bash (whose `ln -s` copies, and a
# copied git.exe or python.exe loses the DLLs next to it) a script that execs it.
link_tool() { # <real path> <name>
  case "${OSTYPE:-}" in
    msys*|cygwin*) printf '#!/bin/sh\nexec %q "$@"\n' "$1" >"$BIN/$2"; chmod +x "$BIN/$2" ;;
    *) ln -sf "$1" "$BIN/$2" ;;
  esac
}

# Does `ln -s` make a real symlink here? (Not on Git Bash by default: it copies.)
real_symlinks() {
  local d="$BATS_TEST_TMPDIR/symlink-probe"
  mkdir -p "$d"; : >"$d/t"; ln -sf t "$d/l" 2>/dev/null; [[ -L "$d/l" ]]
}

# Put named fakes (test/fakes/<name>) on PATH.
use_fake() { local f; for f in "$@"; do ln -sf "$REPO_ROOT/test/fakes/$f" "$BIN/$f"; done; }

# fd 3 is bats' own: a worker or dashboard a test leaves behind must not hold it, or bats
# waits for it after the last test (Git Bash keeps a stub process per native child).
cr() { "$CHARTROOM" "$@" 3>&-; }

# Create a task and give its brief a commander's intent; prints the id.
new_task() {
  local out id
  out="$(cr new --project "$PROJECT" --title "${TITLE:-stub task}" "$@")"
  id="$(sed -n 's/^id=//p' <<<"$out")"
  perl -0pi -e "s/(## Commander's intent\n\n)/\$1Please do the thing.\n/" "$CHARTROOM_HOME/tasks/$id/brief.md"
  printf '%s' "$id"
}

events() { cat "$CHARTROOM_HOME/tasks/$1/events.log"; }
meta_of() { jq -r --arg k "$2" '.[$k] // empty' "$CHARTROOM_HOME/tasks/$1/meta.json"; }

# Wait (default ~10s, or <secs>) until the task's events.log matches a regex.
wait_event() {
  local id="$1" re="$2" i n=$(( ${3:-10} * 4 ))
  for i in $(seq 1 "$n"); do grep -qE "$re" "$CHARTROOM_HOME/tasks/$id/events.log" && return 0; sleep 0.25; done
  echo "timed out waiting for /$re/ in:" >&2; events "$id" >&2; return 1
}
