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
  [ "$(stat -f '%Lp' "$BATS_TEST_TMPDIR/app-push-keys.json" 2>/dev/null || stat -c '%a' "$BATS_TEST_TMPDIR/app-push-keys.json")" = 600 ]
  k='"keys":{"p256dh":"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4","auth":"BTBZMqHH6r4Tts7J_aSIgg"}'
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}")" = 403 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1' -H 'Sec-Fetch-Site: cross-site')" = 403 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"http://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1')" = 400 ]
  [ "$(post /api/v1/push/subscribe '{"endpoint":"https://push.example.net/a","keys":{"p256dh":"x","auth":"y"}}' -H 'X-Chartroom-App: 1')" = 400 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1')" = 200 ]
  [ "$(post /api/v1/push/subscribe "{\"endpoint\":\"https://push.example.net/a\",$k}" -H 'X-Chartroom-App: 1')" = 200 ]
  [ "$(pushinfo | jq -r .devices)" -eq 1 ]
  [ "$(stat -f '%Lp' "$BATS_TEST_TMPDIR/app-push-subs.json" 2>/dev/null || stat -c '%a' "$BATS_TEST_TMPDIR/app-push-subs.json")" = 600 ]
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
  # answered elsewhere and asked again: the same card is not pushed twice
  cr ask answer "$id" --pick 1 >/dev/null
  sleep 2
  [ "$(wc -l <"$BATS_TEST_TMPDIR/got" | tr -d ' ')" -eq 1 ]
}
