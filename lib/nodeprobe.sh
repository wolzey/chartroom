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
# Tools are checked on the PATH a worker would get: the user's interactive login shell's
# ($SHELL -lic, as lib/core.sh login_path reads it: mise, asdf and the like are set up only
# there), read from chartroom's 10-minute cache when it is fresh, else asked here (bounded at
# 10 s; the probe itself writes nothing, though the shell's rc files run as in a new terminal). CHARTROOM_LOGIN_SHELL names another shell, or "none"
# to keep the probe's own PATH. `path_source` says which: login or inherited.
#
# Logins are checked where a worker would run. A Mac's login keychain is closed to an ssh
# session, so claude, codex and gh read as logged out there even when they are not: with an hc
# core answering, the checks run inside it (`hc exec`, a core started in the login session, given
# this probe's PATH); without one, they run here unless this is an ssh session, where they read
# `unknown`.
#
# Lines (a value of "-" is unknown):
#   probe_schema 1 | host H | os NAME VERSION | model M | clock EPOCH
#   cores N | cores_perf N | cores_eff N | mem_bytes N | load L1 L5 L15 | mem_free_pct N | disk_free_pct N
#   cpu_use PCT SECONDS   (the share of all cores' time spent busy over that window: lib/cpuload.sh's
#                          minute when one runs here, else this probe's own few seconds)
#   mem_used_pct N        (what Activity Monitor calls Memory Used, over all memory: app memory, wired
#                          and compressed; not the kernel's pressure level, which is mem_free_pct)
#   power ac|battery|- | battery_pct N | hid_idle_s N
#   initialised 0|1 | config PATH | budget KEY VALUE (cpu mem on_battery priority project_roots accept)
#   runner hc up|down|none VERSION | context core|shell|ssh | agents_live N
#   crew_live N | other_agents N   (hc terminals here that carry chartroom.task, and the other
#                                   agents: an XO, a session chartroom did not start; "-" on an hc
#                                   without an event stream, where agents_live is all there is)
#   agent crew|xo|other ADDRESS STATE NAME WHERE   (each of those, at most 80: a crew worker by its
#                                   task; an agent whose directory is a chartroom home as the XO of
#                                   it; any other by its directory's name. WHERE is the workspace and
#                                   tab a person sees it in. No title, message or path is sent.)
#   path_source login|inherited
#   tool NAME ok|old|down|missing|error VERSION-OR-WHY  (error: the binary and its first line)
#   login NAME ok|no|unknown|missing DETAIL
#   checkouts N | checkout CANONICAL-REMOTE PATH FETCH-AGE-SECONDS  (the latter only for $CR_PROBE_PROJECT,
#                          or every one, its age not read, with CR_PROBE_CHECKOUTS=1)
# Settings it reads: CHARTROOM_NODE_CONFIG (default ${XDG_CONFIG_HOME:-~/.config}/chartroom/node),
# CR_PROBE_PROJECT (a canonical remote, host/owner/repo, to look for among the checkouts),
# CR_PROBE_CHECKOUTS=1 (list them all), CR_PROBE_SAMPLE (seconds its own CPU sample takes, 3), and
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
  # Why a tool failed: its binary and the first line it printed (a broken install says why, such
  # as a library dyld cannot load), else its exit status.
  ck_why() { # <binary> <output> <rc>
    local l; l="$(printf '%s\n' "$2" | tr '\t' ' ' | grep -v '^[[:space:]]*$' | head -1 | cut -c1-200)"
    printf '%s: %s' "$1" "${l:-exited $3 with no output}"
  }
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
      ruby) rc=0; out="$(ck_run 10 "$b" -e 'print RUBY_VERSION' 2>&1)" || rc=$?
        if [[ $rc -eq 0 && -n "$out" ]]; then ck_kv tool ruby ok "$out"; else ck_kv tool ruby error "$(ck_why "$b" "$out" "$rc")"; fi ;;
      go) rc=0; out="$(ck_run 10 "$b" version 2>&1)" || rc=$?; v="$(ck_ver <<<"$out")"
        if [[ $rc -eq 0 && -n "$v" ]]; then ck_kv tool go ok "$v"; else ck_kv tool go error "$(ck_why "$b" "$out" "$rc")"; fi ;;
      tmux) v="$(ck_run 10 "$b" -V 2>/dev/null | ck_ver)"; ck_kv tool tmux ok "${v:--}" ;;
      chartroom) v="$(ck_run 10 "$b" version 2>/dev/null | ck_ver)"; ck_kv tool chartroom ok "${v:--}" ;;
      *) rc=0; out="$(ck_run 10 "$b" --version 2>&1)" || rc=$?; v="$(ck_ver <<<"$out")"
        if [[ $rc -eq 0 && -n "$v" ]]; then ck_kv tool "$t" ok "$v"; else ck_kv tool "$t" error "$(ck_why "$b" "$out" "$rc")"; fi ;;
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

# The login shell's PATH (see the header), or nothing.
login_path_probe() {
  local sh="${CHARTROOM_LOGIN_SHELL:-${SHELL:-}}" f out p
  [[ -n "$sh" && "$sh" != none && -x "$sh" ]] || return 0
  f="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/login-path"
  if [[ -f "$f" && -n "$(find "$f" -mmin -10 2>/dev/null)" ]]; then cat "$f"; return 0; fi
  out="$(bounded 10 "$sh" -lic 'printf "\036%s\036" "$PATH"' </dev/null 2>/dev/null || true)"
  p="${out#*$'\036'}"; [[ "$p" != "$out" ]] || return 0
  p="${p%%$'\036'*}"
  case "$p" in /*) ;; *) return 0 ;; esac
  case "$p" in *$'\n'*) return 0 ;; esac
  printf '%s' "$p"
}

# The first line of a command's output, then the command ended (for `hc events`, a stream that
# never ends on its own): at most <seconds>.
first_line() { # <seconds> <cmd...>
  local s="$1"; shift
  have perl || return 1
  perl -e 'my $s = shift; my $pid = open(my $fh, "-|", @ARGV) or exit 127;
    local $SIG{ALRM} = sub { kill "TERM", $pid; exit 1 }; alarm $s;
    my $l = <$fh>; kill "TERM", $pid; print $l if defined $l; exit 0' "$s" "$@"
}

# How busy the CPUs are, "<percent> <seconds>": the minute lib/cpuload.sh keeps here when it is
# fresh, else a sample of our own (the second row of iostat, the first being since boot).
cpu_use() {
  local f at pct secs s="${CR_PROBE_SAMPLE:-3}" a b
  f="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/node/cpu"
  if [[ -f "$f" ]] && read -r at pct secs <"$f"; then
    case "$at$pct$secs" in ''|*[!0-9]*) ;; *) if (( $(date +%s) - at <= 30 )); then echo "$pct $secs"; return 0; fi ;; esac
  fi
  if have iostat && sysctl_n hw.ncpu >/dev/null; then
    bounded $((s + 5)) iostat -n 0 -w "$s" -c 2 2>/dev/null | awk -v s="$s" '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { n++; id = $3 } END { if (n > 1) print 100 - id, s }'
  elif [[ -r /proc/stat ]]; then
    a="$(awk '/^cpu / { t = 0; for (i = 2; i <= 9; i++) t += $i; print t - $5 - $6, t; exit }' /proc/stat)"; sleep "$s"
    b="$(awk '/^cpu / { t = 0; for (i = 2; i <= 9; i++) t += $i; print t - $5 - $6, t; exit }' /proc/stat)"
    awk -v a="$a" -v b="$b" -v s="$s" 'BEGIN { split(a, x, " "); split(b, y, " "); if (y[2] > x[2]) printf "%.0f %s\n", (y[1] - x[1]) * 100 / (y[2] - x[2]), s }'
  fi
}

# Memory used, in percent of all of it (see the header).
mem_used_pct() { # <mem bytes>
  if have vm_stat && [[ "$1" =~ ^[0-9]+$ ]]; then
    vm_stat 2>/dev/null | awk -v m="$1" '
      /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
      { v = $NF; sub(/\.$/, "", v) }
      /^Anonymous pages:/ { a = v } /^Pages purgeable:/ { p = v } /^Pages wired down:/ { w = v } /^Pages occupied by compressor:/ { c = v }
      END { if (ps > 0 && a != "" && w != "" && m > 0) printf "%.0f", (a - p + w + c) * ps * 100 / m }'
  elif [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t > 0 && a > 0) printf "%.0f", (t - a) * 100 / t }' /proc/meminfo
  fi
}

# The whole probe is one function, read in full before any of it runs: under `bash -s` the
# script is stdin, which a command reading stdin would otherwise eat (hence </dev/null too).
probe_main() {
  exec 9< <(cpu_use) # (its sample, if it takes one, runs while the rest is read)
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
  kv mem_used_pct "$(num_or_dash "$(mem_used_pct "$mem")")"

  # Disk: the share free on the volume that holds the home directory (worktrees and homes live there).
  free="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 && ($3 + $4) > 0 {printf "%d", $4 * 100 / ($3 + $4)}')"
  kv disk_free_pct "$(num_or_dash "$free")"

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
    for k in CPU_BUDGET:cpu MEM_BUDGET:mem ON_BATTERY:on_battery PRIORITY:priority PROJECT_ROOTS:project_roots ACCEPT:accept; do
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

  # The crew among them: terminals carrying chartroom.task (hc ls shows no labels; the first
  # frame of hc's event stream does). The rest are other agents: an XO, a person's own session.
  crew=- others=- named=""
  if [[ "$hc_state" == up ]] && have jq; then
    frame="$(first_line 10 env -u HC_TERMINAL_ID "$hcb" events --json 2>/dev/null || true)"
    if [[ -n "$frame" ]]; then
      counts="$(jq -r 'select((.terminals | type) == "array") | [.terminals[] | select((.address | tostring | contains("/")) | not) | select(.state == "live")]
        | [(map(select((.labels // {})["chartroom.task"] != null)) | length),
           (map(select((.labels // {})["chartroom.task"] == null and ((.status // {}).app // null) != null)) | length)] | @tsv' <<<"$frame" 2>/dev/null || true)"
      if [[ -n "$counts" ]]; then crew="${counts%%$'\t'*}"; others="${counts#*$'\t'}"; fi
      # (no field is empty: a tab-separated read would close the gap)
      named="$(jq -r 'select((.terminals | type) == "array")
        | def f($n): if . == null then "-" else tostring | gsub("[[:cntrl:]]"; " ") | .[0:$n] | if test("^ *$") then "-" else . end end;
        [.terminals[] | select((.address | tostring | contains("/")) | not) | select(.state == "live")
          | (.labels // {}) as $l | $l["chartroom.task"] as $t | select($t != null or ((.status // {}).app // null) != null)
          | ((.foreground // {}).cwd // .cwd // null) as $d
          | [(if $t then "crew" else "other" end), (.address | f(40)), ((.status // {}).state | f(20)), (if $t then $t | f(80) else "-" end),
             (if $t then "-" else $l.where | f(120) end), (if $t then "-" else $d | f(1000) end)]]
        | .[0:80][] | join("\t")' <<<"$frame" 2>/dev/null || true)"
    fi
  fi
  kv crew_live "$(num_or_dash "$crew")"
  kv other_agents "$(num_or_dash "$others")"
  while IFS=$'\t' read -r a_kind a_addr a_state a_name a_where a_dir; do
    [[ -n "$a_kind" ]] || continue
    if [[ "$a_kind" == other && "$a_dir" == /* ]]; then
      a_name="${a_dir%/}"; a_name="${a_name##*/}"; a_name="${a_name#.}"
      # a chartroom home (chartroom init): its agent is that home's XO. Never looked for where macOS
      # asks the person before a program may look, nor on a volume that may be away.
      case "$a_dir" in
        "$HOME"/Documents*|"$HOME"/Desktop*|"$HOME"/Downloads*|"$HOME"/Library/*|/Volumes/*|/Network/*) ;;
        *) if [[ -d "$a_dir/tasks" ]] && [[ -f "$a_dir/commander.md" || -f "$a_dir/captain.md" ]]; then a_kind=xo; fi ;;
      esac
      [[ "$a_dir" != "$HOME" && -n "$a_name" ]] || a_name=-
    fi
    kv agent "$a_kind" "$a_addr" "$a_state" "$a_name" "$a_where"
  done <<<"$named"

  # ---------------------------------------------------------------- tools and logins
  # (on the login shell's PATH when there is one: the tools a worker launched here would run)
  lp="$(login_path_probe)"
  if [[ -n "$lp" ]]; then kv path_source login; else kv path_source inherited; lp="$PATH"; fi
  if [[ "$hc_state" == up ]]; then
    kv context core
    bounded 90 env -u HC_TERMINAL_ID "$hcb" exec --timeout 80 --env "PATH=$lp" -- /bin/bash -c "$(declare -f checks); checks 1" 2>/dev/null ||
      kv login - unknown "hc exec failed"
  elif [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
    kv context ssh
    ( PATH="$lp"; checks 0 )
  else
    kv context shell
    ( PATH="$lp"; checks 1 )
  fi

  # ---------------------------------------------------------------- project checkouts
  # git repos at most three levels under the node's project roots (a worktree's .git is a file, so
  # worktrees are not counted), each known by its canonical remote: host/owner/repo, lowercased.
  n=0 want="${CR_PROBE_PROJECT:-}" nowt="$(date +%s)"
  if [[ -n "$roots" ]]; then
    all=()
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
        [[ "${CR_PROBE_CHECKOUTS:-}" != 1 ]] || all[${#all[@]}]="$g/config"
        [[ -n "$want" ]] || continue
        url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
        [[ -n "$url" && "$(canon "$url")" == "$want" ]] || continue
        age=-; m="$(mtime "$repo/.git/FETCH_HEAD" || true)"; [[ -n "$m" ]] && age=$((nowt - m))
        kv checkout "$want" "$repo" "$age"
      done < <(find "$r" -mindepth 2 -maxdepth 3 -name .git -type d -prune 2>/dev/null)
    done
    kv checkouts "$n"
    # (every one, from its config files read in one go: too many to ask git of each, every 15 s)
    if (( ${#all[@]} > 0 )); then
      awk 'FNR == 1 { o = 0; done = 0 } /^[[:space:]]*\[/ { o = ($0 ~ /^[[:space:]]*\[remote "origin"\]/) }
        o && !done && $1 == "url" { p = FILENAME; sub(/\/\.git\/config$/, "", p); sub(/^[[:space:]]*url[[:space:]]*=[[:space:]]*/, ""); done = 1; print $0 "\t" p }' "${all[@]}" 2>/dev/null |
        while IFS=$'\t' read -r url repo; do kv checkout "$(canon "$url")" "$repo" -; done
    fi
  else
    kv checkouts -
  fi

  cpu="" secs=""; IFS=' ' read -r cpu secs <&9 || true; exec 9<&-
  kv cpu_use "$(num_or_dash "$cpu")" "$(num_or_dash "$secs")"
}

probe_main </dev/null
exit 0
