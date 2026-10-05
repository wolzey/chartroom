# shellcheck shell=bash
# session.sh - shared logic for session runners (herdr, cmux, tmux): an interactive agent
# in a terminal the commander can watch. A runner provides:
#   <r>_open <id> <wt> <launcher>   create the tab/window running <launcher>; record handles in meta
#   <r>_screen <id>                 print the visible screen
#   <r>_keys <id> <key>...          send named keys: enter, esc, down
#   <r>_type <id> <text>            type literal text (no Enter)
#   <r>_alive <id>                  exit 0 while the terminal still exists

# Launcher script: runs the agent in the worktree with chartroom's env, and records
# the session ending as an `exited` event so a vanished agent is never silent.
write_launcher() { # <id> <wt> <argv...>
  local id="$1" wt="$2"; shift 2
  local d f; d="$(tdir "$id")"; f="$d/launch.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cd %q || exit 1\n' "$wt"
    printf 'export CHARTROOM_HOME=%q CHARTROOM_TASK=%q PATH=%q\n' "$CR_HOME" "$id" "$PATH"
    printf '%q ' "$@"; printf '\n'
    printf 'rc=$?\n'
    printf 'printf "%%s exited: agent session ended (exit %%s)\\n" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" "$rc" >>%q\n' "$d/events.log"
  } >"$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# Agent-native state from hook events since the last dispatch/steer:
# working | idle (turn ended) | blocked (awaiting input).
hook_state() { # <id>
  awk '
    ($2=="note:" && $3=="dispatched") || $2=="steered:" || ($2=="agent:" && $3=="prompt-received") { s="working" }
    $2=="agent:" && $3=="turn-ended" { s="idle" }
    $2=="agent:" && $3 ~ /^awaiting-input/ { s="blocked" }
    END { print (s=="" ? "working" : s) }' "$(tdir "$1")/events.log"
}

session_live() { # <runner> <id>
  local r="$1" id="$2"
  "${r}_handle_set" "$id" || { echo not-started; return; }
  if "${r}_alive" "$id"; then hook_state "$id"
  elif grep -q ' exited: ' "$(tdir "$id")/events.log"; then echo stopped
  else echo gone; fi
}

# Wait for the agent's UI to settle (a prompt sent during a splash screen is dropped).
session_wait_ready() { # <runner> <id>
  local r="$1" id="$2" i prev="" cur
  for i in $(seq 1 20); do
    cur="$("${r}_screen" "$id" 2>/dev/null || true)"
    [[ -n "${cur//[[:space:]]/}" && "$cur" == "$prev" ]] && return 0
    prev="$cur"; sleep 1
  done
  return 0
}

# Type a prompt and confirm the agent actually took it. Confirmation is agent-native
# where possible: Claude's UserPromptSubmit hook writes `agent: prompt-received`;
# Codex shows its "esc to interrupt" working line. Retries without re-typing when the
# text is still sitting in the input box.
session_deliver() { # <runner> <id> <agent> <text>
  local r="$1" id="$2" agent="$3" text="$4" f before i t scr retype=1
  f="$(tdir "$id")/events.log"
  for i in 1 2 3 4; do
    before="$(wc -c <"$f")"
    if [[ $retype -eq 1 ]]; then "${r}_type" "$id" "$text"; sleep 0.5; fi
    "${r}_keys" "$id" enter
    for t in $(seq 1 "$CR_DELIVER_WAIT"); do
      sleep 1
      if tail -c +"$((before + 1))" "$f" | grep -qE ' agent: (prompt-received|turn-ended)| (progress|decision|blocked|done|failed): '; then return 0; fi
      if [[ "$agent" != claude ]]; then
        scr="$("${r}_screen" "$id" 2>/dev/null || true)"
        grep -qiE 'esc to interrupt|working \(' <<<"$scr" && return 0
      fi
    done
    scr="$("${r}_screen" "$id" 2>/dev/null || true)"
    if grep -qF -- "${text:0:30}" <<<"$scr"; then retype=0; else retype=1; fi
  done
  return 1
}

session_launch() { # <runner> <id> <wt> <agent>
  local r="$1" id="$2" wt="$3" agent="$4" argv=() launcher
  mapfile -t argv < <(interactive_argv "$id" "$agent" 1)
  launcher="$(write_launcher "$id" "$wt" "${argv[@]}")"
  "${r}_open" "$id" "$wt" "$launcher"
  handle_trust "$id" "$agent" "${r}_screen" "${r}_keys" || true
  session_wait_ready "$r" "$id"
  session_deliver "$r" "$id" "$agent" "$(task_prompt "$id")" ||
    die "agent started but did not confirm the brief; inspect it with: chartroom attach $id"
}

session_steer() { # <runner> <id> <msg>
  local r="$1" id="$2" msg="$3" agent
  agent="$(backend_agent "$id")"
  "${r}_alive" "$id" || die "the $r session for $id is gone; re-dispatch it"
  log_event "$id" steered "$msg"
  session_deliver "$r" "$id" "$agent" "$msg" || die "agent did not confirm the message; check: chartroom peek $id"
  echo "delivered"
}
