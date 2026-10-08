# shellcheck shell=bash
# shellcheck disable=SC2046  # $(cmux_ws_args) expands to "--workspace UUID --surface UUID"; UUIDs never contain spaces
# cmux runner (manaflow-ai/cmux, the macOS terminal for coding agents; macOS 14+).
# IMPLEMENTED AGAINST THE DOCUMENTED CLI, UNVERIFIED ON A REAL cmux INSTALL.
#
# Layout mirrors herdr: one cmux workspace titled $CHARTROOM_WORKSPACE for the crew, one
# surface (tab) per task, created unfocused. The agent runs from chartroom's launcher, and
# turn ends / approval prompts come from the same Claude hooks / Codex notify as tmux.
# cmux has no pipe-pane, so peek reads the screen; close snapshots the scrollback to
# <task>/pane.log first.
#
# Socket access: cmux's default mode only accepts commands from processes started inside
# cmux. A XO running elsewhere needs automation mode (Settings, or
# automation.socketControlMode in ~/.config/cmux/cmux.json). doctor reports this.

cmuxc() { CMUX_QUIET=1 "$(cmux_bin)" "$@"; }
cmux_bin() {
  local b; b="$(bin_of cmux)"
  [[ -z "$b" && -x /Applications/cmux.app/Contents/Resources/bin/cmux ]] && b=/Applications/cmux.app/Contents/Resources/bin/cmux
  printf '%s' "$b"
}

cmux_probe() {
  [[ "$(uname -s)" == Darwin || -n "${CHARTROOM_CMUX_ANY_OS:-}" ]] || { echo "cmux is macOS-only"; return 1; }
  [[ -n "$(cmux_bin)" ]] || { echo "cmux not installed"; return 1; }
  if ! cmuxc ping >/dev/null 2>&1; then
    local mode; mode="$(cmuxc socket-status --json 2>/dev/null | jq -r '.mode // .socketControlMode // empty' 2>/dev/null || true)"
    if [[ -n "$mode" && -z "${CMUX_WORKSPACE_ID:-}" ]]; then echo "cmux socket refused (mode $mode); enable automation mode or run from a cmux terminal"
    else echo "cmux app not running (cmux ping failed)"; fi
    return 1
  fi
  return 0
}
cmux_steer_mode() { echo live; }
cmux_handle_set() { [[ -n "$(meta "$1" cmux_surface)" ]]; }
cmux_ws_args() { printf '%s\n' --workspace "$(meta "$1" cmux_workspace)" --surface "$(meta "$1" cmux_surface)"; }

cmux_open() { # <id> <wt> <launcher>
  local id="$1" wt="$2" launcher="$3" ws r sf cmd
  cmd="bash $(printf '%q' "$launcher")"
  ws="$(cmuxc --json --id-format uuids workspace list 2>/dev/null |
    jq -r --arg t "$CR_WORKSPACE" '.workspaces[]? | select(.title==$t) | (.id // .workspace_id)' | head -1 || true)"
  if [[ -z "$ws" ]]; then
    r="$(cmuxc --json --id-format uuids workspace create --name "$CR_WORKSPACE" --cwd "$wt" --command "$cmd")" || die "cmux workspace create failed"
    ws="$(jq -r '.workspace_id // empty' <<<"$r")"; sf="$(jq -r '.surface_id // empty' <<<"$r")"
    if [[ -z "$sf" ]]; then
      sf="$(cmuxc --json --id-format uuids list-pane-surfaces --workspace "$ws" | jq -r '[.. | objects | (.surface_id // .id)? // empty][0] // empty')"
    fi
  else
    r="$(cmuxc --json --id-format uuids new-surface --workspace "$ws" --working-directory "$wt" --command "$cmd")" || die "cmux new-surface failed"
    sf="$(jq -r '.surface_id // empty' <<<"$r")"
  fi
  [[ -n "$ws" && -n "$sf" ]] || die "cmux did not return workspace/surface ids: $r"
  meta_set "$id" cmux_workspace "$ws"; meta_set "$id" cmux_surface "$sf"
  cmuxc rename-tab --workspace "$ws" --surface "$sf" -- "$id" >/dev/null 2>&1 || true
}

cmux_alive() { cmux_handle_set "$1" && cmuxc read-screen $(cmux_ws_args "$1") --lines 1 >/dev/null 2>&1; }
cmux_screen() { cmuxc read-screen $(cmux_ws_args "$1"); }
cmux_type() { cmuxc send $(cmux_ws_args "$1") -- "${2//$'\n'/ }" >/dev/null; }
cmux_keys() {
  local id="$1" k; shift
  for k in "$@"; do
    case "$k" in esc) k=escape ;; clear) k=ctrl+u ;; esac
    # --force: a key must reach an open dialog (the trust prompt), which cmux otherwise guards.
    cmuxc send-key --force $(cmux_ws_args "$id") "$k" >/dev/null; sleep 0.3
  done
}

cmux_launch() { session_launch cmux "$1" "$2" "$3"; echo "cmux $3 worker running (workspace $CR_WORKSPACE, tab $1; watch: chartroom attach $1)"; }
cmux_live() { session_live cmux "$1"; }
cmux_steer() { session_steer cmux "$1" "$2"; }
cmux_stop() { cmux_alive "$1" && cmux_keys "$1" esc; return 0; }
cmux_peek() { echo "== screen (recent)"; cmux_alive "$1" && cmuxc read-screen $(cmux_ws_args "$1") --scrollback --lines "$(($2 * 3))" | grep -v '^[[:space:]]*$' | tail -n "$(($2 * 2))"; return 0; }
cmux_close() {
  local id="$1"
  cmux_alive "$id" || return 0
  cmuxc read-screen $(cmux_ws_args "$id") --scrollback >>"$(tdir "$id")/pane.log" 2>/dev/null || true
  cmuxc close-surface $(cmux_ws_args "$id") --force >/dev/null 2>&1 ||
    cmuxc workspace close "$(meta "$id" cmux_workspace)" --force >/dev/null 2>&1 || true
}
cmux_attach() {
  cmux_alive "$1" || die "the cmux tab for $1 is gone"
  cmuxc workspace select "$(meta "$1" cmux_workspace)" >/dev/null
  cmuxc focus-panel --panel "$(meta "$1" cmux_surface)" --workspace "$(meta "$1" cmux_workspace)" >/dev/null
  command -v open >/dev/null && open -a cmux 2>/dev/null || true
}
cmux_watch() { :; }
