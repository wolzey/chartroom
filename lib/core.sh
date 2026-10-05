# shellcheck shell=bash
# core.sh - config, state records, events and small portable helpers.
# Sourced by bin/chartroom; every other lib file builds on these functions.

CR_SCHEMA=1
WORKER_KINDS='progress|decision|blocked|done|failed'
# Core kinds: written by chartroom itself or by agent-native hooks, never by a worker by hand.
#   note     bookkeeping (created, dispatched, worktree, fallbacks)
#   steered  the first mate sent the worker a message
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

cfg_file_value() { # <KEY>
  [[ -f "$CR_CONFIG_FILE" ]] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CR_CONFIG_FILE" | tail -1 | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
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
  resolve_home
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
task_prompt() { printf 'Read the brief at %s/brief.md and follow it exactly. Your task id is %s.' "$(tdir "$1")" "$1"; }

# The kind of the last event line, e.g. "done" (field 2 without the colon).
line_kind() { local k; k="$(awk '{print $2}' <<<"$1")"; printf '%s' "${k%:}"; }

# Has the worker reported a terminal event since the last dispatch/steer?
# (Used to decide whether a turn ending or a process exiting is news.)
reported_since_dispatch() {
  awk '
    ($2=="note:" && $3=="dispatched") || $2=="steered:" { t=0 }
    $2 ~ /^(decision|blocked|done|failed):$/ { t=1 }
    END { exit t ? 0 : 1 }' "$(tdir "$1")/events.log"
}
