// composer.js - a new task from anywhere (c): pick the home, write it, optionally a project and a
// priority. It goes to that home's XO as a request (chartroom request), which the XO briefs and
// dispatches, or asks about first; until then it waits in the board's Drafting column.
import { html, useState, useEffect, useRef } from "./html.js";

const PRIOS = ["urgent", "high", "medium", "low"];

export function Composer({ homes, home, projects, onSend, onClose }) {
  const [h, setH] = useState(home || (homes[0] && homes[0].name));
  const [title, setTitle] = useState("");
  const [desc, setDesc] = useState("");
  const [project, setProject] = useState("");
  const [prio, setPrio] = useState("");
  const titleRef = useRef(null);
  useEffect(() => { if (titleRef.current) titleRef.current.focus(); }, []);
  const send = () => {
    if (!title.trim() || !h) return;
    onSend(h, { title: title.trim(), description: desc.trim() || undefined, project: project || undefined, priority: prio || undefined });
  };
  const key = (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); e.stopPropagation(); send(); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onClose(); }
  };
  const list = projects(h);
  return html`<div class="palette-scrim open cmp-scrim" onMouseDown=${(e) => { if (e.target === e.currentTarget) onClose(); }}>
    <div class="palette cmp" role="dialog" aria-label="New task" onKeyDown=${key}>
      <div class="cmp-h"><span class="faint">New task in</span>
        <div class="cmp-homes">${homes.map((x) => html`<button key=${x.name} type="button" class=${"ph-chip" + (x.name === h ? " on" : "")} onClick=${() => { setH(x.name); setProject(""); }}>
          <span class=${"home-dot hue-" + x.hue}></span>${x.name}</button>`)}</div></div>
      <input class="cmp-title" type="text" ref=${titleRef} placeholder="What needs doing?" value=${title} onInput=${(e) => setTitle(e.target.value)} maxlength="200" />
      <textarea class="cmp-desc" rows="5" placeholder="Describe it: what, why, and anything the worker should know." value=${desc} onInput=${(e) => setDesc(e.target.value)}></textarea>
      <div class="cmp-row filters">
        <label class="filter"><span class="k">Project</span>
          <select class="cmp-sel" value=${project} onChange=${(e) => setProject(e.target.value)}>
            <option value="">Any</option>${list.map((p) => html`<option key=${p} value=${p}>${p}</option>`)}</select></label>
        <span class="cmp-prio">${PRIOS.map((p) => html`<button key=${p} type="button" class=${"filter" + (prio === p ? " set" : "")} onClick=${() => setPrio(prio === p ? "" : p)}>${p[0].toUpperCase() + p.slice(1)}</button>`)}</span>
      </div>
      <div class="cmp-foot"><span class="faint grow">It goes to the ${h} XO as a request: it briefs and dispatches it, or asks you first.</span>
        <button class="btn ghost sm" onClick=${onClose}>Cancel</button>
        <button class="btn primary sm" disabled=${!title.trim()} onClick=${send}>Send to the XO <kbd>⌘↵</kbd></button></div>
    </div>
  </div>`;
}
