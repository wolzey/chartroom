#!/usr/bin/env bats
# Placement (lib/place.sh): dispatch sends a task to the node with the most room under its CPU and
# memory limits. The devices here are registry files with a canned heartbeat and a stand-in that
# answers their commands; the whole path with a real app server and agent is in test/device.bats.

load test_helper

setup() {
  common_setup
  use_fake sysctl vm_stat
  export CHARTROOM_MACHINE_NAME=studio CHARTROOM_NODES=none CHARTROOM_TAILSCALE=none
  export FAKE_NODE_DIR="$BATS_TEST_TMPDIR/fake"; fake_use "$FAKE_NODE_DIR" "$XDG_STATE_HOME" 20 30
  export CHARTROOM_NODE_CONFIG="$BATS_TEST_TMPDIR/nodecfg"
  export CHARTROOM_NODE_BACKENDS='hc:claude|hc:codex|command' CHARTROOM_COMMAND="$STUB {id}" STUB_MODE=silent
  cr init >/dev/null; cr homes add acme "$CHARTROOM_HOME" >/dev/null
  cr node init --cpu 80 --mem 75 --battery allow --project-roots "" >/dev/null
  # the project, with a remote another machine can have a checkout of (its URL stands for a local bare)
  git clone -q --bare "$PROJECT" "$BATS_TEST_TMPDIR/origin.git"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$BATS_TEST_TMPDIR/origin.git.insteadOf" GIT_CONFIG_VALUE_0=https://git.example/acme/proj
  git -C "$PROJECT" remote add origin https://git.example/acme/proj; git -C "$PROJECT" fetch -q origin
  git -C "$PROJECT" remote set-head origin main
  FLEET="$BATS_TEST_TMPDIR/fleet"; mkdir -p "$FLEET/devices"
  # the endpoint, as the app server leaves it (lib/fleet.sh asks ps that it is one)
  bash -c 'exec -a "python3 lib/app/server.py" sleep 300' 3>&- & EP=$!
  echo "$EP $(( $(date +%s) - 3600 ))" >"$FLEET/endpoint"
}
# a live hc core's socket where hc looks (never accepted on: it only has to connect)
hc_core_up() {
  use_fake hc; export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"; mkdir -p "$FAKE_HC_DIR"
  unset HC_SOCKET HC_SESSION
  CORE_SOCK="/tmp/crpl.$$.$RANDOM"
  perl -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 128) or die "$!"; sleep 120' "$CORE_SOCK" 3>&- & CORE_PID=$!
  local i; for i in $(seq 1 40); do [[ -S "$CORE_SOCK" ]] && break; sleep 0.05; done
  mkdir -p "$XDG_STATE_HOME/herdr-core/default"; echo "$CORE_SOCK" >"$XDG_STATE_HOME/herdr-core/default/core.lock"
}
teardown() { local p; [[ -z "${CORE_SOCK:-}" ]] || rm -f "$CORE_SOCK"; for p in ${EP:-} ${ANSWER:-} ${CORE_PID:-}; do kill "$p" 2>/dev/null || true; done; }

M3=n-00000000000a; M5=n-00000000000b
# an enrolled device and its last heartbeat: 10 cores, 100 GB, online, able to take work
seed() { # <name> <id> <cpu> <mem> [cpu limit 90] [mem limit 75]
  jq -cn --arg id "$2" --arg n "$1" '{id: $id, name: $n, aliases: [], host: $n, hw_uuid: $n, enrolled: "2026-01-01T00:00:00Z", token_sha256: "x"}' >"$FLEET/devices/$2.json"
  {
    printf 'probe_schema\t1\nhost\t%s\nos\tDarwin\t26\nmodel\tMac\nclock\t%s\ncores\t10\ncores_perf\t8\ncores_eff\t2\nmem_bytes\t107374182400\nload\t1\t1\t1\n' "$1" "$(date +%s)"
    printf 'cpu_use\t%s\t60\nmem_used_pct\t%s\ndisk_free_pct\t50\npower\tac\nbattery_pct\t100\ninitialised\t1\nconfig\t/n\n' "$3" "$4"
    printf 'budget\tcpu\t%s\nbudget\tmem\t%s\nbudget\ton_battery\tpause\nbudget\taccept\ton\nrunner\thc\tup\t1\ncontext\tcore\n' "${5:-90}" "${6:-75}"
    printf 'tool\tclaude\tok\t2\ntool\tcodex\tok\t1\ntool\tgh\tok\t2\ntool\tdocker\tdown\t-\ntool\truby\tok\t3\nlogin\tclaude\tok\t-\nlogin\tcodex\tok\t-\nlogin\tgh\tok\t-\n'
    printf 'checkouts\t1\ncheckout\tgit.example/acme/proj\t/there/proj\t-\n'
  } >"$BATS_TEST_TMPDIR/$1.probe"
  beat "$1" "$2"
}
beat() { # <name> <id> [caps json]: its heartbeat, now, from <name>.probe
  local caps="${3:-}"; [[ -n "$caps" ]] || caps='["commands","update","dispatch","limits","place"]'
  jq -cn --rawfile p "$BATS_TEST_TMPDIR/$1.probe" --argjson c "$caps" --argjson t "$(date +%s)" \
    '{last_seen: $t, clock: $t, version: "0", protocol: 1, probe: $p, rev: null, caps: $c, tasks: {}}' >"$FLEET/devices/$2.seen.json"
}
tweak() { sed -i.bak -e "$3" "$BATS_TEST_TMPDIR/$1.probe"; beat "$1" "$2"; } # <name> <id> <sed>
# the devices, answering every command at once: rc 0, or <id>'s own rc and words in $BATS_TEST_TMPDIR/<id>.answer
answering() {
  ( while sleep 0.1; do
      for f in "$FLEET"/queue/*/*.json; do
        [[ -f "$f" ]] || continue
        c="$(basename "$f" .json)"; d="$(basename "$(dirname "$f")")"; mkdir -p "$FLEET/results" "$BATS_TEST_TMPDIR/taken"
        cp "$f" "$BATS_TEST_TMPDIR/taken/$d.$c.json"; rm -f "$f"
        a='{"rc":0,"out":"ok","err":""}'; [[ -f "$BATS_TEST_TMPDIR/$d.answer" ]] && a="$(cat "$BATS_TEST_TMPDIR/$d.answer")"
        printf '%s' "$a" >"$FLEET/results/$c.json.tmp"; mv "$FLEET/results/$c.json.tmp" "$FLEET/results/$c.json"
      done
    done ) 3>&- >/dev/null 2>&1 & ANSWER=$!
}
where() { meta_of "$1" node; } # a placed task's device, or nothing (here)
dry() { run cr dispatch "$1" --dry-run; echo "$output"; }

@test "placement: the node with the most room takes it; with no device that can, everything is as before" {
  id="$(new_task --backend command)"
  dry "$id"
  [[ "$output" == "$id would run here, as command (not placed)" ]]
  seed m3 $M3 5 10
  dry "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == "$id would run on m3. studio: cpu 20% of 80%, memory 30% of 75%; m3: cpu 5% of 90%, memory 10% of 75%" ]]
  # nothing was recorded by a dry run
  [ -z "$(meta_of "$id" node)" ] && [ ! -e "$FLEET/placed" ]
  # whichever of the two numbers is nearer its limit counts: m3 idle but its memory nearly full
  tweak m3 $M3 $'s/^mem_used_pct\t.*/mem_used_pct\t70/'
  dry "$id"
  [[ "$output" == "$id would run here, as command. "* ]]
  # each against its own limits: the same use, a lower limit, less room
  tweak m3 $M3 $'s/^mem_used_pct\t.*/mem_used_pct\t30/; s/^cpu_use\t.*/cpu_use\t20\t60/; s/^budget\tcpu\t.*/budget\tcpu\t50/'
  dry "$id"
  [[ "$output" == "$id would run here"* ]]
  tweak m3 $M3 $'s/^budget\tcpu\t.*/budget\tcpu\t100/'
  dry "$id"
  [[ "$output" == "$id would run on m3"* ]]
  # pack: the fullest that has room; local: off
  run env CHARTROOM_PLACEMENT=pack "$CHARTROOM" dispatch "$id" --dry-run
  [[ "$output" == "$id would run here"* ]]
  run env CHARTROOM_PLACEMENT=local "$CHARTROOM" dispatch "$id" --dry-run
  [[ "$output" == *"(not placed)" ]]
  run env CHARTROOM_PLACEMENT=sideways "$CHARTROOM" dispatch "$id" --dry-run
  [ "$status" -ne 0 ]
  # a guest home (the work of another brain) never places
  run env CHARTROOM_GUEST=1 "$CHARTROOM" dispatch "$id" --dry-run
  [[ "$output" == *"(not placed)" ]]
}

@test "placement: a node at or over either limit takes nothing new, this machine too; worker counts gate nothing" {
  seed m3 $M3 90 10; seed m5 $M5 5 75
  id="$(new_task --backend command)"
  dry "$id"
  [[ "$output" == "$id would run here"* ]]
  [[ "$output" == *"m3: cpu 90% of 90%, memory 10% of 75% (cpu 90% in use, its limit is 90%)"* ]]
  [[ "$output" == *"m5: cpu 5% of 90%, memory 75% of 75% (memory 75% in use, its limit is 75%)"* ]]
  fake_use "$FAKE_NODE_DIR" "$XDG_STATE_HOME" 81 30
  run cr dispatch "$id"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no node can take $id now"*"studio: cpu 81% of 80%"* ]]
  [ -z "$(meta_of "$id" dispatched)" ] && [ ! -e "$FLEET/placed/acme.$id.json" ]
  events "$id" | grep -q " note: not dispatched: no node can take it now"
  # --over-limit is the override
  run cr dispatch "$id" --over-limit
  echo "$output"
  [ "$status" -eq 0 ]
  # under its limit, but one more worker would go over it: not taken either
  fake_use "$FAKE_NODE_DIR" "$XDG_STATE_HOME" 70 30
  id2="$(new_task --backend command)"
  dry "$id2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"studio: cpu 70% of 80%, memory 30% of 75% (cpu 70% in use and about 15% for this worker"*"is over its 80% limit)"* ]]
  # this machine when its use cannot be read: the last resort, never a stop to all work here
  mv "$FAKE_NODE_DIR/vm_stat" "$FAKE_NODE_DIR/vm_stat.off"
  dry "$id2"; [[ "$output" == "$id2 would run here"*"studio: cpu 70% of 80%, memory ? of 75%;"* ]]
  mv "$FAKE_NODE_DIR/vm_stat.off" "$FAKE_NODE_DIR/vm_stat"
  # ninety workers on a machine with room change nothing
  tweak m3 $M3 $'s/^cpu_use\t.*/cpu_use\t10\t60/; $a\\\nagents_live\t90\\\ncrew_live\t90'
  dry "$id2"
  [[ "$output" == "$id2 would run on m3"* ]]
}

@test "placement: a burst spreads by what each was just given, and stops at the limits, before any number moves" {
  seed m3 $M3 5 10; answering
  local got=""
  for i in 1 2 3 4 5 6 7 8 9; do
    id="$(TITLE="burst $i" new_task --backend command)"
    cr dispatch "$id" >/dev/null
    if [[ "$(where "$id")" == "$M3" ]]; then got+="m"; else got+="s"; fi
  done
  # 15% of CPU a worker: m3 20..80 of 90, the studio 35..80 of 80, the emptier against its limit each time
  echo "$got"
  [ "$got" = mmsmsmsms ]
  id="$(TITLE="burst 10" new_task --backend command)"
  run cr dispatch "$id"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"and 5 just placed"* && "$output" == *"and 4 just placed"* ]]
  # once a hold has run out, only what is measured counts
  run env CHARTROOM_PLACE_HOLD_SECONDS=0 "$CHARTROOM" dispatch "$id" --dry-run
  sleep 1.1
  run env CHARTROOM_PLACE_HOLD_SECONDS=0 "$CHARTROOM" dispatch "$id" --dry-run
  [[ "$output" == "$id would run on m3"* ]]
}

@test "placement: a burst from several shells at once is counted under one lock" {
  seed m3 $M3 5 10; answering
  ids=(); for i in 1 2 3 4 5 6; do ids+=("$(TITLE="par $i" new_task --backend command)"); done
  pids=(); for id in "${ids[@]}"; do ( cr dispatch "$id" >"$BATS_TEST_TMPDIR/$id.out" 2>&1 ) & pids+=($!); done
  wait "${pids[@]}"
  m=0; for id in "${ids[@]}"; do [[ "$(where "$id")" == "$M3" ]] && m=$((m + 1)); done
  cat "$BATS_TEST_TMPDIR"/*.out
  [ "$m" = 4 ]
  [ "$(ls "$FLEET/placed" | wc -l | tr -d ' ')" = 6 ]
}

@test "placement: what a node lacks keeps the task off it; Docker from --needs, projects.md, or the brief's own words" {
  seed m3 $M3 5 10
  tool_ok() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
  tool_ok docker 'echo 29.1'; tool_ok ruby 'printf 3.3'
  id="$(new_task --backend command --needs docker)"
  dry "$id"
  [[ "$output" == "$id would run here"*"m3: "*"(docker is down)"* ]]
  id="$(new_task --backend command)"; dry "$id"; [[ "$output" == *"run on m3"* ]]
  perl -0pi -e 's/Please do the thing\./Bring the stack up with docker compose./' "$CHARTROOM_HOME/tasks/$id/brief.md"
  dry "$id"; [[ "$output" == *"would run here"*"docker is down"* ]]
  cr set "$id" needs=none >/dev/null; dry "$id"; [[ "$output" == *"run on m3"* ]]
  cr set "$id" needs=ruby >/dev/null; dry "$id"; [[ "$output" == *"would run here"*"docker is down"* ]]
  perl -0pi -e 's/docker compose/make/' "$CHARTROOM_HOME/tasks/$id/brief.md"; dry "$id"; [[ "$output" == *"run on m3"* ]]
  printf -- '- proj: base=main; needs=ruby,docker; notes=x\n' >>"$CHARTROOM_HOME/projects.md"
  dry "$id"; [[ "$output" == *"would run here"*"docker is down"* ]]
  # and this machine is a node like any other: without docker it does not take it either
  tool_ok docker 'exit 1'; dry "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"studio: "*"(docker is down)"* ]]
  run cr new --project "$PROJECT" --title t --needs kubernetes
  [ "$status" -ne 0 ]
  run cr set "$id" needs=a,b
  [ "$status" -ne 0 ]
}

@test "placement: a node that is away, on battery, not accepting, not signed in, older, or without the checkout takes nothing" {
  seed m3 $M3 5 10
  export CHARTROOM_NODE_BACKENDS='hc:claude|hc:codex'
  hc_core_up
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/claude"; chmod +x "$BIN/claude"
  id="$(new_task --backend hc:claude)"
  cp "$BATS_TEST_TMPDIR/m3.probe" "$BATS_TEST_TMPDIR/good"
  dry "$id"; [[ "$output" == *"run on m3"* ]]
  no() { cp "$BATS_TEST_TMPDIR/good" "$BATS_TEST_TMPDIR/m3.probe"; tweak m3 $M3 "$1"; dry "$id"; [[ "$output" == "$id would run here"* && "$output" == *"m3: "*"($2)"* ]]; }
  no $'s/^power\tac/power\tbattery/' "it is on battery"
  no $'s/^budget\taccept\ton/budget\taccept\toff/' "it is not accepting work"
  no $'s/^login\tclaude\tok/login\tclaude\tno/' "claude is not logged in"
  no $'s/^tool\tclaude\tok/tool\tclaude\tmissing/' "claude is missing"
  no $'s/^runner\thc\tup/runner\thc\tdown/' "hc is not answering"
  no $'s/^disk_free_pct\t50/disk_free_pct\t9/' "its disk is 9% free"
  no $'s/^checkout\t.*/checkout\tgit.example\\/acme\\/other\t\\/there\\/other\t-/' "no checkout of git.example/acme/proj"
  no $'s/^cpu_use\t.*/cpu_use\t-\t-/' "its CPU or memory use could not be read"
  cp "$BATS_TEST_TMPDIR/good" "$BATS_TEST_TMPDIR/m3.probe"; seed m5 $M5 95 95; beat m3 $M3 '["commands","update","dispatch"]'
  dry "$id"; [[ "$output" == "$id would run here"*"its agent is older (chartroom node update m3)"* ]]
  beat m3 $M3; jq -c '.last_seen -= 100' "$FLEET/devices/$M3.seen.json" >"$FLEET/t" && mv "$FLEET/t" "$FLEET/devices/$M3.seen.json"
  dry "$id"; [[ "$output" == "$id would run here"*"it is stale"* ]]
}

@test "placement: work that is here already, or that only this machine has, stays; a pin decides" {
  seed m3 $M3 5 10
  stays() { dry "$1"; [[ "$output" == "$1 would run here"*"stays on this machine: $2"* ]]; }
  id="$(new_task --backend command)"; git -C "$PROJECT" branch "$(meta_of "$id" branch)"; stays "$id" "its branch is here"
  git -C "$PROJECT" commit -q --allow-empty -m local; id="$(new_task --backend command --base main)"; stays "$id" "its base is on no branch of the remote, only here"
  id="$(new_task --backend command --node here 2>/dev/null)"; stays "$id" "pinned here"
  cr set "$id" node=any >/dev/null; dry "$id"; [[ "$output" == *"run on m3"* ]]
  cr set "$id" node=here >/dev/null; stays "$id" "pinned here"
  id="$(new_task --backend command)"; cr worktree "$id" >/dev/null; stays "$id" "its worktree is here"
  # a runner that is not one of those a device runs is not placed at all
  export CHARTROOM_HARNESS=claude; id="$(new_task --backend subagent)"; dry "$id"; [[ "$output" == *"(not placed)" ]]
  # a pin to a full node is refused with its numbers; --over-limit passes it
  tweak m3 $M3 $'s/^cpu_use\t.*/cpu_use\t95\t60/'; answering
  id="$(new_task --backend command --node m3 2>/dev/null)"
  run cr dispatch "$id"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"it is pinned to m3"* || "$output" == *"is pinned to m3, and cpu 95% in use, its limit is 90%"* ]]
  [ -z "$(meta_of "$id" dispatched)" ]
  run cr dispatch "$id" --over-limit
  echo "$output"
  [ "$status" -eq 0 ]
  jq -e '.payload.over == true' "$BATS_TEST_TMPDIR"/taken/$M3.*.json
  # a home no device could report back to: everything stays
  cr homes rm acme >/dev/null
  id="$(new_task --backend command)"; dry "$id"; [[ "$output" == *"would run here"*"this home is not registered"* ]]
}

@test "placement: a node that refuses when asked is passed over, and nothing of the refusal stays in the record" {
  seed m3 $M3 5 10; seed m5 $M5 6 10; answering
  echo '{"rc":5,"out":"","err":"cpu 97% in use, its limit is 90%\n"}' >"$BATS_TEST_TMPDIR/$M3.answer"
  echo '{"rc":6,"out":"","err":"the base is not there\n"}' >"$BATS_TEST_TMPDIR/$M5.answer"
  id="$(new_task --backend command)"
  run cr dispatch "$id"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(where "$id")" ]
  [ "$(meta_of "$id" backend)" = command ]
  [ -n "$(meta_of "$id" worktree)" ] && [ -n "$(meta_of "$id" dispatched)" ]
  events "$id" | grep -q " note: m3 did not take it: cpu 97% in use, its limit is 90%"
  events "$id" | grep -q " note: m5 did not take it: the base is not there"
  ! events "$id" | grep -q " failed: "
  [ ! -e "$FLEET/tasks/acme/$id.json" ]
  [ "$(jq -r .node "$FLEET/placed/acme.$id.json")" = here ]
  # a pin is not passed over: it says so, and can be dispatched again
  id="$(new_task --backend command --node m3 2>/dev/null)"
  run cr dispatch "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"m3 did not take $id: cpu 97% in use"* ]]
  [ -z "$(meta_of "$id" dispatched)" ]
  # an answer that is a failure to start, not a refusal, is the task's: never started twice
  echo '{"rc":1,"out":"","err":"worktree: boom\n"}' >"$BATS_TEST_TMPDIR/$M5.answer"
  id="$(new_task --backend command)"
  run cr dispatch "$id"
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(where "$id")" = "$M5" ]
  events "$id" | grep -q " failed: the dispatch on m5 did not start a worker: worktree: boom"
}

@test "placement: files of the home that the brief names go along; a file that cannot keeps the task here" {
  seed m3 $M3 5 10; answering
  mkdir -p "$CHARTROOM_HOME/drafts" "$CHARTROOM_HOME/tasks/other-1234/shots"
  echo "the plan" >"$CHARTROOM_HOME/drafts/plan.md"; echo report >"$CHARTROOM_HOME/tasks/other-1234/report.md"; echo png >"$CHARTROOM_HOME/tasks/other-1234/shots/a.png"
  says() { perl -0pi -e "s|(Commander's intent\n\n).*?\n|\$1$2\n|" "$CHARTROOM_HOME/tasks/$1/brief.md"; }
  id="$(new_task --backend command)"
  says "$id" "Read $CHARTROOM_HOME/drafts/plan.md. Then $CHARTROOM_HOME/tasks/other-1234/report.md, and $CHARTROOM_HOME/tasks/other-1234/shots/ (pictures)."
  run cr dispatch "$id"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(where "$id")" = "$M3" ]
  p="$(jq -c .payload "$BATS_TEST_TMPDIR"/taken/$M3.*.json)"
  [ "$(jq -c '.carry' <<<"$p")" = '["drafts/plan.md","tasks/other-1234/report.md","tasks/other-1234/shots"]' ]
  [ "$(jq -r '.files[] | select(.rel == "drafts/plan.md") | .b64' <<<"$p" | base64 -d)" = "the plan" ]
  [ "$(jq -c '[.files[].rel]' <<<"$p")" = '["drafts/plan.md","tasks/other-1234/report.md","tasks/other-1234/shots/a.png"]' ]
  # the device's own checkout of the project, where its list has it
  [ "$(jq -r .project <<<"$p")" = /there/proj ]
  id="$(new_task --backend command)"
  stays() { says "$id" "Look at $1 first."; dry "$id"; [[ "$output" == "$id would run here"*"stays on this machine: its brief names $2"* ]]; }
  goes() { says "$id" "Look at $1 first."; dry "$id"; [[ "$output" == "$id would run on m3"* ]]; }
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"; stays "$BATS_TEST_TMPDIR/elsewhere" "$BATS_TEST_TMPDIR/elsewhere"
  echo x >"$CHARTROOM_HOME/tasks/other-1234/api-token.txt"; stays "$CHARTROOM_HOME/tasks/other-1234/api-token.txt" "$CHARTROOM_HOME/tasks/other-1234/api-token.txt, and tasks/other-1234/api-token.txt does not go"
  printf -- '-----BEGIN %s KEY-----\n' "PRIVATE" >"$CHARTROOM_HOME/drafts/k.md"; stays "$CHARTROOM_HOME/drafts/k.md" "$CHARTROOM_HOME/drafts/k.md"
  ln -s /etc/hosts "$CHARTROOM_HOME/drafts/l.md"; stays "$CHARTROOM_HOME/drafts/l.md" "$CHARTROOM_HOME/drafts/l.md"
  head -c 1100000 /dev/zero | tr '\0' x >"$CHARTROOM_HOME/drafts/big.md"; stays "$CHARTROOM_HOME/drafts/big.md" "$CHARTROOM_HOME/drafts/big.md"
  stays "$CHARTROOM_HOME" "$CHARTROOM_HOME"
  # in the project: tracked files are there too, others are not; a path that does not exist is prose
  goes "$PROJECT/README"
  goes "/api/v1/widgets and /no/such/file"
  echo s >"$PROJECT/.env"; stays "$PROJECT/.env" "$PROJECT/.env, which is not in git"
  # another checkout: the node must have it too
  git init -q "$BATS_TEST_TMPDIR/second"; echo f >"$BATS_TEST_TMPDIR/second/f"; git -C "$BATS_TEST_TMPDIR/second" add f; git -C "$BATS_TEST_TMPDIR/second" commit -qm f
  git -C "$BATS_TEST_TMPDIR/second" remote add origin https://git.example/acme/second
  says "$id" "Compare with $BATS_TEST_TMPDIR/second/f."; dry "$id"; [[ "$output" == *"would run here"*"no checkout of git.example/acme/second"* ]]
  printf 'checkout\tgit.example/acme/second\t/there/second\t-\n' >>"$BATS_TEST_TMPDIR/m3.probe"; beat m3 $M3
  dry "$id"; [[ "$output" == *"run on m3"* ]]
}
