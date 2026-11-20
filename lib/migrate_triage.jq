# migrate_triage.jq - the buckets of `chartroom migrate-home triage` (lib/migrate.sh).
# Input: an array of rows, one per open task on the client: its status row (state, live, kind,
# title, has_report, last_at, created), its git facts (wst, dirty, unpushed, ahead, head), the PRs
# of its branch (prs: [{state, number, title, url, head}]), and studio_wt (a worktree the brain
# already holds for it, or ""). $now: epoch seconds.
# Output: each row plus bucket (a|b|c|d), why, exc (a list) and action (the decision prefilled:
# close, accept, keep, bundle or move; only a live worker moves with its worktree now, and a recently
# active one is kept, its worktree rebuilt on first use). Unknown git facts fail closed: they count as work.
def num0: if . == null then 0 else . end;
map(
  . as $r
  | (($r.last_at // $r.updated // $r.created // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $t
  | (if $t == null then 999 else ((($now - $t) / 86400) | floor) end) as $idle
  | ([($r.prs // [])[] | .state | ascii_downcase]) as $sts
  | (any($sts[]; IN("merged", "completed"))) as $merged
  | (any($sts[]; IN("open", "active"))) as $openpr
  | ((($r.prs // []) | length) > 0 and ($merged | not) and ($openpr | not)) as $closedonly
  | ($r.wst == "own" or $r.wst == "shared") as $own
  | ($own and ($r.dirty == null or $r.unpushed == null or $r.ahead == null)) as $unknown
  | (if $unknown then 1 else ($r.dirty | num0) end) as $dirty
  | (if $unknown then 1 else ($r.unpushed | num0) end) as $unp
  | (if $unknown then 1 else ($r.ahead | num0) end) as $ahead
  | ($dirty == 0 and $unp == 0) as $clean
  | (($r.head // "") as $h | $h != "" and any(($r.prs // [])[];
      (.head // "") as $ph | (.state | ascii_downcase | IN("merged", "completed")) and $ph != "" and (($ph | startswith($h)) or ($h | startswith($ph)))))
    as $mergedhead
  | (($r.studio_wt // "") != "") as $swt
  | ($r.state == "waiting-overdue" or $idle > 7) as $stale
  | (($r.wst | IN("none", "missing")) or ($ahead == 0 and $dirty == 0)) as $nowork0
  | ($nowork0 and (($r.kind == "scout" and $r.has_report == true) | not) and ($swt | not)) as $nowork
  | ($dirty > 0 or ($ahead > 0 and ($merged | not))) as $unlanded
  | (($r.live | IN("working", "blocked")) or ($r.state | IN("working", "awaiting-input"))) as $live
  | (if $live then ["d", "live worker"]
     elif $r.state == "drafting" then ["b", "drafted, never dispatched"]
     elif ($r.state | IN("decision", "blocked", "failed")) then ["b", $r.state]
     elif $merged and $clean and ($openpr | not) and ($mergedhead or ($own | not)) and ($swt | not) then ["a", "PR merged at this HEAD, nothing local"]
     elif $closedonly and $clean and ($swt | not) then ["a", "PR closed or abandoned, nothing local"]
     elif ($r.state | IN("review", "done")) then ["b", $r.state]
     elif $stale and $r.kind == "scout" and $r.has_report == true and ($unlanded | not) then ["b", "\($r.state), scout report to read"]
     elif $stale and ($unlanded or $openpr) then ["c", "\($r.state), idle \($idle)d, " + (if $openpr then "open PR" else "unlanded work" end)]
     elif $stale and $nowork then ["a", "\($r.state), idle \($idle)d, no work"]
     elif $stale then ["c", "\($r.state), idle \($idle)d"]
     else ["d", "\($r.state), active \($idle)d ago"] end) as [$b, $why]
  | ([ (if $unknown then "git facts unreadable: treated as having work" else empty end),
       (if $swt then "the brain already holds a worktree for it: \($r.studio_wt)" else empty end),
       (if $merged and ($clean | not) then "PR merged but local-only commits or changes" else empty end),
       (if $merged and $clean and ($mergedhead | not) and $own and $b != "a" then "PR merged, but HEAD is not the merged head" else empty end),
       (if $b == "c" and $openpr and $idle <= 7 then "overdue but recent, open PR: keep" else empty end),
       (if $b == "d" and ($r.state | IN("review", "done")) then "live terminal on a finished task" else empty end),
       (if $r.state == "awaiting-input" then "blocked at a prompt: answer it before the freeze" else empty end)
     ]) as $exc
  | (if $b == "a" then "close"
     elif $b == "d" then (if $live then "move" else "keep" end)
     elif $b == "c" then (if any($exc[]; startswith("overdue but recent")) then "keep" else "bundle" end)
     elif ($r.state | IN("review", "done")) and $idle > 7 and $dirty == 0 and $unp == 0 and ($exc | length) == 0 then "accept"
     else "keep" end) as $action
  | $r + {bucket: $b, why: $why, exc: $exc, action: $action, idle: $idle})
