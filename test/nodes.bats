#!/usr/bin/env bats
# chartroom nodes / node probe / node init (lib/nodes.sh, lib/nodeprobe.sh): the machines that
# can take crew work, stage 1, read-only. No real ssh, hc, sysctl, pmset or ioreg: the probe reads
# fakes (test/fakes/{sysctl,pmset,ioreg,nodetool,hc}) and other machines answer from a fake ssh
# that logs every call, so the tests can show that the probe script is the only thing run there.

load test_helper

setup() {
  common_setup
  use_fake ssh sysctl pmset ioreg vm_stat iostat
  export CHARTROOM_MACHINE_NAME=studio
  export CHARTROOM_NODES=none
  export FAKE_NODE_DIR="$BATS_TEST_TMPDIR/node"
  export CHARTROOM_NODE_CONFIG="$BATS_TEST_TMPDIR/nodecfg/node"
  SSHD="$BATS_TEST_TMPDIR/ssh"; mkdir -p "$SSHD"
  unset SSH_CONNECTION SSH_CLIENT HC_SOCKET HC_SESSION
  mac_like
}

teardown() {
  [[ -z "${CORE_PID:-}" ]] || kill "$CORE_PID" 2>/dev/null || true
  [[ -z "${CORE_SOCK:-}" ]] || rm -f "$CORE_SOCK"
}

# A Mac-shaped machine: 16 cores (12P+4E), 48 GB, load 3, CPUs 20% busy, memory 25% used (12 GB:
# 8 GB app, 2 GB of it purgeable and so not counted, 4 GB wired, 2 GB compressed; the kernel's
# pressure level says 92% free), on AC with a full battery, idle 40 minutes.
mac_like() {
  local s="$FAKE_NODE_DIR/sysctl"; mkdir -p "$s"
  echo Mac15,8 >"$s/hw.model"; echo 16 >"$s/hw.ncpu"; echo 12 >"$s/hw.perflevel0.physicalcpu"
  echo 4 >"$s/hw.perflevel1.physicalcpu"; echo 51539607552 >"$s/hw.memsize"
  echo '{ 3.00 2.50 2.00 }' >"$s/vm.loadavg"; echo 92 >"$s/kern.memorystatus_level"
  printf '      cpu    load average\n us sy id   1m   5m   15m\n  8  5 87  3.00 2.50 2.00\n 13  7 80  3.00 2.50 2.00\n' >"$FAKE_NODE_DIR/iostat"
  cat >"$FAKE_NODE_DIR/vm_stat" <<'VM'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              1000000.
Pages active:                             900000.
Pages wired down:                         262144.
Pages purgeable:                          131072.
Anonymous pages:                          524288.
File-backed pages:                        700000.
Pages stored in compressor:               400000.
Pages occupied by compressor:             131072.
VM
  printf "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%%; charged; 0:00 remaining present: true\n" >"$FAKE_NODE_DIR/pmset"
  printf '    | |   "HIDIdleTime" = 2400000000000\n' >"$FAKE_NODE_DIR/ioreg"
}

# Fake tools on PATH: <name>[=version[,login|daemon]] ...
tools() {
  local t name rest
  for t in "$@"; do
    name="${t%%=*}"; rest=""; [[ "$t" == *=* ]] && rest="${t#*=}"
    mkdir -p "$FAKE_NODE_DIR/tools/$name"
    ln -sf "$REPO_ROOT/test/fakes/nodetool" "$BIN/$name"
    [[ -z "$rest" ]] || echo "${rest%%,*}" >"$FAKE_NODE_DIR/tools/$name/version"
    if [[ "$rest" == *,* ]]; then
      if [[ "$name" == docker ]]; then echo "${rest#*,}" >"$FAKE_NODE_DIR/tools/$name/daemon"
      else echo "${rest#*,}" >"$FAKE_NODE_DIR/tools/$name/login"; fi
    fi
  done
}

# hc on PATH, and its core answering on a socket its core.lock names (a listener held for the
# test, at a short path: socket paths are limited to ~100 bytes). It never accepts, so its
# backlog is what lets each probe in a test connect.
hc_core_up() {
  use_fake hc; export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"; mkdir -p "$FAKE_HC_DIR"
  CORE_SOCK="/tmp/crnd.$$.$RANDOM"
  perl -MIO::Socket::UNIX -e '$s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 128) or die "$!"; sleep 120' "$CORE_SOCK" 3>&- &
  CORE_PID=$!
  local i; for i in $(seq 1 40); do [[ -S "$CORE_SOCK" ]] && break; sleep 0.05; done
  mkdir -p "$XDG_STATE_HOME/herdr-core/default"; echo "$CORE_SOCK" >"$XDG_STATE_HOME/herdr-core/default/core.lock"
}

probe_val() { awk -F'\t' -v OFS='\t' -v k="$1" '$1 == k { $1 = ""; sub(/^\t/, ""); print; exit }' <<<"$output"; }
tool_line() { grep -E "^tool	$1	" <<<"$output" | cut -f3-; }
login_line() { grep -E "^login	$1	" <<<"$output" | cut -f3; }

# A remote machine's canned probe output: this machine's own, with a few values changed.
remote_probe() { # <target> [initialised 0|1]
  mkdir -p "$SSHD/$1"
  if [[ "${2:-0}" == 1 ]]; then cr node init --cpu 100 --battery allow --project-roots "" >/dev/null; fi
  cr node probe >"$SSHD/$1/probe.tsv"
  rm -f "$CHARTROOM_NODE_CONFIG"
}

@test "node probe: a Mac's cores, memory, load, power and idle time, schema 1 first" {
  run cr node probe
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'probe_schema\t1' ]
  [ "$(probe_val cores)" = 16 ]
  [ "$(probe_val cores_perf)" = 12 ]
  [ "$(probe_val cores_eff)" = 4 ]
  [ "$(probe_val mem_bytes)" = 51539607552 ]
  [ "$(probe_val load)" = $'3.00\t2.50\t2.00' ]
  [ "$(probe_val mem_free_pct)" = 92 ]
  [ "$(probe_val mem_used_pct)" = 25 ]
  [ "$(probe_val cpu_use)" = $'20\t1' ]
  [ "$(probe_val power)" = ac ]
  [ "$(probe_val battery_pct)" = 100 ]
  [ "$(probe_val hid_idle_s)" = 2400 ]
  [ "$(probe_val initialised)" = 0 ]
  [ "$(probe_val runner)" = $'hc\tnone\t-' ]
  [ "$(probe_val context)" = shell ]
  run cr node probe --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.machine, .local, .contact, .cores, .load, .power, .hid_idle_s, .role, .util]' <<<"$output")" = \
    '["studio",true,"ok",16,[3,2.5,2],"ac",2400,"not a node",null]' ]
}

@test "node probe: never starts an hc core; without one answering, hc is not called at all" {
  use_fake hc; export FAKE_HC_DIR="$BATS_TEST_TMPDIR/hc"; mkdir -p "$FAKE_HC_DIR"
  tools claude=2.1.0,core
  # a lock naming a socket nobody listens on: a core that crashed
  mkdir -p "$XDG_STATE_HOME/herdr-core/default"; echo "$BATS_TEST_TMPDIR/dead.sock" >"$XDG_STATE_HOME/herdr-core/default/core.lock"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die' "/tmp/crdead.$$" && mv "/tmp/crdead.$$" "$BATS_TEST_TMPDIR/dead.sock"
  run cr node probe
  [ "$status" -eq 0 ]
  [ "$(probe_val runner)" = $'hc\tdown\t-' ]
  [ ! -s "$FAKE_HC_DIR/calls.log" ]
  # checked in this shell (not over ssh), where the keychain is closed to nothing
  [ "$(probe_val context)" = shell ]
  [ "$(login_line claude)" = no ]
}

@test "node probe: logins are checked inside the hc core, where a Mac's keychain answers" {
  hc_core_up
  tools claude=2.1.329,core gh=2.80.0,core codex=0.160.0,no
  run cr node probe
  [ "$status" -eq 0 ]
  [ "$(probe_val runner)" = $'hc\tup\t0.1.21' ]
  [ "$(probe_val context)" = core ]
  [ "$(grep $'^login\tclaude\t' <<<"$output" | cut -f3,4)" = $'ok\tclaude.ai' ]
  [ "$(login_line gh)" = ok ]
  [ "$(login_line codex)" = no ]
  grep -q '^exec ' "$FAKE_HC_DIR/calls.log"
  # the same tools, checked from an ssh session with no core, read unknown, never "no"
  rm -f "$XDG_STATE_HOME/herdr-core/default/core.lock"
  run env SSH_CONNECTION="10.0.0.1 5000 10.0.0.2 22" "$CHARTROOM" node probe
  [ "$(probe_val context)" = ssh ]
  [ "$(login_line claude)" = unknown ]
  [ "$(login_line gh)" = unknown ]
  [ "$(tool_line claude)" = $'ok\t2.1.329' ]
}

@test "node probe: a tool counts when it works, not when its binary is there" {
  tools docker=28.0.1,down go=1.22.1 node=22.1.0
  run cr node probe
  [ "$status" -eq 0 ]
  [ "$(tool_line docker)" = $'down\tdaemon not answering' ]
  [ "$(tool_line go)" = $'ok\t1.22.1' ]
  [ "$(tool_line node)" = $'ok\t22.1.0' ]
  [ "$(tool_line codex)" = $'missing\t-' ]
  [ "$(login_line codex)" = missing ]
  echo up >"$FAKE_NODE_DIR/tools/docker/daemon"
  run cr node probe
  [ "$(tool_line docker)" = $'ok\t28.0.1' ]
  # an old bash (a Mac's /bin/bash) is reported as old
  printf '#!/bin/sh\necho 3.2.57\n' >"$BATS_TEST_TMPDIR/oldbash"; chmod +x "$BATS_TEST_TMPDIR/oldbash"
  mkdir -p "$BATS_TEST_TMPDIR/old"; ln -sf "$BATS_TEST_TMPDIR/oldbash" "$BATS_TEST_TMPDIR/old/bash"
  run env PATH="$BATS_TEST_TMPDIR/old:$PATH" "$(type -P bash)" "$REPO_ROOT/lib/nodeprobe.sh"
  [ "$(tool_line bash)" = $'old\t3.2.57' ]
}

@test "node probe: tools are checked on the login shell's PATH, where a worker's tools come from" {
  # a node only the login shell's PATH finds (mise and the like are set up in .zshrc only)
  mkdir -p "$BATS_TEST_TMPDIR/mise/bin" "$FAKE_NODE_DIR/tools/node"
  ln -sf "$REPO_ROOT/test/fakes/nodetool" "$BATS_TEST_TMPDIR/mise/bin/node"; echo 24.22.1 >"$FAKE_NODE_DIR/tools/node/version"
  printf '#!/bin/sh\n[ "$1" = -lic ] || exit 1\nprintf "\\036%%s:%%s\\036" "%s" "$PATH"\n' "$BATS_TEST_TMPDIR/mise/bin" >"$BIN/loginsh"; chmod +x "$BIN/loginsh"
  run cr node probe
  [ "$(probe_val path_source)" = inherited ]
  [ "$(tool_line node)" = $'missing\t-' ]
  export CHARTROOM_LOGIN_SHELL="$BIN/loginsh"
  run cr node probe
  [ "$status" -eq 0 ]
  [ "$(probe_val path_source)" = login ]
  [ "$(tool_line node)" = $'ok\t24.22.1' ]
  # the same from an ssh session (no core), and inside an hc core, which gets that PATH too
  run env SSH_CONNECTION="10.0.0.1 5000 10.0.0.2 22" "$CHARTROOM" node probe
  [ "$(probe_val context)" = ssh ]
  [ "$(tool_line node)" = $'ok\t24.22.1' ]
  hc_core_up
  run cr node probe
  [ "$(probe_val context)" = core ]
  [ "$(tool_line node)" = $'ok\t24.22.1' ]
  grep -q "^exec .*PATH=$BATS_TEST_TMPDIR/mise/bin:" "$FAKE_HC_DIR/calls.log"
  # chartroom's own cache of it is read when fresh, so the shell is not asked again
  mkdir -p "$XDG_STATE_HOME/chartroom"; printf '%s' "/cached/bin:$PATH" >"$XDG_STATE_HOME/chartroom/login-path"
  run cr node probe
  [ "$(tool_line node)" = $'missing\t-' ]
  # the shell may come from chartroom's config file, or the older CHARTROOM_BRAIN_LOGIN_SHELL
  unset CHARTROOM_LOGIN_SHELL; export CHARTROOM_CONFIG="$BATS_TEST_TMPDIR/cfg"
  printf 'CHARTROOM_BRAIN_LOGIN_SHELL=%s\n' "$BIN/loginsh" >"$CHARTROOM_CONFIG"
  run cr node probe
  [ "$(probe_val path_source)" = login ]
  printf 'CHARTROOM_LOGIN_SHELL=none\nCHARTROOM_BRAIN_LOGIN_SHELL=%s\n' "$BIN/loginsh" >"$CHARTROOM_CONFIG"
  run cr node probe
  [ "$(probe_val path_source)" = inherited ]
  printf 'CHARTROOM_LOGIN_SHELL=%s\n' "$BIN/loginsh" >"$CHARTROOM_CONFIG"
  # a shell that answers nothing usable leaves the probe's own PATH
  rm -f "$XDG_STATE_HOME/chartroom/login-path"; printf '#!/bin/sh\necho no path here\n' >"$BIN/loginsh"
  run cr node probe
  [ "$(probe_val path_source)" = inherited ]
}

@test "node probe: a broken tool says which binary and why, not just that it failed" {
  tools node=22.1.0 codex=0.171.0
  printf 'dyld[123]: Library not loaded: /opt/homebrew/opt/simdjson/lib/libsimdjson.34.dylib\n  Referenced from: node\n' >"$FAKE_NODE_DIR/tools/node/broken"
  run cr node probe
  [ "$status" -eq 0 ]
  [ "$(tool_line node)" = "error	$BIN/node: dyld[123]: Library not loaded: /opt/homebrew/opt/simdjson/lib/libsimdjson.34.dylib" ]
  [ "$(tool_line codex)" = $'ok\t0.171.0' ]
  # silent and failing: its exit status
  printf '' >"$FAKE_NODE_DIR/tools/node/broken"
  run cr node probe
  [ "$(tool_line node)" = "error	$BIN/node: exited 134 with no output" ]
  # the table names it under the machine
  export CHARTROOM_NODES=none
  run cr nodes
  [ "$status" -eq 0 ]
  grep -q "^studio: node is broken: $BIN/node: exited 134 with no output" <<<"$output"
}

@test "node probe: the crew is chartroom's workers; XOs and other agents are counted apart" {
  hc_core_up; export FAKE_HC_EVENTS=1
  term() { # <address> <state> <labels json> <status json>
    jq -n --arg a "$1" --arg s "$2" --argjson l "$3" --argjson st "$4" '{address: $a, state: $s, labels: $l, status: $st, agent: "claude-code"}' >"$FAKE_HC_DIR/terms/$1.json"
  }
  mkdir -p "$FAKE_HC_DIR/terms"
  term t1 live '{"chartroom.task": "a-1111"}' '{"app": "claude-code", "state": "working"}'
  term t2 live '{"chartroom.task": "b-2222"}' 'null'
  term t3 finished '{"chartroom.task": "c-3333"}' 'null'
  term t4 live '{"where": "XO"}' '{"app": "claude-code", "state": "done"}'
  term t5 live '{}' 'null'
  term m3_t6 live '{"chartroom.task": "d-4444"}' '{"app": "claude-code"}'
  jq '.address = "m3/t6"' "$FAKE_HC_DIR/terms/m3_t6.json" >"$FAKE_HC_DIR/x" && mv "$FAKE_HC_DIR/x" "$FAKE_HC_DIR/terms/m3_t6.json"
  run cr node probe
  [ "$status" -eq 0 ]
  # two live crew here (a finished one is parked or gone; a linked machine's is its own), one XO
  [ "$(probe_val crew_live)" = 2 ]
  [ "$(probe_val other_agents)" = 1 ]
  # placement's slot count is the crew, and the table shows the others apart
  cr node init --cpu 100 --battery allow --project-roots "" >/dev/null
  run cr node probe --json
  [ "$(jq -c '[.crew_live, .other_agents]' <<<"$output")" = '[2,1]' ]
  run cr nodes
  [ "$status" -eq 0 ]
  grep -q $'2 +1 other' <<<"$output"
  grep -q "takes no new task" <<<"$output"
  # an hc with no event stream cannot tell them apart: every live agent counts, and says so
  unset FAKE_HC_EVENTS
  run cr node probe
  [ "$(probe_val crew_live)" = - ]
  run cr nodes
  grep -q "(all agents)" <<<"$output"
}

@test "node probe: agents by name: a worker by its task, an XO by its home; no title, message or path leaves the machine" {
  hc_core_up; export FAKE_HC_EVENTS=1
  mkdir -p "$FAKE_HC_DIR/terms" "$BATS_TEST_TMPDIR/homes/.acme/tasks" "$BATS_TEST_TMPDIR/work/shop/tasks"
  touch "$BATS_TEST_TMPDIR/homes/.acme/commander.md"
  term() { jq -n --arg a "$1" --argjson x "$2" '{address: $a, state: "live", agent: "claude-code", title: "SECRET title", status: {app: "claude-code", state: "done", msg: "SECRET msg"}} + $x' >"$FAKE_HC_DIR/terms/$1.json"; }
  term t1 '{"labels": {"chartroom.task": "a-1111", "where": "crew / SECRET task title"}, "status": {"app": "claude-code", "state": "working"}}'
  # its shell began elsewhere: where its program is now is what counts
  term t2 "$(jq -n --arg d "$BATS_TEST_TMPDIR/homes/.acme" '{cwd: "/elsewhere", foreground: {cwd: $d}, labels: {where: "XO / Acme\tmain"}}')"
  # a tasks directory alone is not a home
  term t3 "$(jq -n --arg d "$BATS_TEST_TMPDIR/work/shop" '{foreground: {cwd: $d}, labels: {}, status: {app: "codex", state: "error"}}')"
  term t4 '{"labels": null, "status": {"app": "claude-code"}}'
  term t5 '{"labels": {}, "status": null}'
  run cr node probe
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^agent\t' <<<"$output")" -eq 4 ]
  grep -qxF $'agent\tcrew\tt1\tworking\ta-1111\t-' <<<"$output"
  grep -qxF $'agent\txo\tt2\tdone\tacme\tXO / Acme main' <<<"$output"
  grep -qxF $'agent\tother\tt3\terror\tshop\t-' <<<"$output"
  grep -qxF $'agent\tother\tt4\t-\t-\t-' <<<"$output"
  if grep -qE "SECRET|$BATS_TEST_TMPDIR/(homes|work)" <<<"$output"; then false; fi
  run cr node probe --json
  [ "$(jq -c '[.agents[] | [.kind, .name, .state, .where]]' <<<"$output")" = '[["crew","a-1111","working",null],["xo","acme","done","XO / Acme main"],["other","shop","error",null],["other",null,null,null]]' ]
  # the brain trusts no probe to keep its own limits: 80 agents, 120 characters each
  mkdir -p "$SSHD/studio2"; run cr node probe
  { printf '%s\n' "$output" | grep -v $'^agent\t'; printf 'agent\tboss\tt0\tdone\tx\t-\n'
    for i in $(seq 1 90); do printf 'agent\tother\tt%s\tdone\t%0300d\t-\n' "$i" 7; done; } >"$SSHD/studio2/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES=studio2 "$CHARTROOM" nodes --json
  [ "$(jq -c '.nodes[] | select(.machine == "studio2") | [(.agents | length), (.agents | map(.kind) | unique), (.agents[0].name | length)]' <<<"$output")" = '[80,["other"],120]' ]
  # with no event stream there are none, and the count is all there is
  unset FAKE_HC_EVENTS
  run cr node probe --json
  [ "$(jq -c .agents <<<"$output")" = '[]' ]
}

@test "node probe: degrades on a machine without sysctl, pmset or ioreg (Linux)" {
  rm -rf "$FAKE_NODE_DIR"
  run cr node probe
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'probe_schema\t1' ]
  [ "$(probe_val power)" = - ]
  [ "$(probe_val battery_pct)" = - ]
  [ "$(probe_val hid_idle_s)" = - ]
  [[ "$(probe_val cores)" =~ ^([0-9]+|-)$ ]]
  run cr node probe --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .contact <<<"$output")" = ok ]
}

@test "node probe: runs on bash 3.2 syntax, and reads the script whole before running it (bash -s)" {
  # stdin is the script under `bash -s`: a command that reads stdin must not eat the rest of it
  rm -f "$BIN/pmset"; printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$BIN/pmset"; chmod +x "$BIN/pmset"
  run bash -s <"$REPO_ROOT/lib/nodeprobe.sh"
  [ "$status" -eq 0 ]
  [ "$(probe_val checkouts)" = - ]
  if [[ -x /bin/bash ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]'; then
    run /bin/bash "$REPO_ROOT/lib/nodeprobe.sh"
    [ "$status" -eq 0 ]
    [ "$(probe_val cores)" = 16 ]
  fi
}

@test "node init: writes this machine's budgets from its own probe; no home, no overwrite" {
  local before; mkdir -p "$CHARTROOM_HOME"; before="$(snapshot "$CHARTROOM_HOME")"
  run cr node init
  [ "$status" -eq 0 ]
  [[ "$output" == *"this machine is a node: $CHARTROOM_NODE_CONFIG"* ]]
  # 12 performance cores -> 6 workers; a battery -> cpu 50%
  ! grep -q MAX_WORKERS "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_CPU_BUDGET=50 "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_MEM_BUDGET=75 "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_ON_BATTERY=pause "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_PRIORITY=nice "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_ACCEPT=on "$CHARTROOM_NODE_CONFIG"
  [ "$(snapshot "$CHARTROOM_HOME")" = "$before" ]
  [ ! -e "$HOME/.chartroom" ]
  run cr node init --cpu 100
  [ "$status" -ne 0 ]
  [[ "$output" == *"exists"*"--force"* ]]
  run cr node init --force --cpu 100 --battery allow --max-workers 3 --priority background --project-roots "~/src:/opt/repos"
  [ "$status" -eq 0 ]
  [[ "$output" == *"efficiency cores"* ]]
  grep -qx CHARTROOM_NODE_CPU_BUDGET=100 "$CHARTROOM_NODE_CONFIG"
  grep -qx 'CHARTROOM_NODE_PROJECT_ROOTS=~/src:/opt/repos' "$CHARTROOM_NODE_CONFIG"
  run cr node probe
  [ "$(probe_val initialised)" = 1 ]
  [ "$(grep $'^budget\tcpu\t' <<<"$output" | cut -f3)" = 100 ]
  # a desktop (no battery) gets cpu 100% by default
  rm -f "$CHARTROOM_NODE_CONFIG"; printf "Now drawing from 'AC Power'\n" >"$FAKE_NODE_DIR/pmset"
  cr node init >/dev/null
  grep -qx CHARTROOM_NODE_CPU_BUDGET=80 "$CHARTROOM_NODE_CONFIG"
}

@test "node init: refuses values out of range, before writing anything" {
  local bad
  for bad in "--cpu 0" "--cpu 101" "--mem x" "--battery maybe" "--priority high" "--project-roots a;b"; do
    # shellcheck disable=SC2086
    run cr node init $bad
    [ "$status" -ne 0 ]
    [ ! -e "$CHARTROOM_NODE_CONFIG" ]
  done
  run cr doctor
  [[ "$output" == *"node:     not a node"* ]]
  cr node init >/dev/null
  run cr doctor
  [[ "$output" == *"node:     $CHARTROOM_NODE_CONFIG: cpu_budget=50"* ]]
}

@test "nodes: CHARTROOM_NODES, else the radar's machines, else herdr's; none is this machine only" {
  run cr nodes --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.nodes[] | [.machine, .local, .via]]' <<<"$output")" = '[["studio",true,"this machine"]]' ]
  remote_probe box; remote_probe m3
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="box m3=m3.tail.example studio" "$CHARTROOM" nodes --json
  [ "$(jq -c '[.nodes[] | [.machine, .target, .via]]' <<<"$output")" = \
    '[["studio",null,"this machine"],["box","box","CHARTROOM_NODES"],["m3","m3.tail.example","CHARTROOM_NODES"]]' ]
  run env -u CHARTROOM_NODES FAKE_SSH_DIR="$SSHD" CHARTROOM_RADAR_MACHINES="box" "$CHARTROOM" nodes --json
  [ "$(jq -c '[.nodes[] | [.machine, .via]]' <<<"$output")" = '[["studio","this machine"],["box","CHARTROOM_RADAR_MACHINES"]]' ]
  use_fake herdr
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"
  echo '[{"id":"1","label":"box","target":"box","enabled":true},{"id":"2","label":"off","target":"off","enabled":false}]' >"$FAKE_HERDR_DIR/machines.json"
  run env -u CHARTROOM_NODES FAKE_SSH_DIR="$SSHD" "$CHARTROOM" nodes --json
  [ "$(jq -c '[.nodes[] | [.machine, .via]]' <<<"$output")" = '[["studio","this machine"],["box","herdr"]]' ]
  : >"$SSHD/calls.log"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="bad;label" "$CHARTROOM" nodes
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not label[=ssh-target]"* ]]
  [ ! -s "$SSHD/calls.log" ]
}

@test "nodes: each machine's contact: ok, not a node, unreachable, auth, incompatible, error" {
  remote_probe good 1; remote_probe fresh
  mkdir -p "$SSHD/down"; echo 255 >"$SSHD/down/exit"; echo "ssh: connect to host down port 22: Operation timed out" >"$SSHD/down/stderr"
  mkdir -p "$SSHD/locked"; echo 255 >"$SSHD/locked/exit"; echo "user@locked: Permission denied (publickey)." >"$SSHD/locked/stderr"
  mkdir -p "$SSHD/newer"; printf 'probe_schema\t2\nhost\tnewer\n' >"$SSHD/newer/probe.tsv"
  mkdir -p "$SSHD/odd"; echo "zsh: something went wrong" >"$SSHD/odd/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="good fresh down locked newer odd" "$CHARTROOM" nodes --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.nodes[] | [.machine, .contact, .role]]' <<<"$output")" = \
    '[["studio","ok","not a node"],["good","ok","node"],["fresh","ok","not a node"],["down","unreachable",null],["locked","auth",null],["newer","incompatible",null],["odd","error",null]]' ]
  [ "$(jq -r '.nodes[] | select(.machine == "down") | .error' <<<"$output")" = "ssh: connect to host down port 22: Operation timed out" ]
  [ "$(jq -r '.nodes[] | select(.machine == "newer") | .error' <<<"$output")" = "probe schema 2; this chartroom reads 1" ]
  [ "$(jq -r '.nodes[] | select(.machine == "odd") | .error' <<<"$output")" = "zsh: something went wrong" ]
  [ "$(jq -c '.nodes[] | select(.machine == "good") | [.budgets.cpu, .budgets.mem, .budgets.on_battery]' <<<"$output")" = '[100,75,"allow"]' ]
  # the table: one row each, this machine first
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="good down" "$CHARTROOM" nodes
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == NODE*CONTACT*ROLE*UTIL ]]
  [[ "${lines[1]}" == "studio (here)"*"not a node"* ]]
  [[ "${lines[2]}" == good*ok*node*"20% of 100%"*"25% of 75%"*"16 cores 48G"*"AC (battery 100%)"*40m* ]]
  [[ "${lines[3]}" == down*"unreachable: ssh: connect to host down"* ]]
}

@test "nodes: only the probe script ever runs on another machine, and this home is left as it was" {
  remote_probe box 1
  mkdir -p "$CHARTROOM_HOME/tasks"; local id; id="$(new_task)"
  local before; before="$(snapshot "$CHARTROOM_HOME/tasks")"
  : >"$SSHD/calls.log"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="box" "$CHARTROOM" nodes
  [ "$status" -eq 0 ]
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="box" "$CHARTROOM" nodes --project "$PROJECT" --json
  [ "$status" -ne 0 ] # a project with no origin remote is refused before any ssh
  git -C "$PROJECT" remote add origin git@github.example:Owner/Proj.git
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="box" "$CHARTROOM" nodes --project "$PROJECT" --json
  [ "$status" -eq 0 ]
  local want; want="$(cksum <"$REPO_ROOT/lib/nodeprobe.sh" | awk '{print $1, $2}')"
  run cat "$SSHD/calls.log"
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == 'box PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" bash -s' ]]
  [ "${lines[1]}" = "box <stdin cksum $want>" ]
  [[ "${lines[2]}" == "box PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\" CR_PROBE_PROJECT='github.example/owner/proj' bash -s" ]]
  [ "${lines[3]}" = "box <stdin cksum $want>" ]
  [ "$(snapshot "$CHARTROOM_HOME/tasks")" = "$before" ]
}

@test "nodes: a probe that never answers is ended after CHARTROOM_NODES_TIMEOUT" {
  mkdir -p "$SSHD/slow"
  # (the link to the fake ssh goes first: writing through it would rewrite the fake itself)
  rm -f "$BIN/ssh"
  cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; exec sleep 30
EOF
  chmod +x "$BIN/ssh"
  local t0=$SECONDS
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="slow" CHARTROOM_NODES_TIMEOUT=1 "$CHARTROOM" nodes --json 3>&-
  [ "$status" -eq 0 ]
  (( SECONDS - t0 < 15 ))
  [ "$(jq -c '.nodes[1] | [.machine, .contact, .error]' <<<"$output")" = '["slow","timeout","no answer within 1s"]' ]
}

@test "nodes: use is measured against each node's two limits; UTIL is with one more worker; a count gates nothing" {
  # m3: 16 cores 20% busy, 48 GB 25% used, limits 100% and 75%; studio2: 28 cores 70% busy, limit 80%
  remote_probe m3 1
  mkdir -p "$SSHD/studio2"
  sed -e $'s/^cores\t.*/cores\t28/; s/^cpu_use\t.*/cpu_use\t70\t60/; s/^budget\tcpu\t.*/budget\tcpu\t80/' "$SSHD/m3/probe.tsv" >"$SSHD/studio2/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="studio2 m3" "$CHARTROOM" nodes --json
  [ "$status" -eq 0 ]
  # m3: cpu (20 + 100 * 1.5 / 16) / 100 = 0.294; mem (25 + 100 * 1.5 / 48) / 75 = 0.375
  [ "$(jq -c '.nodes[] | select(.machine == "m3") | [.cpu_use, .cpu_window_s, .mem_used_pct, .util]' <<<"$output")" = '[20,1,25,{"cpu":0.294,"mem":0.375,"max":0.375}]' ]
  # studio2: (70 + 100 * 1.5 / 28) / 80 = 0.942
  [ "$(jq -c '.nodes[] | select(.machine == "studio2") | .util.max' <<<"$output")" = 0.942 ]
  # at a limit: full; thirty agents and no use: not
  sed -e $'s/^cpu_use\t.*/cpu_use\t80\t60/; s/^agents_live\t.*/agents_live\t30/' "$SSHD/studio2/probe.tsv" >"$SSHD/m3/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="m3" "$CHARTROOM" nodes
  [[ "${lines[2]}" == m3*"80% of 80% (full)"*"25% of 75%"* ]]
  [[ "$output" == *"takes no new task"* ]]
  sed -i.bak -e $'s/^cpu_use\t.*/cpu_use\t5\t60/' "$SSHD/m3/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="m3" "$CHARTROOM" nodes
  [[ "${lines[2]}" == m3*"5% of 80% "* && "$output" != *"(full)"* ]]
  # a machine whose use is not known has no UTIL (never 0)
  sed -i.bak -e $'s/^cpu_use\t.*/cpu_use\t-\t-/' "$SSHD/m3/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="m3" "$CHARTROOM" nodes --json
  [ "$(jq -c '.nodes[1].util' <<<"$output")" = null ]
  # the cost is a setting
  sed -i.bak -e $'s/^cpu_use\t.*/cpu_use\t20\t60/; s/^budget\tcpu\t.*/budget\tcpu\t100/' "$SSHD/m3/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="m3" CHARTROOM_WORKER_CPU=14 "$CHARTROOM" nodes --json
  [ "$(jq -c '.nodes[1].util.cpu' <<<"$output")" = 0.7 ]
  run env CHARTROOM_WORKER_CPU=lots "$CHARTROOM" nodes
  [ "$status" -ne 0 ]
  # paused on battery when it may not run on one
  sed -e $'s/^power\t.*/power\tbattery/; s/^budget\ton_battery\t.*/budget\ton_battery\tpause/' "$SSHD/m3/probe.tsv" >"$SSHD/studio2/probe.tsv"
  run env FAKE_SSH_DIR="$SSHD" CHARTROOM_NODES="studio2" "$CHARTROOM" nodes --json
  [ "$(jq -r '.nodes[1].role' <<<"$output")" = "paused: on battery" ]
}

@test "node limits: shows use against limits, and sets a node's own two, touching nothing else in its file" {
  run cr node limits here 80/70
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a node yet"* ]]
  cr node init --cpu 50 --mem 60 --battery allow --project-roots "" >/dev/null
  printf '# a note of mine\nCHARTROOM_NODE_MAX_WORKERS=20\n' >>"$CHARTROOM_NODE_CONFIG"
  before="$(grep -vE '_(CPU|MEM)_BUDGET=' "$CHARTROOM_NODE_CONFIG")"
  run cr node limits here 80/70
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"under cpu 80% and memory 70% in use"* ]]
  grep -qx CHARTROOM_NODE_CPU_BUDGET=80 "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_MEM_BUDGET=70 "$CHARTROOM_NODE_CONFIG"
  [ "$(grep -vE '_(CPU|MEM)_BUDGET=' "$CHARTROOM_NODE_CONFIG")" = "$before" ]
  # one alone leaves the other
  cr node limits here --mem 85% >/dev/null
  grep -qx CHARTROOM_NODE_CPU_BUDGET=80 "$CHARTROOM_NODE_CONFIG"
  grep -qx CHARTROOM_NODE_MEM_BUDGET=85 "$CHARTROOM_NODE_CONFIG"
  run cr node limits
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "studio (here)"*"20%"*"80%"*"25%"*"85%"*"yes" ]]
  cr node limits here 15/85 >/dev/null
  run cr node limits
  [[ "${lines[1]}" == *"no: cpu at its limit" ]]
  # off and on: its limits stay as they are
  cr node limits here off >/dev/null; grep -qx CHARTROOM_NODE_ACCEPT=off "$CHARTROOM_NODE_CONFIG"
  run cr node limits
  [[ "${lines[1]}" == *"no: paused: not accepting" ]]
  run cr node limits here on
  [[ "$output" == *"under cpu 15% and memory 85% in use" ]]
  for bad in 0/80 80/101 eighty/70 80 "--cpu"; do
    run cr node limits here $bad
    [ "$status" -ne 0 ]
  done
  grep -qx CHARTROOM_NODE_CPU_BUDGET=15 "$CHARTROOM_NODE_CONFIG"
  run cr node limits nosuch 80/70
  [ "$status" -ne 0 ]
}

@test "node probe: the minute a sampler keeps is used while fresh; every checkout is listed when asked" {
  mkdir -p "$XDG_STATE_HOME/chartroom/node"
  echo "$(date +%s) 33 60" >"$XDG_STATE_HOME/chartroom/node/cpu"
  run cr node probe
  [ "$(probe_val cpu_use)" = $'33\t60' ]
  echo "$(( $(date +%s) - 120 )) 33 60" >"$XDG_STATE_HOME/chartroom/node/cpu"
  run cr node probe
  [ "$(probe_val cpu_use)" = $'20\t1' ]
  roots="$BATS_TEST_TMPDIR/repos"; mkdir -p "$roots/o"
  git init -q "$roots/o/a"; git -C "$roots/o/a" remote add upstream https://git.example/x/y; git -C "$roots/o/a" remote add origin git@git.example:O/A.git
  git init -q "$roots/o/b"; git -C "$roots/o/b" remote add origin https://git.example/o/b
  git init -q "$roots/o/none"
  cr node init --project-roots "$roots" >/dev/null
  run env CR_PROBE_CHECKOUTS=1 "$CHARTROOM" node probe
  [ "$(grep -c $'^checkout\t' <<<"$output")" = 2 ]
  [[ "$output" == *$'checkout\tgit.example/o/a\t'"$roots/o/a"$'\t-'* ]]
  run cr node probe
  ! grep -q $'^checkout\t' <<<"$output"
}

@test "cpuload: keeps the busy share of the kernel's counters, the first row (since boot) left out, and ends with its process" {
  # (the fake iostat's rows: a header, since boot 13% busy, then 20% and 40%)
  printf '      cpu    load average\n us sy id   1m   5m   15m\n  8  5 87  3 2 2\n 13  7 80  3 2 2\n 30 10 60  3 2 2\n' >"$FAKE_NODE_DIR/iostat"
  run bash "$REPO_ROOT/lib/cpuload.sh" "$BATS_TEST_TMPDIR/cpu" $$
  [ "$status" -eq 0 ]
  read -r at pct secs <"$BATS_TEST_TMPDIR/cpu"
  [ "$pct" = 30 ] && [ "$secs" = 10 ]
  (( $(date +%s) - at < 30 ))
  # a process that is gone: nothing is written
  rm -f "$BATS_TEST_TMPDIR/cpu"
  ( exit 0 ) & gone=$!; wait "$gone" || true
  run bash "$REPO_ROOT/lib/cpuload.sh" "$BATS_TEST_TMPDIR/cpu" "$gone"
  [ ! -e "$BATS_TEST_TMPDIR/cpu" ]
}

@test "nodes --project: a node knows a project by its canonical remote" {
  local roots="$BATS_TEST_TMPDIR/repos"
  mkdir -p "$roots/owner"
  git init -q "$roots/owner/proj"; git -C "$roots/owner/proj" remote add origin https://github.example/Owner/Proj.git
  git init -q "$roots/owner/other"; git -C "$roots/owner/other" remote add origin https://github.example/owner/other
  touch "$roots/owner/proj/.git/FETCH_HEAD"
  cr node init --project-roots "$roots" >/dev/null
  git -C "$PROJECT" remote add origin git@github.example:owner/proj.git
  run cr nodes --project "$PROJECT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .project <<<"$output")" = github.example/owner/proj ]
  [ "$(jq -c '.nodes[0] | [.checkouts, .project.path, (.project.fetch_age_s < 60)]' <<<"$output")" = "[2,\"$roots/owner/proj\",true]" ]
  run cr nodes --project "$PROJECT"
  [ "${lines[0]}" = "project: github.example/owner/proj" ]
  [[ "${lines[2]}" == *"$roots/owner/proj" ]]
  git -C "$PROJECT" remote set-url origin ssh://git@github.example/owner/missing.git
  run cr nodes --project "$PROJECT" --json
  [ "$(jq -c '.nodes[0] | [.project, .checkouts]' <<<"$output")" = '[null,2]' ]
  run cr nodes --project "$PROJECT"
  [[ "${lines[2]}" == *"no checkout" ]]
}

@test "nodes: help lists node and nodes" {
  run cr help
  [[ "$output" == *"chartroom nodes [--json] [--project PATH]"* ]]
  [[ "$output" == *"chartroom node init [--cpu PCT]"* ]]
  run cr node
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: chartroom node probe"* ]]
}
