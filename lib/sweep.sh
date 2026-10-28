# shellcheck shell=bash
# sweep.sh - `chartroom sweep`: what the crew left running, and (with --apply) freeing the
# part of it that is safe to free. Nothing here is a daemon; the XO runs it now and then.
#
# It looks at this user's processes (ps, plus each one's working directory) against the
# home's task records, and sorts what it finds into four classes:
#   session  the agent chartroom started for a task (it, its launcher or wrapper passes the
#            agent the task's directory; or it is the agent in the task's worktree), the pane
#            shell it runs in, and everything under it
#   close    a done task (accepted by the commander; one still in review never closes here):
#            closeable when its worktree is clean and nothing on it is unlanded
#   orphan   a chartroom loop left behind: `watch`/`listen` whose session is gone (its nearest
#            real parent is init), a listener of a closed task, a second dashboard for the home
#   daemon   anything else running from a task's worktree (dev servers, watchers, daemons:
#            found by working directory and argv, whatever the program), or from a chartroom
#            worktree path that no longer exists
# Each item's action is `apply` (the safe set --apply acts on), `human` (the reason says why
# not) or `keep` (in-flight work, or too fresh to judge; counted, never listed). The rules
# are in lib/sweep.jq. --apply closes through `chartroom close` (which refuses a dirty
# worktree), stops sessions of closed tasks, kills the rest of the safe set (TERM, then KILL
# after 5s), and logs every act to $CHARTROOM_HOME/sweep.log and the task's events.log.

CR_SWEEP_FINISHED='review|done|failed|stopped-silent|closed'

sweep_log() { printf '%s %s\n' "$(now)" "${*//$'\n'/ }" >>"$CR_HOME/sweep.log"; }

# A directory as given and physically (symlinks resolved), one per line, unique.
sweep_forms() { # <path>
  local p="${1%/}" q
  [[ -n "$p" ]] || return 0
  printf '%s\n' "$p"
  q="$(cd "$p" 2>/dev/null && pwd -P)" && [[ -n "$q" && "$q" != "$p" ]] && printf '%s\n' "$q"
  return 0
}

# This user's live processes, one TSV line each: pid ppid age_s cpu_s pcpu rss_kb tty args
# (tty "-" when it has none: bash's read would merge empty tab-separated fields).
# Only POSIX ps columns (macOS and procps agree on them); etime and time are
# [[dd-]hh:]mm:ss, and macOS writes time as mm:ss.cc. Zombies are left out.
sweep_ps() {
  ps -ww -A -o pid=,ppid=,uid=,etime=,time=,pcpu=,rss=,tty=,stat=,args= 2>/dev/null | awk -v me="$(id -u)" '
    function secs(t,   d, n, a) {
      d = 0
      if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
      n = split(t, a, ":")
      if (n == 3) return int(d * 86400 + a[1] * 3600 + a[2] * 60 + a[3])
      if (n == 2) return int(d * 86400 + a[1] * 60 + a[2])
      return int(d * 86400 + a[1])
    }
    $3 == me && $9 !~ /^Z/ {
      s = $0
      for (i = 1; i <= 9; i++) sub(/^[ \t]*[^ \t]+/, "", s)
      sub(/^[ \t]+/, "", s); gsub(/\t/, " ", s)
      tty = ($8 ~ /^(\?+|-)$/) ? "-" : $8
      printf "%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", $1, $2, secs($4), secs($5), $6, $7, tty, s
    }'
}

# Working directories: "pid<TAB>cwd" for this user's processes. /proc where there is one
# (Linux, WSL; a deleted directory reads "<path> (deleted)"), else one lsof call (macOS
# keeps the old path of a deleted directory). Prints nothing when neither works.
sweep_cwds() {
  local l
  if [[ -e /proc/self/cwd ]]; then
    # shellcheck disable=SC2012 # ls -l is the one portable way to read many links in one call
    ls -l /proc/[0-9]*/cwd 2>/dev/null | sed -nE 's#^.* /proc/([0-9]+)/cwd -> (.*)$#\1\t\2#p'
    return 0
  fi
  l="$(bin_of lsof)"; [[ -z "$l" && -x /usr/sbin/lsof ]] && l=/usr/sbin/lsof
  [[ -n "$l" ]] || return 0
  "$l" -a -d cwd -u "$(id -u)" -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }'
  return 0
}

# Directories under which a process with no task of its own is still chartroom's: the home's
# worktrees/<repo>/<name> and each task project's .worktrees/(chartroom|cap)_<name>.
# Prints "<prefix><TAB><layout>" (layout: home | project).
sweep_root_prefixes() {
  local f p
  while IFS= read -r f; do printf '%s/worktrees/\thome\n' "$f"; done < <(sweep_forms "$CR_HOME")
  shopt -s nullglob
  local metas=("$CR_HOME"/tasks/*/meta.json)
  [[ ${#metas[@]} -gt 0 ]] || return 0
  while IFS= read -r p; do
    while IFS= read -r f; do printf '%s/.worktrees/\tproject\n' "$f"; done < <(sweep_forms "$p")
  done < <(jq -r 'select((.joined // "") != "1") | .project // empty' "${metas[@]}" | sort -u)
}

# The process snapshot, one record per process with fields separated by \x1f (a tab would
# merge empty fields in read): pid ppid age cpu pcpu rss tty cwd root root_gone args. root is
# the chartroom worktree directory the cwd lies in (empty when it is in none), root_gone
# whether that directory no longer exists. sweep_procs_to_json makes it JSON.
sweep_procs_json() {
  local tmp pid ppid age cpu pcpu rss tty args cwd pre lay rest root gone
  local -A cwd_of=()
  local prefixes=() layouts=()
  tmp="$(mktemp)"
  sweep_ps >"$tmp"
  while IFS=$'\t' read -r pid cwd; do [[ -n "$pid" ]] && cwd_of[$pid]="$cwd"; done < <(sweep_cwds)
  while IFS=$'\t' read -r pre lay; do prefixes+=("$pre"); layouts+=("$lay"); done < <(sweep_root_prefixes)
  local i n
  while IFS=$'\t' read -r pid ppid age cpu pcpu rss tty args; do
    cwd="${cwd_of[$pid]:-}"; root=""; gone=0
    if [[ "$cwd" == *" (deleted)" ]]; then cwd="${cwd% (deleted)}"; gone=1; fi
    for ((i = 0; i < ${#prefixes[@]}; i++)); do
      pre="${prefixes[$i]}"
      [[ "$cwd" == "$pre"* ]] || continue
      rest="${cwd#"$pre"}"
      if [[ "${layouts[$i]}" == home ]]; then
        n="${rest%%/*}"; rest="${rest#"$n"}"; rest="${rest#/}"
        [[ -n "$n" && -n "${rest%%/*}" ]] && root="$pre$n/${rest%%/*}"
      else
        n="${rest%%/*}"
        [[ "$n" == chartroom_?* || "$n" == cap_?* ]] && root="$pre$n"
      fi
      [[ -n "$root" ]] && break
    done
    [[ -n "$root" && $gone -eq 0 && ! -d "$root" ]] && gone=1
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$pid" "$ppid" "$age" "$cpu" "$pcpu" "$rss" "${tty#-}" "$cwd" "$root" "$gone" "$args"
  done <"$tmp"
  rm -f "$tmp"
}

sweep_procs_to_json() {
  jq -R -s -c '[split("\n")[] | select(length > 0) | split("\u001f")
    | {pid: (.[0] | tonumber), ppid: (.[1] | tonumber), age: (.[2] | tonumber), cpu: (.[3] | tonumber),
       pcpu: (.[4] | tonumber? // 0), rss: (.[5] | tonumber? // 0), tty: .[6], cwd: .[7], root: .[8],
       root_gone: (.[9] == "1"), args: (.[10:] | join(" "))}]'
}

# Is everything on this done task landed and its worktree clean, so closing it loses nothing?
# Prints {ok, reason, later}: later = it would close but finished less than
# CHARTROOM_SWEEP_SETTLE_MINUTES ago, so the XO sees its report before it leaves `status`.
# Never fetches: "landed" is judged against the local copy of the task's base ref.
sweep_check_out() { jq -cn --argjson ok "$1" --arg r "$2" --argjson later "${3:-false}" '{ok: $ok, reason: $r, later: $later}'; }
sweep_close_check() { # <id> <live>
  local id="$1" live="$2" wt project branch base kind tips=() t n dirty done_at age
  wt="$(meta "$id" worktree)"; project="$(meta "$id" project)"; branch="$(meta "$id" branch)"
  base="$(meta "$id" base)"; kind="$(meta "$id" kind)"
  [[ -n "$project" && -d "$project" ]] || { sweep_check_out false "its project ${project:-(none)} is not on this machine"; return; }
  if [[ "$live" =~ ^(working|running|blocked|in-session)$ ]]; then sweep_check_out false "it reported done, but its agent is still $live"; return; fi
  if [[ -n "$wt" && -d "$wt" ]]; then
    if ! dirty="$(git -C "$wt" status --porcelain 2>/dev/null)"; then sweep_check_out false "its worktree $wt is not a readable git worktree"; return; fi
    if [[ -n "$dirty" ]]; then sweep_check_out false "uncommitted changes in its worktree ($(grep -c . <<<"$dirty") path(s))"; return; fi
    t="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)"; [[ -n "$t" ]] && tips+=("$t")
  fi
  if [[ "$kind" == ship && -n "$branch" ]]; then
    t="$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || true)"; [[ -n "$t" ]] && tips+=("$t")
  fi
  if [[ ${#tips[@]} -gt 0 ]]; then
    if [[ -z "$base" ]] || ! git -C "$project" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
      sweep_check_out false "its base ${base:-(none)} is not a ref in $project, so sweep cannot tell whether it landed"; return
    fi
    n="$(git -C "$project" rev-list --count "${tips[@]}" --not "$base" 2>/dev/null || echo "?")"
    if [[ "$n" != 0 ]]; then sweep_check_out false "$n commit(s) not in $base (unpushed or unmerged)"; return; fi
  fi
  done_at="$(awk '$2 == "done:" { t = $1 } END { print t }' "$(tdir "$id")/events.log")"
  age="$(jq -n --arg t "$done_at" '($t | fromdateiso8601? // 0) as $d | if $d == 0 then 0 else (now - $d | floor) end')"
  local settle; settle="$(cfg SWEEP_SETTLE_MINUTES '' 60)"
  if (( age < settle * 60 )); then sweep_check_out true "reported done $((age / 60))m ago; sweep waits ${settle}m so its report is seen first" true; return; fi
  sweep_check_out true "worktree clean, nothing outside ${base:-its base}"
}

# Every task, with what the rules need: state and liveness (status_rows), the task's
# directories, its worktree when sweep may attribute processes to it (never a joined
# session's own directory), how long it has been idle, herdr's view of its agent, and for a
# done task the close check.
sweep_tasks_json() {
  shopt -s nullglob
  local metas=("$CR_HOME"/tasks/*/meta.json)
  [[ ${#metas[@]} -gt 0 ]] || { echo '[]'; return 0; }
  local rows base homes ids id st live runner extra='{}' herdr='null'
  rows="$(status_rows --all | jq -s -c 'map({key: .id, value: {state, live, last_at}}) | from_entries')"
  homes="$(sweep_forms "$CR_HOME" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  base="$(jq -n -c --argjson rows "$rows" --argjson homes "$homes" '
    def canon: {"codex": "headless:codex", "herdr-claude": "herdr:claude", "herdr-codex": "herdr:codex"}[.] // .;
    [inputs | . as $m | ($rows[$m.id] // {}) as $r
     | (($m.backend // "") | canon) as $b
     | (($m.worktree // "") | rtrimstr("/")) as $w
     | {id: $m.id, title: ($m.title // ""), state: ($r.state // "unknown"), live: ($r.live // "-"),
        backend: (if $b == "" then "auto" else $b end), runner: ($b | split(":")[0]),
        project: (($m.project // "") | rtrimstr("/") | split("/") | last), kind: ($m.kind // ""),
        joined: (($m.joined // "") == "1"), pid: (($m.pid // "") | tonumber? // null),
        herdr_tab: ($m.herdr_tab // null),
        dirs: [$homes[] | . + "/tasks/" + $m.id],
        # Sweep attributes processes to a worktree chartroom made for this task (its name ends in
        # the id), never to a joined session own directory or the project checkout itself.
        wt: (if ($m.joined // "") == "1" or $w == "" or $w == (($m.project // "") | rtrimstr("/")) or ($w | split("/") | last | endswith($m.id) | not)
             then "" else $w end),
        idle: ((($r.last_at // $m.updated // $m.created // "") | fromdateiso8601? // null) as $t | if $t then (now - $t | floor) else 0 end)}]' "${metas[@]}")"
  # herdr: one `agent list` when it answers, else `agent get` per finished herdr task.
  if [[ -n "$(bin_of herdr)" ]]; then
    herdr="$(herdr agent list 2>/dev/null | jq -c '[.result.agents[]? | select(.name != null) | {key: .name, value: {tab: .tab_id, status: .agent_status}}] | from_entries' 2>/dev/null || true)"
    [[ -n "$herdr" ]] || herdr='null'
  fi
  local herdr_get='{}' close='{}' r
  while IFS=$'\t' read -r id st live runner; do
    if [[ "$runner" == herdr && "$herdr" == null && -n "$(bin_of herdr)" ]]; then
      r="$(herdr agent get "$id" 2>/dev/null | jq -c '.result.agent | {tab: .tab_id, status: .agent_status}' 2>/dev/null || true)"
      [[ -n "$r" ]] && herdr_get="$(jq -c --arg id "$id" --argjson r "$r" '.[$id] = $r' <<<"$herdr_get")"
    fi
    if [[ "$st" == "done" ]]; then
      close="$(jq -c --arg id "$id" --argjson r "$(sweep_close_check "$id" "$live")" '.[$id] = $r' <<<"$close")"
    fi
  done < <(jq -r --arg fin "^($CR_SWEEP_FINISHED)$" '.[] | select((.state | test($fin)) and (.joined | not)) | [.id, .state, .live, .runner] | @tsv' <<<"$base")
  [[ "$herdr" == null ]] && herdr="$herdr_get"
  jq -c --argjson herdr "$herdr" --argjson close "$close" \
    'map(. + {herdr: (if .runner == "herdr" then ($herdr[.id] // null) else null end), close: ($close[.id] // null)})' <<<"$base"
}

# Every other registered home (lib/homes.sh): its directories (as given and physically), its
# task ids and the worktrees they record, as {homes, ids, wts}. Their work is theirs to sweep:
# this home's sweep neither acts on it nor asks about it.
sweep_others_json() {
  local here name p metas out='{"homes":[],"ids":[],"wts":[]}' tasks
  here="$(phys_dir "$CR_HOME")"
  shopt -s nullglob
  while IFS=$'\t' read -r name p; do
    [[ -d "$p" && "$(phys_dir "$p")" != "$here" ]] || continue
    metas=("$p"/tasks/*/meta.json); tasks='[]'
    [[ ${#metas[@]} -gt 0 ]] && tasks="$(jq -s -c 'map({id, wt: ((.worktree // "") | rtrimstr("/"))})' "${metas[@]}")"
    out="$(jq -c --argjson forms "$(sweep_forms "$p" | jq -R -s -c 'split("\n") | map(select(length > 0))')" --argjson t "$tasks" \
      '.homes += $forms | .ids += [$t[].id] | .wts += [$t[].wt | select(. != "")]' <<<"$out")"
  done < <(homes_entries)
  printf '%s\n' "$out"
}

# herdr's panes as [{pane, tab, cwd, agent}] (one call; [] without herdr or on an older one).
sweep_herdr_panes() {
  local r=""
  [[ -n "$(bin_of herdr)" ]] && r="$(herdr pane list 2>/dev/null | jq -c '[.result.panes[]? | {pane: .pane_id, tab: .tab_id, cwd: ((.foreground_cwd // .cwd // "") | rtrimstr("/")), agent: (.agent // null)}]' 2>/dev/null || true)"
  printf '%s\n' "${r:-[]}"
}

# One plan: the snapshot classified (lib/sweep.jq). <close-failed> is a JSON array of task
# ids whose close failed in this run, so nothing of theirs counts as safe.
sweep_plan() { # [close-failed-json]
  local procs tasks dash="" p _
  procs="$(sweep_procs_json | sweep_procs_to_json)"
  tasks="$(sweep_tasks_json)"
  read -r dash _ < <(dashboard_running) || true
  jq -n -c --argjson procs "$procs" --argjson tasks "$tasks" --argjson panes "$(sweep_herdr_panes)" \
    --argjson homes "$(sweep_forms "$CR_HOME" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson self "$$" --argjson idle "$((CR_SWEEP_IDLE_HOURS * 3600))" \
    --argjson failed "${1:-[]}" --arg dash "$dash" --argjson others "$(sweep_others_json)" \
    -f "$CR_ROOT/lib/sweep.jq"
}

# Kill pids (TERM, then KILL whatever is still there after 5s), but only those whose argv is
# still what the plan saw: a pid reused since the snapshot is left alone. Prints
# "<pid><TAB><result>" per pid.
sweep_kill() { # <pid<TAB>args>... on stdin
  local pid args now_args i left=() p
  local -A want=() res=()
  while IFS=$'\t' read -r pid args; do [[ -n "$pid" ]] && want[$pid]="$args"; done
  [[ ${#want[@]} -gt 0 ]] || return 0
  for pid in "${!want[@]}"; do
    now_args="$(ps -ww -o args= -p "$pid" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
    if [[ -z "$now_args" ]]; then res[$pid]="already gone"
    elif [[ "$now_args" != "$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"${want[$pid]}")" ]]; then res[$pid]="skipped: pid now runs something else"
    elif kill -TERM "$pid" 2>/dev/null; then left+=("$pid")
    else res[$pid]="failed: kill refused"; fi
  done
  for i in $(seq 1 50); do
    p=(); for pid in "${left[@]+"${left[@]}"}"; do pid_alive "$pid" && p+=("$pid"); done
    left=("${p[@]+"${p[@]}"}"); [[ ${#left[@]} -eq 0 ]] && break
    sleep 0.1
  done
  for pid in "${left[@]+"${left[@]}"}"; do kill -KILL "$pid" 2>/dev/null || true; done
  [[ ${#left[@]} -gt 0 ]] && sleep 0.5
  for pid in "${!want[@]}"; do
    [[ -n "${res[$pid]:-}" ]] && { printf '%s\t%s\n' "$pid" "${res[$pid]}"; continue; }
    if [[ " ${left[*]-} " == *" $pid "* ]]; then
      if pid_alive "$pid"; then printf '%s\tfailed: still running after KILL\n' "$pid"; else printf '%s\tkilled (KILL after 5s)\n' "$pid"; fi
    else printf '%s\tkilled\n' "$pid"; fi
  done
}

# --apply: closes first (through `chartroom close`, which refuses a dirty worktree), then
# herdr tabs of closed tasks, then a fresh plan (the closes changed what is safe) whose
# process kills run at once. Prints the final plan with a `result` on every item acted on.
sweep_apply() { # <plan-json>
  local plan="$1" id out rc failed='[]' results='{}' tab st r
  # 1. close done tasks that are clean and landed (re-checked now, not trusted from the plan)
  while IFS= read -r id; do
    r="$(sweep_close_check "$id" "$(status_rows --id "$id" | jq -r .live)")"
    if [[ "$(jq -r '.ok and (.later | not)' <<<"$r")" != true ]]; then
      failed="$(jq -c --arg id "$id" '. + [$id]' <<<"$failed")"
      results="$(jq -c --arg k "close:$id" --arg v "skipped: $(jq -r .reason <<<"$r")" '.[$k] = $v' <<<"$results")"; continue
    fi
    rc=0; out="$(CHARTROOM_HOME="$CR_HOME" "$CR_BIN" close "$id" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then
      log_event "$id" note "sweep: closed (done, $(jq -r .reason <<<"$r"))"
      sweep_log "closed: $id ($(jq -r .reason <<<"$r"))"
      results="$(jq -c --arg k "close:$id" '.[$k] = "closed"' <<<"$results")"
    else
      failed="$(jq -c --arg id "$id" '. + [$id]' <<<"$failed")"
      sweep_log "close failed: $id (exit $rc): $out"
      results="$(jq -c --arg k "close:$id" --arg v "failed: $(tr '\n' ' ' <<<"$out" | cut -c1-200)" '.[$k] = $v' <<<"$results")"
    fi
  done < <(jq -r '.items[] | select(.class == "close" and .action == "apply") | .task' <<<"$plan")
  # 2. herdr sessions of closed tasks: close the tab, but only the one herdr says the task's
  #    agent runs in (the plan carries it only when that matches the recorded tab)
  while IFS=$'\t' read -r id tab; do
    st="$(herdr agent get "$id" 2>/dev/null | jq -r '.result.agent.tab_id // empty' 2>/dev/null || true)"
    [[ -n "$tab" && "$st" == "$tab" ]] || continue
    if herdr tab close "$tab" >/dev/null 2>&1; then
      log_event "$id" note "sweep: closed its herdr tab $tab (task closed)"; sweep_log "stopped: $id herdr tab $tab"
      results="$(jq -c --arg k "tab:$id" '.[$k] = "herdr tab closed"' <<<"$results")"
    fi
  done < <(jq -r '.items[] | select(.class == "session" and .action == "apply" and .herdr_tab != null) | [.task, .herdr_tab] | @tsv' <<<"$plan")
  #    and leftover herdr panes in a closed task's worktree (re-read: still there, same cwd)
  local pane wt cwd
  while IFS=$'\t' read -r id pane wt; do
    cwd="$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane | (.foreground_cwd // .cwd // "")' 2>/dev/null || true)"
    [[ -n "$wt" && ( "$cwd" == "$wt" || "$cwd" == "$wt"/* ) ]] || continue
    if herdr pane close "$pane" >/dev/null 2>&1; then
      log_event "$id" note "sweep: closed a leftover herdr pane $pane in its worktree (task closed)"; sweep_log "stopped: $id herdr pane $pane"
      results="$(jq -c --arg k "tab:$id" '.[$k] = "herdr pane closed"' <<<"$results")"
    fi
  done < <(jq -r '.items[] | select(.class == "session" and .action == "apply") | .task as $t | .worktree as $w | .herdr_panes[]? | [$t, ., $w] | @tsv' <<<"$plan")
  # 3. a fresh plan (the closes changed what is safe); kill its safe process set at once
  local final kills what reason res pids
  final="$(sweep_plan "$failed")"
  kills="$(jq -r '[.items[] | select(.action == "apply" and .class != "close") | .procs[]] | unique_by(.pid) | .[] | [.pid, .args] | @tsv' <<<"$final" | sweep_kill)"
  # Every result goes on its item. Closes come from the first plan, and so does a session that
  # its task's close or herdr tab close already ended (it is gone from the fresh plan).
  final="$(jq -c --argjson plan "$plan" --argjson results "$results" --arg kills "$kills" '
    ($kills | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $k
    | def ok: startswith("killed") or . == "already gone";
    ([.items[] | select(.class == "session") | .task]) as $live
    | .applied = true
    | .items = ([$plan.items[] | select(.class == "close")]
        + [$plan.items[] | select(.class == "session" and .action == "apply") | . as $s | select(any($live[]; . == $s.task) | not)
             | if ($results["tab:" + .task] // null) then .result = "stopped (herdr tab closed)"
               elif ($results["close:" + .task] // "") == "closed" then .result = "stopped (its task was closed)"
               else empty end]
        + [.items[] | select(.class != "close")])
    | .items |= map(
        if .result then .
        elif .class == "close" and .action == "apply" then .result = ($results["close:" + .task] // "not run")
        elif .action == "apply" then
          ([.procs[] | $k[.pid | tostring] // "not run"]) as $r
          | .result = (if all($r[]; ok) then
                (if .class == "session" then (if ($results["tab:" + (.task // "")] // null) then "stopped (herdr tab closed)" else "stopped" end) else "killed" end)
              else ($r | map(select(ok | not)) | unique | join("; ")) end)
        else . end)
    | ([.items[] | select(.action == "apply" and (.result | test("^(closed|stopped|killed)")))]) as $done
    | .summary.apply = {sessions: ([$done[] | select(.class == "session")] | length), closes: ([$done[] | select(.class == "close")] | length),
        orphans: ([$done[] | select(.class == "orphan")] | length), daemons: ([$done[] | select(.class == "daemon")] | length),
        processes: ([$done[].pids[]] | unique | length), rss_kb: ([$done[].rss_kb] | add // 0),
        pcpu: ([$done[].pcpu] | add // 0 | . * 10 | round / 10), cpu_s: ([$done[].cpu_s] | add // 0)}
    | .summary.human = ([.items[] | select(.action == "human" or ((.result // "") | test("^(failed|skipped|not run)"))) | .task // "pid \(.pids[0])"] | unique | length)' <<<"$final")"
  while IFS=$'\t' read -r id what reason res pids; do
    sweep_log "$res: ${id:+$id }$what (pid $pids): $reason"
    [[ -n "$id" && "$res" =~ ^(stopped|killed) ]] && log_event "$id" note "sweep: $res $what (pid $pids): $reason"
  done < <(jq -r '.items[] | select(.action == "apply" and .class != "close") | [.task // "", .what, .reason, .result, (.pids | map(tostring) | join(","))] | @tsv' <<<"$final")
  printf '%s\n' "$final"
}

cmd_sweep() {
  local json=0 apply=0 verbose=0
  CR_SWEEP_IDLE_HOURS="$(cfg SWEEP_IDLE_HOURS '' 24)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --apply) apply=1; shift ;;
      --verbose|-v) verbose=1; shift ;;
      --idle-hours) [[ $# -ge 2 ]] || die "--idle-hours needs a number"; CR_SWEEP_IDLE_HOURS="$2"; shift 2 ;;
      *) die "sweep: unknown arg $1 (usage: chartroom sweep [--apply] [--verbose|--json] [--idle-hours N])" ;;
    esac
  done
  [[ "$CR_SWEEP_IDLE_HOURS" =~ ^[0-9]+$ ]] || die "--idle-hours (CHARTROOM_SWEEP_IDLE_HOURS) must be a whole number of hours"
  [[ "$(cfg SWEEP_SETTLE_MINUTES '' 60)" =~ ^[0-9]+$ ]] || die "CHARTROOM_SWEEP_SETTLE_MINUTES must be a whole number of minutes"
  [[ "$CR_PLATFORM" != msys ]] || die "chartroom sweep is unavailable on Git Bash (its ps cannot list working directories or argv); run it in WSL2"
  [[ -d "$CR_HOME/tasks" ]] || die "no chartroom home at $CR_HOME ($CR_HOME_SOURCE); pass the right one as CHARTROOM_HOME=<path>"
  local plan
  plan="$(sweep_plan)"
  if [[ $apply -eq 1 ]]; then
    plan="$(sweep_apply "$plan")"
    sweep_log "sweep: $(jq -r '.summary | "freed \(.apply.processes) process(es), \(.apply.rss_kb) kB RSS; closed \(.apply.closes) task(s); needs a human: \(.human)"' <<<"$plan")"
  fi
  plan="$(jq -c --argjson load "$(sweep_load_json)" --arg home "$CR_HOME" --argjson idle "$CR_SWEEP_IDLE_HOURS" \
    '{home: $home, applied: (.applied // false), at: (now | todate), idle_hours: $idle, load: $load} + .' <<<"$plan")"
  if [[ $json -eq 1 ]]; then jq . <<<"$plan"; else sweep_print "$plan" "$verbose"; fi
}

# Machine load: the 1/5/15-minute averages and the CPU count.
sweep_load_json() {
  local l="" c
  if [[ -r /proc/loadavg ]]; then l="$(cut -d' ' -f1-3 /proc/loadavg)"
  else l="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' || true)"; fi
  [[ -n "${l// /}" ]] || l="$(uptime 2>/dev/null | sed -nE 's/.*load averages?: *//p' | tr -d ',' || true)"
  c="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  jq -n -c --arg l "$l" --arg c "$c" '{avg: ($l | split(" ") | map(select(length > 0) | tonumber?) | if length == 3 then . else null end), cpus: ($c | tonumber? // null)}'
}

# The report, for a person (or an agent that should spend few tokens on it). By default:
# one summary line, then the items that need a human, one short line each (at most 10).
# --verbose first lists the safe set by class with each item's processes, age, CPU and RSS.
# shellcheck disable=SC2016 # jq, not shell
CR_SWEEP_FMT='
  def dur: (. // 0 | floor) as $s
    | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m"
      elif $s < 86400 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
      else "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h" end;
  def mem: (. // 0) as $k | if $k < 1024 then "\($k)K" elif $k < 1048576 then "\($k / 1024 | floor)M" else "\($k / 1048576 * 10 | round / 10)G" end;
  def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
  def failed: (.result // "") | test("^(failed|skipped|not run)");'
sweep_print() { # <plan-json> <verbose: 0|1>
  local plan="$1" verbose="${2:-0}" cls title head
  if [[ "$verbose" == 1 ]]; then
    for cls in close session orphan daemon; do
      case "$cls" in
        close) title="Done tasks to close (clean, nothing unlanded)"; head="ACTION TASK PROJECT IDLE WHY" ;;
        session) title="Sessions of finished tasks"; head="ACTION TASK STATE BACKEND PROCS UP CPU %CPU RSS WHY" ;;
        orphan) title="Orphaned chartroom processes"; head="ACTION PID WHAT PROCS UP CPU %CPU RSS WHY" ;;
        daemon) title="Dev processes in finished or missing worktrees"; head="ACTION PID TASK WHAT PROCS UP CPU %CPU RSS WHY" ;;
      esac
      [[ "$(jq --arg c "$cls" '[.items[] | select(.class == $c and .action == "apply")] | length' <<<"$plan")" -gt 0 ]] || continue
      printf '%s\n' "$title"
      jq -r --arg c "$cls" --arg head "$head" "$CR_SWEEP_FMT"'
        ($head | split(" ") | @tsv),
        (.applied as $applied | .items[] | select(.class == $c and .action == "apply")
         | (if $applied then (.result // "not run") else {"close": "close", "session": "stop", "orphan": "kill", "daemon": "kill"}[.class] end) as $a
         | if $c == "close" then [$a, .task, .project, (.age_s | dur), .reason]
           elif $c == "session" then [$a, .task, .state, .backend, (.pids | length), (.age_s | dur), (.cpu_s | dur), .pcpu, (.rss_kb | mem), .reason]
           elif $c == "orphan" then [$a, .pids[0], .what, (.pids | length), (.age_s | dur), (.cpu_s | dur), .pcpu, (.rss_kb | mem), .reason]
           else [$a, .pids[0], (.task // "-"), .what, (.pids | length), (.age_s | dur), (.cpu_s | dur), .pcpu, (.rss_kb | mem), .reason] end
         | map(tostring) | @tsv)' <<<"$plan" | table | sed 's/^/  /'
      echo
    done
  fi
  jq -r --argjson verbose "$verbose" "$CR_SWEEP_FMT"'
    .summary as $s | $s.apply as $a
    | ([.items[] | select(.action == "human" or failed) | .why = (if failed then .result else .reason end)]
       | group_by(.task // "pid \(.pids[0] // "?")")) as $h
    # 1. the summary line
    | "sweep (\(if .applied then "applied" else "dry run" end)): "
      + (if .applied then "freed " else "safe to free " end)
      + ([(if $a.closes > 0 then "\($a.closes) done task(s) \(if .applied then "closed" else "to close" end)" else empty end),
          (if $a.sessions > 0 then "\($a.sessions) session(s)" else empty end),
          (if $a.orphans > 0 then "\($a.orphans) orphaned loop(s)" else empty end),
          (if $a.daemons > 0 then "\($a.daemons) dev process tree(s)" else empty end)] | if length > 0 then join(", ") else "nothing" end)
      + (if $a.processes > 0 then " = \($a.processes) proc(s), \($a.rss_kb | mem) RSS, \($a.pcpu)% CPU" else "" end)
      + "; needs a human: \($h | length); left alone: \($s.kept) proc(s) of live work"
      + "; load \(if .load.avg then (.load.avg | map(tostring) | join(" ")) else "?" end)\(if .load.cpus then " on \(.load.cpus) CPUs" else "" end)",
    # 2. what needs a human, one short line each
    ($h | if length > 0 then
        ((if $verbose == 1 then .[] else .[0:10][] end)
         | (first(.[] | select(.class == "close")) // .[0]) as $head
         | ([.[] | .pids[]] | unique | length) as $n
         | ([.[] | .rss_kb] | add // 0) as $rss
         | "  [\($head.task // "pid \($head.pids[0] // "?")")] "
           + ((map(.why) | unique | join("; ")) + (if $n > 0 then " (holds \($n) proc(s), \($rss | mem))" else "" end)
              | if $verbose == 1 then . else cut(150) end)),
        (if $verbose != 1 and length > 10 then "  … \(length - 10) more: chartroom sweep --verbose" else empty end)
      else empty end)' <<<"$plan"
}
