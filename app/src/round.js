// round.js - a card of several questions (a grilling round): every question with its options and a
// note, answered together and submitted once. The first answer wins: if the terminal answered it
// first, the page says so and shows that answer.
import { html, useEffect } from "./html.js";
import { Pill, HomeTag, Options, Why, Linked } from "./ui.js";

const M = window.AppModel;

export function RoundPage({ it, picks, notes, setPick, setNote, focus, setFocus, busy, onSubmit, onBack, owner }) {
  useEffect(() => { window.scrollTo(0, 0); }, [it && it.key]);
  // on the phone, the progress row follows the question being read as the page scrolls
  useEffect(() => {
    if (!it || it.sent || typeof IntersectionObserver === "undefined" || !window.matchMedia("(max-width: 860px)").matches) return;
    const cards = [...document.querySelectorAll(".r-qs .qcard")];
    const io = new IntersectionObserver((es) => {
      const vis = es.filter((e) => e.isIntersecting).map((e) => cards.indexOf(e.target)).filter((i) => i >= 0);
      if (vis.length) setFocus(Math.min(...vis));
    }, { rootMargin: "-120px 0px -55% 0px" });
    cards.forEach((c) => io.observe(c));
    return () => io.disconnect();
  }, [it && it.key, it && it.sent]);
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
  const cur = Math.max(0, Math.min(total - 1, focus || 0));
  // a question to the top of the screen, under the sticky rows (the phone's progress row)
  const goTo = (i) => {
    const k = Math.max(0, Math.min(total - 1, i));
    setFocus(k);
    const el = document.getElementById("q" + qs[k].id);
    if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  const isDone = (q) => picks[q.id] != null || (notes[q.id] || "").trim();
  return html`<main class="a-main r-page">
    <header class="a-head r-head">
      <div class="a-head-l"><button class="link faint r-back" onClick=${onBack}>Needs me</button><span class="faint">/</span>
        <span class="faint r-home">${it.home}</span><span class="faint r-home">/</span><h1 class="truncate"><${Linked} text=${it.title} /></h1></div>
      <div class="row-flex r-pill"><${Pill} kind="round" text=${it.round && it.round.n ? "Round " + it.round.n + (it.round.of ? " of about " + it.round.of : "") : total + " questions"} /></div>
    </header>
    ${sent ? null : html`<nav class="r-steps" aria-label="Questions">
      <button class="btn ghost icon r-step-btn" aria-label="Previous question" disabled=${cur === 0} onClick=${() => goTo(cur - 1)}>‹</button>
      <span class="r-step-n">Question <b>${cur + 1}</b> of ${total}</span>
      <span class="r-dots">${qs.map((q, i) => html`<button key=${q.id} class=${"r-dot" + (isDone(q) ? " done" : "") + (i === cur ? " cur" : "")}
          aria-label=${"Question " + (i + 1) + (isDone(q) ? ", answered" : "")} aria-current=${i === cur ? "step" : null} onClick=${() => goTo(i)}>${i + 1}</button>`)}</span>
      <button class="btn ghost icon r-step-btn" aria-label="Next question" disabled=${cur >= total - 1} onClick=${() => goTo(cur + 1)}>›</button>
    </nav>`}
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
          ${it.context ? html`<span class="muted"><${Linked} text=${it.context} /></span>` : null}
        </div>
      </aside>
      <div class="r-qs">
        ${owner ? html`<p class="r-owner">For the ${owner.kind}: <a href=${owner.href}><${Linked} text=${owner.title} /></a>
          <span class="faint"> · your answers are kept on its page, under Decisions</span></p>` : null}
        ${sent
          ? html`<div class="card r-sent"><div class="empty"><div class="mark">✓</div>
              <h3>${sent.withdrawn ? "Withdrawn" : "Round sent"}</h3>
              <p>${sent.withdrawn ? "The XO no longer needs these answers." : sent.read_by_xo ? "The XO has read your answers." : "The " + it.home + " XO has your answers; it reads them in its next round."}</p>
              <div class="row-flex"><button class="btn primary" onClick=${onBack}>Back to Needs me</button></div></div></div>`
          : qs.map((q, i) => html`<article key=${q.id} id=${"q" + q.id} class=${"card qcard" + ((picks[q.id] != null || (notes[q.id] || "").trim()) ? " answered" : "") + (focus === i ? " focus" : "")}
                onClick=${() => setFocus(i)}>
              <div class="card-h"><span class="qn">${i + 1}</span><h3 class="qtitle grow"><${Linked} text=${q.text} /></h3></div>
              ${q.context ? html`<p class="qctx"><${Linked} text=${q.context} /></p>` : null}
              ${q.options.length ? html`<${Options} options=${q.options} picked=${picks[q.id]} onPick=${(l) => { setPick(q.id, l); if (i < total - 1 && !isDone(qs[i + 1]) && window.matchMedia("(max-width: 860px)").matches) setTimeout(() => goTo(i + 1), 220); }} />` : null}
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
      ${recsLeft.length ? html`<button class="btn ghost r-recs" disabled=${busy} onClick=${() => recsLeft.forEach((q) => setPick(q.id, q.options.find((o) => o.rec).label))}>
        Accept recommended for ${recsLeft.length} left</button>` : null}
      <button class="btn primary r-submit" disabled=${busy || n < total} onClick=${onSubmit}>Submit<span class="r-submit-w"> round</span> <kbd>⌘↵</kbd></button>
    </div></div>`}
  </main>`;
}
