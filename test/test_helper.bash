# Shared setup: every test gets a private HOME, CHARTROOM_HOME and PATH, so nothing
# touches the real machine and no real herdr/tmux/cmux/claude/codex is ever invoked.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CHARTROOM="$REPO_ROOT/bin/chartroom"

common_setup() {
  local real_bash real_jq real_git
  real_bash="$(type -P bash)"; real_jq="$(type -P jq)"; real_git="$(type -P git)"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/chartroom"
  export CHARTROOM_CONFIG="$BATS_TEST_TMPDIR/no-config"
  export CHARTROOM_BIN="$CHARTROOM"
  export CHARTROOM_WATCH_INTERVAL=1
  export CHARTROOM_DELIVER_WAIT=2
  unset CAP_HOME CAP_PROJECT_ROOTS CAP_CREW_WORKSPACE CAP_WATCH_INTERVAL CHARTROOM_HARNESS CHARTROOM_BACKEND_ORDER CHARTROOM_COMMAND
  unset CI TMUX HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH
  # Minimal PATH: bash>=4, jq, git and the base system. Fakes are added per test.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  ln -sf "$real_bash" "$BIN/bash"; ln -sf "$real_jq" "$BIN/jq"; ln -sf "$real_git" "$BIN/git"
  export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global user.name test; git config --global user.email test@example.invalid
  git config --global init.defaultBranch main
  # A throwaway project repo.
  PROJECT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT"; echo hi >"$PROJECT/README"; git -C "$PROJECT" add README; git -C "$PROJECT" commit -qm init
  STUB="$REPO_ROOT/test/stub-agent"
}

# Put named fakes (test/fakes/<name>) on PATH.
use_fake() { local f; for f in "$@"; do ln -sf "$REPO_ROOT/test/fakes/$f" "$BIN/$f"; done; }

cr() { "$CHARTROOM" "$@"; }

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
