# shellcheck shell=bash
# permit.sh - the permission broker: a Claude worker's permission prompts become chartroom cards.
#
# Every Claude worker chartroom launches carries three hooks (claude_settings_file):
#   PreToolUse        `hook <id> pre-tool`    guards (deny), grants and always rules (allow); a call
#                                             the commander must see is sent to a prompt ("ask"),
#                                             or, for a headless worker that has no prompt, held here
#   PermissionRequest `hook <id> permission`  a prompt Claude would show: the policy answers it, or
#                                             it becomes a card the hook waits on (CHARTROOM_PERMIT_WAIT
#                                             seconds, 900), then denies
#   PermissionDenied  `hook <id> denied`      auto mode's classifier refused a call: recorded, and a
#                                             card offers the commander to allow a retry
# The policy is lib/permit.jq, the one place its rules live. Its record sits under
# $CR_HOME/permits/<task>/, outside every directory the worker is given:
#   grants.json          the task's grants (push-branch, open-pr, merge-auto, comment-pr)
#   <p-id>.json          a card: the call, why, the rule that sent it, the "always" pattern
#   <p-id>.answer.json   its answer, written once (noclobber): the first answer wins
#   <p-id>.late.json     an answer given after the card expired (a one-time pre-approval)
#   always.ndjson        "Always for this task" patterns
#   pre/<sig>            one-time pre-approvals of an exact call, by its signature
# Every outcome is a `permit:` line in the task's events.log, so the trail says who allowed what.
# close moves the directory into the task's record (tasks/<id>/permits), where nothing trusts it.

PERMIT_GRANTS='push-branch|open-pr|merge-auto|comment-pr'
PERMIT_ANSWERS='once|always|deny'

permit_root() { printf '%s/permits' "$CR_HOME"; }
permit_wait_text() { if (( CR_PERMIT_WAIT % 60 == 0 )); then printf '%sm' "$((CR_PERMIT_WAIT / 60))"; else printf '%ss' "$CR_PERMIT_WAIT"; fi; }
permit_tdir() { printf '%s/permits/%s' "$CR_HOME" "$1"; }

permit_grants_json() { # <id>
  local f; f="$(permit_tdir "$1")/grants.json"
  if [[ -s "$f" ]]; then jq -c 'if type == "array" then . else [] end' "$f" 2>/dev/null || echo '[]'; else echo '[]'; fi
}
permit_always_json() { # <id>
  local f; f="$(permit_tdir "$1")/always.ndjson"
  if [[ -s "$f" ]]; then jq -s -c '[.[] | select(type == "object")]' "$f" 2>/dev/null || echo '[]'; else echo '[]'; fi
}

# A call's signature: the tool and its input, less the parts that do not change what it does.
permit_sig() { # <tool> <input json>
  jq -cS --arg t "$1" '{t: $t, i: (. | if type == "object" then del(.description, .timeout, .run_in_background, .dangerouslyDisableSandbox) else . end)}' <<<"$2" | text_sig
}

permit_new_id() {
  local t
  while :; do
    t="p-$(rand_hex4)"
    compgen -G "$(permit_root)/*/$t.json" >/dev/null || { printf '%s' "$t"; return; }
  done
}
permit_find() { # <p-id> -> the task id, or 1
  local f
  [[ "$1" =~ ^p-[0-9a-f]{4,}$ ]] || return 1
  for f in "$(permit_root)"/*/"$1.json"; do
    [[ -f "$f" ]] || continue
    f="${f%/*}"; printf '%s' "${f##*/}"; return 0
  done
  return 1
}

# The call as one short phrase for events and cards: Bash "<command>", Edit <path>, or the tool.
permit_desc() { # <tool> <input json>
  jq -r --arg t "$1" '
    def cap(n): gsub("[[:space:]]+"; " ") | if length > n then .[0:n] + "..." else . end;
    if $t == "Bash" then "Bash \"\(.command // "" | cap(160))\""
    elif (.file_path // .notebook_path // .path // "") != "" then "\($t) \(.file_path // .notebook_path // .path)"
    elif (.url // "") != "" then "\($t) \(.url | cap(120))"
    else $t end' <<<"$2" 2>/dev/null || printf '%s' "$1"
}

# The policy's input for one hook payload (lib/permit.jq's header says what each field is). It runs
# before every tool call of every worker, so it reads the payload and the task's record once each, and the
# call's signature only when a pre-approval or an "always" record could need it.
permit_query() { # <id> <event> <payload>
  local id="$1" ev="$2" payload="$3" tool cmd cur="" wt branch sig="" pre="" pd
  pd="$(permit_tdir "$id")"
  { IFS= read -r tool; IFS= read -r cmd; } < <(jq -r '(.tool_name // ""), ((.tool_input.command | strings) // "" | gsub("\n"; " ") | .[0:4000])' <<<"$payload") || return 1
  [[ -n "$tool" ]] || return 1
  meta_path "$id"; [[ -n "$META_PATH" ]] || return 1
  store_uid_of # STORE_DB: the database the home's records went into (the policy guards it)
  { IFS= read -r wt; IFS= read -r branch; } < <(jq -r '(.worktree // ""), (.branch // "")' "$META_PATH") || return 1
  # The worktree's branch, only when a grant could need it.
  if [[ "$tool" == Bash && -s "$pd/grants.json" && -n "$wt" && -d "$wt" && "$cmd" =~ (^|[^A-Za-z0-9_-])(git|gh)[[:space:]] ]]; then
    cur="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
  fi
  if [[ -d "$pd/pre" || -s "$pd/always.ndjson" ]]; then
    sig="$(permit_sig "$tool" "$(jq -c '.tool_input // {}' <<<"$payload")")"
    [[ -f "$pd/pre/$sig" ]] && pre="$(cat "$pd/pre/$sig" 2>/dev/null || true)"
  fi
  jq -c --arg ev "$ev" --arg sig "$sig" \
    --arg wt "$wt" --arg td "$(tdir "$id")" --arg permits "$(permit_root)" --arg uh "$HOME" --arg db "${STORE_DB:-$CR_DB}" \
    --arg branch "$branch" --arg cur "$cur" --argjson grants "$(permit_grants_json "$id")" \
    --argjson always "$(permit_always_json "$id")" --arg pre "$pre" '
    {event: $ev, tool: .tool_name, input: (.tool_input // {}), sig: $sig, cwd: (.cwd // $wt),
     roots: {worktree: $wt, task_dir: $td, scratch: (.scratchpad_dir // ""), permits: $permits, user_home: $uh, db: $db},
     branch: $branch, current_branch: $cur, grants: $grants, always: $always, pre: (if $pre == "" then null else $pre end)}' <<<"$payload"
}

permit_decide() { jq -c -f "$CR_ROOT/lib/permit.jq" <<<"$1"; } # <query json> -> verdict json

# What a hook prints for its event: allow, deny <message>, or ask <reason> (PreToolUse only).
permit_reply() { # <event> <allow|deny|ask> [message]
  case "$1" in
    pre-tool) jq -cn --arg d "$2" --arg r "${3:-}" '{hookSpecificOutput: ({hookEventName: "PreToolUse", permissionDecision: $d} + (if $r != "" then {permissionDecisionReason: $r} else {} end))}' ;;
    permission)
      if [[ "$2" == allow ]]; then jq -cn '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
      else jq -cn --arg m "${3:-}" '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $m}}}'; fi ;;
  esac
}

permit_log() { log_event "$1" permit "$2" >/dev/null 2>&1 || true; } # <id> <text>

# The "Always for this task" pattern a card offers: Claude's own suggested rule for Bash, the
# path for a file tool, otherwise the exact call.
permit_pattern() { # <tool> <payload> <sig>
  jq -r --arg t "$1" --arg sig "$3" '
    if $t == "Bash" then
      ([.permission_suggestions[]? | select(.type == "addRules" and (.behavior // "allow") == "allow") | .rules[]? | select(.toolName == "Bash") | .ruleContent | strings | select(. != "")] | first)
      // (.tool_input.command // "")
    elif (.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // "") != "" then (.tool_input.file_path // .tool_input.notebook_path // .tool_input.path)
    else "sig:\($sig)" end' <<<"$2"
}

# Write a card and its `permit: asks` line (the watch wakes on it). Prints the card's id.
permit_card() { # <id> <event> <payload> <verdict json> <blocking 1|0>
  local id="$1" ev="$2" payload="$3" v="$4" blocking="$5" pid tool input sig d now_s desc pattern
  pid="$(permit_new_id)"; d="$(permit_tdir "$id")"; mkdir -p "$d"
  tool="$(jq -r '.tool_name' <<<"$payload")"; input="$(jq -c '.tool_input // {}' <<<"$payload")"
  sig="$(permit_sig "$tool" "$input")"; now_s="$(date +%s)"
  desc="$(permit_desc "$tool" "$input")"; pattern="$(permit_pattern "$tool" "$payload" "$sig")"
  jq -n --arg id "$pid" --arg task "$id" --arg ev "$ev" --arg tool "$tool" --argjson input "$input" --arg sig "$sig" \
    --argjson v "$v" --arg desc "$desc" --arg pattern "$pattern" --argjson now "$now_s" --argjson wait "$CR_PERMIT_WAIT" \
    --argjson blocking "$blocking" --argjson p "$payload" '
    def cap(n): if length > n then .[0:n] + "..." else . end;
    {id: $id, task: $task, created: ($now | todate), created_epoch: $now, expires_epoch: ($now + $wait),
     event: $ev, blocking: ($blocking == 1), tool: $tool, input: $input, sig: $sig, desc: $desc,
     cwd: ($p.cwd // ""), why: (($input.description // "") | cap(300)), rule: $v.rule, reason: $v.why,
     pattern: $pattern, reason_denied: ($p.reason // null), session_id: ($p.session_id // null),
     transcript: ($p.transcript_path // null), transcript_off: ($toff | tonumber)}' --arg toff "$(permit_size "$(jq -r '.transcript_path // ""' <<<"$payload")")" >"$d/$pid.json.tmp" &&
    mv "$d/$pid.json.tmp" "$d/$pid.json"
  if [[ "$blocking" == 1 ]]; then
    permit_log "$id" "asks $pid: $desc ($(jq -r '.rule' <<<"$v"), $(jq -r '.why' <<<"$v")); waits $(permit_wait_text), then denies. Answer: chartroom permit answer $pid once|always|deny [--note <text>] (always allows \`${pattern:0:160}\` until the task closes)"
  else
    permit_log "$id" "asks $pid: allow a retry of $desc, which auto mode refused ($(jq -r '.reason // "no reason given"' <<<"$payload" | tr '\n' ' ' | cut -c1-120)). Answer: chartroom permit answer $pid once|always|deny [--note <text>] (always allows \`${pattern:0:160}\` until the task closes)"
  fi
  printf '%s' "$pid"
}

permit_size() { if [[ -n "$1" && -f "$1" ]]; then wc -c <"$1" | tr -d ' '; else echo 0; fi; } # <file>

# The transcript's id for the call a card waits on: the newest tool_use of that tool with that input.
permit_tool_use_id() { # <card file>
  local t; t="$(jq -r '.transcript // ""' "$1")"
  [[ -n "$t" && -f "$t" ]] || return 0
  tail -c 4000000 "$t" 2>/dev/null | jq -r --slurpfile c "$1" '
    select(.type == "assistant") | .message.content[]? | select(type == "object" and .type == "tool_use")
    | select(.name == $c[0].tool and .input == $c[0].input) | .id' 2>/dev/null | tail -n 1
}

# Write an answer once: 0 written, 1 there already.
permit_write_once() { ( set -o noclobber; printf '%s\n' "$2" >"$1" ) 2>/dev/null; } # <file> <json>

# Wait for a card's answer, up to its expiry, into PERMIT_ANSWER (in this shell, not a subshell, so
# a signal is handled within a second). An expired card is answered "expired" by chartroom itself,
# unless an answer won the race. If Claude goes on without it (its terminal's dialog was answered,
# which cancels the hook, or the worker stopped), the card is closed as "lapsed" at once.
permit_wait() { # <id> <p-id>
  local id="$1" pid="$2" d ans exp parent="$PPID" tuid="" tr off n=0
  d="$(permit_tdir "$id")"; ans="$d/$pid.answer.json"
  exp="$(jq -r '.expires_epoch' "$d/$pid.json")"
  tr="$(jq -r '.transcript // ""' "$d/$pid.json")"; off="$(jq -r '.transcript_off // 0' "$d/$pid.json")"
  # shellcheck disable=SC2064 # the ids, now
  trap "permit_lapse $(printf '%q %q' "$id" "$pid"); exit 0" TERM INT HUP
  while [[ ! -f "$ans" ]]; do
    if [[ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != "$parent" ]]; then permit_lapse "$id" "$pid"; break; fi
    # Claude does not stop this hook when its terminal answers the prompt: its transcript shows the
    # call's result instead (verified on 2.1.330), checked every few seconds.
    if [[ -n "$tr" && $((n++ % 3)) -eq 0 ]]; then
      [[ -n "$tuid" ]] || tuid="$(permit_tool_use_id "$d/$pid.json")"
      if [[ -n "$tuid" ]] && tail -c +"$((off + 1))" "$tr" 2>/dev/null | grep -qF "\"tool_use_id\":\"$tuid\""; then permit_lapse "$id" "$pid" "its terminal answered the prompt"; break; fi
    fi
    if [[ -n "$(meta_file "$id" closed 2>/dev/null)" ]]; then
      permit_write_once "$ans" "$(jq -cn '{answer: "deny", by: "chartroom", note: "the task was closed", at: (now | todate)}')" || true
      break
    fi
    if (( $(date +%s) >= exp )); then
      if permit_write_once "$ans" "$(jq -cn '{answer: "expired", by: "chartroom", at: (now | todate)}')"; then
        permit_log "$id" "denied $pid: no answer within $(permit_wait_text) (expired)"
      fi
      break
    fi
    sleep 1
  done
  trap - TERM INT HUP
  PERMIT_ANSWER="$(cat "$ans" 2>/dev/null || echo '{"answer":"expired"}')"
}
permit_lapse() { # <id> <p-id> [why]
  permit_write_once "$(permit_tdir "$1")/$2.answer.json" "$(jq -cn --arg w "${3:-it stopped, or its terminal answered the prompt}" '{answer: "lapsed", by: "chartroom", why: $w, at: (now | todate)}')" &&
    permit_log "$1" "closed $2: the worker went on without chartroom's answer (${3:-it stopped, or its terminal answered the prompt})"
}

# The message a worker reads with a deny.
permit_deny_message() { # <answer json> <p-id>
  jq -r --arg p "$2" --arg m "$(permit_wait_text)" '
    if .answer == "expired" then "No answer from the commander within \($m) (permission card \($p)), so this did not run. Post a `decision` event naming what you need and why, then carry on with other work or stop."
    elif .by == "chartroom" then "chartroom denied this (permission card \($p)): \(.note // "no answer")."
    else "The commander denied this (permission card \($p))\(if (.note // "") != "" then ": \(.note)" else "" end). Do not retry it; carry on with other work, or post a `decision` event if you are blocked." end' <<<"$1"
}

# A hook's whole job for one payload. Never fails the agent: with no verdict it prints nothing,
# and Claude's own flow (the classifier, or the terminal's dialog) goes on as before.
permit_hook() { # <event> <id> <payload>
  local ev="$1" id="$2" payload="$3" q v verdict rule why tool input desc pid ans a r
  q="$(permit_query "$id" "$ev" "$payload" 2>/dev/null)" || return 0
  [[ -n "$q" ]] || return 0
  v="$(permit_decide "$q" 2>/dev/null)" || return 0
  IFS=$'\t' read -r verdict rule why < <(jq -r '[.verdict // "none", .rule // "", .why // ""] | @tsv' <<<"$v")
  [[ "$verdict" == none && "$ev" != denied ]] && return 0 # the common case: nothing to say or log
  tool="$(jq -r '.tool' <<<"$q")"; input="$(jq -c '.input' <<<"$q")"; desc="$(permit_desc "$tool" "$input")"
  if [[ "$ev" == denied ]]; then permit_denied "$id" "$payload" "$q" "$desc"; return 0; fi
  case "$verdict" in
    deny)
      permit_reply "$ev" deny "chartroom refused this: it $why ($rule). A worker may not answer its own permission cards or change chartroom's records; if you need this, post a \`decision\` event saying why."
      permit_log "$id" "refused $desc ($rule)" ;;
    allow)
      permit_reply "$ev" allow
      case "$rule" in
        preapproved:*) rm -f "$(permit_tdir "$id")/pre/$(jq -r '.sig' <<<"$q")"; a="once, as the commander allowed (${rule#preapproved:})" ;;
        always:*) a="by the commander's always rule (${rule#always:})" ;;
        grant:*) a="by the task's grant (${rule#grant:})" ;;
        *) a="by policy ($rule)" ;;
      esac
      permit_log "$id" "allowed $desc $a" ;;
    card)
      if [[ "$ev" == pre-tool && "$(backend_runner "$id")" != headless ]]; then
        # An interactive worker shows a prompt for "ask", which reaches the permission hook.
        permit_reply pre-tool ask "chartroom: this needs the commander ($rule: $why). A permission card is waiting for their answer."
        return 0
      fi
      pid="$(permit_card "$id" "$ev" "$payload" "$v" 1)" || return 0
      PERMIT_ANSWER=""; permit_wait "$id" "$pid"; ans="$PERMIT_ANSWER"
      a="$(jq -r '.answer // "expired"' <<<"$ans")"
      case "$a" in
        once|always) permit_reply "$ev" allow ;;
        *) r="$(permit_deny_message "$ans" "$pid")"; permit_reply "$ev" deny "$r" ;;
      esac ;;
  esac
  return 0
}

# Auto mode refused a call: record it, say so when a chartroom allow should have covered it (then
# the hook's allow did not reach the classifier), and offer the commander a retry card.
permit_denied() { # <id> <payload> <query> <desc>
  local id="$1" payload="$2" q="$3" desc="$4" reason v
  reason="$(jq -r '.reason // "no reason given"' <<<"$payload" | tr '\n' ' ' | cut -c1-200)"
  v="$(permit_decide "$(jq -c '.event = "pre-tool"' <<<"$q")" 2>/dev/null || echo '{}')"
  if [[ "$(jq -r '.verdict // ""' <<<"$v")" == allow ]]; then
    permit_log "$id" "auto mode refused $desc although chartroom allowed it ($(jq -r '.rule' <<<"$v")): the hook's allow did not pre-empt the classifier. Reason: $reason"
  else
    permit_log "$id" "auto mode refused $desc. Reason: $reason"
  fi
  [[ "$(jq -r '.verdict // ""' <<<"$v")" == deny ]] && return 0 # a guard's call: never a retry card
  permit_card "$id" denied "$payload" "$(jq -c '{rule: (.rule // "classifier"), why: (.why // "")}' <<<"$v")" 0 >/dev/null || true
}

# ---------------------------------------------------------------- answers and grants

# 0 when this process runs under a chartroom worker: its environment says so, or an ancestor is a
# claude started with a task's claude-settings.json (every launched Claude worker is), in any home,
# while that file exists. Neither the environment nor the config decides it, since a worker sets
# both. The XO, the app and the commander's terminal have no such ancestor. A process that detaches
# itself from its worker (a double fork) escapes this check: the PreToolUse guard, which refuses
# any tool call that answers a permit or touches the record, is the first line.
permit_from_worker() {
  [[ -n "${CHARTROOM_TASK:-}" ]] && return 0
  local p="$$" args i
  for i in $(seq 1 40); do
    args="$(ps -o args= -p "$p" 2>/dev/null || true)"
    if [[ "$args" =~ ^[^[:space:]]*claude[^[:space:]/]*[[:space:]](.*[[:space:]])?--settings[[:space:]=]([^[:space:]]*/tasks/[^/[:space:]]+)/claude-settings\.json ]]; then
      [[ -f "${BASH_REMATCH[2]}/claude-settings.json" ]] && return 0
    fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$p" && "$p" -gt 1 ]] || break
  done
  return 1
}
permit_refuse_worker() { # <what> <task id or ""> -> dies
  if [[ -n "$2" ]] && task_exists "$2"; then
    permit_log "$2" "refused: a worker tried to $1 (guard:self-answer)"
    log_event "$2" decision "[breaking] a worker tried to $1; chartroom refused it. Need: the commander's look at what the worker was doing (chartroom peek $2)" >/dev/null 2>&1 || true
  fi
  die "a worker may not $1: only the commander answers permission cards (through the XO or the app)"
}

# A card's state: open (waiting), answered, expired, lapsed (its wait ended unanswered: the hook
# was stopped, or the terminal answered), and the answer if any.
permit_rows() { # [<task id>] [--all] -> one JSON object per card
  local only="$1" all="$2" f d
  shopt -s nullglob
  for f in "$(permit_root)"/${only:-*}/p-*.json; do
    [[ "$f" == *.answer.json || "$f" == *.late.json ]] && continue
    d="${f%.json}"
    jq -c --argjson now "$(date +%s)" --slurpfile a <(cat "$d.answer.json" 2>/dev/null || true) --slurpfile l <(cat "$d.late.json" 2>/dev/null || true) '
      . + {answer: ($a[0] // null), late: ($l[0] // null)}
      | .state = (if .answer == null then (if $now < .expires_epoch then "open" else "lapsed" end)
                  elif .answer.answer == "expired" then "expired" elif .answer.answer == "lapsed" then "lapsed" else "answered" end)' "$f" 2>/dev/null
  done | if [[ "$all" == 1 ]]; then cat; else jq -c 'select(.state == "open")'; fi
}
# A card the worker's call is waiting on (not a retry card, which holds nothing).
permit_open() { [[ -n "$(permit_rows "$1" 0 | jq -c 'select(.blocking)' | head -n 1)" ]]; } # <task id>

# A one-time pre-approval of the card's exact call, consumed by the next matching hook.
permit_preapprove() { # <task id> <card json>
  local d; d="$(permit_tdir "$1")/pre"; mkdir -p "$d"
  jq -r '.id' <<<"$2" >"$d/$(jq -r '.sig' <<<"$2")"
}
permit_always_add() { # <task id> <card json> <by>
  jq -c --arg by "$3" '{tool, pattern, from: .id, by: $by, at: (now | todate)}' <<<"$2" >>"$(permit_tdir "$1")/always.ndjson"
}

cmd_permit() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    ls|list) permit_cmd_ls "$@" ;;
    show) permit_cmd_show "$@" ;;
    answer) permit_cmd_answer "$@" ;;
    grant|revoke|grants) permit_cmd_grant "$sub" "$@" ;;
    *) die "usage: chartroom permit ls [<task>] [--all] [--json] | show <p-id> | answer <p-id> once|always|deny [--note <text>] [--by commander|app] [--via xo|terminal|app] | grant <task> <name>... | revoke <task> <name>... | grants <task>" ;;
  esac
}

permit_cmd_ls() {
  local only="" all=0 json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --all) all=1 ;; --json) json=1 ;; -*) die "permit ls: unknown flag $1" ;; *) only="$(cmd_resolve "$1")" || exit 1 ;; esac
    shift
  done
  if [[ $json -eq 1 ]]; then permit_rows "$only" "$all" | jq -s -c '.'; return; fi
  permit_rows "$only" "$all" | jq -r --argjson now "$(date +%s)" '
    "\(.id)  \(.task)  \(.state)\(if .state == "open" then " (\(((.expires_epoch - $now) / 60) | floor)m left)" else "" end)  \(.desc)  [\(.rule)]"
    + (if .why != "" then "\n    why: \(.why)" else "" end)
    + "\n    always would allow: \(.pattern)"
    + (if .answer != null then "\n    answer: \(.answer.answer) by \(.answer.by)\(if (.answer.via // "") != "" then " via \(.answer.via)" else "" end)\(if (.answer.note // "") != "" then ": \(.answer.note)" else "" end)" else "" end)'
}

permit_cmd_show() {
  local pid="${1:-}" id
  [[ -n "$pid" ]] || die "usage: chartroom permit show <p-id>"
  id="$(permit_find "$pid")" || die "no such permission card: $pid"
  permit_rows "$id" 1 | jq -c --arg p "$pid" 'select(.id == $p)'
}

permit_cmd_answer() {
  local pid="${1:-}" ans="${2:-}" note="" by=commander via="" id d card rec cur desc msg
  [[ -n "$pid" && -n "$ans" ]] || die "usage: chartroom permit answer <p-id> once|always|deny [--note <text>] [--by commander|app] [--via xo|terminal|app]"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      --via) via="${2:-}"; shift 2 ;;
      *) die "permit answer: unknown arg $1" ;;
    esac
  done
  id="$(permit_find "$pid" || true)"
  permit_from_worker && permit_refuse_worker "answer permission card $pid" "$id"
  [[ -n "$id" ]] || die "no such permission card: $pid"
  [[ "$ans" =~ ^($PERMIT_ANSWERS)$ ]] || die "an answer is one of: ${PERMIT_ANSWERS//|/, }"
  [[ "$by" =~ ^(commander|app)$ ]] || die "--by is commander or app"
  [[ -n "$via" ]] || { if [[ "$by" == app ]]; then via=app; elif [[ -n "${CLAUDECODE:-}${CODEX_SANDBOX:-}${CHARTROOM_HARNESS:-}" ]]; then via=xo; else via=terminal; fi; }
  [[ "$via" =~ ^(xo|terminal|app)$ ]] || die "--via is xo, terminal or app"
  [[ "$note" != *$'\n'* ]] || note="${note//$'\n'/ }"
  d="$(permit_tdir "$id")"; card="$(cat "$d/$pid.json")"; desc="$(jq -r '.desc' <<<"$card")"
  rec="$(jq -cn --arg a "$ans" --arg by "$by" --arg via "$via" --arg n "$note" '{answer: $a, by: $by, via: $via, note: $n, at: (now | todate)}')"
  local word; case "$ans" in once) word="allowed $pid once" ;; always) word="allowed $pid always for this task" ;; deny) word="denied $pid" ;; esac
  local who="by $by (via $via)${note:+, note: \"$note\"}"
  if permit_write_once "$d/$pid.answer.json" "$rec"; then
    [[ "$ans" == always ]] && permit_always_add "$id" "$card" "$by"
    permit_log "$id" "$word $who: $desc"
    if [[ "$(jq -r '.blocking' <<<"$card")" != true ]]; then
      # A retry card: the worker moved on, so the answer is a pre-approval and a word to it.
      [[ "$ans" == once ]] && permit_preapprove "$id" "$card"
      permit_tell_worker "$id" "$ans" "$card" "$note"
    fi
    echo "$word: $desc"
    return 0
  fi
  cur="$(cat "$d/$pid.answer.json")"
  if [[ "$(jq -r '.answer' <<<"$cur")" =~ ^(expired|lapsed)$ && "$ans" != deny ]]; then
    # Answered after the wait ran out: the worker was denied, so this becomes a pre-approval and a
    # word to it (the commander's ruling: a late allow is not lost).
    permit_write_once "$d/$pid.late.json" "$rec" || die "$pid was already answered late: $(jq -r '"\(.answer) by \(.by) at \(.at)"' "$d/$pid.late.json")"
    if [[ "$ans" == always ]]; then permit_always_add "$id" "$card" "$by"; else permit_preapprove "$id" "$card"; fi
    permit_log "$id" "$word (late, after it $(jq -r '.answer' <<<"$cur")) $who: $desc"
    permit_tell_worker "$id" "$ans" "$card" "$note"
    echo "$word (late): $desc; the worker is told to run it again"
    return 0
  fi
  msg="$(jq -r '"\(.answer) by \(.by)\(if (.via // "") != "" then " via \(.via)" else "" end) at \(.at)"' <<<"$cur")"
  die "$pid was already answered: $msg (the first answer wins)"
}

# Tell the worker the outcome of a card it is no longer waiting on.
permit_tell_worker() { # <task id> <answer> <card json> <note>
  local id="$1" ans="$2" card="$3" note="$4" desc pattern msg
  desc="$(jq -r '.desc' <<<"$card")"; pattern="$(jq -r '.pattern' <<<"$card")"
  case "$ans" in
    once) msg="The commander allowed $desc (permission card $(jq -r '.id' <<<"$card")). Run it again now; chartroom lets exactly that call through once." ;;
    always) msg="The commander allowed $desc for the rest of this task (permission card $(jq -r '.id' <<<"$card")): chartroom now allows calls matching \`$pattern\`. Run it again now." ;;
    deny) msg="The commander said no to $desc (permission card $(jq -r '.id' <<<"$card")). Do not retry it." ;;
  esac
  [[ -n "$note" ]] && msg+=" Their note: $note"
  [[ -n "$(meta "$id" dispatched)" && -z "$(meta "$id" closed)" ]] || return 0
  ( cmd_steer "$id" "$msg" >/dev/null 2>&1 ) || log_event "$id" note "could not tell the worker about $(jq -r '.id' <<<"$card"); steer it: $msg"
}

permit_cmd_grant() { # grant|revoke|grants <task> [<name>...]
  local sub="$1" id d cur n names=()
  shift
  [[ -n "${1:-}" ]] || die "usage: chartroom permit $sub <task>${sub/grants/} [<name>...] (names: ${PERMIT_GRANTS//|/, })"
  id="$(cmd_resolve "$1")" || exit 1; shift; need_task "$id"
  cur="$(permit_grants_json "$id")"
  if [[ "$sub" == grants ]]; then jq -r 'if length == 0 then "(none)" else join(", ") end' <<<"$cur"; return 0; fi
  permit_from_worker && permit_refuse_worker "$sub a permission grant" "$id"
  [[ $# -gt 0 ]] || die "usage: chartroom permit $sub <task> <name>... (names: ${PERMIT_GRANTS//|/, })"
  for n in "$@"; do [[ "$n" =~ ^($PERMIT_GRANTS)$ ]] || die "unknown grant '$n' (names: ${PERMIT_GRANTS//|/, })"; names+=("$n"); done
  d="$(permit_tdir "$id")"; mkdir -p "$d"
  if [[ "$sub" == grant ]]; then cur="$(jq -c --args '. + $ARGS.positional | unique' "${names[@]}" <<<"$cur")"
  else cur="$(jq -c --args '. - $ARGS.positional' "${names[@]}" <<<"$cur")"; fi
  printf '%s\n' "$cur" >"$d/grants.json.tmp" && mv "$d/grants.json.tmp" "$d/grants.json"
  log_event "$id" note "grants: $(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$cur") (${sub}ed ${names[*]})"
  echo "grants for $id: $(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$cur")"
}

# The grants as the brief's Authority line says them.
permit_grants_text() { # <json array>
  jq -r '
    def say: {"push-branch": "push the task branch to its remote (never --force, never another branch)",
              "open-pr": "open or edit the pull request for the task branch",
              "merge-auto": "turn on squash auto-merge for the task branch'"'"'s pull request (gh pr merge --squash --auto)",
              "comment-pr": "comment on the task branch'"'"'s pull request"}[.] // .;
    map(say) | join("; ")' <<<"$1"
}

# close: the record moves into the task's own directory, where the policy no longer reads it.
permit_archive() { # <task id>
  local d; d="$(permit_tdir "$1")"
  [[ -d "$d" ]] || return 0
  rm -rf "$(tdir "$1")/permits"
  mv "$d" "$(tdir "$1")/permits" 2>/dev/null || rm -rf "$d"
}
