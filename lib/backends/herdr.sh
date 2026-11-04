# shellcheck shell=bash
# herdr runner (first class): all workers share one herdr workspace labelled
# $CHARTROOM_WORKSPACE, one unfocused tab per task; the herdr agent name is the task id.
# herdr tracks agent state itself (working/idle/done/blocked), so no hooks are needed.

herdr_probe() {
  # herdr's Windows build is a preview chartroom has not been verified against.
  [[ "$CR_PLATFORM" != msys || -n "${CHARTROOM_HERDR_ANY_OS:-}" ]] || { echo "herdr on Windows is unverified (CHARTROOM_HERDR_ANY_OS=1 to try it)"; return 1; }
  [[ -n "$(bin_of herdr)" ]] || { echo "herdr not on PATH"; return 1; }
  herdr workspace list >/dev/null 2>&1 || { echo "herdr server not reachable (is herdr running? HERDR_ENV=${HERDR_ENV:-unset})"; return 1; }
  return 0
}
herdr_steer_mode() { echo live; }
herdr_handle_set() { [[ -n "$(meta "$1" herdr_pane)" ]]; }

crew_workspace() { # sets CREW_WS; when it creates the workspace, also CREW_FRESH_PANE/TAB (its unused root tab)
  CREW_FRESH_PANE=""; CREW_FRESH_TAB=""
  CREW_WS="$(herdr workspace list | jq -r --arg l "$CR_WORKSPACE" '.result.workspaces[] | select(.label==$l) | .workspace_id' | head -1)"
  if [[ -z "$CREW_WS" ]]; then
    local r; r="$(herdr workspace create --cwd "$1" --label "$CR_WORKSPACE" --no-focus)"
    CREW_WS="$(jq -r .result.workspace.workspace_id <<<"$r")"
    CREW_FRESH_PANE="$(jq -r .result.root_pane.pane_id <<<"$r")"
    CREW_FRESH_TAB="$(jq -r .result.tab.tab_id <<<"$r")"
  fi
}

herdr_status() { herdr_up || return 0; herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty' || true; }
# herdr's API socket, found without running herdr ($HERDR_SOCKET_PATH, else the named session's
# under $XDG_CONFIG_HOME/herdr/sessions/, else $XDG_CONFIG_HOME/herdr/herdr.sock, as herdr 0.9.5
# reports them): while no server is there, an agent's state is empty (gone) without running herdr,
# and the watch, the radar and sweep run no herdr command at all.
# (Git Bash: herdr's Windows preview is not known to keep a socket file there, so no gate.)
herdr_up() {
  [[ "${CR_PLATFORM:-}" != msys ]] || return 0
  local s="${HERDR_SOCKET_PATH:-}" c="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
  if [[ -z "$s" && -n "${HERDR_SESSION:-}" ]]; then s="$c/sessions/$HERDR_SESSION/herdr.sock"; fi
  [[ -S "${s:-$c/herdr.sock}" ]]
}
# The watch asks herdr once per round (`agent list`), not once per task; on a herdr without
# `agent list`, `agent get` per task as before. Sets HERDR_W (empty: no such agent, or no server).
declare -A HERDR_ST=()
HERDR_ROUND="" HERDR_W=""
herdr_round_reset() { HERDR_ROUND=""; HERDR_ST=(); }
herdr_watch_status() { # <id>
  local n s
  HERDR_W=""
  herdr_up || return 0
  if [[ -z "$HERDR_ROUND" ]]; then
    HERDR_ROUND="get"
    while IFS=$'\t' read -r n s; do
      if [[ "$n" == @list ]]; then HERDR_ROUND=list; elif [[ -n "$n" ]]; then HERDR_ST[$n]="$s"; fi
    done < <(herdr agent list 2>/dev/null | jq -r 'select((.result.agents | type) == "array") | "@list", (.result.agents[] | select(.name != null) | [.name, (.agent_status // "")] | @tsv)' 2>/dev/null || true)
  fi
  if [[ "$HERDR_ROUND" == list ]]; then HERDR_W="${HERDR_ST[$1]:-}"; else HERDR_W="$(herdr_status "$1")"; fi
  return 0
}
herdr_alive() { [[ -n "$(herdr_status "$1")" ]]; }
herdr_screen() { herdr agent read "$1" --source visible --lines 40; }
herdr_keys() { local id="$1" k; shift; for k in "$@"; do herdr agent send-keys "$id" "$k" >/dev/null; sleep 0.3; done; }

# Submit and confirm the agent took the prompt: 0 confirmed, 2 taken but text unchecked, 1 failed.
# Claude workers carry a UserPromptSubmit hook (prompt mode), so the submitted text's signature
# is checked exactly as for tmux; a mismatch clears the input (ctrl+u) and resubmits, at most 3
# times. Without that hook (codex, or a worker launched before it existed) herdr's own state
# ("working") or the text's start on screen only shows that a prompt was taken.
herdr_deliver() { # <id> <text>
  local name="$1" text="$2" f i t st before new got="" want="" mismatches=0 n
  f="$(tdir "$name")/events.log"
  [[ "$(backend_agent "$name")" == claude ]] && jq -e '.hooks.UserPromptSubmit' "$(tdir "$name")/claude-settings.json" >/dev/null 2>&1 &&
    want="$(printf '%s' "$text" | text_sig)"
  for i in 1 2 3 4 5 6; do
    before="$(wc -c <"$f")"
    herdr agent prompt "$name" "$text" >/dev/null 2>&1 || true
    if [[ -n "$want" ]]; then
      got=""
      for t in $(seq 1 "$CR_DELIVER_WAIT"); do
        sleep 1
        new="$(tail -c +"$((before + 1))" "$f")"
        grep -q " agent: prompt-received sig=$want " <<<"$new" && return 0
        got="$(grep -oE ' agent: prompt-received sig=[0-9a-f]+ len=[0-9]+' <<<"$new" | tail -1 || true)"
      done
      if [[ -n "$got" ]]; then
        mismatches=$((mismatches + 1))
        log_event "$name" note "delivery mismatch: the agent received other text (${got#* agent: prompt-received }; expected sig=$want len=${#text}); clearing its input and retrying"
        [[ $mismatches -ge 3 ]] && return 1
        n=$(( ${#text} / 60 + 3 )); while (( n-- > 0 )); do herdr agent send-keys "$name" ctrl+u >/dev/null 2>&1 || true; done
        continue
      fi
    else
      sleep 3
    fi
    st="$(herdr_status "$name")"
    if [[ "$st" == working ]] || herdr agent read "$name" --source recent --lines 80 2>/dev/null | grep -qF "${text:0:40}"; then
      return 2
    fi
    [[ $i -ge 4 ]] && break
    sleep 2
  done
  return 1
}

# A live agent already named <id> is left over from an earlier start of this task (one that died
# at startup leaves its agent holding the name, and the next start fails agent_name_taken). It is
# closed only if it sits in the tab chartroom recorded for this task, never finished its launch
# (herdr_launched) and is not mid-turn; anything else is not chartroom's to close.
herdr_clear_stale() { # <id>
  local id="$1" old st tab
  herdr_alive "$id" || return 0
  old="$(meta "$id" herdr_tab)"; st="$(herdr_status "$id")"
  tab="$(herdr agent get "$id" 2>/dev/null | jq -r '.result.agent.tab_id // empty' || true)"
  [[ -n "$old" && "$tab" == "$old" ]] || die "a herdr agent named $id already runs in tab ${tab:-?}, which chartroom did not record for this task; close it, then dispatch again"
  [[ "$(meta "$id" herdr_launched)" != 1 ]] || die "the worker for $id is live in herdr tab $tab; steer it, or close it (chartroom close $id) before dispatching again"
  [[ "$st" != working ]] || die "the herdr agent for $id is already working in tab $tab; steer it, or close that tab and dispatch again"
  herdr tab close "$tab" >/dev/null 2>&1 || die "could not close the stale herdr tab $tab for $id"
  log_event "$id" note "closed the stale herdr tab $tab left by an earlier start ($st)"
}

herdr_launch() { # <id> <wt> <agent>
  local id="$1" wt="$2" agent="$3" ws pane tab
  herdr_clear_stale "$id"; meta_set "$id" herdr_launched ""
  crew_workspace "$wt"; ws="$CREW_WS"
  if [[ -n "$CREW_FRESH_PANE" ]]; then
    pane="$CREW_FRESH_PANE"; tab="$CREW_FRESH_TAB"; herdr tab rename "$tab" "$id" >/dev/null
  else
    local r; r="$(herdr tab create --workspace "$ws" --cwd "$wt" --label "$id" --no-focus)"
    pane="$(jq -r .result.root_pane.pane_id <<<"$r")"; tab="$(jq -r .result.tab.tab_id <<<"$r")"
  fi
  meta_set "$id" herdr_workspace "$ws"; meta_set "$id" herdr_tab "$tab"; meta_set "$id" herdr_pane "$pane"; meta_set "$id" agent "$id"

  local start=(agent start "$id" --kind "$agent" --pane "$pane" --timeout 60000) extra=() out i blocked=0
  # herdr starts the agent binary itself; pass the same flags chartroom uses elsewhere.
  mapfile -t extra < <(interactive_argv "$id" "$agent" "$([[ "$agent" == claude ]] && echo prompt || echo 0)" | tail -n +2)
  [[ ${#extra[@]} -gt 0 ]] && start+=(-- "${extra[@]}")
  # agent_not_ready: the agent came up but is blocked at a startup dialog (usually the folder
  # trust prompt). herdr keeps the name for read/send-keys, so carry on to the trust handling
  # below; starting again would only fail agent_name_taken.
  for i in $(seq 1 40); do
    if out="$(herdr "${start[@]}" 2>&1)"; then break; fi
    if grep -q agent_not_ready <<<"$out"; then blocked=1; log_event "$id" note "herdr: agent blocked at startup; checking for a trust dialog"; break; fi
    grep -q agent_pane_busy <<<"$out" || die "herdr agent start failed: $out"
    sleep 0.5
  done
  sleep 1
  if ! handle_trust "$id" "$agent" herdr_screen herdr_keys && [[ $blocked -eq 1 ]]; then
    die "the $agent worker is waiting at a startup dialog chartroom will not answer; answer it in herdr tab $tab, then dispatch $id again"
  fi
  herdr agent wait "$id" --until idle --until "done" --timeout 30000 >/dev/null 2>&1 || true
  local rc=0; herdr_deliver "$id" "$(task_prompt "$id")" || rc=$?
  [[ $rc -eq 1 ]] && die "agent started but did not take the brief; inspect tab $tab"
  meta_set "$id" herdr_launched 1
  echo "herdr $agent worker running (workspace $CR_WORKSPACE, tab $tab)"
}

herdr_live() {
  herdr_handle_set "$1" || { echo not-started; return; }
  local st; st="$(herdr_status "$1")"; echo "${st:-gone}"
}
herdr_steer() {
  log_event "$1" steered "$2"
  local text rc=0; text="$(steer_text "$1" "$2")"
  herdr_deliver "$1" "$text" || rc=$?
  steer_result "$1" "$2" "$text" "$rc"
}
herdr_stop() { herdr agent send-keys "$1" esc >/dev/null 2>&1 || true; }
herdr_peek() { echo "== pane (recent)"; herdr agent read "$1" --source recent --lines "$(($2 * 3))" 2>/dev/null | grep -v '^\s*$' | tail -n "$(($2 * 2))"; return 0; }
herdr_close() { local tab; tab="$(meta "$1" herdr_tab)"; [[ -n "$tab" ]] && herdr tab close "$tab" >/dev/null 2>&1; return 0; }
herdr_attach() { herdr tab focus "$(meta "$1" herdr_tab)"; }

# Extra wakes from herdr's own agent state. Uses the watch loop's HST map. An agent whose server
# is down is gone: it wakes once, and costs nothing after that while the server stays down.
herdr_watch() { # <id>
  local id="$1" st
  herdr_handle_set "$id" || return 0
  herdr_watch_status "$id"; st="${HERDR_W:-gone}"
  if [[ "$st" != "${HST[$id]:-}" ]]; then
    case "$st" in
      blocked) wake "$id" "herdr: agent is waiting on an approval or question prompt" ;;
      idle|done) [[ "${HST[$id]:-}" == working ]] && ! reported_since_dispatch "$id" && wake "$id" "herdr: agent stopped its turn without reporting" ;;
      gone) [[ -n "${HST[$id]:-}" ]] && wake "$id" "lost: herdr agent is no longer running" ;;
    esac
    HST[$id]="$st"
  fi
  return 0
}
