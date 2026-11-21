#!/usr/bin/env bats
# The installable app and Web Push (slice 6): the service worker and the manifest at the root;
# push off unless the config turns it on; subscriptions checked like any write and kept 0600; a new
# Needs me item pushed once, encrypted, to a fake push service on this machine (test/js/push-sink.js,
# which decrypts it as a browser would), and nothing pushed for what was open at start.

load test_helper
load app_fixture

setup() {
  NODE="$(node -p process.execPath 2>/dev/null || true)"
  common_setup
  export CHARTROOM="$REPO_ROOT/bin/chartroom" CHARTROOM_TAILSCALE=none
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
}

teardown() {
  cr app stop >/dev/null 2>&1 || true
  [[ -n "${SINK:-}" ]] && kill "$SINK" 2>/dev/null || true
}

serve() {
  run cr app serve --daemon --port 0 --no-auth
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -e '[.homes[] | select(.snapshot)] | length == 2' >/dev/null && break; sleep 0.2; done
}
post() { # <path> <json> [curl args...]
  local p="$1" d="$2"; shift 2
  curl -s -o "$BATS_TEST_TMPDIR/out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$@" -d "$d" "http://127.0.0.1:$PORT$p"
}
pushinfo() { curl -s "http://127.0.0.1:$PORT/api/v1/push"; }

@test "installable: the service worker and the manifest are served at the root, with their types" {
  serve
  [ "$(curl -s -o /dev/null -w '%{content_type}' "http://127.0.0.1:$PORT/sw.js")" = "text/javascript; charset=utf-8" ]
  [ "$(curl -s -o /dev/null -w '%{content_type}' "http://127.0.0.1:$PORT/manifest.webmanifest")" = "application/manifest+json" ]
  [ "$(curl -s "http://127.0.0.1:$PORT/manifest.webmanifest" | jq -r '"\(.start_url) \(.scope) \(.display) \(.icons | length)"')" = "/ / standalone 3" ]
  [ "$(curl -s -o /dev/null -w '%{content_type}' "http://127.0.0.1:$PORT/app/icons/icon-512.png")" = "image/png" ]
  # never another file from the root
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/index.js")" = 404 ]
}

@test "push is off unless the config turns it on: no keys, and a subscription is refused" {
  serve
  [ "$(pushinfo | jq -r '"\(.available) \(.on)"')" = "false false" ]
  [[ "$(pushinfo | jq -r .reason)" == "off: CHARTROOM_APP_PUSH=on"* ]]
  [ "$(post /api/v1/push/subscribe '{"endpoint":"https://push.example.net/x","keys":{"p256dh":"x","auth":"y"}}' -H 'X-Chartroom-App: 1')" = 409 ]
  [ ! -e "$BATS_TEST_TMPDIR/app-push-keys.json" ]
}

@test "push on: a subscription is a write (the app's header, same origin), an https endpoint, kept 0600" {
  [[ -n "$NODE" ]] || skip "node not available"
  PATH="${NODE%/*}:$PATH"
  export CHARTROOM_APP_PUSH=on
  serve
  for _ in $(seq 1 50); do [ "$(pushinfo | jq -r .available)" = true ] && break; sleep 0.2; done
  [ "$(pushinfo | jq -r '.key | length')" -eq 87 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/app-push-keys.json" 2>/dev/null || stat -f %Lp "$BATS_TEST_TMPDIR/app-push-keys.json")" = 600 ]
  k='"keys":{"p256dh":"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4","auth":"BTBZMqHH6r4Tts7J_aSIgg"}'
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}")" = 403 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1' -H 'Sec-Fetch-Site: cross-site')" = 403 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"http://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1')" = 400 ]
  [ "$(post /api/v1/push/subscribe '{"endpoint":"https://push.example.net/a","keys":{"p256dh":"x","auth":"y"}}' -H 'X-Chartroom-App: 1')" = 400 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1')" = 200 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1')" = 200 ]
  [ "$(pushinfo | jq -r .devices)" -eq 1 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/app-push-subs.json" 2>/dev/null || stat -f %Lp "$BATS_TEST_TMPDIR/app-push-subs.json")" = 600 ]
  [ "$(post /api/v1/push/unsubscribe '{"endpoint":"https://push.example.net/a"}' -H 'X-Chartroom-App: 1')" = 200 ]
  [ "$(pushinfo | jq -r .devices)" -eq 0 ]
}

@test "push on: a new item is pushed once, encrypted, to the device; what was open at start is not" {
  [[ -n "$NODE" ]] || skip "node not available"
  PATH="${NODE%/*}:$PATH"
  export CHARTROOM_APP_PUSH=on CHARTROOM_APP_PUSH_ALLOW_HTTP=1
  "$NODE" "$REPO_ROOT/test/js/push-sink.js" "$BATS_TEST_TMPDIR/sub.json" "$BATS_TEST_TMPDIR/got" &
  SINK=$!
  for _ in $(seq 1 50); do [[ -s "$BATS_TEST_TMPDIR/sub.json" ]] && break; sleep 0.1; done
  serve
  for _ in $(seq 1 50); do [ "$(pushinfo | jq -r .available)" = true ] && break; sleep 0.2; done
  [ "$(post /api/v1/push/subscribe "$(cat "$BATS_TEST_TMPDIR/sub.json")" -H 'X-Chartroom-App: 1')" = 200 ]
  # a restart with the device still subscribed: what is open when it starts is only remembered
  cr app stop >/dev/null
  serve
  for _ in $(seq 1 50); do [ "$(pushinfo | jq -r .available)" = true ] && break; sleep 0.2; done
  [ "$(pushinfo | jq -r .devices)" -eq 1 ]
  sleep 2
  [ ! -s "$BATS_TEST_TMPDIR/got" ]
  id="$(cr ask --title "Ship the gift-card refunds on Friday?" --option Yes --option "Wait a week")"
  for _ in $(seq 1 100); do [[ -s "$BATS_TEST_TMPDIR/got" ]] && break; sleep 0.2; done
  sleep 1
  [ "$(wc -l <"$BATS_TEST_TMPDIR/got" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '"\(.title)|\(.tag)|\(.url)"' "$BATS_TEST_TMPDIR/got")" = "Ship the gift-card refunds on Friday?|acme:$id|/#/n/acme%3A$id" ]
  [[ "$(jq -r .body "$BATS_TEST_TMPDIR/got")" == "acme · To decide"* ]]
  [ "$(pushinfo | jq -r .sent)" -eq 1 ]
  # answered elsewhere: never pushed again, and the notification it left is withdrawn
  cr ask answer "$id" --pick 1 >/dev/null
  for _ in $(seq 1 50); do [ "$(wc -l <"$BATS_TEST_TMPDIR/got" | tr -d ' ')" -ge 2 ] && break; sleep 0.2; done
  sleep 1
  [ "$(wc -l <"$BATS_TEST_TMPDIR/got" | tr -d ' ')" -eq 2 ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/got" | jq -c .)" = "{\"type\":\"close\",\"tag\":\"acme:$id\"}" ]
  [ "$(pushinfo | jq -r '"\(.sent) \(.withdrawn)"')" = "1 1" ]
}

# The commander's word, from a process outside this one's tree (a test run by a chartroom worker
# would otherwise be refused as that worker, rightly).
as_commander() {
  local o="$BATS_TEST_TMPDIR/commander.$RANDOM" i
  ( ( "$CHARTROOM" "$@" >"$o.out" 2>&1; echo $? >"$o.rc" ) 3>&- & )
  for i in $(seq 1 100); do [[ -f "$o.rc" ]] && break; sleep 0.1; done
  cat "$o.out"; return "$(cat "$o.rc" 2>/dev/null || echo 1)"
}
sink_up() {
  "$NODE" "$REPO_ROOT/test/js/push-sink.js" "$BATS_TEST_TMPDIR/sub.json" "$BATS_TEST_TMPDIR/got" &
  SINK=$!
  for _ in $(seq 1 50); do [[ -s "$BATS_TEST_TMPDIR/sub.json" ]] && break; sleep 0.1; done
  serve
  for _ in $(seq 1 50); do [ "$(pushinfo | jq -r .available)" = true ] && break; sleep 0.2; done
  [ "$(post /api/v1/push/subscribe "$(cat "$BATS_TEST_TMPDIR/sub.json")" -H 'X-Chartroom-App: 1')" = 200 ]
}
lines() { if [[ -s "$BATS_TEST_TMPDIR/got" ]]; then wc -l <"$BATS_TEST_TMPDIR/got" | tr -d ' '; else echo 0; fi; }
until_lines() { for _ in $(seq 1 "$((${2:-10} * 5))"); do [ "$(lines)" -ge "$1" ] && return 0; sleep 0.2; done; return 1; }

@test "the XO answers first: a worker's decision answered within the hold is never pushed; one still open after it is; a breaking one, at once" {
  [[ -n "$NODE" ]] || skip "node not available"
  PATH="${NODE%/*}:$PATH"
  export CHARTROOM_APP_PUSH=on CHARTROOM_APP_PUSH_ALLOW_HTTP=1 CHARTROOM_APP_PUSH_HOLD=6
  sink_up
  [ "$(pushinfo | jq -r .hold)" -eq 6 ]
  t="$(cr status --json | jq -r '.[] | select(.title | test("sitemap"; "i")) | .id')"
  # asked, and answered by the XO (the worker carries on) within the hold: nothing reaches the commander
  cr event "$t" decision "Run the sitemap at 02:00 or 04:00 UTC?" >/dev/null
  for _ in $(seq 1 50); do [ "$(pushinfo | jq -r .holding)" -eq 1 ] && break; sleep 0.2; done
  [ "$(pushinfo | jq -r .holding)" -eq 1 ]
  # the XO's answer reaching the worker (what `chartroom steer` records)
  printf '%s steered: The XO: 02:00 UTC\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$(log_of "$t")"
  printf . >"$CHARTROOM_HOME/.changed" # as chartroom's own writes do: the server reads the home again
  sleep 8
  [ "$(lines)" -eq 0 ]
  [ "$(pushinfo | jq -r .holding)" -eq 0 ]
  # asked, and left open: pushed once the hold is over, not before
  cr event "$t" decision "Purge the CDN before the run?" >/dev/null
  sleep 3
  [ "$(lines)" -eq 0 ]
  until_lines 1 10
  [ "$(lines)" -eq 1 ]
  [[ "$(jq -r .tag "$BATS_TEST_TMPDIR/got")" == "acme:ev-$t-"* ]]
  # breaking: no hold
  u="$(cr status --json | jq -r '.[] | select(.title | test("gift"; "i")) | .id')"
  cr event "$u" decision --breaking "Refunds are failing in production: roll back the payments change?" >/dev/null
  until_lines 2 4
  [ "$(lines)" -eq 2 ]
}

@test "escalate: the XO hands a card over and it is pushed at once, marked; answered after the push, it is withdrawn" {
  [[ -n "$NODE" ]] || skip "node not available"
  cr help 2>/dev/null | grep -q 'chartroom permit escalate' || skip "needs the permission broker"
  PATH="${NODE%/*}:$PATH"
  export CHARTROOM_APP_PUSH=on CHARTROOM_APP_PUSH_ALLOW_HTTP=1 CHARTROOM_APP_PUSH_HOLD=60
  t="$(cr status --json | jq -r '.[] | select(.title | test("stock badge"; "i")) | .id')"
  sink_up
  # a new card, after the server read the home (one open at start is only remembered)
  now="$(date +%s)"
  mkdir -p "$CHARTROOM_HOME/permits/$t"
  jq -n --arg task "$t" --argjson now "$now" '{id: "p-5e6f", task: $task, created: ($now | todate), created_epoch: $now, expires_epoch: ($now + 900),
    event: "PermissionRequest", blocking: true, tool: "Bash", input: {command: "git push origin fix/badge", description: "Push the badge fix"},
    sig: "s-5e6f", desc: "Bash \"git push origin fix/badge\"", cwd: "/work/shop", why: "Push the badge fix", rule: "commander:outward",
    reason: "git-push", pattern: "git push:*", reason_denied: null, session_id: null, transcript: null, transcript_off: 0}' >"$CHARTROOM_HOME/permits/$t/p-5e6f.json"
  printf . >"$CHARTROOM_HOME/.changed"
  for _ in $(seq 1 50); do [ "$(pushinfo | jq -r .holding)" -eq 1 ] && break; sleep 0.2; done
  [ "$(pushinfo | jq -r .holding)" -eq 1 ]
  sleep 2
  [ "$(lines)" -eq 0 ]
  # the XO hands it over: pushed now, long before its hold, and the card says whose it is
  run as_commander permit escalate p-5e6f --note "Your call: it goes to the shared repo"
  [ "$status" -eq 0 ]
  [[ "$output" == "escalated p-5e6f"* ]]
  until_lines 1 6
  [ "$(lines)" -eq 1 ]
  [[ "$(jq -r .body "$BATS_TEST_TMPDIR/got")" == *"the XO left this one to you: Your call: it goes to the shared repo" ]]
  [ "$(cr app snapshot --json | jq -r '.needs[] | select(.permit == "p-5e6f") | .escalated.note')" = "Your call: it goes to the shared repo" ]
  # answered (here, through the app): the notification is withdrawn, never left to say it was answered
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' -H 'X-Chartroom-Action: a-esc-00001' \
      -d '{"id":"p-5e6f","answer":"once"}' "http://127.0.0.1:$PORT/api/v1/homes/acme/permit")" = 202 ]
  until_lines 2 15
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/got" | jq -c .)" = '{"type":"close","tag":"acme:p-5e6f"}' ]
  [ "$(pushinfo | jq -r '"\(.sent) \(.withdrawn)"')" = "1 1" ]
  # escalating a card no longer open says so
  run as_commander permit escalate p-5e6f
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not open"* ]]
  # and a worker may not escalate a card at all (the broker refuses it, and says so as breaking): run
  # as a worker is, with its task in the environment, whoever runs this suite (a worker or CI)
  run env CHARTROOM_TASK="$t" "$CHARTROOM" permit escalate p-5e6f
  [ "$status" -ne 0 ]
  [[ "$output" == *"a worker may not escalate permission card p-5e6f"* ]]
}
