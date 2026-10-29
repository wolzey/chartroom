# radar.jq - one machine's `chartroom status --json --all-homes` output, normalized into the fleet
# radar's records (lib/radar.sh runs it; the page is lib/dashboard/radar.html). Run with -n.
# Arguments:
#   $st       [the status output] (--slurpfile), in one of three shapes:
#               [{home, path, current, result: [rows]} | {home, path, current, error}]
#                 a current chartroom: every home on that machine ("all-homes")
#               [rows]  an older chartroom, which ignores --all-homes and reads only its
#                 default home ("single-home"); [] is read the same way (no open tasks)
#               [null]  no usable output ($contact says why)
#   $hd       [herdr agent list output] or [null]: each home's XO, as an untracked flagship
#   $phys     {"<home path>": "<path with symlinks resolved>"} for this machine's own homes ({}
#             for another machine), so herdr's cwd matches a home however it is spelled
#   $machine  the machine's label; $local "true" or "false"; $target its ssh target ("" here)
#   $via      how the machine was found ("this machine", "herdr", "config")
#   $contact  ok | unreachable | no-chartroom | error, from the call itself; $error its message
#
# Output: {machine: {...}, agents: [...], flagships: [...]}. The state table (the README's
# "Radar" section documents the same):
#   status state            live                       radar state      sector
#   decision                any                        decision         decision
#   blocked                 any                        blocked          blocked
#   awaiting-input          blocked (at a prompt)      awaiting-input   blocked
#   failed                  any                        failed           docked
#   review                  any                        review           docked
#   done                    any                        done             docked
#   waiting                 stopped (inside window)    waiting          holding
#   working + waiting_on    still live                 waiting          holding
#   working, last line reads as waiting on someone      waiting (inferred) holding
#   waiting-overdue         stopped                    overdue          adrift
#   stopped-silent          stopped/idle/done          stopped-silent   adrift
#   stopped-silent          gone                       lost             adrift
#   working                 working/running/...        working          underway
#   working                 unknown/not-started        working, live_uncertain  underway
#   drafting, closed        -                          not drawn (drafting is counted on its machine)
#   anything else           -                          unknown          adrift (never hidden)

# The board's rule for "its last line says it waits on a person" (lib/dashboard/lanes.jq
# waits_on_person): kept identical, test/radar.bats checks it, so the two views agree.
def waits_on_person:
  (. // "") | test("waiting (on|for)|awaiting (review|approval|response|reply|feedback|merge|sign-?off)|pending (review|approval)|on hold|blocked on (a |the )?(review|approval|person|human)"; "i");

# "progress: text" -> {kind, text}; a line without a kind keeps its text.
def event_of: if . == null or . == "" then null
  else ((capture("^(?<kind>[a-z][a-z-]*): ?(?<text>[\\s\\S]*)$")) // {kind: null, text: .}) end;

def shape:
  if type != "array" then "none"
  elif length == 0 then "single-home"
  elif all(.[]; type == "object" and has("home") and has("path") and (has("result") or has("error"))) then "all-homes"
  elif all(.[]; type == "object" and has("id") and has("state")) then "single-home"
  else "none" end;

def sector_of: {"decision": "decision", "blocked": "blocked", "awaiting-input": "blocked",
  "overdue": "adrift", "stopped-silent": "adrift", "lost": "adrift", "unknown": "adrift",
  "working": "underway", "waiting": "holding", "review": "docked", "done": "docked", "failed": "docked"}[.] // null;

def live_now: IN("working", "running", "in-session", "listening");

# One status row (from the home $home) -> the radar's record.
def radar($home; $is_local):
  . as $t
  | ($t.live // "unknown") as $live
  | ($t.state // "unknown") as $s
  | (($t.last // "") | startswith("waiting: ")) as $said_waiting
  | ($s == "working" and $t.waiting_on == null and ($said_waiting | not) and ($t.last | waits_on_person)) as $inferred
  | (if $s == "decision" or $s == "blocked" or $s == "awaiting-input" or $s == "failed" or $s == "review" or $s == "done" or $s == "waiting" then $s
     elif $s == "waiting-overdue" then "overdue"
     elif $s == "stopped-silent" then (if $live == "gone" then "lost" else "stopped-silent" end)
     elif $s == "working" then (if $t.waiting_on != null or $inferred then "waiting" else "working" end)
     elif $s == "drafting" or $s == "closed" then $s
     else "unknown" end) as $rs
  | ($rs == "working" and ($live | IN("unknown", "not-started"))) as $uncertain
  | ($t.last | event_of | if . then . + {at: $t.last_at} else null end) as $ev
  | {key: ([$machine, $home.name, $t.id] | join("/")),
     machine: $machine, local: $is_local, home: $home.name, home_path: $home.path,
     id: $t.id, short_id: ($t.short_id // $t.id), title: ($t.title // $t.id), project: ($t.project // ""),
     kind: $t.kind, backend: $t.backend,
     state: $rs, sector: ($rs | sector_of), status_state: $s, live: $live,
     why: (if $rs == "decision" then "asked for your call"
           elif $rs == "blocked" then "reported it cannot proceed"
           elif $rs == "awaiting-input" then "stopped at a permission or question prompt"
           elif $rs == "failed" then "reported failure"
           elif $rs == "review" then "reported done, awaiting your review" + (if $t.has_report then "; a report to read" else "" end)
           elif $rs == "done" then "accepted as done" + (if $t.has_report then "; a report to read" else "" end)
           elif $rs == "waiting" and $inferred then "looks like it is waiting, from its last message (not a waiting report)"
           elif $rs == "waiting" then "waiting on " + $t.waiting_on + (if $s == "working" and ($live | live_now) then "; its process is still live" else "" end)
           elif $rs == "overdue" then "waited past its window" + (if $t.waiting_on then " (on " + $t.waiting_on + ")" else "" end)
           elif $rs == "stopped-silent" then "its process stopped without reporting"
           elif $rs == "lost" then "its session is gone and nothing was reported"
           elif $rs == "working" and $uncertain then "reported working; its backend could not be checked (live: " + $live + ")"
           elif $rs == "working" then "working"
           else "state " + $s end),
     inferred: $inferred, live_uncertain: $uncertain,
     waiting: (if $rs == "waiting" or $rs == "overdue" then
                 {on: (if $inferred then $ev.text else $t.waiting_on end),
                  since: (if $inferred then $t.last_at else $t.waiting_since end), until: $t.waiting_until}
               else null end),
     last_event: $ev, last_activity_at: $t.last_at,
     # what the page's stacks relate tasks by (lib/dashboard/stacks.js); an older chartroom sends
     # no base or mentions, and then only titles, ids and branches relate its tasks
     branch: ($t.branch // null), base: ($t.base // null), mentions: ($t.mentions // []),
     created: $t.created, dispatched: $t.dispatched,
     has_report: ($t.has_report // false), breaking: ($t.breaking // false), stale: false};

($local == "true") as $is_local
| ($st[0]) as $s
| ($hd[0]) as $h
| (if $contact == "ok" then ($s | shape) else "none" end) as $shape
| (if $shape == "all-homes" then [$s[] | {name: .home, path, current: (.current // false), rows: (.result // []), error: (.error // null)}]
   elif $shape == "single-home" then [{name: "default", path: null, current: true, rows: $s, error: null}]
   else [] end) as $homes
| [$homes[] as $home | $home.rows[] | radar($home; $is_local)] as $all
| {
    machine: {
      machine: $machine, local: $is_local, target: (if $target == "" then null else $target end), via: $via,
      contact: (if $contact == "ok" and $shape == "none" then "error" else $contact end),
      error: (if $contact == "ok" and $shape == "none" then "chartroom status gave output the radar cannot read"
              elif $error == "" then null else $error end),
      fetched_at: (now | todate),
      capability: (if $shape == "none" then null else $shape end),
      note: (if $shape == "single-home" and ($is_local | not)
             then "older chartroom: shows its default home only; update chartroom there to see every home" else null end),
      homes: [$homes[] | {name, path, open: (.rows | length), error}],
      drafting: ([$all[] | select(.state == "drafting")] | length),
      herdr: (if $h == null then "unavailable" else "ok" end)
    },
    agents: [$all[] | select(.sector != null)],
    # Each home's XO: a herdr agent whose cwd is the home itself. An older chartroom reports no
    # home paths, so there a cwd that is a default home's directory (~/.captain, ~/.chartroom)
    # stands for its one home.
    flagships: (if $shape == "none" then [] else
      [($h // {}) | (.result.agents // [])[] | . as $a
       | ($a.cwd // $a.foreground_cwd // "") as $cwd
       | (if $shape == "all-homes"
          then ([$homes[] | select(.path != null and (.path == $cwd or ($phys[.path] // "") == $cwd))] | first)
          elif ($cwd | test("/\\.(captain|chartroom)$")) then {name: "default", path: $cwd}
          else null end) as $home
       | select($home != null)
       | {key: ([$machine, $home.name, "xo", ($a.pane_id // "")] | join("/")),
          machine: $machine, local: $is_local, home: $home.name, home_path: $cwd,
          kind: "xo", pane: ($a.pane_id // null), agent: ($a.agent // "agent"),
          status: ($a.agent_status // "unknown"),
          title: ($a.terminal_title_stripped // $a.name // "XO"), why: "untracked: no events"}]
      end)
  }
