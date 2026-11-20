#!/usr/bin/env bash
# shellcheck shell=bash
# nodeprobe.sh - what a machine offers the crew: its capacity, power, idle time, budgets, tools,
# logins and project checkouts, as "<key><TAB><value>..." lines, the first `probe_schema 1`.
# `chartroom nodes` sends this file to another machine as `ssh <target> 'bash -s' < nodeprobe.sh`,
# so it needs nothing installed there, and `chartroom node probe` runs it here. It only reads:
# it writes no file, starts no process that outlives it, and never starts an hc core (every hc
# command starts one when none answers, so hc is asked only once its socket answers).
#
# Written for bash 3.2 (a Mac's /bin/bash, which a non-interactive ssh shell finds first) and
# without jq: no associative arrays, no mapfile, no ${x,,}.
#
# Logins are checked where a worker would run. A Mac's login keychain is closed to an ssh
# session, so claude, codex and gh read as logged out there even when they are not: with an hc
# core answering, the checks run inside it (`hc exec`, a core started in the login session, given
# this probe's PATH); without one, they run here unless this is an ssh session, where they read
# `unknown`.
#
# Lines (a value of "-" is unknown):
#   probe_schema 1 | host H | os NAME VERSION | model M | clock EPOCH
#   cores N | cores_perf N | cores_eff N | mem_bytes N | load L1 L5 L15 | mem_free_pct N
#   power ac|battery|- | battery_pct N | hid_idle_s N
#   initialised 0|1 | config PATH | budget KEY VALUE (max_workers cpu mem on_battery priority project_roots accept)
#   runner hc up|down|none VERSION | context core|shell|ssh | agents_live N
#   tool NAME ok|old|down|missing|error VERSION-OR-WHY
#   login NAME ok|no|unknown|missing DETAIL
#   checkouts N | checkout CANONICAL-REMOTE PATH FETCH-AGE-SECONDS  (the latter only for $CR_PROBE_PROJECT)
# Settings it reads: CHARTROOM_NODE_CONFIG (default ${XDG_CONFIG_HOME:-~/.config}/chartroom/node),
# CR_PROBE_PROJECT (a canonical remote, host/owner/repo, to look for among the checkouts), and
# HC_SOCKET / HC_SESSION / XDG_STATE_HOME as hc reads them.

set -u

kv() { local IFS=$'\t'; printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
# Runs a command for at most <seconds> (macOS has no `timeout`): perl's alarm, else as is.
bounded() { # <seconds> <cmd...>
  local s="$1"; shift
  if have perl; then perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; else "$@"; fi
}
num_or_dash() { case "${1:-}" in ''|*[!0-9.]*) printf '%s' - ;; *) printf '%s' "$1" ;; esac; }
sysctl_n() { have sysctl || return 1; sysctl -n "$1" 2>/dev/null; }

# One function, so it can run here or, whole, inside the hc core (`declare -f`). Its first
# argument says whether logins are checked (1) or read unknown (0).
checks() {
  local logins="$1" t b v out rc
  ck_kv() { local IFS=$'\t'; printf '%s\n' "$*"; }
  ck_ver() { grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }
  ck_run() { # <seconds> <cmd...>
    local s="$1"; shift
    if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; else "$@"; fi
  }
  for t in git jq bash claude codex gh go docker ruby node herdr tmux chartroom; do
    b="$(command -v "$t" 2>/dev/null || true)"
    if [[ -z "$b" ]]; then ck_kv tool "$t" missing -; continue; fi
    case "$t" in
      bash)
        v="$(ck_run 10 "$b" -c 'echo $BASH_VERSION' 2>/dev/null | ck_ver)"
        if [[ "${v%%.*}" =~ ^[0-9]+$ ]] && (( ${v%%.*} >= 4 )); then ck_kv tool bash ok "$v"; else ck_kv tool bash old "${v:--}"; fi ;;
      docker)
        # The daemon has to answer, not just the client be installed.
        if out="$(ck_run 15 "$b" info --format '{{.ServerVersion}}' 2>&1)" && [[ -n "$out" ]]; then ck_kv tool docker ok "$(ck_ver <<<"$out")"
        else ck_kv tool docker down "daemon not answering"; fi ;;
      ruby) v="$(ck_run 10 "$b" -e 'print RUBY_VERSION' 2>/dev/null)"; if [[ -n "$v" ]]; then ck_kv tool ruby ok "$v"; else ck_kv tool ruby error "ruby -e failed"; fi ;;
      go) v="$(ck_run 10 "$b" version 2>/dev/null | ck_ver)"; if [[ -n "$v" ]]; then ck_kv tool go ok "$v"; else ck_kv tool go error "go version failed"; fi ;;
      tmux) v="$(ck_run 10 "$b" -V 2>/dev/null | ck_ver)"; ck_kv tool tmux ok "${v:--}" ;;
      chartroom) v="$(ck_run 10 "$b" version 2>/dev/null | ck_ver)"; ck_kv tool chartroom ok "${v:--}" ;;
      *) v="$(ck_run 10 "$b" --version 2>/dev/null | ck_ver)"; if [[ -n "$v" ]]; then ck_kv tool "$t" ok "$v"; else ck_kv tool "$t" error "--version failed"; fi ;;
    esac
  done
  for t in claude codex gh; do
    b="$(command -v "$t" 2>/dev/null || true)"
    if [[ -z "$b" ]]; then ck_kv login "$t" missing -; continue; fi
    if [[ "$logins" != 1 ]]; then ck_kv login "$t" unknown "no runner core, and an ssh session cannot read the login keychain"; continue; fi
    rc=0
    case "$t" in
      claude)
        out="$(ck_run 20 "$b" auth status 2>/dev/null)" || rc=$?
        if grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*true' <<<"$out"; then ck_kv login claude ok "$(sed -nE 's/.*"authMethod"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<<"$out" | head -1)"
        elif grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*false' <<<"$out"; then ck_kv login claude no "not logged in"
        else ck_kv login claude unknown "claude auth status gave no answer (exit $rc)"; fi ;;
      codex) if ck_run 20 "$b" login status >/dev/null 2>&1; then ck_kv login codex ok -; else ck_kv login codex no "codex login status failed"; fi ;;
      gh) if ck_run 20 "$b" auth status >/dev/null 2>&1; then ck_kv login gh ok -; else ck_kv login gh no "gh auth status failed"; fi ;;
    esac
  done
  return 0
}

canon() { # <remote url>
  local u="$1"
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*@}" ;;
    *@*:*) u="${u#*@}"; u="${u/://}" ;;
    *:*) u="${u/://}" ;;
  esac
  u="${u%/}"; u="${u%.git}"
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}
# (GNU stat first: its -f is the file system's status, which takes %m and prints no mtime)
mtime() { local m; m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)"; [[ "$m" =~ ^[0-9]+$ ]] && printf '%s' "$m"; }

# The whole probe is one function, read in full before any of it runs: under `bash -s` the
# script is stdin, which a command reading stdin would otherwise eat (hence </dev/null too).
probe_main() {
  # ---------------------------------------------------------------- the machine
  host="$(uname -n 2>/dev/null || echo -)"; host="${host%%.*}"
  os="$(uname -s 2>/dev/null || echo -)"; osv=-
  if [[ "$os" == Darwin ]] && have sw_vers; then osv="$(sw_vers -productVersion 2>/dev/null || echo -)"
  elif [[ -r /etc/os-release ]]; then osv="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -1)"; fi
  kv probe_schema 1
  kv host "${host:--}"
  kv os "$os" "${osv:--}"
  kv model "$(sysctl_n hw.model || echo -)"
  kv clock "$(date +%s)"

  cores="$(sysctl_n hw.ncpu || true)"
  [[ -n "$cores" ]] || cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  kv cores "$(num_or_dash "$cores")"
  kv cores_perf "$(num_or_dash "$(sysctl_n hw.perflevel0.physicalcpu || true)")"
  kv cores_eff "$(num_or_dash "$(sysctl_n hw.perflevel1.physicalcpu || true)")"

  mem="$(sysctl_n hw.memsize || true)"
  if [[ -z "$mem" && -r /proc/meminfo ]]; then mem="$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)"; fi
  kv mem_bytes "$(num_or_dash "$mem")"

  load="$(sysctl_n vm.loadavg || true)"
  if [[ -n "$load" ]]; then load="$(tr -d '{}' <<<"$load" | awk '{print $1, $2, $3}')"
  elif [[ -r /proc/loadavg ]]; then load="$(awk '{print $1, $2, $3}' /proc/loadavg)"; fi
  # shellcheck disable=SC2086 # three numbers, split on purpose
  set -- $load
  kv load "$(num_or_dash "${1:-}")" "$(num_or_dash "${2:-}")" "$(num_or_dash "${3:-}")"

  # macOS: the kernel's own "how much memory is free" level (what memory_pressure prints).
  free="$(sysctl_n kern.memorystatus_level || true)"
  if [[ -z "$free" && -r /proc/meminfo ]]; then
    free="$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {if (t > 0 && a > 0) printf "%d", a * 100 / t}' /proc/meminfo)"
  fi
  kv mem_free_pct "$(num_or_dash "$free")"

  # Power: the source, and the battery's charge when there is one (a desktop has none).
  src=- pct=-
  if have pmset && batt="$(pmset -g batt 2>/dev/null)"; then
    case "$batt" in *"'AC Power'"*) src=ac ;; *"'Battery Power'"*) src=battery ;; esac
    pct="$(grep -oE '[0-9]+%' <<<"$batt" | head -1 | tr -d %)"
  fi
  kv power "$src"
  kv battery_pct "$(num_or_dash "$pct")"

  # Seconds since the last keyboard or mouse input (HIDIdleTime is in nanoseconds).
  idle=-
  if have ioreg; then idle="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {printf "%d", $NF / 1000000000; exit}')"; fi
  kv hid_idle_s "$(num_or_dash "$idle")"

  # ---------------------------------------------------------------- its budgets (chartroom node init)
  cfgf="${CHARTROOM_NODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/chartroom/node}"
  cfgv() { # <KEY>: the last KEY=VALUE line's value, quotes and a CR stripped
    [[ -f "$cfgf" ]] || return 0
    sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$cfgf" | tail -1 | tr -d '\r' | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
  }
  roots=""
  if [[ -f "$cfgf" ]]; then
    kv initialised 1
    kv config "$cfgf"
    for k in MAX_WORKERS:max_workers CPU_BUDGET:cpu MEM_BUDGET:mem ON_BATTERY:on_battery PRIORITY:priority PROJECT_ROOTS:project_roots ACCEPT:accept; do
      v="$(cfgv "CHARTROOM_NODE_${k%%:*}")"
      kv budget "${k#*:}" "${v:--}"
    done
    roots="$(cfgv CHARTROOM_NODE_PROJECT_ROOTS)"
  else
    kv initialised 0
    kv config "$cfgf"
  fi

  # ---------------------------------------------------------------- its runner core (hc)
  hcb="$(command -v hc 2>/dev/null || true)"
  [[ -z "$hcb" && -x "$HOME/.local/bin/hc" ]] && hcb="$HOME/.local/bin/hc"
  hc_state=none hc_ver=-
  if [[ -n "$hcb" ]]; then
    hc_state=down
    sock="${HC_SOCKET:-}"
    lock="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/${HC_SESSION:-default}/core.lock"
    [[ -z "$sock" && -f "$lock" ]] && sock="$(head -1 "$lock" 2>/dev/null || true)"
    if [[ -n "$sock" && -S "$sock" ]]; then
      if ! have perl || perl -MIO::Socket::UNIX -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 1)' "$sock" 2>/dev/null; then hc_state=up; fi
    fi
    # (asked only of a core that answers: no hc command may be the one that starts a core)
    [[ "$hc_state" != up ]] || hc_ver="$(bounded 10 "$hcb" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  fi
  kv runner hc "$hc_state" "${hc_ver:--}"

  # Agents live on this machine (its own terminals, not a linked machine's machine/t7).
  agents=-
  if [[ "$hc_state" == up ]] && have jq; then
    agents="$(bounded 15 env -u HC_TERMINAL_ID "$hcb" ls --json 2>/dev/null | jq '[.terminals[]? | select((.address | tostring | contains("/")) | not) | select(.state == "live" and .agent != null)] | length' 2>/dev/null || true)"
  fi
  kv agents_live "$(num_or_dash "$agents")"

  # ---------------------------------------------------------------- tools and logins
  if [[ "$hc_state" == up ]]; then
    kv context core
    # (the PATH this probe runs with, so the tools are the ones a launcher from here would find)
    bounded 90 env -u HC_TERMINAL_ID "$hcb" exec --timeout 80 --env "PATH=$PATH" -- /bin/bash -c "$(declare -f checks); checks 1" 2>/dev/null ||
      kv login - unknown "hc exec failed"
  elif [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
    kv context ssh
    checks 0
  else
    kv context shell
    checks 1
  fi

  # ---------------------------------------------------------------- project checkouts
  # git repos at most three levels under the node's project roots (a worktree's .git is a file, so
  # worktrees are not counted), each known by its canonical remote: host/owner/repo, lowercased.
  n=0 want="${CR_PROBE_PROJECT:-}" nowt="$(date +%s)"
  if [[ -n "$roots" ]]; then
    oldifs="$IFS"; IFS=:
    # shellcheck disable=SC2206 # colon-separated on purpose
    dirs=($roots)
    IFS="$oldifs"
    for r in ${dirs[@]+"${dirs[@]}"}; do
      # shellcheck disable=SC2088 # a literal ~ from the config file, expanded here
      case "$r" in "~") r="$HOME" ;; "~/"*) r="$HOME/${r#\~/}" ;; esac
      [[ -d "$r" ]] || continue
      while IFS= read -r g; do
        repo="${g%/.git}"; n=$((n + 1))
        [[ -n "$want" ]] || continue
        url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
        [[ -n "$url" && "$(canon "$url")" == "$want" ]] || continue
        age=-; m="$(mtime "$repo/.git/FETCH_HEAD" || true)"; [[ -n "$m" ]] && age=$((nowt - m))
        kv checkout "$want" "$repo" "$age"
      done < <(find "$r" -mindepth 2 -maxdepth 3 -name .git -type d -prune 2>/dev/null)
    done
    kv checkouts "$n"
  else
    kv checkouts -
  fi
}

probe_main </dev/null
exit 0
