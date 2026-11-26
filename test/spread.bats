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
  mcp="$(new_task --needs mcp)"
  run cr dispatch "$mcp" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:claude"* ]]
  printf '\nNeeds: browser\n' >>"$CHARTROOM_HOME/tasks/$id/brief.md"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:claude"* ]]
  explicit="$(new_task --needs mcp --backend hc:codex)"
  run cr dispatch "$explicit" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"hc:codex"* ]]
  fresh="$(new_task)"
  CODEX_LOGIN_RC=1 run cr dispatch "$fresh" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" != *"hc:codex"* ]]
  run cr status --spread --json
  [ "$status" -eq 0 ]; [ "$(jq '[.[].live] | add' <<<"$output")" -eq 3 ]
  cr homes add crew "$CHARTROOM_HOME" >/dev/null
  run cr status --spread --json --all-homes
  [ "$status" -eq 0 ]; [ "$(jq '.[0].result | map(.live) | add' <<<"$output")" -eq 3 ]
  run cr dashboard --json --all-homes
  [ "$status" -eq 0 ]; [ "$(jq '.[0].result.agents | length' <<<"$output")" -eq 3 ]
}

@test "done creates one cold Opus review, gates acceptance, and tallies its verdict" {
  id="$(new_task --backend hc:codex)"
  cr worktree "$id"
  wt="$(meta_of "$id" worktree)"
  echo 'reviewable change' >>"$wt/README"
  git -C "$wt" add README; git -C "$wt" commit -qm 'feat: reviewable change'
  set_meta "$id" '.dispatched="2026-01-01T00:00:00Z"'
  echo 'biased worker report' >"$CHARTROOM_HOME/tasks/$id/report.md"
  cr event "$id" done 'implementation ready'
  rid="$(meta_of "$id" review_task)"
  [ -n "$rid" ]
  [ "$(meta_of "$rid" backend)" = hc:claude ]
  [ "$(meta_of "$rid" model)" = claude-opus-5-5 ]
  [ "$(meta_of "$rid" review_of)" = "$id" ]
  grep -q "^+reviewable change" "$CHARTROOM_HOME/tasks/$rid/source.diff"
  ! grep -q 'biased worker report' "$CHARTROOM_HOME/tasks/$rid/brief.md"
  run cr accept "$id"
  [ "$status" -ne 0 ]; [[ "$output" == *"cold review"* ]]
  [ "$(meta_of "$id" review_task)" = "$rid" ]
  cr event "$rid" done 'finished without a verdict'
  run cr accept "$id"
  [ "$status" -ne 0 ]
  cr event "$rid" done 'clean: no actionable findings'
  run cr accept "$id"
  [ "$status" -eq 0 ]
  run cr status --spread --json
  [ "$(jq '.[] | select(.agent=="codex") | .clean' <<<"$output")" -eq 1 ]
  cr event "$rid" done 'clean: repeated delivery'
  run cr status --spread --json
  [ "$(jq '.[] | select(.agent=="codex") | .clean' <<<"$output")" -eq 1 ]
  cr event "$id" done 'second implementation round'
  next="$(meta_of "$id" review_task)"
  [ "$next" != "$rid" ]
  run cr accept "$id"
  [ "$status" -ne 0 ]
  cr event "$next" done 'rework: P1 missing boundary check'
  run cr status --spread --json
  [ "$(jq '.[] | select(.agent=="codex") | [.clean,.rework]' -c <<<"$output")" = '[1,1]' ]
  run cr app snapshot --json
  [ "$status" -eq 0 ]
  [ "$(jq '.agents[] | select(.agent=="codex") | [.clean,.rework]' -c <<<"$output")" = '[1,1]' ]
  # A guest's durable push record identifies it even when its runner drops the guest env.
  mkdir -p "$CHARTROOM_HOME/.push"; echo '{}' >"$CHARTROOM_HOME/.push/$id.json"
  cr event "$id" done 'guest completion belongs to the brain'
  [ "$(meta_of "$id" review_task)" = "$next" ]

}
