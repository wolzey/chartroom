// fleetviews.js - Fleet's other two views, over the same data as its list (state.fleet and the homes'
// tasks; model.js, fleetMap, decides what is on each machine and how it stands):
//   Atom: a machine is a nucleus (its name, how full it is); its sessions orbit it, by state.
//   Dashboard: a card per machine: CPU, load, memory, disk and workers as meters, and its problems.
// A session opens its quick view (an answer, a steer, its ticket), as on the board. Plain SVG and CSS.
import { html, useState, useEffect, useRef } from "./html.js";
import { Linked } from "./ui.js";

const M = window.AppModel;
const STATES = M.FLEET_STATES;
export const VIEWS = [["list", "List"], ["atom", "Atom"], ["dash", "Dashboard"]];
const VIEW_KEY = "chartroom-fleet-view";

// The view this device last had; a link may name one (?fleet=atom).
export function savedView() {
  let v = new URLSearchParams(location.search).get("fleet");
  if (!v) try { v = localStorage.getItem(VIEW_KEY); } catch (e) { /* private window */ }
  return VIEWS.some((x) => x[0] === v) ? v : "list";
}
export function saveView(v) {
  try { localStorage.setItem(VIEW_KEY, v); } catch (e) { /* private window */ }
  const u = new URL(location.href);
  if (u.searchParams.has("fleet")) { u.searchParams.delete("fleet"); history.replaceState(null, "", u); }
}
export function ViewSwitch({ view, onPick }) {
  return html`<div class="fv-switch" role="group" aria-label="View">${VIEWS.map(([id, label]) =>
    html`<button key=${id} aria-pressed=${view === id} onClick=${() => onPick(id)}>${label}</button>`)}</div>`;
}

const ticket = (t) => "#/t/" + encodeURIComponent(t.home) + "/" + encodeURIComponent(t.task);

// ---------------------------------------------------------------- the marks
// One state, one shape and colour: told apart without the colour.
function Mark({ state, r = 9 }) {
  const c = "fv-mk fv-" + state;
  if (state === "needs") return html`<g class=${c}><path d=${`M0 ${-r - 2} L${r + 2} 0 L0 ${r + 2} L${-r - 2} 0 Z`} /><text y="4">!</text></g>`;
  if (state === "stalled") return html`<g class=${c}><rect x=${-r + 0.5} y=${-r + 0.5} width=${2 * r - 1} height=${2 * r - 1} rx="3" /><path class="gl" d="M-3 -3 L3 3 M3 -3 L-3 3" /></g>`;
  if (state === "review") return html`<g class=${c}><circle r=${r} /><path class="gl" d="M-3.6 0.2 L-1 3 L4 -2.8" /></g>`;
  return html`<g class=${c}><circle r=${state === "other" ? r - 3 : r - (state === "waiting" ? 1 : 0)} /></g>`;
}
function MarkIcon({ state, size = 22, own }) {
  return html`<svg width=${size} height=${size} viewBox="-14 -14 28 28" aria-hidden="true">${own ? html`<circle class="fv-halo" r="12.5" />` : null}<${Mark} state=${state} r=${own ? 8 : 9} /></svg>`;
}
function Legend({ counts, own }) {
  return html`<ul class="fv-legend" aria-label="What the marks mean">${Object.entries(STATES).filter(([k]) => k !== "other" || counts.other).map(([k, label]) => html`<li key=${k} class=${counts[k] ? "" : "none"}>
    <${MarkIcon} state=${k} />${label} <b>${counts[k] || 0}</b></li>`)}
    ${own ? html`<li><svg width="22" height="22" viewBox="-14 -14 28 28" aria-hidden="true"><circle class="fv-halo" r="12" /></svg>XO or your own session <b>${own}</b></li>` : null}</ul>`;
}
// everything on a machine, as marks: its sessions, its other agents by name, what it only counts
function elements(o, showRest) {
  const es = o.sessions.concat(o.agents);
  for (let i = 0; i < o.crew; i++) es.push({ id: "c" + i, state: "other", kind: "crew", unnamed: true });
  for (let i = 0; i < o.others; i++) es.push({ id: "o" + i, state: "other", kind: "other", unnamed: true });
  return showRest ? es.concat(o.rest.map((x) => Object.assign({ rest: true }, x))) : es;
}
const isOwn = (e) => e.kind === "xo" || e.kind === "other";
function nameOf(e) {
  return e.task ? e.task.title : e.unnamed ? (e.kind === "crew" ? "A crew worker" : "An XO or your own session") : M.agentLabel(e);
}

// ---------------------------------------------------------------- atom
const RX = 162, RY = 92;
const ORBIT = `M ${RX} 0 A ${RX} ${RY} 0 1 1 ${-RX} 0 A ${RX} ${RY} 0 1 1 ${RX} 0`;
const TILTS = [0, 60, 120];
const reduced = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Where an electron starts on its orbit: evenly by the angle, so a still atom (reduced motion) reads too.
function Electron({ e, i, n, dur, tilt, sel, onPick, still }) {
  const label = nameOf(e) + " (" + STATES[e.state] + (e.task ? ", " + e.task.home : "") + ")";
  const a = (i / n) * 2 * Math.PI, at = still ? `translate(${RX * Math.cos(a)} ${-RY * Math.sin(a)})` : null;
  return html`<g class=${"fv-e" + (sel ? " sel" : "") + (e.rest ? " rest" : "")} role="button" tabIndex="0" aria-label=${label} transform=${at}
      onClick=${(ev) => { ev.stopPropagation(); onPick(e); }} onMouseEnter=${() => onPick(e, true)} onFocus=${() => onPick(e, true)}
      onKeyDown=${(ev) => { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); ev.stopPropagation(); onPick(e); } }}>
    ${still ? null : html`<animateMotion dur=${dur + "s"} begin=${-((i / n) * dur).toFixed(2) + "s"} repeatCount="indefinite" calcMode="paced" path=${ORBIT} />`}
    <g transform=${"rotate(" + -tilt + ")"}><title>${label}</title><circle class="fv-hit" r="17" />${isOwn(e) && !e.unnamed ? html`<circle class="fv-halo" r="13" />` : null}<${Mark} state=${e.state} r=${e.rest ? 6 : 9} /></g></g>`;
}

function Atom({ m, o, pick, setPick, showRest, setShowRest, sel, onSelect, onSession, actionFor }) {
  const svg = useRef(null);
  const [hold, setHold] = useState(false);
  const down = m.state === "down", f = M.fullness(m), isFull = f != null && f >= 1;
  const still = reduced() || down;
  const es = elements(o, showRest);
  // three orbits: working, what waits on someone, the rest
  const rings = [es.filter((e) => e.state === "working"), es.filter((e) => e.state !== "working" && e.state !== "other" && !e.rest),
    es.filter((e) => e.state === "other" || (e.rest && e.state !== "working"))];
  const picked = pick && pick.m === m.name;
  const here = picked ? es.find((e) => e.id === pick.id) || null : null;
  // a moving target is hard to hit: the atom stops under the pointer, and while one is picked
  useEffect(() => {
    const s = svg.current;
    if (!s || !s.pauseAnimations) return;
    if (hold || (here && pick.pinned)) s.pauseAnimations(); else s.unpauseAnimations();
  }, [hold, !!here, pick && pick.pinned]);
  const arc = 2 * Math.PI * 62;
  const choose = (x, soft) => {
    setPick((p) => (soft && p && p.pinned ? p : { m: m.name, id: x.id, pinned: !soft }));
    if (!soft) onSession(x.task && x.task.status !== "closed" ? x.task : null, false);
  };
  return html`<section class=${"fv-atom" + (m.brain ? " brain" : "") + (down ? " down" : "") + (isFull ? " full" : "") + (sel ? " sel" : "")} aria-label=${m.name}>
    ${m.brain ? null : html`<span class="fv-bond" aria-hidden="true"></span>`}
    <svg ref=${svg} viewBox="-190 -178 380 356" onPointerEnter=${() => setHold(true)} onPointerLeave=${() => setHold(false)} onClick=${() => { setPick(null); onSession(null, false); }}>
      ${TILTS.map((t, i) => html`<ellipse key=${"o" + i} class=${"fv-orbit" + (rings[i].length ? "" : " empty")} rx=${RX} ry=${RY} transform=${"rotate(" + t + ")"} />`)}
      ${TILTS.map((t, i) => html`<g key=${i} transform=${"rotate(" + t + ")"}>
        ${rings[i].map((e, j) => html`<${Electron} key=${e.id} e=${e} i=${j} n=${rings[i].length} dur=${[70, 95, 120][i]} tilt=${t} still=${still}
          sel=${here && here.id === e.id} onPick=${choose} />`)}</g>`)}
      <g class="fv-nuc" role="button" tabIndex="0" aria-label=${m.name + (down ? ", offline" : isFull ? ", full" : "")} onClick=${(ev) => { ev.stopPropagation(); setPick(null); onSelect(m.name); }}
          onKeyDown=${(ev) => { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); setPick(null); onSelect(m.name); } }}>
        <circle class="fv-nuc-bg" r="62" />
        ${f != null && !down ? html`<circle class="fv-nuc-track" r="62" /><circle class="fv-nuc-fill" r="62" transform="rotate(-90)" strokeDasharray=${`${Math.min(1, f) * arc} ${arc}`} />` : null}
        <text class="fv-nuc-name" y="-10">${m.name.length > 14 ? m.name.slice(0, 13) + "…" : m.name}</text>
        ${down ? html`<text class="fv-nuc-n" y="14">offline</text><text class="fv-nuc-s" y="30">${m.device && m.device.seen_age_s != null ? "seen " + M.ageText(m.device.seen_age_s) + " ago" : ""}</text>`
          : html`<text class="fv-nuc-n" y="14">${m.budgets && m.budgets.max_workers ? M.crewOf(m) + "/" + m.budgets.max_workers : es.length}</text>
            <text class="fv-nuc-s" y="31">${f > 1 ? "over its limit" : isFull ? "full" : m.state === "degraded" ? "needs a look" : f != null ? "workers" : "agents"}</text>`}
      </g>
    </svg>
    <div class="fv-cap" aria-live="polite">${here ? html`<${Picked} e=${here} m=${m} onSession=${onSession} actionFor=${actionFor} onClose=${() => { setPick(null); onSession(null, false); }} />`
      : down ? html`<p class="warn-t">${m.error || "Not reached"}</p>`
      : html`<p class="faint">${es.length ? "Tap a session to see its task." : "No session here."}</p>`}
      ${o.rest.length ? html`<button class="link fv-rest" aria-pressed=${showRest} onClick=${() => setShowRest(!showRest)}>${showRest ? "Hide" : "Show"} ${o.rest.length} at rest (untouched for ${M.REST_DAYS} days)</button>` : null}</div>
  </section>`;
}
function Picked({ e, m, onClose, onSession, actionFor }) {
  const t = e.task, act = t ? actionFor(t) : null;
  return html`<div class="fv-pick"><${MarkIcon} state=${e.state} size=${24} own=${isOwn(e) && !e.unnamed} />
    <div class="grow">${t ? html`<a class="fv-pick-t" href=${ticket(t)}>${t.title}</a>
        <p class="faint">${t.status === "closed" ? "Its task is closed; its terminal is still open" : STATES[e.state]} · ${t.home}${t.project ? " · " + t.project : ""}${t.last_at ? " · " + M.agoText(t.last_at) : ""}</p>
        ${e.error ? html`<p class="warn-t">Its agent ended its turn on an error</p>` : null}
        ${t.warning || t.line ? html`<p class="fv-pick-l"><${Linked} text=${t.warning || t.line} /></p>` : null}
        ${act ? html`<div class="fv-acts"><button class="btn sm" onClick=${() => onSession(t, true)}>${act}</button></div>` : null}`
      : html`<span class="fv-pick-t">${nameOf(e)}</span><p class="faint">${e.unnamed
          ? "Counted on " + m.name + ", whose chartroom does not name its agents yet."
          : STATES[e.state] + " · " + (e.kind === "crew" ? "no open task in these homes names it" : (e.kind === "xo" ? "XO" : "a session chartroom did not start") + (e.where && e.where !== e.name ? " · " + e.where : ""))}</p>`}</div>
    <button class="btn ghost icon sm" aria-label="Close" onClick=${onClose}>×</button></div>`;
}

export function AtomView({ fleet, tasks, sel, onSelect, onSession, actionFor }) {
  const [pick, setPick] = useState(null);
  const [rest, setRest] = useState({});
  const ms = fleet.machines, by = M.fleetMap(fleet, tasks);
  const counts = {};
  let own = 0;
  for (const m of ms) for (const e of elements(by[m.name], rest[m.name])) { counts[e.state] = (counts[e.state] || 0) + 1; if (isOwn(e) && !e.unnamed) own++; }
  // Escape lets a picked session go, before it leaves the page
  useEffect(() => {
    if (!pick) return;
    const key = (e) => {
      if (e.key !== "Escape" || document.querySelector(".palette, .menu") || (e.target && /^(TEXTAREA|INPUT)$/.test(e.target.tagName))) return;
      e.stopPropagation(); setPick(null); onSession(null, false);
    };
    document.addEventListener("keydown", key, true);
    return () => document.removeEventListener("keydown", key, true);
  }, [!!pick]);
  const at = (m) => html`<${Atom} key=${m.name} m=${m} o=${by[m.name]} pick=${pick} setPick=${setPick} sel=${sel === m.name} onSelect=${onSelect} onSession=${onSession} actionFor=${actionFor}
    showRest=${!!rest[m.name]} setShowRest=${(v) => setRest((r) => Object.assign({}, r, { [m.name]: v }))} />`;
  const rim = ms.filter((m) => !m.brain);
  return html`<div class="fv"><${Legend} counts=${counts} own=${own} />
    <div class=${"fv-mol" + (rim.length > 2 ? " many" : rim.length ? "" : " one")}>${ms.filter((m) => m.brain).map(at)}${rim.length ? html`<div class="fv-rim">${rim.map(at)}</div>` : null}</div></div>`;
}

// ---------------------------------------------------------------- dashboard
// A meter: how much is used, the budget as a tick, a word when it matters.
function Meter({ x }) {
  const v = x.used == null ? null : Math.max(0, Math.min(100, x.used));
  const said = x.text + (x.tickText ? "; " + x.tickText : "");
  return html`<div class=${"fd-m" + (x.level ? " " + x.level : "")}><div class="fd-ml"><span>${x.label}</span><span class=${"fd-mv" + (v == null ? " faint" : "")}>${x.word ? html`<b class="fd-w">${x.word}</b> ` : null}${x.text}</span></div>
    ${v == null ? null : html`<div class="fd-bar" role="meter" aria-label=${x.label} aria-valuemin="0" aria-valuemax="100" aria-valuenow=${Math.round(v)} aria-valuetext=${said} title=${said}>
      <i style=${{ width: v + "%" }}></i>${x.tick ? html`<u style=${{ left: Math.min(100, x.tick) + "%" }}></u>` : null}</div>`}</div>`;
}
// Tasks under a problem or a state: the ticket by its title, and what to do about it here.
function TaskLines({ items, onSession, actionFor }) {
  return html`<ul class="fd-pt">${items.map((e) => {
    const t = e.task, act = t ? actionFor(t) : null;
    return html`<li key=${e.id}><span class="grow">${t ? html`<a href=${ticket(t)}>${t.title}</a>` : html`<span>${nameOf(e)}</span>`}
      <span class="faint"> ${t ? t.home + (t.last_at ? " · " + M.agoText(t.last_at) : "") : e.where && e.where !== e.name ? e.where : ""}</span></span>
      ${act ? html`<button class="btn ghost sm" onClick=${(ev) => { ev.stopPropagation(); onSession(t, true); }}>${act}</button>` : null}</li>`;
  })}</ul>`;
}
function Problem({ p, m, onSession, actionFor, toast }) {
  const [open, setOpen] = useState(false);
  const copy = (e) => { e.stopPropagation(); if (navigator.clipboard) navigator.clipboard.writeText(p.cmd); toast("Copied: " + p.cmd + ". Run it on " + m.name); };
  return html`<li class=${"fd-p " + p.level}><span class="fd-pi" aria-hidden="true">${p.level === "bad" ? "✕" : p.level === "warn" ? "!" : "·"}</span><div class="grow">
    ${p.tasks ? html`<button class="link" aria-expanded=${open} onClick=${(e) => { e.stopPropagation(); setOpen(!open); }}>${p.text} ${open ? "▴" : "▾"}</button>` : html`<span>${p.text}</span>`}
    ${p.sub ? html`<p class="faint">${p.sub}</p>` : null}
    ${p.cmd ? html`<p class="fd-cmd"><code>${p.cmd}</code><button class="btn ghost sm" onClick=${copy}>Copy</button></p>` : null}
    ${open ? html`<${TaskLines} items=${p.tasks.map((t) => ({ id: t.key, task: t }))} onSession=${onSession} actionFor=${actionFor} />` : null}</div></li>`;
}
function Card({ m, o, sel, onSelect, onSession, actionFor, toast }) {
  const [shown, setShown] = useState(null); // the state whose sessions are listed
  const down = m.state === "down";
  const ps = M.fleetProblems(m, o), hard = ps.some((p) => p.level === "bad");
  const by = {};
  for (const e of elements(o, false)) (by[e.state] = by[e.state] || []).push(e);
  return html`<article class=${"fd-card" + (sel ? " sel" : "") + (down ? " down" : hard ? " bad" : "")} aria-label=${m.name} onClick=${() => onSelect(m.name)}>
    <header class="fd-h"><span class=${"glyph " + (m.state === "healthy" ? "ok" : "blocked")}></span><h2>${m.name}</h2><span class="faint">${m.brain ? "brain" : m.role}</span><span class="grow"></span>
      <span class="faint">${m.power === "battery" ? "on battery" + (m.battery_pct != null ? " " + m.battery_pct + "%" : "") : m.power === "ac" ? "plugged in" : ""}</span></header>
    ${down ? null : html`<div class="fd-ms">${M.fleetMeters(m).map((x) => html`<${Meter} key=${x.id} x=${x} />`)}</div>
    <div class="fd-s">${Object.entries(STATES).filter(([k]) => by[k]).map(([k, label]) => html`<button key=${k} class="fd-chip" aria-expanded=${shown === k} onClick=${(e) => { e.stopPropagation(); setShown(shown === k ? null : k); }}>
      <${MarkIcon} state=${k} size=${18} />${by[k].length} ${label.toLowerCase()}</button>`)}</div>
    ${shown && by[shown] ? html`<${TaskLines} items=${by[shown]} onSession=${onSession} actionFor=${actionFor} />` : null}`}
    ${ps.length ? html`<ul class="fd-ps">${ps.map((p) => html`<${Problem} key=${p.id || p.text} p=${p} m=${m} onSession=${onSession} actionFor=${actionFor} toast=${toast} />`)}</ul>` : html`<p class="fd-ok faint"><span class="glyph ok"></span>No problems</p>`}
  </article>`;
}
export function DashView({ fleet, tasks, sel, onSelect, onSession, actionFor, toast }) {
  const by = M.fleetMap(fleet, tasks);
  return html`<div class="fd">${fleet.machines.map((m) => html`<${Card} key=${m.name} m=${m} o=${by[m.name]} sel=${sel === m.name} onSelect=${onSelect} onSession=${onSession} actionFor=${actionFor} toast=${toast} />`)}</div>`;
}
