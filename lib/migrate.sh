# shellcheck shell=bash
# migrate.sh - `chartroom migrate-home`: move a home from a client machine into this one, the
# brain (one-brain step 2). It runs on the brain. One home at a time, in this order:
#
#   triage    read-only: every open task of the client home in a bucket, a decisions.tsv prefilled
#   snapshot  a tar.gz of the home on both machines (--all: every registered home)
#   freeze    client: the .migrating marker (new, dispatch, steer and attach refuse there), the
#             dashboard stopped, every live worker parked once at rest
#   settle    the commander's decisions: close and accept on the client; bundle: the branch and its
#             uncommitted changes fetched here and packed into a git bundle, then closed there
#   move      every record (closed ones too, records only), the open tasks' conversations, their
#             branches (git fetch, read-only on the client), their uncommitted changes, a worktree
#             rebuilt for each `move` task, and the home's own files merged (below)
#   verify    the brain's home equals the union of both sources; must pass before finish
#   finish    client: worktrees locked, the home renamed to .migrated/<home>-<stamp>, a fresh stub
#             in its place, linked to the brain (`brain link`, one-brain step 1) when installed
#   rollback  undoes move (and finish) from the records kept under the state dir
#   materialize <id>  a moved task's worktree, rebuilt on first use (hc's revive calls it)
#   restore <id>      a bundled task's branch and worktree back
#   reap      after 14 days, on the commander's word: the client's clean worktrees and its renamed home
#   status    the state dir's ledger
#
# The client is `--from <ssh target>`, or `--from local` for a home on this machine. Paths are the
# same on both machines (same user, same layout); CHARTROOM_MIGRATE_PATH_MAP="<from>=<to>" maps a
# path prefix where they are not (a client on this machine: the tests). Every client read is a
# fixed subcommand of lib/migrate-client.sh, a tar stream or a `git fetch` (git-upload-pack); it
# writes there only in snapshot, freeze, settle, finish, rollback and reap, and --dry-run prints
# those commands without running them. Ids, paths and branches come from the client's own records.
#
# State: ~/.local/state/chartroom/migrate/<from>-<home>/ (state.json, triage.json, decisions.tsv,
# facts.jsonl, ledger.tsv, the staged merge, backups of every brain file a merge replaced).
#
# The merge, for a home both machines have (B: the brain's, C: the client's):
#   tasks/<id>       union (ids are unique; the same id on both is a conflict, never overwritten)
#   meta.json        machine handles cleared (pids, tmux/herdr/hc), migrated_* added; a Claude
#                    session that can resume lands parked on hc:claude
#   rulings.log      union of lines, stable-sorted by timestamp, so the newest per topic wins; a
#                    ruling id on both with different text is renamed on B's side
#   commander.md     C's (or its captain.md) is the base; B's lines it lacks are appended under a
#                    heading for review; the rulings block is rendered again
#   inbox.md         per section, C's items, then B's whose id C lacks (a clash re-ids B's item)
#   inbox/, artifacts, other top-level files  union; the same path with other bytes keeps B's and
#                    adds C's beside it as <name>.from-<from><.ext>
#   relays           union by record; the watch cursor moves past it
#   config           B's keys win (its own dashboard port); C's other keys are added
#   projects.md      union of lines, C's first; focus.json B's unless only C has one
#   the XO's Claude project dir  sessions unioned, memory files unioned (a clash: <name>.from-<from>.md)

CR_MIG_STATE_V=1
CR_MIG_RECORD_MAX_KB=4096
CR_MIG_HANDLES='["pid","tmux_session","tmux_pane","herdr_pane","herdr_tab","herdr_workspace","herdr_launched","hc_terminal","hc_tab","hc_space","hc_launched","agent_id"]'

# ---------------------------------------------------------------- options and transport

mig_usage() {
  cat <<'EOF'
usage: chartroom migrate-home <verb> --from <ssh target|local> --home <name> [options]
  verbs: triage | snapshot [--all] | freeze | settle [--decisions FILE] | move | verify |
         resync [--task ID] | finish --brain <target> | rollback | status | reap --apply
         materialize <id> | restore <id>          (in this home: no --from)
  options: --client-home PATH  --brain-home PATH  --dry-run  --prs FILE  --no-prs  --clone-missing
           --unguarded (freeze: a client chartroom without the freeze guard, on the commander's word)
           --except ID (repeatable; triage, move, verify, status): a partial move of a client home that
             stays in use. These tasks stay there, untouched; the other tasks, rulings.log and the inbox
             come over. Nothing is written on the client: no freeze, settle or finish
EOF
}

# Parses the shared options into MIG_*; the rest stay in MIG_ARGS.
mig_opts() {
  MIG_FROM="" MIG_HOME="" MIG_CHOME="" MIG_BHOME="" MIG_DRY=0 MIG_PRS="" MIG_NOPRS=0 MIG_DECISIONS=""
  MIG_BRAIN="" MIG_ALL=0 MIG_APPLY=0 MIG_CLONE=0 MIG_UNGUARDED=0 MIG_ARGS=() MIG_TASKS="" MIG_EXCEPT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) MIG_FROM="${2:-}"; shift 2 ;;
      --home) MIG_HOME="${2:-}"; shift 2 ;;
      --client-home) MIG_CHOME="${2:-}"; shift 2 ;;
      --brain-home) MIG_BHOME="${2:-}"; shift 2 ;;
      --brain) MIG_BRAIN="${2:-}"; shift 2 ;;
      --decisions) MIG_DECISIONS="${2:-}"; shift 2 ;;
      --prs) MIG_PRS="${2:-}"; shift 2 ;;
      --no-prs) MIG_NOPRS=1; shift ;;
      --dry-run) MIG_DRY=1; shift ;;
      --all) MIG_ALL=1; shift ;;
      --apply) MIG_APPLY=1; shift ;;
      --clone-missing) MIG_CLONE=1; shift ;;
      --unguarded) MIG_UNGUARDED=1; shift ;;
      --task) [[ "${2:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "migrate-home: --task needs a task id"; MIG_TASKS+=" $2 "; shift 2 ;;
      --except) [[ "${2:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "migrate-home: --except needs a full task id"; MIG_EXCEPT+=" $2 "; shift 2 ;;
      -h|--help) mig_usage; exit 0 ;;
      *) MIG_ARGS+=("$1"); shift ;;
    esac
  done
}

mig_local() { [[ "$MIG_FROM" == local ]]; }
mig_partial() { [[ -n "${MIG_EXCEPT:-}" ]]; }

# Runs a lib/migrate-client.sh subcommand on the client; its stdout is the answer. DRY=1 when
# --dry-run, for the subcommands that write.
mig_client() { # <sub> [args...]
  local dry=""; [[ $MIG_DRY -eq 1 ]] && dry=1
  if mig_local; then
    DRY="$dry" bash "$CR_ROOT/lib/migrate-client.sh" "$@"
  else
    # The remote login shell parses the quoted words (printf %q may use $'...': bash and zsh do).
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 "$MIG_FROM" \
      "CR_MIG_REMOTE=1 DRY=$dry bash -s -- $(printf '%q ' "$@")" <"$CR_ROOT/lib/migrate-client.sh"
  fi
}

mig_git_url() { if mig_local; then printf '%s' "$1"; else printf '%s:%s' "$MIG_FROM" "$1"; fi; } # <client path>

# A client path as it is on the brain: identical, unless CHARTROOM_MIGRATE_PATH_MAP maps its prefix.
mig_map() { # <path>
  local m="${CHARTROOM_MIGRATE_PATH_MAP:-}" from to
  if [[ -n "$m" && -n "$1" ]]; then
    from="${m%%=*}"; to="${m#*=}"
    if [[ "$1" == "$from" || "$1" == "$from"/* ]]; then printf '%s%s' "$to" "${1#"$from"}"; return; fi
  fi
  printf '%s' "$1"
}

mig_enc() { printf '%s' "${1//[^A-Za-z0-9]/-}"; } # a cwd as Claude Code names its project dir
mig_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64; else sha256sum | cut -c1-64; fi; }
mig_sha_prefix() { head -c "$2" "$1" | mig_sha; } # <file> <bytes>
mig_label() { if mig_local; then printf local; else printf '%s' "$MIG_FROM"; fi; }

# Resolves the two homes and the state dir; checks the client answers.
mig_setup() {
  [[ -n "$MIG_FROM" ]] || die "migrate-home: --from <ssh target|local> is required"
  [[ "$MIG_FROM" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die "migrate-home: --from must be an ssh target or 'local'"
  [[ "$MIG_HOME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "migrate-home: --home <name> is required (a registered home's name)"
  local who
  who="$(mig_client whoami)" || die "migrate-home: the client $MIG_FROM did not answer"
  MIG_CLIENT_HOME_DIR="$(awk -F'\t' '$1 == "home" { print $2 }' <<<"$who")"
  if [[ -z "$MIG_BHOME" ]]; then
    MIG_BHOME="$(homes_entries | awk -F'\t' -v n="$MIG_HOME" '$1 == n { p = $2 } END { print p }')"
    [[ -n "$MIG_BHOME" ]] || MIG_BHOME="$HOME/chartroom/$MIG_HOME"
  fi
  if [[ -z "$MIG_CHOME" ]]; then
    MIG_CHOME="$(mig_client homes | awk -F'\t' -v n="$MIG_HOME" '$1 == n { p = $2 } END { print p }')"
    [[ -n "$MIG_CHOME" ]] || die "migrate-home: the client has no home named $MIG_HOME (its homes file)"
  fi
  if ! mig_local && [[ -z "${CHARTROOM_MIGRATE_PATH_MAP:-}" && "$MIG_CLIENT_HOME_DIR" != "$HOME" ]]; then
    die "migrate-home: the client's HOME is $MIG_CLIENT_HOME_DIR, this machine's $HOME: paths must be the same (or set CHARTROOM_MIGRATE_PATH_MAP)"
  fi
  MIG_CCLAUDE="${CHARTROOM_MIGRATE_CLIENT_CLAUDE_DIR:-$MIG_CLIENT_HOME_DIR/.claude}"
  MIG_CCODEX="${CHARTROOM_MIGRATE_CLIENT_CODEX_DIR:-$MIG_CLIENT_HOME_DIR/.codex}"
  if mig_local; then MIG_CBIN="${CHARTROOM_MIGRATE_CLIENT_BIN:-$CR_BIN}"
  else MIG_CBIN="${CHARTROOM_MIGRATE_CLIENT_BIN:-$MIG_CLIENT_HOME_DIR/.local/bin/chartroom}"; fi
  MIG_BCLAUDE="$(claude_config_dir)"
  MIG_BCODEX="${CODEX_HOME:-$HOME/.codex}"
  # Outside the home: a client home's copy of the brain's records must not carry this (staged copies
  # of a whole home, bundles). A state dir from an older migrate-home, inside the home, is still used.
  MIG_S="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/migrate/$(mig_label)-$MIG_HOME"
  [[ -f "$MIG_BHOME/records/migrate/$(mig_label)-$MIG_HOME/state.json" ]] && MIG_S="$MIG_BHOME/records/migrate/$(mig_label)-$MIG_HOME"
  # A partial move keeps its own state, so the home's full move later starts from nothing done.
  if mig_partial; then MIG_S="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/migrate/$(mig_label)-$MIG_HOME.partial"; fi
  mkdir -p "$MIG_S"
  [[ -f "$MIG_S/state.json" ]] || jq -n --argjson v "$CR_MIG_STATE_V" --arg from "$MIG_FROM" --arg home "$MIG_HOME" \
    --arg c "$MIG_CHOME" --arg b "$MIG_BHOME" --arg stamp "$(date -u +%Y%m%dT%H%M%SZ)" \
    '{v: $v, from: $from, home: $home, client_home: $c, brain_home: $b, stamp: $stamp, steps: {}}' >"$MIG_S/state.json"
  MIG_STAMP="$(jq -r .stamp "$MIG_S/state.json")"
  if mig_partial; then
    local ex; ex="$(tr -s ' ' '\n' <<<"$MIG_EXCEPT" | grep . | sort -u | tr '\n' ' ')"
    if [[ -f "$MIG_S/except.txt" ]]; then [[ "$(cat "$MIG_S/except.txt")" == "$ex" ]] || die "migrate-home: this partial move was started with --except $(cat "$MIG_S/except.txt")"
    else printf '%s' "$ex" >"$MIG_S/except.txt"; fi
  fi
}

mig_step_done() { jq -e --arg s "$1" '.steps[$s] // false' "$MIG_S/state.json" >/dev/null 2>&1; } # <step>
mig_mark() { # <step> [json value]
  local f="$MIG_S/state.json"
  jq --arg s "$1" --argjson v "${2:-true}" --arg at "$(now)" '.steps[$s] = $v | .at[$s] = $at' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
mig_ledger() { # <id|*> <outcome> [detail]: a dry run prints what it would record, and records nothing
  local d="${3:-}"
  if [[ $MIG_DRY -eq 1 ]]; then printf '(dry run) %s %s %s\n' "$1" "$2" "${d//$'\t'/ }"; return 0; fi
  printf '%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "${3:-}" >>"$MIG_S/ledger.tsv"
}

# ---------------------------------------------------------------- facts and triage

# One JSON object per task of the client home (lib/migrate-client.sh facts), kept as facts.jsonl.
mig_facts() {
  mig_client facts "$MIG_CHOME" "$MIG_CCLAUDE" "$MIG_CCODEX" "$CR_STATE_AWK" >"$MIG_S/facts.jsonl.tmp" ||
    die "migrate-home: could not read the client's task facts"
  if mig_partial; then
    local x
    for x in $MIG_EXCEPT; do
      jq -e -s --arg i "$x" 'any(.[]; .id == $i)' "$MIG_S/facts.jsonl.tmp" >/dev/null || die "migrate-home: --except $x: no such task on the client"
    done
    jq -c --arg x "$MIG_EXCEPT" 'select(.id as $i | $x | contains(" " + $i + " ") | not)' "$MIG_S/facts.jsonl.tmp" >"$MIG_S/facts.jsonl.tmp2" &&
      mv "$MIG_S/facts.jsonl.tmp2" "$MIG_S/facts.jsonl.tmp"
  fi
  mv "$MIG_S/facts.jsonl.tmp" "$MIG_S/facts.jsonl"
}

# The PRs of every repo the open tasks' branches live in: {repo, head_ref, state, number, title,
# url, head}. GitHub through gh, Azure DevOps through az; --prs FILE stands in (the tests).
mig_prs() { # <facts.jsonl>
  if [[ -n "$MIG_PRS" ]]; then cat "$MIG_PRS"; return; fi
  [[ $MIG_NOPRS -eq 1 ]] && return 0
  local remote r org proj repo
  while IFS= read -r remote; do
    r="$(sed -E 's#^(ssh://)?(git@|https://)##; s#^([^/:]+):#\1/#; s#\.git$##' <<<"$remote")"
    case "$r" in
      github.com/*)
        command -v gh >/dev/null 2>&1 || continue
        gh pr list -R "${r#github.com/}" --author @me --state all --limit 1000 --json headRefName,state,number,title,url,headRefOid 2>/dev/null |
          jq -c --arg r "$r" '.[] | {repo: $r, head_ref: .headRefName, state, number, title, url, head: .headRefOid}' || true ;;
      ssh.dev.azure.com/v3/*|dev.azure.com/*)
        command -v az >/dev/null 2>&1 || continue
        IFS=/ read -r org proj repo < <(sed -E 's#^ssh\.dev\.azure\.com/v3/##; s#^dev\.azure\.com/##; s#/_git/#/#' <<<"$r")
        az repos pr list --org "https://dev.azure.com/$org" --project "$proj" --repository "$repo" --status all --top 1000 \
          --query '[].{b:sourceRefName,s:status,n:pullRequestId,t:title,h:lastMergeSourceCommit.commitId}' -o json 2>/dev/null |
          jq -c --arg r "$r" --arg u "https://dev.azure.com/$org/$proj/_git/$repo/pullrequest/" \
            '.[] | {repo: $r, head_ref: (.b | sub("^refs/heads/"; "")), state: .s, number: .n, title: .t, url: ($u + (.n | tostring)), head: .h}' || true ;;
    esac
  done < <(jq -r 'select(.closed | not) | .remote | select(. != "")' "$1" | sort -u)
}

# A worktree the brain already holds for an open task whose record names none (or one that is
# missing here): <project>/.worktrees/*_<id> or <brain home>/worktrees/*/<id>.
mig_brain_orphan() { # <id> <client project>
  local p f; p="$(mig_map "$2")"
  shopt -s nullglob
  for f in "$p"/.worktrees/*_"$1" "$MIG_BHOME"/worktrees/*/"$1"; do [[ -e "$f/.git" ]] && { printf '%s' "$f"; return; }; done
  return 0
}

mig_triage() {
  mig_facts
  local status prs rows now
  status="$(mig_client status "$MIG_CHOME" "$MIG_CBIN")" || die "migrate-home: chartroom status failed on the client"
  printf '%s\n' "$status" >"$MIG_S/client-status.json"
  prs="$(mig_prs "$MIG_S/facts.jsonl" | jq -s -c .)"
  printf '%s\n' "$prs" >"$MIG_S/prs.json"
  now="${CHARTROOM_MIGRATE_NOW:-$(date +%s)}"
  local orphans="{}" id proj wt o
  while IFS=$'\t' read -r id proj wt; do
    [[ -n "$wt" && -e "$(mig_map "$wt")" ]] && continue
    o="$(mig_brain_orphan "$id" "$proj")"
    [[ -n "$o" ]] && orphans="$(jq -c --arg i "$id" --arg o "$o" '.[$i] = $o' <<<"$orphans")"
  done < <(jq -r 'select(.closed | not) | [.id, .project, .worktree] | @tsv' "$MIG_S/facts.jsonl")
  rows="$(jq -c -n --slurpfile st "$MIG_S/client-status.json" --slurpfile f "$MIG_S/facts.jsonl" --slurpfile prsf "$MIG_S/prs.json" \
    --argjson orph "$orphans" --arg ex "${MIG_EXCEPT:-}" '
    $prsf[0] as $prs   # a file, never an argument: a home'"'"'s PRs can pass the argument limit
    | ($f | map({(.id): .}) | add // {}) as $facts
    | ($prs | group_by(.repo + "\u0000" + .head_ref) | map({(.[0].repo + "\u0000" + .[0].head_ref): .}) | add // {}) as $byref
    | [$st[0][] | select(.closed == null) | select(.id as $i | $ex | contains(" " + $i + " ") | not) | . as $s | ($facts[$s.id] // {}) as $g
       | ($g.remote // "" | sub("^(ssh://)?(git@|https://)"; "") | sub("^(?<h>[^/:]+):"; "\(.h)/") | sub("\\.git$"; "")) as $repo
       | ((if ($g.branch // "") != "" then $g.branch else ($s.branch // "") end)) as $br
       | $s + {wst: ($g.wst // "none"), dirty: $g.dirty, unpushed: $g.unpushed, ahead: $g.ahead, head: ($g.head // ""),
               worktree: ($g.worktree // ""), git_branch: $br, repo: $repo, session_id: ($g.session_id // ""),
               prs: [($byref[$repo + "\u0000" + $br] // [])[] | {state, number, title, url, head}],
               studio_wt: ($orph[$s.id] // "")}]')"
  jq --argjson now "$now" -f "$CR_ROOT/lib/migrate_triage.jq" <<<"$rows" >"$MIG_S/triage.json"
  # decisions.tsv: one line per open task; the commander edits the action (accept|close|keep|bundle|move).
  {
    printf '# id\taction\tbucket\twhy\texceptions\ttitle\n'
    jq -r '.[] | [.id, .action, .bucket, .why, (.exc | join("; ")), (.title | gsub("[\t\n]"; " "))] | @tsv' "$MIG_S/triage.json" | sort -t$'\t' -k3,3 -k1,1
  } >"$MIG_S/decisions.tsv"
  mig_mark triage
  mig_triage_print
}

mig_triage_print() {
  jq -r '
    (group_by(.bucket) | map({(.[0].bucket): length}) | add // {}) as $n
    | (group_by(.action) | map({(.[0].action): length}) | add // {}) as $a
    | "open \(length): (a) close in place \($n.a // 0), (b) your word \($n.b // 0), (c) bundle and close \($n.c // 0), (d) move \($n.d // 0)",
      "prefilled: " + ([$a | to_entries[] | "\(.key) \(.value)"] | join(", ")),
      (map(select((.exc | length) > 0)) | if length > 0 then "exceptions:", (.[] | "  \(.id) (\(.bucket)): \(.exc | join("; "))") else empty end)' "$MIG_S/triage.json"
  echo "decisions: $MIG_S/decisions.tsv"
}

# The commander's decision for a task: decisions.tsv (or --decisions FILE) wins over the triage.
mig_decisions() { # -> "id<TAB>action" lines
  local f="${MIG_DECISIONS:-$MIG_S/decisions.tsv}"
  [[ -f "$f" ]] || die "migrate-home: no decisions file ($f): run triage first"
  awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { print $1 "\t" $2 }' "$f" | while IFS=$'\t' read -r id a; do
    [[ "$a" =~ ^(accept|close|keep|bundle|move)$ ]] || die "migrate-home: decision '$a' for $id is not accept|close|keep|bundle|move"
    printf '%s\t%s\n' "$id" "$a"
  done
}
mig_decision_of() { awk -F'\t' -v i="$1" '$1 == i { a = $2 } END { print a }' "$MIG_S/decided.tsv" 2>/dev/null; } # <id>

# ---------------------------------------------------------------- snapshot, freeze, settle

mig_snapshot() {
  local dir="${CHARTROOM_MIGRATE_SNAPSHOT_DIR:-}" cdir bdir h name p
  cdir="${dir:-$MIG_CLIENT_HOME_DIR/chartroom-migrate}/$MIG_STAMP"
  bdir="${dir:-$HOME/chartroom-migrate}/$MIG_STAMP"
  if [[ $MIG_ALL -eq 1 ]]; then
    while IFS=$'\t' read -r name p; do echo "client $name:"; mig_client snapshot "$p" "$cdir/client"; done < <(mig_client homes)
    while IFS=$'\t' read -r name p; do echo "brain $name:"; mig_snapshot_brain "$p" "$bdir/brain"; done < <(homes_entries)
  else
    echo "client:"; mig_client snapshot "$MIG_CHOME" "$cdir/client"
    echo "brain:"; [[ -d "$MIG_BHOME" ]] && mig_snapshot_brain "$MIG_BHOME" "$bdir/brain"
  fi
  [[ $MIG_DRY -eq 1 ]] || mig_mark snapshot "\"$MIG_STAMP\""
}
mig_snapshot_brain() { # <home> <dir>
  local h="$1" dir="$2" name; name="$(basename "$h")"
  [[ -d "$h" ]] || return 0
  echo "+ tar -czf $dir/$name.tgz (without worktrees/, node_modules, .git), and its Claude project dir" >&2
  [[ $MIG_DRY -eq 1 ]] && return 0
  mkdir -p "$dir"
  tar -czf "$dir/$name.tgz" --exclude "$name/worktrees" --exclude node_modules --exclude .git --exclude "$name/records/migrate" -C "$(dirname "$h")" "$name"
  local x; x="projects/$(mig_enc "$h")"
  [[ -d "$MIG_BCLAUDE/$x" ]] && tar -czf "$dir/$name.claude.tgz" -C "$MIG_BCLAUDE" "$x"
  printf '%s\t%s\n' "$dir/$name.tgz" "$(tar -tzf "$dir/$name.tgz" | grep -vc '/$')"
}

mig_freeze() {
  [[ $MIG_DRY -eq 1 ]] || mig_step_done snapshot || die "migrate-home: snapshot first (migrate-home snapshot)"
  if ! mig_client capable "$MIG_CBIN" >/dev/null; then
    # --unguarded: the commander's word that nobody uses the client home meanwhile; the marker is
    # still written, but that chartroom will not refuse new, dispatch, steer or attach.
    [[ $MIG_UNGUARDED -eq 1 ]] || die "migrate-home: the client's chartroom ($MIG_CBIN) has no migrate-home, so it would not honour a freeze: update its install first (or --unguarded, on the commander's word that nobody uses that home meanwhile)"
    echo "warning: the client's chartroom does not honour the freeze: nothing there refuses new, dispatch, steer or attach while it lasts"
    mig_ledger '*' freeze-unguarded "the client's chartroom ($MIG_CBIN) has no migrate-home"
  fi
  mig_client freeze "$MIG_CHOME" "$MIG_CBIN" "$(hostname -s 2>/dev/null || echo brain)" >/dev/null
  # Park every live worker that can be (lib/park.sh decides; one not at rest is reported).
  local live
  live="$(mig_client status "$MIG_CHOME" "$MIG_CBIN" | jq -r '.[] | select(.closed == null and (.live | IN("working", "idle", "done", "blocked"))) | .id')"
  if [[ -n "$live" ]]; then
    # shellcheck disable=SC2086 # ids, one word each
    mig_client park "$MIG_CHOME" "$MIG_CBIN" $live | tee -a "$MIG_S/freeze.tsv"
  fi
  local still
  still="$(mig_client status "$MIG_CHOME" "$MIG_CBIN" | jq -r '.[] | select(.closed == null and (.live | IN("working", "idle", "done", "blocked"))) | "\(.id) \(.live)"')"
  [[ $MIG_DRY -eq 1 ]] && return 0
  if [[ -n "$still" ]]; then
    printf 'still live (park refused it: wait for its turn to end, or answer its prompt, then freeze again):\n%s\n' "$still"
    return 1
  fi
  mig_mark freeze
  echo "frozen: $MIG_CHOME (no live worker)"
}

# The fetch side of a bundle or a move: a task's branch into this checkout, as refs/heads/<branch>
# when the brain has no such branch or has it at the same commit, else refs/chartroom/migrate/<id>.
# Prints the ref that holds the client's HEAD, or nothing (no checkout here, nothing to fetch).
mig_fetch_branch() { # <facts json>
  local f="$1" id root br head proot ref cur
  id="$(jq -r .id <<<"$f")"; root="$(jq -r .root <<<"$f")"; br="$(jq -r .branch <<<"$f")"; head="$(jq -r .head <<<"$f")"
  [[ -n "$root" && -n "$head" ]] || return 0
  proot="$(mig_map "$root")"
  if ! git -C "$proot" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ $MIG_CLONE -eq 1 && -n "$(jq -r .remote <<<"$f")" ]]; then
      git clone --quiet "$(jq -r .remote <<<"$f")" "$proot" >&2 || return 0
    else
      mig_ledger "$id" no-checkout "$proot (git clone it, or run move again with --clone-missing)"; return 0
    fi
  fi
  if git -C "$proot" cat-file -e "$head^{commit}" 2>/dev/null && [[ -z "$br" ]]; then
    ref="refs/chartroom/migrate/$id"; git -C "$proot" update-ref "$ref" "$head"; printf '%s' "$ref"; return 0
  fi
  if [[ -n "$br" ]]; then
    # One fetch per repo brought every branch in already (mig_prefetch): the copy is then local.
    local src="refs/heads/$br" url
    url="$(mig_git_url "$root")"
    if git -C "$proot" rev-parse -q --verify "refs/chartroom/incoming/$id" >/dev/null 2>&1; then url="."; src="refs/chartroom/incoming/$id"; fi
    cur="$(git -C "$proot" rev-parse -q --verify "refs/heads/$br" 2>/dev/null || true)"
    local prevhead; prevhead="$(mig_prev "$id" head)"
    if [[ -z "$cur" || "$cur" == "$head" || ( -n "$prevhead" && "$cur" == "$prevhead" ) ]] && ! mig_checked_out "$proot" "$br"; then
      git -C "$proot" fetch --quiet --no-tags "$url" "+$src:refs/heads/$br" >&2 || true
      ref="refs/heads/$br"
    elif [[ "$cur" == "$head" ]]; then ref="refs/heads/$br"
    else
      git -C "$proot" fetch --quiet --no-tags "$url" "+$src:refs/chartroom/migrate/$id" >&2 || true
      ref="refs/chartroom/migrate/$id"
    fi
  else
    # A detached HEAD: that commit alone, kept under a ref of its own. A server that won't serve a bare
    # commit: every branch head is fetched aside (never in a partial move: one may be a task that stays).
    if ! git -C "$proot" fetch --quiet --no-tags "$(mig_git_url "$root")" "$head" 2>/dev/null && ! mig_partial; then
      git -C "$proot" fetch --quiet --no-tags "$(mig_git_url "$root")" "+refs/heads/*:refs/chartroom/migrate-$id/*" >&2 || true
    fi
    git -C "$proot" cat-file -e "$head^{commit}" 2>/dev/null && git -C "$proot" update-ref "refs/chartroom/migrate/$id" "$head"
    ref="refs/chartroom/migrate/$id"
  fi
  [[ "$(git -C "$proot" rev-parse -q --verify "$ref" 2>/dev/null || true)" == "$head" ]] && printf '%s' "$ref"
  return 0
}
mig_checked_out() { git -C "$1" worktree list --porcelain 2>/dev/null | grep -qxF "branch refs/heads/$2"; } # <repo> <branch>

# A task's uncommitted changes, as staged.patch, unstaged.patch and untracked.tar in <dir>.
mig_capture_dirty() { # <facts json> <dir>
  local wt; wt="$(jq -r .worktree <<<"$1")"
  mkdir -p "$2"
  mig_client dirty "$wt" | tar -xf - -C "$2"
}

mig_settle() {
  mig_step_done triage || die "migrate-home: run triage first"
  [[ $MIG_DRY -eq 1 ]] || mig_step_done freeze || die "migrate-home: freeze the client home first (migrate-home freeze)"
  mig_decisions >"$MIG_S/decided.tsv"
  local id a f out="" ref d
  while IFS=$'\t' read -r id a; do
    f="$(jq -c --arg i "$id" 'select(.id == $i)' "$MIG_S/facts.jsonl")"
    [[ -n "$f" ]] || { warn "decision for $id: no such open task on the client"; continue; }
    case "$a" in
      close|accept)
        # Commits pushed nowhere (or unreadable) never stay behind: bundled here before the close.
        if [[ "$(jq -r 'if .unpushed == null and (.wst == "own" or .wst == "shared") then 1 else (.unpushed // 0) end' <<<"$f")" -gt 0 ]]; then
          d="$MIG_S/bundles/$id"; mkdir -p "$d"; ref=""
          if [[ $MIG_DRY -eq 0 ]]; then
            ref="$(mig_fetch_branch "$f")"
            if ! mig_bundle "$f" "$ref" "$d"; then mig_ledger "$id" bundle-failed "unpushed commits could not be fetched here: kept, not closed"; continue; fi
          fi
        fi
        out="$(mig_client settle "$MIG_CHOME" "$MIG_CBIN" "$a" "$id")"
        mig_ledger "$id" "settle-$a" "$out" ;;
      bundle)
        d="$MIG_S/bundles/$id"; mkdir -p "$d"
        ref=""
        [[ $MIG_DRY -eq 1 ]] || ref="$(mig_fetch_branch "$f")"
        if [[ $MIG_DRY -eq 0 && "$(jq -r '.dirty // 0' <<<"$f")" -gt 0 ]]; then mig_capture_dirty "$f" "$d"; fi
        if [[ $MIG_DRY -eq 0 ]] && ! mig_bundle "$f" "$ref" "$d"; then
          mig_ledger "$id" bundle-failed "no checkout or commits here: kept"; continue
        fi
        out="$(mig_client settle "$MIG_CHOME" "$MIG_CBIN" close "$id")"
        mig_ledger "$id" settle-bundle "$out" ;;
      keep|move) mig_ledger "$id" "decided-$a" ;;
    esac
    [[ "$out" == refused* && "$a" != keep && "$a" != move ]] && mig_ledger "$id" kept "close refused (uncommitted work); never --discard: it moves as kept"
    out=""
  done <"$MIG_S/decided.tsv"
  [[ $MIG_DRY -eq 1 ]] || mig_mark settle
}

# A git bundle of the commits the remotes lack, plus the branch name and head; with nothing
# unpushed, the branch's name and head alone (they are on the remote).
mig_bundle() { # <facts json> <ref> <dir>
  local f="$1" ref="$2" d="$3" proot
  proot="$(mig_map "$(jq -r .root <<<"$f")")"
  jq -n --argjson f "$f" --arg ref "$ref" '{branch: $f.branch, head: $f.head, ref: $ref, remote: $f.remote}' >"$d/branch.json"
  [[ -n "$ref" ]] || return 1
  if [[ -n "$(git -C "$proot" rev-list --max-count=1 "$ref" --not --remotes 2>/dev/null)" ]]; then
    git -C "$proot" bundle create --quiet "$d/branch.bundle" "$ref" --not --remotes >&2 || return 1
    # It must verify, and hold the client's head, before the task may be closed on the client.
    git -C "$proot" bundle verify --quiet "$d/branch.bundle" >/dev/null 2>&1 || { rm -f "$d/branch.bundle"; return 1; }
    git bundle list-heads "$d/branch.bundle" | awk -v h="$(jq -r .head <<<"$f")" '$1 == h { ok = 1 } END { exit !ok }' || { rm -f "$d/branch.bundle"; return 1; }
  fi
  return 0
}

# ---------------------------------------------------------------- move

mig_disk_check() { # <kb needed>
  local total avail
  if [[ -n "${CHARTROOM_MIGRATE_DF:-}" ]]; then read -r total avail <<<"$CHARTROOM_MIGRATE_DF"
  else read -r total avail < <(df -Pk "$MIG_BHOME" 2>/dev/null | awk 'NR == 2 { print $2, $4 }'); fi
  [[ -n "$total" && -n "$avail" ]] || return 0
  if (( (avail - $1) * 100 < total * 15 )); then
    [[ $MIG_DRY -eq 1 ]] && { echo "warning: the move needs about $(( $1 / 1048576 )) GB and would leave this disk under 15% free ($(( avail / 1048576 )) GB free of $(( total / 1048576 ))); move refuses until space is freed"; return 0; }
    die "migrate-home: the move needs about $(( $1 / 1048576 )) GB and would leave this disk under 15% free ($(( avail / 1048576 )) GB free of $(( total / 1048576 ))): free space first"
  fi
}

mig_move() {
  mig_step_done triage || die "migrate-home: run triage first"
  if mig_partial; then
    # The client stays in use, so whatever comes over must be at rest there.
    local live; live="$(jq -r '[.[] | select(.action == "move") | .id] | join(" ")' "$MIG_S/triage.json")"
    [[ -z "$live" ]] || die "migrate-home: live on the client, and not in --except: $live"
    if [[ $MIG_DRY -eq 0 ]] && ! mig_step_done brain-snapshot; then
      mig_snapshot_brain "$MIG_BHOME" "${CHARTROOM_MIGRATE_SNAPSHOT_DIR:-$HOME/chartroom-migrate}/$MIG_STAMP/brain"
      mig_mark brain-snapshot
    fi
  elif [[ $MIG_DRY -eq 0 ]]; then
    mig_step_done settle || die "migrate-home: run settle first (the commander's decisions)"
    mig_step_done freeze || die "migrate-home: the client home is not frozen (migrate-home freeze)"
  fi
  [[ -f "$MIG_S/decided.tsv" ]] || mig_decisions >"$MIG_S/decided.tsv"
  # The baseline: the client after freeze and settle, when nothing there writes any more. Kept as
  # baseline.jsonl once (verify, finish, rollback and reap read it; a later triage cannot change it).
  mig_facts
  if [[ $MIG_DRY -eq 0 ]]; then
    if [[ -f "$MIG_S/baseline.jsonl" ]]; then cp "$MIG_S/baseline.jsonl" "$MIG_S/facts.jsonl"; else cp "$MIG_S/facts.jsonl" "$MIG_S/baseline.jsonl"; fi
  fi
  local nmove kb
  nmove="$(awk -F'\t' '$2 == "move"' "$MIG_S/decided.tsv" | wc -l | tr -d ' ')"
  kb=$(( nmove * ${CHARTROOM_MIGRATE_WORKTREE_KB:-5242880} + $(jq -s '[.[].transcript_size // 0] | add // 0' "$MIG_S/facts.jsonl") / 1024 + 1048576 ))
  mig_disk_check "$kb"
  local st="$MIG_S/staged"
  rm -rf "$st"; mkdir -p "$st/client" "$st/merged"
  mig_client records "$MIG_CHOME" | tar -xf - -C "$st/client"
  mig_client skipped "$MIG_CHOME" >"$MIG_S/skipped.tsv" || true
  if mig_partial; then
    local x; for x in $MIG_EXCEPT; do rm -rf "${st:?}/client/tasks/$x"; done
  else
    mig_client xo "$MIG_CHOME" "$MIG_CCLAUDE" | tar -xf - -C "$st" 2>/dev/null || true
  fi
  if [[ ! -d "$MIG_BHOME/tasks" && $MIG_DRY -eq 0 ]]; then
    # A home only the client had: made here, registered, with its own workspace and port.
    CHARTROOM_HOME="$MIG_BHOME" "$CR_BIN" init --name "$MIG_HOME" >/dev/null || die "migrate-home: could not make the home $MIG_BHOME"
    printf '%s\n' "$MIG_BHOME" >"$MIG_S/created-home.txt"
  fi
  mkdir -p "$MIG_BHOME/tasks"
  # The brain's own tasks before the move: each log's length and checksum (verify's prefix check).
  local d id
  local cids; cids=" $(jq -r .id "$MIG_S/facts.jsonl" | tr '\n' ' ') "
  : >"$MIG_S/brain-before.tsv"
  shopt -s nullglob
  for d in "$MIG_BHOME"/tasks/*/; do
    id="${d%/}"; id="${id##*/}"
    [[ "$cids" == *" $id "* ]] && continue
    [[ -f "$d/events.log" ]] && printf '%s\t%s\t%s\n' "$id" "$(wc -c <"$d/events.log" | tr -d ' ')" "$(mig_sha <"$d/events.log")" >>"$MIG_S/brain-before.tsv"
  done
  mig_merge_plan
  if [[ $MIG_DRY -eq 1 ]]; then
    echo "dry run: nothing changed on the brain"
    cat "$MIG_S/merge-plan.txt"
    return 0
  fi
  mig_lock
  if ! mig_step_done merge; then mig_merge_apply; mig_mark merge; fi
  mig_move_tasks
  mig_move_conversations
  mig_move_git
  mig_record_sizes
  mig_unlock
  stamp_changed "$MIG_BHOME"
  mig_mark move
  echo "moved: $(awk -F'\t' '$3 == "moved"' "$MIG_S/ledger.tsv" | wc -l | tr -d ' ') tasks into $MIG_BHOME; next: chartroom migrate-home verify --from $MIG_FROM --home $MIG_HOME"
}

mig_lock() {
  local i
  for i in $(seq 1 20); do mkdir "$MIG_BHOME/.migrate.lock" 2>/dev/null && return 0; sleep 0.5; done
  die "migrate-home: $MIG_BHOME/.migrate.lock is held (another migrate-home run?)"
}
mig_unlock() { rmdir "$MIG_BHOME/.migrate.lock" 2>/dev/null || true; }

# Each task record into the brain: closed ones as they are, open ones with their handles cleared.
# MIG_ONLY (" id id "): resync's subset of tasks; MIG_PREV_BASE: the baseline the move took, whose
# heads and transcripts a resync may move forward (nothing on the brain changed them since).
mig_only() { [[ -z "${MIG_ONLY:-}" || "$MIG_ONLY" == *" $1 "* ]]; } # <id>
mig_prev() { [[ -n "${MIG_PREV_BASE:-}" ]] && jq -r --arg i "$1" --arg k "$2" 'select(.id == $i) | .[$k] // "" | tostring' "$MIG_PREV_BASE" 2>/dev/null; return 0; } # <id> <key>

mig_move_tasks() {
  local st="${MIG_TASKS_DIR:-$MIG_S/staged/client/tasks}" d id f dst dec sid be agent runner parked note log_bytes conv rollout
  [[ -d "$st" ]] || return 0
  for d in "$st"/*/; do
    id="${d%/}"; id="${id##*/}"
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    mig_only "$id" || continue
    dst="$MIG_BHOME/tasks/$id"
    if [[ -e "$dst" ]]; then
      if [[ "$(jq -r '.migrated_from // ""' "$dst/meta.json" 2>/dev/null)" == "$(mig_label)" ]]; then continue; fi
      mig_ledger "$id" conflict "a task with this id is already on the brain: left as it is"; continue
    fi
    f="$(jq -c --arg i "$id" 'select(.id == $i)' "$MIG_S/facts.jsonl")"
    [[ -n "$f" ]] || f='{}'
    log_bytes="$(jq -r '.log_bytes // 0' <<<"$f")"
    cp -R "$d" "$MIG_BHOME/tasks/.$id.migrating"
    dec="$(mig_decision_of "$id")"
    sid="$(jq -r '.session_id // ""' <<<"$f")"
    be="$(jq -r '.backend // ""' "$MIG_BHOME/tasks/.$id.migrating/meta.json")"
    be="$(canon_backend "$be" 2>/dev/null || printf '%s' "$be")"
    runner="${be%%:*}"; agent=""; [[ "$be" == *:* ]] && agent="${be#*:}"
    parked="" note=""
    if [[ "$(jq -r '.closed // false' <<<"$f")" == false && "$(jq -r '.closed // ""' "$MIG_BHOME/tasks/.$id.migrating/meta.json")" == "" ]]; then
      conv="$(jq -r '.transcript // ""' <<<"$f")"; rollout="$(jq -r '.rollout // ""' <<<"$f")"
      if [[ "$agent" == claude && -n "$sid" && -n "$conv" ]]; then
        be="hc:claude"; parked="$(now)"; note="session $sid resumes on steer or attach (hc:claude)"
      elif [[ "$agent" == codex && -n "$rollout" ]]; then note="Codex thread $(jq -r .thread_id <<<"$f") copied; resume it with codex"
      elif [[ -n "$runner" && "$runner" != command && "$runner" != subagent ]]; then note="no resumable session: steer starts nothing; dispatch it again with a handoff brief"
      fi
    fi
    jq --argjson h "$CR_MIG_HANDLES" --arg from "$(mig_label)" --arg at "$(now)" --arg ch "$MIG_CHOME" --arg lb "$log_bytes" \
      --arg wt "$(mig_map "$(jq -r '.worktree // ""' "$MIG_BHOME/tasks/.$id.migrating/meta.json")")" \
      --arg proj "$(mig_map "$(jq -r '.project // ""' "$MIG_BHOME/tasks/.$id.migrating/meta.json")")" \
      --arg be "$be" --arg sid "$sid" --arg parked "$parked" --arg dec "$dec" --arg orphan "$(jq -r --arg i "$id" '.[] | select(.id == $i) | .studio_wt // ""' "$MIG_S/triage.json")" '
      reduce $h[] as $k (.; del(.[$k]))
      | .worktree = (if $orphan != "" and (.worktree // "") == "" then $orphan elif $wt != "" then $wt else (.worktree // "") end)
      | .project = (if $proj != "" then $proj else (.project // "") end)
      | (if $be != "" and (.closed // "") == "" then .backend = $be else . end)
      | (if $sid != "" and (.closed // "") == "" then .session_id = $sid else . end)
      | (if $parked != "" and (.dispatched // "") != "" then .parked = $parked else . end)
      | .migrated_from = $from | .migrated_at = $at | .migrated_client_home = $ch | .migrated_log_bytes = $lb
      | .migrated_attempt = "1" | (if $dec != "" then .migrated_decision = $dec else . end)' \
      "$MIG_BHOME/tasks/.$id.migrating/meta.json" >"$MIG_BHOME/tasks/.$id.migrating/meta.json.tmp"
    mv "$MIG_BHOME/tasks/.$id.migrating/meta.json.tmp" "$MIG_BHOME/tasks/.$id.migrating/meta.json"
    # Adopted: a brain worktree for this task, on the branch it holds.
    local orphan; orphan="$(jq -r --arg i "$id" '.[] | select(.id == $i) | .studio_wt // ""' "$MIG_S/triage.json")"
    if [[ -n "$orphan" ]]; then
      local obr; obr="$(git -C "$orphan" symbolic-ref --short -q HEAD 2>/dev/null || true)"
      jq --arg b "$obr" 'if $b != "" then .branch = $b else . end' "$MIG_BHOME/tasks/.$id.migrating/meta.json" >"$MIG_BHOME/tasks/.$id.migrating/m.tmp" &&
        mv "$MIG_BHOME/tasks/.$id.migrating/m.tmp" "$MIG_BHOME/tasks/.$id.migrating/meta.json"
      note="${note:+$note; }adopted the brain's worktree $orphan${obr:+ (branch $obr)}"
    fi
    # The branch the worktree really has checked out wins over the record's (a worker may have moved on).
    local fbr mbr; fbr="$(jq -r '.branch // ""' <<<"$f")"; mbr="$(jq -r '.branch // ""' "$MIG_BHOME/tasks/.$id.migrating/meta.json")"
    if [[ -n "$fbr" && "$fbr" != "$mbr" && -z "$orphan" ]]; then
      jq --arg b "$fbr" --arg o "$mbr" '.branch = $b | .migrated_branch_was = $o' "$MIG_BHOME/tasks/.$id.migrating/meta.json" >"$MIG_BHOME/tasks/.$id.migrating/m.tmp" &&
        mv "$MIG_BHOME/tasks/.$id.migrating/m.tmp" "$MIG_BHOME/tasks/.$id.migrating/meta.json"
      note="${note:+$note; }its worktree is on branch $fbr (the record said ${mbr:-none})"
    fi
    [[ -d "$MIG_S/bundles/$id" ]] && { mkdir -p "$MIG_BHOME/tasks/.$id.migrating/migrate"; cp -R "$MIG_S/bundles/$id/." "$MIG_BHOME/tasks/.$id.migrating/migrate/"; }
    mv "$MIG_BHOME/tasks/.$id.migrating" "$dst"
    printf '%s note: migrated from %s (%s)%s\n' "$(now)" "$(mig_label)" "$MIG_CHOME" "${note:+; $note}" >>"$dst/events.log"
    printf '%s\t%s\n' "$id" "$(wc -c <"$dst/events.log" | tr -d ' ')" >>"$MIG_S/moved-sizes.tsv"
    # The brain's watch reads a moved log from where the client left it, never from its start.
    [[ -f "$MIG_BHOME/.watch-cursor" ]] && printf '%s\t%s\n' "$id" "$(wc -c <"$dst/events.log" | tr -d ' ')" >>"$MIG_BHOME/.watch-cursor"
    mig_ledger "$id" moved "${dec:-closed}"
  done
}

# Each moved task's log length once the move is done with it (a rebuilt worktree adds a note), so a
# later resync or rollback can tell a record the brain has since written to.
mig_record_sizes() {
  local id
  while IFS= read -r id; do
    [[ -f "$MIG_BHOME/tasks/$id/events.log" ]] && printf '%s\t%s\n' "$id" "$(wc -c <"$MIG_BHOME/tasks/$id/events.log" | tr -d ' ')" >>"$MIG_S/moved-sizes.tsv"
  done < <(awk -F'\t' '$3 == "moved" { print $2 }' "$MIG_S/ledger.tsv" 2>/dev/null | sort -u)
}

# Claude transcripts (with their dirs and file history) and Codex rollouts of the open tasks.
mig_move_conversations() {
  local args=() rolls=() ids=() sid wt t tmp p enc_c enc_b f
  local only="${MIG_ONLY:-}" id
  while IFS=$'\t' read -r sid wt id; do args+=("$sid" "$wt"); ids+=("$id"); done < <(jq -r --arg o "$only" 'select((.closed | not) and .transcript != "" and (.id as $i | $o == "" or ($o | contains(" " + $i + " ")))) | [.session_id, .worktree, .id] | @tsv' "$MIG_S/facts.jsonl")
  while IFS= read -r p; do rolls+=("$p"); done < <(jq -r --arg o "$only" 'select((.closed | not) and .rollout != "" and (.id as $i | $o == "" or ($o | contains(" " + $i + " ")))) | .rollout' "$MIG_S/facts.jsonl")
  if (( ${#args[@]} > 0 )); then
    tmp="$(mktemp -d)"
    mig_client claude "$MIG_CCLAUDE" "${args[@]}" | tar -xf - -C "$tmp"
    local i
    for ((i = 0; i < ${#args[@]}; i += 2)); do
      sid="${args[$i]}"; wt="${args[$((i + 1))]}"
      enc_c="$(mig_enc "$wt")"; enc_b="$(mig_enc "$(mig_map "$wt")")"
      for t in "$enc_c/$sid.jsonl" "$enc_c/$sid"; do
        [[ -e "$tmp/projects/$t" ]] || continue
        f="$MIG_BCLAUDE/projects/$enc_b/${t#*/}"
        if [[ -e "$f" ]]; then
          # A resync moves a transcript forward only when the brain's copy is still the one the move made.
          local pid="${ids[$((i / 2))]}" psz psh
          psz="$(mig_prev "$pid" transcript_size)"; psh="$(mig_prev "$pid" transcript_sha)"
          # Moved forward when the brain's copy is the client's with less written yet: nothing here added to it.
          local bsz=""; [[ -f "$f" ]] && bsz="$(wc -c <"$f" | tr -d ' ')"
          if [[ "$t" == *.jsonl && -n "$psz" ]] && { [[ "$bsz" == "$psz" && "$(mig_sha <"$f")" == "$psh" ]] || head -c "$bsz" "$tmp/projects/$t" | cmp -s - "$f"; }; then cp "$tmp/projects/$t" "$f"; continue; fi
          if [[ "$t" != *.jsonl && -n "$psz" ]]; then cp -R "$tmp/projects/$t/." "$f/"; continue; fi
          mig_ledger "$sid" transcript-exists "$f: left as it is"; continue
        fi
        mkdir -p "$(dirname "$f")"; cp -R "$tmp/projects/$t" "$f"
      done
      if [[ -d "$tmp/file-history/$sid" && ! -e "$MIG_BCLAUDE/file-history/$sid" ]]; then
        mkdir -p "$MIG_BCLAUDE/file-history"; cp -R "$tmp/file-history/$sid" "$MIG_BCLAUDE/file-history/$sid"
      fi
    done
    rm -rf "$tmp"
  fi
  if (( ${#rolls[@]} > 0 )); then
    tmp="$(mktemp -d)"
    mig_client codex "$MIG_CCODEX" "${rolls[@]}" | tar -xf - -C "$tmp"
    while IFS= read -r f; do
      t="$MIG_BCODEX/${f#"$tmp"/}"
      [[ -e "$t" ]] && continue
      mkdir -p "$(dirname "$t")"; cp "$f" "$t"
    done < <(find "$tmp" -type f)
    rm -rf "$tmp"
  fi
}

# Every open task's branch, one git fetch per repo, into refs/chartroom/incoming/<id> (a fetch from
# a big checkout costs a minute or more, so one per task would take an hour on a big home).
mig_prefetch() {
  local root proot specs
  while IFS= read -r root; do
    proot="$(mig_map "$root")"
    git -C "$proot" rev-parse --git-dir >/dev/null 2>&1 || continue
    specs=()
    while IFS=$'\t' read -r id br; do specs+=("+refs/heads/$br:refs/chartroom/incoming/$id"); done < <(
      jq -r --arg r "$root" --arg o "${MIG_ONLY:-}" 'select((.closed | not) and .root == $r and .branch != "" and (.id as $i | $o == "" or ($o | contains(" " + $i + " ")))) | [.id, .branch] | @tsv' "$MIG_S/facts.jsonl")
    (( ${#specs[@]} > 0 )) || continue
    echo "fetching ${#specs[@]} branch(es) from $root" >&2
    git -C "$proot" fetch --quiet --no-tags "$(mig_git_url "$root")" "${specs[@]}" >&2 || warn "the batched fetch from $root failed; each branch is fetched on its own"
  done < <(jq -r 'select((.closed | not) and .root != "" and .branch != "") | .root' "$MIG_S/facts.jsonl" | sort -u)
}

# Branches and uncommitted changes of the open tasks that move; a worktree for each `move` task.
mig_move_git() {
  local f id dec ref dir
  mig_prefetch
  # Every task still open on the client after settle, whatever its decision said: a close the client
  # refused (uncommitted work) or a bundle that failed leaves it open, and its work comes too.
  while IFS= read -r f; do
    id="$(jq -r .id <<<"$f")"; dec="$(mig_decision_of "$id")"
    [[ -d "$MIG_BHOME/tasks/$id" ]] || continue
    ref="$(mig_fetch_branch "$f")"
    dir="$MIG_BHOME/tasks/$id/migrate"; mkdir -p "$dir"
    jq -n --argjson f "$f" --arg ref "$ref" '{branch: $f.branch, head: $f.head, ref: $ref, root: $f.root, porcelain_sha: $f.porcelain_sha, diff_sha: $f.diff_sha}' >"$dir/branch.json"
    if [[ "$(jq -r '.dirty // 0' <<<"$f")" -gt 0 ]]; then mig_capture_dirty "$f" "$dir"; fi
    mig_client ignored "$(jq -r .worktree <<<"$f")" >"$dir/ignored.tar" 2>/dev/null || true
    if [[ -z "$(tar -tf "$dir/ignored.tar" 2>/dev/null)" ]]; then rm -f "$dir/ignored.tar"; else tar -tf "$dir/ignored.tar" >"$dir/ignored.txt"; fi
    if [[ "$dec" == move ]]; then
      ( CR_HOME="$MIG_BHOME"; migrate_materialize "$id" ) || mig_ledger "$id" materialize-failed "see the task's events"
    fi
  done < <(jq -c --arg o "${MIG_ONLY:-}" 'select((.closed | not) and .head != "" and (.id as $i | $o == "" or ($o | contains(" " + $i + " "))))' "$MIG_S/facts.jsonl")
  # The batched fetch's refs have served: each task's branch now has its own ref.
  local root proot r
  while IFS= read -r root; do
    proot="$(mig_map "$root")"
    while IFS= read -r r; do git -C "$proot" update-ref -d "$r"; done < <(git -C "$proot" for-each-ref --format='%(refname)' refs/chartroom/incoming/ 2>/dev/null)
  done < <(jq -r 'select(.root != "") | .root' "$MIG_S/facts.jsonl" | sort -u)
}

# ---------------------------------------------------------------- the merge of the home's files

# Writes $MIG_S/merged/<path> for each brain file the merge changes, and merge-plan.txt.
mig_merge_plan() {
  local c="$MIG_S/staged/client" b="$MIG_BHOME" m="$MIG_S/staged/merged" plan="$MIG_S/merge-plan.txt" f rel
  : >"$plan"
  mig_merge_rulings "$c/rulings.log" "$b/rulings.log" "$m/rulings.log" >>"$plan"
  if mig_partial; then mig_merge_inbox "$c" "$b" "$m" >>"$plan"; mig_merge_sums; return 0; fi
  mig_merge_prefs "$c" "$b" "$m" >>"$plan"
  mig_merge_inbox "$c" "$b" "$m" >>"$plan"
  mig_merge_lines "$c/projects.md" "$b/projects.md" "$m/projects.md" projects.md >>"$plan"
  mig_merge_config "$c/config" "$b/config" "$m/config" >>"$plan"
  mig_merge_relays "$c/relays" "$b/relays" "$m/relays" >>"$plan"
  if [[ -f "$c/focus.json" && ! -f "$b/focus.json" ]]; then cp "$c/focus.json" "$m/focus.json"; echo "focus.json: the client's" >>"$plan"; fi
  # Every other file: copied when the brain lacks it; other bytes: beside it, as <name>.from-<from>.
  while IFS= read -r -d '' f; do
    rel="${f#"$c"/}"
    case "$rel" in tasks/*|inbox/*|relays/*|rulings.log|commander.md|captain.md|inbox.md|projects.md|config|focus.json|AGENTS.md|CLAUDE.md) continue ;; esac
    if [[ ! -e "$b/$rel" ]]; then mkdir -p "$m/$(dirname "$rel")"; cp "$f" "$m/$rel"; echo "add $rel" >>"$plan"
    elif ! cmp -s "$f" "$b/$rel"; then
      local alt; alt="$(mig_alt_name "$rel")"
      [[ -e "$b/$alt" ]] && continue
      mkdir -p "$m/$(dirname "$alt")"; cp "$f" "$m/$alt"; echo "conflict $rel: the client's kept as $alt" >>"$plan"
    fi
  done < <(find "$c" -type f -print0)
  mig_merge_xo >>"$plan"
  mig_merge_sums
}
# What the brain's files were when this merge was staged: the apply refuses if one changed since.
mig_merge_sums() {
  ( cd "$b" && for f in rulings.log commander.md captain.md inbox.md projects.md config focus.json relays/inbox.ndjson relays/outbox.ndjson; do
      if [[ -f "$f" ]]; then printf '%s\t%s\n' "$f" "$(mig_sha <"$f")"; fi; done ) >"$MIG_S/brain-sums.tsv"
  printf 'tasks: %s from the client (%s open)\n' "$(jq -s length "$MIG_S/facts.jsonl")" "$(jq -s '[.[] | select(.closed | not)] | length' "$MIG_S/facts.jsonl")" >>"$MIG_S/merge-plan.txt"
}
mig_alt_name() { # <rel path> -> <dir/base>.from-<label><.ext>
  local rel="$1" dir base ext=""
  dir="$(dirname "$rel")"; base="$(basename "$rel")"
  [[ "$base" == *.* && "$base" != .* ]] && { ext=".${base##*.}"; base="${base%.*}"; }
  [[ "$dir" == . ]] && dir="" || dir="$dir/"
  printf '%s%s.from-%s%s' "$dir" "$base" "$(mig_label)" "$ext"
}

# rulings.log: union, one copy of each line, stable-sorted by timestamp (client first on a tie). A
# ruling id on both sides with other text: the brain's gets a fresh id, and its supersedes= follow.
mig_merge_rulings() { # <client> <brain> <out>
  [[ -f "$1" ]] || return 0
  if [[ ! -f "$2" ]]; then mkdir -p "$(dirname "$3")"; cp "$1" "$3"; echo "rulings.log: the client's ($(grep -c . "$1") rulings)"; return 0; fi
  mkdir -p "$(dirname "$3")"
  awk '
    function rid(l,   m) { if (match(l, /\[r-[0-9a-f]+\]/)) return substr(l, RSTART + 1, RLENGTH - 2); return "" }
    FNR == 1 { src++ }
    $0 == "" { next }
    src == 1 { id = rid($0); c[id] = $0; seen[$0] = 1; ids[id] = 1; n++; line[n] = "1\t" FNR "\t" $0; next }
    src == 2 {
      if ($0 in seen) next
      id = rid($0); ids[id] = 1
      if ((id in c) && c[id] != $0) { remap[id] = 1 }
      b[++nb] = $0
    }
    END {
      for (i = 1; i <= nb; i++) {
        l = b[i]
        for (old in remap) {
          if (!(old in fresh)) { do { x = sprintf("r-%04x", int(rand() * 65536)) } while ((x in ids) || (x in used)); fresh[old] = x; used[x] = 1 }
          gsub("\\[" old "\\]", "[" fresh[old] "]", l); gsub("supersedes=" old " ", "supersedes=" fresh[old] " ", l)
        }
        n++; line[n] = "2\t" i "\t" l
      }
      for (i = 1; i <= n; i++) print line[i]
      for (old in fresh) printf "remap\t%s\t%s\n", old, fresh[old] > "/dev/stderr"
    }' "$1" "$2" 2>"$3.remap" |
    awk -F'\t' '{ ts = substr($3, 1, index($3, " ") - 1); printf "%s\t%s\t%08d\t%s\n", ts, $1, $2, $3 }' |
    LC_ALL=C sort -s -t$'\t' -k1,1 -k2,2 -k3,3 | cut -f4- >"$3"
  if cmp -s "$3" "$2"; then rm -f "$3" "$3.remap"; echo "rulings.log: unchanged"; return 0; fi
  printf 'rulings.log: %s lines (client %s, brain %s)%s\n' "$(grep -c . "$3")" "$(grep -c . "$1")" "$(grep -c . "$2")" \
    "$([[ -s "$3.remap" ]] && printf '; renamed on the brain side: %s' "$(awk -F'\t' '{printf "%s->%s ", $2, $3}' "$3.remap")")"
  [[ -s "$3.remap" ]] || rm -f "$3.remap"
}

# commander.md: the client's (or its captain.md) is the base; the brain's lines outside the rulings
# block that the client lacks are appended under a heading. The block is rendered after the apply.
mig_merge_prefs() { # <client dir> <brain dir> <out dir>
  local c b out="$3/commander.md" extra
  if [[ -f "$1/commander.md" ]]; then c="$1/commander.md"; elif [[ -f "$1/captain.md" ]]; then c="$1/captain.md"; else return 0; fi
  if [[ -f "$2/commander.md" ]]; then b="$2/commander.md"; elif [[ -f "$2/captain.md" ]]; then b="$2/captain.md"; else b=""; fi
  mkdir -p "$3"
  if [[ -z "$b" ]]; then cp "$c" "$out"; echo "commander.md: the client's"; return 0; fi
  extra="$(awk '
    FNR == 1 { src++ }
    /^<!-- chartroom:rulings/ { skip = 1 } /^<!-- \/chartroom:rulings/ { skip = 0; next }
    skip { next }
    src == 1 { have[$0] = 1; next }
    $0 ~ /^[[:space:]]*$/ || $0 ~ /^## From the brain/ || ($0 in have) { next }
    { print }' "$c" "$b")"
  { cat "$c"
    if [[ -n "$extra" ]]; then
      printf '\n## From the brain (%s): lines the client home did not have, for review\n\n%s\n' "$(now)" "$extra"
    fi
  } >"$out"
  if cmp -s "$out" "$b"; then rm -f "$out"; echo "commander.md: unchanged"; return 0; fi
  echo "commander.md: the client's, plus $(grep -c . <<<"$extra") line(s) of the brain's for review"
}

# inbox.md: per "## " section, the client's lines, then the brain's whose [i-xxxx] the client
# lacks; an id on both with other text re-ids the brain's (and its inbox/<id>/). inbox/<id>/: union.
mig_merge_inbox() { # <client dir> <brain dir> <out dir>
  local c="$1" b="$2" m="$3" d id
  if [[ -f "$c/inbox.md" ]]; then
    if [[ ! -f "$b/inbox.md" ]]; then cp "$c/inbox.md" "$m/inbox.md"; echo "inbox.md: the client's"
    else
      awk -v remapf="$m/inbox.remap" '
        function iid(l) { if (match(l, /^- \[i-[0-9a-f]+\]/)) return substr(l, 4, RLENGTH - 4); return "" }
        FNR == 1 { src++; sec = "" }
        /^## / { sec = $0; if (!(sec in known)) { known[sec] = 1; order[++ns] = sec } next }
        sec == "" { if (src == 2) pre[++np] = $0; next }
        /^- \(none\)[[:space:]]*$/ || /^[[:space:]]*$/ { next }
        { id = iid($0)
          if (src == 1) { body[sec] = body[sec] $0 "\n"; if (id != "") { cid[id] = $0 } else { ctext[$0] = 1 } ; next }
          if (id != "" && (id in cid)) {
            if (cid[id] == $0) next
            do { x = sprintf("i-%04x", int(rand() * 65536)) } while ((x in cid) || (x in bid))
            print id "\t" x > remapf; sub("\\[" id "\\]", "[" x "]")
          }
          if (id == "" && ($0 in ctext)) next
          if (id != "") bid[id] = 1
          body[sec] = body[sec] $0 "\n" }
        END {
          for (i = 1; i <= np; i++) print pre[i]
          for (i = 1; i <= ns; i++) { s = order[i]; print s; if (body[s] == "") print "- (none)"; else printf "%s", body[s]; print "" }
        }' "$c/inbox.md" "$b/inbox.md" >"$m/inbox.md"
      if cmp -s "$m/inbox.md" "$b/inbox.md"; then rm -f "$m/inbox.md"; echo "inbox.md: unchanged"
      else echo "inbox.md: $(grep -cE '^- \[i-' "$m/inbox.md") items (client $(grep -cE '^- \[i-' "$c/inbox.md"), brain $(grep -cE '^- \[i-' "$b/inbox.md"))$([[ -s "$m/inbox.remap" ]] && printf '; re-id on the brain side: %s' "$(tr '\t\n' '> ' <"$m/inbox.remap")")"; fi
    fi
  fi
  shopt -s nullglob
  for d in "$c"/inbox/*/; do
    id="${d%/}"; id="${id##*/}"
    if [[ ! -e "$b/inbox/$id" ]]; then mkdir -p "$m/inbox"; cp -R "$d" "$m/inbox/$id"; echo "add inbox/$id/"
    else
      local f rel
      while IFS= read -r -d '' f; do
        rel="${f#"$c"/}"
        if [[ ! -e "$b/$rel" ]]; then mkdir -p "$m/$(dirname "$rel")"; cp "$f" "$m/$rel"; echo "add $rel"
        elif ! cmp -s "$f" "$b/$rel"; then local alt; alt="$(mig_alt_name "$rel")"; mkdir -p "$m/$(dirname "$alt")"; cp "$f" "$m/$alt"; echo "conflict $rel: the client's kept as $alt"; fi
      done < <(find "$d" -type f -print0)
    fi
  done
}

mig_merge_lines() { # <client> <brain> <out> <name>: union of lines, the client's first
  [[ -f "$1" ]] || return 0
  if [[ ! -f "$2" ]]; then cp "$1" "$3"; echo "$4: the client's"; return 0; fi
  awk 'FNR == 1 { src++ } src == 1 { print; have[$0] = 1; next } !($0 in have) || $0 ~ /^[[:space:]]*$/ { if ($0 !~ /^[[:space:]]*$/) print }' "$1" "$2" >"$3"
  if cmp -s "$3" "$2"; then rm -f "$3"; echo "$4: unchanged"; else echo "$4: union ($(grep -c . "$3") lines)"; fi
}

mig_merge_config() { # <client> <brain> <out>: the brain's keys win; the client's others are added
  [[ -f "$1" ]] || return 0
  if [[ ! -f "$2" ]]; then cp "$1" "$3"; echo "config: the client's"; return 0; fi
  local add
  add="$(awk -F= 'FNR == 1 { src++ } /^[[:space:]]*(#|$)/ { next } src == 1 { k = $1; gsub(/[[:space:]]/, "", k); if (!(k in seen)) { seen[k] = 1; v[k] = $0; ord[++n] = k } next }
    { k = $1; gsub(/[[:space:]]/, "", k); have[k] = 1 } END { for (i = 1; i <= n; i++) if (!(ord[i] in have)) print v[ord[i]] }' "$1" "$2")"
  [[ -n "$add" ]] || { echo "config: unchanged (the brain's keys win)"; return 0; }
  { cat "$2"; printf '# added by migrate-home from %s (%s)\n%s\n' "$(mig_label)" "$(now)" "$add"; } >"$3"
  echo "config: the brain's, plus $(grep -c . <<<"$add") key(s) of the client's"
}

mig_merge_relays() { # <client dir> <brain dir> <out dir>: union by (kind, id)
  local f
  for f in inbox.ndjson outbox.ndjson; do
    [[ -f "$1/$f" ]] || continue
    mkdir -p "$3"
    if [[ ! -f "$2/$f" ]]; then cp "$1/$f" "$3/$f"; echo "relays/$f: the client's"; continue; fi
    jq -c -n --slurpfile c "$1/$f" --slurpfile b "$2/$f" '
      ($b | map((.kind // "") + " " + (.id // ""))) as $have
      | $b[], ($c[] | select(((.kind // "") + " " + (.id // "")) as $k | $have | index($k) | not))' >"$3/$f"
    if cmp -s "$3/$f" "$2/$f"; then rm -f "$3/$f"; echo "relays/$f: unchanged"; else echo "relays/$f: union"; fi
  done
}

# The XO's own Claude project dir: sessions unioned, memory files unioned, MEMORY.md lines unioned.
mig_merge_xo() {
  local src dst m="$MIG_S/staged/merged-xo" f rel
  src="$MIG_S/staged/projects/$(mig_enc "$MIG_CHOME")"; dst="$MIG_BCLAUDE/projects/$(mig_enc "$MIG_BHOME")"
  [[ -d "$src" ]] || return 0
  rm -rf "$m"; mkdir -p "$m"
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    if [[ ! -e "$dst/$rel" ]]; then mkdir -p "$m/$(dirname "$rel")"; cp "$f" "$m/$rel"
    elif [[ "$rel" == memory/MEMORY.md ]]; then
      mkdir -p "$m/memory"; awk 'FNR == 1 { src++ } src == 1 { print; have[$0] = 1; next } !($0 in have) { print }' "$f" "$dst/$rel" >"$m/$rel"
      cmp -s "$m/$rel" "$dst/$rel" && rm -f "$m/$rel"
    elif [[ "$rel" == memory/* ]] && ! cmp -s "$f" "$dst/$rel"; then
      local alt; alt="$(mig_alt_name "$rel")"; mkdir -p "$m/$(dirname "$alt")"; cp "$f" "$m/$alt"
    fi
  done < <(find "$src" -type f -print0)
  echo "the XO's Claude project dir: $(find "$m" -type f | wc -l | tr -d ' ') file(s) to add"
}

# Installs the staged merge: each brain file it replaces is backed up once, under the state dir.
mig_merge_apply() {
  local m="$MIG_S/staged/merged" bk="$MIG_S/backup" f rel sum
  while IFS=$'\t' read -r rel sum; do
    [[ "$(mig_sha <"$MIG_BHOME/$rel" 2>/dev/null)" == "$sum" ]] || { mig_unlock; die "migrate-home: $MIG_BHOME/$rel changed while the merge was staged: nothing was applied; run move again"; }
  done <"$MIG_S/brain-sums.tsv"
  mkdir -p "$bk"
  if [[ -d "$m" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$m"/}"
      case "$rel" in *.remap) continue ;; esac
      if [[ -e "$MIG_BHOME/$rel" && ! -e "$bk/$rel" ]]; then mkdir -p "$bk/$(dirname "$rel")"; cp -p "$MIG_BHOME/$rel" "$bk/$rel"; fi
      [[ -e "$MIG_BHOME/$rel" ]] || printf '%s\n' "$rel" >>"$MIG_S/added-files.txt"
      mkdir -p "$MIG_BHOME/$(dirname "$rel")"; cp "$f" "$MIG_BHOME/$rel.migrate-tmp" && mv "$MIG_BHOME/$rel.migrate-tmp" "$MIG_BHOME/$rel"
    done < <(find "$m" -type f -print0)
    # The re-id of a brain inbox item moves its artifacts with it.
    if [[ -s "$m/inbox.remap" ]]; then
      local old new
      while IFS=$'\t' read -r old new; do
        [[ -d "$MIG_BHOME/inbox/$old" && ! -e "$MIG_BHOME/inbox/$new" ]] && mv "$MIG_BHOME/inbox/$old" "$MIG_BHOME/inbox/$new"
        printf 'inbox/%s\t%s\n' "$old" "$new" >>"$MIG_S/remaps.tsv"
      done <"$m/inbox.remap"
    fi
    [[ -s "$m/rulings.log.remap" ]] && cat "$m/rulings.log.remap" >>"$MIG_S/remaps.tsv"
  fi
  # The rulings block in commander.md, from the merged log.
  if [[ -f "$MIG_BHOME/rulings.log" ]]; then ( CR_HOME="$MIG_BHOME"; rules_render ) >/dev/null 2>&1 || warn "rule render failed in $MIG_BHOME"; fi
  # The relay mailbox merged: the watch cursor moves past it, so it rings nothing.
  if ! mig_partial && [[ -f "$MIG_BHOME/.watch-cursor" && -f "$MIG_BHOME/relays/inbox.ndjson" ]]; then
    local sz; sz="$(wc -c <"$MIG_BHOME/relays/inbox.ndjson" | tr -d ' ')"
    awk -F'\t' -v s="$sz" 'BEGIN { OFS = "\t" } $1 == "@relays" { $2 = s; done = 1 } { print } END { if (!done) print "@relays", s }' \
      "$MIG_BHOME/.watch-cursor" >"$MIG_BHOME/.watch-cursor.tmp" && mv "$MIG_BHOME/.watch-cursor.tmp" "$MIG_BHOME/.watch-cursor"
  fi
  # The XO's Claude project dir.
  local xs="$MIG_S/staged/merged-xo" xd
  xd="$MIG_BCLAUDE/projects/$(mig_enc "$MIG_BHOME")"
  if [[ -d "$xs" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$xs"/}"
      if [[ -e "$xd/$rel" && ! -e "$bk/xo/$rel" ]]; then mkdir -p "$bk/xo/$(dirname "$rel")"; cp -p "$xd/$rel" "$bk/xo/$rel"; fi
      [[ -e "$xd/$rel" ]] || printf '%s\n' "$xd/$rel" >>"$MIG_S/added-xo.txt"
      mkdir -p "$(dirname "$xd/$rel")"; cp "$f" "$xd/$rel"
    done < <(find "$xs" -type f -print0)
  fi
}

# ---------------------------------------------------------------- resync

# After a move, what changed in the client home before its finish (a worker that ran on, a new
# task, an XO's edits): the changed and new task records, their conversations and branches, and the
# home's own files, merged again. A brain copy that changed on the brain since the move is never
# replaced (listed instead). The fresh facts become the baseline that verify checks.
mig_resync() {
  mig_step_done move || die "migrate-home resync: nothing moved yet"
  mig_step_done finish && die "migrate-home resync: the home was finished already"
  local live
  live="$(mig_client status "$MIG_CHOME" "$MIG_CBIN" | jq -r '.[] | select(.closed == null and (.live | IN("working", "idle", "done", "blocked"))) | .id')"
  [[ -z "$live" || $MIG_DRY -eq 1 ]] || die "migrate-home resync: still live on the client (park them first): $(tr '\n' ' ' <<<"$live")"
  local r old="$MIG_S/staged/client" new f rel id tids="" sz
  r="$MIG_S/resync/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$r"; new="$r/client"; mkdir -p "$new"
  cp "$MIG_S/baseline.jsonl" "$r/baseline-before.jsonl"
  mig_facts
  mig_client records "$MIG_CHOME" | tar -xf - -C "$new"
  mig_client xo "$MIG_CHOME" "$MIG_CCLAUDE" | tar -xf - -C "$r" 2>/dev/null || true
  # What changed: every file new or different, and every task whose log moved on.
  : >"$r/changed.txt"
  while IFS= read -r -d '' f; do rel="${f#"$new"/}"; cmp -s "$f" "$old/$rel" 2>/dev/null || printf '%s\n' "$rel" >>"$r/changed.txt"; done < <(find "$new" -type f -print0)
  while IFS= read -r rel; do
    case "$rel" in tasks/*/*) id="${rel#tasks/}"; id="${id%%/*}"; [[ "$tids" == *" $id "* ]] || tids+=" $id " ;; esac
  done <"$r/changed.txt"
  # --task <id>: copied again whatever the diff says (one a resync kept, say).
  for id in $MIG_TASKS; do [[ "$tids" == *" $id "* ]] || tids+=" $id "; done
  echo "changed on the client since the move: $(grep -c . "$r/changed.txt") file(s), $(wc -w <<<"$tids" | tr -d ' ') task(s):$tids"
  if [[ $MIG_DRY -eq 1 ]]; then sed 's/^/  /' "$r/changed.txt"; return 0; fi
  mig_lock
  # The tasks: a brain copy still as the move left it is replaced; one the brain changed is kept.
  local keep=""
  for id in $tids; do
    [[ -d "$MIG_BHOME/tasks/$id" ]] || continue
    sz="$(awk -F'\t' -v i="$id" '$1 == i { s = $2 } END { print s }' "$MIG_S/moved-sizes.tsv" 2>/dev/null)"
    # Lines the brain added that are all chartroom's own notes (the watch's "waiting overdue", say)
    # are no change of substance: they are about the client's state, which the copy brings anyway.
    local grown=""
    [[ -n "$sz" ]] && grown="$(tail -c +"$((sz + 1))" "$MIG_BHOME/tasks/$id/events.log" | grep -vE '^[0-9T:Z-]+ note: ' || true)"
    if [[ "$(jq -r '.migrated_from // ""' "$MIG_BHOME/tasks/$id/meta.json")" != "$(mig_label)" || -z "$sz" ||
          ( "$(wc -c <"$MIG_BHOME/tasks/$id/events.log" | tr -d ' ')" -lt "$sz" ) || -n "$grown" ]]; then
      mig_ledger "$id" resync-conflict "changed on the brain since the move: left as it is"; keep+=" $id "; continue
    fi
    # A worktree the move rebuilt goes too, to be rebuilt from the client's new state, but only while
    # it is exactly as the move made it (its head, status and diff); one used here since is kept.
    if [[ -f "$MIG_BHOME/tasks/$id/migrate/materialized" ]]; then
      local mw mp ph pp pd
      mw="$(cat "$MIG_BHOME/tasks/$id/migrate/materialized")"; mp="$(jq -r '.project // ""' "$MIG_BHOME/tasks/$id/meta.json")"
      ph="$(jq -r --arg i "$id" 'select(.id == $i) | .head' "$r/baseline-before.jsonl")"
      pp="$(jq -r --arg i "$id" 'select(.id == $i) | .porcelain_sha' "$r/baseline-before.jsonl")"
      pd="$(jq -r --arg i "$id" 'select(.id == $i) | .diff_sha' "$r/baseline-before.jsonl")"
      if [[ -d "$mw" ]]; then
        if [[ "$(git -C "$mw" rev-parse HEAD 2>/dev/null)" == "$ph" && "$(git --no-optional-locks -C "$mw" status --porcelain | LC_ALL=C sort | { s="$(cat)"; printf '%s' "$s"; } | mig_sha)" == "$pp" && "$(git --no-optional-locks -C "$mw" diff --binary HEAD | mig_sha)" == "$pd" ]]; then
          git -C "$mp" worktree remove --force "$mw" >&2
        else
          mig_ledger "$id" resync-conflict "its rebuilt worktree $mw changed on the brain since the move: left as it is"; keep+=" $id "; continue
        fi
      fi
    fi
    mkdir -p "$r/replaced"; mv "$MIG_BHOME/tasks/$id" "$r/replaced/$id"
    [[ -f "$MIG_BHOME/.watch-cursor" ]] && { grep -v "^$id"$'\t' "$MIG_BHOME/.watch-cursor" >"$MIG_BHOME/.watch-cursor.tmp" || true; mv "$MIG_BHOME/.watch-cursor.tmp" "$MIG_BHOME/.watch-cursor"; }
  done
  local only=""; for id in $tids; do [[ "$keep" == *" $id "* ]] || only+=" $id "; done
  MIG_ONLY="$only " MIG_PREV_BASE="$r/baseline-before.jsonl" MIG_TASKS_DIR="$new/tasks" mig_move_tasks
  MIG_ONLY="$only " MIG_PREV_BASE="$r/baseline-before.jsonl" mig_move_conversations
  MIG_ONLY="$only " MIG_PREV_BASE="$r/baseline-before.jsonl" mig_move_git
  mig_record_sizes
  # The home's own files: merged again from the client's new copy (the unions are idempotent).
  local m="$r/merged"; mkdir -p "$m"
  while IFS= read -r rel; do
    case "$rel" in
      tasks/*) ;;
      rulings.log) mig_merge_rulings "$new/rulings.log" "$MIG_BHOME/rulings.log" "$m/rulings.log" ;;
      inbox.md|inbox/*) [[ -f "$m/.inbox-done" ]] || { mig_merge_inbox "$new" "$MIG_BHOME" "$m"; : >"$m/.inbox-done"; } ;;
      relays/*) [[ -f "$m/.relays-done" ]] || { mig_merge_relays "$new/relays" "$MIG_BHOME/relays" "$m/relays"; : >"$m/.relays-done"; } ;;
      projects.md) mig_merge_lines "$new/projects.md" "$MIG_BHOME/projects.md" "$m/projects.md" projects.md ;;
      config) mig_merge_config "$new/config" "$MIG_BHOME/config" "$m/config" ;;
      commander.md|captain.md)
        # The client's new lines (not in its copy at the move, nor here), appended for review.
        local add
        add="$(awk 'FNR == 1 { src++ } src < 3 { have[$0] = 1; next } !($0 in have) && $0 !~ /^[[:space:]]*$/' \
          "$old/$rel" "$MIG_BHOME/commander.md" "$new/$rel" 2>/dev/null | grep -v '^<!-- ' | grep -v '^- .*; r-[0-9a-f]*, ' || true)"
        [[ -n "$add" ]] && { cp "$MIG_BHOME/commander.md" "$m/commander.md"; printf '\n## From the client after the move (%s): lines for review\n\n%s\n' "$(now)" "$add" >>"$m/commander.md"; } ;;
      *) if [[ ! -e "$MIG_BHOME/$rel" ]] || cmp -s "$MIG_BHOME/$rel" "$old/$rel"; then mkdir -p "$m/$(dirname "$rel")"; cp "$new/$rel" "$m/$rel"
         else local alt; alt="$(mig_alt_name "$rel")"; mkdir -p "$m/$(dirname "$alt")"; cp "$new/$rel" "$m/$alt"; fi ;;
    esac
  done <"$r/changed.txt" >"$r/merge-plan.txt"
  rm -f "$m/.inbox-done" "$m/.relays-done"
  local bk="$r/backup"
  while IFS= read -r -d '' f; do
    rel="${f#"$m"/}"; case "$rel" in *.remap) continue ;; esac
    if [[ -e "$MIG_BHOME/$rel" ]]; then mkdir -p "$bk/$(dirname "$rel")"; cp -p "$MIG_BHOME/$rel" "$bk/$rel"; fi
    mkdir -p "$MIG_BHOME/$(dirname "$rel")"; cp "$f" "$MIG_BHOME/$rel.migrate-tmp" && mv "$MIG_BHOME/$rel.migrate-tmp" "$MIG_BHOME/$rel"
  done < <(find "$m" -type f -print0)
  ( CR_HOME="$MIG_BHOME"; rules_render ) >/dev/null 2>&1 || true
  # The client's copy as of now is what verify compares the merged files with; the new facts its baseline.
  rm -rf "$old"; cp -R "$new" "$old"; cp "$MIG_S/facts.jsonl" "$MIG_S/baseline.jsonl"
  mig_unlock; stamp_changed "$MIG_BHOME"
  mig_ledger '*' resync "$(grep -c . "$r/changed.txt") file(s); tasks:$only${keep:+; kept (changed on the brain):$keep}"
  jq '.steps.verify = false' "$MIG_S/state.json" >"$MIG_S/state.json.tmp" && mv "$MIG_S/state.json.tmp" "$MIG_S/state.json"
  cat "$r/merge-plan.txt"
  echo "resynced: tasks$only; next: chartroom migrate-home verify --from $MIG_FROM --home $MIG_HOME"
}

# ---------------------------------------------------------------- materialize and restore

# A migrated task's worktree, rebuilt from its branch at the recorded path, with the client's
# uncommitted changes laid on top (staged, unstaged, untracked). Runs in this home (CR_HOME).
migrate_materialize() { # <id>
  local id="$1" wt proj dir ref br
  need_task "$id"
  [[ -n "$(meta_file "$id" migrated_from)" ]] || die "$id was not migrated (no migrated_from in its record)"
  wt="$(meta_file "$id" worktree)"; proj="$(meta_file "$id" project)"; dir="$(tdir "$id")/migrate"
  [[ -n "$wt" ]] || die "$id records no worktree"
  [[ -f "$dir/branch.json" || -e "$wt" ]] || die "$id has no migrated branch record ($dir/branch.json)"
  ref="$(jq -r '.ref // ""' "$dir/branch.json" 2>/dev/null)"; br="$(jq -r '.branch // ""' "$dir/branch.json" 2>/dev/null)"
  if [[ -e "$wt" ]]; then
    # Something is already at the path: it is this task's only if it is on the client's branch or head.
    local h b2
    h="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"; b2="$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [[ ! -f "$dir/branch.json" || ( -n "$br" && "$b2" == "$br" ) || "$h" == "$(jq -r '.head // ""' "$dir/branch.json")" ]]; then echo "$wt"; return 0; fi
    die "$id: $wt is another worktree (branch ${b2:-detached} at ${h:0:12}), not this task's ${br:-head}: left as it is"
  fi
  [[ -n "$proj" ]] || proj="$(mig_map "$(jq -r '.root // ""' "$dir/branch.json")")"
  git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || die "no checkout of $id's project at $proj"
  if [[ -z "$ref" && -f "$dir/branch.bundle" ]]; then
    ref="refs/chartroom/migrate/$id"
    git -C "$proj" fetch --quiet "$dir/branch.bundle" "+$(git bundle list-heads "$dir/branch.bundle" | awk 'NR == 1 { print $2 }'):$ref" >&2
  fi
  [[ -n "$ref" ]] && git -C "$proj" rev-parse -q --verify "$ref" >/dev/null || die "$id: its branch is not in $proj (ref ${ref:-none})"
  # A worktree with its dependencies costs CHARTROOM_MIGRATE_WORKTREE_KB (5 GB): never under 15% free.
  local total avail need="${CHARTROOM_MIGRATE_WORKTREE_KB:-5242880}"
  if [[ -n "${CHARTROOM_MIGRATE_DF:-}" ]]; then read -r total avail <<<"$CHARTROOM_MIGRATE_DF"
  else read -r total avail < <(df -Pk "$proj" 2>/dev/null | awk 'NR == 2 { print $2, $4 }'); fi
  if [[ -n "$total" && -n "$avail" ]] && (( (avail - need) * 100 < total * 15 )); then
    die "$id: rebuilding its worktree would leave the disk under 15% free ($(( avail / 1048576 )) GB free): free space first"
  fi
  mkdir -p "$(dirname "$wt")"
  if [[ "$ref" == "refs/heads/$br" && -n "$br" ]] && ! mig_checked_out "$proj" "$br"; then
    git -C "$proj" worktree add --quiet "$wt" "$br" >&2
  else
    git -C "$proj" worktree add --quiet --detach "$wt" "$ref" >&2
  fi
  [[ -s "$dir/staged.patch" ]] && git -C "$wt" apply --index --binary "$dir/staged.patch"
  [[ -s "$dir/unstaged.patch" ]] && git -C "$wt" apply --binary "$dir/unstaged.patch"
  [[ -s "$dir/untracked.tar" ]] && tar -xf "$dir/untracked.tar" -C "$wt"
  [[ -s "$dir/ignored.tar" ]] && tar -xf "$dir/ignored.tar" -C "$wt"
  printf '%s\n' "$wt" >"$dir/materialized"
  log_event "$id" note "worktree $wt rebuilt from $ref after the migration$([[ -s "$dir/staged.patch" || -s "$dir/unstaged.patch" || -s "$dir/untracked.tar" ]] && echo ', with its uncommitted changes')"
  echo "$wt"
}

migrate_restore() { # <id>: a bundled task's branch, and its worktree
  local id="$1" dir proj br heads
  need_task "$id"; dir="$(tdir "$id")/migrate"
  [[ -f "$dir/branch.json" ]] || die "$id has no migration record to restore from"
  proj="$(meta_file "$id" project)"; br="$(jq -r .branch "$dir/branch.json")"
  if [[ -f "$dir/branch.bundle" ]]; then
    git -C "$proj" bundle verify --quiet "$dir/branch.bundle" >/dev/null 2>&1 || die "the bundle $dir/branch.bundle does not apply to $proj"
    heads="$(git bundle list-heads "$dir/branch.bundle" | awk 'NR == 1 { print $2 }')"
    git -C "$proj" fetch --quiet "$dir/branch.bundle" "+$heads:refs/chartroom/migrate/$id" >&2
    jq --arg r "refs/chartroom/migrate/$id" '.ref = $r' "$dir/branch.json" >"$dir/branch.json.tmp" && mv "$dir/branch.json.tmp" "$dir/branch.json"
  fi
  [[ -n "$br" ]] && echo "branch: $br (commit $(jq -r .head "$dir/branch.json"))"
  migrate_materialize "$id"
}

# ---------------------------------------------------------------- verify

mig_verify() {
  mig_step_done move || die "migrate-home: nothing moved yet"
  local out="$MIG_S/verify.txt" fails=0 f id d lb ls want got base
  base="$(mig_baseline)"
  : >"$out"
  pass() { printf 'PASS %s\n' "$*" >>"$out"; }
  fail() { printf 'FAIL %s\n' "$*" >>"$out"; fails=$((fails + 1)); }
  # 1. every client record is here, each log starting with the client's bytes, its state the same.
  while IFS= read -r f; do
    id="$(jq -r .id <<<"$f")"; d="$MIG_BHOME/tasks/$id"
    if [[ ! -f "$d/meta.json" ]]; then
      awk -F'\t' -v i="$id" '$2 == i && $3 == "conflict" { f = 1 } END { exit !f }' "$MIG_S/ledger.tsv" 2>/dev/null && { fail "$id: an id clash, not moved (ledger)"; continue; }
      fail "$id: not on the brain"; continue
    fi
    lb="$(jq -r .log_bytes <<<"$f")"; ls="$(jq -r .log_sha <<<"$f")"
    if [[ "$lb" -gt 0 && "$(mig_sha_prefix "$d/events.log" "$lb")" != "$ls" ]] && ! mig_partial_log "$id" "$d/events.log"; then fail "$id: events.log does not start with the client's log"; continue; fi
    want="$(jq -r .state <<<"$f")"
    if [[ -n "$(jq -r '.closed // ""' "$d/meta.json")" ]]; then got=closed
    elif [[ -z "$(jq -r '.dispatched // ""' "$d/meta.json")" ]]; then got=drafting
    else got="$(awk "$CR_STATE_AWK" "$d/events.log")"; fi
    # Accepted on both sides after a partial move: settle's accept also closes there, here it stays done.
    if [[ "$want" == closed && "$got" == "done" ]] && mig_partial_log "$id" "$d/events.log" &&
      grep -qE '^[^ ]+ note: accepted$' "$d/events.log" && grep -qE '^[^ ]+ note: accepted$' "$MIG_S/staged/client/tasks/$id/events.log"; then want="$got"; fi
    [[ "$want" == "$got" ]] || { fail "$id: state $got here, $want on the client"; continue; }
  done < <(jq -c . "$base")
  (( fails == 0 )) && pass "records: all $(jq -s length "$base") client tasks here, logs and states equal"
  # 2. branches, worktrees and transcripts of the open tasks that moved.
  local nf0=$fails ref proj head porc diffsha wt
  while IFS= read -r f; do
    id="$(jq -r .id <<<"$f")"; d="$MIG_BHOME/tasks/$id"
    [[ -f "$d/migrate/branch.json" ]] || continue
    ref="$(jq -r .ref "$d/migrate/branch.json")"; head="$(jq -r .head <<<"$f")"; proj="$(mig_map "$(jq -r .root <<<"$f")")"
    if [[ -z "$ref" ]]; then fail "$id: its branch was not fetched (head $head)"; continue; fi
    [[ "$(git -C "$proj" rev-parse -q --verify "$ref" 2>/dev/null)" == "$head" ]] || { fail "$id: $ref is not the client's head $head"; continue; }
    if [[ -f "$d/migrate/materialized" ]]; then
      wt="$(cat "$d/migrate/materialized")"
      porc="$(git --no-optional-locks -C "$wt" status --porcelain 2>/dev/null | LC_ALL=C sort)"
      diffsha="$(git --no-optional-locks -C "$wt" diff --binary HEAD 2>/dev/null | mig_sha)"
      [[ "$(printf '%s' "$porc" | mig_sha)" == "$(jq -r .porcelain_sha <<<"$f")" ]] || fail "$id: git status in $wt differs from the client's"
      [[ "$diffsha" == "$(jq -r .diff_sha <<<"$f")" ]] || fail "$id: the diff in $wt differs from the client's"
    fi
  done < <(jq -c 'select(.closed | not)' "$base")
  while IFS= read -r f; do
    local t; t="$MIG_BCLAUDE/projects/$(mig_enc "$(mig_map "$(jq -r .worktree <<<"$f")")")/$(jq -r .session_id <<<"$f").jsonl"
    [[ -f "$t" && "$(mig_sha_prefix "$t" "$(jq -r .transcript_size <<<"$f")")" == "$(jq -r .transcript_sha <<<"$f")" ]] ||
      fail "$(jq -r .id <<<"$f"): transcript $t missing or not the client's"
  done < <(jq -c 'select((.closed | not) and .transcript != "")' "$base")
  (( fails == nf0 )) && pass "git and conversations: branch heads, worktrees and transcripts equal the client's"
  # 3. the brain's own tasks: each log still starts with its bytes from before the move.
  nf0=$fails
  local sz sh
  while IFS=$'\t' read -r id sz sh; do
    d="$MIG_BHOME/tasks/$id/events.log"
    [[ -f "$d" && "$(mig_sha_prefix "$d" "$sz")" == "$sh" ]] || fail "$id: the brain's own task changed under the move"
  done <"$MIG_S/brain-before.tsv"
  (( fails == nf0 )) && pass "the brain's own tasks: untouched (append-only prefix)"
  # 4. the merged files hold both sides.
  nf0=$fails
  mig_verify_union "$MIG_S/staged/client/rulings.log" "$MIG_BHOME/rulings.log" '\[r-[0-9a-f]+\]' rulings
  [[ -f "$MIG_S/backup/rulings.log" ]] && mig_verify_union "$MIG_S/backup/rulings.log" "$MIG_BHOME/rulings.log" '\[r-[0-9a-f]+\]' rulings
  mig_verify_union "$MIG_S/staged/client/inbox.md" "$MIG_BHOME/inbox.md" '^- \[i-[0-9a-f]+\]' inbox
  [[ -f "$MIG_S/backup/inbox.md" ]] && mig_verify_union "$MIG_S/backup/inbox.md" "$MIG_BHOME/inbox.md" '^- \[i-[0-9a-f]+\]' inbox
  if [[ -f "$MIG_BHOME/rulings.log" ]]; then
    ( CR_HOME="$MIG_BHOME"; rules_json ) >/dev/null 2>&1 || fail "rulings.log: malformed after the merge"
    local lw lt
    lw="$(CR_HOME="$MIG_BHOME" rules_live_json 2>/dev/null | jq -r '.[].id' | sort)"
    lt="$(CR_HOME="$MIG_BHOME" rules_json 2>/dev/null | jq -r '
      ([.[].supersedes | select(. != "-")]) as $gone
      | group_by(.topic) | map(sort_by(.ts) | last) | map(select((.id as $i | $gone | index($i) | not) and (.retired | not))) | .[].id' | sort)"
    [[ "$lw" == "$lt" ]] || fail "rulings: the live set is not the newest ruling per topic by time"
  fi
  (( fails == nf0 )) && pass "merged files: rulings and inbox hold both sides; the live rulings are the newest per topic"
  cat "$out"
  if (( fails > 0 )); then echo "verify: $fails failure(s)"; return 1; fi
  mig_mark verify
  mig_partial && { echo "verify: passed (partial: the client home stays in use; $MIG_EXCEPT stay there)"; return 0; }
  echo "verify: passed; next: chartroom migrate-home finish --from $MIG_FROM --home $MIG_HOME --brain <this machine's ssh name, as the client reaches it>"
}
# A record an earlier partial move (--except) brought here, which the client only noted on since (its
# accept, at the full move's settle): the brain's log still starts with what that move took, and so does
# the client's, whose lines after it are notes alone.
mig_partial_log() { # <id> <brain log>
  local pb="$MIG_S.partial/baseline.jsonl" c="$MIG_S/staged/client/tasks/$1/events.log" f sz sh
  [[ -f "$pb" && -f "$c" ]] || return 1
  f="$(jq -c --arg i "$1" 'select(.id == $i)' "$pb")"; [[ -n "$f" ]] || return 1
  sz="$(jq -r .log_bytes <<<"$f")"; sh="$(jq -r .log_sha <<<"$f")"
  [[ "$(mig_sha_prefix "$2" "$sz")" == "$sh" && "$(mig_sha_prefix "$c" "$sz")" == "$sh" ]] || return 1
  ! tail -c "+$((sz + 1))" "$c" | grep -qvE '^[^ ]+ note: '
}
mig_verify_union() { # <source> <merged> <id regex> <name>: every id of the source is in the merged file
  [[ -f "$1" ]] || return 0
  local missing
  missing="$(grep -oE "$3" "$1" | grep -oE '[ri]-[0-9a-f]+' | sort -u | while read -r x; do
    grep -qF "[$x]" "$2" 2>/dev/null || awk -F'\t' -v x="$x" '$1 == x || $1 == "inbox/" x { f = 1 } END { exit !f }' "$MIG_S/remaps.tsv" 2>/dev/null || echo "$x"
  done)"
  [[ -z "$missing" ]] || fail "$4: missing after the merge: $(tr '\n' ' ' <<<"$missing")"
}

# ---------------------------------------------------------------- finish, rollback, reap, status

mig_baseline() { if [[ -f "$MIG_S/baseline.jsonl" ]]; then printf '%s' "$MIG_S/baseline.jsonl"; else printf '%s' "$MIG_S/facts.jsonl"; fi; }
mig_open_worktrees() { jq -r 'select((.closed | not) and (.wst == "own" or .wst == "shared")) | .worktree' "$(mig_baseline)"; }

mig_finish() {
  mig_step_done verify || die "migrate-home: verify has not passed (migrate-home verify)"
  [[ -n "$MIG_BRAIN" && "$MIG_BRAIN" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die "migrate-home finish: --brain <ssh name of this machine, as the client reaches it> is required"
  local wts=()
  while IFS= read -r w; do [[ -n "$w" ]] && wts+=("$w"); done < <(mig_open_worktrees)
  mig_client finish "$MIG_CHOME" "$MIG_CBIN" "$MIG_HOME" "$MIG_STAMP" "$MIG_BRAIN" "${wts[@]+"${wts[@]}"}" | tee -a "$MIG_S/finish.tsv"
  [[ $MIG_DRY -eq 1 ]] || mig_mark finish
}

mig_rollback() {
  local id d at sz wts=() w kept=0
  if mig_step_done finish; then
    while IFS= read -r w; do [[ -n "$w" ]] && wts+=("$w"); done < <(mig_open_worktrees)
    mig_client unfinish "$MIG_CHOME" "$MIG_STAMP" "${wts[@]+"${wts[@]}"}"
  else
    mig_client thaw "$MIG_CHOME"
  fi
  [[ $MIG_DRY -eq 1 ]] && return 0
  # The moved records: removed unless the brain wrote to one after the move (kept, and listed).
  while IFS=$'\t' read -r at id _ _; do
    d="$MIG_BHOME/tasks/$id"; [[ -d "$d" ]] || continue
    [[ "$(jq -r '.migrated_from // ""' "$d/meta.json" 2>/dev/null)" == "$(mig_label)" ]] || continue
    sz="$(awk -F'\t' -v i="$id" '$1 == i { s = $2 } END { print s }' "$MIG_S/moved-sizes.tsv" 2>/dev/null)"
    if [[ -f "$d/migrate/materialized" ]]; then
      w="$(cat "$d/migrate/materialized")"
      if [[ -d "$w" && -z "$(git -C "$w" status --porcelain 2>/dev/null)" ]]; then git -C "$(meta_file_in "$d" project)" worktree remove "$w" 2>/dev/null || true
      elif [[ -d "$w" ]]; then echo "kept $w: it has changes made after the move"; kept=1; continue; fi
    fi
    if [[ -n "$sz" && "$(wc -c <"$d/events.log" | tr -d ' ')" != "$sz" ]]; then echo "kept $id: its log grew on the brain after the move"; kept=1; continue; fi
    rm -rf "$d"
  done < <(awk -F'\t' '$3 == "moved"' "$MIG_S/ledger.tsv")
  # The brain's files the merge replaced, back from their backups; the files it added, removed.
  if [[ -d "$MIG_S/backup" ]]; then
    local f rel
    while IFS= read -r -d '' f; do
      rel="${f#"$MIG_S/backup"/}"
      case "$rel" in xo/*) cp -p "$f" "$MIG_BCLAUDE/projects/$(mig_enc "$MIG_BHOME")/${rel#xo/}" ;; *) cp -p "$f" "$MIG_BHOME/$rel" ;; esac
    done < <(find "$MIG_S/backup" -type f -print0)
  fi
  [[ -f "$MIG_S/added-files.txt" ]] && while IFS= read -r rel; do rm -f "$MIG_BHOME/$rel"; done <"$MIG_S/added-files.txt"
  [[ -f "$MIG_S/added-xo.txt" ]] && while IFS= read -r rel; do rm -f "$rel"; done <"$MIG_S/added-xo.txt"
  if [[ -f "$MIG_S/remaps.tsv" ]]; then
    local old new
    while IFS=$'\t' read -r old new; do [[ "$old" == inbox/* && -d "$MIG_BHOME/inbox/$new" ]] && mv "$MIG_BHOME/inbox/$new" "$MIG_BHOME/$old"; done <"$MIG_S/remaps.tsv"
  fi
  stamp_changed "$MIG_BHOME"
  jq '.steps = {triage: .steps.triage, snapshot: .steps.snapshot} | .rolled_back = (now | todate)' "$MIG_S/state.json" >"$MIG_S/state.json.tmp" && mv "$MIG_S/state.json.tmp" "$MIG_S/state.json"
  mv "$MIG_S/ledger.tsv" "$MIG_S/ledger.rolled-back-$(date -u +%Y%m%dT%H%M%SZ).tsv" 2>/dev/null || true
  echo "rolled back: the client home is back in use$([[ $kept -eq 1 ]] && echo '; some records were kept (above)'). Branches fetched here and transcripts copied here are left in place."
}
meta_file_in() { jq -r --arg k "$2" '.[$k] // empty' "$1/meta.json"; } # <task dir> <key>

mig_reap() {
  mig_step_done finish || die "migrate-home reap: the home was not finished"
  local fin age wts=() w
  fin="$(jq -r '.at.finish' "$MIG_S/state.json")"
  age=$(( ( $(date +%s) - $(date -u -d "$fin" +%s 2>/dev/null || date -j -u -f %Y-%m-%dT%H:%M:%SZ "$fin" +%s) ) / 86400 ))
  while IFS= read -r w; do [[ -n "$w" ]] && wts+=("$w"); done < <(mig_open_worktrees)
  if [[ $MIG_APPLY -eq 0 ]]; then
    echo "finished $age day(s) ago. On the client: ${#wts[@]} worktree(s) of moved tasks (only clean ones go) and the renamed home .migrated/$(basename "$MIG_CHOME")-$MIG_STAMP"
    echo "on the commander's word: chartroom migrate-home reap --from $MIG_FROM --home $MIG_HOME --apply"
    return 0
  fi
  (( age >= 14 )) || die "migrate-home reap: finished $age day(s) ago; the rollback window is 14 days"
  mig_client reap "$MIG_CHOME" "$MIG_STAMP" "${wts[@]+"${wts[@]}"}" | tee -a "$MIG_S/reap.tsv"
  mig_mark reap
}

mig_status() {
  jq -r '"\(.from) \(.home): client \(.client_home), brain \(.brain_home), stamp \(.stamp)", "steps: " + ([.steps | to_entries[] | select(.value != false and .value != null) | .key] | join(", "))' "$MIG_S/state.json"
  [[ -f "$MIG_S/ledger.tsv" ]] && awk -F'\t' '{ n[$3]++ } END { for (k in n) printf "  %s %d\n", k, n[k] }' "$MIG_S/ledger.tsv" | sort
  return 0
}

# ---------------------------------------------------------------- the freeze guard

# A home being moved refuses what would start or wake a worker there (new, dispatch, steer, attach).
migrating_guard() { # <verb>
  local f="$CR_HOME/.migrating"
  [[ -f "$f" ]] || return 0
  die "this home is being moved to $(jq -r '.to // "the brain"' "$f" 2>/dev/null) (since $(jq -r '.at // "?"' "$f" 2>/dev/null)): '$1' is refused here until the move is finished or rolled back"
}

cmd_migrate_home() {
  local verb="${1:-}"; shift || true
  case "$verb" in
    ""|-h|--help|help) mig_usage; return 0 ;;
    materialize) [[ $# -eq 1 ]] || die "usage: chartroom migrate-home materialize <id>"; migrate_materialize "$(cmd_resolve "$1")"; return ;;
    restore) [[ $# -eq 1 ]] || die "usage: chartroom migrate-home restore <id>"; migrate_restore "$(cmd_resolve "$1")"; return ;;
  esac
  mig_opts "$@"
  (( ${#MIG_ARGS[@]} == 0 )) || die "migrate-home $verb: unexpected argument '${MIG_ARGS[0]}'"
  if mig_partial; then
    case "$verb" in triage|move|verify|status) ;; *) die "migrate-home $verb: not with --except (a partial move writes nothing on the client)" ;; esac
  fi
  mig_setup
  case "$verb" in
    triage) mig_triage ;;
    snapshot) mig_snapshot ;;
    freeze) mig_freeze ;;
    settle) mig_settle ;;
    move) mig_move ;;
    verify) mig_verify ;;
    finish) mig_finish ;;
    rollback) mig_rollback ;;
    reap) mig_reap ;;
    resync) mig_resync ;;
    status) mig_status ;;
    *) mig_usage >&2; exit 2 ;;
  esac
}
