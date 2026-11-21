#!/usr/bin/env bats
# Fleet (the app's slice 5): every machine's health from `chartroom nodes` (lib/app/fleet.jq), a
# failed sign-in as a Needs me item, the probe's disk-free line, and the server's background check.
# The machines are invented (test/fixtures/app-nodes.json).

load test_helper
load app_fixture

setup() {
  common_setup
  export CHARTROOM="$REPO_ROOT/bin/chartroom" CHARTROOM_TAILSCALE=none
  export CHARTROOM_APP_NODES="$REPO_ROOT/test/fixtures/app-nodes.json"
}

teardown() { cr app stop >/dev/null 2>&1 || true; }

@test "health: healthy, degraded (a sign-in, a tool, low disk) and down; the brain first; optional tools never count" {
  j="$(cr app fleet --json)"
  [ "$(jq -r '[.machines[] | "\(.name):\(.state):\(.brain)"] | join(" ")' <<<"$j")" = "studio:healthy:true laptop:degraded:false mini:degraded:false spare:down:false" ]
  [ "$(jq -r '.machines[] | select(.name == "mini") | .failing | join(",")' <<<"$j")" = "codex,disk below 15% free" ]
  [ "$(jq -r '.machines[] | select(.name == "spare") | .error' <<<"$j")" = "ssh: connect to host spare port 22: Operation timed out" ]
  # go is missing on studio, and it is still healthy: only the crew's own tools are checks
  [ "$(jq -r '.machines[] | select(.name == "studio") | [.tools[].label] | index("go")' <<<"$j")" = null ]
  [[ "$(jq -r .checked_at <<<"$j")" =~ ^20[0-9-]+T ]]
}

@test "a signed-out tool is a Needs me item, with the command to run; a broken tool's sign-in is not" {
  j="$(cr app fleet --json)"
  # mini's codex is missing and its sign-in check failed with it: the tool fails, the sign-in is unknown
  [ "$(jq -r '.needs | length' <<<"$j")" -eq 1 ]
  [ "$(jq -r '.needs[0] | "\(.id) \(.kind) \(.group) \(.machine)"' <<<"$j")" = "login-laptop-gh login unblock laptop" ]
  [ "$(jq -r '.needs[0].title' <<<"$j")" = "Sign in to gh on laptop" ]
  [[ "$(jq -r '.needs[0].summary' <<<"$j")" == "Sign in again on laptop: gh auth login."* ]]
  [ "$(jq -r '.machines[] | select(.name == "mini") | .logins[] | select(.label == "codex sign-in") | "\(.ok) \(.detail)"' <<<"$j")" = "null cannot tell: codex itself does not answer" ]
}

@test "the probe reports the share of disk free" {
  run cr node probe
  [ "$status" -eq 0 ]
  [[ "$output" =~ disk_free_pct[[:space:]]+[0-9]+ ]]
  unset CHARTROOM_APP_NODES
  [ "$(cr nodes --json | jq -r '.nodes[] | select(.local) | .disk_free_pct | type')" = number ]
}

@test "server: a check on demand puts the fleet in the state, its sign-ins with it" {
  app_fixture "$BATS_TEST_TMPDIR/h" "$PROJECT"
  export CHARTROOM_HOME="$BATS_TEST_TMPDIR/h/acme"
  run cr app serve --daemon --port 0 --no-auth
  [ "$status" -eq 0 ]
  PORT="$(awk '{print $2}' "$BATS_TEST_TMPDIR/app.pid")"
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/api/v1/state" >/dev/null && break; sleep 0.2; done
  # it starts ssh probes, so it is a write: the app's header, never a plain GET or a cross-site POST
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/fleet/check")" = 404 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$PORT/api/v1/fleet/check")" = 403 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' -H 'Sec-Fetch-Site: cross-site' -d '{}' "http://127.0.0.1:$PORT/api/v1/fleet/check")" = 403 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Chartroom-App: 1' -d '{}' "http://127.0.0.1:$PORT/api/v1/fleet/check")" = 202 ]
  for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$PORT/api/v1/state" | jq -e '.fleet.machines | length == 4' >/dev/null && break; sleep 0.2; done
  s="$(curl -s "http://127.0.0.1:$PORT/api/v1/state")"
  [ "$(jq -r '.fleet.needs[0].title' <<<"$s")" = "Sign in to gh on laptop" ]
  [ "$(jq -r '.fleet.error' <<<"$s")" = null ]
}
