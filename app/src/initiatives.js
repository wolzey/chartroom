// initiatives.js - initiatives (slice 4): the list across homes, an initiative's page and its
// creation. The page leads with the living plan (initiatives/<id>/plan.md, written by the XO): each
// section takes an inline comment, and an edit goes to the XO as a proposal, never straight into
// the plan. Then the milestones with their stories, the stories the XO proposed (a checklist the
// commander edits, drops, adds, reorders, orders by "after", and approves), the numbered decisions
// and the PRs. Every write is queued like any other action.
import { html, useState, useEffect, useRef } from "./html.js";
import { HomeTag, Status, Linked, linkifyDom, PrBadges, Tabs, DecisionList } from "./ui.js";

const M = window.AppModel;
const MD = window.Markdown;

function Doc({ text }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.textContent = "";
    if (MD) el.append(MD.render(MD.parse(text || ""), { shift: 1 })); else el.textContent = text || "";
    linkifyDom(el);
    for (const a of el.querySelectorAll("a[href^='http']")) { a.target = "_blank"; a.rel = "noopener noreferrer"; }
  }, [text]);
  return html`<div class="doc-b dt-doc" ref=${ref}></div>`;
}

function Ring({ done, total }) {
  const p = total ? Math.round((100 * done) / total) : 0;
  return html`<span class="ring" style=${{ "--p": p }} aria-hidden="true"></span>`;
}

const STATUS_LABEL = { shaping: "Shaping", active: "Active", closing: "Closing", closed: "Closed" };

export function InitiativesList({ list, onOpen, onNew }) {
  return html`<main class="a-main">
    <header class="a-head"><div class="a-head-l"><h1>Initiatives</h1><span class="faint">${list.length} open</span></div>
      <button class="btn primary sm" onClick=${onNew}>New initiative</button></header>
    <div class="a-list">${list.length ? list.map((i) => html`<div key=${i.key} class="a-row ini-row" onClick=${() => onOpen(i)}>
        <${Ring} done=${i.progress.done} total=${i.progress.total} />
        <span class="a-row-title"><span class="truncate">${i.name}</span></span>
        <span class="a-row-quick"><span class="faint">${STATUS_LABEL[i.status] || i.status}${i.progress.proposed ? " · " + i.progress.proposed + " to approve" : ""}</span></span>
        <span class="a-row-meta"><${HomeTag} name=${i.home} hue=${i.hue} /></span>
        <span class="a-row-m">${i.progress.done}/${i.progress.total}</span>
        <span class="a-row-age">${i.target || ""}</span>
      </div>`)
      : html`<div class="empty"><div class="mark">◇</div><h3>No initiatives yet</h3><p>An initiative is an epic: a goal, its stories across projects, its plan and its decisions.</p>
          <button class="btn primary" onClick=${onNew}>New initiative</button></div>`}</div>
  </main>`;
}

// The plan, section by section ("## " headings), each with an inline comment; Edit makes the whole
// text editable, and Propose sends it to the XO, who applies it and keeps the stories in sync.
function Plan({ plan, onComment, onPropose }) {
  const [open, setOpen] = useState(null);
  const [text, setText] = useState("");
  const [editing, setEditing] = useState(null);
  if (editing != null) {
    return html`<div class="doc editing">
      <div class="doc-bar"><span class="faint grow">Your edit goes to the XO as a proposal; it applies it and keeps the stories in sync.</span>
        <button class="btn ghost sm" onClick=${() => setEditing(null)}>Cancel</button>
        <button class="btn primary sm" disabled=${!editing.trim() || editing === plan} onClick=${() => { onPropose(editing); setEditing(null); }}>Propose changes</button></div>
      <textarea class="input plan-edit" rows=${Math.min(40, Math.max(12, editing.split("\n").length + 2))} value=${editing} onInput=${(e) => setEditing(e.target.value)}></textarea>
    </div>`;
  }
  if (!plan) {
    return html`<div class="doc"><p class="dt-empty">The XO has not written the plan yet. It writes it once the shaping round is answered; you can start it yourself:</p>
      <button class="btn sm" onClick=${() => setEditing("## Intent\n\n## Goal and criteria\n\n## Milestones\n\n## Open questions\n\n## Risks\n")}>Start the plan</button></div>`;
  }
  const secs = [];
  let cur = { head: null, body: [] };
  for (const line of plan.split("\n")) {
    const m = /^##\s+(.*)$/.exec(line);
    if (m) { if (cur.head || cur.body.join("").trim()) secs.push(cur); cur = { head: m[1].trim(), body: [] }; } else cur.body.push(line);
  }
  if (cur.head || cur.body.join("").trim()) secs.push(cur);
  return html`<div class="doc">
    <div class="doc-bar"><span class="faint grow">The living plan, kept by the XO. Comment on a section, or edit it and propose the change.</span>
      <button class="btn ghost sm" onClick=${() => setEditing(plan)}>Edit</button></div>
    ${secs.map((s, i) => html`<section key=${i} class="doc-sec">
      ${s.head ? html`<div class="doc-h"><h2><${Linked} text=${s.head} /></h2>
        <button class="doc-c" onClick=${() => { setOpen(open === i ? null : i); setText(""); }}>Comment</button></div>` : null}
      <${Doc} text=${s.body.join("\n")} />
      ${open === i ? html`<div class="composer"><textarea class="input" rows="2" value=${text} onInput=${(e) => setText(e.target.value)}
          placeholder="A comment for the XO on this section"></textarea>
        <div class="row-flex"><span class="grow"></span><button class="btn ghost sm" onClick=${() => setOpen(null)}>Cancel</button>
          <button class="btn primary sm" disabled=${!text.trim()} onClick=${() => { onComment(s.head, text.trim()); setOpen(null); }}>Send to the XO</button></div></div>` : null}
    </section>`)}
  </div>`;
}

// The stories the XO proposed: edit, drop, add, reorder, "after"; Approve dispatches the ready ones.
function Approval({ ini, onApprove }) {
  const [rows, setRows] = useState(() => (ini.stories || []).filter((s) => s.state === "proposed").map((s) => ({ id: s.id, title: s.title, project: s.project || "", after: s.after || [], drop: false })));
  // a new set of proposed stories (the XO proposed more, or they were approved) starts the checklist again
  const proposedKey = (ini.stories || []).filter((s) => s.state === "proposed").map((s) => s.id).join(",");
  useEffect(() => { setRows((ini.stories || []).filter((s) => s.state === "proposed").map((s) => ({ id: s.id, title: s.title, project: s.project || "", after: s.after || [], drop: false }))); }, [ini.id, proposedKey]);
  if (!rows.length) return null;
  const set = (i, patch) => setRows((r) => r.map((x, k) => (k === i ? Object.assign({}, x, patch) : x)));
  const move = (i, d) => setRows((r) => { const a = r.slice(); const j = i + d; if (j < 0 || j >= a.length) return a; [a[i], a[j]] = [a[j], a[i]]; return a; });
  const kept = rows.filter((r) => !r.drop);
  const ready = kept.filter((r) => !r.after.some((a) => kept.some((k) => k.id === a))).length;
  const others = (i) => rows.filter((r, k) => k !== i && r.id && !r.drop);
  return html`<section class="card ni-card approval">
    <div class="card-h"><${Status} status="needs" /><h3 class="grow">The XO proposes ${rows.length} ${rows.length === 1 ? "story" : "stories"}</h3></div>
    <p class="muted">Edit, drop, add or reorder them, and say what waits for what. Approving dispatches the ready ones now and holds the rest until what they come after is done.</p>
    <ol class="ni-list">${rows.map((r, i) => html`<li key=${r.id || "new" + i} class=${"ni-story" + (r.drop ? " dropped" : "")}>
      <span class="ni-move"><button class="btn ghost icon sm" aria-label="Up" onClick=${() => move(i, -1)}>↑</button><button class="btn ghost icon sm" aria-label="Down" onClick=${() => move(i, 1)}>↓</button></span>
      <input class="input ni-title" value=${r.title} onInput=${(e) => set(i, { title: e.target.value })} disabled=${r.drop} />
      <input class="input ni-proj" value=${r.project} placeholder="project" onInput=${(e) => set(i, { project: e.target.value })} disabled=${r.drop} />
      <select class="input ni-after" value=${r.after[0] || ""} onChange=${(e) => set(i, { after: e.target.value ? [e.target.value] : [] })} disabled=${r.drop}>
        <option value="">Ready now</option>${others(i).map((o) => html`<option key=${o.id} value=${o.id}>After: ${o.title.slice(0, 40)}</option>`)}</select>
      <button class="btn ghost sm" onClick=${() => set(i, { drop: !r.drop })}>${r.drop ? "Keep" : "Drop"}</button>
    </li>`)}</ol>
    <div class="row-flex"><button class="btn ghost sm ni-add" onClick=${() => setRows((r) => r.concat([{ id: null, title: "", project: "", after: [], drop: false }]))}>+ Add a story</button>
      <span class="grow"></span>
      <button class="btn primary" disabled=${!kept.length || kept.some((r) => !r.title.trim())}
        onClick=${() => onApprove(rows.map((r) => Object.assign({ title: r.title.trim(), after: r.after, drop: r.drop }, r.id ? { id: r.id } : {}, r.project.trim() ? { project: r.project.trim() } : {})))}>
        Approve: dispatch ${ready}, hold ${kept.length - ready}</button></div>
  </section>`;
}

function Milestones({ ini, onStory }) {
  const groups = M.milestones(ini);
  const [openIds, setOpenIds] = useState({});
  if (!groups.length) return html`<p class="dt-empty">No stories yet: the XO proposes them once the initiative is shaped.</p>`;
  return html`<div class="ms-list">${groups.map((g) => {
    const key = g.id || "loose";
    const open = openIds[key] != null ? openIds[key] : g.current || !g.finished;
    return html`<section key=${key} class=${"ms" + (open ? " open" : "") + (g.finished ? " ms-done" : "")}>
      <button class="ms-h" onClick=${() => setOpenIds(Object.assign({}, openIds, { [key]: !open }))}>
        <span class="chev" aria-hidden="true">›</span><span class=${"ms-ic " + (g.finished ? "done" : g.current ? "current" : "later")}></span>
        <b class="truncate">${g.name}</b><span class="bar"><i style=${{ width: (g.total ? Math.round((100 * g.done) / g.total) : 0) + "%" }}></i></span>
        <span class="ms-n faint">${g.done}/${g.total}</span><span class="ms-t faint">${g.target || ""}</span></button>
      ${open ? html`<div class="ms-b">${g.stories.length ? g.stories.map((s) => html`<div key=${s.id} class=${"story" + (s.task ? " clickable" : "")} onClick=${() => s.task && onStory(s)}>
          <${Status} status=${s.status === "dropped" ? "done" : s.status} />
          <span class="faint">${s.short_id || ""}</span>
          <span class="truncate"><${Linked} text=${s.title} /></span>
          <span class="faint truncate">${s.state === "held" ? "after " + (s.after || []).map((a) => ((ini.stories || []).find((x) => x.id === a) || {}).title || a).join(", ") : s.project || ""}</span>
          <span></span><span class="faint">${s.task ? "open ›" : ""}</span>
        </div>`) : html`<p class="ms-empty faint">No stories in this milestone yet.</p>`}</div>` : null}
    </section>`;
  })}</div>`;
}

export function InitiativePage({ home, hue, id, version, prs, tasksByHome, onAct, onBack, onOpenTask, onOpenRound, toast, cardHref }) {
  const [ini, setIni] = useState(null);
  const [err, setErr] = useState(null);
  const [tab, setTab] = useState("plan");
  const [confirm, setConfirm] = useState(false);
  useEffect(() => {
    let live = true;
    const t = setTimeout(() => {
      fetch("/api/v1/homes/" + encodeURIComponent(home) + "/initiatives/" + encodeURIComponent(id), { cache: "no-store", credentials: "same-origin" })
        .then((r) => (r.ok ? r.json() : r.json().then((j) => Promise.reject(new Error(j.error || r.status)))))
        .then((j) => { if (live) { setIni(j); setErr(null); } }).catch((e) => { if (live) setErr(e.message); });
    }, ini ? 250 : 0);
    return () => { live = false; clearTimeout(t); };
  }, [home, id, version]);
  if (!ini) {
    return html`<main class="a-main"><header class="a-head"><div class="a-head-l"><button class="link faint" onClick=${onBack}>Initiatives</button><span class="faint">/</span><h1>${id}</h1></div></header>
      <div class="page-body"><p class=${err ? "err-t" : "dt-empty"}>${err || "Reading the initiative…"}</p></div></main>`;
  }
  const p = ini.progress || { done: 0, total: 0, needs: 0, blocked: 0, proposed: 0 };
  const taskIds = (ini.stories || []).map((s) => s.task).filter(Boolean);
  const prUrls = [...new Set(taskIds.flatMap((t) => ((tasksByHome[home] || {})[t] || {}).prs || []))];
  const act = (action, body, label) => { onAct(action, Object.assign({ id }, body), label); toast(label); };
  const decisions = (ini.decisions || []).slice().reverse();
  // the commander's answers on its stories' tasks (lib/ask.sh, decisions_json), by story
  const taskDecs = ini.task_decisions || [];
  const superseded = {};
  for (const d of ini.decisions || []) if (d.supersedes) superseded[d.supersedes] = d.n;
  const tabs = [{ id: "plan", label: "Plan" }, { id: "stories", label: "Stories", count: p.total }, { id: "decisions", label: "Decisions", count: decisions.length + taskDecs.length }, { id: "prs", label: "PRs", count: prUrls.length }];
  const main = html`<main class="a-main">
    <header class="a-head"><div class="a-head-l"><button class="link faint" onClick=${onBack}>Initiatives</button><span class="faint">/</span>
      <${HomeTag} name=${home} hue=${hue} /><span class="faint">/</span><h1 class="truncate">${ini.name}</h1></div></header>
    <div class="page-body task-body">
      <div class="task-title"><${Ring} done=${p.done} total=${p.total} /><h1><${Linked} text=${ini.name} /></h1></div>
      ${ini.intent ? html`<p class="i-summary"><${Linked} text=${ini.intent} /></p>` : null}
      <div class="i-progress"><span><b>${p.done} of ${p.total}</b> stories done${p.needs ? html` · <span class="warn-t">${p.needs} need you</span>` : null}${p.blocked ? " · " + p.blocked + " blocked" : ""}${p.proposed ? " · " + p.proposed + " proposed" : ""}</span>
        <span class="bar"><i style=${{ width: (p.total ? Math.round((100 * p.done) / p.total) : 0) + "%" }}></i></span></div>
      ${ini.status === "shaping" && ini.card ? html`<div class="q-line q-needs big"><${Status} status="needs" only=${true} /><span class="grow">Shape it first: goal, success criteria, scope and non-goals</span>
        <button class="btn primary sm" onClick=${() => onOpenRound(ini.card)}>Answer the round</button></div>` : null}
      ${ini.status === "closing" ? html`<section class="card ni-card"><div class="card-h"><${Status} status="review" /><h3 class="grow">The XO proposes closing it</h3></div>
        ${ini.wrapup ? html`<${Doc} text=${ini.wrapup} />` : null}
        <div class="row-flex">${confirm ? html`<button class="btn primary" onClick=${() => act("initiative-close", {}, "Closed " + ini.name)}>Close it</button>`
          : html`<button class="btn primary" onClick=${() => setConfirm(true)}>Confirm the close</button>`}<span class="faint">Or comment on the plan to keep it open.</span></div></section>` : null}
      <${Approval} ini=${ini} onApprove=${(stories) => act("initiative-approve", { stories }, "Stories approved; the XO dispatches the ready ones")} />
      <${Tabs} tabs=${tabs} active=${tab} onPick=${setTab} />
      ${tab === "plan" ? html`<${Plan} plan=${ini.plan} onComment=${(section, text) => act("initiative-comment", { section, text }, "Comment sent to the XO")}
          onPropose=${(plan) => act("initiative-propose", { plan }, "Your edit went to the XO as a proposal")} />`
        : tab === "stories" ? html`<${Milestones} ini=${ini} onStory=${(s) => onOpenTask(home, s.task)} />`
        : tab === "decisions" ? html`<ol class="decisions">${decisions.length ? decisions.map((d) => html`<li key=${d.n} class=${"dec" + (superseded[d.n] ? " superseded" : "")}>
            <span class="dec-n">D${d.n}</span><div class="grow"><div class="dec-c"><${Linked} text=${d.text} /></div>
            <div class="dec-m faint">${M.agoText(d.at)}${d.card ? " · from a card" : ""}${superseded[d.n] ? html` · <span class="sup">superseded by D${superseded[d.n]}</span>` : null}</div></div></li>`)
            : html`<p class="dt-empty">No decisions yet. Every answered card of this initiative becomes one.</p>`}</ol>
          ${taskDecs.length ? html`<section class="ini-taskdecs"><h3 class="i-h">From its tasks <span class="count">${taskDecs.length}</span></h3>
            ${(ini.stories || []).filter((st) => st.task && taskDecs.some((d) => d.task === st.task)).map((st) => html`<div key=${st.id} class="ini-taskdec">
              <button class="link dec-task" onClick=${() => onOpenTask(home, st.task)}><${Linked} text=${st.title} /></button>
              <${DecisionList} items=${taskDecs.filter((d) => d.task === st.task)} home=${home} cardHref=${cardHref ? (d) => cardHref(home, d) : null} /></div>`)}</section>` : null}`
        : html`<div class="pr-list">${prUrls.length ? html`<${PrBadges} urls=${prUrls} prs=${prs} />` : html`<p class="dt-empty">No PRs yet.</p>`}</div>`}
    </div>
  </main>`;
  const aside = html`<aside class="a-detail slim" aria-label="Properties"><dl class="sp">
    <dt>Status</dt><dd>${STATUS_LABEL[ini.status] || ini.status}</dd>
    <dt>Progress</dt><dd>${p.done} of ${p.total} done</dd>
    <dt>Target</dt><dd>${ini.target || html`<span class="faint">None</span>`}</dd>
    <dt>Milestones</dt><dd><div class="sp-ms">${(ini.milestones || []).length ? M.milestones(ini).filter((g) => g.id).map((g) => html`<div key=${g.id} class=${"sp-m" + (g.current ? " cur" : "")}>
      <span class=${"ms-ic " + (g.finished ? "done" : g.current ? "current" : "later")}></span><span class="grow truncate">${g.name}</span><span class="faint">${g.done}/${g.total}</span></div>`) : html`<span class="faint">None yet</span>`}</div></dd>
    <dt>Home</dt><dd><${HomeTag} name=${home} hue=${hue} /></dd>
    <dt>Open PRs</dt><dd>${prUrls.length ? html`<${PrBadges} urls=${prUrls} prs=${prs} />` : html`<span class="faint">None</span>`}</dd>
    <dt>Created</dt><dd class="faint">${M.agoText(ini.created)}</dd>
  </dl></aside>`;
  return html`<${React.Fragment}>${main}${aside}</${React.Fragment}>`;
}

export function NewInitiative({ homes, home, onSend, onClose }) {
  const [h, setH] = useState(home || (homes[0] && homes[0].name));
  const [name, setName] = useState("");
  const [intent, setIntent] = useState("");
  const [target, setTarget] = useState("");
  const ref = useRef(null);
  useEffect(() => { if (ref.current) ref.current.focus(); }, []);
  const send = () => { if (name.trim() && h) onSend(h, { name: name.trim(), intent: intent.trim() || undefined, target: target || undefined }); };
  return html`<div class="palette-scrim open cmp-scrim" onMouseDown=${(e) => { if (e.target === e.currentTarget) onClose(); }}>
    <div class="palette cmp" role="dialog" aria-label="New initiative" onKeyDown=${(e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); e.stopPropagation(); send(); }
      else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onClose(); } }}>
      <div class="cmp-h"><span class="faint">New initiative in</span>
        <div class="cmp-homes">${homes.map((x) => html`<button key=${x.name} type="button" class=${"ph-chip" + (x.name === h ? " on" : "")} onClick=${() => setH(x.name)}>
          <span class=${"home-dot hue-" + x.hue}></span>${x.name}</button>`)}</div></div>
      <input class="cmp-title" ref=${ref} type="text" placeholder="Name it" value=${name} onInput=${(e) => setName(e.target.value)} maxlength="120" />
      <textarea class="cmp-desc" rows="4" placeholder="Its intent, in a sentence or two: what should be true when it is done, and why." value=${intent} onInput=${(e) => setIntent(e.target.value)}></textarea>
      <div class="cmp-row filters"><label class="filter"><span class="k">Target</span><input class="cmp-sel" type="date" value=${target} onInput=${(e) => setTarget(e.target.value)} /></label></div>
      <div class="cmp-foot"><span class="faint grow">Next: a short round on its goal, criteria, scope and non-goals; then the ${h} XO proposes stories for you to approve.</span>
        <button class="btn ghost sm" onClick=${onClose}>Cancel</button>
        <button class="btn primary sm" disabled=${!name.trim()} onClick=${send}>Create <kbd>⌘↵</kbd></button></div>
    </div>
  </div>`;
}
