# shellcheck shell=bash
# dashboard.sh - `chartroom dashboard`: a read-only, loopback-only view of the fleet.
#
# The lanes are computed here, in bash + jq, from the same rows `status` prints
# (status_rows), so the page and the CLI never disagree. lib/dashboard/server.py only
# serves this JSON, the page, and the task files; it never decides what a task means.

CR_DASHBOARD_PORT_DEFAULT=4517
CR_DASHBOARD_THEMES='chartroom hud' # the page's themes (lib/dashboard/index.html and server.py list the same)
# Task files the server may hand out (anything else is a 404).
CR_DASHBOARD_FILES='brief.md report.md plan.md final.md events.log'

dashboard_pidfile() { printf '%s/.dashboard.pid' "$CR_HOME"; }

# The dashboard's python as an argv prefix, in CR_PY (empty when there is none). Git Bash
# rarely has a python3 (python.org installs python and py), and the Microsoft Store's
# python3.exe stub is on PATH but only opens the Store, so there a candidate must run.
CR_PY=()
find_python() {
  local c b try
  CR_PY=()
  if [[ "$CR_PLATFORM" != msys ]]; then
    b="$(bin_of python3)"; [[ -n "$b" ]] && CR_PY=("$b"); return 0
  fi
  for c in python3 python py; do
    b="$(bin_of "$c")"; [[ -n "$b" ]] || continue
    try=("$b"); [[ "$c" == py ]] && try+=(-3)
    if "${try[@]}" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then CR_PY=("${try[@]}"); return 0; fi
  done
  return 0
}
python_missing() {
  if [[ "$CR_PLATFORM" == msys ]]; then
    echo "the dashboard needs python 3.8+ (a python3, python or py -3 that runs; the Microsoft Store stub does not count); 'chartroom dashboard --json' works without it"
  else echo "the dashboard needs python3 (standard library only); 'chartroom dashboard --json' works without it"; fi
}

# Git Bash: a Windows process's command line (empty when there is no such process).
win_cmdline() { # <windows pid>
  powershell.exe -NoProfile -NonInteractive -Command "(Get-CimInstance Win32_Process -Filter 'ProcessId=$1').CommandLine" 2>/dev/null || true
}

# Open inbox.md items as JSON: {waiting:[{short_id,date,text}], approvals:[...]}. Same rules
# as inbox_line: bullets under "## Waiting ..." / "## Approvals ...", "(none)" excluded.
# short_id is the item's "[i-xxxx]" tag (null when untagged), split off the text.
dashboard_inbox() {
  local f="$CR_HOME/inbox.md"
  [[ -f "$f" ]] || { echo '{"waiting":[],"approvals":[]}'; return 0; }
  awk '
    /^## / { s = ($0 ~ /^## Waiting/) ? "waiting" : ($0 ~ /^## Approvals/) ? "approvals" : ""; next }
    s != "" && /^- / && $0 !~ /^- \(none\)/ { sub(/^- /, ""); print s "\t" $0 }' "$f" |
    jq -R -s '
      [split("\n")[] | select(length > 0) | split("\t") | {section: .[0], text: (.[1:] | join("\t"))}
       | ([.text | capture("^\\[(?<id>i-[0-9a-f]{4,})\\] +(?<rest>.*)$")] | first) as $tag
       | if $tag then .short_id = $tag.id | .text = $tag.rest else .short_id = null end
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
  # A stale file's pid may now belong to something else (after a reboot): never claim or
  # signal a process that is not this server.
  if [[ "$CR_PLATFORM" == msys ]]; then
    # Native python wrote its Windows pid, which kill -0 and Git Bash's ps cannot see.
    port="${port%$'\r'}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    win_cmdline "$pid" | grep -qE 'dashboard[/\\]server\.py' || return 1
  else
    pid_alive "$pid" || return 1
    ps -p "$pid" -o command= 2>/dev/null | grep -q 'dashboard/server\.py' || return 1
  fi
  printf '%s %s\n' "$pid" "$port"
}

dashboard_stop() {
  local f pid port i; f="$(dashboard_pidfile)"
  if ! read -r pid port < <(dashboard_running); then
    [[ -f "$f" ]] && rm -f "$f"
    echo "dashboard not running"; return 0
  fi
  if [[ "$CR_PLATFORM" == msys ]]; then taskkill //F //PID "$pid" >/dev/null 2>&1 || true
  else
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 50); do pid_alive "$pid" || break; sleep 0.1; done
    pid_alive "$pid" && { kill -9 "$pid" 2>/dev/null || true; }
  fi
  rm -f "$f"
  echo "dashboard stopped (pid $pid, port $port)"
}

# Does the server on <port> answer /healthz? (python3 is already required to run one.)
dashboard_healthy() { # <port>
  "${CR_PY[@]}" - "$1" <<'PY' >/dev/null 2>&1
import sys, urllib.request
with urllib.request.urlopen("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=2) as r:
    sys.exit(0 if r.read().strip() == b"ok" else 1)
PY
}

# `dashboard open`: reuse this home's dashboard when it answers, else start one as a daemon
# (a stale pid file, or a server that stopped answering, is replaced), then open its URL
# with CHARTROOM_OPENER, else `open` (macOS) or `xdg-open`, else on WSL `wslview` or
# PowerShell's Start-Process and on Git Bash `start`; without any, print it. A lock
# in the home keeps two concurrent calls from starting two servers.
dashboard_open() { # [daemon args...]
  local lock="$CR_HOME/.dashboard.lock" i pid p url opener owner
  # Without python3 the health check below cannot run, and a healthy server must never be
  # mistaken for a dead one and stopped.
  find_python
  [[ ${#CR_PY[@]} -gt 0 ]] || die "$(python_missing)"
  mkdir -p "$CR_HOME"
  # The lock holds its owner's pid. A lock whose owner is gone was left by a killed call and
  # is taken over; a live owner is waited for (up to 60s), never robbed.
  for i in $(seq 1 600); do
    if mkdir "$lock" 2>/dev/null; then echo $$ >"$lock/pid"; break; fi
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! pid_alive "$owner"; then
      warn "taking over $lock from a call that is gone (pid $owner)"; rm -rf "$lock"; continue
    fi
    sleep 0.1
  done
  [[ "$(cat "$lock/pid" 2>/dev/null)" == "$$" ]] || die "another 'dashboard open' still holds $lock"
  trap '[[ "$(cat "'"$lock"'/pid" 2>/dev/null)" == "'"$$"'" ]] && rm -rf "'"$lock"'"' EXIT
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
    elif [[ -n "$(bin_of xdg-open)" ]]; then opener=xdg-open
    elif [[ "$CR_PLATFORM" == wsl && -n "$(bin_of wslview)" ]]; then opener=wslview
    elif [[ "$CR_PLATFORM" == wsl && -n "$(bin_of powershell.exe)" ]]; then opener=open_url_powershell
    elif [[ "$CR_PLATFORM" == msys ]]; then opener=open_url_start; fi
  fi
  if [[ -n "$opener" ]] && $opener "$url" >/dev/null 2>&1; then echo "dashboard open: $url"
  else echo "dashboard running: $url (no browser opener found; open it yourself)"; fi
}

# Windows browser openers (the URL is always http://127.0.0.1:<port>/).
open_url_powershell() { powershell.exe -NoProfile -NonInteractive -Command "Start-Process '$1'"; }
open_url_start() { cmd //c start "" "$1"; }

cmd_dashboard() {
  local port="$CR_DASHBOARD_PORT_DEFAULT" open=0 daemon=0 json=0 prs_file="" gh=1 theme
  theme="$(cfg DASHBOARD_THEME '' chartroom)"
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
      --theme) [[ $# -ge 2 ]] || die "--theme needs a value ($CR_DASHBOARD_THEMES)"; theme="$2"; shift 2 ;;
      *) die "dashboard: unknown arg $1 (usage: chartroom dashboard [--port N] [--open] [--daemon] [--no-gh] [--theme NAME] | open [--port N] [--no-gh] [--theme NAME] | --json | stop | status)" ;;
    esac
  done
  if [[ $json -eq 1 ]]; then dashboard_json "$prs_file"; return; fi
  [[ "$port" =~ ^[0-9]+$ ]] && (( port <= 65535 )) || die "--port must be 0-65535 (0 picks a free port)"
  [[ " $CR_DASHBOARD_THEMES " == *" $theme "* ]] || die "unknown dashboard theme '$theme' (themes: $CR_DASHBOARD_THEMES; set with --theme or CHARTROOM_DASHBOARD_THEME)"
  find_python
  [[ ${#CR_PY[@]} -gt 0 ]] || die "$(python_missing)"
  local pid p
  if read -r pid p < <(dashboard_running); then
    die "a dashboard for $CR_HOME is already running: http://127.0.0.1:$p (pid $pid); 'chartroom dashboard stop' first"
  fi
  mkdir -p "$CR_HOME"
  # Paths in Windows form for a native python on Git Bash (unchanged elsewhere), which also
  # cannot run bin/chartroom, a bash script, without being handed bash.
  local args=("$(win_path "$CR_ROOT/lib/dashboard/server.py")" --port "$port" --pidfile "$(win_path "$(dashboard_pidfile)")" --bin "$(win_path "$CR_BIN")")
  # (Git Bash's own bash.exe: $BASH may be a wrapper script, which python cannot run either.)
  if [[ "$CR_PLATFORM" == msys ]]; then
    local b="$BASH"; [[ -e /usr/bin/bash.exe ]] && b=/usr/bin/bash.exe
    args+=(--bash "$(win_path "$b")")
  fi
  [[ $open -eq 1 ]] && args+=(--open)
  [[ $gh -eq 0 ]] && args+=(--no-gh)
  args+=(--theme "$theme")
  CHARTROOM_HOME="$(win_path "$CR_HOME")"; export CHARTROOM_HOME
  if [[ $daemon -eq 0 ]]; then exec "${CR_PY[@]}" "${args[@]}"; fi
  local log="$CR_HOME/.dashboard.log" i
  nohup "${CR_PY[@]}" "${args[@]}" >"$log" 2>&1 </dev/null &
  local child=$!
  for i in $(seq 1 100); do
    # On Git Bash $! is an MSYS pid and the pid file holds python's Windows pid.
    if read -r pid p < <(dashboard_running) && [[ "$pid" == "$child" || "$CR_PLATFORM" == msys ]]; then
      echo "dashboard running: http://127.0.0.1:$p (pid $pid; log $log; stop with: chartroom dashboard stop)"
      return 0
    fi
    [[ "$CR_PLATFORM" == msys ]] || pid_alive "$child" || break
    sleep 0.1
  done
  tail -n 20 "$log" >&2 2>/dev/null || true
  pid_alive "$child" && kill "$child" 2>/dev/null
  die "dashboard did not start"
}

# `chartroom board`: the dashboard's lanes in the terminal, from the same dashboard_json, so
# the two never disagree. One line per item: short id, title, state, a snippet of the last
# event. Color only when stdout is a terminal (and NO_COLOR is unset); --json is the lanes JSON.
cmd_board() {
  local json=0 color=0 a
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && color=1
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --color) color=1 ;;
      --no-color) color=0 ;;
      *) die "board: unknown arg $a (usage: chartroom board [--json] [--color|--no-color])" ;;
    esac
  done
  if [[ $json -eq 1 ]]; then dashboard_json; return; fi
  dashboard_json | jq -r --argjson color "$color" '
    def c($code): if $color == 1 then "\u001b[" + $code + "m" + . + "\u001b[0m" else . end;
    def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
    def pad($n): . + (" " * ([$n - length, 0] | max));
    [["needs_you", "Needs you", "1;31"], ["in_progress", "In progress", "1;36"], ["on_hold", "On hold", "1;33"],
     ["ready", "Ready for you", "1;32"], ["recent", "Recently finished", "1;90"]] as $lanes
    | . as $b
    | ([$b.lanes[][] | (.short_id // "-") | length] | max // 4) as $w
    | $lanes[] as [$k, $name, $col]
    | ($b.lanes[$k] // []) as $items
    | ("\($name) (\($items | length))" | c($col)),
      (if ($items | length) == 0 then "  none" | c("2")
       else $items[]
         | ((.short_id // "-") | pad($w) | c("1")) + "  " + ((.title // .id) | cut(60))
           + "  " + ("[" + (.reason // .state // "") + "]" | c("2"))
           + (if .type == "inbox" then (if .date then "  since " + .date else "" end)
              elif .waiting_on then "  waiting on: " + (.waiting_on | cut(60))
              elif .last_event then "  " + (.last_event | gsub("\n"; " ") | cut(70)) else "" end)
         | "  " + . end),
      ""'
}
