# shellcheck shell=bash
# brain.sh - client homes (one brain, step 1): a home whose records live on another machine, the
# brain, and whose every chartroom command runs there over ssh, so an XO on a laptop works as
# if the home were local (docs/client-homes.md).
#
# A home is a client when its own `config` sets CHARTROOM_BRAIN=<ssh target> (only there: an
# env var or the machine-wide config file would turn every home, and every worker's shell, into a
# client). The brain finds the home by its registered name (CHARTROOM_BRAIN_HOME, default this
# home's registered name here, else its directory name); the client never sends a path.
#
# Two halves live here:
#   the client   brain_route (called by bin/chartroom right after load_config), the synced copy
#                of the records at the same paths (pull with rsync, local edits proposed to the
#                brain as puts), watch's acked rounds, attach, the dashboard tunnel, `chartroom brain`
#   the gate     `chartroom brain gate` on the brain: the one remote entry point. Its ssh command
#                line is constant; what to run comes on stdin as one JSON header line, then the
#                command's own stdin. Nothing a person typed ever reaches a remote shell.
#
# Seams for later steps: gate_client_seen (step 3: the conn lease, heartbeats from client XOs),
# brain_unreachable and the copy itself (step 5: offline local mode reads the snapshot, queues the
# same verbs). Nothing here places or moves work (step 4).

BRAIN_PROTOCOL=1
BRAIN_EX_UNREACHABLE=75   # the brain could not be reached, or the call was cut (EX_TEMPFAIL)
BRAIN_EX_PROTOCOL=76      # the brain answered but speaks another protocol, or refused the home
BRAIN_RS=$'\036'          # starts a framed control line (ASCII RS): never a wake, never output
BRAIN_MAX_FILE=4194304    # the copy's per-file cap, and a put's (4 MB)
BRAIN_TAR_MAX=10485760    # an upload's cap (10 MB)
BRAIN_BIN_RE='^[A-Za-z0-9_./~$-]+$' # (in a variable: a bare $- inside [[ =~ ]] is the shell's flags)

# ---------------------------------------------------------------- what runs where

# How a command behaves in a client home: forward (runs on the brain), hybrid (runs there, with a
# part here: watch, attach, dashboard, doctor, artifact, init, sweep, rule, new, project), local
# (runs here), refuse. A test fails when a command of bin/chartroom's dispatcher is not listed.
brain_class() { # <command>
  case "$1" in
    version|help|-h|--help|-v|--version|homes|node|install-skills|brain) echo local ;;
    join|hook) echo refuse ;;
    watch|attach|dashboard|doctor|artifact|init|sweep|rule|new|project) echo hybrid ;;
    worktree|dispatch|event|listen|status|ls|board|resolve|show|todo|inbox|relay|focus|peek|steer|stop|park|accept|close|radar|nodes|tell|ask|snooze|link|brief|set|request|initiative|store|remove|restore|done|removed) echo forward ;;
    app|attachment) echo local ;; # each refuses in a client home itself: the app runs on the brain; a file to attach must be there
    *) echo local ;; # an unknown command dies here as anywhere
  esac
}

brain_target() { printf '%s' "${CR_HOME_CFG[CHARTROOM_BRAIN]:-}"; }
brain_is_client() { [[ -z "${CHARTROOM_GATE:-}" && -n "${CR_HOME_CFG[CHARTROOM_BRAIN]:-}" ]]; }
brain_name() {
  local n="${CR_HOME_CFG[CHARTROOM_BRAIN_HOME]:-}"
  [[ -n "$n" ]] || n="$(home_name_of "$CR_HOME")"
  [[ -n "$n" ]] || { n="${CR_HOME%/}"; n="${n##*/}"; }
  printf '%s' "$n"
}

# Called by bin/chartroom for every command once the home is known. Returns for a local command
# (and in any home that is not a client); otherwise runs the command and exits.
brain_route() { # <command> [args...]
  brain_is_client || return 0
  local cmd="$1"; shift
  case "$(brain_class "$cmd")" in
    local) return 0 ;;
    refuse) die "$cmd is refused in a client home: a session joined from this machine would be a worker here, and its liveness and hooks would be read on the brain ($(brain_target)). Join it on the brain, or wait for remote dispatch" ;;
  esac
  brain_setup
  case "$cmd" in
    watch) brain_watch "$@" ;;
    attach) brain_attach "$@" ;;
    dashboard) brain_dashboard "$@" ;;
    doctor) brain_doctor "$@" ;;
    artifact) brain_artifact "$@" ;;
    init) brain_push || exit $?; brain_exec -- init "$@"; brain_pull --full || true; exit "$BRAIN_RC" ;;
    sweep) brain_exec -- sweep "$@"; brain_tunnel_note; exit "$BRAIN_RC" ;;
    rule) brain_rule "$@" ;;
    new|project) local args=(); mapfile -d '' -t args < <(brain_abs_args "$cmd" "$@"); brain_forward_plain "$cmd" "${args[@]+"${args[@]}"}" ;;
    *) brain_forward_plain "$cmd" "$@" ;;
  esac
  exit "${BRAIN_RC:-0}"
}

brain_forward_plain() {
  local f; f="$(brain_stdin_flag "$@")"
  brain_push || exit $?
  brain_exec ${f:+"$f"} -- "$@"; exit "$BRAIN_RC"
}

# new --project P / project P: a path here is made absolute (the brain has the same checkouts).
# Prints the arguments NUL-separated.
brain_abs_args() { # <command> [args...]
  local cmd="$1" a out=() next=0; shift
  for a in "$@"; do
    if [[ $next -eq 1 || ( "$cmd" == project && ${#out[@]} -eq 0 ) ]]; then a="$(brain_abs_path "$a")"; next=0
    elif [[ "$cmd" == new && "$a" == --project ]]; then next=1; fi
    out+=("$a")
  done
  printf '%s\0' "${out[@]+"${out[@]}"}"
}
brain_abs_path() { # <arg>: a path that exists here, absolute; anything else as given
  local p="$1"
  [[ "$p" == "\~" || "$p" == "\~/"* ]] && p="$HOME${p#\~}"
  if [[ ( "$p" == */* || "$p" == . || "$p" == .. ) && -d "$p" ]]; then (cd "$p" && pwd); else printf '%s' "$1"; fi
}

# Commands that read stdin pass it on: artifact add -, relay ... -. Everything else gets none, so a
# forwarded command never waits on a terminal.
brain_stdin_flag() { # <command> [args...]
  local last="${*: -1}"
  case "$1" in
    artifact) [[ "${2:-}" == add && "$last" == - ]] && echo --stdin ;;
    relay) [[ "$last" == - ]] && echo --stdin ;;
  esac
  return 0
}

# ---------------------------------------------------------------- ssh

# Arguments as a JSON array of strings, exactly (jq's --args would take "--x" for its own option).
brain_json_args() { if [[ $# -eq 0 ]]; then echo '[]'; else printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]'; fi; }

brain_setup() {
  BRAIN_TARGET="$(brain_target)"; BRAIN_HOME_NAME="$(brain_name)"
  [[ "$BRAIN_TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,253}$ ]] || die "CHARTROOM_BRAIN in $CR_HOME/config is not an ssh target (letters, digits, . _ - @ :): '$BRAIN_TARGET'"
  [[ "$BRAIN_HOME_NAME" =~ $CR_HOME_NAME_RE ]] || die "this home's name on the brain, '$BRAIN_HOME_NAME', is not a home name (set CHARTROOM_BRAIN_HOME in $CR_HOME/config)"
  BRAIN_SD="$CR_HOME/.brain"
  mkdir -p "$BRAIN_SD" 2>/dev/null || die "cannot write $BRAIN_SD"
  BRAIN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/chartroom-brain.XXXXXX")"
  # shellcheck disable=SC2064 # the path, now
  trap "rm -rf '$BRAIN_TMP'" EXIT
  brain_ssh_opts
}

# One shared connection per brain (ControlMaster): the socket directory sits under the doorbell's
# root (lib/core.sh: short, ours, mode 700), since macOS caps a socket path at 104 bytes.
brain_ssh_opts() { # sets BRAIN_SSH_O
  local t key root
  t="$(cfg BRAIN_CONNECT_TIMEOUT '' 5)"; [[ "$t" =~ ^[0-9]+$ ]] || t=5
  BRAIN_SSH_O=(-o BatchMode=yes -o "ConnectTimeout=$t" -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR)
  key="$(cfg BRAIN_KEY '' '')"
  if [[ -n "$key" ]]; then
    key="${key/#\~/$HOME}"
    [[ "$key" =~ ^[A-Za-z0-9_./@-]+$ ]] || die "CHARTROOM_BRAIN_KEY must be a plain path (letters, digits, . _ / @ -): '$key'"
    BRAIN_SSH_O+=(-i "$key" -o IdentitiesOnly=yes)
  fi
  root="$(bell_root)"
  [[ -d "$root" ]] || { mkdir -p "${root%/*}" && mkdir -m 700 "$root"; } 2>/dev/null || true
  if bell_root_ok "$root" && [[ "$root" =~ ^[A-Za-z0-9_./-]+$ ]] && (( ${#root} + 46 <= 100 )) && { [[ -d "$root/ssh" ]] || mkdir -m 700 "$root/ssh" 2>/dev/null; }; then
    BRAIN_SSH_O+=(-o ControlMaster=auto -o "ControlPath=$root/ssh/%C" -o ControlPersist=600)
  fi
}

# The constant command line the brain's shell runs: its PATH dirs first (a non-interactive ssh
# shell lacks them; CHARTROOM_RADAR_REMOTE_PATH, shared with the radar), then the gate.
brain_remote_line() { # [gate args]
  local bin; bin="$(cfg BRAIN_BIN '' chartroom)"
  [[ "$bin" =~ $BRAIN_BIN_RE ]] || die "CHARTROOM_BRAIN_BIN may hold only a path (letters, digits, . _ / ~ \$ -): '$bin'"
  printf 'PATH="%s:$PATH" exec %s brain gate%s' "$(radar_remote_path)" "$bin" "${1:+ $1}"
}

# A header line for the gate: the protocol, the verb, the home's name on the brain, who asks
# (machine and session: step 3's lease will read it), the client facts the brain cannot know
# (CHARTROOM_HARNESS), the sync token, plus <extra> (a JSON object).
brain_header() { # <verb> <extra-json>
  local tok=""; [[ -f "$BRAIN_SD/token" ]] && tok="$(cat "$BRAIN_SD/token")"
  jq -cn --argjson v "$BRAIN_PROTOCOL" --arg verb "$1" --arg home "$BRAIN_HOME_NAME" --argjson x "${2:-"{}"}" \
    --arg m "$(radar_machine_name)" --arg pid "$$" --arg s "${CLAUDE_CODE_SESSION_ID:-${CODEX_SESSION_ID:-}}" \
    --arg harness "$([[ "${CR_HARNESS:-generic}" != generic ]] && printf '%s' "$CR_HARNESS")" --arg tok "$tok" \
    '{v: $v, verb: $verb, home: $home, client: {machine: $m, pid: ($pid | tonumber), session: (if $s == "" then null else $s end)},
      env: (if $harness == "" then {} else {CHARTROOM_HARNESS: $harness} end), token: (if $tok == "" then null else $tok end)} + $x'
}

# stderr from the brain: framed control lines go to <ctl>, the rest to our stderr as it comes,
# the last of them also to <last> (ssh's own message, when ssh fails).
# Until the gate's hello, the lines are ssh's own: they are held, and given only by the
# unreachable message (its last line) when the gate never ran. <quiet>: hold them all (a watch
# round prints them itself).
brain_err_filter() { # <ctl> <last> [quiet]: writes <ctl>.done when stderr ends
  local l hello=0 held=()
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ "$l" == "$BRAIN_RS"* ]]; then
      printf '%s\n' "${l#"$BRAIN_RS"}" >>"$1"
      if [[ $hello -eq 0 && "$l" == "${BRAIN_RS}CRB hello "* ]]; then
        hello=1; [[ -n "${3:-}" ]] || { [[ ${#held[@]} -eq 0 ]] || printf '%s\n' "${held[@]}" >&2; }
      fi
    else
      printf '%s\n' "$l" >"$2"
      if [[ $hello -eq 1 && -z "${3:-}" ]]; then printf '%s\n' "$l" >&2; else held+=("$l"); [[ -z "${3:-}" ]] || printf '%s\n' "$l" >>"$1.held"; fi
    fi
  done
  { : >"$1.done"; } 2>/dev/null
}
# (a process substitution's pid is not ours to wait on: its marker says when it is through)
brain_filter_wait() { local i; for ((i = 0; i < 200; i++)); do [[ -f "$1.done" ]] && return 0; sleep 0.01; done; return 0; } # <ctl>

# One gate call. Sets BRAIN_RC (the command's own exit code, or BRAIN_EX_UNREACHABLE) and
# BRAIN_CTL (its control lines). Options:
#   --stdin        our stdin follows the header (artifact add -, relay -)
#   --file F       F's bytes follow the header (a put's content, an upload's tar)
#   --out F        the brain's stdout goes to F instead of ours
#   --quiet        the "unreachable" message is the caller's to give
brain_call() { # [options] <verb> <extra-json>
  local in=none file="" outf="" quiet=0 header rc ctl="$BRAIN_TMP/ctl.$RANDOM" last="$BRAIN_TMP/last.$RANDOM" fd
  while [[ "$1" == --* ]]; do
    case "$1" in
      --stdin) in=stdin; shift ;;
      --file) in="file"; file="$2"; shift 2 ;;
      --out) outf="$2"; shift 2 ;;
      --quiet) quiet=1; shift ;;
    esac
  done
  header="$(brain_header "$1" "${2:-}")"
  : >"$ctl"; : >"$last"
  if [[ -n "$outf" ]]; then exec {fd}>"$outf"; else exec {fd}>&1; fi
  local sin; exec {sin}<&0
  rc=0
  ssh "${BRAIN_SSH_O[@]}" -- "$BRAIN_TARGET" "$(brain_remote_line)" \
    < <(printf '%s\n' "$header"; case "$in" in stdin) cat <&"$sin" ;; file) cat -- "$file" ;; esac) \
    1>&"$fd" 2> >(brain_err_filter "$ctl" "$last") || rc=$?
  exec {fd}>&- {sin}<&-
  brain_filter_wait "$ctl"
  BRAIN_CTL="$ctl"; BRAIN_RC=$rc; BRAIN_LAST="$(cat "$last" 2>/dev/null)"
  if grep -q '^CRB hello ' "$ctl"; then
    brain_contact_ok "$ctl"
    if [[ $rc -eq 255 ]]; then
      BRAIN_RC=$BRAIN_EX_UNREACHABLE
      [[ $quiet -eq 1 ]] || warn "the connection to the brain ($BRAIN_TARGET) dropped while this ran: it may or may not have taken effect there$( [[ -s "$last" ]] && printf ' (%s)' "$(cat "$last")"). Check with chartroom show <id> or status once it answers"
    fi
    return 0
  fi
  # No hello: the gate never ran, so nothing did.
  BRAIN_RC=$BRAIN_EX_UNREACHABLE
  brain_contact_failed
  [[ $quiet -eq 1 ]] || brain_unreachable "$rc" "$(cat "$last" 2>/dev/null)"
  return 0
}

# Run a chartroom command on the brain: brain_call's exec verb, then its sync trailer.
#   --stdin / --out F as brain_call; --upload TAR: TAR follows the header (the gate unpacks it and
#   puts its directory where an argument says $BRAIN_RS"IN/"); --outdir: the brain gives a
#   directory where an argument says $BRAIN_RS"OUT/" and sends it back as a tar (stdout: --out F)
brain_exec() { # [options] -- <argv...>
  local opts=() x="{}"
  while [[ "$1" != -- ]]; do
    case "$1" in
      --stdin) opts+=(--stdin); x="$(jq -c '.stdin = true' <<<"$x")"; shift ;;
      --out) opts+=(--out "$2"); shift 2 ;;
      --quiet) opts+=(--quiet); shift ;;
      --upload) opts+=(--file "$2"); x="$(jq -c '.upload = true' <<<"$x")"; shift 2 ;;
      --outdir) x="$(jq -c '.outdir = true' <<<"$x")"; shift ;;
      *) die "brain_exec: unknown option $1" ;;
    esac
  done
  shift
  x="$(jq -c --argjson a "$(brain_json_args "$@")" '. + {argv: $a}' <<<"$x")"
  brain_call "${opts[@]+"${opts[@]}"}" exec "$x"
  [[ $BRAIN_RC -eq $BRAIN_EX_UNREACHABLE ]] || brain_sync_apply
}

# What a failed call says: the brain cannot be reached, so nothing ran there.
brain_unreachable() { # <ssh exit code> <ssh's last line>
  local since="" hint=""
  [[ -f "$BRAIN_SD/contact" ]] && since=" (last contact $(jq -rn --argjson t "$(cat "$BRAIN_SD/contact")" '$t | todate' 2>/dev/null))"
  case "$2" in
    *"Permission denied"*|*"Host key verification failed"*|*tailscale*|*"Tailscale"*) hint=" ssh needs you: run 'ssh $BRAIN_TARGET' once in a terminal." ;;
  esac
  if [[ "$1" == 255 ]]; then
    warn "the brain ($BRAIN_TARGET) is unreachable$since: ${2:-ssh failed}. This home lives there; nothing was run.$hint Offline mode is not built yet"
  else
    warn "the brain ($BRAIN_TARGET) answered, but chartroom's gate did not run there (exit $1: ${2:-no message}); nothing was run. Is chartroom installed there, on CHARTROOM_RADAR_REMOTE_PATH, or named by CHARTROOM_BRAIN_BIN?"
  fi
}

brain_contact_ok() { # <ctl file>
  local h p; h="$(grep -m1 '^CRB hello ' "$1" || true)"
  date +%s >"$BRAIN_SD/contact"; rm -f "$BRAIN_SD/outage"
  read -r _ _ BRAIN_PEER_PROTOCOL BRAIN_PEER_VERSION <<<"$h"
  p="$(grep -m1 '^CRB home ' "$1" | cut -d' ' -f3- || true)"
  [[ -n "$p" ]] && { BRAIN_PEER_PATH="$p"; printf '%s\n' "$p" >"$BRAIN_SD/path"; }
  [[ -n "${BRAIN_PEER_VERSION:-}" ]] && printf '%s\n' "$BRAIN_PEER_VERSION" >"$BRAIN_SD/version"
  return 0
}
brain_contact_failed() { [[ -f "$BRAIN_SD/outage" ]] || date +%s >"$BRAIN_SD/outage"; }

# ---------------------------------------------------------------- the copy

# The copy holds the home's records, at the same paths as on the brain, so every path the brain
# prints opens here: the home's own files (not worktrees/, config or dotfiles but .changed), and
# per task its top-level files plus artifacts/ and messages/. Never a task's other directories
# (workers leave clones and node_modules there), logs, launchers or locks. At most 4 MB a file.
# rsync's rules (first match wins; everything else is taken):
brain_filter() {
  cat <<'EOF'
- /worktrees/
- /config
+ /.changed
- /.*
- pane.log
- hooks.log
- launch.sh
- claude-settings.json
- .stall
- .park-check
- .DS_Store
- *.lock
- *.tmp*
- *.client-conflict-*
- *.client-refused-*
+ /tasks/*/artifacts/
+ /tasks/*/artifacts/**
+ /tasks/*/messages/
- /tasks/*/messages/*/
- /tasks/*/*/
EOF
}

# The same set, walked here: "<path>\t<mtime>\t<size>" per file (perl: one stat each, no fork).
BRAIN_WALK_PL='
use strict; use File::Find;
my $root = shift; chdir $root or exit 0;
my %xn = map { $_ => 1 } qw(pane.log hooks.log launch.sh claude-settings.json .stall .park-check .DS_Store);
find({ no_chdir => 1, wanted => sub {
  my $p = $File::Find::name; $p =~ s{^\./}{}; return if $p eq ".";
  my @c = split m{/}, $p; my $n = $c[-1];
  if ($xn{$n} || $n =~ /\.lock$|\.tmp|\.client-(conflict|refused)-/) { $File::Find::prune = 1; return }
  if (@c == 1 && ($n eq "worktrees" || $n eq "config" || ($n =~ /^\./ && $n ne ".changed"))) { $File::Find::prune = 1; return }
  if ($c[0] eq "tasks" && @c >= 3) {
    if (@c == 3 && -d $_ && $c[2] ne "artifacts" && $c[2] ne "messages") { $File::Find::prune = 1; return }
    if (@c >= 4 && $c[2] eq "messages" && -d $_) { $File::Find::prune = 1; return }
  }
  return if -l $_ || ! -f _;
  my @s = lstat($_); print "$p\t$s[9]\t$s[7]\n";
} }, ".");'
brain_walk() { perl -e "$BRAIN_WALK_PL" "$CR_HOME"; }
# Files edited here and not yet on the brain (the walk against the manifest): "<path>\t<mtime>\t<size>"
# of the version pulled, or "<path>\t\t" for a file made here.
brain_dirty() {
  [[ -f "$BRAIN_SD/manifest" ]] || return 0
  awk -F'\t' 'NR == FNR { m[$1] = $2 "\t" $3; next } !($1 in m) || m[$1] != $2 "\t" $3 { print $1 "\t" (($1 in m) ? m[$1] : "\t") }' \
    "$BRAIN_SD/manifest" <(brain_walk)
}

# One client process at a time touches the copy (a pull, a push, the manifest).
BRAIN_LOCKS=0
brain_lock() {
  local l="$BRAIN_SD/lock" i owner
  if [[ "$(cat "$l/pid" 2>/dev/null)" == "$$" ]]; then BRAIN_LOCKS=$((BRAIN_LOCKS + 1)); return 0; fi
  for i in $(seq 1 300); do
    if mkdir "$l" 2>/dev/null; then echo $$ >"$l/pid"; BRAIN_LOCKS=1; return 0; fi
    owner="$(cat "$l/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! pid_alive "$owner"; then rm -rf "$l"; continue; fi
    sleep 0.1
  done
  die "another chartroom still holds $l"
}
brain_unlock() {
  BRAIN_LOCKS=$((BRAIN_LOCKS - 1))
  (( BRAIN_LOCKS > 0 )) || { BRAIN_LOCKS=0; [[ "$(cat "$BRAIN_SD/lock/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$BRAIN_SD/lock"; }
  return 0
}

# Pull from the brain: --full (everything, deleting what the brain no longer has), or the tasks
# named (and the home's own files); --home: the home's own files only. Then the manifest.
brain_pull() { # --full | --home | <task id>...
  local full=0 f="$BRAIN_TMP/filter" path rc=0 id
  [[ "${1:-}" == --full ]] && { full=1; shift; }
  [[ "${1:-}" == --home ]] && shift
  command -v rsync >/dev/null 2>&1 || { warn "rsync is missing here: the home's copy cannot be refreshed (chartroom brain status)"; return 1; }
  path="$(cat "$BRAIN_SD/path" 2>/dev/null || true)"
  [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || { warn "the brain has not said where this home lives there yet (chartroom brain status)"; return 1; }
  : >"$f"
  brain_lock
  # An edit here that has not reached the brain yet is never overwritten, nor deleted, by a pull
  # (a wake, a crew view's board, another command): it stays out of the pull and keeps its old
  # manifest line, so the next command still sends it.
  local dirty; dirty="$(brain_dirty)" || true
  if [[ -n "$dirty" ]]; then
    cut -f1 <<<"$dirty" | sed -E 's/([][*?\\])/\\\1/g; s#^#- /#' >>"$f"
  fi
  if [[ $full -eq 0 ]]; then
    for id in "$@"; do [[ "$id" =~ $CR_RADAR_ID_RE ]] && printf '+ /tasks/%s/\n' "$id" >>"$f"; done
    printf -- '- /tasks/*/\n' >>"$f"
  fi
  brain_filter >>"$f"
  local del=(); [[ $full -eq 1 ]] && del=(--delete)
  rsync -rt "${del[@]+"${del[@]}"}" --max-size=4m --exclude-from="$f" \
    -e "ssh ${BRAIN_SSH_O[*]}" --rsync-path="$(brain_remote_line rsync)" \
    "$BRAIN_TARGET:${path%/}/" "$CR_HOME/" >>"$BRAIN_SD/rsync.log" 2>&1 || rc=$?
  if [[ $rc -eq 0 || $rc -eq 23 || $rc -eq 24 ]]; then
    # (the dirty files keep the line of the version pulled; one made here gets none)
    brain_walk | awk -F'\t' 'NR == FNR { if ($1 != "") d[$1] = ($2 == "" ? "" : $1 "\t" $2 "\t" $3); next }
      ($1 in d) { if (d[$1] != "") print d[$1]; next } { print }' <(printf '%s\n' "$dirty") - >"$BRAIN_SD/manifest.tmp" &&
      mv "$BRAIN_SD/manifest.tmp" "$BRAIN_SD/manifest"
    [[ $full -eq 1 ]] && date +%s >"$BRAIN_SD/pulled"
    rc=0
  else
    warn "could not refresh this home's copy from the brain (rsync exit $rc; $BRAIN_SD/rsync.log)"
  fi
  brain_unlock
  return $rc
}

# The gate's trailer, "sync <token> all|-|[home] <id>...": pull what changed since the last call.
brain_sync_apply() {
  local line tok what ids=() w home=0
  line="$(grep '^CRB sync ' "$BRAIN_CTL" | tail -1)" || return 0
  read -r _ _ tok what <<<"$line"
  [[ "$tok" =~ ^[0-9]+$ ]] || return 0
  if [[ "$what" == all || ! -f "$BRAIN_SD/manifest" ]]; then brain_pull --full || return 0
  elif [[ "$what" != - ]]; then
    for w in $what; do if [[ "$w" == home ]]; then home=1; else ids+=("$w"); fi; done
    brain_pull "${ids[@]+"${ids[@]}"}" || return 0
  fi
  printf '%s\n' "$tok" >"$BRAIN_SD/token"
}

# What the brain never takes from a put: the records chartroom owns change only through their
# verbs. Prints why, or nothing.
brain_put_refusal() { # <relative path>
  local p="$1" n="${1##*/}" c
  [[ -n "$p" && "$p" != /* && "$p" != */ ]] || { echo "not a path inside the home"; return; }
  local IFS=/; for c in $p; do [[ -n "$c" && "$c" != .* ]] || { echo "no dot or empty path parts"; return; }; done
  case "$p" in
    config|rulings.log|focus.json|worktrees/*|relays/*|tasks/*/meta.json|tasks/*/events.log|tasks/*/events.spool|tasks/*/artifacts/*|tasks/*/messages/*|inbox/*/artifacts/*)
      echo "a record chartroom owns (change it with its command)"; return ;;
  esac
  case "$n" in pane.log|hooks.log|launch.sh|claude-settings.json|*.lock) echo "a file chartroom owns"; return ;; esac
  [[ "$p" == tasks/*/*/* ]] && { echo "outside the task's record"; return; }
  return 0
}

# Before a command goes to the brain: every file edited here since the last pull (by the walk
# against the manifest) is proposed to the brain, which applies it only if its own file is still
# the version pulled. A conflict keeps the edit beside the file and stops the command.
brain_push() {
  [[ -f "$BRAIN_SD/manifest" ]] || return 0
  local rel bm bs why size ts fail=0 changed x ids=() pulled=0
  changed="$(brain_dirty)" || true
  [[ -n "$changed" ]] || return 0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  brain_lock
  while IFS=$'\t' read -r rel bm bs; do
    [[ -n "$rel" && -f "$CR_HOME/$rel" ]] || continue
    why="$(brain_put_refusal "$rel")"
    if [[ -n "$why" ]]; then
      mv -- "$CR_HOME/$rel" "$CR_HOME/$rel.client-refused-$ts"; pulled=1
      [[ "$rel" == tasks/*/* ]] && { local i="${rel#tasks/}"; ids+=("${i%%/*}"); }
      warn "the brain does not take $rel ($why): your copy is now $rel.client-refused-$ts"; continue
    fi
    size=$(($(wc -c <"$CR_HOME/$rel")))
    (( size <= BRAIN_MAX_FILE )) || { warn "$rel is over 4 MB: not sent to the brain"; continue; }
    x="$(jq -cn --arg p "$rel" --arg m "$bm" --arg s "$bs" '{path: $p, base: (if $m == "" then null else {mtime: ($m | tonumber), size: ($s | tonumber)} end)}')"
    brain_call --file "$CR_HOME/$rel" --out "$BRAIN_TMP/put" put "$x"
    [[ "$rel" == tasks/*/* ]] && { local i="${rel#tasks/}"; ids+=("${i%%/*}"); }
    case "$BRAIN_RC" in
      0) brain_put_done "$rel" "$BRAIN_TMP/put"; pulled=1 ;;
      3) mv -- "$CR_HOME/$rel" "$CR_HOME/$rel.client-conflict-$ts"; pulled=1; fail=1
         warn "$rel changed on the brain before your edit reached it: your edit is now $rel.client-conflict-$ts and the brain's version is back in its place" ;;
      "$BRAIN_EX_UNREACHABLE") fail=$BRAIN_EX_UNREACHABLE; break ;;
      *) mv -- "$CR_HOME/$rel" "$CR_HOME/$rel.client-refused-$ts"; warn "the brain refused $rel: your copy is now $rel.client-refused-$ts" ;;
    esac
  done <<<"$changed"
  brain_unlock
  [[ $pulled -eq 1 ]] && { brain_pull "${ids[@]+"${ids[@]}"}" || true; }
  [[ $fail -eq 1 ]] && die "nothing was run: an edit of yours conflicted with the brain's copy (above); merge it and run the command again"
  return $fail
}

# After a put the brain said which version it now holds: this copy takes that mtime and the
# manifest that line, so the file is no longer an edit to send.
brain_put_done() { # <relative path> <the gate's answer>
  local m sz
  m="$(jq -r '.mtime // empty' "$2" 2>/dev/null || true)"; sz="$(jq -r '.size // empty' "$2" 2>/dev/null || true)"
  [[ "$m" =~ ^[0-9]+$ && "$sz" =~ ^[0-9]+$ ]] || return 0
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$m" "$CR_HOME/$1" || return 0
  awk -F'\t' -v p="$1" -v l="$1"$'\t'"$m"$'\t'"$sz" '$1 == p { next } { print } END { print l }' "$BRAIN_SD/manifest" >"$BRAIN_SD/manifest.tmp" &&
    mv "$BRAIN_SD/manifest.tmp" "$BRAIN_SD/manifest"
}

# ---------------------------------------------------------------- the gate (on the brain)

# A home on this machine, by its registered name: sets GATE_HOME (its path). Dies (76) otherwise.
gate_home() { # <name>
  local name="$1" n p
  [[ "$name" =~ $CR_HOME_NAME_RE ]] || gate_die "'$name' is not a home name"
  GATE_HOME=""
  while IFS=$'\t' read -r n p; do [[ "$n" == "$name" ]] && GATE_HOME="$p"; done < <(homes_entries)
  [[ -n "$GATE_HOME" ]] || gate_die "no home named $name is registered on this machine ($CR_HOMES_FILE)"
  [[ -d "$GATE_HOME/tasks" ]] || gate_die "home $name ($GATE_HOME) is not a chartroom home here (no tasks/)"
  [[ -z "$(cfg_value_in "$GATE_HOME/config" CHARTROOM_BRAIN)" ]] || gate_die "home $name on this machine is itself a client of $(cfg_value_in "$GATE_HOME/config" CHARTROOM_BRAIN); a brain never forwards"
  GATE_HOME="$(cd "$GATE_HOME" && pwd -P)"
}
gate_die() { printf 'chartroom (brain): %s\n' "$*" >&2; exit "$BRAIN_EX_PROTOCOL"; }

# Step 3's seam: every call names its client (machine, pid, XO session). The conn lease and the
# client XOs' heartbeats will be recorded here; step 1 records nothing.
gate_client_seen() { :; } # <header json>

# The trailer: what in the copy changed on this machine since the client's token (this machine's
# clock, so no skew), as task ids and "home"; "all" without a token or past 64 tasks.
gate_trailer() { # <start epoch> <token>
  local start="$1" tok="$2" m what="" ids
  if [[ ! "$tok" =~ ^[0-9]+$ ]]; then printf '%sCRB sync %s all\n' "$BRAIN_RS" "$start" >&2; return; fi
  m="$(mktemp)"
  touch -d "$(jq -rn --argjson t "$((tok - 2))" '$t | todate')" "$m" 2>/dev/null || { rm -f "$m"; printf '%sCRB sync %s all\n' "$BRAIN_RS" "$start" >&2; return; }
  local t="$GATE_HOME/tasks"
  if [[ -n "$(find "$GATE_HOME" -mindepth 1 \( -path "$GATE_HOME/worktrees" -o -path "$t" -o -path "$GATE_HOME/config" -o \( -path "$GATE_HOME/.*" ! -path "$GATE_HOME/.changed" \) \) -prune -o -newer "$m" -print 2>/dev/null | head -1)" ]]; then what="home"; fi
  # (a task's own directories other than artifacts/ and messages/ are workers' scratch: never read)
  ids="$(find "$t" -mindepth 2 \( -type d -path "$t/*/*" ! -path "$t/*/artifacts" ! -path "$t/*/artifacts/*" ! -path "$t/*/messages" \) -prune -o -newer "$m" -print 2>/dev/null |
    awk -v p="$t/" 'index($0, p) == 1 { s = substr($0, length(p) + 1); sub(/\/.*/, "", s); print s }' | sort -u)"
  rm -f "$m"
  if [[ -n "$ids" && $(wc -l <<<"$ids") -gt 64 ]]; then what=all
  elif [[ -n "$ids" ]]; then what="${what:+$what }$(tr '\n' ' ' <<<"$ids")"; fi
  printf '%sCRB sync %s %s\n' "$BRAIN_RS" "$start" "${what:--}" >&2
}

# The commands a client may run here. Everything else answers 76.
gate_allows() { # <argv...>
  local c="${1:-}"
  case "$c" in
    init) [[ $# -eq 1 ]] || { echo "init takes no arguments from a client (homes are made on the brain itself)"; return; } ;;
    attach) [[ " $* " == *" --prepare "* ]] || echo "attach from a client is attach <id> --prepare (the client shows the terminal)" ;;
    dashboard) [[ "${2:-}" =~ ^(open|status|--json)$ ]] || echo "dashboard from a client is open, status or --json" ;;
    watch) echo "watch from a client goes through the gate's acked rounds" ;;
    *) case "$(brain_class "$c")" in forward|hybrid) ;; *) echo "$c is not run for a client" ;; esac ;;
  esac
}

brain_gate() {
  # A forced-command key (docs/client-homes.md): ssh hands the gate what the client asked for.
  if [[ $# -eq 0 && -n "${SSH_ORIGINAL_COMMAND:-}" && "$SSH_ORIGINAL_COMMAND" == *" brain gate rsync "* ]]; then
    local w; read -ra w <<<"${SSH_ORIGINAL_COMMAND#* brain gate rsync }"; brain_gate_rsync "${w[@]}"; return
  fi
  [[ "${1:-}" == rsync ]] && { shift; brain_gate_rsync "$@"; return; }
  local header verb v start
  start="$(date +%s)"
  IFS= read -r header || gate_die "no request on stdin"
  v="$(jq -r '.v // empty' <<<"$header" 2>/dev/null)" || gate_die "the request is not JSON"
  verb="$(jq -r '.verb // empty' <<<"$header")"
  printf '%sCRB hello %s %s\n' "$BRAIN_RS" "$BRAIN_PROTOCOL" "$CR_VERSION" >&2
  [[ "$v" == "$BRAIN_PROTOCOL" ]] || gate_die "this brain speaks protocol $BRAIN_PROTOCOL (chartroom $CR_VERSION) and the client speaks ${v:-none}: update chartroom on the older one"
  gate_home "$(jq -r '.home // empty' <<<"$header")"
  printf '%sCRB home %s\n' "$BRAIN_RS" "$GATE_HOME" >&2
  gate_client_seen "$header"
  CR_HOME="$GATE_HOME"
  local tok; tok="$(jq -r '.token // empty' <<<"$header")"
  case "$verb" in
    hello) jq -cn --argjson p "$BRAIN_PROTOCOL" --arg v "$CR_VERSION" --arg h "$GATE_HOME" --arg lp "$(gate_login_path)" \
             '{protocol: $p, version: $v, path: $h, login_path: (if $lp == "" then null else $lp end)}'; gate_trailer "$start" "$tok" ;;
    exec) gate_exec "$header" "$start" "$tok" ;;
    put) gate_put "$header"; local rc=$?; gate_trailer "$start" "$tok"; return $rc ;;
    cat) gate_cat "$header" ;;
    git) gate_git "$header" ;;
    watch1) gate_watch1 "$header" ;;
    *) gate_die "unknown verb '$verb'" ;;
  esac
}

gate_exec() { # <header> <start> <token>
  local header="$1" argv=() why calldir rc=0 a i env=()
  mapfile -d '' -t argv < <(jq -j '.argv[]? | (tostring, "\u0000")' <<<"$header")
  [[ ${#argv[@]} -gt 0 ]] || gate_die "exec without a command"
  why="$(gate_allows "${argv[@]}")"
  [[ -z "$why" ]] || gate_die "refused: $why"
  calldir="$(mktemp -d "${TMPDIR:-/tmp}/chartroom-gate.XXXXXX")"
  # shellcheck disable=SC2064 # the path, now
  trap "rm -rf '$calldir'" EXIT
  mkdir -p "$calldir/in" "$calldir/out"
  if [[ "$(jq -r '.upload // false' <<<"$header")" == true ]]; then
    head -c "$((BRAIN_TAR_MAX + 1))" | tar -x -f - -C "$calldir/in" 2>/dev/null || gate_die "the upload is not a tar"
  fi
  for i in "${!argv[@]}"; do
    a="${argv[$i]}"
    if [[ "$a" == "${BRAIN_RS}IN/"* ]]; then
      a="${a#"${BRAIN_RS}IN/"}"; [[ "$a" =~ ^[^/]+$ && "$a" != .* && -f "$calldir/in/$a" ]] || gate_die "no upload named '$a'"
      argv[i]="$calldir/in/$a"
    elif [[ "$a" == "${BRAIN_RS}OUT/" ]]; then argv[i]="$calldir/out/"; fi
  done
  gate_env "$header"; env=("${GATE_ENV[@]}")
  cd "$GATE_HOME" || gate_die "cannot enter $GATE_HOME"
  if [[ "$(jq -r '.outdir // false' <<<"$header")" == true ]]; then
    env -u CHARTROOM_BRAIN "${env[@]}" "$CR_BIN" "${argv[@]}" </dev/null >"$calldir/stdout" || rc=$?
    [[ $rc -eq 0 ]] && tar -c -f - -C "$calldir/out" .
  elif [[ "$(jq -r '.stdin // false' <<<"$header")" == true ]]; then
    env -u CHARTROOM_BRAIN "${env[@]}" "$CR_BIN" "${argv[@]}" || rc=$?
  else
    env -u CHARTROOM_BRAIN "${env[@]}" "$CR_BIN" "${argv[@]}" </dev/null || rc=$?
  fi
  gate_trailer "$2" "$3"
  return $rc
}

# A path inside the home, physically (no symlink out of it): prints the absolute path. Dies 76.
gate_path() { # <relative path> [--may-be-new]
  local rel="$1" d f
  [[ -n "$rel" && "$rel" != /* ]] || gate_die "'$rel' is not a path inside the home"
  local IFS=/ c; for c in $rel; do [[ "$c" != .. && "$c" != . && -n "$c" ]] || gate_die "'$rel' is not a plain path"; done
  f="$GATE_HOME/$rel"; d="$(dirname -- "$f")"
  if [[ ! -d "$d" ]]; then [[ "${2:-}" == --may-be-new ]] || gate_die "no such file: $rel"; printf '%s' "$f"; return; fi
  d="$(cd -P -- "$d" && pwd)"
  [[ "$d" == "$GATE_HOME" || "$d" == "$GATE_HOME"/* ]] || gate_die "$rel is outside the home"
  [[ ! -L "$f" ]] || gate_die "$rel is a symlink"
  printf '%s/%s' "$d" "${f##*/}"
}

# A put: the client's edit, applied only if this machine's file is still the version the client
# pulled (base: its mtime and size; null: the file must not exist). 3: a conflict; 76: refused.
gate_put() { # <header>
  local rel why f base bm bs m s tmp d
  rel="$(jq -r '.path // empty' <<<"$1")"
  why="$(brain_put_refusal "$rel")"; [[ -z "$why" ]] || gate_die "put $rel refused: $why"
  f="$(gate_path "$rel" --may-be-new)"
  base="$(jq -c '.base' <<<"$1")"
  if [[ "$base" == null ]]; then
    [[ ! -e "$f" ]] || { echo "chartroom (brain): $rel already exists here: it was made on the brain meanwhile" >&2; return 3; }
  else
    bm="$(jq -r '.mtime' <<<"$base")"; bs="$(jq -r '.size' <<<"$base")"
    [[ -f "$f" ]] || { echo "chartroom (brain): $rel is gone here" >&2; return 3; }
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"; s=$(($(wc -c <"$f")))
    [[ "$m" == "$bm" && "$s" == "$bs" ]] || { echo "chartroom (brain): $rel changed here since the client read it" >&2; return 3; }
  fi
  d="$(dirname -- "$f")"
  mkdir -p -- "$d" || gate_die "cannot make $(dirname -- "$rel")"
  d="$(cd -P -- "$d" && pwd)"; [[ "$d" == "$GATE_HOME"/* || "$d" == "$GATE_HOME" ]] || gate_die "$rel is outside the home"
  tmp="$f.put.$$"
  head -c "$((BRAIN_MAX_FILE + 1))" >"$tmp"
  (( $(wc -c <"$tmp") <= BRAIN_MAX_FILE )) || { rm -f "$tmp"; gate_die "put $rel refused: over 4 MB"; }
  mv -- "$tmp" "$f"
  stamp_changed "$GATE_HOME"
  jq -cn --arg p "$rel" --arg m "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" --arg s "$(($(wc -c <"$f")))" \
    '{put: $p, mtime: ($m | tonumber), size: ($s | tonumber)}'
}

# A file of the home, read-only (brain fetch, the artifact verbs). Never config or a dashboard file.
gate_cat() { # <header>
  local rel f; rel="$(jq -r '.path // empty' <<<"$1")"
  case "$rel" in config|.dashboard*|*/.dashboard*) gate_die "$rel is not given out" ;; esac
  f="$(gate_path "$rel")"
  [[ -f "$f" ]] || gate_die "no such file: $rel"
  cat -- "$f"
}

# Read-only git in a task's worktree (brain git), so a client XO can verify a branch.
gate_git() { # <header>
  local id args=() wt sub a
  id="$(jq -r '.id // empty' <<<"$1")"
  [[ "$id" =~ $CR_RADAR_ID_RE ]] || gate_die "no such task: $id"
  CR_HOME="$GATE_HOME"; STORE_UID_FOR=""; meta_path "$id"
  [[ -n "$META_PATH" ]] || gate_die "no such task: $id"
  wt="$(jq -r '.worktree // empty' "$META_PATH")"
  [[ -n "$wt" && -d "$wt" ]] || gate_die "task $id has no worktree here"
  mapfile -d '' -t args < <(jq -j '.args[]? | (tostring, "\u0000")' <<<"$1")
  sub="${args[0]:-}"
  [[ "$sub" =~ ^(log|diff|show|status|rev-parse|branch|rev-list|shortlog|ls-files|merge-base)$ ]] || gate_die "brain git runs only read-only commands (log diff show status rev-parse branch rev-list shortlog ls-files merge-base), not '$sub'"
  for a in "${args[@]:1}"; do
    case "$a" in --output*|-o|--ext-diff|--exec*|-c|--no-index|--upload-pack*|--textconv|-D|-d|-m|-M|--delete|--move|--copy|-C|--set-upstream*|--unset-upstream|--edit-description|--force|-f) gate_die "brain git refuses $a" ;; esac
  done
  [[ "$sub" == branch ]] && for a in "${args[@]:1}"; do [[ "$a" == -* ]] || gate_die "brain git branch only lists (no names)"; done
  git -C "$wt" --no-pager -c core.pager=cat -c diff.external= -c core.fsmonitor= "${args[@]}"
}

# rsync's server side, read-only, for a pull of a registered home's path.
brain_gate_rsync() { # <rsync server args...>
  local a last="" n p ok=0 server=0 sender=0
  for a in "$@"; do
    case "$a" in
      --server) server=1 ;;
      --sender) sender=1 ;;
      .) ;;
      -*) [[ "$a" =~ ^-[A-Za-z.]+$ || "$a" =~ ^--[a-z-]+(=[A-Za-z0-9.]+)?$ ]] || gate_die "rsync: refused option $a"
          [[ "$a" == --remove-source-files* ]] && gate_die "rsync: refused option $a" ;;
      *) last="$a" ;;
    esac
  done
  [[ $server -eq 1 && $sender -eq 1 ]] || gate_die "rsync: only a pull (--server --sender) is served"
  [[ "$last" =~ ^/[A-Za-z0-9_./-]+$ ]] || gate_die "rsync: '$last' is not a plain absolute path"
  while IFS=$'\t' read -r n p; do
    [[ -d "$p/tasks" ]] || continue
    p="$(cd "$p" && pwd -P)"
    [[ "${last%/}" == "$p" ]] && ok=1
  done < <(homes_entries)
  [[ $ok -eq 1 ]] || gate_die "rsync: $last is not a registered home here"
  exec rsync "$@"
}

# The environment a command from a client runs in here: this home, marked as run for a client
# (no forwarding, no browser opened on this screen, no runner that would start in the ssh session).
gate_env() { # <header> -> sets GATE_ENV
  local harness lp
  GATE_ENV=("CHARTROOM_HOME=$GATE_HOME" CHARTROOM_GATE=1 "CHARTROOM_CLIENT=$(jq -r '.client.machine // "a client"' <<<"$1")" CHARTROOM_OPENER=true)
  lp="$(gate_login_path)"; [[ -n "$lp" ]] && GATE_ENV+=("PATH=$lp")
  harness="$(jq -r '.env.CHARTROOM_HARNESS // empty' <<<"$1")"
  if [[ -n "$harness" && "$harness" =~ ^[a-z]{1,16}$ ]]; then GATE_ENV+=("CHARTROOM_HARNESS=$harness"); fi
  return 0
}

# An ssh session's PATH is the thin one of a non-interactive shell, and a worker dispatched or
# revived from it would carry it in its launcher (no version managers' shims, no package
# managers' bins). So what the gate runs gets the PATH of this user's interactive login shell
# ($SHELL -lic, or CHARTROOM_BRAIN_LOGIN_SHELL), read at most every 10 minutes and kept in the
# state dir; with none to read, the session's own.
gate_login_path() {
  local f="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/gate-login-path" sh out p
  if [[ -f "$f" && -n "$(find "$f" -mmin -10 2>/dev/null)" ]]; then cat "$f"; return 0; fi
  sh="$(cfg BRAIN_LOGIN_SHELL '' "${SHELL:-}")"
  [[ -n "$sh" && -x "$sh" ]] || return 0
  out="$(perl -e 'alarm 10; exec @ARGV' "$sh" -lic 'printf "\036%s\036" "$PATH"' </dev/null 2>/dev/null || true)"
  p="${out#*$'\036'}"; [[ "$p" != "$out" ]] || return 0
  p="${p%%$'\036'*}"
  [[ "$p" == /* && "$p" != *$'\n'* ]] || return 0
  mkdir -p "${f%/*}" 2>/dev/null && printf '%s' "$p" >"$f.$$" && mv "$f.$$" "$f"
  printf '%s' "$p"
}

# ---------------------------------------------------------------- watch

# One watch --once round for a client, delivered at least once: the wakes go out, then "end <rc>";
# the client pulls what they name, prints them and answers "ack"; only then does the cursor move.
# A link that drops before the ack leaves the cursor where it was, so the next round replays them.
# A heartbeat every 15 s ends this when the client is gone (a write to a dead link fails), and so
# does the client's stdin closing.
gate_watch1() { # <header>
  local header="$1" which cur tmp calldir wpid mpid r line rc t reset wrc=0 i
  which="$(jq -r '.cursor // "home"' <<<"$header")"
  case "$which" in
    home) cur="$GATE_HOME/.watch-cursor" ;;
    client-*) [[ "$which" =~ ^client-[A-Za-z0-9_.-]{1,64}$ ]] || gate_die "bad cursor name"; cur="$GATE_HOME/.watch-cursor.$which" ;;
    *) gate_die "bad cursor name" ;;
  esac
  t="$(jq -r '.timeout // empty' <<<"$header")"; [[ -z "$t" || "$t" =~ ^[0-9]+$ ]] || gate_die "bad timeout"
  reset="$(jq -r '.reset // false' <<<"$header")"
  CURSOR_FILE="$cur"; [[ "$reset" == true ]] && rm -f "$cur"
  ensure_cursor
  gate_env "$header"
  calldir="$(mktemp -d "${TMPDIR:-/tmp}/chartroom-gate.XXXXXX")"
  tmp="$cur.gate.$$"; cp -- "$cur" "$tmp"
  mkfifo "$calldir/w"
  trap '' PIPE
  # shellcheck disable=SC2064 # the paths, now
  trap "[[ -n \"\${wpid:-}\" ]] && gate_kill_watch \"\$wpid\"; [[ -n \"\${mpid:-}\" ]] && kill \"\$mpid\" 2>/dev/null; rm -rf '$calldir' '$tmp'" EXIT
  printf '%sCRB hello %s %s\n' "$BRAIN_RS" "$BRAIN_PROTOCOL" "$CR_VERSION" || exit "$BRAIN_EX_UNREACHABLE"
  # (in a process group of its own, so its hc event stream and every other helper end with it:
  # signalling the watch's children first orphaned the stream's pipeline, seen on the brain)
  ( cd "$GATE_HOME" && exec perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!"' env -u CHARTROOM_BRAIN "${GATE_ENV[@]}" "$CR_BIN" watch --once --cursor "$tmp" ${t:+--timeout "$t"} </dev/null >"$calldir/w" ) &
  wpid=$!
  ( while IFS= read -r line; do [[ "$line" == ack ]] && : >"$calldir/ack"; done
    : >"$calldir/eof"; [[ -f "$calldir/done" ]] || gate_kill_watch "$wpid" ) <&0 &
  mpid=$!
  exec {r}<"$calldir/w"
  while true; do
    if IFS= read -r -t 15 -u "$r" line; then printf '%s\n' "$line" || exit "$BRAIN_EX_UNREACHABLE"
    else
      rc=$?
      if (( rc > 128 )); then printf '%sCRB beat\n' "$BRAIN_RS" || exit "$BRAIN_EX_UNREACHABLE"; continue; fi
      [[ -z "$line" ]] || printf '%s\n' "$line" || exit "$BRAIN_EX_UNREACHABLE"
      break
    fi
  done
  wait "$wpid" || wrc=$?
  wpid=""
  : >"$calldir/done"
  printf '%sCRB end %d\n' "$BRAIN_RS" "$wrc" || exit "$BRAIN_EX_UNREACHABLE"
  if [[ $wrc -eq 0 ]]; then
    for i in $(seq 1 300); do [[ -f "$calldir/ack" || -f "$calldir/eof" ]] && break; sleep 0.1; done
    if [[ -f "$calldir/ack" ]]; then mv -- "$tmp" "$cur"; printf '%sCRB committed\n' "$BRAIN_RS" || true; fi
  elif [[ $wrc -eq 124 ]]; then mv -- "$tmp" "$cur"
  fi
  exit "$wrc"
}

# The watch a gate round started, and everything in its process group: TERM, which its own trap
# takes to close its hc stream, then KILL for whatever is left after 2 s.
gate_kill_watch() { # <pid, the group's leader>
  local i
  kill -TERM -- "-$1" 2>/dev/null || kill_tree "$1"
  for i in $(seq 1 20); do kill -0 -- "-$1" 2>/dev/null || return 0; sleep 0.1; done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# A client's watch: watch --once is one acked round (and retries while the brain is away);
# watch streams acked rounds against a cursor of this client's own, started at the end of each log.
# After CHARTROOM_BRAIN_OUTAGE_SECONDS (60) without the brain it wakes the XO once, and once
# more when the brain is back. (Step 5 asks there whether to switch to local mode.)
brain_watch() {
  local once=0 timeout=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) once=1; shift ;;
      --timeout) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "watch: --timeout takes whole seconds"; timeout="$2"; shift 2 ;;
      --cursor) die "watch --cursor: a client's watch keeps its cursor on the brain" ;;
      *) die "watch: unknown arg $1" ;;
    esac
  done
  local start back=1 rc first=1 cursor=home elapsed left
  start="$(date +%s)"
  [[ $once -eq 1 ]] || cursor="client-$(radar_machine_name | tr -c 'A-Za-z0-9_.\n-' '-' | cut -c1-64)"
  while true; do
    left=""
    if [[ -n "$timeout" ]]; then elapsed=$(( $(date +%s) - start )); left=$(( timeout - elapsed )); (( left > 0 )) || exit 124; fi
    if [[ -f "$BRAIN_SD/outage-told" ]]; then
      brain_call --quiet --out /dev/null hello '{}'
      if [[ $BRAIN_RC -ne $BRAIN_EX_UNREACHABLE ]]; then
        echo "[brain] $BRAIN_TARGET back after $(brain_ago "$(cat "$BRAIN_SD/outage-told")"); this home answers again"
        rm -f "$BRAIN_SD/outage-told" "$BRAIN_SD/outage"
        [[ $once -eq 1 ]] && exit 0
        back=1; continue
      fi
      rc=$BRAIN_EX_UNREACHABLE
    else
      brain_watch1 "$cursor" "$left" "$([[ $first -eq 1 && $once -eq 0 ]] && echo true || echo false)"; rc=$BRAIN_RC
      case "$rc" in
        0) first=0; back=1; [[ $once -eq 1 ]] && exit 0; continue ;;
        124) [[ $once -eq 1 ]] && exit 124; first=0; continue ;;
        "$BRAIN_EX_UNREACHABLE") ;;
        *) exit "$rc" ;;
      esac
    fi
    brain_contact_failed
    if [[ ! -f "$BRAIN_SD/outage-told" ]] && (( $(date +%s) - $(cat "$BRAIN_SD/outage") >= $(brain_outage_secs) )); then
      echo "[brain] $BRAIN_TARGET unreachable since $(jq -rn --argjson t "$(cat "$BRAIN_SD/outage")" '$t | todate'): ${BRAIN_LAST:-no answer}; this home lives there, so nothing runs until it is back (offline mode is not built yet)"
      cp "$BRAIN_SD/outage" "$BRAIN_SD/outage-told"
      [[ $once -eq 1 ]] && exit 0
    fi
    sleep "$back"; back=$(( back * 2 )); (( back <= 30 )) || back=30
  done
}
brain_outage_secs() { local s; s="$(cfg BRAIN_OUTAGE_SECONDS '' 60)"; [[ "$s" =~ ^[0-9]+$ ]] || s=60; printf '%s' "$s"; }
brain_ago() { local s=$(( $(date +%s) - $1 )); if (( s >= 3600 )); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); elif (( s >= 60 )); then printf '%dm' $((s / 60)); else printf '%ds' "$s"; fi; }

# One round: sets BRAIN_RC (the brain watch's own exit code, or BRAIN_EX_UNREACHABLE).
brain_watch1() { # <cursor> <timeout or ""> <reset true|false>
  local d="$BRAIN_TMP/w$RANDOM" x w r l lines=() endrc="" hello=0 spid ids=() id home=0 src=0
  mkdir -p "$d"; mkfifo "$d/in" "$d/out"; : >"$d/ctl"; : >"$d/last"
  x="$(jq -cn --arg c "$1" --arg t "$2" --argjson r "$3" '{cursor: $c, reset: $r} + (if $t == "" then {} else {timeout: ($t | tonumber)} end)')"
  ssh "${BRAIN_SSH_O[@]}" -- "$BRAIN_TARGET" "$(brain_remote_line)" <"$d/in" >"$d/out" 2> >(brain_err_filter "$d/ctl" "$d/last" quiet) &
  spid=$!
  exec {w}>"$d/in"
  printf '%s\n' "$(brain_header watch1 "$x")" 1>&"$w" 2>/dev/null || true
  exec {r}<"$d/out"
  while IFS= read -r -u "$r" l; do
    case "$l" in
      "${BRAIN_RS}CRB hello "*) hello=1; date +%s >"$BRAIN_SD/contact" ;;
      "${BRAIN_RS}CRB end "*)
        endrc="${l##* }"
        if [[ "$endrc" == 0 ]]; then
          for l in "${lines[@]+"${lines[@]}"}"; do
            if [[ "$l" =~ ^\[relay\  ]]; then home=1
            elif [[ "$l" =~ ^\[([A-Za-z0-9][A-Za-z0-9_.-]*)\] ]]; then ids+=("${BASH_REMATCH[1]}"); fi
          done
          if [[ ${#ids[@]} -gt 0 || $home -eq 1 ]]; then brain_pull "${ids[@]+"${ids[@]}"}" || true; fi
          for l in "${lines[@]+"${lines[@]}"}"; do printf '%s\n' "$l"; done
          printf 'ack\n' 1>&"$w" 2>/dev/null || true
        fi ;;
      "${BRAIN_RS}"*) ;;
      *) lines+=("$l") ;;
    esac
  done
  exec {w}>&- {r}<&-
  wait "$spid" || src=$?
  brain_filter_wait "$d/ctl"
  BRAIN_LAST="$(cat "$d/last" 2>/dev/null || true)"
  # (what the brain said on stderr, once it answered: a refusal, a watch error)
  [[ $hello -eq 1 && -s "$d/ctl.held" ]] && cat "$d/ctl.held" >&2
  if [[ -n "$endrc" ]]; then BRAIN_RC="$endrc"
  elif [[ $hello -eq 1 && $src -ne 255 ]]; then BRAIN_RC=$src
  else BRAIN_RC=$BRAIN_EX_UNREACHABLE; fi
  return 0
}

# ---------------------------------------------------------------- attach, dashboard, artifacts

# attach: the brain resumes a parked worker and says where it runs; this machine shows it (the
# brain's own attach would show it on the brain's screen).
brain_attach() { # <id>
  local id="${1:-}" j runner t s p
  [[ -n "$id" && $# -eq 1 ]] || die "usage: chartroom attach <id>"
  j="$BRAIN_TMP/attach.json"
  brain_push || exit $?
  brain_exec --out "$j" -- attach "$id" --prepare
  [[ $BRAIN_RC -eq 0 ]] || exit "$BRAIN_RC"
  runner="$(jq -r '.runner // empty' "$j")"
  case "$runner" in
    hc) t="$(jq -r '.hc_terminal // empty' "$j")"; [[ "$t" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "the brain gave no hc terminal for $id"
        brain_show_hc "$id" "$t" ;;
    herdr)
      [[ -t 0 && -t 1 ]] && exec herdr --remote "$BRAIN_TARGET"
      die "$id runs in herdr on the brain (its tab is focused there): in a terminal, run herdr --remote $BRAIN_TARGET" ;;
    tmux)
      s="$(jq -r '.tmux_session // empty' "$j")"; p="$(jq -r '.tmux_pane // empty' "$j")"
      [[ "$s" =~ ^[A-Za-z0-9_.:@%-]{1,128}$ && "$p" =~ ^[A-Za-z0-9_.:@%-]{0,128}$ ]] || die "the brain gave no tmux session for $id"
      local line="tmux attach-session -t '=$s'${p:+ \; select-window -t '$p'}"
      [[ -t 0 && -t 1 ]] && exec ssh -t "${BRAIN_SSH_O[@]}" -- "$BRAIN_TARGET" "PATH=\"$(radar_remote_path):\$PATH\" $line"
      die "$id runs in tmux on the brain: in a terminal, run ssh -t $BRAIN_TARGET \"$line\"" ;;
    *) die "$id runs on ${runner:-an unknown runner} on the brain, which cannot be shown from here: open it on the brain" ;;
  esac
}

# The brain's name in this machine's hc (hc's machine link), asked only of a core that already
# answers (every hc command starts one when none does).
brain_hc_machine() {
  local m; m="$(cfg BRAIN_HC_MACHINE '' '')"
  if [[ -n "$m" ]]; then [[ "$m" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] && printf '%s' "$m"; return 0; fi
  [[ -n "$(hc_bin)" ]] && sock_answers "$(hc_socket)" || return 0
  hcx machine ls --json 2>/dev/null | jq -r --arg t "$BRAIN_TARGET" \
    '[.machines[]? | select(.target == $t or .name == $t or .host == $t) | .name | select(test("^[A-Za-z0-9_.-]{1,64}$"))] | first // empty' 2>/dev/null || true
}
# Show the app's tab that holds <machine/terminal>: select its space and tab, then check it is the
# one on screen. 1 when the app has no such tab.
brain_happ_select() { # <address>
  local addr="$1" sp tb
  read -r sp tb < <(happ ls 2>/dev/null | jq -r --arg a "$addr" \
    'first(.spaces[]? as $s | $s.tabs[]? as $t | select(any($t.terminals[]?; .terminal == $a)) | "\($s.id) \($t.id)") // empty' 2>/dev/null) || true
  [[ -n "${sp:-}" && -n "${tb:-}" ]] || return 1
  happ "do" space.select --id "$sp" >/dev/null 2>&1 || return 1
  happ "do" tab.select --id "$tb" >/dev/null 2>&1 || return 1
  happ ls 2>/dev/null | jq -e --arg a "$addr" 'any(.spaces[]? | select(.active) | .tabs[]? | select(.active); any(.terminals[]?; .terminal == $a))' >/dev/null 2>&1
}
brain_show_hc() { # <id> <terminal>
  local id="$1" t="$2" m addr
  m="$(brain_hc_machine)"
  if [[ -n "$m" ]]; then
    addr="$m/$t"
    if happ ls >/dev/null 2>&1; then
      # The app shows a linked machine's terminals in spaces of their own; agent.focus answers ok
      # for one without showing it (verified with herdr-app 0.1.16), so its tab is selected.
      if brain_happ_select "$addr"; then echo "showing $id in Herdr (terminal $t on $m)"; return 0; fi
      if happ "do" terminal.open --argv "$(jq -cn --arg h "$(hc_bin)" --arg a "$addr" '[$h, "attach", $a]')" >/dev/null 2>&1; then
        echo "opened a Herdr tab on $id (hc attach $addr; ctrl+\\ detaches)"; return 0
      fi
    fi
    [[ -t 0 && -t 1 ]] && exec "$(hc_bin)" attach "$addr"
    die "no Herdr window answers here: open Herdr (the worker is terminal $t on $m), or run hc attach $addr in a terminal (ctrl+\\ detaches)"
  fi
  [[ -t 0 && -t 1 ]] && exec ssh -t "${BRAIN_SSH_O[@]}" -- "$BRAIN_TARGET" "PATH=\"$(radar_remote_path):\$PATH\" exec hc attach $t"
  die "this machine's hc does not link the brain (hc machine add $BRAIN_TARGET, or set CHARTROOM_BRAIN_HC_MACHINE): in a terminal, run ssh -t $BRAIN_TARGET hc attach $t"
}

# The dashboard is the brain's. It runs there on loopback, on its own port, and is reached here
# through one ssh tunnel per home (.brain/tunnel: "pid local-port brain-port"), so nothing new
# listens on the network.
brain_dashboard() {
  case "${1:-}" in
    stop) brain_tunnel_stop; exit 0 ;;
    status) brain_exec -- dashboard status; brain_tunnel_line; exit "$BRAIN_RC" ;;
    --json) brain_forward_plain dashboard --json ;;
    open) shift; [[ $# -eq 0 ]] || warn "on a client the dashboard is the brain's: ignoring $*"; brain_open_page dashboard ;;
    *) [[ $# -eq 0 ]] || warn "on a client the dashboard is the brain's, so it is opened there through a tunnel (ignoring $*)"; brain_open_page dashboard ;;
  esac
  exit "${BRAIN_RC:-0}"
}
brain_open_page() { # dashboard | artifact <ref>
  local f="$BRAIN_TMP/open" url bport rest lport lurl opener
  if [[ "$1" == artifact ]]; then brain_exec --out "$f" -- artifact open "$2"; else brain_exec --out "$f" -- dashboard open; fi
  [[ $BRAIN_RC -eq 0 ]] || { cat "$f"; exit "$BRAIN_RC"; }
  url="$(sed -nE 's/^dashboard (open|running): ([^ ]+).*$/\2/p' "$f" | tail -1)"
  [[ -n "$url" ]] || { cat "$f"; die "the brain's dashboard gave no address"; }
  if [[ "$url" =~ ^http://127\.0\.0\.1:([0-9]+)(/.*)?$ ]]; then
    bport="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    lport="$(brain_tunnel_ensure "$bport")" || exit $?
    lurl="http://127.0.0.1:$lport$rest"
  else lurl="$url"; fi
  opener="$(cfg OPENER '' '')"
  if [[ -z "$opener" ]]; then
    if [[ "$(uname -s)" == Darwin && -n "$(bin_of open)" ]]; then opener=open
    elif [[ -n "$(bin_of xdg-open)" ]]; then opener=xdg-open; fi
  fi
  if [[ -n "$opener" ]] && $opener "$lurl" >/dev/null 2>&1; then echo "dashboard open: $lurl (the brain's dashboard, through a tunnel)"
  else echo "dashboard running: $lurl (the brain's, through a tunnel; no browser opener found, open it yourself)"; fi
}
brain_port_busy() { ( exec {x}<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; } # <port>
brain_tunnel_ensure() { # <brain port> -> prints the local port
  local bp="$1" f="$BRAIN_SD/tunnel" pid lp obp o=() i w
  if read -r pid lp obp  2>/dev/null <"$f" && pid_alive "$pid" && [[ "$obp" == "$bp" ]]; then printf '%s' "$lp"; return 0; fi
  [[ -n "${pid:-}" ]] && pid_alive "$pid" && kill "$pid" 2>/dev/null
  lp="$bp"; i=0
  while brain_port_busy "$lp"; do lp=$((lp + 1)); i=$((i + 1)); (( i < 50 )) || die "no free local port for the dashboard tunnel from $bp up"; done
  for w in "${BRAIN_SSH_O[@]}"; do [[ "$w" == Control* ]] || o+=("$w"); done
  # (o still holds the -o before each dropped Control* value: drop those orphans)
  local clean=() k
  for ((k = 0; k < ${#o[@]}; k++)); do
    if [[ "${o[k]}" == -o && ( $((k + 1)) -ge ${#o[@]} || "${o[k+1]}" == -* ) ]]; then continue; fi
    clean+=("${o[k]}")
  done
  nohup ssh "${clean[@]}" -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -N -L "$lp:127.0.0.1:$bp" -- "$BRAIN_TARGET" \
    </dev/null >/dev/null 2>"$BRAIN_SD/tunnel.err" 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
  pid=$!
  printf '%s %s %s\n' "$pid" "$lp" "$bp" >"$f"
  w="$(cfg BRAIN_TUNNEL_WAIT '' 5)"; [[ "$w" =~ ^[0-9]+$ ]] || w=5
  for ((i = 0; i < w * 10; i++)); do
    brain_port_busy "$lp" && break
    pid_alive "$pid" || die "the tunnel to the brain's dashboard did not start: $(tail -1 "$BRAIN_SD/tunnel.err" 2>/dev/null)"
    sleep 0.1
  done
  printf '%s' "$lp"
}
brain_tunnel_stop() {
  local pid lp bp
  if read -r pid lp bp  2>/dev/null <"$BRAIN_SD/tunnel" && pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true; rm -f "$BRAIN_SD/tunnel"
    echo "stopped the tunnel to the brain's dashboard (local port $lp; the brain's dashboard keeps running)"
  else rm -f "$BRAIN_SD/tunnel"; echo "no dashboard tunnel runs (the brain's dashboard is not stopped from a client)"; fi
}
brain_tunnel_line() {
  local pid lp bp
  if read -r pid lp bp  2>/dev/null <"$BRAIN_SD/tunnel" && pid_alive "$pid"; then echo "tunnel: http://127.0.0.1:$lp here is the brain's port $bp (pid $pid)"
  else echo "tunnel: none (chartroom dashboard open starts one)"; fi
}
brain_tunnel_note() {
  local pid lp bp
  if read -r pid lp bp  2>/dev/null <"$BRAIN_SD/tunnel" && pid_alive "$pid"; then
    echo "this client: a dashboard tunnel to the brain runs (pid $pid, port $lp); chartroom dashboard stop ends it"
  fi
  return 0
}

brain_artifact() {
  case "${1:-}" in
    copy) brain_artifact_copy "${@:2}" ;;
    export|pdf) brain_artifact_out "$@" ;;
    open) [[ $# -eq 2 && "$2" != -* ]] || die "usage: chartroom artifact open <ref>"; brain_open_page artifact "$2" ;;
    add) brain_artifact_add "${@:2}" ;;
    *) brain_forward_plain artifact "$@" ;;
  esac
  exit "${BRAIN_RC:-0}"
}
# copy: the text from the brain, onto this machine's clipboard.
brain_artifact_copy() { # <ref>
  [[ $# -eq 1 ]] || die "usage: chartroom artifact copy <ref>"
  local f="$BRAIN_TMP/text" clip argv=()
  brain_exec --out "$f" -- artifact show "$1"
  [[ $BRAIN_RC -eq 0 ]] || exit "$BRAIN_RC"
  clip="$(clipboard_cmd)"
  if [[ "$clip" == - ]]; then cat -- "$f"; return 0; fi
  if [[ -n "$clip" ]]; then
    read -ra argv <<<"$clip"
    if "${argv[@]}" <"$f" >/dev/null 2>&1; then echo "copied $1 to the clipboard ($clip)"; return 0; fi
    warn "$clip failed; printing $1 instead"
  else warn "no clipboard tool (pbcopy, wl-copy, xclip, xsel; or set CHARTROOM_CLIPBOARD); printing $1 instead"; fi
  cat -- "$f"
}
# export / pdf: made on the brain, written here (at --out, else here, as the command does locally).
brain_artifact_out() { # export|pdf <ref> [--out FILE|DIR] [...]
  local sub="$1" outp="" args=() tar="$BRAIN_TMP/out.tar" x="$BRAIN_TMP/outx" f dest ref=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) [[ $# -ge 2 ]] || die "usage: chartroom artifact $sub <ref> [--out FILE|DIR]"; outp="$2"; shift 2 ;;
      -*) args+=("$1"); [[ "$1" == --paper ]] && { args+=("${2:-}"); shift; }; shift ;;
      *) [[ -z "$ref" ]] && ref="$1"; args+=("$1"); shift ;;
    esac
  done
  page_out_path "$outp" placeholder >/dev/null || exit 1 # a missing directory stops it before the brain works
  brain_exec --outdir --out "$tar" -- artifact "$sub" "${args[@]+"${args[@]}"}" --out "${BRAIN_RS}OUT/"
  [[ $BRAIN_RC -eq 0 ]] || exit "$BRAIN_RC"
  mkdir -p "$x"; tar -x -f "$tar" -C "$x" 2>/dev/null || die "the brain sent no file back"
  f="$(find "$x" -type f | head -1)"; [[ -n "$f" ]] || die "the brain sent no file back"
  dest="$(page_out_path "$outp" "${f##*/}")" || exit 1
  mv -- "$f" "$dest"
  if [[ "$sub" == export ]]; then echo "exported $ref to $dest"; else echo "wrote $dest ($ref)"; fi
}
# add <owner> ... <file>: a file here goes up with the images beside it that it names (a page
# inlines those), at most 10 MB; - passes stdin on.
brain_artifact_add() {
  local a pos=() args=() i file="" dir base imgs=() tar="$BRAIN_TMP/up.tar" total=0 im
  local -a orig=("$@")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind|--title|--description|--slug) args+=("$1" "${2:-}"); shift; shift || true ;;
      -) pos+=("-"); args+=("-"); shift ;;
      -*) args+=("$1"); shift ;;
      *) pos+=("$1"); args+=("$1"); shift ;;
    esac
  done
  [[ ${#pos[@]} -ge 2 ]] || { brain_forward_plain artifact add "${orig[@]+"${orig[@]}"}"; }
  file="${pos[1]}"
  [[ "$file" == - ]] && { brain_push || exit $?; brain_exec --stdin -- artifact add "${orig[@]}"; exit "$BRAIN_RC"; }
  [[ -f "$file" ]] || die "no such file: $file"
  dir="$(cd "$(dirname -- "$file")" && pwd)"; base="${file##*/}"
  for im in "$dir"/*.png "$dir"/*.jpg "$dir"/*.jpeg "$dir"/*.gif "$dir"/*.webp "$dir"/*.svg; do
    [[ -f "$im" ]] || continue
    grep -qF -- "${im##*/}" "$file" || continue
    total=$(( total + $(wc -c <"$im") )); (( total <= BRAIN_TAR_MAX )) || { warn "images beside $base pass 10 MB: the rest stay here"; break; }
    imgs+=("${im##*/}")
  done
  tar -c -f "$tar" -C "$dir" -- "$base" "${imgs[@]+"${imgs[@]}"}" || die "could not pack $file"
  for i in "${!args[@]}"; do [[ "${args[$i]}" == "$file" ]] && { args[i]="${BRAIN_RS}IN/$base"; break; }; done
  brain_push || exit $?
  brain_exec --upload "$tar" -- artifact add "${args[@]}"
  exit "$BRAIN_RC"
}
# rule import <map>: the map goes up as an upload; the rest of rule forwards.
brain_rule() {
  if [[ "${1:-}" == import && -n "${2:-}" && "$2" != -* && -f "$2" ]]; then
    local tar="$BRAIN_TMP/up.tar" dir; dir="$(cd "$(dirname -- "$2")" && pwd)"
    tar -c -f "$tar" -C "$dir" -- "${2##*/}" || die "could not pack $2"
    brain_push || exit $?
    brain_exec --upload "$tar" -- rule import "${BRAIN_RS}IN/${2##*/}" "${@:3}"; exit "$BRAIN_RC"
  fi
  brain_forward_plain rule "$@"
}

# doctor: this client's facts, then the brain's own doctor. Session start, so a full sync.
brain_doctor() {
  local json=0 f="$BRAIN_TMP/doctor"
  [[ "${1:-}" == --json ]] && json=1
  brain_push || exit $?
  brain_exec --out "$f" -- doctor "$@"
  if [[ $BRAIN_RC -eq $BRAIN_EX_UNREACHABLE ]]; then
    [[ $json -eq 1 ]] && brain_client_json | jq '{client: .}' || brain_client_lines
    exit "$BRAIN_RC"
  fi
  brain_pull --full || true
  if [[ $json -eq 1 ]]; then jq --argjson c "$(brain_client_json)" '. + {client: $c}' "$f" 2>/dev/null || cat "$f"
  else brain_client_lines; cat "$f"; fi
  exit "$BRAIN_RC"
}
brain_pending_count() {
  [[ -f "$BRAIN_SD/manifest" ]] || { echo 0; return; }
  awk -F'\t' 'NR == FNR { m[$1] = $2 "\t" $3; next } !($1 in m) || m[$1] != $2 "\t" $3 { n++ } END { print n + 0 }' "$BRAIN_SD/manifest" <(brain_walk)
}
brain_client_json() {
  local path pulled contact tp="" tl="" tb=""
  path="$(cat "$BRAIN_SD/path" 2>/dev/null || true)"
  read -r tp tl tb  2>/dev/null <"$BRAIN_SD/tunnel" && ! pid_alive "$tp" && tp=""
  jq -cn --arg b "$BRAIN_TARGET" --arg h "$BRAIN_HOME_NAME" --arg p "$path" --arg here "$CR_HOME" \
    --arg v "$(cat "$BRAIN_SD/version" 2>/dev/null || true)" --arg c "$(cat "$BRAIN_SD/contact" 2>/dev/null || true)" \
    --arg o "$(cat "$BRAIN_SD/outage" 2>/dev/null || true)" --arg pl "$(cat "$BRAIN_SD/pulled" 2>/dev/null || true)" \
    --argjson pend "$(brain_pending_count)" --arg files "$(wc -l <"$BRAIN_SD/manifest" 2>/dev/null | tr -d ' ' || echo 0)" \
    --arg tp "$tp" --arg tl "$tl" --arg tb "$tb" '
    def t: if . == "" then null else (tonumber | todate) end;
    {brain: $b, home: $h, brain_path: (if $p == "" then null else $p end), same_path: ($p == "" or $p == $here),
     brain_version: (if $v == "" then null else $v end), last_contact: ($c | t), unreachable_since: ($o | t),
     last_full_pull: ($pl | t), files: (($files | tonumber?) // 0), pending_pushes: $pend,
     tunnel: (if $tp == "" then null else {pid: ($tp | tonumber), port: ($tl | tonumber), brain_port: ($tb | tonumber)} end)}'
}
brain_client_lines() {
  brain_client_json | jq -r '
    "client:   this home lives on the brain: \(.brain) (home \(.home) there\(if .brain_path then ", at " + .brain_path else "" end)); every chartroom command here runs there",
    "copy:     \(.files) files at the same paths\(if .last_full_pull then ", full pull " + .last_full_pull else "" end); \(.pending_pushes) local edits not yet on the brain\(if .unreachable_since then "; UNREACHABLE since " + .unreachable_since else "" end)",
    (if .same_path then empty else "warning:  the brain keeps this home at \(.brain_path), not at this path: paths it prints will not open here" end)'
}

# ---------------------------------------------------------------- chartroom brain

cmd_brain() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    gate) brain_gate "$@" ;;
    class) [[ $# -eq 1 ]] || die "usage: chartroom brain class <command>"; brain_class "$1" ;;
    link) brain_link "$@" ;;
    unlink|status|pull|fetch|git)
      if ! brain_is_client; then
        [[ "$sub" == status ]] && { echo "this home is local, not a client ($CR_HOME)"; return 0; }
        die "this home is not a client home (chartroom brain link <target> makes one)"
      fi
      brain_setup; "brain_verb_$sub" "$@" ;;
    ""|help|-h|--help) brain_usage ;;
    *) die "brain: unknown subcommand $sub ($(brain_usage | head -1))" ;;
  esac
}
brain_usage() {
  echo "usage: chartroom brain link <target> [--as NAME] | unlink | status [--json] | pull | fetch <path> | git <id> <git args>"
}

# Make this (empty) home a client of <target>'s home of the same name (or --as NAME).
brain_link() {
  local target="" as="" ok n
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) [[ $# -ge 2 ]] || die "--as needs a home name"; as="$2"; shift 2 ;;
      -*) die "brain link: unknown flag $1" ;;
      *) [[ -z "$target" ]] || die "$(brain_usage)"; target="$1"; shift ;;
    esac
  done
  [[ -n "$target" ]] || die "$(brain_usage)"
  [[ -z "${CHARTROOM_GATE:-}" ]] || die "a brain never links to another"
  [[ -z "${CR_HOME_CFG[CHARTROOM_BRAIN]:-}" ]] || die "this home is already a client of ${CR_HOME_CFG[CHARTROOM_BRAIN]} (chartroom brain unlink first)"
  shopt -s nullglob; n=("$CR_HOME"/tasks/*); shopt -u nullglob
  [[ ${#n[@]} -eq 0 ]] || die "this home has ${#n[@]} task(s): moving them to the brain is the migration (one brain, step 2). brain link only makes an empty home a client, and changed nothing"
  # Nothing of the home's own may be overwritten or pruned by the first pull: only the files
  # chartroom init makes, unchanged, are allowed (rulings, relays, notes are the migration's).
  local own=() rel _m _s tpl
  if [[ -d "$CR_HOME" ]]; then
    while IFS=$'\t' read -r rel _m _s; do
      case "$rel" in
        commander.md|projects.md|inbox.md) tpl="$CR_ROOT/templates/$rel" ;;
        CLAUDE.md|AGENTS.md) tpl="$CR_ROOT/templates/home-AGENTS.md" ;;
        *) tpl="" ;;
      esac
      [[ -n "$tpl" ]] && cmp -s "$CR_HOME/$rel" "$tpl" && continue
      own+=("$rel")
    done < <(brain_walk)
  fi
  [[ ${#own[@]} -eq 0 ]] || die "this home holds ${#own[@]} file(s) of its own (${own[*]:0:5}): linking would replace them with the brain's. Moving a home's records is the migration (one brain, step 2); brain link only makes an empty home a client, and changed nothing"
  mkdir -p "$CR_HOME"
  CR_HOME_CFG[CHARTROOM_BRAIN]="$target"; [[ -n "$as" ]] && CR_HOME_CFG[CHARTROOM_BRAIN_HOME]="$as"
  brain_setup
  brain_call --out "$BRAIN_TMP/hello" hello '{}'
  [[ $BRAIN_RC -eq 0 ]] || { rm -rf "$BRAIN_SD"; exit "$BRAIN_RC"; }
  ok="$(cat "$BRAIN_SD/path" 2>/dev/null || true)"
  [[ -f "$CR_HOME/config" ]] || printf '# chartroom settings for this home (KEY=VALUE); they win over %s.\n' "$(home_tilde "$CR_CONFIG_FILE")" >"$CR_HOME/config"
  { echo "# this home lives on the brain: every chartroom command here runs there (chartroom brain unlink undoes this)"
    echo "CHARTROOM_BRAIN=$target"
    [[ -n "$as" ]] && echo "CHARTROOM_BRAIN_HOME=$as"
  } >>"$CR_HOME/config"
  brain_pull --full || true
  echo "this home is now a client of $target (home $BRAIN_HOME_NAME there, at $ok): every chartroom command here runs there, and its records are copied here at the same paths"
  [[ "$ok" == "$CR_HOME" ]] || warn "the brain keeps this home at $ok, not $CR_HOME: paths it prints will not open here"
}
brain_verb_unlink() {
  [[ $# -eq 0 ]] || die "usage: chartroom brain unlink"
  brain_tunnel_stop >/dev/null
  awk '!/^[[:space:]]*CHARTROOM_BRAIN(_HOME)?[[:space:]]*=/ && $0 != "# this home lives on the brain: every chartroom command here runs there (chartroom brain unlink undoes this)"' \
    "$CR_HOME/config" >"$CR_HOME/config.tmp" && mv "$CR_HOME/config.tmp" "$CR_HOME/config"
  rm -f "$BRAIN_SD/manifest" "$BRAIN_SD/token"
  echo "this home is local again; the copy of the brain's records stays here as a snapshot (its worktrees and workers are on $BRAIN_TARGET)"
}
brain_verb_status() {
  local json=0; [[ "${1:-}" == --json ]] && json=1
  brain_call --quiet --out /dev/null hello '{}'
  local reach=true; [[ $BRAIN_RC -eq $BRAIN_EX_UNREACHABLE ]] && reach=false
  if [[ $json -eq 1 ]]; then brain_client_json | jq --argjson r "$reach" --arg why "${BRAIN_LAST:-}" '. + {reachable: $r} + (if $r then {} else {error: $why} end)'; return 0; fi
  brain_client_lines
  if [[ "$reach" == true ]]; then echo "contact:  ok (chartroom $(cat "$BRAIN_SD/version" 2>/dev/null), protocol $BRAIN_PROTOCOL)"
  else echo "contact:  UNREACHABLE: ${BRAIN_LAST:-no answer}"; fi
  local m; m="$(brain_hc_machine)"
  if [[ -n "$m" ]]; then echo "attach:   through this machine's hc link to the brain (machine $m)"
  else echo "attach:   no hc machine link to the brain here (attach falls back to ssh -t in a terminal)"; fi
  brain_tunnel_line
  [[ "$reach" == true ]] || exit "$BRAIN_EX_UNREACHABLE"
}
brain_verb_pull() {
  [[ $# -eq 0 ]] || die "usage: chartroom brain pull"
  brain_push || exit $?
  brain_call --quiet --out /dev/null hello '{}'
  [[ $BRAIN_RC -ne $BRAIN_EX_UNREACHABLE ]] || { brain_unreachable 255 "$BRAIN_LAST"; exit "$BRAIN_EX_UNREACHABLE"; }
  brain_pull --full || exit 1
  echo "pulled: $(wc -l <"$BRAIN_SD/manifest" | tr -d ' ') files of home $BRAIN_HOME_NAME from $BRAIN_TARGET"
}
brain_verb_fetch() { # <path>
  [[ $# -eq 1 ]] || die "usage: chartroom brain fetch <path inside the home>"
  local p="$1" rel bp f="$BRAIN_TMP/fetch"
  bp="$(cat "$BRAIN_SD/path" 2>/dev/null || true)"
  if [[ "$p" == "$CR_HOME"/* ]]; then rel="${p#"$CR_HOME"/}"
  elif [[ -n "$bp" && "$p" == "$bp"/* ]]; then rel="${p#"$bp"/}"
  elif [[ "$p" != /* ]]; then rel="$p"
  else die "$p is not inside this home"; fi
  [[ "$rel" != .* && "$rel" != */.* && "$rel" != *..* ]] || die "brain fetch takes a plain path inside the home, not $rel"
  brain_call --out "$f" cat "$(jq -cn --arg p "$rel" '{path: $p}')"
  [[ $BRAIN_RC -eq 0 ]] || exit "$BRAIN_RC"
  mkdir -p "$(dirname -- "$CR_HOME/$rel")"; mv -- "$f" "$CR_HOME/$rel"
  # (not an edit of yours: never proposed back to the brain)
  perl -e 'my @s = stat($ARGV[1]); print "$ARGV[0]\t$s[9]\t$s[7]\n"' "$rel" "$CR_HOME/$rel" >>"$BRAIN_SD/manifest"
  echo "fetched $CR_HOME/$rel"
}
brain_verb_git() { # <id> <git args...>
  [[ $# -ge 2 ]] || die "usage: chartroom brain git <id> <log|diff|show|status|...> [args]"
  local id="$1"; shift
  brain_call git "$(jq -cn --arg id "$id" --argjson a "$(brain_json_args "$@")" '{id: $id, args: $a}')"
  exit "$BRAIN_RC"
}
