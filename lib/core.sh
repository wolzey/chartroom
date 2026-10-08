# shellcheck shell=bash
# core.sh - config, state records, events and small portable helpers.
# Sourced by bin/chartroom; every other lib file builds on these functions.

CR_SCHEMA=1
WORKER_KINDS='progress|waiting|decision|blocked|done|failed'
# Core kinds: written by chartroom itself or by agent-native hooks, never by a worker by hand.
#   note     bookkeeping (created, dispatched, worktree, fallbacks)
#   steered  the XO sent the worker a message
#   exited   a headless/command process ended (exit N)
#   agent    an agent-native signal: "turn-ended", "awaiting-input: <why>", "prompt-received"
CORE_KINDS='note|steered|exited|agent'
EVENT_KINDS="$WORKER_KINDS|$CORE_KINDS"
TERMINAL_KINDS='decision|blocked|done|failed'

die() { printf 'chartroom: %s\n' "$*" >&2; exit 1; }
warn() { printf 'chartroom: %s\n' "$*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Portable `readlink -f` (macOS < 12.3 lacks -f).
realpath_f() {
  local p="$1" d
  if readlink -f / >/dev/null 2>&1; then readlink -f "$p"; return; fi
  while [[ -L "$p" ]]; do
    d="$(cd "$(dirname "$p")" && pwd)"; p="$(readlink "$p")"
    [[ "$p" == /* ]] || p="$d/$p"
  done
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

rand_hex4() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 2
  else od -An -N2 -tx1 /dev/urandom | tr -d ' \n'; fi
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else
    local h; h="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s-%s-4%s-a%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
  fi
}

# Resolve an executable path without aliases or shell functions (agents often alias claude).
bin_of() { type -P "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- config
# Precedence: CHARTROOM_* env > legacy CAP_* env > config file > default.
# The config file is KEY=VALUE lines (no shell evaluation), at
# ${XDG_CONFIG_HOME:-~/.config}/chartroom/config or $CHARTROOM_CONFIG.

CR_CONFIG_FILE="${CHARTROOM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/chartroom/config}"

# A trailing CR (a file saved by a Windows editor) is not part of the value.
cfg_file_value() { # <KEY>
  [[ -f "$CR_CONFIG_FILE" ]] || return 0
  local cr=$'\r'
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CR_CONFIG_FILE" | tail -1 | sed -E "s/$cr\$//; "'s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

cfg() { # <SUFFIX> <legacy CAP_ name or ""> <default>
  local name="CHARTROOM_$1" legacy="$2" def="$3" v
  v="${!name:-}"
  [[ -z "$v" && -n "$legacy" ]] && v="${!legacy:-}"
  [[ -z "$v" ]] && v="$(cfg_file_value "$name")"
  printf '%s' "${v:-$def}"
}

# Home: explicit env wins; then legacy CAP_HOME; then ~/.chartroom if it exists;
# then a pre-existing ~/.captain (legacy); else ~/.chartroom.
resolve_home() {
  CR_HOME_SOURCE="env"
  if [[ -n "${CHARTROOM_HOME:-}" ]]; then CR_HOME="$CHARTROOM_HOME"; return; fi
  if [[ -n "${CAP_HOME:-}" ]]; then CR_HOME="$CAP_HOME"; CR_HOME_SOURCE="legacy env CAP_HOME"; return; fi
  local f; f="$(cfg_file_value CHARTROOM_HOME)"
  if [[ -n "$f" ]]; then CR_HOME="${f/#\~/$HOME}"; CR_HOME_SOURCE=config; return; fi
  if [[ -d "$HOME/.chartroom" || ! -d "$HOME/.captain" ]]; then CR_HOME="$HOME/.chartroom"; CR_HOME_SOURCE=default
  else CR_HOME="$HOME/.captain"; CR_HOME_SOURCE="legacy ~/.captain"; fi
}

load_config() {
  detect_platform
  resolve_home
  # Git Bash: a Windows-form home (C:\crew\home, as a Windows tool would pass it)
  # becomes /c/crew/home, so globs and path joins keep working.
  if [[ "$CR_PLATFORM" == msys && "$CR_HOME" =~ ^[A-Za-z]:[\\/] ]]; then CR_HOME="$(cygpath -u "$CR_HOME")"; fi
  CR_PROJECT_ROOTS="$(cfg PROJECT_ROOTS CAP_PROJECT_ROOTS '')"
  CR_PROJECT_ROOTS="${CR_PROJECT_ROOTS//\~/$HOME}"
  CR_WORKSPACE="$(cfg WORKSPACE CAP_CREW_WORKSPACE chartroom-crew)"
  CR_WATCH_INTERVAL="$(cfg WATCH_INTERVAL CAP_WATCH_INTERVAL 3)"
  CR_BACKEND_ORDER="$(cfg BACKEND_ORDER '' 'herdr:claude cmux:claude tmux:claude headless:codex headless:claude command')"
  CR_BACKEND_ORDER="${CR_BACKEND_ORDER//,/ }"
  CR_HARNESS="$(cfg HARNESS '' generic)"
  CR_BRANCH_PREFIX="$(cfg BRANCH_PREFIX '' chartroom/)"
  CR_CODEX_SHIP_SANDBOX="$(cfg CODEX_SHIP_SANDBOX '' danger-full-access)"
  CR_CODEX_SCOUT_SANDBOX="$(cfg CODEX_SCOUT_SANDBOX '' workspace-write)"
  CR_CLAUDE_PERMISSION="$(cfg CLAUDE_PERMISSION '' '')"
  CR_CLAUDE_HEADLESS_PERMISSION="$(cfg CLAUDE_HEADLESS_PERMISSION '' acceptEdits)"
  CR_CLAUDE_ALLOWED_TOOLS="$(cfg CLAUDE_ALLOWED_TOOLS '' 'Bash Read Edit Write Glob Grep WebFetch WebSearch')"
  CR_COMMAND="$(cfg COMMAND '' '')"
  CR_DELIVER_WAIT="$(cfg DELIVER_WAIT '' 8)"
  CR_WAITING_GRACE="$(cfg WAITING_GRACE_MINUTES '' 15)"
  CR_WAITING_MAX="$(cfg WAITING_MAX_MINUTES '' 120)"
  [[ "$CR_WAITING_GRACE$CR_WAITING_MAX" =~ ^[0-9]+$ ]] || die "CHARTROOM_WAITING_GRACE_MINUTES and CHARTROOM_WAITING_MAX_MINUTES must be whole minutes"
}

# ---------------------------------------------------------------- platform
# CR_PLATFORM: posix (macOS, Linux), wsl (Linux under WSL) or msys (Git for Windows' Git
# Bash, MSYS2, Cygwin). Windows-only behaviour hangs off this, so macOS and Linux keep their
# code paths. CHARTROOM_PLATFORM overrides the detection.
detect_platform() {
  CR_PLATFORM="$(cfg PLATFORM '' '')"
  if [[ -z "$CR_PLATFORM" ]]; then
    case "${OSTYPE:-}" in
      msys*|cygwin*) CR_PLATFORM=msys ;;
      linux*)
        CR_PLATFORM=posix
        if [[ -n "${WSL_DISTRO_NAME:-}" || "$(cat /proc/sys/kernel/osrelease 2>/dev/null)" == *[Mm]icrosoft* ]]; then CR_PLATFORM=wsl; fi ;;
      *) CR_PLATFORM=posix ;;
    esac
  fi
  [[ "$CR_PLATFORM" =~ ^(posix|wsl|msys)$ ]] || die "CHARTROOM_PLATFORM must be posix, wsl or msys (got $CR_PLATFORM)"
  # A native jq.exe under MSYS writes CRLF, which would leave a CR on every captured value;
  # --binary turns that off. Probed, so an MSYS-built jq that writes LF is left alone.
  if [[ "$CR_PLATFORM" == msys && "$(command jq -n 1 2>/dev/null)" == $'1\r' ]]; then
    jq() { command jq -b "$@"; }
    export -f jq
  fi
  return 0
}

# A path as native Windows programs (python.exe, claude.exe) read it: C:/crew/home on Git
# Bash, unchanged elsewhere.
win_path() { if [[ "$CR_PLATFORM" == msys ]]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Stop a process and its children. On Git Bash, a native child (claude.exe, codex) does not
# die with its MSYS parent, so the whole Windows process tree goes, via the parent's
# Windows pid.
kill_tree() { # <pid>
  local pid="$1" w
  if [[ "$CR_PLATFORM" == msys ]]; then
    w="$(cat "/proc/$pid/winpid" 2>/dev/null || true)"
    [[ -n "$w" ]] && taskkill //T //F //PID "$w" >/dev/null 2>&1 && return 0
    warn "could not end the Windows process tree of pid $pid; its agent may still be running"
  fi
  pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------- task records

tdir() { printf '%s/tasks/%s' "$CR_HOME" "$1"; }
need_task() { [[ -f "$(tdir "$1")/meta.json" ]] || die "no such task: $1"; }
meta() { jq -r --arg k "$2" '.[$k] // empty | tostring' "$(tdir "$1")/meta.json"; }
meta_set() { # meta_set <id> <key> <string-value>
  local f; f="$(tdir "$1")/meta.json"
  jq --arg k "$2" --arg v "$3" '.[$k]=$v | .updated=(now|todate)' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
log_event() { printf '%s %s: %s\n' "$(now)" "$2" "$3" >>"$(tdir "$1")/events.log"; }
pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

slugify() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24 | sed -E 's/-+$//')"
  [[ "$s" =~ ^[a-z] ]] || s="t-$s"
  printf '%s' "${s:-task}"
}

# The worker's single instruction, identical on every backend.
task_prompt() { printf 'Read the brief at %s/brief.md and follow it exactly. Your task id is %s.' "$(win_path "$(tdir "$1")")" "$1"; }

# The kind of the last event line, e.g. "done" (field 2 without the colon).
line_kind() { local k; k="$(awk '{print $2}' <<<"$1")"; printf '%s' "${k%:}"; }

# Has the worker reported since the last dispatch/steer: a terminal event, or a `waiting`
# that nothing has followed yet? (Used to decide whether a turn ending or a process
# exiting is news.) Reads stdin, so callers can cut the log short.
reported_awk() {
  awk '
    ($2=="note:" && $3=="dispatched") || $2=="steered:" { t=0; w=0 }
    $2 ~ /^(decision|blocked|done|failed):$/ { t=1; w=0 }
    $2=="waiting:" { w=1 }
    $2=="progress:" { w=0 }
    END { exit (t || w) ? 0 : 1 }'
}
reported_since_dispatch() { reported_awk <"$(tdir "$1")/events.log"; }

# The worker's open `waiting` event, when it is the newest thing the worker said (a later
# report, steer or dispatch closes it) and no decision/blocked/failed/done came since the
# last dispatch or steer. Prints one JSON object, or nothing:
#   {on, since, until, deadline, overdue, announced}
# until is the first "YYYY-MM-DDTHH:MM[:SS]Z" in the text; the window runs to until plus
# CHARTROOM_WAITING_GRACE_MINUTES, or, without one, CHARTROOM_WAITING_MAX_MINUTES past
# the event. announced: watch already logged "note: waiting overdue" for this event.
waiting_info() { # <id>
  grep -q ' waiting: ' "$(tdir "$1")/events.log" 2>/dev/null || return 0
  jq -R -s -c --argjson grace "$CR_WAITING_GRACE" --argjson max "$CR_WAITING_MAX" '
    def epoch: try (sub("\\.[0-9]+Z$"; "Z") | sub("T(?<hm>[0-9]{2}:[0-9]{2})Z$"; "T\(.hm):00Z") | fromdateiso8601) catch null;
    [split("\n")[] | capture("^(?<ts>[^ ]+) (?<kind>[a-z]+): ?(?<text>.*)$")?] as $ev
    | ([range($ev | length) | select($ev[.] | (.kind | test("^(progress|waiting|decision|blocked|done|failed|steered)$"))
         or (.kind == "note" and (.text | startswith("dispatched"))))] | last) as $i
    | select($i != null and $ev[$i].kind == "waiting")
    # A report the XO must act on (decision/blocked/failed/done) since the last dispatch or
    # steer outranks a later `waiting`: the task keeps that state.
    | ([range($i) | select($ev[.] | .kind == "steered" or (.kind == "note" and (.text | startswith("dispatched"))))] | last // -1) as $r
    | select([$ev[$r + 1:$i][] | select(.kind | test("^(decision|blocked|failed|done)$"))] | length == 0)
    | $ev[$i] as $w
    | ([$w.text | match("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(\\.[0-9]+)?Z"; "g").string] | first | if . then epoch else null end) as $until
    | (if $until != null then $until + $grace * 60 else (($w.ts | epoch) // now) + $max * 60 end) as $deadline
    | {on: $w.text, since: $w.ts, until: (if $until != null then ($until | todate) else null end),
       deadline: ($deadline | todate), overdue: (now > $deadline),
       announced: ($ev[$i + 1:] | any(.kind == "note" and (.text | startswith("waiting overdue"))))}
  ' "$(tdir "$1")/events.log"
}

# ---------------------------------------------------------------- short ids

# Short ids: for a generated id (ending in -<4 hex>), the shortest suffix of it (at least 4
# characters, never starting with "-") that no other id in its pool ends with, so the 4-hex
# suffix is the short id and a shared one grows until it differs (foo-21ba / bar-21ba ->
# o-21ba / r-21ba). Any other id (given with `new --id`) is its own short id.
# An open task's pool is the open tasks, so history never changes it; a closed task's pool
# is every task, so no two short ids are ever equal. Prints {"<id>": "<short>", ...}.
short_ids_json() {
  local metas=("$CR_HOME"/tasks/*/meta.json)
  [[ -e "${metas[0]}" ]] || { echo '{}'; return 0; }
  jq -n -c '
    def short($pool): . as $id
      | if ($id | test("-[0-9a-f]{4}$") | not) then $id else
        ([range(4; $id | length) | $id[-.:] | select(startswith("-") | not)
          | . as $s | select(all($pool[]; . == $id or (endswith($s) | not)))] | first) // $id end;
    [inputs | {id, closed: ((.closed // "") != "")}] as $t
    | ([$t[] | select(.closed | not) | .id]) as $open
    | ($t | map(.id)) as $all
    | [$t[] | (if .closed then $all else $open end) as $pool | {key: .id, value: (.id | short($pool))}] | from_entries' "${metas[@]}"
}
