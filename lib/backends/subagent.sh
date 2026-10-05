# shellcheck shell=bash
# subagent runner: a background subagent of the host harness. Only Claude Code has one
# today (Agent tool + SendMessage + TaskStop), so it is offered only when
# CHARTROOM_HARNESS=claude. chartroom records the task; the session launches it.

subagent_probe() {
  [[ "$CR_HARNESS" == claude ]] || { echo "only inside Claude Code (CHARTROOM_HARNESS=claude)"; return 1; }
  return 0
}
subagent_steer_mode() { echo host; }
subagent_handle_set() { [[ -n "$(meta "$1" dispatched)" ]]; }

subagent_launch() { # <id> <wt>
  local id="$1" wt="$2"
  cat <<EOF
subagent task recorded. Launch it yourself with the Agent tool:
  name: $id
  run_in_background: true
  prompt: $(task_prompt "$id")${wt:+ Your worktree is $wt; cd into it before any command.}
Steer it later with SendMessage to "$id". It dies with this session; if the session restarts, re-dispatch.
EOF
}
subagent_live() { [[ -n "$(meta "$1" dispatched)" ]] && echo in-session || echo not-started; }
subagent_steer() { log_event "$1" steered "$2"; echo "use SendMessage to \"$1\" with the message"; }
subagent_stop() { echo "stop the subagent with TaskStop"; }
subagent_peek() { return 0; }
subagent_close() { return 0; }
subagent_attach() { die "subagents run inside the host session; there is nothing to attach to"; }
subagent_watch() { :; }
