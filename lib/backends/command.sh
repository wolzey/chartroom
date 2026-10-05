# shellcheck shell=bash
# command runner: any CLI, from a template. Set per task (`new --command`) or globally
# (CHARTROOM_COMMAND). Placeholders are replaced with shell-quoted values:
#   {brief} {prompt} {worktree} {task_dir} {id}
# e.g.  aider --yes --message-file {brief}      or      my-agent --cwd {worktree} {prompt}
# The command runs detached in the worktree with CHARTROOM_HOME/CHARTROOM_TASK exported;
# its output goes to <task>/output.log and its end is recorded as `exited (exit N)`.
# Steering is between runs: steer re-runs the template with {prompt} = the message (and
# CHARTROOM_STEER set). `steer --inbox` instead appends to <task>/inbox.md while it runs,
# which only helps if the worker reads it - best effort, never a guarantee.

command_probe() {
  [[ -n "${CR_TASK_COMMAND:-}${CR_COMMAND}" ]] || { echo "no command template (set CHARTROOM_COMMAND or new --command)"; return 1; }
  return 0
}
command_steer_mode() { echo between-runs; }
command_handle_set() { [[ -n "$(meta "$1" pid)" ]]; }

command_render() { # <id> <prompt> -> the shell command line
  local id="$1" prompt="$2" t d
  t="$(meta "$id" command)"; t="${t:-$CR_COMMAND}"
  [[ -n "$t" ]] || die "task $id has no command template"
  d="$(tdir "$id")"
  t="${t//\{brief\}/$(printf '%q' "$d/brief.md")}"
  t="${t//\{prompt\}/$(printf '%q' "$prompt")}"
  t="${t//\{worktree\}/$(printf '%q' "$(meta "$id" worktree)")}"
  t="${t//\{task_dir\}/$(printf '%q' "$d")}"
  t="${t//\{id\}/$(printf '%q' "$id")}"
  printf '%s' "$t"
}

command_run() { # <id> <wt> <prompt> [steer-message]
  local id="$1" wt="$2" prompt="$3" steer="${4:-}" d line
  d="$(tdir "$id")"; line="$(command_render "$id" "$prompt")"
  (cd "${wt:-$d}" || exit 1
  CHARTROOM_HOME="$CR_HOME" CHARTROOM_TASK="$id" CHARTROOM_STEER="$steer" CHARTROOM_BIN="$CR_BIN" CR_T="$d" CR_LINE="$line" \
    nohup bash -c 'bash -c "$CR_LINE" </dev/null >>"$CR_T/output.log" 2>&1; rc=$?
      printf "%s exited: command ended (exit %s)\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$CR_T/events.log"' >/dev/null 2>&1 &
    echo $! >"$d/pid.tmp"; disown || true)
  local pid; pid="$(cat "$d/pid.tmp")"; rm -f "$d/pid.tmp"
  meta_set "$id" pid "$pid"
  echo "command worker running (pid $pid)"
}

command_launch() { command_run "$1" "$2" "$(task_prompt "$1")"; }
command_live() { headless_live "$1"; }
command_steer() { # <id> <msg> [--inbox]
  local id="$1" msg="$2" inbox="${3:-}"
  if pid_alive "$(meta "$id" pid)"; then
    if [[ "$inbox" == --inbox ]]; then
      printf -- '- %s %s\n' "$(now)" "$msg" >>"$(tdir "$id")/inbox.md"
      log_event "$id" steered "(inbox) $msg"
      echo "appended to inbox.md (best effort: the worker must read it)"; return 0
    fi
    die "command worker is mid-run; it takes input between runs. Wait for its stop, 'chartroom stop $id', or 'chartroom steer $id --inbox <msg>'."
  fi
  log_event "$id" steered "$msg"
  command_run "$id" "$(meta "$id" worktree)" "$msg" "$msg"
}
command_stop() { headless_stop "$1"; }
command_peek() { echo "== output (recent)"; tail -n "$2" "$(tdir "$1")/output.log" 2>/dev/null; return 0; }
command_close() { headless_close "$1"; }
command_attach() { die "command workers have no terminal; use 'chartroom peek $1'"; }
command_watch() { pid_watch "$1"; }
