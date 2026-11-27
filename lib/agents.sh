# shellcheck shell=bash
# agents.sh - how to start each agent CLI, independent of where it runs.
#
# Agents: claude (Claude Code), codex (Codex CLI), agy (Antigravity CLI), grok (xAI's Grok Build).
# Every function here prints arguments one per line so callers can `mapfile` them without
# word-splitting.

KNOWN_AGENTS='claude|codex|agy|grok'

# agy runs only as a full session: in hc, in herdr, or on a node's hc. Its headless mode (-p) is
# not a worker (the commander's rule: workers run as full sessions), and the generic tmux/cmux
# path reads Claude's and Codex's screens, not agy's.
AGY_RUNNERS='hc|herdr|node'
# grok likewise (lib/agents.sh, grok section): full sessions only, never headless.
GROK_RUNNERS='hc|herdr|node'
agent_runs_on() { # <agent> <runner>: 0 when chartroom runs that agent on that runner
  case "$1" in
    agy) [[ "$2" =~ ^($AGY_RUNNERS)$ ]] ;;
    grok) [[ "$2" =~ ^($GROK_RUNNERS)$ ]] ;;
    *) return 0 ;;
  esac
}

# (agy installs itself in ~/.local/bin, which a GUI launcher's PATH may lack; grok's installer
# puts it in ~/.grok/bin and links it from ~/.local/bin when that is on PATH)
agent_bin() {
  local b; b="$(bin_of "$1")"
  [[ -z "$b" && "$1" == agy && -x "$HOME/.local/bin/agy" ]] && b="$HOME/.local/bin/agy"
  if [[ -z "$b" && "$1" == grok ]]; then
    if [[ -x "$HOME/.local/bin/grok" ]]; then b="$HOME/.local/bin/grok"
    elif [[ -x "$HOME/.grok/bin/grok" ]]; then b="$HOME/.grok/bin/grok"; fi
  fi
  printf '%s' "$b"
}

# ---------------------------------------------------------------- agy (Antigravity CLI)
#
# Verified on agy 1.5.17 with hc 0.1.21 (skills/chartroom/references/backends.md). agy reports its
# state over OSC 7501, which hc reads as Claude's: working, idle, done, and blocked (kind
# permission or question) at a trust dialog, an approval or a question; hc counts its turns and
# refuses to type into a blocked agy (exit 9). So an agy worker needs no hooks for chartroom to see
# it. Its one chartroom hook is the pattern kill guard (agy_guard_hooks). What chartroom does not
# give it: no permission cards, grants or holds (its own approvals come up as
# `agent: awaiting-input`), its prompts are not checked against their text (no prompt hook), and
# it is never parked (no session id chartroom picks to resume).
AGY_LIMITS="only the pattern-kill guard hook: its own approvals wake the XO as awaiting-input, but no permission cards or grants; steers are taken but not checked against their text; never parked (no resume)"

# The pattern kill guard for agy: agy loads hooks.json from the .agents folder of each workspace
# folder, and the task's folder is one (agy_args --add-dir), so chartroom writes it there, never in
# the worktree. Rewritten at every launch. Verified on agy 1.5.18: a hook there runs with no trust
# prompt, gets toolCall {name: run_command, args.CommandLine}, and {decision: deny, reason} blocks
# the command ("tool call denied by pre-tool hook: <reason>"); no output lets it run as before.
agy_guard_hooks() { # <id>
  local d; d="$(tdir "$1")/.agents"
  mkdir -p "$d"
  jq -n --arg c "CHARTROOM_HOME=$(printf '%q' "$CR_HOME") $(printf '%q' "$CR_BIN") hook $1 guard" \
    '{"chartroom-guard": {PreToolUse: [{matcher: "run_command", hooks: [{type: "command", command: $c, timeout: 30}]}]}}' >"$d/hooks.json"
}

# Signed in? `agy models` lists the account's models, or says "Please sign in" and exits 1 at once
# (it never opens a browser or waits). Asked once per process. Empty: signed in.
# agy keeps its sign-in in a Mac's login keychain, which is closed to an ssh session (a command
# from a client home runs in one): there `agy models` says "Please sign in" though agy is signed
# in (verified on agy 1.5.18). So from an ssh session it is asked inside the hc core (`hc exec`, a
# core started in the login session, where workers run too), as lib/nodeprobe.sh asks logins; with
# no core answering, a Mac says it cannot tell rather than "not signed in".
AGY_LOGIN_WHY="" AGY_LOGIN_ASKED=""
agy_login_why() {
  if [[ -z "$AGY_LOGIN_ASKED" ]]; then
    local b out rc=0 run=()
    AGY_LOGIN_ASKED=1; b="$(agent_bin agy)"
    if [[ -n "${CHARTROOM_GATE:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
      if hc_probe >/dev/null 2>&1; then run=(env -u HC_TERMINAL_ID "$(hc_bin)" exec --timeout 20 --)
      elif [[ "$(uname -s)" == Darwin ]]; then run=(none); fi
    fi
    if [[ -z "$b" ]]; then AGY_LOGIN_WHY="agy not on PATH"
    elif [[ "${run[0]:-}" == none ]]; then
      AGY_LOGIN_WHY="agy's sign-in cannot be read from an ssh session (macOS keeps the login keychain closed there) and no hc core answers to ask in the login session: open Herdr, or run chartroom doctor on this machine itself"
    else
      if [[ ${#run[@]} -gt 0 ]]; then out="$(cd / && "${run[@]}" "$b" models </dev/null 2>&1)" || rc=$? # (hc bounds it)
      elif command -v perl >/dev/null 2>&1; then out="$(cd / && perl -e 'alarm shift; exec @ARGV or exit 127' 20 "$b" models </dev/null 2>&1)" || rc=$?
      else out="$(cd / && "$b" models </dev/null 2>&1)" || rc=$?; fi
      if [[ $rc -ne 0 ]]; then
        if grep -qi 'sign in' <<<"$out"; then AGY_LOGIN_WHY="agy is not signed in here (run agy once in a terminal and finish its Google sign-in)"
        else AGY_LOGIN_WHY="agy models failed (exit $rc): $(grep -v '^Fetching' <<<"$out" | head -1 | cut -c1-120)"; fi
      fi
    fi
  fi
  [[ -z "$AGY_LOGIN_WHY" ]] || { printf '%s' "$AGY_LOGIN_WHY"; return 1; }
}

# agy's flags for a task: its model (task_model) and effort, its mode (meta permission: auto, accept-edits or
# plan; empty is agy's own default: auto on the Macs seen; on a Linux one it asked even with auto), and the task's folder as a workspace directory, by its
# real path (agy compares resolved paths: a folder given through a symlink, as macOS's /tmp is,
# reads as outside the workspace, and each write there asks).
agy_args() { # <id>
  local m e p
  m="$(task_model "$1" agy)"; e="$(meta "$1" effort)"; p="$(meta "$1" permission)"
  [[ -n "$m" ]] && printf '%s\n' --model "$m"
  [[ -n "$e" ]] && printf '%s\n' --effort "$e"
  if [[ -n "$p" ]]; then
    [[ "$p" =~ ^(auto|accept-edits|plan)$ ]] || die "agy has no permission mode '$p' (its modes: auto, accept-edits, plan)"
    printf '%s\n' --mode "$p"
  fi
  agy_guard_hooks "$1"
  printf '%s\n' --add-dir "$(phys_dir "$(tdir "$1")")"
}

# ---------------------------------------------------------------- grok (xAI's Grok Build)
#
# Built against grok 1.0.92 and its own docs (~/.grok/docs/user-guide; references/backends.md).
# grok reports its state over OSC 7501 to Herdr 2, which hc is (verified in hc 0.1.21: a grok
# at its sign-in screen reads `blocked`, kind auth, "Sign in to Grok"; its docs: working, waiting
# on an approval, a question or a sign-in, done, failed). So, as for agy, hc sees its prompts and
# counts its turns, and herdr starts it itself (`--kind grok`, herdr 0.9.5). It is a crew agent
# only when a task's --backend names it: grok is in no default order (the commander picks it).
# What chartroom does not give it: no permission cards, grants or holds (its own approvals come up
# as `agent: awaiting-input`), its prompts are not checked against their text (no prompt hook), and
# it is never parked (grok can resume a session by id, but chartroom's park is Claude's only).
GROK_LIMITS="only the pattern-kill guard hook: its own approvals wake the XO as awaiting-input, but no permission cards or grants; steers are taken but not checked against their text; never parked (chartroom does not resume grok sessions); it also runs your own Claude hooks (grok reads ~/.claude/settings.json)"

# The pattern kill guard for grok. grok loads hooks only from user-wide places (~/.grok/hooks/*.json,
# ~/.grok/hooks-paths, config.toml, the Claude and Cursor files) and from the project itself, never
# from an --add-dir folder, and a GROK_CONFIG overlay may not add hooks. So chartroom keeps one file of
# its own in ~/.grok/hooks, rewritten at every grok launch, whose command does nothing unless the
# launcher's CHARTROOM_TASK is set: the commander's own grok sessions are untouched, and nothing
# goes in the worktree. grok sends PreToolUse {toolName: run_terminal_command, toolInput.command}
# and takes {hookSpecificOutput.permissionDecision: deny} (its docs, 10-hooks.md); it runs a user
# hook only in a folder it trusts, which a chartroom worktree is (--trust, grok_args). One side effect
# on a machine that had no user hook for grok before (no ~/.grok/hooks, no hooks in ~/.claude/settings.json):
# grok's docs say that while any user hook exists, its folder trust asks in every new folder, the
# commander's own sessions there included.
grok_guard_file() { printf '%s/hooks/chartroom-guard.json' "${GROK_HOME:-$HOME/.grok}"; }
grok_guard_hooks() {
  local f c
  f="$(grok_guard_file)"; mkdir -p "${f%/*}"
  c="[ -n \"\${CHARTROOM_TASK:-}\" ] || exit 0; exec $(printf '%q' "$CR_BIN") hook - guard"
  jq -n --arg c "$c" '{hooks: {PreToolUse: [{matcher: "run_terminal_command", hooks: [{type: "command", command: $c, timeout: 30}]}]}}' >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# Signed in? `grok models` lists the models, headed "You are not authenticated." when there is no
# sign-in (exit 0 either way; grok 1.0.92). It never opens a browser: a grok session started signed
# out does (its sign-in screen), which is why a launch asks first. grok keeps its sign-in in
# ~/.grok/auth.json, a file (its docs, 02-authentication.md), not the macOS keychain, so unlike agy
# an ssh session reads it as the login session does. Asked once per process. Empty: signed in.
GROK_SIGN_IN="grok login in a terminal on this machine and finish the browser sign-in, or grok login --device-auth over ssh"
GROK_LOGIN_WHY="" GROK_LOGIN_ASKED=""
grok_login_why() {
  if [[ -z "$GROK_LOGIN_ASKED" ]]; then
    local b out rc=0
    GROK_LOGIN_ASKED=1; b="$(agent_bin grok)"
    if [[ -z "$b" ]]; then GROK_LOGIN_WHY="grok not on PATH"
    else
      if command -v perl >/dev/null 2>&1; then out="$(cd / && perl -e 'alarm shift; exec @ARGV or exit 127' 20 "$b" models </dev/null 2>&1)" || rc=$?
      else out="$(cd / && "$b" models </dev/null 2>&1)" || rc=$?; fi
      if grep -qi 'not authenticated' <<<"$out"; then GROK_LOGIN_WHY="grok is not signed in here (run $GROK_SIGN_IN)"
      elif [[ $rc -ne 0 ]]; then GROK_LOGIN_WHY="grok models failed (exit $rc): $(grep -v '^[[:space:]]*$' <<<"$out" | head -1 | cut -c1-120)"; fi
    fi
  fi
  [[ -z "$GROK_LOGIN_WHY" ]] || { printf '%s' "$GROK_LOGIN_WHY"; return 1; }
}

# grok's flags for a task: its model (-m) and effort (--reasoning-effort), its permission mode (meta
# permission, in grok's own words: default, acceptEdits, auto, dontAsk, bypassPermissions, plan;
# empty is grok's own default, auto in its terminal UI), --trust for a worktree chartroom created itself (the
# folder trust its dialog would ask for, which chartroom answers only for its own worktrees: any
# other folder's dialog is the commander's; grok records the trust for the repository's main
# checkout, seen live, so the commander's own grok sessions there skip the dialog too), and no
# update check. No --add-dir for the task folder:
# grok 1.0.92 refuses one ("additionalDirectories is not supported: a session works only in its
# cwd") and the session never starts. Its sandbox is off by default, so the worker reaches its brief,
# report and event helper by their paths, as its permission mode allows. The update check:
# grok checks for one at each launch ([cli] auto_update), and a worker must not stop for it, as
# Codex's would (--no-auto-update is the per-session switch; grok's own sessions still update).
# A launch asks this first, in its own shell: a die inside grok_args (read through `mapfile < <(...)`)
# would not stop it.
grok_mode_check() { # <id>
  local p; p="$(meta "$1" permission)"
  [[ -z "$p" || "$p" =~ ^(default|acceptEdits|auto|dontAsk|bypassPermissions|plan)$ ]] || die "grok has no permission mode '$p' (its modes: default, acceptEdits, auto, dontAsk, bypassPermissions, plan)"
}
grok_args() { # <id>
  local m e p
  printf '%s\n' --no-auto-update
  m="$(task_model "$1" grok)"; e="$(meta "$1" effort)"; p="$(meta "$1" permission)"
  [[ -n "$m" ]] && printf '%s\n' -m "$m"
  [[ -n "$e" ]] && printf '%s\n' --reasoning-effort "$e"
  if [[ -n "$p" ]]; then grok_mode_check "$1"; printf '%s\n' --permission-mode "$p"; fi
  [[ "$(meta "$1" worktree_created)" == 1 ]] && printf '%s\n' --trust
  grok_guard_hooks
}

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

# The model a task's worker runs: its own (new --model), else the home's default for its agent
# (CHARTROOM_CODEX_MODEL, CHARTROOM_AGY_MODEL), else nothing (the agent's own default). Claude's
# default stays Claude's.
task_model() { # <id> <agent>
  local m; m="$(meta "$1" model)"
  if [[ -z "$m" ]]; then
    case "$2" in codex) m="$CR_CODEX_MODEL" ;; agy) m="$CR_AGY_MODEL" ;; esac
  fi
  printf '%s' "$m"
}

codex_model_args() { # <id>
  local m e
  m="$(task_model "$1" codex)"; e="$(meta "$1" effort)"
  [[ -n "$m" ]] && printf '%s\n' -m "$m"
  [[ -n "$e" ]] && printf '%s\n' -c "model_reasoning_effort=$e"
  return 0
}

# Codex calls `notify` with a JSON argument when a turn completes; chartroom turns
# that into an `agent: turn-ended` event (no screen scraping).
codex_notify_args() { # <id>
  printf '%s\n' -c "notify=[\"$CR_BIN\",\"hook\",\"$1\",\"codex-notify\"]"
}

# The pattern kill guard for Codex (pattern_kill): a per-run PreToolUse hook on Bash that runs
# `chartroom hook - guard`, the guard alone (no permission broker: that is Claude's). Codex runs a
# per-run hook only once it is trusted, and keeps that trust by the hook's own text ("/<session-
# flags>/config.toml:pre_tool_use:0:0" and its hash in ~/.codex/config.toml), so the text names no
# task: the hook reads it from CHARTROOM_TASK, which the launcher exports. Its first launch on a
# machine (per home) shows "Hooks need review" once; the commander trusts it there, and every later
# worker starts without the dialog. Verified on codex-cli 0.160.0: tool_name Bash,
# tool_input.command, and the deny is honored.
codex_guard_args() {
  local cmd
  cmd="CHARTROOM_HOME=$(printf '%q' "$CR_HOME") $(printf '%q' "$CR_BIN") hook - guard"
  printf '%s\n' -c "hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=$(jq -n --arg c "$cmd" '$c')}]}]"
}

# Claude Code hooks for interactive sessions (tmux, cmux): turn end, approval/idle
# prompts and prompt receipt become events. Written per task, loaded with --settings, and
# rewritten at every launch and resume, so an edit to the file does not outlive the session.
# "prompt" mode (herdr, which tracks turn state itself) adds only UserPromptSubmit, so
# delivery can be checked against the submitted text without doubling herdr's wakes.
# "headless" (claude -p) has its own turn signals and gets only the permission hooks.
# Every mode carries the permission broker (lib/permit.sh): PreToolUse on every tool (the pattern
# kill guard and the policy's guards, grants and holds), PermissionRequest (a prompt becomes a
# card) and PermissionDenied (auto mode's refusals are recorded). Their timeout outlasts the card's
# wait, so chartroom always answers before Claude would give up on the hook: a PreToolUse hook that
# times out does not block the call.
claude_settings_file() { # <id> [all|prompt|headless] -> path
  local id="$1" mode="${2:-all}" f h
  f="$(tdir "$id")/claude-settings.json"
  h="CHARTROOM_HOME=$(printf '%q' "$CR_HOME") $(printf '%q' "$CR_BIN") hook $id"
  # Commit and PR attribution off, on every machine (the commander's rule r-cb1b): no Co-Authored-By trailer
  # and no "Generated with" line, whatever the machine's own Claude settings say.
  # A device's guest worker (lib/guest.sh) gets its task folder here rather than by --add-dir:
  # the flag makes Claude ask to add a folder it has not seen, and a guest home is new to it, while
  # a settings file's additional directory is taken as it is (see claude_common_args)
  jq -n --arg stop "$h stop" --arg notif "$h notification" --arg sub "$h prompt-submit" --arg pre "$h pre-tool" \
    --arg guest "${CHARTROOM_GUEST:-}" --arg tdir "$(tdir "$id")" \
    --arg perm "$h permission" --arg denied "$h denied" --arg mode "$mode" --argjson wait "$((CR_PERMIT_WAIT + 60))" '{includeCoAuthoredBy: false, attribution: {commit: "", pr: ""}} + (if $guest == "1" then {permissions: {additionalDirectories: [$tdir]}} else {} end) + {hooks:(
    (if $mode == "all" then {Stop:[{hooks:[{type:"command",command:$stop}]}],
      Notification:[{hooks:[{type:"command",command:$notif}]}]} else {} end)
    + (if $mode != "headless" then {UserPromptSubmit:[{hooks:[{type:"command",command:$sub}]}]} else {} end)
    + {PreToolUse:[{hooks:[{type:"command",command:$pre,timeout:$wait}]}],
       PermissionRequest:[{hooks:[{type:"command",command:$perm,timeout:$wait}]}],
       PermissionDenied:[{hooks:[{type:"command",command:$denied,timeout:30}]}]})}' >"$f"
  printf '%s' "$f"
}

# A worker that stops processes by name or pattern stops the commander's and other workers'
# too (their dev servers match the same pattern), so the Bash tool refuses it: pkill, killall,
# or a kill fed by pgrep, pidof or ps | grep ($(...), backticks, xargs). kill <pid> is fine.
PATTERN_KILL_ADVICE="chartroom blocked this: pkill, killall and a kill fed by pgrep or ps | grep stop every process that matches, the commander's and other workers' too. Stop only processes you started, by their PID, or your own port's listener (lsof -ti tcp:<port> -sTCP:LISTEN)."

# 0 when <command line> runs a pattern kill. It reads the line as commands split at ; & | ( ) { }
# backticks and newlines (a quoted script after `-c` or `eval` too), each named by its first word
# past VAR=value, or by any later word after sudo, env, xargs, do, then and the like. A quoted
# mention (grep pkill, a commit message) is not a command. Not a shell parser: a script file is
# not read, and a quoted mention after a ; or a newline (a heredoc's line) can read as a command.
pattern_kill() { # <command line>
  local seg runs=" " w i
  local -a words
  while IFS= read -r seg; do
    read -ra words <<<"$seg"
    i=0
    while [[ $i -lt ${#words[@]} && "${words[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do i=$((i + 1)); done
    [[ $i -lt ${#words[@]} ]] || continue
    if [[ "${words[i]##*/}" =~ ^(sudo|doas|exec|command|builtin|env|nohup|nice|time|timeout|setsid|watch|xargs|do|then|else|!)$ ]]; then
      for w in "${words[@]:i+1}"; do runs+="${w##*/} "; done
    else
      runs+="${words[i]##*/} "
    fi
  done < <(sed -E "s/(^|[[:space:]])(-[[:alpha:]]*c|eval)[[:space:]]+[\"']/\\1;/g" <<<"$1" | tr ';&|(){}`' '\n\n\n\n\n\n\n\n')
  [[ "$runs" == *" pkill "* || "$runs" == *" killall "* ]] && return 0
  [[ "$runs" == *" kill "* ]] || return 1
  [[ "$runs" == *" pgrep "* || "$runs" == *" pidof "* || ( "$runs" == *" ps "* && "$runs" == *" grep "* ) ]]
}

claude_common_args() { # <id> <permission-mode or "">
  local m perm="$2"
  m="$(meta "$1" model)"
  [[ -n "$m" ]] && printf '%s\n' --model "$m"
  [[ -n "$perm" ]] && printf '%s\n' --permission-mode "$perm"
  # (a device's guest worker has it in its settings file instead: claude_settings_file)
  [[ "${CHARTROOM_GUEST:-}" == 1 && "$(backend_runner "$1")" =~ ^($SESSION_RUNNERS)$ ]] || printf '%s\n' --add-dir "$(tdir "$1")"
}

# Full argv (one per line) for an interactive agent session. <hooks:1|0|prompt>
# <session> (claude): "session" starts the session under meta session_id (--session-id),
# "resume" resumes it (--resume), so a parked worker can be brought back (lib/park.sh).
interactive_argv() { # <id> <agent> <hooks> [session|resume]
  local id="$1" agent="$2" hooks="$3" ses="${4:-}" b
  b="$(agent_bin "$agent")"; [[ -n "$b" ]] || die "$agent not on PATH"
  printf '%s\n' "$b"
  case "$agent" in
    claude)
      local perm sid; perm="$(meta "$id" permission)"
      if [[ -n "$ses" ]]; then
        sid="$(meta "$id" session_id)"; [[ -n "$sid" ]] || die "no session id recorded for $id"
        if [[ "$ses" == resume ]]; then printf '%s\n' --resume "$sid"; else printf '%s\n' --session-id "$sid"; fi
      fi
      claude_common_args "$id" "${perm:-$CR_CLAUDE_PERMISSION}"
      [[ "$hooks" == 1 ]] && printf '%s\n' --settings "$(claude_settings_file "$id")"
      [[ "$hooks" == prompt ]] && printf '%s\n' --settings "$(claude_settings_file "$id" prompt)"
      ;;
    codex)
      # Interactive codex otherwise self-updates on launch and exits, losing the brief.
      printf '%s\n' -c check_for_update_on_startup=false
      codex_sandbox_args "$id"; codex_model_args "$id"; codex_guard_args
      [[ "$hooks" == 1 ]] && codex_notify_args "$id"
      ;;
    agy) agy_args "$id" ;; # (only the guard hook: hc and herdr read its state themselves)
    grok) grok_args "$id" ;; # (likewise: hc and herdr read its state; its one hook is the guard)
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
#
# Codex then asks about hooks: "Hooks need review" for any project or per-run hook it has not
# seen, in each new worktree (its trust is by path, and hooks run outside the sandbox), and once
# per machine for chartroom's own guard (codex_guard_args) until the commander trusts it. chartroom
# never trusts one. By default the dialog goes to the XO as `agent: awaiting-input`; with
# CHARTROOM_CODEX_HOOKS_DIALOG=skip it takes Esc in a worktree chartroom created, which starts
# the agent without those hooks.

trust_dialog_up() { grep -qiE 'trust this folder|do you trust' <<<"$1"; }

# Claude's dialog to add a directory it has not worked in (an --add-dir: chartroom gives a worker
# its task's folder that way): the folder it names, or nothing.
adddir_dialog_path() { # <screen> (the last such dialog in it)
  awk '/Adding a new directory:/ { if ((getline line) > 0) { sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line); p = line } } END { if (p != "") print p }' <<<"$1"
}
# The same, for a dialog whose header has scrolled off a short terminal (its options still show):
# read from the runner's recent history when it has one (<runner>_history: hc, tmux).
adddir_dialog_path_of() { # <runner> <id> <screen>
  local p; p="$(adddir_dialog_path "$3")"
  if [[ -z "$p" ]] && grep -qE '(❯|›) *Yes, add it|^ *Yes, add it' <<<"$3" && declare -F "$1_history" >/dev/null; then
    p="$(adddir_dialog_path "$("$1_history" "$2" 2>/dev/null || true)")"
  fi
  printf '%s' "$p"
}
adddir_dialog_up() { grep -qE '(❯|›)? *Yes, add it' <<<"$1"; } # <screen>
# A folder of a task that chartroom made itself: its record's folder, or the worktree it created.
own_task_folder() { # <id> <path>
  local d; d="$(tdir "$1")"
  [[ "$2" == "$d" || "$2" == "$(cd "$d" 2>/dev/null && pwd -P)" ]] && return 0
  [[ "$(meta "$1" worktree_created)" == 1 && -n "$(meta "$1" worktree)" && "$2" == "$(meta "$1" worktree)" ]]
}

# Prints the keys to send (space-separated, runner-neutral names: down enter), or nothing.
trust_answer_keys() { # <agent> <screen>
  local agent="$1" screen="$2"
  case "$agent" in
    claude)
      if grep -qE '❯ *No, exit' <<<"$screen"; then echo "down enter"
      elif grep -qE '❯ *Yes, I trust' <<<"$screen"; then echo "enter"; fi ;;
    codex)
      grep -qE '› *1\. *Trust and continue' <<<"$screen" && echo "enter" ;;
    # agy (1.5.17): "Do you trust the contents of this project?", the cursor an ASCII ">" on
    # "Yes, I trust this folder" (the first of two), "↑/↓ Navigate · enter Confirm" below.
    agy)
      if grep -qE '^ *> *Yes, I trust this folder' <<<"$screen"; then echo "enter"
      elif grep -qE '^ *> *No, exit' <<<"$screen"; then echo "up enter"; fi ;;
  esac
  return 0
}

# Shared by every session runner. <id> <agent> <screen-fn> <keys-fn>
# screen-fn <id> prints the visible screen; keys-fn <id> <key>... sends named keys.
# 1: a dialog is up that chartroom will not answer, raised as `agent: awaiting-input`.
handle_trust() {
  local id="$1" agent="$2" screen_fn="$3" keys_fn="$4" i scr keys what
  for i in 1 2 3 4 5 6 7 8; do
    scr="$("$screen_fn" "$id" 2>/dev/null || true)"
    # Adding a folder: answered only for the task's own folders, which chartroom made (a device's
    # guest home is new to its Claude, so its task folder is asked about there)
    local add=""
    if adddir_dialog_up "$scr"; then
      add="$(adddir_dialog_path_of "${screen_fn%_screen}" "$id" "$scr")"
      [[ -n "$add" ]] || { log_event "$id" agent "awaiting-input: a dialog to add a folder chartroom could not read; a human must answer it"; return 1; }
    fi
    if [[ -n "$add" ]]; then
      if ! own_task_folder "$id" "$add"; then
        log_event "$id" agent "awaiting-input: a dialog to add $add, a folder chartroom did not make; a human must answer it"
        return 1
      fi
      if grep -qE '❯ *No, exit' <<<"$scr"; then keys="down enter"
      elif grep -qE '❯ *Yes, add it' <<<"$scr"; then keys=enter
      else log_event "$id" agent "awaiting-input: unrecognised dialog to add $add; left for a human"; return 1; fi
      # shellcheck disable=SC2086
      "$keys_fn" "$id" $keys
      log_event "$id" note "added its own folder $add when $agent asked (chartroom made it)"
      sleep 3
      return 0
    fi
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
    # (Before the prompt-box check below: a dialog's own "› 1. ..." line looks like the prompt box.)
    what="$(screen_prompt "$id" "$agent" "$scr")"
    if [[ -n "$what" ]]; then
      if [[ "$what" == *'"Hooks need review"'* && "$CR_CODEX_HOOKS_DIALOG" == skip && "$(meta "$id" worktree_created)" == 1 ]]; then
        "$keys_fn" "$id" esc
        log_event "$id" note "continued past Codex's \"Hooks need review\" dialog without those hooks (CHARTROOM_CODEX_HOOKS_DIALOG=skip): they do not run for this worker"
        sleep 1
        continue
      fi
      prompt_sync "$id" "$what"
      return 1
    fi
    # The agent's main UI is up (prompt box) - no dialog this time.
    grep -qE '(^|[[:space:]])(❯|›|>)[[:space:]]' <<<"$scr" && [[ $i -ge 3 ]] && return 0
    sleep 1
  done
  return 0
}

# The dialogs of a start, one after another: Codex shows folder trust, then its hooks dialog once
# that is answered. 1: one is up that chartroom will not answer (raised by handle_trust).
startup_dialogs() { # <id> <agent> <screen-fn> <keys-fn>
  local i
  for i in 1 2 3; do
    handle_trust "$@" || return 1
    [[ -n "$(screen_prompt "$1" "$2" "$("$3" "$1" 2>/dev/null || true)")" ]] || return 0
  done
  return 1
}
