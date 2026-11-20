# shellcheck shell=bash
# marks.sh - `chartroom remove|restore|done|removed`: take items of work out of every view at once,
# or mark them done, instantly and in bulk, without touching them.
#
# A mark lives in the store (lib/store.py marks) and names an item: a task (its id), an inbox item
# (i-xxxx) or an artifact (<owner>/<slug>). It works the same on an item born as files (a task's
# meta.json, a line in inbox.md, an artifact's sidecar) and one born in the store, and no file is
# ever written: removing a task never touches its worktree, branch, session or record, so unlanded
# work stays exactly where it is (close and sweep keep their own guards). The verbs work whether or
# not the home's switch is on: the first mark gives the home its store id.
#
# One call takes many refs (the app's multi-select). Every ref is resolved and checked first, then
# every one that can be applied is, in one transaction; each ref succeeds or fails on its own, and
# the failures are reported by ref (exit 1 when any failed). A remove can be undone with restore
# for 30 days (lib/store.py RESTORE_DAYS); after that the item stays hidden.
#
# Readers leave removed items out (status, board, todo, inbox list, artifact list, the watch's
# wakes) and take a done mark as done; sweep still sees removed tasks, so their processes are
# never taken for orphans.

MARKS_EMPTY='{"task":{},"inbox":{},"artifact":{}}'

# The home's marks as JSON ({task, inbox, artifact}: ref -> {removed, by, why, done}).
marks_json() {
  if store_load && [[ -s "$STORE_D/.marks.json" ]]; then cat "$STORE_D/.marks.json"; else echo "$MARKS_EMPTY"; fi
}
# Is this task removed? (the watch's wakes; one jq, from this process's read of the store)
task_removed() { # <id>
  store_load && [[ -s "$STORE_D/.marks.json" ]] || return 1
  jq -e --arg id "$1" '.task[$id].removed != null' "$STORE_D/.marks.json" >/dev/null 2>&1
}
# Does this home keep its marks in the store? (a store id, or the switch on): then todo done and
# artifact done mark an item instead of editing its file.
marks_in_store() { store_on || { store_uid_of; [[ -n "$STORE_UID" ]]; }; }

# A ref into MK_KIND (task|inbox|artifact) and MK_REF (the full ref the mark is kept under), or
# MK_WHY when it names nothing. Removed and closed items resolve too (restore needs them).
mark_resolve() { # <ref>
  local q="$1" owner slug o
  MK_KIND="" MK_REF="" MK_WHY=""
  q="$(sed -E 's/^[[:space:]]*\[?//; s/\]?[[:space:]]*$//' <<<"$q")"
  if [[ "$q" == */* ]]; then
    owner="${q%%/*}"; slug="$(tr '[:upper:]' '[:lower:]' <<<"${q#*/}")"; slug="${slug%.md}"; slug="${slug%.html}"
    o="$(artifact_owner "$owner" 2>&1)" || { MK_WHY="${o#chartroom: }"; return 1; }
    [[ -f "$(artifact_dir "${o%% *}" "${o#* }")/$slug.json" ]] || { MK_WHY="no artifact $slug on $owner"; return 1; }
    MK_KIND=artifact MK_REF="${o#* }/$slug"; return 0
  fi
  q="$(tr '[:upper:]' '[:lower:]' <<<"$q")"
  if [[ "$q" =~ ^i-[0-9a-f]{4,}$ ]] && ! task_exists "$q"; then
    if grep -qE "^- \[$q\] " "$CR_HOME/inbox.md" 2>/dev/null ||
       { store_load && jq -e --arg q "$q" 'any(.[]; .id == $q)' "$STORE_D/.inbox.json" >/dev/null 2>&1; }; then
      MK_KIND=inbox MK_REF="$q"; return 0
    fi
    MK_WHY="no inbox item $q"; return 1
  fi
  if task_exists "$q"; then MK_KIND=task MK_REF="$q"; return 0; fi
  local t; t="$(jq -r --arg q "$q" '[to_entries[] | select(.value == $q) | .key] | if length == 1 then .[0] else empty end' <<<"$(short_ids_json)")"
  [[ -n "$t" ]] && { MK_KIND=task MK_REF="$t"; return 0; }
  MK_WHY="not a task, inbox item or artifact"; return 1
}

# A live worker: anything but these (lib/session.sh and the runners' _live words).
MARK_AT_REST='stopped|gone|not-started|parked|done|unknown|-'

# Its worker ended so the task can be removed: parked when it can be (steer or attach resumes it),
# else its runner's session closed (the worktree, branch and record stay as they are).
mark_stop_worker() { # <id>
  local r i; r="$(backend_runner "$1")"
  if park_supported "$1" && ! is_parked "$1" && park_task "$1" now >/dev/null 2>&1; then return 0; fi
  case "$r" in
    headless|command) "${r}_stop" "$1" >/dev/null 2>&1 || return 1 ;; # (its process tree, ended)
    "") return 1 ;;
    *) declare -F "${r}_close" >/dev/null || return 1; "${r}_close" "$1" >/dev/null 2>&1 || return 1 ;;
  esac
  for i in 1 2 3 4 5 6 7 8 9 10; do [[ "$(live_of "$1")" =~ ^($MARK_AT_REST)$ ]] && return 0; sleep 0.5; done
  return 1
}

marks_usage() {
  cat <<'EOF'
usage: chartroom remove <ref>... [--why <text>] [--stop] [--json]
                                      take tasks, inbox items and artifacts out of every view (30 days to undo)
       chartroom restore <ref>... [--json]   undo a remove
       chartroom done <ref>... [--json]      mark inbox items and artifacts done
       chartroom removed [--json]            what is removed, and until when it can be restored
A ref is a task id or short id, an inbox item (i-xxxx) or an artifact (<id>/<slug>).
EOF
}

# remove | restore | done: resolve and check every ref, apply the rest in one transaction.
marks_apply() { # <op> <args...>
  local op="$1"; shift
  local why="" stop=0 json=0 refs=() a items="" failed='[]' st live out
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --why) [[ $# -ge 2 ]] || die "$(marks_usage)"; why="$2"; shift 2 ;;
      --stop) [[ "$op" == remove ]] || die "--stop goes with remove"; stop=1; shift ;;
      --json) json=1; shift ;;
      -h|--help) marks_usage; return 0 ;;
      -*) die "$op: unknown flag $1" ;;
      *) refs+=("$1"); shift ;;
    esac
  done
  [[ ${#refs[@]} -gt 0 ]] || die "$(marks_usage)"
  [[ "$why" != *[$'\n\r']* ]] || die "--why is one line of text"
  marks_fail() { failed="$(jq -c --arg r "$1" --arg w "$2" '. + [{ref: $r, why: $w}]' <<<"$failed")"; }
  local -A seen=()
  for a in "${refs[@]}"; do
    if ! mark_resolve "$a"; then marks_fail "$a" "$MK_WHY"; continue; fi
    [[ -z "${seen[$MK_KIND/$MK_REF]+x}" ]] || continue
    seen[$MK_KIND/$MK_REF]=1
    if [[ "$op" == "done" && "$MK_KIND" == task ]]; then
      marks_fail "$a" "a task is done by accept (its finished work) or close, not marked"; continue
    fi
    if [[ "$op" == remove && "$MK_KIND" == task && -z "$(meta "$MK_REF" closed)" ]]; then
      live="$(live_of "$MK_REF")"
      if [[ ! "$live" =~ ^($MARK_AT_REST)$ ]]; then
        if [[ $stop -eq 0 ]]; then marks_fail "$a" "its worker is $live (--stop ends it first; the worktree stays)"; continue; fi
        mark_stop_worker "$MK_REF" || { marks_fail "$a" "its worker is $live and could not be stopped"; continue; }
        log_event "$MK_REF" note "its worker ended to remove the task (remove --stop)"
      fi
    fi
    items+="$MK_KIND"$'\t'"$MK_REF"$'\n'
  done
  out='{"applied":[],"failed":[]}'
  if [[ -n "$items" ]]; then
    store_home_ensure
    out="$(printf '%s' "$items" | store_py mark "${STORE_HOME_ARGS[@]}" --op "$op" --by "${CHARTROOM_CLIENT:+$CHARTROOM_CLIENT:}${CHARTROOM_VIA:-terminal}" --why "$why")" ||
      die "the store did not take the marks (${STORE_DB:-$CR_DB}): nothing changed"
    store_reset; store_stamp; stamp_changed
  fi
  out="$(jq -c --argjson f "$failed" '.failed = ($f + .failed)' <<<"$out")"
  if [[ $json -eq 1 ]]; then jq . <<<"$out"
  else
    local verb; case "$op" in remove) verb=removed ;; restore) verb=restored ;; "done") verb="done" ;; esac
    jq -r --arg v "$verb" '.applied[] | "\($v) \(.ref)"' <<<"$out"
    jq -r '.failed[] | "chartroom: \(.ref): \(.why)"' <<<"$out" >&2
  fi
  [[ "$(jq '.failed | length' <<<"$out")" -eq 0 ]]
}

cmd_remove() { marks_apply remove "$@"; }
cmd_restore() { marks_apply restore "$@"; }
cmd_done() { marks_apply "done" "$@"; }

cmd_removed() {
  local json=0
  [[ "${1:-}" == --json ]] && json=1
  marks_json | jq -c '[to_entries[] | .key as $k | .value | to_entries[] | select(.value.removed != null)
      | {kind: $k, ref: .key, removed: .value.removed, by: .value.by, why: .value.why,
         restorable_until: ((.value.removed | fromdateiso8601) + 30 * 86400 | todate)}] | sort_by(.removed) | reverse' |
    if [[ $json -eq 1 ]]; then jq .
    else jq -r 'if length == 0 then "removed: nothing" else .[] | "\(.kind) \(.ref)  removed \(.removed)\(if .why then " (\(.why))" else "" end), restorable until \(.restorable_until)" end'; fi
}
