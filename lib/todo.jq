# todo.jq - the commander's next steps, from the board. Input: the board (lanes.jq's output);
# output: the board plus .todo. Argument:
#   $artifacts  the open artifacts (artifacts_json --open), every one, on a card or not
# The program starts with focus mode's jq defs (todo_program in todo.sh), for focus_item.
#
# .todo = {focus, count, held, items}. An item is one thing the commander owes:
#   inbox              an open "Waiting on the commander" item: a question, or their own (`todo add`)
#   decision, blocked  a task waiting on their word
#   ready              finished work in review: a PR or a report to read, until they accept or close it
#   message, runbook   an open artifact to send or run (a note is not owed)
# Each is {ref, type, kind, owner, project, title, text, label, why, since, due, breaking, held,
# tickable, path}: ref is what `todo done` takes (null on an untagged inbox line), owner what
# `show` and /continue take, label the one line the views print, path an artifact's text.
#
# Order: breaking first (a "[breaking] " or "[urgent] " mark, the card's breaking, or the word
# urgent or asap), then by the earliest date in the text still ahead of the item (2026-10-22,
# 2026-10-19 06:00Z; a date alone is its midnight UTC), then oldest first.
#
# Focus mode (lib/focus.sh) decides what is held; this only reads it: each card's held, in_focus
# and breaking, and the board's .focus. An artifact is held when its owner's card is out of focus;
# one whose owner is on no card (a closed task, an answered inbox line) by focus_item; never one
# marked "[breaking] " or on a breaking card. Urgency only orders the list: an urgent item focus
# mode holds stays held. count is what is not held, held what is. Without focus mode no card
# carries a mark and nothing is held.

def marked: test("^\\[(breaking|urgent)\\] "; "i");
def unmark: sub("^\\[(breaking|urgent)\\] +"; ""; "i");
def urgent: marked or test("(?<!not )(?<!non-)\\b(urgent|asap)\\b"; "i");
# The earliest date in the text that lies ahead of the item: a date on or before the day it was
# written is a record ("(asked 2026-10-17)"), not a due date; a time later that day still counts.
def due($since):
  [scan("([0-9]{4}-[0-9]{2}-[0-9]{2})(?:[T ]([0-9]{2}:[0-9]{2})(?::[0-9]{2})?Z?)?")
   | {at: (.[0] + "T" + (.[1] // "00:00") + ":00Z"), timed: (.[1] != null)}
   | select((.at | try fromdateiso8601 catch null) != null)
   | select($since == null or (if .timed then .at >= $since else .at[0:10] > $since[0:10] end))
   | .at] | min;
def verb: {decision: "decide: ", blocked: "blocked: ", message: "send: ", runbook: "run: "}[.] // "";

. as $b
| ($b.focus // null) as $f
| [$b.lanes[][]] as $cards
| def card_of($a): first($cards[] | select(.type == $a.owner_type
    and (if .type == "task" then .id else .short_id end) == $a.owner)) // null;
  ([$b.lanes.needs_you[] | select(.type == "task" and (.state == "decision" or .state == "blocked"))
     | .state as $s
     | {ref: .short_id, type, kind: $s, owner: .short_id, project, title,
        text: ((.last_event // "") | if startswith($s + ": ") then .[($s | length) + 2:] else "" end),
        since: .last_at, held: (.held // false), card_breaking: (.breaking // false)}
     | if .text == "" then .text = .title else . end]
   + [$b.lanes.needs_you[] | select(.type == "task" and .state == "review")
     | {ref: .short_id, type, kind: "ready", owner: .short_id, project, title, text: .title, why: .reason,
        since: .last_at, held: (.held // false), card_breaking: (.breaking // false)}]
   + [$b.lanes.needs_you[] | select(.type == "inbox")
     | {ref: .short_id, type, kind: "inbox", owner: .short_id, project, title, text: .title,
        since: .last_at, held: (.held // false), card_breaking: (.breaking // false)}]
   + [$artifacts[] | select(.kind == "message" or .kind == "runbook") | card_of(.) as $c
     | {ref, type: "artifact", kind, owner: (.ref | split("/") | .[0]), project: (.project // $c.project),
        title, text: .title, since: .created, path, card_breaking: ($c.breaking // false),
        held: (if $f == null or ($c.breaking // false) or ((.title // "") | test("^\\[breaking\\] "; "i")) then false
               elif $c != null then $c.in_focus == false
               else ({project, title} | focus_item($f) | not) end)}])
| map(.title = (.title // .ref // .owner // "") | .text = (if (.text // "") == "" then .title else .text end)
    | .breaking = (.card_breaking or (.text | urgent)) | del(.card_breaking)
    | .text |= unmark
    | .due = (.since as $s | .text | due($s))
    | .label = (if .kind == "ready" then "\(.why // "ready"): \(.text)" else (.kind | verb) + .text end)
    | .tickable = ((.type == "inbox" and .ref != null) or .type == "artifact")
    | {ref, type, kind, owner, project: (.project // null), title, text, label, why: (.why // null),
       since: (.since // null), due, breaking, held, tickable, path: (.path // null)})
| sort_by([(if .breaking then 0 else 1 end), (if .due then 0 else 1 end), (.due // ""), (.since // "~")])
| . as $items
| $b + {todo: {focus: $f, count: ([$items[] | select(.held | not)] | length),
               held: ([$items[] | select(.held)] | length), items: $items}}
