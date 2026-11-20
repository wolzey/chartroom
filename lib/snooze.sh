# shellcheck shell=bash
# snooze.sh - `chartroom snooze`: the commander's "not now" on an item of Needs me (a task, an
# inbox item, a card or an artifact). The item leaves Needs me until the time comes, then returns
# by itself; nothing about the item changes, and the XO is not told.
#
# snoozes.ndjson in the home, append-only, the newest record per ref winning:
#   {"schema":1,"ref":"<id>","until":"<UTC>"|null,"at":"<UTC>"}     (until null: snooze off)

CR_SNOOZE_REF_RE='^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$'

snooze_file() { printf '%s/snoozes.ndjson' "$CR_HOME"; }
snooze_usage() { echo "usage: chartroom snooze <ref> (--for 30m|4h|2d | --until <UTC ISO time>)  |  snooze off <ref>  |  snooze list [--all] [--json]"; }

# {ref: until} for every snooze still in force (until in the future); --all: the newest per ref.
snoozes_json() { # [--all]
  local f all=false; f="$(snooze_file)"
  [[ "${1:-}" == --all ]] && all=true
  [[ -f "$f" ]] || { echo '{}'; return 0; }
  jq -R -s -c --argjson all "$all" '
    [split("\n")[] | fromjson? | select(type == "object" and (.ref | type) == "string")]
    | reduce .[] as $r ({}; .[$r.ref] = $r.until)
    | with_entries(select($all or (.value != null and ((.value | fromdateiso8601? // 0) > now))))' "$f"
}

snooze_write() { # <ref> <until|"">
  jq -n -c --arg r "$1" --arg u "$2" --arg at "$(now)" '{schema: 1, ref: $r, until: (if $u == "" then null else $u end), at: $at}' >>"$(snooze_file)"
  stamp_changed
}

cmd_snooze() {
  case "${1:-}" in
    ""|-h|--help) snooze_usage; [[ -n "${1:-}" ]] ;;
    list)
      shift; local json=0 all="" a
      for a in "$@"; do case "$a" in --json) json=1 ;; --all) all=--all ;; *) die "$(snooze_usage)" ;; esac; done
      if [[ $json -eq 1 ]]; then snoozes_json ${all:+"$all"} | jq .; return; fi
      snoozes_json ${all:+"$all"} | jq -r 'if length == 0 then "snoozed: nothing" else to_entries[] | "- \(.key) until \(.value // "(off)")" end' ;;
    off)
      [[ $# -eq 2 && "$2" =~ $CR_SNOOZE_REF_RE ]] || die "$(snooze_usage)"
      snooze_write "$2" ""; echo "snooze off: $2" ;;
    *)
      local ref="$1" until="" dur=""; shift
      [[ "$ref" =~ $CR_SNOOZE_REF_RE ]] || die "snooze: '$ref' is not an item's id"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --for) [[ $# -ge 2 ]] || die "$(snooze_usage)"; dur="$2"; shift 2 ;;
          --until) [[ $# -ge 2 ]] || die "$(snooze_usage)"; until="$2"; shift 2 ;;
          *) die "$(snooze_usage)" ;;
        esac
      done
      [[ -n "$dur" || -n "$until" ]] && [[ -z "$dur" || -z "$until" ]] || die "$(snooze_usage)"
      if [[ -n "$dur" ]]; then
        [[ "$dur" =~ ^([0-9]{1,4})([mhd])$ ]] || die "snooze: --for takes 30m, 4h or 2d, not '$dur'"
        local secs=$((10#${BASH_REMATCH[1]}))
        case "${BASH_REMATCH[2]}" in m) secs=$((secs * 60)) ;; h) secs=$((secs * 3600)) ;; d) secs=$((secs * 86400)) ;; esac
        (( secs > 0 )) || die "snooze: --for takes a duration above zero"
        until="$(jq -n -r --argjson s "$secs" 'now + $s | floor | todate')"
      else
        jq -e -n --arg u "$until" '$u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and (fromdateiso8601 > now)' >/dev/null 2>&1 ||
          die "snooze: --until takes a future UTC time like 2026-01-02T09:00:00Z"
      fi
      snooze_write "$ref" "$until"; echo "snoozed $ref until $until" ;;
  esac
}
