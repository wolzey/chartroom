# shellcheck shell=bash
# hc runner: workers in herdr-core terminals (`hc`), shown in the Herdr app (`herdr-app`).
# Verified against hc 0.1.14 and herdr-app 0.1.9 (skills/chartroom/references/backends.md).
#
# One hc terminal per task, named after the task id, started in the worktree from chartroom's
# launcher: hc gives a terminal the core's environment, not the caller's, so the launcher
# carries chartroom's PATH, CHARTROOM_HOME and CHARTROOM_TASK. The brief's one-line prompt is
# `hc run`'s task argument, which the launcher hands to the agent as its first prompt: nothing
# is typed into a booting agent.
#
# The app shows a terminal that carries herdr.space=<id> (and herdr.tab=<id>), creating a
# space or tab it does not know, without moving the person's focus (space.new would show the
# new space at once). So each worker is labelled for the space named $CHARTROOM_WORKSPACE and a
# fresh tab of its own; the names come from space.rename / tab.rename while the app runs. With
# the window closed the labels still place the worker; its names follow at the next dispatch
# or attach. A closed tab or space goes when its last terminal ends.
#
# Workers start with --no-parent (and --no-notify, which says the same): they outlive the XO's
# session, never hang off whatever terminal HC_TERMINAL_ID names (it leaks into processes
# started from one, other homes' XOs included), and hc types no notes into the XO; chartroom's
# own wake stream reports them. hc tracks Claude's state itself (OSC 7501, verified), so, as on
# herdr, claude gets only the prompt hook. Codex keeps its notify hook for turn ends (whether hc
# sees Codex's turns is unverified); hc still reports a blocked, failed or lost one. The
# terminal's address is recorded and every later call checks it still carries the task's name.

declare -A HC_TURNS=() # watch: each task's hc turn count at the last look

hc_bin() {
  local b; b="$(bin_of hc)"
  [[ -z "$b" && -x "$HOME/.local/bin/hc" ]] && b="$HOME/.local/bin/hc"
  printf '%s' "$b"
}
# chartroom talks to hc as itself, never as the terminal it may run in: with $HC_TERMINAL_ID set,
# hc tags what it sends `<hc from="t16">...</hc>` (verified), which tells the worker to report
# into that terminal and is not the text the XO sent.
hcx() { env -u HC_TERMINAL_ID "$(hc_bin)" "$@"; }
# herdr-app with a subcommand only: bare `herdr-app` opens the window. Fails (2) without a window.
happ() { local b; b="$(bin_of herdr-app)"; [[ -n "$b" ]] || return 2; "$b" "$@"; }

# The core's socket, found without starting a core (every hc command, `hc ls` and even
# `hc server status`, starts one when none answers). $HC_SOCKET, else the path the core keeps
# in its lock file, else $HC_TERMINAL_SOCKET (set inside hc terminals).
hc_socket() {
  local s="${HC_SOCKET:-}" lock
  if [[ -z "$s" ]]; then
    lock="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/${HC_SESSION:-default}/core.lock"
    [[ -f "$lock" ]] && s="$(head -1 "$lock")"
  fi
  printf '%s' "${s:-${HC_TERMINAL_SOCKET:-}}"
}
# A socket file left by a crashed core is no running core, so connect to it first.
sock_answers() { # <path>
  [[ -S "$1" ]] || return 1
  command -v perl >/dev/null 2>&1 || return 0
  perl -MIO::Socket::UNIX -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 1)' "$1"
}

hc_probe() {
  [[ "$CR_PLATFORM" != msys || -n "${CHARTROOM_HC_ANY_OS:-}" ]] || { echo "hc on Windows is unverified (CHARTROOM_HC_ANY_OS=1 to try it)"; return 1; }
  [[ -n "$(hc_bin)" ]] || { echo "hc (herdr-core) not on PATH"; return 1; }
  local s; s="$(hc_socket)"
  sock_answers "$s" || { echo "herdr-core not running (no live socket${s:+ at $s}; open Herdr or run hc server start)"; return 1; }
  hcx server status --json 2>/dev/null | jq -e '.version' >/dev/null 2>&1 || { echo "herdr-core not reachable at $s"; return 1; }
  return 0
}
hc_steer_mode() { echo live; }
hc_handle_set() { [[ -n "$(meta "$1" hc_terminal)" ]]; }

# One look at the task's terminal: HC_STATE (live; finished; replaced: live, but no longer running
# the task's launcher, because hc's keep (which the app turns on) put a shell in place of a lost
# program, under the same address and name (verified); gone: no terminal at the address, or one
# that no longer carries the task's name), HC_STATUS (working, idle, done, blocked, error, or
# empty before the agent reports) and HC_TURN.
hc_info() { # <id>
  local t j name ours
  HC_STATE=gone; HC_STATUS=""; HC_TURN=0
  t="$(meta "$1" hc_terminal)"; [[ -n "$t" ]] || return 0
  HC_ADDR_TASK[$t]="$1"
  if [[ -n "$HCS_UP" && -n "${HCT_STATE[$t]+x}" ]]; then
    # The watch's event stream already holds this terminal (hc_stream_drain): no `hc get`.
    HC_STATE="${HCT_STATE[$t]}"; HC_STATUS="${HCT_STATUS[$t]}"; HC_TURN="${HCT_TURN[$t]}"; name="${HCT_NAME[$t]}"
    ours=false; [[ "${HCT_LIDS[$t]}" == *" $1 "* ]] && ours=true
  else
    HC_ASKED=1
    if ! j="$(hcx get "$t" --json 2>/dev/null)"; then hc_stream_settle "$t" gone; return 0; fi
    # (the launcher by its task's path suffix: the home may be spelled another way, via a symlink)
    IFS='|' read -r HC_STATE HC_STATUS HC_TURN name ours < <(jq -r --arg l "/tasks/$1/launch.sh" '[.state // "gone", .status.state // "", .turn // 0, .name // "", any((.argv // [])[]; tostring | endswith($l))] | map(tostring) | join("|")' <<<"$j" 2>/dev/null) || true
    [[ "$HC_STATE" != finished || "$name" != "$1" ]] || hc_stream_settle "$t" finished "$name" "$HC_TURN"
  fi
  [[ -n "$HC_STATE" && "$name" == "$1" ]] || { HC_STATE=gone; HC_STATUS=""; HC_TURN=0; hc_stream_settle "$t" gone; return 0; }
  [[ "$HC_STATE" == live && "$ours" != true ]] && { HC_STATE=replaced; HC_STATUS=""; }
  [[ "$HC_TURN" =~ ^[0-9]+$ ]] || HC_TURN=0
  return 0
}
hc_alive() { hc_info "$1"; [[ "$HC_STATE" == live ]]; }
hc_screen() { hcx read "$(meta "$1" hc_terminal)"; }
hc_keys() {
  local id="$1" t k; shift; t="$(meta "$id" hc_terminal)"
  for k in "$@"; do
    [[ "$k" == clear ]] && k=ctrl+u
    hcx keys "$t" "$k" >/dev/null; sleep 0.3
  done
}
hc_has_prompt_hook() { [[ "$(backend_agent "$1")" == claude ]] && jq -e '.hooks.UserPromptSubmit' "$(tdir "$1")/claude-settings.json" >/dev/null 2>&1; }

# The tab's name in the app: the short id and the title, e.g. "28b7 · Fix the login".
hc_tab_name() { # <id>
  local s t
  s="$(short_ids_json | jq -r --arg i "$1" '.[$i] // $i')"; t="$(meta "$1" title)"
  (( ${#t} > 40 )) && t="${t:0:39}…"
  printf '%s%s' "$s" "${t:+ · $t}"
}

# The crew's space id: the one a live worker of this workspace is labelled with (hc's own
# record, so it holds with the window closed), else the app's space of that name, else a new id
# (the app makes the space when it adopts the first terminal labelled with it). Sets HC_SPACE,
# and HC_SPACE_NEW=1 for a new one.
hc_space() {
  local t
  HC_SPACE=""; HC_SPACE_NEW=""
  t="$(hcx ls --json --label "chartroom.workspace=$CR_WORKSPACE" 2>/dev/null | jq -r '.terminals[0].address // empty' 2>/dev/null || true)"
  [[ -n "$t" ]] && HC_SPACE="$(hcx get "$t" --json 2>/dev/null | jq -r '.labels["herdr.space"] // empty' 2>/dev/null || true)"
  [[ -n "$HC_SPACE" ]] || HC_SPACE="$(happ ls 2>/dev/null | jq -r --arg n "$CR_WORKSPACE" '[.spaces[]? | select(.name == $n and .machine == null) | .id][0] // empty' 2>/dev/null || true)"
  [[ -n "$HC_SPACE" ]] || { HC_SPACE="sp$(new_uuid | tr -d -)"; HC_SPACE_NEW=1; }
}

# Names the crew's space and this task's tab in the app, once it has adopted the terminal.
# Returns 1 when no window answers (nothing to name now).
hc_name_layout() { # <id>
  local id="$1" sp tab want l="" i
  sp="$(meta "$id" hc_space)"; tab="$(meta "$id" hc_tab)"; want="$(hc_tab_name "$id")"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    l="$(happ ls 2>/dev/null)" || return 1
    jq -e --arg t "$tab" 'any(.spaces[]?.tabs[]?; .id == $t)' <<<"$l" >/dev/null 2>&1 && break
    sleep 0.5
  done
  # The crew's space carries the workspace's name, unless another space already does.
  if jq -e --arg s "$sp" --arg n "$CR_WORKSPACE" 'any(.spaces[]?; .id == $s and .name != $n) and (any(.spaces[]?; .name == $n) | not)' <<<"$l" >/dev/null 2>&1; then
    happ "do" space.rename --id "$sp" --name "$CR_WORKSPACE" >/dev/null 2>&1 || true
  fi
  if jq -e --arg t "$tab" --arg n "$want" 'any(.spaces[]?.tabs[]?; .id == $t and .name != $n)' <<<"$l" >/dev/null 2>&1; then
    happ "do" tab.rename --id "$tab" --name "$want" >/dev/null 2>&1 || true
  fi
  return 0
}

# A live terminal named <id> is left over from an earlier start of this task (a dispatch that
# failed after `hc run`). It is ended only if it is the terminal chartroom recorded for this
# task, never finished its launch and is not mid-turn; anything else is not chartroom's to end.
hc_clear_stale() { # <id>
  local id="$1" t st i
  t="$(hcx ls --json 2>/dev/null | jq -r --arg n "$id" '[.terminals[]? | select(.name == $n and .state == "live") | .address][0] // empty' 2>/dev/null || true)"
  [[ -n "$t" ]] || return 0
  [[ "$t" == "$(meta "$id" hc_terminal)" ]] || die "an hc terminal named $id ($t) already runs, which chartroom did not record for this task; end it (hc kill $t), then dispatch again"
  hc_info "$id"; st="${HC_STATUS:-starting}"
  if [[ "$HC_STATE" == replaced ]]; then st="a shell in place of its lost agent"
  else [[ "$(meta "$id" hc_launched)" != 1 ]] || die "the worker for $id is live in hc terminal $t; steer it, or close it (chartroom close $id) before dispatching again"; fi
  [[ "$st" != working ]] || die "the hc terminal for $id is already working ($t); steer it, or end it (hc kill $t) and dispatch again"
  hcx kill "$t" >/dev/null 2>&1 || die "could not end the stale hc terminal $t for $id"
  for i in $(seq 1 20); do hc_info "$id"; [[ "$HC_STATE" =~ ^(live|replaced)$ ]] || break; sleep 0.25; done
  hcx rm "$t" >/dev/null 2>&1 || true
  log_event "$id" note "ended the stale hc terminal $t left by an earlier start ($st)"
}

# Signs that the agent took a prompt, short of its text: hc's status or a turn since <turn>
# (after hc_info), an agent or worker event since <offset>, or a working agent's screen
# (Codex: "esc to interrupt").
hc_took_prompt() { # <id> <events.log offset> <turn before>
  local new scr
  [[ "$HC_STATUS" == working || "$HC_TURN" -gt "$3" ]] && return 0
  new="$(tail -c +"$(($2 + 1))" "$(tdir "$1")/events.log")"
  grep -qE ' agent: (prompt-received|turn-ended)| (progress|waiting|decision|blocked|done|failed): ' <<<"$new" && return 0
  scr="$(hc_screen "$1" 2>/dev/null || true)"
  grep -qiE 'esc to interrupt|working \(' <<<"$scr"
}

# The brief went in with the launch, so this only watches for it: 0 when claude's prompt hook
# reports its signature, 2 when the agent took a prompt but its text cannot be checked, 1 when
# the terminal ended or nothing showed in time.
hc_confirm_brief() { # <id> <text> <events.log offset before launch>
  local id="$1" text="$2" before="$3" want="" i new
  hc_has_prompt_hook "$id" && want="$(printf '%s' "$text" | text_sig)"
  for i in $(seq 1 $((CR_DELIVER_WAIT * 4))); do
    if [[ -n "$want" ]]; then
      new="$(tail -c +"$((before + 1))" "$(tdir "$id")/events.log")"
      grep -q " agent: prompt-received sig=$want " <<<"$new" && return 0
    fi
    hc_info "$id"
    [[ "$HC_STATE" == live ]] || return 1
    [[ -z "$want" ]] && hc_took_prompt "$id" "$before" 0 && return 2
    sleep 1
  done
  hc_took_prompt "$id" "$before" 0 && return 2
  return 1
}

hc_launch() { # <id> <wt> <agent>
  local id="$1" wt="$2" agent="$3" argv=() launcher task tab out t before rc=0
  hc_clear_stale "$id"; meta_set "$id" hc_launched ""
  # Claude starts under a session id of chartroom's choosing, fresh each dispatch, so a parked
  # worker can be resumed (lib/park.sh).
  if [[ "$agent" == claude ]]; then
    meta_set "$id" session_id "$(new_uuid)"
    mapfile -t argv < <(interactive_argv "$id" "$agent" prompt session)
  else
    mapfile -t argv < <(interactive_argv "$id" "$agent" 1)
  fi
  # hc's manual: codex needs --no-daemon under hc, or its commands run outside hc.
  [[ "$agent" == codex ]] && argv+=(--no-daemon)
  launcher="$(write_launcher "$id" "$wt" --forward "${argv[@]}")"
  task="$(task_prompt "$id")"
  hc_space; tab="tb$(new_uuid | tr -d -)"
  before="$(wc -c <"$(tdir "$id")/events.log")"
  out="$(hcx run --bg --json --no-parent --no-notify --name "$id" --cwd "$wt" \
    --label "herdr.space=$HC_SPACE" --label "herdr.tab=$tab" \
    --label "chartroom.workspace=$CR_WORKSPACE" --label "chartroom.task=$id" \
    -- "${BASH:-bash}" "$launcher" "$task" 2>&1)" || die "hc run failed: $out"
  t="$(jq -r '.address // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$t" ]] || die "hc run gave no terminal address: $out"
  meta_set "$id" hc_terminal "$t"; meta_set "$id" hc_space "$HC_SPACE"; meta_set "$id" hc_tab "$tab"
  [[ -z "$HC_SPACE_NEW" ]] || log_event "$id" note "hc: new space $HC_SPACE for $CR_WORKSPACE (the app makes it when it adopts this terminal)"
  hc_name_layout "$id" || log_event "$id" note "hc: no Herdr window answers; the labels place the worker in $CR_WORKSPACE once the app opens, and chartroom attach names its tab"
  # A dialog chartroom will not answer leaves the worker waiting with its brief queued as its
  # first prompt: the awaiting-input event wakes the XO, and the brief starts once it is answered.
  if ! handle_trust "$id" "$agent" hc_screen hc_keys; then
    meta_set "$id" hc_launched 1
    echo "hc $agent worker waiting at a startup dialog chartroom will not answer: answer it in Herdr (chartroom attach $id); it starts on the brief once answered"
    return 0
  fi
  hc_confirm_brief "$id" "$task" "$before" || rc=$?
  [[ $rc -eq 1 ]] && die "the $agent worker did not take the brief (hc terminal $t is $HC_STATE); check: chartroom peek $id"
  [[ $rc -eq 2 ]] && log_event "$id" note "the agent took a prompt, but its text could not be checked ($agent has no prompt hook)"
  meta_set "$id" hc_launched 1
  echo "hc $agent worker running (space $CR_WORKSPACE, tab $(hc_tab_name "$id"), terminal $t)"
}

hc_live() {
  hc_handle_set "$1" || { echo not-started; return; }
  hc_info "$1"
  if [[ "$HC_STATE" == live ]]; then
    case "$HC_STATUS" in
      working|idle|done|blocked) echo "$HC_STATUS" ;;
      error) echo blocked ;;
      *) hook_state "$1" ;; # no report yet: starting (or a dialog its events name)
    esac
  elif [[ "$HC_STATE" != replaced ]] && exited_since_dispatch "$1"; then echo stopped
  else echo gone; fi
}

# Send and confirm the agent took it: 0 confirmed, 2 taken but text unchecked, 1 failed.
# `hc send` pastes the text and presses Enter once nobody is typing, and says whether that
# started a turn. Claude workers carry the prompt hook, so the submitted text's signature is
# checked as for herdr; a mismatch clears the input (ctrl+u) and sends again, at most 3 times.
# Without the hook, hc's word or the agent's own signs (hc_took_prompt) count, and text still
# sitting in the input box gets Enter, not a second copy. A blocked agent (a permission or
# question dialog) is never typed into: hc refuses without --force, and so does this.
hc_deliver() { # <id> <text>
  local id="$1" text="$2" t f i k before out rc want="" got="" new mismatches=0 n started tb scr resend=1
  t="$(meta "$id" hc_terminal)"; f="$(tdir "$id")/events.log"
  hc_has_prompt_hook "$id" && want="$(printf '%s' "$text" | text_sig)"
  for i in 1 2 3 4 5; do
    before="$(wc -c <"$f")"; hc_info "$id"; tb="$HC_TURN"
    if [[ $resend -eq 0 ]]; then hcx keys "$t" enter >/dev/null 2>&1 || true; out='{}'; rc=0
    else rc=0; out="$(hcx send "$t" --json "$text" 2>&1)" || rc=$?; fi
    case "$rc" in
      0) ;;
      9) die "the agent is blocked at a dialog (a permission or a question); answer it first (chartroom attach $id), then steer again" ;;
      3|11) return 1 ;;
      *) sleep 2; continue ;;
    esac
    started="$(jq -r '.started // false' <<<"$out" 2>/dev/null || echo false)"
    if [[ -n "$want" ]]; then
      got=""
      for k in $(seq 1 "$CR_DELIVER_WAIT"); do
        sleep 1
        new="$(tail -c +"$((before + 1))" "$f")"
        grep -q " agent: prompt-received sig=$want " <<<"$new" && return 0
        got="$(grep -oE ' agent: prompt-received sig=[0-9a-f]+ len=[0-9]+' <<<"$new" | tail -1 || true)"
      done
      if [[ -n "$got" ]]; then
        # More text than was sent is not a fragment: sending again would run it twice.
        if (( ${got##*len=} > ${#text} )); then
          log_event "$id" note "delivery unverified: the agent received a longer text (${got#* agent: prompt-received }; expected sig=$want len=${#text}); not sent again"
          return 2
        fi
        mismatches=$((mismatches + 1))
        log_event "$id" note "delivery mismatch: the agent received other text (${got#* agent: prompt-received }; expected sig=$want len=${#text}); clearing its input and retrying"
        [[ $mismatches -ge 3 ]] && return 1
        n=$(( ${#text} / 60 + 3 )); while (( n-- > 0 )); do hcx keys "$t" ctrl+u >/dev/null 2>&1 || true; done
        continue
      fi
    fi
    # No hook, or no word from it: hc's account of the send, or the agent's own signs.
    sleep 1; hc_info "$id"
    [[ "$started" == true ]] && return 2
    hc_took_prompt "$id" "$before" "$tb" && return 2
    [[ "$HC_STATE" == live ]] || return 1
    scr="$(hc_screen "$id" 2>/dev/null || true)"
    if grep -qF -- "${text:0:30}" <<<"$scr"; then resend=0; else resend=1; fi
    sleep 1
  done
  return 1
}

hc_steer() {
  local id="$1" msg="$2" text rc=0
  hc_alive "$id" || die "the hc terminal for $id is gone; re-dispatch it"
  log_event "$id" steered "$msg"
  text="$(steer_text "$id" "$msg")"
  hc_deliver "$id" "$text" || rc=$?
  steer_result "$id" "$msg" "$text" "$rc"
}
hc_stop() {
  local out
  hc_alive "$1" || return 0
  out="$(hcx interrupt "$(meta "$1" hc_terminal)" --json 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null || true)"
  [[ -n "$out" ]] && log_event "$1" note "hc interrupt: $out"
  return 0
}
hc_peek() { # <id> <n>
  local id="$1" n="$2" d; d="$(tdir "$id")"
  echo "== terminal (recent)"
  hc_info "$id"
  if [[ "$HC_STATE" != gone ]]; then hcx read "$(meta "$id" hc_terminal)" --lines "$((n * 3))" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n "$((n * 2))" || true
  elif [[ -f "$d/pane.log" ]]; then grep -v '^[[:space:]]*$' "$d/pane.log" | tail -n "$((n * 2))" || true; fi
  return 0
}

# Ends the terminal (its screen and history kept in <task>/pane.log) and removes its record.
# The app drops a pane whose terminal ends and a tab whose last pane goes, window open or not.
# A tab still listed afterwards holds someone else's terminal (a split), so it stays.
hc_close() {
  local id="$1" t tab i
  t="$(meta "$id" hc_terminal)"; [[ -n "$t" ]] || return 0
  hc_info "$id"
  [[ "$HC_STATE" == gone ]] && return 0
  hcx read "$t" --lines 2000 >>"$(tdir "$id")/pane.log" 2>/dev/null || true
  if [[ "$HC_STATE" =~ ^(live|replaced)$ ]]; then
    hcx kill "$t" >/dev/null 2>&1 || true
    for i in $(seq 1 20); do hc_info "$id"; [[ "$HC_STATE" =~ ^(live|replaced)$ ]] || break; sleep 0.25; done
  fi
  if [[ "$HC_STATE" == finished ]]; then hcx rm "$t" >/dev/null 2>&1 || true; fi
  tab="$(meta "$id" hc_tab)"
  for i in 1 2 3 4; do
    happ ls 2>/dev/null | jq -e --arg t "$tab" 'any(.spaces[]?.tabs[]?; .id == $t)' >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  log_event "$id" note "hc: its Herdr tab is still open with another terminal in it; left as it is"
  return 0
}

hc_attach() {
  local id="$1" t; t="$(meta "$id" hc_terminal)"
  hc_alive "$id" || die "the hc terminal for $id is gone"
  if happ ls >/dev/null 2>&1; then
    hc_name_layout "$id" || true
    happ "do" agent.focus --terminal "$t" >/dev/null || die "herdr-app could not show terminal $t"
    echo "showing $id in Herdr (space $CR_WORKSPACE, terminal $t)"
  elif [[ -t 0 && -t 1 ]]; then
    exec "$(hc_bin)" attach "$t"
  else
    die "no Herdr window answers: open Herdr (the worker is in space $CR_WORKSPACE), or run hc attach $t in a terminal (ctrl+\\ detaches)"
  fi
}

# Wakes from hc's own state, polled with the watch loop (HST: the last status seen per task;
# HC_TURNS: the turn count then, so a whole turn between two looks still counts).
hc_watch_word() { # <id> -> sets W (working|idle|done|blocked|error|starting|replaced|gone|parked)
  # A parked worker has no terminal to ask. Its turn count starts again from 0, so the revived
  # terminal's first finished turn counts (lib/park.sh).
  if [[ -n "$(meta "$1" parked)" ]]; then W=parked; HC_TURN=0; return 0; fi
  hc_info "$1"
  case "$HC_STATE" in live) W="${HC_STATUS:-starting}" ;; replaced) W=replaced ;; *) W=gone ;; esac
}
hc_watch_seed() { local W; hc_watch_word "$1"; HST[$1]="$W"; HC_TURNS[$1]="$HC_TURN"; }
hc_watch() { # <id>
  local id="$1" W prev pturn
  hc_handle_set "$id" || return 0
  hc_watch_word "$id"
  prev="${HST[$id]:-}"; pturn="${HC_TURNS[$id]:-}"
  if [[ "$W" != "$prev" || ( "$W" =~ ^(idle|done)$ && -n "$pturn" && "$HC_TURN" -gt "$pturn" ) ]]; then
    case "$W" in
      blocked) wake "$id" "hc: agent is waiting on an approval or question prompt" ;;
      error) wake "$id" "hc: agent reported an error; read its screen (chartroom peek $id)" ;;
      # (Codex: its notify's `agent: turn-ended` wakes through the event stream instead.)
      idle|done)
        if [[ "$prev" == working || ( -n "$pturn" && "$HC_TURN" -gt "$pturn" ) ]] && [[ "$(backend_agent "$id")" != codex ]] && ! reported_since_dispatch "$id"; then
          wake "$id" "hc: agent stopped its turn without reporting"
        fi ;;
      # An agent that exited on its own wrote `exited` (the launcher), which wakes by itself.
      gone) [[ -n "$prev" && "$prev" != replaced ]] && ! exited_since_dispatch "$id" && wake "$id" "lost: hc terminal $(meta "$id" hc_terminal) is no longer running" ;;
      replaced) [[ -n "$prev" && "$prev" != gone ]] && wake "$id" "lost: the agent in hc terminal $(meta "$id" hc_terminal) is gone (hc put a shell in its place); chartroom close $id ends it" ;;
    esac
  fi
  HST[$id]="$W"; HC_TURNS[$id]="$HC_TURN"
  return 0
}
# (A revive starts a new run as a dispatch does: the launcher's `exited` of the parked one is history.)
exited_since_dispatch() { # <id>
  awk '($2=="note:" && ($3=="dispatched" || $3=="revived")) { e=0 } $2=="exited:" { e=1 } END { exit e ? 0 : 1 }' "$(tdir "$1")/events.log"
}

# ---------------------------------------------------------------- park / revive (lib/park.sh)

# Ends the terminal of a worker at rest, keeping its session: the screen goes to pane.log, the
# park is recorded (meta parked, the note) before the terminal ends, so nothing reads its end as
# a lost worker, and the terminal is removed (the app drops its tab). hc_terminal, hc_space and
# hc_tab stay, for the revive. 1 (park undone) when the terminal would not end.
hc_park() { # <id> <session id> <state>
  local id="$1" t i up
  t="$(meta "$id" hc_terminal)"
  hcx read "$t" --lines 2000 >>"$(tdir "$id")/pane.log" 2>/dev/null || true
  meta_set "$id" parked "$(now)"
  log_event "$id" note "parked (session $2; $3, its agent at rest): steer or attach resumes it"
  hcx kill "$t" >/dev/null 2>&1 || true
  # The end is hc's own word: in the watch's round the event stream's view moves only between
  # rounds, so it would still say live (as in hc_stream_check).
  up="${HCS_UP:-}"; HCS_UP=""
  for i in $(seq 1 20); do hc_info "$id"; [[ "$HC_STATE" =~ ^(live|replaced)$ ]] || break; sleep 0.25; done
  HCS_UP="$up"
  if [[ "$HC_STATE" =~ ^(live|replaced)$ ]]; then
    meta_set "$id" parked ""
    log_event "$id" note "park undone: hc terminal $t did not end"
    PARK_WHY="hc terminal $t did not end"
    return 1
  fi
  [[ "$HC_STATE" == finished ]] && { hcx rm "$t" >/dev/null 2>&1 || true; }
  return 0
}

# Up, with no prompt (an attach): 0 once the agent reports a state or shows its empty prompt
# box, 1 if the terminal ends first or nothing shows in time.
hc_wait_ready() { # <id>
  local id="$1" i scr
  for i in $(seq 1 $((CR_DELIVER_WAIT * 4))); do
    hc_info "$id"
    [[ "$HC_STATE" == live ]] || return 1
    [[ -n "$HC_STATUS" ]] && return 0
    scr="$(hc_screen "$id" 2>/dev/null | tail -n 15 | sed $'s/\xc2\xa0/ /g' || true)"
    grep -qE '^[❯>] *$' <<<"$scr" && return 0
    sleep 0.5
  done
  return 1
}

# Resumes a parked worker in a fresh terminal: the same worktree, launcher settings, labels and
# tab name, running `claude --resume <session id>`, with <text> as its first prompt (as a dispatch
# passes the brief), confirmed by the prompt hook; with no text (an attach), once it is up.
# 0 confirmed, 2 taken but unchecked, 1 failed (logged as revive failed; the task stays parked).
hc_revive() { # <id> [text]
  local id="$1" text="${2:-}" wt sid argv=() launcher out t tab before rc=0 why scr code args=()
  wt="$(meta "$id" worktree)"; sid="$(meta "$id" session_id)"
  [[ -n "$sid" ]] || { revive_failed "$id" "no session id is recorded"; return 1; }
  [[ -n "$wt" && -d "$wt" ]] || { revive_failed "$id" "its worktree ${wt:-(none)} is gone"; return 1; }
  why="$(hc_probe 2>&1)" || { revive_failed "$id" "$why"; return 1; }
  mapfile -t argv < <(interactive_argv "$id" claude prompt resume)
  launcher="$(write_launcher "$id" "$wt" --forward "${argv[@]}")"
  HC_SPACE="$(meta "$id" hc_space)"; [[ -n "$HC_SPACE" ]] || hc_space
  tab="$(meta "$id" hc_tab)"; [[ -n "$tab" ]] || tab="tb$(new_uuid | tr -d -)"
  before="$(wc -c <"$(tdir "$id")/events.log")"
  [[ -n "$text" ]] && args=("$text")
  out="$(hcx run --bg --json --no-parent --no-notify --name "$id" --cwd "$wt" \
    --label "herdr.space=$HC_SPACE" --label "herdr.tab=$tab" \
    --label "chartroom.workspace=$CR_WORKSPACE" --label "chartroom.task=$id" \
    -- "${BASH:-bash}" "$launcher" "${args[@]+"${args[@]}"}" 2>&1)" || { revive_failed "$id" "hc run failed: $out"; return 1; }
  t="$(jq -r '.address // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$t" ]] || { revive_failed "$id" "hc run gave no terminal address: $out"; return 1; }
  meta_set "$id" hc_terminal "$t"; meta_set "$id" hc_space "$HC_SPACE"; meta_set "$id" hc_tab "$tab"
  hc_name_layout "$id" || true
  if [[ -n "$text" ]]; then hc_confirm_brief "$id" "$text" "$before" || rc=$?
  else hc_wait_ready "$id" || rc=1; fi
  # Resumed means this session: a fresh one would report another id to the prompt hook.
  if [[ $rc -ne 1 && "$(meta_file "$id" session_id)" != "$sid" ]]; then
    rc=1; why="claude started session $(meta_file "$id" session_id), not $sid"
    meta_set "$id" session_id "$sid"
  fi
  if [[ $rc -eq 1 ]]; then
    hc_info "$id"
    if [[ -z "${why:-}" ]]; then
      scr="$(hcx read "$t" --lines 40 2>/dev/null | grep -m1 -iE 'no conversation found|error|not found' || true)"
      code="$(hcx get "$t" --json 2>/dev/null | jq -r '.exit_code // empty' 2>/dev/null || true)"
      why="claude --resume did not come up in hc terminal $t ($HC_STATE${code:+, exit $code})${scr:+: $scr}"
    fi
    if [[ "$HC_STATE" == finished ]]; then hcx rm "$t" >/dev/null 2>&1 || true
    elif [[ "$HC_STATE" =~ ^(live|replaced)$ ]]; then hcx kill "$t" >/dev/null 2>&1 || true; sleep 0.5; hcx rm "$t" >/dev/null 2>&1 || true; fi
    revive_failed "$id" "$why"
    return 1
  fi
  meta_set "$id" parked ""; meta_set "$id" hc_launched 1
  log_event "$id" note "revived (session $sid, hc terminal $t) for $([[ -n "$text" ]] && echo steer || echo attach)"
  return "$rc"
}

# ---------------------------------------------------------------- the watch's event stream
# While a watch runs, one `hc events --json --label chartroom.workspace=<workspace>` carries hc's
# state of the crew's terminals instead of a `hc get` per task per round (verified with hc 0.1.16
# and Claude Code 2.1.318). Its first line is a snapshot of the matching terminals, with all that
# hc_info reads (name, argv, state, status, turn); then one `event` line per change: `status`
# (the agent's own idle/working/done/blocked), `turn` (once the status leaves working),
# `created`, `lost` followed by `restarted` (keep put a shell in place: the new argv) or by
# `finished`, and `removed`; `heartbeat` every 15 s; `missed` then a fresh snapshot for a reader
# that fell behind. `lost` alone changes nothing chartroom reads, so it is left out: what follows
# it says whether the agent is replaced or finished.
# A coprocess runs it through one long-lived jq, which turns each line into one fact (fields
# split by \x1f):
#   S <seq>, then T per terminal, then E      a snapshot
#   T <address> <state> <status> <turn> <name> < launcher task ids >   created/restarted too
#   U <address> <status>   N <address> <turn>   F <address> (finished)   R <address> (removed)
#   M  missed (the snapshot that follows replaces the view)   H  heartbeat
# and rings the watch's doorbell for each but H. The watch takes them between rounds with bash's
# own read (no fork) into HCT_* (hc_stream_drain), hc_info answers from there, and only the tasks
# whose terminal changed are compared (hc_stream_wakes). The coprocess writes heartbeats too, so
# once the watch is gone, even killed outright, its next write fails and it ends.
HCS_PID="" HCS_FD="" HCS_UP="" HCS_SNAP="" HCS_DOWN="" HCS_FAILS=0 HCS_RETRY=0
HC_ASKED="" # set when hc_info had to ask hc (`hc get`): the watch keeps that task on its fast round
declare -A HCT_STATE=() HCT_STATUS=() HCT_TURN=() HCT_NAME=() HCT_LIDS=() HCS_SEEN=() HC_HIT=() HC_ADDR_TASK=()
# shellcheck disable=SC2016
HC_STREAM_JQ='
  def f: tostring | gsub("[\t\n\u001f]"; " ");
  def ids: " " + ([(.argv // [])[] | tostring | capture("/tasks/(?<id>[^/]+)/launch\\.sh$")? | .id] | join(" ")) + " ";
  def rec: ["T", .address, (.state // "gone"), (.status.state? // ""), (.turn // 0), (.name // ""), ids] | map(f) | join("\u001f");
  def snap($p): ["S\u001f\($p.seq // 0)"] + [$p.terminals[]? | rec] + ["E"];
  foreach (inputs | fromjson? | select(type == "object")) as $l ({s: -1, out: []};
    if ($l.terminals | type) == "array" then {s: ($l.seq // 0), out: snap($l)}
    elif ($l.params.terminals? | type) == "array" then {s: ($l.params.seq // 0), out: snap($l.params)}
    elif $l.method == "heartbeat" then .out = ["H"]
    elif $l.method == "missed" then .out = ["M"]
    elif $l.method == "event" then
      $l.params as $p
      | if ($p.seq // 0) <= .s then .out = []
        else .out = [
          if $p.type == "created" or $p.type == "restarted" then $p.data + {address: ($p.data.address // $p.terminal)} | rec
          elif $p.type == "status" then "U\u001f\($p.terminal | f)\u001f\($p.data.status.state? // "" | f)"
          elif $p.type == "turn" then "N\u001f\($p.terminal | f)\u001f\($p.data.turn // 0 | f)"
          elif $p.type == "finished" then "F\u001f\($p.terminal | f)"
          elif $p.type == "removed" then "R\u001f\($p.terminal | f)"
          else empty end] end
    else .out = [] end;
    .out[])'

hc_stream_ring() { { read -r -t 0 -u "$BELL_FD" || printf . >&"$BELL_FD"; } 2>/dev/null || true; }
# The coprocess. Once the watch is gone (even killed outright), the next line it writes, a
# heartbeat at the latest (15 s), fails, and it ends hc and jq with itself.
hc_stream_pump() { # <hc binary>
  local line in p
  exec {in}< <(env -u HC_TERMINAL_ID "$1" events --json --label "chartroom.workspace=$CR_WORKSPACE" 2>/dev/null |
    jq -R -n -r --unbuffered "$HC_STREAM_JQ" 2>/dev/null)
  p=$!
  trap '' PIPE # (that failed write returns here instead of killing this before it cleans up)
  while IFS= read -r line <&"$in"; do
    printf '%s\n' "$line" 2>/dev/null || break
    [[ "$line" == H ]] || hc_stream_ring
  done
  hc_stream_kill "$p"
  hc_stream_ring
}
hc_stream_kill() { # <pid>: it and everything below it, the deepest first
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do hc_stream_kill "$c"; done
  kill -TERM "$1" 2>/dev/null || true
}
# Starts the stream if it can run: a doorbell to ring (without one the watch polls as before),
# and a core that answers, so the watch never starts one (any hc command would).
hc_stream_open() {
  local hc w
  hc_stream_close
  [[ -n "$BELL_FD" ]] || return 1
  hc="$(hc_bin)"; [[ -n "$hc" ]] || return 1
  sock_answers "$(hc_socket)" || return 1
  coproc HCS_CO { exec </dev/null 2>/dev/null; hc_stream_pump "$hc"; }
  HCS_PID="$HCS_CO_PID"
  exec {HCS_FD}<&"${HCS_CO[0]}" # bash closes a coprocess's own fds when it reaps it
  w="${HCS_CO[1]}"; exec {w}>&-
  return 0
}
# (The watch's EXIT trap passes "exiting", in a string shellcheck 0.9.0 does not read.)
# shellcheck disable=SC2120
hc_stream_close() { # [exiting]
  if [[ -n "$HCS_PID" ]]; then
    hc_stream_kill "$HCS_PID"
    [[ -n "${1:-}" ]] || wait "$HCS_PID" 2>/dev/null || true
  fi
  if [[ -n "$HCS_FD" ]]; then exec {HCS_FD}<&-; fi
  HCS_PID="" HCS_FD="" HCS_UP="" HCS_SNAP=""
  return 0
}
hc_stream_set() { # <address> <state> <status> <turn> <name> <launcher ids>
  local a="$1" t="$4"
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  if [[ -n "${HCT_STATE[$a]+x}" && "${HCT_STATE[$a]}|${HCT_STATUS[$a]}|${HCT_TURN[$a]}|${HCT_NAME[$a]}|${HCT_LIDS[$a]}" == "$2|$3|$t|$5|$6" ]]; then return 0; fi
  HCT_STATE[$a]="$2"; HCT_STATUS[$a]="$3"; HCT_TURN[$a]="$t"; HCT_NAME[$a]="$5"; HCT_LIDS[$a]="$6"; HC_HIT[$a]=1
}
# A terminal the stream does not carry that hc says has ended (finished, or not there: the core
# answers, since the stream is up): final, so it goes into the stream's view and the watch stops
# asking about it, as it would for one the stream reported ending.
hc_stream_settle() { # <address> <finished|gone> [name] [turn]
  [[ -n "$HCS_UP" && -z "${HCT_STATE[$1]+x}" ]] || return 0
  HCT_STATE[$1]="$2"; HCT_STATUS[$1]=""; HCT_TURN[$1]="${4:-0}"; HCT_NAME[$1]="${3:-}"; HCT_LIDS[$1]=" "
}
hc_stream_forget() { # <address>: no longer in the stream (hc_info asks hc again)
  unset "HCT_STATE[$1]" "HCT_STATUS[$1]" "HCT_TURN[$1]" "HCT_NAME[$1]" "HCT_LIDS[$1]"; HC_HIT[$1]=1
}
# Takes every fact the stream has sent so far, without waiting. At its end (the core stopped or
# restarted, `hc update`) the stream is closed and HCS_DOWN set: the watch runs a full round at
# once, then polls every CHARTROOM_WATCH_INTERVAL until a new stream's snapshot is in.
hc_stream_drain() {
  [[ -n "$HCS_FD" ]] || return 0
  local line k a x y z n l
  while read -r -t 0 -u "$HCS_FD"; do
    if ! IFS= read -r -u "$HCS_FD" line; then hc_stream_close; HCS_DOWN=1; return 0; fi
    IFS=$'\x1f' read -r k a x y z n l <<<"$line"
    case "$k" in
      S) HCS_SNAP=1; HCS_SEEN=() ;;
      T)
        if [[ -n "$HCS_SNAP" ]]; then HCS_SEEN[$a]=1; fi
        hc_stream_set "$a" "$x" "$y" "$z" "$n" "$l" ;;
      E)
        for a in "${!HCT_STATE[@]}"; do [[ -n "${HCS_SEEN[$a]+x}" ]] || hc_stream_forget "$a"; done
        HCS_SNAP=""; HCS_SEEN=(); HCS_UP=1; HCS_FAILS=0 ;;
      U)
        if [[ -n "${HCT_STATE[$a]+x}" && "${HCT_STATUS[$a]}" != "$x" ]]; then
          # hc counts a turn each time the status leaves working, and says so in a `turn` line
          # right after this one; counted here already, so a watch that wakes on this line and
          # exits (--once) leaves its cursor at the turn hc will report, not one behind it.
          if [[ "${HCT_STATUS[$a]}" == working && -n "$x" ]]; then HCT_TURN[$a]=$((HCT_TURN[$a] + 1)); fi
          HCT_STATUS[$a]="$x"; HC_HIT[$a]=1
        fi ;;
      N) if [[ -n "${HCT_STATE[$a]+x}" && "$x" =~ ^[0-9]+$ && "${HCT_TURN[$a]}" != "$x" ]]; then HCT_TURN[$a]="$x"; HC_HIT[$a]=1; fi ;;
      F) if [[ -n "${HCT_STATE[$a]+x}" ]]; then HCT_STATE[$a]=finished; HCT_STATUS[$a]=""; HC_HIT[$a]=1; fi ;;
      R) if [[ -n "${HCT_STATE[$a]+x}" ]]; then HCT_STATE[$a]=gone; HCT_STATUS[$a]=""; HC_HIT[$a]=1; fi ;;
      M) HCS_UP="" ;; # until the snapshot that follows: hc_info asks hc
    esac
  done
  return 0
}
# The stream's changes since the last look, compared by hc_watch for each task they touch, as a
# full round would (between rounds: the round compares every task itself).
hc_stream_wakes() {
  local a id metas=()
  local -A ids=()
  (( ${#HC_HIT[@]} > 0 )) || return 0
  for a in "${!HC_HIT[@]}"; do
    id="${HC_ADDR_TASK[$a]:-${HCT_NAME[$a]:-}}"
    if [[ -n "$id" && "$id" != */* && -f "$CR_HOME/tasks/$id/meta.json" ]]; then ids[$id]=1; metas+=("$CR_HOME/tasks/$id/meta.json"); fi
  done
  HC_HIT=()
  (( ${#metas[@]} > 0 )) || return 0
  meta_cache_load "${metas[@]}"
  for id in "${!ids[@]}"; do
    is_closed "$id" && continue
    [[ "$(backend_runner "$id")" == hc && -n "$(meta "$id" dispatched)" ]] || continue
    hc_watch "$id"
    # (a waiting window that ran out while the agent worked: overdue once it stops)
    [[ -z "${WAIT_DUE[$id]+x}" ]] || watch_overdue "$id"
  done
  MC=()
  return 0
}
# The slow round's own look at a terminal the stream holds, for one that ended without an event
# (the brief's one allowed slowdown). It only ever ends a terminal in the stream's view (finished,
# gone, or replaced by a shell), never moves its status, so an event still on its way cannot make
# the same change wake twice.
hc_stream_check() { # <id>
  local t up="$HCS_UP"
  t="$(meta "$1" hc_terminal)"
  [[ -n "$HCS_UP" && -n "$t" && -n "${HCT_STATE[$t]+x}" ]] || return 0
  HCS_UP=""; hc_info "$1"; HCS_UP="$up"
  case "$HC_STATE" in
    gone|finished) [[ "${HCT_STATE[$t]}" == "$HC_STATE" ]] || { HCT_STATE[$t]="$HC_STATE"; HCT_STATUS[$t]=""; } ;;
    replaced) [[ "${HCT_LIDS[$t]}" != *" $1 "* ]] || { HCT_LIDS[$t]=" "; HCT_STATUS[$t]=""; } ;;
  esac
  return 0
}
