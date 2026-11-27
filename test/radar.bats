#!/usr/bin/env bats
# `chartroom radar`: one record per open task on every home of this machine and of other machines
# (a fake ssh), the state table (blocked vs waiting above all), an unreachable machine, an older
# chartroom, and the XOs from herdr. (The web dashboard's /radar page is retired.) No
# network, no real ssh or herdr: other machines are only ever read, and the fake ssh logs every
# command that would have run there.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
  use_fake ssh
  export CHARTROOM_MACHINE_NAME="Test Mac"
  SSHD="$BATS_TEST_TMPDIR/ssh"; mkdir -p "$SSHD"
}

ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# fixture <id> <backend> [key=value ...]: a task record written directly into $FIX_HOME (default
# this home). Keys: dispatched=<secs ago>|"" closed=<secs ago> pid=N. Events come on stdin as
# "<secs ago> <kind>: <text>" lines.
fixture() {
  local id="$1" backend="$2" d kv k v dispatched=7200 closed="" pid=""
  shift 2
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in dispatched) dispatched="$v" ;; closed) closed="$v" ;; pid) pid="$v" ;; esac
  done
  d="${FIX_HOME:-$CHARTROOM_HOME}/tasks/$id"; mkdir -p "$d"
  jq -n --arg id "$id" --arg b "$backend" --arg c "$(ago 9000)" \
    --arg disp "$([[ -n "$dispatched" ]] && ago "$dispatched")" --arg closed "$([[ -n "$closed" ]] && ago "$closed")" --arg pid "$pid" \
    '{schema:1,id:$id,title:("Task " + $id),kind:"ship",backend:$b,project:"/srv/code/todo-cli",branch:("chartroom/" + $id),created:$c,updated:$c}
     + (if $disp != "" then {dispatched:$disp} else {} end)
     + (if $closed != "" then {closed:$closed} else {} end)
     + (if $pid != "" then {pid:$pid} else {} end)' >"$d/meta.json"
  : >"$d/events.log"
  [[ -n "$dispatched" ]] && printf '%s note: dispatched via %s\n' "$(ago "$dispatched")" "$backend" >>"$d/events.log"
  local secs rest
  while read -r secs rest; do
    [[ -n "$secs" ]] && printf '%s %s\n' "$(ago "$secs")" "$rest" >>"$d/events.log"
  done
  return 0
}

DEAD=2147480000 # a pid no process has: the worker's process is gone
rows() { jq -r '[.agents[] | "\(.id) \(.state) \(.sector)"] | sort | join("\n")' <<<"$1"; }
agent() { jq -c --arg id "$1" '[.agents[] | select(.id == $id)][0]' <<<"$2"; }

# A machine "box" over the fake ssh: status.json is what its chartroom prints.
box() { mkdir -p "$SSHD/box"; cat >"$SSHD/box/status.json"; }
row() { # <id> <state> <live> [extra json]: one status row, as `status --json` prints it
  local x="${4:-}"; [[ -n "$x" ]] || x='{}'
  jq -cn --arg id "$1" --arg s "$2" --arg l "$3" --argjson x "$x" \
    '{id: $id, title: ("Task " + $id), kind: "ship", backend: "tmux:claude", project: "web", state: $s, live: $l,
      created: "2026-10-01T00:00:00Z", last: "progress: on it", last_at: "2026-10-29T10:00:00Z", dispatched: "2026-10-01T00:00:01Z",
      closed: null, has_report: false, waiting_on: null, waiting_until: null, waiting_since: null, short_id: ($id | .[-4:]),
      breaking: false, in_focus: true, held: false} + $x'
}
acme() { echo "[{\"home\": \"acme\", \"path\": \"/srv/acme\", \"current\": true, \"result\": [$1]}]"; } # <rows>: a current chartroom's shape

@test "local: every home on this machine, one record per task, keyed by machine, home and id" {
  A="$BATS_TEST_TMPDIR/acme"; G="$BATS_TEST_TMPDIR/globex"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  CHARTROOM_HOME="$G" cr init --name globex >/dev/null
  FIX_HOME="$A" fixture fix-it-21ba subagent <<<"300 progress: parser rewritten"
  FIX_HOME="$G" fixture fix-it-21ba subagent <<<"200 blocked: need staging credentials"
  FIX_HOME="$A" fixture t-draft subagent dispatched= </dev/null
  FIX_HOME="$A" fixture t-closed subagent closed=60 <<<"100 done: shipped"
  run env CHARTROOM_HOME="$A" "$CHARTROOM" radar --json
  [ "$status" -eq 0 ]
  local j="$output"
  # the machine: its label, every registered home, what it could read
  [ "$(jq -c '.machine | [.machine, .local, .contact, .capability, .via, .drafting, .herdr]' <<<"$j")" = '["Test Mac",true,"ok","all-homes","this machine",1,"unavailable"]' ]
  [ "$(jq -r '[.machine.homes[] | "\(.name):\(.open)"] | join(" ")' <<<"$j")" = "acme:2 globex:1" ]
  # the same id (and short id) in two homes: two records, two keys
  [ "$(jq -r '[.agents[] | .key] | sort | join(" ")' <<<"$j")" = "Test Mac/acme/fix-it-21ba Test Mac/globex/fix-it-21ba" ]
  local a; a="$(jq -c '[.agents[] | select(.home == "acme")][0]' <<<"$j")"
  [ "$(jq -c '[.machine, .local, .home, .home_path, .id, .short_id, .title, .project, .state, .sector, .live]' <<<"$a")" = \
    "[\"Test Mac\",true,\"acme\",\"$A\",\"fix-it-21ba\",\"21ba\",\"Task fix-it-21ba\",\"todo-cli\",\"working\",\"underway\",\"in-session\"]" ]
  [ "$(jq -c '.last_event | [.kind, .text]' <<<"$a")" = '["progress","parser rewritten"]' ]
  [ "$(jq -r '.last_activity_at == .last_event.at and (.last_activity_at | test("Z$"))' <<<"$a")" = true ]
  [ "$(jq -r '[.agents[] | select(.home == "globex")][0] | "\(.state) \(.sector)"' <<<"$j")" = "blocked blocked" ]
  # drafting and closed tasks are not drawn
  [ "$(jq '[.agents[] | select(.id == "t-draft" or .id == "t-closed")] | length' <<<"$j")" = 0 ]
  [ "$(jq '.flagships' <<<"$j")" = "[]" ]
}

@test "local: blocked and waiting come from the worker's own reports, never from guesses about motion" {
  local soon later past
  soon="$(jq -rn 'now + 3600 | todate')"; past="$(jq -rn 'now - 7200 | todate')"
  fixture t-blocked subagent <<<"600 blocked: need staging credentials"
  fixture t-decision subagent <<<"600 decision: pick option A or B (recommend A)"
  fixture t-wait command pid=$DEAD <<<"120 waiting: CI on PR 12 until $soon"
  fixture t-wait-open command pid=$DEAD <<<"120 waiting: the vendor's reply"
  fixture t-overdue command pid=$DEAD <<<"9000 waiting: review until $past"
  fixture t-silent command pid=$DEAD <<<"500 progress: halfway"
  fixture t-working subagent <<<"120 progress: parser rewritten, running tests"
  fixture t-inferred subagent <<<"200 progress: waiting on the design team to confirm the copy"
  fixture t-done subagent <<<"400 done: findings in report.md"
  echo "# Report" >"$CHARTROOM_HOME/tasks/t-done/report.md"
  fixture t-failed subagent <<<"300 failed: tests do not build"
  run cr radar --json
  [ "$status" -eq 0 ]
  local j="$output"
  # a worker's done is review (awaiting the commander), docked like done
  [ "$(rows "$j")" = "t-blocked blocked blocked
t-decision decision decision
t-done review docked
t-failed failed docked
t-inferred waiting holding
t-overdue overdue adrift
t-silent stopped-silent adrift
t-wait waiting holding
t-wait-open waiting holding
t-working working underway" ]
  # waiting carries what on and until when; blocked carries no wait at all
  [ "$(agent t-wait "$j" | jq -c '[.waiting.on, (.waiting.until | fromdateiso8601 > now), .inferred, .why]')" = \
    "[\"CI on PR 12 until $soon\",true,false,\"waiting on CI on PR 12 until $soon\"]" ]
  [ "$(agent t-wait-open "$j" | jq -c '[.waiting.on, .waiting.until]')" = '["the vendor'"'"'s reply",null]' ]
  [ "$(agent t-blocked "$j" | jq -c '[.waiting, .why, .last_event.kind]')" = '[null,"reported it cannot proceed","blocked"]' ]
  [ "$(agent t-overdue "$j" | jq -r '.why')" = "waited past its window (on review until $past)" ]
  [ "$(agent t-silent "$j" | jq -c '[.live, .why]')" = '["stopped","its process stopped without reporting"]' ]
  # a wait read from the text is marked as such: not the worker's `waiting` report
  [ "$(agent t-inferred "$j" | jq -c '[.inferred, .waiting.on, .status_state]')" = '[true,"waiting on the design team to confirm the copy","working"]' ]
  [ "$(agent t-done "$j" | jq -c '[.has_report, .why]')" = '[true,"reported done, awaiting your review; a report to read"]' ]
}

@test "remote: the state table, row by row, from another machine's status" {
  {
    echo '['
    jq -cn --argjson rows "[$(row r-await awaiting-input blocked),$(row r-lost stopped-silent gone),$(row r-unknown working unknown),
      $(row r-livewait working working '{"waiting_on":"CI","waiting_until":"2030-01-01T00:00:00Z","waiting_since":"2026-10-29T09:00:00Z","last":"waiting: CI until 2030-01-01T00:00:00Z"}'),
      $(row r-weird mystery stopped),$(row r-fail failed stopped),$(row r-draft drafting not-started),$(row r-gone closed -)]" \
      '{home: "acme", path: "/srv/acme", current: true, result: $rows}'
    echo ','
    echo '{"home": "broken", "path": "/srv/broken", "current": false, "error": "not a chartroom home (no /srv/broken/tasks)"}]'
  } | box
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box --via config
  [ "$status" -eq 0 ]
  local j="$output"
  [ "$(rows "$j")" = "r-await awaiting-input blocked
r-fail failed docked
r-livewait waiting holding
r-lost lost adrift
r-unknown working underway
r-weird unknown adrift" ]
  [ "$(jq -c '.machine | [.machine, .local, .target, .via, .contact, .capability, .note, .drafting]' <<<"$j")" = '["box",false,"box","config","ok","all-homes",null,1]' ]
  [ "$(jq -c '[.machine.homes[] | [.name, .path, .open, .error]]' <<<"$j")" = '[["acme","/srv/acme",8,null],["broken","/srv/broken",0,"not a chartroom home (no /srv/broken/tasks)"]]' ]
  [ "$(agent r-await "$j" | jq -r .why)" = "stopped at a permission or question prompt" ]
  [ "$(agent r-lost "$j" | jq -r .why)" = "its session is gone and nothing was reported" ]
  [ "$(agent r-unknown "$j" | jq -c '[.live_uncertain, .why]')" = '[true,"reported working; its backend could not be checked (live: unknown)"]' ]
  [ "$(agent r-livewait "$j" | jq -c '[.why, .waiting.until, .waiting.since]')" = '["waiting on CI; its process is still live","2030-01-01T00:00:00Z","2026-10-29T09:00:00Z"]' ]
  [ "$(agent r-weird "$j" | jq -r .why)" = "state mystery" ]
  [ "$(jq -r '[.agents[] | .key] | first' <<<"$j")" = "box/acme/r-await" ]
}

@test "remote: an older chartroom (it ignores --all-homes) is read as its one default home, and says so" {
  echo "[$(row r-old-1 blocked stopped),$(row r-old-2 working working)]" | box
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$status" -eq 0 ]
  local j="$output"
  [ "$(jq -c '.machine | [.contact, .capability, .note]' <<<"$j")" = '["ok","single-home","older chartroom: shows its default home only; update chartroom there to see every home"]' ]
  [ "$(jq -c '.machine.homes' <<<"$j")" = '[{"name":"default","path":null,"open":2,"error":null}]' ]
  [ "$(rows "$j")" = "r-old-1 blocked blocked
r-old-2 working underway" ]
  [ "$(jq -r '.agents[0] | "\(.key) \(.home_path)"' <<<"$j")" = "box/default/r-old-1 null" ]
  # no open tasks at all reads the same way: nothing to draw, nothing wrong
  echo '[]' | box
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -c '[.machine.contact, .machine.capability, (.agents | length)]' <<<"$output")" = '["ok","single-home",0]' ]
}

@test "remote: an unreachable machine, or one without chartroom, says why and invents no agents" {
  # no route at all (ssh's own failure, 255)
  run "$CHARTROOM" radar --json --machine box --ssh box
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.machine.contact, .machine.error, .machine.capability, (.agents | length), (.flagships | length)]' <<<"$output")" = \
    '["unreachable","ssh: connect to host box port 22: Connection refused",null,0,0]' ]
  mkdir -p "$SSHD/box"; echo 255 >"$SSHD/box/exit"; printf 'ssh: connect to host box port 22: Operation timed out\r\n' >"$SSHD/box/stderr"
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -c '[.machine.contact, .machine.error]' <<<"$output")" = '["unreachable","ssh: connect to host box port 22: Operation timed out"]' ]
  # reached, but there is no chartroom on its PATH
  echo 127 >"$SSHD/box/exit"; echo 'zsh:1: command not found: chartroom' >"$SSHD/box/stderr"
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -c '[.machine.contact, .machine.error, (.agents | length)]' <<<"$output")" = '["no-chartroom","zsh:1: command not found: chartroom",0]' ]
  # a chartroom too old for status --json
  echo 1 >"$SSHD/box/exit"; echo "chartroom: unknown command 'status' (try: chartroom help)" >"$SSHD/box/stderr"
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -r .machine.contact <<<"$output")" = no-chartroom ]
  # output that is not the status array
  rm "$SSHD/box/exit"; echo 'Welcome to box!' >"$SSHD/box/status.json"
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -c '[.machine.contact, .machine.error, (.agents | length)]' <<<"$output")" = '["error","Welcome to box!",0]' ]
  echo '{"not": "an array"}' >"$SSHD/box/status.json"
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -c '[.machine.contact, (.agents | length)]' <<<"$output")" = '["error",0]' ]
}

@test "remote: only reads ever run there; peek and file refuse anything else before ssh" {
  echo "[$(row r-1 blocked stopped)]" | box
  printf '== events\n2026-10-29T10:00:00Z blocked: need creds\n== pane (recent)\n> waiting\n' >"$SSHD/box/peek.txt"
  mkdir -p "$SSHD/box/files"; echo "# Box report" >"$SSHD/box/files/report.md"
  export FAKE_SSH_DIR="$SSHD"
  cr radar --json --machine box --ssh box >/dev/null
  run cr radar peek --machine box --ssh box --home /srv/acme r-1 5
  [ "$status" -eq 0 ]; [[ "$output" == *"blocked: need creds"* ]]
  run cr radar peek --machine box --ssh box r-1 # an older chartroom: its default home
  [ "$status" -eq 0 ]
  [ "$(cr radar file --machine box --ssh box --home /srv/acme r-1 report.md)" = "# Box report" ]
  run cr radar file --machine box --ssh box r-1 report.md # without a home path: through its own peek
  [ "$status" -eq 0 ]
  local before; before="$(wc -l <"$SSHD/calls.log")"
  # refused before any ssh: a bad id, home, file, count; another file without a home path
  run cr radar peek --machine box --ssh box --home /srv/acme "r-1;reboot" 5; [ "$status" -ne 0 ]
  run cr radar peek --machine box --ssh box --home "/srv/acme'; rm -rf ~; '" r-1 5; [ "$status" -ne 0 ]
  run cr radar peek --machine box --ssh box --home /srv/acme r-1 9999; [ "$status" -ne 0 ]
  run cr radar file --machine box --ssh box --home /srv/acme r-1 meta.json; [ "$status" -ne 0 ]
  run cr radar file --machine box --ssh box --home /srv/acme ../r-1 report.md; [ "$status" -ne 0 ]
  run cr radar file --machine box --ssh box r-1 brief.md
  [ "$status" -ne 0 ]; [[ "$output" == *"older chartroom"*"only report.md"* ]]
  [ "$(wc -l <"$SSHD/calls.log")" -eq "$before" ]
  # everything that ran there: status, peek, cat of a task file; no other command
  local bad; bad="$(grep -vE "^box (PATH=\"[^\"]*\" chartroom status --json --all-homes|PATH=\"[^\"]*\" (CHARTROOM_HOME='/srv/acme' )?chartroom peek 'r-1' [0-9]+|cat '/srv/acme/tasks/r-1/report\.md'|p=\\\$\(PATH=\"[^\"]*\" chartroom peek 'r-1' 1 .*)$" "$SSHD/calls.log" || true)"
  [ -z "$bad" ] || { echo "unexpected remote commands: $bad"; cat "$SSHD/calls.log"; false; }
  [ "$(wc -l <"$SSHD/calls.log")" -eq 5 ]
}

@test "machines: CHARTROOM_RADAR_MACHINES, else herdr's saved machines, else this machine alone" {
  run cr radar machines --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.machines' <<<"$output")" = '[{"machine":"Test Mac","local":true,"target":null,"via":"this machine"}]' ]
  [ "$(jq -c '.settings' <<<"$output")" = '{"local_min":15,"local_max":60,"remote":60,"done_hours":24,"stale_days":3}' ]
  # herdr's enabled saved machines (a herdr that is not running is the same as none)
  use_fake herdr
  [ "$(cr radar machines --json | jq '.machines | length')" = 1 ]
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  echo '[{"id":"1","label":"studio","target":"me@desk.example","enabled":true},{"id":"2","label":"old","target":"old","enabled":false},{"id":"3","label":"bad name;x","target":"x","enabled":true}]' >"$FAKE_HERDR_DIR/machines.json"
  [ "$(cr radar machines --json | jq -c '.machines[1:]')" = '[{"machine":"studio","local":false,"target":"me@desk.example","via":"herdr"}]' ]
  # the setting wins over herdr; "none" turns other machines off
  [ "$(CHARTROOM_RADAR_MACHINES="a b=b.example" cr radar machines --json | jq -c '[.machines[1:][] | [.machine, .target, .via]]')" = '[["a","a","config"],["b","b.example","config"]]' ]
  [ "$(CHARTROOM_RADAR_MACHINES=none cr radar machines --json | jq '.machines | length')" = 1 ]
  run env CHARTROOM_RADAR_MACHINES='x=$(reboot)' "$CHARTROOM" radar machines --json
  [ "$status" -ne 0 ]; [[ "$output" == *"is not label[=ssh-target]"* ]]
  run env CHARTROOM_RADAR_REMOTE_SECONDS=soon "$CHARTROOM" radar machines --json
  [ "$status" -ne 0 ]; [[ "$output" == *"CHARTROOM_RADAR_REMOTE_SECONDS must be a whole number"* ]]
  [ "$(CHARTROOM_RADAR_LOCAL_MAX_SECONDS=120 cr radar machines --json | jq .settings.local_max)" = 120 ]
}

@test "machines: the archive's cutoffs are CHARTROOM_RADAR_DONE_HOURS and CHARTROOM_RADAR_STALE_DAYS, whole and above 0" {
  [ "$(CHARTROOM_RADAR_DONE_HOURS=6 CHARTROOM_RADAR_STALE_DAYS=10 cr radar machines --json | jq -c '[.settings.done_hours, .settings.stale_days]')" = '[6,10]' ]
  # from the home's config too, like every radar setting
  echo "CHARTROOM_RADAR_STALE_DAYS=7" >>"$CHARTROOM_HOME/config"
  [ "$(cr radar machines --json | jq .settings.stale_days)" = 7 ]
  local bad
  for bad in DONE_HOURS=0 DONE_HOURS=1.5 STALE_DAYS=soon STALE_DAYS=-1; do
    run env "CHARTROOM_RADAR_$bad" "$CHARTROOM" radar machines --json
    [ "$status" -ne 0 ]; [[ "$output" == *"CHARTROOM_RADAR_${bad%%=*} must be a whole number of "*", above 0"* ]]
  done
}

@test "local: a record carries its branch, base and the open tasks its brief or events name, for the radar's stacks" {
  fixture first-pr-aa01 subagent <<<"300 progress: opened PR 1"
  fixture second-pr-aa02 subagent <<<"200 progress: building on first-pr-aa01's branch"
  fixture handoff-aa03 subagent <<<"100 progress: started"
  fixture closed-one-aa04 subagent closed=60 <<<"100 done: shipped"
  local d="$CHARTROOM_HOME/tasks"
  jq '.base = "chartroom/first-pr-aa01"' "$d/second-pr-aa02/meta.json" >"$d/x" && mv "$d/x" "$d/second-pr-aa02/meta.json"
  printf '# T\n\n## Spec\n\nFollow-up to second-pr-aa02 (see also closed-one-aa04, and second-pr-aa02 again).\n' >"$d/handoff-aa03/brief.md"
  run cr radar --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.agents[] | [.id, .branch, .base, .mentions]] | sort' <<<"$output")" = \
    '[["first-pr-aa01","chartroom/first-pr-aa01",null,[]],["handoff-aa03","chartroom/handoff-aa03",null,["second-pr-aa02"]],["second-pr-aa02","chartroom/second-pr-aa02","chartroom/first-pr-aa01",["first-pr-aa01"]]]' ]
  # status --json carries them too (another machine's radar reads that)
  [ "$(cr status --json | jq -c '[.[] | select(.id == "handoff-aa03") | .mentions]')" = '[["second-pr-aa02"]]' ]
}

@test "machines: this machine's label is CHARTROOM_MACHINE_NAME (env, the home's config, the config file), else its host name" {
  unset CHARTROOM_MACHINE_NAME
  local n; n="$(cr radar machines --json | jq -r '.machines[0].machine')"
  [ -n "$n" ]; [[ "$n" != *.* ]]
  printf 'CHARTROOM_MACHINE_NAME="Macbook M5"\n' >"$CHARTROOM_CONFIG"
  [ "$(cr radar machines --json | jq -r '.machines[0].machine')" = "Macbook M5" ]
  printf 'CHARTROOM_MACHINE_NAME=desk\n' >"$CHARTROOM_HOME/config"
  [ "$(cr radar machines --json | jq -r '.machines[0].machine')" = desk ]
  [ "$(CHARTROOM_MACHINE_NAME=env-wins cr radar machines --json | jq -r '.machines[0].machine')" = env-wins ]
  [ "$(cr radar --json | jq -r .machine.machine)" = desk ]
}

@test "flagships: a herdr agent whose cwd is a home is that home's XO, untracked; a worker is not" {
  A="$BATS_TEST_TMPDIR/acme"
  CHARTROOM_HOME="$A" cr init --name acme >/dev/null
  use_fake herdr
  export FAKE_HERDR_DIR="$BATS_TEST_TMPDIR/herdr"; mkdir -p "$FAKE_HERDR_DIR"; herdr_sock_up
  jq -n --arg a "$A" '{result: {agents: [
    {agent: "claude", agent_status: "working", cwd: $a, pane_id: "w1:p1", terminal_title_stripped: "XO session"},
    {agent: "claude", agent_status: "idle", cwd: ($a + "/worktrees/x"), pane_id: "w1:p2", name: "t-x"}]}}' >"$FAKE_HERDR_DIR/agent-list.json"
  run env CHARTROOM_HOME="$A" "$CHARTROOM" radar --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.flagships' <<<"$output")" = \
    "[{\"key\":\"Test Mac/acme/xo/w1:p1\",\"machine\":\"Test Mac\",\"local\":true,\"home\":\"acme\",\"home_path\":\"$A\",\"kind\":\"xo\",\"pane\":\"w1:p1\",\"agent\":\"claude\",\"status\":\"working\",\"title\":\"XO session\",\"why\":\"untracked: no events\"}]" ]
  [ "$(jq -r .machine.herdr <<<"$output")" = ok ]
  # its screen, read through herdr
  run cr radar peek --machine "Test Mac" --pane w1:p1
  [ "$status" -eq 0 ]; [[ "$output" == "== screen (recent)"* ]]
  run cr radar peek --machine "Test Mac" --pane 'w1:p1;x'
  [ "$status" -ne 0 ]
  # another machine with an older chartroom: a cwd that is a default home's directory
  mkdir -p "$FAKE_HERDR_DIR/machine-box"
  echo '{"result":{"agents":[{"agent":"claude","agent_status":"idle","cwd":"/srv/u/.captain","pane_id":"w9:p1"},{"agent":"claude","agent_status":"idle","cwd":"/srv/u/code","pane_id":"w9:p2"}]}}' >"$FAKE_HERDR_DIR/machine-box/agent-list.json"
  echo "[$(row r-1 working working)]" | box
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq -c '[.flagships[] | [.home, .home_path, .pane, .status]]' <<<"$output")" = '[["default","/srv/u/.captain","w9:p1","idle"]]' ]
  # a herdr that never answers costs the XOs only, ~10s past ssh, never the machine's contact
  touch "$FAKE_HERDR_DIR/machine-box/hang"
  local t0=$SECONDS
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box 3>&-
  [ "$status" -eq 0 ]; [ $((SECONDS - t0)) -lt 30 ]
  [ "$(jq -c '[.machine.contact, .machine.herdr, (.agents | length), (.flagships | length)]' <<<"$output")" = '["ok","unavailable",1,0]' ]
  rm "$FAKE_HERDR_DIR/machine-box/hang"
  # unreachable: no flagships either
  rm "$SSHD/box/status.json"; echo 255 >"$SSHD/box/exit"
  run env FAKE_SSH_DIR="$SSHD" "$CHARTROOM" radar --json --machine box --ssh box
  [ "$(jq '.flagships | length' <<<"$output")" = 0 ]
}

@test "the inferred-wait rule is the board's own (lanes.jq), word for word" {
  local a b
  a="$(grep -A1 '^def waits_on_person:' "$REPO_ROOT/lib/lanes.jq")"
  b="$(grep -A1 '^def waits_on_person:' "$REPO_ROOT/lib/radar.jq")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

@test "text view: the machine, then its agents by sector, attention first" {
  fixture t-blocked subagent <<<"600 blocked: need staging credentials"
  fixture t-working subagent <<<"120 progress: parser rewritten"
  run cr radar
  [ "$status" -eq 0 ]
  [[ "$output" == "== Test Mac (this machine): ok"*"BLOCKED (1)"*"t-blocked"*"UNDERWAY (1)"*"t-working"* ]]
  run cr radar --machine box
  [ "$status" -ne 0 ]; [[ "$output" == *"--machine and --ssh go together"* ]]
}
