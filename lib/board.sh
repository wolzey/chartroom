# shellcheck shell=bash
# board.sh - the board: every task and inbox item in five lanes (lib/lanes.jq), built in bash + jq
# from the same rows `status` prints (status_rows), so the views never disagree. `chartroom board`
# prints it in the terminal; `board --json` is what the crew views (mods/) poll. The app (lib/app.sh,
# app/) is the commander's web view, and `chartroom dashboard` opens it. The old web dashboard (its
# server and pages) is retired: `dashboard stop` and `sweep` still end one left running from before.

# Task files the views read (anything else is not handed out).
CR_TASK_FILES='brief.md report.md plan.md final.md events.log'

# python3 as an argv prefix, in CR_PY (empty when there is none): the app's server and page PDFs.
CR_PY=()
find_python() {
  local b
  CR_PY=()
  b="$(bin_of python3)"; [[ -n "$b" ]] && CR_PY=("$b")
  return 0
}

# Open inbox.md items as JSON: {waiting:[{short_id,date,project,text}], approvals:[...]}. Same
# rules as inbox_line: bullets under "## Waiting ..." / "## Approvals ...", "(none)" excluded.
# short_id is the item's "[i-xxxx]" tag (null when untagged), split off the text; project is
# the "[project]" label after the date (null on an unlabelled line), split off the same way:
#   - [i-7f3a] 2026-01-02 — [webapp] which region for staging?
# Waiting items carry focus mode's in_focus/held marks (lib/focus.sh); a text starting with
# "[breaking] " (inbox add --breaking) is never held.
# Inbox items born in the store (lib/store.sh) come after inbox.md's, and an item marked removed
# or done (lib/marks.sh) is left out.
inbox_items_json() {
  local f="$CR_HOME/inbox.md" store='[]' marks='{}'
  if store_load; then
    [[ -s "$STORE_D/.inbox.json" ]] && store="$(cat "$STORE_D/.inbox.json")"
    [[ -s "$STORE_D/.marks.json" ]] && marks="$(jq -c '.inbox' "$STORE_D/.marks.json")"
  fi
  [[ -f "$f" || "$store" != '[]' ]] || { echo '{"waiting":[],"approvals":[]}'; return 0; }
  { [[ ! -f "$f" ]] || awk '
    /^## / { s = ($0 ~ /^## Waiting/) ? "waiting" : ($0 ~ /^## Approvals/) ? "approvals" : ""; next }
    s != "" && /^- / && $0 !~ /^- \(none\)/ { sub(/^- /, ""); print s "\t" $0 }' "$f"; } |
    jq -R -s --argjson focus "$(focus_json)" --argjson store "$store" --argjson marks "$marks" "$FOCUS_JQ"'
      [(split("\n")[] | select(length > 0) | split("\t") | {section: .[0], text: (.[1:] | join("\t"))}
       | ([.text | capture("^\\[(?<id>i-[0-9a-f]{4,})\\] +(?<rest>.*)$")] | first) as $tag
       | if $tag then .short_id = $tag.id | .text = $tag.rest else .short_id = null end
       | . + (if (.text | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}"))
              then {date: .text[0:10], text: (.text[10:] | sub("^[\\s—–:-]+"; ""))} else {date: null} end)
       | ([.text | capture("^\\[(?<p>[^\\]]+)\\] +(?<rest>.*)$")] | first) as $proj
       | if $proj and $proj.p != "breaking" then .project = $proj.p | .text = $proj.rest else .project = null end),
       ($store[] | {section, text, short_id: .id, date, project})
       | select(.short_id == null or (($marks[.short_id] // {}) as $m | $m.removed == null and $m.done == null))]
      | {waiting: map(select(.section == "waiting") | del(.section) | . + focus_marks($focus; "inbox"; .text | startswith("[breaking] "))),
         approvals: map(select(.section == "approvals") | del(.section))}'
}

# Per-task facts the status row lacks: PR/MR links found in events.log and report.md, the
# newest worker-meaningful event, and which task files exist.
task_extra_json() { # <id>
  local d f files=() prs report=""
  d="$(tdir "$1")"; events_path "$1"
  for f in $CR_TASK_FILES; do [[ -s "$d/$f" ]] && files+=("$f"); done
  # A store task's events.log is its rendering (lib/store.sh); the server serves it from the store.
  [[ "$EVENTS_PATH" == "$d/events.log" || ! -s "$EVENTS_PATH" ]] || files+=(events.log)
  prs="$(cat "$EVENTS_PATH" "$d/report.md" 2>/dev/null |
    grep -oE 'https?://[^][ <>()"'"'"'`]+/(pull|pulls|merge_requests|pullrequest)/[0-9]+' | awk '!seen[$0]++' || true)"
  report="$(grep -E '^[^ ]+ (progress|waiting|decision|blocked|done|failed|steered): ' "$EVENTS_PATH" 2>/dev/null | tail -1 || true)"
  jq -n --arg prs "$prs" --arg files "${files[*]-}" --arg report "$report" '{
    prs: ($prs | split("\n") | map(select(length > 0))),
    files: ($files | split(" ") | map(select(length > 0))),
    last_event: (if $report == "" then null else ($report[21:]) end),
    last_event_at: (if $report == "" then null else ($report[0:20]) end)}'
}

# The board: status rows + extras + inbox (with the open relays from other homes) + open artifacts, classified into lanes by
# lib/lanes.jq, plus the commander's next steps (.todo, lib/todo.jq). <pr-states> is an optional
# JSON file {url: {state, reviewDecision, isDraft}}; without it every PR is "unknown" and nothing
# depends on gh.
board_json() { # [pr-states-file]
  local prs_file="${1:-}" row id rows=() hours arts since
  hours="$(cfg DASHBOARD_RECENT_HOURS '' 48)"
  [[ "$hours" =~ ^[0-9]+$ ]] || die "CHARTROOM_DASHBOARD_RECENT_HOURS must be a whole number of hours"
  # A task closed before the recent window is on no lane (lanes.jq): its row is never built. This
  # cutoff is taken before lanes.jq takes its own, so it never leaves out a task lanes.jq keeps.
  printf -v since '%(%s)T' -1; since=$((since - 10#$hours * 3600))
  # (a store task's row carries its extras already, from the same read of the store: lib/store.py)
  # (read whole first: a store that cannot be read fails the board, never shows an empty one)
  local all_rows; all_rows="$(CR_ROWS_EXTRA=1 status_rows --all --since "$since" ${CR_BOARD_ID:+--id "$CR_BOARD_ID"})" || exit 1 # CR_BOARD_ID (`show`): that task alone; the inbox stays
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    if [[ "$row" == *'"_extra":'* ]]; then rows+=("$row"); continue; fi
    id="$(jq -r .id <<<"$row")"
    rows+=("$(jq -c --argjson x "$(task_extra_json "$id")" '. + $x' <<<"$row")")
  done <<<"$all_rows"
  if [[ ${#rows[@]} -gt 0 && "${rows[*]}" == *'"_extra":'* ]]; then
    mapfile -t rows < <(printf '%s\n' "${rows[@]}" | jq -c 'if has("_extra") then (. + ._extra | del(._extra)) else . end')
  fi
  local prs='{}'
  if [[ -n "$prs_file" && -s "$prs_file" ]]; then prs="$(jq -c 'if type == "object" then . else {} end' "$prs_file" 2>/dev/null || echo '{}')"; fi
  arts="$(artifacts_json --open)"
  local _agents _usage _rows_json
  _agents="$(spread_summary)"
  _rows_json="$(if (( ${#rows[@]} > 0 )); then printf '%s\n' "${rows[@]}" | jq -sc .; else echo '[]'; fi)"
  _usage="$(usage_rows_json "$_rows_json")"
  printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -s \
    --argjson inbox "$(inbox_with_relays)" --argjson prs "$prs" --argjson hours "$hours" \
    --argjson artifacts "$arts" --argjson artifact_counts "$(jq -c "$ARTIFACT_COUNTS_JQ" <<<"$arts")" \
    --arg home "$CR_HOME" --arg home_name "$(home_name_of "$CR_HOME")" --arg version "$CR_VERSION" --argjson focus "$(focus_json)" \
    -f "$CR_ROOT/lib/lanes.jq" |
    todo_attach "$arts" | jq --argjson agents "$_agents" --argjson usage "$_usage" '. + {agents:$agents, usage:$usage}' # .todo, the commander's next steps (lib/todo.sh)
}

# ---------------------------------------------------------------- the retired web dashboard

# A web dashboard left running from before it was retired: "pid port" from its .dashboard.pid,
# only while that pid is still its server (a stale file's pid may now be something else).
legacy_dashboard_running() {
  local f pid port; f="$CR_HOME/.dashboard.pid"
  [[ -f "$f" ]] || return 1
  read -r pid port _ <"$f" || true
  pid_alive "$pid" || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'dashboard/server\.py' || return 1
  printf '%s %s\n' "$pid" "${port:-?}"
}

# Stop it, and forget its pid file. Prints what it did; nothing when none ran.
legacy_dashboard_stop() {
  local pid port i
  if read -r pid port < <(legacy_dashboard_running); then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 50); do pid_alive "$pid" || break; sleep 0.1; done
    pid_alive "$pid" && { kill -9 "$pid" 2>/dev/null || true; }
    echo "stopped the old web dashboard (pid $pid, port $port): the app replaces it"
  fi
  rm -f "$CR_HOME/.dashboard.pid"
}

# The app's address, in APP_URL: its tailnet URL (Tailscale Serve), or this machine's own loopback
# URL when the app runs with --no-auth. Without one it returns 1, with the reason in APP_URL_WHY.
APP_URL="" APP_URL_WHY=""
app_url() {
  local pid port mode url
  APP_URL="" APP_URL_WHY=""
  if ! read -r pid port mode < <(app_running); then
    APP_URL_WHY="the app is not running on $(hostname -s 2>/dev/null || echo this machine): start it there with chartroom app serve --daemon (or chartroom app service on); chartroom app doctor says what else it needs"
    return 1
  fi
  if [[ "$mode" == noauth ]]; then url="http://127.0.0.1:$port/"
  else url="$(app_serve_url "$port")"; fi
  if [[ -z "$url" ]]; then
    APP_URL_WHY="the app runs (port $port) but Tailscale Serve is not pointed at it yet: chartroom app doctor prints the command"
    return 1
  fi
  APP_URL="${url%/}/" # (Serve prints the address without its slash)
}

# `chartroom dashboard`: the app is the commander's web view now. open (the default) opens it, as
# `app open` does; url prints its address (what a client home asks its brain); status says where it
# is; stop ends an old web dashboard still running; --json is the board's lanes (as `board --json`).
# Run for a client through the brain's gate, nothing opens a browser on the brain: it prints the
# address, and the client opens it there.
cmd_dashboard() {
  local sub="${1:-open}"
  case "$sub" in
    --json)
      # (--pr-states FILE: PR states to place done tasks by, {url: {state, reviewDecision, isDraft}})
      if [[ "${2:-}" == --pr-states ]]; then [[ $# -ge 3 ]] || die "--pr-states needs a file"; board_json "$3"; else board_json; fi
      return ;;
    url)
      app_url || die "$APP_URL_WHY"
      echo "$APP_URL" ;;
    status)
      local pid port ok=0
      if app_url; then echo "app: $APP_URL"; ok=1; else echo "app: $APP_URL_WHY"; fi
      if read -r pid port < <(legacy_dashboard_running); then
        echo "old web dashboard: still running (pid $pid, port $port); chartroom dashboard stop ends it"
      fi
      [[ $ok -eq 1 ]] ;;
    stop)
      local out; out="$(legacy_dashboard_stop)"
      echo "${out:-no old web dashboard runs for this home (the app is chartroom app: status, stop)}" ;;
    open)
      [[ $# -le 1 ]] || die "dashboard open takes no flags: the web dashboard is retired, and this opens the app (chartroom app open)"
      if [[ -n "${CHARTROOM_GATE:-}" ]]; then
        # a client asked: say where, and let it open the address there (an older client reads this line too)
        app_url || die "$APP_URL_WHY"
        echo "dashboard running: $APP_URL"; return 0
      fi
      cmd_app open ;;
    *) die "the web dashboard is retired and the app replaces it: chartroom dashboard [open] opens the app; dashboard url | status | stop (an old one still running); chartroom board for the terminal" ;;
  esac
}

# `chartroom board`: the lanes in the terminal, from board_json, so it and the crew views never
# disagree. One line per item: short id, [project], title, state, the refs of
# its open artifacts, a snippet of the last event (the project leads the text, so a question
# is placed at a glance); then the artifact count. While focus mode is on, the focus line leads,
# each lane's count says how many it holds, and a held item reads "[<state> · held]". Color only
# when stdout is a terminal (and NO_COLOR is unset); --json is the lanes JSON.
cmd_board() {
  local json=0 color=0 a board
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && color=1
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --color) color=1 ;;
      --no-color) color=0 ;;
      *) die "board: unknown arg $a (usage: chartroom board [--json] [--color|--no-color])" ;;
    esac
  done
  if [[ $json -eq 1 ]]; then board_json; return; fi
  board="$(board_json)"
  jq -e '.focus' <<<"$board" >/dev/null && focus_line "$(jq -c '.focus | {projects, since, until}' <<<"$board")" "$(jq '.focus.held' <<<"$board")"
  spread_line "$(jq -c .agents <<<"$board")"
  jq -r --argjson color "$color" '
    def c($code): if $color == 1 then "\u001b[" + $code + "m" + . + "\u001b[0m" else . end;
    def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
    def pad($n): . + (" " * ([$n - length, 0] | max));
    [["needs_you", "Needs you", "1;31"], ["in_progress", "In progress", "1;36"], ["on_hold", "On hold", "1;33"],
     ["ready", "Ready for you", "1;32"], ["recent", "Recently finished", "1;90"]] as $lanes
    | . as $b
    | ([$b.lanes[][] | (.short_id // "-") | length] | max // 4) as $w
    | $lanes[] as [$k, $name, $col]
    | ($b.lanes[$k] // []) as $items
    | ([$items[] | select(.held)] | length) as $held
    | ("\($name) (\($items | length)\(if $held > 0 then ", \($held) held" else "" end))" | c($col)),
      (if ($items | length) == 0 then "  none" | c("2")
       else $items[]
         | ((.short_id // "-") | pad($w) | c("1")) + "  "
           + (if (.project // "") != "" then ("[" + .project + "]" | c("1")) + " " else "" end) + ((.title // .id) | cut(60))
           + "  " + ("[" + (.reason // .state // "") + (if .held then " · held" else "" end) + "]" | c("2"))
           + ((.artifacts // []) | if length == 0 then ""
              else "  " + ("[artifact" + (if length > 1 then "s " else " " end) + (map(.ref) | join(", ")) + "]" | c("1;35")) end)
           + (if .type == "inbox" then (if .date then "  since " + .date else "" end)
              elif .waiting_on then "  waiting on: " + (.waiting_on | cut(60))
              elif .last_event then "  " + (.last_event | gsub("\n"; " ") | cut(70)) else "" end)
         | "  " + . end),
      ""' <<<"$board"
  artifact_line "$(jq -c '.artifacts // {}' <<<"$board")"
}

# For `doctor`: where the app is ({url, why}) and an old web dashboard still running (its pid).
app_doctor_brief_json() {
  local pid _p
  app_url || true
  read -r pid _p < <(legacy_dashboard_running) || pid=""
  jq -cn --arg u "$APP_URL" --arg w "$APP_URL_WHY" --arg p "$pid" \
    '{url: (if $u == "" then null else $u end), why: (if $w == "" then null else $w end), old_dashboard: (if $p == "" then null else ($p | tonumber) end)}'
}
