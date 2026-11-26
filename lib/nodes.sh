# shellcheck shell=bash
# nodes.sh - the machines that can take crew work (docs/multi-machine.md), stage 1: read-only.
#   chartroom node probe [--json]   this machine's facts (lib/nodeprobe.sh)
#   chartroom node init [...]       make this machine a node: its own budgets, in its node file
#   chartroom nodes [--json] [--project PATH]
#                                   every node, this machine first, with its room and what it can run
#
# A node is any machine with a node file (CHARTROOM_NODE_CONFIG, default
# ${XDG_CONFIG_HOME:-~/.config}/chartroom/node), written on that machine by `node init`. It has no
# home and no XO. The other machines are, first, the devices enrolled here (lib/fleet.sh): each
# one's row is its last heartbeat, read from disk, and nothing is sent to it. Then, until every
# machine has enrolled, the ones in CHARTROOM_NODES ("label[=ssh-target] ...", or "none"), else the
# radar's list (CHARTROOM_RADAR_MACHINES, else herdr's saved machines), leaving out any whose label
# is an enrolled device's name or alias. `nodes --ssh` reads only those, as before devices.
#
# A machine still read over ssh is only read. The one command run there is lib/nodeprobe.sh itself, sent as
#   ssh -o BatchMode=yes <target> 'PATH="<CHARTROOM_RADAR_REMOTE_PATH>:$PATH" [CR_PROBE_PROJECT=<remote>] bash -s' < lib/nodeprobe.sh
# so it needs nothing installed there and runs exactly this chartroom's probe. Every probe runs
# side by side and is ended after CHARTROOM_NODES_TIMEOUT seconds (45).
#
# A node has two limits, its owner's: the share of its CPU and of its memory that may be in use
# (CHARTROOM_NODE_CPU_BUDGET and CHARTROOM_NODE_MEM_BUDGET in its node file, percent; `chartroom node
# limits` shows and sets them). What is in use is measured, not estimated: cpu_use (the busy share of
# all cores over the last minute) and mem_used_pct (Activity Monitor's Memory Used); lib/nodeprobe.sh
# says how. Worker counts are shown and gate nothing (an older node file's CHARTROOM_NODE_MAX_WORKERS is not read).
#
# UTIL is how full the node would be, against its own limits, if one more worker landed there: the
# score placement (lib/place.sh) ranks by, with the workers it has just placed counted too.
#   max((cpu_use + c / cores) / cpu limit, (mem_used + m / RAM) / memory limit)
# with c = CHARTROOM_WORKER_CPU cores (1.5) and m = CHARTROOM_WORKER_MEM_GB (1.5).

CR_NODE_LABEL_RE='^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$'
CR_NODE_TARGET_RE='^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,253}$'
CR_NODE_REMOTE_RE='^[a-z0-9][a-z0-9._-]*(:[0-9]+)?(/[a-z0-9._~-]+)+$'

# How busy this machine's CPUs are, kept by lib/cpuload.sh and read by the probe.
node_cpu_file() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/node/cpu"; }
node_config_path() { printf '%s' "${CHARTROOM_NODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/chartroom/node}"; }

# A git remote as host/owner/repo, lowercased (git@h:o/r.git, https://h/o/r and ssh://u@h/o/r
# are one remote). The same rules as the probe's canon().
node_canon_remote() { # <url>
  local u="$1"
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*@}" ;;
    *@*:*) u="${u#*@}"; u="${u/://}" ;;
    *:*) u="${u/://}" ;;
  esac
  u="${u%/}"; u="${u%.git}"
  printf '%s' "${u,,}"
}

# The machines, as JSON, this one first: [{machine, local, target, via}].
nodes_list_json() {
  local spec label target here rows=()
  spec="$(cfg NODES '' '')"
  if [[ -z "$spec" ]]; then
    radar_machines_json | jq 'map(if .via == "config" then .via = "CHARTROOM_RADAR_MACHINES" else . end)'
    return
  fi
  here="$(radar_machine_name)"
  rows+=("$(jq -cn --arg m "$here" '{machine: $m, local: true, target: null, via: "this machine"}')")
  if [[ "$spec" != none ]]; then
    for label in $spec; do
      target="${label#*=}"; label="${label%%=*}"
      [[ "$label" =~ $CR_NODE_LABEL_RE && "$target" =~ $CR_NODE_TARGET_RE ]] ||
        die "CHARTROOM_NODES: '$label=$target' is not label[=ssh-target] (letters, digits, . _ - @)"
      [[ "$label" != "$here" ]] || continue
      rows+=("$(jq -cn --arg m "$label" --arg t "$target" '{machine: $m, local: false, target: $t, via: "CHARTROOM_NODES"}')")
    done
  fi
  printf '%s\n' "${rows[@]}" | jq -s .
}

# Every machine's probe, side by side, each ended after the timeout: <dir>/<i>.out, .err, .rc.
nodes_probe_all() { # <machines json> <dir> <remote to look for, or "">
  local machines="$1" dir="$2" want="$3" n i loc target cmd limit t pids=()
  limit="$(cfg NODES_TIMEOUT '' 45)"
  [[ "$limit" =~ ^[0-9]+$ ]] && (( limit > 0 )) || die "CHARTROOM_NODES_TIMEOUT must be whole seconds above 0 (got '$limit')"
  n="$(jq length <<<"$machines")"
  for ((i = 0; i < n; i++)); do
    IFS=$'\t' read -r loc target < <(jq -r --argjson i "$i" '.[$i] | [.local, (.target // "")] | @tsv' <<<"$machines")
    if [[ "$loc" == true ]]; then
      ( rc=0; CHARTROOM_LOGIN_SHELL="$(login_shell)" CR_PROBE_PROJECT="$want" bash "$CR_ROOT/lib/nodeprobe.sh" >"$dir/$i.out" 2>"$dir/$i.err" </dev/null || rc=$?; echo "$rc" >"$dir/$i.rc" ) 2>/dev/null &
    else
      cmd="PATH=\"$(radar_remote_path):\$PATH\"${want:+ CR_PROBE_PROJECT='$want'} bash -s"
      ( rc=0; radar_ssh_opts; ssh "${RADAR_SSH_O[@]}" -- "$target" "$cmd" <"$CR_ROOT/lib/nodeprobe.sh" >"$dir/$i.out" 2>"$dir/$i.err" || rc=$?
        echo "$rc" >"$dir/$i.rc" ) 2>/dev/null &
    fi
    pids+=($!)
  done
  for ((t = 0; t < limit * 4; t++)); do
    local any=0 p; for p in "${pids[@]}"; do pid_alive "$p" && { any=1; break; }; done
    [[ $any -eq 1 ]] || break
    sleep 0.25
  done
  for ((i = 0; i < n; i++)); do
    if pid_alive "${pids[$i]}"; then
      kill_tree "${pids[$i]}"; echo 124 >"$dir/$i.rc"; echo "no answer within ${limit}s" >>"$dir/$i.err"
    fi
  done
  wait 2>/dev/null || true
}

# What one probe's outcome says about the machine: ok, incompatible, unreachable, auth (ssh would
# need a person: a key, a password, a host key, a Tailscale check), timeout, or error. Sets
# NODE_CONTACT and NODE_ERR (ssh's or the probe's own last line).
node_contact() { # <out> <err> <rc>
  local first rc; rc="$(cat "$3" 2>/dev/null || echo 1)"
  first="$(head -1 "$1" 2>/dev/null | tr -d '\r')"
  NODE_ERR="$(cat "$2" "$1" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' | grep -v $'\t' | tail -1 | cut -c1-300 || true)"
  if [[ "$rc" == 124 ]]; then NODE_CONTACT=timeout
  elif [[ "$rc" == 0 && "$first" == $'probe_schema\t1' ]]; then NODE_CONTACT=ok; NODE_ERR=""
  elif [[ "$first" == probe_schema$'\t'* && "$first" != $'probe_schema\t1' ]]; then NODE_CONTACT=incompatible; NODE_ERR="probe schema ${first#*$'\t'}; this chartroom reads 1"
  elif [[ "$rc" == 255 ]] && grep -qiE 'permission denied|host key verification failed|too many authentication failures|tailscale' "$2" 2>/dev/null; then NODE_CONTACT=auth
  elif [[ "$rc" == 255 ]]; then NODE_CONTACT=unreachable
  else NODE_CONTACT=error; [[ -n "$NODE_ERR" ]] || NODE_ERR="the probe exited $rc with no output"
  fi
}

# One machine's row: its probe lines as JSON, with its role and UTIL (lib/nodes.sh's header).
NODES_ROW_JQ='
  def n: if . == null or . == "-" or . == "" then null else (tonumber? // null) | if . == null then null else . + 0 end end; # (+ 0: jq 1.7 keeps "3.00" as written)
  def s: if . == null or . == "-" or . == "" then null else . end;
  def r3: if . == null then null else (. * 1000 + 0.5 | floor) / 1000 end;
  ($probe | split("\n") | map(select(length > 0) | split("\t"))) as $r
  | def one($k): ([$r[] | select(.[0] == $k)] | .[0]) // [];
  ($m + {contact: $contact, error: (if $err == "" then null else $err end)})
  + (if $contact != "ok" then {} else
      {host: (one("host")[1] | s), os: ([one("os")[1], one("os")[2]] | map(s) | map(select(. != null)) | join(" ") | s),
       model: (one("model")[1] | s), clock: (one("clock")[1] | n),
       cores: (one("cores")[1] | n), cores_perf: (one("cores_perf")[1] | n), cores_eff: (one("cores_eff")[1] | n),
       cpu_use: (one("cpu_use")[1] | n), cpu_window_s: (one("cpu_use")[2] | n), mem_used_pct: (one("mem_used_pct")[1] | n),
       mem_bytes: (one("mem_bytes")[1] | n), load: [one("load")[1, 2, 3] | n], mem_free_pct: (one("mem_free_pct")[1] | n),
       disk_free_pct: (one("disk_free_pct")[1] | n),
       power: (one("power")[1] | s), battery_pct: (one("battery_pct")[1] | n), hid_idle_s: (one("hid_idle_s")[1] | n),
       initialised: (one("initialised")[1] == "1"), config: (one("config")[1] | s),
       budgets: ([$r[] | select(.[0] == "budget") | {key: .[1], value: (.[2] | s)}] | from_entries
         | with_entries(if (.key | IN("cpu", "mem")) then .value |= n else . end)),
       runner: {hc: (one("runner")[2] | s), hc_version: (one("runner")[3] | s)},
       context: (one("context")[1] | s), agents_live: (one("agents_live")[1] | n),
       crew_live: (one("crew_live")[1] | n), other_agents: (one("other_agents")[1] | n),
       agents: ([$r[] | select(.[0] == "agent" and (.[1] | IN("crew", "xo", "other"))) | map(.[0:120])
         | {kind: .[1], address: (.[2] | s), state: (.[3] | s), name: (.[4] | s), where: (.[5] | s)}] | .[0:80]),
       path_source: (one("path_source")[1] | s),
       tools: ([$r[] | select(.[0] == "tool") | {key: .[1], value: {status: .[2], version: (.[3] | s)}}] | from_entries),
       logins: ([$r[] | select(.[0] == "login" and .[1] != "-") | {key: .[1], value: {status: .[2], detail: (.[3] | s)}}] | from_entries),
       checkouts: (one("checkouts")[1] | n), checkouts_scanned: (one("checkouts")[1] != "-"),
       repos: [$r[] | select(.[0] == "checkout") | {remote: .[1], path: .[2], fetch_age_s: (.[3] | n)} + (if (.[4] // "-") == "-" then {} else {flags: (.[4] | split(","))} end)]}
      | .checkouts_listed = ((.checkouts // 0) == 0 or (.repos | length) > 0)
      | .project = (if $want == "" then null else ([.repos[] | select(.remote == $want)] | .[0]) end)
      | .skew_s = (if .clock then .clock - $now else null end)
      | .role = (if .initialised | not then "not a node"
                 elif .budgets.accept == "off" then "paused: not accepting"
                 elif .power == "battery" and .budgets.on_battery != "allow" then "paused: on battery"
                 else "node" end)
      | .util = (if .initialised and .cores and .budgets.cpu and .budgets.mem and .mem_bytes
                    and .cpu_use != null and .mem_used_pct != null then
                   {cpu: ((.cpu_use + 100 * $c / .cores) / .budgets.cpu),
                    mem: ((.mem_used_pct + 100 * $mg * 1073741824 / .mem_bytes) / .budgets.mem)}
                   | .max = ([.cpu, .mem] | max) | map_values(r3)
                 else null end)
    end)'

nodes_settings() { # sets NODE_C, NODE_MG
  NODE_C="$(cfg WORKER_CPU '' 1.5)"; NODE_MG="$(cfg WORKER_MEM_GB '' 1.5)"
  [[ "$NODE_C" =~ ^[0-9]+(\.[0-9]+)?$ && "$NODE_MG" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    die "CHARTROOM_WORKER_CPU and CHARTROOM_WORKER_MEM_GB must be numbers, such as 1.5 (got '$NODE_C', '$NODE_MG')"
}

# Every machine's row, as one JSON document: {nodes: [...], project, settings}.
nodes_json() { # <remote to look for, or ""> [ssh: 1 for the ssh list alone]
  local want="$1" ssh="${2:-0}" machines dir n i now devs='[]'
  nodes_settings
  machines="$(nodes_list_json)" || exit 1
  if [[ "$ssh" != 1 ]]; then
    devs="$(fleet_devices_json)"
    # an enrolled device is read from its heartbeat, never over ssh as well
    machines="$(jq -c --argjson d "$devs" '([$d[] | select(.status != "revoked") | .name, .aliases[]]) as $known
      | map(select(.local or ((.machine | IN($known[])) | not)))' <<<"$machines")"
  fi
  dir="$(mktemp -d)"
  nodes_probe_all "$machines" "$dir" "$want"
  now="$(date +%s)"; n="$(jq length <<<"$machines")"
  {
    for ((i = 0; i < n; i++)); do
      node_contact "$dir/$i.out" "$dir/$i.err" "$dir/$i.rc"
      jq -n --argjson m "$(jq -c --argjson i "$i" '.[$i]' <<<"$machines")" --rawfile probe "$dir/$i.out" \
        --arg contact "$NODE_CONTACT" --arg err "$NODE_ERR" --arg want "$want" --argjson now "$now" \
        --argjson c "$NODE_C" --argjson mg "$NODE_MG" "$NODES_ROW_JQ"
    done
    n="$(jq length <<<"$devs")"
    for ((i = 0; i < n; i++)); do nodes_device_row "$(jq -c --argjson i "$i" '.[$i]' <<<"$devs")" "$now" "$want"; done
  } | jq -s --arg want "$want" --argjson c "$NODE_C" --argjson mg "$NODE_MG" \
    '{nodes: map(del(.repos)), project: (if $want == "" then null else $want end), settings: {worker_cpu: $c, worker_mem_gb: $mg}}'
  rm -rf "$dir"
}

# One enrolled device's row, from its last heartbeat: online and stale devices show what they last
# said (a stale one marked so); a lost, new, revoked or unheard one shows only why.
nodes_device_row() { # <device json> <now> [remote to look for]
  local d="$1" st contact err probe at
  st="$(jq -r .status <<<"$d")"
  case "$st" in
    online|stale) contact=ok; err="" ;;
    lost) contact=lost; err="no heartbeat for $(jq -r '.seen_age_s // 0 | if . < 3600 then "\(. / 60 | floor)m" else "\(. / 3600 | floor)h" end' <<<"$d")" ;;
    new) contact=new; err="enrolled; no heartbeat yet" ;;
    revoked) contact=revoked; err="its token was revoked" ;;
    *) contact=unknown; err="the app server is not running here, so no heartbeat is heard (chartroom app serve --daemon)" ;;
  esac
  probe="$(jq -r '.probe // ""' <<<"$d")"; at="$(jq -r --argjson now "$2" '.last_seen // $now' <<<"$d")"
  jq -n --argjson m "$(jq -c '{machine: .name, local: false, target: null, via: "heartbeat",
        device: {id, status, last_seen, seen_age_s, version, enrolled, aliases, caps}}' <<<"$d")" \
    --arg probe "$probe" --arg contact "$contact" --arg err "$err" --arg want "${3:-}" --argjson now "$at" \
    --argjson c "$NODE_C" --argjson mg "$NODE_MG" "$NODES_ROW_JQ"
}

# The terminal table.
NODES_TABLE_JQ='
  def d: if . == null then "-" else tostring end;
  def ago: if . == null then "-" elif . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
  def gb: if . == null then "-" else "\(. / 1073741824 | floor)G" end;
  def pc: if . == null then "-" else "\(.)%" end;
  def two: if . == null then "-" else (. * 100 + 0.5 | floor) / 100 | tostring end;
  .project as $p
  | (["NODE", "CONTACT", "ROLE", "CPU USED", "MEM USED", "SIZE", "DISK", "POWER", "IDLE", "CREW", "LOGINS", "TOOLS", "CHECKOUTS", "UTIL"] + (if $p then ["PROJECT"] else [] end)),
    (.nodes[] |
      [ .machine + (if .local then " (here)" else "" end),
        (if .device and .contact == "ok" then "\(.device.status) \(.device.seen_age_s | ago)"
         else .contact + (if .error then ": " + (.error | .[0:60]) else "" end) end) ]
      + (if .contact != "ok" then ["-", "-", "-", "-", "-", "-", "-", "-", "-", "-", "-", "-"] + (if $p then ["-"] else [] end) else
        [ .role,
          (.cpu_use | pc) + (if .budgets.cpu then " of \(.budgets.cpu)%" else "" end) + (if .budgets.cpu and .cpu_use != null and .cpu_use >= .budgets.cpu then " (full)" else "" end),
          (.mem_used_pct | pc) + (if .budgets.mem then " of \(.budgets.mem)%" else "" end) + (if .budgets.mem and .mem_used_pct != null and .mem_used_pct >= .budgets.mem then " (full)" else "" end),
          "\(.cores | d) cores \(.mem_bytes | gb)",
          (if .disk_free_pct == null then "-" else "\(.disk_free_pct)% free" + (if .disk_free_pct < 15 then " (low)" else "" end) end),
          (if .power == "ac" then "AC" + (if .battery_pct then " (battery \(.battery_pct)%)" else "" end)
           elif .power == "battery" then "battery \(.battery_pct | d)%" else "-" end),
          (.hid_idle_s | ago),
          (if .crew_live != null then "\(.crew_live)" else "\(.agents_live | d)" end)
          + (if .crew_live != null and (.other_agents // 0) > 0 then " +\(.other_agents) other" elif .crew_live == null and .agents_live != null then " (all agents)" else "" end),
          ([.logins | to_entries[] | "\(.key):\(.value.status)"] | join(" ") | if . == "" then "-" else . end),
          ([.tools | to_entries[] | select(.value.status == "ok")] | length) as $ok
          | ([.tools | to_entries[] | select(.value.status != "ok") | "\(.value.status):\(.key)"] | join(" ")) as $bad
          | "\($ok) ok" + (if $bad == "" then "" else " " + $bad end),
          (if .checkouts_scanned then (.checkouts | d) else "- (no roots)" end),
          (if .util == null then "-" elif .util.max > 1 then "\(.util.max | two) (full)" else (.util.max | two) end) ]
        + (if $p then [if .device and .checkouts_listed != true then "- (its agent is older)" elif .project then .project.path elif .checkouts_scanned then "no checkout" else "no roots" end] else [] end)
      end))
  | @tsv'

cmd_nodes() {
  local json=0 project="" want="" url doc ssh=0 for=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --for) [[ $# -ge 2 ]] || die "--for needs a task id"; for="$(cmd_resolve "$2")" || exit 1; shift 2 ;;
      --ssh) ssh=1; shift ;;
      --project) [[ $# -ge 2 ]] || die "--project needs a path"; project="$2"; shift 2 ;;
      *) die "nodes: unknown arg $1 (usage: chartroom nodes [--json] [--project PATH] [--ssh] [--for <task>])" ;;
    esac
  done
  if [[ -n "$project" ]]; then
    url="$(git -C "$project" config --get remote.origin.url 2>/dev/null)" || die "nodes: $project has no remote 'origin' (a node knows a project by its remote)"
    want="$(node_canon_remote "$url")"
    [[ "$want" =~ $CR_NODE_REMOTE_RE ]] || die "nodes: cannot read '$url' as host/owner/repo"
  fi
  nodes_settings # (its refusal, here: nodes_json runs in a subshell)
  if [[ -n "$for" ]]; then nodes_for "$for" "$json"; return; fi
  doc="$(nodes_json "$want" "$ssh")" || exit 1
  if [[ $json -eq 1 ]]; then printf '%s\n' "$doc"; return; fi
  [[ -z "$want" ]] || echo "project: $want"
  jq -r "$NODES_TABLE_JQ" <<<"$doc" | table
  # why a tool is broken (the binary and its first line)
  jq -r '.nodes[] | select(.contact == "ok") | .machine as $m | (.tools // {}) | to_entries[]
    | select(.value.status == "error") | "\($m): \(.key) is broken: \(.value.version // "no detail")"' <<<"$doc"
  if jq -e 'any(.nodes[]; .budgets.cpu != null)' <<<"$doc" >/dev/null; then
    echo "a node at either limit (the % after \"of\") takes no new task; chartroom node limits <name|here> 80/70 sets its CPU/memory limits. UTIL: how full it would be with one more worker"
  fi
}

# ---------------------------------------------------------------- node probe / node init

# (this machine's login shell as chartroom's settings name it, the config file included)
node_probe_local() { CHARTROOM_LOGIN_SHELL="$(login_shell)" CR_PROBE_PROJECT="${1:-}" bash "$CR_ROOT/lib/nodeprobe.sh" </dev/null; }

# Writes this machine's node file: its limits, so `chartroom nodes` and placement count it in.
# Defaults: cpu 80% on a machine without a battery (its own probe says) and 50% on one with, memory
# 75%, pause on battery, nice priority, and CHARTROOM_PROJECT_ROOTS as the project roots. It writes
# that one file and nothing else: a node has no home. (--max-workers is taken, and ignored, from
# older scripts: a node is limited by its use, not a count.)
cmd_node_init() {
  local cpu="" mem="" battery="" priority="" roots="" force=0 f probe bat tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-workers) warn "node init: --max-workers is no longer a limit (a node is limited by its CPU and memory use); ignored"; shift 2 ;;
      --cpu) cpu="${2:-}"; shift 2 ;;
      --mem) mem="${2:-}"; shift 2 ;;
      --battery) battery="${2:-}"; shift 2 ;;
      --priority) priority="${2:-}"; shift 2 ;;
      --project-roots) roots="${2-}"; [[ $# -ge 2 ]] || die "--project-roots needs dirs"; shift 2 ;;
      --force) force=1; shift ;;
      *) die "node init: unknown arg $1 (usage: chartroom node init [--cpu PCT] [--mem PCT] [--battery pause|allow] [--priority normal|nice|background] [--project-roots DIRS] [--force])" ;;
    esac
  done
  f="$(node_config_path)"
  [[ ! -e "$f" || $force -eq 1 ]] || die "node init: $f exists; edit it, or run again with --force to rewrite it"
  # this machine's id, minted once and kept across --force (a device is known by it: lib/fleet.sh)
  local nid=""; [[ -f "$f" ]] && nid="$(cfg_value_in "$f" CHARTROOM_NODE_ID)"
  [[ "$nid" =~ $CR_DEVICE_ID_RE ]] || nid="n-$(fleet_rand_hex 6)"
  probe="$(node_probe_local)"
  bat="$(awk -F'\t' '$1 == "battery_pct" {print $2}' <<<"$probe")"
  if [[ -z "$cpu" ]]; then if [[ "$bat" =~ ^[0-9]+$ ]]; then cpu=50; else cpu=80; fi; fi
  mem="${mem:-75}"; battery="${battery:-pause}"; priority="${priority:-nice}"
  [[ -n "$roots" ]] || roots="$(cfg PROJECT_ROOTS CAP_PROJECT_ROOTS '')"
  [[ "$cpu" =~ ^[0-9]+$ ]] && (( cpu >= 1 && cpu <= 100 )) || die "node init: --cpu is a percent of this machine's cores, 1-100 (got '$cpu')"
  [[ "$mem" =~ ^[0-9]+$ ]] && (( mem >= 1 && mem <= 100 )) || die "node init: --mem is a percent of this machine's memory, 1-100 (got '$mem')"
  [[ "$battery" =~ ^(pause|allow)$ ]] || die "node init: --battery is pause or allow (got '$battery')"
  [[ "$priority" =~ ^(normal|nice|background)$ ]] || die "node init: --priority is normal, nice or background (got '$priority')"
  [[ "$roots" =~ ^[A-Za-z0-9_./:~\ -]*$ ]] || die "node init: --project-roots is colon-separated directories (got '$roots')"
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  {
    echo "# chartroom node settings (written by chartroom node init, $(now)): this machine takes crew work"
    echo "# while its CPU and memory use are under these limits (percent; chartroom node limits sets them)."
    echo "# It has no home of its own. CHARTROOM_NODE_ACCEPT=off withdraws it at once."
    echo "CHARTROOM_NODE_CPU_BUDGET=$cpu"
    echo "CHARTROOM_NODE_MEM_BUDGET=$mem"
    echo "CHARTROOM_NODE_ON_BATTERY=$battery"
    echo "CHARTROOM_NODE_PRIORITY=$priority"
    echo "CHARTROOM_NODE_PROJECT_ROOTS=$roots"
    echo "CHARTROOM_NODE_ACCEPT=on"
    echo "CHARTROOM_NODE_ID=$nid"
  } >"$tmp" && mv "$tmp" "$f"
  echo "this machine is a node: $f"
  echo "  takes work under cpu $cpu% and memory $mem% in use, on battery: $battery, priority: $priority, project roots: ${roots:-(none: no checkouts are counted)}"
  [[ "$priority" != background ]] || echo "  note: background priority (taskpolicy -b) keeps workers on the efficiency cores on Apple silicon"
}

# The two limits, as "80/70", or --cpu 80 and/or --mem 70. Sets NL_CPU and NL_MEM ("" = as it is), NL_ACCEPT
# for on|off, and NL_CLONE for --clone on|off (may it clone a project it has no checkout of?).
node_limits_args() { # <args...>
  NL_CPU="" NL_MEM="" NL_ACCEPT="" NL_CLONE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu) NL_CPU="${2:-}"; [[ -n "$NL_CPU" ]] || die "node limits: --cpu needs a percent"; shift 2 ;;
      --mem) NL_MEM="${2:-}"; [[ -n "$NL_MEM" ]] || die "node limits: --mem needs a percent"; shift 2 ;;
      on|off) NL_ACCEPT="$1"; shift ;;
      --clone) NL_CLONE="${2:-}"; [[ "$NL_CLONE" =~ ^(on|off)$ ]] || die "node limits: --clone is on or off"; shift 2 ;;
      */*) NL_CPU="${1%%/*}"; NL_MEM="${1#*/}"; shift ;;
      *) die "node limits: '$1' is not CPU/MEMORY (usage: chartroom node limits [<name|here> 80/70 | <name|here> [--cpu 80] [--mem 70] [--clone on|off]])" ;;
    esac
  done
  local v
  for v in ${NL_CPU:+"$NL_CPU"} ${NL_MEM:+"$NL_MEM"}; do
    [[ "${v%\%}" =~ ^[0-9]{1,3}$ ]] && (( 10#${v%\%} >= 1 && 10#${v%\%} <= 100 )) || die "node limits: a limit is a percent, 1-100 (got '$v')"
  done
  NL_CPU="${NL_CPU%\%}"; NL_MEM="${NL_MEM%\%}"
}

# Sets this machine's own limits, or whether it takes new work at all: those lines of its node file,
# and nothing else in it.
node_limits_set() { # <cpu or ""> <mem or ""> [on|off or ""] [clone: on|off or ""]
  local f k v tmp; f="$(node_config_path)"
  [[ -f "$f" ]] || { echo "this machine is not a node yet (chartroom node init)" >&2; return 1; }
  for k in CPU_BUDGET MEM_BUDGET ACCEPT CLONE; do
    case "$k" in CPU_BUDGET) v="$1" ;; MEM_BUDGET) v="$2" ;; ACCEPT) v="${3:-}" ;; CLONE) v="${4:-}" ;; esac
    [[ -n "$v" ]] || continue
    tmp="$f.tmp.$$"
    awk -v k="CHARTROOM_NODE_$k" -v v="$v" '$0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!d) print k "=" v; d = 1; next } { print } END { if (!d) print k "=" v }' "$f" >"$tmp" &&
      mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  done
  if [[ "$(cfg_value_in "$f" CHARTROOM_NODE_ACCEPT)" == off ]]; then echo "takes no new work (off)"; return 0; fi
  local c=""; [[ "$(cfg_value_in "$f" CHARTROOM_NODE_CLONE)" != on ]] || c="; clones a project it has no checkout of"
  echo "takes new work under cpu $(cfg_value_in "$f" CHARTROOM_NODE_CPU_BUDGET)% and memory $(cfg_value_in "$f" CHARTROOM_NODE_MEM_BUDGET)% in use$c"
}

# chartroom node limits                       every node's use against its two limits
# chartroom node limits <name|here> off|on    it takes no new work at all; or does again
# chartroom node limits <name|here> --clone on|off   it may clone a project it has no checkout of, and
#                                             run that project's setup once (lib/guest.sh); off at first
# chartroom node limits <name|here> 80/70     sets them: here in this machine's node file, on a device
#                                             over the connection (one that is away takes it when back)
cmd_node_limits() {
  local doc who id rc=0 st
  if [[ $# -eq 0 ]]; then
    nodes_settings; doc="$(nodes_json "" 0)" || exit 1
    jq -r 'def pc: if . == null then "-" else "\(.)%" end;
      ["NODE", "CPU USED", "CPU LIMIT", "MEMORY USED", "MEMORY LIMIT", "TAKES NEW WORK"],
      (.nodes[] | [.machine + (if .local then " (here)" else "" end), (.cpu_use | pc), (.budgets.cpu | pc), (.mem_used_pct | pc), (.budgets.mem | pc),
        (if .contact != "ok" then "no: \(.contact)" elif .role != "node" then "no: \(.role)"
         elif .util == null then "no: its use is not known"
         elif .cpu_use >= .budgets.cpu then "no: cpu at its limit" elif .mem_used_pct >= .budgets.mem then "no: memory at its limit" else "yes" + (if .budgets.clone == "on" then " (clones)" else "" end) end)])
      | @tsv' <<<"$doc" | table
    return 0
  fi
  who="$1"; shift
  node_limits_args "$@"
  [[ -n "$NL_CPU$NL_MEM$NL_ACCEPT$NL_CLONE" ]] || die "usage: chartroom node limits [<name|here> 80/70|off|on | <name|here> [--cpu 80] [--mem 70] [--clone on|off]]"
  if [[ "$who" == here || "$who" == "$(radar_machine_name)" ]]; then
    printf 'here: '; node_limits_set "$NL_CPU" "$NL_MEM" "$NL_ACCEPT" "$NL_CLONE" || exit 1
    return 0
  fi
  id="$(fleet_resolve "$who")"; st="$(fleet_device_json "$id" | jq -r .status)"
  [[ "$st" != revoked ]] || die "node limits: $who is revoked"
  [[ -z "$NL_CLONE" ]] || fleet_device_json "$id" | jq -e '(.caps // []) | index("clone")' >/dev/null ||
    die "node limits: $who's chartroom is older and cannot clone (chartroom node update $who)"
  local p; p="$(jq -cn --arg c "$NL_CPU" --arg m "$NL_MEM" --arg a "$NL_ACCEPT" --arg k "$NL_CLONE" '{cpu: $c, mem: $m, accept: $a, clone: $k}')"
  if [[ "$st" != online ]]; then
    fleet_enqueue "$id" limits "$p" >/dev/null
    echo "$who is $st: its limits are set when it is back"; return 0
  fi
  printf '%s: ' "$who"
  fleet_call "$id" limits "$p" 30 || rc=$?
  (( rc != 124 )) || die "node limits: $who did not take it within 30s; nothing was set"
  return "$rc"
}

# chartroom nodes --for <task>: each machine and why it would take that task now or not, as dispatch
# would decide (nothing is held or sent).
nodes_for() { # <id> <json 0|1>
  local id="$1" devs b out
  need_task "$id"
  [[ -z "$(meta "$id" dispatched)" || -n "$(meta "$id" closed)" ]] || { echo "$id is dispatched already, on $(if [[ "$(backend_runner "$id")" == node ]]; then node_name_of "$id"; else echo "this machine"; fi)"; return 0; }
  devs="$(fleet_devices_json)"
  place_on "$devs" || { echo "$id would run here: no machine is placed on (no device, or CHARTROOM_PLACEMENT=local)"; return 0; }
  select_backend "$id" >/dev/null 2>&1 || true; b="$SELECTED"
  [[ "$b" =~ ^($(node_backends))$ ]] || { echo "$id would run here: only $(node_backends | tr '|' ' ') workers are placed (it is ${b:-unknown})"; return 0; }
  out="$(place_choose "$id" "$(place_needs "$id" "$b")" "$(place_rows "$devs")" '[]' 1 0)" || die "placement failed"
  if [[ "$2" == 1 ]]; then printf '%s\n' "$out"; return 0; fi
  jq -r "$PLACE_JQ"'"\(.pick.name // "none: it would not be dispatched") takes \($id) now" ,
    (.nodes[] | "  \(.name): " + (if .why then "no: \(.why)" else "yes, \(if .u then "\(.u * 100 | floor)% full with it" else "use not known" end)"
      + (if (.prep // [] | length) > 0 then ", after cloning \(.prep | join(" and "))" else "" end) end))' --arg id "$id" <<<"$out"
}

# This machine's row, every checkout listed (what placement goes by, lib/place.sh).
node_row_local() {
  local dir; dir="$(mktemp -d)"; nodes_settings
  CR_PROBE_CHECKOUTS=1 node_probe_local >"$dir/out" 2>"$dir/err" && echo 0 >"$dir/rc" || echo $? >"$dir/rc"
  node_contact "$dir/out" "$dir/err" "$dir/rc"
  jq -cn --argjson m "$(jq -cn --arg m "$(radar_machine_name)" '{machine: $m, local: true, target: null, via: "this machine"}')" \
    --rawfile probe "$dir/out" --arg contact "$NODE_CONTACT" --arg err "$NODE_ERR" --arg want "" --argjson now "$(date +%s)" \
    --argjson c "$NODE_C" --argjson mg "$NODE_MG" "$NODES_ROW_JQ"
  rm -rf "$dir"
}

cmd_node() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    probe)
      case "${1:-}" in
        "") node_probe_local ;;
        --json)
          nodes_settings; node_row_local | jq . ;;
        *) die "usage: chartroom node probe [--json]" ;;
      esac ;;
    init) cmd_node_init "$@" ;;
    limits) cmd_node_limits "$@" ;;
    add) cmd_node_add "$@" ;;
    rename) cmd_node_rename "$@" ;;
    revoke) cmd_node_revoke "$@" ;;
    rotate) cmd_node_rotate "$@" ;;
    update) cmd_node_update "$@" ;;
    ping) cmd_node_ping "$@" ;;
    prepare) cmd_node_prepare "$@" ;;
    # (internal: the device agent's look at its guest agy workers, lib/guest.sh guest_agy_look_all)
    agy-look)
      [[ -n "${CHARTROOM_GUEST:-}" ]] || die "node agy-look runs only in a guest home on a device (the brain's watch looks at its own)"
      local m id
      for m in "$CR_HOME"/tasks/*/meta.json; do
        [[ -f "$m" ]] || continue
        id="${m%/meta.json}"; id="${id##*/}"
        is_closed "$id" && continue
        [[ "$(meta "$id" backend)" == hc:agy && -n "$(meta "$id" dispatched)" ]] || continue
        hc_agy_look "$id"
      done ;;
    *) die "usage: chartroom node probe [--json] | node init [--cpu PCT] [--mem PCT] [--battery pause|allow] [--priority normal|nice|background] [--project-roots DIRS] [--force] | node limits [<name|here> CPU/MEM|off|on|--clone on|off] | node add [--name N] [--alias A]... [--replace NAME|ID] | node rename <name|id> <new> | node revoke <name|id> | node rotate <name|id> | node update <name|id>...|--all | node ping <name|id> | node prepare <name> <repo>..." ;;
  esac
}

# For doctor: this machine's node file, read as the probe reads it (no probe run).
node_doctor_line() {
  local f k v out=""; f="$(node_config_path)"
  if [[ ! -f "$f" ]]; then echo "node:     not a node (chartroom node init makes this machine one; chartroom nodes lists them)"; return; fi
  for k in CPU_BUDGET MEM_BUDGET ON_BATTERY PRIORITY ACCEPT CLONE; do
    v="$(cfg_value_in "$f" "CHARTROOM_NODE_$k")"; [[ "$k" != CLONE || -n "$v" ]] || continue; out+=" ${k,,}=${v:--}"
  done
  echo "node:     $f:$out"
}
