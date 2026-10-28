# lanes.jq - classify status rows into dashboard lanes. Input: the array of task rows built
# by dashboard_json (status_rows + dashboard_task_extra). Arguments:
#   $inbox    {waiting:[{short_id,date,project,text}], approvals:[...]} from inbox.md, and
#             relays:[{id,from,at,text,re,project,...}], the open relays from other homes
#             (lib/relay.sh): not cards, since they are the XO's to weigh, not the commander's
#   $prs      {url: {state, reviewDecision, isDraft}} (empty when gh is absent or disabled)
#   $hours    how far back "Recently finished" reaches
#   $artifacts        the open artifacts (artifacts_json --open); each card carries its own
#   $artifact_counts  {open, message, runbook, note}
#   $home, $version
#   $home_name  the home's name in the list of homes (lib/homes.sh), "" when it has none
#   $focus    focus mode's {projects, since, until}, or null (lib/focus.sh)
#
# Rules (README "Dashboard" documents the same table):
#   needs_you    decision, blocked, failed, awaiting-input, review (a worker reported done; it
#                waits on the commander's accept or close); plus inbox "Waiting ..." items
#   in_progress  working, drafting, or waiting (a stopped worker inside its `waiting` window;
#                the card carries what it waits on and until when)
#   on_hold      stopped-silent or waiting-overdue; working/done whose last event (other than
#                the worker's own `waiting` event) says it waits on a person;
#                done with an open PR that still needs someone's review (from gh)
#   ready        done (accepted by the commander), not closed, nothing above applies
#   recent       closed within $hours, or done with every known PR merged/closed (gh)
#
# Every card carries in_focus and held from its row or inbox item (lib/focus.sh), and breaking
# (a `--breaking` report or inbox item: first in Needs you). The top-level
# focus is $focus plus held, the count of held cards (null while focus is off).

def ts: if . == null or . == "" then null else (try fromdateiso8601 catch null) end;
def waits_on_person:
  (. // "") | test("waiting (on|for)|awaiting (review|approval|response|reply|feedback|merge|sign-?off)|pending (review|approval)|on hold|blocked on (a |the )?(review|approval|person|human)"; "i");
def priority: {"decision": 0, "blocked": 1, "failed": 2, "awaiting-input": 3, "review": 4}[.] // 5;
def attached($type; $owner): [$artifacts[] | select(.owner_type == $type and .owner == $owner)
  | {ref, owner_type, owner, slug, title, kind, updated}];

now as $now
| ($now - ($hours * 3600)) as $since
| map(
    . as $t
    | ($t.prs | map({url: .} + ($prs[.] // {}) | .state = ((.state // "unknown") | ascii_upcase))) as $pr
    | ($t.last_event // $t.last) as $ev
    | (($ev // "") | startswith("waiting: ")) as $said_waiting
    | (($t.closed | ts) // null) as $closed_at
    | ($pr | length > 0 and all(.[]; .state == "MERGED" or .state == "CLOSED") and any(.[]; .state == "MERGED")) as $merged
    | ($pr | any(.[]; .state == "OPEN" and (.reviewDecision == "REVIEW_REQUIRED" or .reviewDecision == "CHANGES_REQUESTED"))) as $in_review
    | {type: "task", id, short_id: ($t.short_id // $t.id), title, project, kind, backend, state, live, created, closed,
       last_event: $ev, last_at: ($t.last_event_at // $t.last_at // $t.dispatched // $t.created),
       prs: $pr, files, has_report, waiting_on: ($t.waiting_on // null), waiting_until: ($t.waiting_until // null),
       artifacts: attached("task"; $t.id),
       breaking: ($t.breaking // false), in_focus: ($t.in_focus != false), held: ($t.held // false)}
    | .lane = (
        if $t.state == "closed" then (if $closed_at != null and $closed_at >= $since then "recent" else null end)
        elif ($t.state | priority) < 5 then "needs_you"
        elif $t.state == "stopped-silent" or $t.state == "waiting-overdue" then "on_hold"
        elif $t.state == "waiting" then "in_progress"
        elif $t.state == "done" then
          (if $merged then "recent" elif $in_review or ($ev | waits_on_person) then "on_hold" else "ready" end)
        elif ($ev | waits_on_person) and ($said_waiting | not) then "on_hold"
        else "in_progress" end)
    | .reason = (
        if .lane == "needs_you" and $t.state == "review" then
          (if $merged then "PR merged" elif ($pr | length) > 0 then "PR to review" elif $t.has_report then "report to read" else "awaiting review" end)
        elif .lane == "needs_you" then .state
        elif .lane == "on_hold" then
          (if $t.state == "stopped-silent" then "stopped without reporting"
           elif $t.state == "waiting-overdue" then "waiting overdue"
           elif $in_review then "PR awaiting review" else "waiting on someone" end)
        elif .lane == "ready" then "accepted"
        elif .lane == "recent" then (if $merged then "merged" else "closed" end)
        elif $t.state == "drafting" then "drafting the brief"
        elif $t.state == "waiting" then "waiting"
        else .live end)
    | select(.lane != null))
| . as $tasks
| ($inbox.waiting | to_entries | map({type: "inbox", id: ("inbox-" + (.key | tostring)), short_id: (.value.short_id // null), project: (.value.project // null), title: .value.text,
     date: .value.date, last_at: (if .value.date then .value.date + "T00:00:00Z" else null end),
     lane: "needs_you", state: "inbox", reason: "waiting on you (inbox)", prs: [], files: [],
     artifacts: (if .value.short_id then attached("inbox"; .value.short_id) else [] end),
     breaking: (.value.text | startswith("[breaking] ")), in_focus: (.value.in_focus != false), held: (.value.held // false)})) as $waiting
| def by_recent: sort_by(.last_at // "") | reverse;
  def lane($l): $tasks | map(select(.lane == $l));
  {
    generated_at: ($now | todate),
    home: $home,
    home_name: (if $home_name == "" then null else $home_name end),
    version: $version,
    recent_hours: $hours,
    lanes: {
      needs_you: ((lane("needs_you") | sort_by([(.state | priority), (.last_at // "")])) + $waiting | sort_by(.breaking | not)),
      in_progress: (lane("in_progress") | by_recent),
      on_hold: (lane("on_hold") | by_recent),
      ready: (lane("ready") | by_recent),
      recent: ((lane("recent") | map(.finished_at = (.closed // .last_at))) | sort_by(.finished_at // "") | reverse)
    },
    inbox: {waiting: ($inbox.waiting | length), approvals: $inbox.approvals, relays: ($inbox.relays // [])},
    artifacts: $artifact_counts
  }
| .counts = (.lanes | map_values(length))
| .focus = (if $focus == null then null else $focus + {held: ([.lanes[][] | select(.held)] | length)} end)
