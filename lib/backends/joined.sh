# shellcheck shell=bash
# joined runner: an agent session chartroom did NOT launch (Claude Code or Codex in any
# terminal, IDE or app) that ran `chartroom join` itself. It is never dispatched; the
# connection starts from the agent's side, so chartroom needs no way into its terminal.
#
#   steering   a mailbox: tasks/<id>/mail/<n>.txt, read up to the number in mail/read.
#              The agent keeps `chartroom listen <id>` armed (Claude Code: a background
#              Bash command, which re-invokes an idle session when it exits); listen prints
#              the new message(s), marks them read and logs `agent: prompt-received mail #n`.
#              `steer` reports delivered only once the agent has read the message.
#   handles    recorded only when verified: a tmux pane or herdr pane whose shell is an
#              ancestor of the join command (inherited env can point at someone else's
#              pane), or a cmux surface when no other multiplexer is in the env. They serve
#              peek, attach and stop; steering always goes through the mailbox.
#   liveness   the agent's process (pid); turn ends and prompts from the join skill's
#              session-scoped hooks (Claude Code) via `chartroom hook --session`.
#   close      never removes or cleans the session's directory; it only marks the task closed.

joined_probe() { echo "not a dispatch backend: an agent joins with 'chartroom join'"; return 1; }
joined_steer_mode() { [[ "$1" == claude ]] && echo "mailbox (wakes an idle session)" || echo "mailbox (read between steps)"; }
joined_handle_set() { return 0; }
is_joined() { [[ "$(meta "$1" joined)" == 1 ]]; }

# ---------------------------------------------------------------- mailbox

mail_dir() { printf '%s/mail' "$(tdir "$1")"; }
mail_count() { local f=("$(mail_dir "$1")"/*.txt); [[ -e "${f[0]}" ]] && echo "${#f[@]}" || echo 0; }
mail_read_upto() { cat "$(mail_dir "$1")/read" 2>/dev/null || echo 0; }
mail_unread() { echo $(( $(mail_count "$1") - $(mail_read_upto "$1") )); }

mail_post() { # <id> <msg> -> prints the message number
  local d n; d="$(mail_dir "$1")"; mkdir -p "$d"
  n=$(( $(mail_count "$1") + 1 ))
  printf '%s\n' "$2" >"$d/.$n.tmp" && mv "$d/.$n.tmp" "$d/$n.txt"
  echo "$n"
}

# Print every unread message, mark them read, and record the read as an agent event.
mail_take() { # <id> -> exit 1 when there was nothing to read
  local id="$1" d from to n
  d="$(mail_dir "$id")"; from=$(( $(mail_read_upto "$id") + 1 )); to="$(mail_count "$id")"
  (( to >= from )) || return 1
  for ((n = from; n <= to; n++)); do
    printf '== message #%s from the XO\n' "$n"
    cat "$d/$n.txt"
  done
  echo "$to" >"$d/read"
  log_event "$id" agent "prompt-received mail #$from$([[ $to -gt $from ]] && echo "-#$to")"
  printf '== act on it under your brief (%s), report with `chartroom event`, then re-arm: chartroom listen %s\n' "$(tdir "$id")/brief.md" "$id"
}

listener_alive() { local p; p="$(cat "$(mail_dir "$1")/listener.pid" 2>/dev/null)"; pid_alive "$p"; }

# ---------------------------------------------------------------- handles

pid_is_ancestor() { # <ancestor> <pid>
  local a="$1" p="$2" i
  [[ "$a" =~ ^[0-9]+$ && "$a" -gt 1 ]] || return 1
  for i in $(seq 1 64); do
    [[ "$p" == "$a" ]] && return 0
    [[ "$p" =~ ^[0-9]+$ && "$p" -gt 1 ]] || return 1
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

# The agent process this command runs under: CLAUDE_PID for Claude Code, else the nearest
# ancestor named after a known agent. Prints "<agent> <pid>", or nothing.
detect_agent_proc() {
  local p="$$" i c a
  if [[ "${CLAUDECODE:-}" == 1 && -n "${CLAUDE_PID:-}" ]] && pid_is_ancestor "$CLAUDE_PID" "$$"; then echo "claude $CLAUDE_PID"; return; fi
  for i in $(seq 1 64); do
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [[ "$p" =~ ^[0-9]+$ && "$p" -gt 1 ]] || return 0
    c="$(ps -o args= -p "$p" 2>/dev/null)"
    for a in ${KNOWN_AGENTS//|/ }; do
      [[ "$(basename "${c%% *}")" == "$a" || "$c" =~ (^|[/ ])$a(\.js)?( |$) ]] && { echo "$a $p"; return; }
    done
  done
}

# Record the terminal this session runs in, but only a verified one.
joined_detect_pane() { # <id>
  local id="$1" sock ppid hp
  if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" && -n "$(bin_of tmux)" ]]; then
    sock="${TMUX%%,*}"
    ppid="$(tmux -S "$sock" display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null || true)"
    if pid_is_ancestor "$ppid" "$$"; then
      meta_set "$id" tmux_pane "$TMUX_PANE"; meta_set "$id" tmux_socket "$sock"; echo "tmux pane $TMUX_PANE"; return
    fi
  fi
  if [[ -n "${HERDR_PANE_ID:-}" && -n "$(bin_of herdr)" ]]; then
    ppid="$(herdr pane process-info --pane "$HERDR_PANE_ID" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null || true)"
    if pid_is_ancestor "$ppid" "$$"; then
      hp="$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)"
      meta_set "$id" herdr_pane "$HERDR_PANE_ID"; [[ -n "$hp" ]] && meta_set "$id" herdr_tab "$hp"
      echo "herdr pane $HERDR_PANE_ID"; return
    fi
  fi
  if [[ -z "${TMUX:-}" && -z "${HERDR_ENV:-}" && -n "${CMUX_WORKSPACE_ID:-}" && -n "${CMUX_SURFACE_ID:-}" ]]; then
    meta_set "$id" cmux_workspace "$CMUX_WORKSPACE_ID"; meta_set "$id" cmux_surface "$CMUX_SURFACE_ID"; echo "cmux surface $CMUX_SURFACE_ID"; return
  fi
}

jtmux() { local id="$1"; shift; tmux -S "$(meta "$id" tmux_socket)" "$@"; }
joined_pane() { # <id> -> tmux | herdr | cmux | "" (only while the terminal still exists)
  local id="$1"
  if [[ -n "$(meta "$id" tmux_pane)" ]]; then jtmux "$id" display-message -p -t "$(meta "$id" tmux_pane)" '#{pane_id}' >/dev/null 2>&1 && echo tmux
  elif [[ -n "$(meta "$id" herdr_pane)" ]]; then herdr pane get "$(meta "$id" herdr_pane)" >/dev/null 2>&1 && echo herdr
  elif [[ -n "$(meta "$id" cmux_surface)" ]]; then cmux_alive "$id" && echo cmux
  fi
  return 0
}

# Joined sessions can belong to any home, and the join skill's hooks are static: they know
# only the session id. join records <session id> -> <home>\t<task>\t<chartroom binary> here;
# the hook command reads the binary from it, and `chartroom hook --session` the rest.
session_registry() { printf '%s/chartroom/sessions' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

# ---------------------------------------------------------------- runner surface

joined_live() { # listening (its listener is armed) | working | idle | blocked | running | stopped
  local id="$1" pid st=""
  pid="$(meta "$id" pid)"
  grep -q ' exited: ' "$(tdir "$id")/events.log" && { echo stopped; return; }
  if [[ -n "$pid" ]] && ! pid_alive "$pid"; then echo stopped; return; fi
  if [[ "$(joined_pane "$id")" == herdr ]]; then
    st="$(herdr pane get "$(meta "$id" herdr_pane)" 2>/dev/null | jq -r '.result.pane.agent_status // empty' 2>/dev/null || true)"
    [[ "$st" == unknown ]] && st=""
  fi
  # Hook-derived state only once a hook has fired: without hooks it would read "working" forever.
  [[ -z "$st" ]] && grep -qE ' agent: (turn-ended|awaiting-input)' "$(tdir "$id")/events.log" && st="$(hook_state "$id")"
  [[ "$st" == blocked ]] && { echo blocked; return; }
  if listener_alive "$id" && [[ "$st" != working ]]; then echo listening; return; fi
  echo "${st:-running}"
}

joined_steer() { # <id> <msg>
  local id="$1" msg="$2" n i
  # steered first: the listener may read the message (and log its read) at once.
  log_event "$id" steered "$msg"
  n="$(mail_post "$id" "$msg")"
  for ((i = 0; i < CR_JOIN_ACK_WAIT; i++)); do
    (( $(mail_read_upto "$id") >= n )) && { echo "delivered (message #$n read by the agent)"; return 0; }
    sleep 1
  done
  if listener_alive "$id"; then
    echo "queued, not yet read (message #$n): its listener is armed; it picks the message up when the agent's current step ends"
  else
    echo "queued, not yet read (message #$n): no listener is armed, so it is read only when the agent next checks its mailbox"
  fi
}

joined_stop() {
  case "$(joined_pane "$1")" in
    tmux) jtmux "$1" send-keys -t "$(meta "$1" tmux_pane)" Escape ;;
    herdr) herdr pane send-keys "$(meta "$1" herdr_pane)" esc >/dev/null 2>&1 || true ;;
    cmux) cmux_keys "$1" esc ;;
    *) die "no terminal is recorded for joined task $1; ask it to stop with: chartroom steer $1 <message>" ;;
  esac
}

joined_peek() { # <id> <n>
  local id="$1" n="$2"
  printf '== mailbox: %s message(s), %s unread; listener %s\n' "$(mail_count "$id")" "$(mail_unread "$id")" "$(listener_alive "$id" && echo armed || echo "not armed")"
  case "$(joined_pane "$id")" in
    tmux) echo "== pane (recent)"; jtmux "$id" capture-pane -p -t "$(meta "$id" tmux_pane)" -S -200 | grep -v '^[[:space:]]*$' | tail -n "$((n * 2))" ;;
    herdr) echo "== pane (recent)"; herdr pane read "$(meta "$id" herdr_pane)" --source recent --lines "$((n * 3))" 2>/dev/null | grep -v '^\s*$' | tail -n "$((n * 2))" ;;
    cmux) cmux_peek "$id" "$n" ;;
    *) echo "== no terminal recorded for this joined session (events and mailbox only)" ;;
  esac
  return 0
}

joined_close() { # the directory is the session's own: never touched. Forget the session.
  local sid; sid="$(meta "$1" session_id)"
  [[ -n "$sid" ]] && rm -f "$(session_registry)/$sid"
  return 0
}

joined_attach() {
  local id="$1"
  case "$(joined_pane "$id")" in
    tmux)
      if [[ "${TMUX%%,*}" == "$(meta "$id" tmux_socket)" ]]; then jtmux "$id" switch-client -t "$(meta "$id" tmux_pane)"
      else jtmux "$id" attach-session -t "$(meta "$id" tmux_pane)" \; select-window -t "$(meta "$id" tmux_pane)"; fi ;;
    herdr) herdr tab focus "$(meta "$id" herdr_tab)" ;;
    cmux) cmux_attach "$id" ;;
    *) die "no terminal is recorded for joined task $id (it joined from outside tmux/herdr/cmux); find it where it runs, or use: chartroom peek $id" ;;
  esac
}

# The agent's process ending is recorded once, as an `exited` event, so the wake survives
# restarts and --once loops (the scan wakes on it unless the worker had already reported).
joined_watch() { # <id>
  local id="$1" pid; pid="$(meta "$id" pid)"
  [[ -n "$pid" ]] || return 0
  if ! pid_alive "$pid" && ! grep -q ' exited: ' "$(tdir "$id")/events.log"; then
    log_event "$id" exited "joined agent session ended (pid $pid gone)"
  fi
  return 0
}
