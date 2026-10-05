# shellcheck shell=bash
# tmux runner: one tmux session per crew ($CHARTROOM_WORKSPACE), one window per task.
# Output is piped to <task>/pane.log from the start; turn ends and approval prompts come
# from agent hooks (Claude Stop/Notification, Codex notify), not from screen scraping.
# CHARTROOM_TMUX_SOCKET=<name> runs the crew on a separate tmux server (tmux -L).

tmx() {
  local sock; sock="$(cfg TMUX_SOCKET '' '')"
  if [[ -n "$sock" ]]; then tmux -L "$sock" "$@"; else tmux "$@"; fi
}

tmux_probe() {
  local b v
  b="$(bin_of tmux)"; [[ -n "$b" ]] || { echo "tmux not found"; return 1; }
  v="$(tmux -V 2>/dev/null | sed -E 's/^tmux (next-)?([0-9]+)\..*/\2/')"
  [[ "$v" =~ ^[0-9]+$ && "$v" -ge 3 ]] || { echo "tmux >= 3.0 required ($(tmux -V 2>/dev/null))"; return 1; }
  return 0
}
tmux_steer_mode() { echo live; }
tmux_handle_set() { [[ -n "$(meta "$1" tmux_pane)" ]]; }

tmux_open() { # <id> <wt> <launcher>
  local id="$1" wt="$2" launcher="$3" pane
  if tmx has-session -t "=$CR_WORKSPACE" 2>/dev/null; then
    pane="$(tmx new-window -d -t "=$CR_WORKSPACE:" -n "$id" -c "$wt" -P -F '#{pane_id}' "bash $(printf '%q' "$launcher")")"
  else
    pane="$(tmx new-session -d -s "$CR_WORKSPACE" -n "$id" -c "$wt" -x 220 -y 50 -P -F '#{pane_id}' "bash $(printf '%q' "$launcher")")"
  fi
  [[ -n "$pane" ]] || die "tmux did not return a pane id"
  meta_set "$id" tmux_pane "$pane"; meta_set "$id" tmux_session "$CR_WORKSPACE"
  tmx pipe-pane -o -t "$pane" "cat >> $(printf '%q' "$(tdir "$id")/pane.log")" || true
}

tmux_alive() { local p; p="$(meta "$1" tmux_pane)"; [[ -n "$p" ]] && tmx display-message -p -t "$p" '#{pane_id}' >/dev/null 2>&1; }
tmux_screen() { tmx capture-pane -p -t "$(meta "$1" tmux_pane)"; }
tmux_type() { tmx send-keys -t "$(meta "$1" tmux_pane)" -l -- "$2"; }
tmux_keys() {
  local id="$1" k; shift
  for k in "$@"; do
    case "$k" in enter) k=Enter ;; esc) k=Escape ;; down) k=Down ;; esac
    tmx send-keys -t "$(meta "$id" tmux_pane)" "$k"; sleep 0.3
  done
}

tmux_launch() { session_launch tmux "$1" "$2" "$3"; echo "tmux $3 worker running (session $CR_WORKSPACE, window $1; watch: chartroom attach $1)"; }
tmux_live() { session_live tmux "$1"; }
tmux_steer() { session_steer tmux "$1" "$2"; }
tmux_stop() { tmux_alive "$1" && tmux_keys "$1" esc; return 0; }
tmux_peek() { # <id> <n>
  local id="$1" n="$2" d; d="$(tdir "$id")"
  echo "== pane (recent)"
  if tmux_alive "$id"; then tmx capture-pane -p -t "$(meta "$id" tmux_pane)" -S -200 | grep -v '^[[:space:]]*$' | tail -n "$((n * 2))"
  elif [[ -f "$d/pane.log" ]]; then strip_ansi <"$d/pane.log" | grep -v '^[[:space:]]*$' | tail -n "$((n * 2))"; fi
  return 0
}
tmux_close() { tmux_alive "$1" && tmx kill-pane -t "$(meta "$1" tmux_pane)" 2>/dev/null; return 0; }
tmux_attach() {
  local p; p="$(meta "$1" tmux_pane)"; tmux_alive "$1" || die "the tmux window for $1 is gone"
  if [[ -n "${TMUX:-}" && -z "$(cfg TMUX_SOCKET '' '')" ]]; then tmx switch-client -t "$p"
  else tmx attach-session -t "=$(meta "$1" tmux_session)" \; select-window -t "$p"; fi
}
tmux_watch() { :; }

strip_ansi() { sed -E $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g; s/\x1b\\][^\x07]*(\x07|\x1b\\\\)//g; s/\x1b[()][A-Z0-9]//g; s/\r//g'; }
