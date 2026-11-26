#!/usr/bin/env bats
load test_helper
setup() { common_setup; }
teardown() {
  [[ ! -f "$BATS_TEST_TMPDIR/core.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/core.pid")" 2>/dev/null
  return 0
}
core_up() {
  local d="$XDG_STATE_HOME/herdr-core/default" sock="/tmp/cr-spread-$$.sock" i
  mkdir -p "$d"; echo "$sock" >"$d/core.lock"
  perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die "$!"; while (my $c = $s->accept) { close $c }' "$sock" 3>&- &
  echo $! >"$BATS_TEST_TMPDIR/core.pid"
  for i in $(seq 1 50); do [[ ! -S "$sock" ]] || return 0; sleep 0.1; done
  return 1
}

@test "automatic full sessions balance the home, honor MCP and explicit backends, and skip missing logins" {
  use_fake hc agy
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  # Login-only CLIs; --dry-run never launches a worker.
  printf '#!/usr/bin/env bash\nexit "${CODEX_LOGIN_RC:-0}"\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"
  id="$(new_task)"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:codex"* ]]
  busy="$(new_task --backend hc:codex)"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:agy"* ]]
  second="$(new_task --backend hc:agy)"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:claude"* ]]
  # Claude carries the highest share: the opt-out must override the picker.
  new_task --backend hc:claude >/dev/null
  new_task --backend hc:claude >/dev/null
  new_task --backend hc:claude >/dev/null
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:codex"* ]]
  mcp="$(new_task --needs mcp)"
  run cr dispatch "$mcp" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:claude"* ]]
  printf '\nNeeds: git python browser\n' >>"$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:claude"* ]]
  explicit="$(new_task --needs mcp --backend hc:codex)"
  run cr dispatch "$explicit" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:codex"* ]]
  fresh="$(new_task)"
  CODEX_LOGIN_RC=1 run cr dispatch "$fresh" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" != *"hc:codex"* ]]
  run cr status --spread --json
  [ "$status" -eq 0 ]; [ "$(jq '[.[].live] | add' <<<"$output")" -eq 6 ]
  cr homes add crew "$CHARTROOM_HOME" >/dev/null
  run cr status --spread --json --all-homes
  [ "$status" -eq 0 ]; [ "$(jq '.[0].result | map(.live) | add' <<<"$output")" -eq 6 ]
  run cr dashboard --json --all-homes
  [ "$status" -eq 0 ]; [ "$(jq '.[0].result.agents | length' <<<"$output")" -eq 3 ]
  run cr dashboard --all-homes
  [ "$status" -eq 0 ]; [[ "$output" == *"agents:"* ]]
}

reviewable_task() {
  id="$(new_task --backend hc:codex)"
  cr worktree "$id"
  wt="$(meta_of "$id" worktree)"
  echo 'reviewable change' >>"$wt/README"
  git -C "$wt" add README; git -C "$wt" commit -qm 'feat: reviewable change'
  set_meta "$id" '.dispatched="2026-01-01T00:00:00Z"'
}
review_runner() {
  use_fake hc claude
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
}

@test "done queues a cold review; verdicts gate accept and unchanged diffs reuse it; tally counts tasks" {
  reviewable_task
  echo 'biased worker report' >"$CHARTROOM_HOME/tasks/$id/report.md"
  cr event "$id" done 'implementation ready'
  [ -z "$(meta_of "$id" review_task)" ]
  [ "$(meta_of "$id" review_pending)" = 1 ]
  run cr accept "$id"
  [ "$status" -ne 0 ]; [[ "$output" == *"cold review"* ]]
  cr review-sync "$id"
  rid="$(meta_of "$id" review_task)"
  [ -n "$rid" ]
  [ "$(meta_of "$rid" backend)" = hc:claude ]
  [ "$(meta_of "$rid" model)" = claude-opus-5-5 ]
  [ "$(meta_of "$rid" review_of)" = "$id" ]
  grep -q "^+reviewable change" "$CHARTROOM_HOME/tasks/$rid/source.diff"
  ! grep -q 'biased worker report' "$CHARTROOM_HOME/tasks/$rid/brief.md"
  # No runner exists yet: failure is visible and a later sync retries the same review.
  [ -n "$(meta_of "$rid" review_error)" ]
  run cr status --json
  [ "$(jq -r --arg id "$rid" '.[] | select(.id==$id) | .state' <<<"$output")" = blocked ]
  review_runner
  cr review-sync "$id"
  [ "$(meta_of "$id" review_task)" = "$rid" ]
  [ -n "$(meta_of "$rid" dispatched)" ]
  [ -z "$(meta_of "$rid" review_error)" ]
  cr event "$rid" done 'finished without a verdict'
  run cr accept "$id"
  [ "$status" -ne 0 ]
  cr event "$rid" done 'Verdict — Clean: no findings'
  cr review-sync "$rid"
  run cr accept "$id"
  [ "$status" -eq 0 ]
  cr event "$id" done 'same implementation delivered twice'
  cr review-sync "$id"
  [ "$(meta_of "$id" review_task)" = "$rid" ]
  [ "$(meta_of "$id" review_generation)" = 1 ]
  run cr accept "$id"
  [ "$status" -eq 0 ]
  echo 'changed implementation' >>"$wt/README"
  git -C "$wt" commit -qam 'fix: changed implementation'
  cr event "$id" done 'changed implementation ready'
  cr review-sync "$id"
  next="$(meta_of "$id" review_task)"
  [ "$next" != "$rid" ]
  run cr accept "$id"
  [ "$status" -ne 0 ]
  cr event "$next" done 'Verdict: Needs changes — P1 missing boundary check'
  cr review-sync "$next"
  run cr status --spread --json
  [ "$(jq '.[] | select(.agent=="codex") | [.clean,.rework]' -c <<<"$output")" = '[0,1]' ]
  run cr app snapshot --json
  [ "$status" -eq 0 ]
  [ "$(jq '.agents[] | select(.agent=="codex") | [.clean,.rework]' -c <<<"$output")" = '[0,1]' ]
  mkdir -p "$CHARTROOM_HOME/.push"; echo '{}' >"$CHARTROOM_HOME/.push/$id.json"
  cr event "$id" done 'guest completion belongs to the brain'
  cr review-sync "$id"
  [ "$(meta_of "$id" review_task)" = "$next" ]
}

@test "watch starts review asynchronously and retries a fatal Git failure after worktree recovery" {
  reviewable_task
  mv "$wt" "$wt-away"
  cr event "$id" done 'ready while checkout is unavailable'
  run cr watch --once --timeout 2
  # Watch spawns the retry worker and returns without waiting for its Git/dispatch.
  for i in $(seq 1 100); do
    rid="$(meta_of "$id" review_waiting_task)"
    if [[ -n "$rid" && -n "$(meta_of "$rid" review_error)" ]]; then break; fi
    sleep 0.1
  done
  [ -n "$rid" ]
  [[ "$(meta_of "$rid" review_error)" == *"diff is unavailable"* ]]
  run cr status --json
  [ "$(jq -r --arg id "$rid" '.[] | select(.id==$id) | .state' <<<"$output")" = blocked ]
  mv "$wt-away" "$wt"
  review_runner
  cr review-sync "$id"
  [ "$(meta_of "$id" review_task)" = "$rid" ]
  [ -z "$(meta_of "$rid" review_error)" ]
  [ -n "$(meta_of "$rid" dispatched)" ]
  grep -q '^+reviewable change' "$CHARTROOM_HOME/tasks/$rid/source.diff"
}

@test "scouts and legacy tasks are exempt and explicit skip-review releases one gated ship" {
  for kind in scout ship; do
    id="$(new_task --backend hc:codex --kind "$kind")"
    set_meta "$id" '.dispatched="2026-01-01T00:00:00Z"'
    if [[ "$kind" = ship ]]; then set_meta "$id" 'del(.review_gate)'; fi
    cr event "$id" done 'old or report-only work'
    cr review-sync "$id"
    [ -z "$(meta_of "$id" review_task)" ]
    run cr accept "$id"
    [ "$status" -eq 0 ]
  done
  id="$(new_task --backend hc:agy)"
  set_meta "$id" '.dispatched="2026-01-01T00:00:00Z"'
  cr event "$id" done 'gated work'
  run cr accept "$id"
  [ "$status" -ne 0 ]
  run cr accept "$id" --skip-review
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" review_skipped)" = 1 ]
  cr review-sync "$id"
  [ -z "$(meta_of "$id" review_task)" ]
}
