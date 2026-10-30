# shellcheck shell=bash
# show.sh - `chartroom show <id>`: one item in detail, for the crew views (the Claude Code mod
# and the pi extension) and the terminal.
#
# The item's card comes from dashboard_json, narrowed to that one task (CR_BOARD_ID), so its
# lane, reason, PR links and artifacts are exactly the board's. The detail adds what only the
# task's files say: the commander's intent, the last events, the outcome, the report's summary,
# and where the worker runs. Read-only: it starts no process of a backend's.

SHOW_INTENT_LINES=6
SHOW_EVENTS=5
SHOW_SUMMARY_LINES=8

# The first lines of the brief's intent section (legacy homes call it "Captain's intent"),
# without the template's HTML comments or blank lines.
show_intent() { # <brief.md>
  [[ -f "$1" ]] || return 0
  awk -v max="$SHOW_INTENT_LINES" '
    /^## / { if (s) exit; s = ($0 ~ /^## (Commander|Captain).s intent/); next }
    !s { next }
    c { if (index($0, "-->")) c = 0; next }
    /^[[:space:]]*<!--/ { if (!index($0, "-->")) c = 1; next }
    NF { print; if (++n >= max) exit }' "$1"
}

# A report's summary: its "Outcome" (or "Summary") section, else its first lines after the
# title. At most SHOW_SUMMARY_LINES non-empty lines.
show_report_summary() { # <report.md>
  local out
  out="$(awk -v max="$SHOW_SUMMARY_LINES" '
    /^#+ / { if (s) exit; s = (tolower($0) ~ /outcome|summary/); next }
    s && NF { print; if (++n >= max) exit }' "$1")"
  [[ -n "$out" ]] || out="$(awk -v max="$SHOW_SUMMARY_LINES" '/^#+ / { next } NF { print; if (++n >= max) exit }' "$1")"
  printf '%s' "$out"
}

# Where the worker runs, from the handles meta.json records (nothing is probed), as
# "<where>\t<1 when chartroom attach can take you there>".
show_where() { # <id>
  local id="$1" r s
  if [[ -n "$(meta "$id" closed)" ]]; then printf 'closed\t0'; return; fi
  if [[ -z "$(meta "$id" dispatched)" ]] && ! is_joined "$id"; then printf 'not dispatched yet\t0'; return; fi
  if [[ -n "$(meta "$id" hc_terminal)" ]]; then printf 'hc terminal %s (Herdr)\t1' "$(meta "$id" hc_terminal)"; return; fi
  if [[ -n "$(meta "$id" herdr_tab)" ]]; then printf 'herdr tab %s\t1' "$(meta "$id" herdr_tab)"; return; fi
  if [[ -n "$(meta "$id" tmux_pane)" ]]; then
    s="$(meta "$id" tmux_session)"; printf 'tmux %s%s\t1' "${s:+$s:}" "$(meta "$id" tmux_pane)"; return
  fi
  if [[ -n "$(meta "$id" cmux_workspace)" ]]; then printf 'cmux workspace %s\t1' "$(meta "$id" cmux_workspace)"; return; fi
  r="$(backend_runner "$id")"
  case "$r" in
    headless|command) printf '%s, no terminal (chartroom peek %s)\t0' "$r" "$id" ;;
    subagent) printf "a subagent inside the XO's session\t0" ;;
    *) printf '%s\t0' "${r:-unknown}" ;;
  esac
}

# The item's detail JSON: its board card, plus intent, events, outcome, report, brief,
# worktree, branch and attach for a task (null or empty for an inbox item), plus artifacts
# (the card's, [] where the board has none).
show_json() { # <task|inbox> <id>
  local type="$1" id="$2" card
  card="$(CR_BOARD_ID="$id" dashboard_json | jq -c --arg t "$type" --arg id "$id" \
    '[.lanes[][] | select(.type == $t and (if $t == "task" then .id else .short_id end) == $id)] | first // empty')"
  if [[ "$type" == inbox ]]; then
    [[ -n "$card" ]] || die "inbox item $id is not on the board"
    jq -c '. + {text: .title, artifacts: (.artifacts // []), intent: null, events: [], outcome: null,
      report: null, brief: null, worktree: null, branch: null, attach: null}' <<<"$card"
    return
  fi
  local d where report="" summary="" events outcome
  d="$(tdir "$id")"
  # A closed task past the recent window is on no lane: its status row stands in for the card.
  if [[ -z "$card" ]]; then
    card="$(status_rows --id "$id" | jq -c --argjson x "$(dashboard_task_extra "$id")" \
      '{type: "task"} + . + $x + {lane: null, reason: .state, prs: ($x.prs | map({url: ., state: "UNKNOWN"}))}')"
  fi
  where="$(show_where "$id")"
  if [[ -s "$d/report.md" ]]; then report="$d/report.md"; summary="$(show_report_summary "$report")"; fi
  events="$(grep -E '^[^ ]+ (progress|waiting|decision|blocked|done|failed|steered): ' "$d/events.log" 2>/dev/null || true)"
  outcome="$(grep -E '^[^ ]+ (done|failed): ' <<<"$events" | tail -n 1 || true)"
  jq -c --arg intent "$(show_intent "$d/brief.md")" --arg events "$(tail -n "$SHOW_EVENTS" <<<"$events")" \
    --arg outcome "$outcome" --arg report "$report" --arg summary "$summary" \
    --arg brief "$([[ -f "$d/brief.md" ]] && printf '%s' "$d/brief.md")" \
    --arg worktree "$(meta "$id" worktree)" --arg branch "$(meta "$id" branch)" \
    --arg where "${where%$'\t'*}" --argjson attachable "${where##*$'\t'}" '
    def ev: {at: .[0:20], kind: (.[21:] | split(":")[0]), text: (.[21:] | sub("^[^:]*: "; ""))};
    def str: if . == "" then null else . end;
    . + {artifacts: (.artifacts // []),
      intent: ($intent | str),
      events: ($events | split("\n") | map(select(length > 0) | ev)),
      outcome: (if $outcome == "" then null else ($outcome | ev) end),
      report: (if $report == "" then null else {path: $report, summary: ($summary | str)} end),
      brief: ($brief | str), worktree: ($worktree | str), branch: ($branch | str),
      attach: {where: $where, command: (if $attachable == 1 then "chartroom attach " + .id else null end)}}' <<<"$card"
}

# `chartroom show <id> [--json]`: an id as `resolve` takes it (a short id from the board, an
# inbox tag, a full task id).
cmd_show() {
  local json=0 q="" a item
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      -*) die "show: unknown arg $a (usage: chartroom show <id> [--json])" ;;
      *) q="$a" ;;
    esac
  done
  [[ -n "$q" ]] || die "usage: chartroom show <id|short id> [--json]"
  item="$(cmd_resolve "$q" --json)" || exit 1
  local detail; detail="$(show_json "$(jq -r .type <<<"$item")" "$(jq -r .id <<<"$item")")"
  if [[ $json -eq 1 ]]; then echo "$detail"; return; fi
  jq -r '
    def indent: split("\n") | map("  " + .) | join("\n");
    "\(.short_id // .id)  \(if .project then "[\(.project)] " else "" end)\(.title)",
    "state: \(.state)\(if .reason and .reason != .state then " (\(.reason))" else "" end) · lane: \(.lane // "none")\(if .type == "task" then " · live: \(.live) · \(.backend)" else "" end)",
    (if .date then "since: \(.date)" else empty end),
    (if .waiting_on then "waiting on: \(.waiting_on)\(if .waiting_until then " until \(.waiting_until)" else "" end)" else empty end),
    (if .intent then "intent:", (.intent | indent) else empty end),
    (if (.events | length) > 0 then "last events:", (.events[] | "  \(.at) \(.kind): \(.text)") else empty end),
    (if .report then "report: \(.report.path)", (.report.summary // "" | select(. != "") | indent)
     elif .outcome then "outcome: \(.outcome.kind): \(.outcome.text)" else empty end),
    (if (.prs | length) > 0 then "PRs:", (.prs[] | "  \(.url)\(if (.state // "UNKNOWN") != "UNKNOWN" then " (\(.state | ascii_downcase))" else "" end)") else empty end),
    (if (.artifacts | length) > 0 then "artifacts:", (.artifacts[] | "  \(.ref)  \(.title // "")") else empty end),
    (if .attach then "worker: \(.attach.where)\(if .attach.command then " (\(.attach.command))" else "" end)" else empty end),
    (if .worktree then "worktree: \(.worktree)" else empty end)' <<<"$detail"
}
