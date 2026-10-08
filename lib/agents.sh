# shellcheck shell=bash
# agents.sh - how to start each agent CLI, independent of where it runs.
#
# Agents: claude (Claude Code), codex (Codex CLI). Every function here prints
# arguments one per line so callers can `mapfile` them without word-splitting.

KNOWN_AGENTS='claude|codex'

agent_bin() { bin_of "$1"; }

# Codex sandbox per task: meta "sandbox" wins; else scouts get workspace-write (network on,
# writes limited to the worktree + task record) and ship tasks get CHARTROOM_CODEX_SHIP_SANDBOX
# (default danger-full-access). Why: recent codex refuses every .git write under
# workspace-write, so a sandboxed worker cannot commit. The brief's worktree-only rule is
# the control; set CHARTROOM_CODEX_SHIP_SANDBOX=workspace-write for a stricter posture.
codex_sandbox_args() { # <id>
  local d mode
  d="$(tdir "$1")"
  mode="$(meta "$1" sandbox)"
  if [[ -z "$mode" ]]; then
    if [[ "$(meta "$1" kind)" == scout ]]; then mode="$CR_CODEX_SCOUT_SANDBOX"; else mode="$CR_CODEX_SHIP_SANDBOX"; fi
  fi
  case "$mode" in
    workspace-write) printf '%s\n' -s workspace-write -c sandbox_workspace_write.network_access=true --add-dir "$d" ;;
    danger-full-access|read-only) printf '%s\n' -s "$mode" ;;
    *) die "unknown codex sandbox '$mode' for $1" ;;
  esac
}

codex_model_args() { # <id>
  local m e
  m="$(meta "$1" model)"; e="$(meta "$1" effort)"
  [[ -n "$m" ]] && printf '%s\n' -m "$m"
  [[ -n "$e" ]] && printf '%s\n' -c "model_reasoning_effort=$e"
  return 0
}

# Codex calls `notify` with a JSON argument when a turn completes; chartroom turns
# that into an `agent: turn-ended` event (no screen scraping).
codex_notify_args() { # <id>
  printf '%s\n' -c "notify=[\"$CR_BIN\",\"hook\",\"$1\",\"codex-notify\"]"
}

# Claude Code hooks for interactive sessions (tmux, cmux): turn end, approval/idle
# prompts and prompt receipt become events. Written per task, loaded with --settings.
# "prompt" mode (herdr, which tracks turn state itself) adds only UserPromptSubmit, so
# delivery can be checked against the submitted text without doubling herdr's wakes.
claude_settings_file() { # <id> [all|prompt] -> path
  local id="$1" mode="${2:-all}" f h
  f="$(tdir "$id")/claude-settings.json"
  h="CHARTROOM_HOME=$(printf '%q' "$CR_HOME") $(printf '%q' "$CR_BIN") hook $id"
  jq -n --arg stop "$h stop" --arg notif "$h notification" --arg sub "$h prompt-submit" --arg mode "$mode" '{hooks:(
    (if $mode == "all" then {Stop:[{hooks:[{type:"command",command:$stop}]}],
      Notification:[{hooks:[{type:"command",command:$notif}]}]} else {} end)
    + {UserPromptSubmit:[{hooks:[{type:"command",command:$sub}]}]})}' >"$f"
  printf '%s' "$f"
}

claude_common_args() { # <id> <permission-mode or "">
  local m perm="$2"
  m="$(meta "$1" model)"
  [[ -n "$m" ]] && printf '%s\n' --model "$m"
  [[ -n "$perm" ]] && printf '%s\n' --permission-mode "$perm"
  printf '%s\n' --add-dir "$(tdir "$1")"
}

# Full argv (one per line) for an interactive agent session. <hooks:1|0|prompt>
interactive_argv() { # <id> <agent> <hooks>
  local id="$1" agent="$2" hooks="$3" b
  b="$(agent_bin "$agent")"; [[ -n "$b" ]] || die "$agent not on PATH"
  printf '%s\n' "$b"
  case "$agent" in
    claude)
      local perm; perm="$(meta "$id" permission)"
      claude_common_args "$id" "${perm:-$CR_CLAUDE_PERMISSION}"
      [[ "$hooks" == 1 ]] && printf '%s\n' --settings "$(claude_settings_file "$id")"
      [[ "$hooks" == prompt ]] && printf '%s\n' --settings "$(claude_settings_file "$id" prompt)"
      ;;
    codex)
      # Interactive codex otherwise self-updates on launch and exits, losing the brief.
      printf '%s\n' -c check_for_update_on_startup=false
      codex_sandbox_args "$id"; codex_model_args "$id"
      [[ "$hooks" == 1 ]] && codex_notify_args "$id"
      ;;
    *) die "unknown agent '$agent'" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- first-launch trust dialog
#
# Both CLIs gate a never-seen folder behind a "trust this folder" dialog. chartroom
# answers it ONLY for a worktree it created itself for this task (meta worktree_created=1),
# and only by reading the dialog first: Claude puts the cursor on "No, exit" (answer: Down,
# Enter); Codex puts it on "1. Trust and continue" (answer: Enter). Anything else is left
# for a human and raised as an `agent: awaiting-input` event. chartroom never edits
# ~/.claude.json or ~/.codex/config.toml to pre-trust a path.

trust_dialog_up() { grep -qiE 'trust this folder|do you trust' <<<"$1"; }

# Prints the keys to send (space-separated, runner-neutral names: down enter), or nothing.
trust_answer_keys() { # <agent> <screen>
  local agent="$1" screen="$2"
  case "$agent" in
    claude)
      if grep -qE '❯ *No, exit' <<<"$screen"; then echo "down enter"
      elif grep -qE '❯ *Yes, I trust' <<<"$screen"; then echo "enter"; fi ;;
    codex)
      grep -qE '› *1\. *Trust and continue' <<<"$screen" && echo "enter" ;;
  esac
  return 0
}

# Shared by every session runner. <id> <agent> <screen-fn> <keys-fn>
# screen-fn <id> prints the visible screen; keys-fn <id> <key>... sends named keys.
handle_trust() {
  local id="$1" agent="$2" screen_fn="$3" keys_fn="$4" i scr keys
  for i in 1 2 3 4 5 6 7 8; do
    scr="$("$screen_fn" "$id" 2>/dev/null || true)"
    if trust_dialog_up "$scr"; then
      if [[ "$(meta "$id" worktree_created)" != 1 ]]; then
        log_event "$id" agent "awaiting-input: trust dialog for a folder chartroom did not create; a human must answer it"
        return 1
      fi
      keys="$(trust_answer_keys "$agent" "$scr")"
      if [[ -z "$keys" ]]; then
        log_event "$id" agent "awaiting-input: unrecognised trust dialog; left for a human"
        return 1
      fi
      # shellcheck disable=SC2086
      "$keys_fn" "$id" $keys
      log_event "$id" note "accepted workspace trust for its own worktree"
      sleep 3
      return 0
    fi
    # The agent's main UI is up (prompt box) - no dialog this time.
    grep -qE '(^|[[:space:]])(❯|›|>)[[:space:]]' <<<"$scr" && [[ $i -ge 3 ]] && return 0
    sleep 1
  done
  return 0
}
