// fleet.js - Fleet (slice 5): the machines that run the crew, their health (contact, logins, tools,
// disk), their budgets and the workers on them, from `chartroom app fleet --json` (lib/app/fleet.jq,
// over `chartroom nodes`). A machine row selects it; its detail sits in the slim column. Until remote
// dispatch (one brain, step 4) every worker runs on the brain, at attempt 1; attempts and conn
// holders show as not tracked yet rather than as made-up data.
import { html, useState } from "./html.js";
import { Status, Linked, Tabs } from "./ui.js";

const M = window.AppModel;
const STATE = { healthy: "Healthy", degraded: "Needs a look", down: "Unreachable" };

function pct(n) { return n == null ? "—" : Math.round(n) + "%"; }

function Checks({ m }) {
  const all = [{ ok: m.state !== "down", label: "network", detail: m.state === "down" ? m.error || "not reached" : "reached" }]
    .concat(m.logins, m.tools,
      m.disk_free_pct != null ? [{ ok: m.disk_free_pct >= 15, label: "disk", detail: pct(m.disk_free_pct) + " free" }] : []);
  // ok: true passes, false fails, null cannot be told (a sign-in behind a broken tool): shown, never counted
  return html`<div class="m-l2">${all.map((c) => html`<span key=${c.label} class=${"ck" + (c.ok ? " ok" : c.ok === false ? " bad" : " unk")} title=${c.detail || ""}>
    <span class="ck-i">${c.ok ? "✓" : c.ok === false ? "✕" : "?"}</span>${c.label}</span>`)}</div>`;
}

export function FleetPage({ fleet, workers, sel, setSel, onRefresh }) {
  const [tab, setTab] = useState("machines");
  const ms = (fleet && fleet.machines) || [];
  if (!fleet) {
    return html`<main class="a-main"><header class="a-head"><div class="a-head-l"><h1>Fleet</h1></div></header>
      <div class="page-body"><p class="dt-empty">Reading the machines… (every machine's probe, over ssh for the others: up to a minute)</p></div></main>`;
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
      <${Tabs} tabs=${tabs} active=${tab} onPick=${setTab} />
      ${tab === "machines" ? html`<div class="m-list">${ms.map((m) => html`<div key=${m.name} class=${"m-row" + (sel === m.name ? " sel" : "")} onClick=${() => setSel(m.name)}>
          <div class="m-l1"><span class=${"glyph " + (m.state === "healthy" ? "ok" : "blocked")}></span><span class="m-name">${m.name}</span>
            <span class="m-role faint">${m.brain ? "brain" : m.role}</span><span class=${m.state === "healthy" ? "faint" : "warn-t"}>${STATE[m.state]}</span>
            <span class="grow"></span>
            <span class="m-power faint">${m.power === "battery" ? "on battery" + (m.battery_pct != null ? " " + m.battery_pct + "%" : "") : m.power === "ac" ? "plugged in" : ""}</span>
            ${m.budgets && m.budgets.max_workers ? html`<span class="m-slots faint"><span class="slots">${Array.from({ length: m.budgets.max_workers }, (_, i) =>
              html`<i key=${i} class=${i < (m.agents_live || 0) ? "on" : ""}></i>`)}</span> ${m.agents_live || 0}/${m.budgets.max_workers}</span>` : null}</div>
          <${Checks} m=${m} />
          ${m.util ? html`<div class="m-l3"><span class=${m.util.max >= 1 ? "warn-t" : "faint"}>${m.util.max >= 1 ? "At its budget: it takes no new worker. " : ""}With one more worker:
            CPU ${pct(m.util.cpu * 100)}, memory ${pct(m.util.mem * 100)} of its budget</span></div>` : null}
        </div>`)}</div>`
      : tab === "workers" ? html`<div class="w-table">${workers.length ? workers.map((t) => html`<div key=${t.key} class="w-row">
          <span class="pulse"></span><span class="faint">${t.short_id}</span><span class="w-title truncate"><${Linked} text=${t.title} /></span>
          <span class="faint">${t.machine || "the brain"}</span><span class="w-att faint">attempt 1</span><span class="faint">${t.dispatched ? M.ago(t.dispatched) : ""}</span>
          <span class="w-state truncate">${t.line || ""}</span><span class="faint">${t.home}</span></div>`) : html`<p class="dt-empty" style=${{ padding: "16px" }}>No worker is running.</p>`}</div>`
      : html`<p class="dt-empty">${tab === "attempts" ? "Attempts and hand-offs between machines come with remote dispatch (one brain, step 4). Today every worker runs on the brain, at attempt 1."
          : "Who holds each home's conn comes with the conn lease (one brain, step 3). Until then, answers wait in each home's mailbox for its XO's next watch."}</p>`}
    </div>
  </main>`;
}

export function MachineDetail({ m, workers, names }) {
  if (!m) return html`<aside class="a-detail slim"><p class="faint q-keys">Select a machine.</p></aside>`;
  // a worker runs on its home's machine; one whose machine Fleet does not list runs on the brain
  const mine = workers.filter((w) => w.machine === m.name || (m.brain && !(names || []).includes(w.machine)));
  const fixes = { "claude sign-in": "claude /login", "codex sign-in": "codex login", "gh sign-in": "gh auth login" };
  return html`<aside class="a-detail slim" aria-label=${m.name}>
    <h2 class="a-detail-title">${m.name} <span class="m-role faint">${m.brain ? "the brain" : m.role}</span></h2>
    <dl class="sp">
      <dt>Health</dt><dd>${STATE[m.state]}</dd>
      ${m.failing.length ? html`<dt>To fix</dt><dd><ul class="checks">${m.failing.map((f) => html`<li key=${f}><span class="glyph blocked"></span><span><b>${f}</b>
        ${fixes[f] ? html`<br /><span class="faint">on ${m.name}: <code>${fixes[f]}</code></span>` : null}</span></li>`)}</ul></dd>` : null}
      <dt>Load</dt><dd>${m.load ? m.load.map((x) => x.toFixed(1)).join(" · ") : "—"}${m.cores ? html` <span class="faint">on ${m.cores} cores</span>` : null}</dd>
      <dt>Memory free</dt><dd>${pct(m.mem_free_pct)}</dd>
      <dt>Disk free</dt><dd>${pct(m.disk_free_pct)}</dd>
      <dt>Budgets</dt><dd>${m.budgets ? html`${m.budgets.max_workers} workers · CPU ${m.budgets.cpu}% · memory ${m.budgets.mem}%${m.budgets.on_battery ? " · on battery: " + m.budgets.on_battery : ""}` : html`<span class="faint">Not a node yet (chartroom node init)</span>`}</dd>
      <dt>Power</dt><dd>${m.power === "battery" ? "On battery" + (m.battery_pct != null ? " (" + m.battery_pct + "%)" : "") : m.power === "ac" ? "Plugged in" : "—"}</dd>
      <dt>Workers</dt><dd>${mine.length ? html`<div class="sp-ms">${mine.map((w) => html`<div key=${w.key} class="sp-m"><${Status} status="working" only=${true} /><span class="grow truncate">${w.title}</span></div>`)}</div>` : html`<span class="faint">None</span>`}</dd>
    </dl>
  </aside>`;
}
