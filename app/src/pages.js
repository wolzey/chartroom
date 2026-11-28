// pages.js - what a worker leaves for the commander besides its report: drafts (a message to send, a
// runbook to run: their text, with Copy) and pages (a report as HTML, to read and print). A page is
// HTML a worker wrote, so it is untrusted: the server sends it sandboxed (no scripts, an opaque
// origin, nothing fetched; lib/app/server.py PAGE_CSP) and the viewer frames it with the sandbox
// attribute too, so its links open in a new tab and nothing in it can reach the app. Its PDF is
// printed on request by `chartroom artifact pdf`.
import { html, useState, useEffect } from "./html.js";

const enc = encodeURIComponent;
// the file of artifact <a> (an item of a snapshot's or a ticket's `artifacts`) in <home>
export function artifactUrl(home, a, ext) {
  return "/api/v1/homes/" + enc(home) + "/artifacts/" + enc(a.owner_type) + "/" + enc(a.owner) + "/" + enc(a.slug) + "." + ext;
}
export function pageHash(home, a) { return "#/p/" + enc(home) + "/" + enc(a.owner_type) + "/" + enc(a.owner) + "/" + enc(a.slug); }

function copy(text, toast, what) {
  if (navigator.clipboard) navigator.clipboard.writeText(text).then(() => toast && toast("Copied " + what), () => toast && toast("Could not copy: select the text instead"));
  else if (toast) toast("Could not copy: select the text instead");
}

// A draft's text, read when shown, with Copy.
export function DraftText({ home, a, toast }) {
  const [text, setText] = useState(null), [err, setErr] = useState(null);
  useEffect(() => {
    let live = true;
    setText(null); setErr(null);
    fetch(artifactUrl(home, a, "md"), { credentials: "same-origin" })
      .then((r) => (r.ok ? r.text() : Promise.reject(new Error(r.status === 404 ? "This draft is gone" : "Could not read it (" + r.status + ")"))))
      .then((t) => live && setText(t), (e) => live && setErr(e.message));
    return () => { live = false; };
  }, [home, a.owner_type, a.owner, a.slug, a.updated]);
  if (err) return html`<p class="err-t">${err}</p>`;
  if (text == null) return html`<p class="faint">Reading the ${a.kind || "draft"}…</p>`;
  return html`<div class="draft">
    <div class="row-flex"><span class="faint">${a.kind === "runbook" ? "Steps to run" : a.kind === "message" ? "A message to send" : "A draft"}</span><span class="grow"></span>
      <button class="btn sm" onClick=${() => copy(text, toast, "the " + (a.kind || "draft"))}>Copy</button></div>
    <pre class="draft-t">${text}</pre></div>`;
}

// A task's or an inbox item's artifacts: a page opens in the viewer; a draft unfolds with its text.
export function ArtifactList({ home, items, toast }) {
  const [open, setOpen] = useState(null);
  if (!items || !items.length) return null;
  return html`<ul class="art-list">${items.map((a) => {
    const key = a.owner + "/" + a.slug;
    return html`<li key=${key} class=${"art-i" + (a.done ? " art-done" : "")}>
      <div class="row-flex wrap">
        <span class=${"art-k art-" + (a.kind || "note")}>${a.kind === "page" ? "Page" : a.kind === "runbook" ? "Runbook" : a.kind === "message" ? "Message" : "Note"}</span>
        ${a.kind === "page"
          ? html`<a class="art-t" href=${pageHash(home, a)}>${a.title}</a>`
          : html`<button class="link art-t" aria-expanded=${open === key} onClick=${() => setOpen(open === key ? null : key)}>${a.title}</button>`}
        <span class="faint">${a.done ? "done" : ""}</span>
      </div>
      ${a.description ? html`<p class="faint art-d">${a.description}</p>` : null}
      ${open === key ? html`<${DraftText} home=${home} a=${a} toast=${toast} />` : null}
    </li>`;
  })}</ul>`;
}

// #/p/<home>/<task|inbox>/<owner>/<slug>: one page, framed, with its PDF and a way back.
export function PageViewer({ home, a, back, toast }) {
  const src = artifactUrl(home, a, "html");
  return html`<main class="a-main page-view">
    <header class="a-head"><div class="a-head-l">${back ? html`<a class="link faint" href=${back.href}>${back.label}</a><span class="faint">/</span>` : null}
      <h1 class="truncate">${a.title || a.slug}</h1></div>
      <div class="row-flex"><a class="btn ghost sm" href=${src} target="_blank" rel="noopener noreferrer">Open alone</a>
        <a class="btn sm" href=${artifactUrl(home, a, "pdf")} download=${a.slug + ".pdf"}
          onClick=${() => toast && toast("Printing the PDF; it downloads in a few seconds")}>Download PDF</a></div></header>
    <iframe class="page-frame" title=${a.title || a.slug} src=${src} sandbox="allow-popups allow-popups-to-escape-sandbox" referrerpolicy="no-referrer"></iframe>
  </main>`;
}
