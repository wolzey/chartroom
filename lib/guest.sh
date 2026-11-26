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
  local lp sh; lp="$(login_path)"; lp="${lp:-$PATH}"
  # (a project's pinned tools come with mise on first use: its shims, where the login PATH has none)
  sh="${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims"
  if guest_clones_on && [[ -d "$sh" && ":$lp:" != *":$sh:"* ]]; then lp="$sh:$lp"; fi
  CHARTROOM_GUEST=1 CHARTROOM_HOME="$g" CHARTROOM_STORE=files PATH="$lp" CHARTROOM_WORKSPACE="${ws:-chartroom-guest}" "$CR_BIN" "$@"
}

# A guest home is always a files store (guest_run sets CHARTROOM_STORE=files), so its task
# records are files; these two name them, and nothing else here does.
guest_meta_file() { printf '%s/tasks/%s/meta.json' "$1" "$2"; } # <guest dir> <id>
guest_log_file() { printf '%s/tasks/%s/events.log' "$1" "$2"; } # <guest dir> <id>

# (GNU stat first: its -f is the file system's status, which prints no file's time)
guest_mtime() { local m; m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || m=0; [[ "$m" =~ ^[0-9]+$ ]] || m=0; printf '%s' "$m"; }

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

# ---------------------------------------------------------------- a project not here yet
#
# With CHARTROOM_NODE_CLONE=on (chartroom node limits <name> --clone on; off at first) a task's project
# that has no checkout here is cloned: github.com only, with this machine's own gh login, to
# <first project root>/<owner>/<repo>, marked chartroom.cloned in its git config. Before the first
# worker of it starts, its setup runs there once: the command the brain's projects.md names
# (setup=), else the repo's own bin/setup or script/setup, else the tools it pins (mise) and
# its package manager's locked install. It is recorded here and runs again only when the command, its
# script or the pins change. A clone or a setup that fails refuses the task (exit 7) and leaves nothing
# half made. Both can take minutes: such a dispatch runs outside the agent's command loop
# (lib/device.sh), one at a time for each repo, and a close that comes meanwhile cancels it.
# A checkout a person made is never set up, pulled or marked.

CR_CLONE_RE='^github\.com/[a-z0-9][a-z0-9-]{0,38}/[a-z0-9._-]{1,100}$'

guest_state() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/node"; }
guest_clones_on() { [[ "$(cfg_value_in "$(node_config_path)" CHARTROOM_NODE_CLONE)" == on ]]; }
guest_roots() { # this node's project roots that exist, one a line, as the disk has them
  local r roots; roots="$(cfg_value_in "$(node_config_path)" CHARTROOM_NODE_PROJECT_ROOTS)"
  local IFS=:
  for r in $roots; do r="${r/#\~/$HOME}"; [[ ! -d "$r" ]] || (cd "$r" && pwd -P); done
}
guest_remote_of() { node_canon_remote "$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)"; } # <checkout>
guest_cloned() { [[ "$(git -C "$1" config --local --get chartroom.cloned 2>/dev/null)" == true ]]; } # <checkout>

# (CHARTROOM_GUEST_PROJECT_MAP=<brain prefix>:<here prefix>, for the tests only: one machine playing
# two needs the device's checkout somewhere else)
guest_map_path() { # <path>
  local map="${CHARTROOM_GUEST_PROJECT_MAP:-}"
  if [[ -n "$map" && ( "$1" == "${map%%:*}" || "$1" == "${map%%:*}"/* ) ]]; then printf '%s' "${map#*:}${1#"${map%%:*}"}"; else printf '%s' "$1"; fi
}

# This machine's checkout of a remote: one of the paths the brain knows when it is one, else the first
# there is under the roots.
guest_find_checkout() { # <canonical remote> [path...]
  local g r want="$1"; shift
  for g in "$@"; do
    g="$(guest_map_path "$g")"
    if [[ -n "$g" && -e "$g/.git" ]] && guest_project_ok "$g" 2>/dev/null && [[ "$(guest_remote_of "$g")" == "$want" ]]; then printf '%s' "$g"; return 0; fi
  done
  while IFS= read -r r; do
    while IFS= read -r g; do
      if [[ "$(guest_remote_of "${g%/.git}")" == "$want" ]]; then printf '%s' "${g%/.git}"; return 0; fi
    done < <(find "$r" -mindepth 2 -maxdepth 3 -name .git -type d -prune 2>/dev/null)
  done < <(guest_roots)
  return 1
}

guest_lock() { # <name> <seconds>: one holder; a holder that is gone loses it
  local d i p; d="$(guest_state)/locks/$1"; mkdir -p "${d%/*}"
  for ((i = 0; i < $2; i++)); do
    if mkdir "$d" 2>/dev/null; then echo "$BASHPID" >"$d/pid"; return 0; fi
    p="$(cat "$d/pid" 2>/dev/null || true)"
    if [[ "$p" =~ ^[0-9]+$ ]] && ! pid_alive "$p"; then mv "$d" "$d.gone.$BASHPID" 2>/dev/null && rm -rf "$d.gone.$BASHPID"; continue; fi
    sleep 1
  done
  return 1
}
guest_unlock() { rm -rf "$(guest_state)/locks/$1"; }

# Runs a command for at most <seconds>, and everything it started with it (124 when time ran out).
guest_run_group() { # <seconds> <cmd...>
  perl -e 'my $s = shift; my $p = fork; defined $p or exit 127;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    my $late = 0;
    my $end = sub { kill "TERM", -$p; for (1 .. 20) { last unless kill 0, -$p; select undef, undef, undef, 0.25 } kill "KILL", -$p };
    $SIG{ALRM} = sub { $late = 1; $end->() }; $SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { $end->(); exit 143 };
    alarm $s;
    while (1) { my $r = waitpid $p, 0; last if $r == $p || ($r == -1 && !$!{EINTR}) }
    exit($late ? 124 : $? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}
guest_last_line() { tr '\r\t' '\n ' <"$1" 2>/dev/null | sed -E $'s/\x1b\\[[0-9;?]*[ -\/]*[@-~]//g' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200; } # <file>
guest_login_path() { local p; p="$(login_path)"; printf '%s' "${p:-$PATH}"; }

# Clones a remote; prints where. One at a time for each remote (a second waits, and finds it).
guest_clone() { # <canonical remote>
  local remote="$1" o r root dest tmp gh err lp rc=0 k got
  [[ "$remote" =~ $CR_CLONE_RE && ! "${remote##*/}" =~ ^\.+$ ]] || { echo "no checkout of $remote here, and it clones from github.com only" >&2; return 7; }
  o="${remote#*/}"; r="${o#*/}"; o="${o%%/*}"
  root="$(guest_roots | head -1)"
  [[ -n "$root" ]] || { echo "this node has no project roots to clone into (chartroom node init --project-roots, here)" >&2; return 7; }
  lp="$(guest_login_path)"
  gh="$(PATH="$lp" command -v gh || true)"
  [[ -n "$gh" ]] || { echo "no checkout of $remote here, and gh is missing to clone it with" >&2; return 7; }
  k="clone-$(printf '%s' "$remote" | sha256_hex | cut -c1-16)"
  guest_lock "$k" "$(guest_prep_s)" || { echo "$remote is still being cloned here" >&2; return 7; }
  if got="$(guest_find_checkout "$remote")"; then guest_unlock "$k"; printf '%s' "$got"; return 0; fi
  dest="$root/$o/$r"; tmp="$root/.chartroom-clone/$(fleet_rand_hex 4)"; err="$(mktemp)"
  if [[ -e "$dest" || -L "$dest" ]]; then echo "$dest is there, and is not a checkout of $remote" >&2; rc=7
  elif ! mkdir -p "$root/$o" || [[ "$(cd "$root/$o" && pwd -P)" != "$root/$o" ]]; then echo "$root/$o is not a directory of this node's project root" >&2; rc=7
  else
    # (four levels down while it is made, where no scan of the roots counts it as a checkout)
    find "$root/.chartroom-clone" -mindepth 1 -maxdepth 1 -type d -mmin +180 -exec rm -rf {} + 2>/dev/null || true # (one cut short)
    mkdir -p "$tmp" && chmod 700 "$root/.chartroom-clone"
    PATH="$lp" GIT_TERMINAL_PROMPT=0 guest_run_group "$(guest_prep_s)" git clone -q -c chartroom.cloned=true \
      -c credential.https://github.com.helper= -c "credential.https://github.com.helper=!$(printf '%q' "$gh") auth git-credential" \
      "https://github.com/$o/$r.git" "$tmp/repo" >"$err" 2>&1 </dev/null || rc=$?
    if (( rc == 0 )); then mv "$tmp/repo" "$dest" || rc=1; fi
    if (( rc != 0 )); then
      if (( rc == 124 )); then echo "could not clone $remote: not done in $(( $(guest_prep_s) / 60 )) min" >&2
      else echo "could not clone $remote: $(grep -m 1 -E '^(fatal|ERROR|remote): ' "$err" | cut -c1-200 || true)" >&2; fi
      rc=7
    fi
    rm -rf "$tmp"; rmdir "$root/.chartroom-clone" 2>/dev/null || true
  fi
  rm -f "$err"; guest_unlock "$k"
  (( rc == 0 )) || return "$rc"
  device_log "cloned $remote to $dest"
  printf '%s' "$dest"
}
guest_prep_s() { local s; s="$(cfg NODE_PREP_SECONDS '' 1800)"; [[ "$s" =~ ^[0-9]+$ ]] && (( s > 0 )) || s=1800; printf '%s' "$s"; }

# What sets up a clone: the brain's command, else the repo's own way, as one shell line. Nothing: none.
guest_setup_command() { # <checkout> <the brain's command or "">
  local d="$1" out=() lp pins="" pm=""; lp="$(guest_login_path)"
  if [[ -n "$2" ]]; then printf '%s' "$2"; return; fi
  local mise; mise="$(PATH="$lp" command -v mise || true)"
  if [[ -f "$d/mise.toml" || -f "$d/.mise.toml" || -f "$d/.tool-versions" ]]; then pins=1; fi
  if [[ -n "$pins" && -n "$mise" ]]; then out+=("mise install"); pm="mise exec -- "; fi
  local s f=""
  # (a symlinked bin/setup is another program under that name: not the repo's own setup)
  for s in bin/setup script/setup; do [[ -f "$d/$s" && -x "$d/$s" && ! -L "$d/$s" ]] && { f="$s"; break; }; done
  if [[ -n "$f" ]]; then
    if grep -q -- '--skip-server' "$d/$f"; then out+=("$pm$f --skip-server"); else out+=("$pm$f"); fi
  else
    if [[ -f "$d/pnpm-lock.yaml" ]]; then
      if [[ -z "$pm" ]] && ! PATH="$lp" command -v pnpm >/dev/null && PATH="$lp" command -v corepack >/dev/null; then out+=("corepack pnpm install --frozen-lockfile"); else out+=("${pm}pnpm install --frozen-lockfile"); fi
    elif [[ -f "$d/yarn.lock" ]]; then out+=("${pm}yarn install --frozen-lockfile")
    elif [[ -f "$d/bun.lock" || -f "$d/bun.lockb" ]]; then out+=("${pm}bun install --frozen-lockfile")
    elif [[ -f "$d/package-lock.json" ]]; then out+=("${pm}npm ci"); fi
    [[ ! -f "$d/Gemfile.lock" ]] || out+=("${pm}bundle install")
    [[ ! -f "$d/go.mod" ]] || out+=("${pm}go mod download")
  fi
  (( ${#out[@]} == 0 )) || { local x; x="$(printf '%s && ' "${out[@]}")"; printf '%s' "${x% && }"; }
}

guest_setup_file() { printf '%s/setup/%s' "$(guest_state)" "$(printf '%s' "$1" | sha256_hex | cut -c1-16)"; } # <remote>
guest_setup_key() { # <checkout> <command>
  { echo 1; printf '%s\n' "$1" "$2"
    local f; for f in bin/setup script/setup mise.toml .mise.toml .tool-versions; do git -C "$1" rev-parse -q --verify "HEAD:$f" 2>/dev/null || echo -; done
  } | sha256_hex
}
# Brings a clone chartroom made up to date and runs its setup once (see above); 7 when it fails.
guest_setup() { # <checkout> <canonical remote> <the brain's command or "">
  local d="$1" remote="$2" cmd key f k rc=0 v unset=() lp
  guest_cloned "$d" || return 0
  f="$(guest_setup_file "$remote")"; k="clone-$(printf '%s' "$remote" | sha256_hex | cut -c1-16)"
  guest_lock "$k" "$(guest_prep_s)" || { echo "the setup of $remote is still running here" >&2; return 7; }
  run_bounded 300 git -C "$d" fetch -q origin >/dev/null 2>&1 </dev/null || true
  if [[ -z "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then git -C "$d" merge -q --ff-only '@{upstream}' >/dev/null 2>&1 || true; fi
  cmd="$(guest_setup_command "$d" "$3")"; key="$(guest_setup_key "$d" "$cmd")"
  # (a registry login given since a setup that failed: it may now work)
  [[ ! -s "$(env_npm_file "$d")" ]] || key="$(printf '%s %s' "$key" "$(guest_mtime "$(env_npm_file "$d")")" | sha256_hex)"
  if [[ -n "$cmd" && "$(jq -r 'select(.rc == 0) | .key' "$f.json" 2>/dev/null)" != "$key" ]]; then
    mkdir -p "${f%/*}"; chmod 700 "${f%/*}"
    lp="$(guest_login_path)"
    while IFS= read -r v; do unset+=("$v"); done < <(compgen -e | grep -E '^(CHARTROOM|CR|CLAUDE|HC|HERDR)_' || true)
    device_log "setting up $remote in $d: $cmd"
    ( umask 077; : >"$f.log" )
    ( cd "$d" || exit 1
      for v in "${unset[@]+"${unset[@]}"}"; do unset "$v"; done # (it is the repo's own program: none of chartroom's settings)
      export PATH="$lp" MISE_TRUSTED_CONFIG_PATHS="$d" MISE_YES=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0
      # (the repo's registry login from the fleet's store, when there is one: never the node's ~/.npmrc)
      if [[ -s "$(env_npm_file "$d")" ]]; then export NPM_CONFIG_USERCONFIG; NPM_CONFIG_USERCONFIG="$(env_npm_file "$d")"; fi
      guest_run_group "$(guest_prep_s)" "$BASH" -c "$cmd" >>"$f.log" 2>&1 </dev/null ) || rc=$?
    jq -cn --arg r "$remote" --arg p "$d" --arg k "$key" --arg c "$cmd" --arg at "$(now)" --argjson rc "$rc" \
      '{remote: $r, path: $p, key: $k, command: $c, at: $at, rc: $rc}' >"$f.json.tmp" && mv "$f.json.tmp" "$f.json"
    device_log "setup of $remote: exit $rc"
  fi
  guest_unlock "$k"
  (( rc == 0 )) && return 0
  if (( rc == 124 )); then echo "the setup of $remote ($cmd) was not done in $(( $(guest_prep_s) / 60 )) min" >&2
  else echo "the setup of $remote ($cmd) failed (exit $rc): $(guest_last_line "$f.log")" >&2; fi
  return 7
}

# chartroom node prepare: a repo cloned here when it is not (the node must clone) and set up, ahead of any
# task, so the first one does not wait for it. Prints where it is and that it is ready; 7 when it is not.
device_cmd_prepare() { # <payload {remote, setup}>
  local remote path rc=0; remote="$(jq -r '.remote // ""' <<<"$1")"
  [[ "$remote" =~ $CR_NODE_REMOTE_RE ]] || { echo "'$remote' is not a repository" >&2; return 2; }
  if ! path="$(guest_find_checkout "$remote")"; then
    guest_clones_on || { echo "no checkout of $remote here, and this node does not clone (chartroom node limits <name> --clone on)" >&2; return 6; }
    path="$(guest_clone "$remote")" || return
  fi
  if ! guest_cloned "$path"; then echo "$remote: ready at $path (a checkout of a person's own: never set up by chartroom)"; return 0; fi
  [[ "$(jq -r '.env // [] | length' <<<"$1")" == 0 ]] || env_put_here "$remote" "$path" "$(jq -c '.env' <<<"$1")" || return 7
  guest_setup "$path" "$remote" "$(jq -r '.setup // ""' <<<"$1")" || rc=$?
  (( rc == 0 )) || return "$rc"
  echo "$remote: ready at $path, set up ($(jq -r '.command // "nothing to run"' "$(guest_setup_file "$remote").json" 2>/dev/null || echo "nothing to run"))"
}

# Is a dispatch one that may have to wait for a clone or a setup here?
guest_may_prep() { # <payload>
  guest_clones_on || return 1
  local n i remote path; n="$(jq -r '.repos // [] | length' <<<"$1")"
  for ((i = 0; i < n; i++)); do
    remote="$(jq -r --argjson i "$i" '.repos[$i].remote // ""' <<<"$1")"
    path="$(guest_find_checkout "$remote" "$(jq -r --argjson i "$i" '.repos[$i].there // ""' <<<"$1")" "$(jq -r --argjson i "$i" '.repos[$i].path // ""' <<<"$1")")" || return 0
    (( i > 0 )) || ! guest_cloned "$path" || return 0
  done
  return 1
}

# Every repo a task needs here: found, or cloned; its project set up. Sets GP_PROJECT (its checkout),
# GP_CLONED (chartroom cloned it), GP_WAITED (something was cloned or looked at for a setup) and
# GP_PAIRS (the brain's path, this machine's, ...). 6: not here and not cloned; 7: that failed.
guest_prepare() { # <payload>
  local p="$1" n i remote from tilde path rc prefix
  GP_PROJECT="" GP_CLONED=0 GP_WAITED=0 GP_PAIRS=()
  n="$(jq -r '.repos | length' <<<"$p")"
  for ((i = 0; i < n; i++)); do
    remote="$(jq -r --argjson i "$i" '.repos[$i].remote // ""' <<<"$p")"
    from="$(jq -r --argjson i "$i" '.repos[$i].path // ""' <<<"$p")"; tilde="$(jq -r --argjson i "$i" '.repos[$i].tilde // ""' <<<"$p")"
    [[ "$remote" =~ $CR_NODE_REMOTE_RE ]] || { echo "'$remote' is not a repository" >&2; return 6; }
    if ! path="$(guest_find_checkout "$remote" "$(jq -r --argjson i "$i" '.repos[$i].there // ""' <<<"$p")" "$from")"; then
      guest_clones_on || { echo "no checkout of $remote here" >&2; return 6; }
      rc=0; path="$(guest_clone "$remote")" || rc=$?
      (( rc == 0 )) || return "$rc"
      GP_WAITED=1
    fi
    [[ "$from" != /* || "$from" == "$path" ]] || GP_PAIRS+=("$from" "$path")
    [[ -z "$tilde" || "$from" == "$path" ]] || GP_PAIRS+=("$tilde" "$path")
    if (( i == 0 )); then
      prefix="$(jq -r '.prefix // ""' <<<"$p")"
      GP_PROJECT="$path${prefix:+/$prefix}"
      if guest_cloned "$path"; then
        GP_CLONED=1 GP_WAITED=1
        if [[ "$(jq -r '.env // [] | length' <<<"$p")" != 0 ]]; then env_put_here "$remote" "$path" "$(jq -c '.env' <<<"$p")" || return 7; fi
        guest_setup "$path" "$remote" "$(jq -r '.setup // ""' <<<"$p")" || return
      fi
      guest_project_ok "$GP_PROJECT" || return 6
    fi
  done
}

# A text with paths moved to others, each only where it is that whole path (or under it).
guest_move_paths() { # <text> <from> <to>...
  local t="$1"; shift
  (( $# > 0 )) || { printf '%s' "$t"; return; }
  printf '%s' "$t" | perl -e 'local $/; my $t = <STDIN>; my %m; while (@ARGV) { my ($a, $b) = splice @ARGV, 0, 2; $m{$a} = $b }
    my $re = join "|", map { quotemeta } sort { length $b <=> length $a } keys %m;
    $t =~ s{(?<![A-Za-z0-9._~/-])($re)(?![A-Za-z0-9_@+-]|\.[A-Za-z0-9])}{$m{$1}}g; print $t' "$@"
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
  local p="$1" d="$2/tasks/$3/brain" brief="$4" bh bt rel
  bh="$(jq -r '.brain_home // ""' <<<"$p")"; bt="$(jq -r '.brain_home_tilde // ""' <<<"$p")"
  guest_carry_files "$p" "$d"
  # (the longest names first: one may be a folder another is in; a prefix or a pattern of the brain's
  # home stands for what it named there, which is here under the same names)
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ -e "$d/$rel" ]] || compgen -G "$d/${rel%%\**}*" >/dev/null || continue
    brief="${brief//"$bh/$rel"/"$d/$rel"}"
    [[ -z "$bt" ]] || brief="${brief//"$bt/$rel"/"$d/$rel"}"
  done < <(jq -r '.carry // [] | sort_by(-length) | .[]' <<<"$p")
  if [[ "$(jq -r '.files // [] | length' <<<"$p")" != 0 ]]; then
    brief+=$'\n\n'"## Files of the brain's home"$'\n\n'"The files of the brain's home that this brief names are copies, read-only, under $d, at the same paths as in that home (tasks/<id>/report.md is $d/tasks/<id>/report.md). Write nothing there: what you make goes in your worktree and your report. They are brought up to date when the XO steers you."
  fi
  printf '%s' "$brief"
}
# The brain's files for a task, written read-only into its brain/ folder (dispatch, and each steer: brought up to date).
guest_carry_files() { # <payload> <brain dir>
  local p="$1" d="$2" rel i n
  n="$(jq -r '.files // [] | length' <<<"$p")"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n <= CR_CARRY_MAX_FILES )) || n=0
  for ((i = 0; i < n; i++)); do
    rel="$(jq -r --argjson i "$i" '.files[$i].rel // ""' <<<"$p")"
    [[ "$rel" =~ ^[A-Za-z0-9_@+][A-Za-z0-9._@+-]*(/[A-Za-z0-9_@+][A-Za-z0-9._@+-]*)*$ && "$rel" != *..* ]] || continue
    mkdir -p "$d/$(dirname "$rel")"
    rm -f "$d/$rel.new"
    if jq -r --argjson i "$i" '.files[$i].b64 // ""' <<<"$p" | base64 -d >"$d/$rel.new" 2>/dev/null; then chmod a-w "$d/$rel.new"; mv -f "$d/$rel.new" "$d/$rel"; else rm -f "$d/$rel.new"; fi
  done
}

# A dispatch, with what says one is under way here (<guest home>/.prep/<id>: a clone or a setup can take
# minutes, and a close that comes meanwhile cancels it).
device_cmd_dispatch() { # <payload>
  local home id d rc=0
  home="$(jq -r '.home // ""' <<<"$1")"; id="$(jq -r '.id // ""' <<<"$1")"
  [[ "$home" =~ ^[a-z][a-z0-9-]{0,31}$ && "$id" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "dispatch: a home and a task id are needed" >&2; return 2; }
  d="$(guest_dir "$home")/.prep"; mkdir -p "$d"; rm -f "$d/$id.cancel"; echo "$BASHPID" >"$d/$id"
  guest_dispatch "$1" || rc=$?
  rm -f "$d/$id" "$d/$id.cancel"
  return "$rc"
}
guest_cancelled() { # <home> <id>
  [[ -e "$(guest_dir "$1")/.prep/$2.cancel" ]] || return 1
  echo "closed on the brain while its project was being prepared here; nothing was started" >&2
}

guest_dispatch() { # <payload>
  local p="$1" home id kind backend base branch project brief bh attempt g st args=() a new=1 rc name top
  home="$(jq -r '.home // ""' <<<"$p")"; id="$(jq -r '.id // ""' <<<"$p")"; kind="$(jq -r '.kind // ""' <<<"$p")"
  backend="$(jq -r '.backend // ""' <<<"$p")"; base="$(jq -r '.base // ""' <<<"$p")"; branch="$(jq -r '.branch // ""' <<<"$p")"
  project="$(jq -r '.project // ""' <<<"$p")"; bh="$(jq -r '.brain_home // ""' <<<"$p")"; attempt="$(jq -r '.attempt // 0' <<<"$p")"
  [[ "$home" =~ ^[a-z][a-z0-9-]{0,31}$ && "$id" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "dispatch: a home and a task id are needed" >&2; return 2; }
  local nb; nb="$(node_backends)"
  [[ "$kind" =~ ^(ship|scout)$ && "$backend" =~ ^($nb)$ && "$base" =~ ^[0-9a-f]{40}$ && "$attempt" =~ ^[0-9]+$ ]] ||
    { echo "dispatch: kind, backend (${nb//|/ or }), base and attempt are needed" >&2; return 2; }
  project="$(guest_map_path "$project")"
  if [[ "$kind" == ship ]]; then
    [[ "$branch" =~ ^[A-Za-z0-9._/-]{1,200}$ && "$branch" != *..* && "$branch" == *"$id" ]] || { echo "dispatch: the branch '$branch' is not one this task can have" >&2; return 2; }
  fi
  [[ "$bh" == /* ]] || { echo "dispatch: the brain's home path is needed" >&2; return 2; }
  g="$(guest_dir "$home")"
  # a dispatch the brain sends again (its answer lost) finds the task and says so, before anything else
  # is looked at: never two workers
  if [[ -f "$(guest_meta_file "$g" "$id")" ]]; then
    new=0; st="$(jq -r '.attempt // 0' "$g/.push/$id.json" 2>/dev/null || echo 0)"
    if [[ -n "$(jq -r '.dispatched // ""' "$(guest_meta_file "$g" "$id")")" ]]; then
      if [[ "$st" == "$attempt" ]]; then echo "already dispatched here (attempt $attempt)"; return 0; fi
      echo "dispatch: attempt $st of $id is still on this machine; close it first" >&2; return 4
    fi
  fi
  # may it take one more? (5: no, and nothing was made here; asked only of new work)
  if (( new )); then a="$(guest_refuses "$p")"; [[ -z "$a" ]] || { echo "$a" >&2; return 5; }; fi
  # its project, and the other repos its brief names (6: not here; 7: a clone or a setup failed)
  GP_PROJECT="" GP_CLONED=0 GP_WAITED=0 GP_PAIRS=()
  if [[ "$(jq -r '.repos // [] | length' <<<"$p")" != 0 ]]; then
    rc=0; guest_prepare "$p" || rc=$?
    (( rc == 0 )) || return "$rc"
    project="$GP_PROJECT"
    if (( GP_WAITED )); then
      ! guest_cancelled "$home" "$id" || return 8
      if (( new )); then a="$(guest_refuses "$p")"; [[ -z "$a" ]] || { echo "$a" >&2; return 5; }; fi
    fi
  else guest_project_ok "$project" || return 6; fi
  mkdir -p "$g/.push"
  jq -r '.workspace // ""' <<<"$p" | grep -E '^[A-Za-z0-9._-]{1,64}$' >"$g/.workspace" || echo "$home-crew" >"$g/.workspace"
  [[ -f "$g/commander.md" ]] || guest_run "$home" init >/dev/null
  if (( new == 0 )); then
    # (made here before, but its worker never started: this attempt takes it over)
    jq -c --argjson a "$attempt" '.attempt = $a' "$g/.push/$id.json" >"$g/.push/$id.json.tmp" && mv "$g/.push/$id.json.tmp" "$g/.push/$id.json"
  else
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
    # (first the checkouts and chartroom itself, which another machine may have elsewhere)
    a="$(jq -r '.brain_bin // ""' <<<"$p")"; [[ "$a" != /* || "$a" == "$CR_BIN" ]] || GP_PAIRS+=("$a" "$CR_BIN")
    brief="$(guest_move_paths "$(jq -r '.brief // ""' <<<"$p")" "${GP_PAIRS[@]+"${GP_PAIRS[@]}"}")"
    brief="$(guest_carry "$p" "$g" "$id" "$brief")"
    brief="${brief//"$bh"/"$g"}"
    top="${project%/"$(jq -r '.prefix // ""' <<<"$p")"}"
    if (( GP_CLONED )); then
      name="$(device_cfg NAME)"
      a="$(env_files_of "$top" 2>/dev/null | paste -sd' ' - || true)"
      if [[ -n "$a" ]]; then
        brief+=$'\n\n'"## This machine"$'\n\n'"You run on ${name:-another machine} ($(uname -s)), in a clone chartroom made here of the project. Its development env files are in that clone ($a), with production values left out; copy what you need into your worktree. If the work needs a value that is not there, post \`blocked\` naming it; do not look for it elsewhere, and do not ask for its value."
      else
        brief+=$'\n\n'"## This machine"$'\n\n'"You run on ${name:-another machine} ($(uname -s)), in a clone chartroom made here of the project. It has no \`.env\` file. If the work needs one, post \`blocked\` naming the file; do not look for it elsewhere, and do not ask for its value."
      fi
    fi
    if (( GP_CLONED )) && [[ -s "$(env_npm_file "$top")" ]]; then
      brief+=$'\n\n'"Its package registries' login is in $(env_npm_file "$top"): run an install with NPM_CONFIG_USERCONFIG=$(env_npm_file "$top"). Never print that file."
    fi
    printf '%s\n' "$brief" >"$g/tasks/$id/brief.md"
    jq -cn --argjson a "$attempt" --argjson o "$(wc -l <"$(guest_log_file "$g" "$id")" | tr -d ' ')" \
      --argjson at "$(date +%s)" '{attempt: $a, off: $o, files: {}, cards: [], at: $at}' >"$g/.push/$id.json"
  fi
  guest_run "$home" dispatch "$id"
}

# Why this machine takes no such task now, or nothing.
guest_refuses() { # <payload>
  place_refuse_here "$(jq -c '.needs // {agent: "", tools: [], repos: []}' <<<"$1")" "$(jq -r 'if .over then 1 else 0 end' <<<"$1")"
}

device_cmd_steer() {
  guest_check "$1" || return
  # (the brain's files it reads, as they are now, before it reads the steer)
  [[ "$(jq -r '.files // [] | length' <<<"$1")" == 0 ]] || guest_carry_files "$1" "$G_DIR/tasks/$G_ID/brain"
  guest_run "$G_HOME" steer "$G_ID" "$(jq -r '.text // ""' <<<"$1")"
}
device_cmd_stop() {
  # (a dispatch still cloning or setting up: cancelled, and nothing is started)
  if guest_cancel_prep "$1"; then echo "its project was still being prepared here: cancelled, and nothing was started"; return 0; fi
  guest_check "$1" || return; guest_run "$G_HOME" stop "$G_ID"
}
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
# Cancels a dispatch of the task still cloning or setting up here; 1 when there is none.
guest_cancel_prep() { # <payload {home, id}>
  local pf; pf="$(guest_dir "$(jq -r '.home // ""' <<<"$1")")/.prep/$(jq -r '.id // ""' <<<"$1")"
  [[ "$pf" =~ /guests/[a-z][a-z0-9-]*/\.prep/[a-z][a-z0-9_-]*$ && -f "$pf" ]] && pid_alive "$(cat "$pf" 2>/dev/null)" || return 1
  : >"$pf.cancel"
}

device_cmd_close() { # <payload {phase, discard, sha}>
  # (a dispatch of it still cloning or setting up stops before it starts a worker)
  guest_cancel_prep "$1" || true
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
      # (a close refused here, say while its worker is still stopping, is the brain's to hear: never closed there alone)
      if [[ "$discard" == true ]]; then guest_run "$G_HOME" close "$G_ID" --discard || return; else guest_run "$G_HOME" close "$G_ID" || return; fi
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
# agy has no hook (only the guard) to report a prompt or a turn that ends unreported, and no watch runs here: every
# 5 s a home with an hc:agy task asks hc (chartroom node agy-look), whose lines go up with its log.
# grok is the same (no reporting hook, state over OSC 7501), so an hc:grok task counts too.
GUEST_AGY_AT=0
guest_agy_look_all() {
  local g sf now_s; now_s="$(date +%s)"
  (( now_s - GUEST_AGY_AT >= 5 )) || return 0
  GUEST_AGY_AT="$now_s"
  for g in "$(guest_root)"/*/; do
    [[ -d "$g/.push" ]] || continue
    for sf in "$g/.push"/*.json; do
      [[ -f "$sf" ]] || continue
      if grep -qE '"backend": *"hc:(agy|grok)"' "$(guest_meta_file "${g%/}" "$(basename "$sf" .json)")" 2>/dev/null; then
        guest_run "$(basename "$g")" node agy-look >/dev/null 2>&1 || true; break
      fi
    done
  done
}

guest_push_all() {
  local g sf home id now_s
  guest_agy_look_all || true
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
