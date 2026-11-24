# shellcheck shell=bash
# place.sh - where a new task runs (docs/multi-machine.md, "Placement"). `dispatch` sends each task
# that can run on another machine to the node with the most room under its own two limits, the
# share of its CPU and of its memory that may be in use; a node at or over either takes nothing new.
# No one has to say where: the brain's own machine is a node like any other, and --node pins.
#
#   CHARTROOM_PLACEMENT=spread|pack|local   the emptiest node (the default), the fullest that still
#                                           has room, or off: everything runs here, as before
#   CHARTROOM_PLACE_HOLD_SECONDS=180        how long a worker just placed counts at its assumed cost
#                                           (CHARTROOM_WORKER_CPU, _MEM_GB) on top of what is measured
#
# With no device enrolled (or none whose agent can report its use), nothing here happens at all.
#
# What a node has in use is measured there (lib/nodeprobe.sh: cpu_use over the last minute,
# mem_used_pct now) and read from its last heartbeat, so it is up to 15 s and a minute's average
# behind. A burst of dispatches would all see the same empty node; so each placement leaves a hold,
# fleet/placed/<home>.<id>.json, counted at full cost until the measured use has had time to show
# the worker. The choice and its hold are made under one lock, for every home on this machine. The
# device checks its own limits again when it takes the work (lib/guest.sh), with use it reads then
# and the workers it was just given; refused, the task goes to the next node.
#
# What keeps a task on this machine (PN .here): a pin (set node=here), a runner that is not hc, a
# worker or branch it already has here, a base no other machine can fetch, a project with no
# remote, or a brief that names files other machines do not have and that cannot go along.
# What a node must have: hc answering, the task's agent installed and logged in, every tool the task
# needs working (--needs, `needs=` in projects.md, and docker when the brief talks of it), and a
# checkout of the project and of any other repo the brief points into.

CR_NEEDS_TOOLS='docker|ruby|go|node|gh|codex|claude|herdr|tmux'
CR_CARRY_MAX_FILE=1048576
CR_CARRY_MAX_ALL=4194304
CR_CARRY_MAX_FILES=100

place_mode() {
  local m; m="$(cfg PLACEMENT '' spread)"
  [[ "$m" =~ ^(spread|pack|local)$ ]] || die "CHARTROOM_PLACEMENT is spread, pack or local (got '$m')"
  printf '%s' "$m"
}
place_hold_s() {
  local s; s="$(cfg PLACE_HOLD_SECONDS '' 180)"
  [[ "$s" =~ ^[0-9]+$ ]] || die "CHARTROOM_PLACE_HOLD_SECONDS is whole seconds (got '$s')"
  printf '%s' "$s"
}

# Is there anywhere but here to place work? (a guest home never places: it is the placed)
place_on() { # <fleet devices json>
  [[ "${CHARTROOM_GUEST:-}" != 1 && "$(place_mode)" != local ]] &&
    jq -e 'any(.[]; .status != "revoked" and (.caps | index("place")))' <<<"$1" >/dev/null
}

# "docker,ruby" checked and sorted; dies on a name no probe reports.
needs_norm() { # <comma list|none>
  local l out=()
  [[ "$1" != none ]] || { printf none; return; }
  for l in ${1//,/ }; do
    [[ "$l" =~ ^($CR_NEEDS_TOOLS)$ ]] || die "needs: '$l' is not something a node is checked for (${CR_NEEDS_TOOLS//|/, })"
    out+=("$l")
  done
  (( ${#out[@]} > 0 )) || die "needs: a comma list of ${CR_NEEDS_TOOLS//|/, }, or none"
  printf '%s\n' "${out[@]}" | sort -u | paste -sd, -
}

# The tools a task needs, one per line: its own (--needs, set needs=), its project's (projects.md:
# `- <name>: ...; needs=docker,ruby`), and docker when its brief talks of docker. `needs=none` on the
# task says none, whatever the brief mentions.
place_tools() { # <id>
  local id="$1" own p
  own="$(meta "$id" needs)"
  [[ "$own" != none ]] || return 0
  p="$(grep -E "^- $(basename "$(meta "$id" project)"):" "$CR_HOME/projects.md" 2>/dev/null | grep -oE '(^|[;: ])needs=[a-z,]+' | head -1 | sed 's/.*needs=//' || true)"
  {
    tr ',' '\n' <<<"$own"; tr ',' '\n' <<<"$p"
    if sed '/^## Authority/,/^## Worker protocol/d' "$(tdir "$id")/brief.md" 2>/dev/null | grep -qiE '(^|[^a-z0-9])(docker|docker-compose|testcontainers?)([^a-z0-9]|$)'; then echo docker; fi
  } | grep -E "^($CR_NEEDS_TOOLS)$" | sort -u || true
}

# Every path the brief names that exists on this machine, one per line, absolute: the brief says
# /abs or ~/home paths; what chartroom itself wrote into it (its own record, its helper) is left out.
place_brief_paths() { # <id>
  local id="$1" d p q
  d="$(tdir "$id")"
  grep -oE "(^|[[:space:]\`\"'(<=\[])(~|/[A-Za-z0-9._@+-]+)(/[A-Za-z0-9._@+-]+)*/?" "$d/brief.md" 2>/dev/null |
    sed -E "s/^[[:space:]\`\"'(<\[]//" | sort -u | while IFS= read -r p; do
      [[ "$p" != =* ]] || continue # (CHARTROOM_HOME=...: the helper's, rewritten on the device)
      p="${p%/}"; while [[ "$p" == *[.,:] ]]; do p="${p%?}"; done
      q="${p/#\~/$HOME}"
      case "$q" in
        ""|/|/tmp|/private/tmp|/dev|/etc|/usr|/bin|/opt|/var|"$HOME") continue ;;
        /usr/*|/bin/*|/sbin/*|/etc/*|/dev/*|/System/*|/Library/*|/opt/homebrew/*|/Applications/*) continue ;;
        "$CR_BIN"|"$d/report.md"|"$d/plan.md"|"$d/inbox.md"|"$d/brief.md"|"$d"/events.*|"$d/final.md") continue ;;
      esac
      [[ -e "$q" ]] && printf '%s\n' "$q"
    done | sort -u
  return 0
}

# May this file of the home go along with a task? (text and pictures a brief points at; never a
# dotfile, a symlink, what chartroom keeps its own state in, or anything that looks like a secret)
place_carry_ok() { # <path relative to the home>
  local rel="$1" base; base="${rel##*/}"
  [[ "$rel" =~ ^[A-Za-z0-9_@+][A-Za-z0-9._@+-]*(/[A-Za-z0-9_@+][A-Za-z0-9._@+-]*)*$ && "$rel" != *..* ]] || return 1
  [[ "$rel" == */* || "$rel" == *.md || "$rel" == *.log ]] || return 1
  case "$rel" in permits/*|*/permits/*|.*|*/.*) return 1 ;; esac
  case "$base" in meta.*|hooks.log|claude-settings.json|launcher*|pane.log|config|*.pem|*.key|*.p8|*.p12|id_*) return 1 ;; esac
  [[ ! "${base,,}" =~ (secret|token|credential|password|passwd) ]] || return 1
  [[ "${base,,}" =~ \.(md|txt|log|json|jsonl|ndjson|csv|tsv|html|htm|css|svg|png|jpg|jpeg|gif|webp|pdf|yml|yaml|diff|patch|sql|rb|ts|tsx|js|jsx|py|sh)$ ]] || return 1
  [[ -f "$CR_HOME/$rel" && ! -L "$CR_HOME/$rel" ]] || return 1
  [[ "$(phys_dir "$(dirname "$CR_HOME/$rel")")" == "$(phys_dir "$CR_HOME")"* ]] || return 1
  (( $(wc -c <"$CR_HOME/$rel") <= CR_CARRY_MAX_FILE )) || return 1
  ! grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$CR_HOME/$rel"
}

# Why a task stays on this machine, whatever its brief says ("" when it need not).
place_stays() { # <id>
  local id="$1" project; project="$(meta "$id" project)"
  if [[ -n "$(meta "$id" node_here)" ]]; then echo "pinned here"
  elif [[ -z "$(home_name_of "$CR_HOME")" ]]; then echo "this home is not registered (chartroom homes add), so another machine cannot report back to it"
  elif [[ -n "$(meta "$id" migrated_from)" ]]; then echo "it was moved here with its work"
  elif [[ -n "$(meta "$id" worktree)" && -d "$(meta "$id" worktree)" ]]; then echo "its worktree is here"
  elif [[ "$(meta "$id" kind)" == ship ]] && git -C "$project" rev-parse -q --verify "refs/heads/$(meta "$id" branch)" >/dev/null 2>&1; then echo "its branch is here"
  elif [[ ! "$(place_remote "$project")" =~ $CR_NODE_REMOTE_RE ]]; then echo "its project has no remote another machine could have a checkout of"
  elif [[ -z "$(git -C "$project" branch -r --contains "$(meta "$id" base_sha)" --list 'origin/*' 2>/dev/null | head -1)" ]]; then echo "its base is on no branch of the remote, only here"
  fi
}
place_remote() { node_canon_remote "$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)"; } # <checkout>

# What the brief's paths mean for another machine, as JSON: {here: why the task cannot leave for
# them or null, repos: other checkouts it points into, carry: paths of this home it names (relative
# to it), files: every file under those, which go along}. The scan stops at the first that cannot.
place_scan() { # <id>
  local id="$1" project proot hroot here="" repos=() carry=() files=() p rel top f got url all=0
  project="$(meta "$id" project)"
  proot="$(phys_dir "$(git -C "$project" rev-parse --show-toplevel 2>/dev/null || echo "$project")")"; hroot="$(phys_dir "$CR_HOME")"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    rel="" got=()
    if [[ ( "$p/" == "$CR_HOME"/* || "$p/" == "$hroot"/* ) && "$p/" != "$proot"/* ]]; then
      case "$p/" in "$CR_HOME"/*) rel="${p#"$CR_HOME"}" ;; *) rel="${p#"$hroot"}" ;; esac
      rel="${rel#/}"
      if [[ -d "$p" && -n "$rel" ]]; then
        while IFS= read -r f; do got+=("${f#"$CR_HOME/"}"); done < <(find "$CR_HOME/$rel" -type f ! -name .DS_Store 2>/dev/null | head -n $((CR_CARRY_MAX_FILES + 1)))
      elif [[ -n "$rel" ]]; then got=("$rel"); fi
      (( ${#got[@]} > 0 )) || { here="its brief names $p, which is only on this machine"; break; }
      for f in "${got[@]}"; do
        place_carry_ok "$f" || { here="its brief names $p, and $f does not go to another machine"; break 2; }
        all=$((all + $(wc -c <"$CR_HOME/$f"))); files+=("$f")
      done
      carry+=("$rel")
      (( ${#files[@]} <= CR_CARRY_MAX_FILES && all <= CR_CARRY_MAX_ALL )) || { here="its brief names more of this home's files than go along (at $p)"; break; }
      continue
    fi
    # a path in the project, or in another checkout: it is there too, if git tracks it
    top="$(git -C "$(if [[ -d "$p" ]]; then printf '%s' "$p"; else dirname "$p"; fi)" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$top" ]]; then
      [[ "$proot/" != "$p"/* ]] || continue # (a directory the project is in)
      here="its brief names $p, which is only on this machine"; break
    fi
    top="$(phys_dir "$top")"
    if [[ "$top" != "$(phys_dir "$p")" && -z "$(git -C "$top" ls-files -- "$p" 2>/dev/null | head -1)" ]]; then here="its brief names $p, which is not in git"; break; fi
    [[ "$top" != "$proot" ]] || continue
    [[ -d "$top/.git" ]] || { here="its brief names $p, a worktree on this machine"; break; }
    url="$(place_remote "$top")"
    [[ "$url" =~ $CR_NODE_REMOTE_RE ]] || { here="its brief names $p, which is only on this machine"; break; }
    repos+=("$url")
  done < <(place_brief_paths "$id")
  jq -cn --arg here "$here" --arg repos "$(printf '%s\n' "${repos[@]+"${repos[@]}"}")" \
    --arg carry "$(printf '%s\n' "${carry[@]+"${carry[@]}"}")" --arg files "$(printf '%s\n' "${files[@]+"${files[@]}"}")" '
    def l: split("\n") | map(select(length > 0)) | unique;
    {here: (if $here == "" then null else $here end), repos: ($repos | l), carry: ($carry | l), files: ($files | l)}'
}

# What a task asks of a node, as JSON: {agent, tools, repos (its project's first among them), here:
# why it must stay on this machine or null, carry, files}.
place_needs() { # <id> <backend it would run there, hc:claude ...>
  local stays scan='{"here":null,"repos":[],"carry":[],"files":[]}'
  stays="$(place_stays "$1")"
  [[ -n "$stays" ]] || scan="$(place_scan "$1")"
  local agent=""; [[ "$2" != hc:* ]] || agent="${2#hc:}"
  jq -c --arg agent "$agent" --arg stays "$stays" --arg tools "$(place_tools "$1")" --arg own "$(place_remote "$(meta "$1" project)")" '
    . + {agent: $agent, tools: ($tools | split("\n") | map(select(length > 0))),
         repos: ((if $own == "" then [] else [$own] end) + .repos | unique),
         here: (if $stays != "" then $stays else .here end)}' <<<"$scan"
}

# Why a node cannot take one more worker of that task now, or null; and how full it would be.
# Input: a node's row (lib/nodes.sh). $held: workers just placed there. $limits: false checks all
# but the two limits. Shared by the brain's choice and the device's own check.
PLACE_JQ='
  def pc: (. + 0.5 | floor | tostring) + "%";
  def place_limit($held; $c; $mg):
    if .cpu_use == null or .mem_used_pct == null or (.cores // 0) == 0 or (.mem_bytes // 0) == 0 then
      # (this machine, unread, is the last resort: a probe that fails must not stop all work here)
      (if .local then null else "its CPU or memory use could not be read" end)
    else (.budgets.cpu // 80) as $cl | (.budgets.mem // 80) as $ml
      | (100 * $c / .cores) as $cc | (100 * $mg * 1073741824 / .mem_bytes) as $mc
      | if .cpu_use >= $cl then "cpu \(.cpu_use | pc) in use, its limit is \($cl)%"
        elif .mem_used_pct >= $ml then "memory \(.mem_used_pct | pc) in use, its limit is \($ml)%"
        elif .cpu_use + $cc * ($held + 1) > $cl then "cpu \(.cpu_use | pc) in use and about \($cc * ($held + 1) | pc) for this worker\(if $held > 0 then " and \($held) just placed" else "" end) is over its \($cl)% limit"
        elif .mem_used_pct + $mc * ($held + 1) > $ml then "memory \(.mem_used_pct | pc) in use and about \($mc * ($held + 1) | pc) for this worker\(if $held > 0 then " and \($held) just placed" else "" end) is over its \($ml)% limit"
        else null end end;
  def place_u($held; $c; $mg):
    if .cpu_use == null or .mem_used_pct == null or (.cores // 0) == 0 or (.mem_bytes // 0) == 0 then null
    else [ (.cpu_use + 100 * $c * ($held + 1) / .cores) / (.budgets.cpu // 80),
           (.mem_used_pct + 100 * $mg * 1073741824 * ($held + 1) / .mem_bytes) / (.budgets.mem // 80) ] | max end;
  def place_paused: if .budgets.accept == "off" then "it is not accepting work" elif .role == "paused: on battery" then "it is on battery" else null end;
  def place_lacks($n):
    . as $row
    | ([$n.tools[] | select(($row.tools[.].status // "missing") != "ok") | "\(.) is \($row.tools[.].status // "missing")"] | .[0])
      // (if ($n.tools | index("gh")) and ($row.logins.gh.status // "missing") != "ok" then "gh is not logged in" else null end);
  def place_remote_lacks($n):
    if $n.agent != "" and .runner.hc != "up" then "hc is not answering"
    elif $n.agent != "" and (.tools[$n.agent].status // "missing") != "ok" then "\($n.agent) is \(.tools[$n.agent].status // "missing")"
    elif $n.agent != "" and (.logins[$n.agent].status // "missing") != "ok" then "\($n.agent) is not logged in"
    elif (.disk_free_pct // 100) < 15 then "its disk is \(.disk_free_pct)% free"
    else . as $row | ([$n.repos[] | . as $r | select(any($row.repos[]?; .remote == $r) | not) | "no checkout of \($r)"] | .[0]) end;'

place_holds() { # -> {"<device id|here>": count}, of the holds still counted; old ones are dropped
  local d f now hold; d="$(fleet_dir)/placed"; hold="$(place_hold_s)"; now="$(date +%s)"
  shopt -s nullglob
  for f in "$d"/*.json; do
    if (( now - $(jq -r '.at // 0' "$f" 2>/dev/null || echo 0) > hold )); then rm -f "$f"; fi
  done
  local left=("$d"/*.json); shopt -u nullglob
  if (( ${#left[@]} == 0 )); then echo '{}'; return; fi
  jq -s -c 'group_by(.node) | map({key: .[0].node, value: length}) | from_entries' "${left[@]}"
}
place_hold_file() { printf '%s/placed/%s.%s.json' "$(fleet_dir)" "$(home_name_of "$CR_HOME")" "$1"; } # <id>
place_hold() { fleet_write "$(place_hold_file "$1")" "$(jq -cn --arg n "$2" --argjson at "$(date +%s)" '{node: $n, at: $at}')"; } # <id> <device id|here>
place_unhold() { rm -f "$(place_hold_file "$1")"; }

# Every node's row, this machine's first: what is measured here now, and each device's last word.
place_rows() { # <fleet devices json>
  local n i now; nodes_settings; now="$(date +%s)"; n="$(jq length <<<"$1")"
  { node_row_local
    for ((i = 0; i < n; i++)); do nodes_device_row "$(jq -c --argjson i "$i" '.[$i]' <<<"$1")" "$now"; done
  } | jq -s -c .
}

# The choice for a task, with the hold it leaves (not with dry=1): {pick: {id, name} or null, nodes:
# [{id, name, why, u, cpu, mem, ...}]}. The rows are read before the lock; the choice is made in it.
place_choose() { # <id> <needs json> <rows json> <excluded ids json> <dry 0|1> <over 0|1>
  local out pick
  fleet_lock
  out="$(jq -cn --argjson rows "$3" --argjson n "$2" --argjson held "$(place_holds)" --argjson x "$4" --arg mode "$(place_mode)" \
    --argjson c "$NODE_C" --argjson mg "$NODE_MG" --arg over "$6" "$PLACE_JQ"'
    [$rows[] | . as $r | (if .local then "here" else .device.id end) as $id | ($held[$id] // 0) as $h
      | select(.local or .device.status != "revoked")
      | {id: $id, name: .machine, local: .local, held: $h, cpu: .cpu_use, cpu_limit: (.budgets.cpu // 80), mem: .mem_used_pct, mem_limit: (.budgets.mem // 80),
         u: (place_u($h; $c; $mg)),
         why: ((if ($x | index($id)) then "it refused" else null end)
           // (if .local then null
               elif $n.here != null then "the task stays on this machine: " + $n.here
               elif .device.status != "online" then "it is " + .device.status
               elif (.device.caps | index("place")) == null then "its agent is older (chartroom node update \(.machine))"
               else null end)
           // (if .contact != "ok" and (.local | not) then "it could not be read: \(.error // .contact)" else null end)
           // place_paused // place_lacks($n)
           // (if .local then null else place_remote_lacks($n) end)
           // (if $over == "1" then null else place_limit($h; $c; $mg) end))}]
    | . as $nodes
    | ([$nodes[] | select(.why == null)] | sort_by([(if $mode == "pack" then -(.u // 0) else (.u // 9) end), (if .local then 0 else 1 end), .name]) | .[0]) as $p
    | {pick: (if $p then {id: $p.id, name: $p.name} else null end), nodes: $nodes, mode: $mode}')" || { fleet_unlock; return 1; }
  pick="$(jq -r '.pick.id // empty' <<<"$out")"
  [[ -z "$pick" || "$5" == 1 ]] || place_hold "$1" "$pick"
  fleet_unlock
  printf '%s' "$out"
}

# A choice in words: "m3: cpu 4% of 90%, memory 22% of 75%; here: ..." (the nodes and why not)
place_words() { # <choice json>
  jq -r "$PLACE_JQ"'[.nodes[] | "\(.name): cpu \(.cpu | if . == null then "?" else pc end) of \(.cpu_limit)%, memory \(.mem | if . == null then "?" else pc end) of \(.mem_limit)%"
    + (if .why then " (\(.why))" else "" end)] | join("; ")' <<<"$1"
}

# Is this task placed at all, and where? Called by dispatch once its backend is chosen (SELECTED).
# Sets PLACED to "" (not placed: as before), "here", or a device's id, after which the task's record
# says it runs there. Dies when every node is at its limit or lacks what the task needs.
place_task() { # <id> <over 0|1> <dry 0|1> [refused ids json]
  local id="$1" over="$2" dry="$3" x="${4:-[]}" devs needs rows out pick name b nb why
  PLACED="" PLACE_WORDS=""
  place_mode >/dev/null # (its refusal, here: place_on reads it in a subshell)
  devs="$(fleet_devices_json)"
  place_on "$devs" || return 0
  b="$SELECTED"
  if [[ "${b%%:*}" == node ]]; then
    # pinned by the commander (or placed before): that node, if it has room
    nodes_settings
    local did row; did="$(meta "$id" node)"
    row="$(jq -c --arg i "$did" '.[] | select(.id == $i)' <<<"$devs")"
    if [[ -n "$row" && "$(jq -r .status <<<"$row")" == online && -z "$(meta "$id" dispatched)" ]] && jq -e '.caps | index("place")' <<<"$row" >/dev/null; then
      row="$(nodes_device_row "$row" "$(date +%s)")"
      why="$(jq -r --argjson h "$(place_holds | jq --arg i "$did" '.[$i] // 0')" --argjson c "$NODE_C" --argjson mg "$NODE_MG" --arg over "$over" \
        "$PLACE_JQ"' place_paused // (if $over == "1" then null else place_limit($h; $c; $mg) end) // empty' <<<"$row")"
      if [[ -n "$why" ]]; then
        [[ "$dry" == 1 ]] || log_event "$id" note "not dispatched: it is pinned to $(node_name_of "$id"), and $why"
        die "not dispatched: $id is pinned to $(node_name_of "$id"), and $why (--over-limit sends it all the same; chartroom set $id node=any lets it go where there is room)"
      fi
    fi
    [[ "$dry" == 1 ]] || place_hold "$id" "$did"
    PLACED="$did"; return 0
  fi
  nb="$(node_backends)"
  [[ "$b" =~ ^($nb)$ ]] || return 0
  if [[ -n "$(meta "$id" dispatched)" ]]; then return 0; fi # (a worker started again where it was: not new work)
  needs="$(place_needs "$id" "$b")"
  rows="$(place_rows "$devs")"
  nodes_settings
  out="$(place_choose "$id" "$needs" "$rows" "$x" "$dry" "$over")" || die "placement failed"
  PLACE_WORDS="$(place_words "$out")"
  pick="$(jq -r '.pick.id // empty' <<<"$out")"; name="$(jq -r '.pick.name // empty' <<<"$out")"
  if [[ -z "$pick" ]]; then
    [[ "$dry" == 1 ]] || log_event "$id" note "not dispatched: no node can take it now. $PLACE_WORDS"
    die "not dispatched: no node can take $id now. $PLACE_WORDS. Dispatch it again when one has room (chartroom node limits shows and sets the limits), or add --over-limit."
  fi
  PLACED="$pick"
  if [[ "$dry" == 1 ]]; then PLACE_NAME="$name"; return 0; fi
  if [[ "$pick" == here ]]; then
    log_event "$id" note "placed here$(jq -r 'if .here then " (it stays on this machine: \(.here))" else "" end' <<<"$needs"). $PLACE_WORDS"
    return 0
  fi
  meta_set "$id" node "$pick"; meta_set "$id" node_name "$name"; meta_set "$id" node_backend "$b"; meta_set "$id" node_placed 1
  meta_set "$id" node_source "$(meta "$id" backend_source)"
  meta_set "$id" backend "node:${b#*:}"; meta_set "$id" backend_source explicit
  SELECTED="node:${b#*:}"
  log_event "$id" note "placed on $name. $PLACE_WORDS"
  echo "placed on $name: $PLACE_WORDS"
}

# Undoes a placement the node refused before anything was made there.
place_undo() { # <id>
  local id="$1"
  rm -f "$(node_map "$(node_home)" "$id")"
  place_unhold "$id"
  meta_set "$id" backend "$(meta "$id" node_backend)"; meta_set "$id" backend_source "$(meta "$id" node_source)"
  meta_set "$id" node ""; meta_set "$id" node_name ""; meta_set "$id" node_placed ""; meta_set "$id" node_cmd ""
  meta_set "$id" dispatched ""
}

# The files of this home a task's brief names, for its dispatch on a device: {carry: [...], files:
# [{rel, b64}], missing: why the rest cannot go, or null}.
place_carry_json() { # <id>
  local n f tmp; n="$(place_scan "$1")"
  if [[ "$(jq '.files | length' <<<"$n")" == 0 ]]; then jq -c '{carry: [], files: [], missing: .here}' <<<"$n"; return; fi
  tmp="$(mktemp)"
  while IFS= read -r f; do
    jq -cn --arg r "$f" --rawfile b <(base64 <"$CR_HOME/$f" | tr -d '\n') '{rel: $r, b64: $b}'
  done < <(jq -r '.files[]' <<<"$n") >"$tmp"
  jq -c --slurpfile f "$tmp" '{carry: .carry, files: $f, missing: .here}' <<<"$n"
  rm -f "$tmp"
}

# ---------------------------------------------------------------- on a device: may it take this now?

# The device's own answer to the same question, when the work is taken: its use now, its limits, the
# workers it was given in the last CHARTROOM_PLACE_HOLD_SECONDS. Prints why not, or nothing.
place_refuse_here() { # <needs json {agent, tools, repos}> <over 0|1>
  local row held; nodes_settings
  row="$(node_row_local)"; held="$(guest_recent_count "$(place_hold_s)")"
  jq -r --argjson n "$1" --argjson h "$held" --argjson c "$NODE_C" --argjson mg "$NODE_MG" --arg over "$2" "$PLACE_JQ"'
    (if .contact != "ok" then "it could not read itself: \(.error // .contact)" else null end)
    // place_paused // place_lacks($n) // (if $over == "1" then null else place_limit($h; $c; $mg) end) // empty' <<<"$row"
}
