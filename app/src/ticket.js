// ticket.js - a task as a Linear-style ticket (slice 2): its status line (or its open question,
// answered in place), pull requests, the description (the brief's intent and spec, edited in place
// and steered to the worker), the plan and report, attachments, and the activity with a composer
// at the bottom (a comment steers the worker; "@xo" asks the XO). Properties sit in the slim column.
// Every change goes through the outbox like any other action; uploads go straight to the server,
// which queues them.
import { html, useState, useEffect, useRef } from "./html.js";
import { HomeTag, Status, Linked, linkifyDom, PrCard, PrBadges, Menu, DecisionList } from "./ui.js";
import { AskBody } from "./needs.js";
import { taskFile } from "./api.js";

const M = window.AppModel;
const EF = window.EventFmt;
const MD = window.Markdown;
const ATTACH_MAX = 25 * 1024 * 1024;
const WRITE = { "X-Chartroom-App": "1" };

function Doc({ text, cls }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.textContent = "";
    if (MD) el.append(MD.render(MD.parse(text || ""), { shift: 1 })); else el.textContent = text || "";
    linkifyDom(el);
    for (const a of el.querySelectorAll("a[href^='http']")) { a.target = "_blank"; a.rel = "noopener noreferrer"; }
  }, [text]);
  return html`<div class=${"dt-doc " + (cls || "")} ref=${ref}></div>`;
}

const SIZE = (n) => (n > 1048576 ? (n / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1024)) + " KB");
function attKind(type) {
  if (/^image\//.test(type)) return "image";
  if (/^video\//.test(type)) return "video";
  if (type === "application/pdf") return "pdf";
  if (/csv|json/.test(type)) return "data";
  if (/^text\//.test(type)) return "text";
  return "file";
}

function Attachment({ a, base }) {
  const kind = attKind(a.type);
  const href = base + "/attachments/" + encodeURIComponent(a.id);
  const vis = kind === "image" ? html`<img class="thumb-img" alt="" loading="lazy" src=${href} />`
    : kind === "video" ? html`<span class="file-ic f-video">Video</span><span class="play" aria-hidden="true"></span>`
    : html`<span class=${"file-ic f-" + kind}>${{ pdf: "PDF", data: "Data", text: "Text" }[kind] || "File"}</span>`;
  return html`<a class="att-t" href=${href} target="_blank" rel="noopener noreferrer" title=${a.name}>
    <span class="att-v">${vis}</span>
    <span class="att-n truncate">${a.caption || a.name}</span>
    <span class="att-m faint truncate">${SIZE(a.size)} · ${a.by === "commander" ? "you" : a.by === "worker" ? html`<b class="by-w">worker</b>` : "XO"} · ${M.agoText(a.at)}</span>
  </a>`;
}

// The activity: worker events, the commander's comments (steers that start "The commander: ")
// and what was told to the XO about this task, oldest first, and the comments sent from here that
// have not come back yet.
function feedOf(t, pending) {
  const out = [];
  for (const line of t.events || []) {
    const ev = EF ? EF.parseLine(line) : null;
    if (!ev) continue;
    if (ev.kind === "steered" && !/^The commander (attached|edited)/.test(ev.text)) {
      // a comment: the commander's ("The commander: ...") or the XO's own steer
      const mine = /^The commander: ([\s\S]*)$/.exec(ev.text);
      out.push({ type: "comment", at: ev.at, who: mine ? "you" : "xo", to: "worker", text: mine ? mine[1] : ev.text });
    } else {
      // chartroom's own steers (an attachment, a brief edit) and every other event: a line, its headline
      const text = M.askText(ev.text);
      out.push({ type: "event", at: ev.at, kind: ev.kind || "note", text: ev.kind === "steered" ? M.headline(text) : text });
    }
  }
  for (const m of t.tells || []) out.push({ type: "comment", at: m.at, who: "you", to: "xo", text: m.text, read: m.acked });
  for (const p of pending) if (!out.some((o) => o.type === "comment" && o.text.trim() === p.text.trim())) out.push(Object.assign({ pending: true }, p));
  return out.sort((a, b) => String(a.at).localeCompare(String(b.at)));
}

export function TicketPage({ home, hue, id, version, prs, item, machine, askProps, onAct, onBack, toast, cardHref }) {
  const [t, setT] = useState(null);
  const [err, setErr] = useState(null);
  const [report, setReport] = useState(null);
  const [editing, setEditing] = useState(null); // {heading: text} while the description is edited
  const [comment, setComment] = useState("");
  const [pending, setPending] = useState([]);
  const [uploads, setUploads] = useState([]);
  const [steerNew, setSteerNew] = useState(true);
  const [menu, setMenu] = useState(null);
  const [confirmClose, setConfirmClose] = useState(false);
  const [overrides, setOverrides] = useState({});
  const [more, setMore] = useState(false);
  const fileInput = useRef(null);
  const base = "/api/v1/homes/" + encodeURIComponent(home) + "/tasks/" + encodeURIComponent(id);

  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => {
      fetch(base, { cache: "no-store", credentials: "same-origin" })
        .then((r) => (r.ok ? r.json() : r.json().then((j) => Promise.reject(new Error(j.error || r.status)))))
        .then((j) => { if (live) { setT(j); setErr(null); } })
        .catch((e) => { if (live) setErr(e.message); });
    }, t ? 250 : 0);
    return () => { live = false; clearTimeout(timer); };
  }, [home, id, version]);
  useEffect(() => {
    if (!t || !(t.files || []).includes("report.md")) { setReport(null); return; }
    taskFile(home, id, "report.md").then(setReport).catch(() => setReport(null));
  }, [home, id, t && t.last_at]);
  // An upload is done once the ticket lists a file of its name from after it started.
  useEffect(() => {
    if (!t) return;
    setUploads((u) => u.filter((x) => x.state === "failed" || !(t.attachments || []).some((a) => a.name === x.name && Date.parse(a.at) >= x.started - 2000)));
  }, [t]);
  // Paste a screenshot anywhere on the ticket.
  useEffect(() => {
    const onPaste = (e) => {
      if (e.target && (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT")) return;
      const files = [...((e.clipboardData && e.clipboardData.files) || [])];
      if (files.length) { e.preventDefault(); attach(files, "paste"); }
    };
    window.addEventListener("paste", onPaste);
    return () => window.removeEventListener("paste", onPaste);
  });

  if (!t) {
    return html`<main class="a-main"><header class="a-head"><div class="a-head-l"><button class="link faint" onClick=${onBack}>Needs me</button>
      <span class="faint">/</span><span class="faint">${home}</span><span class="faint">/</span><h1>${id}</h1></div></header>
      <div class="page-body"><p class=${err ? "err-t" : "dt-empty"}>${err || "Reading the ticket…"}</p></div></main>`;
  }
  const o = Object.assign({}, t, overrides);
  const worker = (o.backend || "worker").replace(/^[a-z]+:/, "");
  const prUrls = (o.links || []).filter((l) => l.kind === "pr").map((l) => l.url);
  const others = (o.links || []).filter((l) => l.kind !== "pr");
  // the description is the intent and the spec; an empty one (a template's comment) is left out
  const sections = ["Commander's intent", "Spec"].filter((h) => o.sections && (o.sections[h] || "").trim());
  const editable = ["Commander's intent", "Spec"].filter((h) => o.sections && o.sections[h] != null);
  const feed = feedOf(o, pending);

  function attach(files, how) {
    for (const f of files) {
      const name = f.name && f.name !== "image.png" ? f.name : "screenshot-" + new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19) + ".png";
      if (f.size > ATTACH_MAX) { toast(name + " is over 25 MB: put it somewhere and link it instead"); continue; }
      const up = { key: Math.random().toString(36).slice(2), name, size: f.size, state: "uploading", started: Date.now(), file: f, how };
      setUploads((u) => u.concat([up]));
      send(up);
    }
  }
  function send(up) {
    const aid = "a-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
    fetch(base + "/attachments", {
      method: "POST", credentials: "same-origin", body: up.file,
      headers: Object.assign({ "X-Chartroom-Action": aid, "X-Filename": encodeURIComponent(up.name), "Content-Type": up.file.type || "application/octet-stream",
        "X-Caption": encodeURIComponent(up.how === "paste" ? "Pasted screenshot" : "") }, steerNew ? {} : { "X-Silent": "1" }, WRITE),
    }).then(async (r) => {
      if (r.status === 202) { setUploads((u) => u.map((x) => (x.key === up.key ? Object.assign({}, x, { state: "attaching" }) : x))); return; }
      let j = {}; try { j = await r.json(); } catch (e) { j = {}; }
      setUploads((u) => u.map((x) => (x.key === up.key ? Object.assign({}, x, { state: "failed", error: j.error || "refused (" + r.status + ")" }) : x)));
    }).catch(() => setUploads((u) => u.map((x) => (x.key === up.key ? Object.assign({}, x, { state: "failed", error: "the server could not be reached" }) : x))));
  }
  const sendComment = () => {
    const text = comment.trim();
    if (!text) return;
    const toXo = /^\s*@xo\b/i.test(text);
    onAct("comment", { task: id, text }, toXo ? "Comment to the XO" : "Comment to the worker");
    setPending((p) => p.concat([{ type: "comment", at: new Date().toISOString(), who: "you", to: toXo ? "xo" : "worker", text: toXo ? text.replace(/^\s*@xo\b[:,]?\s*/i, "") : text }]));
    setComment("");
    toast(toXo ? (askProps && askProps.undelivered ? "Kept for the " + home + " XO · it reaches the XO once the app is installed" : "Sent to the " + home + " XO") : "Sent to the worker, as a steer");
  };
  const saveDesc = () => {
    const changed = {};
    for (const h of Object.keys(editing)) if ((editing[h] || "").trim() !== (o.sections[h] || "").trim()) changed[h] = editing[h].trim();
    setEditing(null);
    if (!Object.keys(changed).length) return;
    onAct("brief", { task: id, sections: changed }, "Description saved");
    setOverrides((x) => Object.assign({}, x, { sections: Object.assign({}, o.sections, changed) }));
    toast("Saved; the worker gets the change as a steer");
  };
  const setProp = (body, label, local) => { onAct("set", Object.assign({ task: id }, body), label); setOverrides((x) => Object.assign({}, x, local)); };

  // the banner: the open question, answered here, or what the task is doing
  let banner;
  if (item && !item.sent) {
    banner = html`<section class="card needs-card"><div class="card-h"><${Status} status=${item.kind === "review" ? "review" : "needs"} /><span class="faint">${M.agoText(item.at)}</span></div>
      <${AskBody} ...${askProps} it=${item} hidePrs=${true} /></section>`;
  } else if (item && item.sent) {
    banner = html`<${AskBody} ...${askProps} it=${item} />`;
  } else if (o.status === "working") {
    banner = html`<div class="q-line q-working big"><span class="pulse"></span><span class="grow"><${Linked} text=${M.headline((o.last_event || "").replace(/^[a-z-]+: /, "")) || "Working"} /></span>
      <span class="faint">${machine || ""}${o.dispatched ? " · " + M.ago(o.dispatched) : ""}</span></div>`;
  } else {
    const line = { drafting: "Being briefed", queued: "Waiting for a slot", waiting: o.waiting_on ? "Waiting on " + o.waiting_on + (o.waiting_until ? " until " + o.waiting_until : "") : "Waiting",
      needs: "Waiting on you", review: "The worker reported done. Accept it, or close it", done: "Accepted", closed: "Closed" }[o.status] || o.status;
    banner = html`<div class=${"q-line q-" + o.status + " big"}><${Status} status=${o.status} only=${true} /><span class="grow">${line}</span>
      ${o.status === "review" ? html`<button class="btn primary sm" onClick=${() => onAct("accept", { task: id }, "Accepted " + o.short_id)}>Accept</button>` : null}</div>`;
  }

  const main = html`<main class="a-main">
    <header class="a-head">
      <div class="a-head-l"><button class="link faint" onClick=${onBack}>Needs me</button><span class="faint">/</span>
        <${HomeTag} name=${home} hue=${hue} /><span class="faint">/</span><span class="faint">${o.short_id}</span></div>
      <div class="row-flex"><button class="btn ghost sm" title="Copy the command that opens the worker's terminal"
        onClick=${() => { navigator.clipboard && navigator.clipboard.writeText("chartroom attach " + o.short_id); toast("Copied: chartroom attach " + o.short_id); }}>Copy attach</button></div>
    </header>
    <div class="page-body task-body">
      <div class="task-title"><${Status} status=${o.status} only=${true} /><h1><${Linked} text=${o.title} /></h1></div>
      ${o.warning ? html`<p class="warn-t">${o.warning}</p>` : null}
      <div class="ticket-banner">${banner}</div>

      ${prUrls.length ? html`<section class="t-sec t-prs"><div class="sec-h"><h2 class="i-h">Pull requests <span class="count">${prUrls.length}</span></h2></div>
        <div class="pr-list">${prUrls.map((u) => html`<${PrCard} key=${u} url=${u} pr=${prs[u]} />`)}</div></section>` : null}

      ${(o.decisions || []).length ? html`<section class="t-sec t-decs"><div class="sec-h"><h2 class="i-h">Decisions <span class="count">${o.decisions.length}</span></h2></div>
        <p class="faint dec-lede">What you answered for this task, newest first.</p>
        <${DecisionList} items=${o.decisions} home=${home} cardHref=${cardHref ? (d) => cardHref(home, d) : null} /></section>` : null}

      <section class="t-sec"><div class="sec-h"><h2 class="i-h">Description</h2><span class="grow"></span>
        ${editing
          ? html`<span class="faint">Saving updates the brief and steers the ${worker} worker.</span>
              <button class="btn ghost sm" onClick=${() => setEditing(null)}>Cancel</button><button class="btn primary sm" onClick=${saveDesc}>Save and steer</button>`
          : editable.length ? html`<button class="btn ghost sm" onClick=${() => setEditing(Object.fromEntries(editable.map((h) => [h, o.sections[h] || ""])))}>Edit</button>` : null}</div>
        ${editing
          ? html`<div class="desc editing">${editable.map((h) => html`<label key=${h} class="desc-f"><span class="d-h">${h}</span>
              <textarea class="input" rows=${Math.min(14, Math.max(3, (editing[h] || "").split("\n").length + 1))} value=${editing[h]}
                onInput=${(e) => setEditing(Object.assign({}, editing, { [h]: e.target.value }))}></textarea></label>`)}</div>`
          : html`<div class="desc">${sections.map((h) => html`<div key=${h} class="desc-s">${h !== "Commander's intent" ? html`<div class="d-h">${h}</div>` : null}<${Doc} text=${o.sections[h]} /></div>`)}
              ${!sections.length ? html`<p class="dt-empty">No description in the brief.</p>` : null}
              <button class="link desc-more" onClick=${() => setMore(!more)}>${more ? "Hide the rest of the brief" : "The whole brief"}</button>
              ${more ? Object.keys(o.sections).filter((h) => !sections.includes(h)).map((h) => html`<div key=${h} class="desc-s"><div class="d-h">${h}</div><${Doc} text=${o.sections[h]} /></div>`) : null}</div>`}
      </section>

      ${o.plan ? html`<section class="t-sec"><div class="sec-h"><h2 class="i-h">Plan</h2></div><${Doc} text=${o.plan} /></section>` : null}
      ${report ? html`<section class="t-sec"><div class="sec-h"><h2 class="i-h">Report</h2></div><${Doc} text=${report.replace(/^\s*#\s+Report\s*\n/i, "")} /></section>` : null}

      <section class="t-sec"
          onDragOver=${(e) => { e.preventDefault(); }} onDrop=${(e) => { e.preventDefault(); attach([...(e.dataTransfer.files || [])], "drop"); }}>
        <div class="sec-h"><h2 class="i-h">Attachments <span class="count">${(o.attachments || []).length + others.length}</span></h2><span class="grow"></span>
          <label class="tog"><input type="checkbox" checked=${steerNew} onChange=${(e) => setSteerNew(e.target.checked)} /> Send new ones to the worker as a steer</label>
          <button class="btn sm" onClick=${() => fileInput.current && fileInput.current.click()}>Attach</button>
          <input type="file" multiple hidden ref=${fileInput} onChange=${(e) => { attach([...e.target.files], "browse"); e.target.value = ""; }} /></div>
        <div class="att-grid">
          ${(o.attachments || []).slice().reverse().map((a) => html`<${Attachment} key=${a.id} a=${a} base=${base} />`)}
          ${uploads.map((u) => html`<div key=${u.key} class=${"att-t" + (u.state === "failed" ? " att-failed" : "")}>
            <span class="att-v"><span class="file-ic">${u.state === "failed" ? "Failed" : "…"}</span></span>
            <span class="att-n truncate">${u.name}</span>
            <span class="att-m faint truncate">${u.state === "failed" ? u.error : u.state === "uploading" ? "uploading " + SIZE(u.size) : "attaching"}</span>
            ${u.state === "failed" ? html`<span class="row-flex"><button class="btn sm" onClick=${() => { setUploads((x) => x.map((y) => (y.key === u.key ? Object.assign({}, y, { state: "uploading", error: null, started: Date.now() }) : y))); send(u); }}>Retry</button>
              <button class="btn ghost sm" onClick=${() => setUploads((x) => x.filter((y) => y.key !== u.key))}>Remove</button></span>` : null}
          </div>`)}
          ${others.map((l) => html`<a key=${l.url} class="att-t" href=${l.url} target="_blank" rel="noopener noreferrer"><span class="att-v"><span class="file-ic">Link</span></span>
            <span class="att-n truncate">${l.title || l.url}</span><span class="att-m faint truncate">${l.url}</span></a>`)}
        </div>
        <div class="drop">Drop files here or paste a screenshot: images, screen recordings, PDFs, logs, CSV or JSON, up to 25 MB each. Bigger files go as a link.</div>
        <p class="faint att-note">Kept in the task's folder on the brain, and shared only if you share them.</p>
      </section>

      <hr class="dt-rule" />
      <section class="t-sec"><h2 class="i-h">Activity</h2>
        <ol class="feed">${feed.map((f, i) => f.type === "event"
          ? html`<li key=${i} class=${"ev k-" + f.kind}><span class="tl-dot"></span><span class="grow"><span class="faint">${f.kind}</span> <${Linked} text=${f.text} /></span><span class="faint">${M.agoText(f.at)}</span></li>`
          : html`<li key=${i} class=${"cm" + (f.pending ? " pending" : "")}><div class="cmt"><div class="grow"><div class="row-flex wrap"><b>${f.who === "you" ? "You" : "The XO"}</b>
              <span class=${"route" + (f.to === "xo" ? " r-xo" : "")}>${f.to === "xo" ? "to the XO" : "steer to the worker"}</span>
              <span class="faint">${f.pending ? "sending…" : M.agoText(f.at)}</span></div><p><${Linked} text=${f.text} /></p></div></div></li>`)}</ol>
        <div class="composer">
          <textarea class="input" rows="3" value=${comment} onInput=${(e) => setComment(e.target.value)}
            onKeyDown=${(e) => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); e.stopPropagation(); sendComment(); } }}
            placeholder=${"Leave a comment. It reaches the worker as a steer. Start with @xo to ask the " + home + " XO instead."}></textarea>
          <div class="row-flex"><span class="route-live faint">${/^\s*@xo\b/i.test(comment) ? "→ the " + home + " XO" : "→ the worker, as a steer"}</span><span class="grow"></span>
            <button class="btn primary sm" disabled=${!comment.trim()} onClick=${sendComment}>Comment <kbd>⌘↵</kbd></button></div>
        </div>
      </section>
    </div>
  </main>`;

  const prio = o.priority || "none";
  const props = [
    ["Status", html`<button class="st-btn" onClick=${(e) => setMenu({ what: "status", anchor: e.currentTarget })}><${Status} status=${o.status} /> <span class="caret"></span></button>`],
    ["Priority", html`<button class="link" onClick=${(e) => setMenu({ what: "priority", anchor: e.currentTarget })}>${prio === "none" ? "No priority" : prio[0].toUpperCase() + prio.slice(1)}</button>`],
    ["Labels", html`<span>${(o.labels || []).map((l) => html`<span key=${l} class="label">${l}</span>`)}
      <button class="link" onClick=${() => setMenu({ what: "labels" })}>${(o.labels || []).length ? "Edit" : "Add"}</button></span>`],
    ["Initiative", o.initiative || html`<span class="faint">None</span>`],
    ["Project", o.project || "—"],
    ["Home", html`<${HomeTag} name=${home} hue=${hue} />`],
    ["Machine", html`${machine || "this brain"} <span class="faint">attempt ${o.attempt || 1}</span>`],
    ["Worker", html`${worker} <span class="faint">${o.live || ""}</span>`],
    ["Time", o.dispatched ? "Dispatched " + M.agoText(o.dispatched) : html`<span class="faint">Not dispatched</span>`],
    ["PRs", prUrls.length ? html`<${PrBadges} urls=${prUrls} prs=${prs} />` : html`<span class="faint">None yet</span>`],
    ["Branch", html`<span class="faint">${o.branch || "—"}</span>`],
    ["Created", html`<span class="faint">${M.agoText(o.created)}</span>`],
  ];
  const statusItems = ["drafting", "queued", "working", "waiting", "needs", "review", "done", "closed"].map((s) => ({
    id: s, label: M.STATUS[s] + (s === "done" && o.status === "review" ? " (accept)" : s === "closed" && o.status !== "closed" ? " (close)" : s === o.status ? "" : ""),
    sub: (s === "done" && o.status === "review") || (s === "closed" && o.status !== "closed") ? "" : s === o.status ? "now" : "set by the work"
  }));
  const aside = html`<aside class="a-detail slim task-props" aria-label="Properties">
    <dl class="sp">${props.map(([k, v]) => html`<${React.Fragment} key=${k}><dt>${k}</dt><dd>${v}</dd></${React.Fragment}>`)}</dl>
    ${menu && menu.what === "labels" ? html`<form class="labels-f" onSubmit=${(e) => { e.preventDefault(); const v = e.target.elements.l.value.split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
        setProp({ labels: v }, "Labels set", { labels: v }); setMenu(null); }}>
        <input class="input" name="l" defaultValue=${(o.labels || []).join(", ")} placeholder="storefront, bug" autoFocus />
        <div class="row-flex"><button class="btn primary sm" type="submit">Save</button><button class="btn ghost sm" type="button" onClick=${() => setMenu(null)}>Cancel</button></div></form>` : null}
    <div class="a-detail-actions t-actions">
      ${o.status !== "closed" ? (confirmClose
        ? html`<button class="btn qv-confirm" onClick=${() => { setConfirmClose(false); onAct("close", { task: id }, "Closed " + o.short_id); }}>Close it: work is never discarded</button>`
        : html`<button class="btn ghost" onClick=${() => setConfirmClose(true)}>Close task</button>`) : null}
    </div>
  </aside>`;

  return html`<${React.Fragment}>${main}${aside}
    ${menu && menu.what === "priority" ? html`<${Menu} anchor=${menu.anchor} title="Priority" picked=${prio}
        items=${["urgent", "high", "medium", "low", "none"].map((p) => ({ id: p, label: p === "none" ? "No priority" : p[0].toUpperCase() + p.slice(1) }))}
        onPick=${(x) => setProp({ priority: x.id }, "Priority set", { priority: x.id === "none" ? null : x.id })} onClose=${() => setMenu(null)} />` : null}
    ${menu && menu.what === "status" ? html`<${Menu} anchor=${menu.anchor} title="Status" picked=${o.status} items=${statusItems}
        onPick=${(x) => {
          if (x.id === "done" && o.status === "review") onAct("accept", { task: id }, "Accepted " + o.short_id);
          else if (x.id === "closed" && o.status !== "closed") setConfirmClose(true);
          else if (x.id !== o.status) toast(M.STATUS[x.id] + " is set by the work itself, not by hand");
        }} onClose=${() => setMenu(null)} />` : null}
  </${React.Fragment}>`;
}
