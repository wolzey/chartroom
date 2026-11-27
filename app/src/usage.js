// usage.js - subscription usage, on Fleet: for each agent (split by machine only where the readings
// differ), its plan, what is used and left in each window, when each resets, how old the reading is,
// and the live workers on it. An agent that is out or near its limit says so; a model-only window
// (Claude's Opus week) is information, never "out". The rows are model.js's (usageRows, usageView),
// over every home's snapshot `usage` (lib/usage.sh); this file only draws them. Phone first: each
// agent is one card, its windows stacked; wider screens set the cards side by side.
import { html, useState, useEffect } from "./html.js";

const M = window.AppModel;

// re-render once a minute, so the countdowns and the ages stay true while the page is open
function useMinute() {
  const [, set] = useState(0);
  useEffect(() => { const t = setInterval(() => set((n) => n + 1), 60e3); return () => clearInterval(t); }, []);
}

function Window({ w, agent }) {
  return html`<div class=${"u-win u-" + w.level}>
    <div class="u-win-h"><span class="u-wl">${w.label}</span>${w.scoped ? html`<span class="u-tag" title="This limit covers one model only: when it runs out, the agent's other models still work">one model</span>` : null}
      <span class="grow"></span><span class="u-num"><b>${w.leftText}</b> <span class="faint">· ${w.usedText}</span></span></div>
    <div class="u-bar" role="meter" aria-label=${agent + " " + w.label + " used"} aria-valuemin="0" aria-valuemax="100" aria-valuenow=${w.used == null ? undefined : Math.round(w.used)}>
      <i style=${{ width: (w.used || 0) + "%" }}></i></div>
    <div class="u-reset faint" title=${w.resetsAt ? new Date(w.resetsAt).toLocaleString() : ""}>${w.reset}</div>
  </div>`;
}

function Row({ v }) {
  return html`<article class=${"u-row u-st-" + v.state} aria-label=${v.agent + (v.where ? " on " + v.where : "") + ": " + v.stateText}>
    <header class="u-row-h">
      <span class="u-agent">${v.agent}</span>${v.where ? html`<span class="u-where faint truncate">${v.where}</span>` : null}
      <span class="grow"></span><span class=${"u-state u-s-" + v.state}>${v.stateText}</span>
    </header>
    <div class="u-plan faint">${v.plan || "Plan not reported"}</div>
    ${v.windows.length ? html`<div class="u-wins">${v.windows.map((w) => html`<${Window} key=${w.id} w=${w} agent=${v.agent} />`)}</div>` : null}
    ${v.note ? html`<p class=${"u-note" + (v.state === "out" ? " u-note-out" : "")}>${v.note}</p>` : null}
    <footer class="u-foot faint">
      <span class=${v.live ? "u-live busy" : "u-live"}>${v.live} live worker${v.live === 1 ? "" : "s"}</span>
      <span class=${v.stale ? "u-age warn-t" : "u-age"} title=${v.sampledAt ? new Date(v.sampledAt).toLocaleString() : ""}>${v.age}${v.stale ? ", stale" : ""}</span>
    </footer>
  </article>`;
}

// The usage page (#/usage): every agent's card in the CLI's order (claude, codex, agy, grok; this
// machine first), so a card stays in its place as its numbers change.
export function UsagePage({ data }) {
  useMinute();
  const rows = M.usageRows(data), now = Date.now(), views = rows.map((r) => M.usageView(r, now)), sum = M.usageSummary(rows);
  const read = ((data && data.homes) || []).some((h) => h.snapshot);
  return html`<main class="a-main">
    <header class="a-head"><div class="a-head-l"><a class="link faint" href="#/fleet">Fleet</a><span class="faint">/</span><h1>Usage</h1></div></header>
    <div class="page-body usage-page">
      <div class=${"fleet-sum u-sum-" + sum.level}><span class=${"glyph " + (sum.level === "ok" ? "ok" : "blocked")}></span>
        <p>${!read ? "Reading the homes…" : sum.text}${rows.length ? "." : ""}
          <span class="faint"> What each subscription has used and has left, and when each limit resets. New work skips an agent that is out.</span></p></div>
      ${views.length ? html`<div class="u-grid">${views.map((v) => html`<${Row} key=${v.key} v=${v} />`)}</div>`
        : read ? html`<p class="dt-empty">No usage reading yet. <code>chartroom usage --refresh</code> on the brain reads every agent there.</p>` : null}
    </div>
  </main>`;
}

// On Fleet, above the machines: one line per agent and a way to the page.
export function UsageStrip({ data }) {
  useMinute();
  const rows = M.usageRows(data);
  if (!rows.length) return null;
  const now = Date.now(), sum = M.usageSummary(rows);
  const chips = rows.map((r) => M.usageView(r, now)).map((v) => {
    const w = v.windows.filter((x) => !x.scoped).sort((a, b) => (b.used || 0) - (a.used || 0))[0];
    return { key: v.key, v, text: w ? w.leftText + " of " + w.label : v.stateText };
  });
  return html`<a class=${"u-strip u-sum-" + sum.level} href="#/usage" aria-label=${"Usage: " + sum.text + ". Open the usage page"}>
    <span class="u-strip-h"><b>Usage</b><span class="faint">${sum.text}</span><span class="grow"></span><span class="faint">Details →</span></span>
    <span class="u-chips">${chips.map((c) => html`<span key=${c.key} class=${"u-chip u-s-" + c.v.state}>
      <b>${c.v.agent}</b>${c.v.where && c.v.where.indexOf(",") < 0 && !/ machines$/.test(c.v.where) && rows.filter((r) => r.agent === c.v.agent).length > 1 ? html`<span class="faint">${c.v.where}</span>` : null}
      <span>${c.text}</span></span>`)}</span>
  </a>`;
}
