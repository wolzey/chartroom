# shellcheck shell=bash
# request.sh - `chartroom request`: new work the commander asks for from the app (the composer),
# for the XO to brief and dispatch, or to ask about first. A request is not a task: the XO turns it
# into one (chartroom new ...), then marks it done with the task's id. Until then the app shows it
# in the board's Drafting column.
#
#   requests/<rq-id>.json   {schema, id, title, description, project, priority, initiative, at, by,
#                            done_at, task}
# The XO hears it at once as the commander's words (lib/tell.sh): [commander cm-…] [re rq-…] ...

CR_REQUEST_ID_RE='^rq-[0-9a-f]{4,}$'

request_dir() { printf '%s/requests' "$CR_HOME"; }
request_usage() {
  cat <<'EOF'
usage: chartroom request --title T [--project P] [--priority urgent|high|medium|low] [--initiative ID] [--via app|terminal] <description|->
       chartroom request done <rq-id> [--task <id>]     the XO briefed it (or will not): it leaves Drafting
       chartroom request list [--all] [--json]
EOF
}

requests_json() { # [--all]
  local d all=false; d="$(request_dir)"
  [[ "${1:-}" == --all ]] && all=true
  shopt -s nullglob
  local files=("$d"/rq-*.json)
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || { echo '[]'; return 0; }
  jq -s -c --argjson all "$all" '[.[] | select(type == "object" and (.id | type) == "string") | select($all or .done_at == null)] | sort_by(.at)' "${files[@]}"
}

request_new() {
  local title="" project="" priority="" initiative="" via="terminal" src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) [[ $# -ge 2 ]] || die "$(request_usage)"; title="$2"; shift 2 ;;
      --project) [[ $# -ge 2 ]] || die "$(request_usage)"; project="$(inbox_project "$2")" || exit 1; shift 2 ;;
      --priority) [[ $# -ge 2 ]] || die "$(request_usage)"; priority="$2"; shift 2 ;;
      --initiative) [[ $# -ge 2 ]] || die "$(request_usage)"; initiative="$2"; shift 2 ;;
      --via) [[ $# -ge 2 ]] || die "$(request_usage)"; via="$2"; shift 2 ;;
      -) src=-; shift ;;
      -*) die "request: unknown flag $1"$'\n'"$(request_usage)" ;;
      *) [[ -z "$src" ]] || die "$(request_usage)"; src="$1"; shift ;;
    esac
  done
  title="$(printf '%s' "$title" | LC_ALL=C tr -d '\000-\037\177')"
  [[ -n "${title//[[:space:]]/}" ]] || die "request: --title is needed"
  (( ${#title} <= 200 )) || die "request: the title is over 200 characters"
  [[ -z "$priority" || "$priority" =~ ^(urgent|high|medium|low)$ ]] || die "request: --priority is urgent, high, medium or low"
  [[ -z "$initiative" || "$initiative" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "request: --initiative is an id"
  [[ "$via" =~ ^(app|terminal)$ ]] || die "request: --via is app or terminal"
  local desc=""
  if [[ "$src" == - ]]; then desc="$(head -c 16001)"; elif [[ -n "$src" ]]; then desc="$src"; fi
  desc="$(printf '%s' "$desc" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  (( ${#desc} <= 16000 )) || die "request: the description is over 16000 characters"
  local kind
  if kind="$(relay_secret_kind "$title $desc")"; then die "request refused: it looks like it holds $kind. Say where it is kept instead (nothing was sent)"; fi
  local d id; d="$(request_dir)"
  mkdir -p "$d"
  while true; do id="rq-$(rand_hex4)"; [[ -e "$d/$id.json" ]] || break; done
  jq -n -c --arg id "$id" --arg t "$title" --arg d "$desc" --arg p "$project" --arg pr "$priority" --arg i "$initiative" --arg at "$(now)" \
    '{schema: 1, id: $id, title: $t, description: (if $d == "" then null else $d end), project: (if $p == "" then null else $p end),
      priority: (if $pr == "" then null else $pr end), initiative: (if $i == "" then null else $i end), at: $at, by: "commander",
      done_at: null, task: null}' >"$d/$id.json.tmp" && mv "$d/$id.json.tmp" "$d/$id.json"
  local words="New task request $id: $title"
  [[ -n "$project" ]] && words+=" (project $project)"
  [[ -n "$priority" ]] && words+=" [priority $priority]"
  [[ -n "$desc" ]] && words+=$'\n'"$desc"
  words+=$'\n'"Brief and dispatch it, or ask me first; then: chartroom request done $id --task <task id>"
  tell_send --via "$via" --re "$id" ${project:+--project "$project"} -- "$words" >/dev/null ||
    warn "kept request $id, but could not tell the XO"
  stamp_changed
  printf '%s\n' "$id"
}

cmd_request() {
  case "${1:-}" in
    ""|-h|--help) request_usage; [[ -n "${1:-}" ]] ;;
    list)
      shift; local json=0 all="" a
      for a in "$@"; do case "$a" in --json) json=1 ;; --all) all=--all ;; *) die "$(request_usage)" ;; esac; done
      if [[ $json -eq 1 ]]; then requests_json ${all:+"$all"} | jq .; return; fi
      requests_json ${all:+"$all"} | jq -r 'if length == 0 then "requests: none open" else .[] | "- [\(.id)] \(.at[0:16] | sub("T"; " "))Z — \(.title)" + (if .task then "  → \(.task)" elif .done_at then "  (done)" else "" end) end' ;;
    done)
      shift; local id="${1:-}" task=""; shift || true
      [[ "$id" =~ $CR_REQUEST_ID_RE && -f "$(request_dir)/$id.json" ]] || die "request done: no request $id"
      if [[ "${1:-}" == --task ]]; then task="${2:-}"; [[ -f "$(tdir "$task")/meta.json" ]] || die "request done: no task $task"; fi
      local f; f="$(request_dir)/$id.json"
      jq --arg at "$(now)" --arg t "$task" '.done_at = $at | .task = (if $t == "" then null else $t end)' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
      stamp_changed; echo "request $id done${task:+ (task $task)}" ;;
    *) request_new "$@" ;;
  esac
}
