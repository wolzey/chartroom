// main.js - the chartroom app: every home's Needs me, the quick view, a round's cards, a task's details,
// the palette and the keyboard. Routes live in the hash: #/ (Needs me), #/q/<home>/<card> (a round),
// #/t/<home>/<task>[/<tab>] (a task's details).
import { html, useState, useEffect, useRef, useMemo, useCallback } from "./html.js";
import { getState, postAction, subscribe } from "./api.js";
import { Toasts, Menu } from "./ui.js";
import { NeedsList, QuickView, BulkBar } from "./needs.js";
import { RoundPage } from "./round.js";
import { TicketPage } from "./ticket.js";
import { Palette } from "./palette.js";

const M = window.AppModel;
const EF = window.EventFmt;
const OB = window.Outbox;
const OUTBOX_KEY = "chartroom-outbox";

function parseRoute() {
  const p = (location.hash || "#/").slice(1).split("/").filter(Boolean).map(decodeURIComponent);
  if (p[0] === "q" && p.length >= 3) return { name: "round", home: p[1], id: p[2] };
  if (p[0] === "t" && p.length >= 3) return { name: "task", home: p[1], id: p[2], tab: p[3] && p[3] !== "events" ? p[3] : "brief" };
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
  const [outbox, setOutbox] = useState(() => { try { return OB.load(localStorage.getItem(OUTBOX_KEY)); } catch (e) { return []; } });
  const [picks, setPicks] = useState({});
  const [notes, setNotes] = useState({});
  const [toasts, setToasts] = useState([]);
  const [palette, setPalette] = useState(false);
  const [qvOpen, setQvOpen] = useState(false);
  const [snoozeOpen, setSnoozeOpen] = useState(false);
  const [focusQ, setFocusQ] = useState(0);
  const [picked, setPicked] = useState(() => new Set());
  const anchor = useRef(null);
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

  const all = useMemo(() => M.items(data).map((it) => M.promote(it, EF)), [data]);
  const homes = useMemo(() => M.homes(data), [data]);
  // The outbox, kept across reloads; reconciled with the server's view of its actions on every state.
  useEffect(() => { try { localStorage.setItem(OUTBOX_KEY, JSON.stringify(outbox)); } catch (e) { /* private window */ } }, [outbox]);
  useEffect(() => { if (data) setOutbox((o) => OB.prune(OB.reconcile(o, data.actions || {}, Date.now()), Date.now())); }, [data]);
  // An item with an action on its way (or just done) is out of Needs me at once; a failed one is back.
  const local = useMemo(() => {
    const l = {};
    for (const e of outbox) {
      const st = OB.standing(outbox, e.key);
      if (e.key && (st === "pending" || st === "done")) l[e.key] = e.action === "snooze" ? "snoozed" : e.action === "unsnooze" ? undefined : "sent";
    }
    for (const k of Object.keys(l)) if (!l[k]) delete l[k];
    return l;
  }, [outbox]);
  const obState = useMemo(() => { const m = {}; for (const e of outbox) if (e.key) m[e.key] = OB.standing(outbox, e.key); return m; }, [outbox]);
  const opts = { filters, tab, local };
  const list = useMemo(() => M.ordered(M.visible(all, opts)), [all, filters, tab, local]);
  const sending = useRef(false);
  // The pump: sends what is due, one at a time, oldest first; a refusal fails it, silence retries it.
  useEffect(() => {
    const t = setInterval(async () => {
      if (sending.current) return;
      const next = OB.due(outboxRef.current, Date.now())[0];
      if (!next) return;
      sending.current = true;
      try {
        const r = await postAction(next.home, next.action, next.body, next.id);
        setOutbox((o) => o.map((e) => (e.id === next.id ? OB.posted(e, r.status, r.error, Date.now()) : e)));
        if (r.status >= 400 && r.status < 500) toast(next.label + " failed: " + (r.error || r.status));
      } finally { sending.current = false; }
    }, 400);
    return () => clearInterval(t);
  }, []);
  const counts = useMemo(() => M.counts(all, { filters, local }), [all, filters, local]);
  let sel = list.findIndex((it) => it.key === selKey);
  if (sel < 0) sel = list.length ? 0 : -1;
  const cur = sel >= 0 ? list[sel] : null;
  const setSel = (i) => { const it = list[Math.max(0, Math.min(list.length - 1, i))]; setSelKey(it ? it.key : null); setSnoozeOpen(false); if (!wide()) setQvOpen(true); };

  const hueOf = (home) => (homes.find((h) => h.name === home) || {}).hue || 5;
  const openDetails = (it, which) => {
    if (it.kind === "round") return go("#/q/" + encodeURIComponent(it.home) + "/" + encodeURIComponent(it.card));
    if (it.task) return go("#/t/" + encodeURIComponent(it.home) + "/" + encodeURIComponent(it.task) + (which ? "/" + which : ""));
  };
  const pick = (key, qid, label) => setPicks((p) => Object.assign({}, p, { [key]: Object.assign({}, p[key], { [qid]: label }) }));
  const note = (key, qid, text) => setNotes((n) => Object.assign({}, n, { [key]: Object.assign({}, n[key], { [qid]: text }) }));

  // Every action is queued: the page moves on at once, and the outbox sends it (see outbox.js).
  const enqueue = (it, action, body, label) => {
    const e = OB.create(it.home, action, body, it.key, label, Date.now());
    setOutbox((o) => o.concat([e]));
    return e;
  };
  const perform = (it, what) => {
    const n = (notes[it.key] || {})[1] || "";
    let action, body, msg = "Sent to the " + it.home + " XO, as your words";
    if (what.type === "answer") { action = "answer"; body = M.answerBody(it, picks[it.key], notes[it.key]); }
    else if (what.type === "approve" || what.type === "changes") {
      action = "answer"; body = M.answerBody(it, null, { 1: n }, what.type);
      msg = what.type === "approve" ? "Approved; the " + it.home + " XO tells the worker" : "Changes requested; the " + it.home + " XO tells the worker";
    } else if (what.type === "tell") { action = "tell"; body = { text: n, re: it.ref || it.task || undefined, project: it.project || undefined }; }
    else if (what.type === "accept" || what.type === "close") { action = what.type; body = { task: it.task }; msg = (what.type === "accept" ? "Accepted " : "Closed ") + (it.short_id || it.task); }
    else if (what.type === "done") { action = "done"; body = { ref: it.ref }; msg = "Marked done"; }
    else if (what.type === "snooze") { action = "snooze"; body = Object.assign({ ref: it.ref }, what.body); msg = "Snoozed for " + what.label.toLowerCase(); }
    else return;
    const e = enqueue(it, action, body, msg.split(";")[0]);
    const i = list.findIndex((x) => x.key === it.key);
    const next = list.filter((x) => x.key !== it.key)[Math.min(i, list.length - 2)];
    if (route.name === "needs") setSelKey(next ? next.key : null);
    if (!wide()) setQvOpen(false);
    toast(msg, what.type === "snooze" ? () => {
      // undo: drop it if it has not gone yet, else queue the opposite
      setOutbox((o) => o.filter((x) => !(x.id === e.id && x.state === "queued")));
      if (outboxRef.current.some((x) => x.id === e.id && x.state !== "queued")) enqueue(it, "unsnooze", { ref: it.ref }, "Undo snooze");
    } : null);
    return true;
  };
  const outboxRef = useRef(outbox); outboxRef.current = outbox;

  // Bulk selection: a set of item keys, kept to what the list shows.
  const visibleKeys = useMemo(() => new Set(list.map((x) => x.key)), [list]);
  useEffect(() => { setPicked((p) => { const n = new Set([...p].filter((k) => visibleKeys.has(k))); return n.size === p.size ? p : n; }); }, [visibleKeys]);
  const onPick = (key, how) => {
    setPicked((p) => {
      const n = new Set(p);
      if (how === "range" && anchor.current) { for (const k of M.range(list, anchor.current, key)) n.add(k); }
      else if (n.has(key)) n.delete(key); else n.add(key);
      return n;
    });
    if (how !== "range") anchor.current = key;
  };
  const onPickAll = (on) => { setPicked(on ? new Set(list.map((x) => x.key)) : new Set()); anchor.current = null; };
  const pickedItems = list.filter((x) => picked.has(x.key));
  // One outbox entry per item; what does not apply to an item is skipped, and said.
  const runBulk = (verb, extra, label) => {
    const plan = M.bulkPlan(pickedItems, verb, extra);
    const word = { done: "Marked done", accept: "Accepted", close: "Closing", snooze: "Snoozed" }[verb];
    for (const r of plan.run) enqueue(r.item, r.action, r.body, word + ": " + (r.item.short_id || r.item.title));
    const left = new Set(plan.skip.map((x) => x.item.key));
    setPicked(left);
    toast(word + " " + plan.run.length + (label ? " for " + label.toLowerCase() : "") +
      (plan.skip.length ? "; " + plan.skip.length + " left selected: " + plan.skip[0].why : "") +
      (verb === "close" ? ". A task with work it cannot keep refuses, and says why above." : ""));
  };
  const retryFailed = (e) => setOutbox((o) => o.map((x) => (x.id === e.id ? OB.retry(x, Date.now()) : x)));
  const dismissFailed = (e) => setOutbox((o) => o.filter((x) => x.id !== e.id));

  const doPrimary = (it) => {
    if (!it) return;
    const p = M.primary(it, EF);
    if (p.type === "open-round") return openDetails(it);
    if (it.sent) return;
    if (p.type === "focus-note") { setSelKey(it.key); if (!wide()) setQvOpen(true); setTimeout(() => { const t = document.querySelector('.a-detail textarea[data-note]'); if (t) t.focus(); }, 30); return; }
    return perform(it, { type: p.type });
  };
  // Enter, or a row's quick button: a decide row answers with the recommendation.
  const quick = (it) => {
    const p = M.primary(it, EF);
    if (p.type === "answer" && !it.sent) {
      enqueue(it, "answer", { card: it.card, answers: [{ q: 1, choice: p.choice, note: ((notes[it.key] || {})[1] || "").trim() || null }] }, "Answer “" + p.choice + "”");
      toast("Sent “" + p.choice + "” to the " + it.home + " XO");
      return;
    }
    return doPrimary(it);
  };

  const roundItem = route.name === "round" ? all.find((it) => it.home === route.home && it.card === route.id) : null;
  const submitRound = () => {
    const it = roundItem;
    if (!it) return;
    if (M.answered(it, picks[it.key], notes[it.key]) < (it.questions || []).length) { toast("Answer every question first, or take the recommendations for the rest."); return; }
    enqueue(it, "answer", M.answerBody(it, picks[it.key], notes[it.key]), "Round answers");
    toast("Round sent to the " + it.home + " XO");
  };

  // The keyboard.
  const state = { list, sel, cur, route, roundItem, focusQ, palette, snoozeOpen, picked };
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
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "a" && s.route.name === "needs") { e.preventDefault(); onPickAllRef.current(true); return; }
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
      if ((e.key === "J" || e.key === "K") && e.shiftKey && s.cur) {
        // extend the selection: this row and the next
        e.preventDefault();
        const to = s.list[M.move(s.sel, e.key === "J" ? 1 : -1, n)];
        setPicked((p) => { const q = new Set(p); q.add(s.cur.key); if (to) q.add(to.key); return q; });
        anchor.current = anchor.current || s.cur.key;
        if (to) setSelKeyFrom(s.list, s.list.indexOf(to));
        return;
      }
      if (e.key === "x" && s.cur) { onPickRef.current(s.cur.key, "toggle"); return; }
      if (e.key === "Escape" && s.picked.size) { setPicked(new Set()); return; }
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
  const onPickRef = useRef(onPick); onPickRef.current = onPick;
  const onPickAllRef = useRef(onPickAll); onPickAllRef.current = onPickAll;
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
  for (const e of outbox.filter((x) => x.state === "failed")) {
    notices.push(html`<div key=${"x" + e.id} class="notice warn"><span class="grow"><b>${e.label}</b> did not go through: ${e.error}</span>
      <button class="btn sm" onClick=${() => retryFailed(e)}>Retry</button><button class="btn ghost sm" onClick=${() => dismissFailed(e)}>Dismiss</button></div>`);
  }
  const queued = outbox.filter((x) => x.state === "queued" && x.tries > 0).length;
  if (queued) notices.push(html`<div key="q" class="notice"><span>${queued} ${queued === 1 ? "action is" : "actions are"} waiting for the server; ${queued === 1 ? "it goes" : "they go"} as soon as it answers.</span></div>`);
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
    main = html`<${RoundPage} it=${it && !it.sent && local[it.key] ? Object.assign({}, it, { sent: { at: new Date(it.at).toISOString(), via: "app", pending: obState[it.key] === "pending" } }) : it} picks=${(it && picks[it.key]) || {}} notes=${(it && notes[it.key]) || {}} busy=${false}
      setPick=${(q, l) => pick(it.key, q, l)} setNote=${(q, t) => note(it.key, q, t)} focus=${focusQ} setFocus=${setFocusQ}
      onSubmit=${submitRound} onBack=${() => go("#/")} />`;
  } else if (route.name === "task") {
    // the ticket: its open question (if Needs me has one for it) is answered in place, as in the quick view
    const raw = all.find((x) => x.home === route.home && x.task === route.id && ["open", "sent"].includes(M.standing(x, local)));
    const it = raw && !raw.sent && local[raw.key] === "sent" ? Object.assign({}, raw, { sent: { at: new Date().toISOString(), via: "app", pending: obState[raw.key] === "pending" } }) : raw;
    const h = (data && data.homes || []).find((x) => x.name === route.home);
    // the ticket's own changes go through the outbox too; accept and close also clear its Needs me item
    const ticketAct = (action, body, label) => {
      const key = (action === "accept" || action === "close") && raw ? raw.key : null;
      setOutbox((o) => o.concat([OB.create(route.home, action, body, key, label, Date.now())]));
      if (action === "accept" || action === "close") toast(label);
    };
    main = html`<${TicketPage} home=${route.home} hue=${hueOf(route.home)} id=${route.id} version=${data && data.version} prs=${(data && data.prs) || {}}
      item=${it} machine=${h && h.snapshot ? h.snapshot.machine : null} onAct=${ticketAct} onBack=${() => go("#/")} toast=${toast}
      askProps=${{ picks: raw && picks[raw.key], setPick: (q, l) => raw && pick(raw.key, q, l), note: raw && (notes[raw.key] || {})[1],
        setNote: (t) => raw && note(raw.key, 1, t), busy: false, onAct: perform, onDetails: openDetails, prs: (data && data.prs) || {} }} />`;
  } else {
    main = html`<${NeedsList} all=${all} list=${list} tab=${tab} setTab=${setTab} filters=${filters} setFilters=${setFilters} homes=${homes}
      counts=${counts} sel=${sel} setSel=${setSel} ob=${obState} onQuick=${quick} notices=${notices}
      picked=${picked} onPick=${onPick} onPickAll=${onPickAll} prs=${(data && data.prs) || {}} />`;
    const shown = cur && !cur.sent && local[cur.key] === "sent" ? Object.assign({}, cur, { sent: { at: new Date().toISOString(), via: "app", pending: obState[cur.key] === "pending" } }) : cur;
    aside = html`<${QuickView} it=${shown} open=${qvOpen} onClose=${() => setQvOpen(false)}
      picks=${cur && picks[cur.key]} setPick=${(q, l) => pick(cur.key, q, l)}
      note=${cur && (notes[cur.key] || {})[1]} setNote=${(t) => note(cur.key, 1, t)} busy=${false}
      onAct=${perform} onDetails=${openDetails} snoozeAnchorRef=${snoozeAnchor} snoozeOpen=${snoozeOpen} setSnoozeOpen=${setSnoozeOpen} prs=${(data && data.prs) || {}} />`;
  }
  return html`<div class="a-app">
    <${Sidebar} homes=${homes} filters=${filters} setFilters=${setFilters} counts=${counts} onPalette=${() => setPalette(true)} onLater=${later}
      link=${link} updated=${updated} theme=${theme} toggleTheme=${toggleTheme} route=${route} />
    ${main}${aside}
    ${qvOpen && aside ? html`<div class="qv-scrim" onClick=${() => setQvOpen(false)}></div>` : null}
    ${snoozeOpen && cur && snoozeAnchor.current ? html`<${Menu} anchor=${snoozeAnchor.current} title="Snooze until"
        items=${M.snoozes().map((x) => ({ id: x.label, label: x.label, body: x.body }))}
        onPick=${(x) => perform(cur, { type: "snooze", body: x.body, label: x.label })} onClose=${() => setSnoozeOpen(false)} />` : null}
    ${route.name === "needs" ? html`<${BulkBar} items=${pickedItems} onRun=${runBulk} onClear=${() => setPicked(new Set())} />` : null}
    ${palette ? html`<${Palette} entries=${entries} onClose=${() => setPalette(false)} />` : null}
    <${Toasts} toasts=${toasts} onUndo=${(t) => { setToasts((ts) => ts.filter((x) => x.id !== t.id)); t.undo(); }} />
  </div>`;
}

window.ReactDOM.createRoot(document.getElementById("app")).render(html`<${App} />`);
