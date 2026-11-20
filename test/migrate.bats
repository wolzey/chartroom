#!/usr/bin/env bats
# migrate-home (lib/migrate.sh): a client home moved into the brain's. Both machines are this
# one: the client's tree lives under $C and the brain's under $B, and CHARTROOM_MIGRATE_PATH_MAP
# maps one to the other, as identical paths do between two real machines.

load test_helper

setup() {
  common_setup
  # Physical paths: worktrees record theirs (pwd -P), and the map must match them.
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"; C="$T/c"; B="$T/b"; CH="$C/home"; BH="$B/home"
  export CHARTROOM_MIGRATE_PATH_MAP="$C=$B"
  export CHARTROOM_MIGRATE_CLIENT_CLAUDE_DIR="$C/claude" CLAUDE_CONFIG_DIR="$B/claude"
  export CHARTROOM_MIGRATE_CLIENT_CODEX_DIR="$C/codex" CODEX_HOME="$B/codex"
  export CHARTROOM_MIGRATE_DF="1000000000 900000000" CHARTROOM_MIGRATE_SNAPSHOT_DIR="$T/snaps"
  export CHARTROOM_MIGRATE_NOW="$(date +%s)"
  git init -q --bare "$T/remote.git"
  git -C "$PROJECT" remote add origin "$T/remote.git"; git -C "$PROJECT" push -q origin main
  mkdir -p "$C/work" "$B/work" "$C/claude" "$B/claude"
  git clone -q "$T/remote.git" "$C/work/proj"; git clone -q "$T/remote.git" "$B/work/proj"
  echo '.worktrees/' >>"$C/work/proj/.git/info/exclude"; echo '.worktrees/' >>"$B/work/proj/.git/info/exclude"
  CHARTROOM_HOME="$CH" cr init >/dev/null; CHARTROOM_HOME="$BH" cr init >/dev/null
  printf 'CHARTROOM_WORKSPACE=app-crew\nCHARTROOM_DASHBOARD_PORT=4519\nCHARTROOM_PROJECT_ROOTS=%s/work\n' "$C" >"$CH/config"
  printf 'CHARTROOM_WORKSPACE=app-crew\nCHARTROOM_DASHBOARD_PORT=4520\n' >"$BH/config"
}

mh() { CHARTROOM_HOME="$BH" cr migrate-home "$1" --from local --home app --client-home "$CH" --brain-home "$BH" --no-prs "${@:2}"; }
frz() { mh snapshot >/dev/null && mh freeze "$@"; } # a freeze needs a snapshot first
on_c() { CHARTROOM_HOME="$CH" cr "$@"; }
on_b() { CHARTROOM_HOME="$BH" cr "$@"; }
cmeta() { local f="$CH/tasks/$1/meta.json"; jq "${@:2}" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
bmeta() { jq -r "$2" "$BH/tasks/$1/meta.json"; }
S() { printf '%s/records/migrate/local-app' "$BH"; }

# A client task: created, its brief given an intent, marked dispatched on hc:claude with a session.
ctask() { # <title> [kind]
  local out id
  out="$(on_c new --project "$C/work/proj" --title "$1" --kind "${2:-ship}" --backend hc:claude)"
  id="$(sed -n 's/^id=//p' <<<"$out")"
  cmeta "$id" --arg s "$(printf '%08x-0000-4000-8000-%012x' "$RANDOM$RANDOM" "$RANDOM$RANDOM")" \
    '.dispatched = "2026-01-01T00:00:00Z" | .session_id = $s | .hc_terminal = "t9" | .hc_tab = "tb1" | .pid = "4242"'
  printf '%s note: dispatched via hc:claude\n' "2026-01-01T00:00:01Z" >>"$CH/tasks/$id/events.log"
  printf '%s' "$id"
}
# Its session's transcript where Claude Code keeps it, under the client's Claude dir.
ctranscript() { # <id>
  local wt sid d; wt="$(jq -r .worktree "$CH/tasks/$1/meta.json")"; sid="$(jq -r .session_id "$CH/tasks/$1/meta.json")"
  d="$C/claude/projects/${wt//[^A-Za-z0-9]/-}"; mkdir -p "$d/$sid/tool-results" "$C/claude/file-history/$sid"
  printf '{"type":"user","sessionId":"%s","message":{"content":"Your task id is %s."}}\n' "$sid" "$1" >"$d/$sid.jsonl"
  echo out >"$d/$sid/tool-results/r1.txt"; echo v1 >"$C/claude/file-history/$sid/f@v1"
}

# The client: one ship task with a commit pushed nowhere and staged, unstaged and untracked work, in
# review (moved); one closed; one drafted. Rulings and inbox items on both sides, a brain task.
fixture() {
  A="$(ctask "add the widget")"
  on_c worktree "$A" >/dev/null
  W="$(jq -r .worktree "$CH/tasks/$A/meta.json")"
  git -C "$W" checkout -q -b worker-renamed   # the worker moved its work to a branch the record does not name
  echo one >"$W/a.txt"; git -C "$W" add a.txt; git -C "$W" commit -qm "widget one"
  echo staged >"$W/b.txt"; git -C "$W" add b.txt
  echo unstaged >>"$W/README"
  echo new >"$W/untracked.txt"
  echo '.env.local' >>"$C/work/proj/.git/info/exclude"; echo '.env.local' >>"$B/work/proj/.git/info/exclude"; echo 'TOKEN=dev-only' >"$W/.env.local"
  printf '%s done: widget added\n' "2026-01-02T00:00:00Z" >>"$CH/tasks/$A/events.log"
  ctranscript "$A"
  Z="$(ctask "an old closed one")"; cmeta "$Z" '.closed = "2026-01-03T00:00:00Z"'
  D="$(on_c new --project "$C/work/proj" --title "a draft" | sed -n 's/^id=//p')"
  cat >"$CH/rulings.log" <<'EOF'
2026-01-01T00:00:00Z [r-0001] topic=delivery supersedes=- src=import :: commit on a branch
2026-01-05T00:00:00Z [r-0002] topic=ci supersedes=- src=chat :: client says CI weekly
2026-01-06T00:00:00Z [r-0003] topic=tone supersedes=- src=chat :: short sentences
EOF
  cat >"$BH/rulings.log" <<'EOF'
2026-01-01T00:00:00Z [r-0001] topic=delivery supersedes=- src=import :: commit on a branch
2026-01-07T00:00:00Z [r-00b1] topic=ci supersedes=- src=chat :: brain says CI on ready only
2026-01-04T00:00:00Z [r-0003] topic=naming supersedes=- src=chat :: a brain ruling that shares an id
2026-01-02T00:00:00Z [r-00b2] topic=tone supersedes=- src=chat :: an older brain tone
EOF
  printf '# Commander\n\nclient preference line\n' >"$CH/commander.md"
  printf '# Commander\n\nclient preference line\nbrain-only preference line\n' >"$BH/commander.md"
  on_c rule render >/dev/null; on_b rule render >/dev/null
  awk '{print} /^## Waiting on the commander$/ {print "- [i-c001] 2026-01-01 — [proj] client question"}' "$CH/inbox.md" >"$CH/inbox.md.t" && mv "$CH/inbox.md.t" "$CH/inbox.md"
  awk '{print} /^## Waiting on the commander$/ {print "- [i-b001] 2026-01-02 — [proj] brain question"}' "$BH/inbox.md" >"$BH/inbox.md.t" && mv "$BH/inbox.md.t" "$BH/inbox.md"
  mkdir -p "$CH/designs"; echo "a design" >"$CH/designs/plan.md"
  BT="$(CHARTROOM_HOME="$BH" cr new --project "$B/work/proj" --title "brain's own" | sed -n 's/^id=//p')"
}

@test "triage rules: each bucket, failing closed on unreadable git" {
  local now; now="$(date +%s)"
  run jq -c --argjson now "$now" -f "$REPO_ROOT/lib/migrate_triage.jq" <<EOF
[{"id":"live","state":"working","live":"working","wst":"own","dirty":0,"unpushed":0,"ahead":1,"prs":[]},
 {"id":"active","state":"stopped-silent","live":"parked","wst":"own","dirty":0,"unpushed":0,"ahead":1,"prs":[],"last_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"},
 {"id":"merged","state":"review","live":"done","wst":"own","dirty":0,"unpushed":0,"ahead":3,"head":"abc","prs":[{"state":"MERGED","head":"abc"}]},
 {"id":"merged-later","state":"review","live":"done","wst":"own","dirty":0,"unpushed":0,"ahead":4,"head":"def","prs":[{"state":"MERGED","head":"abc"}],"last_at":"2020-01-01T00:00:00Z"},
 {"id":"unknown","state":"waiting-overdue","live":"gone","wst":"own","dirty":null,"unpushed":null,"ahead":null,"prs":[],"last_at":"2020-01-01T00:00:00Z"},
 {"id":"old-review","state":"review","live":"done","wst":"own","dirty":0,"unpushed":0,"ahead":0,"prs":[],"last_at":"2020-01-01T00:00:00Z"},
 {"id":"overdue-pr","state":"waiting-overdue","live":"gone","wst":"own","dirty":0,"unpushed":0,"ahead":2,"prs":[{"state":"OPEN"}],"last_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"},
 {"id":"stale-work","state":"waiting-overdue","live":"gone","wst":"own","dirty":1,"unpushed":0,"ahead":0,"prs":[],"last_at":"2020-01-01T00:00:00Z"},
 {"id":"scout","kind":"scout","has_report":true,"state":"waiting-overdue","live":"gone","wst":"none","prs":[],"last_at":"2020-01-01T00:00:00Z"},
 {"id":"orphan","state":"drafting","live":"not-started","wst":"none","prs":[],"studio_wt":"/x/.worktrees/cap_orphan"}]
EOF
  [ "$status" -eq 0 ]
  b() { jq -r --arg i "$1" '.[] | select(.id == $i) | "\(.bucket) \(.action)"' <<<"$output"; }
  [ "$(b live)" = "d move" ]
  [ "$(b active)" = "d keep" ]                  # recently active but not live: kept, its worktree rebuilt on first use
  [ "$(b merged)" = "a close" ]
  [ "$(b merged-later)" = "b keep" ]            # merged, but the worktree moved on: never closed as landed
  [ "$(b unknown)" = "c bundle" ]               # unreadable git counts as work
  [ "$(b old-review)" = "b accept" ]            # the bulk default: old review with nothing local
  [ "$(b overdue-pr)" = "c keep" ]              # overdue but recent, with an open PR: kept
  [ "$(b stale-work)" = "c bundle" ]
  [ "$(b scout)" = "b keep" ]                   # an unread scout report is never closed
  [ "$(b orphan)" = "b keep" ]
  jq -e '.[] | select(.id == "unknown") | .exc | index("git facts unreadable: treated as having work")' <<<"$output"
}

@test "triage reads the client and writes nothing there" {
  fixture
  before="$(snapshot "$CH" "$C/work" "$C/claude")"
  run mh triage
  [ "$status" -eq 0 ]
  [[ "$output" == *"open 2:"* ]]
  [ -f "$(S)/decisions.tsv" ]
  awk -F'\t' -v i="$A" '$1 == i { f = 1 } END { exit !f }' "$(S)/decisions.tsv"
  [ "$(jq -r --arg i "$A" '.[] | select(.id == $i) | .dirty' "$(S)/triage.json")" = 3 ]
  [ "$(snapshot "$CH" "$C/work" "$C/claude")" = "$before" ]
}

@test "a home being moved refuses new, dispatch, steer and attach" {
  fixture
  echo '{"to":"brain","at":"2026-01-01T00:00:00Z"}' >"$CH/.migrating"
  run on_c new --project "$C/work/proj" --title x
  [ "$status" -ne 0 ]; [[ "$output" == *"being moved to brain"* ]]
  run on_c dispatch "$A"; [ "$status" -ne 0 ]; [[ "$output" == *"'dispatch' is refused"* ]]
  run on_c steer "$A" hello; [ "$status" -ne 0 ]
  run on_c attach "$A"; [ "$status" -ne 0 ]
}

# The whole move, decided as triage prefilled it, with the client's work kept.
full_move() {
  fixture
  mh triage >/dev/null
  awk -F'\t' -v OFS='\t' -v a="$A" '$1 == a { $2 = "move" } { print }' "$(S)/decisions.tsv" >"$T/dec.tsv"
  frz >/dev/null
  mh settle --decisions "$T/dec.tsv" >/dev/null
  mh move >"$T/move.out"
}

@test "move: every record, the open task's branch, changes and session, the merged files" {
  full_move
  # Records: all three client tasks, the brain's own untouched.
  [ -f "$BH/tasks/$A/meta.json" ] && [ -f "$BH/tasks/$Z/meta.json" ] && [ -f "$BH/tasks/$D/meta.json" ]
  [ -f "$BH/tasks/$BT/meta.json" ]
  [ -n "$(bmeta "$Z" .closed)" ]
  # Handles cleared; parked on hc:claude with the same session; paths mapped to the brain.
  [ "$(bmeta "$A" '.hc_terminal // "none"')" = none ] && [ "$(bmeta "$A" '.pid // "none"')" = none ]
  [ "$(bmeta "$A" .backend)" = hc:claude ]
  [ -n "$(bmeta "$A" .parked)" ]
  [ "$(bmeta "$A" .session_id)" = "$(jq -r .session_id "$CH/tasks/$A/meta.json")" ]
  BW="$(bmeta "$A" .worktree)"; [[ "$BW" == "$B"/* ]]; [ "$BW" = "${W/#$C/$B}" ]
  [ "$(bmeta "$A" .migrated_from)" = local ]
  grep -q 'note: migrated from local' "$BH/tasks/$A/events.log"
  # The worktree, rebuilt: the commit, and staged, unstaged and untracked work as on the client.
  [ "$(git -C "$BW" rev-parse HEAD)" = "$(git -C "$W" rev-parse HEAD)" ]
  [ "$(git -C "$BW" symbolic-ref --short HEAD)" = worker-renamed ] && [ "$(bmeta "$A" .branch)" = worker-renamed ]
  [ "$(git -C "$B/work/proj" rev-list --count main..worker-renamed)" = "$(git -C "$W" rev-list --count main..HEAD)" ]
  [ "$(git -C "$BW" status --porcelain | sort)" = "$(git -C "$W" status --porcelain | sort)" ]
  [ "$(git -C "$BW" diff --cached)" = "$(git -C "$W" diff --cached)" ]
  [ "$(cat "$BW/untracked.txt")" = new ]
  [ "$(cat "$BW/.env.local")" = TOKEN=dev-only ]   # a small ignored file comes too
  # The session: transcript, its dir and its file history, under the brain's path.
  sid="$(bmeta "$A" .session_id)"
  t="$B/claude/projects/${BW//[^A-Za-z0-9]/-}/$sid.jsonl"
  [ -f "$t" ] && [ -f "${t%.jsonl}/tool-results/r1.txt" ] && [ -f "$B/claude/file-history/$sid/f@v1" ]
  # Rulings: union, by time; the brain's clashing r-0003 renamed; the newest per topic lives.
  [ "$(grep -c . "$BH/rulings.log")" -eq 6 ]
  grep -q 'topic=naming' "$BH/rulings.log"; ! grep -q '\[r-0003\] topic=naming' "$BH/rulings.log"
  live="$(on_b rule list --json 2>/dev/null || CHARTROOM_HOME="$BH" cr rule list)"
  [[ "$live" == *"brain says CI on ready only"* ]]; [[ "$live" != *"client says CI weekly"* ]]
  # By time, not by file: the client's newer tone wins over the brain's older one listed after it.
  [[ "$live" == *"short sentences"* ]]; [[ "$live" != *"an older brain tone"* ]]
  # commander.md: the client's base, the brain's extra line appended for review.
  grep -q 'From the brain' "$BH/commander.md"; grep -q 'brain-only preference line' "$BH/commander.md"
  grep -q 'short sentences' "$BH/commander.md"
  # inbox: both items. config: the brain's port, the client's other key added. Other files: added.
  grep -q 'i-c001' "$BH/inbox.md"; grep -q 'i-b001' "$BH/inbox.md"
  grep -q '^CHARTROOM_DASHBOARD_PORT=4520$' "$BH/config"; ! grep -q 4519 "$BH/config"
  grep -q '^CHARTROOM_PROJECT_ROOTS=' "$BH/config"
  [ "$(cat "$BH/designs/plan.md")" = "a design" ]
  # The client still has its home, frozen, and its task's worktree untouched.
  [ -f "$CH/.migrating" ] && [ -f "$CH/tasks/$A/meta.json" ] && [ -f "$W/untracked.txt" ]
}

@test "verify passes on a clean move, and fails when a moved log loses its history" {
  full_move
  run mh verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS records"* ]]; [[ "$output" == *"PASS git and conversations"* ]]
  [[ "$output" == *"PASS the brain's own tasks"* ]]; [[ "$output" == *"PASS merged files"* ]]
  printf 'tampered\n' >"$BH/tasks/$A/events.log"
  run mh verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"$A: events.log does not start with the client's log"* ]]
}

@test "a watch on the brain wakes nothing for a moved task's history" {
  fixture
  # The brain's watch has looked before the move (its cursor exists), as a running XO's has.
  CHARTROOM_HOME="$BH" "$CHARTROOM" watch --once --timeout 1 >/dev/null 2>&1 || true
  mh triage >/dev/null; frz >/dev/null; mh settle >/dev/null; mh move >/dev/null
  grep -q "^$A"$'\t' "$BH/.watch-cursor"
  # A watch that has no offset for it (one streaming since before the move) starts where the client left off.
  grep -v "^$A"$'\t' "$BH/.watch-cursor" >"$BH/.watch-cursor.t" && mv "$BH/.watch-cursor.t" "$BH/.watch-cursor"
  run env CHARTROOM_HOME="$BH" "$CHARTROOM" watch --once --timeout 2
  [[ "$output" != *"widget added"* ]]
  printf '%s decision: a new question on the brain\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$BH/tasks/$A/events.log"
  run env CHARTROOM_HOME="$BH" "$CHARTROOM" watch --once --timeout 3
  [[ "$output" == *"a new question on the brain"* ]]
  [[ "$output" != *"widget added"* ]]
}

@test "move again is a no-op: no record, ruling or commander line twice" {
  full_move
  r="$(cksum <"$BH/rulings.log")"; c="$(cksum <"$BH/commander.md")"; i="$(cksum <"$BH/inbox.md")"
  mh move >/dev/null
  [ "$(cksum <"$BH/rulings.log")" = "$r" ]; [ "$(cksum <"$BH/commander.md")" = "$c" ]; [ "$(cksum <"$BH/inbox.md")" = "$i" ]
  [ "$(grep -c 'note: migrated' "$BH/tasks/$A/events.log")" -eq 1 ]
}

@test "move --dry-run changes nothing on the brain" {
  fixture
  mh triage >/dev/null
  before="$(snapshot "$BH/tasks" "$B/work" "$B/claude"; cksum <"$BH/rulings.log"; cksum <"$BH/inbox.md")"
  run mh move --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run: nothing changed on the brain"* ]]
  [[ "$output" == *"rulings.log:"* ]]
  [ "$(snapshot "$BH/tasks" "$B/work" "$B/claude"; cksum <"$BH/rulings.log"; cksum <"$BH/inbox.md")" = "$before" ]
}

@test "each step needs the one before: freeze a snapshot, settle a freeze, move a disk that stays over 15% free" {
  fixture
  mh triage >/dev/null
  run mh freeze
  [ "$status" -ne 0 ]; [[ "$output" == *"snapshot first"* ]]; [ ! -f "$CH/.migrating" ]
  run mh settle
  [ "$status" -ne 0 ]; [[ "$output" == *"freeze the client home first"* ]]
  run mh move
  [ "$status" -ne 0 ]; [[ "$output" == *"run settle first"* ]]
  frz >/dev/null; mh settle >/dev/null
  CHARTROOM_MIGRATE_DF="100000000 15500000" run mh move
  [ "$status" -ne 0 ]; [[ "$output" == *"under 15% free"* ]]
  [ ! -d "$BH/tasks/$A" ]
}

@test "rollback: the brain's files back byte for byte, the moved records gone, the client thawed" {
  fixture
  r="$(cksum <"$BH/rulings.log")"; c="$(cksum <"$BH/commander.md")"; i="$(cksum <"$BH/inbox.md")"; k="$(cksum <"$BH/config")"
  mh triage >/dev/null; frz >/dev/null; mh settle >/dev/null; mh move >/dev/null
  [ -d "$BH/tasks/$A" ]
  run mh rollback
  [ "$status" -eq 0 ]
  [ ! -d "$BH/tasks/$A" ] && [ ! -d "$BH/tasks/$Z" ] && [ -d "$BH/tasks/$BT" ]
  [ "$(cksum <"$BH/rulings.log")" = "$r" ]; [ "$(cksum <"$BH/commander.md")" = "$c" ]
  [ "$(cksum <"$BH/inbox.md")" = "$i" ]; [ "$(cksum <"$BH/config")" = "$k" ]
  [ ! -e "$BH/designs/plan.md" ]
  [ ! -f "$CH/.migrating" ]
}

@test "settle: close refuses a dirty worktree and keeps the task; bundle packs unpushed commits; restore brings them back" {
  fixture
  # A second ship task with a commit pushed nowhere and a clean tree, to be bundled.
  E="$(ctask "stale work")"; on_c worktree "$E" >/dev/null
  WE="$(jq -r .worktree "$CH/tasks/$E/meta.json")"
  echo s >"$WE/s.txt"; git -C "$WE" add s.txt; git -C "$WE" commit -qm "stale commit"
  head="$(git -C "$WE" rev-parse HEAD)"
  mh triage >/dev/null
  { printf '%s\tclose\n' "$A"; printf '%s\tbundle\n' "$E"; } >"$T/dec.tsv"
  frz >/dev/null
  mh settle --decisions "$T/dec.tsv" >/dev/null
  # A: dirty, so close refused it; never --discard: it stays open and moves as kept.
  [ -z "$(jq -r '.closed // ""' "$CH/tasks/$A/meta.json")" ]
  awk -F'\t' -v i="$A" '$2 == i && $3 == "kept"' "$(S)/ledger.tsv" | grep -q .
  # E: bundled on the brain, then closed on the client.
  [ -n "$(jq -r '.closed // ""' "$CH/tasks/$E/meta.json")" ]
  mh move >/dev/null
  [ -f "$BH/tasks/$E/migrate/branch.bundle" ]
  # A, still open after its refused close, brings its branch and its uncommitted work.
  [ "$(jq -r .head "$BH/tasks/$A/migrate/branch.json")" = "$(git -C "$W" rev-parse HEAD)" ]
  [ -s "$BH/tasks/$A/migrate/staged.patch" ] && [ -s "$BH/tasks/$A/migrate/unstaged.patch" ] && [ -s "$BH/tasks/$A/migrate/untracked.tar" ]
  # The commit gone from the brain's checkout, so only the bundle can bring it back.
  br="$(jq -r .branch "$BH/tasks/$E/migrate/branch.json")"
  git -C "$B/work/proj" update-ref -d "refs/chartroom/migrate/$E" 2>/dev/null || true
  git -C "$B/work/proj" branch -D "$br" >/dev/null 2>&1 || true
  git -C "$B/work/proj" reflog expire --expire=now --all; git -C "$B/work/proj" gc -q --prune=now
  ! git -C "$B/work/proj" cat-file -e "$head^{commit}" 2>/dev/null
  run on_b migrate-home restore "$E"
  [ "$status" -eq 0 ]
  [ "$(git -C "$(bmeta "$E" .worktree)" rev-parse HEAD)" = "$head" ]
}

@test "materialize: a kept task's worktree is rebuilt on first use, with its uncommitted work" {
  fixture
  mh triage >/dev/null
  awk -F'\t' -v OFS='\t' -v a="$A" '$1 == a { $2 = "keep" } { print }' "$(S)/decisions.tsv" >"$T/dec.tsv"
  frz >/dev/null; mh settle --decisions "$T/dec.tsv" >/dev/null; mh move >/dev/null
  BW="$(bmeta "$A" .worktree)"
  [ ! -e "$BW" ]
  run on_b migrate-home materialize "$A"
  [ "$status" -eq 0 ]
  [ "$(git -C "$BW" status --porcelain | sort)" = "$(git -C "$W" status --porcelain | sort)" ]
  grep -q "worktree $BW rebuilt" "$BH/tasks/$A/events.log"
}

@test "finish renames the client home, locks its worktrees and leaves a fresh stub; rollback undoes it" {
  full_move
  mh verify >/dev/null
  run mh finish --brain brainhost
  [ "$status" -eq 0 ]
  arch="$(awk -F'\t' '$1 == "archived" { print $2 }' <<<"$output")"
  [ -d "$arch/tasks/$A" ] && [ -d "$CH/tasks" ] && [ -z "$(ls "$CH/tasks")" ]
  [ "$(cat "$CH/config")" = "$(cat "$arch/config")" ]
  git -C "$C/work/proj" worktree list --porcelain | grep -q '^locked'
  run mh rollback
  [ "$status" -eq 0 ]
  [ -f "$CH/tasks/$A/meta.json" ] && [ ! -d "$arch" ]
  ! git -C "$C/work/proj" worktree list --porcelain | grep -q '^locked'
}

@test "snapshot: a tar of the home on both sides, without worktrees" {
  fixture
  run mh snapshot
  [ "$status" -eq 0 ]
  c="$(find "$T/snaps" -path '*/client/home.tgz')"; b="$(find "$T/snaps" -path '*/brain/home.tgz')"
  [ -f "$c" ] && [ -f "$b" ]
  tar -tzf "$c" | grep -q "home/tasks/$A/meta.json"
  ! tar -tzf "$c" | grep -q '/worktrees/'
}

core_up() { # a listening socket where the fake hc core's lock file says (as in park.bats)
  local d="$XDG_STATE_HOME/herdr-core/default" i
  CORE_DIR="$(mktemp -d /tmp/crmg.XXXXXX)"; SOCK="$CORE_DIR/s"
  mkdir -p "$d"; printf '%s\n' "$SOCK" >"$d/core.lock"
  perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 5) or die "$!"; while (my $c = $s->accept) { close $c }' "$SOCK" 3>&- &
  echo $! >"$T/core.pid"
  for i in $(seq 1 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  return 1
}
teardown() {
  [[ -f "${T:-/nonexistent}/core.pid" ]] && kill "$(cat "$T/core.pid")" 2>/dev/null
  [[ -n "${CORE_DIR:-}" ]] && rm -rf "$CORE_DIR"
  return 0
}

@test "a steer resumes a moved, parked task on the brain: its worktree rebuilt, then the same session" {
  fixture
  mh triage >/dev/null
  awk -F'\t' -v OFS='\t' -v a="$A" '$1 == a { $2 = "keep" } { print }' "$(S)/decisions.tsv" >"$T/dec.tsv"
  frz >/dev/null; mh settle --decisions "$T/dec.tsv" >/dev/null; mh move >/dev/null
  BW="$(bmeta "$A" .worktree)"; sid="$(bmeta "$A" .session_id)"
  [ ! -e "$BW" ]
  use_fake hc herdr-app claude
  export FAKE_HC_DIR="$T/hc" FAKE_HERDR_APP_DIR="$T/app" CHARTROOM_PS_FILE="$T/ps" FAKE_HC_EXITED=1
  mkdir -p "$FAKE_HC_DIR" "$FAKE_HERDR_APP_DIR"; : >"$CHARTROOM_PS_FILE"
  core_up
  run on_b steer "$A" "you moved to the brain; carry on"
  [ "$status" -eq 0 ]
  [ -d "$BW" ]
  [ "$(git -C "$BW" status --porcelain | sort)" = "$(git -C "$W" status --porcelain | sort)" ]
  grep -q "worktree $BW rebuilt" "$BH/tasks/$A/events.log"
  grep -q "note: revived (session $sid" "$BH/tasks/$A/events.log"
  grep -q -- "--resume $sid " "$BH/tasks/$A/launch.sh"
}

@test "settle: a close of a task with commits pushed nowhere bundles them here first" {
  fixture
  E="$(ctask "closed with a local commit")"; on_c worktree "$E" >/dev/null
  WE="$(jq -r .worktree "$CH/tasks/$E/meta.json")"
  echo s >"$WE/s.txt"; git -C "$WE" add s.txt; git -C "$WE" commit -qm "local only"
  head="$(git -C "$WE" rev-parse HEAD)"
  printf '%s done: finished\n' "2026-01-02T00:00:00Z" >>"$CH/tasks/$E/events.log"
  mh triage >/dev/null
  printf '%s\taccept\n' "$E" >"$T/dec.tsv"
  frz >/dev/null; mh settle --decisions "$T/dec.tsv" >/dev/null
  [ -n "$(jq -r '.closed // ""' "$CH/tasks/$E/meta.json")" ]
  grep -q 'note: accepted' "$CH/tasks/$E/events.log"
  mh move >/dev/null
  [ -f "$BH/tasks/$E/migrate/branch.bundle" ]
  git -C "$B/work/proj" bundle list-heads "$BH/tasks/$E/migrate/branch.bundle" | grep -q "^$head "
}

@test "reap: only after 14 days, and a dirty worktree inside the renamed home keeps it" {
  fixture
  # A task whose worktree lives inside the home (its project does not ignore .worktrees/).
  git clone -q "$T/remote.git" "$C/work/inhome"; git clone -q "$T/remote.git" "$B/work/inhome"
  F="$(on_c new --project "$C/work/inhome" --title "in the home" --backend hc:claude | sed -n 's/^id=//p')"
  cmeta "$F" '.dispatched = "2026-01-01T00:00:00Z"'
  on_c worktree "$F" >/dev/null
  WF="$(jq -r .worktree "$CH/tasks/$F/meta.json")"; [[ "$WF" == "$CH"/worktrees/* ]]
  echo wip >"$WF/wip.txt"
  mh triage >/dev/null; frz >/dev/null; mh settle >/dev/null; mh move >/dev/null; mh verify >/dev/null
  mh finish --brain brainhost >/dev/null
  arch="$(dirname "$CH")/.migrated/$(basename "$CH")-$(jq -r .stamp "$(S)/state.json")"
  [ -f "$arch/${WF#"$CH"/}/wip.txt" ]
  run mh reap --apply
  [ "$status" -ne 0 ]; [[ "$output" == *"rollback window is 14 days"* ]]
  jq '.at.finish = "2020-01-01T00:00:00Z"' "$(S)/state.json" >"$T/st" && mv "$T/st" "$(S)/state.json"
  run mh reap --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept-dirty"* ]]
  [ -d "$arch" ] && [ -f "$arch/${WF#"$CH"/}/wip.txt" ]
}

@test "move: a home only the client has is made here and registered" {
  fixture
  NB="$B/newhome"
  m() { CHARTROOM_HOME="$BH" cr migrate-home "$1" --from local --home app --client-home "$CH" --brain-home "$NB" --no-prs "${@:2}"; }
  m triage >/dev/null; m snapshot >/dev/null; m freeze >/dev/null; m settle >/dev/null
  run m move
  [ "$status" -eq 0 ]
  [ -f "$NB/AGENTS.md" ] && [ -f "$NB/tasks/$A/meta.json" ]
  CHARTROOM_HOME="$BH" cr homes path app | grep -qx "$NB"
}

@test "materialize never adopts another worktree that sits at the recorded path" {
  fixture
  mh triage >/dev/null
  awk -F'\t' -v OFS='\t' -v a="$A" '$1 == a { $2 = "keep" } { print }' "$(S)/decisions.tsv" >"$T/dec.tsv"
  frz >/dev/null; mh settle --decisions "$T/dec.tsv" >/dev/null; mh move >/dev/null
  BW="$(bmeta "$A" .worktree)"
  git -C "$B/work/proj" worktree add -q -b someone-else "$BW" main
  run on_b migrate-home materialize "$A"
  [ "$status" -ne 0 ]; [[ "$output" == *"is another worktree"* ]]
  [ "$(git -C "$BW" symbolic-ref --short HEAD)" = someone-else ]
}

@test "resync: what the client did after the move comes over; a task the brain changed is kept; verify passes" {
  full_move
  mh verify >/dev/null
  # The client goes on: an event, a grown transcript, a new task, an inbox item, a ruling.
  printf '%s progress: one more thing on the client\n' "2026-01-09T00:00:00Z" >>"$CH/tasks/$A/events.log"
  sid="$(jq -r .session_id "$CH/tasks/$A/meta.json")"
  printf '{"type":"assistant","sessionId":"%s"}\n' "$sid" >>"$C/claude/projects/${W//[^A-Za-z0-9]/-}/$sid.jsonl"
  mv "$CH/.migrating" "$T/m.bak"; N="$(ctask "made during the freeze")"; mv "$T/m.bak" "$CH/.migrating"   # a client without the guard
  awk '{print} /^## Waiting on the commander$/ {print "- [i-c002] 2026-01-09 — [proj] a later client question"}' "$CH/inbox.md" >"$CH/inbox.md.t" && mv "$CH/inbox.md.t" "$CH/inbox.md"
  echo '2026-01-09T00:00:00Z [r-0009] topic=late supersedes=- src=chat :: a ruling made after the move' >>"$CH/rulings.log"
  # The brain changed the closed task Z since the move (its log grew here): it must be left alone.
  printf '%s note: touched on the brain\n' "2026-01-09T00:00:00Z" >>"$BH/tasks/$Z/events.log"
  printf '%s note: and on the client\n' "2026-01-09T00:00:00Z" >>"$CH/tasks/$Z/events.log"
  run mh resync
  [ "$status" -eq 0 ]
  grep -q 'one more thing on the client' "$BH/tasks/$A/events.log"
  [ "$(grep -c 'note: migrated from' "$BH/tasks/$A/events.log")" -eq 1 ]
  [ -f "$BH/tasks/$N/meta.json" ] && [ "$(bmeta "$N" .migrated_from)" = local ]
  grep -q 'i-c002' "$BH/inbox.md" && grep -q 'i-b001' "$BH/inbox.md"
  grep -q 'r-0009' "$BH/rulings.log"
  t="$B/claude/projects/${W//[^A-Za-z0-9]/-}"; t="${t/$C/$B}"
  BW="$(bmeta "$A" .worktree)"; tb="$B/claude/projects/${BW//[^A-Za-z0-9]/-}/$sid.jsonl"
  [ "$(wc -l <"$tb")" -eq 2 ]
  grep -q 'touched on the brain' "$BH/tasks/$Z/events.log"; ! grep -q 'and on the client' "$BH/tasks/$Z/events.log"
  [[ "$output" == *"resynced"* ]]
  awk -F'\t' -v z="$Z" '$2 == z && $3 == "resync-conflict"' "$(S)/ledger.tsv" | grep -q .
  # Verify now checks the new baseline: Z's client log moved on, so its record differs, and says so.
  run mh verify
  [[ "$output" == *"PASS git and conversations"* ]]
  [[ "$output" == *"$Z: events.log does not start with the client's log"* || "$output" == *"PASS records"* ]]
}
