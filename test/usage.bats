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
  unset CHARTROOM_USAGE_ACCOUNT_CLAUDE CHARTROOM_USAGE_ACCOUNT_CODEX CHARTROOM_USAGE_ACCOUNT_AGY CHARTROOM_USAGE_ACCOUNT_GROK
}

teardown() {
  [[ ! -f "$BATS_TEST_TMPDIR/core.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/core.pid")" 2>/dev/null || true
  [[ ! -f "$BATS_TEST_TMPDIR/dash.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/dash.pid")" 2>/dev/null || true
  [[ ! -f "$BATS_TEST_TMPDIR/ep.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/ep.pid")" 2>/dev/null || true
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
  ep_fut="$(jq -rn '(now | floor) + 3600')"
  ep_past="$(jq -rn '(now | floor) - 60')"
  fut="$(jq -rn --argjson e "$ep_fut" '$e | todate')"
  past="$(jq -rn --argjson e "$ep_past" '$e | todate')"
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

@test "detects real captured usage-limit stops per agent, parses real reset times, wakes XO once, and ignores prose/code" {
  # 1. Real captured Codex binary strings (curly apostrophe U+2019 + TUI ■ prefix) in both screen and headless modes.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    run bash -c '
      source "'"$REPO_ROOT/lib/core.sh"'"
      source "'"$REPO_ROOT/lib/usage.sh"'"
      usage_screen_limit codex "$1" screen && usage_screen_limit codex "$1" headless
    ' _ "$line"
    [ "$status" -eq 0 ]
  done <"$REPO_ROOT/test/fixtures/usage/limits/codex-binary-limits.txt"

  # 2. Real captured Claude transcript limit entry (structured + screen + headless).
  local claude_real_txt
  claude_real_txt="$(jq -r '.message.content[0].text' "$REPO_ROOT/test/fixtures/usage/limits/claude-transcript-limit.jsonl")"
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit claude "$1" screen
  ' _ "$claude_real_txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nov 23 at 3am (America/Denver)"* ]]

  # Structured Claude session transcript detection (works even if TUI drew under ⎿) and ignores stale errors after resume.
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/demo-proj"
  cp "$REPO_ROOT/test/fixtures/usage/limits/claude-transcript-limit.jsonl" \
    "$CLAUDE_CONFIG_DIR/projects/demo-proj/sess-limit-1234.jsonl"
  run bash -c '
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_claude_transcript_limit sess-limit-1234
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nov 23 at 3am (America/Denver)"* ]]
  # Once a newer normal assistant turn is appended, the older limit error no longer triggers.
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Resumed and continuing."}]}}' \
    >>"$CLAUDE_CONFIG_DIR/projects/demo-proj/sess-limit-1234.jsonl"
  run bash -c '
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_claude_transcript_limit sess-limit-1234
  '
  [ "$status" -ne 0 ]

  # 3. Real agy and grok binary limit strings.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    run bash -c '
      source "'"$REPO_ROOT/lib/core.sh"'"
      source "'"$REPO_ROOT/lib/usage.sh"'"
      usage_screen_limit agy "$1" screen
    ' _ "$line"
    [ "$status" -eq 0 ]
  done <"$REPO_ROOT/test/fixtures/usage/limits/agy-binary-limits.txt"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    run bash -c '
      source "'"$REPO_ROOT/lib/core.sh"'"
      source "'"$REPO_ROOT/lib/usage.sh"'"
      usage_screen_limit grok "$1" screen
    ' _ "$line"
    [ "$status" -eq 0 ]
  done <"$REPO_ROOT/test/fixtures/usage/limits/grok-binary-limits.txt"

  # 4. Real reset-time parsing: IANA timezones, pipe-epoch, local wall-clock, relative minutes/days.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    r_den="$(usage_extract_reset_text "You'\''ve hit your monthly spend limit · your weekly limit resets Nov 23 at 3am (America/Denver)")"
    i_den="$(usage_parse_reset_iso "$r_den" 1795000000)"
    r_3pm="$(usage_extract_reset_text "You'\''ve hit your session limit · resets 3pm (America/Denver) · progress saved")"
    i_3pm="$(usage_parse_reset_iso "$r_3pm" 1795700000)"
    r_ep="$(usage_extract_reset_text "Claude AI usage limit reached|1795900000")"
    i_ep="$(usage_parse_reset_iso "$r_ep" 1795700000)"
    r_loc="$(usage_extract_reset_text "You’ve hit your usage limit. Upgrade to Plus, or try again at 3:05 PM.")"
    i_loc="$(usage_parse_reset_iso "$r_loc" 1795700000)"
    printf "%s|%s|%s|%s|%s\n" "$i_den" "$i_3pm" "$i_ep" "$r_loc" "$i_loc"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "2026-11-23T10:00:00Z|2026-11-26T22:00:00Z|2026-11-28T21:06:40Z|3:05 PM|2026-"*Z ]]

  # 5. P1-1: a worker hit_limit with a future resets_at MUST NOT be wiped by a routine reading
  #    whose account-wide windows are below warn (e.g. monthly spend limit while 7d is 58%).
  local ep5_58 ep7_58 fut_3d
  ep5_58="$(jq -rn '(now | floor) + 7200')"
  ep7_58="$(jq -rn '(now | floor) + 300000')"
  fut_3d="$(jq -rn --argjson e "$ep7_58" '$e | todate')"
  jq --argjson e5 "$ep5_58" --argjson e7 "$ep7_58" \
    '.rate_limits.five_hour.used_percentage = 10.0 | .rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.used_percentage = 58.0 | .rate_limits.seven_day.resets_at = $e7' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine desk --plan max
  cr usage record claude --hit-limit --resets-at "$fut_3d" --message "You've hit your monthly spend limit"
  # Age hit_limit.at by 10 minutes so the next routine reading is clearly newer.
  local older_at; older_at="$(iso_offset -600)"
  jq --arg t "$older_at" '.hit_limit.at = $t' "$CHARTROOM_HOME/usage/desk--claude.json" >"$BATS_TEST_TMPDIR/cl.tmp"
  mv "$BATS_TEST_TMPDIR/cl.tmp" "$CHARTROOM_HOME/usage/desk--claude.json"
  # Re-record the same 58% reading -> hit_limit must STILL hold until resets_at!
  jq --argjson e5 "$ep5_58" --argjson e7 "$ep7_58" \
    '.rate_limits.five_hour.used_percentage = 10.0 | .rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.used_percentage = 58.0 | .rate_limits.seven_day.resets_at = $e7' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine desk --plan max
  run cr usage --agent claude --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].out' <<<"$output")" = true ]
  [ "$(jq -r '.[0].hit_active' <<<"$output")" = true ]
  [ "$(jq -r '.[0].out_resets_at' <<<"$output")" = "$fut_3d" ]
  # Explicit `usage clear` clears the lockout cleanly.
  cr usage clear claude >/dev/null
  run cr usage --agent claude --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].out' <<<"$output")" = false ]

  # 6. P2-2: a transient Claude error:"rate_limit" WITHOUT apiError:"usage_limit_reached" or a limit banner
  #    must NOT mark Claude out of subscription usage.
  cat >"$CLAUDE_CONFIG_DIR/projects/demo-proj/sess-429-transient.jsonl" <<'JSON'
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"API Error: Request rejected (429) · Rate limited, please retry"}]}}
JSON
  run bash -c '
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_claude_transcript_limit sess-429-transient
  '
  [ "$status" -ne 0 ]

  # 7. P3-5: past month/day dates stay in the current year (never lock out for a year),
  #    while Dec -> Jan year boundary rolls cleanly to next year.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    p1="$(usage_parse_reset_iso "Nov 23 at 3am (America/Denver)" 1795700000)"
    p2="$(usage_parse_reset_iso "Jan 2 at 3am (America/Denver)" 1798450000)"
    printf "%s|%s\n" "$p1" "$p2"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "2026-11-23T10:00:00Z|2027-01-02T10:00:00Z" ]

  # 8. P3-4: WARN > LIMIT is rejected by config validation.
  CHARTROOM_USAGE_WARN_PCT=96 CHARTROOM_USAGE_LIMIT_PCT=90 run cr usage --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHARTROOM_USAGE_WARN_PCT"* ]]

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

  # End-to-end watch detection on headless:claude AND headless:codex (with curly apostrophe + error code).
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

  # Headless codex with real curly-apostrophe message + structured usage_limit_reached code.
  cid="$(new_task --backend headless:codex)"
  set_meta "$cid" '.dispatched="2026-11-26T00:00:00Z" | .pid="999998"'
  printf '{"type":"error","code":"usage_limit_reached","message":"You’ve hit your usage limit. Upgrade to Plus to continue using Codex, or try again at %s."}\n' "$fut" \
    >"$CHARTROOM_HOME/tasks/$cid/codex.jsonl"
  run cr watch --once --timeout 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent: out-of-usage: codex resets $fut"* ]]
}

@test "chartroom move switches an exhausted task to another agent while preserving brief, branch, commits, and uncommitted changes" {
  use_fake hc agy
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"

  id="$(new_task --backend hc:claude --model claude-opus-5-5)"
  # Dispatch for real so move exercises stopping a live worker, clearing agent-specific model, and re-dispatching.
  run cr dispatch "$id"
  [ "$status" -eq 0 ]
  old_term="$(meta_of "$id" hc_terminal)"
  [ -n "$old_term" ]
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

  # Move automatically onto codex WITH full stop + re-dispatch (no --no-dispatch).
  # Fake codex has no prompt hook; fake hc marks turn/working on run.
  FAKE_HC_NO_HOOK=1 run cr move "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved $id: hc:claude -> hc:codex"* ]]
  [[ "$output" == *"cleared model=claude-opus-5-5"* ]]

  # Old terminal was stopped/removed; new worker dispatched on hc:codex with model cleared!
  [ ! -f "$FAKE_HC_DIR/terms/$old_term.json" ]
  new_term="$(meta_of "$id" hc_terminal)"
  [ -n "$new_term" ]
  [ "$new_term" != "$old_term" ]
  [ "$(meta_of "$id" backend)" = hc:codex ]
  [ -z "$(meta_of "$id" model)" ]
  [ "$(meta_of "$id" moved_from)" = hc:claude ]
  [ -n "$(meta_of "$id" dispatched)" ]
  # Worktree/branch/commits/uncommitted/untracked/brief all preserved intact.
  [ "$(meta_of "$id" worktree)" = "$wt" ]
  [ "$(meta_of "$id" branch)" = "$branch" ]
  [ "$(git -C "$wt" branch --show-current)" = "$branch" ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$commit_sha" ]
  grep -qxF 'uncommitted edit' "$wt/work.txt"
  grep -qxF 'untracked scratch' "$wt/notes.tmp"
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/brief.md")" = "$brief_before" ]
  grep -q 'Moved from `hc:claude` to `hc:codex`' "$CHARTROOM_HOME/tasks/$id/inbox.md"
  events "$id" | grep -q 'moved from hc:claude to hc:codex'

  # P1-2: `chartroom move` clearing model/effort must NOT leak IFS=", " into cmd_dispatch
  # (otherwise `for i in $(seq 1 5)` inside runner wait loops collapses to 1 iteration).
  ifs_id="$(new_task --backend hc:claude --model claude-opus-5-5)"
  run bash -c '
    export CHARTROOM_HOME="'"$CHARTROOM_HOME"'"
    export CHARTROOM_MACHINE_NAME=desk
    export FAKE_HC_DIR="'"$FAKE_HC_DIR"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/store.sh"'"
    source "'"$REPO_ROOT/lib/agents.sh"'"
    source "'"$REPO_ROOT/lib/spread.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    load_config
    migrating_guard() { :; }
    cmd_resolve() { printf "%s" "$1"; }
    is_joined() { return 1; }
    valid_backend() { return 0; }
    probe_backend() { return 0; }
    cmd_dispatch() {
      local n=0 i
      for i in $(seq 1 5); do n=$((n + 1)); done
      echo "DISPATCH_SEQ_ITERS=$n"
      [ "$n" -eq 5 ]
    }
    cmd_move "'"$ifs_id"'" --agent codex
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISPATCH_SEQ_ITERS=5"* ]]

  # Moving a Codex ship task onto Claude preserves the required non-Claude Opus cold review gate.
  cr usage clear claude >/dev/null
  run cr move "$id" --agent claude --no-dispatch
  [ "$status" -eq 0 ]
  [ "$(meta_of "$id" backend)" = hc:claude ]
  [ "$(meta_of "$id" review_required)" = 1 ]
  set_meta "$id" '.dispatched="2026-11-26T00:00:00Z"'
  cr event "$id" done 'finished after move to claude'
  [ "$(meta_of "$id" review_pending)" = 1 ]
  run cr accept "$id"
  [ "$status" -ne 0 ]
}

@test "dashboard JSON and HTML expose subscription usage with per-machine dispatched live worker counts" {
  local ep5; ep5="$(jq -rn '(now | floor) + 5400')"
  jq --argjson e5 "$ep5" '.rate_limits.five_hour.used_percentage = 82.0 | .rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.used_percentage = 44.0 | .rate_limits.seven_day.resets_at = ($e5 + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine desk --plan max_20x
  jq --argjson e5 "$ep5" '.rate_limits.five_hour.used_percentage = 12.0 | .rate_limits.five_hour.resets_at = $e5 | .rate_limits.seven_day.used_percentage = 15.0 | .rate_limits.seven_day.resets_at = ($e5 + 86400)' \
    "$REPO_ROOT/test/fixtures/usage/claude-statusline.json" | cr usage record claude --machine mini --plan max_20x

  # Undispatched draft must NOT count as a live worker; dispatched local tasks count ONLY on desk (not mini).
  new_task --backend hc:claude >/dev/null
  t_live1="$(new_task --backend hc:claude)"
  t_live2="$(new_task --backend hc:claude)"
  set_meta "$t_live1" '.dispatched="2026-11-26T00:00:00Z"'
  set_meta "$t_live2" '.dispatched="2026-11-26T00:00:00Z"'

  run cr dashboard --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.usage[] | select(.agent=="claude" and .machine=="desk") | .state' <<<"$output")" = near ]
  [ "$(jq -r '.usage[] | select(.agent=="claude" and .machine=="desk") | .live_workers' <<<"$output")" = 2 ]
  [ "$(jq -r '.usage[] | select(.agent=="claude" and .machine=="mini") | .live_workers' <<<"$output")" = 0 ]
  [ "$(jq -r '.usage[] | select(.agent=="claude" and .machine=="desk") | .plan' <<<"$output")" = max_20x ]

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
  #    Must read account-wide 7d 58% used / 42% left (state=ok, out=false) while keeping 7d opus
  #    as an informational scoped window (`scoped: true`, excluded from out/near).
  jq --arg r7 "$fut7" \
    '.seven_day.resets_at = $r7 | .seven_day_opus.resets_at = $r7 | .limits |= map(.resets_at = $r7)' \
    "$REPO_ROOT/test/fixtures/usage/claude-oauth-api-real.json" >"$BATS_TEST_TMPDIR/claude-real.json"
  CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-real.json" CHARTROOM_CLAUDE_PLAN=max_20x \
    run cr usage --agent claude --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].state' <<<"$output")" = ok ]
  [ "$(jq -r '.[0].out' <<<"$output")" = false ]
  [ "$(jq '[.[0].windows[] | select(.scoped != true)] | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].windows[] | select(.label=="7d") | [.used_pct,.left_pct,.scoped] | @csv' <<<"$output")" = '58,42,false' ]
  [ "$(jq -r '.[0].windows[] | select(.label=="7d opus") | [.used_pct,.left_pct,.scoped] | @csv' <<<"$output")" = '99,1,true' ]

  # Also when top-level seven_day is null, limits[] fallback uses only active scope==null buckets
  # for exhaustion (out=false, state=ok) while keeping scoped buckets informational (`scoped: true`).
  jq '.seven_day = null' "$BATS_TEST_TMPDIR/claude-real.json" >"$BATS_TEST_TMPDIR/claude-limits-only.json"
  CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-limits-only.json" CHARTROOM_CLAUDE_PLAN=max_20x \
    run cr usage --agent claude --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].state' <<<"$output")" = ok ]
  [ "$(jq -r '.[0].out' <<<"$output")" = false ]
  [ "$(jq '[.[0].windows[] | select(.scoped != true)] | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].windows[] | select(.label=="7d") | [.used_pct,.left_pct,.scoped] | @csv' <<<"$output")" = '58,42,false' ]

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
  #    using the enrolled device NAME ("studio-node") even when it differs from hostname ("mini"),
  #    and `node probe` emits it read-only.
  mkdir -p "$HOME/.config/chartroom"
  echo "CHARTROOM_DEVICE_NAME=studio-node" >"$HOME/.config/chartroom/device"
  jq -c --arg ts "$now_iso" --argjson e5 "$ep5" \
    'select(.payload.rate_limits? != null) | .timestamp = $ts | .payload.rate_limits.primary.used_percent = 97.0 | .payload.rate_limits.primary.resets_at = $e5 | .payload.rate_limits.secondary = null' \
    "$REPO_ROOT/test/fixtures/usage/codex-session.jsonl" | head -n 1 >"$CODEX_HOME/sessions/2026/11/26/rollout-node.jsonl"

  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node usage-refresh
  [ "$status" -eq 0 ]
  [ -f "$XDG_STATE_HOME/chartroom/usage/studio-node--codex.json" ]
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'usage\tcodex\tok\tpro\tchatgpt'* ]]
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" run cr node probe --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.usage.codex.out' <<<"$output")" = true ]

  # 2. Guest-side `node usage-look` detects an idle guest worker's limit stop, logs out-of-usage
  #    with the device NAME, and mirrors hit_limit into $XDG_STATE_HOME/chartroom/usage with
  #    local=true so the node's next probe reports claude as out.
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
  events "$gid" | grep -q "agent: out-of-usage: claude on studio-node resets $fut5"
  [ -f "$XDG_STATE_HOME/chartroom/usage/studio-node--claude.json" ]
  [ "$(jq -r '.local' "$XDG_STATE_HOME/chartroom/usage/studio-node--claude.json")" = true ]
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

@test "re-dispatch of auto tasks skips out agents, node wakes list fleet agents, clock resets and move pre-checks hold, pid uses BASHPID, and account labels stay non-identifying" {
  use_fake hc agy
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR"
  core_up
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"

  local fut ep_fut now_iso
  ep_fut="$(jq -rn '(now | floor) + 3600')"
  fut="$(jq -rn --argjson e "$ep_fut" '$e | todate')"
  now_iso="$(iso_offset 0)"

  # P2-1: Re-dispatching an already-dispatched automatic task whose stored agent is now out
  # must NOT silently re-dispatch onto the exhausted agent; it switches to another available agent,
  # and refuses when no other signed-in full-session agent is available.
  local rid
  rid="$(new_task)"
  set_meta "$rid" '.backend="hc:codex" | .backend_source="auto" | .dispatched="2026-11-26T00:00:00Z"'
  cr usage record codex --hit-limit --resets-at "$fut" --message "You've hit your usage limit"
  run cr dispatch "$rid" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"switching to hc:agy"* ]]
  [[ "$output" == *"would run here, as hc:agy"* ]]
  [[ "$output" == *"$fut"* ]]
  # When all other local agents are also out, re-dispatch refuses rather than sending work to codex.
  cr usage record agy --hit-limit --resets-at "$fut" --message "Usage limit reached"
  cr usage record claude --hit-limit --resets-at "$fut" --message "You've hit your weekly limit"
  run cr dispatch "$rid" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot re-dispatch $rid on hc:codex"* ]]
  [[ "$output" == *"$fut"* ]]
  cr usage clear codex >/dev/null
  cr usage clear agy >/dev/null
  cr usage clear claude >/dev/null
  cr close "$rid" >/dev/null

  # P3-1: A node's out-of-usage event scanned by the brain's watch rewrites `available:` to
  # reflect the brain's fleet-wide view (including the brain's local agents), not just the node's.
  local nid
  nid="$(new_task --backend node:claude)"
  set_meta "$nid" '.dispatched="2026-11-26T00:00:00Z" | .node="dev-mini" | .node_name="mini" | .node_backend="hc:claude"'
  printf '%s agent: out-of-usage: claude on mini resets %s; available: none (move with: chartroom move %s)\n' \
    "$now_iso" "$fut" "$nid" >>"$CHARTROOM_HOME/tasks/$nid/events.log"
  run cr watch --once --timeout 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"out-of-usage: claude on mini resets $fut; available: "*"codex"* ]]
  [[ "$output" == *"(move with: chartroom move $nid)"* ]]
  # Brain also recorded claude as out on mini (not on desk).
  run cr usage --agent claude --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.machine=="mini") | .out' <<<"$output")" = true ]
  set_meta "$nid" '.closed="2026-11-26T00:00:00Z"'

  # P3-2: A clock-only reset seen after that hour stays in the past (already reset) instead of
  # rolling +1 day into a ~23h lockout, while an overnight wrap (>6h behind, e.g. 11pm -> 3am)
  # still rolls to tomorrow; Codex's ordinal date + year shape also parses cleanly.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    # 1795734000 = 2026-11-26T23:00:00Z = 4:00 PM America/Denver -> 3pm already passed 1h ago
    p_past="$(usage_parse_reset_iso "3pm (America/Denver)" 1795734000)"
    # 1795759200 = 2026-11-27T06:00:00Z = 11:00 PM America/Denver -> 3am is 4h ahead tomorrow
    p_wrap="$(usage_parse_reset_iso "3am (America/Denver)" 1795759200)"
    # Codex ordinal date + year
    p_ord="$(usage_parse_reset_iso "Nov 30th, 2026 3:05 PM (UTC)" 1795700000)"
    printf "%s|%s|%s\n" "$p_past" "$p_wrap" "$p_ord"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "2026-11-26T22:00:00Z|2026-11-27T10:00:00Z|2026-11-30T15:05:00Z" ]

  # P3-3: `chartroom move --node mini --agent codex` checks mini's usage BEFORE touching anything.
  export CHARTROOM_FLEET_DIR="$BATS_TEST_TMPDIR/fleet"
  mkdir -p "$CHARTROOM_FLEET_DIR/devices"
  jq -cn '{id:"n-111111111111",name:"mini",aliases:[],host:"mini.local",enrolled:1795700000}' \
    >"$CHARTROOM_FLEET_DIR/devices/n-111111111111.json"
  jq -cn --argjson ls "$(date +%s)" \
    '{last_seen:$ls,caps:["dispatch","place"],probe:"runner\thc\tup\ntool\tcodex\tok\nlogin\tcodex\tok\n"}' \
    >"$CHARTROOM_FLEET_DIR/devices/n-111111111111.seen.json"
  cr homes add test "$CHARTROOM_HOME" >/dev/null
  # codex is ok on desk, but out on mini.
  cr usage record codex --machine mini --hit-limit --resets-at "$fut" --message "You've hit your usage limit"
  local uid
  uid="$(new_task --backend hc:claude --kind scout)"
  run cr move "$uid" --node mini --agent codex --no-dispatch
  [ "$status" -ne 0 ]
  [[ "$output" == *"codex on mini is out of usage"* ]]
  [ "$(meta_of "$uid" backend)" = hc:claude ]
  [ -z "$(meta_of "$uid" node)" ]
  cr close "$uid" >/dev/null

  # P1-1: `chartroom move --node mini` on a started local task with commits/edits MUST refuse
  # even when codex IS available on mini (remote dispatch starts from base_sha and would strand
  # local commits/edits), leaving the old worker untouched.
  cr usage clear codex --machine mini >/dev/null
  local mid old_term mwt msha
  mid="$(new_task --backend hc:claude)"
  run cr dispatch "$mid"
  [ "$status" -eq 0 ]
  old_term="$(meta_of "$mid" hc_terminal)"
  mwt="$(meta_of "$mid" worktree)"
  [ -n "$old_term" ]
  [ -f "$FAKE_HC_DIR/terms/$old_term.json" ]
  echo 'local work' >"$mwt/local.txt"
  git -C "$mwt" add local.txt
  git -C "$mwt" commit -qm 'feat: local commit that must not be stranded'
  msha="$(git -C "$mwt" rev-parse HEAD)"
  echo 'uncommitted wip' >>"$mwt/local.txt"

  run cr move "$mid" --node mini --agent codex --no-dispatch
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot move"* ]]
  # Old worker was NOT stopped, metadata NOT cleared, and commits/edits intact!
  [ -f "$FAKE_HC_DIR/terms/$old_term.json" ]
  [ "$(meta_of "$mid" hc_terminal)" = "$old_term" ]
  [ -n "$(meta_of "$mid" dispatched)" ]
  [ "$(meta_of "$mid" backend)" = hc:claude ]
  [ -z "$(meta_of "$mid" node)" ]
  [ "$(git -C "$mwt" rev-parse HEAD)" = "$msha" ]
  grep -qxF 'uncommitted wip' "$mwt/local.txt"

  # P3-4: Background `usage_device_refresh 0` records subshell $BASHPID (not parent $$) in .refresh.pid.
  run bash -c '
    export XDG_STATE_HOME="'"$XDG_STATE_HOME"'"
    export CHARTROOM_MACHINE_NAME=mini
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    CR_USAGE_REFRESH_MIN=5
    usage_refresh_local() { sleep 0.4; }
    parent_pid=$$
    usage_device_refresh 0
    pf="$XDG_STATE_HOME/chartroom/usage/.refresh.pid"
    for _ in $(seq 1 30); do [[ -s "$pf" ]] && break; sleep 0.02; done
    got="$(cat "$pf" 2>/dev/null || true)"
    wait 2>/dev/null || true
    echo "parent=$parent_pid got=$got"
    [[ "$got" =~ ^[0-9]+$ && "$got" != "$parent_pid" ]]
  '
  [ "$status" -eq 0 ]

  # P3-5: Non-identifying account labels distinguish separate subscriptions without storing raw IDs,
  # split identical-percentage readings across machines, and honor CHARTROOM_USAGE_ACCOUNT_<AGENT>.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    a1="$(usage_account_label claude claude.ai "org-11111111-aaaa")"
    a2="$(usage_account_label claude claude.ai "org-22222222-bbbb")"
    a3="$(CHARTROOM_USAGE_ACCOUNT_CLAUDE=personal usage_account_label claude claude.ai "org-11111111-aaaa")"
    printf "%s|%s|%s\n" "$a1" "$a2" "$a3"
    [[ "$a1" =~ ^claude\.ai\ #[0-9a-f]{6}$ ]]
    [[ "$a2" =~ ^claude\.ai\ #[0-9a-f]{6}$ ]]
    [[ "$a1" != "$a2" ]]
    [[ "$a1" != *"org-11111111"* && "$a2" != *"org-22222222"* ]]
    [[ "$a3" == "personal" ]]
  '
  [ "$status" -eq 0 ]

  # Two machines with identical Codex percentages/plan but different accountIds split into 2 rows
  # with distinct non-identifying `chatgpt #<6-hex>` labels and zero raw UUIDs on disk.
  jq --argjson e "$ep_fut" \
    '.accountId = "acct-aaaa-1111" | .rateLimits.primary.resetsAt = $e | .rateLimitsByLimitId.codex.primary.resetsAt = $e' \
    "$REPO_ROOT/test/fixtures/usage/codex-appserver-ratelimits.json" | cr usage record codex --machine desk
  jq --argjson e "$ep_fut" \
    '.accountId = "acct-bbbb-2222" | .rateLimits.primary.resetsAt = $e | .rateLimitsByLimitId.codex.primary.resetsAt = $e' \
    "$REPO_ROOT/test/fixtures/usage/codex-appserver-ratelimits.json" | cr usage record codex --machine mini
  ! grep -qiE 'acct-aaaa-1111|acct-bbbb-2222|accountId' "$CHARTROOM_HOME/usage/desk--codex.json" "$CHARTROOM_HOME/usage/mini--codex.json"
  run cr usage --agent codex --json
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.[0].account' <<<"$output")" != "$(jq -r '.[1].account' <<<"$output")" ]
  [[ "$(jq -r '.[0].account' <<<"$output")" =~ ^chatgpt\ #[0-9a-f]{6}$ ]]
}

@test "quoted limit banners in idle prose never trigger lockouts, wrapped Codex banners keep reset times, scoped Claude buckets display without marking out, and headless/tmux fallback appears in available list" {
  # P2-1a: Claude with a readable session transcript showing a normal reply must trust the
  # transcript and NEVER fall back to screen matching even if the screen quotes a limit banner.
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/demo-proj"
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I documented the banner."}]}}' \
    >"$CLAUDE_CONFIG_DIR/projects/demo-proj/sess-normal-9999.jsonl"
  local tid
  tid="$(new_task --backend hc:claude)"
  set_meta "$tid" '.dispatched="2026-11-26T00:00:00Z" | .session_id="sess-normal-9999"'
  run bash -c '
    export CHARTROOM_HOME="'"$CHARTROOM_HOME"'"
    export CLAUDE_CONFIG_DIR="'"$CLAUDE_CONFIG_DIR"'"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/store.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    load_config
    usage_limit_look "'"$tid"'" hc claude "You'\''ve hit your limit · resets 3pm" idle desk
  '
  [ "$status" -eq 0 ]
  ! events "$tid" | grep -q 'out-of-usage'
  [ ! -f "$CHARTROOM_HOME/usage/desk--claude.json" ]

  # P2-1b: Idle prose-continuation screens (both indented and col-0 wrapped) quoting limit banners
  # must NOT match for claude, codex, or agy.
  local scr_cl scr_cl0 scr_cx scr_ag scr_ag0 scr_wrap
  scr_cl=$'● I updated the docs. The message users see is:\n  You'\''ve hit your limit · resets 3pm\n❯ \n? for help'
  scr_cl0=$'● I updated the docs. The message users see is:\nYou'\''ve hit your limit · resets 3pm\n❯ '
  scr_cx=$'• Added the limit banner test. Codex prints this when it stops:\n  You'\''ve hit your usage limit. Upgrade to Pro or try again at 3:05 PM.\n› Ask Codex to do anything'
  scr_ag=$'✦ Done. The quota error reads:\n  Usage limit reached. Try again later.'
  scr_ag0=$'✦ Done. The quota error reads:\nUsage limit reached. Try again later.'
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    ! usage_screen_limit claude "$1" screen
    ! usage_screen_limit claude "$2" screen
    ! usage_screen_limit codex "$3" screen
    ! usage_screen_limit agy "$4" screen
    ! usage_screen_limit agy "$5" screen
  ' _ "$scr_cl" "$scr_cl0" "$scr_cx" "$scr_ag" "$scr_ag0"
  [ "$status" -eq 0 ]

  # P3-1: A real Codex ■ limit banner wrapped across two lines preserves its reset time.
  scr_wrap=$'■ You'\''ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit\nhttps://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:05 PM.'
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_screen_limit codex "$1" screen
  ' _ "$scr_wrap"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"3:05 PM" ]]

  # P3-2: Real redacted Claude response includes scoped 7d opus (99%) as an informational window
  # (scoped=true) so dashboard/CLI show it while account-wide state stays ok (out=false).
  local fut7; fut7="$(iso_offset 320000)"
  jq --arg r7 "$fut7" \
    '.seven_day.resets_at = $r7 | .seven_day_opus.resets_at = $r7 | .limits |= map(.resets_at = $r7)' \
    "$REPO_ROOT/test/fixtures/usage/claude-oauth-api-real.json" >"$BATS_TEST_TMPDIR/claude-real-scoped.json"
  CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-real-scoped.json" CHARTROOM_CLAUDE_PLAN=max_20x \
    run cr usage --agent claude --json --refresh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].state' <<<"$output")" = ok ]
  [ "$(jq -r '.[0].out' <<<"$output")" = false ]
  [ "$(jq -r '.[0].windows[] | select(.label=="7d") | [.used_pct,.left_pct,.scoped] | @csv' <<<"$output")" = '58,42,false' ]
  [ "$(jq -r '.[0].windows[] | select(.label=="7d opus") | [.used_pct,.left_pct,.scoped] | @csv' <<<"$output")" = '99,1,true' ]

  # P3-4: On a machine without hc/herdr (headless/tmux only), usage_available_agents still lists
  # usable fallback agents instead of saying none.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/codex"
  printf '#!/usr/bin/env bash\necho '\''{"loggedIn":true}'\''\n' >"$BIN/claude"
  chmod +x "$BIN/codex" "$BIN/claude"
  run bash -c '
    export PATH="'"$BIN"':$PATH"
    export CHARTROOM_HOME="'"$CHARTROOM_HOME"'"
    export CHARTROOM_MACHINE_NAME=desk
    export CHARTROOM_BACKEND_ORDER="headless:codex headless:claude"
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/agents.sh"'"
    source "'"$REPO_ROOT/lib/spread.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    load_config
    spread_local_backends() { :; }
    probe_backend() { [[ "$1" == headless:codex || "$1" == headless:claude ]]; }
    usage_available_agents claude desk
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex"* ]]
}

# Judge one stored reading as the machine holding it does (lib/usage.sh eval_rec, default thresholds).
local_verdict() { # <record file>
  bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    jq -c --argjson now "$(date +%s)" "$USAGE_EVAL_JQ"'"'"'eval_rec($now; 95; 80; 1800; 3600)
      | {state, out, limit_reached: (.limit_reached == true), hit_active}'"'"' "$1"' _ "$1"
}

# Give the brain a heartbeat from enrolled node "mini" carrying <probe output>, heard at [epoch].
heartbeat_from_mini() { # <probe output file> [last_seen epoch]
  export CHARTROOM_FLEET_DIR="$BATS_TEST_TMPDIR/fleet"
  mkdir -p "$CHARTROOM_FLEET_DIR/devices"
  jq -cn '{id:"n-222222222222",name:"mini",aliases:[],host:"mini.local",enrolled:1795700000}' \
    >"$CHARTROOM_FLEET_DIR/devices/n-222222222222.json"
  jq -cn --rawfile p "$1" --argjson ls "${2:-$(date +%s)}" '{last_seen:$ls,caps:["dispatch","place"],probe:$p}' \
    >"$CHARTROOM_FLEET_DIR/devices/n-222222222222.seen.json"
  # the endpoint hearing it, as the app server leaves it (lib/fleet.sh asks ps that it is one)
  if [[ ! -f "$BATS_TEST_TMPDIR/ep.pid" ]]; then
    bash -c 'exec -a "python3 lib/app/server.py" sleep 300' 3>&- &
    echo $! >"$BATS_TEST_TMPDIR/ep.pid"
    echo "$! $(( $(date +%s) - 3600 ))" >"$CHARTROOM_FLEET_DIR/endpoint"
  fi
}

@test "a reading taken on a node reaches the brain with every flag intact for claude, codex and agy" {
  local ep7 node_usage="$XDG_STATE_HOME/chartroom/usage" a nv bv sv
  ep7="$(jq -rn '(now | floor) + 320000')"
  export CHARTROOM_NODES=none CHARTROOM_NODE_CONFIG="$BATS_TEST_TMPDIR/nodecfg/node"

  # The node "mini" reads its own agents from the real redacted samples:
  #  - claude: account-wide 7d 58%, Opus-only weekly bucket 99% (scoped: never locks the account)
  #  - codex:  app-server 26% used, but ordinaryUsageAllowed=false and rateLimitReachedType set
  #  - agy:    100% left on every bucket
  jq --argjson e "$ep7" '(.seven_day.resets_at, .seven_day_opus.resets_at) = ($e | todate) | .limits |= map(.resets_at = ($e | todate))' \
    "$REPO_ROOT/test/fixtures/usage/claude-oauth-api-real.json" >"$BATS_TEST_TMPDIR/claude-real.json"
  jq --argjson e "$ep7" '.ordinaryUsageAllowed = false
      | (.rateLimits, .rateLimitsByLimitId.codex) |= (.rateLimitReachedType = "rate_limit_reached" | .primary.resetsAt = $e)' \
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
fi
exit 0
EOF
  cat >"$BIN/agy" <<EOF
#!/usr/bin/env bash
[[ "\$*" == *"-p=/usage"* ]] && cat "$REPO_ROOT/test/fixtures/usage/agy-usage.json"
exit 0
EOF
  chmod +x "$BIN/codex" "$BIN/agy"
  CHARTROOM_CLAUDE_USAGE_FILE="$BATS_TEST_TMPDIR/claude-real.json" CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" \
    run cr node usage-refresh
  [ "$status" -eq 0 ]
  # agy: a worker stopped at its limit two minutes ago with no reset time it could read (the
  # record a guest's `node usage-look` leaves: hit_limit with resets_at null, within the cooldown)
  jq --arg at "$(iso_offset -120)" '.hit_limit = {at: $at, resets_at: null, resets_text: null, task: "t1", message: "limit"}' \
    "$node_usage/mini--agy.json" >"$BATS_TEST_TMPDIR/agy.json" && mv "$BATS_TEST_TMPDIR/agy.json" "$node_usage/mini--agy.json"

  # What the node itself makes of each reading.
  [ "$(local_verdict "$node_usage/mini--claude.json")" = '{"state":"ok","out":false,"limit_reached":false,"hit_active":false}' ]
  [ "$(local_verdict "$node_usage/mini--codex.json")" = '{"state":"out","out":true,"limit_reached":true,"hit_active":false}' ]
  [ "$(local_verdict "$node_usage/mini--agy.json")" = '{"state":"out","out":true,"limit_reached":false,"hit_active":true}' ]

  # Its heartbeat carries them as the brain will read them.
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" cr node probe >"$BATS_TEST_TMPDIR/probe.out"
  grep -q $'^usage\tclaude\tok\t.*7d opus:99:[0-9]*:s' "$BATS_TEST_TMPDIR/probe.out"
  grep -q $'^usage\tcodex\tok\t.*\t1\t-$' "$BATS_TEST_TMPDIR/probe.out"
  grep -qE $'^usage\tagy\tok\t.*\t-\t0\t[0-9]+$' "$BATS_TEST_TMPDIR/probe.out"
  heartbeat_from_mini "$BATS_TEST_TMPDIR/probe.out"

  # 1. Before any sync, `nodes` judges the heartbeat itself the same way.
  run cr nodes --json
  [ "$status" -eq 0 ]
  for a in claude codex agy; do
    nv="$(jq -c --arg a "$a" '.nodes[] | select(.machine == "mini") | .usage[$a]
      | {state, out, limit_reached, hit_active}' <<<"$output")"
    [ "$nv" = "$(local_verdict "$node_usage/mini--$a.json")" ]
  done
  [ "$(jq -r '.nodes[] | select(.machine == "mini") | .usage.claude.windows[] | select(.label == "7d opus") | .scoped' <<<"$output")" = true ]
  run cr nodes
  [[ "$output" == *"mini: codex reached usage limit"* ]]
  [[ "$output" == *"mini: agy hit usage limit"* ]]
  [[ "$output" != *"mini: claude"* ]]

  # 2. After the brain syncs the heartbeat, its own stored readings agree too.
  run cr usage --json
  [ "$status" -eq 0 ]
  for a in claude codex agy; do
    [ "$(local_verdict "$CHARTROOM_HOME/usage/mini--$a.json")" = "$(local_verdict "$node_usage/mini--$a.json")" ]
  done
  [ "$(jq -r '.windows[] | select(.label == "7d opus") | .scoped' "$CHARTROOM_HOME/usage/mini--claude.json")" = true ]
  [ "$(jq -r '.hit_limit.at' "$CHARTROOM_HOME/usage/mini--agy.json")" = "$(jq -r '.hit_limit.at' "$node_usage/mini--agy.json")" ]
  # and placing work on mini skips exactly the out agents
  run cr nodes --json
  [ "$(jq -r '.nodes[] | select(.machine == "mini") | [.usage.claude.out, .usage.codex.out, .usage.agy.out] | @csv' <<<"$output")" = 'false,true,true' ]

  # 3. A stop with no reset expires after the cooldown on the node and the brain alike.
  jq --arg at "$(iso_offset -7200)" '.hit_limit.at = $at' "$node_usage/mini--agy.json" >"$BATS_TEST_TMPDIR/agy.json" \
    && mv "$BATS_TEST_TMPDIR/agy.json" "$node_usage/mini--agy.json"
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" cr node probe >"$BATS_TEST_TMPDIR/probe.out"
  heartbeat_from_mini "$BATS_TEST_TMPDIR/probe.out"
  [ "$(local_verdict "$node_usage/mini--agy.json" | jq -r .out)" = false ]
  run cr nodes --json
  [ "$(jq -r '.nodes[] | select(.machine == "mini") | .usage.agy.out' <<<"$output")" = false ]
  cr usage --json >/dev/null
  [ "$(local_verdict "$CHARTROOM_HOME/usage/mini--agy.json" | jq -r .out)" = false ]

  # 4. A stop cleared on the node clears on the brain; one the brain heard after that heartbeat stays.
  jq 'del(.hit_limit)' "$node_usage/mini--agy.json" >"$BATS_TEST_TMPDIR/agy.json" && mv "$BATS_TEST_TMPDIR/agy.json" "$node_usage/mini--agy.json"
  CHARTROOM_MACHINE_NAME=mini CHARTROOM_HOME="" cr node probe >"$BATS_TEST_TMPDIR/probe.out"
  heartbeat_from_mini "$BATS_TEST_TMPDIR/probe.out"
  cr usage --json >/dev/null
  [ "$(jq -r '.hit_limit' "$CHARTROOM_HOME/usage/mini--agy.json")" = null ]
  heartbeat_from_mini "$BATS_TEST_TMPDIR/probe.out" "$(( $(date +%s) - 30 ))"
  cr usage record agy --machine mini --hit-limit --message "You've hit your usage limit"
  run cr nodes --json
  [ "$(jq -r '.nodes[] | select(.machine == "mini") | .usage.agy.out' <<<"$output")" = true ]
  cr usage --json >/dev/null
  [ "$(local_verdict "$CHARTROOM_HOME/usage/mini--agy.json" | jq -r .out)" = true ]

  # 5. A node still on the older nine-field line is read as before (no flags), never misread.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_from_probe_line mini "$(printf "usage\tcodex\tok\tpro\tchatgpt\t2026-11-26T22:00:00Z\t7d:26:4100500000\t-\t-")"'
  [ "$status" -eq 0 ]
  [ "$(jq -c '{limit_reached, hit_limit, w: .windows[0] | [.label, .used_pct, (.scoped // false)]}' <<<"$output")" = '{"limit_reached":false,"hit_limit":null,"w":["7d",26,false]}' ]
}

@test "one out-of-usage wake per limit stop, raised again once the worker resumed and stopped anew" {
  use_fake hc
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$FAKE_HC_DIR/terms"
  core_up
  local id fut1 fut2 n
  fut1="$(iso_offset 7200)"; fut2="$(iso_offset 9000)"
  id="$(new_task --backend hc:codex)"
  set_meta "$id" '.dispatched="2026-11-26T00:00:00Z" | .hc_terminal="t-w" | .hc_launched="1"'
  term() { # <state>
    jq -cn --arg id "$id" --arg l "$CHARTROOM_HOME/tasks/$id/launch.sh" --arg st "$1" \
      '{address:"t-w",name:$id,state:"live",argv:["bash",$l],status:{app:"codex",state:$st}}' >"$FAKE_HC_DIR/terms/t-w.json"
  }
  wakes() { events "$id" | grep -c 'agent: out-of-usage: codex' || true; }
  term idle
  printf "■ You've hit your usage limit. Try again at %s.\n› \n" "$fut1" >"$FAKE_HC_DIR/screen.t-w"
  # The same stop, seen on three looks: one wake.
  for n in 1 2 3; do cr watch --once --timeout 1 >/dev/null 2>&1 || true; done
  [ "$(wakes)" -eq 1 ]
  # Resumed without a steer (keys sent through hc), seen working, then stopped again: a second wake.
  term working
  printf "working...\n" >"$FAKE_HC_DIR/screen.t-w"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  term idle
  printf "■ You've hit your usage limit. Try again at %s.\n› \n" "$fut1" >"$FAKE_HC_DIR/screen.t-w"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  [ "$(wakes)" -eq 2 ]
  # A stop with another reset time, even unseen working between looks: a third.
  printf "■ You've hit your usage limit. Try again at %s.\n› \n" "$fut2" >"$FAKE_HC_DIR/screen.t-w"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  [ "$(wakes)" -eq 3 ]
}

@test "the brain's background usage refresh never runs twice at once" {
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$BATS_TEST_TMPDIR/slow-chartroom"
  chmod +x "$BATS_TEST_TMPDIR/slow-chartroom"
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    CR_HOME="'"$CHARTROOM_HOME"'" CR_BIN="'"$BATS_TEST_TMPDIR/slow-chartroom"'" CR_USAGE_REFRESH_MIN=5
    usage_watch_refresh; first="$(cat "$CR_HOME/usage/.watch-refresh.pid")"
    USAGE_WATCH_NEXT=0; usage_watch_refresh; second="$(cat "$CR_HOME/usage/.watch-refresh.pid")"
    kill "$first" 2>/dev/null; wait "$first" 2>/dev/null
    USAGE_WATCH_NEXT=0; usage_watch_refresh; third="$(cat "$CR_HOME/usage/.watch-refresh.pid")"
    kill "$third" 2>/dev/null
    [[ "$first" == "$second" && "$third" != "$first" ]] && echo guarded'
  [ "$status" -eq 0 ]
  [ "$output" = guarded ]
}

@test "a clock-only reset is read from when the stop can have happened, so a stop first seen hours late never locks a healthy agent out" {
  use_fake hc
  export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc" TZ=UTC
  mkdir -p "$FAKE_HC_DIR/terms"
  core_up
  local now clk today tomorrow late live
  now="$(date +%s)"
  # Codex prints a clock-only reset in local time ("try again at 3:05 AM"): one 8 hours ago, today.
  clk="$(jq -rn --argjson e "$((now - 28800))" '$e | strftime("%I:%M %p")')"
  today="$(jq -rn --argjson e "$((now - 28800))" '$e | strftime("%Y-%m-%dT%H:%M:00Z")')"
  tomorrow="$(jq -rn --argjson e "$((now - 28800 + 86400))" '$e | strftime("%Y-%m-%dT%H:%M:00Z")')"
  worker() { # <id> <address> <state>
    jq -cn --arg id "$1" --arg l "$CHARTROOM_HOME/tasks/$1/launch.sh" --arg a "$2" --arg st "$3" \
      '{address:$a,name:$id,state:"live",argv:["bash",$l],status:{app:"codex",state:$st}}' >"$FAKE_HC_DIR/terms/$2.json"
  }
  banner() { printf "■ You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro) or try again at %s.\n› \n" "$clk" >"$FAKE_HC_DIR/screen.$1"; }

  # 1. Dispatched 12 hours ago and not looked at since (the watch was closed, the machine asleep): the
  #    stop can have come before that reset, so it is not read as tomorrow's.
  late="$(new_task --backend hc:codex)"
  set_meta "$late" ".dispatched=\"$(jq -rn --argjson e "$((now - 43200))" '$e | todate')\" | .hc_terminal=\"t-late\" | .hc_launched=\"1\""
  worker "$late" t-late idle; banner t-late
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  events "$late" | grep -q 'agent: out-of-usage: codex'
  [ "$(jq -r '.hit_limit.resets_at' "$CHARTROOM_HOME/usage/desk--codex.json")" = "$today" ]
  [ "$(local_verdict "$CHARTROOM_HOME/usage/desk--codex.json" | jq -r .out)" = false ]
  cr close "$late" >/dev/null

  # 2. Seen working a minute ago and stopped since: that same time is tomorrow's, and codex is out.
  live="$(new_task --backend hc:codex)"
  set_meta "$live" ".dispatched=\"$(jq -rn --argjson e "$((now - 43200))" '$e | todate')\" | .hc_terminal=\"t-live\" | .hc_launched=\"1\""
  worker "$live" t-live working; printf 'working...\n' >"$FAKE_HC_DIR/screen.t-live"
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  worker "$live" t-live idle; banner t-live
  cr watch --once --timeout 1 >/dev/null 2>&1 || true
  events "$live" | grep -q 'agent: out-of-usage: codex'
  [ "$(jq -r '.hit_limit.resets_at' "$CHARTROOM_HOME/usage/desk--codex.json")" = "$tomorrow" ]
  [ "$(local_verdict "$CHARTROOM_HOME/usage/desk--codex.json" | jq -r .out)" = true ]

  # 3. A stop whose time is known (a Claude transcript entry) is read from that time exactly.
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    # 1795759200 = 23:00 Denver; read at 09:30 Denver the next day (1795797000)
    printf "%s|%s\n" "$(usage_parse_reset_iso "3am (America/Denver)" 1795797000 1795759200)" \
      "$(usage_parse_reset_iso "in 2 hours" 1795797000 1795759200)"'
  [ "$output" = "2026-11-27T10:00:00Z|2026-11-27T08:00:00Z" ]
}

@test "re-dispatching an automatic task placed on a node never goes back onto that node's exhausted agent" {
  export CHARTROOM_NODES=none CHARTROOM_NODE_CONFIG="$BATS_TEST_TMPDIR/nodecfg/node"
  local id fut a
  id="$(new_task)"
  cr homes add test "$CHARTROOM_HOME" >/dev/null
  printf 'runner\thc\tup\n' >"$BATS_TEST_TMPDIR/probe.out"
  for a in claude codex; do printf 'tool\t%s\tok\t1.0\nlogin\t%s\tok\t-\n' "$a" "$a" >>"$BATS_TEST_TMPDIR/probe.out"; done
  heartbeat_from_mini "$BATS_TEST_TMPDIR/probe.out"
  fut="$(iso_offset 7200)"
  # As placement leaves it (lib/place.sh): the node's agent marked explicit, the task's own choice kept.
  set_meta "$id" '.backend="node:claude" | .backend_source="explicit" | .node_source="auto" | .node_placed="1"
    | .node="n-222222222222" | .node_name="mini" | .node_backend="hc:claude" | .dispatched="2026-11-26T00:00:00Z"'
  cr usage record claude --machine mini --hit-limit --resets-at "$fut" --message "You've hit your usage limit"

  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"switching to node:codex"* ]]
  [[ "$output" != *"chosen explicitly"* ]]

  cr usage record codex --machine mini --hit-limit --resets-at "$fut" --message "You've hit your usage limit"
  run cr dispatch "$id" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot re-dispatch $id on node:claude (mini)"* ]]

  # A node backend the commander chose is still theirs: it warns and goes ahead.
  set_meta "$id" '.node_source="explicit"'
  run cr dispatch "$id" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"proceeding because --backend was chosen explicitly"* ]]
}

@test "an agent's own error text never keeps an email, and an older stop on a heartbeat never replaces a newer one the brain heard" {
  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    usage_unknown_record agy mini true agy-usage "Print mode: authenticated as someone@example.com" | jq -r .reason'
  [ "$output" = "Print mode: authenticated as <email>" ]

  run bash -c '
    source "'"$REPO_ROOT/lib/core.sh"'"
    source "'"$REPO_ROOT/lib/usage.sh"'"
    CR_HOME="'"$CHARTROOM_HOME"'"; stamp_changed() { :; }
    now_s="$(date +%s)"; at() { jq -rn --argjson e "$1" "\$e | todate"; }
    # the brain heard a stop 10 s ago; the heartbeat (heard 30 s ago) still carries an expired one from yesterday
    usage_write_record codex mini "$(jq -cn --arg at "$(at "$((now_s - 10))")" "{agent:\"codex\",machine:\"mini\",status:\"ok\",windows:[],hit_limit:{at:\$at,resets_at:null}}")" 1
    usage_write_record codex mini "$(jq -cn --arg at "$(at "$((now_s - 86400))")" "{agent:\"codex\",machine:\"mini\",status:\"ok\",windows:[],hit_limit:{at:\$at,resets_at:null}}")" 1 "$((now_s - 90))"
    jq -r ".hit_limit.at" "$CR_HOME/usage/mini--codex.json"; at "$((now_s - 10))"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "${lines[1]}" ]
}
