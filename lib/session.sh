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

# Type a prompt and confirm the agent actually took it. Returns 0 when confirmed, 2 when
# the agent took something but the text could not be checked, 1 on failure.
#   claude  confirmed only by the UserPromptSubmit hook's `agent: prompt-received sig=<sig>`
#           matching the text's signature. Only a different signature and no match within
#           the wait means a fragment (or other text) was submitted: the input box is cleared (Ctrl-U per wrapped line) and the
#           text typed again, up to 3 times, then it fails. Never "delivered" on a mismatch.
#   codex   no prompt hook: its "esc to interrupt" working line, or a worker event, shows it
#           took a prompt; that does not prove which text (returns 2).
# Retries without re-typing when the text is still sitting in the input box.
session_deliver() { # <runner> <id> <agent> <text>
  local r="$1" id="$2" agent="$3" text="$4" f before i t scr new retype=1 want="" got="" seen=0 mismatches=0
  f="$(tdir "$id")/events.log"
  [[ "$agent" == claude ]] && want="$(printf '%s' "$text" | text_sig)"
  for i in 1 2 3 4 5 6; do
    before="$(wc -c <"$f")"
    if [[ $retype -eq 1 ]]; then "${r}_type" "$id" "$text"; sleep 0.5; fi
    "${r}_keys" "$id" enter
    got=""
    for t in $(seq 1 "$CR_DELIVER_WAIT"); do
      sleep 1
      new="$(tail -c +"$((before + 1))" "$f")"
      if [[ "$agent" == claude ]]; then
        grep -q " agent: prompt-received sig=$want " <<<"$new" && return 0
        # Other text (a fragment, or a prompt the session made itself, such as a background
        # task's completion notice) only counts as a mismatch if ours never arrives in the window.
        got="$(grep -oE ' agent: prompt-received sig=[0-9a-f]+ len=[0-9]+' <<<"$new" | tail -1 || true)"
        grep -qE ' agent: prompt-received$| agent: turn-ended| (progress|decision|blocked|done|failed): ' <<<"$new" && seen=1
      else
        grep -qE ' agent: (prompt-received|turn-ended)| (progress|decision|blocked|done|failed): ' <<<"$new" && return 2
        scr="$("${r}_screen" "$id" 2>/dev/null || true)"
        grep -qiE 'esc to interrupt|working \(' <<<"$scr" && return 2
      fi
    done
    if [[ -n "$got" ]]; then
      mismatches=$((mismatches + 1))
      log_event "$id" note "delivery mismatch: the agent received other text (${got#* agent: prompt-received }; expected sig=$want len=${#text}); clearing its input and retrying"
      [[ $mismatches -ge 3 ]] && return 1
      # Ctrl-U clears one wrapped line of input per press; extra presses are harmless.
      local n; n=$(( ${#text} / 60 + 3 ))
      while (( n-- > 0 )); do "${r}_keys" "$id" clear; done
      retype=1; continue
    fi
    scr="$("${r}_screen" "$id" 2>/dev/null || true)"
    if grep -qF -- "${text:0:30}" <<<"$scr"; then retype=0; else retype=1; fi
    [[ $i -ge 4 ]] && break
  done
  [[ $seen -eq 1 ]] && return 2
  return 1
}

# What steer reports for a session runner's delivery result (see session_deliver).
steer_result() { # <id> <msg> <typed text> <rc>
  local id="$1" msg="$2" text="$3" rc="$4" agent; agent="$(backend_agent "$id")"
  case "$rc" in
    0) if [[ "$text" == "$msg" ]]; then echo "delivered (the agent received the full text)"
       else echo "delivered (the agent received the full one-line pointer; the message is in $(tdir "$id")/messages/)"; fi ;;
    2) echo "submitted, not verified: the agent took a prompt, but chartroom cannot check its text ($agent: $([[ "$agent" == claude ]] && echo "no prompt text from its hook" || echo "no prompt hook")); check: chartroom peek $id" ;;
    *) die "agent did not confirm the message (or received only part of it); check: chartroom peek $id" ;;
  esac
}

# Long or multi-line messages are not typed: typing them into a TUI is where text gets cut
# (a newline submits early, a long paste races Enter). They go to <task>/messages/<n>.md and the
# agent gets a short one-line pointer, which delivery can then confirm exactly.
steer_text() { # <id> <msg> -> the text to type
  local id="$1" msg="$2" d n
  if [[ "$msg" != *$'\n'* && ${#msg} -le $CR_STEER_INLINE_MAX ]]; then printf '%s' "$msg"; return; fi
  d="$(tdir "$id")/messages"; mkdir -p "$d"
  n=1; while [[ -e "$d/$n.md" ]]; do n=$((n + 1)); done
  printf '%s\n' "$msg" >"$d/$n.md"
  printf 'Message from the XO (%s characters, in a file so nothing is cut): read %s and act on it.' "${#msg}" "$d/$n.md"
}

session_launch() { # <runner> <id> <wt> <agent>
  local r="$1" id="$2" wt="$3" agent="$4" argv=() launcher
  mapfile -t argv < <(interactive_argv "$id" "$agent" 1)
  launcher="$(write_launcher "$id" "$wt" "${argv[@]}")"
  "${r}_open" "$id" "$wt" "$launcher"
  handle_trust "$id" "$agent" "${r}_screen" "${r}_keys" || true
  session_wait_ready "$r" "$id"
  local rc=0; session_deliver "$r" "$id" "$agent" "$(task_prompt "$id")" || rc=$?
  [[ $rc -eq 1 ]] && die "agent started but did not confirm the brief; inspect it with: chartroom attach $id"
  [[ $rc -eq 2 ]] && log_event "$id" note "the agent took a prompt, but its text could not be checked ($agent has no prompt hook)"
  return 0
}

session_steer() { # <runner> <id> <msg>
  local r="$1" id="$2" msg="$3" agent
  agent="$(backend_agent "$id")"
  "${r}_alive" "$id" || die "the $r session for $id is gone; re-dispatch it"
  log_event "$id" steered "$msg"
  local text rc=0; text="$(steer_text "$id" "$msg")"
  session_deliver "$r" "$id" "$agent" "$text" || rc=$?
  steer_result "$id" "$msg" "$text" "$rc"
}
