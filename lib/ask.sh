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
#            them (app/shared/eventfmt.js), so there is no record to write and no migration.
#   i-xxxx   an open "Waiting on the commander" inbox item.
# An answer is questions/<id>.answer.json, created only if absent (noclobber): the first answer
# wins, from the app or the terminal, and a second is refused with who answered and when.
# With the store on (CHARTROOM_STORE=sqlite), a new q- card is a store doc (kind card) instead of
# its file. An answer lives where its card does (ask_place), so the first one wins in one place:
# a file card's in its noclobber file, a store card's as a store doc (kind answer) the store
# inserts only once; a worker's ask follows its task, an inbox item's follows the item. An answer
# from the app is also told to the XO as the commander's words (lib/tell.sh), so the XO relays a
# worker's answer with `steer` and records the rest, as it would an answer typed in its session.
#
# A card the XO posts (stdin or a file, JSON):
#   {"title": "...", "kind": "grill"|"choice", "context": "...", "project": "...", "task": "<id>",
#    "initiative": "<id>", "round": {"n": 2, "of": 4},
#    "questions": [{"text": "...", "context": "...", "why": "...",
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
  local f; events_path "$1"; f="$EVENTS_PATH"
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
         | {id: ($k + 1), text: (.text | s), context: (.context | s), why: (.why | s),
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
        task_exists "$task" || die "ask: --task $2 is not a task"; shift 2 ;;
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
  while true; do id="q-$(rand_hex4)"; [[ -e "$d/$id.json" || -n "$(store_doc_list card "$id")" ]] || break; done
  card="$(ask_normalize "$id" "$(now)" <<<"$json")"
  if kind="$(relay_secret_kind "$card")"; then die "ask refused: the card looks like it holds $kind (nothing was posted)"; fi
  if store_on; then
    store_doc_put card "$id" "$card" insert || die "ask: card id $id was taken just now; post it again"
  else
    mkdir -p "$d"
    printf '%s\n' "$card" >"$d/$id.json.tmp" && mv "$d/$id.json.tmp" "$d/$id.json"
  fi
  stamp_changed
  printf '%s\n' "$id"
}

# The card behind an id, as JSON: a posted card as stored; a worker's ask as {id, kind: "event",
# task, event_kind, line, text}; an inbox item as {id, kind: "inbox", text}. Fails when unknown.
ask_card_json() { # <id>
  local id="$1"
  case "$(ask_kind "$id")" in
    q) ask_posted_card "$id" ;;
    ev)
      [[ "$id" =~ ^ev-(.+)-([0-9]+)$ ]] || return 1
      local task="${BASH_REMATCH[1]}" off="${BASH_REMATCH[2]}" got
      [[ "$task" =~ ^[a-z0-9][a-z0-9-]*$ && -d "$(tdir "$task")" ]] || return 1
      got="$(ask_event_at "$task" "$off")" || return 1
      jq -n -c --arg id "$id" --arg task "$task" --arg k "${got%%$'\t'*}" --arg line "${got#*$'\t'}" \
        '{id: $id, kind: "event", task: $task, event_kind: $k, line: $line,
          text: ($line | sub("^[^ ]+ [a-z-]+: ?"; "")), at: ($line[0:20])}' ;;
    inbox)
      local row; row="$(inbox_items_json | jq -c --arg id "$id" '.waiting[] | select(.short_id == $id)' | head -n 1)"
      [[ -n "$row" ]] || return 1
      jq -c --arg id "$id" '{id: $id, kind: "inbox", text, date, project}' <<<"$row" ;;
    *) return 1 ;;
  esac
}

ask_answer_file() { printf '%s/%s.answer.json' "$(ask_dir)" "$1"; }

# An inbox item born in the store (lib/store.sh renders them into .inbox.json).
inbox_in_store() { # <i-id>
  store_load || return 1
  [[ -s "$STORE_D/.inbox.json" ]] && jq -e --arg id "$1" 'any(.[]; .id == $id)' "$STORE_D/.inbox.json" >/dev/null
}

# Where a card and its answer live: db (store docs) or file (questions/).
ask_place() { # <id>
  case "$(ask_kind "$1")" in
    q) if [[ -f "$(ask_dir)/$1.json" ]]; then echo file
       elif [[ -n "$(store_doc_list card "$1")" ]]; then echo db
       else echo file; fi ;;
    ev) [[ "$1" =~ ^ev-(.+)-([0-9]+)$ ]] && is_store_task "${BASH_REMATCH[1]}" && { echo db; return 0; }; echo file ;;
    inbox) if inbox_in_store "$1"; then echo db; else echo file; fi ;;
    *) echo file ;;
  esac
}

# A posted card (q-), from wherever it lives; fails when there is none.
ask_posted_card() { # <q-id>
  local f; f="$(ask_dir)/$1.json"
  if [[ -f "$f" ]]; then cat "$f"; return 0; fi
  local c; c="$(store_doc_list card "$1")"
  [[ -n "$c" ]] && printf '%s\n' "$c"
}

# The card's answer (its JSON), or nothing while it is open.
ask_answer_get() { # <id>
  if [[ "$(ask_place "$1")" == db ]]; then store_doc_list answer "$1"
  else local f; f="$(ask_answer_file "$1")"; [[ ! -f "$f" ]] || cat "$f"; fi
}

# The first answer, kept only if there is none yet: fails when one is there already.
ask_answer_put() { # <id> <record>
  if [[ "$(ask_place "$1")" == db ]]; then store_doc_put answer "$1" "$2" insert || return 1; return 0; fi
  mkdir -p "$(ask_dir)"
  ( set -o noclobber; printf '%s\n' "$2" >"$(ask_answer_file "$1")" ) 2>/dev/null
}

# The answer kept, updated after it won (who was told).
ask_answer_set() { # <id> <record>
  if [[ "$(ask_place "$1")" == db ]]; then store_doc_put answer "$1" "$2"; return; fi
  local f; f="$(ask_answer_file "$1")"
  printf '%s\n' "$2" >"$f.tmp" && mv "$f.tmp" "$f"
}

# Every answer kept, {card id: answer}: the files and the store's.
answers_json() {
  local d afiles=() st; d="$(ask_dir)"
  if [[ -d "$d" ]]; then shopt -s nullglob; afiles=("$d"/*.answer.json); shopt -u nullglob; fi
  st="$(store_doc_list answer | jq -s -c .)" || exit 1
  { [[ ${#afiles[@]} -eq 0 ]] || cat "${afiles[@]}"; } | jq -s -c --argjson st "$st" '
    (. + $st) | map(select(type == "object" and (.id | type) == "string") | {key: .id, value: .}) | from_entries' 2>/dev/null || echo '{}'
}

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
        elif ($a.answers | length) > 1 then
          # a round asked by a worker: each answer names the question it answers
          "Answers to \($c.task)'"'"'s \($c.event_kind) (\($ask)):"
          + ([$a.answers[] | "\n\(.q). " + (if (.question | type) == "string" then (.question | line) + " → " else "" end) + say(.)] | join(""))
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
  local had; had="$(ask_answer_get "$id")"
  if [[ -n "$had" ]]; then
    die "ask answer: $id was already answered ($(jq -r '"by \(.via) at \(.at)" + (if .withdrawn then ", withdrawn" else "" end)' <<<"$had" 2>/dev/null || echo "earlier"))"
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
    elif $c.kind == "event" or $c.kind == "inbox" then (if ($a.answers | all(has)) then empty else "every question needs a choice or a note" end)
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
  # The first answer wins: it is kept only if there is none yet (a noclobber file, or a store insert).
  if ! ask_answer_put "$id" "$rec"; then
    die "ask answer: $id was already answered ($(ask_answer_get "$id" | jq -r '"by \(.via) at \(.at)"' 2>/dev/null || echo "just now"))"
  fi
  # From the app, the XO hears it as the commander's words; in the terminal it already has them.
  # A worker's own ask (ev-) answered from the app goes to the worker directly, after the answer
  # is kept (the steer closes the ask), and the XO is told it as done, not to relay. A steer
  # that cannot be delivered (the worker mid-run, gone, or not steerable from here) leaves the
  # XO to relay it, as before: the answer stands either way.
  local steered=false
  if [[ "$via" == app ]]; then
    local re project
    re="$(jq -r 'if .kind == "event" then .task else .id end' <<<"$card")"
    project="$(jq -r '.project // empty' <<<"$card")"
    [[ -n "$project" ]] || { [[ "$re" == "$id" ]] || project="$(project_label "$re" 2>/dev/null || true)"; }
    local say="$words"
    if [[ "$(jq -r .kind <<<"$card")" == event ]]; then
      # (bounded: the app runs this verb under a time limit, and a steer can wait on a park or a
      # resume. One still going after CR_ASK_STEER_WAIT seconds carries on by itself; the XO is
      # told it is under way, so the XO is told in any case.)
      local sp i rc=0 wait_s="${CR_ASK_STEER_WAIT:-40}"
      "$CR_BIN" steer "$re" "The commander answered your $(jq -r .event_kind <<<"$card") from the app. $words" </dev/null >/dev/null 2>&1 &
      sp=$!
      for ((i = 0; i < wait_s * 4; i++)); do kill -0 "$sp" 2>/dev/null || break; sleep 0.25; done
      if kill -0 "$sp" 2>/dev/null; then
        steered='"pending"'
        say="Answered $re from the app; a steer of it to the worker is still being delivered, so check $re's events before relaying it. $words"
      else
        wait "$sp" || rc=$?
        if (( rc == 0 )); then
          steered=true
          say="Answered $re directly from the app: the worker has it already (steered), so there is nothing to relay. $words"
        fi
      fi
    fi
    told="$(tell_send --via app --re "$re" ${project:+--project "$project"} -- "$say")" ||
      warn "answered $id, but could not tell the XO; the answer is kept (chartroom ask show $id)"
    if [[ -n "$told" || "$steered" != false ]]; then
      rec="$(jq -c --arg t "$told" --argjson s "$steered" '.told = (if $t == "" then null else $t end) | .steered = $s' <<<"$rec")"
      ask_answer_set "$id" "$rec"
    fi
  fi
  # an answered card of an initiative is one of its decisions, numbered, linked to the card
  local init; init="$(jq -r '.initiative // empty' <<<"$card")"
  if [[ "$init" =~ $CR_INIT_ID_RE && -f "$(init_file "$init")" ]]; then
    initiative_decide "$init" --card "$id" -- "$words" >/dev/null || warn "answered $id, but could not record it as a decision of $init"
  fi
  stamp_changed
  echo "answered $id$(case "$steered" in true) echo " (steered to the worker)" ;; '"pending"') echo " (a steer to the worker is under way)" ;; esac)${told:+ (told the XO: $told)}"
}

ask_withdraw() {
  local id="${1:-}"; shift || true
  [[ "$id" =~ $CR_ASK_ID_RE ]] && ask_posted_card "$id" >/dev/null || die "ask withdraw: no card $id (a q-xxxx the XO posted)"
  local rec; rec="$(jq -n -c --arg id "$id" --arg at "$(now)" --arg r "$*" '{schema: 1, id: $id, at: $at, via: "xo", withdrawn: true, note: (if $r == "" then null else $r end), answers: []}')"
  ask_answer_put "$id" "$rec" || die "ask withdraw: $id was already answered"
  stamp_changed
  echo "withdrew $id"
}

# The commander's decisions on tasks: every answered card that belongs to one, newest first. Two
# sources, wherever the answer came from (the app, the terminal, or the XO recording it with
# `ask answer`):
#   - a card the XO posted (`chartroom ask`, a choice or a grilling round) whose task is one of these;
#   - a task's own ask (a worker's decision or plan, ev-<task>-<offset>) answered in the app.
# A withdrawn card decided nothing. Each question in its own words, with the answer and the note:
#   [{card, kind: choice|round|decision|approval, task, title, asked_at, at, via, note,
#     questions: [{text, choice, note}]}]
decisions_json() { # <task id>...
  [[ $# -gt 0 ]] || { echo '[]'; return; }
  local tasks answers cards evs
  tasks="$(jq -n -c '$ARGS.positional' --args "$@")"
  answers="$(answers_json)"
  cards="$(asks_json --all | jq -c --argjson t "$tasks" '[.[] | select(.task != null and (.task as $x | $t | index($x)) and .answer != null and (.answer.withdrawn | not))]')"
  # a task's own asks with an answer: each one's question, from its event line
  evs="$(jq -r --argjson t "$tasks" 'keys[] | select(test("^ev-.+-[0-9]+$")) | select(capture("^ev-(?<t>.+)-[0-9]+$").t as $x | $t | index($x))' <<<"$answers" \
    | while IFS= read -r k; do [[ -z "$k" ]] || ask_card_json "$k" 2>/dev/null || true; done | jq -s -c .)"
  jq -n -c --argjson cards "$cards" --argjson evs "${evs:-[]}" --argjson ans "$answers" '
    def headline: if length > 140 then (.[0:140] | sub("[\\s,;:(]+[^\\s]*$"; "")) + "…" else . end;
    ([$cards[] | . as $c | $c.answer as $a
      | {card: $c.id, kind: (if ($c.questions | length) > 1 then "round" else "choice" end), task: $c.task, initiative: ($c.initiative // null),
         title: $c.title, asked_at: $c.asked_at, at: $a.at, via: $a.via, note: ($a.note // null),
         questions: [$a.answers[]? as $x | ($c.questions[] | select(.id == $x.q)) as $q
           | {text: $q.text, choice: ($x.choice // null), note: ($x.note // null)}]}]
     + [$evs[] | . as $c | $ans[$c.id] as $a | select($a != null and ($a.withdrawn | not))
      | ($c.text | sub("\\s+--detail\\s.*$"; "") | sub("\\s*\\bDetails?:.*$"; "")) as $ask
      | {card: $c.id, kind: (if $a.action then "approval" else "decision" end), task: $c.task, initiative: null,
         title: ($ask | headline), asked_at: $c.at, at: $a.at, via: $a.via, note: ($a.note // null),
         questions: (if $a.action == "approve" then [{text: $ask, choice: "Approved", note: ($a.note // null)}]
                     elif $a.action == "changes" then [{text: $ask, choice: "Changes requested", note: ($a.note // null)}]
                     else [$a.answers[]? | {text: ((.question // null) // $ask), choice: (.choice // null), note: (.note // null)}] end)}])
    | sort_by(.at // "") | reverse'
}

# Every posted card with its answer (null while open), newest first: [{card..., answer}].
asks_json() { # [--all]
  local d; d="$(ask_dir)"
  local all=false; [[ "${1:-}" == --all ]] && all=true
  shopt -s nullglob
  local files=("$d"/q-*.json)
  shopt -u nullglob
  local st
  st="$({ store_doc_list card; store_doc_list answer; } | jq -s -c .)" || exit 1
  { [[ ${#files[@]} -eq 0 ]] || cat "${files[@]}"; } | jq -s -c --argjson all "$all" --argjson st "$st" '
    (. + $st) as $docs
    | ($docs | map(select(.answers != null or .withdrawn == true)) | map({key: .id, value: .}) | from_entries) as $ans
    | [$docs[] | select(.questions != null) | . + {answer: $ans[.id]}] | map(select($all or .answer == null))
    | sort_by(.asked_at) | reverse' 
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
  f="$(ask_answer_get "$id")"; [[ -z "$f" ]] || ans="$f"
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
