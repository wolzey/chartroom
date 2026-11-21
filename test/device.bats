#!/usr/bin/env bats
# Devices (lib/fleet.sh, lib/device.sh, the device routes in lib/app/server.py): a device enrols
# with a one-time code and pushes heartbeats; the brain never reaches it. These run the real app
# server on 127.0.0.1 and a device in a second HOME. No real keychain, launchd or hardware id
# (test_helper: the token goes to a 0600 file, the test runs the agent itself). Needs python3, curl.

load test_helper

setup() {
  common_setup
  PY="$(type -P python3 || true)"
  [[ -n "$PY" ]] || skip "python3 not available"
  link_tool "$PY" python3
  export CHARTROOM="$REPO_ROOT/bin/chartroom"
  export CHARTROOM_TAILSCALE=none CHARTROOM_MACHINE_NAME=studio CHARTROOM_NODES=none
  printf 'CHARTROOM_APP_USER=owner@example.com\n' >"$CHARTROOM_CONFIG"
  cr init >/dev/null; cr homes add acme "$CHARTROOM_HOME" >/dev/null
  FLEET="$BATS_TEST_TMPDIR/fleet" # beside the config file, as the app server's own state
  DEV="$BATS_TEST_TMPDIR/dev"; mkdir -p "$DEV/home"; : >"$DEV/config"
}

teardown() { cr app stop >/dev/null 2>&1 || true; }

start() {
  run cr app serve --daemon --port 0
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  URL="http://127.0.0.1:$PORT"
}
# the device: its own HOME, config and state; same chartroom
dev() { HOME="$DEV/home" XDG_STATE_HOME="$DEV/state" CHARTROOM_CONFIG="$DEV/config" CHARTROOM_NODE_CONFIG="$DEV/node" \
  CHARTROOM_HOME="$DEV/nohome" CHARTROOM_MACHINE_NAME=m3 "$CHARTROOM" "$@" 3>&-; }
code_of() { sed -n 's/^enrolment code[^:]*: \([A-Z0-9]\{5\}-[A-Z0-9]\{5\}\) .*/\1/p' <<<"$1"; }
new_code() { local out; out="$(cr node add "$@")"; code_of "$out"; }
dev_id() { sed -n 's/^CHARTROOM_DEVICE_ID=//p' "$DEV/home/.config/chartroom/device"; }
token() { cat "$DEV/state/chartroom/device/token"; }
beat() { # <token> <id> [extra json] -> HTTP code; body in $BATS_TEST_TMPDIR/body
  local x="${3:-}"; [[ -n "$x" ]] || x='{}'
  curl -s -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    ${1:+-H "Authorization: Bearer $1"} -d "$(jq -cn --arg id "$2" --argjson x "$x" '{id: $id, protocol: 1, probe: ""} + $x')" "$URL/api/v1/device/heartbeat"
}
sha() { if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
joined() { # enrols the device as m3 and answers one heartbeat
  start
  run dev device join "$URL" "$(new_code --name m3)"
  echo "$output"
  [ "$status" -eq 0 ]
  dev device run --once
}

@test "join: a code works once; used, wrong or expired it is refused; the device then reports" {
  start
  c="$(new_code --name m3)"
  [[ "$c" =~ ^[A-Z0-9]{5}-[A-Z0-9]{5}$ ]]
  # the code itself is never stored, only its hash
  ! grep -rq "${c//-/}" "$FLEET"
  run dev device join "$URL" "$c"
  [ "$status" -eq 0 ]
  [[ "$output" == *"joined $URL as m3 (n-"* ]]
  [ -n "$(find "$DEV/state/chartroom/device/token" -perm 600)" ]
  # the brain keeps the token's hash only
  id="$(dev_id)"
  [ "$(jq -r .token_sha256 "$FLEET/devices/$id.json")" = "$(printf '%s' "$(token)" | sha)" ]
  ! grep -rq "$(token)" "$FLEET"
  run dev device join "$URL" "$c"
  [ "$status" -ne 0 ]
  [[ "$output" == *"used already, expired, or never issued"* ]]
  run dev device join "$URL" "AAAAA-BBBBB"
  [ "$status" -ne 0 ]
  c="$(new_code)"; f="$(ls "$FLEET"/codes/*.json)"
  jq '.expires = 1' "$f" >"$f.x" && mv "$f.x" "$f"
  run curl -s -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg c "$c" '{code: $c, id: "n-0123456789ab", host: "other", hw_uuid: "hw-2", protocol: 1}')" "$URL/api/v1/device/join"
  [[ "$output" == *"expired"* ]]
  run dev device run --once
  [ "$status" -eq 0 ]
  run cr nodes --json
  jq -e '.nodes[] | select(.machine == "m3") | .via == "heartbeat" and .contact == "ok" and .device.status == "online" and (.cores != null)' <<<"$output"
  run dev device status
  [[ "$output" == *"joined $URL as m3"* ]]
  [[ "$output" == *"last: ok at"* ]]
  # the code can come on stdin instead, off the command line
  run dev device join "$URL" - <<<"$(new_code --replace m3)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"as m3 (n-"* ]]
}

@test "token scope: device routes open by the token alone; it opens nothing else" {
  joined
  id="$(dev_id)"; t="$(token)"
  [ "$(beat "$t" "$id")" = 200 ]
  jq -e '.ok and .name == "m3" and .rotate == false' "$BATS_TEST_TMPDIR/body"
  [ "$(beat "" "$id")" = 401 ]
  [ "$(beat "$(printf '%064d' 0)" "$id")" = 401 ]
  # another device's id with this token
  [ "$(beat "$t" "n-0123456789ab")" = 401 ]
  # the owner's Tailscale login does not stand in for a token on a device route
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Tailscale-User-Login: owner@example.com' \
    -d "{\"id\":\"$id\",\"protocol\":1}" "$URL/api/v1/device/heartbeat"
  [ "$output" = 401 ]
  # and a device token does not open the app
  run curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $t" "$URL/api/v1/state"
  [ "$output" = 403 ]
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' -H "Authorization: Bearer $t" \
    -d '{"text":"hi"}' "$URL/api/v1/homes/acme/tell"
  [ "$output" = 403 ]
  # a device on another protocol is told to update
  [ "$(beat "$t" "$id" '{"protocol": 2}')" = 409 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$URL/api/v1/device/nope")" = 404 ]
}

@test "revoke: the next heartbeat gets 401, the agent stops, nothing on the device is touched" {
  joined
  before="$(cat "$DEV/node")"
  run cr node revoke m3
  [ "$status" -eq 0 ]
  [[ "$output" == *"revoked m3"* ]]
  run dev device run --once
  [ "$status" -eq 1 ]
  jq -e '.state == "revoked"' "$DEV/state/chartroom/device/agent.json"
  grep -q 'the brain revoked this device' "$DEV/state/chartroom/device/agent.log"
  [ "$(cat "$DEV/node")" = "$before" ]
  [ -f "$DEV/state/chartroom/device/token" ]
  run cr nodes --json
  jq -e '.nodes[] | select(.machine == "m3") | .contact == "revoked"' <<<"$output"
  # the agent's own exit is 0 under launchd, so KeepAlive (SuccessfulExit=false) leaves it stopped
  grep -q 'return $(( once ? 1 : 0 ))' "$REPO_ROOT/lib/device.sh"
}

@test "rotate: a new token on the next heartbeat; the old one keeps working 10 minutes" {
  joined
  old="$(token)"; id="$(dev_id)"
  cr node rotate m3
  [ "$(beat "$old" "$id")" = 200 ]
  jq -e '.rotate == true' "$BATS_TEST_TMPDIR/body"
  dev device run --once
  new="$(token)"
  [ "$new" != "$old" ]
  [[ "$new" =~ ^[0-9a-f]{64}$ ]]
  jq -e '.rotate == false' "$FLEET/devices/$id.json"
  [ "$(beat "$new" "$id")" = 200 ]
  [ "$(beat "$old" "$id")" = 200 ]
  # once its 10 minutes are up, the old one is refused
  jq '.prev_until = 1' "$FLEET/devices/$id.json" >"$BATS_TEST_TMPDIR/d" && mv "$BATS_TEST_TMPDIR/d" "$FLEET/devices/$id.json"
  [ "$(beat "$old" "$id")" = 401 ]
  [ "$(beat "$new" "$id")" = 200 ]
}

@test "status: online, stale, lost; the brain's own downtime is never held against a device" {
  joined
  id="$(dev_id)"; s="$FLEET/devices/$id.seen.json"; now="$(date +%s)"; read -r pid _ <"$FLEET/endpoint"
  st() { cr fleet devices --json | jq -r '.[0].status'; }
  [ "$(st)" = online ]
  seen() { jq --argjson t "$1" '.last_seen = $t' "$s" >"$s.x" && mv "$s.x" "$s"; }
  up() { echo "$pid $1" >"$FLEET/endpoint"; }
  up $((now - 7200))
  seen $((now - 60)); [ "$(st)" = stale ]
  seen $((now - 700)); [ "$(st)" = lost ]
  # the endpoint came back a minute ago after 40 minutes down: the device last spoke before that
  seen $((now - 2460)); up $((now - 60)); [ "$(st)" = stale ]
  # ... and has not spoken in the 11 minutes the endpoint has been up since
  up $((now - 660)); [ "$(st)" = lost ]
  # the endpoint is not running: nothing can be heard, so nothing is called lost
  echo "999999 $now" >"$FLEET/endpoint"; [ "$(st)" = unknown ]
  run cr nodes --json
  jq -e '.nodes[] | select(.machine == "m3") | .contact == "unknown"' <<<"$output"
  run cr doctor
  [[ "$output" == *"fleet:    1 device(s): m3 unknown"* ]]
  [[ "$output" == *"the app server is not running"* ]]
  CHARTROOM_NODE_LOST_MINUTES=0 run cr fleet devices --json
  [ "$status" -ne 0 ]
}

@test "enrolment: one entry per machine; a second is refused naming the first, unless it replaces it" {
  joined
  id="$(dev_id)"
  # the same machine again (a new node id, the same hardware)
  sed -i.bak '/CHARTROOM_NODE_ID/d' "$DEV/node"
  run dev device join "$URL" "$(new_code --name m3b)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already enrolled as m3 ($id)"* ]]
  [[ "$output" == *"node add --replace $id"* ]]
  run dev device join "$URL" "$(new_code --replace m3)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"as m3 (n-"* ]]
  [ "$(dev_id)" != "$id" ]
  jq -e --arg n "$(dev_id)" '.revoked != null and .replaced_by == $n' "$FLEET/devices/$id.json"
  # a name is one device's
  run cr node add --name m3
  [ "$status" -ne 0 ]
  [[ "$output" == *"already called 'm3'"* ]]
  run cr node add --name 'no spaces'
  [ "$status" -ne 0 ]
}

@test "rename keeps the old name as an alias, and an ssh row of either name is not probed too" {
  use_fake ssh
  joined
  run cr node rename m3 m3-mini
  [ "$status" -eq 0 ]
  dev device run --once
  grep -q '^CHARTROOM_DEVICE_NAME=m3-mini$' "$DEV/home/.config/chartroom/device"
  export CHARTROOM_NODES="m3 other" FAKE_SSH_DIR="$BATS_TEST_TMPDIR/ssh"; mkdir -p "$FAKE_SSH_DIR"
  run cr nodes --json
  jq -e '[.nodes[].machine] == ["studio", "other", "m3-mini"]' <<<"$output"
  ! grep -q '^m3 ' "$FAKE_SSH_DIR/calls.log"
  run cr nodes --ssh --json
  jq -e '[.nodes[].machine] == ["studio", "m3", "other"] and all(.nodes[]; .via != "heartbeat")' <<<"$output"
  run cr nodes
  [[ "$output" == *"m3-mini"*"online "* ]]
}

@test "app fleet: a device's row comes from its heartbeat, with its status and age" {
  joined
  run cr app fleet --json
  [ "$status" -eq 0 ]
  jq -e '.machines[] | select(.name == "m3") | .source == "heartbeat" and .device.status == "online" and .state != "down" and (.load | length) == 3' <<<"$output"
  id="$(dev_id)"; s="$FLEET/devices/$id.seen.json"
  jq '.last_seen -= 120' "$s" >"$s.x" && mv "$s.x" "$s"
  run cr app fleet --json
  jq -e '.machines[] | select(.name == "m3") | .state == "degraded" and (.failing[0] | startswith("no heartbeat for 1"))' <<<"$output"
}

@test "joins: ten wrong codes in a minute, then the route refuses for the rest of it" {
  start
  for i in $(seq 1 10); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -d '{"code":"AAAAABBBBB","id":"n-0123456789ab","host":"x","hw_uuid":"h","protocol":1}' "$URL/api/v1/device/join")" = 401 ]
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg c "$(new_code)" '{code: $c, id: "n-0123456789ab", host: "x", hw_uuid: "h", protocol: 1}')" "$URL/api/v1/device/join")" = 429 ]
}

@test "node init: a node id minted once and kept across --force; device join adds one to an old node file" {
  export CHARTROOM_NODE_CONFIG="$BATS_TEST_TMPDIR/n/node"
  cr node init >/dev/null
  id="$(sed -n 's/^CHARTROOM_NODE_ID=//p' "$CHARTROOM_NODE_CONFIG")"
  [[ "$id" =~ ^n-[0-9a-f]{12}$ ]]
  cr node init --force --max-workers 3 >/dev/null
  [ "$(sed -n 's/^CHARTROOM_NODE_ID=//p' "$CHARTROOM_NODE_CONFIG")" = "$id" ]
  grep -q '^CHARTROOM_NODE_MAX_WORKERS=3$' "$CHARTROOM_NODE_CONFIG"
  # a node file from before ids: join appends one and changes nothing else
  start
  printf 'CHARTROOM_NODE_MAX_WORKERS=6\nCHARTROOM_NODE_ACCEPT=on\n' >"$DEV/node"
  dev device join "$URL" "$(new_code)" >/dev/null
  [ "$(head -2 "$DEV/node")" = "$(printf 'CHARTROOM_NODE_MAX_WORKERS=6\nCHARTROOM_NODE_ACCEPT=on')" ]
  grep -q "^CHARTROOM_NODE_ID=$(dev_id)\$" "$DEV/node"
}

@test "device join refuses a brain it cannot reach or a URL that is not https; leave forgets the token" {
  run dev device join "http://example.com" "AAAAA-BBBBB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://"* ]]
  run dev device join "http://127.0.0.1:9" "AAAAA-BBBBB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot reach the brain"* ]]
  joined
  run dev device leave
  [ "$status" -eq 0 ]
  [[ "$output" == *"chartroom node revoke m3"* ]]
  [ ! -e "$DEV/state/chartroom/device/token" ]
  [ ! -e "$DEV/home/.config/chartroom/device" ]
  run dev device status
  [[ "$output" == *"not joined"* ]]
}

@test "keychain: the token goes in through stdin, is read back, survives a rotate, and leave deletes it" {
  use_fake security
  export CHARTROOM_KEYCHAIN="$BIN/security" FAKE_KEYCHAIN_DIR="$BATS_TEST_TMPDIR/kc"
  joined
  id="$(dev_id)"
  grep -q '^CHARTROOM_DEVICE_TOKEN_STORE=keychain$' "$DEV/home/.config/chartroom/device"
  t="$(cat "$FAKE_KEYCHAIN_DIR/chartroom-device/$id")"
  [[ "$t" =~ ^[0-9a-f]{64}$ ]]
  [ ! -e "$DEV/state/chartroom/device/token" ]
  ! grep -q "$t" "$FAKE_LOG" "$DEV/state/chartroom/device/agent.log"
  cr node rotate m3
  dev device run --once
  [ "$(cat "$FAKE_KEYCHAIN_DIR/chartroom-device/$id")" != "$t" ]
  [ ! -e "$FAKE_KEYCHAIN_DIR/chartroom-device/$id.next" ]
  dev device run --once
  run dev device leave
  [ "$status" -eq 0 ]
  [[ "$output" == *"left: the agent is stopped"* ]]
  [ ! -e "$FAKE_KEYCHAIN_DIR/chartroom-device/$id" ]
}

@test "keychain: one that refuses (an ssh session's) leaves the token in a 0600 file, and says so" {
  use_fake security
  export CHARTROOM_KEYCHAIN="$BIN/security" FAKE_KEYCHAIN_DIR="$BATS_TEST_TMPDIR/kc"
  mkdir -p "$FAKE_KEYCHAIN_DIR"; touch "$FAKE_KEYCHAIN_DIR/refuse"
  joined
  grep -q '^CHARTROOM_DEVICE_TOKEN_STORE=file$' "$DEV/home/.config/chartroom/device"
  [ -n "$(find "$DEV/state/chartroom/device/token" -perm 600)" ]
  grep -q 'the keychain refused the token (security: SecKeychainItemCreateFromContent: User interaction is not allowed.)' "$DEV/state/chartroom/device/agent.log"
}
