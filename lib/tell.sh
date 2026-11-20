# shellcheck shell=bash
# tell.sh - `chartroom tell`: the commander's own words to this home's XO, from the app (or any
# place that is not the XO's session), with no daemon.
#
# A told message is one record appended to the home's mailbox, relays/inbox.ndjson, the same file
# relays from other homes arrive in (lib/relay.sh), so the XO's `chartroom watch` already reads
# it under its @relays cursor and wakes with:
#   [commander cm-3f2a] [via app] [<project>] [re <ref>] <text>
# The XO treats that line as the commander speaking, as if they had typed it in the session. The
# record waits in the file when no XO is open, and the next watch of that home reads it. Acking
# appends an ack record, as for relays. One record per line:
#   {"schema":1,"kind":"commander","id":"cm-3f2a","at":"<UTC>","text":"...","via":"app",
#    "re":"q-1b2c"|null,"project":"shop"|null}
# relay list never shows these: they are the commander's, not another home's.

CR_TELL_MAX=16000 # bytes of text: a round of answers with notes fits
CR_TELL_ID_RE='^cm-[0-9a-f]{4,}$'
# What a --re may name: a task id, an inbox item, a question card, a relay, or an artifact ref.
CR_TELL_RE_RE='^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$'

tell_usage() { echo "usage: chartroom tell [--re <ref>] [--project P] [--via app|terminal] <text|->  |  tell ack <cm-id>...  |  tell list [--all] [--json]"; }

# This home's told messages, oldest first: the unacked ones, or with --all every one. Each is
# {id, at, text, via, re, project, acked, acked_at}.
tells_json() { # [--all]
  local all=false f; f="$(relay_dir)/inbox.ndjson"
  [[ "${1:-}" == --all ]] && all=true
  [[ -f "$f" ]] || { echo '[]'; return 0; }
  jq -R -s -c --argjson all "$all" --arg re "$CR_TELL_ID_RE" '
    [split("\n")[] | fromjson? | select(type == "object" and (.id | type) == "string")] as $recs
    | ([$recs[] | select(.kind == "ack")] | map({key: .id, value: (.at // "")}) | from_entries) as $acks
    | [$recs[] | select(.kind == "commander" and (.id | test($re)) and (.text | type) == "string")
       | {id, at: (.at // null), text: (.text | gsub("(?![\\n\\t])[[:cntrl:]]"; "")), via: (.via // null),
          re: (.re // null), project: (.project // null), acked: ($acks[.id] != null), acked_at: $acks[.id]}
       | select($all or (.acked | not))]' "$f"
}

# tell <text>: one commander record appended to this home's mailbox; prints its id.
tell_send() {
  local re="" project="" via="terminal" words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --re) [[ $# -ge 2 ]] || die "$(tell_usage)"; re="$2"; shift 2 ;;
      --project) [[ $# -ge 2 ]] || die "$(tell_usage)"; project="$(inbox_project "$2")" || exit 1; shift 2 ;;
      --via) [[ $# -ge 2 ]] || die "$(tell_usage)"; via="$2"; shift 2 ;;
      --) shift; words+=("$@"); break ;;
      --[a-z]*) [[ "$1" =~ ^--[a-z][a-z-]*$ ]] && die "tell: unknown flag $1 ($(tell_usage))"
        words+=("$1"); shift ;;
      *) words+=("$1"); shift ;;
    esac
  done
  [[ ${#words[@]} -ge 1 ]] || die "$(tell_usage)"
  [[ "$via" =~ ^(app|terminal)$ ]] || die "tell: --via is app or terminal, not '$via'"
  [[ -z "$re" || "$re" =~ $CR_TELL_RE_RE ]] || die "tell: --re takes an id (a task, i-xxxx, q-xxxx, a relay or an artifact ref), not '$re'"
  local text
  if [[ ${#words[@]} -eq 1 && "${words[0]}" == - ]]; then text="$(cat)"; else text="${words[*]}"; fi
  text="$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  [[ -n "${text//[[:space:]]/}" ]] || die "tell: the message is empty"
  local bytes; bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
  (( bytes <= CR_TELL_MAX )) || die "tell: the message is $bytes bytes; at most $CR_TELL_MAX. Attach the detail to a task and say where it is"
  local kind
  if kind="$(relay_secret_kind "$text")"; then
    die "tell refused: the message looks like it holds $kind. Say where it is kept instead (nothing was sent)"
  fi
  local d id; d="$(relay_dir)"
  mkdir -p "$d"
  while true; do
    id="cm-$(rand_hex4)"
    grep -q "\"id\":\"$id\"" "$d/inbox.ndjson" 2>/dev/null || break
  done
  mailbox_append "$d/inbox.ndjson" "$(jq -n -c --arg id "$id" --arg at "$(now)" --arg text "$text" --arg via "$via" --arg re "$re" --arg project "$project" \
    '{schema: 1, kind: "commander", id: $id, at: $at, text: $text, via: $via,
      re: (if $re == "" then null else $re end), project: (if $project == "" then null else $project end)}')"
  stamp_changed
  bell_ring "" watch
  printf '%s\n' "$id"
}

tell_ack() {
  [[ $# -ge 1 ]] || die "usage: chartroom tell ack <cm-id>..."
  local f q rows; f="$(relay_dir)/inbox.ndjson"
  rows="$(tells_json --all)"
  for q in "$@"; do
    q="$(tr '[:upper:]' '[:lower:]' <<<"$q" | sed -E 's/^\[//; s/\]$//')"
    [[ "$q" =~ $CR_TELL_ID_RE ]] || die "tell ack: '$q' is not a told message's id (cm-xxxx)"
    case "$(jq -r --arg id "$q" 'map(select(.id == $id)) | if length == 0 then "none" elif .[0].acked then "acked" else "open" end' <<<"$rows")" in
      none) die "tell ack: no message $q in this home (chartroom tell list --all)" ;;
      acked) echo "$q was already acked" ;;
      open)
        mailbox_append "$f" "$(jq -n -c --arg id "$q" --arg at "$(now)" '{schema: 1, kind: "ack", id: $id, at: $at}')" && stamp_changed
        rows="$(jq -c --arg id "$q" 'map(if .id == $id then .acked = true else . end)' <<<"$rows")"
        echo "acked $q" ;;
    esac
  done
}

tell_list() {
  local json=0 all="" a rows
  for a in "$@"; do
    case "$a" in --json) json=1 ;; --all) all=--all ;; *) die "tell list: unknown arg $a (usage: chartroom tell list [--all] [--json])" ;; esac
  done
  rows="$(tells_json ${all:+"$all"})"
  if [[ $json -eq 1 ]]; then jq . <<<"$rows"; return; fi
  jq -r 'if length == 0 then "told: nothing open"
    else .[] | "- [\(.id)] " + ((.at // "")[0:16] | sub("T"; " ")) + "Z — [via \(.via // "?")] "
      + (if .project then "[\(.project)] " else "" end) + (if .re then "[re \(.re)] " else "" end)
      + (.text | gsub("[[:cntrl:]]+"; " ")) + (if .acked then "  (acked)" else "" end) end' <<<"$rows"
}

cmd_tell() {
  case "${1:-}" in
    "") die "$(tell_usage)" ;;
    -h|--help) tell_usage ;;
    ack) shift; tell_ack "$@" ;;
    list) shift; tell_list "$@" ;;
    *) tell_send "$@" ;;
  esac
}
