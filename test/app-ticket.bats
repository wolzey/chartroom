#!/usr/bin/env bats
# A task as a ticket (the app's slice 2): attachments, links, the description edited in place,
# planning properties, the ticket's JSON, and the server's ticket, upload and attachment routes.
# Invented data only (test/app_fixture.bash).

load test_helper
load app_fixture

setup() {
  common_setup
  export CHARTROOM="$REPO_ROOT/bin/chartroom" CHARTROOM_TAILSCALE=none
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  T="$(cr status --json | jq -r '.[] | select(.title | test("stock badge")) | .id')"
}

teardown() { cr app stop >/dev/null 2>&1 || true; }

steers() { events "$T" | grep -c ' steered: ' || true; }

@test "attachment: kept 0600 in the task's folder; the commander's steers the worker, --silent and a worker's do not" {
  printf 'a screenshot' >"$BATS_TEST_TMPDIR/shot.png"
  n0="$(steers)"
  run cr attachment add "$T" --by commander --caption "before the fix" "$BATS_TEST_TMPDIR/shot.png"
  [ "$status" -eq 0 ]
  att="$(cr attachment list "$T" --json | jq -r '.[0].id')"
  f="$CHARTROOM_HOME/tasks/$T/attachments/$att/shot.png"
  [ "$(cat "$f")" = "a screenshot" ]
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ]
  [ "$(cr attachment list "$T" --json | jq -r '.[0] | "\(.type) \(.size) \(.by) \(.caption)"')" = "image/png 12 commander before the fix" ]
  [ "$(steers)" -eq $((n0 + 1)) ]
  events "$T" | grep -q "steered: The commander attached a file to this task: .*shot.png"
  cr attachment add "$T" --by commander --silent "$BATS_TEST_TMPDIR/shot.png" >/dev/null
  CHARTROOM_TASK="$T" cr attachment add "$T" "$BATS_TEST_TMPDIR/shot.png" >/dev/null
  [ "$(steers)" -eq $((n0 + 1)) ]
  [ "$(cr attachment list "$T" --json | jq -r '[.[].by] | join(" ")')" = "commander commander worker" ]
  cr attachment rm "$T" "$att" >/dev/null
  [ ! -e "$f" ]
  [ "$(cr attachment list "$T" --json | jq length)" -eq 2 ]
}

@test "attachment: over 25 MB is refused, and a name never leaves the folder" {
  dd if=/dev/zero of="$BATS_TEST_TMPDIR/big.mov" bs=1048576 count=26 2>/dev/null
  run cr attachment add "$T" --silent "$BATS_TEST_TMPDIR/big.mov"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most 25 MB"* ]]
  printf 'x' >"$BATS_TEST_TMPDIR/x.txt"
  cr attachment add "$T" --silent --name "../../../evil.sh" "$BATS_TEST_TMPDIR/x.txt" >/dev/null
  att="$(cr attachment list "$T" --json | jq -r '.[0].id')"
  [ "$(cr attachment list "$T" --json | jq -r '.[0].name')" = ".._.._evil.sh" ] || [ "$(cr attachment list "$T" --json | jq -r '.[0].name')" = "_.._.._evil.sh" ]
  [ ! -e "$CHARTROOM_HOME/evil.sh" ]
  compgen -G "$CHARTROOM_HOME/tasks/$T/attachments/$att/*evil.sh" >/dev/null
}

@test "link: a worker's PR URLs and added links together, once each; rm hides one" {
  cr link "$T" https://github.com/acme/shop/pull/415 --title "Badge reads live stock" >/dev/null
  cr link "$T" https://github.com/acme/shop/pull/412 >/dev/null # the worker already wrote this one
  cr link "$T" https://tickets.example.com/SHOP-9 >/dev/null
  [ "$(cr link list "$T" --json | jq -r '[.[] | "\(.kind):\(.url | split("/") | last)"] | join(" ")')" = "pr:412 pr:415 url:SHOP-9" ]
  cr link rm "$T" https://tickets.example.com/SHOP-9 >/dev/null
  [ "$(cr link list "$T" --json | jq length)" -eq 2 ]
  run cr link "$T" "javascript:alert(1)"
  [ "$status" -ne 0 ]
}

@test "brief: sections replaced in place, the old brief kept, the worker steered with the change" {
  n0="$(steers)"
  run cr brief "$T" --sections - <<<'{"Spec":"- read the live count\n- add a test"}'
  [ "$status" -eq 0 ]
  grep -q '^- add a test$' "$CHARTROOM_HOME/tasks/$T/brief.md"
  grep -q "^## Commander's intent" "$CHARTROOM_HOME/tasks/$T/brief.md"
  grep -q "^The badge says in stock when it is not.$" "$CHARTROOM_HOME/tasks/$T/brief.md"
  [ "$(ls "$CHARTROOM_HOME/tasks/$T/brief-history" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(steers)" -eq $((n0 + 1)) ]
  events "$T" | grep -q 'steered: The commander edited your brief'
  run cr brief "$T" --sections - <<<'{"Nope":"x"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no section '## Nope'"* ]]
}

@test "set: priority, labels, initiative; bad values refused; the ticket carries them" {
  cr set "$T" priority=high labels=storefront,bug >/dev/null
  run cr set "$T" priority=extreme
  [ "$status" -ne 0 ]
  run cr set "$T" labels='Not OK'
  [ "$status" -ne 0 ]
  j="$(cr app task "$T" --json)"
  [ "$(jq -r '"\(.priority) \(.labels | join(","))"' <<<"$j")" = "high bug,storefront" ]
  [ "$(jq -r '.status' <<<"$j")" = review ]
  [ "$(jq -r '.sections["Commander'"'"'s intent"]' <<<"$j")" = "The badge says in stock when it is not." ]
  [ "$(jq -r '[.links[].url] | join(" ")' <<<"$j")" = "https://github.com/acme/shop/pull/412" ]
  [ "$(jq -r '.events | length > 0' <<<"$j")" = true ]
  cr set "$T" priority=none >/dev/null
  [ "$(cr app task "$T" --json | jq -r .priority)" = null ]
}

@test "server: the ticket, an upload (queued, 25 MB at most), and attachments served without running anything" {
  run cr app serve --daemon --port 0 --no-auth
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -e '[.homes[] | select(.snapshot)] | length == 2' >/dev/null && break; sleep 0.2; done
  [ "$(curl -s "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$T" | jq -r .id)" = "$T" ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/no-such-task")" = 404 ]
  up() { curl -s -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -X POST -H 'X-Chartroom-App: 1' -H "X-Chartroom-Action: $1" \
    -H "X-Filename: $2" -H "Content-Type: $3" --data-binary "@$4" "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$T/attachments"; }
  printf '<script>alert(1)</script>' >"$BATS_TEST_TMPDIR/page.html"
  printf 'plain words' >"$BATS_TEST_TMPDIR/note.txt"
  [ "$(up a-up-00001 note.txt text/plain "$BATS_TEST_TMPDIR/note.txt")" = 202 ]
  [ "$(up a-up-00002 page.html text/html "$BATS_TEST_TMPDIR/page.html")" = 202 ]
  [ "$(up a-up-00001 note.txt text/plain "$BATS_TEST_TMPDIR/note.txt")" = 202 ] # a retry: never a second copy
  for _ in $(seq 1 100); do [ "$(cr attachment list "$T" --json | jq length)" -ge 2 ] && break; sleep 0.1; done
  sleep 0.5
  [ "$(cr attachment list "$T" --json | jq -r '[.[].name] | join(" ")')" = "note.txt page.html" ]
  ! compgen -G "$CHARTROOM_HOME/tasks/$T/attachments/.incoming-*" >/dev/null || false
  dd if=/dev/zero of="$BATS_TEST_TMPDIR/big.bin" bs=1048576 count=26 2>/dev/null
  [ "$(up a-up-00003 big.bin application/octet-stream "$BATS_TEST_TMPDIR/big.bin")" = 413 ]
  note="$(cr attachment list "$T" --json | jq -r '.[] | select(.name == "note.txt") | .id')"
  page="$(cr attachment list "$T" --json | jq -r '.[] | select(.name == "page.html") | .id')"
  curl -s -D "$BATS_TEST_TMPDIR/h1" -o "$BATS_TEST_TMPDIR/b1" "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$T/attachments/$note"
  grep -qi '^content-type: text/plain' "$BATS_TEST_TMPDIR/h1"
  grep -qi "^content-security-policy: sandbox" "$BATS_TEST_TMPDIR/h1"
  [ "$(cat "$BATS_TEST_TMPDIR/b1")" = "plain words" ]
  # HTML a worker or anyone attached is only ever a download: never run on the app's origin
  curl -s -D "$BATS_TEST_TMPDIR/h2" -o /dev/null "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$T/attachments/$page"
  grep -qi '^content-type: application/octet-stream' "$BATS_TEST_TMPDIR/h2"
  grep -qi '^content-disposition: attachment' "$BATS_TEST_TMPDIR/h2"
  # a byte range, for video in Safari
  [ "$(curl -s -H 'Range: bytes=0-4' "http://127.0.0.1:$PORT/api/v1/homes/acme/tasks/$T/attachments/$note")" = "plain" ]
}
