# shellcheck shell=bash
# ask.sh - question cards: `chartroom ask` (the XO's questions for the commander, as cards the app
# shows and answers) and the commander's answers to every kind of card, the first one winning.
#
# Cards, by id:
#   q-xxxx   a card the XO posted: questions/<q-id>.json. A grilling round is one card with several
#            questions, answered and submitted together; a multiple-choice prompt is a card with one.
#   ev-<task>-<offset>
#            a worker's ask: the decision/blocked/failed (or agent awaiting-input) event at that byte
#            offset of the task's events.log. Its options are the event's own words; the app parses
#            them (lib/dashboard/eventfmt.js), so there is no record to write and no migration.
#   i-xxxx   an open "Waiting on the commander" inbox item.
# An answer is questions/<id>.answer.json, created only if absent (noclobber): the first answer
# wins, from the app or the terminal, and a second is refused with who answered and when. An answer
# from the app is also told to the XO as the commander's words (lib/tell.sh), so the XO relays a
# worker's answer with `steer` and records the rest, as it would an answer typed in its session.
#
# A card the XO posts (stdin or a file, JSON):
#   {"title": "...", "kind": "grill"|"choice", "context": "...", "project": "...", "task": "<id>",
#    "initiative": "<id>", "round": {"n": 2, "of": 4},
#    "questions": [{"text": "...", "context": "...", "why": "...", "multi": false,
#                   "options": ["a", {"label": "b", "detail": "..."}], "recommended": 0 | "b"}]}
# An answer (stdin, JSON): {"answers": [{"q": 1, "choice": "<option label>"|null, "note": "..."}],
#   "action": "approve"|"changes" (a plan approval), "note": "..."}.

CR_ASK_ID_RE='^q-[0-9a-f]{4,}$'
CR_ASK_MAX=65536 # bytes of a card or an answer as given

ask_dir() { printf '%s/questions' "$CR_HOME"; }
ask_usage() {
  cat <<'EOF'
usage: chartroom ask <file|->                       post a card (JSON); prints its id
       chartroom ask --title T [--context C] [--option O]... [--recommend N] [--project P] [--task ID]
                                                    post a one-question card
       chartroom ask answer <id> [--via app|terminal] (<file|-> | --pick N [--note T] | --note T)
       chartroom ask withdraw <q-id> [reason]       the XO no longer needs it
       chartroom ask list [--all] [--json]          open cards (--all: answered ones too)
       chartroom ask show <id> [--json]
A card (JSON):
  {"title": "...", "context": "...", "project": "...", "task": "<id>", "round": {"n": 1, "of": 3},
   "questions": [{"text": "...", "context": "...", "why": "...",
                  "options": ["a", {"label": "b", "detail": "..."}], "recommended": 0}]}
  (recommended: an option's 0-based index or its label; a question with no options is free text)
An answer (JSON): {"answers": [{"q": 1, "choice": "<option label>", "note": "..."}]}
  or, for a plan approval: {"action": "approve"|"changes", "note": "..."}
EOF
}

# The kind of card an id names: q, ev, inbox; or nothing.
ask_kind() { # <id>
  if [[ "$1" =~ $CR_ASK_ID_RE ]]; then echo q
  elif [[ "$1" =~ ^ev-(.+)-([0-9]+)$ ]]; then echo ev
  elif [[ "$1" =~ ^i-[0-9a-f]{4,}$ ]]; then echo inbox
  fi
}

# A worker's ask at <task> <offset>: prints "<kind>\t<line>" when the events.log line starting at
# that byte offset is one the commander answers; fails otherwise.
ask_event_at() { # <task> <offset>
  local f; f="$(tdir "$1")/events.log"
  [[ -f "$f" ]] || return 1
  local line
  line="$(tail -c +"$(($2 + 1))" "$f" | head -n 1)"
  if (( $2 > 0 )); then [[ "$(head -c "$2" "$f" | tail -c 1 | od -An -tu1 | tr -d ' ')" == 10 ]] || return 1; fi
  case "$line" in
    ????-??-??T??:??:??Z\ decision:\ *) printf 'decision\t%s\n' "$line" ;;
    ????-??-??T??:??:??Z\ blocked:\ *) printf 'blocked\t%s\n' "$line" ;;
    ????-??-??T??:??:??Z\ failed:\ *) printf 'failed\t%s\n' "$line" ;;
    ????-??-??T??:??:??Z\ agent:\ awaiting-input*) printf 'awaiting-input\t%s\n' "$line" ;;
    *) return 1 ;;
  esac
}

# Normalize a posted card (JSON on stdin) or die with what is wrong.
ask_normalize() { # <id> <at>
  local out
  out="$(jq -c --arg id "$1" --arg at "$2" '
    def s: if type == "string" then gsub("(?![\\n\\t])[[:cntrl:]]"; "") else null end;
    def nonempty: type == "string" and (gsub("\\s"; "") | length) > 0;
    if type != "object" then error("a card is a JSON object")
    elif (.questions | type) != "array" or (.questions | length) == 0 then error("a card needs at least one question in .questions")
    elif (.questions | length) > 20 then error("a card holds at most 20 questions; ask the rest in the next round")
    elif (.title | nonempty | not) and (.questions | length) > 1 then error("a card of several questions needs a .title")
    else . end
    | {schema: 1, id: $id, kind: (if (.kind | type) == "string" and (.kind | test("^(grill|choice)$")) then .kind
                                  elif (.questions | length) > 1 then "grill" else "choice" end),
       title: ((.title | s) // .questions[0].text), context: (.context | s),
       project: (.project | s), task: (.task | s), initiative: (.initiative | s),
       round: (if (.round | type) == "object" then {n: (.round.n | numbers? // null), of: (.round.of | numbers? // null)} else null end),
       asked_at: $at, asked_by: "xo",
       questions: [.questions | to_entries[] | .key as $k | .value
         | if type != "object" or (.text | nonempty | not) then error("question \($k + 1) needs .text") else . end
         | (.options // []) as $o
         | if ($o | type) != "array" or ($o | length) > 9 then error("question \($k + 1): .options is a list of at most 9") else . end
         | [$o[] | if type == "string" then {label: .} elif type == "object" and (.label | nonempty) then {label: .label, detail: (.detail | s)}
                   else error("question \($k + 1): each option is a string or {label, detail}") end
             | .label |= s] as $opts
         | (.recommended) as $r
         | (if $r == null then null
            elif ($r | type) == "number" then (if $r >= 0 and $r < ($opts | length) then $r else error("question \($k + 1): .recommended \($r) is not an option index (0-based)") end)
            else ([$opts | to_entries[] | select(.value.label == $r) | .key] | first // error("question \($k + 1): .recommended names no option")) end) as $ri
         | {id: ($k + 1), text: (.text | s), context: (.context | s), why: (.why | s), multi: (.multi == true),
            options: [$opts | to_entries[] | .value + {rec: (.key == $ri)}]}]}' 2>&1)" ||
    die "ask: $(sed -E 's/^jq: error \(at [^)]*\): //' <<<"$out")"
  printf '%s\n' "$out"
}

ask_post() { # <file|-> | quick flags
  local title="" context="" project="" task="" rec="" opts=() src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) [[ $# -ge 2 ]] || die "$(ask_usage)"; title="$2"; shift 2 ;;
      --context) [[ $# -ge 2 ]] || die "$(ask_usage)"; context="$2"; shift 2 ;;
      --option) [[ $# -ge 2 ]] || die "$(ask_usage)"; opts+=("$2"); shift 2 ;;
      --recommend) [[ $# -ge 2 ]] || die "$(ask_usage)"; rec="$2"; shift 2 ;;
      --project) [[ $# -ge 2 ]] || die "$(ask_usage)"; project="$(inbox_project "$2")" || exit 1; shift 2 ;;
      --task) [[ $# -ge 2 ]] || die "$(ask_usage)"; task="$(cmd_resolve "$2")" || exit 1
        [[ -f "$(tdir "$task")/meta.json" ]] || die "ask: --task $2 is not a task"; shift 2 ;;
      -) src=-; shift ;;
      -*) die "ask: unknown flag $1"$'\n'"$(ask_usage)" ;;
      *) [[ -z "$src" ]] || die "$(ask_usage)"; src="$1"; shift ;;
    esac
  done
  local json
  if [[ -n "$src" ]]; then
    [[ -z "$title$context${opts[*]-}$rec" ]] || die "ask: give a card file or the --title form, not both"
    if [[ "$src" == - ]]; then json="$(head -c $((CR_ASK_MAX + 1)))"; else [[ -f "$src" ]] || die "ask: no file $src"; json="$(head -c $((CR_ASK_MAX + 1)) "$src")"; fi
    (( ${#json} <= CR_ASK_MAX )) || die "ask: the card is over $CR_ASK_MAX bytes"
    [[ -z "$project" ]] || json="$(jq -c --arg p "$project" '.project = $p' <<<"$json" 2>/dev/null)" || die "ask: the card is not JSON"
    [[ -z "$task" ]] || json="$(jq -c --arg t "$task" '.task = $t' <<<"$json" 2>/dev/null)" || die "ask: the card is not JSON"
  else
    [[ -n "$title" ]] || die "$(ask_usage)"
    [[ -z "$rec" || "$rec" =~ ^[1-9]$ ]] || die "ask: --recommend takes an option's number (1-9)"
    json="$(jq -n -c --arg t "$title" --arg c "$context" --arg p "$project" --arg task "$task" --arg r "$rec" \
      --args '{questions: [{text: $t, context: (if $c == "" then null else $c end), options: $ARGS.positional,
               recommended: (if $r == "" then null else ($r | tonumber) - 1 end)}],
               project: (if $p == "" then null else $p end), task: (if $task == "" then null else $task end)}' "${opts[@]+"${opts[@]}"}")"
  fi
  jq -e . >/dev/null 2>&1 <<<"$json" || die "ask: the card is not JSON"
  local d id card kind; d="$(ask_dir)"
  mkdir -p "$d"
  while true; do id="q-$(rand_hex4)"; [[ -e "$d/$id.json" ]] || break; done
  card="$(ask_normalize "$id" "$(now)" <<<"$json")"
  if kind="$(relay_secret_kind "$card")"; then die "ask refused: the card looks like it holds $kind (nothing was posted)"; fi
  printf '%s\n' "$card" >"$d/$id.json.tmp" && mv "$d/$id.json.tmp" "$d/$id.json"
  stamp_changed
  printf '%s\n' "$id"
}

# The card behind an id, as JSON: a posted card as stored; a worker's ask as {id, kind: "event",
# task, event_kind, line, text}; an inbox item as {id, kind: "inbox", text}. Fails when unknown.
ask_card_json() { # <id>
  local id="$1"
  case "$(ask_kind "$id")" in
    q) [[ -f "$(ask_dir)/$id.json" ]] || return 1; cat "$(ask_dir)/$id.json" ;;
    ev)
      [[ "$id" =~ ^ev-(.+)-([0-9]+)$ ]] || return 1
      local task="${BASH_REMATCH[1]}" off="${BASH_REMATCH[2]}" got
      [[ "$task" =~ ^[a-z0-9][a-z0-9-]*$ && -d "$(tdir "$task")" ]] || return 1
      got="$(ask_event_at "$task" "$off")" || return 1
      jq -n -c --arg id "$id" --arg task "$task" --arg k "${got%%$'\t'*}" --arg line "${got#*$'\t'}" \
        '{id: $id, kind: "event", task: $task, event_kind: $k, line: $line,
          text: ($line | sub("^[^ ]+ [a-z-]+: ?"; "")), at: ($line[0:20])}' ;;
    inbox)
      local row; row="$(dashboard_inbox | jq -c --arg id "$id" '.waiting[] | select(.short_id == $id)' | head -n 1)"
      [[ -n "$row" ]] || return 1
      jq -c --arg id "$id" '{id: $id, kind: "inbox", text, date, project}' <<<"$row" ;;
    *) return 1 ;;
  esac
}

ask_answer_file() { printf '%s/%s.answer.json' "$(ask_dir)" "$1"; }

# The commander's words for an answer: what the XO reads in its wake.
ask_words() { # <card-json> <answer-json>
  jq -n -r --argjson c "$1" --argjson a "$2" '
    def line: gsub("[[:cntrl:]]+"; " ");
    def say($x): ($x.choice // null) as $ch | ($x.note // "" | line) as $n
      | (if $ch then $ch | line else "" end) + (if $ch and $n != "" then ". Note: " else "" end) + $n;
    if $c.kind == "event" then
      ($c.text | line | if length > 140 then .[0:139] + "…" else . end) as $ask
      | if $a.action == "approve" then "Approved \($c.task)'"'"'s plan" + (if ($a.note // "") != "" then ". Note: " + ($a.note | line) else "" end) + " (re: \($ask))"
        elif $a.action == "changes" then "Requested changes to \($c.task)'"'"'s plan: " + ($a.note // "" | line) + " (re: \($ask))"
        else "Answer to \($c.task)'"'"'s \($c.event_kind) (\($ask)): " + say($a.answers[0] // {note: $a.note}) end
    elif $c.kind == "inbox" then "Answer to inbox item \($c.id) (\($c.text | line)): " + say($a.answers[0] // {note: $a.note})
    else
      "Answers to \($c.id) (\($c.title | line)):"
      + ([$a.answers[] as $x | ($c.questions[] | select(.id == $x.q)) as $q
          | "\n\($q.id). \($q.text | line) → " + say($x)] | join(""))
      + (if ($a.note // "") != "" then "\nNote: " + ($a.note | line) else "" end) end'
}

ask_answer() {
  local id="" via=terminal pick="" note="" src="" a
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --via) [[ $# -ge 2 ]] || die "$(ask_usage)"; via="$2"; shift 2 ;;
      --pick) [[ $# -ge 2 ]] || die "$(ask_usage)"; pick="$2"; shift 2 ;;
      --note) [[ $# -ge 2 ]] || die "$(ask_usage)"; note="$2"; shift 2 ;;
      -) src=-; shift ;;
      -*) die "ask answer: unknown flag $1"$'\n'"$(ask_usage)" ;;
      *) if [[ -z "$id" ]]; then id="$1"; elif [[ -z "$src" ]]; then src="$1"; else die "$(ask_usage)"; fi; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "$(ask_usage)"
  [[ "$via" =~ ^(app|terminal)$ ]] || die "ask answer: --via is app or terminal"
  local card; card="$(ask_card_json "$id")" || die "ask answer: no open card $id (chartroom ask list)"
  local f; f="$(ask_answer_file "$id")"
  if [[ -f "$f" ]]; then
    die "ask answer: $id was already answered ($(jq -r '"by \(.via) at \(.at)" + (if .withdrawn then ", withdrawn" else "" end)' "$f" 2>/dev/null || echo "earlier"))"
  fi
  # A worker's ask is answerable only while it is the worker's open question: once the task moved
  # on (the XO answered it in the terminal with steer, or the worker asked something newer), an
  # answer from a view opened before then would reach the XO about a question already settled.
  if [[ "$(jq -r .kind <<<"$card")" == event ]]; then
    local task off last st
    task="$(jq -r .task <<<"$card")"; off="${id##*-}"
    IFS=$'\t' read -r last _ < <(app_last_ask "$task") || true
    st="$(status_rows --id "$task" | jq -r '.state // empty')"
    [[ "$last" == "$off" && "$st" =~ ^(decision|blocked|failed|awaiting-input)$ ]] ||
      die "ask answer: $task has moved on since that question (it is ${st:-unknown} now$([[ "$last" != "$off" ]] && echo ", with a newer ask")); nothing was sent"
  fi
  local ans
  if [[ -n "$src" ]]; then
    [[ -z "$pick$note" ]] || die "ask answer: give an answer file or --pick/--note, not both"
    if [[ "$src" == - ]]; then ans="$(head -c $((CR_ASK_MAX + 1)))"; else [[ -f "$src" ]] || die "ask answer: no file $src"; ans="$(head -c $((CR_ASK_MAX + 1)) "$src")"; fi
    (( ${#ans} <= CR_ASK_MAX )) || die "ask answer: the answer is over $CR_ASK_MAX bytes"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$ans" || die "ask answer: the answer is not a JSON object"
  else
    [[ -n "$pick$note" ]] || die "ask answer: --pick N, --note T or an answer file"
    [[ -z "$pick" || "$pick" =~ ^[1-9]$ ]] || die "ask answer: --pick takes an option's number (1-9)"
    [[ -z "$pick" ]] || jq -e '.kind != "event" and .kind != "inbox" and (.questions | length) == 1' >/dev/null <<<"$card" ||
      die "ask answer: --pick is for a card with one question; answer this one with --note or an answer file"
    ans="$(jq -n -c --argjson c "$card" --arg p "$pick" --arg n "$note" '
      {answers: [{q: 1, choice: (if $p == "" then null else ($c.questions[0].options[($p | tonumber) - 1].label // error("--pick \($p): no such option")) end),
                  note: (if $n == "" then null else $n end)}]}' 2>&1)" || die "ask answer: ${ans#jq: error*: }"
  fi
  # Check it against the card: every question of a posted card answered, choices among its options.
  local err
  err="$(jq -n -r --argjson c "$card" --argjson a "$ans" '
    def has: ((.choice // "") | tostring | length) > 0 or ((.note // "") | tostring | gsub("\\s"; "") | length) > 0;
    if ($a.action // null) != null and ($a.action | tostring | test("^(approve|changes)$") | not) then "action is approve or changes"
    elif $a.action == "changes" and (($a.note // "") | gsub("\\s"; "") | length) == 0 then "requesting changes needs a note saying what to change"
    elif $a.action != null then empty
    elif ($a.answers | type) != "array" or ($a.answers | length) == 0 then "no answers"
    elif $c.kind == "event" or $c.kind == "inbox" then (if ($a.answers[0] | has) then empty else "the answer is empty" end)
    else
      ([$c.questions[] | .id as $q | select([$a.answers[] | select(.q == $q and has)] | length == 0) | $q]) as $missing
      | ([$a.answers[] | select(.choice != null) | . as $x | select([$c.questions[] | select(.id == $x.q) | .options[] | select(.label == $x.choice)] | length == 0) | .q]) as $bad
      | if ($missing | length) > 0 then "question(s) \($missing | map(tostring) | join(", ")) not answered (a choice or a note each)"
        elif ($bad | length) > 0 then "question(s) \($bad | map(tostring) | join(", ")): the choice is not one of its options"
        else empty end end' 2>&1)"
  [[ -z "$err" ]] || die "ask answer: $err"
  local words told="" rec
  words="$(ask_words "$card" "$ans")"
  rec="$(jq -n -c --arg id "$id" --arg at "$(now)" --arg via "$via" --argjson a "$ans" --arg w "$words" \
    '{schema: 1, id: $id, at: $at, via: $via, action: ($a.action // null), answers: ($a.answers // []), note: ($a.note // null), words: $w, told: null}')"
  # What would stop the XO from being told stops the answer too, before it is recorded: an answer
  # kept with nobody told would show as sent and never arrive.
  if [[ "$via" == app ]]; then
    local kind bytes
    if kind="$(relay_secret_kind "$words")"; then die "ask answer refused: it looks like it holds $kind. Say where it is kept instead (nothing was sent)"; fi
    bytes="$(printf '%s' "$words" | wc -c | tr -d ' ')"
    (( bytes <= CR_TELL_MAX )) || die "ask answer: the answer is $bytes bytes as words for the XO; at most $CR_TELL_MAX"
  fi
  mkdir -p "$(ask_dir)"
  # The first answer wins: the file is created only if it is not there yet.
  if ! ( set -o noclobber; printf '%s\n' "$rec" >"$f" ) 2>/dev/null; then
    die "ask answer: $id was already answered ($(jq -r '"by \(.via) at \(.at)"' "$f" 2>/dev/null || echo "just now"))"
  fi
  # From the app, the XO hears it as the commander's words; in the terminal it already has them.
  if [[ "$via" == app ]]; then
    local re project
    re="$(jq -r 'if .kind == "event" then .task else .id end' <<<"$card")"
    project="$(jq -r '.project // empty' <<<"$card")"
    [[ -n "$project" ]] || { [[ "$re" == "$id" ]] || project="$(project_label "$re" 2>/dev/null || true)"; }
    told="$(tell_send --via app --re "$re" ${project:+--project "$project"} -- "$words")" ||
      warn "answered $id, but could not tell the XO; it is in $(ask_answer_file "$id")"
    if [[ -n "$told" ]]; then
      jq -c --arg t "$told" '.told = $t' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    fi
  fi
  stamp_changed
  echo "answered $id${told:+ (told the XO: $told)}"
}

ask_withdraw() {
  local id="${1:-}"; shift || true
  [[ "$id" =~ $CR_ASK_ID_RE && -f "$(ask_dir)/$id.json" ]] || die "ask withdraw: no card $id (a q-xxxx the XO posted)"
  local f; f="$(ask_answer_file "$id")"
  local rec; rec="$(jq -n -c --arg id "$id" --arg at "$(now)" --arg r "$*" '{schema: 1, id: $id, at: $at, via: "xo", withdrawn: true, note: (if $r == "" then null else $r end), answers: []}')"
  ( set -o noclobber; printf '%s\n' "$rec" >"$f" ) 2>/dev/null || die "ask withdraw: $id was already answered"
  stamp_changed
  echo "withdrew $id"
}

# Every posted card with its answer (null while open), newest first: [{card..., answer}].
asks_json() { # [--all]
  local d; d="$(ask_dir)"
  local all=false; [[ "${1:-}" == --all ]] && all=true
  shopt -s nullglob
  local files=("$d"/q-*.json)
  shopt -u nullglob
  local cards=() answers=() f
  for f in "${files[@]+"${files[@]}"}"; do
    case "$f" in *.answer.json) answers+=("$f") ;; *) cards+=("$f") ;; esac
  done
  [[ ${#cards[@]} -gt 0 ]] || { echo '[]'; return 0; }
  jq -s -c --argjson all "$all" '
    (map(select(.answers != null or .withdrawn == true)) | map({key: .id, value: .}) | from_entries) as $ans
    | [.[] | select(.questions != null) | . + {answer: $ans[.id]}] | map(select($all or .answer == null))
    | sort_by(.asked_at) | reverse' "${cards[@]}" "${answers[@]+"${answers[@]}"}"
}

ask_list() {
  local json=0 all="" a rows
  for a in "$@"; do
    case "$a" in --json) json=1 ;; --all) all=--all ;; *) die "ask list: unknown arg $a (usage: chartroom ask list [--all] [--json])" ;; esac
  done
  rows="$(asks_json ${all:+"$all"})"
  if [[ $json -eq 1 ]]; then jq . <<<"$rows"; return; fi
  jq -r 'if length == 0 then "cards: nothing open"
    else .[] | "- [\(.id)] \(.asked_at[0:16] | sub("T"; " "))Z — "
      + (if .project then "[\(.project)] " else "" end) + .title
      + " (\(.questions | length) question" + (if (.questions | length) == 1 then "" else "s" end) + ")"
      + (if .answer == null then "" elif .answer.withdrawn then "  (withdrawn)" else "  (answered via \(.answer.via))" end) end' <<<"$rows"
}

ask_show() {
  local id="" json=0 a
  for a in "$@"; do case "$a" in --json) json=1 ;; *) id="$a" ;; esac; done
  [[ -n "$id" ]] || die "usage: chartroom ask show <id> [--json]"
  local card ans="null" f; card="$(ask_card_json "$id")" || die "ask show: no card $id"
  f="$(ask_answer_file "$id")"; [[ -f "$f" ]] && ans="$(cat "$f")"
  if [[ $json -eq 1 ]]; then jq --argjson a "$ans" '. + {answer: $a}' <<<"$card"; return; fi
  jq -r --argjson a "$ans" '
    if .kind == "event" then "\(.id): \(.task)'"'"'s \(.event_kind)\n  \(.text)"
    elif .kind == "inbox" then "\(.id): \(.text)"
    else "\(.id): \(.title)" + (if .context then "\n  " + .context else "" end)
      + ([.questions[] | "\n\(.id). \(.text)" + ([.options | to_entries[] | "\n   (\(.key + 1)) \(.value.label)" + (if .value.rec then "  RECOMMENDED" else "" end)] | join(""))] | join("")) end
    + (if $a == null then "\nopen" else "\nanswered via \($a.via) at \($a.at)" + (if $a.words then ":\n" + $a.words else "" end) end)' <<<"$card"
}

cmd_ask() {
  case "${1:-}" in
    "") die "$(ask_usage)" ;;
    -h|--help) ask_usage ;;
    answer) shift; ask_answer "$@" ;;
    withdraw) shift; ask_withdraw "$@" ;;
    list) shift; ask_list "$@" ;;
    show) shift; ask_show "$@" ;;
    *) ask_post "$@" ;;
  esac
}
