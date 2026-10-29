# shellcheck shell=bash
# radar.sh - `chartroom radar`: the data behind the dashboard's fleet radar (/radar). One record
# per open crew task on every home of this machine (the rows `status --json` prints, read in each
# home) and of other machines over ssh, plus each home's XO as an untracked "flagship" from herdr.
# The state table lives in lib/dashboard/radar.jq; lib/dashboard/server.py only schedules these
# calls (off the request path, only while the radar is open), caches them and serves the result.
#
# Other machines are only ever read. The only commands that run there are
#   chartroom status --json --all-homes
#   chartroom peek <id> <n>                  (CHARTROOM_HOME set to a home that machine reported)
#   cat <home>/tasks/<id>/<file>             (brief.md report.md plan.md final.md events.log)
# over `ssh -o BatchMode=yes`, and herdr's own `--machine <m> agent list` and `agent read`.
# An older chartroom ignores --all-homes and answers for its default home only: radar.jq tells
# the two apart by the shape of the output (the version string does not change), and says so.
#
# Settings: CHARTROOM_MACHINE_NAME (this machine's label; default: its host name),
# CHARTROOM_RADAR_MACHINES ("label[=ssh-target] ...", or "none"; default: herdr's enabled saved
# machines), CHARTROOM_RADAR_REMOTE_PATH (PATH dirs put first on the other machine, whose
# non-interactive ssh shell lacks them), and how often the dashboard re-reads while the radar is
# open: this machine when its task files or herdr's agent states change but at most every
# CHARTROOM_RADAR_LOCAL_MIN_SECONDS (15) and at least every CHARTROOM_RADAR_LOCAL_MAX_SECONDS (60),
# another machine every CHARTROOM_RADAR_REMOTE_SECONDS (60). The page's "active only" view (its
# default) leaves out a docked task (review, done, failed) quiet for CHARTROOM_RADAR_DONE_HOURS (24)
# and folds a task whose session is gone and that has been quiet for CHARTROOM_RADAR_STALE_DAYS (3)
# into each machine's archive; a breaking report is never archived.

CR_RADAR_REMOTE_PATH_DEFAULT='$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin'
CR_RADAR_FILES='brief.md report.md plan.md final.md events.log' # = CR_DASHBOARD_FILES (lib/dashboard.sh)
CR_RADAR_ID_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'              # = TASK_ID (lib/dashboard/server.py)
CR_RADAR_PATH_RE='^/[A-Za-z0-9_./ -]+$'
CR_RADAR_PANE_RE='^[A-Za-z0-9:_-]{1,64}$'

# This machine's label: CHARTROOM_MACHINE_NAME (env, the home's config, the config file), else the
# host name without its domain.
radar_machine_name() {
  local n; n="$(cfg MACHINE_NAME '' '')"
  [[ -n "$n" ]] || { n="$(uname -n 2>/dev/null || true)"; n="${n%%.*}"; }
  printf '%s' "${n:-this machine}"
}

# The PATH prefix for the other machine's shell; refuses anything but path characters and $HOME.
radar_remote_path() {
  local p; p="$(cfg RADAR_REMOTE_PATH '' "$CR_RADAR_REMOTE_PATH_DEFAULT")"
  [[ "$p" =~ ^[A-Za-z0-9_./:$~-]+$ ]] || die "CHARTROOM_RADAR_REMOTE_PATH may hold only directories, ':' and \$HOME (got '$p')"
  printf '%s' "$p"
}

# Run one fixed, read-only command on <target>. Never prompts (BatchMode), gives up on a dead
# link (ConnectTimeout, ServerAlive*), and reuses one connection per target while the radar polls
# (the control socket lives in this home; skipped when its path would be too long for a socket).
radar_ssh() { # <target> <remote command>
  local o=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR)
  if [[ "$CR_PLATFORM" != msys && $(( ${#CR_HOME} + 48 )) -le 100 ]] && mkdir -p "$CR_HOME/.radar" 2>/dev/null; then
    chmod 700 "$CR_HOME/.radar" 2>/dev/null || true
    o+=(-o ControlMaster=auto -o "ControlPath=$CR_HOME/.radar/%C" -o ControlPersist=120)
  fi
  ssh "${o[@]}" -- "$1" "$2" </dev/null
}

# The machines the radar reads, as JSON: this one first, then the others.
#   [{machine, local, target, via}]
radar_machines_json() {
  local spec label target out
  local rows=("$(jq -cn --arg m "$(radar_machine_name)" '{machine: $m, local: true, target: null, via: "this machine"}')")
  spec="$(cfg RADAR_MACHINES '' '')"
  if [[ "$spec" == none ]]; then :
  elif [[ -n "$spec" ]]; then
    for label in $spec; do
      target="${label#*=}"; label="${label%%=*}"
      [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ && "$target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,253}$ ]] ||
        die "CHARTROOM_RADAR_MACHINES: '$label=$target' is not label[=ssh-target] (letters, digits, . _ - @)"
      rows+=("$(jq -cn --arg m "$label" --arg t "$target" '{machine: $m, local: false, target: $t, via: "config"}')")
    done
  elif [[ -n "$(bin_of herdr)" ]] && out="$(herdr machine list --json 2>/dev/null)"; then
    while IFS= read -r label; do [[ -n "$label" ]] && rows+=("$label"); done < <(jq -c '
      (if type == "array" then . else [] end)[] | select(.enabled != false and (.label // "") != "")
      | select((.label | test("^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$")) and ((.target // .label) | test("^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,253}$")))
      | {machine: .label, local: false, target: (.target // .label), via: "herdr"}' <<<"$out" 2>/dev/null || true)
  fi
  printf '%s\n' "${rows[@]}" | jq -s .
}

# Every home on this machine in the all-homes shape of `status --json --all-homes`
# ([{home, path, current, result} | {home, path, current, error}]), the homes read side by side.
radar_local_status() {
  local rows n i name path cur tmp rc why
  rows="$(homes_rows | jq -s -c .)"
  n="$(jq length <<<"$rows")"
  tmp="$(mktemp -d)"
  for ((i = 0; i < n; i++)); do
    jq -r --argjson i "$i" '.[$i] | [(.name // "(this home)"), .path, .current] | @tsv' <<<"$rows" >"$tmp/$i.who"
    IFS=$'\t' read -r name path cur <"$tmp/$i.who"
    if [[ ! -d "$path/tasks" ]]; then
      printf 'not a chartroom home (no %s/tasks)\n' "$path" >"$tmp/$i.err"; echo 1 >"$tmp/$i.rc"; continue
    fi
    ( rc=0; CHARTROOM_HOME="$path" "$CR_BIN" status --json >"$tmp/$i.out" 2>"$tmp/$i.err" </dev/null || rc=$?; echo "$rc" >"$tmp/$i.rc" ) &
  done
  wait
  for ((i = 0; i < n; i++)); do
    IFS=$'\t' read -r name path cur <"$tmp/$i.who"
    if [[ "$(cat "$tmp/$i.rc")" == 0 ]] && jq -e 'type == "array"' "$tmp/$i.out" >/dev/null 2>&1; then
      jq -c --arg h "$name" --arg p "$path" --argjson c "$cur" '{home: $h, path: $p, current: $c, result: .}' "$tmp/$i.out"
    else
      why="$(sed -E 's/^chartroom: //' "$tmp/$i.err" | grep -v '^[[:space:]]*$' | head -1)"
      jq -cn --arg h "$name" --arg p "$path" --argjson c "$cur" --arg e "${why:-status failed}" '{home: $h, path: $p, current: $c, error: $e}'
    fi
  done | jq -s .
  rm -rf "$tmp"
}

# {"<home path>": "<physical path>"} for this machine's homes.
radar_phys_json() {
  local name path
  while IFS=$'\t' read -r name path; do
    jq -cn --arg p "$path" --arg q "$(phys_dir "$path")" '{($p): $q}'
  done < <(homes_rows | jq -r '[.name // "", .path] | @tsv') | jq -s 'add // {}'
}

# One machine's normalized snapshot: radar.jq over its status output and herdr's agent list.
radar_normalize() { # <status-file> <herdr-file> <machine> <local> <target> <via> <contact> <error> <phys-json>
  local f
  for f in "$1" "$2"; do jq -e . "$f" >/dev/null 2>&1 || echo null >"$f"; done
  jq -n --slurpfile st "$1" --slurpfile hd "$2" --arg machine "$3" --arg local "$4" --arg target "$5" \
    --arg via "$6" --arg contact "$7" --arg error "$8" --argjson phys "$9" -f "$CR_ROOT/lib/dashboard/radar.jq"
}

radar_snapshot_local() {
  local tmp; tmp="$(mktemp -d)"
  if [[ -n "$(bin_of herdr)" ]]; then herdr agent list >"$tmp/herdr" 2>/dev/null || : >"$tmp/herdr"; else : >"$tmp/herdr"; fi
  radar_local_status >"$tmp/status"
  radar_normalize "$tmp/status" "$tmp/herdr" "$(radar_machine_name)" true "" "this machine" ok "" "$(radar_phys_json)"
  rm -rf "$tmp"
}

# Another machine: its status over ssh (and herdr's agent list there, alongside). The call's
# outcome becomes the machine's contact: ok (any JSON array), unreachable (ssh's own 255),
# no-chartroom (127, "not found", "unknown command"), else error; with the last line it printed.
radar_snapshot_remote() { # <label> <target> <via>
  local label="$1" target="$2" via="$3" tmp rc=0 contact err hpid=""
  tmp="$(mktemp -d)"; : >"$tmp/herdr"
  if [[ -n "$(bin_of herdr)" ]]; then ( herdr --machine "$label" agent list >"$tmp/herdr" 2>/dev/null || : >"$tmp/herdr" ) 2>/dev/null & hpid=$!; fi
  radar_ssh "$target" "PATH=\"$(radar_remote_path):\$PATH\" chartroom status --json --all-homes" >"$tmp/status" 2>"$tmp/err" || rc=$?
  # herdr's answer gets 10s more than ssh's: a herdr stuck on a dead machine costs the XOs only,
  # never the machine's own contact (and there is no `timeout` on macOS)
  if [[ -n "$hpid" ]]; then
    local i; for i in $(seq 1 20); do pid_alive "$hpid" || break; sleep 0.5; done
    if pid_alive "$hpid"; then kill_tree "$hpid"; : >"$tmp/herdr"; fi
    wait "$hpid" 2>/dev/null || true
  fi
  err="$(cat "$tmp/err" "$tmp/status" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-300 || true)"
  if jq -e 'type == "array"' "$tmp/status" >/dev/null 2>&1; then contact=ok; err=""
  elif [[ $rc -eq 255 ]]; then contact=unreachable
  elif [[ $rc -eq 127 ]] || grep -qiE 'command not found|not found|unknown command' "$tmp/err" "$tmp/status" 2>/dev/null; then contact=no-chartroom
  else contact=error; [[ -n "$err" ]] || err="chartroom status exited $rc with no output"; fi
  radar_normalize "$tmp/status" "$tmp/herdr" "$label" false "$target" "$via" "$contact" "$err" '{}'
  rm -rf "$tmp"
}

# `radar peek`: a task's recent events and pane (its own `chartroom peek`), or a flagship's
# screen (herdr agent read), on this machine or another one.
radar_peek() { # --machine L [--ssh T] [--home P] (<id> [n] | --pane PANE)
  local machine="" target="" home="" pane="" id="" n=15
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --machine) machine="${2:-}"; shift 2 ;;
      --ssh) target="${2:-}"; shift 2 ;;
      --home) home="${2:-}"; shift 2 ;;
      --pane) pane="${2:-}"; shift 2 ;;
      *) if [[ -z "$id" ]]; then id="$1"; else n="$1"; fi; shift ;;
    esac
  done
  [[ -n "$machine" ]] || die "usage: chartroom radar peek --machine L [--ssh T] [--home P] (<id> [n] | --pane PANE)"
  [[ "$n" =~ ^[0-9]{1,3}$ ]] && (( n > 0 && n <= 200 )) || die "radar peek: n is 1-200"
  # (a home path goes into the other machine's shell, so only plain path characters; here it
  # only has to hold the task)
  [[ -z "$target" || -z "$home" || "$home" =~ $CR_RADAR_PATH_RE ]] || die "radar peek: not a home path: $home"
  if [[ -n "$pane" ]]; then
    [[ "$pane" =~ $CR_RADAR_PANE_RE ]] || die "radar peek: not a herdr pane id: $pane"
    [[ -n "$(bin_of herdr)" ]] || die "radar peek: herdr is not on PATH"
    echo "== screen (recent)"
    if [[ -z "$target" ]]; then herdr agent read "$pane" --source recent --lines 60
    else herdr --machine "$machine" agent read "$pane" --source recent --lines 60; fi
    return
  fi
  [[ "$id" =~ $CR_RADAR_ID_RE ]] || die "radar peek: not a task id: ${id:-(none)}"
  if [[ -z "$target" ]]; then
    [[ -n "$home" && -f "$home/tasks/$id/meta.json" ]] || die "radar peek: no task $id in ${home:-(no home)}"
    CHARTROOM_HOME="$home" "$CR_BIN" peek "$id" "$n" </dev/null
  else
    radar_ssh "$target" "PATH=\"$(radar_remote_path):\$PATH\" ${home:+CHARTROOM_HOME='$home' }chartroom peek '$id' $n"
  fi
}

# `radar file`: one of a task's files from another machine (the dashboard reads this machine's
# itself). Without a home path (an older chartroom), only report.md, found through its own peek.
radar_file() { # --machine L --ssh T [--home P] <id> <file>
  local machine="" target="" home="" id="" file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --machine) machine="${2:-}"; shift 2 ;;
      --ssh) target="${2:-}"; shift 2 ;;
      --home) home="${2:-}"; shift 2 ;;
      *) if [[ -z "$id" ]]; then id="$1"; else file="$1"; fi; shift ;;
    esac
  done
  [[ -n "$machine" && -n "$target" ]] || die "usage: chartroom radar file --machine L --ssh T [--home P] <id> <file>"
  [[ "$id" =~ $CR_RADAR_ID_RE ]] || die "radar file: not a task id: ${id:-(none)}"
  [[ " $CR_RADAR_FILES " == *" $file "* ]] || die "radar file: only $CR_RADAR_FILES"
  [[ -z "$home" || "$home" =~ $CR_RADAR_PATH_RE ]] || die "radar file: not a home path: $home"
  if [[ -n "$home" ]]; then
    radar_ssh "$target" "cat '$home/tasks/$id/$file'"
  else
    [[ "$file" == report.md ]] || die "radar file: $machine runs an older chartroom that reports no home path; only report.md can be read"
    radar_ssh "$target" "p=\$(PATH=\"$(radar_remote_path):\$PATH\" chartroom peek '$id' 1 | sed -n 's/^== report: //p' | tail -1); case \"\$p\" in */tasks/$id/report.md) cat \"\$p\" ;; *) echo 'no report.md for $id' >&2; exit 1 ;; esac"
  fi
}

# `radar machines`: the machines, the dashboard's re-read intervals and the archive's cutoffs, as JSON.
radar_listing_json() {
  local k v name unit settings=()
  for k in LOCAL_MIN_SECONDS:15 LOCAL_MAX_SECONDS:60 REMOTE_SECONDS:60 DONE_HOURS:24 STALE_DAYS:3; do
    v="$(cfg "RADAR_${k%%:*}" '' "${k#*:}")"
    name="${k%%:*}"; unit="${name##*_}"; name="${name%_*}"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )) || die "CHARTROOM_RADAR_${k%%:*} must be a whole number of $(tr '[:upper:]' '[:lower:]' <<<"$unit"), above 0 (got '$v')"
    settings+=(--argjson "$(tr '[:upper:]' '[:lower:]' <<<"${k%%:*}")" "$v")
  done
  jq -n --argjson machines "$(radar_machines_json)" "${settings[@]}" \
    '{machines: $machines, settings: {local_min: $local_min_seconds, local_max: $local_max_seconds, remote: $remote_seconds,
      done_hours: $done_hours, stale_days: $stale_days}}'
}

cmd_radar() {
  local json=0 machine="" target="" via=config snap
  case "${1:-}" in
    machines) shift; radar_listing_json; return ;;
    peek) shift; radar_peek "$@"; return ;;
    file) shift; radar_file "$@"; return ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --machine) [[ $# -ge 2 ]] || die "--machine needs a label"; machine="$2"; shift 2 ;;
      --ssh) [[ $# -ge 2 ]] || die "--ssh needs a target"; target="$2"; shift 2 ;;
      --via) [[ $# -ge 2 ]] || die "--via needs a word"; via="$2"; shift 2 ;;
      *) die "radar: unknown arg $1 (usage: chartroom radar [--json] [--machine L --ssh T] | radar machines | radar peek ... | radar file ...)" ;;
    esac
  done
  if [[ -n "$machine" && -n "$target" ]]; then snap="$(radar_snapshot_remote "$machine" "$target" "$via")"
  elif [[ -n "$machine$target" ]]; then die "radar: --machine and --ssh go together (another machine)"
  else snap="$(radar_snapshot_local)"; fi
  if [[ $json -eq 1 ]]; then printf '%s\n' "$snap"; return; fi
  # The terminal view: the machine, then one line per agent by sector (attention first).
  jq -r '
    def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
    .machine as $m
    | "== \($m.machine)\(if $m.local then " (this machine)" else " via ssh " + ($m.target // "") end): \($m.contact)"
      + (if $m.error then " (" + $m.error + ")" else "" end) + (if $m.note then "; " + $m.note else "" end),
      (["decision", "blocked", "adrift", "holding", "underway", "docked"][] as $s
       | [.agents[] | select(.sector == $s)] | select(length > 0)
       | "  \($s | ascii_upcase) (\(length))", (.[] | "    \(.short_id)  [\(.home)] \(.title | cut(50))  \(.state): \(.why | cut(70))")),
      (.flagships[] | "  XO \(.home): \(.status) (untracked: no events)")' <<<"$snap"
}
