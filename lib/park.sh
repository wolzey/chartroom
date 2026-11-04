# shellcheck shell=bash
# park.sh - parking idle session workers, and reviving them on demand.
#
# An idle worker still holds its agent and that agent's MCP servers: about a gigabyte and four
# processes for a Claude Code worker, doing nothing. Parking ends them and keeps the agent's
# session id; steer and attach resume the session in a fresh terminal (`claude --resume <id>`),
# with the message as its first prompt, in a second or two.
#
#   at rest   the terminal is live and its agent reported its turn over (hc status idle or
#             done), and nothing was prompted since. The watch parks a worker at rest for
#             CHARTROOM_PARK_AFTER_MINUTES (default 60: no shorter than the prompt cache lasts in
#             the Claude Code sessions it was built on, an hour, so a revive pays no more than a
#             live worker steered as late would);
#             accept and `chartroom park` park one at once; sweep --apply parks those due.
#   never     a turn under way, an agent blocked at a dialog, a joined session, a tool command
#             still running under the agent (a dev server, a monitor, a background wait: it
#             would die with it), no recorded session id or no transcript for it, or a runner
#             or agent that cannot resume (hc:claude only, for now).
#   parked    meta `parked` holds the time; liveness reads `parked`; the watch never probes it.
#             The log carries `note: parked (session <id>; ...)`, written before the terminal
#             ends, so the launcher's `exited` after it is not news (reported_awk), and
#             `note: revived (...)` when a revive took, which every reader of the log treats as
#             the start of a new run (exited_since_dispatch). A revive that fails logs
#             `note: revive failed: ...`, which wakes the XO; the task stays parked.
#
# Runners provide <r>_park <id> <session id> <why> and <r>_revive <id> [text] (0 confirmed, 2
# taken but unchecked, 1 failed); the rest here is runner-neutral. A per-task lock (park, revive,
# steer, attach) keeps a park from ending a worker while a message is typed into it.

CR_PARK_RUNNERS='hc'

# Can this task's worker be parked and resumed at all?
park_supported() { # <id>
  [[ "$(backend_runner "$1")" =~ ^($CR_PARK_RUNNERS)$ && "$(backend_agent "$1")" == claude ]] && ! is_joined "$1"
}
is_parked() { [[ -n "$(meta "$1" parked)" ]]; }

# ---------------------------------------------------------------- Claude Code's own records
# Where Claude Code keeps a session: <config>/projects/<cwd, every non-alphanumeric as ->/<id>.jsonl
# (claude --resume reads it there; claude 2.1.318 also finds one under another directory).
claude_config_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
claude_transcript() { # <session id> <cwd> -> its transcript's path, or nothing
  local d f p
  d="$(claude_config_dir)/projects"; [[ -d "$d" ]] || return 0
  for p in "$2" "$(cd -P -- "$2" 2>/dev/null && pwd)"; do
    [[ -n "$p" ]] || continue
    f="$d/${p//[^A-Za-z0-9]/-}/$1.jsonl"
    [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  f="$(find "$d" -mindepth 2 -maxdepth 2 -name "$1.jsonl" 2>/dev/null | head -1)"
  [[ -n "$f" && -s "$f" ]] && printf '%s' "$f"
  return 0
}
# A worker started before chartroom recorded session ids: Claude Code's own record of the agent
# process (<config>/sessions/<pid>.json, undocumented), trusted only when that session's
# transcript is this task's: it holds the brief's line ("... Your task id is <id>.").
claude_legacy_session() { # <id> <agent pid> <cwd> -> the session id, or nothing
  local f sid t
  f="$(claude_config_dir)/sessions/$2.json"; [[ -f "$f" ]] || return 0
  sid="$(jq -r '.sessionId // empty' "$f" 2>/dev/null || true)"
  [[ "$sid" =~ ^[0-9a-fA-F-]{36}$ ]] || return 0
  t="$(claude_transcript "$sid" "$3")"
  [[ -n "$t" ]] && grep -qF "Your task id is $1." "$t" && printf '%s' "$sid"
  return 0
}

# ---------------------------------------------------------------- the agent's processes
# This user's processes as "pid ppid args" lines. CHARTROOM_PS_FILE stands in a process table
# (the tests), as CHARTROOM_PROC does for kill_tree.
park_ps() {
  if [[ -n "${CHARTROOM_PS_FILE:-}" ]]; then cat "$CHARTROOM_PS_FILE"; else ps -ww -A -o pid=,ppid=,args= 2>/dev/null; fi
}
# Under the terminal's program <root> (the launcher), the agent (a child named <agent>), and what
# runs under it: "agent <pid>", then "busy <pid> <args>" for each process that a tool started.
# Claude Code runs every tool command, background ones too, in a shell sourcing one of its
# shell snapshots; its MCP servers and caffeinate are not under one. Any shell under the agent
# counts too, so a changed snapshot path fails safe (no park), not the other way.
park_procs() { # <root pid> <agent name>
  park_ps | awk -v root="$1" -v name="$2" '
    function base(s,   w) { split(s, w, " "); s = w[1]; sub(/.*\//, "", s); sub(/^-/, "", s); return s }
    { a = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", a); args[$1] = a; kids[$2] = kids[$2] " " $1 }
    END {
      n = split(kids[root], k, " "); agent = ""
      for (i = 1; i <= n; i++) if (base(args[k[i]]) == name) { agent = k[i]; break }
      if (agent == "") exit
      print "agent " agent
      q[1] = agent; h = 1; t = 1
      while (h <= t) {
        x = q[h++]; m = split(kids[x], c, " ")
        for (j = 1; j <= m; j++) {
          y = c[j]; q[++t] = y
          if (args[y] ~ /shell-snapshots\/snapshot-/ || base(args[y]) ~ /^(sh|bash|zsh|dash|ksh|fish)$/) print "busy " y " " args[y]
        }
      }
    }'
}
# What a tool shell runs, for a person: the text Claude Code eval'd, else its argv.
park_tool_cmd() { # <args>
  local a="$1" c
  if [[ "$a" == *"eval '"* ]]; then c="${a#*eval \'}"; c="${c%%\' < /dev/null*}"; c="${c%%\'*}"; else c="$a"; fi
  (( ${#c} > 60 )) && c="${c:0:59}…"
  printf '%s' "$c"
}

# ---------------------------------------------------------------- may it park?
# Whether the task's worker may park now. <mode>: auto (the watch, sweep: at rest for the grace)
# or now (park, accept: its turn over, whatever the time). Sets PARK_WHY (why not), and on
# success PARK_SID (its session id), PARK_SID_FROM (meta | legacy) and PARK_STATE. Reads only.
park_check() { # <id> <mode>
  local id="$1" mode="$2" st t j pid procs line sid ms last now_s lp tab cs
  PARK_WHY=""; PARK_SID=""; PARK_SID_FROM=""; PARK_STATE=""
  [[ -z "$(meta_file "$id" closed)" ]] || { PARK_WHY="it is closed"; return 1; }
  [[ -z "$(meta_file "$id" parked)" ]] || { PARK_WHY="it is already parked"; return 1; }
  is_joined "$id" && { PARK_WHY="a joined session is the commander's own"; return 1; }
  park_supported "$id" || { PARK_WHY="only hc:claude workers can be parked and resumed (this is $(meta "$id" backend))"; return 1; }
  [[ -n "$(meta_file "$id" dispatched)" ]] || { PARK_WHY="it was never dispatched"; return 1; }
  # (A task at rest that is "working" by its log said nothing since its last prompt, or is waiting.)
  st="$(state_of "$id")"
  [[ "$st" != working ]] || { st=stopped-silent; [[ -z "$(waiting_info "$id" 2>/dev/null || true)" ]] || st=waiting; }
  PARK_STATE="$st"
  t="$(meta_file "$id" hc_terminal)"
  j="$(hcx get "$t" --json 2>/dev/null)" || { PARK_WHY="its hc terminal ${t:-?} does not answer"; return 1; }
  hc_info "$id"
  [[ "$HC_STATE" == live ]] || { PARK_WHY="its hc terminal is $HC_STATE"; return 1; }
  case "$HC_STATUS" in
    idle|done) ;;
    "") PARK_WHY="its agent has reported no state yet"; return 1 ;;
    *) PARK_WHY="its agent is $HC_STATUS"; return 1 ;;
  esac
  ms="$(jq -r '.status_ms // empty' <<<"$j")"
  [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
  printf -v now_s '%(%s)T' -1
  # A prompt taken after its turn ended (a steer that just went in) means its turn is not over.
  last="$(grep -E ' (steered: |agent: prompt-received)' "$(tdir "$id")/events.log" | tail -1 | cut -c1-20 || true)"
  lp="$(jq -rn --arg t "$last" '$t | fromdateiso8601? // 0')"
  if (( ms > 0 && lp * 1000 > ms )); then PARK_WHY="a prompt went in after its turn ended"; return 1; fi
  if [[ "$mode" == auto ]] && (( ms == 0 || now_s - ms / 1000 < CR_PARK_AFTER * 60 )); then
    PARK_WHY="at rest less than ${CR_PARK_AFTER}m"; return 1
  fi
  # The commander may be reading it, or typing into it: its tab is the one Herdr shows.
  tab="$(meta_file "$id" hc_tab)"
  if [[ -n "$tab" ]] && happ ls 2>/dev/null | jq -e --arg t "$tab" 'any(.spaces[]? | select(.active == true) | .tabs[]?; .id == $t and .active == true)' >/dev/null 2>&1; then
    PARK_WHY="it is on screen in Herdr"; return 1
  fi
  pid="$(jq -r '.pid // empty' <<<"$j")"
  [[ "$pid" =~ ^[0-9]+$ ]] || { PARK_WHY="hc gives no process for its terminal"; return 1; }
  procs="$(park_procs "$pid" claude)"
  [[ "$procs" == agent\ * ]] || { PARK_WHY="its claude process was not found under the terminal's program (pid $pid)"; return 1; }
  # Claude Code's own word on its session (undocumented): work it runs in its own process (a
  # background agent) has no process of its own to find. Only "idle", or no word, may park.
  cs="$(jq -r '.status // empty' "$(claude_config_dir)/sessions/$(head -1 <<<"$procs" | cut -d' ' -f2).json" 2>/dev/null || true)"
  [[ -z "$cs" || "$cs" == idle ]] || { PARK_WHY="Claude Code reports its session $cs"; return 1; }
  line="$(grep -m1 '^busy ' <<<"$procs" || true)"
  if [[ -n "$line" ]]; then
    line="${line#busy }"
    PARK_WHY="a tool command is still running under its agent: $(park_tool_cmd "${line#* }") (pid ${line%% *})"; return 1
  fi
  sid="$(meta_file "$id" session_id)"; PARK_SID_FROM=meta
  if [[ -z "$sid" ]]; then
    procs="$(head -1 <<<"$procs")"
    sid="$(claude_legacy_session "$id" "${procs#agent }" "$(meta "$id" worktree)")"; PARK_SID_FROM=legacy
    [[ -n "$sid" ]] || { PARK_WHY="no session id is recorded for it (its next prompt records one)"; return 1; }
  fi
  [[ -n "$(claude_transcript "$sid" "$(meta "$id" worktree)")" ]] ||
    { PARK_WHY="no transcript for its session $sid under $(claude_config_dir)/projects"; return 1; }
  PARK_SID="$sid"
  return 0
}

# ---------------------------------------------------------------- the lock
# One holder at a time: a symlink made atomically, pointing at its holder's pid; one whose
# holder is gone is taken over. Not inside $(...): the holder is BASHPID.
task_lock() { # <id> [seconds to wait, 0 = try once; default 30]
  local l n p
  l="$(tdir "$1")/.lock"; n=$(( ${2:-30} * 4 ))
  while ! ln -s "$BASHPID" "$l" 2>/dev/null; do
    p="$(readlink "$l" 2>/dev/null || true)"
    if [[ "$p" =~ ^[0-9]+$ ]] && ! kill -0 "$p" 2>/dev/null && ! ps -p "$p" >/dev/null 2>&1; then rm -f "$l"; continue; fi
    (( n-- > 0 )) || return 1
    sleep 0.25
  done
  return 0
}
task_unlock() { # <id>
  local l; l="$(tdir "$1")/.lock"
  [[ "$(readlink "$l" 2>/dev/null || true)" == "$BASHPID" ]] && rm -f "$l"
  return 0
}

# ---------------------------------------------------------------- park
# Park the task's worker if park_check allows it. 0 parked; 1 not (PARK_WHY says why).
park_task() { # <id> <auto|now>
  local id="$1" mode="$2" rest
  task_lock "$id" "$([[ "$mode" == auto ]] && echo 0 || echo 30)" || { PARK_WHY="a steer, attach or park of it is under way"; return 1; }
  if ! park_check "$id" "$mode"; then task_unlock "$id"; return 1; fi
  if [[ "$PARK_SID_FROM" == legacy ]]; then
    meta_set "$id" session_id "$PARK_SID"
    log_event "$id" note "session id $PARK_SID recorded from Claude Code's own session record (a worker started before chartroom recorded ids)"
  fi
  rest="$PARK_STATE"
  if ! "$(backend_runner "$id")_park" "$id" "$PARK_SID" "$rest"; then
    PARK_WHY="${PARK_WHY:-its terminal could not be ended}"; task_unlock "$id"; return 1
  fi
  rm -f "$(tdir "$id")/.park-check"
  task_unlock "$id"
  return 0
}

# A file whose mtime is now minus the grace, so `-ot` tells a log at rest that long without a
# fork. Remade at most once a minute. Sets PARK_REF; 1 when parking is off or it cannot be made.
PARK_REF="" PARK_REF_AT=0
park_ref() {
  (( CR_PARK_AFTER > 0 )) || return 1
  local f="$CR_HOME/.park-ref" t s
  printf -v t '%(%s)T' -1
  if (( t - PARK_REF_AT >= 60 )) || [[ ! -e "$f" ]]; then
    printf -v s '%(%Y%m%d%H%M.%S)T' $((t - CR_PARK_AFTER * 60))
    touch -t "$s" "$f" 2>/dev/null || return 1
    PARK_REF_AT=$t
  fi
  PARK_REF="$f"
}
# The tasks worth a park check: open, dispatched, not parked, parkable, and nothing in their log
# (and no refusal) for the grace. Forks for none of the others. Sets PARK_CANDIDATES.
park_candidates() {
  PARK_CANDIDATES=()
  park_ref || return 0
  local d id chk
  for d in "$CR_HOME"/tasks/*/; do
    id="${d%/}"; id="${id##*/}"; chk="$d.park-check"
    [[ -f "$d/meta.json" && "$d/events.log" -ot "$PARK_REF" ]] || continue
    [[ ! -e "$chk" || "$chk" -ot "$PARK_REF" ]] || continue
    is_closed "$id" && continue
    # (From the watch round's meta cache when it holds the task: no fork per parked task.)
    if [[ "${MC["$id/"]:-}" == open ]]; then
      [[ -z "${MC["$id/parked"]:-}" && -n "${MC["$id/dispatched"]:-}" && "${MC["$id/backend"]:-}" =~ ^($CR_PARK_RUNNERS):claude$ ]] || continue
    else
      [[ -z "$(meta "$id" parked)" && -n "$(meta "$id" dispatched)" ]] || continue
    fi
    park_supported "$id" || continue
    PARK_CANDIDATES+=("$id")
  done
}
# Park every worker due (the watch's full round, `park --due`). Prints one line per worker
# parked. A refusal is kept in <task>/.park-check, so the task is looked at again only after
# another grace; it is logged as a note only when its reason changed.
park_due() {
  local id prev out why
  park_candidates
  for id in "${PARK_CANDIDATES[@]+"${PARK_CANDIDATES[@]}"}"; do
    # In a subshell: nothing in a park may end the caller (the watch), whatever fails.
    out="$( ( MC=(); if park_task "$id" auto; then printf parked; else printf 'no\t%s' "$PARK_WHY"; fi ) 2>/dev/null || true)"
    if [[ "$out" == parked ]]; then
      echo "parked $id (session $(meta_file "$id" session_id))"
      continue
    fi
    why="${out#no$'\t'}"; [[ "$out" == no$'\t'* && -n "$why" ]] || why="the park check failed"
    # Another park (a second watch, a sweep) got there first, or holds it now: nothing to note.
    [[ -z "$(meta_file "$id" parked)" && "$why" != "a steer, attach or park of it is under way" ]] || continue
    prev=""; { read -r prev <"$(tdir "$id")/.park-check"; } 2>/dev/null || true
    printf '%s\n' "$why" >"$(tdir "$id")/.park-check"
    [[ "$prev" == "$why" ]] || log_event "$id" note "not parked: $why"
  done
  return 0
}
# The ids park_due would park now, as a JSON array (sweep's plan). Reads only.
park_due_json() {
  local id ids=()
  park_candidates
  for id in "${PARK_CANDIDATES[@]+"${PARK_CANDIDATES[@]}"}"; do
    ( MC=(); park_check "$id" auto ) >/dev/null 2>&1 && ids+=("$id")
  done
  printf '%s\n' "${ids[@]+"${ids[@]}"}" | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# ---------------------------------------------------------------- revive
# A revive that did not take: logged as the one line that wakes the XO; the task stays parked.
revive_failed() { # <id> <why>
  log_event "$1" note "revive failed: $2 (session $(meta_file "$1" session_id)); still parked: steer or attach tries again, chartroom dispatch $1 starts a fresh worker on its brief"
}
# Resume a parked worker. <text>: its first prompt (steer), or none (attach). 0 confirmed,
# 2 taken but its text unchecked, 1 failed (logged by the runner as revive failed).
revive_task() { # <id> [text]
  local r; r="$(backend_runner "$1")"
  declare -F "${r}_revive" >/dev/null || { revive_failed "$1" "the $r runner cannot resume a session"; return 1; }
  "${r}_revive" "$1" "${2:-}"
}

# `chartroom park <id>` (now) or `chartroom park --due` (every worker at rest for the grace).
cmd_park() {
  local usage="usage: chartroom park <id> | chartroom park --due"
  [[ $# -eq 1 ]] || die "$usage"
  if [[ "$1" == --due ]]; then
    (( CR_PARK_AFTER > 0 )) || { echo "parking is off (CHARTROOM_PARK_AFTER_MINUTES=0)"; return 0; }
    park_due; return 0
  fi
  local id; id="$(cmd_resolve "$1")" || exit 1; need_task "$id"
  park_task "$id" now || die "$id not parked: $PARK_WHY"
  echo "parked $id (session $(meta_file "$id" session_id)): steer or attach resumes it"
}
