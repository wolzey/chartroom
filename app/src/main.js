// main.js - the chartroom app: every home's Needs me, the quick view, a round's cards, a task's details,
// the palette and the keyboard. Routes live in the hash: #/ (Needs me), #/q/<home>/<card> (a round),
// #/t/<home>/<task>[/<tab>] (a task's details).
import { html, useState, useEffect, useRef, useMemo, useCallback } from "./html.js";
import { getState, act, subscribe } from "./api.js";
import { Toasts, Menu } from "./ui.js";
import { NeedsList, QuickView } from "./needs.js";
import { RoundPage } from "./round.js";
import { DetailsPage } from "./details.js";
import { Palette } from "./palette.js";

const M = window.AppModel;
const EF = window.EventFmt;

function parseRoute() {
  const p = (location.hash || "#/").slice(1).split("/").filter(Boolean).map(decodeURIComponent);
  if (p[0] === "q" && p.length >= 3) return { name: "round", home: p[1], id: p[2] };
  if (p[0] === "t" && p.length >= 3) return { name: "task", home: p[1], id: p[2], tab: p[3] || "brief" };
  return { name: "needs" };
}
function go(path) { location.hash = path; }
function load(k, d) { try { const v = JSON.parse(localStorage.getItem(k)); return v == null ? d : v; } catch (e) { return d; } }
function save(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* private window */ } }
const typing = (el) => el && (el.tagName === "TEXTAREA" || el.tagName === "INPUT" || el.isContentEditable);
const wide = () => window.matchMedia("(min-width: 1181px)").matches;

function Sidebar({ homes, filters, setFilters, counts, onPalette, onLater, link, updated, theme, toggleTheme, route }) {
  return html`<aside class="a-side">
    <div class="a-brand"><span class="a-logo" aria-hidden="true"></span><span class="grow">Chartroom</span>
      <button class="btn ghost icon" title=${"Switch to " + (theme === "dark" ? "light" : "dark") + " mode"} aria-label="Toggle dark mode" onClick=${toggleTheme}>${theme === "dark" ? "☀" : "☾"}</button></div>
    <div class="a-side-search"><button class="search-trigger" onClick=${onPalette}><span class="s-ic" aria-hidden="true"></span><span>Search</span><kbd>⌘K</kbd></button></div>
    <nav class="a-nav">
      <a class=${"nav-i" + (route.name === "needs" ? " on" : "")} href="#/"><span class="nav-ic needs" aria-hidden="true"></span><span class="grow">Needs me</span>${counts.all ? html`<span class="count">${counts.all}</span>` : null}</a>
      ${[["board", "Board"], ["initiatives", "Initiatives"], ["fleet", "Fleet"]].map(([id, label]) => html`<button key=${id} class="nav-i" aria-disabled="true" onClick=${() => onLater(label)}>
        <span class=${"nav-ic " + id} aria-hidden="true"></span><span class="grow">${label}</span></button>`)}
    </nav>
    <div class="a-sec">Homes</div>
    <div class="a-nav">${homes.map((h) => html`<button key=${h.name} class=${"nav-i" + (filters.home === h.name ? " on" : "")} title=${h.error || ""}
        onClick=${() => { setFilters(filters.home === h.name ? {} : { home: h.name }); go("#/"); }}>
      <span class=${"home-dot hue-" + h.hue} aria-hidden="true"></span><span class="grow truncate">${h.name}</span>
      ${h.error ? html`<span class="home-err" aria-label="could not be read"></span>` : h.counts && h.counts.needs ? html`<span class="count">${h.counts.needs}</span>` : null}
    </button>`)}</div>
    <div class="a-side-foot"><span class=${"sync" + (link ? "" : " off")}><i></i>${link ? "Live" : "Reconnecting"}${updated ? " · " + M.agoText(updated) : ""}</span></div>
  </aside>
  <div class="a-mobilebar"><span class="a-logo" aria-hidden="true"></span><b class="grow">Chartroom</b>
    <button class="btn ghost icon" aria-label="Toggle dark mode" onClick=${toggleTheme}>${theme === "dark" ? "☀" : "☾"}</button>
    <button class="btn ghost icon" aria-label="Search" onClick=${onPalette}><span class="s-ic"></span></button></div>`;
}

function App() {
  const [data, setData] = useState(null);
  const [loadErr, setLoadErr] = useState(null);
  const [link, setLink] = useState(false);
  const [route, setRoute] = useState(parseRoute());
  const [tab, setTab] = useState("all");
  const [filters, setFiltersRaw] = useState(load("chartroom-filters", {}));
  const [selKey, setSelKey] = useState(null);
  const [local, setLocal] = useState({});
  const [picks, setPicks] = useState({});
  const [notes, setNotes] = useState({});
  const [busy, setBusy] = useState(null);
  const [toasts, setToasts] = useState([]);
  const [palette, setPalette] = useState(false);
  const [qvOpen, setQvOpen] = useState(false);
  const [snoozeOpen, setSnoozeOpen] = useState(false);
  const [focusQ, setFocusQ] = useState(0);
  const [theme, setTheme] = useState(document.documentElement.getAttribute("data-theme") || "light");
  const snoozeAnchor = useRef(null);
  const inflight = useRef(null);
  const [, tick] = useState(0);

  const setFilters = (f) => { setFiltersRaw(f); save("chartroom-filters", f); };
  const refresh = useCallback(() => {
    if (inflight.current) { inflight.current.again = true; return; }
    const run = () => {
      inflight.current = { again: false };
      getState().then((s) => { setData(s); setLoadErr(null); }).catch((e) => setLoadErr(e.message))
        .finally(() => { const again = inflight.current && inflight.current.again; inflight.current = null; if (again) refresh(); });
    };
    run();
  }, []);
  useEffect(() => { refresh(); return subscribe(refresh, setLink); }, []);
  useEffect(() => { const f = () => { setRoute(parseRoute()); setPalette(false); }; window.addEventListener("hashchange", f); return () => window.removeEventListener("hashchange", f); }, []);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 15000); return () => clearInterval(t); }, []);
  useEffect(() => { document.body.setAttribute("data-screen", route.name === "task" ? "task" : route.name === "round" ? "round" : "needs"); }, [route.name]);

  const toast = (text, undo) => {
    const id = Math.random().toString(36).slice(2);
    setToasts((ts) => ts.concat([{ id, text, undo }]));
    setTimeout(() => setToasts((ts) => ts.filter((t) => t.id !== id)), undo ? 6000 : 4200);
  };

  const all = useMemo(() => M.items(data), [data]);
  const homes = useMemo(() => M.homes(data), [data]);
  // An item acted on here stays marked until a snapshot no longer lists it as open.
  useEffect(() => {
    setLocal((l) => {
      const next = {};
      for (const k of Object.keys(l)) { const it = all.find((x) => x.key === k); if (it && M.standing(it) === "open") next[k] = l[k]; }
      return next;
    });
  }, [all]);
  const opts = { filters, tab, local };
  const list = useMemo(() => M.ordered(M.visible(all, opts)), [all, filters, tab, local]);
  const counts = useMemo(() => M.counts(all, { filters, local }), [all, filters, local]);
  let sel = list.findIndex((it) => it.key === selKey);
  if (sel < 0) sel = list.length ? 0 : -1;
  const cur = sel >= 0 ? list[sel] : null;
  const setSel = (i) => { const it = list[Math.max(0, Math.min(list.length - 1, i))]; setSelKey(it ? it.key : null); setSnoozeOpen(false); if (!wide()) setQvOpen(true); };

  const taskOf = (home, id) => { const h = (data && data.homes || []).find((x) => x.name === home); return h && h.snapshot ? (h.snapshot.tasks || []).find((t) => t.id === id) : null; };
  const hueOf = (home) => (homes.find((h) => h.name === home) || {}).hue || 5;
  const openDetails = (it, which) => {
    if (it.kind === "round") return go("#/q/" + encodeURIComponent(it.home) + "/" + encodeURIComponent(it.card));
    if (it.task) return go("#/t/" + encodeURIComponent(it.home) + "/" + encodeURIComponent(it.task) + (which ? "/" + which : ""));
  };
  const pick = (key, qid, label) => setPicks((p) => Object.assign({}, p, { [key]: Object.assign({}, p[key], { [qid]: label }) }));
  const note = (key, qid, text) => setNotes((n) => Object.assign({}, n, { [key]: Object.assign({}, n[key], { [qid]: text }) }));

  const perform = async (it, what) => {
    const n = (notes[it.key] || {})[1] || "";
    let action, body, mark = "sent", msg = "Sent to the " + it.home + " XO, as your words";
    if (what.type === "answer") { action = "answer"; body = M.answerBody(it, picks[it.key], notes[it.key]); }
    else if (what.type === "approve" || what.type === "changes") {
      action = "answer"; body = M.answerBody(it, null, { 1: n }, what.type);
      msg = what.type === "approve" ? "Approved; the " + it.home + " XO tells the worker" : "Changes requested; the " + it.home + " XO tells the worker";
    } else if (what.type === "tell") { action = "tell"; body = { text: n, re: it.ref || it.task || undefined, project: it.project || undefined }; }
    else if (what.type === "accept" || what.type === "close") { action = what.type; body = { task: it.task }; mark = "gone"; msg = (what.type === "accept" ? "Accepted " : "Closed ") + (it.short_id || it.task); }
    else if (what.type === "done") { action = "done"; body = { ref: it.ref }; mark = "gone"; msg = "Marked done"; }
    else if (what.type === "snooze") { action = "snooze"; body = Object.assign({ ref: it.ref }, what.body); mark = "snoozed"; msg = "Snoozed for " + what.label.toLowerCase(); }
    else return;
    setBusy(it.key);
    try {
      await act(it.home, action, body);
      setLocal((l) => Object.assign({}, l, { [it.key]: mark }));
      const i = list.findIndex((x) => x.key === it.key);
      const next = list.filter((x) => x.key !== it.key)[Math.min(i, list.length - 2)];
      if (route.name === "needs") setSelKey(next ? next.key : null);
      if (!wide()) setQvOpen(false);
      toast(msg, what.type === "snooze" ? async () => { await act(it.home, "unsnooze", { ref: it.ref }).catch((e) => toast(e.message)); setLocal((l) => { const c = Object.assign({}, l); delete c[it.key]; return c; }); refresh(); } : null);
      refresh();
      return true;
    } catch (e) {
      toast(e.message);
      refresh();
      return false;
    } finally { setBusy(null); }
  };

  const doPrimary = (it) => {
    if (!it) return;
    const p = M.primary(it, EF);
    if (p.type === "open-round") return openDetails(it);
    if (it.sent) return;
    if (p.type === "focus-note") { setSelKey(it.key); if (!wide()) setQvOpen(true); setTimeout(() => { const t = document.querySelector('.a-detail textarea[data-note]'); if (t) t.focus(); }, 30); return; }
    return perform(it, { type: p.type });
  };
  // Enter, or a row's quick button: a decide row answers with the recommendation in one request.
  const quick = (it) => {
    const p = M.primary(it, EF);
    if (p.type === "answer") {
      const body = { card: it.card, answers: [{ q: 1, choice: p.choice, note: ((notes[it.key] || {})[1] || "").trim() || null }] };
      setBusy(it.key);
      return act(it.home, "answer", body).then(() => {
        setLocal((l) => Object.assign({}, l, { [it.key]: "sent" }));
        toast("Sent “" + p.choice + "” to the " + it.home + " XO");
        refresh();
      }).catch((e) => { toast(e.message); refresh(); }).finally(() => setBusy(null));
    }
    return doPrimary(it);
  };

  const roundItem = route.name === "round" ? all.find((it) => it.home === route.home && it.card === route.id) : null;
  const submitRound = async () => {
    const it = roundItem;
    if (!it) return;
    if (M.answered(it, picks[it.key], notes[it.key]) < (it.questions || []).length) { toast("Answer every question first, or take the recommendations for the rest."); return; }
    setBusy(it.key);
    try {
      await act(it.home, "answer", M.answerBody(it, picks[it.key], notes[it.key]));
      toast("Round sent to the " + it.home + " XO");
      refresh();
    } catch (e) { toast(e.message); refresh(); } finally { setBusy(null); }
  };

  // The keyboard.
  const state = { list, sel, cur, route, roundItem, focusQ, palette, snoozeOpen };
  const ref = useRef(state); ref.current = state;
  useEffect(() => {
    const onKey = (e) => {
      const s = ref.current;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); setPalette((p) => !p); return; }
      if (s.palette || s.snoozeOpen || (e.target && e.target.closest && e.target.closest(".palette, .menu"))) return;
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        if (s.route.name === "round") return submitRoundRef.current();
        const it = s.cur;
        if (!it || it.sent) return;
        if (it.kind === "approve") return performRef.current(it, { type: "approve" });
        const t = (notesRef.current[it.key] || {})[1];
        const has = (picksRef.current[it.key] || {})[1] != null || (t && t.trim());
        if (has && !["review", "artifact", "round"].includes(it.kind)) performRef.current(it, { type: it.card ? "answer" : "tell" });
        return;
      }
      if (typing(document.activeElement)) { if (e.key === "Escape") document.activeElement.blur(); return; }
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === "/") { e.preventDefault(); setPalette(true); return; }
      if (s.route.name === "round") {
        const qs = s.roundItem ? M.questions(s.roundItem) : [];
        if (e.key === "j" || e.key === "ArrowDown") { e.preventDefault(); setFocusQ((f) => M.move(f, 1, qs.length)); }
        else if (e.key === "k" || e.key === "ArrowUp") { e.preventDefault(); setFocusQ((f) => M.move(f, -1, qs.length)); }
        else if (/^[1-9]$/.test(e.key) && qs[s.focusQ]) { const o = qs[s.focusQ].options[+e.key - 1]; if (o) pick(s.roundItem.key, qs[s.focusQ].id, o.label); }
        else if (e.key === "r" && qs[s.focusQ]) { const o = qs[s.focusQ].options.find((x) => x.rec); if (o) pick(s.roundItem.key, qs[s.focusQ].id, o.label); }
        else if (e.key === "Escape") go("#/");
        return;
      }
      if (s.route.name === "task") { if (e.key === "Escape") go("#/"); return; }
      const n = s.list.length;
      if (e.key === "j" || e.key === "ArrowDown") { e.preventDefault(); setSelKeyFrom(s.list, M.move(s.sel, 1, n)); }
      else if (e.key === "k" || e.key === "ArrowUp") { e.preventDefault(); setSelKeyFrom(s.list, M.move(s.sel, -1, n)); }
      else if (e.key === "Enter" && e.shiftKey) { if (s.cur) openDetails(s.cur); }
      else if (e.key === "o") { if (s.cur) openDetails(s.cur); }
      else if (e.key === "Enter") { if (s.cur) doPrimaryRef.current(s.cur); }
      else if (e.key === "a") {
        const it = s.cur;
        if (it && !it.sent && ["approve", "review", "artifact"].includes(it.kind)) performRef.current(it, { type: it.kind === "approve" ? "approve" : it.kind === "review" ? "accept" : "done" });
      }
      else if (e.key === "s") { if (s.cur && s.cur.ref && !s.cur.sent) { if (!wide()) setQvOpen(true); setTimeout(() => setSnoozeOpen(true), 0); } }
      else if (/^[1-9]$/.test(e.key) && s.cur && !s.cur.sent) {
        const q = M.questions(s.cur, EF)[0];
        const o = q && q.options[+e.key - 1];
        if (o) pick(s.cur.key, 1, o.label);
      }
      else if (e.key === "Escape") { setQvOpen(false); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  const setSelKeyFrom = (l, i) => { const it = l[i]; if (it) { setSelKey(it.key); setSnoozeOpen(false); const el = document.querySelector('.a-row[data-key="' + CSS.escape(it.key) + '"]'); if (el) el.scrollIntoView({ block: "nearest" }); } };
  const performRef = useRef(perform); performRef.current = perform;
  const doPrimaryRef = useRef(quick); doPrimaryRef.current = quick;
  const submitRoundRef = useRef(submitRound); submitRoundRef.current = submitRound;
  const picksRef = useRef(picks); picksRef.current = picks;
  const notesRef = useRef(notes); notesRef.current = notes;

  const toggleTheme = () => { const t = theme === "dark" ? "light" : "dark"; document.documentElement.setAttribute("data-theme", t); try { localStorage.setItem("chartroom-theme", t); } catch (e) { /* */ } setTheme(t); };
  const later = (label) => toast(label + " comes in a later slice; Needs me is first.");

  const entries = useMemo(() => {
    const e = [
      { id: "c-needs", group: "Go to", label: "Needs me", run: () => { setTab("all"); go("#/"); } },
      { id: "c-sent", group: "Go to", label: "Sent answers", sub: "waiting on an XO", run: () => { setTab("sent"); go("#/"); } },
      { id: "c-theme", group: "Commands", label: "Switch to " + (theme === "dark" ? "light" : "dark") + " mode", run: toggleTheme },
      { id: "c-clear", group: "Commands", label: "Clear filters", run: () => setFilters({}) },
    ];
    for (const h of homes) e.push({ id: "h-" + h.name, group: "Homes", label: "Only " + h.name, sub: h.counts ? h.counts.needs + " open" : "", run: () => { setFilters({ home: h.name }); go("#/"); } });
    for (const it of all) {
      if (M.standing(it) !== "open") continue;
      e.push({ id: "i-" + it.key, group: "Needs me", label: it.title, sub: it.home + (it.short_id ? " · " + it.short_id : ""), run: () => { setTab("all"); go("#/"); setSelKey(it.key); if (!wide()) setQvOpen(true); } });
    }
    return e;
  }, [all, homes, theme]);

  // Notices above the list: homes not read yet, or that failed; items focus mode holds.
  const notices = [];
  if (loadErr) notices.push(html`<div key="err" class="notice warn"><span>${loadErr}</span></div>`);
  for (const h of (data && data.homes) || []) {
    if (h.error) notices.push(html`<div key=${"e" + h.name} class="notice warn"><span><b>${h.name}</b> could not be read: ${h.error}</span></div>`);
    else if (!h.snapshot) notices.push(html`<div key=${"r" + h.name} class="notice"><span>Reading <b>${h.name}</b>… the first read of a big home takes a few seconds.</span></div>`);
    else if (h.snapshot.counts && h.snapshot.counts.held) notices.push(html`<div key=${"f" + h.name} class="notice"><span>Focus mode in <b>${h.name}</b> holds ${h.snapshot.counts.held} more.</span></div>`);
  }
  const updated = data && data.homes && data.homes.map((h) => h.refreshed_at).filter(Boolean).sort().pop();

  let main, aside = null;
  if (!data && !loadErr) main = html`<main class="a-main"><div class="a-head"><div class="a-head-l"><h1>Needs me</h1></div></div><div class="notice"><span>Reading every home…</span></div></main>`;
  else if (route.name === "round") {
    const it = roundItem;
    main = html`<${RoundPage} it=${it} picks=${(it && picks[it.key]) || {}} notes=${(it && notes[it.key]) || {}} busy=${busy === (it && it.key)}
      setPick=${(q, l) => pick(it.key, q, l)} setNote=${(q, t) => note(it.key, q, t)} focus=${focusQ} setFocus=${setFocusQ}
      onSubmit=${submitRound} onBack=${() => go("#/")} />`;
  } else if (route.name === "task") {
    main = html`<${DetailsPage} home=${route.home} hue=${hueOf(route.home)} id=${route.id} task=${taskOf(route.home, route.id)} tab=${route.tab}
      setTab=${(t) => go("#/t/" + encodeURIComponent(route.home) + "/" + encodeURIComponent(route.id) + "/" + t)} onBack=${() => go("#/")} />`;
  } else {
    main = html`<${NeedsList} all=${all} list=${list} tab=${tab} setTab=${setTab} filters=${filters} setFilters=${setFilters} homes=${homes}
      counts=${counts} sel=${sel} setSel=${setSel} local=${local} onQuick=${quick} notices=${notices} />`;
    aside = html`<${QuickView} it=${cur} open=${qvOpen} onClose=${() => setQvOpen(false)}
      picks=${cur && picks[cur.key]} setPick=${(q, l) => pick(cur.key, q, l)}
      note=${cur && (notes[cur.key] || {})[1]} setNote=${(t) => note(cur.key, 1, t)} busy=${busy === (cur && cur.key)}
      onAct=${perform} onDetails=${openDetails} snoozeAnchorRef=${snoozeAnchor} snoozeOpen=${snoozeOpen} setSnoozeOpen=${setSnoozeOpen} />`;
  }
  return html`<div class="a-app">
    <${Sidebar} homes=${homes} filters=${filters} setFilters=${setFilters} counts=${counts} onPalette=${() => setPalette(true)} onLater=${later}
      link=${link} updated=${updated} theme=${theme} toggleTheme=${toggleTheme} route=${route} />
    ${main}${aside}
    ${qvOpen && aside ? html`<div class="qv-scrim" onClick=${() => setQvOpen(false)}></div>` : null}
    ${snoozeOpen && cur && snoozeAnchor.current ? html`<${Menu} anchor=${snoozeAnchor.current} title="Snooze until"
        items=${M.snoozes().map((x) => ({ id: x.label, label: x.label, body: x.body }))}
        onPick=${(x) => perform(cur, { type: "snooze", body: x.body, label: x.label })} onClose=${() => setSnoozeOpen(false)} />` : null}
    ${palette ? html`<${Palette} entries=${entries} onClose=${() => setPalette(false)} />` : null}
    <${Toasts} toasts=${toasts} onUndo=${(t) => { setToasts((ts) => ts.filter((x) => x.id !== t.id)); t.undo(); }} />
  </div>`;
}

window.ReactDOM.createRoot(document.getElementById("app")).render(html`<${App} />`);
