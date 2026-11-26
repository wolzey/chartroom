# shellcheck shell=bash
# usage.sh - subscription usage awareness: read real usage per agent (and per machine),
# skip exhausted agents on dispatch/fallback, detect usage-limit stops on workers, and
# move stuck work onto another agent without losing commits or worktree state.
#
# State under $CHARTROOM_HOME/usage/:
#   <machine>--<agent>.json   one record per (machine, agent), atomic 0600 writes.
#   Never stores tokens, cookies, emails, org IDs or account secrets.
#
# Sources (real only; never guessed or estimated):
#   claude  1) Claude OAuth usage endpoint (https://api.anthropic.com/api/oauth/usage) using
#              Claude Code's active OAuth token (macOS Keychain "Claude Code-credentials" first
#              on macOS, else ~/.claude/.credentials.json, cross-checked against claude auth
#              status orgId in memory), passed via stdin to curl -K - (never on argv/logs)
#           2) Claude Code statusLine JSON (`chartroom usage record claude`, stdin)
#   codex   1) Live `codex app-server` JSON-RPC `account/rateLimits/read` (matches /status)
#           2) Fallback: latest `token_count` event with `limit_id == "codex"` under ~/.codex/sessions/
#   agy     `agy --output-format json -p=/usage` (via `hc exec` in ssh on macOS)
#   grok    `grok usage --json` (daemon route; on shell route reports unknown + why)

CR_USAGE_SCHEMA=1
CR_USAGE_DEFAULT_AGENTS='claude codex agy'

usage_dir() { printf '%s/usage' "${CR_USAGE_DIR_BASE:-$CR_HOME}"; }
usage_node_cache_dir() { printf '%s/chartroom/usage' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

usage_machine_name() {
  if declare -F radar_machine_name >/dev/null 2>&1; then radar_machine_name
  else local h; h="$(cfg MACHINE_NAME '' "$(hostname -s 2>/dev/null || echo this)")"; printf '%s' "${h:-this}"; fi
}

usage_safe_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

usage_file() { # <agent> [machine]
  local m="${2:-$(usage_machine_name)}"
  printf '%s/%s--%s.json' "$(usage_dir)" "$(usage_safe_key "$m")" "$(usage_safe_key "$1")"
}

# Agents to track on this machine: claude, codex, agy, plus grok when installed or already recorded.
usage_agents_list() {
  local a list=() custom
  custom="$(cfg USAGE_AGENTS '' '')"
  if [[ -n "$custom" ]]; then
    for a in ${custom//,/ }; do [[ -n "$a" ]] && list+=("$a"); done
  else
    list=(claude codex agy)
    if [[ -n "$(usage_agent_bin grok)" || -f "$(usage_file grok)" ]]; then list+=(grok); fi
  fi
  printf '%s\n' "${list[@]}"
}

# Resolve an agent binary without modifying lib/agents.sh (grok installs to ~/.grok/bin/grok).
usage_agent_bin() { # <agent>
  local b=""
  if declare -F agent_bin >/dev/null 2>&1; then b="$(agent_bin "$1")"; else b="$(bin_of "$1")"; fi
  if [[ -z "$b" && "$1" == grok && -x "$HOME/.grok/bin/grok" ]]; then b="$HOME/.grok/bin/grok"; fi
  printf '%s' "$b"
}

# Write one reading atomically (0600), preserving any active hit_limit unless explicitly replaced.
usage_write_record() { # <agent> <machine> <json> [replace_hit 0|1]
  local agent="$1" machine="$2" doc="$3" rep="${4:-0}" f tmp prev='null'
  f="$(usage_file "$agent" "$machine")"
  mkdir -p "$(usage_dir)"
  if [[ "$rep" != 1 && -s "$f" ]]; then prev="$(cat "$f" 2>/dev/null || echo null)"; fi
  doc="$(jq -c --argjson prev "$prev" --argjson rep "$rep" '
    if $rep == 1 or ($prev | type) != "object" then .
    else
      # Preserve an existing active hit_limit if the new reading does not carry one,
      # and if the new reading is unknown (e.g. offline/transient error) while previous
      # had real windows, keep the previous windows & sampled_at and record last_error.
      (if (.hit_limit // null) == null and ($prev.hit_limit // null) != null then .hit_limit = $prev.hit_limit else . end)
      | if .status == "unknown" and $prev.status == "ok" and ((.windows // []) | length) == 0 and (($prev.windows // []) | length) > 0
           and ((.reason // "") | test("not signed in|not on PATH|not installed|API key"; "i") | not)
        then $prev + {recorded_at: .recorded_at, last_error: .reason, hit_limit: (.hit_limit // $prev.hit_limit)}
        else . end
    end' <<<"$doc")" || return 1
  tmp="$f.tmp.$$"
  ( umask 077; printf '%s\n' "$doc" >"$tmp" ) && mv "$tmp" "$f"
  stamp_changed
}

# ---------------------------------------------------------------- shared evaluation (jq)
# Evaluates a raw reading against the current clock and thresholds so CLI, picker, doctor,
# nodes, and dashboard always agree. Never estimates or invents numbers after reset: a window
# whose resets_at has passed is marked reset (awaiting a fresh reading) and never locks out.
# shellcheck disable=SC2016
USAGE_EVAL_JQ='
  def epoch:
    if . == null or . == "" then null
    elif type == "number" then (if . > 0 then floor else null end)
    else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | sub("Z$"; "Z") | try fromdateiso8601 catch null)
    end;
  def r1: ((. * 10 + 0.5) | floor) / 10;
  def clamp: if . < 0 then 0 elif . > 100 then 100 else . end;
  def eval_win($now; $lim; $warn):
    (.resets_at | epoch) as $re
    | ($re != null and $now >= $re) as $passed
    | ((.used_pct // (if .left_pct != null then (100 - .left_pct) else null end)) | if . == null then null else (clamp | r1) end) as $u
    | ((.left_pct // (if $u != null then (100 - $u) else null end)) | if . == null then null else (clamp | r1) end) as $l
    | (if $u == null then "unknown"
       elif $passed then "reset"
       elif $u >= $lim then "out"
       elif $u >= $warn then "near"
       else "ok" end) as $ws
    | . + {used_pct: $u, left_pct: $l, resets_epoch: $re, reset_passed: $passed, state: $ws};
  def eval_rec($now; $lim; $warn; $stale_s; $cool_s):
    (.sampled_at | epoch) as $se
    | (if $se != null then ([$now - $se, 0] | max) else null end) as $age
    | ($age != null and $age > $stale_s) as $stale
    | ((.windows // []) | map(eval_win($now; $lim; $warn))) as $wins
    | (.hit_limit // null) as $hl
    | ($hl.resets_at | epoch) as $hre
    | ($hl.at | epoch) as $hat
    | ($hl != null and (
        if $hre != null then $now < $hre
        elif $hat != null then ($now - $hat) < $cool_s
        else false end)) as $hit_active
    | ([$wins[] | select(.state == "out")]) as $out_wins
    | ([$wins[] | select(.state == "near")]) as $near_wins
    | ($hit_active or (($out_wins | length) > 0) or (.limit_reached == true and ($stale | not))) as $is_out
    | (if $is_out then "out"
       elif ($near_wins | length) > 0 then "near"
       elif .status == "ok" and (($wins | length) > 0) then "ok"
       else "unknown" end) as $st
    | ([$out_wins[] | select(.resets_epoch != null) | {e: .resets_epoch, iso: .resets_at}]
       + (if $hit_active and $hre != null then [{e: $hre, iso: $hl.resets_at}] else [] end)
       | sort_by(.e) | last // null) as $reset_obj
    | ($reset_obj.iso // (if $hit_active and $hl.resets_text then $hl.resets_text else null end)) as $out_resets
    | (if $hit_active then
         "\(.agent) hit usage limit" + (if $out_resets then " (resets \($out_resets))" else "" end)
       elif ($out_wins | length) > 0 then
         ($out_wins | sort_by(-.used_pct) | .[0]) as $w
         | "\(.agent) is out of usage (\($w.label) \($w.used_pct)% used, \($w.left_pct)% left" + (if $w.resets_at then ", resets \($w.resets_at)" else "" end) + ")"
       elif $is_out then
         "\(.agent) reached usage limit"
       else null end) as $out_reason
    | . + {
        windows: $wins,
        age_s: $age,
        stale: $stale,
        hit_active: $hit_active,
        state: $st,
        out: $is_out,
        near: ($st == "near"),
        out_resets_at: $out_resets,
        out_reason: $out_reason
      };
'

# ---------------------------------------------------------------- parsers (pure, tested on real samples)

# Parse Claude OAuth usage API response JSON (stdin) into a schema-1 reading.
# Args: <machine> <local true|false> <plan> <account> <sampled_at ISO>
usage_parse_claude_api() {
  local machine="$1" loc="$2" plan="$3" acct="$4" sampled="$5"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" \
    --arg plan "$plan" --arg acct "$acct" --arg sampled "$sampled" --arg rec "$(now)" '
    def norm_iso:
      if . == null or . == "" then null
      elif type == "number" then (if . > 0 then (floor | todate) else null end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) end;
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def win($id; $lbl; $obj):
      if ($obj | type) == "object" and ($obj.utilization // $obj.used_percentage // $obj.percent) != null then
        (($obj.utilization // $obj.used_percentage // $obj.percent) | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1) as $u
        | [{id: $id, label: $lbl, used_pct: $u, left_pct: ((100 - $u) | r1),
            resets_at: ($obj.resets_at | norm_iso), active: true}]
      else [] end;
    (win("five_hour"; "5h"; .five_hour) + win("seven_day"; "7d"; .seven_day)) as $w0
    | (if ($w0 | length) > 0 then $w0
       else
         # Only account-wide active limits (scope == null); never model/surface-scoped or inactive buckets.
         [(.limits // [])[] | select(.is_active == true and (.scope // null) == null and .percent != null
            and ((.kind // "") == "weekly_all" or (.kind // "") == "five_hour" or (.group // "") == "five_hour" or (.group // "") == "weekly"))
          | ((.percent | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1)) as $u
          | {id: (.kind // .group // "limit"),
             label: (if .group == "weekly" or (.kind // "" | startswith("weekly")) then "7d"
                     elif .group == "five_hour" or (.kind // "" | test("5h|five_hour")) then "5h"
                     else (.kind // .group // "limit") end),
             used_pct: $u, left_pct: ((100 - $u) | r1),
             resets_at: (.resets_at | norm_iso), active: true}]
       end) as $wins
    | {
        schema: $schema, agent: "claude", machine: $m, local: $loc,
        account: (if $acct == "" then "claude.ai" else $acct end),
        plan: (if $plan == "" then null else $plan end),
        status: (if ($wins | length) > 0 then "ok" else "unknown" end),
        source: "claude-oauth-api",
        reason: (if ($wins | length) > 0 then null else "Claude usage API returned no active rate-limit windows" end),
        sampled_at: $sampled, recorded_at: $rec,
        windows: $wins,
        extra_usage: (if (.extra_usage | type) == "object" then
          {enabled: (.extra_usage.is_enabled == true),
           spend_limit_reached: (.extra_usage.spend_limit_reached == true),
           disabled_reason: (.extra_usage.disabled_reason // null)}
          else null end)
      }'
}

# Parse Claude Code statusLine JSON (stdin) into a schema-1 reading.
# Args: <machine> <local true|false> <plan> <account> <sampled_at ISO>
usage_parse_claude_statusline() {
  local machine="$1" loc="$2" plan="$3" acct="$4" sampled="$5"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" \
    --arg plan "$plan" --arg acct "$acct" --arg sampled "$sampled" --arg rec "$(now)" '
    def norm_iso:
      if . == null or . == "" then null
      elif type == "number" then (if . > 0 then (floor | todate) else null end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) end;
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def win($id; $lbl; $obj):
      if ($obj | type) == "object" and ($obj.used_percentage // $obj.utilization) != null then
        (($obj.used_percentage // $obj.utilization) | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1) as $u
        | [{id: $id, label: $lbl, used_pct: $u, left_pct: ((100 - $u) | r1),
            resets_at: ($obj.resets_at | norm_iso), active: true}]
      else [] end;
    (.rate_limits // {}) as $rl
    | (win("five_hour"; "5h"; $rl.five_hour) + win("seven_day"; "7d"; $rl.seven_day)) as $wins
    | {
        schema: $schema, agent: "claude", machine: $m, local: $loc,
        account: (if $acct == "" then "claude.ai" else $acct end),
        plan: (if $plan == "" then null else $plan end),
        status: (if ($wins | length) > 0 then "ok" else "unknown" end),
        source: "claude-statusline",
        reason: (if ($wins | length) > 0 then null else "statusLine input contained no rate_limits windows" end),
        sampled_at: $sampled, recorded_at: $rec,
        windows: $wins
      }'
}

# Parse a Codex session JSONL `token_count` event (stdin) into a schema-1 reading.
# Args: <machine> <local true|false>
usage_parse_codex_event() {
  local machine="$1" loc="$2"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" --arg rec "$(now)" '
    def norm_iso:
      if . == null or . == "" then null
      elif type == "number" then (if . > 0 then (floor | todate) else null end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) end;
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def win_lbl($mins; $fallback):
      if ($mins | type) != "number" or $mins <= 0 then $fallback
      elif $mins == 300 then "5h"
      elif $mins == 10080 then "7d"
      elif ($mins % 1440) == 0 then "\($mins / 1440 | floor)d"
      elif ($mins % 60) == 0 then "\($mins / 60 | floor)h"
      else "\($mins | floor)m" end;
    def win($id; $obj):
      if ($obj | type) == "object" and $obj.used_percent != null then
        ($obj.used_percent | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1) as $u
        | [{id: $id, label: win_lbl($obj.window_minutes; $id), used_pct: $u, left_pct: ((100 - $u) | r1),
            window_minutes: ($obj.window_minutes // null),
            resets_at: ($obj.resets_at | norm_iso), active: true}]
      else [] end;
    ((.payload // .).rate_limits // null) as $rl
    | (if ($rl | type) == "object" then (win("primary"; $rl.primary) + win("secondary"; $rl.secondary)) else [] end) as $wins
    | (($rl.rate_limit_reached_type // null) != null or ($rl.spend_control_reached == true)) as $reached
    | {
        schema: $schema, agent: "codex", machine: $m, local: $loc,
        account: "chatgpt",
        plan: ($rl.plan_type // null),
        status: (if ($wins | length) > 0 then "ok" else "unknown" end),
        source: "codex-sessions",
        reason: (if ($wins | length) > 0 then null else "Codex token_count event had no rate_limits windows" end),
        sampled_at: ((.timestamp // $rec) | norm_iso),
        recorded_at: $rec,
        windows: $wins,
        limit_reached: $reached
      }'
}

# Parse `codex app-server` JSON-RPC `account/rateLimits/read` result (stdin) into a schema-1 reading.
# Uses only the primary account-wide "codex" bucket (never model-scoped side buckets) and strips
# accountId, credits balances, and reset-credit IDs.
# Args: <machine> <local true|false> <sampled_at ISO>
usage_parse_codex_appserver() {
  local machine="$1" loc="$2" sampled="${3:-$(now)}"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" \
    --arg sampled "$sampled" --arg rec "$(now)" '
    def norm_iso:
      if . == null or . == "" then null
      elif type == "number" then (if . > 0 then (floor | todate) else null end)
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) end;
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def win_lbl($mins; $fallback):
      if ($mins | type) != "number" or $mins <= 0 then $fallback
      elif $mins == 300 then "5h"
      elif $mins == 10080 then "7d"
      elif ($mins % 1440) == 0 then "\($mins / 1440 | floor)d"
      elif ($mins % 60) == 0 then "\($mins / 60 | floor)h"
      else "\($mins | floor)m" end;
    def win($id; $obj):
      if ($obj | type) == "object" and ($obj.usedPercent // $obj.used_percent) != null then
        (($obj.usedPercent // $obj.used_percent) | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1) as $u
        | ($obj.windowDurationMins // $obj.window_minutes // null) as $wm
        | [{id: $id, label: win_lbl($wm; $id), used_pct: $u, left_pct: ((100 - $u) | r1),
            window_minutes: $wm,
            resets_at: (($obj.resetsAt // $obj.resets_at) | norm_iso), active: true}]
      else [] end;
    (.rateLimitsByLimitId.codex // (if (.rateLimits.limitId // "codex") == "codex" then .rateLimits else null end)) as $rl
    | (if ($rl | type) == "object" then (win("primary"; $rl.primary) + win("secondary"; $rl.secondary)) else [] end) as $wins
    | ((.ordinaryUsageAllowed == false)
       or (($rl.rateLimitReachedType // null) != null)
       or ($rl.spendControlReached == true)) as $reached
    | {
        schema: $schema, agent: "codex", machine: $m, local: $loc,
        account: "chatgpt",
        plan: ($rl.planType // $rl.plan_type // null),
        status: (if ($wins | length) > 0 then "ok" else "unknown" end),
        source: "codex-app-server",
        reason: (if ($wins | length) > 0 then null else "Codex app-server returned no rateLimits windows" end),
        sampled_at: $sampled,
        recorded_at: $rec,
        windows: $wins,
        limit_reached: $reached
      }'
}

# Parse `agy --output-format json -p=/usage` output (stdin) into a schema-1 reading.
# Args: <machine> <local true|false> <model_hint> <sampled_at ISO>
usage_parse_agy_json() {
  local machine="$1" loc="$2" hint="${3:-}" sampled="${4:-$(now)}"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" \
    --arg hint "$hint" --arg sampled "$sampled" --arg rec "$(now)" '
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def norm_reset:
      if . == null or . == "" then null
      elif (tostring | startswith("1970-01-01")) then null
      else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) end;
    def map_bucket:
      ((.remaining_fraction // null) | if . == null then null else (tonumber * 100 | if . < 0 then 0 elif . > 100 then 100 else . end | r1) end) as $l
      | (if $l == null then null else ((100 - $l) | r1) end) as $u
      | (.reset_time | norm_reset) as $rt
      | {id: (.id // .window // "quota"),
         label: (if .window == "5h" then "5h" elif .window == "weekly" then "7d" else (.window // .name // "quota") end),
         used_pct: $u, left_pct: $l, resets_at: $rt, active: ($rt != null)};
    (.command.data.groups // []) as $groups
    | (if ($hint | test("^(claude|gpt)"; "i")) then
         ([$groups[] | select(.name | test("claude|gpt"; "i"))] | .[0])
       else
         ([$groups[] | select(.name | test("gemini"; "i"))] | .[0])
       end // ($groups[0] // null)) as $primary
    | (if $primary != null then [($primary.buckets // [])[] | map_bucket | select(.used_pct != null)] else [] end) as $wins
    | ([ $wins[] | select(.label == "5h") ] + [ $wins[] | select(.label != "5h") ]) as $ordered
    | {
        schema: $schema, agent: "agy", machine: $m, local: $loc,
        account: "google",
        plan: ($primary.name // null),
        status: (if ($ordered | length) > 0 then "ok" else "unknown" end),
        source: "agy-usage",
        reason: (if ($ordered | length) > 0 then null else "agy /usage returned no quota buckets" end),
        sampled_at: $sampled, recorded_at: $rec,
        windows: $ordered,
        extra_groups: [$groups[] | select($primary == null or .name != $primary.name) | {name, windows: [(.buckets // [])[] | map_bucket]}]
      }'
}

# Grok daemon-route JSON has not been captured live yet; never guess field names.
usage_read_grok() { # [machine]
  local m="${1:-$(usage_machine_name)}" b out rc=0
  b="$(usage_agent_bin grok)"
  if [[ -z "$b" ]]; then
    usage_unknown_record grok "$m" true grok-usage "grok not on PATH"
    return 0
  fi
  out="$(run_bounded 15 "$b" usage --json </dev/null 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    if grep -qi 'managed by your team' <<<"$out"; then
      usage_unknown_record grok "$m" true grok-usage "usage limits are managed by your team"
      return 0
    fi
    usage_unknown_record grok "$m" true grok-usage "grok daemon-route usage JSON format is not yet verified against a real capture"
    return 0
  fi
  local why
  if grep -qi "can't show your plan's usage here yet" <<<"$out"; then
    why="grok usage needs Grok's background service (daemon route); on the shell route run /usage inside grok"
  elif grep -qi 'not signed in\|sign in\|login' <<<"$out"; then
    why="grok is not signed in"
  else
    why="$(printf '%s\n' "$out" | tr '\r' '\n' | grep -v '^[[:space:]]*$' | head -1 | cut -c1-180 || true)"
    [[ -n "$why" ]] || why="grok usage --json exited $rc"
  fi
  usage_unknown_record grok "$m" true grok-usage "$why"
}

usage_unknown_record() { # <agent> <machine> <local true|false> <source> <reason> [plan] [account]
  jq -cn --argjson schema "$CR_USAGE_SCHEMA" --arg a "$1" --arg m "$2" --argjson loc "$3" \
    --arg src "$4" --arg why "$5" --arg plan "${6:-}" --arg acct "${7:-}" --arg now "$(now)" '
    {schema: $schema, agent: $a, machine: $m, local: $loc,
     account: (if $acct == "" then null else $acct end),
     plan: (if $plan == "" then null else $plan end),
     status: "unknown", source: $src, reason: $why,
     sampled_at: $now, recorded_at: $now, windows: []}'
}

# ---------------------------------------------------------------- live local readers

# Read Claude's active OAuth token the way Claude Code itself does, without ever printing it.
# On macOS Claude Code keeps active credentials in Keychain ("Claude Code-credentials", or
# "Claude Code-credentials-<sha256_8>" for a custom CLAUDE_CONFIG_DIR), ahead of any stale
# ~/.claude/.credentials.json file. Cross-checks organizationUuid against claude auth status
# orgId (in memory only) so a leftover credential from another account is never queried.
# Prints token to stdout only (callers must never echo/log it or pass it on a command line).
usage_claude_keychain_service() {
  local cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" def="$HOME/.claude" h=""
  if [[ -z "${CLAUDE_CONFIG_DIR:-}" || "${cfg_dir%/}" == "${def%/}" ]]; then
    printf 'Claude Code-credentials'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then h="$(printf '%s' "$cfg_dir" | shasum -a 256 | cut -c1-8)"
  elif command -v sha256sum >/dev/null 2>&1; then h="$(printf '%s' "$cfg_dir" | sha256sum | cut -c1-8)"; fi
  printf 'Claude Code-credentials%s' "${h:+-$h}"
}

usage_claude_extract_token() { # <raw_json> [expected_org_id] [require_org_match 0|1]
  local raw="$1" exp_org="${2:-}" req_match="${3:-0}" tok="" cred_org=""
  [[ -n "$raw" ]] || return 1
  tok="$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$raw" 2>/dev/null || true)"
  [[ -n "$tok" ]] || return 1
  cred_org="$(jq -r '.claudeAiOauth.organizationUuid // empty' <<<"$raw" 2>/dev/null || true)"
  if [[ -n "$exp_org" ]]; then
    if [[ -n "$cred_org" && "$cred_org" != "$exp_org" ]]; then return 2; fi
    if [[ "$req_match" == 1 && "$cred_org" != "$exp_org" ]]; then return 2; fi
  fi
  printf '%s' "$tok"
  return 0
}

usage_claude_oauth_token() { # [expected_org_id]
  local exp_org="${1:-}" cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" f raw="" tok="" sec="" svc kc_used=0
  f="$cfg_dir/.credentials.json"
  # Determine Keychain tool (macOS default /usr/bin/security, or explicit CHARTROOM_KEYCHAIN path; "none" disables).
  if [[ "${CHARTROOM_KEYCHAIN:-}" != none ]]; then
    if [[ -n "${CHARTROOM_KEYCHAIN:-}" && -x "${CHARTROOM_KEYCHAIN}" ]]; then sec="$CHARTROOM_KEYCHAIN"
    elif [[ "$(uname -s)" == Darwin && -x /usr/bin/security ]]; then sec="/usr/bin/security"; fi
  fi
  if [[ -n "$sec" ]]; then
    kc_used=1
    svc="$(usage_claude_keychain_service)"
    if [[ -n "${CHARTROOM_GATE:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]] && declare -F hc_probe >/dev/null 2>&1 && hc_probe >/dev/null 2>&1; then
      raw="$(env -u HC_TERMINAL_ID "$(hc_bin)" exec --timeout 10 -- "$sec" find-generic-password -s "$svc" -w 2>/dev/null || true)"
    else
      raw="$("$sec" find-generic-password -s "$svc" -w 2>/dev/null || true)"
    fi
    if tok="$(usage_claude_extract_token "$raw" "$exp_org" 0)"; then
      printf '%s' "$tok"; return 0
    fi
  fi
  if [[ -r "$f" ]]; then
    raw="$(cat "$f" 2>/dev/null || true)"
    # On macOS (where Keychain is Claude Code's primary store), only accept .credentials.json when
    # orgId is unknown or explicitly matches claude auth status, so a stale file from another account
    # is never silently queried.
    if tok="$(usage_claude_extract_token "$raw" "$exp_org" "$kc_used")"; then
      printf '%s' "$tok"; return 0
    fi
  fi
  return 1
}

usage_read_claude() { # [machine]
  local m="${1:-$(usage_machine_name)}" b auth="" plan="" acct="" api_prov="" logged="" exp_org="" tok="" out="" code="" url sampled
  sampled="$(now)"
  # Test / offline fixture hook: CHARTROOM_CLAUDE_USAGE_FILE bypasses network cleanly.
  if [[ -n "${CHARTROOM_CLAUDE_USAGE_FILE:-}" && -r "${CHARTROOM_CLAUDE_USAGE_FILE}" ]]; then
    plan="${CHARTROOM_CLAUDE_PLAN:-}"; acct="${CHARTROOM_CLAUDE_ACCOUNT:-claude.ai}"
    if out="$(usage_parse_claude_api "$m" true "$plan" "$acct" "$sampled" <"$CHARTROOM_CLAUDE_USAGE_FILE" 2>/dev/null)"; then
      printf '%s\n' "$out"; return 0
    fi
  fi
  b="$(usage_agent_bin claude)"
  if [[ -z "$b" ]]; then
    usage_unknown_record claude "$m" true claude-oauth-api "claude not on PATH"
    return 0
  fi
  auth="$(run_bounded 15 "$b" auth status </dev/null 2>/dev/null || true)"
  if [[ -n "$auth" ]] && jq -e 'type == "object"' <<<"$auth" >/dev/null 2>&1; then
    logged="$(jq -r '.loggedIn // ""' <<<"$auth")"
    acct="$(jq -r '.authMethod // ""' <<<"$auth")"
    api_prov="$(jq -r '.apiProvider // ""' <<<"$auth")"
    plan="$(jq -r '.planTier // .subscriptionType // ""' <<<"$auth")"
    # Keep orgId in shell memory only to verify credential account match; never stored or printed.
    exp_org="$(jq -r '.orgId // ""' <<<"$auth")"
    if [[ "$logged" == false ]]; then
      usage_unknown_record claude "$m" true claude-oauth-api "claude is not signed in" "$plan" "$acct"
      return 0
    fi
    if [[ -n "$acct" && "$acct" != "claude.ai" && "$acct" != "oauth" ]]; then
      usage_unknown_record claude "$m" true claude-oauth-api "claude uses $acct billing (no subscription rate limits)" "$plan" "$acct"
      return 0
    fi
    if [[ -n "$api_prov" && "$api_prov" != "firstParty" ]]; then
      usage_unknown_record claude "$m" true claude-oauth-api "claude uses $api_prov provider (no subscription rate limits)" "$plan" "$acct"
      return 0
    fi
  fi
  tok="$(usage_claude_oauth_token "$exp_org" || true)"
  exp_org=""
  if [[ -z "$tok" ]]; then
    usage_unknown_record claude "$m" true claude-oauth-api "no matching Claude OAuth credential found for active account (use claude /login or pipe statusLine to chartroom usage record claude)" "$plan" "$acct"
    return 0
  fi
  url="${CHARTROOM_CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
  local tmp; tmp="$(mktemp)"
  code="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\nheader = "User-Agent: chartroom/%s"\n' "$tok" "${CR_VERSION:-0}" |
    curl -sS -K - --max-time 12 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  tok="" # drop from shell memory promptly
  if [[ "$code" == 200 ]] && out="$(usage_parse_claude_api "$m" true "$plan" "$acct" "$sampled" <"$tmp" 2>/dev/null)"; then
    rm -f "$tmp"
    printf '%s\n' "$out"
    return 0
  fi
  rm -f "$tmp"
  usage_unknown_record claude "$m" true claude-oauth-api "Claude usage endpoint returned HTTP ${code:-000}" "$plan" "$acct"
}

# Query live Codex rate limits via `codex app-server` JSON-RPC `account/rateLimits/read`
# (the same live endpoint Codex's /status reads). Prints result JSON to stdout on success.
usage_codex_appserver_read() { # <codex_bin>
  local b="$1" py
  [[ "${CHARTROOM_CODEX_APP_SERVER:-on}" != off ]] || return 1
  py="$(cfg PYTHON '' python3)"
  command -v "$py" >/dev/null 2>&1 || return 1
  "$py" - "$b" <<'PY' 2>/dev/null
import json, select, subprocess, sys, time
cmd = [sys.argv[1], "app-server"]
try:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
except Exception:
    sys.exit(1)
ok = False
try:
    for req in (
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "chartroom", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}},
    ):
        p.stdin.write(json.dumps(req) + "\n")
    p.stdin.flush()
    deadline = time.time() + 10.0
    while time.time() < deadline:
        r, _, _ = select.select([p.stdout], [], [], max(0.05, deadline - time.time()))
        if not r:
            continue
        line = p.stdout.readline()
        if not line:
            break
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("id") == 2 and isinstance(obj.get("result"), dict):
            sys.stdout.write(json.dumps(obj["result"]))
            ok = True
            break
        if obj.get("id") == 2 and "error" in obj:
            break
finally:
    try: p.terminate()
    except Exception: pass
    try: p.wait(timeout=2)
    except Exception:
        try: p.kill()
        except Exception: pass
sys.exit(0 if ok else 1)
PY
}

usage_read_codex() { # [machine]
  local m="${1:-$(usage_machine_name)}" codex_home="${CODEX_HOME:-$HOME/.codex}" b raw sampled sdir f line best=""
  sampled="$(now)"
  b="$(usage_agent_bin codex)"
  # 1. Live `codex app-server` RPC (matches Codex /status in real time).
  if [[ -n "$b" ]] && raw="$(usage_codex_appserver_read "$b")" && [[ -n "$raw" ]]; then
    if jq -e '(.rateLimitsByLimitId.codex // .rateLimits) | type == "object"' <<<"$raw" >/dev/null 2>&1; then
      usage_parse_codex_appserver "$m" true "$sampled" <<<"$raw"
      return 0
    fi
  fi
  # 2. Fallback: latest `token_count` event with `limit_id == "codex"` under ~/.codex/sessions/.
  sdir="$codex_home/sessions"
  if [[ ! -d "$sdir" ]]; then
    if [[ -z "$b" ]]; then usage_unknown_record codex "$m" true codex-sessions "codex not on PATH"
    else usage_unknown_record codex "$m" true codex-sessions "no Codex session files under $sdir"; fi
    return 0
  fi
  # Scan newest session files first (up to 40) for the latest account-wide codex token_count event.
  while IFS= read -r f; do
    [[ -n "$f" && -r "$f" ]] || continue
    grep -q '"rate_limits"' "$f" 2>/dev/null || continue
    line="$(grep '"rate_limits"' "$f" 2>/dev/null | jq -c '
      select(.type == "event_msg" and (.payload.type? == "token_count")
        and ((.payload.rate_limits | type) == "object")
        and ((.payload.rate_limits.limit_id // "codex") == "codex")
        and (.payload.rate_limits.primary != null or .payload.rate_limits.secondary != null))' 2>/dev/null |
      jq -sc 'last // empty' 2>/dev/null || true)"
    if [[ -n "$line" ]]; then best="$line"; break; fi
  done < <(find "$sdir" -type f -name '*.jsonl' 2>/dev/null | while IFS= read -r p; do
      local mt; mt="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo 0)"
      printf '%s\t%s\n' "$mt" "$p"
    done | sort -rn -k1,1 | head -n 40 | cut -f2-)
  if [[ -z "$best" ]]; then
    usage_unknown_record codex "$m" true codex-sessions "no Codex session with rate_limits found under $sdir"
    return 0
  fi
  usage_parse_codex_event "$m" true <<<"$best"
}

usage_read_agy() { # [machine]
  local m="${1:-$(usage_machine_name)}" b out rc=0 run=() sampled
  sampled="$(now)"
  b="$(usage_agent_bin agy)"
  if [[ -z "$b" ]]; then
    usage_unknown_record agy "$m" true agy-usage "agy not on PATH"
    return 0
  fi
  if [[ -n "${CHARTROOM_GATE:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
    if declare -F hc_probe >/dev/null 2>&1 && hc_probe >/dev/null 2>&1; then
      run=(env -u HC_TERMINAL_ID "$(hc_bin)" exec --timeout 20 --)
    elif [[ "$(uname -s)" == Darwin ]]; then
      usage_unknown_record agy "$m" true agy-usage "agy quota cannot be read from an ssh session without a running hc core (keychain locked)"
      return 0
    fi
  fi
  if [[ ${#run[@]} -gt 0 ]]; then
    out="$(cd / && "${run[@]}" "$b" --output-format json -p=/usage </dev/null 2>&1)" || rc=$?
  else
    out="$(cd / && run_bounded 20 "$b" --output-format json -p=/usage </dev/null 2>&1)" || rc=$?
  fi
  if [[ $rc -eq 0 ]] && jq -e '.command.name == "usage" and (.command.data.groups | type) == "array"' <<<"$out" >/dev/null 2>&1; then
    usage_parse_agy_json "$m" true "${CR_AGY_MODEL:-}" "$sampled" <<<"$out"
    return 0
  fi
  local why
  why="$(printf '%s\n' "$out" | tr '\r' '\n' | grep -v '^[[:space:]]*$' | head -1 | cut -c1-180 || true)"
  if grep -qi 'sign in' <<<"$out"; then why="agy is not signed in"
  elif grep -qi 'GEMINI_API_KEY\|API key' <<<"$out"; then why="agy uses GEMINI_API_KEY (no account quota)"
  elif [[ -z "$why" ]]; then why="agy -p=/usage exited $rc"; fi
  usage_unknown_record agy "$m" true agy-usage "$why"
}

usage_read_one() { # <agent> [machine]
  local a="$1" m="${2:-$(usage_machine_name)}"
  case "$a" in
    claude) usage_read_claude "$m" ;;
    codex) usage_read_codex "$m" ;;
    agy) usage_read_agy "$m" ;;
    grok) usage_read_grok "$m" ;;
    *) usage_unknown_record "$a" "$m" true unknown "unsupported agent '$a'" ;;
  esac
}

# Refresh one local agent if missing or older than CHARTROOM_USAGE_REFRESH_MINUTES (or force=1).
usage_refresh_agent() { # <agent> [force 0|1]
  local a="$1" force="${2:-0}" m f rec age_s now_s max_s doc
  m="$(usage_machine_name)"; f="$(usage_file "$a" "$m")"
  max_s=$((CR_USAGE_REFRESH_MIN * 60))
  if [[ "$force" != 1 && -s "$f" ]]; then
    if (( CR_USAGE_REFRESH_MIN == 0 )); then return 0; fi
    now_s="$(date +%s)"
    rec="$(jq -r '.recorded_at // .sampled_at // "" | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch 0' "$f" 2>/dev/null || echo 0)"
    age_s=$((now_s - rec))
    if (( age_s >= 0 && age_s < max_s )); then
      # For Codex, re-read if a newer session file appeared since recorded_at.
      if [[ "$a" != codex ]] || ! find "${CODEX_HOME:-$HOME/.codex}/sessions" -type f -name '*.jsonl' -newer "$f" 2>/dev/null | grep -q .; then
        return 0
      fi
    fi
  fi
  doc="$(usage_read_one "$a" "$m")" || return 0
  usage_write_record "$a" "$m" "$doc" 0
}

usage_refresh_local() { # [force 0|1]
  local force="${1:-0}" a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    usage_refresh_agent "$a" "$force"
  done < <(usage_agents_list)
}

# Refresh local usage into the node-level state dir ($XDG_STATE_HOME/chartroom/usage) so
# enrolled nodes (which have no CHARTROOM_HOME in launchd) emit live readings in every heartbeat.
USAGE_DEVICE_NEXT=0
usage_device_refresh() { # [force 0|1]
  local force="${1:-0}" now_s
  (( CR_USAGE_REFRESH_MIN > 0 || force == 1 )) || return 0
  printf -v now_s '%(%s)T' -1
  (( force == 1 || now_s >= USAGE_DEVICE_NEXT )) || return 0
  USAGE_DEVICE_NEXT=$((now_s + (CR_USAGE_REFRESH_MIN > 0 ? CR_USAGE_REFRESH_MIN : 5) * 60))
  (
    CR_USAGE_DIR_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom"
    usage_refresh_local "$force"
  ) >/dev/null 2>&1 || true
}

# Sync usage lines from remote enrolled devices' last heartbeats into $CHARTROOM_HOME/usage/.
usage_sync_nodes() {
  declare -F fleet_devices_json >/dev/null 2>&1 || return 0
  local devs n i dev name probe line a st plan acct sampled wspec why hre doc
  devs="$(fleet_devices_json 2>/dev/null || echo '[]')"
  n="$(jq length <<<"$devs" 2>/dev/null || echo 0)"
  for ((i = 0; i < n; i++)); do
    dev="$(jq -c --argjson i "$i" '.[$i]' <<<"$devs")"
    [[ "$(jq -r '.status // ""' <<<"$dev")" =~ ^(online|stale)$ ]] || continue
    name="$(jq -r '.name // ""' <<<"$dev")"; probe="$(jq -r '.probe // ""' <<<"$dev")"
    [[ -n "$name" && -n "$probe" ]] || continue
    while IFS=$'\t' read -r _ a st plan acct sampled wspec why hre; do
      [[ -n "$a" ]] || continue
      doc="$(usage_from_probe_line "$name" "$a" "$st" "$plan" "$acct" "$sampled" "$wspec" "$why" "${hre:-}")" || continue
      usage_write_record "$a" "$name" "$doc" 0
    done < <(awk -F'\t' '$1 == "usage" { print }' <<<"$probe")
  done
}

# Convert one nodeprobe `usage` TSV line into a schema-1 reading JSON.
# Format: usage <agent> <status> <plan|-> <account|-> <sampled_at|-> <wspec|-> <reason|-> [hit_resets_epoch|->]
# wspec: comma-separated "<label>:<used_pct>:<resets_epoch_or_->" (e.g. "5h:12.0:1795700000,7d:94.0:1795900000")
usage_from_probe_line() { # <machine> <agent> <status> <plan> <acct> <sampled> <wspec> <reason> [hit_resets_epoch]
  jq -cn --argjson schema "$CR_USAGE_SCHEMA" --arg m "$1" --arg a "$2" --arg st "$3" \
    --arg plan "$4" --arg acct "$5" --arg sampled "$6" --arg wspec "$7" --arg why "$8" \
    --arg hre "${9:-}" --arg rec "$(now)" '
    def d: if . == "" or . == "-" then null else . end;
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def parse_w:
      if . == "" or . == "-" then []
      else split(",") | map(select(length > 0) | split(":")
        | (.[1] | tonumber? // null) as $u
        | select($u != null)
        | (.[2] // "-" | tonumber? // null) as $re
        | {id: .[0], label: .[0], used_pct: ($u | r1), left_pct: ((100 - $u) | if . < 0 then 0 elif . > 100 then 100 else . end | r1),
           resets_at: (if $re != null and $re > 0 then ($re | floor | todate) else null end),
           active: ($re != null and $re > 0)}) end;
    ($hre | d | if . != null then (tonumber? // null) else null end) as $he
    | {schema: $schema, agent: $a, machine: $m, local: false,
       account: ($acct | d), plan: ($plan | d),
       status: (if $st == "ok" then "ok" else "unknown" end),
       source: "node-probe",
       reason: ($why | d),
       sampled_at: (($sampled | d) // $rec), recorded_at: $rec,
       windows: ($wspec | parse_w)}
      + (if $he != null and $he > 0 then {hit_limit: {at: $rec, resets_at: ($he | floor | todate), resets_text: null, task: null, message: "worker hit usage limit on \($m)"}} else {} end)'
}

# Print local usage as nodeprobe TSV lines without writing any files (lib/nodeprobe.sh is strictly read-only).
usage_probe_tsv() {
  local d f seen=" "
  for d in "${CHARTROOM_HOME:+$CHARTROOM_HOME/usage}" "${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/usage"; do
    [[ -n "$d" && -d "$d" ]] || continue
    shopt -s nullglob
    for f in "$d"/*.json; do
      local a; a="$(jq -r 'select(.local == true) | .agent // empty' "$f" 2>/dev/null || true)"
      [[ -n "$a" && "$seen" != *" $a "* ]] || continue
      seen+="$a "
      jq -r '
        def s: if . == null or . == "" then "-" else (tostring | gsub("[\t\n\r]"; " ")) end;
        def ep: if . == null or . == "" then "-" else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch "-") | tostring) end;
        ["usage", (.agent | s), (.status | s), (.plan | s), (.account | s), (.sampled_at | s),
         ((.windows // []) | map("\(.label):\(.used_pct // ""):\(.resets_at | ep)") | join(",") | s),
         (.reason | s),
         ((.hit_limit.resets_at // null) | ep)] | @tsv' "$f" 2>/dev/null || true
    done
    shopt -u nullglob
  done
  if [[ "$seen" != *" codex "* && -d "${CODEX_HOME:-$HOME/.codex}/sessions" ]]; then
    local cdoc; cdoc="$(CHARTROOM_CODEX_APP_SERVER=off usage_read_codex "$(usage_machine_name)" 2>/dev/null || true)"
    [[ -z "$cdoc" ]] || jq -r '
      select(.status == "ok")
      | def s: if . == null or . == "" then "-" else (tostring | gsub("[\t\n\r]"; " ")) end;
      def ep: if . == null or . == "" then "-" else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch "-") | tostring) end;
      ["usage", (.agent | s), (.status | s), (.plan | s), (.account | s), (.sampled_at | s),
       ((.windows // []) | map("\(.label):\(.used_pct // ""):\(.resets_at | ep)") | join(",") | s),
       (.reason | s), "-"] | @tsv' <<<"$cdoc" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- query & exhaustion checks

# All stored readings evaluated against current clock and thresholds, as a JSON array.
usage_all_json() {
  local d now_s files=()
  d="$(usage_dir)"; now_s="$(date +%s)"
  shopt -s nullglob
  files=("$d"/*.json)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then echo '[]'; return 0; fi
  jq -sc --argjson now "$now_s" --argjson lim "$CR_USAGE_LIMIT_PCT" --argjson warn "$CR_USAGE_WARN_PCT" \
    --argjson stale "$((CR_USAGE_STALE_MIN * 60))" --argjson cool "$((CR_USAGE_COOLDOWN_MIN * 60))" \
    "$USAGE_EVAL_JQ"'map(select(type == "object" and .agent != null) | eval_rec($now; $lim; $warn; $stale; $cool))' \
    "${files[@]}" 2>/dev/null || echo '[]'
}

# Evaluated reading for one (agent, machine); prints JSON object or empty.
usage_of() { # <agent> [machine]
  local f now_s
  f="$(usage_file "$1" "${2:-}")"
  [[ -s "$f" ]] || return 0
  now_s="$(date +%s)"
  jq -c --argjson now "$now_s" --argjson lim "$CR_USAGE_LIMIT_PCT" --argjson warn "$CR_USAGE_WARN_PCT" \
    --argjson stale "$((CR_USAGE_STALE_MIN * 60))" --argjson cool "$((CR_USAGE_COOLDOWN_MIN * 60))" \
    "$USAGE_EVAL_JQ"'eval_rec($now; $lim; $warn; $stale; $cool)' "$f" 2>/dev/null || true
}

# Returns 0 (and prints the reason) when <agent> on [machine] is out of usage; returns 1 otherwise.
# Unknown/unrecorded agents are NEVER treated as out.
usage_agent_out() { # <agent> [machine]
  local rec
  rec="$(usage_of "$1" "${2:-}")"
  [[ -n "$rec" ]] || return 1
  if jq -e '.out == true' <<<"$rec" >/dev/null 2>&1; then
    jq -r '.out_reason // "\(.agent) is out of usage"' <<<"$rec"
    return 0
  fi
  return 1
}

# Prints why <agent> on [machine] cannot take new work due to usage, returning 1 when out, 0 when ok.
# (Matches the `auto_ok` / `agent_login_why` convention: empty + rc 0 = ok; message + rc 1 = unavailable.)
usage_agent_why() { # <agent> [machine]
  local why
  if why="$(usage_agent_out "$1" "${2:-}")"; then
    printf '%s' "$why"
    return 1
  fi
  return 0
}

# JSON array of rows for display (CLI and dashboard):
# - One row per agent, and per machine where machines differ (different plan, account, status,
#   state, or window percentages). When all machines match for an agent, collapse to one row
#   (preferring the local machine's row, with `machines: [...]`).
# - Enriches each row with `live_workers` (count of live non-closed/non-review/non-done/non-failed
#   tasks on that agent).
# shellcheck disable=SC2120
usage_rows_json() { # [spread_summary json]
  local all live_json here
  all="$(usage_all_json)"
  if [[ -n "${1:-}" ]]; then live_json="$1"
  elif declare -F spread_summary >/dev/null 2>&1; then live_json="$(spread_summary 2>/dev/null || echo '[]')"
  else live_json='[]'; fi
  here="$(usage_machine_name)"
  jq -cn --argjson all "$all" --argjson live "$live_json" --arg here "$here" '
    (["claude", "codex", "agy", "grok"]) as $order
    | ([$live[]? | {key: .agent, value: (.live // 0)}] | from_entries) as $lmap
    | def rank($a): ($order | index($a)) // 99;
    def sig: [
      .status, .state, (.plan // ""), (.account // ""),
      (.out_resets_at // ""),
      ([(.windows // [])[] | [.label, (.used_pct // -1), (.resets_at // "")]] | sort)
    ];
    ($all | group_by(.agent) | map(
      sort_by([(if .local then 0 else 1 end), .machine]) as $g
      | ([$g[] | sig] | unique | length) as $distinct
      | if $distinct <= 1 then
          [$g[0] + {machines: [$g[].machine], per_machine: false}]
        else
          [$g[] | . + {machines: [.machine], per_machine: true}]
        end
    ) | add // [])
    | map(. + {live_workers: ($lmap[.agent] // 0)})
    | sort_by([rank(.agent), (if .local then 0 else 1 end), .machine])'
}

# Available agents (excluding <skip_agent>) formatted for the XO wake message.
usage_available_agents() { # [exclude_agent]
  local excl="${1:-}" a bs="" out=() rec left
  if declare -F spread_local_backends >/dev/null 2>&1; then bs="$(spread_local_backends 2>/dev/null || true)"; fi
  for a in codex agy claude; do
    [[ "$a" != "$excl" ]] || continue
    [[ "$bs" == *":$a"* ]] || continue
    usage_agent_out "$a" >/dev/null && continue
    rec="$(usage_of "$a")"
    left="$(jq -r 'if .status == "ok" and ((.windows // []) | length) > 0 then ([.windows[] | select(.reset_passed != true and .left_pct != null) | "\(.label) \(.left_pct | floor)% left"] | join(", ")) else "" end' <<<"$rec" 2>/dev/null || true)"
    out+=("$a${left:+ ($left)}")
  done
  local IFS=', '; printf '%s' "${out[*]-}"
}

# ---------------------------------------------------------------- worker limit-stop detection (Part 3)

# Extract a human-readable reset time phrase from a usage-limit error line, or empty.
# Note: grep -E operates line-by-line; never put \n inside [...] (that excludes literal 'n').
usage_extract_reset_text() { # <text>
  local t=""
  # Match "resets <time>", "reset at <time>", "try again at <time>", "try again in <dur>", "Resets in <dur>"
  t="$(grep -oiE '(resets? (at |in )?[^.;]+|try again (at |in )[^.;]+)' <<<"$1" | head -1 || true)"
  t="$(sed -E 's/^(resets?|try again)[[:space:]]+(at|in)[[:space:]]+//i; s/^resets?[[:space:]]+//i; s/[[:space:]]+$//' <<<"$t")"
  # Keep "in <dur>" marker when it was a relative duration so parser knows it's relative.
  if grep -qiE '(resets?|try again)[[:space:]]+in[[:space:]]+' <<<"$1" && [[ -n "$t" ]]; then
    t="in $t"
  fi
  printf '%s' "${t:0:80}"
}

# Convert a reset phrase into an ISO-8601 UTC timestamp when unambiguous:
# - ISO-8601 UTC ("2026-11-30T10:00:00Z" or "2026-11-30 10:00 UTC")
# - Relative duration ("in 1 hour 20 minutes", "in 2 days 3 hours 10 minutes", "in 4h 30m", "in 45m")
# - Explicit UTC wall-clock ("14:30 UTC", "5pm (UTC)", "5:30pm UTC", "Nov 30, 10am (UTC)", "Nov 30 at 10:00am UTC")
# Returns empty when ambiguous (caller falls back to matching API window resets_at or cooldown).
usage_parse_reset_iso() { # <reset_text> [now_epoch]
  local txt="$1" now_s="${2:-$(date +%s)}"
  [[ -n "$txt" ]] || return 0
  # Already ISO-8601 UTC?
  if [[ "$txt" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[T[:space:]][0-9]{2}:[0-9]{2}(:[0-9]{2})?)[[:space:]]*(Z|UTC) ]]; then
    local iso="${BASH_REMATCH[1]/ /T}"
    [[ "$iso" == *:*:* ]] || iso="${iso}:00"
    printf '%sZ' "$iso"; return 0
  fi
  # Relative duration: "in 3d 4h 20m", "in 1 hour 20 minutes", "in 2 days 3 hours 10 minutes"
  if [[ "${txt,,}" =~ ^in[[:space:]] ]]; then
    local d=0 h=0 m=0 s=0 any=0
    if [[ "${txt,,}" =~ ([0-9]+)[[:space:]]*(d|day|days)([^a-z]|$) ]]; then d="${BASH_REMATCH[1]}"; any=1; fi
    if [[ "${txt,,}" =~ ([0-9]+)[[:space:]]*(h|hr|hrs|hour|hours)([^a-z]|$) ]]; then h="${BASH_REMATCH[1]}"; any=1; fi
    if [[ "${txt,,}" =~ ([0-9]+)[[:space:]]*(m|min|mins|minute|minutes)([^a-z]|$) ]]; then m="${BASH_REMATCH[1]}"; any=1; fi
    if [[ "${txt,,}" =~ ([0-9]+)[[:space:]]*(s|sec|secs|second|seconds)([^a-z]|$) ]]; then s="${BASH_REMATCH[1]}"; any=1; fi
    if (( any == 1 )); then
      local target=$((now_s + 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s))
      jq -rn --argjson t "$target" '$t | todate'
      return 0
    fi
  fi
  # Explicit UTC wall-clock formats ("5pm (UTC)", "5:30pm UTC", "14:30 UTC", "Nov 30, 10am (UTC)")
  local py; py="$(cfg PYTHON '' python3)"
  if command -v "$py" >/dev/null 2>&1 && grep -qi 'UTC' <<<"$txt"; then
    "$py" - "$txt" "$now_s" <<'PY' 2>/dev/null || true
import datetime, re, sys
txt, now_s = sys.argv[1], int(sys.argv[2])
now = datetime.datetime.fromtimestamp(now_s, tz=datetime.timezone.utc)
t = re.sub(r'\(UTC\)|\bUTC\b', '', txt, flags=re.I).strip(' ,.')
months = {m: i for i, m in enumerate(
    ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'], 1)}
def parse_clock(s):
    m = re.match(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$', s.strip(), re.I)
    if not m: return None
    hh, mm, ap = int(m.group(1)), int(m.group(2) or 0), (m.group(3) or '').lower()
    if mm > 59: return None
    if ap:
        if hh < 1 or hh > 12: return None
        hh = (0 if hh == 12 else hh) + (12 if ap == 'pm' else 0)
    elif hh > 23:
        return None
    return hh, mm
# "Nov 30, 10am" or "Nov 30 at 10:30am"
m = re.match(r'^([A-Za-z]{3})[a-z]*\s+(\d{1,2})(?:[,\s]+(?:at\s+)?)(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)$', t, re.I)
if m and m.group(1).lower() in months:
    clk = parse_clock(m.group(3))
    if clk:
        mon, day = months[m.group(1).lower()], int(m.group(2))
        yr = now.year
        dt = datetime.datetime(yr, mon, day, clk[0], clk[1], tzinfo=datetime.timezone.utc)
        if dt < now - datetime.timedelta(hours=12):
            dt = datetime.datetime(yr + 1, mon, day, clk[0], clk[1], tzinfo=datetime.timezone.utc)
        print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
        sys.exit(0)
# Time-only "5pm" or "14:30" (today or tomorrow UTC)
clk = parse_clock(t)
if clk:
    dt = now.replace(hour=clk[0], minute=clk[1], second=0, microsecond=0)
    if dt <= now:
        dt += datetime.timedelta(days=1)
    print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
  fi
  return 0
}

# Detect a real plan/subscription usage-limit stop in a worker's screen tail or headless output.
# Prints "<matched_line>\t<reset_text>" on match (rc 0), or nothing (rc 1).
# Strict by design so ordinary prose, diffs, code, or tool output can NEVER trigger a false lockout:
#   - Inspects only the last 4 non-prompt/non-footer lines (UI position of the actual stop banner).
#   - Drops any line led by agent prose/tool bullets (●, ⎿, •, │, ├, └), diff/comment/shell prefixes,
#     numbered code lines ("1180: ..."), or code assignments.
#   - Matches only whole-line anchored agent limit-stop banners / error lines.
# Args: <agent> <screen_or_output> [mode: screen|headless (default screen)]
usage_screen_limit() { # <agent> <screen_or_output> [screen|headless]
  local agent="$1" scr="$2" mode="${3:-screen}" tail_lines="" line norm hit="" rx=""
  if [[ "$mode" == headless ]]; then
    tail_lines="$(grep -vE '^[[:space:]]*$' <<<"$scr" | tail -n 8 || true)"
  else
    # Strip blank lines, [hc] notes, box dividers, and interactive prompt/status-bar footers,
    # then look ONLY at the bottom 4 actual output lines (where a limit banner sits at rest).
    tail_lines="$(grep -vE '^[[:space:]]*$|^\[hc\] |^[[:space:]]*[─━═┄┈-]{3,}[[:space:]]*$|^[[:space:]]*(❯|›|>)[[:space:]]*$|shift\+tab to cycle|for shortcuts|\? for help|esc to cancel|Ask Codex to do anything|Type a message|^[[:space:]]*[0-9]+% (left|context)|^[[:space:]]*ctx [0-9]+%' <<<"$scr" | tail -n 4 || true)"
  fi
  [[ -n "$tail_lines" ]] || return 1
  case "$agent" in
    claude)
      rx="^(you've hit your (5-hour |weekly |session |usage )?limit([[:space:]]*[·•—-][[:space:]]*resets .*)?|claude usage limit reached([[:space:].,·•—-].*)?|out of extra usage([[:space:].,·•—-].*)?)$" ;;
    codex)
      rx="^(you've hit your usage limit\.?([[:space:]]+(upgrade to|try again|resets?).*)?|usage_limit_reached([[:space:]:].*)?)$" ;;
    agy)
      rx="^((individual|model) quota (limit )?reached|weekly quota (limit )?(reached|exceeded|exhausted)|quota exhausted|spend[- ]cap (reached|exceeded)|prepaid[- ]balance (exhausted|depleted|empty)|resource_exhausted:.*(quota|limit|resets in))([[:space:].,:].*)?$" ;;
    grok)
      rx="^(you've hit your usage limit|usage limit reached|credit limit reached|out of credits|insufficient credits)([[:space:].,:].*)?$" ;;
    *)
      rx="^(you've hit your (usage )?limit|usage limit reached|quota exhausted)([[:space:].,:].*)?$" ;;
  esac
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # Reject agent prose/tool markers (Claude ● / ⎿, Codex •, tree/box chars), diffs, comments, code, line numbers.
    if [[ "$mode" != headless ]]; then
      grep -qE '^[[:space:]]*(●|⎿|•|│|├|└|\+|-|#|//|/\*|\*[[:space:]]|\$ |> |`|[0-9]+:[[:space:]])' <<<"$line" && continue
      grep -qE '(rx=|usage_screen_limit|\b(grep|echo|printf|case)\b)' <<<"$line" && continue
    fi
    # Normalize leading/trailing whitespace and optional UI error prefix ("Error: ", "⚠ ", "✖ ", "✕ ", "✗ ", "× ").
    norm="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^(Error:[[:space:]]*|(⚠|✖|✕|✗|×)[[:space:]]*)//i' <<<"$line")"
    [[ -n "$norm" ]] || continue
    if grep -qiE "$rx" <<<"$norm"; then
      hit="${norm:0:200}"
    fi
  done <<<"$tail_lines"
  [[ -n "$hit" ]] || return 1
  local rtxt; rtxt="$(usage_extract_reset_text "$hit")"
  printf '%s\t%s\n' "$hit" "$rtxt"
  return 0
}

# Record a hit-limit event on (machine, agent), keeping existing windows & plan/account metadata.
# Only locks out that specific (machine, agent) record.
usage_record_hit_limit() { # <agent> <machine> <resets_iso_or_empty> <resets_text_or_empty> <task_id_or_empty> <message>
  local a="$1" m="${2:-$(usage_machine_name)}" riso="$3" rtxt="$4" tid="$5" msg="$6" f cur loc=false
  [[ "$m" == "$(usage_machine_name)" ]] && loc=true
  f="$(usage_file "$a" "$m")"
  if [[ -s "$f" ]]; then cur="$(cat "$f" 2>/dev/null || true)"; else cur=""; fi
  if [[ -z "$cur" ]] || ! jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1; then
    cur="$(usage_unknown_record "$a" "$m" "$loc" worker-limit "worker hit usage limit")"
  fi
  # If the error message had no unambiguous ISO reset time, reuse the matching future window reset
  # from the reading (preferring 7d when the message says weekly/7d, 5h when it says 5-hour/session,
  # else the highest-used active future window).
  if [[ -z "$riso" ]]; then
    local now_s want_lbl=""
    now_s="$(date +%s)"
    if grep -qiE 'weekly|7-day|7d' <<<"$msg"; then want_lbl="7d"
    elif grep -qiE '5-hour|5h|session' <<<"$msg"; then want_lbl="5h"; fi
    riso="$(jq -r --argjson now "$now_s" --arg want "$want_lbl" '
      [(.windows // [])[] | select(.resets_at != null)
       | (.resets_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch 0) as $e
       | select($e > $now) | {e: $e, iso: .resets_at, lbl: .label, u: (.used_pct // 0)}] as $futs
      | (if $want != "" then ([$futs[] | select(.lbl == $want)] | first) else null end)
        // ($futs | sort_by([-.u, .e]) | first)
      | .iso // empty' <<<"$cur" 2>/dev/null || true)"
  fi
  cur="$(jq -c --arg at "$(now)" --arg riso "$riso" --arg rtxt "$rtxt" --arg tid "$tid" --arg msg "${msg:0:200}" '
    .hit_limit = {
      at: $at,
      resets_at: (if $riso == "" then null else $riso end),
      resets_text: (if $rtxt == "" then null else $rtxt end),
      task: (if $tid == "" then null else $tid end),
      message: $msg
    }' <<<"$cur")"
  usage_write_record "$a" "$m" "$cur" 1
}

# Called by watch_look (lib/stuck.sh) for each open task and by `node usage-look` on enrolled nodes.
# Detects usage-limit stops on screen (when worker is NOT mid-turn) or headless error output,
# records the agent as out on its own machine only, and logs one `agent: out-of-usage: ...` wake
# per dispatch/steer telling the XO which agents have room.
usage_limit_look() { # <id> <runner> <agent> <screen> [live] [machine]
  local id="$1" r="$2" agent="$3" scr="$4" live="${5:-}" mach="${6:-$(usage_machine_name)}" d text="" mode="screen" match hit rtxt riso when avail f last_sig sig
  [[ -n "$agent" ]] || return 0
  d="$(tdir "$id")"
  case "$r" in
    hc|herdr|tmux|cmux)
      # Never trigger while the worker is actively mid-turn (editing/reading code or outputting prose).
      case "$live" in working|listening|parked|not-started) return 0 ;; esac
      # tmux/cmux report "running" even mid-turn; skip when the active-turn spinner footer is up.
      if grep -qi 'esc to interrupt' <<<"$(tail -n 6 <<<"$scr")"; then return 0; fi
      text="$scr"; mode="screen" ;;
    headless)
      mode="headless"
      if [[ "$agent" == claude ]]; then
        text="$( { jq -r 'select(.type=="result" and .is_error==true) | .result // empty' "$d/claude.jsonl" 2>/dev/null | tail -n 5; tail -n 10 "$d/claude.err" 2>/dev/null; } || true)"
      elif [[ "$agent" == codex ]]; then
        text="$( { jq -r 'select(.type=="error" or .type=="turn.failed") | (.message // .error.message // empty)' "$d/codex.jsonl" 2>/dev/null | tail -n 5; tail -n 10 "$d/codex.err" 2>/dev/null; } || true)"
      fi ;;
    *) return 0 ;;
  esac
  [[ -n "$text" ]] || return 0
  match="$(usage_screen_limit "$agent" "$text" "$mode")" || return 0
  hit="${match%%$'\t'*}"; rtxt="${match#*$'\t'}"
  # Deduplicate per dispatch/steer: one wake until the task is steered or re-dispatched.
  f="$d/.usage-limit"
  local steer_cnt
  events_path "$id"
  steer_cnt="$(grep -c ' steered: ' "$EVENTS_PATH" 2>/dev/null || true)"
  sig="$(meta "$id" dispatched):${steer_cnt:-0}:$agent"
  last_sig="$(cat "$f" 2>/dev/null || true)"
  [[ "$sig" != "$last_sig" ]] || return 0
  printf '%s\n' "$sig" >"$f"
  riso="$(usage_parse_reset_iso "$rtxt")"
  usage_record_hit_limit "$agent" "$mach" "$riso" "$rtxt" "$id" "$hit"
  # On a node guest home, mirror hit_limit into $XDG_STATE_HOME/chartroom/usage so the node's
  # next heartbeat immediately reports this agent out to the brain.
  if [[ -n "${CHARTROOM_GUEST:-}" ]]; then
    ( CR_USAGE_DIR_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom"; usage_record_hit_limit "$agent" "$mach" "$riso" "$rtxt" "$id" "$hit" ) >/dev/null 2>&1 || true
  fi
  # Re-read effective reset time (may have inherited API window reset).
  local rec eff_reset where=""
  rec="$(usage_of "$agent" "$mach")"
  eff_reset="$(jq -r '.out_resets_at // empty' <<<"$rec" 2>/dev/null || true)"
  when="${eff_reset:-${rtxt:-unknown}}"
  avail="$(usage_available_agents "$agent")"
  [[ -z "${CHARTROOM_GUEST:-}" ]] || where=" on $mach"
  log_event "$id" agent "out-of-usage: $agent$where resets $when; available: ${avail:-none} (move with: chartroom move $id)"
}

# ---------------------------------------------------------------- chartroom move (Part 3)

# Move a task off an exhausted (or unwanted) agent onto another agent, keeping the exact same
# brief, branch, worktree, commits, and uncommitted changes. Never discards unlanded work.
cmd_move() {
  migrating_guard move
  local id="" want_agent="" want_backend="" want_node="" dry=0 force=0 no_dispatch=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) [[ $# -ge 2 ]] || die "move: --agent needs a name"; want_agent="$2"; shift 2 ;;
      --backend) [[ $# -ge 2 ]] || die "move: --backend needs a value"; want_backend="$2"; shift 2 ;;
      --node) [[ $# -ge 2 ]] || die "move: --node needs a device or here"; want_node="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      --no-dispatch) no_dispatch=1; shift ;;
      -*) die "usage: chartroom move <id> [--agent A | --backend R:A] [--node DEVICE|here] [--dry-run] [--force] [--no-dispatch]" ;;
      *) [[ -z "$id" ]] || die "move: unexpected arg $1"; id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: chartroom move <id> [--agent A | --backend R:A] [--node DEVICE|here] [--dry-run] [--force] [--no-dispatch]"
  id="$(cmd_resolve "$id" 2>/dev/null || printf '%s' "$id")"
  need_task "$id"
  [[ -z "$(meta "$id" closed)" ]] || die "move: task $id is closed"
  is_joined "$id" && die "move: task $id joined from a running session; it cannot be moved"
  [[ -z "$want_agent" || -z "$want_backend" ]] || die "move: pass either --agent or --backend, not both"

  local old_backend old_runner old_agent wt branch base_sha commits=0 dirty=0 new_backend="" new_agent=""
  old_backend="$(canon_backend "$(meta "$id" backend)")"
  old_runner="$(backend_runner "$id")"
  old_agent="$(backend_agent "$id")"
  wt="$(meta "$id" worktree)"
  branch="$(meta "$id" branch)"
  base_sha="$(meta "$id" base_sha)"

  if [[ -n "$wt" && -d "$wt" ]]; then
    if [[ -n "$base_sha" ]]; then
      commits="$(git -C "$wt" rev-list --count "$base_sha..HEAD" 2>/dev/null || echo 0)"
    fi
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  fi

  # Choose destination backend (never silently picking an exhausted agent, the same agent, or
  # sending a Claude-only task onto codex/agy unless explicitly overridden).
  local needs_claude=0
  if declare -F spread_claude >/dev/null 2>&1 && spread_claude "$id"; then needs_claude=1; fi
  if [[ -n "$want_backend" ]]; then
    valid_backend "$want_backend" || die "move: unknown backend '$want_backend'"
    new_backend="$(canon_backend "$want_backend")"
    new_agent="${new_backend#*:}"
    if [[ "$needs_claude" == 1 && "$new_agent" != claude ]]; then
      warn "move: $id declares Claude-only needs (mcp/browser/claude); moving to $new_backend because --backend was explicit"
    fi
    if [[ "$force" != 1 ]] && usage_agent_out "$new_agent" >/dev/null; then
      die "move: $new_agent is out of usage ($(usage_agent_out "$new_agent")); pass --force to override"
    fi
  elif [[ -n "$want_agent" ]]; then
    [[ "$want_agent" =~ ^($KNOWN_AGENTS)$ ]] || die "move: unknown agent '$want_agent' (known: ${KNOWN_AGENTS//|/, })"
    if [[ "$needs_claude" == 1 && "$want_agent" != claude ]]; then
      warn "move: $id declares Claude-only needs (mcp/browser/claude); moving to $want_agent because --agent was explicit"
    fi
    if [[ "$force" != 1 ]] && usage_agent_out "$want_agent" >/dev/null; then
      die "move: $want_agent is out of usage ($(usage_agent_out "$want_agent")); pass --force to override"
    fi
    local r
    for r in hc herdr tmux cmux headless; do
      agent_runs_on "$want_agent" "$r" || continue
      if probe_backend "$r:$want_agent" >/dev/null 2>&1; then new_backend="$r:$want_agent"; break; fi
    done
    [[ -n "$new_backend" ]] || die "move: no usable runner for $want_agent here (run chartroom doctor)"
    new_agent="$want_agent"
  else
    if [[ "$needs_claude" == 1 && "$force" != 1 ]]; then
      if [[ "$old_agent" == claude ]]; then
        local cwhy; cwhy="$(usage_agent_out claude || true)"
        die "move: $id needs Claude (mcp/browser/claude) and cannot be moved to codex or agy${cwhy:+ ($cwhy)}; wait for reset or pass --agent A / --force to override"
      fi
    fi
    local bs avail pick only_cl=0
    [[ "$needs_claude" == 1 && "$force" != 1 ]] && only_cl=1
    bs="$(spread_local_backends)"
    avail="$(printf '%s\n' "$bs" | jq -Rsc --arg old "$old_agent" 'split("\n") | map(select(length>0) | split(":")[1]) | map(select(. != $old))')"
    pick="$(spread_pick "$(spread_summary "$id")" "$avail" "$only_cl")" || true
    if [[ -n "$pick" ]]; then
      new_backend="$(grep ":$pick$" <<<"$bs" | head -1)"
      new_agent="$pick"
    else
      # Fallback for tmux/cmux/headless setups without hc/herdr: pick first usable backend for another agent.
      local cand ca
      for cand in ${CR_BACKEND_ORDER//,/ }; do
        cand="$(canon_backend "$cand")"
        [[ "$cand" == *:* ]] || continue
        ca="${cand#*:}"
        [[ "$ca" != "$old_agent" ]] || continue
        [[ "$only_cl" != 1 || "$ca" == claude ]] || continue
        usage_agent_out "$ca" >/dev/null && continue
        if probe_backend "$cand" >/dev/null 2>&1; then
          new_backend="$cand"; new_agent="$ca"; break
        fi
      done
    fi
    [[ -n "$new_backend" ]] || die "move: no other signed-in agent with remaining usage is available here (was ${old_agent:-none}; run chartroom usage and chartroom doctor)"
  fi

  if [[ "$dry" -eq 1 ]]; then
    echo "would move $id from ${old_backend:-auto} to $new_backend (keeps branch ${branch:-detached}, $commits commit(s), $dirty uncommitted change(s))"
    return 0
  fi

  # 1. Stop old worker safely without touching the worktree or branch.
  if [[ "$old_runner" == node ]]; then
    node_recall "$id" || die "move: could not recall $id from $(node_name_of "$id"); nothing moved"
  elif [[ -n "$old_runner" && -n "$(meta "$id" dispatched)" ]]; then
    case "$old_runner" in
      hc|herdr|tmux|cmux) "${old_runner}_close" "$id" >/dev/null 2>&1 || true ;;
      headless|command) "${old_runner}_stop" "$id" >/dev/null 2>&1 || true ;;
    esac
  fi

  # 2. Clear runner handles while preserving worktree, worktree_created, branch, base_sha, brief, grants.
  local k
  for k in hc_terminal hc_launched hc_space hc_tab herdr_pane herdr_tab tmux_session tmux_window tmux_pane cmux_workspace cmux_surface pid session_id thread_id parked brief_pending dispatched; do
    [[ -z "$(meta "$id" "$k")" ]] || meta_set "$id" "$k" ""
  done
  rm -f "$(tdir "$id")/.usage-limit" "$(tdir "$id")/.stall"
  meta_set "$id" backend "$new_backend"
  meta_set "$id" backend_source explicit
  meta_set "$id" moved_from "${old_backend:-unknown}"
  if [[ -n "$want_node" ]]; then
    node_pin "$id" "$want_node" >/dev/null
  fi

  # 3. Record handoff instructions in tasks/<id>/inbox.md so the new worker continues cleanly.
  local d; d="$(tdir "$id")"
  {
    printf '\n## Handoff (%s)\n\n' "$(now)"
    printf 'Moved from `%s` to `%s`.\n' "${old_backend:-unknown}" "$new_backend"
    printf 'Existing branch `%s` has %s commit(s) ahead of `%s` and %s uncommitted change(s) in `%s`.\n' \
      "${branch:-HEAD}" "$commits" "${base_sha:0:12}" "$dirty" "${wt:-worktree}"
    printf 'Inspect `git status` and `git log %s..HEAD`, keep all existing commits and work-in-progress, and finish the brief.\n' "${base_sha:-HEAD}"
  } >>"$d/inbox.md"

  log_event "$id" note "moved from ${old_backend:-auto} to $new_backend (kept worktree, branch ${branch:-detached}, $commits commit(s), $dirty uncommitted change(s))"
  echo "moved $id: ${old_backend:-auto} -> $new_backend (kept $commits commit(s), $dirty uncommitted change(s))"

  if [[ "$no_dispatch" -eq 0 ]]; then
    cmd_dispatch "$id"
  fi
}

# ---------------------------------------------------------------- CLI: chartroom usage

# Format seconds into short human duration (e.g. 2m, 3h15m, 2d4h).
# shellcheck disable=SC2016
USAGE_TABLE_JQ='
  def fmt_dur:
    if . == null then "-"
    elif . < 60 then "\(floor)s"
    elif . < 3600 then "\(. / 60 | floor)m"
    elif . < 172800 then "\(. / 3600 | floor)h\(((. % 3600) / 60 | floor) | tostring | if length == 1 then "0" + . else . end)m"
    else "\(. / 86400 | floor)d\(((. % 86400) / 3600 | floor))h" end;
  def fmt_win($now):
    if .used_pct == null then "\(.label): unknown"
    else
      (.resets_epoch as $re
       | if .reset_passed then "\(.label) reset (stale)"
         else "\(.label) \(.used_pct)% used / \(.left_pct)% left"
              + (if $re != null then " (resets in \($re - $now | fmt_dur))" else "" end)
         end)
    end;
  ["AGENT", "MACHINE", "PLAN", "STATE", "WINDOWS", "AGE", "LIVE"],
  (.[] | [
    .agent,
    (if .per_machine then .machine elif (.machines | length) > 1 then "\(.machine) (+\((.machines | length) - 1))" else .machine end),
    ([.plan, .account] | map(select(. != null and . != "")) | join(" · ") | if . == "" then "-" else . end),
    (if .state == "out" then "OUT" + (if .out_resets_at then " (resets \(.out_resets_at))" else "" end)
     elif .state == "near" then "NEAR LIMIT"
     elif .state == "ok" then "ok"
     else "unknown" end),
    (if ((.windows // []) | length) > 0 then ([.windows[] | fmt_win($now)] | join("; "))
     else (.reason // "no data") end),
    (if .age_s == null then "-" else "\(.age_s | fmt_dur) ago" + (if .stale then " (stale)" else "" end) end),
    "\(.live_workers // 0)"
  ]) | @tsv'

cmd_usage() {
  local sub="${1:-}"
  case "$sub" in
    record) shift; cmd_usage_record "$@"; return ;;
    clear) shift; cmd_usage_clear "$@"; return ;;
    probe-tsv) shift; usage_probe_tsv "$@"; return ;;
  esac
  local json=0 refresh=0 only_agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --refresh) refresh=1; shift ;;
      --agent) [[ $# -ge 2 ]] || die "usage: --agent needs a name"; only_agent="$2"; shift 2 ;;
      -h|--help)
        echo "usage: chartroom usage [--json] [--refresh] [--agent A] | usage record <agent> [--from-statusline | --hit-limit [--resets-at ISO] [--task ID] [--message MSG]] | usage clear <agent> [--machine M]"
        return 0 ;;
      *) die "usage: unknown arg $1" ;;
    esac
  done
  if [[ -n "$only_agent" ]]; then
    usage_refresh_agent "$only_agent" "$refresh"
  else
    usage_refresh_local "$refresh"
    usage_sync_nodes
  fi
  local rows
  rows="$(usage_rows_json)"
  if [[ -n "$only_agent" ]]; then
    rows="$(jq -c --arg a "$only_agent" 'map(select(.agent == $a))' <<<"$rows")"
  fi
  if [[ $json -eq 1 ]]; then
    jq . <<<"$rows"
    return 0
  fi
  jq -r --argjson now "$(date +%s)" "$USAGE_TABLE_JQ" <<<"$rows" | table
}

cmd_usage_record() {
  local agent="${1:-}" machine="" mode="statusline" resets_at="" resets_text="" tid="" msg="" plan="" acct=""
  [[ -n "$agent" ]] || die "usage: chartroom usage record <agent> [--machine M] [--from-statusline | --hit-limit [--resets-at ISO] [--task ID] [--message MSG]]"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --machine) machine="$2"; shift 2 ;;
      --from-statusline) mode=statusline; shift ;;
      --hit-limit) mode=hit; shift ;;
      --resets-at) resets_at="$2"; shift 2 ;;
      --resets-text) resets_text="$2"; shift 2 ;;
      --task) tid="$2"; shift 2 ;;
      --message) msg="$2"; shift 2 ;;
      --plan) plan="$2"; shift 2 ;;
      --account) acct="$2"; shift 2 ;;
      *) die "usage record: unknown arg $1" ;;
    esac
  done
  machine="${machine:-$(usage_machine_name)}"
  local loc=false; [[ "$machine" == "$(usage_machine_name)" ]] && loc=true
  if [[ "$mode" == hit ]]; then
    usage_record_hit_limit "$agent" "$machine" "$resets_at" "$resets_text" "$tid" "${msg:-worker hit usage limit}"
    echo "recorded usage limit for $agent on $machine"
    return 0
  fi
  local payload doc
  payload="$(cat)"
  [[ -n "$payload" ]] || die "usage record: expected JSON on stdin"
  case "$agent" in
    claude) doc="$(usage_parse_claude_statusline "$machine" "$loc" "$plan" "$acct" "$(now)" <<<"$payload")" ;;
    codex)
      if jq -e 'has("rateLimits") or has("rateLimitsByLimitId")' <<<"$payload" >/dev/null 2>&1; then
        doc="$(usage_parse_codex_appserver "$machine" "$loc" "$(now)" <<<"$payload")"
      else
        doc="$(usage_parse_codex_event "$machine" "$loc" <<<"$payload")"
      fi ;;
    agy) doc="$(usage_parse_agy_json "$machine" "$loc" "${CR_AGY_MODEL:-}" "$(now)" <<<"$payload")" ;;
    *) die "usage record: unsupported agent '$agent' for JSON record (use --hit-limit to record a limit hit)" ;;
  esac
  usage_write_record "$agent" "$machine" "$doc" 0
  echo "recorded usage for $agent on $machine"
}

cmd_usage_clear() {
  local agent="${1:-}" machine=""
  [[ -n "$agent" ]] || die "usage: chartroom usage clear <agent> [--machine M]"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --machine) machine="$2"; shift 2 ;;
      *) die "usage clear: unknown arg $1" ;;
    esac
  done
  machine="${machine:-$(usage_machine_name)}"
  local f; f="$(usage_file "$agent" "$machine")"
  [[ -s "$f" ]] || { echo "no usage record for $agent on $machine"; return 0; }
  local doc; doc="$(jq -c 'del(.hit_limit) | .limit_reached = false' "$f")"
  usage_write_record "$agent" "$machine" "$doc" 1
  echo "cleared usage-limit lockout for $agent on $machine"
}

# Background refresh from watch's full round: automatically keeps local readings and enrolled
# node heartbeat readings fresh every CR_USAGE_REFRESH_MIN minutes (0 turns it off).
USAGE_WATCH_NEXT=0
usage_watch_refresh() {
  (( CR_USAGE_REFRESH_MIN > 0 )) || return 0
  local now_s; printf -v now_s '%(%s)T' -1
  (( now_s >= USAGE_WATCH_NEXT )) || return 0
  USAGE_WATCH_NEXT=$((now_s + CR_USAGE_REFRESH_MIN * 60))
  CHARTROOM_HOME="$CR_HOME" nohup "$CR_BIN" usage --json </dev/null >/dev/null 2>&1 3>&- &
  return 0
}

# Compact summary for `chartroom doctor`: one line per tracked agent showing usage & exhaustion.
usage_doctor_lines() {
  usage_rows_json | jq -r --argjson now "$(date +%s)" '
    def fmt_dur:
      if . == null then "-"
      elif . < 60 then "\(floor)s"
      elif . < 3600 then "\(. / 60 | floor)m"
      elif . < 172800 then "\(. / 3600 | floor)h\(((. % 3600) / 60 | floor) | tostring | if length == 1 then "0" + . else . end)m"
      else "\(. / 86400 | floor)d\(((. % 86400) / 3600 | floor))h" end;
    .[] | "usage:    \(.agent)"
      + (if .per_machine then " (\(.machine))" else "" end) + ": "
      + (if .state == "out" then "OUT — \(.out_reason // "out of usage")"
         elif .state == "near" then "near limit — " + ([.windows[] | "\(.label) \(.used_pct)% used / \(.left_pct)% left" + (if .resets_at then " (resets \(.resets_at))" else "" end)] | join(", "))
         elif .state == "ok" then ([.windows[] | "\(.label) \(.used_pct)% used / \(.left_pct)% left" + (if .resets_at then " (resets \(.resets_at))" else "" end)] | join(", "))
         else "unknown (\(.reason // "no data"))" end)
      + (if .age_s != null then " [\(.age_s | fmt_dur) ago\(if .stale then ", stale" else "" end)]" else "" end)'
}
