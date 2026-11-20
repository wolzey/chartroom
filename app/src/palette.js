// palette.js - the command palette (⌘K or /): jump to any item, switch a filter, change the theme.
import { html, useState, useEffect, useRef } from "./html.js";

const M = window.AppModel;

export function Palette({ entries, onClose }) {
  const [q, setQ] = useState("");
  const [hl, setHl] = useState(0);
  const input = useRef(null);
  const list = M.search(entries, q);
  useEffect(() => { if (input.current) input.current.focus(); }, []);
  useEffect(() => { setHl(0); }, [q]);
  const run = (e) => { if (!e) return; onClose(); e.run(); };
  const key = (e) => {
    // the palette's keys are its own: never the list's j/k/Enter underneath
    if (["ArrowDown", "ArrowUp", "Enter", "Escape"].includes(e.key) || e.ctrlKey) e.stopPropagation();
    if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) { e.preventDefault(); setHl(Math.min(list.length - 1, hl + 1)); }
    else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) { e.preventDefault(); setHl(Math.max(0, hl - 1)); }
    else if (e.key === "Enter") { e.preventDefault(); run(list[hl]); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onClose(); }
  };
  let lastGroup = null;
  return html`<div class="palette-scrim open" onMouseDown=${(e) => { if (e.target === e.currentTarget) onClose(); }}>
    <div class="palette" role="dialog" aria-label="Command palette">
      <div class="p-in"><span class="s-ic" aria-hidden="true"></span>
        <input ref=${input} value=${q} placeholder="Search items, homes and commands…" onInput=${(e) => setQ(e.target.value)} onKeyDown=${key} /></div>
      <div class="p-list" role="listbox">
        ${list.length ? list.map((e, i) => {
          const head = e.group !== lastGroup ? html`<div class="p-h" key=${"h" + i}>${e.group}</div>` : null;
          lastGroup = e.group;
          return html`<${React.Fragment} key=${e.id}>${head}<button type="button" class=${"p-item" + (i === hl ? " hl" : "")}
              onMouseEnter=${() => setHl(i)} onClick=${() => run(e)}>
            <span class="grow truncate">${e.label}</span>${e.sub ? html`<span class="sub">${e.sub}</span>` : null}</button></${React.Fragment}>`;
        }) : html`<div class="p-empty faint">Nothing matches.</div>`}
      </div>
      <div class="p-foot faint"><span><kbd>↑</kbd><kbd>↓</kbd> move</span><span><kbd>↵</kbd> open</span><span><kbd>esc</kbd> close</span></div>
    </div>
  </div>`;
}
