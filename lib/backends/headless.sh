# shellcheck shell=bash
# headless runner: the agent CLI with no terminal at all, detached with nohup so it
# outlives the first mate. Needs nothing but the agent CLI.
#   headless:codex   `codex exec --json`, thread id from `thread.started`; steer = `exec resume`
#                    after the run stops (codex takes no input mid-run).
#   headless:claude  `claude -p` with stream-json in and out and a pre-assigned --session-id.
#                    stdin is a FIFO held open by the wrapper, so `steer` delivers mid-run
#                    (confirmed by the replayed user message); after the run ends, steer
#                    resumes the same session with --resume.
# Neither CLI shows a trust dialog in this mode.

headless_probe() { # <agent>
  [[ -n "$(agent_bin "$1")" ]] || { echo "$1 not on PATH"; return 1; }
  return 0
}
headless_steer_mode() { [[ "$1" == claude ]] && echo live || echo between-runs; }
headless_handle_set() { [[ -n "$(meta "$1" pid)" ]]; }

headless_launch() { # <id> <wt> <agent>
  case "$3" in
    codex) launch_codex "$1" "$2" "$(task_prompt "$1")" ;;
    claude) launch_claude_headless "$1" "$2" "$(task_prompt "$1")" ;;
    *) die "headless runner does not support agent '$3'" ;;
  esac
}

launch_codex() { # <id> <wt> <prompt> [resume-thread]
  local id="$1" wt="$2" prompt="$3" thread="${4:-}" d args=() sb=() mo=()
  d="$(tdir "$id")"
  mapfile -t sb < <(codex_sandbox_args "$id")
  mapfile -t mo < <(codex_model_args "$id")
  args=(exec --json -C "$wt" "${sb[@]}" "${mo[@]}" -o "$d/final.md")
  if [[ -n "$thread" ]]; then args+=(resume "$thread" "$prompt"); else args+=("$prompt"); fi
  # Detached on purpose: the worker must outlive the first mate's session.
  CR_T="$d" nohup bash -c 'codex "$@" </dev/null >>"$CR_T/codex.jsonl" 2>>"$CR_T/codex.err"; rc=$?
    printf "%s exited: codex process ended (exit %s)\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$CR_T/events.log"' \
    _ "${args[@]}" >/dev/null 2>&1 &
  local pid=$!; disown || true
  meta_set "$id" pid "$pid"
  if [[ -z "$thread" ]]; then
    local i t=""
    for i in $(seq 1 60); do
      t="$(grep -m1 '"thread.started"' "$d/codex.jsonl" 2>/dev/null | jq -r .thread_id 2>/dev/null || true)"
      [[ -n "$t" ]] && break
      pid_alive "$pid" || break
      sleep 0.5
    done
    [[ -n "$t" ]] || die "codex did not report a thread id; see $d/codex.err"
    meta_set "$id" thread_id "$t"
  fi
  echo "headless codex worker running (pid $pid, thread $(meta "$id" thread_id))"
}

claude_user_line() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }

launch_claude_headless() { # <id> <wt> <prompt> [resume]
  local id="$1" wt="$2" prompt="$3" resume="${4:-}" d sid perm args=() common=() b
  d="$(tdir "$id")"
  b="$(agent_bin claude)"; [[ -n "$b" ]] || die "claude not on PATH"
  sid="$(meta "$id" session_id)"
  if [[ -z "$sid" ]]; then sid="$(new_uuid)"; meta_set "$id" session_id "$sid"; fi
  perm="$(meta "$id" permission)"; perm="${perm:-$CR_CLAUDE_HEADLESS_PERMISSION}"
  mapfile -t common < <(claude_common_args "$id" "$perm")
  args=(-p --input-format stream-json --output-format stream-json --verbose --replay-user-messages "${common[@]}")
  # shellcheck disable=SC2206
  [[ -n "$CR_CLAUDE_ALLOWED_TOOLS" ]] && args+=(--allowedTools $CR_CLAUDE_ALLOWED_TOOLS)
  if [[ -n "$resume" ]]; then args+=(--resume "$sid"); else args+=(--session-id "$sid"); fi
  rm -f "$d/stdin.fifo"; mkfifo "$d/stdin.fifo"
  claude_user_line "$prompt" >"$d/stdin.first"
  # The wrapper holds the FIFO open (fd 3) so steer can write more user turns, and closes
  # it once the stream ends on a `result` with nothing new for 3s - then claude exits.
  (cd "$wt" && CR_T="$d" CR_CLAUDE="$b" nohup bash -c '
    "$CR_CLAUDE" "$@" <"$CR_T/stdin.fifo" >>"$CR_T/claude.jsonl" 2>>"$CR_T/claude.err" &
    cpid=$!
    exec 3>"$CR_T/stdin.fifo"
    cat "$CR_T/stdin.first" >&3
    quiet=0; last=""
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 1
      cur="$(tail -n 1 "$CR_T/claude.jsonl" 2>/dev/null)"
      if [[ "$cur" == *"\"type\":\"result\""* && "$cur" == "$last" ]]; then quiet=$((quiet+1)); else quiet=0; fi
      last="$cur"
      if (( quiet >= 3 )); then exec 3>&-; break; fi
    done
    wait "$cpid"; rc=$?
    jq -r "select(.type==\"result\") | .result // empty" "$CR_T/claude.jsonl" 2>/dev/null | tail -n 1 >"$CR_T/final.md"
    rm -f "$CR_T/stdin.fifo"
    printf "%s exited: claude process ended (exit %s)\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$CR_T/events.log"' \
    _ "${args[@]}" >/dev/null 2>&1 &
    echo $! >"$d/pid.tmp"; disown || true)
  local pid; pid="$(cat "$d/pid.tmp")"; rm -f "$d/pid.tmp"
  meta_set "$id" pid "$pid"
  echo "headless claude worker running (pid $pid, session $sid)"
}

headless_live() {
  local pid; pid="$(meta "$1" pid)"
  if [[ -z "$pid" ]]; then echo not-started; elif pid_alive "$pid"; then echo running; else echo stopped; fi
}

headless_steer() { # <id> <msg>
  local id="$1" msg="$2" wt d agent
  wt="$(meta "$id" worktree)"; d="$(tdir "$id")"; agent="$(backend_agent "$id")"
  case "$agent" in
    codex)
      pid_alive "$(meta "$id" pid)" && die "codex worker is mid-run; headless codex takes input only between runs. Wait for its stop, or 'chartroom stop $id' first."
      [[ -n "$(meta "$id" thread_id)" ]] || die "no codex thread recorded for $id"
      log_event "$id" steered "$msg"
      launch_codex "$id" "$wt" "$msg" "$(meta "$id" thread_id)" ;;
    claude)
      log_event "$id" steered "$msg"
      if pid_alive "$(meta "$id" pid)" && [[ -p "$d/stdin.fifo" ]]; then
        local before i; before="$(wc -c <"$d/claude.jsonl" 2>/dev/null || echo 0)"
        # Write in the background: opening a FIFO blocks if the reader just went away.
        ( claude_user_line "$msg" >"$d/stdin.fifo" ) 2>/dev/null & local wpid=$!
        for i in $(seq 1 15); do
          sleep 1
          if tail -c +"$((before + 1))" "$d/claude.jsonl" 2>/dev/null |
            jq -e --arg t "$msg" 'select(.type=="user" and (.message.content|type)=="string" and .message.content==$t)' >/dev/null 2>&1; then
            echo "delivered (live)"; return 0
          fi
        done
        kill "$wpid" 2>/dev/null || true
        # Not echoed back: the run was ending. Wait for it, then resume.
        for i in $(seq 1 30); do pid_alive "$(meta "$id" pid)" || break; sleep 1; done
        pid_alive "$(meta "$id" pid)" && die "claude did not take the message and is still running; check: chartroom peek $id"
      fi
      launch_claude_headless "$id" "$wt" "$msg" resume >/dev/null
      echo "delivered (resumed session $(meta "$id" session_id))" ;;
  esac
}

headless_stop() {
  local pid; pid="$(meta "$1" pid)"
  if pid_alive "$pid"; then pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true; fi
  return 0
}

headless_peek() { # <id> <n>
  local id="$1" n="$2" d; d="$(tdir "$id")"
  case "$(backend_agent "$id")" in
    codex)
      echo "== codex (recent)"
      jq -r 'select(.type=="item.completed") | .item |
        if .type=="agent_message" then "msg: \(.text|gsub("\n";" ")|.[0:300])"
        elif .type=="command_execution" then "cmd[\(.exit_code)]: \(.command|.[0:160])"
        elif .type=="file_change" then "edit: \(.changes // [] | map(.path) | join(", "))"
        else empty end' "$d/codex.jsonl" 2>/dev/null | tail -n "$n" ;;
    claude)
      echo "== claude (recent)"
      jq -r 'if .type=="assistant" then (.message.content[]? |
          if .type=="text" then "msg: \(.text|gsub("\n";" ")|.[0:300])"
          elif .type=="tool_use" then "tool: \(.name) \(.input|tostring|.[0:160])" else empty end)
        elif .type=="user" and (.message.content|type)=="string" then "user: \(.message.content|.[0:200])"
        elif .type=="result" then "result: \(.subtype) \(.result // "" | gsub("\n";" ") | .[0:200])"
        else empty end' "$d/claude.jsonl" 2>/dev/null | tail -n "$n" ;;
  esac
  return 0
}
headless_close() { pid_alive "$(meta "$1" pid)" && die "worker still running; 'chartroom stop $1' first"; return 0; }
headless_attach() { die "headless workers have no terminal; use 'chartroom peek $1'"; }
headless_watch() { pid_watch "$1"; }

# A pid-based worker that died without its wrapper writing `exited` was killed hard.
pid_watch() { # <id>
  local id="$1" pid; pid="$(meta "$id" pid)"
  if [[ -n "$pid" ]] && ! pid_alive "$pid" && [[ -z "${LOST[$id]:-}" ]] && ! tail -n 3 "$(tdir "$id")/events.log" | grep -q ' exited: '; then
    sleep 1 # the wrapper writes `exited` right after the process ends
    tail -n 3 "$(tdir "$id")/events.log" | grep -q ' exited: ' && return 0
    wake "$id" "lost: worker process vanished without an exit record"; LOST[$id]=1
  fi
  return 0
}
