// details.js - a task's details, until the ticket (slice 2) replaces it: its status and intent, then
// the brief, the plan, the report and the events, read from the brain's records as they are.
import { html, useState, useEffect, useRef } from "./html.js";
import { HomeTag, Status, Tabs } from "./ui.js";
import { taskFile } from "./api.js";

const M = window.AppModel;
const EF = window.EventFmt;
const MD = window.Markdown;

function Doc({ text }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.textContent = "";
    if (MD) el.append(MD.render(MD.parse(text || ""), { shift: 0 }));
    else el.textContent = text || "";
  }, [text]);
  return html`<div class="dt-doc" ref=${ref}></div>`;
}

function Events({ text }) {
  const lines = String(text || "").split("\n").filter(Boolean).reverse();
  return html`<ul class="dt-events">${lines.map((l, i) => {
    const ev = EF ? EF.parseLine(l) : null;
    if (!ev) return html`<li key=${i}><span class="k"></span><span class="t">${l}</span></li>`;
    const ask = ["decision", "blocked", "failed"].includes(ev.kind);
    return html`<li key=${i} class=${ask ? "ask" : ""}><span class="k">${ev.kind || ""} · ${M.ago(ev.at)}</span><span class="t">${ev.text}</span></li>`;
  })}</ul>`;
}

export function DetailsPage({ home, hue, id, task, tab, setTab, onBack }) {
  const [files, setFiles] = useState({});
  const [err, setErr] = useState(null);
  useEffect(() => {
    let live = true;
    setErr(null);
    Promise.all(["brief.md", "plan.md", "report.md", "events.log"].map((n) => taskFile(home, id, n).then((t) => [n, t])))
      .then((pairs) => { if (live) setFiles(Object.fromEntries(pairs)); })
      .catch((e) => { if (live) setErr(e.message); });
    return () => { live = false; };
  }, [home, id, task && task.last_at]);
  const tabs = [
    { id: "brief", label: "Brief", file: "brief.md" }, { id: "plan", label: "Plan", file: "plan.md" },
    { id: "report", label: "Report", file: "report.md" }, { id: "events", label: "Events", file: "events.log" },
  ].filter((t) => files[t.file] != null || t.id === "brief");
  const cur = tabs.find((t) => t.id === tab) || tabs[0];
  return html`<main class="a-main">
    <header class="a-head">
      <div class="a-head-l"><button class="link faint" onClick=${onBack}>Needs me</button><span class="faint">/</span>
        <span class="faint">${home}</span><span class="faint">/</span><h1 class="truncate">${task ? task.short_id : id}</h1></div>
    </header>
    <div class="page-body dt">
      <div class="dt-head">${task ? html`<${Status} status=${task.status} />` : null}<${HomeTag} name=${home} hue=${hue} />
        ${task && task.project ? html`<span class="faint">${task.project}</span>` : null}
        ${task && task.warning ? html`<span class="warn-t">${task.warning}</span>` : null}</div>
      <h1 class="dt-title">${task ? task.title : id}</h1>
      <p class="dt-sub">${task && task.last_event ? "Last: " + (task.last_event.length > 220 ? task.last_event.slice(0, 219) + "…" : task.last_event) : ""}</p>
      ${err ? html`<p class="err-t">${err}</p>` : null}
      <${Tabs} tabs=${tabs} active=${cur.id} onPick=${setTab} />
      ${files[cur.file] == null ? html`<p class="dt-empty">${Object.keys(files).length ? "Nothing here yet." : "Reading…"}</p>`
        : cur.id === "events" ? html`<${Events} text=${files[cur.file]} />` : html`<${Doc} text=${files[cur.file]} />`}
    </div>
  </main>`;
}
