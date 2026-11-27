# shellcheck shell=bash
# ticket.sh - a task as a ticket (the app's slice 2): attachments, linked PRs and URLs, the
# description (the brief's intent and spec, edited in place), planning properties, and the
# ticket's whole record as one JSON for the app.
#
#   tasks/<id>/attachments/<att-id>/<name>   the file, 0600, at most 25 MB
#   tasks/<id>/attachments.ndjson            one record per attachment, append-only:
#     {"schema":1,"id":"att-3f2a","name":"...","type":"image/png","size":123,"sha256":"...",
#      "by":"commander"|"xo"|"worker","at":"<UTC>","caption":"..."|null,"silent":false}
#     {"schema":1,"id":"att-3f2a","removed":true,"at":"<UTC>"}      (the file is deleted too)
#   tasks/<id>/links.ndjson                  links added on purpose (PRs, tickets, any URL):
#     {"schema":1,"url":"...","kind":"pr"|"url","title":"..."|null,"by":"...","at":"<UTC>"}
#     {"schema":1,"url":"...","removed":true,"at":"<UTC>"}
#   meta.json: priority (urgent|high|medium|low), labels ([...]), initiative, milestone: all optional
# A PR is also every PR URL a worker wrote in events.log or report.md, as the dashboard has
# always found them; a link record adds to those, never replaces them.
#
# What the commander attaches or edits reaches the worker as a steer (attach --silent: not), in
# the commander's words; what a worker attaches never steers anyone.

CR_ATTACH_MAX=26214400 # 25 MB
CR_ATTACH_ID_RE='^att-[0-9a-f]{4,}$'
CR_LABEL_RE='^[a-z0-9][a-z0-9._-]{0,31}$'
CR_PR_URL_RE='^https?://[^[:space:]]+/(pull|pulls|merge_requests|pullrequest)/[0-9]+$'

ticket_usage() {
  cat <<'EOF'
usage: chartroom attachment add <id> [--name N] [--type MIME] [--caption C] [--by commander|xo|worker] [--silent] <file>
       chartroom attachment rm <id> <att-id>      chartroom attachment list <id> [--json]
       chartroom link <id> <url> [--title T]      chartroom link rm <id> <url>       chartroom link list <id> [--json]
       chartroom brief <id> --sections <file|->   replace sections of the brief: {"Commander's intent": "...", "Spec": "..."}
       chartroom set <id> priority=urgent|high|medium|low|none labels=a,b initiative=<id>|none milestone=<id>|none
       chartroom set <id> model=<m> effort=<e> sandbox=<mode> permission=<mode>   (before dispatch)
       chartroom set <id> node=<device>|here|any                                   (before dispatch)
       chartroom set <id> needs=docker,ruby,...|none
EOF
}

# Who is doing this: a worker inside its own task, else the XO, unless --by says the commander.
ticket_by() { # <task-id> [--by value]
  if [[ -n "${2:-}" ]]; then
    [[ "$2" =~ ^(commander|xo|worker)$ ]] || die "--by is commander, xo or worker"
    printf '%s' "$2"; return
  fi
  if [[ -n "${CHARTROOM_TASK:-}" && "$CHARTROOM_TASK" == "$1" ]]; then echo worker; else echo xo; fi
}

# A steer to the task's worker, when it has one running or resumable; a note otherwise. Never fails
# the caller: the record is already kept.
ticket_steer() { # <id> <message>
  local id="$1"
  if [[ -z "$(meta "$id" dispatched)" || -n "$(meta "$id" closed)" ]]; then
    echo "(not steered: $id has no worker to tell)"; return 0
  fi
  "$CR_BIN" steer "$id" "$2" >/dev/null 2>&1 && { echo "steered $id"; return 0; }
  warn "kept it, but could not steer $id; tell the worker yourself (chartroom steer $id ...)"
  return 0
}

# The MIME type for a name, from its extension (what `file` would say is not portable enough).
ticket_mime() { # <name>
  local ext; ext="$(tr '[:upper:]' '[:lower:]' <<<"${1##*.}")"
  case "$ext" in
    png) echo image/png ;; jpg|jpeg) echo image/jpeg ;; gif) echo image/gif ;; webp) echo image/webp ;; heic) echo image/heic ;;
    svg) echo image/svg+xml ;; mp4|m4v) echo video/mp4 ;; mov) echo video/quicktime ;; webm) echo video/webm ;;
    pdf) echo application/pdf ;; json) echo application/json ;; csv) echo text/csv ;;
    txt|log|md|diff|patch) echo text/plain ;; html|htm) echo text/html ;;
    *) echo application/octet-stream ;;
  esac
}

attachments_json() { # <id>: the attachments still there, oldest first
  local f; f="$(tdir "$1")/attachments.ndjson"
  [[ -f "$f" ]] || { echo '[]'; return 0; }
  jq -R -s -c --arg re "$CR_ATTACH_ID_RE" '
    [split("\n")[] | fromjson? | select(type == "object" and (.id | type) == "string" and (.id | test($re)))]
    | (map(select(.removed == true) | .id)) as $gone
    | [.[] | select(.removed != true and (.id as $i | $gone | index($i) | not))]' "$f"
}

cmd_attachment() {
  case "${1:-}" in
    ""|-h|--help) ticket_usage; [[ -n "${1:-}" ]]; return ;;
    add) shift ;;
    list)
      local id="${2:-}"; need_task "$id"
      if [[ "${3:-}" == --json ]]; then attachments_json "$id" | jq .; return; fi
      attachments_json "$id" | jq -r 'if length == 0 then "attachments: none" else .[] | "- \(.id)  \(.name)  \(.size) bytes  by \(.by)  \(.at)" + (if .caption then "  — " + .caption else "" end) end'
      return ;;
    rm)
      local id="${2:-}" att="${3:-}"; need_task "$id"
      [[ "$att" =~ $CR_ATTACH_ID_RE ]] && attachments_json "$id" | jq -e --arg a "$att" 'any(.[]; .id == $a)' >/dev/null ||
        die "attachment rm: no attachment $att on $id (chartroom attachment list $id)"
      rm -rf "$(tdir "$id")/attachments/$att"
      jq -n -c --arg a "$att" --arg at "$(now)" '{schema: 1, id: $a, removed: true, at: $at}' >>"$(tdir "$id")/attachments.ndjson"
      stamp_changed; echo "removed $att from $id"; return ;;
    *) die "$(ticket_usage)" ;;
  esac
  brain_is_client && die "attachment add runs on the brain, where the task's folder is ($(brain_target)): copy the file there and attach it, or attach it from the app"
  local id="$1"; shift
  need_task "$id"
  local name="" type="" caption="" by="" silent=0 src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "$(ticket_usage)"; name="$2"; shift 2 ;;
      --type) [[ $# -ge 2 ]] || die "$(ticket_usage)"; type="$2"; shift 2 ;;
      --caption) [[ $# -ge 2 ]] || die "$(ticket_usage)"; caption="$2"; shift 2 ;;
      --by) [[ $# -ge 2 ]] || die "$(ticket_usage)"; by="$2"; shift 2 ;;
      --silent) silent=1; shift ;;
      -*) die "attachment: unknown flag $1"$'\n'"$(ticket_usage)" ;;
      *) [[ -z "$src" ]] || die "$(ticket_usage)"; src="$1"; shift ;;
    esac
  done
  [[ -n "$src" && -f "$src" ]] || die "attachment: no file '$src'"
  by="$(ticket_by "$id" "$by")"
  [[ -n "$name" ]] || name="${src##*/}"
  # A name is a file name: no directory, no control characters, nothing hidden.
  name="$(printf '%s' "$name" | LC_ALL=C tr -d '\000-\037\177' | tr '/\\' '__' | sed -E 's/^[.[:space:]]+//')"
  [[ -n "$name" ]] || name="file"
  (( ${#name} <= 120 )) || name="${name:0:80}…${name: -30}"
  local size; size="$(wc -c <"$src" | tr -d ' ')"
  (( size <= CR_ATTACH_MAX )) || die "attachment: $name is $((size / 1048576)) MB; attachments hold at most 25 MB. Put it somewhere you can link and use: chartroom link $id <url>"
  [[ -n "$type" ]] || type="$(ticket_mime "$name")"
  [[ "$type" =~ ^[a-z]+/[a-z0-9.+-]+$ ]] || type=application/octet-stream
  local d att sha
  d="$(tdir "$id")/attachments"
  mkdir -p "$d"; chmod 700 "$d"
  while true; do att="att-$(rand_hex4)"; [[ -e "$d/$att" ]] || break; done
  mkdir -p "$d/$att"
  ( umask 077; cp "$src" "$d/$att/$name" )
  sha="$(shasum -a 256 "$d/$att/$name" 2>/dev/null || sha256sum "$d/$att/$name" 2>/dev/null)"; sha="${sha%% *}"
  jq -n -c --arg a "$att" --arg n "$name" --arg t "$type" --argjson s "$size" --arg sha "$sha" --arg by "$by" --arg at "$(now)" \
    --arg c "$caption" --argjson silent "$([[ $silent -eq 1 ]] && echo true || echo false)" \
    '{schema: 1, id: $a, name: $n, type: $t, size: $s, sha256: $sha, by: $by, at: $at,
      caption: (if $c == "" then null else $c end), silent: $silent}' >>"$(tdir "$id")/attachments.ndjson"
  log_event "$id" note "attached $name ($att, by $by)"
  echo "attached $att: $d/$att/$name"
  if [[ "$by" == commander && $silent -eq 0 ]]; then
    ticket_steer "$id" "The commander attached a file to this task: $d/$att/$name ($type, $size bytes)${caption:+. Their note: $caption}. Read or view it before you go on."
  fi
}

# Every link of a task: PR URLs the worker wrote (events.log, report.md) and the ones added on
# purpose, without duplicates or removed ones: [{url, kind, title, by, at, source}].
links_json() { # <id>
  local d f found; d="$(tdir "$1")"; f="$d/links.ndjson"
  found="$({ task_events "$1"; cat "$d/report.md" 2>/dev/null; } |
    grep -oE 'https?://[^][ <>()"'"'"'`]+/(pull|pulls|merge_requests|pullrequest)/[0-9]+' | awk '!seen[$0]++' || true)"
  { [[ -f "$f" ]] && cat "$f"; true; } | jq -R -s -c --arg found "$found" '
    [split("\n")[] | fromjson? | select(type == "object" and (.url | type) == "string")] as $recs
    | ([$recs[] | {key: .url, value: .}] | from_entries) as $last
    | [($found | split("\n")[] | select(length > 0) | {url: ., kind: "pr", title: null, by: "worker", at: null, source: "found"}),
       ($recs[] | select(.removed != true) | {url, kind: (.kind // "url"), title: (.title // null), by: (.by // null), at: (.at // null), source: "added"})]
    | map(select(($last[.url].removed // false) | not))
    | reduce .[] as $l ([]; if any(.[]; .url == $l.url) then . else . + [$l] end)'
}

cmd_link() {
  case "${1:-}" in
    ""|-h|--help) ticket_usage; [[ -n "${1:-}" ]]; return ;;
    list)
      local id="${2:-}"; need_task "$id"
      if [[ "${3:-}" == --json ]]; then links_json "$id" | jq .; return; fi
      links_json "$id" | jq -r 'if length == 0 then "links: none" else .[] | "- [\(.kind)] \(.url)" + (if .title then "  — " + .title else "" end) end'
      return ;;
    rm)
      local id="${2:-}" url="${3:-}"; need_task "$id"
      links_json "$id" | jq -e --arg u "$url" 'any(.[]; .url == $u)' >/dev/null || die "link rm: $id has no link $url"
      jq -n -c --arg u "$url" --arg at "$(now)" '{schema: 1, url: $u, removed: true, at: $at}' >>"$(tdir "$id")/links.ndjson"
      stamp_changed; echo "unlinked $url from $id"; return ;;
  esac
  local id="$1" url="${2:-}" title="" by=""; need_task "$id"; shift 2 || die "$(ticket_usage)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) [[ $# -ge 2 ]] || die "$(ticket_usage)"; title="$2"; shift 2 ;;
      --by) [[ $# -ge 2 ]] || die "$(ticket_usage)"; by="$2"; shift 2 ;;
      *) die "$(ticket_usage)" ;;
    esac
  done
  [[ ${#url} -le 2000 && "$url" =~ ^https?://[^[:space:]\"\'\<\>]{3,}$ ]] || die "link: '$url' is not an http(s) URL"
  by="$(ticket_by "$id" "$by")"
  local kind="url"; [[ "$url" =~ $CR_PR_URL_RE ]] && kind="pr"
  jq -n -c --arg u "$url" --arg k "$kind" --arg t "$title" --arg by "$by" --arg at "$(now)" \
    '{schema: 1, url: $u, kind: $k, title: (if $t == "" then null else $t end), by: $by, at: $at}' >>"$(tdir "$id")/links.ndjson"
  stamp_changed
  echo "linked $kind $url to $id"
}

# The brief's sections by heading, as JSON {heading: body}: what the ticket shows as its description.
brief_sections_json() { # <id>
  local f; f="$(tdir "$1")/brief.md"
  [[ -f "$f" ]] || { echo '{}'; return 0; }
  jq -R -s -c '
    split("\n") | reduce .[] as $l ({cur: null, out: {}};
      if ($l | test("^## ")) then .cur = ($l[3:] | gsub("\\s+$"; "")) | .out[.cur] = []
      elif .cur != null then .out[.cur] += [$l] else . end)
    | .out | map_values(join("\n") | gsub("<!--[\\s\\S]*?-->"; "") | gsub("^\\s+|\\s+$"; ""))' "$f"
}

# brief <id> --sections <json>: replace the bodies of the named sections (they must exist), keep the
# rest of the brief as it is, keep the old brief beside it, and steer the worker with what changed.
cmd_brief() {
  local id="${1:-}" src=""; need_task "$id"; shift
  [[ "${1:-}" == --sections && $# -eq 2 ]] || die "$(ticket_usage)"
  src="$2"
  local json
  if [[ "$src" == - ]]; then json="$(head -c 200001)"; else [[ -f "$src" ]] || die "brief: no file $src"; json="$(head -c 200001 "$src")"; fi
  (( ${#json} <= 200000 )) || die "brief: the sections are over 200 KB"
  jq -e 'type == "object" and length > 0 and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$json" ||
    die "brief: --sections takes a JSON object of heading: text"
  local f old new missing; f="$(tdir "$id")/brief.md"
  [[ -f "$f" ]] || die "brief: $id has no brief.md"
  old="$(cat "$f")"
  missing="$(jq -r --argjson have "$(brief_sections_json "$id")" '[keys[] | select($have[.] == null)] | join(", ")' <<<"$json")"
  [[ -z "$missing" ]] || die "brief: no section '## $missing' in $id's brief"
  new="$(jq -R -s -r --argjson set "$json" '
    split("\n") | reduce .[] as $l ({cur: null, skip: false, out: []};
      if ($l | test("^## ")) then
        ($l[3:] | gsub("\\s+$"; "")) as $h
        | .cur = $h | .skip = ($set[$h] != null)
        | .out += [$l] + (if .skip then ["", $set[$h], ""] else [] end)
      elif .skip then . else .out += [$l] end)
    | .out | join("\n")' "$f")"
  [[ "$new" != "$old" ]] || { echo "brief: nothing changed"; return 0; }
  local stamp; stamp="$(now | tr -d ':-')"
  mkdir -p "$(tdir "$id")/brief-history"
  cp "$f" "$(tdir "$id")/brief-history/brief-$stamp.md"
  printf '%s\n' "$new" >"$f.tmp" && mv "$f.tmp" "$f"
  local diff; diff="$(diff -u "$(tdir "$id")/brief-history/brief-$stamp.md" "$f" | tail -n +3 | head -c 3000 || true)"
  log_event "$id" note "brief edited by the commander (the old one: brief-history/brief-$stamp.md)"
  echo "updated $id's brief"
  ticket_steer "$id" "The commander edited your brief ($f): re-read the sections they changed and carry on under them. What changed:
$diff"
}

# set <id> key=value...: a task's settings before dispatch (what the skill once had the XO edit in
# meta.json by hand) and the ticket's planning properties. Every pair is checked before any is
# written; each goes through meta_set or meta_set_json, so a store task's row is set the same way.
CR_SET_KEYS='model|effort|sandbox|permission|priority|labels|initiative|milestone'
cmd_set() {
  local id="${1:-}"; need_task "$id"; shift
  [[ $# -ge 1 ]] || die "$(ticket_usage)"
  # node=<device>|here: where it runs (lib/backends/node.sh), set on its own
  if [[ "$1" == node=* ]]; then [[ $# -eq 1 ]] || die "set: node=... goes on its own"; node_pin "$id" "${1#node=}"; return; fi
  # needs=docker,ruby|none: what a node must have for it (lib/place.sh), set on its own
  if [[ "$1" == needs=* ]]; then
    [[ $# -eq 1 ]] || die "set: needs=... goes on its own"
    local needs; needs="$(needs_norm "${1#needs=}")" || exit 1
    meta_set "$id" needs "$needs"; log_event "$id" note "needs: $needs"; echo "$id needs $needs"; return
  fi
  local kv k v l keys=() vals=() json=()
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || die "set: '$kv' is not key=value"
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      model|effort|sandbox|permission) json+=(0) ;;
      priority)
        [[ "$v" =~ ^(urgent|high|medium|low|none)$ ]] || die "set: priority is urgent, high, medium, low or none"
        if [[ "$v" == none ]]; then v=""; json+=(1); else json+=(0); fi ;;
      labels)
        for l in ${v//,/ }; do [[ "$l" =~ $CR_LABEL_RE ]] || die "set: label '$l' is lowercase letters, digits, . _ - (32 at most)"; done
        v="$(jq -n -c --arg v "$v" '$v | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique | if . == [] then empty else . end')"
        json+=(1) ;;
      initiative|milestone)
        [[ "$v" == none || "$v" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "set: $k is an id (or none)"
        if [[ "$v" == none ]]; then v=""; json+=(1); else json+=(0); fi ;;
      *) die "set: '$k' is not a setting (keys: ${CR_SET_KEYS//|/, })" ;;
    esac
    keys+=("$k"); vals+=("$v")
  done
  local i
  for i in "${!keys[@]}"; do
    if [[ "${json[$i]}" == 1 ]]; then meta_set_json "$id" "${keys[$i]}" "${vals[$i]}"
    else meta_set "$id" "${keys[$i]}" "${vals[$i]}"; fi
  done
  echo "set $* on $id"
}

# The ticket as the app shows it: the status row (with the app's status), the description, the
# open ask, the plan, attachments, links, the told messages about it, and the events.
ticket_json() { # <id>
  local id="$1" d row ask=null off line
  d="$(tdir "$id")"
  row="$(status_rows --id "$id" | jq -c '. + {}')"
  [[ -n "$row" ]] || die "no task $id"
  meta_path "$id"; events_path "$id"
  if IFS=$'\t' read -r off line < <(app_last_ask "$id"); then
    ask="$(jq -n -c --arg id "ev-$id-$off" --arg line "$line" '{id: $id, line: $line,
      kind: ($line | capture("^[^ ]+ (?<k>[a-z-]+):") | if .k == "agent" then "awaiting-input" else .k end)}')"
  fi
  local answer=null
  if [[ "$ask" != null ]]; then answer="$(ask_answer_get "ev-$id-$off")"; [[ -n "$answer" ]] || answer=null; fi
  jq -n -c --argjson row "$row" --argjson extra "$(dashboard_task_extra "$id")" --argjson meta "$(cat "$META_PATH")" \
    --argjson sections "$(brief_sections_json "$id")" --argjson ask "$ask" --argjson answer "$answer" \
    --argjson attachments "$(attachments_json "$id")" --argjson links "$(links_json "$id")" \
    --argjson tells "$(tells_json --all | jq -c --arg id "$id" 'map(select(.re == $id))')" \
    --argjson decisions "$(decisions_json "$id")" \
    --argjson artifacts "$(artifacts_json --owner task "$id" | jq -c 'map(del(.path))')" \
    --rawfile events "$EVENTS_PATH" --arg plan "$(cat "$d/plan.md" 2>/dev/null || true)" \
    --arg home "$(home_name_of "$CR_HOME")" '
    ($row.state) as $s
    | {id: $row.id, short_id: $row.short_id, title: $row.title, home: $home, project: $row.project, kind: $row.kind,
       backend: $row.backend, state: $s, live: $row.live,
       status: ({"drafting": "drafting", "working": "working", "waiting": "waiting", "waiting-overdue": "waiting",
                 "stopped-silent": "waiting", "decision": "needs", "blocked": "needs", "failed": "needs",
                 "awaiting-input": "working", "review": "review", "done": "done", "closed": "closed"}[$s] // "working"),
       warning: (if $s == "awaiting-input" then "at a prompt in its terminal, for the XO to handle" else null end),
       created: $row.created, dispatched: ($meta.dispatched // null), closed: ($row.closed // null),
       last_event: ($extra.last_event // $row.last), last_at: ($extra.last_event_at // $row.last_at),
       waiting_on: $row.waiting_on, waiting_until: $row.waiting_until, branch: ($meta.branch // null), base: ($meta.base // null),
       worktree: ($meta.worktree // null), machine: null, attempt: 1,
       priority: ($meta.priority // null), labels: ($meta.labels // []), initiative: ($meta.initiative // null), milestone: ($meta.milestone // null),
       plan_gate: (($meta.plan_gate // "") | tostring == "1"),
       sections: $sections, ask: (if $ask == null or ($s | test("^(decision|blocked|failed)$") | not) then null else $ask end),
       answer: $answer, plan: (if $plan == "" then null else $plan end), files: $extra.files,
       attachments: $attachments, artifacts: $artifacts, links: $links, tells: $tells, decisions: $decisions,
       events: ($events | split("\n") | map(select(length > 0)) | .[-400:])}'
}
