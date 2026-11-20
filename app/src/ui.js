// ui.js - the design system's small components (app/styles/base.css), as React.
import { html, useEffect, useRef } from "./html.js";

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

export function Toasts({ toasts, onUndo }) {
  return html`<div class="toasts" aria-live="polite">
    ${toasts.map((t) => html`<div key=${t.id} class="toast"><span>${t.text}</span>
      ${t.undo ? html`<button type="button" onClick=${() => onUndo(t)}>Undo</button>` : null}</div>`)}
  </div>`;
}
