#!/usr/bin/env bash
# Git Bash smoke test for what the bats fakes (bash scripts) cannot show: a native Windows
# agent process fed through headless:claude's pipe and stopped as a process tree, and the
# dashboard run by a native python. CI runs it on windows-latest; anywhere else it exits 0.
set -euo pipefail
case "${OSTYPE:-}" in msys*|cygwin*) ;; *) echo "windows-smoke: not Git Bash; nothing to do"; exit 0 ;; esac

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
export CHARTROOM_HOME="$t/home" CHARTROOM_CONFIG="$t/no-config"
cr() { "$root/bin/chartroom" "$@"; }
step() { printf '== %s\n' "$*"; }
fail() {
  printf 'windows-smoke: FAIL: %s\n' "$*" >&2
  if [[ -n "${id:-}" ]]; then
    local f
    for f in events.log claude.err claude.jsonl stdin.first meta.json; do
      [[ ! -f "$CHARTROOM_HOME/tasks/$id/$f" ]] || { echo "== $f" >&2; tail -n 20 "$CHARTROOM_HOME/tasks/$id/$f" >&2; }
    done
    echo "== processes" >&2; ps -W 2>/dev/null | grep -iE 'python|bash' >&2 || true
  fi
  [[ ! -f "$CHARTROOM_HOME/.dashboard.log" ]] || { echo "== .dashboard.log" >&2; cat "$CHARTROOM_HOME/.dashboard.log" >&2; }
  exit 1
}
wait_for() { # <file> <regex> <seconds>
  local i; for i in $(seq 1 $(($3 * 4))); do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 0.25; done; return 1
}
new() { # <title> -> task id, with a commander's intent so it can be dispatched
  local i; i="$(cr new --project "$p" --title "$1" --backend headless:claude | sed -n 's/^id=//p')"
  sed -i "/^## Commander's intent$/a Smoke test." "$CHARTROOM_HOME/tasks/$i/brief.md"
  printf '%s' "$i"
}

py=""
for c in python3 python; do
  c="$(type -P "$c" || true)"
  [[ -n "$c" ]] && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null && { py="$c"; break; }
done
[[ -n "$py" ]] || fail "no python 3.8+"

# A native "claude": python.exe speaking just enough stream-json, like test/fakes/claude
# (compact, as claude writes it: the wrapper looks for "type":"result").
mkdir -p "$t/bin"
cat >"$t/chartroom-smoke-agent.py" <<'PY'
import json, os, sys, time
out = sys.stdout.buffer
def emit(o):
    out.write((json.dumps(o, separators=(",", ":")) + "\n").encode()); out.flush()
emit({"type": "system", "subtype": "init"})
for line in sys.stdin.buffer:
    out.write(line.rstrip(b"\r\n") + b"\n"); out.flush()
    time.sleep(float(os.environ.get("SMOKE_TURN", "1")))
    emit({"type": "result", "subtype": "success", "result": "native result"})
PY
printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$py" "$(cygpath -m "$t/chartroom-smoke-agent.py")" >"$t/bin/claude"
chmod +x "$t/bin/claude"
export PATH="$t/bin:$PATH"
agents() { # how many native smoke agents (python processes) are running; the query's own
  # powershell.exe has the same text in its command line, so match the process name too
  powershell.exe -NoProfile -NonInteractive -Command \
    "@(Get-CimInstance Win32_Process | Where-Object { \$_.Name -like 'python*' -and \$_.CommandLine -like '*chartroom-smoke-agent*' }).Count" | tr -d '\r'
}

p="$t/proj"
git init -q "$p"
git -C "$p" -c user.name=smoke -c user.email=smoke@example.invalid commit -q --allow-empty -m init
cr init >/dev/null
cr doctor

step "headless:claude with a native agent: pipe delivery, final result, resume"
id="$(new "smoke run")"
cr dispatch "$id"
d="$CHARTROOM_HOME/tasks/$id"
wait_for "$d/events.log" ' exited: claude process ended' 90 || fail "the run did not end"
[[ "$(cat "$d/final.md")" == "native result" ]] || fail "final.md is '$(cat "$d/final.md")'"
SMOKE_TURN=0 cr steer "$id" "second turn"
for _ in $(seq 1 360); do [[ "$(grep -c ' exited: ' "$d/events.log")" -ge 2 ]] && break; sleep 0.25; done
[[ "$(grep -c ' exited: ' "$d/events.log")" -ge 2 ]] || fail "the resumed run did not end"
grep -q '"second turn"' "$d/claude.jsonl" || fail "the steer never reached the agent"

step "stop ends the native agent's process tree"
id="$(new "smoke stop")"
SMOKE_TURN=300 cr dispatch "$id"
for _ in $(seq 1 40); do [[ "$(agents)" -ge 1 ]] && break; sleep 0.5; done
[[ "$(agents)" -ge 1 ]] || fail "the native agent never started"
cr stop "$id"
for _ in $(seq 1 20); do [[ "$(agents)" == 0 ]] && break; sleep 0.5; done
[[ "$(agents)" == 0 ]] || fail "the native agent survived stop"
id=""

step "dashboard: native python, started, found by its Windows pid, served, stopped"
cr dashboard --daemon --port 0 --no-gh
read -r _ port <"$CHARTROOM_HOME/.dashboard.pid"
cr dashboard status || fail "status does not find the running dashboard"
curl -fsS --max-time 120 "http://127.0.0.1:$port/api/dashboard" | jq -e '.lanes | length == 5' >/dev/null || fail "/api/dashboard"
cr dashboard stop
if cr dashboard status >/dev/null; then fail "the dashboard is still running after stop"; fi

echo "windows-smoke: ok"
