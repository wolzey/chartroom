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

herdr_status() { herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty' || true; }
herdr_alive() { [[ -n "$(herdr_status "$1")" ]]; }
herdr_screen() { herdr agent read "$1" --source visible --lines 40; }
herdr_keys() { local id="$1" k; shift; for k in "$@"; do herdr agent send-keys "$id" "$k" >/dev/null; sleep 0.3; done; }

herdr_deliver() { # <agent> <text> - submit and confirm the agent actually took the prompt
  local name="$1" text="$2" i st
  for i in 1 2 3 4; do
    herdr agent prompt "$name" "$text" >/dev/null 2>&1 || true
    sleep 3
    st="$(herdr_status "$name")"
    if [[ "$st" == working ]] || herdr agent read "$name" --source recent --lines 80 2>/dev/null | grep -qF "${text:0:40}"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

herdr_launch() { # <id> <wt> <agent>
  local id="$1" wt="$2" agent="$3" ws pane tab
  crew_workspace "$wt"; ws="$CREW_WS"
  if [[ -n "$CREW_FRESH_PANE" ]]; then
    pane="$CREW_FRESH_PANE"; tab="$CREW_FRESH_TAB"; herdr tab rename "$tab" "$id" >/dev/null
  else
    local r; r="$(herdr tab create --workspace "$ws" --cwd "$wt" --label "$id" --no-focus)"
    pane="$(jq -r .result.root_pane.pane_id <<<"$r")"; tab="$(jq -r .result.tab.tab_id <<<"$r")"
  fi
  meta_set "$id" herdr_workspace "$ws"; meta_set "$id" herdr_tab "$tab"; meta_set "$id" herdr_pane "$pane"; meta_set "$id" agent "$id"

  local start=(agent start "$id" --kind "$agent" --pane "$pane" --timeout 60000) extra=() out i
  # herdr starts the agent binary itself; pass the same flags chartroom uses elsewhere.
  mapfile -t extra < <(interactive_argv "$id" "$agent" 0 | tail -n +2)
  [[ ${#extra[@]} -gt 0 ]] && start+=(-- "${extra[@]}")
  for i in $(seq 1 40); do
    if out="$(herdr "${start[@]}" 2>&1)"; then break; fi
    grep -q agent_pane_busy <<<"$out" || die "herdr agent start failed: $out"
    sleep 0.5
  done
  sleep 1
  handle_trust "$id" "$agent" herdr_screen herdr_keys || true
  herdr agent wait "$id" --until idle --until "done" --timeout 30000 >/dev/null 2>&1 || true
  herdr_deliver "$id" "$(task_prompt "$id")" || die "agent started but did not take the brief; inspect tab $tab"
  echo "herdr $agent worker running (workspace $CR_WORKSPACE, tab $tab)"
}

herdr_live() {
  herdr_handle_set "$1" || { echo not-started; return; }
  local st; st="$(herdr_status "$1")"; echo "${st:-gone}"
}
herdr_steer() {
  log_event "$1" steered "$2"
  herdr_deliver "$1" "$2" || die "agent did not take the message; check: chartroom peek $1"
  echo "delivered"
}
herdr_stop() { herdr agent send-keys "$1" esc >/dev/null 2>&1 || true; }
herdr_peek() { echo "== pane (recent)"; herdr agent read "$1" --source recent --lines "$(($2 * 3))" 2>/dev/null | grep -v '^\s*$' | tail -n "$(($2 * 2))"; return 0; }
herdr_close() { local tab; tab="$(meta "$1" herdr_tab)"; [[ -n "$tab" ]] && herdr tab close "$tab" >/dev/null 2>&1; return 0; }
herdr_attach() { herdr tab focus "$(meta "$1" herdr_tab)"; }

# Extra wakes from herdr's own agent state. Uses the watch loop's HST map.
herdr_watch() { # <id>
  local id="$1" st
  herdr_handle_set "$id" || return 0
  st="$(herdr_status "$id")"; st="${st:-gone}"
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
