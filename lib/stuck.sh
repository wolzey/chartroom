# shellcheck shell=bash
# stuck.sh - a worker must never sit stuck unnoticed, on any backend.
#
# The agents' own signals say most of it (hooks, hc's and herdr's agent state, notify), but not
# all: Codex reports no state to hc and its notify fires only when a turn completes, so nothing
# said it was sitting at an approval prompt (verified on codex-cli 0.158.0 and hc 0.1.16). What
# is left is told here, from what the terminal shows. The watch's full round calls watch_look for
# each dispatched task, at most once per CHARTROOM_LOOK_INTERVAL (60 s), which:
#   - raises a prompt or dialog nothing else reports as `agent: awaiting-input: <what>`, and logs
#     `agent: prompt-cleared` once it is gone (screen_prompt, prompt_sync)
#   - delivers a brief that waited behind a startup dialog, once that clears (brief_pending_look)
#   - wakes once for a task whose output and events have not changed for CHARTROOM_STALL_MINUTES
#     (stall_look), recorded as `note: stalled: ...` like `note: waiting overdue: ...`
# A look costs one read of the terminal and a few small forks; a look that finds a task quiet
# for nearly the whole stall adds one `ps`. Nothing here ever types into a terminal, except the
# brief once its dialog has gone.

declare -A LOOK_NEXT=() # the next look at each task (epoch ms)
LOOK_MS=60000 STALL_SECS=600 STALL_BUSY_SECS=3600 STALL_BUSY_PCT=10 LOOK_ANY=0

# The last <n> non-blank lines of what is on stdin, without hc's own notes.
screen_tail() { grep -vE '^[[:space:]]*$|^\[hc\] ' | tail -n "$1" || true; }

# ---------------------------------------------------------------- prompts and dialogs

# The dialog a screen shows, as one line for the wake, or nothing. Only an overlay's own footer on
# the screen's last lines counts: the same words higher up are a transcript (a worker reading this
# very file), and while the composer is up its lines are the last ones. Verified on codex-cli
# 0.158.0; Claude's approvals are its hooks' and hc's to report, so only its folder dialog is here.
screen_prompt() { # <id> <agent> <screen>
  local id="$1" agent="$2" scr="$3" foot line
  foot="$(screen_tail 3 <<<"$scr")"
  case "$agent" in
    codex)
      case "$foot" in
        *'enter confirm · esc skip'*)
          grep -qF 'Hooks need review' <<<"$scr" || return 0
          line="$(grep -oE '[0-9]+ hooks? (is|are) new or changed' <<<"$scr" | head -1 || true)"
          printf 'Codex "Hooks need review" dialog%s. Esc continues without those hooks; trusting them is the commander'\''s call. The brief starts once it clears' "${line:+: $line}" ;;
        *'enter continue · esc quit'*) trust_prompt_text "$id" ;;
        *'Press enter to confirm or esc to cancel'*)
          line="$(grep -E '^[[:space:]]*(\$ |Would you like )' <<<"$scr" | tail -n 1 | sed -E 's/^[[:space:]]+//' | cut -c1-160 || true)"
          printf 'Codex approval prompt: %s' "${line:-(see its screen)}" ;;
      esac ;;
    claude)
      if grep -qE '(❯|›) *(No, exit|Yes, I trust)' <<<"$(screen_tail 6 <<<"$scr")"; then trust_prompt_text "$id"; fi ;;
  esac
  return 0
}
trust_prompt_text() { # <id>
  if [[ "$(meta "$1" worktree_created)" == 1 ]]; then printf 'trust dialog came up after the dispatch; a human must answer it'
  else printf 'trust dialog for a folder chartroom did not create; a human must answer it'; fi
}

# Bring the log in line with what is on screen: <what> is up (a new one wakes, through the event
# scan, once) or, with "", nothing is. The log is the memory, so a restarted or --once watch does
# not repeat a prompt, and status and the dashboard read it as every other prompt.
prompt_sync() { # <id> <what or "">
  local id="$1" what="$2" st last
  st="$(hook_state "$id")"
  if [[ -z "$what" ]]; then
    [[ "$st" != blocked ]] || log_event "$id" agent prompt-cleared
    return 0
  fi
  last="$(grep ' agent: awaiting-input' "$(tdir "$id")/events.log" | tail -n 1 || true)"
  [[ "$st" == blocked && "$last" == *" agent: awaiting-input: $what" ]] || log_event "$id" agent "awaiting-input: $what"
}

# Codex says so in its terminal title while an approval is up, "[ . ] Action Required | ..." and
# "[ ! ] ..." in turn (verified on codex-cli 0.158.0; herdr's own codex rule reads the same).
codex_title_prompt() { [[ "$1" =~ ^\[\ [.!]\ \]\ Action\ Required ]]; }
CODEX_TITLE_WHAT='Codex approval prompt (its terminal title says Action Required)'

# What a look at this task's terminal has to raise, for an agent that does not report it itself:
# Codex anywhere (herdr knows its approvals, but reads the hooks dialog as idle), and on hc any
# agent with no state yet (a dialog before it starts).
prompt_look() { # <id> <runner> <agent> <live> <screen>
  local id="$1" r="$2" agent="$3" live="$4" scr="$5" what
  case "$r:$agent" in
    hc:*)
      hc_info "$id"
      # (Up since before this watch began, or a second one with the title never off. Idempotent.)
      if [[ -n "$HC_TITLE_BLOCKED" ]]; then
        what="$(screen_prompt "$id" "$agent" "$scr")"
        prompt_sync "$id" "${what:-$CODEX_TITLE_WHAT}"
        return 0
      fi
      [[ -z "$HC_STATUS" ]] || return 0 ;;
    herdr:codex) [[ "$live" != blocked ]] || return 0 ;;
    tmux:codex|cmux:codex) ;;
    *) return 0 ;;
  esac
  what="$(screen_prompt "$id" "$agent" "$scr")"
  if [[ -z "$what" && "$r" == tmux ]] && codex_title_prompt "$(tmux_title "$id")"; then what="$CODEX_TITLE_WHAT"; fi
  prompt_sync "$id" "$what"
}

# Typed text and Enter at Codex's approval overlay approve the command: the overlay drops the text
# and Enter takes its highlighted "Yes, proceed" (verified on codex-cli 0.158.0, through `hc send`).
# hc does not refuse it, because hc does not know that Codex is blocked. So chartroom never types there.
steer_guard() { # <runner> <id>
  local r="$1" id="$2" what
  [[ "$(backend_agent "$id")" == codex ]] || return 0
  what="$(screen_prompt "$id" codex "$("${r}_screen" "$id" 2>/dev/null || true)")"
  if [[ -z "$what" && "$r" == tmux ]] && codex_title_prompt "$(tmux_title "$id")"; then what="$CODEX_TITLE_WHAT"; fi
  [[ -z "$what" ]] || die "the agent is blocked at a dialog (${what%%. *}); answer it first (chartroom attach $id), then steer again"
}

# ---------------------------------------------------------------- the brief behind a dialog

# A session runner types the brief, and typing it at a dialog loses it: the dialog drops the text
# and Enter answers it (verified on tmux, codex-cli 0.158.0). So a launch that meets a dialog
# leaves meta brief_pending set, and the first look to find the dialog gone delivers the brief.
# (hc passes the brief as the agent's first prompt, which waits behind the dialog by itself.)
brief_pending_look() { # <id> <runner> <agent> <screen>
  local id="$1" r="$2" agent="$3" scr="$4" rc=0
  [[ "$(meta "$id" brief_pending)" == 1 && "$r" != hc ]] || return 0
  [[ -z "$(screen_prompt "$id" "$agent" "$scr")" ]] || return 0
  if [[ "$r" == tmux && "$agent" == codex ]] && codex_title_prompt "$(tmux_title "$id")"; then return 0; fi
  if [[ "$r" == herdr && "$(herdr_status "$id")" == blocked ]]; then return 0; fi
  task_lock "$id" 0 || return 0
  if [[ "$r" == herdr ]]; then herdr_deliver "$id" "$(task_prompt "$id")" || rc=$?
  else session_deliver "$r" "$id" "$agent" "$(task_prompt "$id")" || rc=$?; fi
  meta_set "$id" brief_pending ""
  task_unlock "$id"
  case "$rc" in
    0) log_event "$id" note "the brief went in once the dialog cleared" ;;
    2) log_event "$id" note "the brief went in once the dialog cleared; the agent took a prompt, but its text could not be checked" ;;
    *) log_event "$id" agent "awaiting-input: the dialog cleared, but the agent did not confirm the brief; check: chartroom peek $id" ;;
  esac
}

# ---------------------------------------------------------------- the stall watchdog

# A screen as it would compare if nothing happened: what ticks by itself goes (the agents' working
# lines, elapsed times, a clock, spinner glyphs, the verb Claude rotates, the rotating tip), and what
# the agent did stays, Claude's running token count among it. Bytes throughout, so any screen is valid.
screen_norm() {
  local t='(^|[^[:alnum:].])[0-9]+(\.[0-9]+)?(ms|h|m|s)([^[:alnum:].]|$)'
  LC_ALL=C sed -E \
    -e '/esc to interrupt/d; /Tip: /d; /^\[hc\] /d' \
    -e 's/(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|✻|✽|✶|✢|✳|✺|·)//g' \
    -e 's/^[[:space:]]*[A-Za-z]+…/…/' \
    -e 's/[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?( ?[AP]M)?//g' \
    -e "s/$t/\\1\\4/g" -e "s/$t/\\1\\4/g" \
    -e 's/[[:space:]]+$//'
}

# The process table as "pid ppid cputime args". CHARTROOM_STALL_PS_FILE stands in one (the tests).
stall_ps() {
  if [[ -n "${CHARTROOM_STALL_PS_FILE:-}" ]]; then cat "$CHARTROOM_STALL_PS_FILE"; else ps -ww -A -o pid=,ppid=,time=,args= 2>/dev/null; fi
}
# The process that holds the worker's whole tree, or nothing where the runner cannot say (cmux).
stall_root() { # <id> <runner>
  case "$2" in
    hc) hcx get "$(meta "$1" hc_terminal)" --json 2>/dev/null | jq -r '.pid // empty' 2>/dev/null || true ;;
    tmux) tmx display-message -p -t "$(meta "$1" tmux_pane)" '#{pane_pid}' 2>/dev/null || true ;;
    herdr) herdr pane process-info --pane "$(meta "$1" herdr_pane)" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null || true ;;
    headless|command) meta "$1" pid ;;
  esac
}
# The CPU that what runs under <root> has used, in hundredths of a second, and the command a shell
# there runs, tab-separated. The agent's own processes do not count (a TUI animates while it waits
# on anything); its tools do. An idle MCP server's share stays far below STALL_BUSY_PCT.
stall_tree() { # <root pid> <agent name, or "">
  stall_ps | awk -v root="$1" -v name="$2" '
    function base(s) { sub(/.*\//, "", s); sub(/^-/, "", s); return s }
    function cs(t,   p, n, i, d, s) { # [[dd-]hh:]mm:ss[.cc], on macOS and Linux
      d = 0; if (index(t, "-")) { split(t, p, "-"); d = p[1]; t = p[2] }
      n = split(t, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      return int((d * 86400 + s) * 100)
    }
    function own(x,   w) {
      if (name == "") return 0
      split(args[x], w, " ")
      return index(base(w[1]), name) == 1 || index(base(w[2]), name) == 1
    }
    {
      a = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]*/, "", a)
      args[$1] = a; cpu[$1] = cs($3); kids[$2] = kids[$2] " " $1
    }
    END {
      q[1] = root; h = 1; t = 1; total = 0; cmd = ""
      while (h <= t) {
        x = q[h++]; m = split(kids[x], c, " ")
        for (j = 1; j <= m; j++) {
          y = c[j]; q[++t] = y
          if (own(y)) continue
          total += cpu[y]
          split(args[y], w, " ")
          if (cmd == "" && (args[y] ~ /shell-snapshots\/snapshot-/ || base(w[1]) ~ /^(sh|bash|zsh|dash|ksh|fish)$/)) cmd = args[y]
        }
      }
      printf "%d\t%s\n", total, cmd
    }'
}
# The worker's last lines, on one line, without the agents' own furniture.
stall_last_lines() { # <id> <runner> <screen>
  local out line s="" n=0
  case "$2" in
    headless) out="$(headless_peek "$1" 6 2>/dev/null || true)" ;;
    command) out="$(command_peek "$1" 6 2>/dev/null | strip_ansi || true)" ;;
    *) out="$3" ;;
  esac
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    (( ${#line} <= 100 )) || line="${line:0:99}…"
    s+="${s:+ | }$line"; n=$((n + 1))
  done < <(grep -vE '^[[:space:]]*$|^\[hc\] |^== |Tip: |for shortcuts|shift\+tab to cycle|Ask Codex to do anything| default · |^[[:space:]]*(❯|›|>)[[:space:]]*$|^[[:space:]]*[─━-]+[[:space:]]*$' <<<"$out" | tail -n 3 || true)
  printf '%s' "$s"
}
# A task that is in flight (not reporting, not waiting by its own word, not at a prompt the XO has
# been told of) and whose output and events have not moved for STALL_SECS wakes once; its output
# or a new event re-arms it. A note, this one's own included, is not an event here. The state
# survives a restart in <task>/.stall (signature, since, fired, CPU sample, its time). Past the
# stall, a tree still using CPU is a long command at work: it waits, up to STALL_BUSY_SECS.
stall_look() { # <id> <runner> <agent> <live> <screen>
  local id="$1" r="$2" agent="$3" live="$4" scr="$5" d f sig osig="" since="" fired="" cpu="" at="" n quiet out root tree cmd="" pct=-1 msg last
  (( STALL_SECS > 0 )) || return 0
  [[ "$live" != blocked && "$live" != listening ]] || return 0
  # (herdr reads Codex's hooks dialog as idle: the log knows better. It ends a prompt's account too.)
  [[ "$(hook_state "$id")" != blocked ]] || return 0
  [[ "$(state_of "$id")" == working ]] || return 0
  [[ -z "$(waiting_info "$id" 2>/dev/null || true)" ]] || return 0
  d="$(tdir "$id")"; f="$d/.stall"
  case "$r" in
    headless) out="$(wc -c <"$d/$agent.jsonl" 2>/dev/null || echo 0)" ;;
    command) out="$(wc -c <"$d/output.log" 2>/dev/null || echo 0)" ;;
    *) out="$(screen_norm <<<"$scr" | cksum)" ;;
  esac
  n="$(grep -vc ' note: ' "$d/events.log" || true)"
  sig="${out//[[:space:]]/}:$n"
  local now_s; printf -v now_s '%(%s)T' -1
  if [[ -f "$f" ]]; then IFS=$'\t' read -r osig since fired cpu at <"$f" || true; fi
  if [[ "$sig" != "$osig" || ! "$since" =~ ^[0-9]+$ ]]; then printf '%s\t%s\t0\t\t\n' "$sig" "$now_s" >"$f"; return 0; fi
  [[ "$fired" != 1 ]] || return 0
  quiet=$((now_s - since))
  (( quiet + LOOK_MS / 1000 >= STALL_SECS )) || return 0
  root="$(stall_root "$id" "$r")"
  if [[ -n "$root" ]]; then
    tree="$(stall_tree "$root" "$agent" || true)"
    cmd="${tree#*$'\t'}"; tree="${tree%%$'\t'*}"
    [[ "$tree" =~ ^[0-9]+$ ]] || tree=0
    if [[ "$cpu" =~ ^[0-9]+$ && "$at" =~ ^[0-9]+$ ]] && (( now_s > at )); then pct=$(( (tree - cpu) / (now_s - at) )); fi
    if (( quiet < STALL_SECS || pct < 0 )) || (( pct >= STALL_BUSY_PCT && quiet < STALL_BUSY_SECS )); then
      printf '%s\t%s\t0\t%s\t%s\n' "$sig" "$since" "$tree" "$now_s" >"$f"
      return 0
    fi
  elif (( quiet < STALL_SECS )); then return 0
  fi
  printf '%s\t%s\t1\t\t\n' "$sig" "$since" >"$f"
  msg="stalled: no output or events for $((quiet / 60)) min"
  if [[ -n "$cmd" ]]; then
    if (( pct >= STALL_BUSY_PCT )); then msg+=" (still using CPU: $(park_tool_cmd "$cmd"))"; else msg+=" (a command is running, idle: $(park_tool_cmd "$cmd"))"; fi
  fi
  last="$(stall_last_lines "$id" "$r" "$scr")"
  msg+=". Last output: ${last:-(none)}"
  log_event "$id" note "$msg"
  wake "$id" "$msg"
}

# ---------------------------------------------------------------- the look

# <id> <runner>: at most one per task per CHARTROOM_LOOK_INTERVAL. A worker that has stopped is
# the launcher's and the probes' to report; a joined session is the commander's own, and a
# subagent the host's: neither has anything here to read.
watch_look() {
  local id="$1" r="$2" agent live scr=""
  case "$r" in hc|herdr|tmux|cmux|headless|command) ;; *) return 0 ;; esac
  LOOK_ANY=1
  clock_ms
  (( NOW_MS >= ${LOOK_NEXT[$id]:-0} )) || return 0
  LOOK_NEXT[$id]=$((NOW_MS + LOOK_MS))
  live="$(live_of "$id")"
  case "$live" in not-started|stopped|gone|parked|unknown) return 0 ;; esac
  agent="$(backend_agent "$id")"
  case "$r" in
    hc|herdr|tmux|cmux)
      # (No read of its terminal: nothing to compare. A blank screen is still a screen.)
      scr="$("${r}_screen" "$id" 2>/dev/null)" || return 0
      prompt_look "$id" "$r" "$agent" "$live" "$scr"
      brief_pending_look "$id" "$r" "$agent" "$scr"
      # (Its prompt may just have come or gone: the live word above is from before that.)
      if [[ "$r" != herdr ]]; then live="$(live_of "$id")"; fi ;;
  esac
  stall_look "$id" "$r" "$agent" "$live" "$scr"
}
