# lanes.jq - classify status rows into dashboard lanes. Input: the array of task rows built
# by dashboard_json (status_rows + dashboard_task_extra). Arguments:
#   $inbox    {waiting:[{date,text}], approvals:[...]} from inbox.md
#   $prs      {url: {state, reviewDecision, isDraft}} (empty when gh is absent or disabled)
#   $hours    how far back "Recently finished" reaches
#   $home, $version
#
# Rules (README "Dashboard" documents the same table):
#   needs_you    decision, blocked, failed, awaiting-input; plus inbox "Waiting ..." items
#   in_progress  working, drafting, or waiting (a stopped worker inside its `waiting` window;
#                the card carries what it waits on and until when)
#   on_hold      stopped-silent or waiting-overdue; working/done whose last event (other than
#                the worker's own `waiting` event) says it waits on a person;
#                done with an open PR that still needs someone's review (from gh)
#   ready        done, not closed, nothing above applies (a PR or report to read)
#   recent       closed within $hours, or done with every known PR merged/closed (gh)

def ts: if . == null or . == "" then null else (try fromdateiso8601 catch null) end;
def waits_on_person:
  (. // "") | test("waiting (on|for)|awaiting (review|approval|response|reply|feedback|merge|sign-?off)|pending (review|approval)|on hold|blocked on (a |the )?(review|approval|person|human)"; "i");
def priority: {"decision": 0, "blocked": 1, "failed": 2, "awaiting-input": 3}[.] // 4;

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
    | {type: "task", id, title, project, kind, backend, state, live, created, closed,
       last_event: $ev, last_at: ($t.last_event_at // $t.last_at // $t.dispatched // $t.created),
       prs: $pr, files, has_report, waiting_on: ($t.waiting_on // null), waiting_until: ($t.waiting_until // null)}
    | .lane = (
        if $t.state == "closed" then (if $closed_at != null and $closed_at >= $since then "recent" else null end)
        elif ($t.state | priority) < 4 then "needs_you"
        elif $t.state == "stopped-silent" or $t.state == "waiting-overdue" then "on_hold"
        elif $t.state == "waiting" then "in_progress"
        elif $t.state == "done" then
          (if $merged then "recent" elif $in_review or ($ev | waits_on_person) then "on_hold" else "ready" end)
        elif ($ev | waits_on_person) and ($said_waiting | not) then "on_hold"
        else "in_progress" end)
    | .reason = (
        if .lane == "needs_you" then .state
        elif .lane == "on_hold" then
          (if $t.state == "stopped-silent" then "stopped without reporting"
           elif $t.state == "waiting-overdue" then "waiting overdue"
           elif $in_review then "PR awaiting review" else "waiting on someone" end)
        elif .lane == "ready" then (if ($pr | length) > 0 then "PR to review" elif $t.has_report then "report to read" else "done" end)
        elif .lane == "recent" then (if $merged then "merged" else "closed" end)
        elif $t.state == "drafting" then "drafting the brief"
        elif $t.state == "waiting" then "waiting"
        else .live end)
    | select(.lane != null))
| . as $tasks
| ($inbox.waiting | to_entries | map({type: "inbox", id: ("inbox-" + (.key | tostring)), title: .value.text,
     date: .value.date, last_at: (if .value.date then .value.date + "T00:00:00Z" else null end),
     lane: "needs_you", state: "inbox", reason: "waiting on you (inbox)", prs: [], files: []})) as $waiting
| def by_recent: sort_by(.last_at // "") | reverse;
  def lane($l): $tasks | map(select(.lane == $l));
  {
    generated_at: ($now | todate),
    home: $home,
    version: $version,
    recent_hours: $hours,
    lanes: {
      needs_you: ((lane("needs_you") | sort_by([(.state | priority), (.last_at // "")])) + $waiting),
      in_progress: (lane("in_progress") | by_recent),
      on_hold: (lane("on_hold") | by_recent),
      ready: (lane("ready") | by_recent),
      recent: ((lane("recent") | map(.finished_at = (.closed // .last_at))) | sort_by(.finished_at // "") | reverse)
    },
    inbox: {waiting: ($inbox.waiting | length), approvals: $inbox.approvals}
  }
| .counts = (.lanes | map_values(length))
