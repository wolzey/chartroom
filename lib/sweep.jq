# sweep.jq - classify what the crew left running (chartroom sweep). Pure: no I/O, so the
# rules are all here. Arguments:
#   $procs   this user's processes: [{pid, ppid, age, cpu, pcpu, rss, tty, cwd, args, root, root_gone}]
#            (age, cpu: seconds; rss: kB; root: the chartroom worktree dir the cwd lies in)
#   $tasks   every task: [{id, state, live, backend, runner, project, kind, joined, pid, dirs, wt,
#            idle, herdr_tab, herdr: {tab, status}|null, close: {ok, reason, later}|null}]
#   $panes   herdr's panes: [{pane, tab, cwd, agent}] ([] without herdr)
#   $homes   the home as given and physically
#   $self    the sweep's own pid; it and its ancestors are never touched
#   $idle    seconds a finished-but-open task must be idle before its leftovers are raised
#   $failed  task ids whose close failed in this run: nothing of theirs is safe
#   $dash    the pid of the dashboard .dashboard.pid tracks ("" when none runs)
#   $others  the other registered homes: {homes: their dirs, ids: their task ids, wts: the
#            worktrees their tasks record}
#
# Output: {items, summary}. Each item: {class, action, reason, task, what, pids, procs, age_s,
# cpu_s, pcpu, rss_kb}; class session | close | orphan | daemon; action apply (the safe set) |
# human (needs a human). Work that is in flight, or too fresh to judge, is never an item;
# summary.kept counts its processes.
#
# The rules:
#   in-flight tasks (anything but review, done, failed, stopped-silent, closed): never touched.
#   review (a worker reported done; the commander has not accepted it) is finished but never
#            closed by sweep: only the commander says it is done (`chartroom accept`/`close`).
#   session  (the agent chartroom started, its launcher and pane shell, and what runs under it)
#            closed task -> apply (a leftover herdr pane in its worktree too). done task that closes in this sweep -> apply. A joined
#            session (the commander's own) -> human. review, done (not closeable), failed,
#            stopped-silent, idle >= $idle -> human. Otherwise kept.
#   close    done (accepted), clean, nothing unlanded, settled -> apply. Not closeable and idle >= $idle,
#            or holding processes -> human.
#   orphan   `chartroom watch` run from this home whose session is gone (nearest real parent
#            is init) -> apply; from an unknown home -> human. `listen <id>` of this home's
#            task: orphaned or its task closed -> apply. A second dashboard for this home
#            (not the one .dashboard.pid tracks) -> apply; an untracked one -> human.
#   daemon   in a closed task's worktree, or one that closes in this sweep -> apply; in a
#            dir under this home's worktrees/ that no longer exists -> apply; in any other
#            chartroom worktree dir no task of this home records -> human; in a review/done/failed/stopped-silent task's worktree, running
#            >= $idle with the task idle >= $idle -> human. A process with a terminal is
#            never apply (someone may be using it): human instead.
#   other homes  a loop run from another registered home, a listener for its task, a process in
#            a worktree its task records: kept, never listed (that home's sweep sees to it).

def base: split("/") | last;
def words: split(" ") | map(select(length > 0));
def under($p): . == $p or startswith($p + "/");
def mentions($p): (.args + " ") | contains($p + "/") or contains($p + " ");
def finished: IN("review", "done", "failed", "stopped-silent", "closed");
def dur: floor as $s
  | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
    else "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h" end;

# A short name for a process: a known dev tool by name, else the program (for an interpreter,
# the script it runs) and its first arguments.
def known: [
  ["nx(\\.js)? daemon|nx/src/daemon", "nx daemon"], ["nx(\\.js)? (run|serve|watch)", "nx"],
  ["(^|[/ ])tsc( .*)? (--watch|-w)( |$)", "tsc --watch"], ["(^|[/ ])vite(\\.js)?( |$)", "vite"],
  ["(^|[/ ])vitest", "vitest"], ["(^|[/ ])next(\\.js)? dev|next-server|next/dist/server", "next dev"],
  ["(^|[/ ])nuxt(\\.mjs)? dev|nuxi dev", "nuxt dev"], ["esbuild.* --service", "esbuild service"],
  ["(^|[/ ])turbo(d)? .*daemon|turbod", "turbo daemon"], ["(^|[/ ])turbo .*(dev|watch)", "turbo"],
  ["(^|[/ ])webpack.*(serve|--watch)", "webpack watch"], ["(^|[/ ])nodemon", "nodemon"],
  ["(^|[/ ])jest .*--watch", "jest --watch"], ["storybook", "storybook"],
  ["(^|[/ ])rails (s|server)( |$)|(^|[/ ])puma", "rails server"], ["(^|[/ ])sidekiq", "sidekiq"],
  ["(^|[/ ])spring (server|app)", "spring"], ["(^|[/ ])(guard|foreman|overmind)( |$)", "dev runner"]];
def pname:
  .args as $a
  | (first(known[] as $kn | select($a | test($kn[0])) | $kn[1]) // null) as $k
  | ($a | words) as $w | (($w[0] // "") | base) as $b
  # an interpreter: name the script it runs (its first non-flag argument) and what follows it
  | (if ($b | test("^(node|nodejs|bun|deno|python[0-9.]*|ruby|perl|php|java|bash|sh|zsh)$")) and ($w | length) > 1 then
       (first(range(1; $w | length) as $i | select($w[$i] | startswith("-") | not) | $i) // null) as $i
       | if $i then ([($w[$i] | base | sub("\\.(m?js|cjs|ts|py|rb|sh|pl)$"; ""))] + $w[$i + 1:$i + 3]) | join(" ") else $b end
     else ([$b] + $w[1:3]) | join(" ") end) as $g
  | (if $k and ($g | startswith($k) | not) then "\($k) (\($g))" else $g end) | if length > 70 then .[0:69] + "…" else . end;

def agent: (.args | words | .[0] // "" | base) as $b
  | IN($b; "claude", "codex") or (IN($b; "node", "bun") and (.args | test("/(claude|codex)(\\.js)?( |$)")));
# Is this process the session chartroom started for the task in <dir>? An agent naming the
# directory (claude --add-dir/--settings, codex -o/--add-dir), the session launcher, or a wrapper
# passing the agent its --add-dir. Anything else that merely names it (a pager or editor on its
# report, a tail -f of its events) is not.
def session_for($d): mentions($d) and (agent or ((.args + " ") | contains($d + "/launch.sh ") or contains("--add-dir " + $d + " ")));
# A wrapper that is not "the session": `sh -c ...` shells, nohup, timeout, env.
def wrapper: (.args | words) as $w | (($w[0] // "") | base) as $b
  | IN($b; "nohup", "timeout", "env", "caffeinate") or (IN($b; "sh", "bash", "zsh", "dash", "ksh", "fish") and any($w[]; . == "-c"));

($procs | map({key: (.pid | tostring), value: .}) | from_entries) as $by
| ([limit(64; $self | recurse(if . > 1 then ($by[tostring].ppid // 0) else empty end))]) as $mine
| (now) as $now

# Is p's session gone? Its nearest real parent (shell -c wrappers skipped) is init: pid 1, or
# a launchd / init / systemd (a subreaper) of this user.
| def orphaned: . as $p
    | (reduce range(0; 32) as $_ ({at: $p.ppid, done: false};
        if .done then . else ($by[.at | tostring]) as $q
          | if $q != null and ($q | wrapper) then .at = $q.ppid else .done = true end end) | .at) as $a
    | $a <= 1 or (($by[$a | tostring] // null) as $q | $q != null
        and (($q.args | words | .[0] // "" | base | ltrimstr("-")) | IN("launchd", "init", "systemd")));

# chartroom's own loops: {kind: watch|listen|dashboard, arg}
  def loop:
    (.args | words) as $w
    | if (.args | test("(^|/)dashboard/server\\.py( |$)")) then
        {kind: "dashboard", arg: ([range(0; ($w | length) - 1) as $i | select($w[$i] == "--pidfile") | $w[$i + 1]] | first // null)}
      else
        ([range(0; ($w | length) - 1) as $i | select(($w[$i] | base) == "chartroom" and IN($w[$i + 1]; "watch", "listen"))
          | {kind: $w[$i + 1], arg: ($w[$i + 2] // null)}] | first // null)
      end;

  ($tasks | map({key: .id, value: .}) | from_entries) as $T
| ($procs | map(select(.pid as $x | any($mine[]; . == $x) | not))) as $P
| ([$P[] | . as $p | ($p | loop) as $l | select($l != null) | $p + {loop: $l}]) as $loops
| ([$loops[].pid]) as $loop_pids

# Direct attribution: the task's session (session_for, or the pid recorded for the task), else
# the task's worktree as cwd or in argv, else a chartroom worktree dir no task records.
| ([$tasks[] | select((.dirs | length) > 0)]) as $TT
| ([$P[] | select(.pid as $x | any($loop_pids[]; . == $x) | not)
     | select(((.args + " " + .cwd) | contains("/tasks/") or contains("worktrees")))
     | . as $p
     | (first($TT[] | . as $t | select(any($t.dirs[]; . as $d | $p | session_for($d)) or ($p.pid == $t.pid and any($t.dirs[]; . as $d | $p | mentions($d)))) | $t.id) // null) as $s
     | (if $s then null else (first($TT[] | select(.wt != "") | . as $t | select(($p.cwd | under($t.wt)) or ($p | mentions($t.wt))) | .id) // null) end) as $w
     | if $s then {pid, task: $s, kind: "session"}
       # An agent found only by its directory is the task's session when it has no terminal, or
       # herdr has a pane there; with a terminal of its own it may be someone's own session.
       elif $w then {pid, task: $w, kind: (if $p.pid == $T[$w].pid
           or (($p | agent) and ($p.tty == "" or any($panes[]; .cwd | under($T[$w].wt)))) then "session" else "dev" end)}
       elif $p.root != "" then {pid, task: null, kind: "dev", root: $p.root, root_gone: $p.root_gone}
       else empty end]
   | map({key: (.pid | tostring), value: .}) | from_entries) as $direct

# Descendants inherit: anything under a session's agent is that session (its tool shells, MCP
# servers, a dev server it started and still owns), whatever its own directory; anything else
# takes its own attribution, else its nearest attributed ancestor's (a dev server's workers).
| ($P | map(select(.pid as $x | any($loop_pids[]; . == $x) | not)) | map(. as $p
    | (reduce range(0; 32) as $_ ({at: $p.ppid, ses: null, any: null};
        if .ses != null or .at <= 1 then . else ($direct[.at | tostring] // null) as $d
          | (if $d != null and $d.kind == "session" then .ses = $d else . end)
          | (if $d != null and .any == null then .any = $d else . end)
          | .at = (($by[.at | tostring].ppid) // 0) end)) as $up
    | ($direct[$p.pid | tostring] // null) as $own
    | (if $up.ses != null and ($own == null or $own.task == null or $own.task == $up.ses.task) then $up.ses
       else ($own // $up.any) end) as $a
    | select($a != null) | $p + {task: $a.task, kind: $a.kind, root: ($a.root // $p.root), root_gone: ($a.root_gone // $p.root_gone)})) as $att0
# The shell a session runs in (a herdr or tmux pane's shell in the worktree) is the session
# too: an ancestor of the agent, or a terminal shell in a worktree where herdr has a pane.
| ([$att0[] | select(.kind == "session") | {task, pid}]) as $sp
| ($att0 | map(. as $p
    | if $p.kind == "dev" and $p.task != null and $p.tty != "" and ($p | wrapper | not)
        and (($p.args | words | .[0] // "" | base | ltrimstr("-")) | IN("sh", "bash", "zsh", "dash", "ksh", "fish"))
        and any($panes[]; .cwd as $c | $T[$p.task].wt as $w | $w != "" and ($c | under($w)))
      then .kind = "session"
    elif $p.kind == "dev" and $p.task != null and any($sp[]; .task == $p.task and (. as $s
        | reduce range(0; 32) as $_ ({at: ($by[$s.pid | tostring].ppid // 0), hit: false};
            if .hit or .at <= 1 then . elif .at == $p.pid then .hit = true else .at = (($by[.at | tostring].ppid) // 0) end) | .hit))
      then .kind = "session" else . end)) as $att

| def sum(f): map(f) | add // 0;
  def group_item($ps): ($ps | map(.pid)) as $ids
    | ($ps | map(select(.ppid as $pp | any($ids[]; . == $pp) | not))) as $roots
    | {pids: $ids, procs: ($ps | map({pid, args})), what: ((first($ps[] | select(agent)) // $roots[0]) | if agent then (.args | words | .[0] | base) else pname end),
       age_s: ($roots | map(.age) | max // 0), cpu_s: ($ps | sum(.cpu)), pcpu: ($ps | sum(.pcpu) * 10 | round / 10), rss_kb: ($ps | sum(.rss)),
       tty: ([$ps[] | select(.tty != "") | .tty] | unique | join(","))};
  # Roots of a set, each with its subtree inside the set.
  def trees($ps): ($ps | map(.pid)) as $ids
    | [$ps[] | select(.ppid as $pp | any($ids[]; . == $pp) | not)] as $roots
    | $roots[] | . as $r
    | [$r] + [$ps[] | . as $q | select($q.pid != $r.pid)
        | select(reduce range(0; 32) as $_ ({at: $q.ppid, hit: false};
            if .hit or .at <= 1 then . elif .at == $r.pid then .hit = true else .at = (($by[.at | tostring].ppid) // 0) end) | .hit)];
  def closing($t): $t.state == "done" and ($t.close.ok // false) and (($t.close.later // false) | not) and (IN($t.id; $failed[]) | not);
  def stale($t): $t.idle >= $idle;

# sessions: one item per task with a live agent tree (or a live herdr agent)
  ([$tasks[] | . as $t
    | [$att[] | select(.task == $t.id and .kind == "session")] as $ps
    | ($t.runner == "herdr" and $t.herdr != null) as $hl
    # herdr panes whose cwd is in the task's worktree: panes chartroom opened for this task
    # (left open by its close, or by an earlier start)
    | ([$panes[] | select($t.wt != "" and (.cwd | under($t.wt))) | .pane]) as $tp
    | select(($ps | length) > 0 or ((($hl) or ($tp | length) > 0) and ($t.state | finished)))
    | (if ($ps | length) > 0 then group_item($ps) else {pids: [], procs: [], what: (if $hl then "herdr agent" else "herdr pane" end), age_s: 0, cpu_s: 0, pcpu: 0, rss_kb: 0, tty: ""} end)
    + {class: "session", task: $t.id, state: $t.state, backend: $t.backend, project: $t.project,
       herdr_tab: (if $hl and $t.herdr.tab == $t.herdr_tab then $t.herdr_tab else null end),
       herdr_panes: (if $t.state == "closed" then $tp else [] end), worktree: $t.wt}
    | . + (if ($t.state | finished | not) then {action: "keep"}
           elif $t.joined then {action: "human", reason: "a joined session is the commander's own; ask before ending it"}
           elif $t.state == "closed" then
             (if (.pids | length) == 0 and .herdr_tab == null and (.herdr_panes | length) == 0 then
                {action: "human", reason: "herdr has an agent named \($t.id) in tab \($t.herdr.tab), not the tab recorded for this task (\($t.herdr_tab // "none"))"}
              else {action: "apply", reason: "its task is closed"} end)
           elif closing($t) then {action: "apply", reason: "its task closes in this sweep"}
           elif ($t.close.later // false) then {action: "keep"}
           elif stale($t) | not then {action: "keep"}
           elif $t.state == "review" then {action: "human", reason: "reported done \($t.idle | dur) ago, awaiting your review (chartroom accept or close)"}
           elif $t.state == "done" then {action: "human", reason: "done \($t.idle | dur) ago, not closeable: \($t.close.reason // "no close check")"}
           elif $t.state == "failed" then {action: "human", reason: "failed \($t.idle | dur) ago; its session is still open"}
           else {action: "human", reason: "stopped without reporting \($t.idle | dur) ago; its session is still open"} end)]) as $sessions

# closes: done tasks
| ([$tasks[] | select(.state == "done" and (.joined | not) and .close != null) | . as $t
    | {class: "close", task: $t.id, state: $t.state, backend: $t.backend, project: $t.project,
       what: ($t.title | if length > 60 then .[0:59] + "…" else . end), pids: [], procs: [], age_s: $t.idle, cpu_s: 0, pcpu: 0, rss_kb: 0}
    | if closing($t) then . + {action: "apply", reason: $t.close.reason}
      elif ($t.close.ok // false) then empty
      elif stale($t) then . + {action: "human", reason: "done \($t.idle | dur) ago, not closeable: \($t.close.reason)"}
      else empty end]) as $closes

# orphans: chartroom's own loops
| ([$loops[] | . as $p | $p.loop as $l
    | ([$p] + [$P[] | . as $q | select($q.pid != $p.pid)
        | select(reduce range(0; 32) as $_ ({at: $q.ppid, hit: false};
            if .hit or .at <= 1 then . elif .at == $p.pid then .hit = true else .at = (($by[.at | tostring].ppid) // 0) end) | .hit)]) as $ps
    | group_item($ps) + {class: "orphan", task: null, what: ("chartroom " + $l.kind + (if $l.kind == "listen" and $l.arg then " " + $l.arg else "" end))}
    | ($p | orphaned) as $o
    | (any($homes[]; . as $h | $p.cwd | under($h))) as $here
    | if $l.kind == "watch" then
        (if $o and $here then . + {action: "apply", reason: "its session is gone (parent \(if $p.ppid <= 1 then "pid 1" else "init" end)), running \($p.age | dur)"}
         elif $o and any($others.homes[]; . as $h | $p.cwd | under($h)) then . + {action: "keep"}
         elif $o then . + {action: "human", reason: "orphaned (its session is gone), but run from \($p.cwd // "an unknown directory"), not this home"}
         else empty end)
      elif $l.kind == "listen" then
        ($T[$l.arg // ""] // null) as $t
        | (if $t != null and $o then . + {task: $t.id, action: "apply", reason: "its session is gone (parent pid 1 or init)"}
           elif $t != null and $t.state == "closed" then . + {task: $t.id, action: "apply", reason: "its task is closed"}
           elif $t == null and IN($l.arg // ""; $others.ids[]) then . + {action: "keep"}
           elif $t == null and $o then . + {action: "human", reason: "orphaned listener for a task this home does not have"}
           else empty end)
      else
        (($l.arg // "") | sub("/[^/]*$"; "")) as $h
        | if any($homes[]; . == $h) | not then empty
          elif ($dash != "" and ($p.pid | tostring) != $dash) then . + {what: "chartroom dashboard", action: "apply", reason: "a second dashboard for this home (the tracked one is pid \($dash))"}
          elif $dash == "" then . + {what: "chartroom dashboard", action: "human", reason: "a dashboard for this home that .dashboard.pid does not track"}
          else empty end
      end]) as $orphans

# dev processes: everything else attributed to a task's worktree, one item per process tree
| ([$att[] | select(.kind == "dev")] | group_by([.task, .root]) | map(
     .[0] as $g | ($T[$g.task // ""] // null) as $t
     | trees(.) as $tree | group_item($tree)
     + {class: "daemon", task: $g.task, state: ($t.state // null), project: ($t.project // null), worktree: ($t.wt // $g.root)}
     | (any($homes[]; . as $h | $g.root | startswith($h + "/worktrees/"))) as $ours
     | . + (if $t == null and any($others.wts[]; . as $w | $g.root | under($w)) then {action: "keep"}
            elif $t == null then
              (if $g.root_gone and $ours then {action: "apply", reason: "its worktree \($g.root) no longer exists"}
               elif $g.root_gone then {action: "human", reason: "runs in \($g.root), which no longer exists and no task of this home records (another home's?)"}
               else {action: "human", reason: "runs in a chartroom worktree no task records (\($g.root))"} end)
            elif ($t.state | finished | not) then {action: "keep"}
            elif $t.state == "closed" then {action: "apply", reason: "in the worktree of a closed task"}
            elif closing($t) then {action: "apply", reason: "in the worktree of a task that closes in this sweep"}
            elif .age_s >= $idle and stale($t) then {action: "human", reason: "running \(.age_s | dur) in the worktree of a \($t.state) task idle \($t.idle | dur)"}
            else {action: "keep"} end)
     | if .action == "apply" and .tty != "" then .action = "human" | .reason = "attached to a terminal (\(.tty)), so someone may be using it; " + .reason else . end)) as $daemons

| ($sessions + $closes + $orphans + $daemons) as $all
| ($all | map(select(.action != "keep") | del(.tty))) as $items
| ([$items[] | select(.action == "apply")]) as $safe
| ([$safe[].pids[]] | unique) as $freed
| {items: $items,
   summary: {
     apply: {sessions: ([$safe[] | select(.class == "session")] | length), closes: ([$safe[] | select(.class == "close")] | length),
             orphans: ([$safe[] | select(.class == "orphan")] | length), daemons: ([$safe[] | select(.class == "daemon")] | length),
             processes: ($freed | length),
             rss_kb: ([$P[] | select(.pid as $x | any($freed[]; . == $x)) | .rss] | add // 0),
             pcpu: ([$P[] | select(.pid as $x | any($freed[]; . == $x)) | .pcpu] | add // 0 | . * 10 | round / 10),
             cpu_s: ([$P[] | select(.pid as $x | any($freed[]; . == $x)) | .cpu] | add // 0)},
     human: ([$items[] | select(.action == "human") | .task // "pid \(.pids[0])"] | unique | length),
     kept: ([$all[] | select(.action == "keep") | .pids[]] | unique | length)}}
