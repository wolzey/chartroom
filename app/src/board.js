// board.js - the board (slice 3): every home's tasks in the design's seven columns, filtered by home,
// project, initiative and machine. A card click selects it and shows its quick view beside the
// board (never navigates); o or Open details opens the ticket. With nothing selected, the slim
// column sums the board up. Requests from the composer wait in Drafting until the XO briefs them.
import { html, useState, useEffect, useRef } from "./html.js";
import { HomeTag, Status, Linked, PrBadges, Menu } from "./ui.js";

const M = window.AppModel;
const PRIO = { urgent: "!!!", high: "!!", medium: "!", low: "" };

function Card({ t, sel, prs, onSelect }) {
  return html`<button class=${"b-tk" + (sel ? " sel" : "") + (t.warning ? " stalled" : "") + (t.column === "working" ? " live" : "")}
      data-key=${t.key} onClick=${() => onSelect(t.key)}>
    <span class="b-tk-top"><span class="t-id faint">${t.short_id || t.id}</span>
      ${t.priority && PRIO[t.priority] ? html`<span class=${"prio prio-" + t.priority} title=${"Priority: " + t.priority}>${PRIO[t.priority]}</span>` : null}
      <span class="grow"></span><${PrBadges} urls=${t.prs || []} prs=${prs} max=${1} /></span>
    <span class="b-tk-title"><${Linked} text=${t.title} /></span>
    ${t.line ? html`<span class="b-tk-line">${t.column === "working" ? html`<span class="pulse"></span>` : null}<span>${t.line}</span></span>` : null}
    ${t.warning ? html`<span class="b-tk-warn">${t.warning}</span>` : null}
    <span class="b-tk-meta"><span class=${"home-dot hue-" + t.hue}></span><span class="truncate">${t.project || t.home}</span><span class="grow"></span>
      ${t.machine && t.column === "working" ? html`<span class="faint">${t.machine}${t.dispatched ? " · " + M.ago(t.dispatched) : ""}</span>` : null}</span>
  </button>`;
}

function Filters({ all, filters, setFilters }) {
  const [menu, setMenu] = useState(null);
  const uniq = (k) => [...new Set(all.map((t) => t[k]).filter(Boolean))].sort();
  const defs = [["home", "Home"], ["project", "Project"], ["initiative", "Initiative"], ["machine", "Machine"]];
  return html`<div class="filters">
    ${defs.map(([k, label]) => filters[k]
      ? html`<button key=${k} class="filter set" onClick=${(e) => setMenu({ k, label, anchor: e.currentTarget })}><span class="k">${label}</span> ${filters[k]}
          <span class="x" onClick=${(e) => { e.stopPropagation(); setFilters(Object.assign({}, filters, { [k]: null })); }}>×</span></button>`
      : html`<button key=${k} class="filter" disabled=${!uniq(k).length} onClick=${(e) => setMenu({ k, label, anchor: e.currentTarget })}><span class="k">+</span> ${label} <span class="caret"></span></button>`)}
    ${Object.values(filters).some(Boolean) ? html`<button class="btn ghost sm" onClick=${() => setFilters({})}>Clear</button>` : null}
    ${menu ? html`<${Menu} anchor=${menu.anchor} title=${menu.label} picked=${filters[menu.k]}
        items=${uniq(menu.k).map((v) => ({ id: v, label: v, n: M.boardFilter(all, Object.assign({}, filters, { [menu.k]: v })).length }))}
        onPick=${(x) => setFilters(Object.assign({}, filters, { [menu.k]: x.id }))} onClose=${() => setMenu(null)} />` : null}
  </div>`;
}

export function BoardPage({ all, list, filters, setFilters, selKey, setSelKey, prs, onCompose }) {
  const cols = M.boardColumns(list);
  const working = list.filter((t) => t.column === "working").length;
  const warned = list.filter((t) => t.warning).length;
  useEffect(() => {
    const el = selKey && document.querySelector('.b-tk[data-key="' + CSS.escape(selKey) + '"]');
    if (el) el.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [selKey]);
  return html`<main class="a-main">
    <header class="a-head">
      <div class="a-head-l"><h1>Board</h1><span class="faint">${list.length} ${list.length === 1 ? "task" : "tasks"} · ${working} working${warned ? html` · <span class="warn-t">${warned} need a look</span>` : null}</span></div>
      <button class="btn primary sm" onClick=${onCompose}>New task <kbd>c</kbd></button>
    </header>
    <div class="a-toolbar"><${Filters} all=${all} filters=${filters} setFilters=${setFilters} /><span class="grow"></span>
      <span class="a-keys faint"><span><kbd>j</kbd><kbd>k</kbd> move</span><span><kbd>o</kbd> open</span><span><kbd>c</kbd> new task</span><span><kbd>esc</kbd> close</span></span></div>
    <div class="kanban" style=${{ gridTemplateColumns: cols.map((c) => (c.cards.length ? "minmax(212px, 300px)" : "minmax(132px, 160px)")).join(" ") }}>${cols.map((c) => html`<section key=${c.status} class=${"b-col col-" + c.status + (c.cards.length ? "" : " empty")}>
      <div class="b-col-h"><${Status} status=${c.status} /><span class="count">${c.cards.length}</span>
        ${c.status === "drafting" ? html`<span class="grow"></span><button class="btn ghost icon sm" title="New task (c)" aria-label="New task" onClick=${onCompose}>+</button>` : null}</div>
      <div class="b-col-b">${c.cards.length ? c.cards.map((t) => html`<${Card} key=${t.key} t=${t} sel=${t.key === selKey} prs=${prs} onSelect=${setSelKey} />`)
        : html`<p class="faint b-empty">Nothing here</p>`}</div>
    </section>`)}</div>
  </main>`;
}

// With nothing selected: the board summed up, in the slim column.
export function BoardSummary({ list, prs }) {
  const counts = M.BOARD.map((s) => [s, list.filter((t) => t.column === s).length]).filter(([, n]) => n);
  const homes = {};
  for (const t of list) homes[t.home] = homes[t.home] || { n: 0, hue: t.hue }, homes[t.home].n++;
  const open = [...new Set(list.flatMap((t) => t.prs || []))].filter((u) => !prs[u] || !["merged", "closed"].includes(prs[u].state));
  return html`<aside class="a-detail slim" aria-label="The board">
    <dl class="sp">
      <dt>Status</dt><dd><div class="sp-ms">${counts.map(([s, n]) => html`<div key=${s} class="sp-m"><${Status} status=${s} only=${true} /><span class="grow">${M.STATUS[s]}</span><span class="faint">${n}</span></div>`)}</div></dd>
      <dt>Homes</dt><dd><div class="sp-ms">${Object.keys(homes).map((h) => html`<div key=${h} class="sp-m"><${HomeTag} name=${h} hue=${homes[h].hue} /><span class="grow"></span><span class="faint">${homes[h].n}</span></div>`)}</div></dd>
      <dt>Open PRs</dt><dd>${open.length ? html`<${PrBadges} urls=${open} prs=${prs} />` : html`<span class="faint">None</span>`}</dd>
    </dl>
    <p class="faint q-keys">Click a card for its quick view.</p>
  </aside>`;
}

// A card's quick view when Needs me has nothing for it: what it is doing, a steer, and the ticket.
export function TaskQuick({ t, onOpen, onAct, onClose, open, toast }) {
  const [text, setText] = useState("");
  const ref = useRef(null);
  useEffect(() => { setText(""); }, [t && t.key]);
  if (!t) return null;
  const send = () => {
    const v = text.trim();
    if (!v) return;
    onAct(t.home, "comment", { task: t.task, text: v }, "Steer to " + (t.short_id || t.id));
    setText("");
    toast(/^\s*@xo\b/i.test(v) ? "Sent to the " + t.home + " XO" : "Sent to the worker, as a steer");
  };
  return html`<aside class=${"a-detail quick" + (open ? " open" : "")} aria-label="Quick view">
    <div class="a-detail-h"><${Status} status=${t.column === "done" && t.status === "closed" ? "done" : t.column} /><span class="grow"></span>
      ${t.type === "task" ? html`<button class="btn ghost sm od" title="Open details (o)" onClick=${() => onOpen(t)}><span class="od-ic"></span>Open details</button>` : null}
      <button class="btn ghost icon qv-close" aria-label="Close" onClick=${onClose}>×</button></div>
    <h2 class="a-detail-title"><${Linked} text=${t.title} /></h2>
    <div class="a-detail-meta"><span class="meta"><${HomeTag} name=${t.home} hue=${t.hue} />${t.project ? html`<span class="dot-sep">${t.project}</span>` : null}
      ${t.machine ? html`<span class="dot-sep">${t.machine}</span>` : null}</span></div>
    ${t.line ? html`<div class=${"q-line q-" + t.column}>${t.column === "working" ? html`<span class="pulse"></span>` : html`<${Status} status=${t.column} only=${true} />`}<span class="grow">${t.line}</span></div>` : null}
    ${t.warning ? html`<p class="warn-t">${t.warning}</p>` : null}
    ${t.type === "request" ? html`<p class="muted">You asked for this; the ${t.home} XO briefs it and dispatches it (or asks you first). It moves along the board from there.</p>`
      : t.column !== "done" ? html`<textarea class="input note" rows="2" ref=${ref} value=${text} onInput=${(e) => setText(e.target.value)}
          onKeyDown=${(e) => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); e.stopPropagation(); send(); } }}
          placeholder="Steer it: it reads this as your words. Start with @xo to ask the XO instead."></textarea>
        <div class="a-detail-actions"><button class="btn primary" disabled=${!text.trim()} onClick=${send}>Send <kbd>⌘↵</kbd></button>
          ${t.column === "review" ? html`<button class="btn" onClick=${() => onAct(t.home, "accept", { task: t.task }, "Accepted " + t.short_id)}>Accept</button>` : null}</div>` : null}
  </aside>`;
}
