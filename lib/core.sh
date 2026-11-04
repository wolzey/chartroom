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

# A GUI launcher's login shell often lacks Homebrew's bin dirs on macOS (their PATH line
# usually lives in an interactive rc file), so herdr, tmux, gh and jq go missing for chartroom
# and for every worker it spawns, which inherits this PATH. Append the dirs that exist and are
# missing, after the user's own entries so their order still wins. CHARTROOM_PATH_APPEND
# replaces the list (colon-separated); set it empty to turn this off.
path_hygiene() {
  local d def=""
  [[ "${OSTYPE:-}" == darwin* ]] && def="/opt/homebrew/bin:/usr/local/bin"
  CR_PATH_ADDED=()
  local IFS=:
  for d in ${CHARTROOM_PATH_APPEND-$def}; do
    [[ -n "$d" && -d "$d" ]] || continue
    [[ ":$PATH:" == *":$d:"* ]] && continue
    PATH="${PATH:+$PATH:}$d"; CR_PATH_ADDED+=("$d")
  done
  export PATH
}

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
# Precedence: CHARTROOM_* env > legacy CAP_* env > the home's own config > config file > default.
# The config file is KEY=VALUE lines (no shell evaluation), at
# ${XDG_CONFIG_HOME:-~/.config}/chartroom/config or $CHARTROOM_CONFIG. A home may hold its
# own `config` in the same format (several homes on one machine: each its own workspace,
# dashboard port, project roots); it can set any key but CHARTROOM_HOME and CHARTROOM_PLATFORM,
# which are read before the home is known.

CR_CONFIG_FILE="${CHARTROOM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/chartroom/config}"
# The homes on this machine (lib/homes.sh): `name=path` lines, next to the config file.
CR_HOMES_FILE="${CR_CONFIG_FILE%/*}/homes"
CR_HOME_CONFIG=""
declare -A CR_HOME_CFG=() CR_FILE_CFG=()

# A trailing CR (a file saved by a Windows editor) is not part of the value.
cfg_value_in() { # <file> <KEY>
  [[ -f "$1" ]] || return 0
  local cr=$'\r'
  sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -1 | sed -E "s/$cr\$//; "'s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

# A config file's settings as "<KEY><TAB><value>" lines, by cfg_value_in's rules (the last
# line for a key wins when read in order).
cfg_pairs() { # <file>
  local cr=$'\r'
  sed -nE $'s/^[[:space:]]*(CHARTROOM_[A-Z0-9_]+)[[:space:]]*=[[:space:]]*/\\1\t/p' "$1" |
    sed -E "s/$cr\$//; "$'s/\t"(.*)"$/\t\\1/; s/\t\'(.*)\'$/\t\\1/'
}

# The config file and the home's own config are each read once, into CR_FILE_CFG and
# CR_HOME_CFG, and load_config sets its twenty-odd settings with cfg_set: every run starts
# there, and forks are slow on Git Bash (a lookup per setting through $(...) was some forty
# forks a run, more than a hundred processes with a config file).
load_file_config() {
  CR_FILE_CFG=()
  [[ -f "$CR_CONFIG_FILE" ]] || return 0
  local k v
  while IFS=$'\t' read -r k v; do CR_FILE_CFG[$k]="$v"; done < <(cfg_pairs "$CR_CONFIG_FILE")
}
cfg_file_value() { printf '%s' "${CR_FILE_CFG[$1]:-}"; } # <KEY>

load_home_config() {
  CR_HOME_CFG=(); CR_HOME_CONFIG="$CR_HOME/config"
  [[ -f "$CR_HOME_CONFIG" ]] || return 0
  local k v
  while IFS=$'\t' read -r k v; do
    [[ "$k" == CHARTROOM_HOME || "$k" == CHARTROOM_PLATFORM ]] && continue
    CR_HOME_CFG[$k]="$v"
  done < <(cfg_pairs "$CR_HOME_CONFIG")
}

# A setting into the variable <VAR>, without a fork.
cfg_set() { # <VAR> <SUFFIX> <legacy CAP_ name or ""> <default>
  local _n="CHARTROOM_$2" _v
  _v="${!_n:-}"
  [[ -z "$_v" && -n "$3" ]] && _v="${!3:-}"
  [[ -z "$_v" ]] && _v="${CR_HOME_CFG[$_n]:-}"
  [[ -z "$_v" ]] && _v="${CR_FILE_CFG[$_n]:-}"
  printf -v "$1" '%s' "${_v:-$4}"
}
cfg() { local value; cfg_set value "$@"; printf '%s' "$value"; } # <SUFFIX> <legacy CAP_ name or ""> <default>

# The registered homes, one "<name><TAB><path>" line each (~ expanded, no trailing slash; the
# last line for a name wins). Prints nothing without a homes file.
homes_entries() {
  [[ -f "$CR_HOMES_FILE" ]] || return 0
  local cr=$'\r'
  sed -nE $'s/^[[:space:]]*([a-z][a-z0-9-]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\\1\t\\2/p' "$CR_HOMES_FILE" |
    sed -E "s/$cr\$//; "$'s/\t"(.*)"$/\t\\1/; s/\t\'(.*)\'$/\t\\1/; s#/+$##' |
    awk -F'\t' -v home="$HOME" '{ p = $2; if (p == "~" || substr(p, 1, 2) == "~/") p = home substr(p, 2); n[$1] = p; if (!($1 in seen)) { seen[$1] = 1; o[++k] = $1 } }
      END { for (i = 1; i <= k; i++) print o[i] "\t" n[o[i]] }'
}

# The registered home that <dir> is, or lies inside (the nearest), as "<name><TAB><path>".
# Paths compare as given and physically (symlinks resolved).
home_of_dir() { # <dir>
  local dir="${1%/}" phys name p q best="" blen=0 c
  phys="$(cd "$dir" 2>/dev/null && pwd -P)" || phys="$dir"
  while IFS=$'\t' read -r name p; do
    [[ -n "$p" ]] || continue
    for q in "$p" "$(cd "$p" 2>/dev/null && pwd -P)"; do
      [[ -n "$q" ]] || continue
      for c in "$dir" "$phys"; do
        if [[ "$c" == "$q" || "$c" == "$q"/* ]] && (( ${#q} > blen )); then best="$name"$'\t'"$p"; blen=${#q}; fi
      done
    done
  done < <(homes_entries)
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# Home: explicit env wins; then legacy CAP_HOME; then the registered home this directory is (or
# lies inside); then the config file; then ~/.chartroom if it exists; then a pre-existing
# ~/.captain (legacy); else ~/.chartroom.
resolve_home() {
  CR_HOME_SOURCE="env"
  if [[ -n "${CHARTROOM_HOME:-}" ]]; then CR_HOME="$CHARTROOM_HOME"; return; fi
  if [[ -n "${CAP_HOME:-}" ]]; then CR_HOME="$CAP_HOME"; CR_HOME_SOURCE="legacy env CAP_HOME"; return; fi
  local f n
  if [[ -f "$CR_HOMES_FILE" ]] && f="$(home_of_dir "$PWD")" && [[ -n "$f" ]]; then
    n="${f%%$'\t'*}"; CR_HOME="${f#*$'\t'}"; CR_HOME_SOURCE="registered home $n, from the current directory"; return
  fi
  f="${CR_FILE_CFG[CHARTROOM_HOME]:-}"
  if [[ -n "$f" ]]; then CR_HOME="${f/#\~/$HOME}"; CR_HOME_SOURCE=config; return; fi
  if [[ -d "$HOME/.chartroom" || ! -d "$HOME/.captain" ]]; then CR_HOME="$HOME/.chartroom"; CR_HOME_SOURCE=default
  else CR_HOME="$HOME/.captain"; CR_HOME_SOURCE="legacy ~/.captain"; fi
}

load_config() {
  CR_HOME_CFG=(); CR_HOME_CONFIG=""
  load_file_config
  detect_platform
  resolve_home
  # Git Bash: a Windows-form home (C:\chartroom\home, as a Windows tool would pass it)
  # becomes /c/chartroom/home, so globs and path joins keep working.
  if [[ "$CR_PLATFORM" == msys && "$CR_HOME" =~ ^[A-Za-z]:[\\/] ]]; then CR_HOME="$(cygpath -u "$CR_HOME")"; fi
  load_home_config
  cfg_set CR_PROJECT_ROOTS PROJECT_ROOTS CAP_PROJECT_ROOTS ''
  CR_PROJECT_ROOTS="${CR_PROJECT_ROOTS//\~/$HOME}"
  cfg_set CR_WORKSPACE WORKSPACE CAP_CREW_WORKSPACE chartroom-crew
  cfg_set CR_WATCH_INTERVAL WATCH_INTERVAL CAP_WATCH_INTERVAL 3
  cfg_set CR_WATCH_HC_INTERVAL WATCH_HC_INTERVAL '' 60
  cfg_set CR_BACKEND_ORDER BACKEND_ORDER '' 'hc:claude herdr:claude cmux:claude tmux:claude headless:codex headless:claude command'
  CR_BACKEND_ORDER="${CR_BACKEND_ORDER//,/ }"
  cfg_set CR_HARNESS HARNESS '' generic
  cfg_set CR_BRANCH_PREFIX BRANCH_PREFIX '' chartroom/
  cfg_set CR_CODEX_SHIP_SANDBOX CODEX_SHIP_SANDBOX '' danger-full-access
  cfg_set CR_CODEX_SCOUT_SANDBOX CODEX_SCOUT_SANDBOX '' workspace-write
  cfg_set CR_CLAUDE_PERMISSION CLAUDE_PERMISSION '' ''
  cfg_set CR_CLAUDE_HEADLESS_PERMISSION CLAUDE_HEADLESS_PERMISSION '' acceptEdits
  cfg_set CR_CLAUDE_ALLOWED_TOOLS CLAUDE_ALLOWED_TOOLS '' 'Bash Read Edit Write Glob Grep WebFetch WebSearch'
  cfg_set CR_COMMAND COMMAND '' ''
  cfg_set CR_DELIVER_WAIT DELIVER_WAIT '' 8
  cfg_set CR_JOIN_ACK_WAIT JOIN_ACK_WAIT '' 20
  cfg_set CR_STEER_INLINE_MAX STEER_INLINE_MAX '' 300
  cfg_set CR_WAITING_GRACE WAITING_GRACE_MINUTES '' 15
  cfg_set CR_WAITING_MAX WAITING_MAX_MINUTES '' 120
  [[ "$CR_WAITING_GRACE$CR_WAITING_MAX" =~ ^[0-9]+$ ]] || die "CHARTROOM_WAITING_GRACE_MINUTES and CHARTROOM_WAITING_MAX_MINUTES must be whole minutes"
  # Park a worker at rest this long (lib/park.sh); 0 turns automatic parking off.
  cfg_set CR_PARK_AFTER PARK_AFTER_MINUTES '' 60
  [[ "$CR_PARK_AFTER" =~ ^[0-9]+$ ]] || die "CHARTROOM_PARK_AFTER_MINUTES must be whole minutes (0: never park on its own)"
}

# ---------------------------------------------------------------- platform
# CR_PLATFORM: posix (macOS, Linux), wsl (Linux under WSL) or msys (Git for Windows' Git
# Bash, MSYS2, Cygwin). Windows-only behaviour hangs off this, so macOS and Linux keep their
# code paths. CHARTROOM_PLATFORM overrides the detection.
detect_platform() {
  cfg_set CR_PLATFORM PLATFORM '' ''
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
  if [[ "$CR_PLATFORM" == msys ]]; then
    # A native jq.exe under MSYS can write CRLF (jq 1.8.1 does for some output and not for
    # other), which would leave a CR on captured values; --binary turns that off, so it is
    # passed whenever this jq accepts it.
    CR_JQ_BINARY=""; command jq -b -n 1 >/dev/null 2>&1 && CR_JQ_BINARY=1
    # /tmp's Windows path, so msys_jq converts most file operands without a cygpath each.
    CR_MSYS_TMP="$(cygpath -m /tmp 2>/dev/null || true)"
    export CR_JQ_BINARY CR_MSYS_TMP
    jq() { msys_jq "$@"; }
    export -f jq msys_jq
  fi
  return 0
}

# Git Bash: run the native jq.exe with its arguments as written. MSYS would rewrite any
# path-looking argument, so a --arg value such as /tmp/x (a worktree, the home, a steer
# message starting with /) would be stored as C:/...; with that off, file operands (the
# ones that exist) are converted to Windows paths here instead: drive and /tmp paths in
# bash, anything else in one cygpath call (forks are slow on Windows).
msys_jq() {
  local a d i=0 skip=0 out=() files=() at=() conv=() bin=()
  [[ -n "${CR_JQ_BINARY:-}" ]] && bin=(-b)
  for a in "$@"; do
    out+=("$a")
    if (( skip > 0 )); then skip=$((skip - 1))
    elif [[ "$a" == --arg || "$a" == --argjson ]]; then skip=2
    elif [[ "$a" == /* && -e "$a" ]]; then
      if [[ "$a" =~ ^/([A-Za-z])/ ]]; then d="${BASH_REMATCH[1]}"; out[i]="${d^^}:${a:2}"
      elif [[ -n "${CR_MSYS_TMP:-}" && "$a" == /tmp/* ]]; then out[i]="$CR_MSYS_TMP${a:4}"
      else files+=("$a"); at+=("$i"); fi
    fi
    i=$((i + 1))
  done
  if (( ${#files[@]} > 0 )); then
    mapfile -t conv < <(cygpath -m -- "${files[@]}")
    for i in "${!at[@]}"; do out[${at[$i]}]="${conv[$i]}"; done
  fi
  MSYS2_ARG_CONV_EXCL='*' command jq "${bin[@]}" "${out[@]}"
}

# A path as native Windows programs (python.exe, claude.exe) read it: C:/chartroom/home on Git
# Bash, unchanged elsewhere.
win_path() { if [[ "$CR_PLATFORM" == msys ]]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Stop a process and its children. On Git Bash a native child (claude.exe, codex) does not
# die with its MSYS parent, and taskkill /T cannot reach one exec'd from a forked subshell
# (its Windows parent is gone), so the pid and all its MSYS descendants (by
# <proc>/<pid>/ppid) are ended by their Windows pids. CHARTROOM_PROC (default /proc) lets
# the tests stand in a process table.
kill_tree() { # <pid>
  local pid="$1" proc="${CHARTROOM_PROC:-/proc}" p d x todo args=()
  if [[ "$CR_PLATFORM" == msys ]]; then
    todo=("$pid")
    while (( ${#todo[@]} > 0 )); do
      p="${todo[0]}"; todo=("${todo[@]:1}")
      if { read -r x <"$proc/$p/winpid"; } 2>/dev/null; then args+=(//PID "$x"); fi
      for d in "$proc"/[0-9]*; do
        { read -r x <"$d/ppid"; } 2>/dev/null && [[ "$x" == "$p" ]] && todo+=("${d##*/}")
      done
    done
    if (( ${#args[@]} > 0 )); then
      taskkill //F //T "${args[@]}" >/dev/null 2>&1 || true
    else
      warn "could not end the Windows process tree of pid $pid; its agent may still be running"
    fi
  fi
  pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------- task records

tdir() { printf '%s/tasks/%s' "$CR_HOME" "$1"; }
need_task() { [[ -f "$(tdir "$1")/meta.json" ]] || die "no such task: $1"; }
# The watch's full round reads every task's meta.json with one jq (meta_cache_load) instead of
# several per task. While MC holds a task ("<id>/" is open; a closed one keeps only that mark,
# "closed"), meta answers from it; meta_set drops the task. MC is empty outside a round.
declare -A MC=()
meta() {
  if [[ "${MC["$1/"]:-}" == open ]]; then [[ -z "${MC["$1/$2"]+x}" ]] || printf '%s\n' "${MC["$1/$2"]}"; return 0; fi
  meta_file "$@"
}
meta_file() { jq -r --arg k "$2" '.[$k] // empty | tostring' "$(tdir "$1")/meta.json"; } # never cached
meta_cache_load() { # [meta.json files: these tasks only; default every task]
  MC=()
  local metas=("$@") line id rest k v
  (( $# > 0 )) || metas=("$CR_HOME"/tasks/*/meta.json)
  [[ -e "${metas[0]-}" ]] || return 0
  # (A malformed file ends jq there: the tasks after it are left out and read one by one.)
  while IFS= read -r line; do
    id="${line%%$'\t'*}"; rest="${line#*$'\t'}"; k="${rest%%$'\t'*}"; v="${rest#*$'\t'}"
    [[ "$v" == *\\* ]] && printf -v v '%b' "$v" # @tsv's \t \n \r \\
    MC["$id/$k"]="$v"
  done < <(jq -r '(input_filename | split("/") | .[-2]) as $id | select(type == "object")
    | if (.closed // "" | tostring) != "" then [$id, "", "closed"]
      else (to_entries[] | select(.value != null and .value != false) | [$id, .key, (.value | tostring)]), [$id, "", "open"] end
    | @tsv' "${metas[@]}" 2>/dev/null || true)
}
# The task's project as the commander knows it: the repo's directory name (status rows use
# the same rule), or empty when the task has none.
project_label() { local p; p="$(meta "$1" project 2>/dev/null || true)"; p="${p%/}"; printf '%s' "${p##*/}"; }
meta_set() { # meta_set <id> <key> <string-value>
  local f; f="$(tdir "$1")/meta.json"
  unset "MC[$1/]"
  jq --arg k "$2" --arg v "$3" '.[$k]=$v | .updated=(now|todate)' "$f" >"$f.tmp" && mv "$f.tmp" "$f" && stamp_changed
}
# One line per event, always: newlines in the text become spaces. Rings the home's watches.
log_event() { printf '%s %s: %s\n' "$(now)" "$2" "${3//$'\n'/ }" >>"$(tdir "$1")/events.log"; stamp_changed; bell_ring "" watch; }
pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

# ---------------------------------------------------------------- change stamp
# $CHARTROOM_HOME/.changed is rewritten after each write of what the board shows, once the write
# is on disk: a task's events.log (log_event) and meta.json (meta_set), inbox.md (inbox_rewrite),
# focus.json, an artifact, a relay into the home and its ack. A view that polls the board
# (crew-view's band, a panel) stats it and reads the board again only when its mtime moved, with
# a slow refresh for what moves with the clock alone (ages, waiting windows, a focus running out)
# and for what writes without chartroom (a line appended with printf >>, a hand edit). The byte
# it holds means nothing: one byte written moves the mtime on every filesystem, with no fork (a
# `touch` would be one). No stamp: an older chartroom, or nothing written since the update.
# A stable contract (README "State format and event protocol").
CR_STAMP=.changed
# (lib/relay.sh passes the other home: shellcheck 0.9.0, on CI's Linux job, does not see that call.)
# shellcheck disable=SC2120
stamp_changed() { { printf . >"${1:-$CR_HOME}/$CR_STAMP"; } 2>/dev/null || true; } # [home]

# ---------------------------------------------------------------- doorbell
# A listener (watch, listen) waits on its own FIFO instead of sleeping, and whatever writes a
# record rings the listeners that read it, once the record is on disk: log_event rings the
# home's watches, mail_post the task's listen, relay the target home's watches. A ring carries
# no data (the records stay the only truth); a lost one costs a fallback round. It is coalesced:
# the ringer opens the FIFO read-write, which never blocks, and writes one byte only when none
# is pending, so not even a stopped listener can fill it and block a ringer.
# FIFOs stay out of the records (a grep -r or a backup could hang on one), at a fixed place like
# tmux's sockets, so a ringer and a listener meet whatever environment each was started in (hc
# and tmux run workers in their server's, not the XO's, so $TMPDIR may differ):
#   ${CHARTROOM_RUNTIME_DIR:-/tmp}/chartroom-<uid>/bells/<home's dir name>-<cksum of its physical path>/
#     <name>-<pid>.fifo     one per listener: watch-<pid>, listen-<task id>-<pid>
#     <name>-<pid>.mark0|1  the watch's scan markers (bell_mark)
# A FIFO whose listener is gone is removed only by a ringer of its own home; a ring into another
# home skips it. Git Bash, a runtime dir not ours, or a filesystem where mkfifo fails: no FIFO,
# and the listener polls as before.
declare -A BELL_DIRS=()
BELL_AT="" BELL_NAME="" BELL_FILE="" BELL_FD="" BELL_PREV="" BELL_MARK=0
bell_root() { local r="${CHARTROOM_RUNTIME_DIR:-/tmp}"; printf '%s/chartroom-%s' "${r%/}" "$EUID"; }
bell_root_ok() { [[ -d "$1" && ! -L "$1" && -O "$1" ]]; } # <root>: ours, and not a link
# Sets BELL_AT to a home's bell directory (not created); 1 when there is none.
bell_dir_of() { # <home>
  BELL_AT=""
  [[ "${CR_PLATFORM:-}" != msys ]] || return 1
  local h="${1%/}" p s=""; h="${h:-/}"
  if [[ -z "${BELL_DIRS[$h]+x}" ]]; then
    p="$(cd -P -- "$h" 2>/dev/null && pwd)" && s="$(cksum <<<"$p")" || p=""
    BELL_DIRS[$h]="${p:+$(bell_root)/bells/${p##*/}-${s%% *}}"
  fi
  BELL_AT="${BELL_DIRS[$h]}"
  [[ -n "$BELL_AT" ]]
}
# Gone for sure: kill -0 fails, and not because a sandbox may not signal it (ps still sees it).
bell_gone() { ! kill -0 "$1" 2>/dev/null && ! ps -p "$1" >/dev/null 2>&1; } # <pid>
bell_ring() { # <home, or "" for this one> <name>: ring every live listener <name>-<pid> there
  bell_dir_of "${1:-$CR_HOME}" || return 0
  bell_root_ok "${BELL_AT%/bells/*}" || return 0
  local f p fd
  for f in "$BELL_AT/$2"-*.fifo; do
    p="${f%.fifo}"; p="${p##*-}"
    [[ "$f" == "$BELL_AT/$2-$p.fifo" && "$p" =~ ^[0-9]+$ && -p "$f" ]] || continue
    if bell_gone "$p"; then
      [[ -n "$1" ]] || rm -f "$f" "${f%.fifo}.mark0" "${f%.fifo}.mark1"
      continue
    fi
    { exec {fd}<>"$f" && { read -r -t 0 -u "$fd" || printf . >&"$fd"; }; exec {fd}>&-; } 2>/dev/null || true
  done
  return 0
}
# This process's FIFO, <name>-<pid>, which bell_wait waits on; BELL_FILE stays empty (and
# bell_wait sleeps) when there can be none here.
bell_open() { # <name>
  bell_close; BELL_NAME="$1"
  bell_dir_of "$CR_HOME" || return 0
  local root="${BELL_AT%/bells/*}"
  [[ -d "$root" ]] || { mkdir -p "${root%/*}" && mkdir -m 700 "$root"; } 2>/dev/null || true
  bell_root_ok "$root" && mkdir -p "$BELL_AT" 2>/dev/null || return 0
  BELL_FILE="$BELL_AT/$1-$$.fifo"; rm -f "$BELL_FILE"
  if ! { mkfifo -m 600 "$BELL_FILE" && exec {BELL_FD}<>"$BELL_FILE"; } 2>/dev/null; then
    rm -f "$BELL_FILE"; BELL_FILE=""; BELL_FD=""
  fi
  return 0
}
# A FIFO removed under a live listener (a tmp cleaner) is made again, so rings find it.
bell_check() { [[ -z "$BELL_NAME" || -p "$BELL_FILE" ]] || bell_open "$BELL_NAME"; }
bell_close() {
  if [[ -n "$BELL_FD" ]]; then exec {BELL_FD}>&-; fi
  [[ -z "$BELL_FILE" ]] || rm -f "$BELL_FILE" "${BELL_FILE%.fifo}.mark0" "${BELL_FILE%.fifo}.mark1"
  BELL_FILE=""; BELL_FD=""; BELL_NAME=""
}
# Wait for a ring, at most <seconds>: 0 when rung (every pending ring is taken), 1 when not.
bell_wait() { # <seconds>
  if [[ -z "$BELL_FD" ]]; then sleep "$1"; return 1; fi
  local c rc=0
  read -r -N 1 -t "$1" -u "$BELL_FD" c || rc=$?
  if [[ $rc -eq 0 ]]; then
    while read -r -t 0 -u "$BELL_FD"; do read -r -N 1 -u "$BELL_FD" c || break; done
    return 0
  fi
  [[ $rc -gt 128 ]] && return 1
  bell_close; sleep "$1"; return 1 # the FIFO failed: poll from here on
}
# Before a scan: touch the next marker; BELL_PREV is the one touched when the previous scan
# started, so a log not older than it may have grown since (bash's -ot, no fork).
bell_mark() {
  BELL_PREV=""
  [[ -n "$BELL_FILE" ]] || return 0
  BELL_PREV="${BELL_FILE%.fifo}.mark$BELL_MARK"; BELL_MARK=$((1 - BELL_MARK))
  { printf . >"${BELL_FILE%.fifo}.mark$BELL_MARK"; } 2>/dev/null || true
}

slugify() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24 | sed -E 's/-+$//')"
  [[ "$s" =~ ^[a-z] ]] || s="t-$s"
  printf '%s' "${s:-task}"
}

# The worker's single instruction, identical on every backend.
task_prompt() { printf 'Read the brief at %s/brief.md and follow it exactly. Your task id is %s.' "$(win_path "$(tdir "$1")")" "$1"; }

# A short signature of a prompt's text: whitespace runs collapsed and trimmed, so a typed
# message and what the agent's prompt hook received compare equal; first 12 hex of sha256.
text_sig() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=(sha256sum); else h=(shasum -a 256); fi
  tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//' | "${h[@]}" | cut -c1-12
}

# The kind of the last event line, e.g. "done" (field 2 without the colon).
line_kind() { local k; k="$(awk '{print $2}' <<<"$1")"; printf '%s' "${k%:}"; }

# Has the worker reported since the last dispatch/steer: a terminal event, or a `waiting`
# that nothing has followed yet? (Used to decide whether a turn ending or a process
# exiting is news.) A parked worker (lib/park.sh) is at rest until a revive takes (its note,
# or the resumed agent taking its first prompt, which may finish its turn before the note is
# written), so the launcher's `exited` after a park, or after a resume that failed, is not news.
# Reads stdin, so callers can cut the log short.
reported_awk() {
  awk '
    ($2=="note:" && $3=="dispatched") || $2=="steered:" { t=0; w=0 }
    $2=="note:" && $3=="dispatched" { p=0 }
    $2=="note:" && $3=="parked" { p=1 }
    $2=="note:" && ($3=="revived" || ($3=="park" && $4=="undone:")) { p=0 }
    $2=="agent:" && $3=="prompt-received" { p=0 }
    $2 ~ /^(decision|blocked|done|failed):$/ { t=1; w=0 }
    $2=="waiting:" { w=1 }
    $2=="progress:" { w=0 }
    END { exit (t || w || p) ? 0 : 1 }'
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
  [[ -e "${metas[0]-}" ]] || { echo '{}'; return 0; } # (empty under nullglob)
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
