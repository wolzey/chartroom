// round.js - a card of several questions (a grilling round): every question with its options and a
// note, answered together and submitted once. The first answer wins: if the terminal answered it
// first, the page says so and shows that answer.
import { html, useEffect } from "./html.js";
import { Pill, HomeTag, Options, Why } from "./ui.js";

const M = window.AppModel;

export function RoundPage({ it, picks, notes, setPick, setNote, focus, setFocus, busy, onSubmit, onBack }) {
  useEffect(() => { window.scrollTo(0, 0); }, [it && it.key]);
  if (!it) {
    return html`<main class="a-main"><header class="a-head r-head"><div class="a-head-l">
        <button class="link faint" onClick=${onBack}>Needs me</button><span class="faint">/</span><h1>Not found</h1></div></header>
      <div class="page-body"><p class="muted">This card is gone: it was answered, withdrawn, or its home is not on this brain.</p></div></main>`;
  }
  const qs = M.questions(it);
  const n = M.answered(it, picks, notes), total = qs.length;
  const left = qs.filter((q) => !(picks[q.id] != null || (notes[q.id] || "").trim()));
  const recsLeft = left.filter((q) => q.options.some((o) => o.rec));
  const sent = it.sent;
  return html`<main class="a-main">
    <header class="a-head r-head">
      <div class="a-head-l"><button class="link faint" onClick=${onBack}>Needs me</button><span class="faint">/</span>
        <span class="faint">${it.home}</span><span class="faint">/</span><h1>${it.title}</h1></div>
      <div class="row-flex"><${Pill} kind="round" text=${it.round && it.round.n ? "Round " + it.round.n + (it.round.of ? " of about " + it.round.of : "") : total + " questions"} /></div>
    </header>
    <div class="r-a">
      <aside class="r-tree">
        <div class="r-tree-h">This round</div>
        <ul class="tree">${qs.map((q, i) => {
          const done = picks[q.id] != null || (notes[q.id] || "").trim();
          return html`<li key=${q.id} class=${"current" + (done ? " answered" : "")}>
            <button class="node" onClick=${() => { setFocus(i); const el = document.getElementById("q" + q.id); if (el) el.scrollIntoView({ behavior: "smooth", block: "center" }); }}>
              <span class="ic"></span><span class="grow">${q.text.length > 60 ? q.text.slice(0, 59) + "…" : q.text}${done && picks[q.id] ? html`<span class="ans">${picks[q.id]}</span>` : null}</span></button></li>`;
        })}</ul>
        <div class="r-meta">
          <${HomeTag} name=${it.home} hue=${it.hue} />
          <span class="faint">asked ${M.agoText(it.at)}</span>
          ${it.context ? html`<span class="muted">${it.context}</span>` : null}
        </div>
      </aside>
      <div class="r-qs">
        ${sent
          ? html`<div class="card r-sent"><div class="empty"><div class="mark">✓</div>
              <h3>${sent.withdrawn ? "Withdrawn" : "Round sent"}</h3>
              <p>${sent.withdrawn ? "The XO no longer needs these answers." : sent.read_by_xo ? "The XO has read your answers." : "The " + it.home + " XO has your answers; it reads them in its next round."}</p>
              <div class="row-flex"><button class="btn primary" onClick=${onBack}>Back to Needs me</button></div></div></div>`
          : qs.map((q, i) => html`<article key=${q.id} id=${"q" + q.id} class=${"card qcard" + ((picks[q.id] != null || (notes[q.id] || "").trim()) ? " answered" : "") + (focus === i ? " focus" : "")}
                onClick=${() => setFocus(i)}>
              <div class="card-h"><span class="qn">${i + 1}</span><h3 class="qtitle grow">${q.text}</h3></div>
              ${q.context ? html`<p class="qctx">${q.context}</p>` : null}
              ${q.options.length ? html`<${Options} options=${q.options} picked=${picks[q.id]} onPick=${(l) => setPick(q.id, l)} />` : null}
              <${Why} text=${q.why} />
              <textarea class="input note" rows="1" placeholder=${q.options.length ? "Other answer or a note" : "Your answer"}
                value=${notes[q.id] || ""} onInput=${(e) => setNote(q.id, e.target.value)} disabled=${busy}></textarea>
            </article>`)}
        ${sent ? null : html`<p class="r-keys faint"><span><kbd>j</kbd><kbd>k</kbd> next question</span><span><kbd>1</kbd><kbd>2</kbd><kbd>3</kbd> choose</span><span><kbd>r</kbd> take the recommendation</span><span><kbd>⌘↵</kbd> submit</span></p>`}
      </div>
    </div>
    ${sent ? null : html`<div class="r-bar"><div class="r-bar-in">
      <div class="r-bar-prog"><span class="r-bar-n"><b>${n}</b> of ${total} answered</span><div class="bar"><i style=${{ width: Math.round(100 * n / total) + "%" }}></i></div></div>
      <span class="grow"></span>
      ${recsLeft.length ? html`<button class="btn ghost" disabled=${busy} onClick=${() => recsLeft.forEach((q) => setPick(q.id, q.options.find((o) => o.rec).label))}>
        Accept recommended for ${recsLeft.length} left</button>` : null}
      <button class="btn primary" disabled=${busy || n < total} onClick=${onSubmit}>Submit round <kbd>⌘↵</kbd></button>
    </div></div>`}
  </main>`;
}
