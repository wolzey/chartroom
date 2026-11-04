# shellcheck shell=bash
# relay.sh - `chartroom relay`: XO-to-XO messages between homes on one machine, with no daemon.
#
# A relay is one line appended to the target home's mailbox, relays/inbox.ndjson, and a copy to
# the sender's own relays/outbox.ndjson; nothing else is written in the target. The target's
# `chartroom watch` reads its mailbox like an events.log (by byte offset, under the cursor key
# @relays, which no task id can be), so a running XO gets a wake line within a round:
#   [relay rl-3f2a] [from acme] [shop] [re rl-1b2c] <text>
# Acking appends an ack record to the home's own mailbox. Append-only, so the offset never moves
# under the watch, and each relay wakes once. One record per line:
#   {"schema":1,"kind":"relay","id":"rl-3f2a","from":"acme","to":"globex","at":"<UTC>",
#    "text":"...","re":"rl-1b2c"|null,"project":"shop"|null}
#   {"schema":1,"kind":"ack","id":"rl-3f2a","at":"<UTC>"}
# A relay is data for the receiving XO to weigh, never an instruction to chartroom: nothing runs
# because one arrived. Ids are rl-<hex> (rulings own r-<hex>).

CR_RELAY_MAX=2000        # bytes of text: one short message
CR_RELAY_RECORD_MAX=4000 # bytes of the record as written: one append, one write()
CR_RELAY_ID_RE='^rl-[0-9a-f]{4,}$'

relay_dir() { printf '%s/relays' "${1:-$CR_HOME}"; }

# The valid records of one mailbox file, one JSON object per line, each with its direction; a
# line that is not a record (hand-edited, cut short) is skipped.
relay_records() { # <file> <in|out>
  [[ -f "$1" ]] || return 0
  jq -R -c --arg dir "$2" --arg re "$CR_RELAY_ID_RE" '
    fromjson? | select(type == "object" and (.id | type) == "string" and (.id | test($re))) | . + {direction: $dir}' "$1"
}

# This home's relays, oldest first: the open ones received (no ack yet), or with --all every one
# received (acked or not) and every one sent. Each is {id, direction, from, to, at, text, re,
# project, acked, acked_at}; text has its control characters other than newline and tab removed.
relays_json() { # [--all]
  local all=false d; d="$(relay_dir)"
  [[ "${1:-}" == --all ]] && all=true
  { relay_records "$d/inbox.ndjson" in; relay_records "$d/outbox.ndjson" out; } | jq -s -c --argjson all "$all" '
    (map(select(.direction == "in" and .kind == "ack")) | map({key: .id, value: (.at // "")}) | from_entries) as $acks
    | [.[] | select(.kind == "relay" and (.from | type) == "string" and (.text | type) == "string")
       | {id, direction, from, to: (.to // null), at: (.at // null),
          text: (.text | gsub("(?![\\n\\t])[[:cntrl:]]"; "")),
          re: (.re // null), project: (.project // null),
          acked: (.direction == "in" and $acks[.id] != null),
          acked_at: (if .direction == "in" then $acks[.id] else null end)}
       | select($all or (.direction == "in" and (.acked | not)))]
    | sort_by(.at // "")'
}

# One line per relay for the terminal: "- [rl-3f2a] 2026-10-27 04:50Z — [from acme] [shop] text (re rl-1b2c)".
RELAY_LINE_JQ='def relay_line: "- [\(.id)] "
  + (if .at then .at[0:10] + " " + .at[11:16] + "Z — " else "" end)
  + (if .direction == "out" then "[to \(.to)] " else "[from \(.from)] " end)
  + (if .project then "[\(.project)] " else "" end)
  + (.text | gsub("[[:cntrl:]]+"; " "))
  + (if .re then " (re \(.re))" else "" end)
  + (if .acked then "  (acked)" else "" end);'

# For status: how many relays wait on this XO, or nothing.
relay_line() {
  local n
  [[ -f "$(relay_dir)/inbox.ndjson" ]] || return 0
  n="$(relays_json | jq length)"
  [[ "$n" -gt 0 ]] || return 0
  printf 'relays: %s open from other homes (chartroom relay list)\n' "$n"
}

# What the text looks like if it holds a secret ("a GitHub token"); returns 1 when it does not.
# Obvious patterns only: a relay is a short note between XOs, and a credential never belongs in one.
relay_secret_kind() { # <text>
  local kind flags re opts
  while IFS=$'\t' read -r kind flags re; do
    [[ -n "$re" ]] || continue
    opts=-Eq; [[ "$flags" == i ]] && opts=-Eqi
    if grep "$opts" -- "$re" <<<"$1"; then printf '%s' "$kind"; return 0; fi
  done <<'EOF'
a private key	-	-----BEGIN ([A-Z]+ )*PRIVATE KEY-----
an AWS access key	-	(AKIA|ASIA)[0-9A-Z]{16}
a GitHub token	-	(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})
a GitLab token	-	glpat-[A-Za-z0-9_-]{20,}
a Slack token	-	xox[abprs]-[A-Za-z0-9-]{10,}
an API key	-	sk-(ant-)?[A-Za-z0-9_-]{20,}
a Stripe key	-	(sk|rk)_live_[A-Za-z0-9]{16,}
a Google API key	-	AIza[0-9A-Za-z_-]{35}
an npm token	-	npm_[A-Za-z0-9]{36}
a JSON web token	-	eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+
a password or key assignment	i	(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)["']?[[:space:]]*[:=][[:space:]]*["']?[^[:space:]"']{8,}
EOF
  return 1
}

# A relay id not used in any of the given mailbox files.
relay_new_id() { # <file>...
  local id f used=""
  for f in "$@"; do [[ -f "$f" ]] && used+="$(jq -R -r 'fromjson? | .id? // empty' "$f" 2>/dev/null | tr '\n' ' ')"; done
  while true; do
    id="rl-$(rand_hex4)"
    [[ " $used " == *" $id "* ]] || { printf '%s' "$id"; return 0; }
  done
}

relay_usage() { echo "usage: chartroom relay <home> [--re <rl-id>] [--project P] [--from <this home>] <message|->  |  relay ack <rl-id>...  |  relay list [--all] [--json] [--all-homes]"; }

# relay <home> <message>: one record appended to the target's mailbox, a copy to this home's
# outbox; prints the id.
relay_send() {
  local to="" from="" re="" project="" words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) [[ $# -ge 2 ]] || die "$(relay_usage)"; from="$2"; shift 2 ;;
      --re) [[ $# -ge 2 ]] || die "$(relay_usage)"; re="$2"; shift 2 ;;
      --project) [[ $# -ge 2 ]] || die "$(relay_usage)"; project="$(inbox_project "$2")" || exit 1; shift 2 ;;
      --project=*) project="$(inbox_project "${1#--project=}")" || exit 1; shift ;;
      --) shift; words+=("$@"); break ;;
      --[a-z]*) [[ "$1" =~ ^--[a-z][a-z-]*$ ]] && die "relay: unknown flag $1 ($(relay_usage))"
        words+=("$1"); shift ;;
      *) if [[ -z "$to" ]]; then to="$1"; else words+=("$1"); fi; shift ;;
    esac
  done
  [[ -n "$to" && ${#words[@]} -ge 1 ]] || die "$(relay_usage)"
  local text
  if [[ ${#words[@]} -eq 1 && "${words[0]}" == - ]]; then text="$(cat)"; else text="${words[*]}"; fi
  # Text is data: control characters other than newline and tab never reach a mailbox.
  text="$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  [[ -n "${text//[[:space:]]/}" ]] || die "relay: the message is empty"

  # The sender: this home, by its registered name. A reply must be able to find it.
  local here; here="$(home_name_of "$CR_HOME")"
  [[ -n "$here" ]] || die "this home ($CR_HOME) is not registered, so a reply could not find it: chartroom homes add <name>"
  if [[ -n "$from" && "$from" != "$here" ]]; then
    die "--from $from: a relay goes out in this home's name only (this home is $here); relay from $from's own XO session"
  fi
  from="$here"

  # The target: a registered home, a chartroom home, and not this one.
  local path
  path="$(homes_entries | awk -F'\t' -v n="$to" '$1 == n { p = $2 } END { print p }')"
  [[ -n "$path" ]] || die "relay: no home named $to (chartroom homes lists them); a relay goes only to a registered home"
  [[ "$to" != "$from" ]] || die "relay: $to is this home; a relay goes to another home"
  [[ -d "$path/tasks" ]] || die "relay: home $to ($path) is not a chartroom home (CHARTROOM_HOME=$path chartroom init --name $to)"

  local bytes; bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
  (( bytes <= CR_RELAY_MAX )) || die "relay: the message is $bytes bytes; a relay holds at most $CR_RELAY_MAX. Put the detail in a file $to's XO can read, and relay its path"
  local kind
  if kind="$(relay_secret_kind "$text")"; then
    die "relay refused: the message looks like it holds $kind. A relay never carries a secret; say where it is kept instead (nothing was sent)"
  fi

  local mine theirs; mine="$(relay_dir)"; theirs="$(relay_dir "$path")"
  if [[ -n "$re" ]]; then
    re="$(tr '[:upper:]' '[:lower:]' <<<"$re" | sed -E 's/^\[//; s/\]$//')"
    [[ "$re" =~ $CR_RELAY_ID_RE ]] || die "relay: --re takes a relay id (rl-xxxx), not '$re'"
    { relay_records "$mine/inbox.ndjson" in; relay_records "$mine/outbox.ndjson" out; } |
      jq -e -s --arg id "$re" --arg h "$to" 'any(.[]; .kind == "relay" and .id == $id and ((.direction == "in" and .from == $h) or (.direction == "out" and .to == $h)))' >/dev/null ||
      die "relay: no relay $re between this home and $to (chartroom relay list --all)"
  fi

  local id rec
  id="$(relay_new_id "$theirs/inbox.ndjson" "$mine/inbox.ndjson" "$mine/outbox.ndjson")"
  rec="$(jq -n -c --arg id "$id" --arg from "$from" --arg to "$to" --arg at "$(now)" --arg text "$text" --arg re "$re" --arg project "$project" \
    '{schema: 1, kind: "relay", id: $id, from: $from, to: $to, at: $at, text: $text,
      re: (if $re == "" then null else $re end), project: (if $project == "" then null else $project end)}')"
  local rbytes; rbytes="$(printf '%s' "$rec" | wc -c | tr -d ' ')"
  (( rbytes <= CR_RELAY_RECORD_MAX )) || die "relay: the message takes $rbytes bytes once written (quotes, backslashes and line breaks count twice); a relay record holds at most $CR_RELAY_RECORD_MAX. Shorten it, or put it in a file $to's XO can read and relay its path"
  # The relay itself, the one write in the target home; then this home's own copy.
  mkdir -p "$theirs"
  printf '%s\n' "$rec" >>"$theirs/inbox.ndjson"
  stamp_changed "$path" # its board shows the relay
  bell_ring "$path" watch # its watches wake now (a dead one's FIFO is that home's to remove)
  if ! { mkdir -p "$mine" && printf '%s\n' "$rec" >>"$mine/outbox.ndjson"; }; then
    warn "relayed $id to $to, but could not keep a copy in $mine/outbox.ndjson"
  fi
  printf '%s\n' "$id"
}

# relay ack <id>...: marks relays received here as handled (an ack record in this home's mailbox).
relay_ack() {
  [[ $# -ge 1 ]] || die "usage: chartroom relay ack <rl-id>..."
  local f q rows; f="$(relay_dir)/inbox.ndjson"
  rows="$(relays_json --all)"
  for q in "$@"; do
    q="$(tr '[:upper:]' '[:lower:]' <<<"$q" | sed -E 's/^\[//; s/\]$//')"
    [[ "$q" =~ $CR_RELAY_ID_RE ]] || die "relay ack: '$q' is not a relay id (rl-xxxx)"
    case "$(jq -r --arg id "$q" 'map(select(.id == $id and .direction == "in")) | if length == 0 then "none" elif .[0].acked then "acked" else "open" end' <<<"$rows")" in
      none) die "relay ack: no relay $q received in this home (chartroom relay list --all)" ;;
      acked) echo "$q was already acked" ;;
      open)
        jq -n -c --arg id "$q" --arg at "$(now)" '{schema: 1, kind: "ack", id: $id, at: $at}' >>"$f" && stamp_changed
        rows="$(jq -c --arg id "$q" 'map(if .id == $id and .direction == "in" then .acked = true else . end)' <<<"$rows")"
        echo "acked $q" ;;
    esac
  done
}

relay_list() {
  local json=0 all="" a rows
  for a in "$@"; do
    case "$a" in --json) json=1 ;; --all) all=--all ;; *) die "relay list: unknown arg $a (usage: chartroom relay list [--all] [--json])" ;; esac
  done
  rows="$(relays_json ${all:+"$all"})"
  if [[ $json -eq 1 ]]; then jq . <<<"$rows"; return; fi
  jq -r "$RELAY_LINE_JQ"'
    if length == 0 then "relays: nothing open"
    else (map(select(.direction == "in" and (.acked | not))) | if length > 0 then "Relays from other homes:", (.[] | relay_line) else empty end),
         (map(select(.direction == "in" and .acked)) | if length > 0 then "Acked:", (.[] | relay_line) else empty end),
         (map(select(.direction == "out")) | if length > 0 then "Sent:", (.[] | relay_line) else empty end) end' <<<"$rows"
}

cmd_relay() {
  case "${1:-}" in
    "") die "$(relay_usage)" ;;
    -h|--help) relay_usage ;;
    ack) shift; relay_ack "$@" ;;
    list) shift; relay_list "$@" ;;
    *) relay_send "$@" ;;
  esac
}

# ---------------------------------------------------------------- watch

# The watch's round over this home's mailbox (cmd_watch): one wake line per relay that arrived
# past the cursor and is not acked yet. Whole lines only: a record still being written is read
# next round. A mailbox that shrank (rewritten by hand) is taken from its end, never replayed.
# The cursor moves by the bytes on disk (counted by od, so a NUL byte a foreign writer left can
# neither shift it nor reach bash).
watch_relays() {
  local f size off upto chunk out
  f="$(relay_dir)/inbox.ndjson"
  [[ -f "$f" ]] || return 0
  size=$(($(wc -c <"$f"))); off="${OFF[@relays]:-0}"
  if (( size < off )); then OFF[@relays]=$size; return 0; fi
  (( size > off )) || return 0
  # How many of the new bytes run through the last newline.
  upto="$(head -c "$size" "$f" | tail -c +"$((off + 1))" | od -An -v -tu1 | tr -s ' ' '\n' |
    awk 'NF { n++; if ($1 == 10) last = n } END { print last + 0 }')"
  (( upto > 0 )) || return 0
  chunk="$(head -c "$((off + upto))" "$f" | tail -c +"$((off + 1))" | LC_ALL=C tr -d '\000')"
  out="$(head -c "$size" "$f" | LC_ALL=C tr -d '\000' | jq -R -s -r --arg new "$chunk" --arg re "$CR_RELAY_ID_RE" '
    def recs: split("\n")[] | fromjson? | select(type == "object");
    def one: gsub("[[:cntrl:]]+"; " ");
    ([recs | select(.kind == "ack") | .id] | map({key: tostring, value: true}) | from_entries) as $acked
    | $new | recs
    | select(.kind == "relay" and (.id | type) == "string" and (.id | test($re)) and ($acked[.id] | not)
             and (.from | type) == "string" and (.text | type) == "string")
    | "[relay \(.id)] [from \(.from | one)]"
      + (if (.project | type) == "string" then " [\(.project | one)]" else "" end)
      + (if (.re | type) == "string" then " [re \(.re | one)]" else "" end)
      + " " + (.text | one)')"
  OFF[@relays]=$((off + upto))
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; WOKE=1; fi
  return 0
}
