// needs.js - Needs me: one inbox across every home, grouped Decide / Approve / Unblock / Read, and the
// quick view beside it where most items are answered without leaving the list. A row click selects
// (never navigates); the full page opens only from Open details, o or Shift+Enter.
import { html, useState, useRef, useEffect } from "./html.js";
import { Pill, Glyph, HomeTag, Tabs, Empty, Options, Why, Menu, Linked, PrCard, PrBadges } from "./ui.js";

const M = window.AppModel;
const EF = window.EventFmt;

// A row's button names the recommendation in a few words: its first sentence, cut short.
function short(label) {
  const first = String(label).split(/(?<=[.;])\s/)[0].replace(/[.;]$/, "");
  return first.length > 34 ? first.slice(0, 33).replace(/\s+\S*$/, "") + "…" : first;
}

function quickLabel(it) {
  if (it.kind === "permission") return "Review";
  const p = M.primary(it, EF);
  if (p.type === "answer") return short(p.choice);
  if (p.type === "open-round") return "Answer " + (it.questions || []).length;
  if (p.type === "approve") return "Approve";
  if (p.type === "accept") return "Accept";
  if (p.type === "done") return "Mark done";
  return "Answer";
}

// The title a person reads: tidied of chartroom's ids and paths (model.js, view).
const titleOf = (it) => (it.view && it.view.title) || it.title;

// The rest of a card after its title: what introduces the list, the list (several questions or
// steps, one a line), and the remainder, folded when it is long.
function ViewBody({ v, lead }) {
  const [open, setOpen] = useState(false);
  if (!v) return null;
  const long = v.more && v.more.length > 220;
  return html`
    ${lead && v.lead ? html`<p class="a-detail-sum qv-ask"><${Linked} text=${v.lead} /></p>` : null}
    ${v.list && v.list.length ? html`<div class="qv-list">${v.intro ? html`<div class="qv-list-h">${v.intro}</div>` : null}
      <ul>${v.list.map((x, k) => html`<li key=${k}><${Linked} text=${x} /></li>`)}</ul></div>` : null}
    ${v.more ? (long && !open
      ? html`<p class="muted qv-more">${v.more.slice(0, 200).replace(/\s+\S*$/, "")}… <button class="link" onClick=${() => setOpen(true)}>Show more</button></p>`
      : html`<p class="muted qv-more"><${Linked} text=${v.more} /></p>`) : null}`;
}

function sentLine(it) {
  if (!it.sent) return null;
  if (it.sent.withdrawn) return "withdrawn by the XO";
  if (it.sent.read_by_xo) return "read by the XO";
  return it.sent.via === "terminal" ? "answered in the terminal" : "sent · not read yet";
}

function Row({ it, i, sel, ob, picked, picking, onSelect, onQuick, onPick, prs }) {
  const pending = ob === "pending";
  const sent = ob === "failed" ? null : pending ? "sending…" : sentLine(it) || (ob === "done" ? "sent · not read yet" : null);
  return html`<div class=${"a-row" + (sel ? " sel" : "") + (pending ? " pending" : "") + (picked ? " picked" : "") + (picking ? " picking" : "")}
      data-key=${it.key} role="option" aria-selected=${sel} tabindex="-1"
      onMouseDown=${(e) => { if (e.shiftKey) e.preventDefault(); /* a range select, not a text selection */ }}
      onClick=${(e) => { if (e.shiftKey || e.metaKey || e.ctrlKey) { e.preventDefault(); onPick(it.key, e.shiftKey ? "range" : "toggle"); } else onSelect(i); }}>
    <span class="pick-cell"><${Glyph} kind=${it.kind} />
      <input type="checkbox" class="pick" aria-label=${"Select " + it.title} checked=${!!picked}
        onClick=${(e) => { e.stopPropagation(); onPick(it.key, e.shiftKey ? "range" : "toggle"); }} onChange=${() => {}} /></span>
    <span class="a-row-title"><span class="truncate"><${Linked} text=${titleOf(it)} /></span><${PrBadges} urls=${it.prs} prs=${prs} max=${2} /></span>
    <span class="a-row-quick">${ob === "failed" ? html`<span class="sent-st failed">not sent · see above</span>` : sent
      ? html`<span class=${"sent-st" + (it.sent && it.sent.read_by_xo ? " read" : "")}>${sent}</span>`
      : html`<button class="btn sm" title="Enter" onClick=${(e) => { e.stopPropagation(); onQuick(it); }}>${quickLabel(it)}</button>`}</span>
    <span class="a-row-meta"><${HomeTag} name=${it.home} hue=${it.hue} />${it.project ? html`<span class="a-row-init truncate">${it.project}</span>` : null}</span>
    <span class="a-row-m">${it.short_id || ""}</span>
    <span class="a-row-age">${it.kind === "permission" ? html`<${Clock} it=${it} short=${true} />` : M.ago(it.at)}</span>
  </div>`;
}

// A permission card's countdown (to the broker's deny), live; amber, red in its last 2 minutes.
function Clock({ it, short }) {
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 1000); return () => clearInterval(t); }, []);
  const l = M.permitLeft(it);
  if (!l) return null;
  const text = !short ? l.text : l.secs == null ? "retry" : l.over ? "missed" : l.secs >= 60 ? Math.floor(l.secs / 60) + "m" : l.secs + "s";
  return html`<span class=${"perm-clock" + (l.over ? " over" : l.secs != null && l.secs < 120 ? " soon" : "")} title=${l.text}>${text}</span>`;
}

// A worker's tool call waiting on the commander (the permission broker, lib/permit.sh). It leads
// with what the worker wants, in plain words, and why it came to the commander; the call itself is
// one line, unfolded on request. Nothing here is allowed by a key: only these buttons answer it.
function PermitBody({ it, note, setNote, noteRef, busy, onAct }) {
  const [, tick] = useState(0);
  const [showCmd, setShowCmd] = useState(false);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 1000); return () => clearInterval(t); }, []);
  useEffect(() => { setShowCmd(false); }, [it.key]);
  const l = M.permitLeft(it);
  const late = l && l.over;
  const act = (answer) => onAct(it, { type: "permit", answer });
  const call = it.command != null ? it.command : it.input || it.desc || "";
  const fl = M.firstLine(it.command != null ? it.command : it.desc || "");
  const scope = M.permitScope(it);
  return html`
    <p class="perm-lead">${M.permitLead(it)}</p>
    <p class="muted perm-why">Asked because ${M.permitReason(it)}${it.project ? html`<span class="perm-repo"> · in <b>${it.project}</b></span>` : null}
      <span class="perm-left"> · <${Clock} it=${it} /></span></p>
    ${it.escalated ? html`<p class="perm-xo"><b>The XO left this one to you.</b>${it.escalated.note ? " " + it.escalated.note : ""}</p>` : null}
    ${!it.blocking && it.reason_denied ? html`<p class="faint perm-note">Auto mode refused it first (${it.reason_denied.replace(/^\[|\]$/g, "")}).</p>` : null}
    <div class=${"perm-call" + (showCmd ? " open" : "")}>
      <code class="perm-line" title=${fl.line}>${fl.line}</code>
      ${fl.more || it.command == null ? html`<button class="link perm-toggle" aria-expanded=${showCmd} onClick=${() => setShowCmd(!showCmd)}>${showCmd ? "Hide" : "Show command"}</button>` : null}
      ${showCmd ? html`<pre class="perm-cmd">${call}</pre>` : null}
    </div>
    ${late ? html`<p class="perm-late">The wait ran out. An allow still works: the worker is told to run it again.</p>` : null}
    <textarea class="input note" rows="2" ref=${noteRef} data-note="1" placeholder=${late || !it.blocking ? "A note for the worker (optional)" : "A note for the worker, sent with a deny (optional)"}
      value=${note || ""} onInput=${(e) => setNote(e.target.value)} disabled=${busy}></textarea>
    <div class="perm-acts">
      <button class="btn primary" disabled=${busy} onClick=${() => act("once")}>${late ? "Allow now" : "Allow once"}</button>
      <button class="btn" disabled=${busy} onClick=${() => act("always")}>Always for this task</button>
      ${late ? null : html`<button class="btn danger" disabled=${busy} onClick=${() => act("deny")}>Deny</button>`}
    </div>
    <p class="faint perm-scope">“Always” allows ${typeof scope === "string" ? scope : html`${scope.text} <code>${scope.code}</code>${scope.after}`}.</p>`;
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

// Finished tasks waiting for the commander's nod, apart from the questions, with Accept all: every
// one shown that asks nothing more (one whose report still asks something is opened, not accepted
// in bulk). Two clicks: the first says how many.
function FinishedHead({ g, items, onAcceptAll }) {
  const [confirm, setConfirm] = useState(false);
  const ok = items.filter((it) => it.kind === "review" && !(it.view && it.view.asks) && !it.sent);
  const asking = items.length - ok.length;
  useEffect(() => { setConfirm(false); }, [items.length]);
  return html`<div class="a-group a-group-finished" title=${g.hint}>
    <span>${g.heading || g.label}</span><span class="count">${items.length}</span><span class="grow"></span>
    ${asking ? html`<span class="faint a-group-note">${asking} still ${asking === 1 ? "asks" : "ask"} you something</span>` : null}
    ${ok.length && onAcceptAll ? (confirm
      ? html`<button class="btn sm primary" onClick=${() => { setConfirm(false); onAcceptAll(ok); }}>Accept ${ok.length}?</button>
          <button class="btn sm ghost" onClick=${() => setConfirm(false)}>Cancel</button>`
      : html`<button class="btn sm" onClick=${() => setConfirm(true)}>Accept all${ok.length !== items.length ? " " + ok.length : ""}</button>`) : null}
  </div>`;
}

export function NeedsList({ all, list, tab, setTab, filters, setFilters, homes, counts, sel, setSel, ob, onQuick, notices, picked, onPick, onPickAll, prs, onAcceptAll }) {
  const picking = picked.size > 0;
  const allPicked = list.length > 0 && list.every((it) => picked.has(it.key));
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
    rows = list.map((it) => html`<${Row} key=${it.key} it=${it} i=${i} sel=${i++ === sel} ob=${ob[it.key]} picked=${picked.has(it.key)} picking=${picking} onSelect=${setSel} onQuick=${onQuick} onPick=${onPick} prs=${prs} />`);
  } else {
    for (const g of M.GROUPS) {
      const inG = list.filter((it) => it.group === g.id);
      if (!inG.length) continue;
      rows.push(g.id === "finished"
        ? html`<${FinishedHead} key=${"g-" + g.id} g=${g} items=${inG} onAcceptAll=${onAcceptAll} />`
        : html`<div key=${"g-" + g.id} class="a-group" title=${g.hint}><span>${g.heading || g.label}</span><span class="count">${inG.length}</span></div>`);
      for (const it of inG) {
        const k = i++;
        rows.push(html`<${Row} key=${it.key} it=${it} i=${k} sel=${k === sel} ob=${ob[it.key]} picked=${picked.has(it.key)} picking=${picking} onSelect=${setSel} onQuick=${onQuick} onPick=${onPick} prs=${prs} />`);
      }
    }
  }
  return html`<main class="a-main">
    <header class="a-head">
      <div class="a-head-l"><h1>Needs me</h1><span class="faint">${counts.all} ${counts.all === 1 ? "item" : "items"}${homesWith > 1 ? " · " + homesWith + " homes" : ""}</span></div>
      <${Tabs} tabs=${tabs} active=${tab} onPick=${(t) => { setTab(t); setSel(0); }} />
    </header>
    <div class="a-toolbar">
      <label class="sel-all" title="Select every item shown (⌘A)">
        <input type="checkbox" checked=${allPicked} ref=${(el) => { if (el) el.indeterminate = picking && !allPicked; }}
          onChange=${() => onPickAll(!allPicked)} disabled=${!list.length} /></label>
      <${Filters} all=${all} filters=${filters} setFilters=${(f) => { setFilters(f); setSel(0); }} homes=${homes} />
      <span class="grow"></span>
      <span class="a-keys faint"><span><kbd>j</kbd><kbd>k</kbd> move</span><span><kbd>↵</kbd> answer</span><span><kbd>o</kbd> details</span><span><kbd>1</kbd><kbd>2</kbd><kbd>3</kbd> choose</span><span><kbd>s</kbd> snooze</span><span><kbd>x</kbd> select</span></span>
    </div>
    ${notices}
    <div class="a-list" role="listbox" aria-label="Needs me">${rows}</div>
  </main>`;
}

// An item's question and the controls that answer it: the quick view's body, and the ticket's
// banner when the task waits on the commander.
export function AskBody({ it, picks, setPick, note, setNote, busy, onAct, onDetails, snoozeAnchorRef, snoozeOpen, setSnoozeOpen, prs, hidePrs, undelivered }) {
  const [confirmClose, setConfirmClose] = useState(false);
  const noteRef = useRef(null);
  useEffect(() => { setConfirmClose(false); }, [it && it.key]);
  const qs = M.questions(it, EF);
  const q = qs[0];
  const blocks = M.details(it, EF);
  const sent = it.sent;
  const xo = it.home + " XO";
  const hasAnswer = (picks && picks[1] != null) || (note && note.trim());
  const snoozeBtn = it.ref && setSnoozeOpen ? html`<button class="btn ghost" ref=${snoozeAnchorRef} onClick=${() => setSnoozeOpen(!snoozeOpen)} disabled=${busy}>Snooze <kbd>s</kbd></button>` : null;
  const noteBox = (placeholder) => html`<textarea class="input note" rows="2" ref=${noteRef} data-note="1" placeholder=${placeholder}
      value=${note || ""} onInput=${(e) => setNote(e.target.value)} disabled=${busy || !!sent}></textarea>`;
  let body = null;
  if (sent) {
    body = sent.pending ? html`<div class="qv-sent"><span><b>Sending…</b> It is queued here and goes as soon as the server takes it; nothing more to do.</span></div>`
      : html`<div class="qv-sent"><span><b>${sent.withdrawn ? "Withdrawn" : "Sent"}</b> ${M.agoText(sent.at)}${sent.via === "terminal" ? " from the terminal" : ""}.
      ${sent.withdrawn ? "" : sent.read_by_xo ? " The XO has read it." : undelivered ? " Kept, not yet read: it reaches the XO once this version of chartroom is installed and its watch restarted."
        : " Not read by the XO yet; it waits in the home's mailbox until an XO session reads it."}</span>
      ${sent.words ? html`<span class="words faint"><${Linked} text=${sent.words} /></span>` : null}</div>`;
  } else if (it.kind === "round") {
    // a round is never answered in the side panel: one line, and it opens in the main area
    body = html`
      <div class="a-detail-actions"><button class="btn primary" onClick=${() => onDetails(it)}>Open grilling · ${qs.length} questions <kbd>↵</kbd></button>${snoozeBtn}</div>`;
  } else if (it.kind === "review") {
    body = html`
      ${it.view ? html`<${ViewBody} v=${it.view} lead=${true} />` : html`<p class="a-detail-sum qv-ask"><${Linked} text=${it.summary || "The worker reported done."} /></p>`}
      ${it.view && it.view.asks ? html`<p class="qv-asks">The report still asks you something: read it before you accept.</p>` : null}
      ${(it.prs || []).length && !hidePrs ? html`<div class="q-prs"><div class="d-h">Pull requests <span class="count">${it.prs.length}</span></div>
        ${it.prs.map((u) => html`<${PrCard} key=${u} url=${u} pr=${(prs || {})[u]} compact=${true} />`)}</div>` : null}
      <div class="a-detail-actions">
        <button class="btn primary" disabled=${busy} onClick=${() => onAct(it, { type: "accept" })}>Accept <kbd>a</kbd></button>
        ${confirmClose
          ? html`<button class="btn qv-confirm" disabled=${busy} onClick=${() => onAct(it, { type: "close" })}>Close: removes a clean worktree</button>`
          : html`<button class="btn" disabled=${busy} onClick=${() => setConfirmClose(true)}>Close</button>`}
        ${it.has_report ? html`<button class="btn ghost" onClick=${() => onDetails(it, "report")}>Read the report</button>` : null}
        ${snoozeBtn}
      </div>`;
  } else if (it.kind === "stories") {
    // approved on the initiative's page, where the whole checklist fits
    body = html`<p class="a-detail-sum">${it.summary}</p>
      <div class="a-detail-actions"><button class="btn primary" onClick=${() => onDetails(it)}>Review the stories <kbd>↵</kbd></button>${snoozeBtn}</div>`;
  } else if (it.kind === "permission") {
    body = html`<${PermitBody} it=${it} note=${note} setNote=${setNote} noteRef=${noteRef} busy=${busy} onAct=${onAct} />`;
  } else if (it.kind === "login") {
    // only the commander can sign in again; it leaves Needs me by itself at the next fleet check
    const cmd = (it.summary || "").replace(/^Sign in again on [^:]+: /, "").replace(/\. Until then.*$/, "");
    body = html`<p class="a-detail-sum">${it.summary}</p>
      ${it.detail ? html`<p class="muted">${it.detail}</p>` : null}
      <div class="qv-sent"><span>On <b>${it.machine}</b>, run:</span><code class="qv-cmd">${cmd}</code>
        <span>It clears here at the next fleet check, or press Check again on Fleet.</span></div>
      <div class="a-detail-actions"><button class="btn primary" onClick=${() => onDetails(it)}>Open Fleet <kbd>↵</kbd></button></div>`;
  } else if (it.kind === "artifact") {
    body = html`
      <p class="a-detail-sum">A ${it.sub || "draft"} for you to send or run, kept with ${it.owner}.</p>
      <div class="a-detail-actions"><button class="btn primary" disabled=${busy} onClick=${() => onAct(it, { type: "done" })}>Mark done <kbd>a</kbd></button>${snoozeBtn}</div>`;
  } else if (it.kind === "approve") {
    body = html`
      <p class="a-detail-sum qv-ask"><${Linked} text=${q.text} /></p>
      ${blocks.length ? html`<div class="qv-blocks">${blocks.map((b, k) => html`<p key=${k}>${b.label ? html`<b>${b.label}: </b>` : null}<${Linked} text=${b.text} /></p>`)}</div>` : null}
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
    const prompt = it.kind === "input";
    // an inbox line or an approval is one text: its title is the first sentence, the body the rest
    const own = (it.type === "inbox" || it.type === "approval") && it.view && !q.options.length;
    body = html`
      ${prompt ? html`<div class="qv-sent"><span><b>The worker is stopped at a prompt in its terminal</b>: a permission or a question
        chartroom cannot read, so there is nothing to choose here. Open its terminal and answer it there:</span>
        <code class="qv-cmd">chartroom attach ${it.short_id || it.task}</code>
        <span>Or write below, and the XO will see to it.</span></div>` : null}
      ${own ? html`<${ViewBody} v=${it.view} />` : html`
        ${q.text && !M.repeats(titleOf(it), q.text) && !prompt ? html`<p class="a-detail-sum qv-ask"><${Linked} text=${M.plain(q.text, null, it.project)} /></p>` : null}
        ${q.context ? html`<p class="muted"><${Linked} text=${M.plain(q.context, null, it.project)} /></p>` : null}
        ${blocks.length ? html`<div class="qv-blocks">${blocks.map((b, k) => html`<p key=${k}>${b.label ? html`<b>${b.label}: </b>` : null}<${Linked} text=${M.plain(b.text)} /></p>`)}</div>` : null}`}
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
  return body;
}

// The quick view: the selected item, answered in place.
export function QuickView(props) {
  const { it, open, onClose, onDetails } = props;
  if (!it) return html`<aside class="a-detail"><div class="a-detail-empty faint">Select something to see it here.</div></aside>`;
  const ctx = [];
  if (it.task) ctx.push(["Task", html`<button class="link" onClick=${() => onDetails(it)}>${it.title} <span class="faint">${it.short_id}</span></button>`]);
  ctx.push(["Home", html`<${HomeTag} name=${it.home} hue=${it.hue} />`]);
  if (it.project) ctx.push(["Project", it.project]);
  if (it.intent) ctx.push(["Intent", html`<span class="intent"><${Linked} text=${it.intent} /></span>`]);
  if (it.live && it.task) ctx.push(["Worker", it.live]);
  if (it.round && it.round.n) ctx.push(["Round", it.round.n + (it.round.of ? " of about " + it.round.of : "")]);
  return html`<aside class=${"a-detail" + (open ? " open" : "")} aria-label="Quick view">
    <div class="a-detail-h">
      <${Pill} kind=${it.kind} text=${it.sub ? M.kind(it.kind).label + " · " + it.sub : null} />
      <span class="faint">${M.agoText(it.at)}</span><span class="grow"></span>
      ${it.task || it.kind === "round" ? html`<button class="btn ghost sm od" title="Open details (o)" onClick=${() => onDetails(it)}><span class="od-ic"></span>Open details</button>` : null}
      <button class="btn ghost icon qv-close" aria-label="Close" onClick=${onClose}>×</button>
    </div>
    <h2 class="a-detail-title"><${Linked} text=${titleOf(it)} /></h2>
    <div class="a-detail-meta"><span class="meta"><${HomeTag} name=${it.home} hue=${it.hue} />${it.project ? html`<span class="dot-sep">${it.project}</span>` : null}</span></div>
    <${AskBody} ...${props} />
    <dl class="a-ctx">${ctx.map(([k, v]) => html`<${React.Fragment} key=${k}><dt>${k}</dt><dd class=${k === "Intent" ? "intent" : ""}>${v}</dd></${React.Fragment}>`)}</dl>
  </aside>`;
}

// The bulk bar: what the selected items can have done to them, each with how many it applies to.
// Every item goes through the outbox on its own, so each one shows its own pending, sent or failed.
export function BulkBar({ items, onRun, onClear }) {
  const [confirm, setConfirm] = useState(false);
  const [snooze, setSnooze] = useState(null);
  const snoozeBtn = useRef(null);
  useEffect(() => { setConfirm(false); }, [items.length]);
  if (!items.length) return null;
  const n = (verb) => M.bulkPlan(items, verb).run.length;
  const done = n("done"), accept = n("accept"), close = n("close"), sn = n("snooze");
  // the menu sits beside the bar, not in it: the bar's transform would make the menu's fixed
  // position relative to the bar instead of the window
  return html`<${React.Fragment}><div class="bulk" role="toolbar" aria-label="Selected items">
    <span class="bulk-n"><b>${items.length}</b> selected</span>
    <button class="btn sm" disabled=${!done} onClick=${() => onRun("done")} title="Inbox questions and drafts are marked done; finished tasks are accepted">Mark done${done !== items.length && done ? " (" + done + ")" : ""}</button>
    ${accept ? html`<button class="btn sm" onClick=${() => onRun("accept")}>Accept (${accept})</button>` : null}
    ${close ? (confirm
      ? html`<button class="btn sm qv-confirm" onClick=${() => { setConfirm(false); onRun("close"); }}>Close ${close}? Work is never discarded</button>`
      : html`<button class="btn sm" onClick=${() => setConfirm(true)}>Close (${close})</button>`) : null}
    <button class="btn sm" ref=${snoozeBtn} disabled=${!sn} onClick=${() => setSnooze(snoozeBtn.current)}>Snooze${sn !== items.length && sn ? " (" + sn + ")" : ""}</button>
    <button class="btn ghost sm" title="Clear the selection (Esc)" onClick=${onClear}>Dismiss</button>
  </div>
  ${snooze ? html`<${Menu} anchor=${snooze} title="Snooze until" items=${M.snoozes().map((x) => ({ id: x.label, label: x.label, body: x.body }))}
      onPick=${(x) => onRun("snooze", x.body, x.label)} onClose=${() => setSnooze(null)} />` : null}</${React.Fragment}>`;
}
