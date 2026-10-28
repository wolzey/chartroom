# shellcheck shell=bash
# focus.sh - `chartroom focus`: one project (or a few) at a time, with a held count.
#
# `chartroom focus <project>` writes focus.json in the home (the format other tools read):
#   {"schema": 1, "projects": ["shop"], "scope": ["IR-006"], "since": "<UTC>", "until": "<UTC>"|null}
# No file, or an until in the past, means focus is off. While it is on, every item out of focus
# that would ask something of the commander is held: a task in decision, blocked, failed,
# awaiting-input or review, and an inbox "Waiting" item. Held items stay on the board and still
# wake the XO (marked [held]); status, board, the dashboard and the crew views count them, so a
# focus is never left on by accident.
#
# An item is in focus when its project equals a focus name or starts with "<name>-"
# (case-insensitive), so "shop" covers shop-api too; and, with a scope (`--scope IR-006`, for one
# incident inside a project), when it also mentions a scope word: a task in its title or id, an
# inbox item in its text (whole word, case-insensitive). An item marked breaking ("[breaking] "
# at the start of its text, from `event --breaking` or `inbox add --breaking`) is never held.
# `--for 4h` sets an end: past it the focus is off, as if `focus off` had run (nothing runs to
# end it; every reader checks).

# The rules, shared by status rows, inbox items, watch and the focus command (jq defs; a program
# starts with "$FOCUS_JQ").
#   focus_in($f)                    a project label (or null) -> is the project in focus $f?
#   focus_item($f)                  a task row ({project, title, id}) or inbox item ({project,
#                                   text}) -> is it in focus (project and scope)?
#   focus_marks($f; $kind; $brk)    a task row or inbox item -> {in_focus, held}; with no focus,
#                                   every item is in focus and none is held
#   focus_name, focus_line($held)   the focus -> "shop (IR-006)", and its one-line indicator
# A scope word is letters, digits, ".", "_", "-": only "." needs escaping in the regex.
FOCUS_JQ='
def focus_in($f): (. // "" | ascii_downcase) as $p | any($f.projects[]; . as $n | $p == $n or ($p | startswith($n + "-")));
def focus_item($f):
  ([.title, .text, .id] | map(select(type == "string")) | join(" ")) as $t
  | (.project | focus_in($f))
    and (($f.scope // []) | length == 0 or any(.[]; . as $w | $t | test("(^|[^A-Za-z0-9])" + ($w | gsub("\\."; "\\.")) + "($|[^A-Za-z0-9])"; "i")));
def focus_marks($f; $kind; $brk):
  if $f == null then {in_focus: true, held: false}
  else ($brk or focus_item($f)) as $in
    | {in_focus: $in, held: (($in | not) and ($kind == "inbox" or (.state | test("^(decision|blocked|failed|awaiting-input|review)$"))))}
  end;
def focus_dur: floor as $s
  | def two($big; $bu; $small; $su): "\($big)\($bu)" + (if $small > 0 then "\($small)\($su)" else "" end);
  if $s < 60 then "<1m" elif $s < 3600 then "\($s / 60 | floor)m"
  elif $s < 86400 then two($s / 3600 | floor; "h"; $s % 3600 / 60 | floor; "m")
  else two($s / 86400 | floor; "d"; $s % 86400 / 3600 | floor; "h") end;
def focus_name: (.projects | join(", ")) + (if (.scope // []) | length > 0 then " (\(.scope | join(", ")))" else "" end);
def focus_line($held):
  "🎯 focus: \(focus_name) · \($held) held (since \(now - (.since | fromdateiso8601) | focus_dur)"
  + (if .until then ", \((.until | fromdateiso8601) - now | focus_dur) left" else "" end) + ")";'

focus_file() { printf '%s/focus.json' "$CR_HOME"; }

# The focus in force as {projects, scope, since, until}, or null: no file, an unreadable one, or
# one past its until.
focus_json() {
  local f; f="$(focus_file)"
  [[ -f "$f" ]] || { echo null; return 0; }
  jq -c 'if (.projects | type) == "array" and (.projects | length) > 0 and (.since | type) == "string"
           and (.until == null or (.until | fromdateiso8601) > now) then {projects, scope: (.scope // []), since, until} else null end' "$f" 2>/dev/null ||
    { warn "ignoring unreadable $f"; echo null; }
}

# A focus file whose until has passed: its JSON, else nothing.
focus_ran_out() {
  local f; f="$(focus_file)"
  [[ -f "$f" ]] || return 0
  jq -c 'select(.until != null and (.until | fromdateiso8601) <= now)' "$f" 2>/dev/null || true
}

focus_has() { # <focus json> <item json: {project, title, id} or {project, text}> -> 0 when in focus
  jq -e -n --argjson f "$1" --argjson i "$2" "$FOCUS_JQ"' $i | focus_item($f)' >/dev/null
}
focus_has_task() { # <focus json> <id>
  jq -e --argjson f "$1" "$FOCUS_JQ"' {project: ((.project // "") | rtrimstr("/") | split("/") | last), title, id} | focus_item($f)' \
    "$(tdir "$2")/meta.json" >/dev/null
}

# Is the task's state set by a breaking report: its newest decision/blocked/failed/done event
# starts with "[breaking] "? (Only a decision, blocked or failed state can be.)
breaking_of() { # <id> <state>
  [[ "$2" =~ ^(decision|blocked|failed)$ ]] || return 1
  grep -E '^[^ ]+ (decision|blocked|done|failed): ' "$(tdir "$1")/events.log" 2>/dev/null | tail -1 | grep -qE '^[^ ]+ [a-z]+: \[breaking\] '
}

focus_line() { # <focus json> <held count>
  jq -r --argjson held "$2" "$FOCUS_JQ"' focus_line($held)' <<<"$1"
}

# How many items the focus holds: the held task rows on stdin (status_rows) plus the held inbox
# items. Closed tasks are never held, so open rows count the same as the board.
focus_held_count() {
  jq -s --argjson inbox "$(dashboard_inbox)" '([.[] | select(.held)] | length) + ([$inbox.waiting[] | select(.held)] | length)'
}

# The held cards of a board, one line each, as `board` prints an item.
focus_held_lines() { # <board json>
  jq -r '.lanes[][] | select(.held)
    | "  \(.short_id // "-")  \(if (.project // "") != "" then "[\(.project)] " else "" end)\(.title // .id)  [\(.reason // .state)]"' <<<"$1"
}

cmd_focus() {
  local json=0 dur="" scope="" names=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --for) [[ $# -ge 2 ]] || die "focus: --for needs a duration (30m, 4h, 1d)"; dur="$2"; shift 2 ;;
      --for=*) dur="${1#--for=}"; shift ;;
      --scope) [[ $# -ge 2 ]] || die "focus: --scope needs a word, such as an incident or ticket id"; scope="$scope,$2"; shift 2 ;;
      --scope=*) scope="$scope,${1#--scope=}"; shift ;;
      -*) die "focus: unknown arg $1 (usage: chartroom focus [<project>[,<project>...] [--scope WORD[,WORD...]] [--for 4h] | off] [--json])" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  if [[ ${#names[@]} -eq 0 ]]; then
    [[ -z "$dur$scope" ]] || die "focus: --for and --scope go with a project: chartroom focus <project> --scope <word> --for 4h"
    focus_show "$json"
  elif [[ "${names[*]}" == off ]]; then
    [[ -z "$dur$scope" ]] || die "focus off takes no --for or --scope"
    focus_off
  else
    focus_on "$dur" "$scope" "${names[@]}"
  fi
}

focus_show() { # <json 0|1>
  local focus out board
  focus="$(focus_json)"
  if [[ "$focus" == null ]]; then
    out="$(focus_ran_out)"
    if [[ $1 -eq 1 ]]; then jq -cn --argjson r "${out:-null}" '{on: false, ran_out: (if $r then {projects: $r.projects, scope: ($r.scope // []), until: $r.until} else null end)}'
    elif [[ -n "$out" ]]; then jq -r "$FOCUS_JQ"' "focus: off (\(focus_name) ran out at \(.until))"' <<<"$out"
    else echo "focus: off"; fi
    return 0
  fi
  board="$(dashboard_json)"
  if [[ $1 -eq 1 ]]; then
    jq -c --argjson f "$focus" '$f + {on: true, held: .focus.held, items: [.lanes[][] | select(.held)
      | {type, id, short_id, project, title, state, reason}]}' <<<"$board"
  else
    focus_line "$focus" "$(jq '.focus.held' <<<"$board")"
  fi
}

focus_off() {
  local f focus out board n
  f="$(focus_file)"; focus="$(focus_json)"
  if [[ "$focus" == null ]]; then
    out="$(focus_ran_out)"
    rm -f "$f"
    if [[ -n "$out" ]]; then jq -r "$FOCUS_JQ"' "focus: off (\(focus_name) had run out at \(.until))"' <<<"$out"
    else echo "focus: already off"; fi
    return 0
  fi
  board="$(dashboard_json)" # before the file goes, so the held marks are this focus's
  rm -f "$f"
  n="$(jq '.focus.held' <<<"$board")"
  jq -r --argjson n "$n" "$FOCUS_JQ"' "focus off: \(focus_name), on for \(now - (.since | fromdateiso8601) | focus_dur). "
    + (if $n == 0 then "Nothing was held." else "\($n) held, now back in view:" end)' <<<"$focus"
  if [[ "$n" -gt 0 ]]; then focus_held_lines "$board"; echo "(bearings walks them)"; fi
}

focus_on() { # <duration or ""> <scope words, comma-separated, or ""> <name...>
  local dur="$1" n names=() scope=() until=null focus prev matches
  shift
  for n in $(tr ',' ' ' <<<"$1"); do
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "focus: scope '$n' must be one word (letters, digits, '.', '_', '-'), such as IR-006"
    [[ " ${scope[*]} " == *" $n "* ]] || scope+=("$n")
  done
  shift
  for n in $(tr ',[:upper:]' ' [:lower:]' <<<"$*"); do
    [[ "$n" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "focus: '$n' is not a project name (as status prints them: letters, digits, '.', '_', '-')"
    [[ "$n" != off ]] || die "focus: 'off' turns focus off on its own: chartroom focus off"
    [[ " ${names[*]} " == *" $n "* ]] || names+=("$n")
  done
  [[ ${#names[@]} -gt 0 ]] || die "usage: chartroom focus <project>[,<project>...] [--scope WORD] [--for 4h]"
  if [[ -n "$dur" ]]; then
    [[ "$dur" =~ ^([0-9]+)([mhd])$ && "${BASH_REMATCH[1]}" -gt 0 ]] || die "focus: --for takes a duration such as 30m, 4h or 1d (got '$dur')"
    case "${BASH_REMATCH[2]}" in m) n=60 ;; h) n=3600 ;; d) n=86400 ;; esac
    until="$(jq -n --argjson s "$((BASH_REMATCH[1] * n))" 'now + $s | floor | todate')"
  fi
  prev="$(focus_json)"
  mkdir -p "$CR_HOME"
  focus="$(jq -n -c --arg names "${names[*]}" --arg scope "${scope[*]-}" --arg since "$(now)" --argjson until "$until" \
    '{schema: 1, projects: ($names | split(" ")), scope: ($scope | split(" ") | map(select(length > 0))), since: $since, until: $until}')"
  printf '%s\n' "$focus" >"$(focus_file).tmp" && mv "$(focus_file).tmp" "$(focus_file)"
  # What it covers now (the open tasks' projects and items, and inbox items), so the rules are seen
  # when it is set; a focus that covers nothing is kept (a project may have no work yet).
  shopt -s nullglob
  local metas=("$CR_HOME"/tasks/*/meta.json)
  matches="$(jq -n -c --argjson f "$focus" --argjson inbox "$(dashboard_inbox)" "$FOCUS_JQ"'
    [inputs | select((.closed // "") == "") | {project: ((.project // "") | rtrimstr("/") | split("/") | last), title, id}] as $open
    | ([$open[].project | select(. != "")] | unique) as $projects
    | {projects: [$projects[] | select(focus_in($f))], other: [$projects[] | select(focus_in($f) | not)],
       tasks: [$open[] | select(focus_item($f))] | length, inbox: [$inbox.waiting[] | select(focus_item($f))] | length}' "${metas[@]}" </dev/null)"
  jq -r --argjson prev "$prev" --argjson m "$matches" "$FOCUS_JQ"'
    def n($k; $what): if $m[$k] > 0 then ["\($m[$k]) \($what)\(if $m[$k] > 1 then "s" else "" end)"] else [] end;
    ([if $prev != null and ($prev | focus_name) != focus_name then "was \($prev | focus_name)" else empty end,
      if (.scope | length) > 0 then
        (if $m.tasks + $m.inbox > 0 then "covers " + (n("tasks"; "task") + n("inbox"; "inbox item") | join(", ")) + " in " + ($m.projects | join(", ")) else empty end)
      elif ($m.projects | length) + $m.inbox > 0
      then "covers " + ([($m.projects | join(", ")) | select(. != "")] + n("inbox"; "inbox item") | join(", "))
      else empty end] | join("; ")) as $notes
    | "focus on: \(focus_name)" + (if .until then " until \(.until)" else "" end) + (if $notes != "" then " (\($notes))" else "" end)' <<<"$focus"
  if [[ ${#scope[@]} -gt 0 ]] && jq -e '.tasks + .inbox == 0' <<<"$matches" >/dev/null; then
    warn "nothing open in $(IFS=,; echo "${names[*]}") mentions $(IFS=,; echo "${scope[*]}") yet; name it in a task's title or an inbox item's text to bring that item into focus"
  elif jq -e '(.projects | length) + .inbox == 0' <<<"$matches" >/dev/null; then
    warn "nothing open is in $(IFS=,; echo "${names[*]}") yet$(jq -r 'if (.other | length) > 0 then " (open projects: \(.other | join(", ")))" else "" end' <<<"$matches")"
  fi
  focus_line "$focus" "$(status_rows | focus_held_count)"
}
