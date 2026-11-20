// needs.js - Needs me: one inbox across every home, grouped Decide / Approve / Unblock / Read, and the
// quick view beside it where most items are answered without leaving the list. A row click selects
// (never navigates); the full page opens only from Open details, o or Shift+Enter.
import { html, useState, useRef, useEffect } from "./html.js";
import { Pill, Glyph, HomeTag, Tabs, Empty, Options, Why, Menu } from "./ui.js";

const M = window.AppModel;
const EF = window.EventFmt;

function quickLabel(it) {
  const p = M.primary(it, EF);
  if (p.type === "answer") return p.choice;
  if (p.type === "open-round") return "Answer " + (it.questions || []).length;
  if (p.type === "approve") return "Approve";
  if (p.type === "accept") return "Accept";
  if (p.type === "done") return "Mark done";
  return "Answer";
}

function sentLine(it) {
  if (!it.sent) return null;
  if (it.sent.withdrawn) return "withdrawn by the XO";
  if (it.sent.read_by_xo) return "read by the XO";
  return it.sent.via === "terminal" ? "answered in the terminal" : "sent · not read yet";
}

function Row({ it, i, sel, pending, onSelect, onQuick }) {
  const sent = sentLine(it);
  return html`<div class=${"a-row" + (sel ? " sel" : "") + (pending ? " pending" : "")} data-key=${it.key} role="option"
      aria-selected=${sel} tabindex="-1" onClick=${() => onSelect(i)}>
    <${Glyph} kind=${it.kind} />
    <span class="a-row-title"><span class="truncate">${it.title}</span></span>
    <span class="a-row-quick">${sent
      ? html`<span class=${"sent-st" + (it.sent.read_by_xo ? " read" : "")}>${sent}</span>`
      : html`<button class="btn sm" title="Enter" onClick=${(e) => { e.stopPropagation(); onQuick(it); }}>${quickLabel(it)}</button>`}</span>
    <span class="a-row-meta"><${HomeTag} name=${it.home} hue=${it.hue} />${it.project ? html`<span class="a-row-init truncate">${it.project}</span>` : null}</span>
    <span class="a-row-m">${it.short_id || ""}</span>
    <span class="a-row-age">${M.ago(it.at)}</span>
  </div>`;
}

function Filters({ all, filters, setFilters, homes }) {
  const [menu, setMenu] = useState(null);
  const defs = [
    { key: "home", label: "Home", items: () => homes.map((h) => ({ id: h.name, label: h.name, hue: h.hue,
        n: M.visible(all, { filters: Object.assign({}, filters, { home: h.name }) }).length })) },
    { key: "project", label: "Project", items: () => M.projects(all, filters.home).map((p) => ({ id: p, label: p,
        n: M.visible(all, { filters: Object.assign({}, filters, { project: p }) }).length })) },
  ];
  const any = filters.home || filters.project;
  return html`<div class="filters">
    ${defs.map((f) => filters[f.key]
      ? html`<button key=${f.key} class="filter set" onClick=${(e) => setMenu({ f, anchor: e.currentTarget })}>
          <span class="k">${f.label}</span> ${filters[f.key]}
          <span class="x" aria-label=${"Clear " + f.label} onClick=${(e) => { e.stopPropagation(); setFilters(Object.assign({}, filters, { [f.key]: null })); }}>×</span></button>`
      : html`<button key=${f.key} class="filter" onClick=${(e) => setMenu({ f, anchor: e.currentTarget })}><span class="k">+</span> ${f.label} <span class="caret"></span></button>`)}
    ${any ? html`<button class="btn ghost sm" onClick=${() => setFilters({})}>Clear</button>` : null}
    ${menu ? html`<${Menu} anchor=${menu.anchor} title=${menu.f.label} items=${menu.f.items()} picked=${filters[menu.f.key]}
        onPick=${(x) => setFilters(Object.assign({}, filters, { [menu.f.key]: x.id }, menu.f.key === "home" ? { project: null } : {}))}
        onClose=${() => setMenu(null)} />` : null}
  </div>`;
}

export function NeedsList({ all, list, tab, setTab, filters, setFilters, homes, counts, sel, setSel, local, onQuick, notices }) {
  const tabs = [{ id: "all", label: "All", count: counts.all }]
    .concat(M.GROUPS.map((g) => ({ id: g.id, label: g.label, count: counts[g.id] })))
    .concat([{ id: "sent", label: "Sent", count: counts.sent || null }]);
  if (counts.snoozed) tabs.push({ id: "snoozed", label: "Snoozed", count: counts.snoozed });
  const homesWith = new Set(list.map((it) => it.home)).size;
  let rows = [], i = 0;
  if (!list.length) {
    rows = filters.home || filters.project || tab !== "all"
      ? html`<${Empty} title="Nothing here" text="Nothing matches. Everything else is still in All.">
          <button class="btn" onClick=${() => { setFilters({}); setTab("all"); }}>Show all</button></${Empty}>`
      : html`<${Empty} title="You're all caught up" text="Nothing needs you right now. New questions and approvals land here first." />`;
  } else if (tab === "sent" || tab === "snoozed") {
    rows = list.map((it) => html`<${Row} key=${it.key} it=${it} i=${i} sel=${i++ === sel} pending=${!!local[it.key]} onSelect=${setSel} onQuick=${onQuick} />`);
  } else {
    for (const g of M.GROUPS) {
      const inG = list.filter((it) => it.group === g.id);
      if (!inG.length) continue;
      rows.push(html`<div key=${"g-" + g.id} class="a-group" title=${g.hint}><span>${g.label}</span><span class="count">${inG.length}</span></div>`);
      for (const it of inG) {
        const k = i++;
        rows.push(html`<${Row} key=${it.key} it=${it} i=${k} sel=${k === sel} pending=${!!local[it.key]} onSelect=${setSel} onQuick=${onQuick} />`);
      }
    }
  }
  return html`<main class="a-main">
    <header class="a-head">
      <div class="a-head-l"><h1>Needs me</h1><span class="faint">${counts.all} ${counts.all === 1 ? "item" : "items"}${homesWith > 1 ? " · " + homesWith + " homes" : ""}</span></div>
      <${Tabs} tabs=${tabs} active=${tab} onPick=${(t) => { setTab(t); setSel(0); }} />
    </header>
    <div class="a-toolbar">
      <${Filters} all=${all} filters=${filters} setFilters=${(f) => { setFilters(f); setSel(0); }} homes=${homes} />
      <span class="grow"></span>
      <span class="a-keys faint"><span><kbd>j</kbd><kbd>k</kbd> move</span><span><kbd>↵</kbd> answer</span><span><kbd>o</kbd> details</span><span><kbd>1</kbd><kbd>2</kbd><kbd>3</kbd> choose</span><span><kbd>s</kbd> snooze</span></span>
    </div>
    ${notices}
    <div class="a-list" role="listbox" aria-label="Needs me">${rows}</div>
  </main>`;
}

// The quick view: the selected item, answered in place.
export function QuickView({ it, open, onClose, picks, setPick, note, setNote, busy, onAct, onDetails, snoozeAnchorRef, snoozeOpen, setSnoozeOpen }) {
  const [confirmClose, setConfirmClose] = useState(false);
  const noteRef = useRef(null);
  useEffect(() => { setConfirmClose(false); }, [it && it.key]);
  if (!it) return html`<aside class="a-detail"><div class="a-detail-empty faint">Select something to see it here.</div></aside>`;
  const qs = M.questions(it, EF);
  const q = qs[0];
  const blocks = M.details(it, EF);
  const sent = it.sent;
  const xo = it.home + " XO";
  const hasAnswer = (picks && picks[1] != null) || (note && note.trim());
  const snoozeBtn = it.ref ? html`<button class="btn ghost" ref=${snoozeAnchorRef} onClick=${() => setSnoozeOpen(!snoozeOpen)} disabled=${busy}>Snooze <kbd>s</kbd></button>` : null;
  const noteBox = (placeholder) => html`<textarea class="input note" rows="2" ref=${noteRef} data-note="1" placeholder=${placeholder}
      value=${note || ""} onInput=${(e) => setNote(e.target.value)} disabled=${busy || !!sent}></textarea>`;
  let body = null;
  if (sent) {
    body = html`<div class="qv-sent"><span><b>${sent.withdrawn ? "Withdrawn" : "Sent"}</b> ${M.agoText(sent.at)}${sent.via === "terminal" ? " from the terminal" : ""}.
      ${sent.withdrawn ? "" : sent.read_by_xo ? " The XO has read it." : " Not read by the XO yet; it waits in the home's mailbox until an XO session reads it."}</span>
      ${sent.words ? html`<span class="words faint">${sent.words}</span>` : null}</div>`;
  } else if (it.kind === "round") {
    body = html`
      ${it.summary ? html`<p class="a-detail-sum">${it.summary}</p>` : null}
      <p class="muted">${qs.length} questions in this round. Answer them together and submit once.</p>
      <div class="a-detail-actions"><button class="btn primary" onClick=${() => onDetails(it)}>Answer the round <kbd>↵</kbd></button>${snoozeBtn}</div>`;
  } else if (it.kind === "review") {
    body = html`
      <p class="a-detail-sum qv-ask">${it.summary || "The worker reported done."}</p>
      ${(it.prs || []).length ? html`<div class="qv-blocks">${it.prs.map((p) => html`<a key=${p.url || p} href=${p.url || p} target="_blank" rel="noopener noreferrer">${p.url || p}</a>`)}</div>` : null}
      <div class="a-detail-actions">
        <button class="btn primary" disabled=${busy} onClick=${() => onAct(it, { type: "accept" })}>Accept <kbd>a</kbd></button>
        ${confirmClose
          ? html`<button class="btn qv-confirm" disabled=${busy} onClick=${() => onAct(it, { type: "close" })}>Close: removes a clean worktree</button>`
          : html`<button class="btn" disabled=${busy} onClick=${() => setConfirmClose(true)}>Close</button>`}
        ${it.has_report ? html`<button class="btn ghost" onClick=${() => onDetails(it, "report")}>Read the report</button>` : null}
        ${snoozeBtn}
      </div>`;
  } else if (it.kind === "artifact") {
    body = html`
      <p class="a-detail-sum">A ${it.sub || "draft"} for you to send or run, kept with ${it.owner}.</p>
      <div class="a-detail-actions"><button class="btn primary" disabled=${busy} onClick=${() => onAct(it, { type: "done" })}>Mark done <kbd>a</kbd></button>${snoozeBtn}</div>`;
  } else if (it.kind === "approve") {
    body = html`
      <p class="a-detail-sum qv-ask">${q.text}</p>
      ${blocks.length ? html`<div class="qv-blocks">${blocks.map((b, k) => html`<p key=${k}>${b.label ? html`<b>${b.label}: </b>` : null}${b.text}</p>`)}</div>` : null}
      ${it.files && it.files.includes("plan.md") ? html`<button class="link" onClick=${() => onDetails(it, "plan")}>Read the plan</button>` : null}
      ${noteBox("A note for the worker, or what to change")}
      <div class="a-detail-actions">
        <button class="btn primary" disabled=${busy} onClick=${() => onAct(it, { type: "approve" })}>Approve <kbd>↵</kbd></button>
        <button class="btn" disabled=${busy || !(note && note.trim())} title=${note && note.trim() ? "" : "Say what to change in the note"}
          onClick=${() => onAct(it, { type: "changes" })}>Request changes</button>
        ${snoozeBtn}
      </div>`;
  } else {
    // decide, inbox, blocked, failed, input, approval: one question, options when it has them
    body = html`
      ${q.text && q.text !== it.title ? html`<p class="a-detail-sum qv-ask">${q.text}</p>` : null}
      ${q.context ? html`<p class="muted">${q.context}</p>` : null}
      ${blocks.length ? html`<div class="qv-blocks">${blocks.map((b, k) => html`<p key=${k}>${b.label ? html`<b>${b.label}: </b>` : null}${b.text}</p>`)}</div>` : null}
      ${q.options.length ? html`<${Options} options=${q.options} picked=${picks && picks[1]} onPick=${(l) => setPick(1, l)} />` : null}
      <${Why} text=${q.why} />
      ${noteBox(q.options.length ? "Add a note, or answer in your own words" : "Your answer, in your own words")}
      <div class="a-detail-actions">
        <button class="btn primary" disabled=${busy || !hasAnswer} onClick=${() => onAct(it, { type: it.card ? "answer" : "tell" })}>Send to the ${xo} <kbd>⌘↵</kbd></button>
        ${it.kind === "inbox" ? html`<button class="btn ghost" disabled=${busy} title="Already answered elsewhere: take it off the list"
            onClick=${() => onAct(it, { type: "done" })}>Mark done</button>` : null}
        ${snoozeBtn}
      </div>`;
  }
  const ctx = [];
  if (it.task) ctx.push(["Task", html`<button class="link" onClick=${() => onDetails(it)}>${it.title} <span class="faint">${it.short_id}</span></button>`]);
  ctx.push(["Home", html`<${HomeTag} name=${it.home} hue=${it.hue} />`]);
  if (it.project) ctx.push(["Project", it.project]);
  if (it.intent) ctx.push(["Intent", html`<span class="intent">${it.intent}</span>`]);
  if (it.live && it.task) ctx.push(["Worker", it.live]);
  if (it.round && it.round.n) ctx.push(["Round", it.round.n + (it.round.of ? " of about " + it.round.of : "")]);
  return html`<aside class=${"a-detail" + (open ? " open" : "")} aria-label="Quick view">
    <div class="a-detail-h">
      <${Pill} kind=${it.kind} text=${it.sub ? M.kind(it.kind).label + " · " + it.sub : null} />
      <span class="faint">${M.agoText(it.at)}</span><span class="grow"></span>
      ${it.task || it.kind === "round" ? html`<button class="btn ghost sm od" title="Open details (o)" onClick=${() => onDetails(it)}><span class="od-ic"></span>Open details</button>` : null}
      <button class="btn ghost icon qv-close" aria-label="Close" onClick=${onClose}>×</button>
    </div>
    <h2 class="a-detail-title">${it.title}</h2>
    <div class="a-detail-meta"><span class="meta"><${HomeTag} name=${it.home} hue=${it.hue} />${it.project ? html`<span class="dot-sep">${it.project}</span>` : null}</span></div>
    ${body}
    <dl class="a-ctx">${ctx.map(([k, v]) => html`<${React.Fragment} key=${k}><dt>${k}</dt><dd class=${k === "Intent" ? "intent" : ""}>${v}</dd></${React.Fragment}>`)}</dl>
  </aside>`;
}
