# shellcheck shell=bash
# homes.sh - several homes on one machine: the list of homes (`chartroom homes`) and the
# read-only view across them (`--all-homes`).
#
# Each home is a whole chartroom of its own (tasks, preferences, inbox, worktrees), usually one
# per company, with its own XO session. What would collide on one machine comes from the home's
# own `config` (lib/core.sh): the herdr/cmux/tmux workspace, the dashboard port, the project
# roots. The list of homes is $CR_HOMES_FILE, `homes` next to the config file:
#   acme=~/chartroom/acme
#   globex=~/chartroom/globex
# It names each home for launchers (`chartroom homes path acme`), lets a session started in a
# home's directory resolve that home without CHARTROOM_HOME (resolve_home), lets sweep leave
# other homes' work alone (lib/sweep.sh), and lets any home read the others (`--all-homes`).
# Registering or unregistering never writes inside a home.

CR_HOME_NAME_RE='^[a-z][a-z0-9-]{0,31}$'
CR_HOME_PORT_FIRST=4518 # 4517, the dashboard's default, stays with a home that sets none

# A path with $HOME written as ~ (the homes file stays readable and portable).
home_tilde() { local p="$1"; if [[ "$p" == "$HOME" || "$p" == "$HOME"/* ]]; then printf '~%s' "${p#"$HOME"}"; else printf '%s' "$p"; fi; }

# A path with symlinks resolved, also one not created yet (through its nearest existing parent).
phys_dir() { # <path>
  local p="${1%/}" rest="" base=""
  [[ "$p" == /* ]] || p="$PWD/$p"
  while [[ -n "$p" && ! -d "$p" ]]; do rest="/${p##*/}$rest"; p="${p%/*}"; done
  [[ -n "$p" ]] && base="$(cd "$p" 2>/dev/null && pwd -P)"
  [[ "$base" == / ]] && base=""
  printf '%s%s' "$base" "$rest"
}

# The registered name of the home at <path> (compared physically), or nothing.
home_name_of() { # <path>
  local want name p; want="$(phys_dir "$1")"
  while IFS=$'\t' read -r name p; do
    [[ "$(phys_dir "$p")" == "$want" ]] && { printf '%s' "$name"; return 0; }
  done < <(homes_entries)
  return 0
}

# A setting as the home at <path> sees it when launched normally: its own config, else the
# config file, else <default> (this session's environment is left out).
home_setting() { # <path> <SUFFIX> <default>
  local v; v="$(cfg_value_in "$1/config" "CHARTROOM_$2")"
  [[ -n "$v" ]] || v="$(cfg_file_value "CHARTROOM_$2")"
  printf '%s' "${v:-$3}"
}

# The dashboard of the home at <path> when it runs: "pid port host" (dashboard_running there).
home_dashboard() { ( CR_HOME="$1"; dashboard_running ) 2>/dev/null || true; }

# One JSON object per registered home, and one for this home when it is not registered:
#   {name, path, current, registered, exists, is_home, workspace, port, open, dashboard}
# open: tasks not closed; dashboard: the port it runs on, or null.
homes_rows() {
  local name p here phys open dash pid port _ seen=0
  here="$(phys_dir "$CR_HOME")"
  while IFS=$'\t' read -r name p; do
    phys="$(phys_dir "$p")"; open=0; dash=""
    [[ "$phys" == "$here" ]] && seen=1
    if [[ -d "$p/tasks" ]]; then
      local metas=("$p"/tasks/*/meta.json)
      [[ -e "${metas[0]-}" ]] && open="$(jq -r 'select((.closed // "") == "") | .id' "${metas[@]}" | grep -c . || true)"
    fi
    read -r pid port _ < <(home_dashboard "$p") && dash="$port"
    jq -cn --arg n "$name" --arg p "$p" --argjson cur "$([[ "$phys" == "$here" ]] && echo true || echo false)" \
      --argjson ex "$([[ -d "$p" ]] && echo true || echo false)" --argjson ih "$([[ -d "$p/tasks" ]] && echo true || echo false)" \
      --arg ws "$(home_setting "$p" WORKSPACE chartroom-crew)" --arg port "$(home_setting "$p" DASHBOARD_PORT "$CR_DASHBOARD_PORT_DEFAULT")" \
      --argjson open "${open:-0}" --arg dash "$dash" --arg brain "$(cfg_value_in "$p/config" CHARTROOM_BRAIN)" \
      '{name: $n, path: $p, current: $cur, registered: true, exists: $ex, is_home: $ih, workspace: $ws,
        port: ($port | tonumber? // $port), open: $open, dashboard: (if $dash == "" then null else ($dash | tonumber? // $dash) end),
        brain: (if $brain == "" then null else $brain end)}'
  done < <(homes_entries)
  if [[ $seen -eq 0 ]]; then
    open=0; dash=""
    local metas=("$CR_HOME"/tasks/*/meta.json)
    [[ -e "${metas[0]-}" ]] && open="$(jq -r 'select((.closed // "") == "") | .id' "${metas[@]}" | grep -c . || true)"
    read -r pid port _ < <(home_dashboard "$CR_HOME") && dash="$port"
    jq -cn --arg p "$CR_HOME" --arg ws "$CR_WORKSPACE" --arg port "$(cfg DASHBOARD_PORT '' "$CR_DASHBOARD_PORT_DEFAULT")" \
      --argjson ih "$([[ -d "$CR_HOME/tasks" ]] && echo true || echo false)" --argjson open "${open:-0}" --arg dash "$dash" \
      --arg brain "${CR_HOME_CFG[CHARTROOM_BRAIN]:-}" \
      '{name: null, path: $p, current: true, registered: false, exists: true, is_home: $ih, workspace: $ws,
        port: ($port | tonumber? // $port), open: $open, dashboard: (if $dash == "" then null else ($dash | tonumber? // $dash) end),
        brain: (if $brain == "" then null else $brain end)}'
  fi
}

# What would collide, one line each: a shared workspace or port, a home inside another, a path
# that is gone or not a home. <rows> is homes_rows as a JSON array.
homes_warnings() { # <rows-json>
  local name p q n2
  jq -r '
    (group_by(.workspace)[] | select(length > 1) | "homes \(map(.name // "(this home)") | join(", ")) share the workspace \(.[0].workspace): their workers would share it"),
    (group_by(.port)[] | select(length > 1) | "homes \(map(.name // "(this home)") | join(", ")) share the dashboard port \(.[0].port): only one dashboard can run"),
    (.[] | select(.registered and (.exists | not)) | "home \(.name): \(.path) does not exist (chartroom homes rm \(.name), or create it with chartroom init --name \(.name))"),
    (.[] | select(.registered and .exists and (.is_home | not)) | "home \(.name): \(.path) is not a chartroom home yet (CHARTROOM_HOME=\(.path) chartroom init --name \(.name))")' <<<"$1"
  while IFS=$'\t' read -r name p; do
    [[ -d "$p" ]] || continue
    while IFS=$'\t' read -r n2 q; do
      [[ "$n2" != "$name" && -d "$q" ]] || continue
      [[ "$(phys_dir "$q")" == "$(phys_dir "$p")"/* ]] && echo "home $n2 lies inside home $name: a home's sweep and directory lookup would take it for its own"
    done < <(homes_entries)
  done < <(homes_entries)
}

# Checks shared by `homes add` and `init --name`; dies saying why. Prints "same" when <name>
# is already registered to <path>.
homes_check() { # <name> <path>
  local name="$1" path="$2" want n p pp
  [[ "$name" =~ $CR_HOME_NAME_RE ]] || die "a home's name is lowercase letters, digits and -, starting with a letter (got '$name')"
  want="$(phys_dir "$path")"
  while IFS=$'\t' read -r n p; do
    pp="$(phys_dir "$p")"
    if [[ "$n" == "$name" ]]; then
      [[ "$pp" == "$want" ]] && { echo same; return 0; }
      die "a home named $name is already registered, at $p (chartroom homes rm $name first)"
    fi
    [[ "$pp" == "$want" ]] && die "$path is already registered as home $n"
    [[ "$want" == "$pp"/* ]] && die "$path lies inside home $n ($p); homes cannot nest"
    [[ "$pp" == "$want"/* ]] && die "home $n ($p) lies inside $path; homes cannot nest"
  done < <(homes_entries)
  return 0
}

homes_register() { # <name> <path>
  local name="$1" path="$2" chk
  chk="$(homes_check "$name" "$path")" || exit 1
  [[ "$chk" == same ]] && return 0
  mkdir -p "$(dirname "$CR_HOMES_FILE")"
  if [[ ! -s "$CR_HOMES_FILE" ]]; then
    printf '# chartroom homes on this machine, one name=path line each (chartroom homes add|rm).\n' >>"$CR_HOMES_FILE"
  fi
  printf '%s=%s\n' "$name" "$(home_tilde "$path")" >>"$CR_HOMES_FILE"
}

# The first dashboard port from CR_HOME_PORT_FIRST up that no registered home uses.
home_next_port() {
  local used=" " name p port
  while IFS=$'\t' read -r name p; do used+="$(home_setting "$p" DASHBOARD_PORT "$CR_DASHBOARD_PORT_DEFAULT") "; done < <(homes_entries)
  port="$CR_HOME_PORT_FIRST"
  while [[ "$used" == *" $port "* ]]; do port=$((port + 1)); done
  printf '%s' "$port"
}

cmd_homes() {
  local sub="${1:-}" json=0 a rows name path
  case "$sub" in
    ""|list|--json)
      for a in "$@"; do case "$a" in list) ;; --json) json=1 ;; *) die "homes: unknown arg $a" ;; esac; done
      rows="$(homes_rows | jq -s -c .)"
      if [[ $json -eq 1 ]]; then jq . <<<"$rows"; return; fi
      if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then echo "no homes registered ($CR_HOMES_FILE)"; return; fi
      jq -r --arg home "$HOME" '.[] | [(if .current then "*" else "" end) + (.name // "(this home)"),
          (.path | if . == $home or startswith($home + "/") then "~" + ltrimstr($home) else . end), .workspace, (.port | tostring), (.open | tostring),
          (if .dashboard then "running on \(.dashboard)" elif .exists then "-" else "missing" end)] | @tsv' <<<"$rows" |
        { printf 'NAME\tPATH\tWORKSPACE\tPORT\tOPEN\tDASHBOARD\n'; cat; } | table
      jq -r '.[] | select(.brain) | "client home: \(.name // "(this home)") lives on the brain \(.brain) (its OPEN count is this machine'"'"'s copy)"' <<<"$rows"
      jq -e 'any(.[]; .current and (.registered | not))' <<<"$rows" >/dev/null &&
        echo "this home ($CR_HOME) is not registered: chartroom homes add <name>"
      homes_warnings "$rows" | sed 's/^/warning: /'
      return 0 ;;
    add)
      [[ $# -ge 2 && $# -le 3 ]] || die "usage: chartroom homes add <name> [<path>]   (path: this home)"
      name="$2"; path="${3:-$CR_HOME}"; path="${path/#\~/$HOME}"
      [[ -d "$path" ]] || die "no directory $path (to create a home: CHARTROOM_HOME=$path chartroom init --name $name)"
      path="$(cd "$path" && pwd)"
      local chk; chk="$(homes_check "$name" "$path")" || exit 1
      if [[ "$chk" == same ]]; then echo "home $name is already registered: $path"; return 0; fi
      homes_register "$name" "$path"
      echo "registered home $name: $path (in $CR_HOMES_FILE; nothing in the home changed)"
      [[ -d "$path/tasks" ]] || echo "note: $path is not a chartroom home yet (CHARTROOM_HOME=$path chartroom init --name $name)" ;;
    rm)
      [[ $# -eq 2 ]] || die "usage: chartroom homes rm <name>"
      name="$2"; path="$(homes_entries | awk -F'\t' -v n="$name" '$1 == n { p = $2 } END { print p }')"
      [[ -n "$path" ]] || die "no home named $name (chartroom homes)"
      awk -v n="$name" '{ l = $0; sub(/^[[:space:]]+/, "", l) } index(l, n "=") == 1 || l ~ "^" n "[[:space:]]*=" { next } { print }' \
        "$CR_HOMES_FILE" >"$CR_HOMES_FILE.tmp" && mv "$CR_HOMES_FILE.tmp" "$CR_HOMES_FILE"
      echo "unregistered home $name ($path); the home itself is untouched" ;;
    path)
      [[ $# -eq 2 ]] || die "usage: chartroom homes path <name>"
      path="$(homes_entries | awk -F'\t' -v n="$2" '$1 == n { p = $2 } END { print p }')"
      [[ -n "$path" ]] || die "no home named $2 (chartroom homes lists them)"
      printf '%s\n' "$path" ;;
    *) die "usage: chartroom homes [--json] | homes add <name> [<path>] | homes rm <name> | homes path <name>" ;;
  esac
}

# ---------------------------------------------------------------- the view across homes

# `<command> --all-homes`: the command, read-only, in every registered home (and this one, when
# it is not registered), each run by its own chartroom with CHARTROOM_HOME set to that home, so
# each home's own config applies. Text: one "== <name> · <path>" section per home with the
# command's own output. --json: an array, one {home, path, current, result} per home (result is
# the command's own --json output), or {home, path, current, error}. Exits 1 when any home
# could not be read, after printing the rest.
all_homes() { # <command> [args...]
  local cmd="$1" json=0 color=0 a args=() rows n fail=0 i name path cur out err rc
  shift
  for a in "$@"; do
    case "$a" in
      --all-homes) ;;
      --json) json=1; args+=("$a") ;;
      --color|--no-color) color=2; args+=("$a") ;;
      *) args+=("$a") ;;
    esac
  done
  # board and todo color their own output only on a terminal; theirs is a pipe here.
  if [[ $color -eq 0 && $json -eq 0 && -t 1 && -z "${NO_COLOR:-}" && "$cmd" =~ ^(board|todo)$ ]]; then args+=(--color); fi
  rows="$(homes_rows | jq -s -c .)"
  n="$(jq length <<<"$rows")"
  [[ "$n" -gt 0 ]] || die "no homes registered ($CR_HOMES_FILE)"
  err="$(mktemp)"
  local results=()
  for ((i = 0; i < n; i++)); do
    IFS=$'\t' read -r name path cur < <(jq -r --argjson i "$i" '.[$i] | [(.name // "(this home)"), .path, .current] | @tsv' <<<"$rows")
    out=""; rc=0
    if [[ ! -d "$path/tasks" ]]; then printf 'not a chartroom home (no %s/tasks)\n' "$path" >"$err"; rc=1
    else out="$(CHARTROOM_HOME="$path" "$CR_BIN" "$cmd" "${args[@]}" 2>"$err")" || rc=$?; fi
    if [[ $rc -eq 0 ]]; then
      if [[ $json -eq 1 ]]; then
        results+=("$(jq -c --arg h "$name" --arg p "$path" --argjson c "$cur" '{home: $h, path: $p, current: $c, result: .}' <<<"$out")")
      else
        [[ $i -gt 0 ]] && echo
        printf '== %s · %s%s\n' "$name" "$(home_tilde "$path")" "$([[ "$cur" == true ]] && echo ' (this home)')"
        printf '%s\n' "$out"
      fi
    else
      fail=1
      local why; why="$(sed -E 's/^chartroom: //' "$err" | head -1)"
      warn "$name ($path): ${why:-$cmd failed}"
      if [[ $json -eq 1 ]]; then
        results+=("$(jq -cn --arg h "$name" --arg p "$path" --argjson c "$cur" --arg e "${why:-$cmd failed}" '{home: $h, path: $p, current: $c, error: $e}')")
      else
        [[ $i -gt 0 ]] && echo
        printf '== %s · %s\n(could not read it: %s)\n' "$name" "$(home_tilde "$path")" "${why:-$cmd failed}"
      fi
    fi
  done
  rm -f "$err"
  [[ $json -eq 1 ]] && printf '%s\n' "${results[@]}" | jq -s .
  return "$fail"
}
