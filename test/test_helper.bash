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
  unset CHARTROOM_OPENER
  unset CI TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH
  # An XO running inside Herdr passes its herdr-core terminal's address and socket down.
  unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET HC_SESSION HERDR_APP_HOME
  unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID CHARTROOM_TASK
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  # Never the real login shell and its rc files (lib/core.sh login_path, lib/nodeprobe.sh): a test
  # that wants one names a fake.
  export CHARTROOM_LOGIN_SHELL=none
  # Never the real keychain, launchd or hardware id (lib/device.sh): a device's token goes to a
  # 0600 file and its agent is run by the test itself.
  export CHARTROOM_KEYCHAIN=none CHARTROOM_LAUNCHCTL=none CHARTROOM_HW_UUID=test-hw-0001
  # no test starts the CPU sampler (lib/cpuload.sh) behind an agent or an app server; a probe's own
  # sample is short
  export CHARTROOM_CPU_SAMPLER=off CR_PROBE_SAMPLE=1
  unset CHARTROOM_PLACEMENT CHARTROOM_PLACE_HOLD_SECONDS CHARTROOM_GUEST
  unset CHARTROOM_FLEET_DIR CHARTROOM_BRAIN_URL CHARTROOM_DEVICE_HEARTBEAT CHARTROOM_NODE_STALE_SECONDS CHARTROOM_NODE_LOST_MINUTES
  # (A runner's own would move herdr's socket away from this test's HOME: see herdr_sock_up.)
  unset XDG_CONFIG_HOME
  # The doorbell's FIFOs (lib/core.sh), here instead of /tmp/chartroom-<uid>.
  export CHARTROOM_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  # Never a real browser: `artifact pdf` finds no Chrome unless a test puts the fake on
  # (CHARTROOM_CHROME=chrome, test/fakes/chrome) or opts in to a real one (test/pages.bats).
  export CHARTROOM_CHROME="$BATS_TEST_TMPDIR/no-chrome-in-tests"
  unset CHARTROOM_PDF_PAPER CHARTROOM_PDF_TIMEOUT
  # Minimal PATH: bash>=4, jq, git and the base system. Fakes are added per test.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  link_tool "$real_bash" bash; link_tool "$real_jq" jq; link_tool "$real_git" git
  export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  # No PATH hygiene by default: on a Mac with Homebrew it would append the real herdr/tmux/gh.
  export CHARTROOM_PATH_APPEND=""
  unset CHARTROOM_BASH_SEARCH _CHARTROOM_REEXEC
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global user.name test; git config --global user.email test@example.invalid
  git config --global init.defaultBranch main
  # A throwaway project repo.
  PROJECT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT"; echo hi >"$PROJECT/README"; git -C "$PROJECT" add README; git -C "$PROJECT" commit -qm init
  STUB="$REPO_ROOT/test/stub-agent"
}

# Put a real tool on the test PATH.
link_tool() { ln -sf "$1" "$BIN/$2"; } # <real path> <name>

# A herdr server's socket where herdr looks by default ($HOME/.config/herdr/herdr.sock), so the
# watch, the radar and sweep, which run no herdr command without one, reach the fake herdr. Bound
# at a short path (socket paths are limited to ~100 bytes) and moved into place; nothing listens.
herdr_sock_up() {
  local d="$HOME/.config/herdr" s="/tmp/crhd.$$.$RANDOM"
  mkdir -p "$d"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die "$!"' "$s" && mv "$s" "$d/herdr.sock"
}

# Put named fakes (test/fakes/<name>) on PATH.
use_fake() { local f; for f in "$@"; do ln -sf "$REPO_ROOT/test/fakes/$f" "$BIN/$f"; done; }

# fd 3 is bats' own: a worker or dashboard a test leaves behind must not hold it, or bats
# waits for it after the last test.
cr() { "$CHARTROOM" "$@" 3>&-; }

# A machine with 10 cores and 100 GB whose CPUs are <cpu>% busy and memory <mem>% used, for probes run
# with FAKE_NODE_DIR=<fake dir> and XDG_STATE_HOME=<state dir> (needs use_fake sysctl vm_stat).
fake_use() { # <fake dir> <state dir> <cpu> <mem>
  mkdir -p "$1/sysctl" "$2/chartroom/node"
  echo 10 >"$1/sysctl/hw.ncpu"; echo 107374182400 >"$1/sysctl/hw.memsize"; echo '{ 1.00 1.00 1.00 }' >"$1/sysctl/vm.loadavg"
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages wired down: 0.\nPages purgeable: 0.\nAnonymous pages: %s.\nPages occupied by compressor: 0.\n' $(( $4 * 65536 )) >"$1/vm_stat"
  echo "$(( $(date +%s) + 3600 )) $3 60" >"$2/chartroom/node/cpu"
}

# Create a task and give its brief a commander's intent; prints the id.
new_task() {
  local out id
  out="$(cr new --project "$PROJECT" --title "${TITLE:-stub task}" "$@")"
  id="$(sed -n 's/^id=//p' <<<"$out")"
  perl -0pi -e "s/(## Commander's intent\n\n)/\$1Please do the thing.\n/" "$CHARTROOM_HOME/tasks/$id/brief.md"
  printf '%s' "$id"
}

# Every file under the given dirs with its checksum, to show a run wrote nothing (or only what
# it should).
snapshot() { find "$@" -type f -exec cksum {} + | sort; }

# A test of a file's own format (inbox.md, focus.json) runs with the switch off: with it on, those
# records are store rows (test/store-marks.bats covers them there).
files_only() { [[ "${CHARTROOM_STORE:-}" != sqlite ]] || skip "${1:-the format of a file the store replaces}"; }

# A task's events and record, wherever it lives (a store task has no events.log or meta.json).
events() {
  if [[ -f "$CHARTROOM_HOME/tasks/$1/meta.json" ]]; then cat "$CHARTROOM_HOME/tasks/$1/events.log"
  else "$CHARTROOM" store events "$1" 3>&-; fi
}
meta_of() {
  if [[ -f "$CHARTROOM_HOME/tasks/$1/meta.json" ]]; then jq -r --arg k "$2" '.[$k] // empty' "$CHARTROOM_HOME/tasks/$1/meta.json"
  else "$CHARTROOM" store meta "$1" 3>&- | jq -r --arg k "$2" '.[$k] // empty'; fi
}

# The file a line is appended to without chartroom (a raw printf, as a launcher's wrapper does):
# a file task's events.log, a store task's events.spool.
log_of() {
  if [[ -f "$CHARTROOM_HOME/tasks/$1/meta.json" ]]; then printf '%s/tasks/%s/events.log' "$CHARTROOM_HOME" "$1"
  else printf '%s/tasks/%s/events.spool' "$CHARTROOM_HOME" "$1"; fi
}
# A home's mailbox records (relays, told words, acks), wherever they live: [home].
mail_of() { CHARTROOM_HOME="${1:-$CHARTROOM_HOME}" "$CHARTROOM" store mail 3>&-; }

# Change a task's record as a test fakes one (a dispatch time, a pid), wherever it lives: <jq filter>.
set_meta() { # <id> <jq filter>
  local f="$CHARTROOM_HOME/tasks/$1/meta.json" doc
  if [[ -f "$f" ]]; then jq "$2" "$f" >"$f.t" && mv "$f.t" "$f"; return; fi
  doc="$("$CHARTROOM" store meta "$1" 3>&- | jq -c "$2")" || return 1
  python3 - "$REPO_ROOT/lib" "$CHARTROOM_HOME" "$1" "$doc" <<'PY'
import json, os, sqlite3, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import store
home, tid, doc = sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
with open(os.path.join(home, ".home-id")) as f:
    uid, db = (f.read().split("\n") + ["", ""])[:2]
db = os.environ.get("CHARTROOM_DB") or db
c = sqlite3.connect(db)
hid = c.execute("SELECT hid FROM homes WHERE uid = ?", (uid,)).fetchone()[0]
row = store.task_row(c, hid, tid)
extra = {k: v for k, v in doc.items() if k not in store.META_COLS}
for k in store.META_COLS:
    if k != "id":
        c.execute("UPDATE tasks SET %s = ? WHERE hid = ? AND id = ?" % k, (doc.get(k), hid, tid))
c.execute("UPDATE tasks SET extra = ? WHERE hid = ? AND id = ?", (json.dumps(extra), hid, tid))
c.commit()
PY
}

# Every event of a task at one time <ts>, as if its history were that old, wherever it lives (a
# file task's events.log is rewritten and its mtime set; a store task's rows are).
age_events() { # <id> <ts>
  local f="$CHARTROOM_HOME/tasks/$1/events.log"
  if [[ -f "$CHARTROOM_HOME/tasks/$1/meta.json" ]]; then
    sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/$2/" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$(jq -rn --arg t "$2" '$t | fromdateiso8601')" "$f"
    return
  fi
  python3 - "$CHARTROOM_HOME" "$1" "$2" <<'PY'
import os, sqlite3, sys
home, tid, ts = sys.argv[1:4]
with open(os.path.join(home, ".home-id")) as f:
    uid, db = (f.read().split("\n") + ["", ""])[:2]
c = sqlite3.connect(os.environ.get("CHARTROOM_DB") or db)
c.execute("UPDATE events SET ts = ? WHERE task = ? AND hid = (SELECT hid FROM homes WHERE uid = ?)", (ts, tid, uid))
c.commit()
PY
}

# Wait (default ~10s, or <secs>) until the task's events.log matches a regex.
wait_event() {
  local id="$1" re="$2" i n=$(( ${3:-10} * 4 ))
  for i in $(seq 1 "$n"); do events "$id" 2>/dev/null | grep -qE "$re" && return 0; sleep 0.25; done
  echo "timed out waiting for /$re/ in:" >&2; events "$id" >&2; return 1
}
