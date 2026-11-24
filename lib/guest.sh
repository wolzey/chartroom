# shellcheck shell=bash
# guest.sh - a device's side of a pinned task (lib/backends/node.sh is the brain's): the brain's
# commands run here in a guest home, one per brain home,
#   $XDG_STATE_HOME/chartroom/node/guests/<home>/   a chartroom home of this machine's own (files
#                                                  store), never under ~/chartroom: a device can be
#                                                  a client of its own homes too
# with this machine's chartroom, hc, claude/codex, git and gh logins. Nothing of the brain's is
# copied here but the task's brief (its paths moved to the guest home) and its grants. What the
# worker writes goes back to the brain from the agent's loop (guest_push_all): its event lines
# from the dispatch on, report.md and plan.md, and its permission cards; an answer given on the
# brain comes back as a permit-sync command. Push state: <guest>/.push/<id>.json.

guest_root() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/node/guests"; }
guest_dir() { printf '%s/%s' "$(guest_root)" "$1"; } # <home>

guest_run() { # <home> <chartroom verb...>: in the guest home, with the login PATH (a launchd PATH is thin)
  local g ws; g="$(guest_dir "$1")"; shift
  ws="$(cat "$g/.workspace" 2>/dev/null || true)"
  local lp; lp="$(login_path)"
  CHARTROOM_GUEST=1 CHARTROOM_HOME="$g" CHARTROOM_STORE=files PATH="${lp:-$PATH}" CHARTROOM_WORKSPACE="${ws:-chartroom-guest}" "$CR_BIN" "$@"
}

# A guest home is always a files store (guest_run sets CHARTROOM_STORE=files), so its task
# records are files; these two name them, and nothing else here does.
guest_meta_file() { printf '%s/tasks/%s/meta.json' "$1" "$2"; } # <guest dir> <id>
guest_log_file() { printf '%s/tasks/%s/events.log' "$1" "$2"; } # <guest dir> <id>

guest_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

guest_check() { # <payload>: sets G_HOME, G_ID, G_DIR for a task the brain dispatched here
  G_HOME="$(jq -r '.home // ""' <<<"$1")"; G_ID="$(jq -r '.id // ""' <<<"$1")"
  [[ "$G_HOME" =~ ^[a-z][a-z0-9-]{0,31}$ && "$G_ID" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "a home and a task id are needed" >&2; return 2; }
  G_DIR="$(guest_dir "$G_HOME")"
  [[ -f "$(guest_meta_file "$G_DIR" "$G_ID")" ]] || { echo "no task $G_ID here (it was never dispatched to this machine)" >&2; return 3; }
}

# A project the brain names must be a git checkout inside one of this node's project roots.
guest_project_ok() { # <path>
  local p="$1" roots r rp
  [[ "$p" == /* && "$p" != *"/../"* && -d "$p" ]] || { echo "the project $p is not a directory here" >&2; return 1; }
  git -C "$p" rev-parse --git-dir >/dev/null 2>&1 || { echo "$p is not a git checkout here" >&2; return 1; }
  roots="$(cfg_value_in "$(node_config_path)" CHARTROOM_NODE_PROJECT_ROOTS)"
  [[ -n "$roots" ]] || { echo "this node has no project roots (chartroom node init --project-roots, here)" >&2; return 1; }
  rp="$(cd "$p" && pwd -P)"
  local IFS=:
  for r in $roots; do
    r="${r/#\~/$HOME}"; [[ -d "$r" ]] || continue
    r="$(cd "$r" && pwd -P)"
    [[ "$rp" == "$r"/* ]] && return 0
  done
  echo "$p is outside this node's project roots ($roots)" >&2; return 1
}

# The workers the brain gave this machine in the last <seconds>: too new to show in what it measures.
guest_recent_count() { # <seconds>
  local f n=0 t now; now="$(date +%s)"
  shopt -s nullglob
  for f in "$(guest_root)"/*/.push/*.json; do
    t="$(jq -r '.at // 0' "$f" 2>/dev/null || echo 0)"
    [[ "$t" =~ ^[0-9]+$ ]] && (( now - t <= $1 )) && n=$((n + 1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}

# The files of the brain's home that the brief names, kept in the task's own folder here (brain/),
# and the brief's paths moved to them. Only plain relative names; never over anything else.
guest_carry() { # <payload> <guest dir> <id> <brief>  -> the brief
  local p="$1" d="$2/tasks/$3/brain" brief="$4" bh bt rel i n
  bh="$(jq -r '.brain_home // ""' <<<"$p")"; bt="$(jq -r '.brain_home_tilde // ""' <<<"$p")"
  n="$(jq -r '.files // [] | length' <<<"$p")"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n <= CR_CARRY_MAX_FILES )) || n=0
  for ((i = 0; i < n; i++)); do
    rel="$(jq -r --argjson i "$i" '.files[$i].rel // ""' <<<"$p")"
    [[ "$rel" =~ ^[A-Za-z0-9_@+][A-Za-z0-9._@+-]*(/[A-Za-z0-9_@+][A-Za-z0-9._@+-]*)*$ && "$rel" != *..* ]] || continue
    mkdir -p "$d/$(dirname "$rel")"
    jq -r --argjson i "$i" '.files[$i].b64 // ""' <<<"$p" | base64 -d >"$d/$rel" 2>/dev/null || rm -f "$d/$rel"
  done
  # (the longest names first: one may be a folder another is in)
  while IFS= read -r rel; do
    [[ -n "$rel" && -e "$d/$rel" ]] || continue
    brief="${brief//"$bh/$rel"/"$d/$rel"}"
    [[ -z "$bt" ]] || brief="${brief//"$bt/$rel"/"$d/$rel"}"
  done < <(jq -r '.carry // [] | sort_by(-length) | .[]' <<<"$p")
  printf '%s' "$brief"
}

device_cmd_dispatch() { # <payload>
  local p="$1" home id kind backend base branch project brief bh attempt g st args=() a
  home="$(jq -r '.home // ""' <<<"$p")"; id="$(jq -r '.id // ""' <<<"$p")"; kind="$(jq -r '.kind // ""' <<<"$p")"
  backend="$(jq -r '.backend // ""' <<<"$p")"; base="$(jq -r '.base // ""' <<<"$p")"; branch="$(jq -r '.branch // ""' <<<"$p")"
  project="$(jq -r '.project // ""' <<<"$p")"; bh="$(jq -r '.brain_home // ""' <<<"$p")"; attempt="$(jq -r '.attempt // 0' <<<"$p")"
  [[ "$home" =~ ^[a-z][a-z0-9-]{0,31}$ && "$id" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "dispatch: a home and a task id are needed" >&2; return 2; }
  local nb; nb="$(node_backends)"
  [[ "$kind" =~ ^(ship|scout)$ && "$backend" =~ ^($nb)$ && "$base" =~ ^[0-9a-f]{40}$ && "$attempt" =~ ^[0-9]+$ ]] ||
    { echo "dispatch: kind, backend (${nb//|/ or }), base and attempt are needed" >&2; return 2; }
  # (CHARTROOM_GUEST_PROJECT_MAP=<brain prefix>:<here prefix>, for the tests only: one machine
  # playing two needs the device's checkout somewhere else; on real devices paths are the same)
  local map="${CHARTROOM_GUEST_PROJECT_MAP:-}"
  if [[ -n "$map" && "$project" == "${map%%:*}"* ]]; then project="${map#*:}${project#"${map%%:*}"}"; fi
  if [[ "$kind" == ship ]]; then
    [[ "$branch" =~ ^[A-Za-z0-9._/-]{1,200}$ && "$branch" != *..* && "$branch" == *"$id" ]] || { echo "dispatch: the branch '$branch' is not one this task can have" >&2; return 2; }
  fi
  [[ "$bh" == /* ]] || { echo "dispatch: the brain's home path is needed" >&2; return 2; }
  guest_project_ok "$project" || return 6
  g="$(guest_dir "$home")"
  mkdir -p "$g/.push"
  jq -r '.workspace // ""' <<<"$p" | grep -E '^[A-Za-z0-9._-]{1,64}$' >"$g/.workspace" || echo "$home-crew" >"$g/.workspace"
  [[ -f "$g/commander.md" ]] || guest_run "$home" init >/dev/null
  # a dispatch the brain sends again (its answer lost) finds the task and says so: never two workers
  if [[ -f "$(guest_meta_file "$g" "$id")" ]]; then
    st="$(jq -r '.attempt // 0' "$g/.push/$id.json" 2>/dev/null || echo 0)"
    if [[ "$st" == "$attempt" && -n "$(jq -r '.dispatched // ""' "$(guest_meta_file "$g" "$id")")" ]]; then
      echo "already dispatched here (attempt $attempt)"; return 0
    fi
    if [[ -n "$(jq -r '.dispatched // ""' "$(guest_meta_file "$g" "$id")")" && "$st" != "$attempt" ]]; then
      echo "dispatch: attempt $st of $id is still on this machine; close it first" >&2; return 4
    fi
    # (made here before, but its worker never started: this attempt takes it over)
    jq -c --argjson a "$attempt" '.attempt = $a' "$g/.push/$id.json" >"$g/.push/$id.json.tmp" && mv "$g/.push/$id.json.tmp" "$g/.push/$id.json"
  else
    # may it take one more? (5: no, and nothing was made here; asked only of new work)
    a="$(place_refuse_here "$(jq -c '.needs // {agent: "", tools: [], repos: []}' <<<"$p")" "$(jq -r 'if .over then 1 else 0 end' <<<"$p")")"
    [[ -z "$a" ]] || { echo "$a" >&2; return 5; }
    run_bounded 120 git -C "$project" fetch -q origin 2>&1 || echo "dispatch: git fetch in $project failed; trying with what is here" >&2
    git -C "$project" cat-file -e "$base^{commit}" 2>/dev/null ||
      { echo "dispatch: the base ${base:0:12} is not in $project here, even after a fetch (push it, or dispatch it on the brain)" >&2; return 6; }
    args=(new --id "$id" --project "$project" --title "$(jq -r '.title // ""' <<<"$p")" --kind "$kind" --backend "$backend" --base "$base")
    [[ "$(jq -r '.plan_gate' <<<"$p")" != true ]] || args+=(--plan-gate)
    a="$(jq -r '.permission // ""' <<<"$p")"; [[ -z "$a" ]] || args+=(--permission "$a")
    a="$(jq -r '.model // ""' <<<"$p")"; [[ -z "$a" ]] || args+=(--model "$a")
    while IFS= read -r a; do [[ -n "$a" ]] && args+=(--grant "$a"); done < <(jq -r '.grants[]? // empty' <<<"$p")
    CHARTROOM_BRANCH_PREFIX="${branch%"$id"}" guest_run "$home" "${args[@]}" >/dev/null
    # the brain's brief, with its home's paths moved to this guest home
    brief="$(guest_carry "$p" "$g" "$id" "$(jq -r '.brief // ""' <<<"$p")")"
    printf '%s\n' "${brief//"$bh"/"$g"}" >"$g/tasks/$id/brief.md"
    jq -cn --argjson a "$attempt" --argjson o "$(wc -l <"$(guest_log_file "$g" "$id")" | tr -d ' ')" \
      --argjson at "$(date +%s)" '{attempt: $a, off: $o, files: {}, cards: [], at: $at}' >"$g/.push/$id.json"
  fi
  guest_run "$home" dispatch "$id"
}

device_cmd_steer() { guest_check "$1" || return; guest_run "$G_HOME" steer "$G_ID" "$(jq -r '.text // ""' <<<"$1")"; }
device_cmd_stop() { guest_check "$1" || return; guest_run "$G_HOME" stop "$G_ID"; }
# Read-only git in the worker's worktree (chartroom git on the brain): the XO checks a branch there
# before it comes home at close. Refused there and here alike.
device_cmd_git() {
  guest_check "$1" || return
  local args=() wt why
  wt="$(jq -r '.worktree // ""' "$(guest_meta_file "$G_DIR" "$G_ID")")"
  [[ -n "$wt" && -d "$wt" ]] || { echo "$G_ID has no worktree on this machine" >&2; return 1; }
  mapfile -d '' -t args < <(jq -j '.args[]? | (tostring, "\u0000")' <<<"$1")
  why="$(git_readonly_refuses "${args[@]+"${args[@]}"}")"; [[ -z "$why" ]] || { echo "$why" >&2; return 2; }
  git_readonly "$wt" "${args[@]}"
}
device_cmd_peek() {
  guest_check "$1" || return
  echo "guest home: $G_DIR"
  guest_run "$G_HOME" peek "$G_ID" "$(jq -r '.n // 15' <<<"$1")"
}

# close, in two phases the brain runs in order (lib/backends/node.sh): bundle sends the branch to
# the brain and prints its tip as the brain acked it; close closes the guest task and deletes this
# machine's copy of the branch when it is at the commit the brain holds.
device_cmd_close() { # <payload {phase, discard, sha}>
  guest_check "$1" || return
  local m wt project branch base tip f out sha discard
  m="$(guest_meta_file "$G_DIR" "$G_ID")"
  wt="$(jq -r '.worktree // ""' "$m")"; project="$(jq -r '.project // ""' "$m")"; branch="$(jq -r '.branch // ""' "$m")"; base="$(jq -r '.base_sha // ""' "$m")"
  discard="$(jq -r '.discard // false' <<<"$1")"
  guest_push_task "$G_HOME" "$G_ID" || true # (what the worker wrote last goes first)
  case "$(jq -r '.phase // ""' <<<"$1")" in
    bundle)
      if [[ -n "$wt" && -d "$wt" && "$discard" != true && -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        echo "uncommitted work in $wt on this machine: commit it, or close with --discard on the commander's word" >&2; return 2
      fi
      tip="$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch" || true)"
      [[ -n "$tip" && "$tip" != "$base" ]] || { echo "no commits of its own on $branch"; return 0; }
      f="$(mktemp)"
      git -C "$project" bundle create -q "$f" "refs/heads/$branch" "^$base" 2>/dev/null || { rm -f "$f"; echo "git bundle failed" >&2; return 1; }
      out="$(mktemp)"
      local http tok; tok="$(device_token_get)"
      http="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -sS -K - -o "$out" -w '%{http_code}' --max-time 280 -X POST \
        -H 'Content-Type: application/octet-stream' -H "X-Device: $(device_cfg ID)" -H "X-Home: $G_HOME" -H "X-Task: $G_ID" \
        -H "X-Attempt: $(jq -r '.attempt // 0' <<<"$1")" -H "X-Branch: $branch" -H "X-Sha: $tip" \
        --data-binary @"$f" "$(device_cfg BRAIN)/api/v1/device/bundle" 2>/dev/null)" || http=000
      rm -f "$f"
      sha="$(jq -r '.sha // ""' "$out" 2>/dev/null || true)"
      if [[ "$http" != 200 || "$sha" != "$tip" ]]; then
        echo "the brain did not take the bundle ($http): $(jq -r '.error // empty' "$out" 2>/dev/null || true)" >&2; rm -f "$out"; return 1
      fi
      rm -f "$out"
      echo "bundled $branch at ${tip:0:12}; the brain holds it"
      echo "sha=$tip" ;;
    close)
      sha="$(jq -r '.sha // ""' <<<"$1")"
      if [[ "$discard" == true ]]; then guest_run "$G_HOME" close "$G_ID" --discard; else guest_run "$G_HOME" close "$G_ID"; fi
      if [[ "$sha" =~ ^[0-9a-f]{40}$ && "$(git -C "$project" rev-parse --verify --quiet "refs/heads/$branch" || true)" == "$sha" ]]; then
        git -C "$project" update-ref -d "refs/heads/$branch" "$sha" && echo "branch $branch deleted here: the brain holds it at ${sha:0:12}"
      fi
      rm -f "$G_DIR/.push/$G_ID.json" ;;
    *) echo "close: phase is bundle or close" >&2; return 2 ;;
  esac
}

# An answer the commander gave on the brain, for a card the worker here waits on: written where
# nothing is yet (the first answer wins), and the "always" list as the brain has it.
device_cmd_permit_sync() {
  guest_check "$1" || return
  local d f; d="$G_DIR/permits/$G_ID"; mkdir -p "$d/pre"
  while IFS= read -r f; do
    [[ "$f" =~ ^(p-[0-9a-f]{4,16}\.(answer|late)\.json|always\.ndjson|pre/[0-9a-f]{6,64})$ ]] || continue
    if [[ "$f" == always.ndjson ]]; then jq -j --arg f "$f" '.files[$f]' <<<"$1" >"$d/.always.tmp" && mv "$d/.always.tmp" "$d/always.ndjson"
    elif [[ ! -e "$d/$f" ]]; then jq -j --arg f "$f" '.files[$f]' <<<"$1" >"$d/$f.tmp" && mv -n "$d/$f.tmp" "$d/$f"; rm -f "$d/$f.tmp"; fi
  done < <(jq -r '.files // {} | keys[]' <<<"$1")
  echo "permits of $G_ID in step with the brain"
}

# ---------------------------------------------------------------- pushes (the agent's loop)

guest_post() { # <route> <json>
  local b tok; b="$(mktemp)"; printf '%s' "$2" >"$b"
  tok="$(device_token_get)" || { rm -f "$b"; return 1; }
  device_post "/api/v1/device/$1" "$b" "$tok"; rm -f "$b"
  [[ "$DEV_HTTP" == 200 ]]
}

guest_push_task() { # <home> <id>
  local home="$1" id="$2" g sf st att off n lines res name f m pid t
  g="$(guest_dir "$home")"; sf="$g/.push/$id.json"; [[ -f "$sf" ]] || return 0
  st="$(cat "$sf")"; att="$(jq -r .attempt <<<"$st")"; off="$(jq -r .off <<<"$st")"
  t="$(jq -cn --arg id "$(device_cfg ID)" --argjson p "$CR_FLEET_PROTOCOL" --arg h "$home" --arg t "$id" --argjson a "$att" \
    '{id: $id, protocol: $p, home: $h, task: $t, attempt: $a}')"
  # its event lines, 200 at a time, from where the brain has them
  n="$(wc -l <"$(guest_log_file "$g" "$id")" | tr -d ' ')"
  if (( n > off )); then
    lines="$(sed -n "$((off + 1)),$((off + 200))p" "$(guest_log_file "$g" "$id")" | jq -R . | jq -s -c .)"
    if guest_post events "$(jq -c --argjson o "$off" --argjson l "$lines" '. + {offset: $o, lines: $l}' <<<"$t")"; then
      off="$(jq -r '.offset' <<<"$DEV_BODY")"; st="$(jq -c --argjson o "$off" '.off = $o' <<<"$st")"
    elif [[ "$DEV_HTTP" == 403 || "$DEV_HTTP" == 409 ]]; then
      device_log "pushes of $home/$id stop: the brain says $(device_err)"; rm -f "$sf"; return 0
    fi
  fi
  # report.md and plan.md, when they change
  for name in report.md plan.md; do
    f="$g/tasks/$id/$name"; [[ -f "$f" ]] || continue
    m="$(guest_mtime "$f")"
    [[ "$(jq -r --arg n "$name" '.files[$n] // ""' <<<"$st")" != "$m" ]] || continue
    if guest_post files "$(jq -c --arg n "$name" --rawfile c "$f" '. + {name: $n, content: $c}' <<<"$t")"; then
      st="$(jq -c --arg n "$name" --arg m "$m" '.files[$n] = $m' <<<"$st")"
    fi
  done
  # permission cards not sent yet (never an answer: answers are the brain's)
  for f in "$g/permits/$id"/p-*.json; do
    [[ -f "$f" ]] || continue
    pid="${f##*/}"; pid="${pid%.json}"
    [[ "$pid" =~ ^p-[0-9a-f]{4,16}$ ]] || continue
    jq -e --arg p "$pid" '.cards | index($p)' <<<"$st" >/dev/null && continue
    if guest_post permits "$(jq -c --arg p "$pid" --slurpfile c "$f" '. + {cards: {($p): $c[0]}}' <<<"$t")"; then
      st="$(jq -c --arg p "$pid" '.cards += [$p]' <<<"$st")"
    fi
  done
  [[ ! -f "$sf" ]] || printf '%s\n' "$st" >"$sf"
}

GUEST_PARKED_AT=0
guest_push_all() {
  local g sf home id now_s
  for g in "$(guest_root)"/*/; do
    [[ -d "$g/.push" ]] || continue
    home="$(basename "$g")"
    for sf in "$g/.push"/*.json; do
      [[ -f "$sf" ]] || continue
      id="$(basename "$sf" .json)"
      guest_push_task "$home" "$id" || true
    done
  done
  # idle workers park here as they do on the brain (lib/park.sh); a steer resumes them
  now_s="$(date +%s)"
  if (( now_s - GUEST_PARKED_AT >= 60 )); then
    GUEST_PARKED_AT="$now_s"
    for g in "$(guest_root)"/*/; do [[ -d "$g/.push" ]] && guest_run "$(basename "$g")" park --due >/dev/null 2>&1 || true; done
  fi
}

# Each pinned task's liveness here, for the heartbeat: {"<home>/<id>": live word}.
guest_tasks_json() {
  local g home ids
  for g in "$(guest_root)"/*/; do
    [[ -d "$g/.push" ]] || continue
    home="$(basename "$g")"
    ids="$(cd "$g/.push" && ls -1 2>/dev/null | sed -n 's/\.json$//p' | jq -R . | jq -s -c .)"
    [[ "$ids" != "[]" ]] || continue
    guest_run "$home" status --json 2>/dev/null | jq -c --arg h "$home" --argjson ids "$ids" \
      '[.[] | select(.id as $i | $ids | index($i)) | {key: "\($h)/\(.id)", value: .live}] | from_entries' || true
  done | jq -s -c 'add // {}'
}
