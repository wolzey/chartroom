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
  local f; f="$(tdir "$1")/events.log"
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

# One home as the app reads it (lib/app/snapshot.jq).
app_snapshot_json() {
  local since row id rows=() extra ask intent off line
  printf -v since '%(%s)T' -1; since=$((since - CR_APP_RECENT_HOURS * 3600))
  while IFS= read -r row; do
    id="$(jq -r .id <<<"$row")"
    extra="$(dashboard_task_extra "$id")"
    ask=null intent=""
    case "$(jq -r .state <<<"$row")" in
      decision|blocked|failed|awaiting-input|review)
        if IFS=$'\t' read -r off line < <(app_last_ask "$id"); then
          ask="$(jq -n -c --arg id "ev-$id-$off" --arg line "$line" '{id: $id, line: $line,
            kind: ($line | capture("^[^ ]+ (?<k>[a-z-]+):( (?<a>awaiting-input))?") | if .k == "agent" then "awaiting-input" else .k end)}')"
        fi
        intent="$(app_intent "$id")" ;;
    esac
    rows+=("$(jq -c --argjson x "$extra" --argjson ask "$ask" --arg intent "$intent" \
      '. + $x + {ask: $ask, intent: (if $intent == "" then null else $intent end)}' <<<"$row")")
  done < <(status_rows --all --since "$since")
  local answers='{}' d f
  d="$(ask_dir)"
  if [[ -d "$d" ]]; then
    shopt -s nullglob
    local afiles=("$d"/*.answer.json)
    shopt -u nullglob
    [[ ${#afiles[@]} -eq 0 ]] || answers="$(jq -s -c 'map(select(type == "object" and (.id | type) == "string") | {key: .id, value: .}) | from_entries' "${afiles[@]}" 2>/dev/null || echo '{}')"
  fi
  f="$(mktemp)"
  printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -s -c \
    --arg home "$CR_HOME" --arg home_name "$(home_name_of "$CR_HOME")" --arg version "$CR_VERSION" \
    --arg machine "$(cfg MACHINE_NAME '' "$(hostname -s 2>/dev/null || echo this)")" \
    --argjson inbox "$(dashboard_inbox)" --argjson artifacts "$(artifacts_json --open)" \
    --argjson cards "$(asks_json --all)" --argjson answers "$answers" --argjson tells "$(tells_json --all)" \
    --argjson snoozes "$(snoozes_json)" --argjson focus "$(focus_json)" \
    '{home: $home, home_name: (if $home_name == "" then ($home | split("/") | last) else $home_name end),
      machine: $machine, version: $version, rows: ., inbox: $inbox, artifacts: $artifacts, cards: $cards,
      answers: $answers, tells: $tells, snoozes: $snoozes, focus: $focus}' >"$f"
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

app_stop() {
  local pid port i
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
  if read -r pid port _ < <(app_running); then echo "server: running on 127.0.0.1:$port (pid $pid)"
  else echo "server: not running (chartroom app serve --daemon)"; port="$(app_port)"; fi
  if [[ -n "$user" ]]; then echo "allowed: $user (CHARTROOM_APP_USER)"
  else echo "allowed: nobody yet; set CHARTROOM_APP_USER=<your Tailscale login> in $CR_CONFIG_FILE"; fi
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
    stop) app_stop; return ;;
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
    ""|-h|--help) echo "usage: chartroom app serve [--port N] [--daemon] [--no-auth] | open | stop | status | doctor | snapshot --json"; [[ -n "${1:-}" ]]; return ;;
    *) die "app: unknown command $1 (serve, open, stop, status, doctor, snapshot)" ;;
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
  if [[ $noauth -eq 1 ]]; then args+=(--no-auth); else args+=(--user "$user"); fi
  [[ $daemon -eq 1 ]] || exec "${CR_PY[@]}" "${args[@]}"
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
