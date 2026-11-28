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

# Build a non-identifying account label (never storing emails or raw org/account IDs).
# Precedence: CHARTROOM_USAGE_ACCOUNT_<AGENT> alias > "<base> #<6-hex sha256>" > "<base>".
usage_account_label() { # <agent> <base_label> [raw_id_in_memory]
  local agent="$1" base="${2:-}" raw_id="${3:-}" upper alias h=""
  upper="${agent^^}"
  alias="$(cfg "USAGE_ACCOUNT_${upper}" '' '')"
  if [[ -n "$alias" ]]; then
    printf '%s' "$alias"
    return 0
  fi
  if [[ -n "$raw_id" ]]; then
    if command -v shasum >/dev/null 2>&1; then h="$(printf '%s:%s' "$agent" "$raw_id" | shasum -a 256 | cut -c1-6)"
    elif command -v sha256sum >/dev/null 2>&1; then h="$(printf '%s:%s' "$agent" "$raw_id" | sha256sum | cut -c1-6)"; fi
  fi
  if [[ -n "$h" ]]; then
    printf '%s #%s' "${base:-$agent}" "$h"
  else
    printf '%s' "$base"
  fi
}

# Write one reading atomically (0600) under a per-record mkdir lock, preserving any active
# hit_limit unless explicitly replaced so concurrent refresh + hit_limit writes never race.
# With [keep_hit_after EPOCH] (a node's heartbeat, usage_sync_nodes) the reading replaces the kept
# one whole, except that a kept limit stop recorded after EPOCH stays: the choice is made under the
# lock, so a stop recorded meanwhile is never lost.
usage_write_record() { # <agent> <machine> <json> [replace_hit 0|1] [keep_hit_after EPOCH]
  local agent="$1" machine="$2" doc="$3" rep="${4:-0}" after="${5:-}" f tmp prev='null' lock i locked=0
  f="$(usage_file "$agent" "$machine")"
  mkdir -p "$(usage_dir)"
  lock="$f.lock"
  for ((i = 0; i < 50; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "${BASHPID:-$$}" >"$lock/pid" 2>/dev/null || true
      locked=1; break
    fi
    local lp; lp="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$lp" =~ ^[0-9]+$ ]] && ! pid_alive "$lp"; then
      rm -rf "$lock"; continue
    fi
    sleep 0.05
  done
  if [[ ( "$rep" != 1 || -n "$after" ) && -s "$f" ]]; then prev="$(cat "$f" 2>/dev/null || echo null)"; fi
  jq -e . >/dev/null 2>&1 <<<"$prev" || prev=null
  doc="$(jq -c --argjson prev "$prev" --argjson rep "$rep" --arg after "$after" '
    def epoch: if . == null then null else (tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null) end;
    if $after != "" then
      (if ($prev | type) == "object" and $prev.hit_limit != null
          and (($prev.hit_limit.at | epoch) // 0) > ($after | tonumber)
          and (($prev.hit_limit.at | epoch) // 0) > ((.hit_limit.at | epoch) // 0)
       then .hit_limit = $prev.hit_limit else . end)
    elif $rep == 1 or ($prev | type) != "object" then .
    else
      # Preserve an existing hit_limit across routine refreshes until its resets_at passes,
      # its cooldown expires, or the user runs `chartroom usage clear`. A worker can be blocked
      # by a spend/scoped/secondary limit even when account-wide windows look below threshold.
      (if (.hit_limit // null) == null and ($prev.hit_limit // null) != null
       then .hit_limit = $prev.hit_limit else . end)
      | if .status == "unknown" and $prev.status == "ok" and ((.windows // []) | length) == 0 and (($prev.windows // []) | length) > 0
           and ((.reason // "") | test("not signed in|not on PATH|not installed|API key"; "i") | not)
        then $prev + {recorded_at: .recorded_at, last_error: .reason, hit_limit: (.hit_limit // $prev.hit_limit)}
        else . end
    end' <<<"$doc")" || { (( locked == 1 )) && rm -rf "$lock"; return 1; }
  tmp="$f.tmp.${BASHPID:-$$}"
  if ( umask 077; printf '%s\n' "$doc" >"$tmp" ) && mv "$tmp" "$f"; then
    (( locked == 1 )) && rm -rf "$lock"
    stamp_changed
  else
    rm -f "$tmp"
    (( locked == 1 )) && rm -rf "$lock"
    return 1
  fi
}

# ---------------------------------------------------------------- shared evaluation (jq)
# Evaluates a raw reading against the current clock and thresholds so CLI, picker, doctor,
# nodes, and the app always agree. Never estimates or invents numbers after reset: a window
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
    | ([$wins[] | select(.state == "out" and ((.scoped // false) | not))]) as $out_wins
    | ([$wins[] | select(.state == "near" and ((.scoped // false) | not))]) as $near_wins
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
    def win($id; $lbl; $obj; $scoped):
      if ($obj | type) == "object" and ($obj.utilization // $obj.used_percentage // $obj.percent) != null then
        (($obj.utilization // $obj.used_percentage // $obj.percent) | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1) as $u
        | [{id: $id, label: $lbl, used_pct: $u, left_pct: ((100 - $u) | r1),
            resets_at: ($obj.resets_at | norm_iso), active: true, scoped: $scoped}]
      else [] end;
    (win("five_hour"; "5h"; .five_hour; false) + win("seven_day"; "7d"; .seven_day; false)) as $w_acct
    | (win("seven_day_opus"; "7d opus"; .seven_day_opus; true)
       + win("seven_day_sonnet"; "7d sonnet"; .seven_day_sonnet; true)) as $w_scoped
    | (if ($w_acct | length) > 0 then ($w_acct + $w_scoped)
       else
         # Account-wide active limits (scope == null) govern exhaustion; model-scoped buckets
         # are kept as informational windows (`scoped: true`, excluded from out/near checks).
         ([(.limits // [])[] | select(.is_active == true and (.scope // null) == null and .percent != null
            and ((.kind // "") == "weekly_all" or (.kind // "") == "five_hour" or (.group // "") == "five_hour" or (.group // "") == "weekly"))
          | ((.percent | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1)) as $u
          | {id: (.kind // .group // "limit"),
             label: (if .group == "weekly" or (.kind // "" | startswith("weekly")) then "7d"
                     elif .group == "five_hour" or (.kind // "" | test("5h|five_hour")) then "5h"
                     else (.kind // .group // "limit") end),
             used_pct: $u, left_pct: ((100 - $u) | r1),
             resets_at: (.resets_at | norm_iso), active: true, scoped: false}]
          + (if ($w_scoped | length) > 0 then $w_scoped
             else [(.limits // [])[] | select((.scope.model // null) != null and .percent != null)
               | ((.percent | tonumber | if . < 0 then 0 elif . > 100 then 100 else . end | r1)) as $u
               | {id: (.kind // "weekly_scoped"),
                  label: ("7d " + ((.scope.model.display_name // "scoped") | ascii_downcase)),
                  used_pct: $u, left_pct: ((100 - $u) | r1),
                  resets_at: (.resets_at | norm_iso), active: (.is_active == true), scoped: true}]
             end))
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
# Args: <machine> <local true|false> [account]
usage_parse_codex_event() {
  local machine="$1" loc="$2" acct="${3:-}"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" --arg acct "$acct" --arg rec "$(now)" '
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
        account: (if $acct == "" then "chatgpt" else $acct end),
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
# Args: <machine> <local true|false> <sampled_at ISO> [account]
usage_parse_codex_appserver() {
  local machine="$1" loc="$2" sampled="${3:-$(now)}" acct="${4:-}"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" \
    --arg sampled "$sampled" --arg acct "$acct" --arg rec "$(now)" '
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
        account: (if $acct == "" then "chatgpt" else $acct end),
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
# Args: <machine> <local true|false> <model_hint> <sampled_at ISO> [account]
usage_parse_agy_json() {
  local machine="$1" loc="$2" hint="${3:-}" sampled="${4:-$(now)}" acct="${5:-}"
  jq -c --argjson schema "$CR_USAGE_SCHEMA" --arg m "$machine" --argjson loc "$loc" \
    --arg hint "$hint" --arg sampled "$sampled" --arg acct "$acct" --arg rec "$(now)" '
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
        account: (if $acct == "" then "google" else $acct end),
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
     status: "unknown", source: $src,
     reason: ($why | gsub("[^[:space:]]+@[^[:space:]]+\\.[^[:space:]]+"; "<email>")),
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
  local m="${1:-$(usage_machine_name)}" b auth="" plan="" acct="" acct_label="" api_prov="" logged="" exp_org="" tok="" out="" code="" url sampled
  sampled="$(now)"
  # Test / offline fixture hook: CHARTROOM_CLAUDE_USAGE_FILE bypasses network cleanly.
  if [[ -n "${CHARTROOM_CLAUDE_USAGE_FILE:-}" && -r "${CHARTROOM_CLAUDE_USAGE_FILE}" ]]; then
    plan="${CHARTROOM_CLAUDE_PLAN:-}"
    acct_label="$(usage_account_label claude "${CHARTROOM_CLAUDE_ACCOUNT:-claude.ai}" "")"
    if out="$(usage_parse_claude_api "$m" true "$plan" "$acct_label" "$sampled" <"$CHARTROOM_CLAUDE_USAGE_FILE" 2>/dev/null)"; then
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
    # Keep orgId in shell memory only to verify credential match and compute a non-identifying 6-hex tag.
    exp_org="$(jq -r '.orgId // ""' <<<"$auth")"
    acct_label="$(usage_account_label claude "${acct:-claude.ai}" "$exp_org")"
    if [[ "$logged" == false ]]; then
      usage_unknown_record claude "$m" true claude-oauth-api "claude is not signed in" "$plan" "$acct_label"
      return 0
    fi
    if [[ -n "$acct" && "$acct" != "claude.ai" && "$acct" != "oauth" ]]; then
      usage_unknown_record claude "$m" true claude-oauth-api "claude uses $acct billing (no subscription rate limits)" "$plan" "$acct_label"
      return 0
    fi
    if [[ -n "$api_prov" && "$api_prov" != "firstParty" ]]; then
      usage_unknown_record claude "$m" true claude-oauth-api "claude uses $api_prov provider (no subscription rate limits)" "$plan" "$acct_label"
      return 0
    fi
  else
    acct_label="$(usage_account_label claude claude.ai "")"
  fi
  tok="$(usage_claude_oauth_token "$exp_org" || true)"
  exp_org=""
  if [[ -z "$tok" ]]; then
    usage_unknown_record claude "$m" true claude-oauth-api "no matching Claude OAuth credential found for active account (use claude /login or pipe statusLine to chartroom usage record claude)" "$plan" "$acct_label"
    return 0
  fi
  url="${CHARTROOM_CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
  local tmp; tmp="$(mktemp)"
  code="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\nheader = "User-Agent: chartroom/%s"\n' "$tok" "${CR_VERSION:-0}" |
    curl -sS -K - --max-time 12 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  tok="" # drop from shell memory promptly
  if [[ "$code" == 200 ]] && out="$(usage_parse_claude_api "$m" true "$plan" "$acct_label" "$sampled" <"$tmp" 2>/dev/null)"; then
    rm -f "$tmp"
    printf '%s\n' "$out"
    return 0
  fi
  rm -f "$tmp"
  usage_unknown_record claude "$m" true claude-oauth-api "Claude usage endpoint returned HTTP ${code:-000}" "$plan" "$acct_label"
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
  local m="${1:-$(usage_machine_name)}" codex_home="${CODEX_HOME:-$HOME/.codex}" b raw sampled sdir f line best="" raw_aid="" acct_label=""
  sampled="$(now)"
  b="$(usage_agent_bin codex)"
  # 1. Live `codex app-server` RPC (matches Codex /status in real time).
  if [[ -n "$b" ]] && raw="$(usage_codex_appserver_read "$b")" && [[ -n "$raw" ]]; then
    if jq -e '(.rateLimitsByLimitId.codex // .rateLimits) | type == "object"' <<<"$raw" >/dev/null 2>&1; then
      # Hash accountId in memory into a non-identifying 6-hex tag; never store raw accountId.
      raw_aid="$(jq -r '.accountId // .rateLimitsByLimitId.codex.accountId // .rateLimits.accountId // ""' <<<"$raw" 2>/dev/null || true)"
      acct_label="$(usage_account_label codex chatgpt "$raw_aid")"
      raw_aid=""
      usage_parse_codex_appserver "$m" true "$sampled" "$acct_label" <<<"$raw"
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
  acct_label="$(usage_account_label codex chatgpt "")"
  usage_parse_codex_event "$m" true "$acct_label" <<<"$best"
}

usage_read_agy() { # [machine]
  local m="${1:-$(usage_machine_name)}" b out rc=0 run=() sampled acct_label=""
  sampled="$(now)"
  acct_label="$(usage_account_label agy google "")"
  b="$(usage_agent_bin agy)"
  if [[ -z "$b" ]]; then
    usage_unknown_record agy "$m" true agy-usage "agy not on PATH" "" "$acct_label"
    return 0
  fi
  if [[ -n "${CHARTROOM_GATE:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
    if declare -F hc_probe >/dev/null 2>&1 && hc_probe >/dev/null 2>&1; then
      run=(env -u HC_TERMINAL_ID "$(hc_bin)" exec --timeout 20 --)
    elif [[ "$(uname -s)" == Darwin ]]; then
      usage_unknown_record agy "$m" true agy-usage "agy quota cannot be read from an ssh session without a running hc core (keychain locked)" "" "$acct_label"
      return 0
    fi
  fi
  if [[ ${#run[@]} -gt 0 ]]; then
    out="$(cd / && "${run[@]}" "$b" --output-format json -p=/usage </dev/null 2>&1)" || rc=$?
  else
    out="$(cd / && run_bounded 20 "$b" --output-format json -p=/usage </dev/null 2>&1)" || rc=$?
  fi
  if [[ $rc -eq 0 ]] && jq -e '.command.name == "usage" and (.command.data.groups | type) == "array"' <<<"$out" >/dev/null 2>&1; then
    usage_parse_agy_json "$m" true "${CR_AGY_MODEL:-}" "$sampled" "$acct_label" <<<"$out"
    return 0
  fi
  local why
  why="$(printf '%s\n' "$out" | tr '\r' '\n' | grep -v '^[[:space:]]*$' | head -1 | cut -c1-180 || true)"
  if grep -qi 'sign in' <<<"$out"; then why="agy is not signed in"
  elif grep -qi 'GEMINI_API_KEY\|API key' <<<"$out"; then why="agy uses GEMINI_API_KEY (no account quota)"
  elif [[ -z "$why" ]]; then why="agy -p=/usage exited $rc"; fi
  usage_unknown_record agy "$m" true agy-usage "$why" "" "$acct_label"
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
usage_refresh_agent() { # <agent> [force 0|1] [machine]
  local a="$1" force="${2:-0}" m="${3:-$(usage_machine_name)}" f rec age_s now_s max_s doc
  f="$(usage_file "$a" "$m")"
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

usage_refresh_local() { # [force 0|1] [machine]
  local force="${1:-0}" m="${2:-$(usage_machine_name)}" a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    usage_refresh_agent "$a" "$force" "$m"
  done < <(usage_agents_list)
}

# Refresh local usage into the node-level state dir ($XDG_STATE_HOME/chartroom/usage) so
# enrolled nodes (which have no CHARTROOM_HOME in launchd) emit live readings in every heartbeat.
# Periodic calls (force=0) run in the background so slow CLIs never delay device heartbeats;
# explicit calls (`chartroom node usage-refresh`, force=1) run synchronously.
USAGE_DEVICE_NEXT=0
usage_device_refresh() { # [force 0|1]
  local force="${1:-0}" now_s m="" cdir pf oldp
  (( CR_USAGE_REFRESH_MIN > 0 || force == 1 )) || return 0
  printf -v now_s '%(%s)T' -1
  (( force == 1 || now_s >= USAGE_DEVICE_NEXT )) || return 0
  USAGE_DEVICE_NEXT=$((now_s + (CR_USAGE_REFRESH_MIN > 0 ? CR_USAGE_REFRESH_MIN : 5) * 60))
  if declare -F device_cfg >/dev/null 2>&1; then m="$(device_cfg NAME 2>/dev/null || true)"; fi
  [[ -n "$m" ]] || m="$(usage_machine_name)"
  cdir="$(usage_node_cache_dir)"
  if [[ "$force" == 1 ]]; then
    (
      CR_USAGE_DIR_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom"
      usage_refresh_local 1 "$m"
    ) >/dev/null 2>&1 || true
    return 0
  fi
  mkdir -p "$cdir"
  pf="$cdir/.refresh.pid"
  if [[ -f "$pf" ]]; then
    oldp="$(cat "$pf" 2>/dev/null || true)"
    if [[ "$oldp" =~ ^[0-9]+$ ]] && pid_alive "$oldp"; then return 0; fi
  fi
  (
    echo "$BASHPID" >"$pf"
    trap 'rm -f "$pf"' EXIT
    CR_USAGE_DIR_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom"
    usage_refresh_local 0 "$m"
  ) </dev/null >/dev/null 2>&1 3>&- &
  return 0
}

# A heartbeat's `usage` line (lib/nodeprobe.sh's header: the one producer) as a schema-1 reading,
# read by the brain's stored records (usage_from_probe_line) and `chartroom nodes` (NODES_ROW_JQ)
# alike, so both judge it with eval_rec as the node judged it. Input: the line's fields, "usage"
# first. A line from an older chartroom has no LIMIT-REACHED or HIT-AT field and no ":s" marks.
# shellcheck disable=SC2016
USAGE_PROBE_JQ='
  def usage_probe_rec($m; $rec):
    def d: if . == null or . == "" or . == "-" then null else . end;
    def r1: ((. * 10 + 0.5) | floor) / 10;
    def ep: d | if . == null then null else (tonumber? // null) | if . != null and . > 0 then floor else null end end;
    def parse_w:
      if . == null or . == "" or . == "-" then []
      else split(",") | map(select(length > 0) | split(":")
        | (.[1] | tonumber? // null) as $u
        | select($u != null)
        | (.[2] | ep) as $re
        | {id: .[0], label: .[0], used_pct: ($u | r1), left_pct: ((100 - $u) | if . < 0 then 0 elif . > 100 then 100 else . end | r1),
           resets_at: (if $re != null then ($re | todate) else null end),
           active: ($re != null)}
          + (if (.[3] // "") == "s" then {scoped: true} else {} end)) end;
    . as $f
    | ($f[8] | ep) as $hre
    | ($f[10] | ep) as $hat
    | {schema: '"$CR_USAGE_SCHEMA"', agent: $f[1], machine: $m, local: false,
       account: ($f[4] | d), plan: ($f[3] | d),
       status: (if $f[2] == "ok" then "ok" else "unknown" end),
       source: "node-probe",
       reason: ($f[7] | d),
       sampled_at: (($f[5] | d) // $rec), recorded_at: $rec,
       windows: ($f[6] | parse_w),
       limit_reached: ($f[9] == "1")}
      + (if $hre != null or $hat != null then
           {hit_limit: {at: (if $hat != null then ($hat | todate) else $rec end),
                        resets_at: (if $hre != null then ($hre | todate) else null end),
                        resets_text: null, task: null, message: "worker hit usage limit on \($m)"}}
         else {} end);
'

# Sync usage lines from remote enrolled devices' last heartbeats into $CHARTROOM_HOME/usage/.
# The node's line is the truth for its own readings, a limit stop and its clearing included; only
# a stop the brain recorded itself (from a node task's wake) after that heartbeat's probe began is
# kept over it. (A probe takes seconds before its heartbeat is heard, hence the minute's margin.)
usage_sync_nodes() {
  declare -F fleet_devices_json >/dev/null 2>&1 || return 0
  local devs n i dev name probe seen line doc
  devs="$(fleet_devices_json 2>/dev/null || echo '[]')"
  n="$(jq length <<<"$devs" 2>/dev/null || echo 0)"
  for ((i = 0; i < n; i++)); do
    dev="$(jq -c --argjson i "$i" '.[$i]' <<<"$devs")"
    [[ "$(jq -r '.status // ""' <<<"$dev")" =~ ^(online|stale)$ ]] || continue
    name="$(jq -r '.name // ""' <<<"$dev")"; probe="$(jq -r '.probe // ""' <<<"$dev")"
    seen="$(jq -r '.last_seen // 0 | tonumber? // 0 | floor' <<<"$dev")"
    [[ -n "$name" && -n "$probe" ]] || continue
    while IFS= read -r line; do
      doc="$(usage_from_probe_line "$name" "$line")" || continue
      [[ -n "$doc" ]] || continue
      usage_write_record "$(jq -r .agent <<<"$doc")" "$name" "$doc" 1 "$((seen - 60))"
    done < <(awk -F'\t' '$1 == "usage" && $2 != "" && $2 != "-" { print }' <<<"$probe")
  done
}

# One heartbeat `usage` line (tab-separated, as lib/nodeprobe.sh prints it) as a schema-1 reading.
usage_from_probe_line() { # <machine> <line>
  jq -cn --arg m "$1" --arg line "$2" --arg rec "$(now)" \
    "$USAGE_PROBE_JQ"'($line | split("\t")) | select(.[0] == "usage" and (.[1] // "-") != "-") | usage_probe_rec($m; $rec)'
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

# Count actually dispatched, open, live workers per (machine, agent) — excluding never-dispatched
# drafts/queued tasks and finished (review/done/failed/closed) tasks.
usage_live_counts_json() {
  local here devs='[]' docs doc id st b r a m
  here="$(usage_machine_name)"
  task_meta_files
  (( ${#TASK_METAS[@]} > 0 )) || { echo '{}'; return 0; }
  if declare -F fleet_devices_json >/dev/null 2>&1; then devs="$(fleet_devices_json 2>/dev/null || echo '[]')"; fi
  docs="$(jq -c 'select((.closed // "") == "" and (.dispatched // "") != "")' "${TASK_METAS[@]}" 2>/dev/null || true)"
  [[ -n "$docs" ]] || { echo '{}'; return 0; }
  while IFS= read -r doc; do
    [[ -n "$doc" ]] || continue
    id="$(jq -r .id <<<"$doc")"
    st="$(state_of "$id" 2>/dev/null || true)"
    case "$st" in review|done|closed|failed) continue ;; esac
    b="$(canon_backend "$(jq -r '.backend // ""' <<<"$doc")")"
    [[ "$b" == *:* ]] || continue
    r="${b%%:*}"; a="${b#*:}"
    if [[ "$r" == node ]]; then
      local nid; nid="$(jq -r '.node // ""' <<<"$doc")"
      m="$(jq -r --arg id "$nid" 'first(.[] | select(.id == $id or .name == $id) | .name) // $id' <<<"$devs" 2>/dev/null || echo "$nid")"
      [[ -n "$m" ]] || m="$here"
    else
      m="$here"
    fi
    printf '%s|%s\n' "$m" "$a"
  done <<<"$docs" | jq -Rsc 'split("\n") | map(select(length > 0)) | group_by(.) | map({key: .[0], value: length}) | from_entries'
}

# JSON array of rows for display (the CLI and the app, lib/app.sh):
# - One row per agent, and per machine where machines differ (different plan, account, status,
#   state, or window percentages). When all machines match for an agent, collapse to one row
#   (preferring the local machine's row, with `machines: [...]`).
# - Enriches each row with `live_workers` counted per (machine, agent) from actually dispatched
#   live workers (summed across `.machines` when a row is collapsed).
# shellcheck disable=SC2120
usage_rows_json() { # [precomputed status_rows JSON array]
  local all live_map here pre_rows="${1:-}"
  all="$(usage_all_json)"
  here="$(usage_machine_name)"
  if [[ -n "$pre_rows" ]]; then
    live_map="$(jq -c --arg here "$here" '
      map(select((.closed // "") == "" and (.dispatched // "") != ""
                 and ((.state // "") | IN("review","done","closed","failed") | not))
          | ((.backend // "") | sub("^herdr-"; "herdr:")) as $b
          | select($b | contains(":"))
          | "\(.machine // $here)|\($b | split(":") | last)")
      | group_by(.) | map({key: .[0], value: length}) | from_entries' <<<"$pre_rows" 2>/dev/null || echo '{}')"
  else
    live_map="$(usage_live_counts_json 2>/dev/null || echo '{}')"
  fi
  jq -cn --argjson all "$all" --argjson lmap "$live_map" --arg here "$here" '
    (["claude", "codex", "agy", "grok"]) as $order
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
    | map(. as $row | . + {live_workers: ([$row.machines[] | ($lmap["\(.)|\($row.agent)"] // 0)] | add // 0)})
    | sort_by([rank(.agent), (if .local then 0 else 1 end), .machine])'
}

# Available agents (excluding <skip_agent> on [skip_machine]) formatted for the XO wake message,
# including local agents and online enrolled nodes' available agents.
usage_available_agents() { # [exclude_agent] [exclude_machine]
  local excl="${1:-}" excl_m="${2:-$(usage_machine_name)}" here a bs="" out=() rec left
  here="$(usage_machine_name)"
  if declare -F spread_local_backends >/dev/null 2>&1; then bs="$(spread_local_backends 2>/dev/null || true)"; fi
  for a in codex agy grok claude; do
    [[ "$a" != "$excl" || "$here" != "$excl_m" ]] || continue
    usage_agent_out "$a" "$here" >/dev/null && continue
    local usable=0
    if [[ "$bs" == *":$a"* ]]; then
      usable=1
    else
      # Fallback for tmux/cmux/headless setups without hc/herdr (mirrors cmd_move).
      local cand
      for cand in ${CR_BACKEND_ORDER//,/ }; do
        cand="$(canon_backend "$cand" 2>/dev/null || printf '%s' "$cand")"
        [[ "$cand" == *":$a" ]] || continue
        if declare -F agent_login_why >/dev/null 2>&1 && ! agent_login_why "$a" >/dev/null 2>&1; then break; fi
        if declare -F probe_backend >/dev/null 2>&1 && probe_backend "$cand" >/dev/null 2>&1; then
          usable=1; break
        fi
      done
    fi
    (( usable == 1 )) || continue
    rec="$(usage_of "$a" "$here")"
    left="$(jq -r 'if .status == "ok" and ((.windows // []) | length) > 0 then ([.windows[] | select((.scoped // false) | not) | select(.reset_passed != true and .left_pct != null) | "\(.label) \(.left_pct | floor)% left"] | join(", ")) else "" end' <<<"$rec" 2>/dev/null || true)"
    out+=("$a${left:+ ($left)}")
  done
  # Also list available agents on online enrolled nodes (excluding the same exhausted node+agent).
  if [[ -z "${CHARTROOM_GUEST:-}" ]] && declare -F fleet_devices_json >/dev/null 2>&1 && declare -F nodes_device_row >/dev/null 2>&1; then
    local devs n i d r nm na
    devs="$(fleet_devices_json 2>/dev/null || echo '[]')"
    n="$(jq length <<<"$devs" 2>/dev/null || echo 0)"
    for ((i = 0; i < n; i++)); do
      d="$(jq -c --argjson i "$i" '.[$i]' <<<"$devs")"
      [[ "$(jq -r '.status // ""' <<<"$d")" == online ]] || continue
      nm="$(jq -r '.name // ""' <<<"$d")"
      [[ -n "$nm" ]] || continue
      nodes_settings 2>/dev/null || true
      r="$(nodes_device_row "$d" "$(date +%s)" 2>/dev/null || true)"
      [[ -n "$r" ]] || continue
      for na in codex agy grok claude; do
        [[ "$na" != "$excl" || "$nm" != "$excl_m" ]] || continue
        jq -e --arg a "$na" '.runner.hc == "up" and .tools[$a].status == "ok" and .logins[$a].status == "ok" and ((.usage[$a].out // false) | not)' <<<"$r" >/dev/null 2>&1 || continue
        usage_agent_out "$na" "$nm" >/dev/null && continue
        out+=("$na on $nm")
      done
    done
  fi
  local one joined=""
  for one in "${out[@]+"${out[@]}"}"; do joined+="${joined:+, }$one"; done
  printf '%s' "$joined"
}

# ---------------------------------------------------------------- worker limit-stop detection (Part 3)

# Extract a human-readable reset time phrase from a usage-limit error line, or empty.
# Handles: "resets Nov 23 at 3am (America/Denver)", "resets 3pm (America/Los_Angeles)",
# "try again at 3:05 PM", "Resets in 1 hour 20 minutes.", "Claude AI usage limit reached|1795900000".
# Note: grep -E operates line-by-line; never put \n inside [...] (that excludes literal 'n').
usage_extract_reset_text() { # <text>
  local t=""
  # Pipe-epoch suffix from Claude headless: "Claude AI usage limit reached|1795900000"
  if [[ "$1" =~ \|([0-9]{10})([^0-9]|$) ]]; then
    printf '|%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  # Match "resets <time>", "reset at <time>", "try again at <time>", "try again in <dur>", "Resets in <dur>"
  # Stop at sentence-ending dot/semicolon or middle-dot separator (· / •) so trailing "· progress saved" is excluded.
  t="$(grep -oiE '(resets? (at |in )?[^.;·•]+|try again (at |in )[^.;·•]+)' <<<"$1" | head -1 || true)"
  t="$(sed -E 's/^(resets?|try again)[[:space:]]+(at|in)[[:space:]]+//i; s/^resets?[[:space:]]+//i; s/[[:space:]]+$//' <<<"$t")"
  # Keep "in <dur>" marker when it was a relative duration so parser knows it's relative.
  if grep -qiE '(resets?|try again)[[:space:]]+in[[:space:]]+' <<<"$1" && [[ -n "$t" ]]; then
    t="in $t"
  fi
  printf '%s' "${t:0:80}"
}

# Convert a reset phrase into an ISO-8601 UTC timestamp when parseable:
# - Pipe-epoch ("|1795900000")
# - ISO-8601 UTC ("2026-11-30T10:00:00Z" or "2026-11-30 10:00 UTC")
# - Relative duration ("in 1 hour 20 minutes", "in 2 days 3 hours 10 minutes", "in 4h 30m")
# - Explicit timezone ("Nov 23 at 3am (America/Denver)", "3pm (America/Denver)", "Nov 30, 10am (UTC)")
# - Local wall-clock time ("3:05 PM", "Nov 30, 10am") resolved in the machine's local timezone
# Returns empty when unparseable (caller falls back to matching API window resets_at or cooldown).
# With [earliest_stop_epoch], the earliest the stop itself can have happened (its transcript entry,
# its output file, or the last look that saw the worker not stopped), a clock-only time ("3am",
# "3:05 PM") is the first such time after that moment, and a relative one ("in 2 hours") counts
# from it: never from when the stop was first noticed, which can be hours later (a closed watch, a
# sleeping machine). Without it, a clock-only time is today's unless that passed over 6 hours ago.
usage_parse_reset_iso() { # <reset_text> [now_epoch] [earliest_stop_epoch]
  local txt="$1" now_s="${2:-$(date +%s)}" since_s="${3:-}"
  [[ "$since_s" =~ ^[0-9]+$ ]] || since_s=""
  [[ -n "$txt" ]] || return 0
  # Pipe-epoch ("|1795900000")?
  if [[ "$txt" =~ ^\|([0-9]{10})$ ]]; then
    jq -rn --argjson t "${BASH_REMATCH[1]}" '$t | todate'
    return 0
  fi
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
      local target=$((${since_s:-$now_s} + 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s))
      jq -rn --argjson t "$target" '$t | todate'
      return 0
    fi
  fi
  # Wall-clock formats with optional IANA timezone "(America/Denver)", "UTC", or machine local timezone:
  # e.g. "Nov 23 at 3am (America/Denver)", "3pm (America/Denver)", "Nov 30, 10am (UTC)", "3:05 PM", "14:30 UTC"
  local py; py="$(cfg PYTHON '' python3)"
  if command -v "$py" >/dev/null 2>&1; then
    "$py" - "$txt" "$now_s" "$since_s" <<'PY' 2>/dev/null || true
import datetime, re, sys
try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

txt, now_s = sys.argv[1].strip(), int(sys.argv[2])
since_s = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else None
tz = None
t = txt
# Check for parenthesized IANA timezone or UTC, e.g. "(America/Denver)" or "(UTC)"
m_tz = re.search(r'\(([A-Za-z0-9_./+-]+)\)\s*$', t)
if m_tz:
    zname = m_tz.group(1)
    t = t[:m_tz.start()].strip(' ,.')
    if zname.upper() in ('UTC', 'GMT', 'Z'):
        tz = datetime.timezone.utc
    elif ZoneInfo is not None:
        try:
            tz = ZoneInfo(zname)
        except Exception:
            sys.exit(0)
elif re.search(r'\b(UTC|GMT)\b', t, re.I):
    tz = datetime.timezone.utc
    t = re.sub(r'\b(UTC|GMT)\b', '', t, flags=re.I).strip(' ,.')
else:
    # Local timezone of this machine (for Codex's "3:05 PM" etc.)
    tz = datetime.datetime.now().astimezone().tzinfo

now = datetime.datetime.fromtimestamp(now_s, tz=tz)
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

# "Nov 23 at 3am", "Nov 30, 10:30am", "Nov 30 10am", "Nov 30th, 2026 3:05 PM"
m = re.match(r'^([A-Za-z]{3})[a-z]*\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?:[,\s]+(?:at\s+)?)(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)$', t, re.I)
if m and m.group(1).lower() in months:
    clk = parse_clock(m.group(4))
    if clk:
        mon, day = months[m.group(1).lower()], int(m.group(2))
        yr = int(m.group(3)) if m.group(3) else now.year
        dt = datetime.datetime(yr, mon, day, clk[0], clk[1], tzinfo=tz)
        # Only roll to next year across the Dec -> Jan boundary (within 30 days ahead),
        # never turning a recent past date (e.g. Nov 23 read on Nov 26) into a 1-year lockout.
        if not m.group(3) and dt < now:
            dt_next = datetime.datetime(yr + 1, mon, day, clk[0], clk[1], tzinfo=tz)
            if (dt_next - now) <= datetime.timedelta(days=30):
                dt = dt_next
        print(dt.astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        sys.exit(0)

# Time-only "3pm", "3:05 PM", "14:30".
# If the clock time already passed within the last 6 hours (e.g. a stale banner first noticed
# after its reset hour), keep today's past timestamp so it is treated as already reset instead
# of falsely locking out for ~23 hours. Roll to tomorrow only when > 6h behind (e.g. 11pm -> 3am).
# With the earliest the stop can have happened, it is the first such time after that: exact for a
# stop whose time is known, and never a lockout for one first noticed long after its reset.
clk = parse_clock(t)
if clk and since_s is not None:
    since = datetime.datetime.fromtimestamp(since_s, tz=tz)
    dt = since.replace(hour=clk[0], minute=clk[1], second=0, microsecond=0)
    if dt <= since:
        dt += datetime.timedelta(days=1)
elif clk:
    dt = now.replace(hour=clk[0], minute=clk[1], second=0, microsecond=0)
    if dt <= now and (now - dt) > datetime.timedelta(hours=6):
        dt += datetime.timedelta(days=1)
if clk:
    print(dt.astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
  fi
  return 0
}

# Check a Claude worker's structured session transcript for a trailing usage-limit API error.
# Claude Code records `isApiErrorMessage:true, apiError:"usage_limit_reached"` on the exact
# message where it stopped. A generic transient 429 (`error:"rate_limit"` without
# `apiError:"usage_limit_reached"`) only matches if its text is a real anchored limit banner.
# Exit codes:
#   0 = authoritative limit stop found (prints "<text>\t<reset_text>\t<the entry's epoch, or empty>")
#   1 = authoritative transcript file exists and shows NO limit stop (do NOT fall back to screen)
#   2 = no readable transcript file found for this session_id
usage_claude_transcript_limit() { # <session_id>
  local sid="$1" cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" f="" row="" api_err="" txt=""
  [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || return 2
  shopt -s nullglob
  local matches=("$cfg_dir"/projects/*/"$sid.jsonl")
  if (( ${#matches[@]} == 0 )) && [[ "$cfg_dir" != "$HOME/.claude" ]]; then
    matches=("$HOME"/.claude/projects/*/"$sid.jsonl")
  fi
  shopt -u nullglob
  (( ${#matches[@]} > 0 )) || return 2
  f="${matches[0]}"
  [[ -r "$f" ]] || return 2
  row="$(tail -n 30 "$f" 2>/dev/null | jq -rs '
    [.[] | select(type == "object" and (.type == "assistant" or .type == "user"))]
    | last // empty
    | select(.type == "assistant" and .isApiErrorMessage == true
        and ((.apiError // "") == "usage_limit_reached" or (.error // "") == "rate_limit"))
    | [((.timestamp // "") | tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try (fromdateiso8601 | tostring) catch "")),
       (.apiError // ""),
       ((.message.content | if type == "array" then ([.[] | select(.type == "text") | .text] | join(" ")) else (. // "") end)
        | gsub("[\r\n\t]+"; " ") | gsub("^ +| +$"; ""))] | @tsv' 2>/dev/null || true)"
  [[ -n "$row" ]] || return 1
  local at="${row%%$'\t'*}"; row="${row#*$'\t'}"
  api_err="${row%%$'\t'*}"; txt="${row#*$'\t'}"
  [[ -n "$txt" ]] || return 1
  if [[ "$api_err" != usage_limit_reached ]]; then
    usage_screen_limit claude "$txt" headless >/dev/null || return 1
  fi
  local rtxt; rtxt="$(usage_extract_reset_text "$txt")"
  printf '%s\t%s\t%s\n' "${txt:0:200}" "$rtxt" "$at"
  return 0
}

# Detect a real plan/subscription usage-limit stop in a worker's screen tail or headless output.
# Prints "<matched_text>\t<reset_text>" on match (rc 0), or nothing (rc 1).
# Grounded in real strings extracted from the installed binaries (codex-cli 0.160.0, claude 2.1.332,
# agy 1.5.18, grok) and real Claude transcripts:
#   - Normalizes curly apostrophe U+2019 (’) to straight ' and strips TUI error markers (■, ⚠, ✖, ✕, ✗, ×, Error:).
#   - In screen mode, tracks prose/tool blocks (●, ⎿, •, ✦, │, ├, └, diffs, code) across the
#     bottom 20 non-footer lines so indented continuations quoting a limit banner NEVER match,
#     and evaluates only the bottom 4 lines.
#   - In screen mode for Codex, requires the real TUI error marker (■ / Error: / ⚠ / ✖) at col 0.
#   - Joins up to 2 wrapped continuation lines after a matched banner so wrapped reset times survive.
usage_screen_limit() { # <agent> <screen_or_output> [screen|headless]
  local agent="$1" scr="$2" mode="${3:-screen}" filtered="" line norm hit="" rx=""
  local -a raw_lines=() nb_idx=()
  if [[ "$mode" == headless ]]; then
    filtered="$(grep -vE '^[[:space:]]*$' <<<"$scr" | tail -n 8 || true)"
  else
    # Strip [hc] notes, box dividers, and interactive prompt/status-bar footers, preserving blank
    # lines so paragraph boundaries after prose markers (● / • / ✦ / ⎿) stay visible across up to
    # 30 tail lines before evaluating only the bottom 4 non-blank output lines.
    filtered="$(grep -vE '^\[hc\] |^[[:space:]]*[─━═┄┈-]{3,}[[:space:]]*$|^[[:space:]]*[╭╰][─━═┄┈].*[╮╯][[:space:]]*$|^[[:space:]]*│[[:space:]]*(❯|›|>)[[:space:]]*│[[:space:]]*$|^[[:space:]]*(❯|›|>)[[:space:]]*$|shift\+tab to cycle|Shift\+Tab:mode|for shortcuts|\? for help|esc to cancel|Ask Codex to do anything|Type a message|^[[:space:]]*[0-9]+% (left|context)|^[[:space:]]*ctx [[:space:]0-9]+%' <<<"$scr" | tail -n 30 || true)"
  fi
  [[ -n "$filtered" ]] || return 1
  local idx=0
  while IFS= read -r line; do
    raw_lines+=("$line")
    if [[ "$line" =~ [^[:space:]] ]]; then nb_idx+=("$idx"); fi
    idx=$((idx + 1))
  done <<<"$filtered"
  local n=${#raw_lines[@]} nb_n=${#nb_idx[@]}
  (( nb_n > 0 )) || return 1
  case "$agent" in
    claude)
      rx="^(you've hit your (5-hour |weekly |session |usage |monthly spend |channel's monthly spend |fast )?limit([[:space:].,·•—-].*)?|you're out of usage credits([[:space:].,·•—-].*)?|your org is out of usage([[:space:].,·•—-].*)?|claude( ai)? usage limit reached([[:space:].,·•—|-].*)?|out of extra usage([[:space:].,·•—-].*)?|goal paused[[:space:]]*[·•—-][[:space:]]*usage limit reached.*)$" ;;
    codex)
      rx="^(you've hit your usage limit\.([[:space:]].*)?|usage_limit_reached([[:space:]:].*)?)$" ;;
    agy)
      # Real strings present in the agy 1.5.18 binary (live interactive stop layout unverified).
      rx="^(usage limit reached|individual quota reached|resource_exhausted:.*(quota|limit|exhausted your capacity)|.*exhausted your capacity)([[:space:].,:].*)?$" ;;
    grok)
      # Real strings present in the grok 1.0.92 binary.
      rx="^(you hit your (free usage|weekly) limit\.?|you've hit the (credit|rate) limit for your plan\.?|you've hit your spending cap\.?|you've hit your team's api rate limit\.?|you've reached your free grok build usage limit( for now)?\.?)([[:space:]].*)?$" ;;
    *)
      rx="^(you've hit your (usage )?limit|usage limit reached|quota exhausted)([[:space:].,:].*)?$" ;;
  esac
  # Bottom 4 non-blank output lines are eligible in screen mode; all 8 in headless mode.
  local min_raw_idx=0
  if [[ "$mode" != headless ]] && (( nb_n > 4 )); then
    min_raw_idx="${nb_idx[$((nb_n - 4))]}"
  fi
  local in_prose=0 i j hit_idx=-1
  for ((i = 0; i < n; i++)); do
    line="${raw_lines[$i]}"
    if [[ ! "$line" =~ [^[:space:]] ]]; then
      in_prose=0; continue
    fi
    if [[ "$mode" != headless ]]; then
      # Prose/tool/diff/code prefixes start a prose paragraph and never match.
      if grep -qE '^[[:space:]]*(●|⎿|•|✦|│|├|└|\+|-|#|//|/\*|\*[[:space:]]|\$ |> |`|[0-9]+:[[:space:]])' <<<"$line"; then
        in_prose=1; continue
      fi
      # Explicit TUI error marker at col 0 (■ / ⚠ / ✖ / Error:) breaks out of any prose block.
      local has_err_mark=0
      if grep -qE '^[[:space:]]?(■|⚠|✖|✕|✗|×|Error:)' <<<"$line"; then
        has_err_mark=1; in_prose=0
      fi
      # Any continuation line inside a prose paragraph (indented OR wrapped to column 0),
      # or any line indented by 2+ spaces, is quoted prose rather than an agent error banner.
      if [[ "$in_prose" == 1 ]] || [[ "$line" =~ ^[[:space:]]{2,} ]]; then
        continue
      fi
      (( i >= min_raw_idx )) || continue
      grep -qE '(rx=|usage_screen_limit|\b(grep|echo|printf|case)\b)' <<<"$line" && continue
      # Codex TUI renders its own limit banner with a leading error marker (■ / Error: / ⚠ / ✖).
      if [[ "$agent" == codex && "$has_err_mark" != 1 ]]; then
        continue
      fi
    fi
    # Normalize curly apostrophe (U+2019 -> '), trim whitespace, strip TUI error prefixes.
    norm="$(sed -E "s/’/'/g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^(Error:[[:space:]]*|(■|⚠|✖|✕|✗|×)[[:space:]]*)//i" <<<"$line")"
    [[ -n "$norm" ]] || continue
    if grep -qiE "$rx" <<<"$norm"; then
      hit="$norm"
      hit_idx=$i
    fi
  done
  (( hit_idx >= 0 )) || return 1
  # Join up to 2 wrapped continuation lines after the matched banner so reset times split across
  # lines (e.g. Codex wrapping "... visit\nhttps://... or try again at 3:05 PM.") are preserved.
  local joined="$hit" nxt
  for ((j = hit_idx + 1; j <= hit_idx + 2 && j < n; j++)); do
    nxt="${raw_lines[$j]}"
    [[ "$nxt" =~ [^[:space:]] ]] || break
    if [[ "$mode" != headless ]] && grep -qE '^[[:space:]]*(●|⎿|•|✦|■|⚠|✖|✕|✗|×|❯|›|>)' <<<"$nxt"; then
      break
    fi
    nxt="$(sed -E "s/’/'/g; s/^[[:space:]]+//; s/[[:space:]]+$//" <<<"$nxt")"
    [[ -n "$nxt" ]] || break
    joined+=" $nxt"
  done
  local rtxt; rtxt="$(usage_extract_reset_text "$joined")"
  printf '%s\t%s\n' "${joined:0:200}" "$rtxt"
  return 0
}

# Record a hit-limit event on (machine, agent), keeping existing windows & plan/account metadata.
# Only locks out that specific (machine, agent) record.
# Optional 7th arg: force_local=1 (for enrolled nodes where device NAME may differ from hostname).
usage_record_hit_limit() { # <agent> <machine> <resets_iso_or_empty> <resets_text_or_empty> <task_id_or_empty> <message> [force_local 0|1]
  local a="$1" m="${2:-$(usage_machine_name)}" riso="$3" rtxt="$4" tid="$5" msg="$6" fl="${7:-0}" f cur loc=false
  if [[ "$fl" == 1 || "$m" == "$(usage_machine_name)" ]]; then loc=true; fi
  f="$(usage_file "$a" "$m")"
  if [[ -s "$f" ]]; then cur="$(cat "$f" 2>/dev/null || true)"; else cur=""; fi
  if [[ -z "$cur" ]] || ! jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1; then
    cur="$(usage_unknown_record "$a" "$m" "$loc" worker-limit "worker hit usage limit")"
  elif [[ "$fl" == 1 ]]; then
    cur="$(jq -c '.local = true' <<<"$cur")"
  fi
  # If the error message had no parseable ISO reset time, reuse the matching future window reset
  # from the reading (preferring 7d for weekly/monthly/7d, 5h for 5-hour/session, else longest future window).
  if [[ -z "$riso" ]]; then
    local now_s want_lbl=""
    now_s="$(date +%s)"
    if grep -qiE 'weekly|7-day|7d|monthly' <<<"$msg"; then want_lbl="7d"
    elif grep -qiE '5-hour|5h|session' <<<"$msg"; then want_lbl="5h"; fi
    riso="$(jq -r --argjson now "$now_s" --arg want "$want_lbl" '
      [(.windows // [])[] | select(.resets_at != null)
       | (.resets_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch 0) as $e
       | select($e > $now) | {e: $e, iso: .resets_at, lbl: .label, u: (.used_pct // 0)}] as $futs
      | (if $want != "" then ([$futs[] | select(.lbl == $want)] | first) else null end)
        // ($futs | sort_by([-.u, -.e]) | first)
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

usage_mtime() { local m; m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)"; [[ "$m" =~ ^[0-9]+$ ]] && printf '%s' "$m"; }
usage_seen_clear() { : >"$1/.usage-clear" 2>/dev/null || true; }

# Called by watch_look (lib/stuck.sh) for each open task and by `node usage-look` on enrolled nodes.
# Detects usage-limit stops via:
#   1. Structured Claude session transcript API error (zero false positives, works under ⎿)
#   2. Structured headless error JSONL (claude.jsonl / codex.jsonl, including error.code == usage_limit_reached)
#   3. Anchored terminal limit-stop banners on idle/stopped session workers (never while mid-turn)
# Records the agent as out on its own machine only, and logs one `agent: out-of-usage: ...` wake.
# A look that finds no stop leaves <task>/.usage-clear (its mtime: the last time the worker was seen
# not stopped), the earliest a stop seen later can have happened, which a clock-only reset is read
# from (usage_parse_reset_iso).
usage_limit_look() { # <id> <runner> <agent> <screen> [live] [machine]
  local id="$1" r="$2" agent="$3" scr="$4" live="${5:-}" mach="${6:-$(usage_machine_name)}" d text="" mode="screen" match="" hit rtxt riso when avail f last_sig sig sid since="" m
  [[ -n "$agent" ]] || return 0
  d="$(tdir "$id")"
  case "$r" in
    hc|herdr|tmux|cmux)
      # Never trigger while the worker is actively mid-turn (editing/reading code or outputting prose).
      # A worker seen working again has resumed, however it was resumed (a steer, hc keys, attach, a
      # person's answer), so its next limit stop is a new one and raises its own wake.
      case "$live" in
        working) rm -f "$d/.usage-limit"; usage_seen_clear "$d"; return 0 ;;
        listening|parked|not-started) usage_seen_clear "$d"; return 0 ;;
      esac
      if grep -qi 'esc to interrupt' <<<"$(tail -n 6 <<<"$scr")"; then rm -f "$d/.usage-limit"; usage_seen_clear "$d"; return 0; fi
      # 1. For Claude workers, prefer the structured transcript signal when session_id is known.
      # When a readable transcript exists and shows no limit stop (rc 1), trust it and NEVER fall
      # back to screen scraping (prevents false lockouts when a reply quotes a limit banner).
      if [[ "$agent" == claude ]]; then
        sid="$(meta "$id" session_id 2>/dev/null || true)"
        if [[ -n "$sid" ]]; then
          local tr_rc=0
          match="$(usage_claude_transcript_limit "$sid")" || tr_rc=$?
          if [[ $tr_rc -eq 1 ]]; then usage_seen_clear "$d"; return 0; fi
          [[ $tr_rc -eq 0 ]] || match=""
        fi
      fi
      if [[ -z "$match" ]]; then
        text="$scr"; mode="screen"
      fi ;;
    headless)
      mode="headless"
      if [[ "$agent" == claude ]]; then
        sid="$(meta "$id" session_id 2>/dev/null || true)"
        if [[ -n "$sid" ]] && match="$(usage_claude_transcript_limit "$sid")"; then :; else match=""; fi
        if [[ -z "$match" ]]; then
          text="$( {
            jq -r 'if .type=="result" and .is_error==true then .result // empty
                   elif .isApiErrorMessage==true and ((.apiError // "")=="usage_limit_reached" or (.error // "")=="rate_limit") then
                     (.message.content | if type=="array" then ([.[] | select(.type=="text") | .text] | join(" ")) else (. // "") end)
                   else empty end' "$d/claude.jsonl" 2>/dev/null | tail -n 5
            tail -n 10 "$d/claude.err" 2>/dev/null
          } || true)"
        fi
      elif [[ "$agent" == codex ]]; then
        text="$( {
          jq -r 'select(.type=="error" or .type=="turn.failed")
            | [(.code // .error.code // empty), (.message // .error.message // empty)] | map(select(length > 0)) | join(": ")' "$d/codex.jsonl" 2>/dev/null | tail -n 5
          tail -n 10 "$d/codex.err" 2>/dev/null
        } || true)"
      fi
      # (a headless stop is the last thing its output files took: their newest mtime is its time)
      for f in "$d/claude.jsonl" "$d/claude.err" "$d/codex.jsonl" "$d/codex.err"; do
        m="$(usage_mtime "$f")" || continue
        [[ -n "$since" ]] && (( since >= m )) || since="$m"
      done ;;
    *) return 0 ;;
  esac
  if [[ -z "$match" ]]; then
    [[ -n "$text" ]] || { usage_seen_clear "$d"; return 0; }
    match="$(usage_screen_limit "$agent" "$text" "$mode")" || { usage_seen_clear "$d"; return 0; }
  fi
  hit="${match%%$'\t'*}"; rtxt="${match#*$'\t'}"
  # The earliest the stop can have happened: the transcript entry's own time when there is one, the
  # headless output's (above), else the last look that saw the worker not stopped, or its dispatch.
  if [[ "$rtxt" == *$'\t'* ]]; then
    m="${rtxt#*$'\t'}"; rtxt="${rtxt%%$'\t'*}"
    [[ ! "$m" =~ ^[0-9]+$ ]] || since="$m"
  fi
  if [[ -z "$since" && "$mode" == screen ]]; then
    since="$(usage_mtime "$d/.usage-clear" || true)"
    m="$(meta "$id" dispatched 2>/dev/null || true)"
    m="$(jq -rn --arg t "$m" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch empty)' 2>/dev/null || true)"
    if [[ "$m" =~ ^[0-9]+$ ]] && { [[ -z "$since" ]] || (( m > since )); }; then since="$m"; fi
  fi
  # One wake per stop: the same stop stays on screen across looks, so it is raised again only
  # after a re-dispatch, a steer, the worker seen working (above), or a stop with another reset.
  f="$d/.usage-limit"
  local steer_cnt
  events_path "$id"
  steer_cnt="$(grep -c ' steered: ' "$EVENTS_PATH" 2>/dev/null || true)"
  sig="$(meta "$id" dispatched):${steer_cnt:-0}:$agent:$rtxt"
  last_sig="$(cat "$f" 2>/dev/null || true)"
  [[ "$sig" != "$last_sig" ]] || return 0
  printf '%s\n' "$sig" >"$f"
  riso="$(usage_parse_reset_iso "$rtxt" "" "$since")"
  usage_record_hit_limit "$agent" "$mach" "$riso" "$rtxt" "$id" "$hit" 0
  # On a node guest home, mirror hit_limit into $XDG_STATE_HOME/chartroom/usage with force_local=1
  # so the node's next heartbeat reports this agent out even when device NAME != hostname.
  if [[ -n "${CHARTROOM_GUEST:-}" ]]; then
    ( CR_USAGE_DIR_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom"; usage_record_hit_limit "$agent" "$mach" "$riso" "$rtxt" "$id" "$hit" 1 ) >/dev/null 2>&1 || true
  fi
  # Re-read effective reset time (may have inherited API window reset).
  local rec eff_reset where=""
  rec="$(usage_of "$agent" "$mach")"
  eff_reset="$(jq -r '.out_resets_at // empty' <<<"$rec" 2>/dev/null || true)"
  when="${eff_reset:-${rtxt:-unknown}}"
  avail="$(usage_available_agents "$agent" "$mach")"
  [[ -z "${CHARTROOM_GUEST:-}" ]] || where=" on $mach"
  log_event "$id" agent "out-of-usage: $agent$where resets $when; available: ${avail:-none} (move with: chartroom move $id)"
  LOOK_LOGGED=1
}

# ---------------------------------------------------------------- chartroom move (Part 3)

# Returns 0 (and prints reason) if <agent> on <machine> is out of usage according to either
# the brain's stored record or an optional pre-built nodes_device_row JSON.
usage_target_out() { # <agent> <machine> [node_row_json]
  local ca="$1" tm="$2" trow="${3:-}" why=""
  if why="$(usage_agent_out "$ca" "$tm")"; then
    printf '%s' "$why"
    return 0
  fi
  if [[ -n "$trow" ]] && jq -e --arg a "$ca" '.usage[$a].out == true' <<<"$trow" >/dev/null 2>&1; then
    jq -r --arg a "$ca" '.usage[$a].out_reason // "\($a) is out of usage"' <<<"$trow"
    return 0
  fi
  return 1
}

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

  # Resolve target machine BEFORE selecting agent or stopping the old worker, so a bad node
  # or an exhausted agent on the target node fails cleanly without disturbing the running worker.
  local target_machine="" target_dev_json="" target_is_remote=0 target_row=""
  local here_m; here_m="$(usage_machine_name)"
  if [[ -n "$want_node" && "$want_node" != here && "$want_node" != any && "$want_node" != none && "$want_node" != "$here_m" ]]; then
    local tdid=""
    declare -F fleet_resolve >/dev/null 2>&1 || die "move: unknown node '$want_node'"
    tdid="$(fleet_resolve "$want_node")" || exit 1
    target_dev_json="$(fleet_device_json "$tdid")"
    [[ "$(jq -r '.status // ""' <<<"$target_dev_json")" != revoked ]] || die "move: $want_node is revoked"
    jq -e '.caps | index("dispatch")' <<<"$target_dev_json" >/dev/null 2>&1 ||
      die "move: $want_node's agent cannot take work yet (chartroom node update $want_node)"
    node_home >/dev/null
    target_machine="$(jq -r '.name // empty' <<<"$target_dev_json")"
    target_is_remote=1
    if declare -F nodes_device_row >/dev/null 2>&1; then
      nodes_settings 2>/dev/null || true
      target_row="$(nodes_device_row "$target_dev_json" "$(date +%s)" 2>/dev/null || true)"
    fi
  fi
  target_machine="${target_machine:-$here_m}"

  # Never move a started task onto another machine: remote dispatch starts from base_sha and
  # would strand local unpushed commits or uncommitted worktree edits. Moving a remote node task
  # back to this machine (`--node here` or no `--node`) is safe because node_recall bundles its branch home.
  if [[ "$target_is_remote" == 1 ]]; then
    local proj_has_branch=0 proj_dir; proj_dir="$(meta "$id" project)"
    if [[ -n "$branch" && -n "$proj_dir" ]] && git -C "$proj_dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
      proj_has_branch=1
    fi
    if [[ -n "$wt" && -d "$wt" ]] || (( commits > 0 || dirty > 0 || proj_has_branch == 1 )) || [[ "$old_runner" == node ]] || [[ -n "$(meta "$id" dispatched)" ]]; then
      die "move: cannot move $id to another machine ($target_machine) after work has started: remote dispatch starts from base_sha and would strand unpushed commits or worktree edits (move locally with 'chartroom move $id', or recall home with 'chartroom move $id --node here')"
    fi
  fi

  local target_uwhy=""

  # Choose destination backend (never silently picking an exhausted agent, the same agent on the
  # same machine, or sending a Claude-only task onto codex/agy unless explicitly overridden).
  local needs_claude=0
  if declare -F spread_claude >/dev/null 2>&1 && spread_claude "$id"; then needs_claude=1; fi
  if [[ -n "$want_backend" ]]; then
    valid_backend "$want_backend" || die "move: unknown backend '$want_backend'"
    new_backend="$(canon_backend "$want_backend")"
    new_agent="${new_backend#*:}"
    if [[ "$needs_claude" == 1 && "$new_agent" != claude ]]; then
      warn "move: $id declares Claude-only needs (mcp/browser/claude); moving to $new_backend because --backend was explicit"
    fi
    if [[ "$target_is_remote" == 1 ]]; then
      local nb; nb="$(node_backends)"
      [[ "$new_backend" =~ ^($nb)$ ]] || die "move: only ${nb//|/ and } run on another machine (got $new_backend)"
    fi
    if [[ "$force" != 1 ]] && target_uwhy="$(usage_target_out "$new_agent" "$target_machine" "$target_row")"; then
      die "move: $new_agent on $target_machine is out of usage ($target_uwhy); pass --force to override"
    fi
  elif [[ -n "$want_agent" ]]; then
    [[ "$want_agent" =~ ^($KNOWN_AGENTS)$ ]] || die "move: unknown agent '$want_agent' (known: ${KNOWN_AGENTS//|/, })"
    if [[ "$needs_claude" == 1 && "$want_agent" != claude ]]; then
      warn "move: $id declares Claude-only needs (mcp/browser/claude); moving to $want_agent because --agent was explicit"
    fi
    if [[ "$force" != 1 ]] && target_uwhy="$(usage_target_out "$want_agent" "$target_machine" "$target_row")"; then
      die "move: $want_agent on $target_machine is out of usage ($target_uwhy); pass --force to override"
    fi
    if [[ "$target_is_remote" == 1 ]]; then
      local nb; nb="$(node_backends)"
      [[ "hc:$want_agent" =~ ^($nb)$ ]] || die "move: $want_agent cannot run on another machine (supported: ${nb//|/, })"
      if [[ -n "$target_row" ]]; then
        [[ "$(jq -r '.runner.hc // ""' <<<"$target_row")" == up ]] || die "move: hc is not answering on $target_machine"
        [[ "$(jq -r --arg a "$want_agent" '.tools[$a].status // "missing"' <<<"$target_row")" == ok ]] || die "move: $want_agent is not installed on $target_machine"
        [[ "$(jq -r --arg a "$want_agent" '.logins[$a].status // "missing"' <<<"$target_row")" == ok ]] || die "move: $want_agent is not signed in on $target_machine"
      fi
      new_backend="hc:$want_agent"
    else
      local r
      for r in hc herdr tmux cmux headless; do
        agent_runs_on "$want_agent" "$r" || continue
        if probe_backend "$r:$want_agent" >/dev/null 2>&1; then new_backend="$r:$want_agent"; break; fi
      done
      [[ -n "$new_backend" ]] || die "move: no usable runner for $want_agent here (run chartroom doctor)"
    fi
    new_agent="$want_agent"
  else
    local same_machine=1
    if [[ "$target_is_remote" == 1 ]]; then
      [[ "$old_runner" == node && "$(node_name_of "$id")" == "$target_machine" ]] || same_machine=0
    elif [[ "$old_runner" == node ]]; then
      same_machine=0
    fi
    if [[ "$needs_claude" == 1 && "$force" != 1 && "$same_machine" == 1 && "$old_agent" == claude ]]; then
      local cwhy; cwhy="$(usage_agent_out claude "$target_machine" || true)"
      die "move: $id needs Claude (mcp/browser/claude) and cannot be moved to codex, agy or grok${cwhy:+ ($cwhy)}; wait for reset or pass --agent A / --force to override"
    fi
    local avail pick only_cl=0
    [[ "$needs_claude" == 1 && "$force" != 1 ]] && only_cl=1
    if [[ "$target_is_remote" == 1 ]]; then
      local srow
      srow="$(spread_node_agents "[$target_row]" | jq -c '.[0]')"
      avail="$(jq -c --arg old "$old_agent" --argjson same "$same_machine" '(.spread_agents // []) | if $same == 1 then map(select(. != $old)) else . end' <<<"$srow")"
      pick="$(spread_pick "$(spread_summary "$id")" "$avail" "$only_cl")" || true
      [[ -n "$pick" ]] || die "move: no signed-in agent with remaining usage is available on $target_machine (run chartroom usage and chartroom nodes)"
      new_backend="hc:$pick"
      new_agent="$pick"
    else
      local bs
      bs="$(spread_local_backends)"
      avail="$(printf '%s\n' "$bs" | jq -Rsc --arg old "$old_agent" --argjson same "$same_machine" 'split("\n") | map(select(length>0) | split(":")[1]) | if $same == 1 then map(select(. != $old)) else . end')"
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
          [[ "$same_machine" != 1 || "$ca" != "$old_agent" ]] || continue
          [[ "$only_cl" != 1 || "$ca" == claude ]] || continue
          usage_agent_out "$ca" >/dev/null && continue
          if probe_backend "$cand" >/dev/null 2>&1; then
            new_backend="$cand"; new_agent="$ca"; break
          fi
        done
      fi
      [[ -n "$new_backend" ]] || die "move: no other signed-in agent with remaining usage is available here (was ${old_agent:-none}; run chartroom usage and chartroom doctor)"
    fi
  fi

  if [[ "$dry" -eq 1 ]]; then
    local target_suffix=""
    [[ "$target_is_remote" == 1 ]] && target_suffix=" on $target_machine"
    echo "would move $id from ${old_backend:-auto} to $new_backend$target_suffix (keeps branch ${branch:-detached}, $commits commit(s), $dirty uncommitted change(s))"
    return 0
  fi

  # Pre-check dispatch readiness BEFORE stopping the old worker so a broken brief or unplaceable
  # target node fails cleanly without leaving the task undispatched.
  if [[ "$no_dispatch" -eq 0 ]]; then
    grep -qE '^## Spec' "$(tdir "$id")/brief.md" || die "move: brief is missing its Spec section; nothing moved"
    if ! grep -A3 -E "^## (Commander|Captain)'s intent" "$(tdir "$id")/brief.md" | grep -qvE "^(## |<!--|\s*$)"; then
      die "move: brief has no commander's intent yet; nothing moved"
    fi
    if [[ "$target_is_remote" == 1 ]]; then
      [[ "$needs_claude" != 1 ]] || die "move: Claude-only tools are configured on this machine; cannot move $id to $target_machine"
      if declare -F place_stays >/dev/null 2>&1; then
        local stays; stays="$(place_stays "$id")"
        if [[ -n "$stays" && "$stays" != "pinned here" ]]; then
          die "move: cannot move $id to $target_machine: $stays"
        fi
      fi
    fi
  fi

  # 1. Stop old worker safely without touching the worktree or branch.
  if [[ "$old_runner" == node ]]; then
    node_recall "$id" || die "move: could not recall $id from $(node_name_of "$id"); nothing moved"
    # Recall brings the branch home to the brain's project repo; recount commits from it.
    if [[ -n "$branch" && -n "$base_sha" ]]; then
      local proj; proj="$(meta "$id" project)"
      if [[ -n "$proj" && -d "$proj" ]]; then
        commits="$(git -C "$proj" rev-list --count "$base_sha..refs/heads/$branch" 2>/dev/null || echo "$commits")"
      fi
    fi
  elif [[ -n "$old_runner" && -n "$(meta "$id" dispatched)" ]]; then
    case "$old_runner" in
      hc|herdr|tmux|cmux) "${old_runner}_close" "$id" >/dev/null 2>&1 || true ;;
      headless|command) "${old_runner}_stop" "$id" >/dev/null 2>&1 || true ;;
    esac
  fi

  # 2. Clear runner handles while preserving worktree, worktree_created, branch, base_sha, brief, grants.
  # When switching agents, also clear agent-specific launch settings (model, effort, permission, sandbox)
  # so a Claude model name is never passed to Codex/agy/grok (and vice versa), and preserve the non-Claude
  # cold-review requirement whenever work started on codex, agy or grok moves onto claude.
  local k cleared=()
  for k in hc_terminal hc_launched hc_space hc_tab herdr_pane herdr_tab tmux_session tmux_window tmux_pane cmux_workspace cmux_surface pid session_id thread_id parked brief_pending dispatched; do
    [[ -z "$(meta "$id" "$k")" ]] || meta_set "$id" "$k" ""
  done
  if [[ "$old_agent" != "$new_agent" ]]; then
    for k in model effort permission sandbox; do
      local oldv; oldv="$(meta "$id" "$k")"
      if [[ -n "$oldv" ]]; then
        meta_set "$id" "$k" ""
        cleared+=("$k=$oldv")
      fi
    done
    if [[ "$(meta "$id" kind)" == ship && "$old_agent" =~ ^(codex|agy|grok)$ ]]; then
      meta_set "$id" review_required 1
    fi
  fi
  rm -f "$(tdir "$id")/.usage-limit" "$(tdir "$id")/.stall"
  meta_set "$id" backend "$new_backend"
  meta_set "$id" backend_source explicit
  meta_set "$id" moved_from "${old_backend:-unknown}"
  if [[ -n "$want_node" ]]; then
    meta_set "$id" node_backend ""
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

  local cleared_note=""
  if (( ${#cleared[@]} > 0 )); then
    local one joined=""
    for one in "${cleared[@]}"; do joined+="${joined:+, }$one"; done
    cleared_note="; cleared $joined"
  fi
  log_event "$id" note "moved from ${old_backend:-auto} to $new_backend (kept worktree, branch ${branch:-detached}, $commits commit(s), $dirty uncommitted change(s)$cleared_note)"
  echo "moved $id: ${old_backend:-auto} -> $new_backend (kept $commits commit(s), $dirty uncommitted change(s)$cleared_note)"

  if [[ "$no_dispatch" -eq 0 ]]; then
    if ! ( cmd_dispatch "$id" ); then
      log_event "$id" note "moved to $new_backend but dispatch failed; worktree and commits are intact (run: chartroom dispatch $id)"
      die "move: $id switched to $new_backend (worktree and commits intact), but dispatch failed — run: chartroom dispatch $id"
    fi
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
  local payload doc eff_acct
  payload="$(cat)"
  [[ -n "$payload" ]] || die "usage record: expected JSON on stdin"
  case "$agent" in
    claude)
      eff_acct="${acct:-$(usage_account_label claude claude.ai "")}"
      doc="$(usage_parse_claude_statusline "$machine" "$loc" "$plan" "$eff_acct" "$(now)" <<<"$payload")" ;;
    codex)
      if jq -e 'has("rateLimits") or has("rateLimitsByLimitId")' <<<"$payload" >/dev/null 2>&1; then
        local raw_aid=""
        raw_aid="$(jq -r '.accountId // .rateLimitsByLimitId.codex.accountId // .rateLimits.accountId // ""' <<<"$payload" 2>/dev/null || true)"
        eff_acct="${acct:-$(usage_account_label codex chatgpt "$raw_aid")}"
        raw_aid=""
        doc="$(usage_parse_codex_appserver "$machine" "$loc" "$(now)" "$eff_acct" <<<"$payload")"
      else
        eff_acct="${acct:-$(usage_account_label codex chatgpt "")}"
        doc="$(usage_parse_codex_event "$machine" "$loc" "$eff_acct" <<<"$payload")"
      fi ;;
    agy)
      eff_acct="${acct:-$(usage_account_label agy google "")}"
      doc="$(usage_parse_agy_json "$machine" "$loc" "${CR_AGY_MODEL:-}" "$(now)" "$eff_acct" <<<"$payload")" ;;
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
  # one refresh at a time: a slow one (agy through hc, many Codex sessions) is let finish, never doubled
  local pf oldp
  pf="$(usage_dir)/.watch-refresh.pid"
  mkdir -p "$(usage_dir)" 2>/dev/null || return 0
  oldp="$(cat "$pf" 2>/dev/null || true)"
  if [[ "$oldp" =~ ^[0-9]+$ ]] && pid_alive "$oldp"; then return 0; fi
  CHARTROOM_HOME="$CR_HOME" nohup "$CR_BIN" usage --json </dev/null >/dev/null 2>&1 3>&- &
  printf '%s\n' "$!" >"$pf" 2>/dev/null || true
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
