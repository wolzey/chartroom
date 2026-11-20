# snapshot.jq - one home as the app sees it: every task with its app status (the seven of the
# design), and Needs me, built from the records alone. Input (lib/app.sh, app_snapshot_json):
#   {home, home_name, machine, version, rows: [status rows + extras], inbox: {waiting, approvals},
#    artifacts: [open artifacts], cards: [open posted cards], answers: {id: answer}, tells: [told
#    messages, newest last], snoozes: {ref: until}, focus: {projects, since, until} | null}
# The server only caches and serves this; what an item means is decided here.
#
# App status (the design's seven) from a task's state:
#   drafting                                  -> drafting
#   working                                   -> working   (stalled: a warning, never a status)
#   waiting, waiting-overdue, stopped-silent  -> waiting   (overdue / stopped without reporting: a warning)
#   decision, blocked, failed, awaiting-input -> needs
#   review                                    -> review
#   done                                      -> done      (accepted)
#   closed                                    -> closed
# queued has no source until initiatives hold stories (slice 4) or remote dispatch places work.
#
# Needs me groups: decide (worker decisions, posted cards, inbox questions), approve (plan
# approvals, inbox approvals), unblock (blocked, failed, a prompt nothing answers), read (a done
# report or PR to review, drafts to send or run). An item answered from the app (or the terminal)
# leaves the list for "sent" until the XO acts on it; a snoozed item leaves it until its time; an
# item focus mode holds is counted, not listed.

def status7:
  {"drafting": "drafting", "working": "working", "waiting": "waiting", "waiting-overdue": "waiting",
   "stopped-silent": "waiting", "decision": "needs", "blocked": "needs", "failed": "needs",
   "awaiting-input": "needs", "review": "review", "done": "done", "closed": "closed"}[.] // "working";
def warning($t):
  if $t.state == "waiting-overdue" then "waiting overdue"
  elif $t.state == "stopped-silent" then "stopped without reporting"
  elif ($t.last_event // "") | startswith("stalled: ") then "stalled"
  else null end;
def cut($n): if . == null then null elif length > $n then .[0:$n - 1] + "…" else . end;
# a title from free text: the first ~100 characters, at a word boundary
def headline: if . == null then null elif length > 100 then (.[0:100] | sub("[\\s,;:(]+[^\\s]*$"; "")) + "…" else . end;
def plan_ask: test("plan (is )?ready for (your )?approval|approve the plan|plan.md (is )?ready"; "i");
def askline: sub("^[^ ]+ [a-z-]+: ?"; "");

. as $in
| ($in.answers // {}) as $answers
| ($in.snoozes // {}) as $snoozes
| ([$in.tells[]? | {key: .id, value: .}] | from_entries) as $tells
| ([$in.artifacts[]? | {ref, owner_type, owner, slug, title, kind, updated}]) as $arts
| def arts_of($type; $id): [$arts[] | select(.owner_type == $type and .owner == $id)];
  def sent($id): ($answers[$id] // null) as $a
    | if $a == null then null
      else {at: $a.at, via: $a.via, withdrawn: ($a.withdrawn // false), told: $a.told,
            read_by_xo: (if $a.told then ($tells[$a.told].acked // false) else null end), words: ($a.words | cut(600))} end;

[$in.rows[]? | . as $t
  | {id, short_id: (.short_id // .id), title, project, kind, backend, state, live,
     status: (.state | status7), warning: warning($t),
     created, dispatched: (.dispatched // null), closed: (.closed // null),
     last_event: (.last_event // .last), last_at: (.last_event_at // .last_at // .dispatched // .created),
     waiting_on, waiting_until, branch: (.branch // null), prs: (.prs // []), files: (.files // []),
     has_report, breaking: (.breaking // false), in_focus: (.in_focus != false), held: (.held // false),
     ask: (.ask // null), intent: (.intent // null), artifacts: arts_of("task"; .id)}] as $tasks

| ([$tasks[] | select(.status == "needs" or .status == "review")
    | . as $t
    | ($t.ask) as $ask
    | (if $t.status == "review" then
         {kind: "review", group: "read",
          sub: (if ($t.prs | length) > 0 then "PR to review" elif $t.has_report then "report to read" else "awaiting review" end),
          ref: $t.id, summary: ($t.last_event | cut(900))}
       elif $ask == null then
         {kind: (if $t.state == "decision" then "decide" elif $t.state == "awaiting-input" then "input" else $t.state end),
          group: (if $t.state == "decision" then "decide" else "unblock" end), ref: $t.id, summary: ($t.last_event | cut(900))}
       else ($ask.line | askline) as $text
         | {kind: (if $ask.kind == "decision" then (if ($text | plan_ask) then "approve" else "decide" end)
                   elif $ask.kind == "awaiting-input" then "input" else $ask.kind end),
            group: (if $ask.kind == "decision" then (if ($text | plan_ask) then "approve" else "decide" end) else "unblock" end),
            ref: $ask.id, card: $ask.id, text: $text, summary: ($text | cut(4000)), asked_at: $ask.line[0:20]} end) as $it
    | $it + {id: $it.ref, type: "task", task: $t.id, short_id: $t.short_id, title: $t.title, project: $t.project,
             at: ($it.asked_at // $t.last_at), breaking: $t.breaking, held: $t.held,
             prs: $t.prs, has_report: $t.has_report, files: $t.files, intent: $t.intent, artifacts: $t.artifacts,
             live: $t.live, state: $t.state}]
  + [$in.cards[]? | select(.answer == null or ((.answer.at | fromdateiso8601? // 0) > now - 48 * 3600))
     | {id, type: "card", kind: (if (.questions | length) > 1 then "round" else "decide" end), group: "decide",
       ref: .id, card: .id, title, project, task, initiative, at: .asked_at, round, context, questions,
       summary: (.context // (if (.questions | length) == 1 then .questions[0].context else null end)),
       breaking: false, held: false}]
  + [$in.inbox.waiting[]? | select(.short_id != null)
     | {id: .short_id, type: "inbox", kind: "inbox", group: "decide", ref: .short_id, card: .short_id,
        title: (.text | headline), text, summary: .text, project, at: (if .date then .date + "T00:00:00Z" else null end),
        breaking: (.text | startswith("[breaking] ")), held: (.held // false), artifacts: arts_of("inbox"; .short_id)}]
  + [$in.inbox.approvals[]?
     | {id: ("approval-" + (.text | @base64 | gsub("[^A-Za-z0-9]"; "") | .[0:20])), type: "approval", kind: "approval", group: "approve",
        ref: null, title: (.text | headline), text, summary: .text, project, at: (if .date then .date + "T00:00:00Z" else null end),
        breaking: false, held: false}]
  + [$arts[] | select(.kind == "message" or .kind == "runbook")
     | {id: .ref, type: "artifact", kind: "artifact", group: "read", sub: .kind, ref: .ref, title, project: null,
        owner_type, owner, at: .updated, breaking: false, held: false}]
  ) as $all
| ($all | map(. + {sent: (if .card then sent(.card) else null end),
                   snoozed_until: (if .ref and $snoozes[.ref] then $snoozes[.ref] else null end)})) as $all
| {schema: 1, home: $in.home_name, path: $in.home, machine: $in.machine, version: $in.version,
   generated_at: (now | todate), focus: $in.focus,
   counts: {needs: ([$all[] | select(.sent == null and .snoozed_until == null and (.held | not))] | length),
            held: ([$all[] | select(.held and .sent == null)] | length),
            snoozed: ([$all[] | select(.snoozed_until != null and .sent == null)] | length),
            sent: ([$all[] | select(.sent != null)] | length)},
   needs: ($all | sort_by([(if .breaking then 0 else 1 end), (.at // "")]) ),
   tasks: $tasks,
   tells: [$in.tells[]? | {id, at, via, re, project, acked, text: (.text | cut(300))}] | .[-30:]}
