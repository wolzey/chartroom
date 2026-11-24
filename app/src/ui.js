// ui.js - the design system's small components (app/styles/base.css), as React.
import { html, useEffect, useRef, useState } from "./html.js";

const M = window.AppModel;

// Text with every URL a link (a new tab, no opener); GitHub PRs and issues read "repo#123". A click
// on a link never selects the row or card it sits in.
export function Linked({ text }) {
  if (text == null || text === "") return null;
  return M.linkParts(text).map((p, i) => (p.href
    ? html`<a key=${i} href=${p.href} target="_blank" rel="noopener noreferrer" title=${p.href} onClick=${(e) => e.stopPropagation()}>${p.label}</a>`
    : p.text));
}

// The same for text rendered outside React (markdown.js's DOM): every URL in a text node, a link.
export function linkifyDom(root) {
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walk.nextNode()) if (/https?:\/\//.test(walk.currentNode.nodeValue) && !walk.currentNode.parentElement.closest("a, code, pre")) nodes.push(walk.currentNode);
  for (const n of nodes) {
    const frag = document.createDocumentFragment();
    for (const p of M.linkParts(n.nodeValue)) {
      if (!p.href) { frag.append(p.text); continue; }
      const a = document.createElement("a");
      a.href = p.href; a.target = "_blank"; a.rel = "noopener noreferrer"; a.title = p.href; a.textContent = p.label;
      frag.append(a);
    }
    n.replaceWith(frag);
  }
}

// Pull requests, the way Linear shows them. <pr> is the server's gh lookup ({state, num, repo,
// title, checks, reviewers, branch, base, automerge}), or nothing yet: then the URL alone, with
// "No check data".
const PR_STATE = { draft: "Draft", open: "Open", approved: "Approved", changes: "Changes requested", merged: "Merged", closed: "Closed" };
function prName(url, pr) {
  if (pr && pr.repo) return pr.repo.split("/").pop() + pr.num;
  // a GitHub PR, or an Azure DevOps one (…/_git/<repo>/pullrequest/<n>): "repo#n", never the whole URL
  const m = /github\.com\/[^/]+\/([^/]+)\/pull\/(\d+)/.exec(url || "") || /\/_git\/([^/?#]+)\/pullrequest\/(\d+)/.exec(url || "");
  return m ? m[1] + "#" + m[2] : url;
}
export function PrIcon({ state }) {
  return html`<span class=${"pr-ic pr-" + (PR_STATE[state] ? state : "open")} aria-hidden="true"><i></i></span>`;
}
export function PrBadges({ urls, prs, max }) {
  if (!urls || !urls.length) return null;
  const shown = max ? urls.slice(0, max) : urls, more = urls.length - shown.length;
  return html`<span class="pr-badges">${shown.map((u) => {
    const p = (prs || {})[u], c = p && p.checks;
    const dot = !c ? "" : c.fail ? " ck-fail" : c.run ? " ck-run" : "";
    return html`<a key=${u} class=${"pr-badge pr-b-" + ((p && p.state) || "open") + dot} href=${u} target="_blank" rel="noopener noreferrer"
      title=${prName(u, p) + (p ? " · " + PR_STATE[p.state] : "")} onClick=${(e) => e.stopPropagation()}>
      <${PrIcon} state=${p && p.state} />${prName(u, p).replace(/^.*#/, "#")}</a>`;
  })}${more > 0 ? html`<span class="pr-badge pr-more">+${more}</span>` : null}</span>`;
}
function checks(c) {
  if (!c) return html`<span class="ck-sum none">No check data</span>`;
  if (c.fail) return html`<span class="ck-sum fail"><b>✕</b> ${c.fail} failing · ${c.pass} of ${c.total} passed</span>`;
  if (c.run) return html`<span class="ck-sum run"><b>◌</b> ${c.run} running · ${c.pass} of ${c.total} passed</span>`;
  return html`<span class="ck-sum pass"><b>✓</b> ${c.pass === c.total ? "All checks passed" : c.pass + " of " + c.total + " checks passed"}</span>`;
}
export function PrCard({ url, pr, compact }) {
  const st = (pr && pr.state) || "open";
  return html`<div class=${"pr-card pr-c-" + st + (compact ? " compact" : "")}>
    <div class="pr-top"><${PrIcon} state=${st} /><span class="pr-title grow">${pr && pr.title ? pr.title : prName(url, pr)}</span>
      <a class="btn ghost sm gh" href=${url} target="_blank" rel="noopener noreferrer" title="Open on GitHub">GitHub ↗</a></div>
    <div class="pr-sub"><span class="pr-repo">${prName(url, pr)}</span>${pr ? html`<span class="pr-state">${PR_STATE[st]}</span>` : null}
      ${pr && pr.automerge ? html`<span class="pr-am">Auto-merge on</span>` : null}
      ${pr && pr.branch ? html`<span class="pr-branch truncate" title=${pr.branch + " → " + (pr.base || "main")}>${pr.branch} <span class="faint">→ ${pr.base || "main"}</span></span>` : null}</div>
    <div class="pr-meta">${checks(pr && pr.checks)}
      ${((pr && pr.reviewers) || []).map((r) => html`<span key=${r.name} class=${"rv rv-" + r.state}><span class="rv-t">${r.name} · ${{ approved: "approved", changes: "changes requested" }[r.state] || "commented"}</span></span>`)}</div>
  </div>`;
}

export function Pill({ kind, text }) {
  const k = M.kind(kind);
  const cls = { decide: "decide", round: "round", approve: "approve", blocked: "blocked", read: "read", tidy: "tidy" }[k.glyph] || "read";
  return html`<span class=${"pill " + cls}>${text || k.label}</span>`;
}

export function Glyph({ kind }) {
  return html`<span class=${"glyph " + M.kind(kind).glyph} aria-hidden="true"></span>`;
}

export function HomeTag({ name, hue }) {
  return html`<span class="home-tag"><span class=${"home-dot hue-" + (hue || 5)} aria-hidden="true"></span>${name}</span>`;
}

export function Status({ status, only }) {
  if (!status) return null;
  return html`<span class=${"st st-" + status + (only ? " st-only" : "")}><i></i>${only ? null : M.STATUS[status] || status}</span>`;
}

export function Tabs({ tabs, active, onPick }) {
  return html`<div class="tabs" role="tablist">
    ${tabs.map((t) => html`<button key=${t.id} class="tab" role="tab" aria-selected=${t.id === active} onClick=${() => onPick(t.id)}>
      ${t.label}${t.count != null ? html` <span class="count">${t.count}</span>` : null}</button>`)}
  </div>`;
}

export function Empty({ title, text, children }) {
  return html`<div class="empty"><div class="mark">✓</div><h3>${title}</h3><p>${text}</p>${children || null}</div>`;
}

// One question's options. picked: the label picked; onPick(label).
export function Options({ options, picked, onPick, compact }) {
  return html`<div class="options" role="radiogroup">
    ${options.map((o, i) => html`<button key=${i} type="button" class=${"opt" + (o.rec ? " rec" : "")} role="radio"
        aria-checked=${picked === o.label} onClick=${() => onPick(picked === o.label ? null : o.label)}>
      <span class="n">${i + 1}</span>
      <span class="grow"><span class="t"><${Linked} text=${o.label} /></span>${o.detail && !compact ? html`<span class="d"><${Linked} text=${o.detail} /></span>` : null}</span>
      ${o.rec ? html`<span class="tag"><span class="pill rec">Recommended</span></span>` : null}
    </button>`)}
  </div>`;
}

export function Why({ text }) {
  if (!text) return null;
  return html`<div class="why"><span><b>Why recommended.</b> ${text}</span></div>`;
}

// A menu at an anchor element: items [{id, label, sub, n}]; closes on pick, Escape or a click outside.
export function Menu({ anchor, title, items, picked, onPick, onClose }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || !anchor) return;
    const r = anchor.getBoundingClientRect();
    const w = el.offsetWidth, h = el.offsetHeight;
    el.style.left = Math.max(12, Math.min(r.left, window.innerWidth - w - 12)) + "px";
    el.style.top = (r.bottom + 6 + h > window.innerHeight ? Math.max(12, r.top - h - 6) : r.bottom + 6) + "px";
    const first = el.querySelector("button"); if (first) first.focus();
    const away = (e) => { if (!el.contains(e.target) && e.target !== anchor) onClose(); };
    const key = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    setTimeout(() => document.addEventListener("mousedown", away), 0);
    document.addEventListener("keydown", key, true);
    return () => { document.removeEventListener("mousedown", away); document.removeEventListener("keydown", key, true); };
  }, [anchor]);
  return html`<div class="menu" role="menu" ref=${ref}>
    <div class="menu-h">${title}</div>
    ${items.map((x) => html`<button key=${x.id} type="button" role="menuitemradio" aria-checked=${picked === x.id}
        onClick=${() => { onPick(x); onClose(); }}>
      ${x.hue ? html`<span class=${"home-dot hue-" + x.hue}></span>` : null}
      <span class="grow truncate">${x.label}${x.sub ? html` <span class="faint">${x.sub}</span>` : null}</span>
      ${x.n != null ? html`<span class="n">${x.n}</span>` : null}
    </button>`)}
  </div>`;
}

export function Toasts({ toasts, onUndo, stale, onReload }) {
  return html`<div class="toasts" aria-live="polite">
    ${stale ? html`<div class="toast"><span>A newer Chartroom is installed; this page still runs the old one.</span>
      <button type="button" onClick=${onReload}>Reload</button></div>` : null}
    ${toasts.map((t) => html`<div key=${t.id} class="toast"><span>${t.text}</span>
      ${t.undo ? html`<button type="button" onClick=${() => onUndo(t)}>Undo</button>` : null}</div>`)}
  </div>`;
}

// The commander's decisions on a task (lib/ask.sh, decisions_json): each answered card, its
// questions in their own words with the answer and the note, when, where it was answered, and a
// link to the card while it is still in the app (a round's page). Long rounds fold after three.
const VIA = { app: "in the app", terminal: "in the terminal", xo: "through the XO" };
export function DecisionList({ items, home, cardHref }) {
  const [open, setOpen] = useState({});
  if (!items || !items.length) return null;
  return html`<ol class="dec-list">${items.map((d) => {
    const qs = d.questions || [];
    const shown = open[d.card] || qs.length <= 4 ? qs : qs.slice(0, 3);
    const href = cardHref ? cardHref(d) : null;
    return html`<li key=${d.card} class="dec-item">
      <div class="dec-top"><span class="dec-title"><${Linked} text=${d.title} /></span></div>
      <div class="dec-m faint">${d.kind === "round" ? qs.length + " questions · " : ""}answered ${M.agoText(d.at)}${VIA[d.via] ? " " + VIA[d.via] : ""}${href
        ? html` · <a href=${href}>${d.kind === "round" ? "open the round" : "open the card"}</a>` : null}</div>
      ${qs.length ? html`<ul class="dec-qs">${shown.map((q, i) => html`<li key=${i}>
          ${qs.length > 1 || (q.text && q.text !== d.title) ? html`<div class="dec-q"><${Linked} text=${q.text} /></div>` : null}
          <div class="dec-a">${q.choice ? html`<b>${q.choice}</b>` : null}${q.choice && q.note ? html`<span class="faint"> · </span>` : null}${q.note
            ? html`<span class="dec-note"><${Linked} text=${q.note} /></span>` : null}${!q.choice && !q.note ? html`<span class="faint">no answer</span>` : null}</div></li>`)}</ul>` : null}
      ${shown.length < qs.length ? html`<button class="link dec-more" onClick=${() => setOpen(Object.assign({}, open, { [d.card]: true }))}>Show all ${qs.length}</button>` : null}
      ${d.note ? html`<p class="dec-note muted">Note: <${Linked} text=${d.note} /></p>` : null}
    </li>`;
  })}</ol>`;
}
