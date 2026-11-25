# shellcheck shell=bash
# fleet.sh - the brain's side of devices (docs/multi-machine.md, "Devices"): a machine that runs
# chartroom's device agent (lib/device.sh) enrols once with a one-time code and then pushes a
# heartbeat to the brain's app server every 15 s. The brain never reaches out to it.
#
#   chartroom node add [--name N] [--alias A]... [--replace NAME|ID]
#                                   a one-time enrolment code (single use, 10 min) and the command
#                                   to run on the device
#   chartroom node rename <name|id> <new>   names are display only; the old one is kept as an alias
#   chartroom node revoke <name|id>         its token stops working: the device's next request gets
#                                           401 and its agent stops; nothing on it is touched
#   chartroom node rotate <name|id>         a new token on its next heartbeat
#   chartroom fleet join|rotate             the app server's (lib/app/server.py) writes: one JSON
#                                           document on stdin, one on stdout; not for people
#
# The registry is this machine's, not a home's: fleet/ beside the app server's own state (the
# directory of the config file, ~/.config/chartroom/fleet; CHARTROOM_FLEET_DIR moves it), so an app
# server started under another config (a test's, a worktree's) never shares it.
#   devices/<id>.json       who the device is: id, name, aliases, host, hw_uuid, enrolled, the
#                           sha256 of its token (never the token), and a rotate or revoke. Written
#                           here only, under the registry's lock.
#   devices/<id>.seen.json  what it last said: last_seen, its clock, version, protocol and its
#                           probe (lib/nodeprobe.sh's lines). Written by the app server only.
#   codes/<sha256>.json     an enrolment code not yet used (the code itself is never stored)
#   queue/<id>/<cmd>.json   a command for that device, until it answers (written here only; the
#                           device takes it by long-poll: POST /api/v1/device/commands)
#   results/<cmd>.json      a device's answer to one (written by the server; read and removed here)
#   endpoint                "<pid> <since>": the app server that takes heartbeats, and since when
#
# A device's status is decided here, at read time, never in the server:
#   online   heard from within CHARTROOM_NODE_STALE_SECONDS (45)
#   stale    longer than that; nothing is placed on it
#   lost     not heard from for CHARTROOM_NODE_LOST_MINUTES (10) of the endpoint's own uptime:
#            while the brain's endpoint is down, a device's silence is not counted against it, and
#            after a restart every device is stale until it says hello again
#   new      enrolled, no heartbeat yet
#   revoked  its token was revoked
#   unknown  the endpoint is not running here, so nothing can be heard

CR_DEVICE_ID_RE='^n-[0-9a-f]{12}$'
CR_DEVICE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
CR_FLEET_PROTOCOL=1
CR_FLEET_CODE_TTL=600
CR_FLEET_CODE_ALPHABET='ABCDEFGHJKMNPQRSTUVWXYZ23456789'

fleet_dir() { printf '%s' "${CHARTROOM_FLEET_DIR:-${CR_CONFIG_FILE%/*}/fleet}"; }

sha256_hex() { # stdin -> hex
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

fleet_rand_hex() { # <bytes>
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$1"
  else od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; fi
}

# A code people can read out: 10 letters and digits with no 0/O, 1/I/L, as XXXXX-XXXXX.
fleet_new_code() {
  local hex i c="" n=${#CR_FLEET_CODE_ALPHABET}
  hex="$(fleet_rand_hex 10)"
  for ((i = 0; i < 10; i++)); do c+="${CR_FLEET_CODE_ALPHABET:$(( 16#${hex:$((i * 2)):2} % n )):1}"; done
  printf '%s-%s' "${c:0:5}" "${c:5:5}"
}
fleet_code_norm() { local c="${1^^}"; c="${c//[- ]/}"; printf '%s' "$c"; }

# The registry's lock (a directory holding its holder's pid); a dead holder's lock is taken over.
fleet_lock() {
  local d i; d="$(fleet_dir)/.lock"; mkdir -p "$(fleet_dir)"
  for ((i = 0; i < 100; i++)); do
    if mkdir "$d" 2>/dev/null; then echo $$ >"$d/pid"; return 0; fi
    pid_alive "$(cat "$d/pid" 2>/dev/null)" || { rm -rf "$d"; continue; }
    sleep 0.1
  done
  die "the device registry is locked ($d)"
}
fleet_unlock() { rm -rf "$(fleet_dir)/.lock"; }

fleet_write() { # <file> <json>: atomically, 0600
  local f="$1" tmp; tmp="$f.tmp.$$"
  mkdir -p "$(dirname "$f")"
  ( umask 077; printf '%s\n' "$2" >"$tmp" ) && mv "$tmp" "$f"
}

fleet_settings() { # sets FLEET_STALE_S, FLEET_LOST_S
  FLEET_STALE_S="$(cfg NODE_STALE_SECONDS '' 45)"; local m; m="$(cfg NODE_LOST_MINUTES '' 10)"
  [[ "$FLEET_STALE_S" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]] && (( FLEET_STALE_S > 0 && m > 0 )) ||
    die "CHARTROOM_NODE_STALE_SECONDS and CHARTROOM_NODE_LOST_MINUTES are whole numbers above 0 (got '$FLEET_STALE_S', '$m')"
  FLEET_LOST_S=$((m * 60))
}

# The endpoint taking heartbeats on this machine, as "<since epoch>" when it runs, else nothing.
fleet_endpoint_since() {
  local f pid since; f="$(fleet_dir)/endpoint"
  [[ -f "$f" ]] || return 0
  read -r pid since <"$f" || true
  pid_alive "$pid" && ps -p "$pid" -o command= 2>/dev/null | grep -q 'app/server\.py' && [[ "$since" =~ ^[0-9]+$ ]] && printf '%s' "$since"
  return 0
}

# Every enrolled device with what it last said and its status: a JSON array, by name.
fleet_devices_json() {
  local d f now since
  d="$(fleet_dir)/devices"; fleet_settings
  now="$(date +%s)"; since="$(fleet_endpoint_since)"
  shopt -s nullglob
  local files=() rows=()
  for f in "$d"/n-*.json; do [[ "$f" == *.seen.json ]] || files+=("$f"); done
  shopt -u nullglob
  for f in "${files[@]+"${files[@]}"}"; do
    rows+=("$(jq -c --slurpfile seen <(cat "${f%.json}.seen.json" 2>/dev/null || true) '{dev: ., seen: ($seen[0] // null)}' "$f" 2>/dev/null)") || true
  done
  printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -s -c --argjson now "$now" --arg since "$since" \
    --argjson stale "$FLEET_STALE_S" --argjson lost "$FLEET_LOST_S" '
    (if $since == "" then null else ($since | tonumber) end) as $up
    | map(select(.dev.id != null) | .dev as $d | .seen as $s
      | ($s.last_seen // null) as $ls
      | (if $d.revoked then "revoked"
         elif $up == null then "unknown"
         elif $ls == null then "new"
         elif $ls < $up then (if $now - $up >= $lost then "lost" else "stale" end)
         elif $now - $ls < $stale then "online"
         elif $now - $ls < $lost then "stale"
         else "lost" end) as $st
      | {id: $d.id, name: $d.name, aliases: ($d.aliases // []), host: $d.host, hw_uuid: ($d.hw_uuid // null), enrolled: $d.enrolled,
         revoked: ($d.revoked // null), rotate_pending: ($d.rotate // false), status: $st,
         last_seen: $ls, seen_age_s: (if $ls == null then null else $now - $ls end),
         version: ($s.version // null), protocol: ($s.protocol // null), rev: ($s.rev // null), caps: ($s.caps // []), tasks: ($s.tasks // {}),
         skew_s: (if $s.clock != null and $ls != null then $s.clock - $ls else null end),
         probe: ($s.probe // null)})
    | sort_by(.name)'
}

# <name|id> -> its id (a live device's name before a revoked one's)
fleet_resolve() {
  local want="$1" id
  id="$(fleet_devices_json | jq -r --arg w "$want" '
    ([.[] | select(.id == $w)] + [.[] | select(.name == $w and .status != "revoked")]
     + [.[] | select(.name == $w)] + [.[] | select((.aliases | index($w)) and .status != "revoked")]) | .[0].id // empty')"
  [[ -n "$id" ]] || die "no enrolled device is called '$want' (chartroom nodes lists them)"
  printf '%s' "$id"
}

fleet_name_taken() { # <name> [except id] -> 0 when another live device holds it
  fleet_devices_json | jq -e --arg n "$1" --arg x "${2:-}" 'any(.[]; .id != $x and .status != "revoked" and .name == $n)' >/dev/null
}

# ---------------------------------------------------------------- commands for a device

fleet_ms() { perl -MTime::HiRes=time -e 'printf "%013d", time * 1000'; }

# Queues a command; prints its id. It waits for the device however long it is offline, unless a
# ttl is given: then the server answers it "expired" once the ttl has passed untaken.
fleet_enqueue() { # <device id> <type> <payload json> [ttl seconds]
  local did="$1" type="$2" payload="$3" ttl="${4:-0}" cid exp=null
  [[ "$did" =~ $CR_DEVICE_ID_RE ]] || die "fleet: no device $did"
  cid="c-$(fleet_ms)-$(fleet_rand_hex 3)"
  (( ttl > 0 )) && exp=$(( $(date +%s) + ttl ))
  # (the payload on stdin: a dispatch carries files, past what a command line holds)
  fleet_write "$(fleet_dir)/queue/$did/$cid.json" "$(jq -c --arg id "$cid" --arg t "$type" \
    --arg at "$(now)" --argjson e "$exp" '{id: $id, type: $t, payload: ., at: $at, expires: $e}' <<<"$payload")"
  printf '%s' "$cid"
}

# Waits for a command's answer: prints it ({rc, out, err}) and removes it; 1 on timeout.
fleet_wait() { # <cmd id> <seconds>
  local f i n; f="$(fleet_dir)/results/$1.json"; n=$(( $2 * 4 ))
  for ((i = 0; i <= n; i++)); do
    if [[ -f "$f" ]]; then cat "$f"; rm -f "$f"; return 0; fi
    sleep 0.25
  done
  return 1
}
fleet_withdraw() { rm -f "$(fleet_dir)/queue/$1/$2.json"; } # <device id> <cmd id>

# A command run to its answer: its output printed, its exit code returned. A command not taken
# within <seconds> is withdrawn (it never runs late) unless --keep: then it stays queued.
fleet_call() { # <device id> <type> <payload json> <seconds> [--keep]
  local cid res
  cid="$(fleet_enqueue "$1" "$2" "$3")"
  if ! res="$(fleet_wait "$cid" "$4")"; then
    if [[ "${5:-}" == --keep ]]; then FLEET_CID="$cid"; return 124; fi
    fleet_withdraw "$1" "$cid"
    # (it may have been taken just now: its answer, if one comes, is read and dropped)
    [[ -f "$(fleet_dir)/results/$cid.json" ]] && { res="$(cat "$(fleet_dir)/results/$cid.json")"; rm -f "$(fleet_dir)/results/$cid.json"; } || return 124
  fi
  printf '%s' "$(jq -r '.out // ""' <<<"$res")"
  local err; err="$(jq -r '.err // ""' <<<"$res")"; [[ -z "$err" ]] || printf '%s\n' "$err" >&2
  return "$(jq -r '.rc // 1' <<<"$res")"
}

fleet_device_json() { # <id> -> its row of fleet_devices_json
  fleet_devices_json | jq -c --arg id "$1" '.[] | select(.id == $id)'
}

# chartroom node ping <name|id>: a round trip over the connection (the command channel works).
cmd_node_ping() {
  [[ $# -eq 1 ]] || die "usage: chartroom node ping <name|id>"
  local id rc=0 t0; id="$(fleet_resolve "$1")"; t0="$(fleet_ms)"
  fleet_call "$id" ping '{}' 30 || rc=$?
  if (( rc == 124 )); then die "node ping: $1 did not take the command within 30s ($(fleet_device_json "$id" | jq -r .status))"; fi
  echo " ($(( ($(fleet_ms) - t0) )) ms)"
  return "$rc"
}

# chartroom node update <name|id>|--all: the device moves its chartroom to this brain's commit
# (it must be on the device's own origin/main: a device only ever fast-forwards) and its agent
# restarts onto it. Waits for the heartbeat that says so.
cmd_node_update() {
  local targets=() a rev ids id row name rc out i got
  [[ $# -ge 1 ]] || die "usage: chartroom node update <name|id>... | --all"
  if [[ "$1" == --all ]]; then mapfile -t targets < <(fleet_devices_json | jq -r '.[] | select(.status != "revoked") | .id')
  else for a in "$@"; do targets+=("$(fleet_resolve "$a")"); done; fi
  rev="$(git -C "$CR_ROOT" rev-parse HEAD)"
  local fail=0
  for id in "${targets[@]+"${targets[@]}"}"; do
    row="$(fleet_device_json "$id")"; name="$(jq -r .name <<<"$row")"
    if [[ "$(jq -r .status <<<"$row")" != online ]]; then echo "$name: $(jq -r .status <<<"$row"), not updated (it takes no command until it is back)"; fail=1; continue; fi
    if ! jq -e '.caps | index("update")' <<<"$row" >/dev/null; then echo "$name: its agent is older than updates over the connection (once by hand: chartroom device update there)"; fail=1; continue; fi
    if [[ "$(jq -r '.rev // ""' <<<"$row")" == "$rev" ]]; then echo "$name: already at ${rev:0:7}"; continue; fi
    rc=0; out="$(fleet_call "$id" update "$(jq -cn --arg r "$rev" '{rev: $r}')" 90 2>&1)" || rc=$?
    if (( rc != 0 )); then echo "$name: update failed ($rc): $out"; fail=1; continue; fi
    echo "$name: $out"
    got=""
    for ((i = 0; i < 120; i++)); do
      got="$(fleet_device_json "$id" | jq -r '.rev // ""')"
      [[ "$got" == "$rev" ]] && break
      sleep 1
    done
    if [[ "$got" == "$rev" ]]; then echo "$name: its agent restarted and reports ${rev:0:7}"
    else echo "$name: updated, but no heartbeat from the new agent within 2 minutes (last rev ${got:0:7})"; fail=1; fi
  done
  return "$fail"
}

# ---------------------------------------------------------------- node add / rename / revoke / rotate

cmd_node_add() {
  local name="" replace="" aliases=() code sha exp url rid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --alias) aliases+=("${2:-}"); shift 2 ;;
      --replace) replace="${2:-}"; shift 2 ;;
      *) die "node add: unknown arg $1 (usage: chartroom node add [--name N] [--alias A]... [--replace NAME|ID])" ;;
    esac
  done
  local a
  for a in ${name:+"$name"} "${aliases[@]+"${aliases[@]}"}"; do
    [[ "$a" =~ $CR_DEVICE_NAME_RE ]] || die "node add: '$a' is not a name (letters, digits, . _ -; up to 64)"
  done
  if [[ -n "$replace" ]]; then rid="$(fleet_resolve "$replace")"; fi
  if [[ -n "$name" ]] && fleet_name_taken "$name" "$rid"; then die "node add: a device is already called '$name' (chartroom node rename, or --replace it)"; fi
  code="$(fleet_new_code)"; sha="$(printf '%s' "$(fleet_code_norm "$code")" | sha256_hex)"
  exp=$(( $(date +%s) + CR_FLEET_CODE_TTL ))
  fleet_write "$(fleet_dir)/codes/$sha.json" "$(jq -cn --arg n "$name" --arg r "$rid" --argjson e "$exp" --arg at "$(now)" \
    '{name: (if $n == "" then null else $n end), aliases: $ARGS.positional, replace: (if $r == "" then null else $r end), expires: $e, issued: $at}' \
    --args "${aliases[@]+"${aliases[@]}"}")"
  url="$(fleet_brain_url)"
  echo "enrolment code${name:+ for $name}: $code (single use, valid until $(date -u -r "$exp" +%H:%M:%SZ 2>/dev/null || date -u -d "@$exp" +%H:%M:%SZ))"
  [[ -z "$rid" ]] || echo "it replaces $replace ($rid): that entry is revoked when the new one joins"
  echo "on the device (after install.sh --device):"
  echo "  chartroom device join ${url:-<the brain app URL>} $code"
  [[ -n "$url" ]] || echo "(the app is not on the tailnet yet: chartroom app doctor prints how; devices reach the brain there)"
}

# The URL devices reach this brain at: CHARTROOM_BRAIN_URL, else the app's Tailscale Serve URL.
fleet_brain_url() {
  local u; u="$(cfg BRAIN_URL '' '')"
  if [[ -z "$u" ]]; then u="$(app_serve_url "$(app_port)" 2>/dev/null || true)"; fi
  printf '%s' "${u%/}"
}

fleet_update() { # <id> <jq filter> [jq args...]: under the lock
  local id="$1" f flt="$2"; shift 2
  f="$(fleet_dir)/devices/$id.json"
  [[ -f "$f" ]] || die "no device $id"
  fleet_write "$f" "$(jq -c "$@" "$flt" "$f")"
}

cmd_node_rename() {
  [[ $# -eq 2 ]] || die "usage: chartroom node rename <name|id> <new name>"
  [[ "$2" =~ $CR_DEVICE_NAME_RE ]] || die "node rename: '$2' is not a name (letters, digits, . _ -; up to 64)"
  fleet_lock; trap fleet_unlock EXIT
  local id; id="$(fleet_resolve "$1")"
  fleet_name_taken "$2" "$id" && die "node rename: a device is already called '$2'"
  fleet_update "$id" '(.name) as $old | .name = $new | .aliases = ((.aliases // []) + [$old] | map(select(. != $new)) | unique)' --arg new "$2"
  echo "renamed $1 to $2 ($id); '$1' stays an alias"
}

cmd_node_revoke() {
  [[ $# -eq 1 ]] || die "usage: chartroom node revoke <name|id>"
  fleet_lock; trap fleet_unlock EXIT
  local id; id="$(fleet_resolve "$1")"
  fleet_unlock; env_drop_node "$id"; fleet_lock # (told while its token still works: the env files it was given go first)
  fleet_update "$id" '.token_sha256 = null | .prev_sha256 = null | .prev_until = null | .rotate = false | .revoked = $at' --arg at "$(now)"
  echo "revoked $1 ($id): its next request gets 401 and its agent stops; nothing on it is touched"
  echo "to enrol it again: chartroom node add --replace $id"
}

cmd_node_rotate() {
  [[ $# -eq 1 ]] || die "usage: chartroom node rotate <name|id>"
  fleet_lock; trap fleet_unlock EXIT
  local id; id="$(fleet_resolve "$1")"
  jq -e '.revoked == null' "$(fleet_dir)/devices/$id.json" >/dev/null || die "node rotate: $1 is revoked (chartroom node add --replace $id)"
  fleet_update "$id" '.rotate = true'
  echo "$1 ($id) takes a new token on its next heartbeat; the old one then works for 10 more minutes"
}

# ---------------------------------------------------------------- fleet join / rotate (the server's)

# Exit codes the server maps to HTTP: 0 200, 2 400, 3 401, 4 409.
fleet_fail() { printf 'chartroom: %s\n' "$2" >&2; exit "$1"; }

# stdin {code, id, host, hw_uuid, version, protocol} -> {id, name, token, protocol}
fleet_join() {
  local in code sha cf used meta id host hw now_s name rid old token
  in="$(cat)"; jq -e 'type == "object"' >/dev/null 2>&1 <<<"$in" || fleet_fail 2 "the body is not a JSON object"
  code="$(jq -r '.code // "" | tostring' <<<"$in")"; id="$(jq -r '.id // "" | tostring' <<<"$in")"
  host="$(jq -r '.host // "" | tostring' <<<"$in")"; hw="$(jq -r '.hw_uuid // "" | tostring' <<<"$in")"
  [[ "$(jq -r '.protocol // 0' <<<"$in")" == "$CR_FLEET_PROTOCOL" ]] || fleet_fail 4 "this brain speaks device protocol $CR_FLEET_PROTOCOL; update chartroom on the device"
  [[ "$id" =~ $CR_DEVICE_ID_RE ]] || fleet_fail 2 "the device id is not n-<12 hex>"
  [[ "$hw" =~ ^[A-Za-z0-9-]{1,64}$ ]] || fleet_fail 2 "the hardware id is missing or malformed"
  [[ "$host" =~ ^[A-Za-z0-9._-]{1,253}$ ]] || fleet_fail 2 "the host name is missing or malformed"
  code="$(fleet_code_norm "$code")"
  [[ "$code" =~ ^[A-Z0-9]{10}$ ]] || fleet_fail 3 "that is not an enrolment code"
  sha="$(printf '%s' "$code" | sha256_hex)"; cf="$(fleet_dir)/codes/$sha.json"
  fleet_lock; trap fleet_unlock EXIT
  used="$cf.used.$$"
  mv "$cf" "$used" 2>/dev/null || fleet_fail 3 "that code is not valid: used already, expired, or never issued (chartroom node add on the brain makes a new one)"
  meta="$(cat "$used")"; rm -f "$used"
  now_s="$(date +%s)"
  (( $(jq -r '.expires' <<<"$meta") > now_s )) || fleet_fail 3 "that code expired (they last 10 minutes; chartroom node add makes a new one)"
  rid="$(jq -r '.replace // ""' <<<"$meta")"
  local devs; devs="$(fleet_devices_json)"
  # a machine already enrolled under another entry is refused, naming it, unless the code replaces it
  old="$(jq -r --arg hw "$hw" --arg id "$id" --arg r "$rid" \
    '[.[] | select(.status != "revoked" and .id != $r and (.id == $id or .hw_uuid == $hw))] | .[0] | if . then "\(.name)\t\(.id)" else "" end' <<<"$devs")"
  [[ -z "$old" ]] || fleet_fail 4 "this machine is already enrolled as ${old%%$'\t'*} (${old#*$'\t'}); on the brain, chartroom node add --replace ${old#*$'\t'} makes a code that replaces it"
  name="$(jq -r '.name // ""' <<<"$meta")"
  if [[ -z "$name" && -n "$rid" ]]; then name="$(jq -r --arg r "$rid" '.[] | select(.id == $r) | .name' <<<"$devs")"; fi
  if [[ -z "$name" ]]; then name="${host%%.*}"; name="${name,,}"; fi
  [[ "$name" =~ $CR_DEVICE_NAME_RE ]] || name="device-${id#n-}"
  if jq -e --arg n "$name" --arg id "$id" --arg r "$rid" 'any(.[]; .id != $id and .id != $r and .status != "revoked" and .name == $n)' <<<"$devs" >/dev/null; then
    fleet_fail 4 "a device is already called '$name' (on the brain: chartroom node add --name <another>)"
  fi
  token="$(fleet_rand_hex 32)"
  if [[ -n "$rid" && "$rid" != "$id" && -f "$(fleet_dir)/devices/$rid.json" ]]; then
    fleet_update "$rid" '.token_sha256 = null | .prev_sha256 = null | .revoked = $at | .replaced_by = $new' --arg at "$(now)" --arg new "$id"
  fi
  fleet_write "$(fleet_dir)/devices/$id.json" "$(jq -cn --arg id "$id" --arg n "$name" --arg h "$host" --arg hw "$hw" --arg at "$(now)" \
    --arg sha "$(printf '%s' "$token" | sha256_hex)" --argjson al "$(jq -c '.aliases // []' <<<"$meta")" \
    '{id: $id, name: $n, aliases: $al, host: $h, hw_uuid: $hw, enrolled: $at, token_sha256: $sha, prev_sha256: null, prev_until: null, rotate: false, revoked: null}')"
  jq -cn --arg id "$id" --arg n "$name" --arg t "$token" --argjson p "$CR_FLEET_PROTOCOL" '{id: $id, name: $n, token: $t, protocol: $p}'
}

# stdin {id, auth_sha256, token}: the server has checked the device's current token (whose
# sha256 is auth_sha256); the new one replaces it, and the one that asked stays good 10 minutes,
# in case the device never heard the answer.
fleet_rotate() {
  local in id auth new f
  in="$(cat)"; id="$(jq -r '.id // ""' <<<"$in")"; auth="$(jq -r '.auth_sha256 // ""' <<<"$in")"; new="$(jq -r '.token // ""' <<<"$in")"
  [[ "$id" =~ $CR_DEVICE_ID_RE ]] || fleet_fail 2 "the device id is not n-<12 hex>"
  [[ "$new" =~ ^[0-9a-f]{64}$ ]] || fleet_fail 2 "a new token is 64 hex characters"
  fleet_lock; trap fleet_unlock EXIT
  f="$(fleet_dir)/devices/$id.json"
  [[ -f "$f" ]] || fleet_fail 3 "unknown device"
  jq -e --arg a "$auth" --argjson now "$(date +%s)" '.revoked == null and (.token_sha256 == $a or (.prev_sha256 == $a and (.prev_until // 0) > $now))' "$f" >/dev/null ||
    fleet_fail 3 "that token no longer opens this device's routes"
  fleet_update "$id" '.prev_sha256 = $a | .prev_until = ($now + 600) | .token_sha256 = $sha | .rotate = false' \
    --arg a "$auth" --argjson now "$(date +%s)" --arg sha "$(printf '%s' "$new" | sha256_hex)"
  jq -cn '{ok: true}'
}

cmd_fleet() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    join) fleet_join "$@" ;;
    rotate) fleet_rotate "$@" ;;
    devices) [[ "${1:-}" == --json ]] || die "usage: chartroom fleet devices --json"; fleet_devices_json | jq 'map(del(.probe))' ;;
    ingest) node_ingest "$@" ;;
    *) die "usage: chartroom fleet join|rotate (the app server's; one JSON document on stdin) | fleet devices --json" ;;
  esac
}

# ---------------------------------------------------------------- doctor

fleet_doctor_line() {
  [[ -d "$(fleet_dir)/devices" ]] || return 0 # never a brain to devices
  local devs since; devs="$(fleet_devices_json 2>/dev/null || echo '[]')"; since="$(fleet_endpoint_since)"
  if [[ "$(jq length <<<"$devs")" == 0 ]]; then
    echo "fleet:    no devices (chartroom node add enrols one)"; return
  fi
  jq -r --arg since "$since" '"fleet:    \(length) device(s): " + (map("\(.name) \(.status)" + (if .seen_age_s != null and .status != "revoked" then " (\(.seen_age_s)s ago)" else "" end)) | join(", "))
    + (if $since == "" then "; the app server is not running, so no heartbeat is heard (chartroom app serve --daemon)" else "" end)' <<<"$devs"
}
