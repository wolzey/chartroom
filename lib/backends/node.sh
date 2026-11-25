# shellcheck shell=bash
# node runner: a task pinned to an enrolled device (docs/multi-machine.md §13) runs there, in a
# guest home of the device's own chartroom (lib/guest.sh), on that device's hc. The brain reaches
# it only through commands the device takes by long-poll (lib/fleet.sh); what the worker writes
# comes back the same way: its event lines, report.md and plan.md, its permission cards, and at
# close its branch, as a git bundle. The brain never opens a connection to the device.
#
# A task gets here pinned by the commander, or placed by dispatch itself (lib/place.sh; then
# meta.node_placed is 1 and node_source is the backend_source it had).
#   chartroom new ... --node <name|id|here>   pins at birth; chartroom set <id> node=<name|id>|here|any
#   meta.node          the device's id (names are display only); meta.node_name its name then
#   meta.node_backend  what it runs there: hc:claude or hc:codex (meta.backend reads node:<agent>)
#   meta.node_attempt  which attempt the device is on; meta.node_off the lines of its log taken
#   fleet/tasks/<home>/<id>.json   the pin the server checks each push against (device, attempt)
#
# Close goes in this order, and stops at the first step that does not hold, deleting nothing:
# the device bundles the branch -> the brain fetches it (fast-forward only, into the task's own
# branch) -> the brain's tip is the device's tip -> the device closes its guest task and deletes
# its copy of the branch -> the brain closes the record (its branch then kept or deleted by the
# landed rule, as for any task).

# What may run on a device (CHARTROOM_NODE_BACKENDS; the tests add command).
node_backends() { cfg NODE_BACKENDS '' 'hc:claude|hc:codex'; }

node_probe() { return 0; } # (whether the device can take it is decided at launch: away, it waits)
node_steer_mode() { echo live; }
node_handle_set() { [[ -n "$(meta "$1" node)" ]]; }
node_name_of() { # <id>: the device's name now, else the one it had when pinned
  local n; n="$(fleet_device_json "$(meta "$1" node)" 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)"
  printf '%s' "${n:-$(meta "$1" node_name)}"
}
node_home() { # this home's registered name (the device and the server know a task by it)
  local n; n="$(home_name_of "$CR_HOME")"
  [[ -n "$n" ]] || die "this home is not registered (chartroom homes add <name> $CR_HOME): a pinned task is known to its device by its home's name"
  printf '%s' "$n"
}
node_map() { printf '%s/tasks/%s/%s.json' "$(fleet_dir)" "$1" "$2"; } # <home> <id>

# Pins a task to a device, or to this machine (here), or takes its pin away (any|none: dispatch
# places it). Only before its dispatch.
node_pin() { # <id> <name|id|here|any|none>
  local id="$1" want="$2" b did row name
  [[ -z "$(meta "$id" dispatched)" || -n "$(meta "$id" closed)" ]] || die "set: $id is dispatched already; a pin moves only work not started"
  if [[ "$want" =~ ^(here|any|none)$ ]]; then
    if [[ -n "$(meta "$id" node)" ]]; then
      meta_set "$id" backend "$(meta "$id" node_backend)"; meta_set "$id" node ""; meta_set "$id" node_name ""; meta_set "$id" node_placed ""
      log_event "$id" note "pin removed"
    fi
    if [[ "$want" == here ]]; then
      meta_set "$id" node_here 1; log_event "$id" note "pinned here: it runs on this machine"; echo "$id runs on this machine"
    else
      meta_set "$id" node_here ""; echo "$id is not pinned: dispatch places it"
    fi
    return 0
  fi
  is_joined "$id" && die "set: $id joined from a running session; it cannot move"
  did="$(fleet_resolve "$want")"; row="$(fleet_device_json "$did")"; name="$(jq -r .name <<<"$row")"
  [[ "$(jq -r .status <<<"$row")" != revoked ]] || die "set: $name is revoked"
  jq -e '.caps | index("dispatch")' <<<"$row" >/dev/null ||
    die "set: $name's agent cannot take work yet (chartroom node update $name brings it to this brain's chartroom)"
  node_home >/dev/null
  b="$(meta "$id" node_backend)"; [[ -n "$b" ]] || b="$(canon_backend "$(meta "$id" backend)")"
  [[ -z "$b" || "$b" == auto || "${b%%:*}" == node ]] && b=hc:claude
  local nb; nb="$(node_backends)"
  [[ "$b" =~ ^($nb)$ ]] || die "set: only ${nb//|/ and } run on another machine for now (this task is $b)"
  meta_set "$id" node "$did"; meta_set "$id" node_name "$name"; meta_set "$id" node_backend "$b"; meta_set "$id" node_here ""
  meta_set "$id" backend "node:${b#*:}"
  meta_set "$id" backend_source explicit
  log_event "$id" note "pinned to $name ($did): it runs there, as $b"
  echo "$id is pinned to $name: it runs there as $b ($(jq -r .status <<<"$row") now)"
}

# The project's checkout on that device: the same path when its list has it, else its first
# checkout of the same remote, else (an agent with no list) the same path.
node_project_on() { # <device id> <brain project path>
  local project="$2" want probe got pre
  want="$(place_remote "$project")"; pre="$(git -C "$project" rev-parse --show-prefix 2>/dev/null || true)"; pre="${pre%/}"
  local top="$project"; [[ -z "$pre" ]] || top="${project%/"$pre"}"
  probe="$(fleet_device_json "$1" | jq -r '.probe // ""')"
  got="$(awk -F'\t' -v w="$want" -v t="$top" '$1 == "checkout" && $2 == w { if ($3 == t) { print $3; f = 1; exit } if (!first) first = $3 } END { if (!f && first) print first }' <<<"$probe")"
  printf '%s' "${got:-$top}${pre:+/$pre}"
}

# The repos a task needs on its device, its project first, as JSON: [{remote, path (here), tilde, there (that
# device's checkout, when its last heartbeat has one)}], and the project's subdirectory. Empty when the
# project has no remote: the path alone then says which it is.
node_repos_json() { # <id> -> {repos, prefix}
  local id="$1" project own top pre scan probe
  project="$(meta "$id" project)"; own="$(place_remote "$project")"
  [[ "$own" =~ $CR_NODE_REMOTE_RE ]] || { echo '{"repos":[],"prefix":""}'; return; }
  pre="$(git -C "$project" rev-parse --show-prefix 2>/dev/null || true)"; pre="${pre%/}"
  top="$project"; [[ -z "$pre" ]] || top="${project%/"$pre"}"
  scan="$(place_scan "$id")"; probe="$(fleet_device_json "$(meta "$id" node)" | jq -r '.probe // ""')"
  jq -cn --arg own "$own" --arg top "$top" --arg phys "$(phys_dir "$top")" --arg pre "$pre" --arg probe "$probe" --arg home "$HOME" --argjson scan "$scan" '
    ([$probe | split("\n")[] | split("\t") | select(.[0] == "checkout") | {remote: .[1], path: .[2]}]) as $there
    | ([{remote: $own, path: $top}] + (if $phys != $top then [{remote: $own, path: $phys}] else [] end) + ($scan.at // []))
    | unique_by([.remote, .path]) | sort_by(if .remote == $own then (if .path == $top then 0 else 1 end) else 2 end)
    | {prefix: $pre, repos: map(. as $r | . + {tilde: (if ($r.path | startswith($home + "/")) then "~" + ($r.path[($home | length):]) else "" end),
        there: ((([$there[] | select(.remote == $r.remote and .path == $r.path)] + [$there[] | select(.remote == $r.remote)]) | .[0].path) // "")})}'
}
# The repos among them that this device must clone first (it has no checkout, and it may), one per line.
node_to_clone() { # <id> <repos json>
  local row; row="$(fleet_device_json "$(meta "$1" node)")"
  jq -e '(.caps // []) | index("clone")' >/dev/null <<<"$row" || return 0
  grep -q $'^budget\tclone\ton$' <<<"$(jq -r '.probe // ""' <<<"$row")" || return 0
  jq -r '[.repos[] | select(.there == "") | .remote] | unique | .[]' <<<"$2"
}

node_payload() { # <id> <attempt> <over 0|1> <repos json>
  local id="$1" carry f
  f="$(mktemp)"; place_carry_json "$id" >"$f"
  carry="$(jq -r '.missing // empty' "$f")"
  [[ -z "$carry" ]] || log_event "$id" note "its brief on $(node_name_of "$id"): $carry" # (a pin goes all the same)
  jq -cn --arg home "$(node_home)" --arg id "$id" --arg title "$(meta "$id" title)" --arg kind "$(meta "$id" kind)" \
    --arg project "$(node_project_on "$(meta "$id" node)" "$(meta "$id" project)")" --arg base "$(meta "$id" base_sha)" --arg branch "$(meta "$id" branch)" \
    --arg backend "$(meta "$id" node_backend)" --arg plan_gate "$(meta "$id" plan_gate)" --arg permission "$(meta "$id" permission)" \
    --arg model "$(meta "$id" model)" --rawfile brief "$(tdir "$id")/brief.md" --arg brain_home "$CR_HOME" --arg tilde "${CR_HOME/#"$HOME"/\~}" \
    --argjson grants "$(permit_grants_json "$id")" --argjson attempt "$2" --arg ws "$CR_WORKSPACE" --arg over "${3:-0}" \
    --arg tools "$(place_tools "$id")" --slurpfile c "$f" --argjson r "$4" --arg setup "$(place_setup "$id")" --arg pins "$(place_pins "$id")" --arg bin "$CR_BIN" \
    '{home: $home, id: $id, title: $title, kind: $kind, project: $project, base: $base, branch: $branch, backend: $backend,
      plan_gate: ($plan_gate == "1"), permission: $permission, model: $model, brief: $brief, brain_home: $brain_home,
      brain_home_tilde: (if $tilde == $brain_home then "" else $tilde end),
      grants: $grants, attempt: $attempt, workspace: $ws, over: ($over == "1"),
      needs: {agent: ($backend | split(":") | .[1] // ""), tools: ($tools | split("\n") | map(select(length > 0))), repos: [], pins: ($pins | split("\n") | map(select(length > 0)))},
      repos: $r.repos, prefix: $r.prefix, setup: $setup, brain_bin: $bin,
      carry: $c[0].carry, files: $c[0].files}'
  rm -f "$f"
}

# Sets NODE_REFUSED (the device's reason) when the device would not take it and made nothing of it
# (exit 5: its limits or what it lacks; 6: no checkout, or no such base; 7: it could not clone or set up the
# project): the caller places it again.
node_launch() { # <id> <wt (none here)> <agent> [over 0|1]
  local id="$1" did home attempt cid res name st rc repos clone wait=150
  NODE_REFUSED=""
  did="$(meta "$id" node)"; home="$(node_home)"; name="$(node_name_of "$id")"
  attempt="$(meta "$id" node_attempt)"; attempt=$(( ${attempt:-0} + 1 ))
  fleet_write "$(node_map "$home" "$id")" "$(jq -cn --arg d "$did" --argjson a "$attempt" --arg h "$CR_HOME" --arg b "$(meta "$id" branch)" \
    --arg p "$(meta "$id" project)" '{device: $d, attempt: $a, home_path: $h, branch: $b, project: $p}')"
  meta_set "$id" node_attempt "$attempt"; meta_set "$id" node_off 0; meta_set "$id" node_name "$name"
  repos="$(node_repos_json "$id")"; clone="$(node_to_clone "$id" "$repos" | paste -sd' ' -)"
  if [[ -n "$clone" ]]; then
    log_event "$id" note "$name clones ${clone// / and } and sets it up first; the worker starts after that, or it goes to the next machine"
    place_hold "$id" "$did" 2700; wait="$(cfg NODE_PREP_WAIT '' 20)"; [[ "$wait" =~ ^[0-9]+$ ]] || wait=20
  fi
  cid="$(fleet_enqueue "$did" dispatch "$(node_payload "$id" "$attempt" "${4:-0}" "$repos")")"
  meta_set "$id" node_cmd "$cid"
  st="$(fleet_device_json "$did" | jq -r '.status // "unknown"')"
  if [[ "$st" != online ]]; then
    log_event "$id" note "queued for $name: it is $st; the dispatch waits for it"
    echo "queued for $name ($st): it takes the dispatch when it is back"; return 0
  fi
  if res="$(fleet_wait "$cid" "$wait")"; then
    meta_set "$id" node_cmd ""
    rc="$(jq -r '.rc // 1' <<<"$res")"
    if node_refusal "$id" "$rc"; then
      NODE_REFUSED="$(jq -r '.err // .out // "no reason given"' <<<"$res" | grep -v '^[[:space:]]*$' | tail -1)"
      [[ "$rc" != 7 ]] || place_prep_failed "$did" "$(place_remote "$(meta "$id" project)")" "$NODE_REFUSED"
      return 0
    fi
    [[ -z "$clone" ]] || place_hold "$id" "$did"
    node_dispatch_outcome "$id" "$res" || die "the dispatch on $name failed: $(jq -r '.err // .out' <<<"$res" | tail -3)"
    jq -r '.out' <<<"$res" | tail -3
    echo "the worker runs on $name (attempt $attempt): steer, peek and close it from here"
  elif [[ -n "$clone" ]]; then
    echo "$name clones ${clone// / and } and sets it up first; the worker starts after that (its answer comes as an event)"
  else
    echo "$name took the dispatch but has not answered within 150s; its answer comes as an event"
  fi
}
# Is that answer a refusal, with nothing made there? (a pin to a machine without the checkout is a failure: 6)
node_refusal() { [[ "$2" == 5 || "$2" == 7 || ( "$2" == 6 && -n "$(meta "$1" node_placed)" ) ]]; } # <id> <rc>

# A dispatch's answer, once it comes: a note when it took, a failed when it did not.
node_dispatch_outcome() { # <id> <result json>
  local id="$1" rc; rc="$(jq -r '.rc // 1' <<<"$2")"
  if [[ "$rc" == 0 ]]; then return 0; fi
  # (refused before anything was made there, in an answer that came late, say after a clone: the next machine)
  if node_refusal "$id" "$rc"; then
    local why name; why="$(jq -r '.err // .out // ""' <<<"$2" | tr '\n' ' ' | cut -c1-300)"; name="$(node_name_of "$id")"
    [[ "$rc" != 7 ]] || place_prep_failed "$(meta "$id" node)" "$(place_remote "$(meta "$id" project)")" "$why"
    if [[ -n "$(meta "$id" node_placed)" ]]; then
      place_undo "$id"; log_event "$id" note "$name did not take it: $why; it is placed again"; node_again "$id"
    else
      meta_set "$id" dispatched ""; place_unhold "$id"
      log_event "$id" failed "$name did not take it: $why (dispatch it again)"
    fi
    return 1
  fi
  [[ "$rc" != 8 ]] || return 1 # (closed here while the device prepared it: nothing was started)
  log_event "$1" failed "the dispatch on $(node_name_of "$id") did not start a worker: $(jq -r '(.err // "") + " " + (.out // "")' <<<"$2" | tr '\n' ' ' | cut -c1-300)"
  return 1
}

# Dispatches a task again by itself, beside the watch that calls it; a dispatch no machine takes is a failed event.
node_again() { # <id>
  (
    local out
    out="$(env -u CHARTROOM_TASK CHARTROOM_HOME="$CR_HOME" "$CR_BIN" dispatch "$1" 2>&1 </dev/null)" ||
      log_event "$1" failed "not started: $(grep -v '^[[:space:]]*$' <<<"$out" | tail -1 | sed 's/^chartroom: //' | cut -c1-400) (dispatch it again)"
  ) </dev/null >/dev/null 2>&1 3>&- &
}

declare -A NODE_LOOKED=()
# A working task whose device is lost (not heard from for CHARTROOM_NODE_LOST_MINUTES): one wake, and
# a note when it is back. Looked at twice a minute.
node_watch_lost() { # <id>
  (( SECONDS - ${NODE_LOOKED[$1]:--30} >= 30 )) || return 0
  NODE_LOOKED[$1]=$SECONDS
  local row st was; was="$(meta "$1" node_lost)"
  row="$(fleet_device_json "$(meta "$1" node)")"; st="$(jq -r '.status // "unknown"' <<<"$row")"
  if [[ "$st" == lost && -z "$was" && "$(state_of "$1")" == working ]]; then
    meta_set "$1" node_lost 1
    local msg; msg="stalled: $(node_name_of "$1") has not been heard from for $(jq -r '((.seen_age_s // 0) / 60 | floor)' <<<"$row") min; the worker and its work are there, and it carries on when that machine is back"
    log_event "$1" note "$msg"; wake "$1" "$msg"
  elif [[ "$st" == online && -n "$was" ]]; then
    meta_set "$1" node_lost ""
    log_event "$1" note "$(node_name_of "$1") is heard from again"
  fi
}
node_watch() { # (each round of the brain's watch): a dispatch's answer that came after the dispatch
  node_watch_lost "$1"
  local cid f; cid="$(meta "$1" node_cmd)"; [[ -n "$cid" ]] || return 0
  f="$(fleet_dir)/results/$cid.json"; [[ -f "$f" ]] || return 0
  meta_set "$1" node_cmd ""
  local res; res="$(cat "$f")"; rm -f "$f"
  if node_dispatch_outcome "$1" "$res"; then place_hold "$1" "$(meta "$1" node)"; fi
}

# Its liveness, as the device said in its last heartbeat; unknown when the device is not heard.
node_live() {
  local row st w
  row="$(fleet_device_json "$(meta "$1" node)")"; st="$(jq -r '.status // "unknown"' <<<"$row")"
  if [[ "$st" != online && "$st" != stale ]]; then echo unknown; return; fi
  w="$(jq -r --arg k "$(node_home)/$1" '.tasks[$k] // empty' <<<"$row")"
  [[ "$w" =~ ^[a-z-]+$ ]] || w=not-started
  echo "$w"
}

node_need_online() { # <id> <what>
  local st; st="$(fleet_device_json "$(meta "$1" node)" | jq -r '.status // "unknown"')"
  [[ "$st" == online ]] || die "$2: $(node_name_of "$1") is $st, so it cannot be reached now (nothing was sent)"
}
node_cmd() { # <id> <type> <payload extras json> <seconds> -> the device's answer printed; its exit
  local id="$1" p rc=0 a; a="$(meta "$id" node_attempt)"
  p="$(jq -c --arg home "$(node_home)" --arg id "$id" --argjson a "${a:-0}" '. + {home: $home, id: $id, attempt: $a}' <<<"$3")"
  fleet_call "$(meta "$id" node)" "$2" "$p" "$4" || rc=$?
  (( rc != 124 )) || echo "not delivered: $(node_name_of "$id") did not take it within $4s; it was withdrawn" >&2
  return "$rc"
}

node_steer() { # <id> <msg>
  node_need_online "$1" "steer"
  node_cmd "$1" steer "$(jq -cn --arg t "$2" '{text: $t}')" 60
}
node_stop() { node_need_online "$1" "stop"; node_cmd "$1" stop '{}' 30; }
node_close() { node_stop "$1" >/dev/null 2>&1; } # (a session end, for remove: the record and worktree stay)
node_peek() { # <id> <n>
  local st; st="$(fleet_device_json "$(meta "$1" node)" | jq -r '"\(.status) (last heartbeat \(.seen_age_s // "?")s ago)"')"
  echo "== on $(node_name_of "$1"): $st"
  [[ "$st" == online* ]] || return 0
  node_cmd "$1" peek "$(jq -cn --argjson n "${2:-15}" '{n: $n}')" 30 | sed -nE '/^== (pane|screen|terminal)/,$p' || true
}
node_git() { # <id> <read-only git args...>: in the worker's worktree, there
  local id="$1"; shift; node_need_online "$id" "git"
  node_cmd "$id" git "$(jq -cn --args '{args: $ARGS.positional}' -- "$@")" 60
}
node_attach() {
  die "the worker of $1 runs on $(node_name_of "$1"): attach there (chartroom attach $1, with CHARTROOM_HOME set to its guest home: chartroom peek $1 prints it), or with your own hc link to it"
}
node_park() { return 1; }

# Takes back a dispatch the device has not answered.
node_withdraw() { # <id> <cmd id or "">
  [[ -n "$2" ]] || return 0
  fleet_withdraw "$(meta "$1" node)" "$2"; rm -f "$(fleet_dir)/results/$2.json"; meta_set "$1" node_cmd ""; place_unhold "$1"
}

# close, for a pinned task (cmd_close calls it first). Prints what happened; dies, deleting
# nothing, at the first step that does not hold.
node_close_task() { # <id> <discard 0|1>
  local id="$1" discard="$2" name kind branch project out sha have rc
  name="$(node_name_of "$id")"; kind="$(meta "$id" kind)"; branch="$(meta "$id" branch)"; project="$(meta "$id" project)"
  [[ -n "$(meta "$id" dispatched)" ]] || return 0
  # a revoked device is gone for good: the record closes here; what it held stays there
  if [[ "$(fleet_device_json "$(meta "$id" node)" | jq -r '.status // "unknown"')" == revoked ]]; then
    echo "$name is revoked: the record closes here, and anything of it on $name stays there"
    rm -f "$(node_map "$(node_home)" "$id")"; return 0
  fi
  node_need_online "$id" "close"
  # (a dispatch it has not answered, say one that clones first, is taken back: that answer no longer counts)
  local cid; cid="$(meta "$id" node_cmd)"
  sha=""
  if [[ "$kind" == ship && -n "$branch" ]]; then
    rc=0; out="$(node_cmd "$id" close "$(jq -cn --argjson d "$discard" '{phase: "bundle", discard: ($d == 1)}')" 300 2>&1)" || rc=$?
    # (3: the device never had it, say a dispatch it refused: nothing there to bring or close)
    if (( rc == 3 )); then echo "$name has nothing of $id"; rm -f "$(node_map "$(node_home)" "$id")"; node_withdraw "$id" "$cid"; return 0; fi
    (( rc == 0 )) || { printf 'chartroom: not closed: on %s: %s\n' "$name" "$out" >&2; exit 2; }
    sha="$(sed -n 's/^sha=\([0-9a-f]\{40\}\)$/\1/p' <<<"$out" | tail -1)"
    if [[ -n "$sha" ]]; then
      have="$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch" || true)"
      [[ "$have" == "$sha" ]] || die "not closed: the brain's $branch is ${have:-missing}, not $name's $sha (nothing deleted anywhere)"
      echo "branch $branch is on this machine at ${sha:0:12} (from $name)"
    else
      echo "$name: $branch has no commits of its own"
    fi
  fi
  rc=0; out="$(node_cmd "$id" close "$(jq -cn --argjson d "$discard" --arg s "$sha" '{phase: "close", discard: ($d == 1), sha: $s}')" 120 2>&1)" || rc=$?
  if (( rc == 3 )); then echo "$name has nothing of $id"; rm -f "$(node_map "$(node_home)" "$id")"; node_withdraw "$id" "$cid"; return 0; fi
  (( rc == 0 )) || { printf 'chartroom: not closed: on %s: %s\n' "$name" "$out" >&2; exit 2; }
  printf '%s\n' "$out" | sed "s/^/$name: /"
  log_event "$id" note "closed on $name"
  rm -f "$(node_map "$(node_home)" "$id")"
}

# ---------------------------------------------------------------- what a device pushes (the server's)

# chartroom fleet ingest events|files|permits|bundle, in the task's home: one JSON document on
# stdin ({home, id, attempt, device, ...}), checked against the pin again here.
node_ingest_check() { # <json> -> sets NI_ID
  local in="$1" map
  NI_ID="$(jq -r '.id // ""' <<<"$in")"
  [[ "$NI_ID" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || fleet_fail 2 "the task id is malformed"
  task_exists "$NI_ID" || fleet_fail 3 "no task $NI_ID here"
  map="$(node_map "$(jq -r .home <<<"$in")" "$NI_ID")"
  [[ -f "$map" ]] || fleet_fail 3 "$NI_ID is not pinned to a device"
  jq -e --argjson x "$in" '.device == $x.device and .attempt == $x.attempt' "$map" >/dev/null ||
    fleet_fail 4 "$NI_ID is not this device's at that attempt (it was handed off or closed)"
}

# A line of a worker's log, as it wrote it: only the kinds a worker and its hooks write, and never
# what only the brain writes (an accept, a close).
CR_NODE_LINE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z (progress|waiting|decision|blocked|done|failed|agent|note|steered|permit|exited): '

node_ingest() { # <events|files|permits|bundle>
  local in; in="$(cat)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$in" || fleet_fail 2 "the body is not a JSON object"
  node_ingest_check "$in"
  local id="$NI_ID"
  case "$1" in
    events)
      local off got n i line kept=0
      off="$(meta "$id" node_off)"; off="${off:-0}"
      got="$(jq -r '.offset // -1' <<<"$in")"; n="$(jq -r '.lines | length' <<<"$in")"
      [[ "$got" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] || fleet_fail 2 "offset and lines[] are needed"
      if (( got > off )); then jq -cn --argjson o "$off" '{offset: $o, gap: true}'; return 0; fi
      for ((i = off - got; i < n; i++)); do
        line="$(jq -r --argjson i "$i" '.lines[$i] | tostring' <<<"$in")"
        if [[ "$line" =~ $CR_NODE_LINE_RE && "$line" != *$'\n'* && ! "$line" =~ \ note:\ (accepted|closed)$ && ! "$line" =~ \ note:\ closed\ \( ]]; then
          log_event_line "$id" "$line"; kept=$((kept + 1))
        fi
      done
      (( n > off - got )) && meta_set "$id" node_off "$((got + n))"
      jq -cn --argjson o "$(( got + n > off ? got + n : off ))" --argjson k "$kept" '{offset: $o, kept: $k}' ;;
    files)
      local name
      name="$(jq -r '.name // ""' <<<"$in")"
      [[ "$name" =~ ^(report\.md|plan\.md)$ ]] || fleet_fail 2 "only report.md and plan.md come from a device"
      jq -j '.content // ""' <<<"$in" >"$(tdir "$id")/.$name.incoming"
      (( $(wc -c <"$(tdir "$id")/.$name.incoming") <= 1048576 )) || { rm -f "$(tdir "$id")/.$name.incoming"; fleet_fail 2 "$name is over 1 MB"; }
      mv "$(tdir "$id")/.$name.incoming" "$(tdir "$id")/$name"
      stamp_changed; jq -cn '{ok: true}' ;;
    permits)
      local pid d; d="$(permit_tdir "$id")"; mkdir -p "$d"
      while IFS= read -r pid; do
        [[ "$pid" =~ ^p-[0-9a-f]{4,16}$ ]] || continue
        [[ -e "$d/$pid.json" ]] && continue
        if jq -c --arg p "$pid" '.cards[$p] | select(type == "object")' <<<"$in" >"$d/.$pid.incoming" 2>/dev/null && [[ -s "$d/.$pid.incoming" ]]; then
          mv "$d/.$pid.incoming" "$d/$pid.json"
        fi
        rm -f "$d/.$pid.incoming"
      done < <(jq -r '.cards // {} | keys[]' <<<"$in")
      stamp_changed; bell_ring "" watch; jq -cn '{ok: true}' ;;
    bundle)
      local path branch sha project have
      path="$(jq -r '.path // ""' <<<"$in")"; branch="$(jq -r '.branch // ""' <<<"$in")"; sha="$(jq -r '.sha // ""' <<<"$in")"
      [[ "$branch" == "$(meta "$id" branch)" && -n "$branch" ]] || fleet_fail 4 "a bundle comes only for the task's own branch ($(meta "$id" branch))"
      [[ "$sha" =~ ^[0-9a-f]{40}$ && -f "$path" ]] || fleet_fail 2 "a bundle needs its file and its tip"
      project="$(meta "$id" project)"
      git -C "$project" bundle verify -q "$path" >/dev/null 2>&1 || fleet_fail 2 "the bundle does not verify against $project"
      # fast-forward only, into the task's own branch: never over work of the brain's
      git -C "$project" fetch -q "$path" "refs/heads/$branch:refs/heads/$branch" 2>/dev/null ||
        fleet_fail 4 "the brain's $branch cannot fast-forward to the device's (it has commits of its own)"
      have="$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch")"
      [[ "$have" == "$sha" ]] || fleet_fail 4 "after the fetch the brain's $branch is $have, not $sha"
      log_event "$id" note "branch $branch fetched from $(node_name_of "$id") at ${sha:0:12}"
      jq -cn --arg s "$sha" '{ok: true, sha: $s}' ;;
    *) fleet_fail 2 "fleet ingest: events, files, permits or bundle" ;;
  esac
}

# An answer given here to a card a device's worker waits on goes to that device: the answer, the
# task's "always" patterns and its one-time pre-approvals (lib/permit.sh's files), written there
# only where nothing is yet (the first answer wins there too).
node_permit_sync() { # <id>
  local id="$1" files; files="$(permit_sync_files_json "$id")"
  [[ -n "$files" ]] || files='{}'
  node_cmd "$id" permit-sync "$(jq -cn --argjson f "$files" '{files: $f}')" 30 >/dev/null 2>&1 ||
    warn "the answer could not reach $(node_name_of "$id") now; it is sent again with the next answer"
}
