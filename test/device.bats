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
  # three machines whose use the tests set: this one, and the two devices
  use_fake sysctl vm_stat
  fake_use "$BATS_TEST_TMPDIR/fake-brain" "$XDG_STATE_HOME" 20 30; export FAKE_NODE_DIR="$BATS_TEST_TMPDIR/fake-brain"
  fake_use "$BATS_TEST_TMPDIR/fake-dev" "$DEV/state" 5 10
  fake_use "$BATS_TEST_TMPDIR/fake-dev2" "$BATS_TEST_TMPDIR/dev2/state" 5 10
  DEV2="$BATS_TEST_TMPDIR/dev2"; mkdir -p "$DEV2/home"; : >"$DEV2/config"
}

# A process and everything under it (an agent, its long-poll loop, the launchd stand-in's loop):
# nothing a test starts may outlive it (another suite's sweep would count it).
kill_tree_of() {
  local c
  for c in $(ps -A -o pid=,ppid= | awk -v p="$1" '$2 == p {print $1}'); do kill_tree_of "$c"; done
  kill "$1" 2>/dev/null || true
}
teardown() {
  local p
  for p in ${AGENTS:-} \
    "$(jq -r '.pid // empty' "$DEV/state/chartroom/device/agent.json" 2>/dev/null || true)" \
    "$(jq -r '.pid // empty' "$DEV2/state/chartroom/device/agent.json" 2>/dev/null || true)"; do
    [[ -z "$p" ]] || kill_tree_of "$p"
  done
  cr app stop >/dev/null 2>&1 || true
}

start() {
  run cr app serve --daemon --port 0
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  URL="http://127.0.0.1:$PORT"
}
# the device: its own HOME, config and state; same chartroom
dev() { HOME="$DEV/home" XDG_STATE_HOME="$DEV/state" CHARTROOM_CONFIG="$DEV/config" CHARTROOM_NODE_CONFIG="$DEV/node" \
  CHARTROOM_HOME="$DEV/nohome" CHARTROOM_MACHINE_NAME=m3 FAKE_NODE_DIR="$BATS_TEST_TMPDIR/fake-dev" "${DEVBIN:-$CHARTROOM}" "$@" 3>&-; }
# a second device (its own hardware)
dev2() { HOME="$DEV2/home" XDG_STATE_HOME="$DEV2/state" CHARTROOM_CONFIG="$DEV2/config" CHARTROOM_NODE_CONFIG="$DEV2/node" \
  CHARTROOM_HOME="$DEV2/nohome" CHARTROOM_MACHINE_NAME=m5 FAKE_NODE_DIR="$BATS_TEST_TMPDIR/fake-dev2" CHARTROOM_HW_UUID=test-hw-0002 "$CHARTROOM" "$@" 3>&-; }
agent() { # the device's agent in the background, a heartbeat a second (as launchd would run it)
  ( CHARTROOM_DEVICE_HEARTBEAT=1 dev device run >/dev/null 2>&1 ) 3>&- &
  AGENTS="${AGENTS:-} $!"
}
until_true() { local i; for i in $(seq 1 "${2:-120}"); do eval "$1" && return 0; sleep 0.25; done; return 1; }
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
  cr node init --force --cpu 33 >/dev/null
  [ "$(sed -n 's/^CHARTROOM_NODE_ID=//p' "$CHARTROOM_NODE_CONFIG")" = "$id" ]
  grep -q '^CHARTROOM_NODE_CPU_BUDGET=33$' "$CHARTROOM_NODE_CONFIG"
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

@test "commands: a round trip by long-poll; expired and unknown ones; only a device's own to answer" {
  joined
  agent
  run cr node ping m3
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "pong from m3 at "* ]]
  id="$(dev_id)"; q="$FLEET/queue/$id"
  # an unknown command is answered, not run
  c="c-$(date +%s)000-aaaaaa"; echo '{"type":"frobnicate","payload":{}}' >"$q/$c.json"
  until_true '[ -f "$FLEET/results/$c.json" ]'
  jq -e '.rc == 2 and (.err | contains("does not know the command"))' "$FLEET/results/$c.json"
  # a command whose ttl ran out before the device took it is answered "expired" and never runs
  c="c-$(date +%s)001-bbbbbb"; echo '{"type":"ping","payload":{},"expires":1}' >"$q/$c.json"
  until_true '[ -f "$FLEET/results/$c.json" ]'
  jq -e '.rc == 124 and (.err | contains("expired"))' "$FLEET/results/$c.json"
  ! grep -q "command ping ($c)" "$DEV/state/chartroom/device/agent.log"
  # another device cannot answer this device's command
  dev2 device join "$URL" "$(new_code --name m5)" >/dev/null
  t2="$(cat "$DEV2/state/chartroom/device/token")"; id2="$(sed -n 's/^CHARTROOM_DEVICE_ID=//p' "$DEV2/home/.config/chartroom/device")"
  c="c-$(date +%s)002-cccccc"; mkdir -p "$BATS_TEST_TMPDIR/hold"; echo '{"type":"ping","payload":{}}' >"$BATS_TEST_TMPDIR/hold/$c.json"
  mv "$BATS_TEST_TMPDIR/hold/$c.json" "$q/"
  run curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $t2" \
    -d "{\"id\":\"$id2\",\"protocol\":1,\"cmd\":\"$c\",\"rc\":0,\"out\":\"forged\"}" "$URL/api/v1/device/result"
  [ "$output" = 404 ]
  until_true '[ -f "$FLEET/results/$c.json" ]'
  ! grep -q forged "$FLEET/results/$c.json"
  # and its long-poll never hands it another device's commands
  run curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $t2" -d "{\"id\":\"$id2\",\"protocol\":1,\"wait\":0}" "$URL/api/v1/device/commands"
  [ "$(jq '.commands | length' <<<"$output")" = 0 ]
}

@test "node update: a device fast-forwards to the brain's commit over the connection and restarts onto it" {
  type -P rsync >/dev/null || skip "rsync not available"
  T="$BATS_TEST_TMPDIR"
  rsync -a --exclude .git "$REPO_ROOT/" "$T/src/"
  git -C "$T/src" init -q; git -C "$T/src" add -A; git -C "$T/src" commit -qm c1
  git clone -q --bare "$T/src" "$T/origin.git"
  git clone -q "$T/origin.git" "$T/devroot"; git clone -q "$T/origin.git" "$T/brainroot"
  git -C "$T/brainroot" commit -q --allow-empty -m c2; git -C "$T/brainroot" push -q origin HEAD:main
  export CHARTROOM="$T/brainroot/bin/chartroom" DEVBIN="$T/devroot/bin/chartroom"
  joined
  # launchd's part: an agent that exits 75 is started again
  ( while :; do rc=0; CHARTROOM_DEVICE_HEARTBEAT=1 dev device run >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 75 ] || break; done ) 3>&- &
  AGENTS="$!"
  c1="$(git -C "$T/devroot" rev-parse HEAD)"; c2="$(git -C "$T/brainroot" rev-parse HEAD)"
  until_true '[ "$(cr fleet devices --json | jq -r ".[0].rev")" = "$c1" ]'
  run cr node update m3
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3: updated ${c1:0:7} -> ${c2:0:7}"* ]]
  [[ "$output" == *"m3: its agent restarted and reports ${c2:0:7}"* ]]
  [ "$(git -C "$T/devroot" rev-parse HEAD)" = "$c2" ]
  grep -q "restarting onto chartroom ${c2:0:7}" "$DEV/state/chartroom/device/agent.log"
  run cr node update m3
  [[ "$output" == "m3: already at ${c2:0:7}" ]]
  # a commit the device's origin does not have is refused, and the device stays where it is
  git -C "$T/brainroot" commit -q --allow-empty -m c3
  run cr node update m3
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not on this machine's origin/main"* ]]
  [ "$(git -C "$T/devroot" rev-parse HEAD)" = "$c2" ]
}

# A pinned task end to end, the device's worker the stub agent on the command runner (the suite
# has no real hc): the device's checkout is a clone of the brain's at another path.
pinned_setup() {
  export CHARTROOM_NODE_BACKENDS='hc:claude|hc:codex|command' CHARTROOM_COMMAND="$STUB {id}" CHARTROOM_PROJECT_ROOTS="$BATS_TEST_TMPDIR"
  git clone -q "$PROJECT" "$BATS_TEST_TMPDIR/devproj"
  export CHARTROOM_GUEST_PROJECT_MAP="$PROJECT:$BATS_TEST_TMPDIR/devproj"
  joined
  agent
  until_true 'cr fleet devices --json | jq -e ".[0].caps | index(\"dispatch\")" >/dev/null'
  ID="$(new_task --backend command --node m3 2>/dev/null)"
  jq -e '.node != null and .backend == "node:command" and .node_backend == "command"' "$CHARTROOM_HOME/tasks/$ID/meta.json"
}
ev_has() { grep -q -- "$1" "$CHARTROOM_HOME/tasks/$ID/events.log"; }

@test "pinned: dispatch runs it on the device; its events come back; a steer reaches it; close brings the record home" {
  export STUB_MODE=decision
  pinned_setup
  run cr dispatch "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the worker runs on m3 (attempt 1)"* ]]
  # (no worktree here: it is made on the device)
  [ -z "$(jq -r '.worktree // ""' "$CHARTROOM_HOME/tasks/$ID/meta.json")" ]
  [ -n "$(jq -r '.worktree // ""' "$DEV/state/chartroom/node/guests/acme/tasks/$ID/meta.json")" ]
  until_true 'ev_has " decision: pick A or B"'
  ev_has " note: dispatched via command"
  # the brain reads its liveness from the device's heartbeat, and shows where it runs
  until_true '[ "$(cr status --json | jq -r --arg i "$ID" ".[] | select(.id == \$i) | .live")" != unknown ]'
  cr status --json | jq -c --arg i "$ID" '.[] | select(.id == $i) | {machine, state, live}'
  cr status --json | jq -e --arg i "$ID" '.[] | select(.id == $i) | (.machine == "m3") and (.state | test("decision|needs|blocked"))'
  run cr steer "$ID" "A, please"
  echo "$output"
  [ "$status" -eq 0 ]
  until_true 'ev_has " done: finished after steer: A, please"'
  ev_has " steered: A, please"
  until_true '[ -f "$CHARTROOM_HOME/tasks/$ID/report.md" ]'
  grep -q 'steer: A, please' "$CHARTROOM_HOME/tasks/$ID/report.md"
  # each line once, however often it was pushed
  [ "$(grep -c ' done: finished after steer' "$CHARTROOM_HOME/tasks/$ID/events.log")" = 1 ]
  run cr peek "$ID"
  [[ "$output" == *"== on m3: online"* ]]
  # the brain's own loops take a remote task in their stride
  run cr watch --once --timeout 3
  echo "watch: $status $output"
  [[ "$status" -eq 0 || "$status" -eq 124 ]]
  [[ "$output" != *"command not found"* ]]
  run cr sweep --json
  [ "$status" -eq 0 ]
  run cr board
  [ "$status" -eq 0 ]
  run cr close "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3: "*"closed $ID"* ]]
  [[ "$output" == *"closed $ID" ]]
  [ -n "$(jq -r '.closed // ""' "$CHARTROOM_HOME/tasks/$ID/meta.json")" ]
  [ ! -e "$FLEET/tasks/acme/$ID.json" ]
  [ -n "$(jq -r '.closed // ""' "$DEV/state/chartroom/node/guests/acme/tasks/$ID/meta.json")" ]
}

@test "pinned close: the branch comes home by bundle first, and the device's copy goes only once the brain holds it" {
  export STUB_MODE=done STUB_COMMIT=1
  pinned_setup
  cr dispatch "$ID" >/dev/null
  until_true 'ev_has " done: stub finished"'
  b="$(jq -r .branch "$CHARTROOM_HOME/tasks/$ID/meta.json")"
  tip="$(git -C "$BATS_TEST_TMPDIR/devproj" rev-parse "refs/heads/$b")"
  ! git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$b"
  run cr close "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch $b is on this machine at ${tip:0:12} (from m3)"* ]]
  # (here the device's origin is the brain's checkout, so its own landed rule already finds it
  # there; on a real device its origin is the forge and the copy goes because the brain holds it)
  [[ "$output" == *"m3: branch $b deleted"* ]]
  [ "$(git -C "$PROJECT" rev-parse "refs/heads/$b")" = "$tip" ]
  ! git -C "$BATS_TEST_TMPDIR/devproj" rev-parse --verify --quiet "refs/heads/$b"
  # here it is unlanded work, so it is kept
  [[ "$output" == *"branch $b kept"* ]]
  ev_has " note: branch $b fetched from m3 at ${tip:0:12}"
}

@test "pinned: a push for a task not this device's, or a line only the brain writes, is refused" {
  export STUB_MODE=silent
  pinned_setup
  cr dispatch "$ID" >/dev/null
  t2() { curl -s -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $1" -d "$2" "$URL/api/v1/device/$3"; }
  id="$(dev_id)"; t="$(token)"
  dev2 device join "$URL" "$(new_code --name m5)" >/dev/null
  tok2="$(cat "$DEV2/state/chartroom/device/token")"; id2="$(sed -n 's/^CHARTROOM_DEVICE_ID=//p' "$DEV2/home/.config/chartroom/device")"
  body() { jq -cn --arg d "$1" --arg t "$ID" --argjson a "$2" --argjson l "$3" '{id: $d, protocol: 1, home: "acme", task: $t, attempt: $a, offset: 9999, lines: $l}'; }
  # another device, and this device at another attempt
  [ "$(t2 "$tok2" "$(body "$id2" 1 '[]')" events)" = 403 ]
  [ "$(t2 "$t" "$(body "$id" 2 '[]')" events)" = 403 ]
  # a file other than report.md / plan.md
  [ "$(t2 "$t" "$(jq -cn --arg d "$id" --arg t "$ID" '{id: $d, protocol: 1, home: "acme", task: $t, attempt: 1, name: "meta.json", content: "{}"}')" files)" = 400 ]
  # an accept or a close in a pushed line is dropped; a worker's line is kept
  off="$(jq -r '.node_off' "$CHARTROOM_HOME/tasks/$ID/meta.json")"
  l="$(jq -cn '["2026-01-01T00:00:00Z note: accepted", "2026-01-01T00:00:01Z note: closed", "2026-01-01T00:00:02Z progress: real line"]')"
  [ "$(t2 "$t" "$(jq -cn --arg d "$id" --arg t "$ID" --argjson o "$off" --argjson l "$l" '{id: $d, protocol: 1, home: "acme", task: $t, attempt: 1, offset: $o, lines: $l}')" events)" = 200 ]
  ev_has "progress: real line"
  ! ev_has "2026-01-01T00:00:00Z note: accepted"
  ! ev_has "2026-01-01T00:00:01Z note: closed"
  # a card's answer comes only from the brain: a pushed answer is not a card
  [ "$(t2 "$t" "$(jq -cn --arg d "$id" --arg t "$ID" '{id: $d, protocol: 1, home: "acme", task: $t, attempt: 1, cards: {"p-1234.answer": {"answer": "once"}, "../x": {}}}')" permits)" = 200 ]
  [ -z "$(ls "$CHARTROOM_HOME/permits/$ID" 2>/dev/null | grep -v '^grants.json$' || true)" ]
}

@test "pinned: a permission card on the device is the brain's to answer, and the answer goes back to the worker waiting there" {
  export STUB_MODE=silent
  pinned_setup
  cr dispatch "$ID" >/dev/null
  g="$DEV/state/chartroom/node/guests/acme/permits/$ID"; mkdir -p "$g"
  now="$(date +%s)"
  # as the device's PermissionRequest hook writes one (lib/permit.sh permit_card)
  jq -cn --arg t "$ID" --argjson now "$now" '{id: "p-abcd", task: $t, created: ($now | todate), created_epoch: $now, expires_epoch: ($now + 900),
    event: "permission", blocking: true, tool: "Bash", input: {command: "make deploy"}, sig: "0123456789ab", desc: "run make deploy",
    cwd: "", why: "", rule: "ask", reason: "a deploy", pattern: "Bash(make deploy)"}' >"$g/p-abcd.json"
  until_true '[ -f "$CHARTROOM_HOME/permits/$ID/p-abcd.json" ]'
  # (as the commander would: a process of its own, not one under the worker running this suite)
  as_commander() {
    local o="$BATS_TEST_TMPDIR/commander.$RANDOM" i
    ( ( "$CHARTROOM" "$@" >"$o.out" 2>&1; echo $? >"$o.rc" ) 3>&- & )
    for i in $(seq 1 600); do [[ -f "$o.rc" ]] && break; sleep 0.1; done
    cat "$o.out"; return "$(cat "$o.rc" 2>/dev/null || echo 1)"
  }
  run as_commander permit answer p-abcd once --note "go ahead"
  echo "$output"
  [ "$status" -eq 0 ]
  until_true '[ -f "$g/p-abcd.answer.json" ]' 40
  jq -e '.answer == "once" and .note == "go ahead"' "$g/p-abcd.answer.json"
  # a card of the same id under another task here, long answered, does not stand in for the device's
  mkdir -p "$CHARTROOM_HOME/permits/an-older-task"
  cp "$g/p-abcd.json" "$CHARTROOM_HOME/permits/an-older-task/p-dcba.json"
  printf '{"answer":"once","by":"commander","at":"2026-01-01T00:00:00Z"}\n' >"$CHARTROOM_HOME/permits/an-older-task/p-dcba.answer.json"
  jq -c '.id = "p-dcba"' "$g/p-abcd.json" >"$g/p-dcba.json"
  until_true '[ -f "$CHARTROOM_HOME/permits/$ID/p-dcba.json" ]'
  run as_commander permit answer p-dcba deny
  echo "$output"
  [ "$status" -eq 0 ]
  until_true '[ -f "$g/p-dcba.answer.json" ]' 40
  jq -e '.answer == "deny"' "$g/p-dcba.answer.json"
  # and the device never sends an answer back as if it were a card
  sleep 3
  [ ! -e "$CHARTROOM_HOME/permits/$ID/p-abcd.answer.json.json" ]
}

@test "pinned: a dispatch the device refuses is a failed event; the task still closes; a revoked device's task closes here" {
  export STUB_MODE=silent
  pinned_setup
  # a project outside the device's roots (read from its node file at each dispatch)
  sed -i.bak "s|^CHARTROOM_NODE_PROJECT_ROOTS=.*|CHARTROOM_NODE_PROJECT_ROOTS=$BATS_TEST_TMPDIR/elsewhere|" "$DEV/node"; mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run cr dispatch "$ID"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not start a worker"* || "$output" == *"failed"* ]]
  ev_has " failed: the dispatch on m3 did not start a worker: "
  run cr close "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3 has nothing of $ID"* ]]
  [[ "$(grep ' failed: ' "$CHARTROOM_HOME/tasks/$ID/events.log")" == *"outside this node's project roots"* ]]
  # a task on a device that is then revoked
  mv "$DEV/node.bak" "$DEV/node"
  id2="$(new_task --backend command --node m3 2>/dev/null)"
  cr dispatch "$id2" >/dev/null
  cr node revoke m3 >/dev/null
  run cr close "$id2"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3 is revoked: the record closes here"* ]]
}

# A project with a remote both machines have a checkout of (its URL stands for a local bare).
placed_setup() { # [agent heartbeat seconds]
  export CHARTROOM_NODE_BACKENDS='hc:claude|hc:codex|command' CHARTROOM_COMMAND="$STUB {id}" CHARTROOM_PROJECT_ROOTS="$BATS_TEST_TMPDIR"
  git clone -q --bare "$PROJECT" "$BATS_TEST_TMPDIR/origin.git"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$BATS_TEST_TMPDIR/origin.git.insteadOf" GIT_CONFIG_VALUE_0=https://git.example/acme/proj
  git -C "$PROJECT" remote add origin https://git.example/acme/proj; git -C "$PROJECT" fetch -q origin; git -C "$PROJECT" remote set-head origin main
  git clone -q https://git.example/acme/proj "$BATS_TEST_TMPDIR/devproj"
  export CHARTROOM_GUEST_PROJECT_MAP="$PROJECT:$BATS_TEST_TMPDIR/devproj"
  cr node init --cpu 80 --mem 75 --battery allow --project-roots "$BATS_TEST_TMPDIR" >/dev/null
  joined
  ( CHARTROOM_DEVICE_HEARTBEAT="${1:-1}" dev device run >/dev/null 2>&1 ) 3>&- &
  AGENTS="${AGENTS:-} $!"
  until_true 'cr fleet devices --json | jq -e ".[0].caps | index(\"place\")" >/dev/null'
  # (the agent's own first heartbeat, after the one join made)
  until_true '[ "$(grep -c "heartbeat ok" "$DEV/state/chartroom/device/agent.log")" -ge 2 ]'
}

@test "placed: a ship task nobody pinned runs on the device with room, its files with it, and its branch comes home at close" {
  export STUB_COMMIT=1
  placed_setup
  mkdir -p "$CHARTROOM_HOME/drafts"; echo "the plan" >"$CHARTROOM_HOME/drafts/plan.md"
  ID="$(new_task --backend command 2>/dev/null)"
  perl -0pi -e "s|Please do the thing\\.|Read $CHARTROOM_HOME/drafts/plan.md first.|" "$CHARTROOM_HOME/tasks/$ID/brief.md"
  run cr dispatch "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"placed on m3: studio: cpu 20% of 80%, memory 30% of 75%; m3: cpu 5% of 50%"* || "$output" == *"placed on m3: studio: cpu 20% of 80%, memory 30% of 75%; m3: cpu 5% of 80%"* ]]
  [[ "$output" == *"the worker runs on m3 (attempt 1)"* ]]
  G="$DEV/state/chartroom/node/guests/acme/tasks/$ID"
  grep -q "Read $G/brain/drafts/plan.md first." "$G/brief.md"
  [ "$(cat "$G/brain/drafts/plan.md")" = "the plan" ]
  until_true 'ev_has " done: stub finished"'
  cr status --json | jq -e --arg i "$ID" '.[] | select(.id == $i) | .machine == "m3"'
  # its branch is read there before it comes home, read-only
  run cr git "$ID" log --oneline -1
  echo "$output"
  [[ "$output" == *"feat: stub change"* ]]
  run cr git "$ID" commit -m x
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only"* ]]
  run cr close "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is on this machine at"*"(from m3)"* ]]
  git -C "$PROJECT" show "refs/heads/$(jq -r .branch "$CHARTROOM_HOME/tasks/$ID/meta.json"):stub.txt"
}

@test "placed: the device checks its own limits when it takes the work, with what it uses then, and the next node takes it" {
  export CHARTROOM_NODE_STALE_SECONDS=300
  placed_setup 200
  # it cannot read its own memory any more: it does not guess
  mv "$BATS_TEST_TMPDIR/fake-dev/vm_stat" "$BATS_TEST_TMPDIR/vm_stat.off"
  ID="$(new_task --backend command 2>/dev/null)"
  run cr dispatch "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"m3 did not take it: its CPU or memory use could not be read"* ]]
  mv "$BATS_TEST_TMPDIR/vm_stat.off" "$BATS_TEST_TMPDIR/fake-dev/vm_stat"
  # it has filled up since its last heartbeat
  fake_use "$BATS_TEST_TMPDIR/fake-dev" "$DEV/state" 97 10
  ID="$(new_task --backend command 2>/dev/null)"
  run cr dispatch "$ID"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"placed on m3"*"m3 did not take it: cpu 97% in use, its limit is"* ]]
  [ -z "$(jq -r '.node // ""' "$CHARTROOM_HOME/tasks/$ID/meta.json")" ]
  [ -d "$(jq -r .worktree "$CHARTROOM_HOME/tasks/$ID/meta.json")" ]
  [ ! -e "$DEV/state/chartroom/node/guests/acme/tasks/$ID" ]
  until_true 'ev_has " done: stub finished"'
  [ "$(grep -c ' done: stub finished' "$CHARTROOM_HOME/tasks/$ID/events.log")" = 1 ]
}

@test "node limits: a device takes its limits from the brain, in its own node file, and reports them; one away takes them when back" {
  joined; agent
  until_true 'cr fleet devices --json | jq -e ".[0].caps | index(\"limits\")" >/dev/null'
  before="$(grep -vE '_(CPU|MEM)_BUDGET=' "$DEV/node")"
  run cr node limits m3 85/65
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "m3: takes new work under cpu 85% and memory 65% in use" ]]
  grep -qx CHARTROOM_NODE_CPU_BUDGET=85 "$DEV/node"; grep -qx CHARTROOM_NODE_MEM_BUDGET=65 "$DEV/node"
  [ "$(grep -vE '_(CPU|MEM)_BUDGET=' "$DEV/node")" = "$before" ]
  until_true '[ "$(cr node limits | grep "^m3" | tr -s " ")" = "m3 5% 85% 10% 65% yes" ]'
  cr node limits m3 off; until_true 'cr node limits | grep "^m3" | grep -q "no: paused: not accepting"'; cr node limits m3 on
  run cr node limits m3 0/65
  [ "$status" -ne 0 ]
  for p in $AGENTS; do kill_tree_of "$p"; done; AGENTS=""
  until_true '[ "$(CHARTROOM_NODE_STALE_SECONDS=2 cr fleet devices --json | jq -r ".[0].status")" = stale ]'
  run env CHARTROOM_NODE_STALE_SECONDS=2 "$CHARTROOM" node limits m3 --cpu 70
  [[ "$output" == *"m3 is stale: its limits are set when it is back"* ]]
  agent
  until_true 'grep -qx CHARTROOM_NODE_CPU_BUDGET=70 "$DEV/node"'
  grep -qx CHARTROOM_NODE_MEM_BUDGET=65 "$DEV/node"
}
