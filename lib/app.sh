# shellcheck shell=bash
# app.sh - `chartroom app`: the chartroom app (app/, a React PWA) and its server, one per brain,
# for every home on it (designs: the chartroom app; one brain).
#
# The server (lib/app/server.py, stdlib Python) binds 127.0.0.1 only, on CHARTROOM_APP_PORT
# (default 4516). Tailscale Serve puts it on the tailnet over HTTPS and names the person at each
# request; only CHARTROOM_APP_USER (a Tailscale login, set in the brain's config file) gets in.
# It reads each home through `chartroom app snapshot --json` (this file plus lib/app/snapshot.jq:
# what an item means is decided here, never in the server), off the request path, and every
# write it makes is a chartroom verb run in that home (tell, ask answer, accept, close, snooze,
# todo done, artifact done), so the records keep one writer: the brain.
#
#   chartroom app serve [--port N] [--daemon] [--no-auth]   run the server (--no-auth: no
#                                          identity check, for this machine's own browser before
#                                          Serve is set up; never with Serve pointed at it)
#   chartroom app open | stop | status | doctor
#   chartroom app service on|off|status    run the server as a LaunchAgent (dev.chartroom.app) in
#                                          the login session: launchd starts it at login and again
#                                          whenever it ends, so it is back after a reboot (once the
#                                          user is logged in: with automatic login, by itself)
#   chartroom app snapshot --json          one home as the app reads it

CR_APP_PORT_DEFAULT=4516
CR_APP_RECENT_HOURS=48 # closed tasks the snapshot keeps (the board's own window comes in slice 3)

app_state_dir() { printf '%s' "${CR_CONFIG_FILE%/*}"; }
app_pidfile() { printf '%s/app.pid' "$(app_state_dir)"; }
app_logfile() { printf '%s/app.log' "$(app_state_dir)"; }
app_port() { cfg APP_PORT '' "$CR_APP_PORT_DEFAULT"; }

# A worker's latest ask in a task's events.log: "<byte offset>\t<line>" for the newest decision,
# blocked, failed or agent awaiting-input line; nothing when there is none.
app_last_ask() { # <task>
  local f; events_path "$1"; f="$EVENTS_PATH"
  [[ -f "$f" ]] || return 0
  LC_ALL=C awk '{ if ($2 ~ /^(decision|blocked|failed):$/ || ($2 == "agent:" && $3 ~ /^awaiting-input/)) { off = pos; line = $0 }
                  pos += length($0) + 1 }
                END { if (line != "") print off "\t" line }' "$f"
}

# The commander's intent from a task's brief (the "## Commander's intent" section), cut short.
app_intent() { # <task>
  local f; f="$(tdir "$1")/brief.md"
  [[ -f "$f" ]] || return 0
  awk '/^## /{ if (on) exit; if ($0 ~ /^## Commander.s intent/) { on = 1; next } } on' "$f" |
    jq -R -s -r 'gsub("<!--[\\s\\S]*?-->"; "") | gsub("^\\s+|\\s+$"; "") | .[0:1500]'
}

# The Tailscale CLI: CHARTROOM_TAILSCALE (none: no Tailscale), else on PATH, else the Mac app's.
app_tailscale() {
  local ts="${CHARTROOM_TAILSCALE:-}"
  if [[ -n "$ts" ]]; then [[ "$ts" == none ]] || printf '%s' "$ts"; return 0; fi
  ts="$(bin_of tailscale)"
  [[ -z "$ts" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]] && ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  printf '%s' "$ts"
}

# The tailnet URL Tailscale Serve gives the app on <port>, or nothing.
app_serve_url() { # <port>
  local ts; ts="$(app_tailscale)"
  [[ -n "$ts" ]] || return 0
  "$ts" serve status 2>/dev/null | grep -B1 "127.0.0.1:$1\$" | head -1 | awk '/^https?:/ {print $1}' || true
}

# Permission cards (the broker, lib/permit.sh: a Claude worker's prompt chartroom's policy would not
# answer): the open ones, and for an hour those that expired or lapsed unanswered (a late allow still
# works: the worker is told to retry). Empty where this chartroom has no broker.
app_permits_json() {
  declare -F permit_rows >/dev/null || { echo '[]'; return; }
  permit_rows "" 1 | jq -s -c --argjson now "$(date +%s)" '
    map(select(.state == "open"
      or ((.state == "expired" or .state == "lapsed") and .late == null
          and ($now - ((.answer.at // null | if . then fromdateiso8601 else null end) // .expires_epoch)) < 3600)))' 2>/dev/null || echo '[]'
}

# One home as the app reads it (lib/app/snapshot.jq).
app_snapshot_json() {
  local since row id st rows=() extra ask intent off line
  printf -v since '%(%s)T' -1; since=$((since - CR_APP_RECENT_HOURS * 3600))
  # (read whole first: a store that cannot be read fails the snapshot, never shows an empty home)
  # (a store task's row carries its extras already, from the same read of the store, as the board's)
  local all_rows; all_rows="$(CR_ROWS_EXTRA=1 status_rows --all --since "$since")" || exit 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r id st < <(jq -r '[.id, .state] | @tsv' <<<"$row")
    if [[ "$row" == *'"_extra":'* ]]; then extra='{}'; else extra="$(dashboard_task_extra "$id")"; fi
    ask=null intent=""
    case "$st" in
      decision|blocked|failed|awaiting-input|review)
        if IFS=$'\t' read -r off line < <(app_last_ask "$id"); then
          ask="$(jq -n -c --arg id "ev-$id-$off" --arg line "$line" '{id: $id, line: $line,
            kind: ($line | capture("^[^ ]+ (?<k>[a-z-]+):( (?<a>awaiting-input))?") | if .k == "agent" then "awaiting-input" else .k end)}')"
        fi
        intent="$(app_intent "$id")" ;;
    esac
    meta_path "$id"
    rows+=("$(jq -c --argjson x "$extra" --argjson ask "$ask" --arg intent "$intent" \
      --argjson links "$(links_json "$id")" --slurpfile meta "$META_PATH" \
      '(. + (._extra // {}) | del(._extra)) + $x + {ask: $ask, intent: (if $intent == "" then null else $intent end),
        prs: ([$links[] | select(.kind == "pr") | .url]), links: $links,
        priority: ($meta[0].priority // null), labels: ($meta[0].labels // []),
        initiative: ($meta[0].initiative // null), milestone: ($meta[0].milestone // null)}' <<<"$row")")
  done <<<"$all_rows"
  local answers f
  answers="$(answers_json)" || exit 1
  f="$(mktemp)"
  printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -s -c \
    --arg home "$CR_HOME" --arg home_name "$(home_name_of "$CR_HOME")" --arg version "$CR_VERSION" \
    --arg machine "$(cfg MACHINE_NAME '' "$(hostname -s 2>/dev/null || echo this)")" \
    --argjson inbox "$(dashboard_inbox)" --argjson artifacts "$(artifacts_json --open)" \
    --argjson cards "$(asks_json --all)" --argjson answers "$answers" --argjson tells "$(tells_json --all)" \
    --argjson snoozes "$(snoozes_json)" --argjson focus "$(focus_json)" --argjson requests "$(requests_json)" --argjson initiatives "$(initiatives_json)" \
    --argjson permits "$(app_permits_json)" \
    '{home: $home, home_name: (if $home_name == "" then ($home | split("/") | last) else $home_name end),
      machine: $machine, version: $version, rows: ., inbox: $inbox, artifacts: $artifacts, cards: $cards,
      answers: $answers, tells: $tells, snoozes: $snoozes, focus: $focus, requests: $requests, initiatives: $initiatives,
      permits: $permits}' >"$f"
  jq -c -f "$CR_ROOT/lib/app/snapshot.jq" "$f"
  rm -f "$f"
}

app_running() { # -> "pid port mode" when the app server runs (mode: tailscale or noauth)
  local f pid port mode; f="$(app_pidfile)"
  [[ -f "$f" ]] || return 1
  read -r pid port mode <"$f" || true
  pid_alive "$pid" || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'app/server\.py' || return 1
  printf '%s %s %s\n' "$pid" "$port" "${mode:-tailscale}"
}

app_healthy() { # <port>
  "${CR_PY[@]}" - "$1" <<'PY' >/dev/null 2>&1
import sys, urllib.request
with urllib.request.urlopen("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=2) as r:
    sys.exit(0 if r.read().strip() == b"ok" else 1)
PY
}

CR_APP_LABEL=dev.chartroom.app
app_plist() { printf '%s' "$HOME/Library/LaunchAgents/$CR_APP_LABEL.plist"; }
app_service_loaded() { local lc; lc="$(device_launchctl)"; [[ -n "$lc" ]] && "$lc" print "gui/$(id -u)/$CR_APP_LABEL" >/dev/null 2>&1; }

app_stop() {
  local pid port i
  # launchd would only start a killed server again: a service is booted out (it is back at the
  # next login, or with chartroom app serve --daemon / app service on)
  if app_service_loaded; then
    "$(device_launchctl)" bootout "gui/$(id -u)/$CR_APP_LABEL" 2>/dev/null || true
    for i in $(seq 1 50); do read -r pid port _ < <(app_running) || break; sleep 0.1; done
    rm -f "$(app_pidfile)"
    echo "app stopped (its LaunchAgent $CR_APP_LABEL is booted out; it starts again at the next login, or with chartroom app service on)"
    return 0
  fi
  if ! read -r pid port _ < <(app_running); then rm -f "$(app_pidfile)"; echo "app not running"; return 0; fi
  kill "$pid" 2>/dev/null || true
  for i in $(seq 1 50); do pid_alive "$pid" || break; sleep 0.1; done
  pid_alive "$pid" && { kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$(app_pidfile)"
  echo "app stopped (pid $pid, port $port)"
}

# What the commander needs to know to reach the app: the server, the allowed user, and Serve.
app_doctor() {
  local pid port user ts serve=""
  user="$(cfg APP_USER '' '')"
  if app_service_loaded; then echo "service: LaunchAgent $CR_APP_LABEL (launchd starts it at login and again if it ends)"
  elif [[ "$(uname -s)" == Darwin ]]; then echo "service: none (chartroom app service on: launchd keeps it up and starts it after a reboot)"; fi
  if read -r pid port _ < <(app_running); then echo "server: running on 127.0.0.1:$port (pid $pid)"
  else echo "server: not running (chartroom app serve --daemon)"; port="$(app_port)"; fi
  if [[ -n "$user" ]]; then echo "allowed: $user (CHARTROOM_APP_USER)"
  else echo "allowed: nobody yet; set CHARTROOM_APP_USER=<your Tailscale login> in $CR_CONFIG_FILE"; fi
  # notifications: local ones need only the HTTPS address; Web Push also needs node and the switch
  if [[ "$(cfg APP_PUSH '' off)" != on ]]; then
    echo "push: off (CHARTROOM_APP_PUSH=on turns on Web Push: new items reach a closed app through the browser maker's push service, encrypted end to end)"
  elif ! command -v node >/dev/null 2>&1; then echo "push: on, but node is not installed, so it cannot send"
  elif node "$CR_ROOT/lib/app/push.mjs" selftest >/dev/null 2>&1; then echo "push: on (node $(node --version))"
  else echo "push: on, but node's crypto failed the push self-test"; fi
  ts="$(app_tailscale)"
  if [[ -z "$ts" ]]; then echo "tailscale: not found; the app stays on this machine (http://127.0.0.1:$port)"; return 0; fi
  serve="$("$ts" serve status 2>/dev/null || true)"
  if grep -q "127.0.0.1:$port" <<<"$serve"; then
    echo "tailscale serve: on: $(grep -B1 "127.0.0.1:$port" <<<"$serve" | head -1 | awk '{print $1}')"
  else
    echo "tailscale serve: not pointed at the app. To put it on your tailnet (HTTPS, tailnet only):"
    echo "  $ts serve --bg --https=443 http://127.0.0.1:$port"
  fi
}

cmd_app() {
  if brain_is_client; then
    die "this home is a client of the brain ($(brain_target)): the app runs there, for every home on it; open it on the brain's tailnet address"
  fi
  case "${1:-}" in
    snapshot)
      shift; [[ "${1:-}" == --json ]] || die "usage: chartroom app snapshot --json"
      app_snapshot_json; return ;;
    task)
      shift; [[ $# -eq 2 && "$2" == --json ]] || die "usage: chartroom app task <id> --json"
      need_task "$1"; ticket_json "$1"; return ;;
    fleet)
      # the machines (chartroom nodes: each one's probe, over ssh for the others) as Fleet shows them
      shift; [[ "${1:-}" == --json ]] || die "usage: chartroom app fleet --json"
      # CHARTROOM_APP_NODES (tests only): a file of `chartroom nodes --json` to read instead of the machines
      local nodes
      if [[ -n "${CHARTROOM_APP_NODES:-}" ]]; then nodes="$(cat "$CHARTROOM_APP_NODES")" || die "app fleet: cannot read $CHARTROOM_APP_NODES"
      else nodes="$(cmd_nodes --json)" || die "app fleet: chartroom nodes failed"; fi
      jq -c --arg at "$(now)" -f "$CR_ROOT/lib/app/fleet.jq" <<<"$nodes" | jq -c --arg at "$(now)" '. + {checked_at: $at}'
      return ;;
    stop) app_stop; return ;;
    service) shift; app_service "$@"; return ;;
    status)
      local pid port
      if read -r pid port _ < <(app_running); then echo "app running: http://127.0.0.1:$port (pid $pid)"; else echo "app not running"; return 1; fi
      return ;;
    doctor) find_python; app_doctor; return ;;
    open)
      shift; find_python
      [[ ${#CR_PY[@]} -gt 0 ]] || die "the app needs python3 (standard library only)"
      local pid port mode opener url
      if ! read -r pid port mode < <(app_running); then cmd_app serve --daemon "$@" >&2; read -r pid port mode < <(app_running) || die "the app did not start"; fi
      # With the identity check on, only Tailscale Serve's URL lets anyone in.
      if [[ "$mode" == noauth ]]; then url="http://127.0.0.1:$port/"
      else
        url="$(app_serve_url "$port")"
        [[ -n "$url" ]] || die "the app (port $port) lets in only $(cfg APP_USER '' 'CHARTROOM_APP_USER') through Tailscale Serve, which is not pointed at it yet (chartroom app doctor prints the command); for this machine's browser alone: chartroom app stop, then chartroom app open --no-auth"
      fi
      opener="$(cfg OPENER '' '')"
      if [[ -z "$opener" ]]; then
        if [[ "$(uname -s)" == Darwin && -n "$(bin_of open)" ]]; then opener=open; elif [[ -n "$(bin_of xdg-open)" ]]; then opener=xdg-open; fi
      fi
      if [[ -n "$opener" ]] && $opener "$url" >/dev/null 2>&1; then echo "app open: $url"; else echo "app running: $url"; fi
      return ;;
    serve) shift ;;
    ""|-h|--help) echo "usage: chartroom app serve [--port N] [--daemon] [--no-auth] | open | stop | status | doctor | service on|off|status | snapshot --json"; [[ -n "${1:-}" ]]; return ;;
    *) die "app: unknown command $1 (serve, open, stop, status, doctor, service, snapshot)" ;;
  esac
  local port daemon=0 noauth=0
  port="$(app_port)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) [[ $# -ge 2 ]] || die "--port needs a value"; port="$2"; shift 2 ;;
      --daemon) daemon=1; shift ;;
      --no-auth) noauth=1; shift ;;
      *) die "app serve: unknown arg $1 (usage: chartroom app serve [--port N] [--daemon] [--no-auth])" ;;
    esac
  done
  [[ "$port" =~ ^[0-9]+$ ]] && (( port <= 65535 )) || die "--port must be 0-65535 (CHARTROOM_APP_PORT)"
  find_python
  [[ ${#CR_PY[@]} -gt 0 ]] || die "the app needs python3 (standard library only)"
  local pid p
  if read -r pid p _ < <(app_running); then die "the app is already running: http://127.0.0.1:$p (pid $pid); 'chartroom app stop' first"; fi
  local user; user="$(cfg APP_USER '' '')"
  [[ $noauth -eq 1 || -n "$user" ]] || die "app serve: set CHARTROOM_APP_USER=<your Tailscale login> in $CR_CONFIG_FILE first (only that person gets in), or --no-auth for this machine's own browser"
  mkdir -p "$(app_state_dir)"
  local args=("$CR_ROOT/lib/app/server.py" --port "$port" --pidfile "$(app_pidfile)" --bin "$CR_BIN" --root "$CR_ROOT")
  # the device routes (lib/fleet.sh): devices push their heartbeats here, under this machine's registry
  args+=(--fleet-dir "$(fleet_dir)")
  if [[ $noauth -eq 1 ]]; then args+=(--no-auth); else args+=(--user "$user"); fi
  # Web Push (slice 6): off unless the brain's config turns it on; it sends through the browser
  # maker's push service, encrypted end to end
  local push; push="$(cfg APP_PUSH '' off)"
  [[ "$push" == on ]] || push=off
  args+=(--push "$push" --push-subject "$(cfg APP_PUSH_SUBJECT '' 'mailto:chartroom@example.com')")
  # a worker's card or decision is the XO's first: pushed only if still open after this many seconds
  local hold; hold="$(cfg APP_PUSH_HOLD '' 120)"
  [[ "$hold" =~ ^[0-9]+$ ]] || hold=120
  args+=(--push-hold "$hold")
  [[ $daemon -eq 1 ]] || exec "${CR_PY[@]}" "${args[@]}"
  # the server is a LaunchAgent here (app service on): launchd starts it, never a nohup copy beside it
  if [[ -f "$(app_plist)" && -n "$(device_launchctl)" && "$port" == "$(app_port)" && $noauth -eq 0 ]]; then
    app_service_start; return
  fi
  local log; log="$(app_logfile)"
  ( umask 077; nohup "${CR_PY[@]}" "${args[@]}" >"$log" 2>&1 </dev/null & echo $! >"$log.pid" )
  local child i; child="$(cat "$log.pid")"; rm -f "$log.pid"
  for i in $(seq 1 100); do
    if read -r pid p _ < <(app_running) && [[ "$pid" == "$child" ]] && app_healthy "$p"; then
      echo "app running: http://127.0.0.1:$p (pid $pid; log $log; stop with: chartroom app stop)"
      return 0
    fi
    pid_alive "$child" || break
    sleep 0.1
  done
  tail -n 20 "$log" >&2 2>/dev/null || true
  pid_alive "$child" && kill "$child" 2>/dev/null
  die "the app did not start"
}

# ---------------------------------------------------------------- app service (launchd)

app_service_write() {
  local f log; f="$(app_plist)"; log="$(app_logfile)"
  mkdir -p "$(dirname "$f")" "$(app_state_dir)"
  local env="" k
  for k in SHELL XDG_CONFIG_HOME XDG_STATE_HOME CHARTROOM_CONFIG LANG; do
    [[ -n "${!k:-}" ]] && env+="<key>$k</key><string>$(xml_esc "${!k}")</string>"
  done
  cat >"$f.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- chartroom's app server (written by chartroom app service on; chartroom app service off removes it) -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$CR_APP_LABEL</string>
  <key>ProgramArguments</key><array><string>$(xml_esc "$CR_BIN")</string><string>app</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$(xml_esc "$HOME/.local/bin")</string><key>HOME</key><string>$(xml_esc "$HOME")</string>$env</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$(xml_esc "$log")</string>
  <key>StandardErrorPath</key><string>$(xml_esc "$log")</string>
</dict>
</plist>
PLIST
  mv "$f.tmp" "$f"
}

app_service_start() {
  local lc i pid p; lc="$(device_launchctl)"
  app_service_loaded || "$lc" bootstrap "gui/$(id -u)" "$(app_plist)" || die "launchd would not load $(app_plist)"
  for i in $(seq 1 100); do
    if read -r pid p _ < <(app_running) && app_healthy "$p"; then
      echo "app running: http://127.0.0.1:$p (pid $pid; LaunchAgent $CR_APP_LABEL; log $(app_logfile))"; return 0
    fi
    sleep 0.1
  done
  tail -n 20 "$(app_logfile)" >&2 2>/dev/null || true
  die "the app's LaunchAgent did not bring the server up (log $(app_logfile))"
}

# The Mac's automatic login, as far as it can be read without asking for a password.
app_autologin() {
  local u; u="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  if [[ -n "$u" ]]; then echo "automatic login: on (as $u), so after a reboot the app comes back by itself"
  else echo "automatic login: off, so after a reboot the app comes back once you log in at the screen"; fi
}

app_service() {
  local lc; lc="$(device_launchctl)"
  case "${1:-status}" in
    on)
      [[ -n "$lc" ]] || die "app service: needs launchd (macOS); elsewhere run chartroom app serve under your own supervisor"
      local user; user="$(cfg APP_USER '' '')"
      [[ -n "$user" ]] || die "app service: set CHARTROOM_APP_USER=<your Tailscale login> in $CR_CONFIG_FILE first"
      find_python; [[ ${#CR_PY[@]} -gt 0 ]] || die "the app needs python3 (standard library only)"
      if app_service_loaded; then "$lc" bootout "gui/$(id -u)/$CR_APP_LABEL" 2>/dev/null || true; fi
      app_stop >/dev/null # (a nohup server from before, on the same port)
      app_service_write
      app_service_start
      app_autologin ;;
    off)
      if [[ -n "$lc" ]] && app_service_loaded; then "$lc" bootout "gui/$(id -u)/$CR_APP_LABEL" 2>/dev/null || true; fi
      rm -f "$(app_plist)" "$(app_pidfile)"
      echo "app service off: launchd no longer runs the server (chartroom app serve --daemon runs one by hand)" ;;
    status)
      if app_service_loaded; then echo "app service: on ($CR_APP_LABEL)"; [[ "$(uname -s)" != Darwin ]] || app_autologin
      elif [[ -f "$(app_plist)" ]]; then echo "app service: installed but not loaded (chartroom app service on)"
      else echo "app service: off"; fi ;;
    *) die "usage: chartroom app service on|off|status" ;;
  esac
}

