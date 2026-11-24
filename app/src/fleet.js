// fleet.js - Fleet (slice 5): the machines that run the crew, their health (contact, logins, tools,
// disk), what they have in use against their limits, and the workers on them, from `chartroom app
// fleet --json` (lib/app/fleet.jq, over `chartroom nodes`). A machine row selects it; its detail sits
// in the slim column. Hand-offs and conn holders show as not tracked yet rather than as made-up data. The same
// machines as an atom or a dashboard: fleetviews.js.
import { html, useState } from "./html.js";
import { Status, Linked, Tabs } from "./ui.js";
import { ViewSwitch, savedView, saveView, AtomView, DashView } from "./fleetviews.js";

const M = window.AppModel;
const STATE = { healthy: "Healthy", degraded: "Needs a look", down: "Unreachable" };

function pct(n) { return n == null ? "—" : Math.round(n) + "%"; }
const secs = M.ageText;
// How the brain knows a machine: itself, an enrolled device's heartbeat (pushed by the device; the
// brain never reaches out), or, until it enrols, the probe over ssh.
function via(m) {
  if (m.brain) return "this machine";
  if (m.device) {
    const d = m.device;
    return d.status === "online" || d.status === "stale" ? d.status + " · heartbeat " + secs(d.seen_age_s) + " ago"
      : d.status === "lost" ? "lost · last heartbeat " + secs(d.seen_age_s) + " ago"
      : d.status === "new" ? "enrolled · no heartbeat yet" : d.status === "revoked" ? "revoked" : "not heard (the brain's endpoint is down)";
  }
  return "read over ssh (not enrolled)";
}
// Its workers, for information: an XO or a person's own agent is shown apart. An hc with no event
// stream cannot tell them apart, so then every live agent counts.
const crew = M.crewOf;
// What is in use against the node's limit: at or over it, the node takes no new task.
function Use({ label, use, limit }) {
  const over = use != null && limit != null && use >= limit;
  return html`<span class=${"m-use" + (over ? " warn-t" : "")} title=${label + " in use" + (limit != null ? "; at " + limit + "% it takes no new task" : "")}>
    <span class="faint">${label}</span><span class="m-bar"><i style=${{ width: Math.min(100, use || 0) + "%" }} class=${over ? "over" : ""}></i>${limit != null ? html`<b style=${{ left: limit + "%" }}></b>` : null}</span>
    ${pct(use)}${limit != null ? html` <span class="faint">of ${limit}%</span>` : null}</span>`;
}

function Checks({ m }) {
  const all = [{ ok: m.state !== "down", label: "network", detail: m.state === "down" ? m.error || "not reached" : "reached" }]
    .concat(m.logins, m.tools, (m.extra || []).map((c) => Object.assign({ warn: true }, c)),
      m.disk_free_pct != null ? [{ ok: m.disk_free_pct >= 15, label: "disk", detail: pct(m.disk_free_pct) + " free" }] : []);
  // ok: true passes, false fails (warn: it never changes the machine's health), null cannot be told (a
  // sign-in behind a broken tool): shown, never counted
  return html`<div class="m-l2">${all.map((c) => html`<span key=${c.label} class=${"ck" + (c.ok ? " ok" : c.ok === false ? (c.warn ? " warn" : " bad") : " unk")} title=${c.detail || ""}>
    <span class="ck-i">${c.ok ? "✓" : c.ok === false ? (c.warn ? "!" : "✕") : "?"}</span>${c.label}</span>`)}</div>`;
}

export function FleetPage({ fleet, workers, tasks, sel, setSel, onRefresh, onSession, actionFor, toast }) {
  const [tab, setTab] = useState("machines");
  const [view, setView] = useState(savedView);
  const pickView = (v) => { setView(v); saveView(v); onSession(null, false); };
  const ms = (fleet && fleet.machines) || [];
  if (!fleet) {
    return html`<main class="a-main"><header class="a-head"><div class="a-head-l"><h1>Fleet</h1></div></header>
      <div class="page-body"><p class="dt-empty">Reading the machines… (this one's probe and each device's last heartbeat; a machine not enrolled yet over ssh, up to a minute)</p></div></main>`;
  }
  const bad = ms.filter((m) => m.state !== "healthy");
  const live = workers.length;
  const sum = bad.length
    ? bad.map((m) => m.name + (m.state === "down" ? " cannot be reached" : " needs a look: " + m.failing.join(", "))).join("; ") + "."
    : "All " + ms.length + " machines are healthy.";
  const tabs = [{ id: "machines", label: "Machines", count: ms.length }, { id: "workers", label: "Workers", count: live },
    { id: "attempts", label: "Attempts" }, { id: "xos", label: "XOs" }];
  return html`<main class="a-main">
    <header class="a-head"><div class="a-head-l"><h1>Fleet</h1><span class="faint">${ms.length} machines · ${live} working · checked ${M.agoText(fleet.checked_at)}</span></div>
      <button class="btn ghost sm" onClick=${onRefresh}>Check again</button></header>
    <div class="page-body">
      <div class="fleet-sum"><span class=${"glyph " + (bad.length ? "blocked" : "ok")}></span><p>${sum}</p></div>
      ${fleet.error ? html`<p class="err-t">${fleet.error}</p>` : null}
      <div class="fv-bar"><${ViewSwitch} view=${view} onPick=${pickView} /></div>
      ${view === "atom" ? html`<${AtomView} fleet=${fleet} tasks=${tasks} sel=${sel} onSelect=${setSel} onSession=${onSession} actionFor=${actionFor} />`
      : view === "dash" ? html`<${DashView} fleet=${fleet} tasks=${tasks} sel=${sel} onSelect=${setSel} onSession=${onSession} actionFor=${actionFor} toast=${toast} />` : null}
      ${view !== "list" ? null : html`<${Tabs} tabs=${tabs} active=${tab} onPick=${setTab} />`}
      ${view !== "list" ? null : tab === "machines" ? html`<div class="m-list">${ms.map((m) => html`<div key=${m.name} class=${"m-row" + (sel === m.name ? " sel" : "")} onClick=${() => setSel(m.name)}>
          <div class="m-l1"><span class=${"glyph " + (m.state === "healthy" ? "ok" : "blocked")}></span><span class="m-name">${m.name}</span>
            <span class="m-role faint">${m.brain ? "brain" : m.role}</span><span class=${m.state === "healthy" ? "faint" : "warn-t"}>${STATE[m.state]}</span>
            <span class="m-via faint">${via(m)}</span>
            <span class="grow"></span>
            <span class="m-power faint">${m.power === "battery" ? "on battery" + (m.battery_pct != null ? " " + m.battery_pct + "%" : "") : m.power === "ac" ? "plugged in" : ""}</span>
            ${m.crew_live != null || m.agents_live != null ? html`<span class="m-slots faint" title="for information: the limits are its CPU and memory use">${crew(m)} worker${crew(m) === 1 ? "" : "s"}${m.other_agents ? " · " + m.other_agents + " other" : ""}</span>` : null}</div>
          <${Checks} m=${m} />
          ${m.state !== "down" ? html`<div class="m-l3"><${Use} label="CPU" use=${m.cpu_use} limit=${m.budgets && m.budgets.cpu} /><${Use} label="Memory" use=${m.mem_used_pct} limit=${m.budgets && m.budgets.mem} />
            ${m.full ? html`<span class="warn-t">Takes no new work: ${m.full}</span>` : m.budgets && m.budgets.cpu ? html`<span class="faint">Takes new work</span>` : null}</div>` : null}
        </div>`)}</div>`
      : tab === "workers" ? html`<div class="w-table">${workers.length ? workers.map((t) => html`<div key=${t.key} class="w-row">
          <span class="pulse"></span><span class="faint">${t.short_id}</span><span class="w-title truncate"><${Linked} text=${t.title} /></span>
          <span class="faint">${t.machine || "the brain"}</span><span class="w-att faint">attempt 1</span><span class="faint">${t.dispatched ? M.ago(t.dispatched) : ""}</span>
          <span class="w-state truncate">${t.line || ""}</span><span class="faint">${t.home}</span></div>`) : html`<p class="dt-empty" style=${{ padding: "16px" }}>No worker is running.</p>`}</div>`
      : html`<p class="dt-empty">${tab === "attempts" ? "Hand-offs between machines come later: a running worker stays on the machine it started on."
          : "Who holds each home's conn comes with the conn lease (one brain, step 3). Until then, answers wait in each home's mailbox for its XO's next watch."}</p>`}
    </div>
  </main>`;
}

export function MachineDetail({ m, workers, names }) {
  if (!m) return html`<aside class="a-detail slim"><p class="faint q-keys">Select a machine.</p></aside>`;
  // a worker runs on its home's machine; one whose machine Fleet does not list runs on the brain
  const mine = workers.filter((w) => w.machine === m.name || (m.brain && !(names || []).includes(w.machine)));
  const fixes = M.SIGN_IN, own = (m.agents || []).filter((a) => a.kind !== "crew");
  return html`<aside class="a-detail slim" aria-label=${m.name}>
    <h2 class="a-detail-title">${m.name} <span class="m-role faint">${m.brain ? "the brain" : m.role}</span></h2>
    <dl class="sp">
      <dt>Health</dt><dd>${STATE[m.state]}</dd>
      <dt>Connection</dt><dd>${via(m)}${m.device && m.device.version ? html` <span class="faint">· chartroom ${m.device.version}</span>` : null}</dd>
      ${m.failing.length ? html`<dt>To fix</dt><dd><ul class="checks">${m.failing.map((f) => html`<li key=${f}><span class="glyph blocked"></span><span><b>${f}</b>
        ${fixes[f] ? html`<br /><span class="faint">on ${m.name}: <code>${fixes[f]}</code></span>` : null}</span></li>`)}</ul></dd>` : null}
      <dt>Load</dt><dd>${m.load ? m.load.map((x) => x.toFixed(1)).join(" · ") : "—"}${m.cores ? html` <span class="faint">on ${m.cores} cores</span>` : null}</dd>
      <dt>CPU in use</dt><dd>${pct(m.cpu_use)}${m.budgets && m.budgets.cpu ? html` <span class="faint">limit ${m.budgets.cpu}%, over the last minute</span>` : null}</dd>
      <dt>Memory in use</dt><dd>${pct(m.mem_used_pct)}${m.budgets && m.budgets.mem ? html` <span class="faint">limit ${m.budgets.mem}%, as Activity Monitor counts it</span>` : null}</dd>
      <dt>Disk free</dt><dd>${pct(m.disk_free_pct)}</dd>
      <dt>Agents</dt><dd>${m.crew_live != null ? html`${m.crew_live} crew${m.other_agents ? html` <span class="faint">· ${m.other_agents} other (XOs, your own sessions)</span>` : null}` : m.agents_live != null ? html`${m.agents_live} <span class="faint">(crew and others together)</span>` : "—"}</dd>
      ${own.length ? html`<dt>XOs and your sessions</dt><dd><div class="sp-ms">${own.map((a) => html`<div key=${a.address} class="sp-m" title=${a.where || ""}><span class="grow truncate">${M.agentLabel(a)}</span><span class="faint">${a.state === "done" ? "idle" : a.state || ""}</span></div>`)}</div></dd>` : null}
      <dt>Limits</dt><dd>${m.budgets ? html`CPU ${m.budgets.cpu}% · memory ${m.budgets.mem}%${m.budgets.on_battery ? " · on battery: " + m.budgets.on_battery : ""}<br /><span class="faint">change: <code>chartroom node limits ${m.brain ? "here" : m.name} 80/70</code></span>` : html`<span class="faint">Not a node yet (chartroom node init)</span>`}</dd>
      <dt>Power</dt><dd>${m.power === "battery" ? "On battery" + (m.battery_pct != null ? " (" + m.battery_pct + "%)" : "") : m.power === "ac" ? "Plugged in" : "—"}</dd>
      <dt>Workers</dt><dd>${mine.length ? html`<div class="sp-ms">${mine.map((w) => html`<div key=${w.key} class="sp-m"><${Status} status="working" only=${true} /><span class="grow truncate">${w.title}</span></div>`)}</div>` : html`<span class="faint">None</span>`}</dd>
    </dl>
  </aside>`;
}
