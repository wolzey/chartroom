# shellcheck shell=bash
# migrate-client.sh - what `chartroom migrate-home` runs on the client machine (lib/migrate.sh).
#
# Sent over `ssh <target> 'bash -s -- <sub> <args>'` with this file on stdin, or run by bash here
# for a client on this machine. It must stay bash-3.2-safe: a Mac's ssh shell has /bin/bash 3.2
# and no Homebrew on PATH. It needs bash, git, jq, tar and find, as the probe does.
#
# Read-only subcommands print to stdout and write nothing:
#   whoami                        HOME and user
#   capable <bin>                 exit 0 when that chartroom has migrate-home (it honours a freeze)
#   homes                         this machine's registered homes, "name<TAB>path"
#   status <home> <bin>           `chartroom status --json --all` in that home
#   facts <home> <claude> <codex> <awk>  one JSON object per task: its record, its worktree's
#                                 git, its session's transcript; <awk> derives a task's state from
#                                 its log, the same program the brain uses (CR_STATE_AWK)
#   records <home>                a tar of the home's records (the filter below)
#   skipped <home>                what that filter leaves out for its size, "bytes<TAB>path"
#   claude <claude> <sid> <cwd>...  a tar of each session's transcript, its dir and file history
#   codex <codex> <path>...       a tar of Codex rollouts (paths under <codex>/sessions)
#   xo <home> <claude>            a tar of the home's own Claude project dir (XO sessions, memory)
#   dirty <wt>                    a tar of staged.patch, unstaged.patch and untracked.tar
#   ignored <wt>                  a tar of the worktree's small ignored files (.env.local and the like)
# Subcommands that write (each prints "+ <command>" before it runs it; DRY=1 prints only):
#   snapshot <home> <dir>         tar.gz of the home without worktrees/ or node_modules
#   freeze <home> <bin> <to>      the .migrating marker, the dashboard stopped
#   park <home> <bin> <id>...     `chartroom park` each (a worker not at rest is reported)
#   settle <home> <bin> <action> <id>  accept+close, or close
#   finish <home> <bin> <name> <stamp> <brain> <wt>...  lock worktrees, rename, fresh stub
#   unfinish <home> <stamp> <wt>... the rename undone, the worktrees unlocked
#   thaw <home>                   the .migrating marker removed
#   reap <home> <stamp> <wt>...   remove clean worktrees and the renamed home

# Over ssh a Mac's PATH lacks Homebrew and ~/.local/bin; a client on this machine keeps its own.
[ "${CR_MIG_REMOTE:-}" = 1 ] && export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
G="git --no-optional-locks"
run() { echo "+ $*" >&2; [ "${DRY:-}" = 1 ] || "$@"; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64; else sha256sum | cut -c1-64; fi; }
enc() { printf '%s' "${1//[^A-Za-z0-9]/-}"; }

# The records: top-level files and the shared dirs of the home (no dot-state, nothing 0600, no
# secrets/), and per task its top-level files (no launcher, settings, pane or hook logs), its
# artifacts and messages. Never worktrees/ or anything else inside a task dir; at most 4 MB a file,
# except artifacts and messages.
records_list() { # <home> -> NUL-separated relative paths
  local h="$1" f
  cd "$h" || exit 1
  find . -mindepth 1 -maxdepth 1 -type f ! -name '.*' ! -perm 0600 -size -4097k -print0
  find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name tasks ! -name worktrees ! -name secrets ! -name clones -print0 |
    while IFS= read -r -d '' f; do find "$f" -type f ! -perm 0600 -size -4097k ! -path '*/node_modules/*' ! -path '*/.git/*' -print0; done
  find ./tasks -mindepth 2 -maxdepth 2 -type f ! -name launch.sh ! -name claude-settings.json ! -name pane.log \
    ! -name hooks.log ! -name '.*' ! -name '*.tmp' -size -4097k -print0 2>/dev/null
  # Artifacts and messages are the commander's records: whatever their size.
  find ./tasks -mindepth 3 -type f \( -path './tasks/*/artifacts/*' -o -path './tasks/*/messages/*' -o -path './tasks/*/migrate/*' \) \
    -print0 2>/dev/null
}

sub="${1:-}"; shift || true
case "$sub" in
  whoami)
    printf 'home\t%s\nuser\t%s\n' "$HOME" "$(id -un)" ;;
  homes)
    f="$HOME/.config/chartroom/homes"
    [ -f "$f" ] || exit 0
    grep -vE '^[[:space:]]*(#|$)' "$f" | sed "s|^\([^=]*\)=~|\1=$HOME|; s|=|	|" ;;
  status)
    CHARTROOM_HOME="$1" "$2" status --json --all ;;
  capable)
    "$1" help 2>/dev/null | grep -q 'chartroom migrate-home' ;;
  facts)
    h="$1"; claude="$2"; codex="$3"; awkp="$4"
    for m in "$h"/tasks/*/meta.json; do
      [ -f "$m" ] || continue
      d="${m%/meta.json}"; id="${d##*/}"
      lb=0; ls=""
      if [ -f "$d/events.log" ]; then lb=$(wc -c <"$d/events.log" | tr -d ' '); ls=$(sha <"$d/events.log"); fi
      closed=$(jq -r '.closed // ""' "$m"); dispatched=$(jq -r '.dispatched // ""' "$m")
      if [ -n "$closed" ]; then st=closed; elif [ -z "$dispatched" ]; then st=drafting
      else st=$(awk "$awkp" "$d/events.log" 2>/dev/null); fi
      wt=$(jq -r '.worktree // ""' "$m"); sid=$(jq -r '.session_id // ""' "$m"); tid=$(jq -r '.thread_id // ""' "$m")
      wst=none root="" remote="" branch="" head="" dirty="" unpushed="" ahead="" porc="" diffsha=""
      if [ -z "$closed" ] && [ -n "$wt" ]; then
        if [ ! -e "$wt" ]; then wst=missing
        elif $G -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
          case "$wt" in */.worktrees/*|*/worktrees/*) wst=own ;; *) wst=shared ;; esac
          root=$($G -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); root="${root%/.git}"
          remote=$($G -C "$wt" remote get-url origin 2>/dev/null || true)
          branch=$($G -C "$wt" symbolic-ref --short -q HEAD || true)
          head=$($G -C "$wt" rev-parse HEAD 2>/dev/null || true)
          porc=$($G -C "$wt" status --porcelain 2>/dev/null | LC_ALL=C sort)
          dirty=$(printf '%s' "$porc" | grep -c . || true)
          unpushed=$($G -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || true)
          def=$($G -C "$wt" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
          [ -n "$def" ] || def=origin/main
          ahead=$($G -C "$wt" rev-list --count HEAD --not "$def" 2>/dev/null || true)
          diffsha=$($G -C "$wt" diff --binary HEAD 2>/dev/null | sha)
          porc=$(printf '%s' "$porc" | sha)
        else wst=nogit; fi
      fi
      # The session: the recorded one, else the transcript under the worktree's dir that holds the
      # brief's line (as lib/park.sh's claude_legacy_session trusts one).
      tpath="" tsize="" tsha="" legacy=""
      if [ -z "$closed" ] && [ -n "$wt" ]; then
        pd="$claude/projects/$(enc "$wt")"
        if [ -z "$sid" ] && [ -d "$pd" ]; then
          f=$(grep -lF "Your task id is $id." "$pd"/*.jsonl 2>/dev/null | head -1 || true)
          if [ -n "$f" ]; then sid=$(basename "$f" .jsonl); legacy=1; fi
        fi
        if [ -n "$sid" ] && [ -s "$pd/$sid.jsonl" ]; then
          tpath="$pd/$sid.jsonl"; tsize=$(wc -c <"$tpath" | tr -d ' '); tsha=$(sha <"$tpath")
        fi
      fi
      rollout=""
      if [ -z "$closed" ] && [ -n "$tid" ] && [ -d "$codex/sessions" ]; then
        rollout=$(find "$codex/sessions" -name "*$tid.jsonl" 2>/dev/null | head -1)
      fi
      jq -cn --arg id "$id" --arg st "$st" --argjson lb "$lb" --arg ls "$ls" --arg wt "$wt" --arg wst "$wst" \
        --arg root "$root" --arg remote "$remote" --arg branch "$branch" --arg head "$head" --arg dirty "$dirty" \
        --arg unpushed "$unpushed" --arg ahead "$ahead" --arg porc "$porc" --arg diffsha "$diffsha" --arg sid "$sid" \
        --arg legacy "$legacy" --arg tpath "$tpath" --arg tsize "$tsize" --arg tsha "$tsha" --arg tid "$tid" --arg rollout "$rollout" \
        --slurpfile meta "$m" '
        def num: if . == "" then null else (tonumber? // null) end;
        {id: $id, closed: (($meta[0].closed // "") != ""), state: $st, log_bytes: $lb, log_sha: $ls,
         kind: ($meta[0].kind // ""), backend: ($meta[0].backend // ""), project: ($meta[0].project // ""),
         meta_branch: ($meta[0].branch // ""), worktree: $wt, wst: $wst, root: $root, remote: $remote,
         branch: $branch, head: $head, dirty: ($dirty | num), unpushed: ($unpushed | num), ahead: ($ahead | num),
         porcelain_sha: $porc, diff_sha: $diffsha, session_id: $sid, session_legacy: ($legacy == "1"),
         transcript: $tpath, transcript_size: ($tsize | num), transcript_sha: $tsha, thread_id: $tid, rollout: $rollout}'
    done ;;
  records)
    records_list "$1" | ( cd "$1" && tar -cf - --null -T - ) ;;
  skipped)
    cd "$1" || exit 1
    { find . -mindepth 1 -maxdepth 1 -type f ! -name '.*' -size +4096k
      find ./tasks -mindepth 2 -maxdepth 2 -type f -size +4096k ! -name pane.log ! -name hooks.log 2>/dev/null
      find . -mindepth 1 -maxdepth 1 -type f ! -name '.*' -perm 0600
    } | while IFS= read -r f; do printf '%s\t%s\n' "$(wc -c <"$f" | tr -d ' ')" "${f#./}"; done ;;
  claude)
    c="$1"; shift
    while [ $# -ge 2 ]; do
      s="$1"; w="$2"; shift 2; p="projects/$(enc "$w")"
      [ -f "$c/$p/$s.jsonl" ] && printf '%s\0' "$p/$s.jsonl"
      [ -d "$c/$p/$s" ] && printf '%s\0' "$p/$s"
      [ -d "$c/file-history/$s" ] && printf '%s\0' "file-history/$s"
    done | ( cd "$c" && tar -cf - --null -T - ) ;;
  codex)
    c="$1"; shift
    for p in "$@"; do case "$p" in "$c/sessions/"*) printf '%s\0' "${p#"$c"/}" ;; esac; done | ( cd "$c" && tar -cf - --null -T - ) ;;
  xo)
    c="$2"; p="projects/$(enc "$1")"
    if [ -d "$c/$p" ]; then ( cd "$c" && tar -cf - "$p" ); else ( cd "$c" 2>/dev/null || cd /; tar -cf - --null -T /dev/null ); fi ;;
  dirty)
    wt="$1"; t=$(mktemp -d "${TMPDIR:-/tmp}/crmig.XXXXXX") || exit 1
    $G -C "$wt" diff --binary --cached >"$t/staged.patch"
    $G -C "$wt" diff --binary >"$t/unstaged.patch"
    ( cd "$wt" && $G ls-files -o --exclude-standard -z | tar -cf "$t/untracked.tar" --null -T - )
    ( cd "$t" && tar -cf - staged.patch unstaged.patch untracked.tar )
    rm -rf "$t" ;;
  ignored)
    # Small ignored files a worker may need that git cannot rebuild (.env.local and the like): at
    # most 1 MB each, never under node_modules, build output or vendored dependencies.
    wt="$1"
    ( cd "$wt" && $G ls-files -o -i --exclude-standard --directory 2>/dev/null | while IFS= read -r f; do
        case "$f" in */|*node_modules*|*.next/*|dist/*|build/*|target/*|vendor/*|coverage/*|*.log) continue ;; esac
        [ -f "$f" ] && [ "$(wc -c <"$f" | tr -d ' ')" -le 1048576 ] && printf '%s\0' "$f"
      done | tar -cf - --null -T - ) ;;
  snapshot)
    h="$1"; dir="$2"; name="${h##*/}"
    run mkdir -p "$dir"
    echo "+ tar -czf $dir/$name.tgz -C ${h%/*} $name (without worktrees/, node_modules, .git)" >&2
    [ "${DRY:-}" = 1 ] || tar -czf "$dir/$name.tgz" --exclude "$name/worktrees" --exclude node_modules --exclude .git -C "${h%/*}" "$name"
    [ "${DRY:-}" = 1 ] || printf '%s\t%s\n' "$dir/$name.tgz" "$(tar -tzf "$dir/$name.tgz" | grep -vc '/$')" ;;
  freeze)
    h="$1"; bin="$2"; to="$3"
    [ -f "$h/.migrating" ] || { echo "+ write $h/.migrating" >&2; [ "${DRY:-}" = 1 ] || jq -cn --arg to "$to" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{to: $to, at: $at}' >"$h/.migrating"; }
    run env CHARTROOM_HOME="$h" "$bin" dashboard stop >/dev/null 2>&1 || true ;;
  park)
    h="$1"; bin="$2"; shift 2
    for id in "$@"; do
      if out=$(run env CHARTROOM_HOME="$h" "$bin" park "$id" 2>&1); then printf 'parked\t%s\n' "$id"
      else printf 'not-parked\t%s\t%s\n' "$id" "$(printf '%s' "$out" | tr '\n\t' '  ')"; fi
    done ;;
  settle)
    h="$1"; bin="$2"; act="$3"; id="$4"
    if [ "$act" = accept ]; then run env CHARTROOM_HOME="$h" "$bin" accept "$id" >/dev/null 2>&1 || true; fi
    if out=$(run env CHARTROOM_HOME="$h" "$bin" close "$id" 2>&1); then printf 'closed\t%s\n' "$id"
    else printf 'refused\t%s\t%s\n' "$id" "$(printf '%s' "$out" | tr '\n\t' '  ')"; fi ;;
  finish)
    h="$1"; bin="$2"; name="$3"; stamp="$4"; brain="$5"; shift 5
    arch="${h%/*}/.migrated/${h##*/}-$stamp"
    for w in "$@"; do [ -e "$w" ] && run git -C "$w" worktree lock --reason "chartroom migration to $brain: rollback until 14 days after $stamp" "$w" 2>/dev/null; done
    run mkdir -p "${h%/*}/.migrated"
    run mv "$h" "$arch"
    run mkdir -p "$h"
    run env CHARTROOM_HOME="$h" "$bin" init --name "$name" >/dev/null
    [ -f "$arch/config" ] && run cp "$arch/config" "$h/config"
    if env CHARTROOM_HOME="$h" "$bin" help 2>/dev/null | grep -q 'brain link'; then
      run env CHARTROOM_HOME="$h" "$bin" brain link "$brain" --as "$name"
    else
      echo "this client's chartroom has no 'brain link' yet: $h is a fresh, empty home; link it once forwarding is installed" >&2
    fi
    printf 'archived\t%s\n' "$arch" ;;
  unfinish)
    h="$1"; stamp="$2"; shift 2
    arch="${h%/*}/.migrated/${h##*/}-$stamp"
    [ -d "$arch" ] || { echo "no archived home at $arch" >&2; exit 1; }
    if [ -e "$h" ]; then run mv "$h" "${h%/*}/.migrated/${h##*/}-stub-$(date -u +%Y%m%dT%H%M%SZ)"; fi
    run mv "$arch" "$h"
    run rm -f "$h/.migrating"
    for w in "$@"; do [ -e "$w" ] && run git -C "$w" worktree unlock "$w" 2>/dev/null; done
    true ;;
  thaw)
    run rm -f "$1/.migrating" ;;
  reap)
    h="$1"; stamp="$2"; shift 2
    arch="${h%/*}/.migrated/${h##*/}-$stamp"; keep_arch=""
    for w in "$@"; do
      # A worktree inside the home moved with it into the archive: checked there, never removed
      # with the archive while it holds uncommitted work.
      case "$w" in "$h"/*) a="$arch/${w#"$h"/}"
        if [ -e "$a" ] && [ -n "$($G -C "$a" status --porcelain 2>/dev/null)" ]; then printf 'kept-dirty\t%s\n' "$a"; keep_arch=1; fi
        continue ;; esac
      [ -e "$w" ] || continue
      if [ -n "$($G -C "$w" status --porcelain 2>/dev/null)" ]; then printf 'kept-dirty\t%s\n' "$w"; continue; fi
      r=$($G -C "$w" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); r="${r%/.git}"
      run git -C "$r" worktree unlock "$w" 2>/dev/null
      if run git -C "$r" worktree remove "$w"; then printf 'removed\t%s\n' "$w"; else printf 'kept\t%s\n' "$w"; fi
    done
    if [ -n "$keep_arch" ]; then printf 'kept\t%s\t(a worktree in it has uncommitted work)\n' "$arch"
    elif [ -d "$arch" ]; then run rm -rf "$arch" && printf 'removed\t%s\n' "$arch"; fi
    true ;;
  *) echo "migrate-client: unknown subcommand '$sub'" >&2; exit 2 ;;
esac
