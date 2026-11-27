#!/usr/bin/env bats
# Several homes on one machine: a home's own config, the list of homes (`chartroom homes`,
# `init --name`), finding the home from the current directory, and the read-only view across
# homes (`--all-homes`).

load test_helper
setup() {
  common_setup
  HOMES="$BATS_TEST_TMPDIR/homes" # next to CHARTROOM_CONFIG
  A="$BATS_TEST_TMPDIR/acme"; B="$BATS_TEST_TMPDIR/globex"
}

@test "a home's own config wins over the config file, and the environment over both" {
  cr init >/dev/null
  printf 'CHARTROOM_WORKSPACE=from-file\nCHARTROOM_BRANCH_PREFIX=file/\n' >"$CHARTROOM_CONFIG"
  printf '# this home\nCHARTROOM_WORKSPACE = "from-home"\r\nCHARTROOM_HOME=/not/here\n' >"$CHARTROOM_HOME/config"
  run cr doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspace, .home_config, .home' <<<"$output" | tr '\n' ' ')" = "from-home $CHARTROOM_HOME/config $CHARTROOM_HOME " ]
  [ "$(CHARTROOM_WORKSPACE=from-env cr doctor --json | jq -r .workspace)" = from-env ]
  # a key the home leaves alone still comes from the file
  id="$(new_task --kind ship)"
  [ "$(meta_of "$id" branch)" = "file/$id" ]
  run cr doctor
  [[ "$output" == *"config:   $CHARTROOM_CONFIG"*"$CHARTROOM_HOME/config (this home's own; wins over the file above)"* ]]
  [[ "$output" == *"workspace: from-home"* ]]
}

@test "init --name writes the home's workspace, registers it; no dashboard port any more" {
  run env CHARTROOM_HOME="$A" "$CHARTROOM" init --name acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace acme-crew)"*"registered home acme"* ]]
  grep -qx 'CHARTROOM_WORKSPACE=acme-crew' "$A/config"
  ! grep -q DASHBOARD_PORT "$A/config"
  [ "$(grep -v '^#' "$HOMES")" = "acme=$A" ]
  CHARTROOM_HOME="$B" cr init --name globex --workspace gx >/dev/null
  grep -qx 'CHARTROOM_WORKSPACE=gx' "$B/config"
  ! grep -q DASHBOARD_PORT "$B/config"
  # again: idempotent, the config is not rewritten
  cp "$A/config" "$BATS_TEST_TMPDIR/cfg-before"
  run env CHARTROOM_HOME="$A" "$CHARTROOM" init --name acme
  [ "$status" -eq 0 ]; [[ "$output" == *"home acme: already registered"* ]]
  cmp "$A/config" "$BATS_TEST_TMPDIR/cfg-before"
  [ "$(grep -c '^acme=' "$HOMES")" -eq 1 ]
  # a taken name, another name for a registered home, a home inside another, a bad name:
  # refused before anything is created
  run env CHARTROOM_HOME="$BATS_TEST_TMPDIR/third" "$CHARTROOM" init --name acme
  [ "$status" -ne 0 ]; [[ "$output" == *"a home named acme is already registered"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/third" ]
  run env CHARTROOM_HOME="$A" "$CHARTROOM" init --name other
  [ "$status" -ne 0 ]; [[ "$output" == *"already registered as home acme"* ]]
  run env CHARTROOM_HOME="$A/inner" "$CHARTROOM" init --name inner
  [ "$status" -ne 0 ]; [[ "$output" == *"lies inside home acme"* ]]
  [ ! -e "$A/inner" ]
  run env CHARTROOM_HOME="$BATS_TEST_TMPDIR/x" "$CHARTROOM" init --name Bad_Name
  [ "$status" -ne 0 ]; [[ "$output" == *"a home's name is lowercase"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/x" ]
  # a relative home is registered by its full path
  run bash -c 'cd "$1" && CHARTROOM_HOME=rel "$2" init --name rel' _ "$BATS_TEST_TMPDIR" "$CHARTROOM"
  [ "$status" -eq 0 ]
  grep -qx "rel=$BATS_TEST_TMPDIR/rel" "$HOMES"
}

@test "homes: list, add without writing in the home, path, rm, and the warnings" {
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/legacy/tasks/old-1"
  echo '{"id":"old-1"}' >"$BATS_TEST_TMPDIR/legacy/tasks/old-1/meta.json"
  before="$(snapshot "$BATS_TEST_TMPDIR/legacy")"
  run cr homes add legacy "$BATS_TEST_TMPDIR/legacy"
  [ "$status" -eq 0 ]; [[ "$output" == *"registered home legacy: $BATS_TEST_TMPDIR/legacy (in $HOMES; nothing in the home changed)"* ]]
  [ "$(snapshot "$BATS_TEST_TMPDIR/legacy")" = "$before" ]
  [ "$(cr homes path legacy)" = "$BATS_TEST_TMPDIR/legacy" ]
  run cr homes path nope
  [ "$status" -ne 0 ]; [[ "$output" == *"no home named nope"* ]]
  # the list, from acme: acme is the current one; legacy has the defaults and one open task
  run env CHARTROOM_HOME="$A" "$CHARTROOM" homes --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | [.name, .current, .workspace, .open, .brain]]' <<<"$output")" = '[["acme",true,"acme-crew",0,null],["legacy",false,"chartroom-crew",1,null]]' ]
  run env CHARTROOM_HOME="$A" "$CHARTROOM" homes
  [[ "${lines[0]}" =~ ^NAME\ +PATH\ +WORKSPACE\ +OPEN$ ]]; [[ "$output" == *"*acme"*"acme-crew"* ]]
  [[ "$output" != *warning* ]]
  # this home, when it is not registered, is listed and said to be
  run cr homes
  [[ "$output" == *"(this home)"* && "$output" == *"this home ($CHARTROOM_HOME) is not registered"* ]]
  # a shared workspace and a missing path are warned about
  printf 'CHARTROOM_WORKSPACE=acme-crew\n' >"$BATS_TEST_TMPDIR/legacy/config"
  echo "gone=$BATS_TEST_TMPDIR/nowhere" >>"$HOMES"
  run env CHARTROOM_HOME="$A" "$CHARTROOM" homes
  [[ "$output" == *"warning: homes acme, legacy share the workspace acme-crew"* ]]
  [[ "$output" == *"warning: home gone: $BATS_TEST_TMPDIR/nowhere does not exist"* ]]
  # rm unregisters only
  run cr homes rm legacy
  [ "$status" -eq 0 ]; [[ "$output" == *"unregistered home legacy"*"untouched"* ]]
  [ -d "$BATS_TEST_TMPDIR/legacy/tasks/old-1" ]
  ! grep -q '^legacy=' "$HOMES"
  grep -q '^acme=' "$HOMES"
  run cr homes add Legacy "$BATS_TEST_TMPDIR/legacy"
  [ "$status" -ne 0 ]
}

@test "a session in a registered home's directory resolves that home without CHARTROOM_HOME" {
  printf 'CHARTROOM_HOME=%s\n' "$BATS_TEST_TMPDIR/default" >"$CHARTROOM_CONFIG"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  mkdir -p "$A/tasks/sub" "$BATS_TEST_TMPDIR/acme-two"
  # ~ in the homes file is the user's home
  mkdir -p "$HOME/chartroom/globex/tasks"; echo "globex=~/chartroom/globex" >>"$HOMES"
  for d in "$A" "$A/tasks/sub"; do
    run bash -c 'cd "$1" && unset CHARTROOM_HOME && "$2" doctor --json' _ "$d" "$CHARTROOM"
    [ "$(jq -r '.home, .home_source, .workspace' <<<"$output" | tr '\n' '|')" = "$A|registered home acme, from the current directory|acme-crew|" ]
  done
  run bash -c 'cd "$1" && unset CHARTROOM_HOME && "$2" doctor --json' _ "$HOME/chartroom/globex" "$CHARTROOM"
  [ "$(jq -r .home <<<"$output")" = "$HOME/chartroom/globex" ]
  # a sibling whose name only starts the same is not inside it; the config decides there
  run bash -c 'cd "$1" && unset CHARTROOM_HOME && "$2" doctor --json' _ "$BATS_TEST_TMPDIR/acme-two" "$CHARTROOM"
  [ "$(jq -r '.home, .home_source' <<<"$output" | tr '\n' '|')" = "$BATS_TEST_TMPDIR/default|config|" ]
  # the environment still wins
  run bash -c 'cd "$1" && "$2" doctor --json' _ "$A" "$CHARTROOM"
  [ "$(jq -r .home <<<"$output")" = "$CHARTROOM_HOME" ]
}

@test "--all-homes: status, inbox list, todo and board across homes, labelled, read-only" {
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$B" cr init --name globex >/dev/null
  CHARTROOM_HOME="$A" cr inbox add --project shop "which region?" >/dev/null
  id="$(CHARTROOM_HOME="$B" cr new --project "$PROJECT" --title "look around" --kind scout | sed -n 's/^id=//p')"
  before="$(snapshot "$A" "$B")"
  run env CHARTROOM_HOME="$A" "$CHARTROOM" status --all-homes
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "== acme · $A (this home)" ]
  [[ "$output" == *"inbox: 1 waiting on the commander"*"== globex · $B"*"$id"*"drafting"* ]]
  run env CHARTROOM_HOME="$A" "$CHARTROOM" status --all-homes --json
  [ "$(jq -c '[.[] | [.home, .current, (.result | length)]]' <<<"$output")" = '[["acme",true,0],["globex",false,1]]' ]
  [ "$(jq -r '.[1].result[0].id, .[1].path' <<<"$output" | tr '\n' ' ')" = "$id $B " ]
  run env CHARTROOM_HOME="$B" "$CHARTROOM" inbox list --all-homes
  [[ "$output" == *"== acme · $A"*"[shop] which region?"*"== globex · $B (this home)"*"inbox: nothing open"* ]]
  [ "$(CHARTROOM_HOME="$B" cr inbox list --all-homes --json | jq -r '.[0].result.waiting[0].text')" = "which region?" ]
  [ "$(CHARTROOM_HOME="$B" cr todo --all-homes --json | jq -c '[.[] | [.home, (.result.items | length)]]')" = '[["acme",1],["globex",0]]' ]
  [ "$(CHARTROOM_HOME="$B" cr board --all-homes --json | jq -r '.[1].result.home_name')" = globex ]
  [ "$(snapshot "$A" "$B")" = "$before" ]
  # a home that cannot be read is said so, and the rest still printed
  echo "gone=$BATS_TEST_TMPDIR/nowhere" >>"$HOMES"
  run env CHARTROOM_HOME="$A" "$CHARTROOM" status --all-homes
  [ "$status" -eq 1 ]
  [[ "$output" == *"== globex"*"== gone · $BATS_TEST_TMPDIR/nowhere"*"(could not read it: not a chartroom home"* ]]
  # only the view takes the flag; acting on one home refuses it, and an event's text is text
  run env CHARTROOM_HOME="$A" "$CHARTROOM" todo done i-1234 --all-homes
  [ "$status" -ne 0 ]; [[ "$output" == *"acts on one home"* ]]
  run env CHARTROOM_HOME="$B" "$CHARTROOM" event "$id" progress added the --all-homes flag
  [ "$status" -eq 0 ]
  CHARTROOM_HOME="$B" events "$id" | grep -q 'progress: added the --all-homes flag'
}

@test "inbox list: the open items, or that nothing is open" {
  cr init >/dev/null
  run cr inbox list
  [ "$status" -eq 0 ]; [ "$output" = "inbox: nothing open" ]
  t="$(cr inbox add --project shop "which region?")"
  run cr inbox list
  [ "${lines[0]}" = "Waiting on the commander:" ]
  [[ "${lines[1]}" == "- [$t] "*" — [shop] which region?" ]]
  [ "$(cr inbox list --json | jq -r '.waiting[0].short_id')" = "$t" ]
}
