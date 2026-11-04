#!/usr/bin/env bats
# The change stamp (lib/core.sh stamp_changed): every chartroom write of what the board shows
# rewrites <home>/.changed once the write is on disk, so a view polling the board (crew-view's
# band) can stat it instead of running `board` every round; nothing that only reads touches it.
# Each check removes the stamp first and looks for it after, so the filesystem's mtime
# resolution never matters.

load test_helper
setup() {
  common_setup
  A="$BATS_TEST_TMPDIR/acme"; B="$BATS_TEST_TMPDIR/globex"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$B" cr init --name globex >/dev/null
  export CHARTROOM_HOME="$A"
  MSG="$BATS_TEST_TMPDIR/msg.md"; printf 'a draft\n' >"$MSG"
}

# moves <home> <command...>: the command rewrites that home's stamp. still: it does not.
moves() {
  local s="$1/.changed"; shift
  rm -f "$s"; "$@" >/dev/null || { echo "failed: $*" >&2; return 1; }
  [[ -f "$s" ]] || { echo "did not move $s: $*" >&2; return 1; }
}
still() {
  local s="$1/.changed"; shift
  rm -f "$s"; "$@" >/dev/null || { echo "failed: $*" >&2; return 1; }
  [[ ! -e "$s" ]] || { echo "moved $s: $*" >&2; return 1; }
}

@test "every write of task state moves the home's change stamp: events, meta, inbox, focus, artifacts, accept, close" {
  local id tag
  rm -f "$A/.changed"
  id="$(new_task)"
  [ -f "$A/.changed" ]
  moves "$A" cr event "$id" progress "halfway"
  moves "$A" "$CHARTROOM" hook "$id" stop </dev/null
  rm -f "$A/.changed"; tag="$(cr inbox add --project shop "which region?")"; [ -f "$A/.changed" ]
  moves "$A" cr inbox project "$tag" billing
  # an inbox item's artifact logs no event: the artifact itself moves the stamp
  moves "$A" cr artifact add "$tag" --kind note --title "Draft" "$MSG"
  moves "$A" cr artifact done "$tag/draft"
  moves "$A" cr todo done "$tag"
  moves "$A" cr focus shop
  moves "$A" cr focus off
  local d="$A/tasks/$id"
  jq '. + {dispatched: "2026-01-02T10:00:00Z"}' "$d/meta.json" >"$d/m" && mv "$d/m" "$d/meta.json"
  moves "$A" cr event "$id" done "finished"
  moves "$A" cr accept "$id"
  moves "$A" cr close "$id"
  [ "$(od -An -c "$A/.changed" | tr -d ' ')" = . ]
}

@test "a relay moves the target home's stamp, an ack the receiving home's; the sender's board is unchanged" {
  local rid
  rm -f "$A/.changed" "$B/.changed"
  rid="$(cr relay globex "heads up")"
  [ -f "$B/.changed" ]
  [ ! -e "$A/.changed" ]
  CHARTROOM_HOME="$B" moves "$B" cr relay ack "$rid"
}

@test "reading never moves the stamp: board, dashboard --json, status, show, todo, inbox list, artifact list" {
  local id
  id="$(new_task)"
  cr inbox add "which region?" >/dev/null
  still "$A" cr board --json
  still "$A" cr dashboard --json
  still "$A" cr status --json --all
  still "$A" cr show "$id" --json
  still "$A" cr todo --json
  still "$A" cr inbox list --json
  still "$A" cr artifact list --all --json
}
