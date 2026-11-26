#!/usr/bin/env bats
# Subscription usage awareness (lib/usage.sh): real sample parsing, exhaustion skipping,
# doctor/nodes reporting, worker limit-stop detection, chartroom move, and dashboard usage data.

load test_helper

setup() {
  common_setup
  export CHARTROOM_MACHINE_NAME=desk
  export CHARTROOM_KEYCHAIN=none
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CODEX_HOME/sessions/2026/11/26" "$CLAUDE_CONFIG_DIR"
  unset CHARTROOM_CLAUDE_USAGE_FILE CHARTROOM_CLAUDE_USAGE_URL CHARTROOM_CLAUDE_PLAN CHARTROOM_CLAUDE_ACCOUNT
}

teardown() {
  [[ ! -f "$BATS_TEST_TMPDIR/core.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/core.pid")" 2>/dev/null || true
  [[ ! -f "$BATS_TEST_TMPDIR/dash.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/dash.pid")" 2>/dev/null || true
  return 0
}

core_up() {
  local d="$XDG_STATE_HOME/herdr-core/default" sock="/tmp/cr-usage-$$-$RANDOM.sock" i
  mkdir -p "$d"; echo "$sock" >"$d/core.lock"
  perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die "$!"; while (my $c = $s->accept) { close $c }' "$sock" 3>&- &
  echo $! >"$BATS_TEST_TMPDIR/core.pid"
  for i in $(seq 1 50); do [[ ! -S "$sock" ]] || return 0; sleep 0.1; done
  return 1
}

# Future and past ISO timestamps for deterministic threshold/reset assertions.
iso_offset() {
  jq -rn --argjson off "$1" '(now | floor) + $off | todate'
}

@test "parses real sanitized usage samples for claude, codex, agy, and grok without storing secrets" {
  local fut5 fut7 past
  fut5="$(iso_offset 7200)"
  fut7="$(iso_offset 259200)"
  past="$(iso_offset -7200)"
  local now_iso; now_iso="$(iso_offset 0)"

  # 1. Claude OAuth API sample (via fixture hook) + fake claude auth status containing email/orgId that must never be stored.
  jq --arg r5 "$fut5" --arg r7 "$fut7" \
    '.five_hour.resets_at = $r5 | .seven_day.resets_at = $r7' \
    "$REPO_ROOT/test/fixtures/usage/claude-oauth-api.json" >"$BATS_TEST_TMPDIR/claude-api.json"
  export CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-api.json"
  export CHARTROOM_CLAUDE_PLAN=max_20x
  export CHARTROOM_CLAUDE_ACCOUNT=claude.ai

  # 2. Codex session JSONL sample with future resets_at epochs.
  local ep5 ep7
  ep5="$(jq -rn --argjson off 7200 '(now | floor) + $off')"
  ep7="$(jq -rn --argjson off 259200 '(now | floor) + $off')"
  jq -c --arg ts "$now_iso" --argjson e5 "$ep5" --argjson e7 "$ep7" \
    'if .payload.rate_limits? then .timestamp = $ts | .payload.rate_limits.primary.resets_at = $e5 | .payload.rate_limits.secondary.resets_at = $e7 else . end' \
    "$REPO_ROOT/test/fixtures/usage/codex-session.jsonl" >"$CODEX_HOME/sessions/2026/11/26/rollout-sample.jsonl"

  # 3. agy fake returning sanitized /usage JSON with future resets.
  jq --arg r5 "$fut5" --arg r7 "$fut7" \
    '.command.data.groups |= map(.buckets |= map(if .window == "5h" then .reset_time = $r5 elif .window == "weekly" then .reset_time = $r7 else . end))' \
    "$REPO_ROOT/test/fixtures/usage/agy-usage.json" >"$BATS_TEST_TMPDIR/agy-usage.json"
  cat >"$BIN/agy" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"-p=/usage"* ]]; then cat "$BATS_TEST_TMPDIR/agy-usage.json"; exit 0; fi
echo "Gemini 3 Pro"
EOF
  chmod +x "$BIN/agy"

  # 4. grok fake returning real captured shell-route error and team-managed message.
  cat >"$BIN/grok" <<'EOF'
#!/usr/bin/env bash
if [[ "${GROK_MODE:-shell}" == team ]]; then
  echo 'Usage limits are managed by your team.'
  exit 0
fi
echo 'Error: `grok usage` can'\''t show your plan'\''s usage here yet. Run /usage inside grok instead.' >&2
exit 1
EOF
  chmod +x "$BIN/grok"

  run cr usage --json --refresh
  [ "$status" -eq 0 ]

  # Claude: 5h 12% used / 88% left, 7d 94% used / 6% left -> state=near (between 80 and 95).
  [ "$(jq -r '.[] | select(.agent=="claude") | .state' <<<"$output")" = near ]
  [ "$(jq -r '.[] | select(.agent=="claude") | .plan' <<<"$output")" = max_20x ]
  [ "$(jq -r '.[] | select(.agent=="claude") | .windows[] | select(.label=="7d") | [.used_pct,.left_pct] | @csv' <<<"$output")" = '94,6' ]

  # Codex: 5h 35% used / 65% left, 7d 15% used / 85% left -> state=ok, plan=pro.
  [ "$(jq -r '.[] | select(.agent=="codex") | .state' <<<"$output")" = ok ]
  [ "$(jq -r '.[] | select(.agent=="codex") | .plan' <<<"$output")" = pro ]
  [ "$(jq -r '.[] | select(.agent=="codex") | .windows[] | select(.label=="5h") | [.used_pct,.left_pct] | @csv' <<<"$output")" = '35,65' ]
  [ "$(jq -r '.[] | select(.agent=="codex") | .windows[] | select(.label=="7d") | [.used_pct,.left_pct] | @csv' <<<"$output")" = '15,85' ]

  # agy: Gemini Models group -> 5h 0.5% used / 99.5% left, 7d 0.1% used / 99.9% left -> state=ok.
  [ "$(jq -r '.[] | select(.agent=="agy") | .state' <<<"$output")" = ok ]
  [ "$(jq -r '.[] | select(.agent=="agy") | .plan' <<<"$output")" = "Gemini Models" ]
  [ "$(jq -r '.[] | select(.agent=="agy") | .windows[] | select(.label=="5h") | [.used_pct,.left_pct] | @csv' <<<"$output")" = '0.5,99.5' ]
  [ "$(jq -r '.[] | select(.agent=="agy") | .windows[] | select(.label=="7d") | [.used_pct,.left_pct] | @csv' <<<"$output")" = '0.1,99.9' ]

  # grok (shell route): unknown with clear reason, never guessed.
  [ "$(jq -r '.[] | select(.agent=="grok") | .state' <<<"$output")" = unknown ]
  [[ "$(jq -r '.[] | select(.agent=="grok") | .reason' <<<"$output")" == *"daemon route"* ]]

  # grok (team-managed): unknown with clear reason, never guessed.
  GROK_MODE=team run cr usage --agent grok --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].state' <<<"$output")" = unknown ]
  [[ "$(jq -r '.[0].reason' <<<"$output")" == *"managed by your team"* ]]

  # Claude statusLine secondary input via `chartroom usage record claude`.
  jq --argjson e5 "$ep5" --argjson e7 "$ep7" \
    '.rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.resets_at = $e7' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" >"$BATS_TEST_TMPDIR/claude-sl.json"
  run cr usage record claude --plan max <"$BATS_TEST_TMPDIR/claude-sl.json"
  [ "$status" -eq 0 ]
  run cr usage --agent claude --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].source' <<<"$output")" = claude-statusline ]
  [ "$(jq -r '.[0].windows[] | select(.label=="5h") | .used_pct' <<<"$output")" = 25 ]
  [ "$(jq -r '.[0].windows[] | select(.label=="7d") | .used_pct' <<<"$output")" = 55 ]

  # Stale reading is flagged with age and stale=true.
  jq --arg old "$past" '.sampled_at = $old' "$CHARTROOM_HOME/usage/desk--codex.json" >"$BATS_TEST_TMPDIR/c.tmp"
  mv "$BATS_TEST_TMPDIR/c.tmp" "$CHARTROOM_HOME/usage/desk--codex.json"
  run cr usage --agent codex --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].stale' <<<"$output")" = true ]
  [ "$(jq -r '.[0].age_s >= 3600' <<<"$output")" = true ]

  # Zero secrets, tokens, cookies, emails, or orgIds stored on disk under $CHARTROOM_HOME/usage/.
  run grep -riE 'sk-ant|Bearer|accessToken|refreshToken|cookie|@|orgId' "$CHARTROOM_HOME/usage"
  [ "$status" -ne 0 ]
}

@test "per-machine readings collapse when identical and split per machine when they differ" {
  local fut5; fut5="$(iso_offset 7200)"
  local ep5; ep5="$(jq -rn --argjson off 7200 '(now | floor) + $off')"
  local now_iso; now_iso="$(iso_offset 0)"

  # Record identical claude usage on desk and mini -> mini must automatically be local=false,
  # and both machines should collapse into 1 row.
  jq --argjson e5 "$ep5" '.rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.resets_at = ($e5 + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" >"$BATS_TEST_TMPDIR/sl.json"
  cr usage record claude --machine desk --plan max <"$BATS_TEST_TMPDIR/sl.json"
  cr usage record claude --machine mini --plan max <"$BATS_TEST_TMPDIR/sl.json"
  [ "$(jq -r '.local' "$CHARTROOM_HOME/usage/desk--claude.json")" = true ]
  [ "$(jq -r '.local' "$CHARTROOM_HOME/usage/mini--claude.json")" = false ]

  # Record differing codex usage on desk (35%) vs mini (98%) -> should split into 2 rows,
  # and desk's node probe must NEVER emit mini's non-local reading as desk's.
  jq -c --arg ts "$now_iso" --argjson e5 "$ep5" \
    'select(.payload.rate_limits? != null) | .timestamp = $ts | .payload.rate_limits.primary.resets_at = $e5 | .payload.rate_limits.secondary.resets_at = ($e5 + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/codex-session.jsonl" | head -n 1 >"$BATS_TEST_TMPDIR/cx-desk.json"
  jq -c '.payload.rate_limits.primary.used_percent = 98.0' "$BATS_TEST_TMPDIR/cx-desk.json" >"$BATS_TEST_TMPDIR/cx-mini.json"
  cr usage record codex --machine mini <"$BATS_TEST_TMPDIR/cx-mini.json"
  [ "$(jq -r '.local' "$CHARTROOM_HOME/usage/mini--codex.json")" = false ]
  run cr node probe
  [ "$status" -eq 0 ]
  [[ "$output" != *$'usage\tcodex\tok'* ]]
  cr usage record codex --machine desk <"$BATS_TEST_TMPDIR/cx-desk.json"

  run cr dashboard --json
  [ "$status" -eq 0 ]
  # claude collapsed to 1 row listing both machines
  [ "$(jq '[.usage[] | select(.agent=="claude")] | length' <<<"$output")" -eq 1 ]
  [ "$(jq '[.usage[] | select(.agent=="claude") | .machines[]] | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.usage[] | select(.agent=="claude") | .per_machine' <<<"$output")" = false ]
  # codex split into 2 rows (desk ok, mini out)
  [ "$(jq '[.usage[] | select(.agent=="codex")] | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.usage[] | select(.agent=="codex" and .machine=="desk") | .state' <<<"$output")" = ok ]
  [ "$(jq -r '.usage[] | select(.agent=="codex" and .machine=="mini") | .state' <<<"$output")" = out ]
  [ "$(jq -r '.usage[] | select(.agent=="codex" and .machine=="mini") | .per_machine' <<<"$output")" = true ]
}

@test "exhausted agents are skipped on dispatch and fallback until resets_at passes, and reported by doctor and nodes" {
  use_fake hc agy
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"

  local fut past ep_fut ep_past now_iso
  fut="$(iso_offset 3600)"
  past="$(iso_offset -60)"
  ep_fut="$(jq -rn '(now | floor) + 3600')"
  ep_past="$(jq -rn '(now | floor) - 60')"
  now_iso="$(iso_offset 0)"

  # Mark codex at 96% (>= default 95% threshold) until fut.
  jq -c --arg ts "$now_iso" --argjson e "$ep_fut" \
    'select(.payload.rate_limits? != null) | .timestamp = $ts | .payload.rate_limits.primary.used_percent = 96.0 | .payload.rate_limits.primary.resets_at = $e | .payload.rate_limits.secondary.resets_at = ($e + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/codex-session.jsonl" | head -n 1 | cr usage record codex --machine desk

  # Normally ties pick codex first; with codex out, automatic dispatch must pick agy instead.
  id="$(new_task)"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc:agy"* ]]

  # An explicit --backend for an exhausted agent proceeds with a clear warning naming its reset time.
  exp_id="$(new_task --backend hc:codex --kind scout)"
  run cr dispatch "$exp_id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"explicit backend hc:codex"* ]]
  [[ "$output" == *"$fut"* ]]
  cr close "$exp_id" >/dev/null

  # Mark agy hit-limit as well -> automatic dispatch must pick claude.
  cr usage record agy --hit-limit --resets-at "$fut" --message "Individual quota reached"
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc:claude"* ]]

  # Configurable threshold: with claude at 88%, default 95% still picks claude, but 85% skips claude too.
  jq --argjson e "$ep_fut" '.rate_limits.five_hour.used_percentage = 88.0 | .rate_limits.five_hour.resets_at = $e | .rate_limits.seven_day.used_percentage = 40.0 | .rate_limits.seven_day.resets_at = ($e + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine desk --plan max
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc:claude"* ]]

  CHARTROOM_USAGE_LIMIT_PCT=85 run cr dispatch "$id" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backend available"* ]]

  # Doctor reports exhausted agents with reset times in both text and JSON.
  run cr doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"*"codex"*"OUT"* ]]
  [[ "$output" == *"usage:"*"agy"*"OUT"* ]]
  run cr doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.usage[] | select(.agent=="codex") | .state' <<<"$output")" = out ]
  [ "$(jq -r '.usage[] | select(.agent=="codex") | .out_resets_at' <<<"$output")" = "$fut" ]

  # Nodes reports exhausted agents in text and JSON, and `node probe` emits read-only usage TSV lines.
  export CHARTROOM_NODES=none
  export CHARTROOM_NODE_CONFIG="$BATS_TEST_TMPDIR/nodecfg/node"
  run cr node probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'usage\tcodex\tok'* ]]
  run cr nodes
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex:out"* ]]
  [[ "$output" == *"out of usage"* ]]
  run cr nodes --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.nodes[0].usage.codex.out' <<<"$output")" = true ]

  # Once resets_at passes, codex is automatically usable again (never stays locked out forever).
  jq -c --arg ts "$now_iso" --argjson e "$ep_past" \
    'select(.payload.rate_limits? != null) | .timestamp = $ts | .payload.rate_limits.primary.used_percent = 96.0 | .payload.rate_limits.primary.resets_at = $e | .payload.rate_limits.secondary.resets_at = ($e + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/codex-session.jsonl" | head -n 1 | cr usage record codex --machine desk
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hc:codex"* ]]
}

@test "detects usage-limit stops per agent, wakes XO once with available agents, and ignores code/diff lines" {
  # Direct pattern checks across all 4 agents (and non-matching code/diff lines).
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit claude "You'\''ve hit your limit · resets 2026-11-27T00:00:00Z"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-11-27T00:00:00Z"* ]]

  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit codex "You'\''ve hit your usage limit. Try again in 2h 15m."
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"in 2h 15m"* ]]

  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit agy "Model quota limit reached. Resets in 4h 30m."
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"in 4h 30m"* ]]

  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit grok "Error: You'\''ve hit your usage limit. Try again at 2026-11-27T03:00:00Z."
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-11-27T03:00:00Z"* ]]

  # Diff / comment / code / agent prose / tool output lines must NEVER trigger a false positive.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit claude "+  echo \"You'\''ve hit your limit · resets 2026-11-27T00:00:00Z\"
# usage limit reached
• Ran grep -i \"usage limit reached\" lib/usage.sh"
  '
  [ "$status" -ne 0 ]

  # Exact cold-review false-positive screens: Claude tool output (⎿), Claude prose (●), Codex prose (•).
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit claude "  ⎿  1180:      rx=\"you'\''ve hit your usage limit|usage_limit_reached|usage limit reached\" ;;"
  '
  [ "$status" -ne 0 ]

  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit claude "● The watch now wakes the XO when a worker prints \"Claude usage limit reached\", then marks it out."
  '
  [ "$status" -ne 0 ]

  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit codex "• I added detection for \"You'\''ve hit your usage limit\" in lib/usage.sh."
  '
  [ "$status" -ne 0 ]

  # Reset-time extraction and parsing preserve full words ("minutes", not "mi") and UTC clock dates.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    r1="$(usage_extract_reset_text "Resets in 1 hour 20 minutes.")"
    i1="$(usage_parse_reset_iso "$r1" 1795700000)"
    r2="$(usage_extract_reset_text "Try again in 2 days 3 hours 10 minutes.")"
    i2="$(usage_parse_reset_iso "$r2" 1795700000)"
    r3="$(usage_extract_reset_text "You'\''ve hit your limit · resets Nov 30, 10am (UTC)")"
    i3="$(usage_parse_reset_iso "$r3" 1795700000)"
    printf "%s|%s|%s|%s|%s|%s\n" "$r1" "$i1" "$r2" "$i2" "$r3" "$i3"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "in 1 hour 20 minutes|2026-11-26T14:53:20Z|in 2 days 3 hours 10 minutes|2026-11-28T16:43:20Z|Nov 30, 10am (UTC)|2026-11-30T10:00:00Z" ]

  # A weekly limit hit without explicit reset text inherits the 7d window reset (NOT the 5h window).
  local ep5_w ep7_w iso7_w
  ep5_w="$(jq -rn '(now | floor) + 3600')"
  ep7_w="$(jq -rn '(now | floor) + 300000')"
  iso7_w="$(jq -rn --argjson e "$ep7_w" '$e | todate')"
  jq --argjson e5 "$ep5_w" --argjson e7 "$ep7_w" \
    '.rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.resets_at = $e7' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine desk --plan max
  cr usage record claude --hit-limit --message "You've hit your weekly limit"
  run cr usage --agent claude --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].out_resets_at' <<<"$output")" = "$iso7_w" ]
  cr usage clear claude >/dev/null

  # Interactive worker mid-turn (live=working) must NOT trigger limit detection even if banner text appears.
  mid_id="$(new_task --backend hc:claude)"
  set_meta "$mid_id" '.dispatched="2026-11-26T00:00:00Z"'
  run bash -c '
    export CHARTROOM_HOME="'"$CHARTROOM_HOME"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    load_config
    usage_limit_look "'"$mid_id"'" hc claude "You'\''ve hit your limit · resets 2026-11-27T00:00:00Z" working desk
  '
  [ "$status" -eq 0 ]
  ! events "$mid_id" | grep -q 'out-of-usage'

  # End-to-end watch detection on a headless:claude worker that stopped on a usage limit.
  use_fake hc agy
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"

  local fut; fut="$(iso_offset 7200)"
  id="$(new_task --backend headless:claude)"
  set_meta "$id" '.dispatched="2026-11-26T00:00:00Z" | .pid="999999"'
  printf '{"type":"result","is_error":true,"result":"You'\''ve hit your weekly limit · resets %s"}\n' "$fut" \
    >"$CHARTROOM_HOME/tasks/$id/claude.jsonl"

  run cr watch --once --timeout 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: out-of-usage: claude resets $fut"* ]]
  [[ "$output" == *"available:"*"codex"* ]]
  [[ "$output" == *"chartroom move $id"* ]]

  # Agent is now recorded as out of usage.
  run cr usage --agent claude --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].out' <<<"$output")" = true ]
  [ "$(jq -r '.[0].out_resets_at' <<<"$output")" = "$fut" ]

  # Running watch again does not duplicate the out-of-usage wake.
  run cr watch --once --timeout 1
  [[ "$output" != *"out-of-usage"* ]]
}

@test "chartroom move switches an exhausted task to another agent while preserving brief, branch, commits, and uncommitted changes" {
  use_fake hc agy
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"

  id="$(new_task --backend hc:claude)"
  cr worktree "$id"
  wt="$(meta_of "$id" worktree)"
  branch="$(meta_of "$id" branch)"
  brief_before="$(cat "$CHARTROOM_HOME/tasks/$id/brief.md")"

  # Make one commit AND one uncommitted tracked edit AND one untracked file in the worktree.
  echo 'committed work' >"$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm 'feat: partial work before limit'
  commit_sha="$(git -C "$wt" rev-parse HEAD)"
  echo 'uncommitted edit' >>"$wt/work.txt"
  echo 'untracked scratch' >"$wt/notes.tmp"

  # Simulate claude running out of usage.
  local fut; fut="$(iso_offset 7200)"
  cr usage record claude --hit-limit --resets-at "$fut" --message "You've hit your weekly limit"

  # --dry-run reports destination and kept work without modifying anything.
  run cr move "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would move $id from hc:claude to hc:codex"* ]]
  [[ "$output" == *"1 commit(s), 2 uncommitted change(s)"* ]]
  [ "$(meta_of "$id" backend)" = hc:claude ]

  # Explicit move onto exhausted claude is refused without --force.
  run cr move "$id" --agent claude --no-dispatch
  [ "$status" -ne 0 ]
  [[ "$output" == *"out of usage"* ]]

  # A task that needs Claude (--needs mcp) must NOT automatically move to codex or agy.
  mcp_id="$(new_task --backend hc:claude --needs mcp)"
  run cr move "$mcp_id" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs Claude"* ]]
  # Explicit --agent overrides with a warning.
  run cr move "$mcp_id" --agent codex --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude-only needs"* ]]
  [[ "$output" == *"would move $mcp_id from hc:claude to hc:codex"* ]]

  # Move automatically onto codex (--no-dispatch so we verify state before launch, then verify prompt).
  run cr move "$id" --no-dispatch
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved $id: hc:claude -> hc:codex"* ]]

  # Backend switched, worktree/branch/commits/uncommitted/brief all preserved intact.
  [ "$(meta_of "$id" backend)" = hc:codex ]
  [ "$(meta_of "$id" moved_from)" = hc:claude ]
  [ "$(meta_of "$id" worktree)" = "$wt" ]
  [ "$(meta_of "$id" branch)" = "$branch" ]
  [ "$(git -C "$wt" branch --show-current)" = "$branch" ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$commit_sha" ]
  grep -qxF 'uncommitted edit' "$wt/work.txt"
  grep -qxF 'untracked scratch' "$wt/notes.tmp"
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/brief.md")" = "$brief_before" ]
  grep -q 'Moved from `hc:claude` to `hc:codex`' "$CHARTROOM_HOME/tasks/$id/inbox.md"
  events "$id" | grep -q 'moved from hc:claude to hc:codex'
}

@test "dashboard JSON and HTML expose subscription usage with live worker counts" {
  local ep5; ep5="$(jq -rn '(now | floor) + 5400')"
  jq --argjson e5 "$ep5" '.rate_limits.five_hour.used_percentage = 82.0 | .rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.used_percentage = 44.0 | .rate_limits.seven_day.resets_at = ($e5 + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine desk --plan max_20x

  new_task --backend hc:claude >/dev/null
  new_task --backend hc:claude >/dev/null

  run cr dashboard --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.usage[] | select(.agent=="claude") | .state' <<<"$output")" = near ]
  [ "$(jq -r '.usage[] | select(.agent=="claude") | .live_workers' <<<"$output")" = 2 ]
  [ "$(jq -r '.usage[] | select(.agent=="claude") | .plan' <<<"$output")" = max_20x ]

  # Dashboard HTML contains the usage panel markup and renderer.
  grep -q 'id="usage"' "$REPO_ROOT/lib/dashboard/index.html"
  grep -q 'function renderUsage' "$REPO_ROOT/lib/dashboard/index.html"
}

@test "real redacted Claude and Codex response shapes ignore scoped buckets, extra_usage, and mismatched credentials" {
  local fut7 ep7
  fut7="$(iso_offset 320000)"
  ep7="$(jq -rn '(now | floor) + 320000')"

  # 1. Real redacted Claude /api/oauth/usage shape: seven_day=58%, five_hour=null,
  #    seven_day_opus=99%, weekly_scoped=99%, extra_usage.spend_limit_reached=true, spend=100%.
  #    Must read 58% used / 42% left, state=ok, out=false.
  jq --arg r7 "$fut7" \
    '.seven_day.resets_at = $r7 | .seven_day_opus.resets_at = $r7 | .limits |= map(.resets_at = $r7)' \
    "$REPO_ROOT/test/fixtures/usage/claude-oauth-api-real.json" >"$BATS_TEST_TMPDIR/claude-real.json"
  CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-real.json" CHARTROOM_CLAUDE_PLAN=max_20x \
    run cr usage --agent claude --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].state' <<<"$output")" = ok ]
  [ "$(jq -r '.[0].out' <<<"$output")" = false ]
  [ "$(jq -r '.[0].windows | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].windows[0] | [.label,.used_pct,.left_pct] | @csv' <<<"$output")" = '"7d",58,42' ]

  # Also when top-level seven_day is null, limits[] fallback uses only active scope==null buckets (never weekly_scoped 99%).
  jq '.seven_day = null' "$BATS_TEST_TMPDIR/claude-real.json" >"$BATS_TEST_TMPDIR/claude-limits-only.json"
  CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-limits-only.json" CHARTROOM_CLAUDE_PLAN=max_20x \
    run cr usage --agent claude --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].state' <<<"$output")" = ok ]
  [ "$(jq -r '.[0].windows | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].windows[0] | [.label,.used_pct,.left_pct] | @csv' <<<"$output")" = '"7d",58,42' ]

  # 2. Claude credential precedence & account orgId cross-check:
  #    Keychain must win over a stale ~/.claude/.credentials.json from another account, and a
  #    mismatched organizationUuid must be rejected instead of querying the wrong account.
  cat >"$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
{"claudeAiOauth":{"accessToken":"tok-stale-wrong-acct","organizationUuid":"org-other"}}
JSON
  cat >"$BATS_TEST_TMPDIR/fake-security" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_KC_MODE:-ok}" == ok ]]; then
  echo '{"claudeAiOauth":{"accessToken":"tok-active-keychain","organizationUuid":"org-live"}}'
  exit 0
fi
exit 44
EOF
  chmod +x "$BATS_TEST_TMPDIR/fake-security"

  # Keychain active token wins over stale .credentials.json when both exist.
  run bash -c '
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    export CHARTROOM_KEYCHAIN="'"$BATS_TEST_TMPDIR/fake-security"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_claude_oauth_token "org-live"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "tok-active-keychain" ]

  # When Keychain fails and .credentials.json belongs to a different org (or is unattributed), reject it.
  run bash -c '
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    export CHARTROOM_KEYCHAIN="'"$BATS_TEST_TMPDIR/fake-security"'"
    export FAKE_KC_MODE=miss
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_claude_oauth_token "org-live"
  '
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  # Even with CHARTROOM_KEYCHAIN=none (Linux), an explicit organizationUuid mismatch is rejected.
  run bash -c '
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    export CHARTROOM_KEYCHAIN=none
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_claude_oauth_token "org-live"
  '
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  # 3. Real redacted Codex app-server `account/rateLimits/read` shape:
  #    Primary "codex" bucket is 26% used / 74% left; model-scoped "codex_scoped_model" is 100% reached.
  #    Must read 26% used / 74% left, state=ok, out=false, source=codex-app-server, and strip accountId/credits.
  jq --argjson e7 "$ep7" \
    '.rateLimits.primary.resetsAt = $e7 | .rateLimitsByLimitId.codex.primary.resetsAt = $e7 | .rateLimitsByLimitId.codex_scoped_model.primary.resetsAt = $e7' \
    "$REPO_ROOT/test/fixtures/usage/codex-appserver-ratelimits.json" >"$BATS_TEST_TMPDIR/codex-as.json"
  cat >"$BIN/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "app-server" ]]; then
  while IFS= read -r line; do
    if [[ "\$line" == *"account/rateLimits/read"* ]]; then
      printf '{"jsonrpc":"2.0","id":2,"result":%s}\n' "\$(jq -c . "$BATS_TEST_TMPDIR/codex-as.json")"
      exit 0
    fi
  done
  exit 0
fi
exit 0
EOF
  chmod +x "$BIN/codex"

  run cr usage --agent codex --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].source' <<<"$output")" = codex-app-server ]
  [ "$(jq -r '.[0].state' <<<"$output")" = ok ]
  [ "$(jq -r '.[0].out' <<<"$output")" = false ]
  [ "$(jq -r '.[0].plan' <<<"$output")" = pro ]
  [ "$(jq -r '.[0].windows | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].windows[0] | [.label,.used_pct,.left_pct] | @csv' <<<"$output")" = '"7d",26,74' ]
  # Verify accountId and credit balance are never stored on disk.
  ! grep -qiE 'accountId|00000000-0000-0000-0000-000000000000|balance' "$CHARTROOM_HOME/usage/desk--codex.json"
}

@test "nodes refresh and report live usage and guest limit stops, and watch auto-tracks fresh homes" {
  local fut5 ep5 now_iso
  fut5="$(iso_offset 7200)"
  ep5="$(jq -rn '(now | floor) + 7200')"
  now_iso="$(iso_offset 0)"

  # 1. Node usage-refresh writes to $XDG_STATE_HOME/chartroom/usage (no CHARTROOM_HOME needed)
  #    and `node probe` emits it read-only.
  jq -c --arg ts "$now_iso" --argjson e5 "$ep5" \
    'select(.payload.rate_limits? != null) | .timestamp = $ts | .payload.rate_limits.primary.used_percent = 97.0 | .payload.rate_limits.primary.resets_at = $e5 | .payload.rate_limits.secondary = null' \
    "$REPO_ROOT/test/fixtures/usage/codex-session.jsonl" | head -n 1 >"$CODEX_HOME/sessions/2026/11/26/rollout-node.jsonl"

  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node usage-refresh
  [ "$status" -eq 0 ]
  [ -f "$XDG_STATE_HOME/chartroom/usage/mini--codex.json" ]
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'usage\tcodex\tok\tpro\tchatgpt'* ]]
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node probe --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.usage.codex.out' <<<"$output")" = true ]

  # 2. Guest-side `node usage-look` detects an idle guest worker's limit stop, logs out-of-usage
  #    with the node name, and mirrors hit_limit into $XDG_STATE_HOME/chartroom/usage so the
  #    node's next probe reports claude as out.
  use_fake hc
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  local gid; gid="$(new_task --backend hc:claude)"
  set_meta "$gid" '.dispatched="2026-11-26T00:00:00Z" | .hc_terminal="t-guest" | .hc_launched="1"'
  mkdir -p "$FAKE_HC_DIR/terms"
  jq -cn --arg id "$gid" --arg l "$CHARTROOM_HOME/tasks/$gid/launch.sh" \
    '{address:"t-guest",name:$id,state:"live",argv:["bash",$l],status:{app:"claude-code",state:"idle"}}' \
    >"$FAKE_HC_DIR/terms/t-guest.json"
  printf "You've hit your weekly limit · resets %s\n❯ \n" "$fut5" >"$FAKE_HC_DIR/screen.t-guest"

  CHARTROOM_GUEST=1 CHARTROOM_MACHINE_NAME=mini run cr node usage-look
  [ "$status" -eq 0 ]
  events "$gid" | grep -q "agent: out-of-usage: claude on mini resets $fut5"
  [ -f "$XDG_STATE_HOME/chartroom/usage/mini--claude.json" ]
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node probe --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.usage.claude.out' <<<"$output")" = true ]
  [ "$(jq -r '.usage.claude.out_resets_at' <<<"$output")" = "$fut5" ]

  # 3. Automatic watch refresh on a fresh home (with no usage/ directory yet) creates and populates usage/.
  local fresh_home="$BATS_TEST_TMPDIR/fresh-home"
  mkdir -p "$fresh_home/tasks"
  [ ! -d "$fresh_home/usage" ]
  CHARTROOM_HOME="$fresh_home" CHARTROOM_USAGE_REFRESH_MINUTES=5 run cr watch --once --timeout 1
  for _ in $(seq 1 40); do
    [[ -f "$fresh_home/usage/desk--codex.json" ]] && break
    sleep 0.1
  done
  [ -f "$fresh_home/usage/desk--codex.json" ]
}
