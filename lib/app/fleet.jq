# fleet.jq - the machines as the app's Fleet shows them (slice 5), from `chartroom nodes --json`
# (lib/nodes.sh: this machine's probe, each enrolled device's last heartbeat, and over ssh any
# machine not enrolled yet). Input: that JSON. The brain is the machine `nodes` ran on (its .local
# node): every worker runs there until remote dispatch.
# What a machine's health means is decided here, never in the server:
#   healthy   reached, no sign-in found signed out, the crew's tools answer, disk free >= 15%
#   degraded  reached, with a check failing (signed out, a tool missing or broken, low disk), or a
#             device whose heartbeat is late (stale: what it last said is shown)
#   down      not reached (its contact failed; for a device: lost, revoked, or not heard yet)
# A signed-out tool is also a Needs me item: only the commander can sign in again (one brain: an
# expired login goes to the inbox). A sign-in that cannot be told is shown, never counted.

def check($ok; $label; $detail): {ok: $ok, label: $label, detail: $detail};
def tool_ok: .status == "ok";
# A sign-in (the probe's ok|no|unknown|missing): failed only when the tool itself answers and says
# it is signed out. When the tool is broken or missing the sign-in cannot be told (ok: null), and
# the tool's own check is what fails.
def login_check($tools):
  (.key) as $k | ($tools[$k] // {} | tool_ok) as $tool
  | if .value.status == "ok" then check(true; ($k + " sign-in"); .value.detail)
    elif .value.status == "no" and $tool then check(false; ($k + " sign-in"); (.value.detail // "not signed in"))
    elif .value.status == "no" then check(null; ($k + " sign-in"); ("cannot tell: " + $k + " itself does not answer"))
    elif .value.status == "missing" then check(null; ($k + " sign-in"); "not installed")
    else check(null; ($k + " sign-in"); (.value.detail // "unknown")) end;
([.nodes[]? | select(.local == true) | .machine] | first // null) as $brain
| [.nodes[]? | . as $n
    | (($n.contact // "") == "ok") as $up
    | [ ($n.logins // {} | to_entries[] | login_check($n.tools // {})) ] as $logins
    | [ ($n.tools // {} | to_entries[] | select(.key | test("^(git|jq|bash|claude|codex|gh|chartroom)$"))
        | check(.value | tool_ok; .key; (.value.version // .value.status))) ] as $tools
    | ($n.disk_free_pct // null) as $disk
    | ([$logins[], $tools[]] | map(select(.ok == false))) as $failing
    | ($n.device // null) as $dev
    | (if $dev != null and $dev.status == "stale" then ["no heartbeat for \($dev.seen_age_s)s"] else [] end) as $late
    | {name: ($n.machine // $n.target // "?"), role: ($n.role // "node"), brain: (($n.machine // "") == $brain),
       state: (if ($up | not) then "down" elif ($failing | length) > 0 or ($late | length) > 0 or ($disk != null and $disk < 15) then "degraded" else "healthy" end),
       # how the brain knows: "this machine", "heartbeat" (an enrolled device), else the ssh list
       source: ($n.via // null), device: $dev,
       error: ($n.error // null), contact: ($n.contact // null),
       power: ($n.power // null), battery_pct: ($n.battery_pct // null), idle_s: ($n.hid_idle_s // null),
       cores: ($n.cores // null), load: ($n.load // null), mem_free_pct: ($n.mem_free_pct // null), disk_free_pct: $disk,
       budgets: ($n.budgets // null), util: ($n.util // null), agents_live: ($n.agents_live // null),
       # the crew (chartroom's workers, the slots against max_workers) and the other agents apart;
       # null crew: an hc with no event stream, where every live agent is all that can be told
       crew_live: ($n.crew_live // null), other_agents: ($n.other_agents // null), path_source: ($n.path_source // null),
       logins: $logins, tools: $tools,
       failing: ($late + [$failing[] | .label] + (if $disk != null and $disk < 15 then ["disk below 15% free"] else [] end)),
       on_battery: (($n.power // "") == "battery")}]
| {machines: (sort_by([(if .brain then 0 else 1 end), .name])),
   needs: [.[] | . as $m | $m.logins[] | select(.ok == false)
     | {id: ("login-" + $m.name + "-" + (.label | split(" ")[0])), type: "fleet", kind: "login", group: "unblock",
        machine: $m.name,
        title: ("Sign in to " + (.label | split(" ")[0]) + " on " + $m.name),
        summary: ("Sign in again on " + $m.name + ": " + ({"claude": "claude /login", "codex": "codex login", "gh": "gh auth login"}[.label | split(" ")[0]] // "sign in")
                  + ". Until then " + $m.name + " takes no new work that needs it."),
        detail: .detail, at: null, breaking: false, held: false}]}
