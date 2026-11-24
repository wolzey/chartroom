#!/usr/bin/env bash
# shellcheck shell=bash
# cpuload.sh <file> <pid> - how busy this machine's CPUs really are, kept in <file> for as long as
# process <pid> lives: one line, "<epoch> <percent> <seconds>", the share of all cores' time spent
# busy (user and system) over the last <seconds> (up to 60), rewritten every 5 s. A device's agent
# (lib/device.sh) and the brain's app server (lib/app/server.py) each run one; lib/nodeprobe.sh
# reads the file, and placement (lib/place.sh) goes by it.
#
# It is the kernel's own busy/idle tick counters over a window (macOS: `iostat -w`, whose rows after
# the first are the counters' change since the last row; Linux: /proc/stat). The load average is
# not used: it counts threads that wait, not CPU time, lags by minutes, and on a Mac mixes fast and
# slow cores. A minute's average, because a worker's CPU use comes in bursts.
#
# bash 3.2 (a Mac's /bin/bash). Ends by itself within one row of <pid> ending.

set -u
file="${1:?usage: cpuload.sh <file> <pid>}"; parent="${2:?usage: cpuload.sh <file> <pid>}"
every="${CR_CPU_EVERY:-5}"; keep=12

# Rows of "user system idle", the first of them since boot (skipped below).
rows() {
  if sysctl -n hw.ncpu >/dev/null 2>&1; then exec iostat -n 0 -w "$every"; fi
  local busy=0 total=0 b t
  while [[ -r /proc/stat ]]; do
    read -r b t < <(awk '/^cpu / { t = 0; for (i = 2; i <= 9; i++) t += $i; print t - $5 - $6, t; exit }' /proc/stat)
    if (( t > total )); then awk -v b=$((b - busy)) -v t=$((t - total)) 'BEGIN { u = b * 100 / t; printf "%.0f 0 %.0f\n", u, 100 - u }'; fi
    busy=$b; total=$t
    sleep "$every"
  done
}

mkdir -p "$(dirname "$file")"
rows 2>/dev/null </dev/null | {
  n=0 ring=""
  while read -r us sy id _; do
    case "$us$sy$id" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$parent" 2>/dev/null || exit 0
    n=$((n + 1)); (( n > 1 )) || continue
    ring="$ring $((100 - id))"
    # shellcheck disable=SC2086 # the kept rows, one word each
    set -- $ring
    while (( $# > keep )); do shift; done
    ring="$*"; sum=0
    for v in "$@"; do sum=$((sum + v)); done
    printf '%s %s %s\n' "$(date +%s)" "$(( (sum + $# / 2) / $# ))" "$(( $# * every ))" >"$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"
  done
}
