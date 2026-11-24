# shellcheck shell=bash
# device.sh - a device's side (docs/multi-machine.md, "Devices"): this machine enrols with a brain
# once and then keeps telling it how it is. It opens no port and holds no key to the brain; the
# brain holds none to it. Only this machine starts a connection, always to the brain's app URL.
#
#   chartroom device join <brain-url> <code|->  enrol with a code from `chartroom node add` on the brain
#                                              (- reads it from stdin, off the command line)
#   chartroom device run [--once]              the agent: a heartbeat every CHARTROOM_DEVICE_HEARTBEAT
#                                              seconds (15), run by launchd in the login session
#   chartroom device status [--json]           joined to what, the agent, its last heartbeat
#   chartroom device leave                     stop the agent and forget the token here
#   chartroom device update                    fast-forward to origin/main and restart the agent (by hand;
#                                              the brain's `node update` does it over the connection)
#
# On macOS `join` writes the code to a 0600 file and loads the agent (a LaunchAgent in the login
# session, dev.chartroom.device); the agent makes the join itself, so its token goes into the login
# keychain from the session that can open it (an ssh session often cannot). The token is kept in the
# keychain (service chartroom-device, account <node id>), or in a 0600 file where there is none
# (CHARTROOM_KEYCHAIN=none: Linux, the tests). It never goes on a command line or into a log.
#
# A heartbeat carries this machine's probe (lib/nodeprobe.sh: load, memory, disk, power, crew,
# tools on the login PATH), its chartroom version and its clock. Its answer can ask for a new
# token (`chartroom node rotate` on the brain). A 401 means the brain revoked this device: the
# agent stops and touches nothing else here. No work is placed on a device yet.
#
#   config  $XDG_CONFIG_HOME/chartroom/device    CHARTROOM_DEVICE_BRAIN, _ID, _NAME, _TOKEN_STORE
#   state   $XDG_STATE_HOME/chartroom/device/    agent.json (the agent's last word), agent.log,
#                                                join-code and token files (0600) while needed

CR_DEVICE_LABEL=dev.chartroom.device
CR_DEVICE_KEYCHAIN_SERVICE=chartroom-device

device_config_path() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/chartroom/device"; }
device_state_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/device"; }
device_cfg() { cfg_value_in "$(device_config_path)" "CHARTROOM_DEVICE_$1"; }

device_set_cfg() { # <KEY> <value>: one line of the device file, the others kept
  local f tmp; f="$(device_config_path)"; mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  { if [[ -f "$f" ]]; then grep -v "^CHARTROOM_DEVICE_$1=" "$f" || true; fi
    [[ -f "$f" ]] || echo "# chartroom device settings (written by chartroom device join): the brain this machine reports to"
    echo "CHARTROOM_DEVICE_$1=$2"; } >"$tmp" && mv "$tmp" "$f"
}

device_keychain() { # the security binary, or nothing when the token lives in a file
  local k; k="$(cfg KEYCHAIN '' '')"
  [[ "$k" == none ]] && return 0
  if [[ -z "$k" ]]; then [[ "$(uname -s)" == Darwin && -x /usr/bin/security ]] && k=/usr/bin/security; fi
  printf '%s' "$k"
}
device_launchctl() { # the launchctl binary, or nothing where the agent is run some other way
  local l; l="$(cfg LAUNCHCTL '' '')"
  [[ "$l" == none ]] && return 0
  if [[ -z "$l" ]]; then [[ "$(uname -s)" == Darwin && -x /bin/launchctl ]] && l=/bin/launchctl; fi
  printf '%s' "$l"
}

# ---------------------------------------------------------------- the token

device_token_get() { # [next] -> the token on stdout
  local acct id; id="$(device_cfg ID)"; acct="$id${1:+.$1}"
  [[ -n "$id" ]] || return 1
  if [[ "$(device_cfg TOKEN_STORE)" == keychain ]]; then
    "$(device_keychain)" find-generic-password -s "$CR_DEVICE_KEYCHAIN_SERVICE" -a "$acct" -w 2>/dev/null
  else
    cat "$(device_state_dir)/token${1:+-$1}" 2>/dev/null
  fi
}

# Keeps a token (from stdin): the keychain when there is one, else a 0600 file. Sets the store.
device_token_put() { # [next] < token
  local tok acct id k err; tok="$(cat)"; id="$(device_cfg ID)"; acct="$id${1:+.$1}"
  k="$(device_keychain)"
  if [[ -n "$k" ]]; then
    if err="$(printf 'add-generic-password -U -s %s -a %s -w %s\n' "$CR_DEVICE_KEYCHAIN_SERVICE" "$acct" "$tok" | "$k" -i 2>&1)" &&
       [[ "$("$k" find-generic-password -s "$CR_DEVICE_KEYCHAIN_SERVICE" -a "$acct" -w 2>/dev/null)" == "$tok" ]]; then
      device_set_cfg TOKEN_STORE keychain; return 0
    fi
    device_log "the keychain refused the token (${err:-it read back wrong}); keeping it in a 0600 file instead"
  fi
  mkdir -p "$(device_state_dir)"
  ( umask 077; printf '%s\n' "$tok" >"$(device_state_dir)/token${1:+-$1}.tmp" ) && mv "$(device_state_dir)/token${1:+-$1}.tmp" "$(device_state_dir)/token${1:+-$1}"
  device_set_cfg TOKEN_STORE file
}

device_token_del() { # [next]
  local id acct k; id="$(device_cfg ID)"; acct="$id${1:+.$1}"; k="$(device_keychain)"
  if [[ -n "$k" && -n "$id" ]]; then "$k" delete-generic-password -s "$CR_DEVICE_KEYCHAIN_SERVICE" -a "$acct" >/dev/null 2>&1 || true; fi
  rm -f "$(device_state_dir)/token${1:+-$1}"
  return 0
}

# ---------------------------------------------------------------- talking to the brain

device_log() { mkdir -p "$(device_state_dir)"; printf '%s %s\n' "$(now)" "$*" >>"$(device_state_dir)/agent.log"; }

device_status_write() { # <state> [error]
  local f; f="$(device_state_dir)/agent.json"; mkdir -p "$(device_state_dir)"
  jq -cn --arg s "$1" --arg e "${2:-}" --arg at "$(now)" --arg ok "${DEV_LAST_OK:-}" --arg n "$(device_cfg NAME)" \
    --arg b "$(device_cfg BRAIN)" --argjson pid "$$" \
    '{state: $s, error: (if $e == "" then null else $e end), at: $at, last_ok: (if $ok == "" then null else $ok end),
      name: (if $n == "" then null else $n end), brain: $b, pid: $pid}' >"$f.tmp" && mv "$f.tmp" "$f"
}

# POST <path> with the JSON in <file>, the token (if any) sent as a header through curl's config on
# stdin, never on its command line. Sets DEV_HTTP (000 when nothing answered) and DEV_BODY.
device_post() { # <path> <json file> [token]
  local out url; out="$(mktemp)"; url="$(device_cfg BRAIN)"
  DEV_HTTP="$( { [[ -z "${3:-}" ]] || printf 'header = "Authorization: Bearer %s"\n' "$3"; } |
    curl -sS -K - -o "$out" -w '%{http_code}' --max-time "${DEV_MAXTIME:-20}" -X POST -H 'Content-Type: application/json' \
      --data-binary @"$2" "${url%/}$1" 2>/dev/null)" || DEV_HTTP=000
  [[ "$DEV_HTTP" =~ ^[0-9]{3}$ ]] || DEV_HTTP=000
  DEV_BODY="$(cat "$out" 2>/dev/null)"; rm -f "$out"
}
device_err() { jq -r '.error // empty' <<<"$DEV_BODY" 2>/dev/null || true; }

device_hw_uuid() {
  local u="${CHARTROOM_HW_UUID:-}"
  if [[ -z "$u" && "$(uname -s)" == Darwin ]]; then u="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ {print $4}')"; fi
  if [[ -z "$u" && -r /etc/machine-id ]]; then u="$(cat /etc/machine-id)"; fi
  printf '%s' "$u"
}
device_host() { local h; h="$(hostname 2>/dev/null || echo device)"; h="${h//[^A-Za-z0-9._-]/-}"; printf '%s' "${h:0:200}"; }

# This machine's node id (CHARTROOM_NODE_ID in its node file), minted once; a machine with no node
# file gets one with the defaults first (chartroom node init).
device_node_id() {
  local f id; f="$(node_config_path)"
  [[ -f "$f" ]] || cmd_node_init >&2
  id="$(cfg_value_in "$f" CHARTROOM_NODE_ID)"
  if [[ ! "$id" =~ $CR_DEVICE_ID_RE ]]; then
    id="n-$(fleet_rand_hex 6)"
    printf 'CHARTROOM_NODE_ID=%s\n' "$id" >>"$f"
  fi
  printf '%s' "$id"
}

# The join itself, with the code in the join-code file. 0 joined; 1 refused (the code is gone:
# make a new one); 2 the brain did not answer (try again while the code lasts).
device_do_join() {
  local cf code body; cf="$(device_state_dir)/join-code"
  code="$(cat "$cf" 2>/dev/null)" || return 1
  body="$(mktemp)"
  jq -cn --arg c "$code" --arg id "$(device_cfg ID)" --arg h "$(device_host)" --arg hw "$(device_hw_uuid)" \
    --arg v "$CR_VERSION" --argjson p "$CR_FLEET_PROTOCOL" '{code: $c, id: $id, host: $h, hw_uuid: $hw, version: $v, protocol: $p}' >"$body"
  device_post /api/v1/device/join "$body"; rm -f "$body"
  case "$DEV_HTTP" in
    200)
      jq -r '.token' <<<"$DEV_BODY" | device_token_put
      device_set_cfg NAME "$(jq -r '.name' <<<"$DEV_BODY")"
      rm -f "$cf"; DEV_LAST_OK="$(now)"
      device_log "joined $(device_cfg BRAIN) as $(device_cfg NAME) ($(device_cfg ID)); token kept in the $(device_cfg TOKEN_STORE)"
      device_status_write joined; return 0 ;;
    000|5*) device_status_write joining "the brain did not answer ($DEV_HTTP)"; return 2 ;;
    *) rm -f "$cf"; device_log "join refused ($DEV_HTTP): $(device_err)"; device_status_write refused "$(device_err)"; return 1 ;;
  esac
}

# What this agent can be asked to do over the connection (the brain refuses a pin without it).
CR_DEVICE_CAPS="commands update dispatch"
device_rev() { git -C "$CR_ROOT" rev-parse HEAD 2>/dev/null || true; }

device_heartbeat_body() { # <file> <started>
  # (the rev before the probe, which takes a second or more: an update that lands meanwhile is this
  # agent's checkout, not yet this agent, and `node update` waits for the agent that runs it)
  local rev probe tasks='{}'; rev="$(device_rev)"; probe="$(node_probe_local 2>/dev/null || true)"
  if declare -F guest_tasks_json >/dev/null; then tasks="$(guest_tasks_json 2>/dev/null || echo '{}')"; fi
  jq -cn --arg id "$(device_cfg ID)" --arg v "$CR_VERSION" --argjson p "$CR_FLEET_PROTOCOL" --argjson c "$(date +%s)" \
    --argjson s "$2" --arg probe "$probe" --arg rev "$rev" --arg caps "$CR_DEVICE_CAPS" --argjson t "$tasks" \
    '{id: $id, version: $v, protocol: $p, clock: $c, started: $s, probe: $probe, rev: $rev,
      caps: ($caps | split(" ")), tasks: $t}' >"$1"
}

# ---------------------------------------------------------------- commands from the brain

# The agent's second loop: it holds a long-poll open to the brain and runs each command it gets,
# one at a time, in a subshell (a command that dies does not end the loop), and posts the answer.
# A command it has already run (the answer lost on the way) gets the same answer again.
device_poll_loop() {
  local body tok c; body="$(mktemp)"
  mkdir -p "$(device_state_dir)/cmds"
  while true; do
    tok="$(device_token_get)" || tok=""
    [[ -n "$tok" ]] || { sleep 5; continue; }
    jq -cn --arg id "$(device_cfg ID)" --argjson p "$CR_FLEET_PROTOCOL" '{id: $id, protocol: $p, wait: 25}' >"$body"
    DEV_MAXTIME=40 device_post /api/v1/device/commands "$body" "$tok"
    if [[ "$DEV_HTTP" != 200 ]]; then sleep 5; continue; fi
    while IFS= read -r c; do
      [[ -n "$c" ]] && device_run_command "$c" "$tok"
    done < <(jq -c '.commands[]?' <<<"$DEV_BODY" 2>/dev/null || true)
  done
}

device_run_command() { # <command json> <token>
  local c="$1" tok="$2" cid type cache out err rc=0 res i
  cid="$(jq -r '.id // ""' <<<"$c")"; type="$(jq -r '.type // ""' <<<"$c")"
  [[ "$cid" =~ ^c-[0-9]{13}-[0-9a-f]{6}$ ]] || return 0
  cache="$(device_state_dir)/cmds/$cid.json"
  if [[ ! -f "$cache" ]]; then
    out="$(mktemp)"; err="$(mktemp)"
    case "$type" in
      ping|update|dispatch|steer|stop|peek|close|close-done|permit-sync)
        ( "device_cmd_${type//-/_}" "$(jq -c '.payload // {}' <<<"$c")" ) >"$out" 2>"$err" </dev/null || rc=$? ;;
      *) echo "this agent does not know the command '$type' (chartroom node update)" >"$err"; rc=2 ;;
    esac
    jq -cn --arg id "$(device_cfg ID)" --argjson p "$CR_FLEET_PROTOCOL" --arg cmd "$cid" --argjson rc "$rc" \
      --rawfile o "$out" --rawfile e "$err" '{id: $id, protocol: $p, cmd: $cmd, rc: $rc, out: ($o | .[-60000:]), err: ($e | .[-60000:])}' >"$cache"
    rm -f "$out" "$err"
    device_log "command $type ($cid): exit $rc"
    # (the newest 200 answers are kept, for a brain that asks again)
    ls -1t "$(device_state_dir)/cmds"/*.json 2>/dev/null | tail -n +201 | while IFS= read -r f; do rm -f "$f"; done
  fi
  for ((i = 0; i < 3; i++)); do
    device_post /api/v1/device/result "$cache" "$tok"
    [[ "$DEV_HTTP" == 200 || "$DEV_HTTP" == 404 ]] && break
    sleep 2
  done
  return 0
}

device_cmd_ping() { echo "pong from $(device_cfg NAME) at $(device_rev | cut -c1-7)"; }

# Fast-forward this machine's chartroom to the brain's commit, which must be on this checkout's
# own origin/main; the agent then restarts onto it (exit 75: launchd starts it again).
device_cmd_update() { # <payload {rev}>
  local rev cur; rev="$(jq -r '.rev // ""' <<<"$1")"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "update: rev is a full commit id" >&2; return 2; }
  cur="$(device_rev)"
  if [[ "$cur" == "$rev" ]]; then echo "already at ${rev:0:7}"; return 0; fi
  [[ -z "$(git -C "$CR_ROOT" status --porcelain 2>/dev/null)" ]] || { echo "update: $CR_ROOT has local changes; not touched" >&2; return 1; }
  git -C "$CR_ROOT" fetch -q origin main 2>&1 || { echo "update: git fetch failed" >&2; return 1; }
  git -C "$CR_ROOT" merge-base --is-ancestor "$rev" origin/main || { echo "update: ${rev:0:7} is not on this machine's origin/main" >&2; return 1; }
  git -C "$CR_ROOT" merge-base --is-ancestor "$cur" "$rev" || { echo "update: ${rev:0:7} is not ahead of ${cur:0:7}; a device only fast-forwards" >&2; return 1; }
  git -C "$CR_ROOT" merge -q --ff-only "$rev" || { echo "update: the fast-forward failed" >&2; return 1; }
  touch "$(device_state_dir)/restart"
  echo "updated ${cur:0:7} -> ${rev:0:7}; the agent restarts onto it"
}

# A new token this device makes; the brain keeps the old one good 10 minutes, so an answer lost
# on the way is not a lockout: until the new one is confirmed it is kept as "next", and a 401 on
# the old one tries it.
device_rotate() { # <current token>
  local new body; new="$(fleet_rand_hex 32)"; body="$(mktemp)"
  printf '%s' "$new" | device_token_put next
  jq -cn --arg id "$(device_cfg ID)" --arg t "$new" --argjson p "$CR_FLEET_PROTOCOL" '{id: $id, token: $t, protocol: $p}' >"$body"
  device_post /api/v1/device/rotate "$body" "$1"; rm -f "$body"
  if [[ "$DEV_HTTP" == 200 ]]; then
    printf '%s' "$new" | device_token_put; device_token_del next
    device_log "token rotated at the brain's request"
  elif [[ "$DEV_HTTP" =~ ^4 ]]; then
    device_token_del next; device_log "the brain refused a new token ($DEV_HTTP): $(device_err)"
  fi
}

cmd_device_run() {
  local once=0 every started tok body last="" st next=0 now_s
  DEV_POLLER="" # (globals: the EXIT trap reads them after this function has returned)
  [[ "${1:-}" == --once ]] && once=1
  every="$(cfg DEVICE_HEARTBEAT '' 15)"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 )) || die "CHARTROOM_DEVICE_HEARTBEAT is whole seconds (got '$every')"
  [[ -n "$(device_cfg BRAIN)" && -n "$(device_cfg ID)" ]] || die "device run: this machine has not joined a brain (chartroom device join <brain-url> <code>)"
  started="$(date +%s)"; body="$(mktemp)"; DEV_HB_BODY="$body"
  local log; log="$(device_state_dir)/agent.log"
  [[ ! -f "$log" ]] || (( $(wc -c <"$log") < 1048576 )) || mv -f "$log" "$log.1"
  rm -f "$(device_state_dir)/restart"
  device_log "agent started (chartroom $CR_VERSION at $(device_rev | cut -c1-7), pid $$, brain $(device_cfg BRAIN), every ${every}s)"
  # shellcheck disable=SC2064 # the poller's pid, when it exits
  trap '[[ -z "${DEV_POLLER:-}" ]] || kill "$DEV_POLLER" 2>/dev/null; rm -f "${DEV_HB_BODY:-}"' EXIT
  trap 'exit 143' TERM INT # (so the EXIT trap ends the poller too)
  while true; do
    if [[ -f "$(device_state_dir)/join-code" ]]; then
      st=0; device_do_join || st=$?
      if (( st == 1 )); then return 0; fi # refused: stays stopped until joined again
      if (( st == 2 )); then (( once )) && return 1; sleep 30; continue; fi
    fi
    if [[ -f "$(device_state_dir)/restart" ]]; then
      rm -f "$(device_state_dir)/restart"
      device_log "restarting onto chartroom $(device_rev | cut -c1-7)"
      exit 75 # (not 0: launchd's KeepAlive starts it again)
    fi
    # the second loop, for commands (not with --once: one heartbeat, nothing else)
    if (( ! once )) && { [[ -z "$DEV_POLLER" ]] || ! pid_alive "$DEV_POLLER"; }; then
      device_poll_loop & DEV_POLLER=$!
    fi
    now_s="$(date +%s)"
    if declare -F guest_push_all >/dev/null; then guest_push_all || true; fi
    if (( now_s >= next )); then
      next=$((now_s + every))
      tok="$(device_token_get)" || tok=""
      if [[ -z "$tok" ]]; then
        device_log "no token here: chartroom device join <brain-url> <code> again; the agent stops"
        device_status_write error "no token"; return 0
      fi
      device_heartbeat_body "$body" "$started"
      device_post /api/v1/device/heartbeat "$body" "$tok"
      if [[ "$DEV_HTTP" == 401 ]] && tok="$(device_token_get next)" && [[ -n "$tok" ]]; then
        device_post /api/v1/device/heartbeat "$body" "$tok"
        if [[ "$DEV_HTTP" == 200 ]]; then printf '%s' "$tok" | device_token_put; device_token_del next; fi
      fi
      case "$DEV_HTTP" in
        200)
          DEV_LAST_OK="$(now)"
          [[ "$last" == ok ]] || device_log "heartbeat ok: the brain knows this machine as $(jq -r '.name // "?"' <<<"$DEV_BODY")"
          last=ok
          local nm; nm="$(jq -r '.name // empty' <<<"$DEV_BODY" 2>/dev/null || true)"
          [[ -z "$nm" || "$nm" == "$(device_cfg NAME)" ]] || device_set_cfg NAME "$nm"
          device_status_write ok
          [[ "$(jq -r '.rotate // false' <<<"$DEV_BODY")" != true ]] || device_rotate "$tok" ;;
        401)
          device_log "the brain revoked this device (401: $(device_err)); the agent stops and leaves everything here as it is"
          device_status_write revoked "$(device_err)"; return $(( once ? 1 : 0 )) ;; # exit 0: launchd leaves it stopped
        *)
          st="$( [[ "$DEV_HTTP" == 000 ]] && echo "the brain did not answer" || echo "the brain answered $DEV_HTTP: $(device_err)")"
          [[ "$last" == "$st" ]] || device_log "heartbeat failed: $st (trying again every ${every}s)"
          last="$st"; device_status_write unreachable "$st" ;;
      esac
      if (( once )); then [[ "$last" == ok ]]; return; fi
    fi
    sleep 2
  done
}

# chartroom device update: the same fast-forward as the brain's `node update`, by hand here (an
# agent from before updates over the connection), then the agent is restarted.
cmd_device_update() {
  local rev; git -C "$CR_ROOT" fetch -q origin main || die "device update: git fetch failed"
  rev="$(git -C "$CR_ROOT" rev-parse origin/main)"
  device_cmd_update "$(jq -cn --arg r "$rev" '{rev: $r}')" || exit 1
  rm -f "$(device_state_dir)/restart"
  local lc; lc="$(device_launchctl)"
  if [[ -n "$lc" ]] && "$lc" print "gui/$(id -u)/$CR_DEVICE_LABEL" >/dev/null 2>&1; then
    "$lc" kickstart -k "gui/$(id -u)/$CR_DEVICE_LABEL" && echo "the agent restarted"
  fi
}

# ---------------------------------------------------------------- the LaunchAgent

device_plist_path() { printf '%s' "$HOME/Library/LaunchAgents/$CR_DEVICE_LABEL.plist"; }
xml_esc() { # (sed, not ${s//}: bash 5.2 reads & in a replacement as the match)
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

device_write_plist() {
  local f bin log env="" k; f="$(device_plist_path)"; mkdir -p "$(dirname "$f")" "$(device_state_dir)"
  bin="$CR_BIN" # this checkout's own (a CHARTROOM_BIN in the caller's environment may be another chartroom)
  log="$(device_state_dir)/agent.log"
  for k in SHELL XDG_CONFIG_HOME XDG_STATE_HOME CHARTROOM_CONFIG; do
    [[ -n "${!k:-}" ]] && env+="<key>$k</key><string>$(xml_esc "${!k}")</string>"
  done
  cat >"$f.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- chartroom's device agent (written by chartroom device join; chartroom device leave removes it) -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$CR_DEVICE_LABEL</string>
  <key>ProgramArguments</key><array><string>$(xml_esc "$bin")</string><string>device</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>HOME</key><string>$(xml_esc "$HOME")</string>$env</dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$(xml_esc "$log")</string>
  <key>StandardErrorPath</key><string>$(xml_esc "$log")</string>
</dict>
</plist>
PLIST
  mv "$f.tmp" "$f"
}

device_agent_load() { # (re)starts the agent in the login session
  local lc dom; lc="$(device_launchctl)"; dom="gui/$(id -u)"
  "$lc" bootout "$dom/$CR_DEVICE_LABEL" >/dev/null 2>&1 || true
  "$lc" bootstrap "$dom" "$(device_plist_path)" 2>&1 || return 1
}
device_agent_state() { # running, loaded, not loaded, or "-" where launchd is not used
  local lc out; lc="$(device_launchctl)"
  [[ -n "$lc" ]] || { echo "-"; return; }
  out="$("$lc" print "gui/$(id -u)/$CR_DEVICE_LABEL" 2>/dev/null)" || { echo "not loaded"; return; }
  if grep -q 'state = running' <<<"$out"; then echo running; else echo loaded; fi
}

# ---------------------------------------------------------------- join / status / leave

cmd_device_join() {
  [[ $# -eq 2 ]] || die "usage: chartroom device join <brain-url> <code|->   (the code from chartroom node add on the brain; - reads it from stdin)"
  local url="${1%/}" code="$2" id i st
  [[ "$code" != - ]] || IFS= read -r code || true
  [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ || "$url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] ||
    die "device join: the brain's URL is https://<host> (its app's Tailscale address; http only for 127.0.0.1)"
  code="$(fleet_code_norm "$code")"
  [[ "$code" =~ ^[A-Z0-9]{10}$ ]] || die "device join: that is not an enrolment code (XXXXX-XXXXX, from chartroom node add)"
  [[ "$(curl -sS --max-time 10 "$url/healthz" 2>&1)" == ok ]] || die "device join: cannot reach the brain at $url (curl $url/healthz did not say ok)"
  [[ -n "$(device_hw_uuid)" ]] || die "device join: cannot read this machine's hardware id"
  id="$(device_node_id)"
  device_set_cfg BRAIN "$url"; device_set_cfg ID "$id"
  mkdir -p "$(device_state_dir)"
  ( umask 077; printf '%s\n' "$code" >"$(device_state_dir)/join-code" )
  rm -f "$(device_state_dir)/agent.json"
  if [[ -z "$(device_launchctl)" ]]; then
    st=0; device_do_join || st=$?
    case $st in
      0) echo "joined $url as $(device_cfg NAME) ($id); token in the $(device_cfg TOKEN_STORE)"
         echo "start the agent: chartroom device run (as a service of your own; on macOS join loads it with launchd)" ;;
      1) die "device join: the brain refused: $(jq -r '.error // empty' "$(device_state_dir)/agent.json")" ;;
      *) die "device join: the brain did not answer; run it again" ;;
    esac
    return 0
  fi
  device_write_plist
  device_agent_load >/dev/null || die "device join: launchd would not load the agent (is this user logged in at the screen? the agent runs in the login session)"
  for ((i = 0; i < 90; i++)); do
    st="$(jq -r '.state // empty' "$(device_state_dir)/agent.json" 2>/dev/null || true)"
    [[ "$st" == ok || "$st" == refused || "$st" == revoked || "$st" == error ]] && break
    sleep 0.5
  done
  case "$st" in
    ok) echo "joined $url as $(device_cfg NAME) ($id); the agent runs ($CR_DEVICE_LABEL) and its first heartbeat was answered"
        echo "token in the $(device_cfg TOKEN_STORE)$([[ "$(device_cfg TOKEN_STORE)" == keychain ]] && echo " (service $CR_DEVICE_KEYCHAIN_SERVICE, account $id)")" ;;
    refused|revoked|error) die "device join: $(jq -r '.error // .state' "$(device_state_dir)/agent.json") (log: $(device_state_dir)/agent.log)" ;;
    *) die "device join: no answer from the agent within 45s (state '${st:-none}'; log: $(device_state_dir)/agent.log)" ;;
  esac
}

device_status_json() {
  local st; st="$(jq -c . "$(device_state_dir)/agent.json" 2>/dev/null || echo null)"
  jq -cn --arg b "$(device_cfg BRAIN)" --arg id "$(device_cfg ID)" --arg n "$(device_cfg NAME)" --arg ts "$(device_cfg TOKEN_STORE)" \
    --arg agent "$(device_agent_state)" --argjson st "$st" --arg pending "$([[ -f "$(device_state_dir)/join-code" ]] && echo 1)" \
    '{joined: ($b != "" and $n != ""), brain: (if $b == "" then null else $b end), id: (if $id == "" then null else $id end),
      name: (if $n == "" then null else $n end), token_store: (if $ts == "" then null else $ts end),
      join_pending: ($pending == "1"), agent: $agent, last: $st}'
}

cmd_device_status() {
  local j; j="$(device_status_json)"
  [[ "${1:-}" == --json ]] && { printf '%s\n' "$j"; return; }
  jq -r 'if .joined | not then (if .join_pending then "joining \(.brain) (the agent makes the join; chartroom device status again)" else "not joined (chartroom device join <brain-url> <code>)" end)
    else "joined \(.brain) as \(.name) (\(.id)); token in the \(.token_store // "?")" end,
    "agent: \(.agent)" + (if .last then "; last: \(.last.state) at \(.last.at)" + (if .last.error then " (\(.last.error))" else "" end) else "" end)' <<<"$j"
}

cmd_device_leave() {
  local lc; lc="$(device_launchctl)"
  if [[ -n "$lc" ]]; then "$lc" bootout "gui/$(id -u)/$CR_DEVICE_LABEL" >/dev/null 2>&1 || true; rm -f "$(device_plist_path)"; fi
  local name; name="$(device_cfg NAME)"
  device_token_del next; device_token_del
  rm -f "$(device_config_path)" "$(device_state_dir)/join-code" "$(device_state_dir)/agent.json"
  echo "left: the agent is stopped and the token is gone from this machine (its node id stays in $(node_config_path))"
  echo "on the brain, also: chartroom node revoke ${name:-<its name>}"
}

cmd_device() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    join) cmd_device_join "$@" ;;
    run) cmd_device_run "$@" ;;
    status) cmd_device_status "$@" ;;
    leave) cmd_device_leave "$@" ;;
    update) cmd_device_update "$@" ;;
    *) die "usage: chartroom device join <brain-url> <code> | run [--once] | status [--json] | leave | update" ;;
  esac
}

# For doctor, on a device.
device_doctor_line() {
  [[ -f "$(device_config_path)" ]] || return 0
  cmd_device_status | paste -sd '|' - | sed 's/|/; /g; s/^/device:   /'
}
