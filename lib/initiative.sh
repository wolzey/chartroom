# shellcheck shell=bash
# initiative.sh - `chartroom initiative`: epics (the app's slice 4). An initiative belongs to one
# home; its stories are tasks of any project that home knows. The XO proposes and keeps it up to
# date; the commander creates, shapes, approves and closes it, from the app or the terminal.
#
#   initiatives/<id>/initiative.json  {schema, id, name, intent, status, target, created, created_by,
#                                      card, milestones: [{id, name, target}],
#                                      stories: [{id, title, project, milestone, after: [ids], state,
#                                                 task, note}], wrapup}
#     status: shaping (being grilled) -> active -> closing (the XO proposed a close) -> closed
#     a story's state: proposed -> approved (ready: dispatch it) | held (waits on its "after") |
#                      dropped; a story with a task follows the task
#   initiatives/<id>/plan.md          the living plan, written by the XO (never by the app)
#   initiatives/<id>/decisions.ndjson numbered decisions: every answered card of the initiative, and
#                                     the XO's own; a later one may supersede an earlier one
#   initiatives/<id>/comments.ndjson  the commander's inline comments on the plan, by section
#   initiatives/<id>/proposals/       plan edits the commander proposed (the XO applies them)
# What the commander does here reaches the XO as their words (lib/tell.sh): [commander ...] [re in-…].

CR_INIT_ID_RE='^in-[0-9a-f]{4,}$'
CR_STORY_ID_RE='^st-[0-9a-f]{4,}$'
CR_MS_ID_RE='^ms-[0-9a-f]{4,}$'
CR_DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

init_dir() { printf '%s/initiatives/%s' "$CR_HOME" "$1"; }
init_file() { printf '%s/initiative.json' "$(init_dir "$1")"; }
need_init() { [[ "${1:-}" =~ $CR_INIT_ID_RE && -f "$(init_file "$1")" ]] || die "no initiative ${1:-} (chartroom initiative list)"; }

initiative_usage() {
  cat <<'EOF'
usage: chartroom initiative new --name N [--intent I] [--target YYYY-MM-DD] [--via app|terminal]
       chartroom initiative list [--all] [--json]          show <id> [--json]
       chartroom initiative set <id> name=.. intent=.. target=YYYY-MM-DD|none status=active
       chartroom initiative milestone add <id> --name N [--target YYYY-MM-DD]
       chartroom initiative story add <id> --title T [--project P] [--milestone <ms-id>] [--after <st-id>,...] [--note T]
       chartroom initiative story link <id> <st-id> <task-id>
       chartroom initiative approve <id> <file|->          the commander's checklist (JSON): stories in order,
                                                          each {id?, title, project?, milestone?, after: [], drop?}
       chartroom initiative comment <id> --section S <text|->
       chartroom initiative propose <id> <plan.md|->      the commander's edit of the plan, for the XO to apply
       chartroom initiative decide <id> [--supersedes N] [--card <id>] <text|->
       chartroom initiative close <id> --propose <wrap-up|-> | --confirm
EOF
}

# One change to an initiative's record, under its lock: <jq filter> with extra jq args.
init_update() { # <id> <filter> [jq args...]
  local id="$1" filter="$2"; shift 2
  local f lock i; f="$(init_file "$id")"; lock="$f.lock"
  for i in $(seq 1 100); do mkdir "$lock" 2>/dev/null && break; sleep 0.05; done
  [[ -d "$lock" ]] || die "initiative $id is being changed; try again"
  if jq "$@" "$filter | .updated = (now | todate)" "$f" >"$f.tmp" 2>"$f.err"; then mv "$f.tmp" "$f"; rm -f "$f.err"; rmdir "$lock"
  else local e; e="$(sed -E 's/^jq: error \(at [^)]*\): //' "$f.err")"; rm -f "$f.tmp" "$f.err"; rmdir "$lock"; die "initiative: $e"; fi
  stamp_changed
}

init_new_id() { local p="$1" d="$2" id; while true; do id="$p-$(rand_hex4)"; [[ -e "$d/$id" ]] || { printf '%s' "$id"; return; }; done; }

# Stories with what their tasks say: each gets status (the task's app status, or the story's own
# state), and the initiative its progress. Reads each linked task's status row.
initiative_json() { # <id>
  local id="$1" f rows="{}" t
  f="$(init_file "$id")"
  local tasks; tasks="$(jq -r '[.stories[]?.task | select(. != null)] | unique | .[]' "$f")"
  if [[ -n "$tasks" ]]; then
    rows="$(for t in $tasks; do task_exists "$t" && status_rows --id "$t"; done | jq -s -c 'map({key: .id, value: {state, short_id, title, last: (.last // null)}}) | from_entries')"
  fi
  local decisions comments
  decisions="$( { [[ -f "$(init_dir "$id")/decisions.ndjson" ]] && cat "$(init_dir "$id")/decisions.ndjson"; true; } | jq -R -s -c '[split("\n")[] | fromjson? | select(type == "object")]')"
  comments="$( { [[ -f "$(init_dir "$id")/comments.ndjson" ]] && cat "$(init_dir "$id")/comments.ndjson"; true; } | jq -R -s -c '[split("\n")[] | fromjson? | select(type == "object")]')"
  jq -c --argjson rows "$rows" --argjson decisions "$decisions" --argjson comments "$comments" \
    --rawfile plan <(cat "$(init_dir "$id")/plan.md" 2>/dev/null || true) '
    def st7: {"drafting": "drafting", "working": "working", "waiting": "waiting", "waiting-overdue": "waiting",
              "stopped-silent": "waiting", "decision": "needs", "blocked": "needs", "failed": "needs",
              "awaiting-input": "working", "review": "review", "done": "done", "closed": "done"}[.] // "working";
    .stories = [.stories[]? | . as $s | ($rows[$s.task // ""] // null) as $r
      | . + {status: (if $r then ($r.state | st7) elif .state == "held" then "queued" elif .state == "approved" then "queued"
                      elif .state == "dropped" then "dropped" else "drafting" end),
             task_state: ($r.state // null), short_id: ($r.short_id // null), last: ($r.last // null)}]
    | (.stories | map(select(.state != "dropped" and .state != "proposed"))) as $live
    | .progress = {done: ($live | map(select(.status == "done")) | length), total: ($live | length),
                   needs: ($live | map(select(.status == "needs")) | length),
                   blocked: ($live | map(select(.task_state == "blocked" or .task_state == "failed")) | length),
                   proposed: (.stories | map(select(.state == "proposed")) | length)}
    | .decisions = $decisions | .comments = $comments | .plan = (if $plan == "" then null else $plan end)' "$f"
}

# Every initiative of this home, in brief (for the snapshot and the list).
initiatives_json() { # [--all]
  local d="$CR_HOME/initiatives" all=false id out=()
  [[ "${1:-}" == --all ]] && all=true
  [[ -d "$d" ]] || { echo '[]'; return 0; }
  shopt -s nullglob
  for f in "$d"/in-*/initiative.json; do
    id="${f%/initiative.json}"; id="${id##*/}"
    out+=("$(initiative_json "$id" | jq -c '{id, name, intent, status, target, created, progress, card,
      milestones: [.milestones[]? | {id, name, target}],
      stories: [.stories[]? | {id, title, project, milestone, after, state, task, status, short_id}]}')")
  done
  shopt -u nullglob
  printf '%s\n' "${out[@]+"${out[@]}"}" | jq -s -c --argjson all "$all" 'map(select($all or .status != "closed")) | sort_by(.created)'
}

# The words the XO hears, as the commander's (tell), about this initiative.
init_tell() { # <id> <via> <words>
  local p; p="$(jq -r '.stories[0].project // empty' "$(init_file "$1")" 2>/dev/null || true)"
  tell_send --via "$2" --re "$1" -- "$3" >/dev/null || warn "kept it, but could not tell the XO"
}

initiative_new() {
  local name="" intent="" target="" via="terminal"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "$(initiative_usage)"; name="$2"; shift 2 ;;
      --intent) [[ $# -ge 2 ]] || die "$(initiative_usage)"; intent="$2"; shift 2 ;;
      --target) [[ $# -ge 2 ]] || die "$(initiative_usage)"; target="$2"; shift 2 ;;
      --via) [[ $# -ge 2 ]] || die "$(initiative_usage)"; via="$2"; shift 2 ;;
      *) die "$(initiative_usage)" ;;
    esac
  done
  name="$(printf '%s' "$name" | LC_ALL=C tr -d '\000-\037\177')"
  [[ -n "${name//[[:space:]]/}" && ${#name} -le 120 ]] || die "initiative new: --name of at most 120 characters"
  [[ -z "$target" || "$target" =~ $CR_DATE_RE ]] || die "initiative new: --target is YYYY-MM-DD"
  [[ "$via" =~ ^(app|terminal)$ ]] || die "initiative new: --via is app or terminal"
  local kind; if kind="$(relay_secret_kind "$name $intent")"; then die "initiative refused: it looks like it holds $kind"; fi
  mkdir -p "$CR_HOME/initiatives"
  local id d; id="$(init_new_id in "$CR_HOME/initiatives")"; d="$(init_dir "$id")"
  mkdir -p "$d"
  jq -n --arg id "$id" --arg n "$name" --arg i "$intent" --arg t "$target" --arg at "$(now)" '{schema: 1, id: $id, name: $n,
    intent: (if $i == "" then null else $i end), status: "shaping", target: (if $t == "" then null else $t end),
    created: $at, created_by: "commander", card: null, milestones: [], stories: [], wrapup: null}' >"$d/initiative.json"
  # The shaping round: the four things every initiative settles first, answered in the app
  local card
  card="$(jq -n -c --arg n "$name" --arg id "$id" --arg i "$intent" '{title: ("Shape " + $n), kind: "grill", initiative: $id,
    context: (if $i == "" then "A new initiative: shape it before the XO proposes stories." else "Intent: " + $i end),
    round: {n: 1, of: 1},
    questions: [{text: "What is the goal, in one or two sentences?"},
                {text: "How will we know it worked? The success criteria."},
                {text: "What is in scope?"},
                {text: "What is out of scope (the non-goals)?"}]}' | ask_post -)" || true
  [[ -n "$card" ]] && init_update "$id" '.card = $c' --arg c "$card"
  init_tell "$id" "$via" "New initiative $id: $name${intent:+. Intent: $intent}. I am answering its shaping round ($card) on goal, criteria, scope and non-goals; then propose stories (chartroom initiative story add $id ...) and write its plan in initiatives/$id/plan.md."
  printf '%s\n' "$id"
}

initiative_story() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      local id="${1:-}"; need_init "$id"; shift
      local title="" project="" ms="" after="" note=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --title) title="$2"; shift 2 ;; --project) project="$2"; shift 2 ;; --milestone) ms="$2"; shift 2 ;;
          --after) after="$2"; shift 2 ;; --note) note="$2"; shift 2 ;; *) die "$(initiative_usage)" ;;
        esac
      done
      [[ -n "${title//[[:space:]]/}" ]] || die "story add: --title is needed"
      [[ -z "$ms" || "$ms" =~ $CR_MS_ID_RE ]] || die "story add: --milestone is an ms-id"
      local st; st="st-$(rand_hex4)"
      init_update "$id" '
        (if $ms != "" and ([.milestones[] | select(.id == $ms)] | length) == 0 then error("no milestone " + $ms) else . end)
        | ($after | split(",") | map(select(length > 0))) as $a
        | (if ([$a[] | . as $x | select([$s0[] | select(.id == $x)] | length == 0)] | length) > 0 then error("--after names no story of this initiative") else . end)
        | .stories += [{id: $st, title: $t, project: (if $p == "" then null else $p end), milestone: (if $ms == "" then null else $ms end),
                        after: $a, state: "proposed", task: null, note: (if $n == "" then null else $n end)}]' \
        --arg st "$st" --arg t "$title" --arg p "$project" --arg ms "$ms" --arg after "$after" --arg n "$note" \
        --argjson s0 "$(jq -c '.stories' "$(init_file "$id")")"
      echo "$st" ;;
    link)
      local id="${1:-}" st="${2:-}" task="${3:-}"; need_init "$id"; need_task "$task"
      init_update "$id" 'if ([.stories[] | select(.id == $st)] | length) == 0 then error("no story " + $st) else . end
        | .stories |= map(if .id == $st then .task = $task | .state = (if .state == "proposed" then "approved" else .state end) else . end)
        | if .status == "shaping" then .status = "active" else . end' --arg st "$st" --arg task "$task"
      cmd_set "$task" "initiative=$id" >/dev/null
      echo "linked $st to $task" ;;
    *) die "$(initiative_usage)" ;;
  esac
}

# approve <id> <json>: the commander's checklist. Its order is the stories' order; a story without an
# id is new; drop: true drops it. Ready stories (no "after", or every "after" done) are approved, the
# rest held. The XO hears which to dispatch now and which to hold.
initiative_approve() {
  local id="${1:-}" src="${2:-}" via="${3:-terminal}"; need_init "$id"
  local json; if [[ "$src" == - ]]; then json="$(head -c 200001)"; else [[ -f "$src" ]] || die "approve: no file $src"; json="$(cat "$src")"; fi
  jq -e 'type == "object" and (.stories | type) == "array"' >/dev/null 2>&1 <<<"$json" || die "approve: a JSON object with .stories"
  local before; before="$(initiative_json "$id")"
  # an id for each story the checklist adds (one per line of it: the unused ones are dropped)
  local n ids=() i; n="$(jq '.stories | length' <<<"$json")"
  for ((i = 0; i < n; i++)); do ids+=("st-$(rand_hex4)"); done
  local plan
  plan="$(jq -c -n --argjson cur "$before" --argjson in "$json" --args '
    ($cur.stories | map({key: .id, value: .}) | from_entries) as $old
    | [$in.stories | to_entries[] | .key as $k | .value as $s
        | if ($s.id // null) != null and $old[$s.id] == null then error("no story " + $s.id) else . end
        | ($old[$s.id // ""] // {}) as $o
        | {id: ($s.id // $ARGS.positional[$k]),
           title: (($s.title // $o.title // "") | tostring), project: ($s.project // $o.project // null),
           milestone: ($s.milestone // $o.milestone // null), after: ($s.after // $o.after // []),
           note: ($o.note // null), task: ($o.task // null), drop: ($s.drop == true), was: ($o.state // null)}]
    | (map(select(.drop | not)) | map(.id)) as $kept
    | map(.after |= map(select(. as $a | $kept | index($a))))
    # ready: nothing to wait for, or everything it comes after is done; else held until it is
    | map(.state = (if .drop then "dropped"
        elif .task != null then (if .was == "proposed" or .was == null then "approved" else .was end)
        elif all(.after[]; ($old[.].status // "") == "done") then "approved"
        else "held" end) | del(.drop, .was))
    | if any(.[]; (.title | gsub("\\s"; "") | length) == 0) then error("every story needs a title") else . end' "${ids[@]}")" ||
    die "approve: could not read the checklist"
  # the checklist covers the stories it names; every other story (already approved, linked or held)
  # stays as it was, first, in its order
  init_update "$id" '($p | map(.id)) as $ids | .stories = ([.stories[] | select(.id as $i | $ids | index($i) | not)] + $p)
    | if .status == "shaping" then .status = "active" else . end' --argjson p "$plan"
  local words
  words="$(jq -r -n --argjson p "$plan" --arg id "$id" --arg name "$(jq -r .name "$(init_file "$id")")" '
    ($p | map({key: .id, value: .title}) | from_entries) as $t
    | "Approved the stories of \($id) (\($name)):"
      + ([$p[] | select(.state == "approved" and .task == null) | "\n- dispatch now: \(.id) \(.title)" + (if .project then " [" + .project + "]" else "" end)] | join(""))
      + ([$p[] | select(.state == "held") | "\n- hold until done: \(.id) \(.title), after " + ([.after[] | "\(.) (\($t[.]))"] | join(", "))] | join(""))
      + ([$p[] | select(.state == "dropped") | "\n- dropped: \(.id) \(.title)"] | join(""))
      + "\nBrief each, then: chartroom initiative story link \($id) <st-id> <task-id>"')"
  init_tell "$id" "$via" "$words"
  jq -r -n --argjson p "$plan" '"approved: \([$p[] | select(.state == "approved")] | length), held: \([$p[] | select(.state == "held")] | length), dropped: \([$p[] | select(.state == "dropped")] | length)"'
}

initiative_decide() { # <id> [--supersedes N] [--card ID] <text|->  (also called for an answered card)
  local id="${1:-}"; need_init "$id"; shift
  local sup="" card="" words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in --supersedes) sup="$2"; shift 2 ;; --card) card="$2"; shift 2 ;; --) shift; words+=("$@"); break ;; *) words+=("$1"); shift ;; esac
  done
  local text; if [[ "${words[*]-}" == - ]]; then text="$(cat)"; else text="${words[*]-}"; fi
  [[ -n "${text//[[:space:]]/}" ]] || die "decide: the decision is empty"
  [[ -z "$sup" || "$sup" =~ ^[0-9]+$ ]] || die "decide: --supersedes takes a decision's number"
  local f n; f="$(init_dir "$id")/decisions.ndjson"
  n="$(( $( { [[ -f "$f" ]] && jq -R -s '[split("\n")[] | fromjson? | select(.n)] | length' "$f"; } || echo 0) + 1 ))"
  jq -n -c --argjson n "$n" --arg at "$(now)" --arg t "$text" --arg c "$card" --arg s "$sup" \
    '{schema: 1, n: $n, at: $at, text: $t, card: (if $c == "" then null else $c end), supersedes: (if $s == "" then null else ($s | tonumber) end)}' >>"$f"
  stamp_changed
  echo "decision $n"
}

cmd_initiative() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    ""|-h|--help) initiative_usage; [[ -n "$sub" ]] ;;
    new) initiative_new "$@" ;;
    list)
      local json=0 all="" a
      for a in "$@"; do case "$a" in --json) json=1 ;; --all) all=--all ;; *) die "$(initiative_usage)" ;; esac; done
      if [[ $json -eq 1 ]]; then initiatives_json ${all:+"$all"} | jq .; return; fi
      initiatives_json ${all:+"$all"} | jq -r 'if length == 0 then "initiatives: none" else .[] | "- [\(.id)] \(.name)  \(.status)  \(.progress.done)/\(.progress.total) done" + (if .progress.proposed > 0 then ", \(.progress.proposed) proposed" else "" end) end' ;;
    show)
      local id="${1:-}"; need_init "$id"
      if [[ "${2:-}" == --json ]]; then initiative_json "$id" | jq .; return; fi
      initiative_json "$id" | jq -r '"\(.id) \(.name) (\(.status))" + (if .intent then "\n  " + .intent else "" end)
        + ([.stories[] | "\n- \(.id) [\(.status)] \(.title)" + (if .task then " → \(.task)" else "" end) + (if (.after | length) > 0 then " (after \(.after | join(", ")))" else "" end)] | join(""))' ;;
    set)
      local id="${1:-}"; need_init "$id"; shift
      local kv k v
      for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
          name) [[ -n "$v" ]] || die "set: name is empty"; init_update "$id" '.name = $v' --arg v "$v" ;;
          intent) init_update "$id" '.intent = $v' --arg v "$v" ;;
          target) [[ "$v" == none || "$v" =~ $CR_DATE_RE ]] || die "set: target is YYYY-MM-DD or none"
            init_update "$id" '.target = (if $v == "none" then null else $v end)' --arg v "$v" ;;
          status) [[ "$v" =~ ^(shaping|active)$ ]] || die "set: status is shaping or active (close with: initiative close)"
            init_update "$id" '.status = $v' --arg v "$v" ;;
          *) die "set: unknown key $k (name, intent, target, status)" ;;
        esac
      done
      echo "set $* on $id" ;;
    milestone)
      [[ "${1:-}" == add ]] || die "$(initiative_usage)"; shift
      local id="${1:-}" name="" target=""; need_init "$id"; shift
      while [[ $# -gt 0 ]]; do case "$1" in --name) name="$2"; shift 2 ;; --target) target="$2"; shift 2 ;; *) die "$(initiative_usage)" ;; esac; done
      [[ -n "$name" ]] || die "milestone add: --name is needed"
      [[ -z "$target" || "$target" =~ $CR_DATE_RE ]] || die "milestone add: --target is YYYY-MM-DD"
      local ms; ms="ms-$(rand_hex4)"
      init_update "$id" '.milestones += [{id: $ms, name: $n, target: (if $t == "" then null else $t end)}]' --arg ms "$ms" --arg n "$name" --arg t "$target"
      echo "$ms" ;;
    story) initiative_story "$@" ;;
    approve)
      local id="${1:-}" src="${2:-}" via=terminal
      [[ "${3:-}" == --via ]] && via="${4:-terminal}"
      initiative_approve "$id" "$src" "$via" ;;
    comment)
      local id="${1:-}" section="" via=terminal; need_init "$id"; shift
      local words=()
      while [[ $# -gt 0 ]]; do case "$1" in --section) section="$2"; shift 2 ;; --via) via="$2"; shift 2 ;; *) words+=("$1"); shift ;; esac; done
      local text; if [[ "${words[*]-}" == - ]]; then text="$(cat)"; else text="${words[*]-}"; fi
      [[ -n "${text//[[:space:]]/}" ]] || die "comment: the comment is empty"
      jq -n -c --arg s "$section" --arg t "$text" --arg at "$(now)" '{schema: 1, section: (if $s == "" then null else $s end), text: $t, at: $at, by: "commander"}' >>"$(init_dir "$id")/comments.ndjson"
      init_tell "$id" "$via" "Comment on the plan of $id${section:+, section \"$section\"}: $text"
      stamp_changed; echo "commented on $id" ;;
    propose)
      local id="${1:-}" src="${2:-}" via=terminal; need_init "$id"
      [[ "${3:-}" == --via ]] && via="${4:-terminal}"
      local text; if [[ "$src" == - ]]; then text="$(head -c 200001)"; else [[ -f "$src" ]] || die "propose: no file $src"; text="$(cat "$src")"; fi
      [[ -n "${text//[[:space:]]/}" ]] || die "propose: the plan is empty"
      local d stamp; d="$(init_dir "$id")/proposals"; stamp="$(now | tr -d ':-')"; mkdir -p "$d"
      printf '%s\n' "$text" >"$d/plan-$stamp.md"
      local diff; diff="$(diff -u "$(init_dir "$id")/plan.md" "$d/plan-$stamp.md" 2>/dev/null | tail -n +3 | head -c 3000 || true)"
      init_tell "$id" "$via" "I edited the plan of $id: apply it to initiatives/$id/plan.md (my full version: initiatives/$id/proposals/plan-$stamp.md) and keep the stories in sync. What changed:
${diff:-(no plan.md yet: take mine as the start)}"
      stamp_changed; echo "proposed proposals/plan-$stamp.md" ;;
    decide) initiative_decide "$@" ;;
    close)
      local id="${1:-}"; need_init "$id"; shift
      case "${1:-}" in
        --propose)
          local src="${2:-}" text; if [[ "$src" == - ]]; then text="$(cat)"; else text="$src"; fi
          init_update "$id" '.status = "closing" | .wrapup = $w' --arg w "$text"
          echo "proposed closing $id" ;;
        --confirm)
          local via=terminal; [[ "${2:-}" == --via ]] && via="${3:-terminal}"
          init_update "$id" '.status = "closed" | .closed = (now | todate)'
          init_tell "$id" "$via" "Closed initiative $id: the wrap-up stands."
          echo "closed $id" ;;
        *) die "$(initiative_usage)" ;;
      esac ;;
    *) die "$(initiative_usage)" ;;
  esac
}
