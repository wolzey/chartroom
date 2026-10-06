# shellcheck shell=bash
# dashboard.sh - `chartroom dashboard`: a read-only, loopback-only view of the fleet.
#
# The lanes are computed here, in bash + jq, from the same rows `status` prints
# (status_rows), so the page and the CLI never disagree. lib/dashboard/server.py only
# serves this JSON, the page, and the task files; it never decides what a task means.

CR_DASHBOARD_PORT_DEFAULT=4517
# Task files the server may hand out (anything else is a 404).
CR_DASHBOARD_FILES='brief.md report.md plan.md final.md events.log'

dashboard_pidfile() { printf '%s/.dashboard.pid' "$CR_HOME"; }

# Open inbox.md items as JSON: {waiting:[{date,text}], approvals:[...]}. Same rules as
# inbox_line: bullets under "## Waiting ..." / "## Approvals ...", "(none)" excluded.
dashboard_inbox() {
  local f="$CR_HOME/inbox.md"
  [[ -f "$f" ]] || { echo '{"waiting":[],"approvals":[]}'; return 0; }
  awk '
    /^## / { s = ($0 ~ /^## Waiting/) ? "waiting" : ($0 ~ /^## Approvals/) ? "approvals" : ""; next }
    s != "" && /^- / && $0 !~ /^- \(none\)/ { sub(/^- /, ""); print s "\t" $0 }' "$f" |
    jq -R -s '
      [split("\n")[] | select(length > 0) | split("\t") | {section: .[0], text: (.[1:] | join("\t"))}
       | . + (if (.text | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}"))
              then {date: .text[0:10], text: (.text[10:] | sub("^[\\s—–:-]+"; ""))} else {date: null} end)]
      | {waiting: map(select(.section == "waiting") | del(.section)),
         approvals: map(select(.section == "approvals") | del(.section))}'
}

# Per-task facts the status row lacks: PR/MR links found in events.log and report.md, the
# newest worker-meaningful event, and which task files exist.
dashboard_task_extra() { # <id>
  local d f files=() prs report=""
  d="$(tdir "$1")"
  for f in $CR_DASHBOARD_FILES; do [[ -s "$d/$f" ]] && files+=("$f"); done
  prs="$(cat "$d/events.log" "$d/report.md" 2>/dev/null |
    grep -oE 'https?://[^][ <>()"'"'"'`]+/(pull|pulls|merge_requests|pullrequest)/[0-9]+' | awk '!seen[$0]++' || true)"
  report="$(grep -E '^[^ ]+ (progress|waiting|decision|blocked|done|failed|steered): ' "$d/events.log" 2>/dev/null | tail -1 || true)"
  jq -n --arg prs "$prs" --arg files "${files[*]-}" --arg report "$report" '{
    prs: ($prs | split("\n") | map(select(length > 0))),
    files: ($files | split(" ") | map(select(length > 0))),
    last_event: (if $report == "" then null else ($report[21:]) end),
    last_event_at: (if $report == "" then null else ($report[0:20]) end)}'
}

# The board: status rows + extras + inbox, classified into lanes by lib/dashboard/lanes.jq.
# <pr-states> is an optional JSON file {url: {state, reviewDecision, isDraft}} (the server
# fills it from gh); without it every PR is "unknown" and nothing depends on gh.
dashboard_json() { # [pr-states-file]
  local prs_file="${1:-}" row id rows=() hours
  hours="$(cfg DASHBOARD_RECENT_HOURS '' 48)"
  [[ "$hours" =~ ^[0-9]+$ ]] || die "CHARTROOM_DASHBOARD_RECENT_HOURS must be a whole number of hours"
  while IFS= read -r row; do
    id="$(jq -r .id <<<"$row")"
    rows+=("$(jq -c --argjson x "$(dashboard_task_extra "$id")" '. + $x' <<<"$row")")
  done < <(status_rows --all)
  local prs='{}'
  if [[ -n "$prs_file" && -s "$prs_file" ]]; then prs="$(jq -c 'if type == "object" then . else {} end' "$prs_file" 2>/dev/null || echo '{}')"; fi
  printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -s \
    --argjson inbox "$(dashboard_inbox)" --argjson prs "$prs" --argjson hours "$hours" \
    --arg home "$CR_HOME" --arg version "$CR_VERSION" \
    -f "$CR_ROOT/lib/dashboard/lanes.jq"
}

dashboard_running() { # -> prints "pid port" when a dashboard for this home is up
  local f pid port; f="$(dashboard_pidfile)"
  [[ -f "$f" ]] || return 1
  read -r pid port <"$f" || true
  pid_alive "$pid" || return 1
  # A stale file's pid may now belong to something else (after a reboot): never claim or
  # signal a process that is not this server.
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'dashboard/server\.py' || return 1
  printf '%s %s\n' "$pid" "$port"
}

dashboard_stop() {
  local f pid port i; f="$(dashboard_pidfile)"
  if ! read -r pid port < <(dashboard_running); then
    [[ -f "$f" ]] && rm -f "$f"
    echo "dashboard not running"; return 0
  fi
  kill "$pid" 2>/dev/null || true
  for i in $(seq 1 50); do pid_alive "$pid" || break; sleep 0.1; done
  pid_alive "$pid" && { kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$f"
  echo "dashboard stopped (pid $pid, port $port)"
}

# Does the server on <port> answer /healthz? (python3 is already required to run one.)
dashboard_healthy() { # <port>
  "$(bin_of python3)" - "$1" <<'PY' >/dev/null 2>&1
import sys, urllib.request
with urllib.request.urlopen("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=2) as r:
    sys.exit(0 if r.read().strip() == b"ok" else 1)
PY
}

# `dashboard open`: reuse this home's dashboard when it answers, else start one as a daemon
# (a stale pid file, or a server that stopped answering, is replaced), then open its URL
# with CHARTROOM_OPENER, else `open` (macOS) or `xdg-open`; without any, print it. A lock
# in the home keeps two concurrent calls from starting two servers.
dashboard_open() { # [daemon args...]
  local lock="$CR_HOME/.dashboard.lock" i pid p url opener got=0
  # Without python3 the health check below cannot run, and a healthy server must never be
  # mistaken for a dead one and stopped.
  [[ -n "$(bin_of python3)" ]] || die "the dashboard needs python3 (standard library only); 'chartroom dashboard --json' works without it"
  mkdir -p "$CR_HOME"
  for i in $(seq 1 100); do mkdir "$lock" 2>/dev/null && { got=1; break; }; sleep 0.1; done
  # A lock older than 10s was left by a killed call: take it over.
  [[ $got -eq 1 ]] || warn "taking over a stale $lock"
  trap 'rmdir "'"$lock"'" 2>/dev/null || true' EXIT
  if read -r pid p < <(dashboard_running) && ! dashboard_healthy "$p"; then
    warn "dashboard pid $pid is not answering on port $p; restarting it"
    dashboard_stop >/dev/null
  fi
  if ! read -r pid p < <(dashboard_running); then
    rm -f "$(dashboard_pidfile)"
    ( cmd_dashboard --daemon "$@" ) >&2 || die "dashboard did not start"
    read -r pid p < <(dashboard_running) || die "dashboard did not start"
  fi
  for i in $(seq 1 50); do dashboard_healthy "$p" && break; sleep 0.1; done
  dashboard_healthy "$p" || die "dashboard (pid $pid) is not answering on port $p"
  url="http://127.0.0.1:$p/"
  opener="$(cfg OPENER '' '')"
  if [[ -z "$opener" ]]; then
    if [[ "$(uname -s)" == Darwin && -n "$(bin_of open)" ]]; then opener=open
    elif [[ -n "$(bin_of xdg-open)" ]]; then opener=xdg-open; fi
  fi
  if [[ -n "$opener" ]] && $opener "$url" >/dev/null 2>&1; then echo "dashboard open: $url"
  else echo "dashboard running: $url (no browser opener found; open it yourself)"; fi
}

cmd_dashboard() {
  local port="$CR_DASHBOARD_PORT_DEFAULT" open=0 daemon=0 json=0 prs_file="" gh=1
  case "${1:-}" in
    open) shift; dashboard_open "$@"; return ;;
    stop) dashboard_stop; return ;;
    status)
      local pid p
      if read -r pid p < <(dashboard_running); then echo "dashboard running: http://127.0.0.1:$p (pid $pid)"; else echo "dashboard not running"; return 1; fi
      return ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) [[ $# -ge 2 ]] || die "--port needs a value"; port="$2"; shift 2 ;;
      --open) open=1; shift ;;
      --daemon) daemon=1; shift ;;
      --json) json=1; shift ;;
      --pr-states) [[ $# -ge 2 ]] || die "--pr-states needs a file"; prs_file="$2"; shift 2 ;;
      --no-gh) gh=0; shift ;;
      *) die "dashboard: unknown arg $1 (usage: chartroom dashboard [--port N] [--open] [--daemon] [--no-gh] | open [--port N] [--no-gh] | --json | stop | status)" ;;
    esac
  done
  if [[ $json -eq 1 ]]; then dashboard_json "$prs_file"; return; fi
  [[ "$port" =~ ^[0-9]+$ ]] && (( port <= 65535 )) || die "--port must be 0-65535 (0 picks a free port)"
  local py; py="$(bin_of python3)"
  [[ -n "$py" ]] || die "the dashboard needs python3 (standard library only); 'chartroom dashboard --json' works without it"
  local pid p
  if read -r pid p < <(dashboard_running); then
    die "a dashboard for $CR_HOME is already running: http://127.0.0.1:$p (pid $pid); 'chartroom dashboard stop' first"
  fi
  mkdir -p "$CR_HOME"
  local args=("$CR_ROOT/lib/dashboard/server.py" --port "$port" --pidfile "$(dashboard_pidfile)" --bin "$CR_BIN")
  [[ $open -eq 1 ]] && args+=(--open)
  [[ $gh -eq 0 ]] && args+=(--no-gh)
  export CHARTROOM_HOME="$CR_HOME"
  if [[ $daemon -eq 0 ]]; then exec "$py" "${args[@]}"; fi
  local log="$CR_HOME/.dashboard.log" i
  nohup "$py" "${args[@]}" >"$log" 2>&1 </dev/null &
  local child=$!
  for i in $(seq 1 100); do
    if read -r pid p < <(dashboard_running) && [[ "$pid" == "$child" ]]; then
      echo "dashboard running: http://127.0.0.1:$p (pid $pid; log $log; stop with: chartroom dashboard stop)"
      return 0
    fi
    pid_alive "$child" || break
    sleep 0.1
  done
  tail -n 20 "$log" >&2 2>/dev/null || true
  pid_alive "$child" && kill "$child" 2>/dev/null
  die "dashboard did not start"
}
