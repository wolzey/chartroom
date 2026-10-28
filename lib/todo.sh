# shellcheck shell=bash
# todo.sh - `chartroom todo`: the commander's own list of next steps, made from the records the
# crew already keeps, so nothing is typed in twice: open inbox items under "Waiting on the
# commander" (the XO's questions, and the commander's own items from `todo add`), open artifacts
# to send or run, and tasks waiting on the commander's word (a decision, a blocker, finished work
# to land).
#
# lib/todo.jq computes the list from the board, and dashboard_json carries it as .todo, so the
# terminal, the crew views (one `board --json` poll) and the dashboard read the same list.
# Ticking an item off changes the record it came from: `todo done` removes an inbox line or marks
# an artifact done. A task's decision is never ticked here; it clears when the XO relays the
# answer.

# Focus mode's jq defs (lib/focus.sh) when it is there; without it focus_item is never reached
# (no card carries focus marks and the board has no .focus), but the program must still compile.
TODO_NO_FOCUS_JQ='def focus_item($f): true;'

todo_program() { printf '%s\n%s' "${FOCUS_JQ:-$TODO_NO_FOCUS_JQ}" "$(<"$CR_ROOT/lib/todo.jq")"; }

# The board on stdin, plus .todo. <artifacts> is artifacts_json --open.
todo_attach() { jq --argjson artifacts "$1" "$(todo_program)"; } # <artifacts json>

# Remove an open "Waiting" line by its tag; prints its text. When it was the last one, the
# section reads "- (none)" again, as the template has it.
inbox_remove() { # <i-xxxx>
  local tag="$1" out
  out="$(mktemp)"
  inbox_rewrite '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^## /) { w = (line[i] ~ /^## Waiting/); n = 0; sec = i; continue }
        if (!w || line[i] !~ /^- / || line[i] ~ /^- \(none\)/) continue
        if (!hit && index(line[i], "- [" tag "] ") == 1) { hit = i; hitsec = sec; continue }
        left[sec]++
      }
      if (hit) print substr(line[hit], length("- [" tag "] ") + 1) > out
      for (i = 1; i <= NR; i++) {
        if (i == hit) { if (!left[hitsec]) print "- (none)"; continue }
        print line[i]
      }
    }' -v tag="$tag" -v out="$out"
  if [[ -s "$out" ]]; then cat "$out"; rm -f "$out"; else rm -f "$out"; die "no open inbox item $tag"; fi
}

# `todo done <ref>`: an artifact (<owner>/<slug>) is marked done, an inbox item's line removed. A
# task is never ticked: its decision clears when the XO relays the answer, finished work when the
# commander accepts or closes it.
todo_done() { # <ref>
  [[ $# -eq 1 ]] || die "usage: chartroom todo done <ref> (the ref chartroom todo prints: i-7f3a, 21ba/reply-to-review)"
  if [[ "$1" == */* ]]; then artifact_done "$1"; return; fi
  local item type id text st sid
  item="$(cmd_resolve "$1" --json)" || exit 1
  IFS=$'\t' read -r type id st sid < <(jq -r '[.type, .id, (.state // ""), (.short_id // .id)] | @tsv' <<<"$item")
  if [[ "$type" == inbox ]]; then
    text="$(inbox_remove "$id")" || exit 1
    echo "done $id: ${text#* — }"
    return
  fi
  case "$st" in
    decision) die "$sid waits on your decision: it clears when the XO relays your answer (/continue $sid), not from the list" ;;
    blocked) die "$sid is blocked on you: it clears when the XO relays your answer (/continue $sid), not from the list" ;;
    review) die "$sid is finished work awaiting your review: it clears when you accept or close it (chartroom accept $sid, /continue $sid)" ;;
    *) die "$sid is a task in $st, not something on your list (open artifacts are ticked as <id>/<slug>: chartroom todo)" ;;
  esac
}

# The list in the terminal: the focus line while focus mode is on, then one line per item, the
# held ones only with --all. Color only when stdout is a terminal (and NO_COLOR is unset).
todo_print() { # <todo json> <all 0|1> <color 0|1>
  jq -r --argjson all "$2" --argjson color "$3" '
    def c($code): if $color == 1 then "\u001b[" + $code + "m" + . + "\u001b[0m" else . end;
    def pad($n): . + (" " * ([$n - length, 0] | max));
    def ago: (now - (try fromdateiso8601 catch now)) as $s
      | if $s < 3600 then "\($s / 60 | floor)m" elif $s < 86400 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end;
    def due: if test("T00:00:00Z$") then .[0:10] else .[0:10] + " " + .[11:16] + "Z" end;
    . as $t
    | [.items[] | select($all == 1 or (.held | not))] as $shown
    | ([$shown[] | (.ref // "-") | length] | max // 4) as $w
    | (if $t.focus then
        "🎯 focus: \($t.focus.projects | join(", "))\(if (($t.focus.scope // []) | length) > 0 then " (\($t.focus.scope | join(", ")))" else "" end) · \($t.held) held\(if $all == 1 or $t.held == 0 then "" else " (chartroom todo --all)" end)" | c("1;33")
       else empty end),
      (if ($shown | length) == 0 then "nothing waiting on you" | c("2")
       else $shown[]
         | "☐ " + ((.ref // "-") | pad($w) | c("1")) + "  "
           + (if .project then ("[" + .project + "]" | c("1")) + " " else "" end) + .label
           + (if .breaking then "  " + ("breaking" | c("1;31")) else "" end)
           + (if .due then "  " + ("due " + (.due | due) | c("33")) else "" end)
           + (if .held then "  " + ("held" | c("2")) else "" end)
           + (if .since then "  " + (.since | ago | c("2")) else "" end) end)' <<<"$1"
}

cmd_todo() {
  case "${1:-}" in
    done) shift; todo_done "$@"; return ;;
    add) shift; cmd_inbox add "$@"; return ;; # an inbox item like any other: it prints the id
  esac
  local json=0 all=0 color=0 a todo
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && color=1
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --all) all=1 ;;
      --color) color=1 ;;
      --no-color) color=0 ;;
      *) die "todo: unknown arg $a (usage: chartroom todo [--all] [--json] | done <ref> | add [--project P] <text>)" ;;
    esac
  done
  todo="$(dashboard_json | jq -c '.todo')"
  if [[ $json -eq 1 ]]; then jq . <<<"$todo"; return; fi
  todo_print "$todo" "$all" "$color"
}
