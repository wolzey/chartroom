// model.js - what the app shows, from the server's state: every home's Needs me items as one list,
// the filters and tabs over it, a card's options, and the keyboard's selection. Pure: no DOM, no
// fetch. The page loads it as a plain script (window.AppModel); test/js/app-model.test.js runs it
// under node. What an item *is* (its kind, group, whether it was answered) comes from the CLI's
// snapshot (lib/app/snapshot.jq); this file only arranges it.
var AppModel = (function () {
  "use strict";
  // eventfmt.js: the page loads it before this file; under node it is required beside the tests
  const EF_HEAD = typeof EventFmt !== "undefined" ? EventFmt
    : typeof require === "function" ? (() => { try { return require("../shared/eventfmt.js"); } catch (e) { return null; } })() : null;

  // Kinds, as the snapshot names them, onto the design's glyphs and labels.
  const KINDS = {
    decide: { label: "Decide", glyph: "decide" },
    round: { label: "Questions", glyph: "round" },
    approve: { label: "Approve", glyph: "approve" },
    approval: { label: "Approve", glyph: "approve" },
    inbox: { label: "Question", glyph: "decide" },
    blocked: { label: "Blocked", glyph: "blocked" },
    failed: { label: "Failed", glyph: "blocked" },
    input: { label: "Needs input", glyph: "blocked" },
    review: { label: "Finished", glyph: "read" },
    artifact: { label: "To send", glyph: "tidy" },
    stories: { label: "Stories", glyph: "approve" },
    login: { label: "Sign-in", glyph: "login" },
    permission: { label: "Permission", glyph: "blocked" },
  };
  // A finished task waiting to be accepted is not a question: its own group, last, apart from what
  // asks the commander something (the snapshot says "read"; the app splits it off by kind).
  const GROUPS = [
    { id: "decide", label: "Decide", hint: "Questions and choices waiting on you" },
    { id: "approve", label: "Approve", hint: "Plans ready for a yes" },
    { id: "unblock", label: "Unblock", hint: "Work that can't move without you" },
    { id: "read", label: "Read", hint: "Drafts to send or run" },
    { id: "finished", label: "Finished", hint: "Done, waiting for your nod", heading: "Finished, waiting for your nod" },
  ];
  const STATUS = {
    drafting: "Drafting", queued: "Queued", working: "Working", waiting: "Waiting",
    needs: "Needs you", review: "Review", done: "Done", closed: "Closed",
  };

  function kind(k) { return KINDS[k] || { label: k || "Item", glyph: "read" }; }

  // Every home's items, each tagged with its home (and the home's hue, 1-5 in the order homes come).
  function items(state) {
    const out = [];
    const ids = taskIds(state);
    ((state && state.homes) || []).forEach((h, i) => {
      const snap = h.snapshot;
      if (!snap || !Array.isArray(snap.needs)) return;
      for (const it of snap.needs) {
        const x = Object.assign({}, it, { home: h.name, hue: (i % 5) + 1, key: h.name + ":" + it.id }, it.kind === "review" ? { group: "finished" } : {});
        x.view = view(x, ids);
        out.push(x);
      }
    });
    // the fleet's own: a failed sign-in on a machine belongs to no home (only the commander can fix it)
    const fl = state && state.fleet;
    for (const it of (fl && fl.needs) || []) {
      const x = Object.assign({}, it, { home: "fleet", hue: 0, key: "fleet:" + it.id, at: it.at || fl.checked_at });
      x.view = view(x, ids);
      out.push(x);
    }
    return out;
  }

  function homes(state) {
    return ((state && state.homes) || []).map((h, i) => ({
      name: h.name, hue: (i % 5) + 1, ok: h.ok, error: h.error, refreshed_at: h.refreshed_at,
      counts: (h.snapshot && h.snapshot.counts) || null, focus: (h.snapshot && h.snapshot.focus) || null,
    }));
  }

  // Where an item stands: "open" (in Needs me), "sent" (answered, waiting on the XO), "snoozed", "held"
  // (focus mode), or "gone" (acted on here a moment ago; the next snapshot drops it).
  function standing(it, local) {
    if (local && local[it.key]) return local[it.key]; // "sent" or "snoozed": an action on its way from here
    if (it.sent) return "sent";
    if (it.snoozed_until && Date.parse(it.snoozed_until) > Date.now()) return "snoozed";
    if (it.held) return "held";
    return "open";
  }

  // The list for a tab and filters. tab: "all", a group id, "sent" or "snoozed".
  function visible(all, opts) {
    const o = opts || {};
    const f = o.filters || {};
    return all.filter((it) => {
      const st = standing(it, o.local);
      if (o.tab === "sent") { if (st !== "sent") return false; }
      else if (o.tab === "snoozed") { if (st !== "snoozed") return false; }
      else if (st !== "open") return false;
      if (f.home && it.home !== f.home) return false;
      if (f.project && (it.project || "") !== f.project) return false;
      if (o.tab && !["all", "sent", "snoozed"].includes(o.tab) && it.group !== o.tab) return false;
      return true;
    });
  }

  // The list in display order: by group, then breaking first, then oldest first.
  // A live permission card a worker is blocked on: the only items with a clock, so they come first
  // (nearest expiry first), ahead of every group.
  const clocked = (it) => it.kind === "permission" && it.blocking && !it.missed;
  function ordered(list) {
    const rank = {}; GROUPS.forEach((g, i) => { rank[g.id] = i; });
    return list.slice().sort((a, b) =>
      (clocked(b) ? 1 : 0) - (clocked(a) ? 1 : 0) || (clocked(a) ? a.expires_epoch - b.expires_epoch : 0) ||
      (rank[a.group] ?? 9) - (rank[b.group] ?? 9) || (b.breaking ? 1 : 0) - (a.breaking ? 1 : 0) ||
      String(a.at || "").localeCompare(String(b.at || "")) || String(a.key).localeCompare(String(b.key)));
  }

  function counts(all, opts) {
    const base = Object.assign({}, opts, { tab: "all" });
    const open = visible(all, base);
    const c = { all: open.length, sent: visible(all, Object.assign({}, base, { tab: "sent" })).length,
      snoozed: visible(all, Object.assign({}, base, { tab: "snoozed" })).length };
    GROUPS.forEach((g) => { c[g.id] = open.filter((it) => it.group === g.id).length; });
    return c;
  }

  function projects(all, home) {
    const s = new Set();
    for (const it of all) if (it.project && (!home || it.home === home)) s.add(it.project);
    return [...s].sort();
  }

  // A card's questions, the same shape for every kind: [{id, text, context, why, options: [{label,
  // detail, rec}], free}]. A worker's ask is parsed by EventFmt (app/shared/eventfmt.js), the
  // shared reader of "Options: (1) ... (2) ... RECOMMENDED"; an ask with no options is one
  // free-text question.
  function questions(it, EventFmt) {
    if (Array.isArray(it.questions)) {
      return it.questions.map((q) => ({ id: q.id, text: q.text, context: q.context || null, why: q.why || null,
        options: (q.options || []).map((o) => ({ label: o.label, detail: o.detail || null, rec: !!o.rec })), free: !(q.options || []).length }));
    }
    const text = askText(it.text || it.summary || "");
    let parsed = null;
    if (EventFmt && it.type === "task") {
      try { parsed = EventFmt.parseEvent(it.kind === "decide" || it.kind === "approve" ? "decision" : it.kind, text); } catch (e) { parsed = null; }
    }
    const lead = (parsed && parsed.headline) || text;
    // Each list of options in the ask is one question: a worker or XO that asks several things at
    // once wrote a grilling round, and it is answered as one (the round page, never the quick view).
    const qs = [];
    for (const b of (parsed && parsed.blocks) || []) {
      for (const p of b.parts || []) {
        if (p.type !== "options") continue;
        const options = [];
        for (const o of p.items) {
          const label = (o.title || o.text || "").replace(/[.\s]+$/, "");
          // Only an explicit marker recommends: "(1) RECOMMENDED: ..." (the label leading the option)
          // or "(1, recommended)". A word in the option's text ("Not recommended; ...") never does.
          if (label) options.push({ label, detail: o.title ? o.text || null : null, rec: !!(o.recommended && o.recword) });
        }
        // At most one recommendation per question: two marked options recommend neither.
        if (options.filter((o) => o.rec).length > 1) options.forEach((o) => { o.rec = false; });
        if (!options.length) continue;
        const said = (b.parts || []).filter((x) => x.type === "p").map((x) => x.text).join(" ");
        const label = b.label && !/^(options?|choices)$/i.test(b.label) ? b.label : null;
        qs.push({ label, said, options });
      }
    }
    if (qs.length <= 1) {
      const options = qs.length ? qs[0].options : [];
      return [{ id: 1, text: lead, context: null, why: null, options, free: options.length === 0 }];
    }
    // an unlabelled first list answers the ask's own lead; the others are named by their label
    return qs.map((q, i) => {
      const text = q.label || (i === 0 ? lead : q.said) || "Question " + (i + 1);
      const context = q.said && q.said !== text ? q.said : null;
      return { id: i + 1, text, context, why: null, options: q.options, free: false };
    });
  }

  // An item with several questions is a round, whatever it came from: it opens on the round page.
  function promote(it, EventFmt) {
    if (it.kind === "round" || it.type !== "task" || !it.card || it.kind === "approve") return it;
    const qs = questions(it, EventFmt);
    return qs.length > 1 ? Object.assign({}, it, { kind: "round", questions: qs, asked_kind: it.kind }) : it;
  }

  // A worker's ask as it was meant: "headline --detail rest" is a `chartroom event` whose flag came
  // after the headline, so the flag went into the text. It reads as the headline, then the detail.
  function askText(text) {
    return String(text || "").replace(/\s+--detail\s+/, ". Details: ");
  }

  // The headline of a worker's event text, never its detail: the first sentence or clause.
  function headline(text) {
    const t = askText(text);
    if (EF_HEAD) { try { const p = EF_HEAD.parseEvent("progress", t); if (p.headline) return p.headline; } catch (e) { /* plain */ } }
    const m = /^(.{1,200}?)(?:[.:;](?:\s|$)|\s+Details:)/.exec(t);
    return (m ? m[1] : t.slice(0, 200)).trim();
  }

  // The parts of a worker's ask after its headline, as label + text pairs, for the quick view.
  function details(it, EventFmt) {
    if (!EventFmt || it.type !== "task" || !(it.text || it.summary)) return [];
    let parsed;
    try { parsed = EventFmt.parseEvent("decision", askText(it.text || it.summary)); } catch (e) { return []; }
    const out = [];
    for (const b of parsed.blocks || []) {
      const text = (b.parts || []).filter((p) => p.type === "p").map((p) => p.text)
        .concat(...(b.parts || []).filter((p) => p.type === "ul").map((p) => p.items)).join(" ");
      const clean = text.replace(/\s*\b(options?|choices)\s*:?\s*$/i, "").trim();
      if (clean && !/^(options?|choices)$/i.test(b.label || "")) out.push({ label: b.label || null, text: clean });
    }
    return out;
  }

  // What Enter does on a row: answer with the recommendation, approve, accept, or open the card.
  // A permission card's clock (lib/permit.sh: denied when it runs out). -> {secs, text, over}.
  function permitLeft(it, nowMs) {
    if (!it || it.kind !== "permission") return null;
    if (!it.blocking) return { secs: null, text: "auto mode refused this", over: false };
    const secs = Math.floor(it.expires_epoch - (nowMs == null ? Date.now() : nowMs) / 1000);
    if (it.missed || secs <= 0) return { secs: 0, text: it.state_permit === "lapsed" ? "the worker went on without it" : "the wait ran out: denied", over: true };
    return { secs, text: secs >= 60 ? Math.floor(secs / 60) + "m left" : secs + "s left", over: false };
  }

  function primary(it, EventFmt) {
    if (it.kind === "round" || it.kind === "stories" || it.kind === "login") return { type: "open-round" };
    // never allowed by a key press: Enter only puts the cursor in the note
    if (it.kind === "permission") return { type: "focus-note" };
    if (it.kind === "approve") return { type: "approve" };
    if (it.kind === "review") return { type: "accept" };
    if (it.kind === "artifact") return { type: "done" };
    if (it.kind === "decide") {
      const q = questions(it, EventFmt);
      const rec = q.length === 1 ? q[0].options.find((o) => o.rec) : null;
      if (rec) return { type: "answer", choice: rec.label };
    }
    return { type: "focus-note" };
  }

  // The body of an answer for POST /answer.
  function answerBody(it, picks, notes, action) {
    if (action) return { card: it.card, action, note: (notes && notes[1]) || null };
    const qs = Array.isArray(it.questions) ? it.questions : [{ id: 1 }];
    // a worker's round has no record of its questions: each answer carries its question's words
    return { card: it.card, answers: qs.map((q) => Object.assign({ q: q.id, choice: picks && picks[q.id] != null ? picks[q.id] : null,
      note: notes && notes[q.id] && notes[q.id].trim() ? notes[q.id].trim() : null }, it.asked_kind && q.text ? { question: q.text } : {})) };
  }

  function answered(it, picks, notes) {
    const qs = Array.isArray(it.questions) ? it.questions.map((q) => q.id) : [1];
    return qs.filter((id) => (picks && picks[id] != null) || (notes && notes[id] && notes[id].trim())).length;
  }

  // j/k: the next selection in a list of n, staying in range.
  function move(sel, delta, n) {
    if (!n) return 0;
    return Math.max(0, Math.min(n - 1, (sel == null ? -1 : sel) + delta));
  }

  // "3h ago", or "just now".
  function agoText(iso, now) { const a = ago(iso, now); return a === "now" ? "just now" : a ? a + " ago" : ""; }

  function ago(iso, now) {
    const t = Date.parse(iso || "");
    if (!isFinite(t)) return "";
    const s = Math.max(0, Math.round(((now || Date.now()) - t) / 1000));
    if (s < 60) return "now";
    if (s < 3600) return Math.floor(s / 60) + "m";
    if (s < 86400) return Math.floor(s / 3600) + "h";
    return Math.floor(s / 86400) + "d";
  }

  // Snooze choices: [{label, body}] where body is what POST /snooze takes.
  function snoozes(now) {
    const d = new Date(now || Date.now());
    const morning = new Date(d); morning.setDate(d.getDate() + 1); morning.setHours(9, 0, 0, 0);
    const iso = morning.toISOString().replace(/\.\d{3}Z$/, "Z");
    return [
      { label: "1 hour", body: { for: "1h" } },
      { label: "4 hours", body: { for: "4h" } },
      { label: "Tomorrow morning", body: { until: iso } },
      { label: "Next week", body: { for: "7d" } },
    ];
  }

  // The board (slice 3): every home's tasks, plus the requests not yet briefed (Drafting), each
  // keyed by home and carrying its home's machine. Closed tasks are in Done.
  const BOARD = ["drafting", "queued", "working", "waiting", "needs", "review", "done"];
  function boardItems(state) {
    const out = [];
    ((state && state.homes) || []).forEach((h, i) => {
      const s = h.snapshot;
      if (!s) return;
      const base = { home: h.name, hue: (i % 5) + 1, machine: s.machine || null };
      for (const t of s.tasks || []) {
        const line = t.status === "working" || t.status === "waiting" ? headline(String(t.last_event || "").replace(/^[a-z-]+: /, "")) : null;
        // a task pinned to a device runs there; the others on their home's machine
        out.push(Object.assign({}, t, base, { machine: t.machine || base.machine, key: h.name + ":" + t.id, type: "task", task: t.id, column: t.status === "closed" ? "done" : t.status, line }));
      }
      // an initiative's approved stories that have no task yet: Queued (held ones wait on their "after")
      for (const ini of s.initiatives || []) {
        for (const st of ini.stories || []) {
          if (st.task || !["approved", "held"].includes(st.state)) continue;
          out.push(Object.assign({}, base, { key: h.name + ":" + st.id, id: st.id, short_id: st.id, type: "story", title: st.title, project: st.project,
            initiative: ini.id, status: "queued", column: "queued", created: ini.created, prs: [],
            line: st.state === "held" ? "Waits for " + (st.after || []).map((a) => ((ini.stories || []).find((x) => x.id === a) || {}).title || a).join(", ") : "Approved; the XO briefs it" }));
        }
      }
      for (const r of s.requests || []) {
        out.push(Object.assign({}, base, { key: h.name + ":" + r.id, id: r.id, short_id: r.id, type: "request", title: r.title, project: r.project,
          priority: r.priority, initiative: r.initiative, status: "drafting", column: "drafting", created: r.at, line: "Asked for; the XO briefs it", prs: [] }));
      }
    });
    return out;
  }
  function boardFilter(list, f) {
    const o = f || {};
    return list.filter((t) => (!o.home || t.home === o.home) && (!o.project || t.project === o.project) &&
      (!o.initiative || t.initiative === o.initiative) && (!o.machine || t.machine === o.machine));
  }
  // Columns in the design's order, cards in each newest-first by their last move.
  function boardColumns(list) {
    return BOARD.map((s) => ({ status: s, cards: list.filter((t) => t.column === s)
      .sort((a, b) => String(b.last_at || b.created || "").localeCompare(String(a.last_at || a.created || ""))) }));
  }

  // Fleet's atom and dashboard (fleetviews.js): what each machine holds, and what is wrong on it.
  const FLEET_STATES = { working: "Working", waiting: "Waiting", needs: "Needs me", stalled: "Stalled", review: "Finished", other: "Unknown" };
  const REST_DAYS = 7; // a session whose task has not moved for this long is "at rest": a count until shown
  const OPEN_LIVE = ["working", "blocked", "done", "in-session"]; // a session is open; parked, gone, stopped: none
  const rank = (s) => Object.keys(FLEET_STATES).indexOf(s);
  function fleetState(t) {
    if (t.state === "stopped-silent" || t.state === "waiting-overdue" || t.state === "failed" || t.live === "gone") return "stalled";
    if (t.status === "needs") return "needs";
    if (t.state === "awaiting-input") return "stalled"; // at a prompt in its terminal, for the XO
    if (t.status === "waiting") return "waiting";
    if (t.status === "review" || t.status === "done") return "review";
    return "working";
  }
  // an agent as its terminal reports it (an XO, a person's own session): at rest it waits on someone
  function agentState(a) { return { working: "working", blocked: "needs", error: "stalled" }[a.state] || (a.state ? "waiting" : "other"); }
  // chartroom's own workers, for information; an hc that cannot tell the crew apart: every agent
  function crewOf(m) { return m.crew_live != null ? m.crew_live : m.agents_live || 0; }
  // How near its limits a machine is: the greater of its CPU and its memory in use over their limits,
  // 1 at a limit, where it takes no new task. Null without limits, or with either use not known.
  function fullness(m) {
    const b = m.budgets || {};
    return b.cpu && b.mem && m.cpu_use != null && m.mem_used_pct != null ? Math.max(m.cpu_use / b.cpu, m.mem_used_pct / b.mem) : null;
  }
  function stale(t, now) { return !!t.last_at && now - Date.parse(t.last_at) > REST_DAYS * 86400e3; }

  // Each machine's tasks, its open sessions (those at rest apart) and its other agents by name. What a
  // machine only counts (a probe that does not name them yet) is a number: crew, others.
  function fleetMap(fleet, tasks, nowMs) {
    const now = nowMs == null ? Date.now() : nowMs;
    const ms = (fleet && fleet.machines) || [], brain = ms.find((m) => m.brain) || ms[0], out = {};
    for (const m of ms) out[m.name] = { tasks: [], sessions: [], rest: [], agents: [], crew: 0, others: 0 };
    const named = {}, mine = {};
    for (const m of ms) for (const a of m.agents || []) if (a.kind === "crew" && a.name) named[a.name] = a;
    for (const t of tasks) {
      if (t.type !== "task" || t.status === "closed") continue;
      // its own machine, by name or a device's alias; one Fleet does not list runs on the brain
      const m = ms.find((x) => x.name === t.machine || (x.device && (x.device.aliases || []).includes(t.machine))) || brain;
      if (!m) continue;
      const o = out[m.name];
      o.tasks.push(t);
      if (!OPEN_LIVE.includes(t.live)) continue;
      let state = fleetState(t);
      // its agent ended its turn on an error (a spend limit, a dropped network): it moves nothing
      const err = !!named[t.task] && named[t.task].state === "error" && (state === "working" || state === "waiting");
      if (err) state = "stalled";
      (stale(t, now) && t.live !== "working" ? o.rest : o.sessions).push({ id: t.key, state, task: t, error: err || undefined });
      mine[t.task] = true;
    }
    for (const m of ms) {
      const o = out[m.name], list = m.agents || [];
      const by = (a, b) => rank(a.state) - rank(b.state) || (a.id < b.id ? -1 : 1);
      o.sessions.sort(by); o.rest.sort(by);
      for (const a of list) {
        // a crew worker is its task's session; one of no open task here is shown as its own
        if (a.kind === "crew" && mine[a.name]) continue;
        const t = a.kind === "crew" ? tasks.find((x) => x.type === "task" && x.task === a.name) : null;
        o.agents.push({ id: "a:" + a.address, state: t && t.status !== "closed" ? fleetState(t) : agentState(a), kind: a.kind, name: a.name || a.where || null, where: a.where || null, task: t || undefined });
      }
      o.agents.sort(by);
      const n = list.filter((a) => a.kind === "crew").length;
      const seen = o.sessions.length + o.rest.length;
      o.crew = m.crew_live == null ? 0 : Math.max(0, m.crew_live - (n || seen));
      // (an hc that cannot tell the crew apart: what its tasks do not account for)
      o.others = Math.max(0, m.crew_live == null ? (m.agents_live || 0) - seen : (m.other_agents || 0) - (list.length - n));
    }
    return out;
  }
  function agentLabel(a) {
    return a.kind === "xo" ? (a.name ? "XO of " + a.name : "An XO") : a.kind === "crew" ? a.name || "A crew worker" : a.name || "An agent";
  }

  // A machine's meters, 0-100: what is used, its limit as a tick, and a word when it matters. CPU and
  // memory are the measures placement goes by (the CPU time spent busy over the last minute, and the
  // memory in use), each against the machine's own limit. Load and workers are for information.
  function fleetMeters(m) {
    const b = m.budgets || {}, out = [], crew = crewOf(m), load = m.load && m.load[0] != null && m.cores ? m.load[0] : null;
    const add = (id, label, used, text, o) => {
      const x = o || {};
      const lvl = used == null ? null : x.bad != null && used >= x.bad ? "bad" : x.warn != null && used >= x.warn ? "warn" : null;
      out.push({ id, label, used, text, tick: x.tick || null, tickText: x.tickText || null, level: lvl, word: lvl ? (x.words || ["high", "very high"])[lvl === "bad" ? 1 : 0] : null });
    };
    const limit = (n) => (n ? "limit " + n + "%: at it, no new task" : null), at = ["at its limit", "at its limit"];
    add("cpu", "CPU", m.cpu_use, m.cpu_use == null ? "not measured there yet" : m.cpu_use + "% in use", { tick: b.cpu, tickText: limit(b.cpu), warn: b.cpu || 85, words: b.cpu ? at : undefined });
    add("mem", "Memory", m.mem_used_pct, m.mem_used_pct == null ? "not measured there yet" : m.mem_used_pct + "% in use", { tick: b.mem, tickText: limit(b.mem), warn: b.mem || 85, words: b.mem ? at : undefined });
    add("load", "Load", load == null ? null : 100 * load / m.cores, load == null ? "not read" : load.toFixed(1) + " on " + m.cores + " cores", {});
    const disk = m.disk_free_pct == null ? null : 100 - m.disk_free_pct;
    add("disk", "Disk", disk, disk == null ? "not read" : m.disk_free_pct + "% free", { tick: 85, tickText: "flagged under 15% free", warn: 80, bad: 85.01, words: ["low", "very low"] });
    add("workers", "Workers", null, String(crew), {});
    return out;
  }

  // What is wrong on a machine, worst first: {level: bad|warn|old, text, sub, cmd, tasks}.
  const SIGN_IN = { "claude sign-in": "claude /login", "codex sign-in": "codex login", "gh sign-in": "gh auth login" };
  function fleetProblems(m, o, nowMs) {
    const now = nowMs == null ? Date.now() : nowMs, out = [], b = m.budgets || {};
    if (m.state === "down") out.push({ level: "bad", text: "Offline: " + (m.error || "not reached"), sub: m.device && m.device.seen_age_s != null ? "last heartbeat " + ageText(m.device.seen_age_s) + " ago" : null });
    for (const f of m.failing || []) {
      const c = (m.logins || []).concat(m.tools || []).find((x) => x.label === f);
      out.push({ level: "bad", text: /sign-in$/.test(f) ? f + " failed" : c ? f + " is not working" : f[0].toUpperCase() + f.slice(1), sub: c && c.detail, cmd: SIGN_IN[f] || null });
    }
    for (const c of (m.extra || []).filter((x) => x.ok === false)) out.push({ level: "warn", text: c.label + " is not working", sub: c.detail });
    for (const c of (m.logins || []).filter((x) => x.ok === null)) out.push({ level: "warn", text: c.label + " cannot be told", sub: c.detail });
    if (m.power === "battery") out.push({ level: "warn", text: "On battery" + (m.battery_pct != null ? ", " + m.battery_pct + "%" : ""), sub: b.on_battery === "pause" ? "new work pauses here" : null });
    const f = fullness(m);
    if (f != null && f >= 1) out.push({ level: "warn", text: "Takes no new work: " + [["CPU", m.cpu_use, b.cpu], ["memory", m.mem_used_pct, b.mem]].filter((x) => x[1] >= x[2])
      .map((x) => x[0] + " " + x[1] + "% of its " + x[2] + "% limit").join(", ") });
    const fresh = o.tasks.filter((t) => !stale(t, now));
    const group = (level, n, one, many, list) => { if (list.length) out.push({ level, id: n, text: list.length + " " + (list.length === 1 ? one : many), tasks: list }); };
    group("bad", "failed", "failed task", "failed tasks", fresh.filter((t) => t.state === "failed"));
    group("bad", "silent", "stopped without reporting", "stopped without reporting", fresh.filter((t) => t.state === "stopped-silent" || (t.live === "gone" && t.status === "working" && t.state !== "failed")));
    group("bad", "error", "agent ended on an error", "agents ended on an error", o.sessions.filter((s) => s.error).map((s) => s.task));
    group("warn", "overdue", "waiting past its time", "waiting past their time", fresh.filter((t) => t.state === "waiting-overdue"));
    group("warn", "prompt", "at a prompt in a terminal", "at a prompt in a terminal", fresh.filter((t) => t.state === "awaiting-input"));
    for (const a of o.agents.filter((x) => x.state === "stalled")) out.push({ level: "warn", text: agentLabel(a) + " ended on an error", sub: a.where });
    group("old", "old", "more stalled, untouched for " + REST_DAYS + " days", "more stalled, untouched for " + REST_DAYS + " days", o.tasks.filter((t) => stale(t, now) && fleetState(t) === "stalled"));
    const worst = { bad: 0, warn: 1, old: 2 };
    return out.sort((x, y) => worst[x.level] - worst[y.level]);
  }
  function ageText(s) { return s == null ? "" : s < 60 ? s + "s" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d"; }

  // Initiatives (slice 4): every home's, each with its home and hue.
  function initiatives(state) {
    const out = [];
    ((state && state.homes) || []).forEach((h, i) => {
      for (const ini of (h.snapshot && h.snapshot.initiatives) || []) out.push(Object.assign({}, ini, { home: h.name, hue: (i % 5) + 1, key: h.name + ":" + ini.id }));
    });
    return out;
  }
  // An initiative's milestones with their stories and progress, in order; stories in none come last.
  // The current milestone is the first not finished: open; finished ones fold.
  function milestones(ini) {
    const live = (ini.stories || []).filter((s) => s.state !== "dropped" && s.state !== "proposed");
    const groups = (ini.milestones || []).map((m) => ({ id: m.id, name: m.name, target: m.target, stories: live.filter((s) => s.milestone === m.id) }));
    const loose = live.filter((s) => !s.milestone || !groups.some((g) => g.id === s.milestone));
    if (loose.length) groups.push({ id: null, name: groups.length ? "Not in a milestone" : "Stories", target: null, stories: loose });
    let current = null;
    for (const g of groups) {
      g.done = g.stories.filter((s) => s.status === "done").length;
      g.total = g.stories.length;
      g.finished = g.total > 0 && g.done === g.total;
      if (!current && !g.finished) current = g.id || "loose";
    }
    for (const g of groups) g.current = (g.id || "loose") === current;
    return groups;
  }

  // Text with its links: [{text}] and [{href, label}] parts, in order. Any http(s) URL is a link
  // (trailing punctuation stays text); a GitHub PR or issue reads "repo#123", its URL behind it.
  const URL_RE = /https?:\/\/[^\s<>"'`]+/g;
  function linkParts(text) {
    const s = String(text == null ? "" : text), out = [];
    let at = 0, m;
    URL_RE.lastIndex = 0;
    while ((m = URL_RE.exec(s))) {
      let url = m[0];
      // a sentence's own punctuation, or a closing bracket the URL did not open, is not the URL's
      while (/[.,;:!?)\]}]$/.test(url)) {
        const last = url[url.length - 1];
        if ((last === ")" && (url.match(/\(/g) || []).length >= (url.match(/\)/g) || []).length)) break;
        url = url.slice(0, -1);
      }
      if (m.index > at) out.push({ text: s.slice(at, m.index) });
      const gh = /^https:\/\/github\.com\/[^/]+\/([^/]+)\/(pull|issues)\/(\d+)(?:[/?#].*)?$/.exec(url)
        || /^https:\/\/[^/]+\/(?:[^/]+\/)*_git\/([^/?#]+)\/(pullrequest)\/(\d+)(?:[/?#].*)?$/.exec(url); // Azure DevOps
      out.push({ href: url, label: gh ? gh[1] + "#" + gh[3] : url });
      at = m.index + url.length;
      URL_RE.lastIndex = at;
    }
    if (at < s.length) out.push({ text: s.slice(at) });
    return out;
  }

  // Bulk actions over selected items: which chartroom action each item gets, and which it skips
  // (and why). verb: done | accept | close | snooze. "Done" means what it means for that item:
  // an inbox question or a draft is marked done, a finished task is accepted; a question still
  // waiting for an answer is never "done" without one. Close is chartroom close: it never discards
  // work, and a task with work it cannot keep refuses on its own, item by item.
  function bulkPlan(items, verb, extra) {
    const run = [], skip = [];
    for (const it of items) {
      let a = null, why = null;
      if (verb === "done") {
        if ((it.kind === "inbox" || it.kind === "artifact") && it.ref) a = ["done", { ref: it.ref }];
        else if (it.kind === "review" && it.task) a = ["accept", { task: it.task }];
        else why = "it waits for an answer";
      } else if (verb === "accept") {
        if (it.kind === "review" && it.task) a = ["accept", { task: it.task }];
        else why = "only a finished task is accepted";
      } else if (verb === "close") {
        if (it.type === "task" && it.task) a = ["close", { task: it.task }];
        else why = "it is not a task";
      } else if (verb === "snooze") {
        if (it.ref) a = ["snooze", Object.assign({ ref: it.ref }, extra || {})];
        else why = "it cannot be snoozed";
      }
      if (a) run.push({ item: it, action: a[0], body: a[1] }); else skip.push({ item: it, why });
    }
    return { run, skip };
  }

  // The keys from one row to another, inclusive, in list order (shift-click, Shift+J/K).
  function range(list, fromKey, toKey) {
    const i = list.findIndex((x) => x.key === fromKey), j = list.findIndex((x) => x.key === toKey);
    if (i < 0 || j < 0) return j >= 0 ? [toKey] : [];
    const [a, b] = i <= j ? [i, j] : [j, i];
    return list.slice(a, b + 1).map((x) => x.key);
  }

  // Palette entries for a query: commands first, then items, best match first.
  function search(entries, q) {
    const s = String(q || "").trim().toLowerCase();
    if (!s) return entries.slice(0, 30);
    const words = s.split(/\s+/);
    return entries.map((e) => {
      const hay = (e.label + " " + (e.sub || "")).toLowerCase();
      if (!words.every((w) => hay.includes(w))) return null;
      return { e, rank: (hay.startsWith(s) ? 0 : 1) + (e.label.toLowerCase().includes(s) ? 0 : 1) };
    }).filter(Boolean).sort((a, b) => a.rank - b.rank).map((x) => x.e).slice(0, 30);
  }

  // Local notifications (slice 6). prev: {seen: the keys known, read: the homes read before}, or
  // null the first time. -> {fresh: the items to announce, next: the new prev}. Only an item of a
  // home read before is announced: a home's first read (the page opening, a home added) is only
  // remembered. A key of a home not read this time is kept, so a home that failed a read and
  // comes back does not announce its items again.
  const SEEN_MAX = 600;
  function freshItems(prev, all, readHomes) {
    const read = new Set(readHomes || []);
    const open = all.filter((it) => read.has(it.home) && standing(it) === "open");
    const keys = open.map((it) => it.key);
    const known = new Set((prev && prev.seen) || []);
    const before = new Set((prev && prev.read) || []);
    const fresh = open.filter((it) => before.has(it.home) && !known.has(it.key));
    const kept = [...known].filter((k) => !read.has(k.split(":")[0]));
    return { fresh, next: { seen: kept.concat(keys).slice(-SEEN_MAX), read: [...new Set([...before, ...read])] } };
  }
  // Where a notification's tap lands (#/n/<key>): the item's own page. A task's item opens the task
  // (its question is the banner there), a round its round page, stories their initiative, a sign-in
  // its machine. A permission card or a question of no task has no page of its own: Needs me, that
  // card open. An item no longer open still opens its task when the key names one (gone: true).
  // -> {hash, select?, gone?}
  function noticeTarget(all, key, state) {
    const enc = encodeURIComponent;
    const it = all.find((x) => x.key === key);
    if (it) {
      if (it.kind === "round" && it.card) return { hash: "#/q/" + enc(it.home) + "/" + enc(it.card) };
      if (it.kind === "stories" && it.initiative) return { hash: "#/i/" + enc(it.home) + "/" + enc(it.initiative) };
      if (it.kind === "login" && it.machine) return { hash: "#/fleet/" + enc(it.machine) };
      if (it.kind !== "permission" && it.task) return { hash: "#/t/" + enc(it.home) + "/" + enc(it.task) };
      return { hash: "#/", select: it.key };
    }
    const i = String(key).indexOf(":");
    const home = i > 0 ? key.slice(0, i) : "", id = i > 0 ? key.slice(i + 1) : "";
    const h = ((state && state.homes) || []).find((x) => x.name === home);
    const t = ((h && h.snapshot && h.snapshot.tasks) || []).find((x) => x.id === id || id.startsWith("ev-" + x.id + "-"));
    return t ? { hash: "#/t/" + enc(home) + "/" + enc(t.id), gone: true } : { hash: "#/", gone: true };
  }

  // One notification: the item's key as its tag (the push of the same item replaces it), and a link
  // that opens Needs me on it.
  function notice(it) {
    if (it.kind === "permission") {
      return { title: ("Allow " + (it.desc || "a call") + "?").slice(0, 100), body: (it.home + " · " + it.title).slice(0, 180),
        tag: it.key, url: "/#/n/" + encodeURIComponent(it.key) };
    }
    const g = (GROUPS.find((x) => x.id === it.group) || {}).label || "Needs you";
    // the body says what the title does not: never the same words again
    const v = it.view;
    const rest = v ? (v.lead || (v.list && v.list.length ? v.list.join(" · ") : v.more) || "") : it.summary || "";
    return { title: String((v && v.title) || it.title || "Chartroom").slice(0, 100), body: (it.home + " · " + g + (rest ? ": " + rest : "")).slice(0, 180),
      tag: it.key, url: "/#/n/" + encodeURIComponent(it.key) };
  }

  // ---- Plain words (the commander, 2026-11-21: cards "feel way too computer generated") ----
  // The real fix is the writers (skills/chartroom/SKILL.md, "Writing for the app", and the brief's
  // worker protocol). This only tidies, for display, what still reads machine-written: chartroom's
  // own ids and paths out, an event's kind word off the front, the title never repeated as the
  // body, several questions or steps as a list. What is sent back (an answer's question words, a
  // card or ref) is never this text.

  // Every task's id and short id, across homes: in a card's text they are chartroom's, not the reader's.
  function taskIds(state) {
    const s = new Set();
    for (const h of (state && state.homes) || []) {
      for (const t of (h.snapshot && h.snapshot.tasks) || []) { if (t.id) s.add(t.id); if (t.short_id) s.add(t.short_id); }
    }
    return s;
  }

  const ID_TOKEN = /\b(?:i|q|p|r|cm|rq|st|ms|in)-[0-9a-f]{4,}\b|\bev-[a-z0-9-]+-\d+\b|\bQ\d{2,}\b/g;
  // A path on this machine, or one inside a home: never something the reader opens by its path.
  const PATH = /(?:~\/|\/(?:Users|home|private|tmp|var|opt)\/)[^\s'"`<>),;]*|\btasks\/[\w.-]+(?:\/[^\s'"`<>),;]*)?/g;
  function pathWords(p) {
    const clean = p.replace(/[.:]+$/, "");
    const tail = clean.replace(/\/+$/, "").split("/").pop() || clean;
    if (/^report\.md$/i.test(tail)) return "the report";
    if (/^plan\.md$/i.test(tail)) return "the plan";
    if (/^brief\.md$/i.test(tail)) return "the brief";
    return /^tasks$/.test(tail) || /\/tasks\/[\w.-]+$/.test(clean) ? "the task's folder" : tail;
  }
  function plain(text, ids, project) {
    let s = askText(text);
    s = s.replace(/^(?:done|decision|blocked|failed|progress|waiting|review|awaiting-input|note):\s*/i, "");
    // a leading "<project>:" says what the card's project tag already says
    if (project) s = s.replace(new RegExp("^" + String(project).replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ":\\s+", "i"), "");
    s = s.replace(/\s*\((?:see )?pages? [^()]*\)/gi, "").replace(/\s*\(carried[^()]*\)/gi, "");
    s = s.replace(PATH, (p) => { const end = /[.:]$/.exec(p); return pathWords(p) + (end ? end[0] : ""); });
    s = s.replace(ID_TOKEN, "");
    if (ids && ids.size) {
      // a task's short id or full id as a word (a ref "c1e7/slug" goes with it)
      s = s.replace(/\b[0-9a-z-]*[0-9a-f]{4}(?:\/[\w.-]+)?\b/g, (w) => (ids.has(w.split("/")[0]) ? "" : w));
    }
    // "Report: the report" says nothing once the path is gone
    s = s.replace(/\b(?:Report|Plan|Details):\s*the (?:report|plan)\b\s*[.;,]?\s*/g, "");
    s = s.replace(/\(\s*[,;:]?\s*\)/g, "").replace(/\(\s*[,;]\s*/g, "(").replace(/\s*[,;]\s*\)/g, ")")
      .replace(/\s+([,;:.?!)])/g, "$1").replace(/\(\s+/g, "(").replace(/([,;:])(?=[,;:])/g, "").replace(/\s{2,}/g, " ").trim()
      .replace(/^[,;:.\-–—\s]+/, "");
    // a sentence starts with a capital; a lowercase name or ref ("mcp:", "shop#12") stays as written
    return /^[a-z]+(?:\s|$)/.test(s) ? s[0].toUpperCase() + s.slice(1) : s;
  }

  // Sentences, without breaking after an abbreviation, a number's point or a domain's dot.
  function sentences(text) {
    const out = [];
    let cur = "";
    for (const part of String(text).split(/(?<=[.?!])\s+(?=["'(A-Z0-9])/)) {
      cur = cur ? cur + " " + part : part;
      if (/\b(?:e\.g|i\.e|vs|etc|approx|incl|cf|no|Mr|Ms|Dr|St|v)\.$/i.test(cur)) continue;
      out.push(cur.trim()); cur = "";
    }
    if (cur.trim()) out.push(cur.trim());
    return out;
  }

  // "(1) a; (2) b" or "A) a; B) b" in one sentence: the text before it, and the steps. null when it
  // is not a run of numbered parts from the first.
  function steps(text) {
    for (const [re, first] of [[/\((\d{1,2})\)\s+/g, "1"], [/(?:^|\s)([A-H])\)\s+/g, "A"]]) {
      const marks = [...text.matchAll(re)];
      if (marks.length < 2 || marks[0][1] !== first) continue;
      const seq = marks.every((m, k) => m[1] === (first === "1" ? String(k + 1) : String.fromCharCode(65 + k)));
      if (!seq) continue;
      const items = marks.map((m, k) => text.slice(m.index + m[0].length, k + 1 < marks.length ? marks[k + 1].index : text.length)
        .replace(/^[\s,;]+|[\s,;]+$/g, "").replace(/\s*(?:,|;)?\s*(?:and|or)$/i, "").trim()).filter(Boolean);
      return { before: text.slice(0, marks[0].index).replace(/[\s,;:]+$/, "").trim(), items };
    }
    return null;
  }

  // "Also: a, b, c": each part a question of its own, when the parts are short; else one line.
  function alsoList(text) {
    const m = /^(.*?)\s*\bAlso:\s+(.+)$/i.exec(text);
    if (!m) return null;
    const rest = m[2].trim();
    const parts = rest.replace(/[.]$/, "").split(/,\s+(?:and\s+|or\s+)?/);
    const list = parts.length >= 2 && parts.length <= 6 && parts.every((p) => p.length <= 70) ? parts : [rest];
    return { before: m[1].trim(), items: list.map((p) => p[0].toUpperCase() + p.slice(1)) };
  }

  // One text as a card reads it: {lead, list, more}. lead: the first sentence, the one a person
  // would say first; list: several questions or steps, one a line; more: the rest, only when it
  // adds something.
  function shape(text, ids, project) {
    const t = plain(text, ids, project);
    const d = /\s*\bDetails?:\s*/.exec(t);
    const head = d ? t.slice(0, d.index) : t;
    const rest = d ? t.slice(d.index + d[0].length).trim() : "";
    const ss = sentences(head);
    let lead = ss.shift() || "";
    let list = [], intro = null;
    const more = [];
    const al = alsoList(lead);
    if (al && al.before) { lead = al.before; list = list.concat(al.items); intro = "Also"; }
    const st = steps(lead);
    if (st && st.before) { lead = st.before.replace(/[:]$/, "") + ":"; list = list.concat(st.items); }
    for (const s of ss) {
      const a = alsoList(s), p = steps(s);
      if (/\?$/.test(s)) { list.push(s); intro = intro || (list.length > 1 ? null : "Also"); }
      else if (a) { if (a.before) more.push(a.before); list = list.concat(a.items); intro = intro || "Also"; }
      // steps in a later sentence: that sentence's opening introduces them
      else if (p && list.length === 0) { list = list.concat(p.items); intro = p.before ? p.before.replace(/[:]$/, "") : null; }
      else more.push(s);
    }
    if (rest) more.push(rest);
    const same = (a, b) => norm(a) === norm(b);
    return { lead, intro: list.length ? intro : null, list: list.filter((x) => !same(x, lead)), more: more.filter((x) => x && !same(x, lead)).join(" ") || null };
  }
  function norm(s) { return String(s || "").toLowerCase().replace(/[…."'?!:\s]+/g, " ").trim(); }
  // Text that is cut ("…") or tidied still counts as the same words: the body never repeats the title.
  function repeats(title, text) {
    const a = norm(title), b = norm(text);
    if (!a || !b) return false;
    return a === b || b.startsWith(a) || a.startsWith(b);
  }

  // A done report that still asks the commander something: never accepted in bulk.
  const ASKS = /\?|\bneeds? (?:a |your )?(?:call|decision|answer|go|word|ok)\b|\bplease (?:confirm|decide|answer|check)\b|\bdecisions? (?:for|from) (?:you|the commander|[A-Z][a-z]+)\b|\bon (?:your|the commander's|[A-Z][a-z]+'s) (?:word|go)\b|\bawaits? (?:you|your|the commander)\b|\bNeed:/i;
  function asks(text) { return ASKS.test(String(text || "")); }

  // What a card shows, worked out once per state: {title, lead, list, more, asks}.
  function view(it, ids) {
    if (it.kind === "permission") return { title: plain(it.title, ids) || it.title, lead: null, list: [], more: null, asks: true };
    const own = it.type === "inbox" || it.type === "approval";
    if (own) {
      // an inbox line is all one text: its first sentence is the title, the rest the body
      const s = shape(it.text || it.summary || it.title, ids, it.project);
      return { title: s.lead || it.title, lead: null, intro: s.intro, list: s.list, more: s.more, asks: true };
    }
    const title = plain(it.title, ids, it.project) || it.title;
    if (it.kind === "review") {
      const s = shape(it.summary || "", ids, it.project);
      // a done line's clauses ("PR open; tests green; nothing merged"), one a line when there are several
      let lead = s.lead, list = s.list;
      const parts = lead.split(/;\s+/);
      let intro = s.intro;
      if (parts.length >= 3 && lead.length > 90) { lead = parts[0]; list = parts.slice(1).concat(list); intro = null; }
      // what a finished report still asks is said as such, not as "Also"
      if (list.length && list.every((x) => /\?$/.test(x))) intro = "It still asks";
      return { title, lead: lead || null, intro, list, more: s.more, asks: asks(it.summary) };
    }
    return { title, lead: null, list: [], more: null, asks: true };
  }

  // ---- The permission card in plain words ----
  // The broker's rule ("commander:<class>") and reason, said the way a person would.
  const LOGINS = { az: "Azure", gcloud: "Google Cloud", aws: "AWS", gh: "GitHub", op: "1Password", vault: "Vault",
    heroku: "Heroku", vercel: "Vercel", fly: "Fly", flyctl: "Fly", doctl: "DigitalOcean", stripe: "Stripe", kubectl: "Kubernetes",
    npm: "npm", docker: "Docker", firebase: "Firebase", wrangler: "Cloudflare" };
  function permitReason(it) {
    const rule = String(it.rule || ""), r = String(it.reason || "");
    const cls = rule.startsWith("commander:") ? rule.slice(10) : null;
    const head = (r.match(/^[\w-]+/) || [""])[0].replace(/-.*$/, "");
    const login = LOGINS[head];
    if (cls === "secrets") return login ? "it uses your " + login + " login" : r === "a secret's path" ? "it reads a secret" : "it uses a password, key or token";
    if (cls === "outward") {
      if (/^git-push/.test(r)) return "it pushes code to a shared repository";
      if (/^git-(remote|mail)/.test(r)) return r === "git-mail" ? "it sends email from git" : "it changes where git pushes to";
      if (/^gh[- ]pr/.test(r)) return "it changes a pull request on GitHub";
      if (/^gh /.test(r)) return "it changes something on GitHub";
      if (/^message/.test(r)) return "it sends a message" + (/\((\w+)\)/.test(r) ? " (" + r.match(/\((\w+)\)/)[1] + ")" : "");
      if (/^deploy/.test(r)) return "it deploys" + (/\((\w+)\)/.test(r) ? " with " + r.match(/\((\w+)\)/)[1] : "");
      if (/publish|docker push/.test(r)) return "it publishes a package or image";
      if (/^http write/.test(r)) return "it writes to a web service";
      if (/^az /.test(r)) return "it changes something in Azure";
      return "it reaches outside this machine";
    }
    if (cls === "production") return "it touches production";
    if (cls === "elsewhere") {
      if (/another machine/.test(r)) return "it works on another machine";
      if (/sudo/.test(r)) return "it runs as an administrator";
      return "it touches files outside its own folder";
    }
    if (cls === "controls") return "it changes its own permissions or settings";
    if (cls === "flags") return "it changes feature flags";
    if (cls === "money") return "it touches billing or payments";
    if (cls === "unlisted") return "chartroom has no rule for it yet";
    return r ? r.replace(/\s*\([^)]*:[^)]*\)\s*$/, "") : "chartroom's policy would not answer it";
  }
  // "Wants to use your Azure login to read who can approve deploys."
  function permitLead(it) {
    const why = String(it.why || "").trim().replace(/[.\s]+$/, "");
    const reason = permitReason(it);
    const login = /^it uses your (.+) login$/.exec(reason);
    // Claude's description is mostly an order ("Check the runs"): "Wants to check the runs". One that
    // starts with a name or a number ("CI logs for main") is said as it was written.
    const verb = /^[A-Z][a-z]+\b/.test(why) && !/^(?:The|A|An|This|That|These|Those|All|Some|Any|Each|Every|No|My|Our|Your|Its|Their)\b/.test(why);
    const lc = why && verb ? why[0].toLowerCase() + why.slice(1) : why;
    if (login) return lc ? (verb ? "Wants to use your " + login[1] + " login to " + lc + "." : "Uses your " + login[1] + " login: " + lc + ".") : "Wants to use your " + login[1] + " login.";
    if (lc) return verb ? "Wants to " + lc + "." : lc + ".";
    return it.tool === "Bash" ? "Wants to run a command that needs your OK." : "Wants to use " + (it.tool || "a tool") + ", which needs your OK.";
  }
  // What "Always for this task" covers, in a few words; never less than it allows.
  function permitScope(it) {
    const p = String(it.pattern || ""), cmd = it.command != null ? String(it.command) : null;
    if (!p) return "this call, until the task closes";
    if (/^sig:/.test(p) || (cmd != null && p === cmd)) return "this exact " + (it.tool === "Bash" ? "command" : "call") + ", until the task closes";
    const pre = /^(.+?):\*$/.exec(p);
    if (pre && pre[1].length <= 60) return { code: pre[1], text: "any command starting with", after: ", until the task closes" };
    if (/^[~/]/.test(p)) return { code: pathWords(p), text: "any change to", after: ", until the task closes" };
    return { code: p.length > 60 ? p.slice(0, 59) + "…" : p, text: "calls matching", after: ", until the task closes" };
  }
  // The call's first line that does something, for the collapsed view: a plain variable set to a
  // path, a `set -e` or a comment says nothing about what the call does.
  function firstLine(text) {
    const lines = String(text || "").split("\n").map((l) => l.trim()).filter(Boolean);
    const idle = (l) => /^#/.test(l) || /^set\s+[-+]/.test(l) || /^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=(?:"[^"$`]*"|'[^']*'|[^\s"'$`;|&]*)$/.test(l);
    const line = lines.find((l) => !idle(l)) || lines[0] || "";
    return { line, more: lines.length > 1 || line.length > 40 }; // a long line is cut in the card: it unfolds too
  }

  // Subscription usage (usage.js), from each home's snapshot `usage` (lib/usage.sh usage_rows_json:
  // that home's own readings, its own live workers). Every home keeps its own readings, so one agent
  // on one machine may be read in several homes: a live limit hit wins (a fresher "ok" elsewhere never
  // hides it), then the newest sample. The readings are then grouped as the CLI groups them: one row
  // per agent, split by machine only where the readings differ. Live workers are counted over every
  // home's open tasks, by the CLI's rule (dispatched, not closed, not review/done/failed).
  const USAGE_AGENTS = ["claude", "codex", "agy", "grok"];
  const USAGE_SKIP = ["review", "done", "closed", "failed"];
  function usageHit(r, now) { return !!r.hit_active && !(r.out_resets_at && Date.parse(r.out_resets_at) <= now); }
  function usageSig(r) {
    const w = (r.windows || []).map((x) => [x.label, x.used_pct == null ? -1 : x.used_pct, x.resets_at || ""].join("|")).sort();
    return JSON.stringify([r.status, r.state, r.plan || "", r.account || "", r.out_resets_at || "", w]);
  }
  function usageRows(state, nowMs) {
    const now = nowMs == null ? Date.now() : nowMs, best = {}, live = {};
    for (const h of (state && state.homes) || []) {
      const s = h.snapshot;
      if (!s) continue;
      for (const r of s.usage || []) {
        if (!r || !r.agent) continue;
        for (const m of r.machines && r.machines.length ? r.machines : [r.machine]) {
          const k = r.agent + "|" + m, rec = Object.assign({}, r, { machine: m }), cur = best[k];
          const hr = usageHit(rec, now), hc = cur && usageHit(cur, now);
          if (!cur || (hr && !hc) || (hr === hc && (Date.parse(rec.sampled_at || "") || 0) > (Date.parse(cur.sampled_at || "") || 0))) best[k] = rec;
        }
      }
      for (const t of s.tasks || []) {
        if (t.closed || !t.dispatched || USAGE_SKIP.includes(t.state)) continue;
        const b = String(t.backend || "").replace(/^herdr-/, "herdr:");
        if (!b.includes(":")) continue;
        const k = b.split(":").pop() + "|" + (t.machine || s.machine);
        live[k] = (live[k] || 0) + 1;
      }
    }
    const by = {};
    for (const r of Object.values(best)) (by[r.agent] = by[r.agent] || []).push(r);
    const rank = (a) => (USAGE_AGENTS.indexOf(a) + 1 || 99);
    const order = (a, b) => (a.local ? 0 : 1) - (b.local ? 0 : 1) || (a.machine < b.machine ? -1 : a.machine > b.machine ? 1 : 0);
    const out = [];
    for (const agent of Object.keys(by)) {
      const g = by[agent].sort(order);
      const split = new Set(g.map(usageSig)).size > 1;
      const rows = split ? g.map((r) => Object.assign({}, r, { machines: [r.machine], per_machine: true }))
        : [Object.assign({}, g[0], { machines: g.map((r) => r.machine), per_machine: false })];
      for (const r of rows) out.push(Object.assign(r, { live_workers: r.machines.reduce((n, m) => n + (live[agent + "|" + m] || 0), 0) }));
    }
    return out.sort((a, b) => rank(a.agent) - rank(b.agent) || order(a, b));
  }
  // "in 3d 4h", "in 2h 5m", "in 12m": how long until <iso>; "now" once it has passed.
  function untilText(iso, nowMs) {
    const t = Date.parse(iso || "");
    if (!isFinite(t)) return "";
    const s = Math.round((t - (nowMs == null ? Date.now() : nowMs)) / 1000);
    if (s <= 0) return "now";
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    return "in " + (d ? d + "d" + (h ? " " + h + "h" : "") : h ? h + "h" + (m ? " " + m + "m" : "") : Math.max(1, m) + "m");
  }
  function pctText(v) { return v == null ? "—" : (Number.isInteger(v) ? String(v) : v.toFixed(1).replace(/\.0$/, "")) + "%"; }
  // One row as the page shows it. A model-only window (scoped: Claude's Opus or Sonnet week) is for
  // information: it never reads as out or near, whatever its own state says; the row's state (the
  // CLI's, which leaves those windows out) is what marks the agent.
  const USAGE_STATE = { out: "Out", near: "Near its limit", ok: "Within limits", unknown: "Not known" };
  function usageView(r, nowMs) {
    const now = nowMs == null ? Date.now() : nowMs, st = USAGE_STATE[r.state] ? r.state : "unknown";
    const where = r.per_machine ? r.machine : r.machines && r.machines.length > 1 ? (r.machines.length > 3 ? r.machines.length + " machines" : r.machines.join(", ")) : r.machine || "";
    const windows = (r.windows || []).map((w) => {
      const scoped = !!w.scoped, used = w.used_pct == null ? null : Math.max(0, Math.min(100, w.used_pct));
      const reset = w.reset_passed ? "reset; waiting for a new reading"
        : w.resets_at ? "resets " + untilText(w.resets_at, now)
        : w.active === false ? "not started" : "reset not known";
      return { id: w.id || w.label, label: w.label || w.id || "limit", scoped, used, usedText: pctText(w.used_pct) + " used", leftText: pctText(w.left_pct) + " left",
        level: scoped ? "info" : ["out", "near"].includes(w.state) ? w.state : "ok", reset, resetsAt: w.resets_at || null };
    });
    let note = null;
    if (r.hit_active && usageHit(r, now)) note = "A worker hit the limit" + (r.out_resets_at ? "; it resets " + untilText(r.out_resets_at, now) : "");
    else if (st === "out" && r.limit_reached && !windows.some((w) => w.level === "out")) note = r.agent + " allows no more use for now" + (r.out_resets_at ? "; it resets " + untilText(r.out_resets_at, now) : "");
    else if (st === "unknown") note = r.reason || "no usage reading yet";
    const sampled = Date.parse(r.sampled_at || "");
    const age = isFinite(sampled) ? ageText(Math.max(0, Math.round((now - sampled) / 1000))) : null;
    return { key: r.agent + "|" + (r.per_machine ? r.machine : (r.machines || []).join(",")), agent: r.agent, state: st, stateText: USAGE_STATE[st], where,
      plan: [r.plan, r.account].filter(Boolean).join(" · "), windows, note, live: r.live_workers || 0,
      age: age == null ? "no reading yet" : "read " + age + " ago", stale: !!r.stale, sampledAt: r.sampled_at || null };
  }
  // Fleet's line about usage: which agents are out or near, else that all are within their limits.
  function usageSummary(rows) {
    const name = (r) => (r.per_machine ? r.agent + " on " + r.machine : r.agent);
    const out = rows.filter((r) => r.state === "out").map(name), near = rows.filter((r) => r.state === "near").map(name);
    const parts = [];
    if (out.length) parts.push(out.join(", ") + " out");
    if (near.length) parts.push(near.join(", ") + " near the limit");
    return { level: out.length ? "out" : near.length ? "near" : "ok", text: parts.length ? parts.join("; ") : rows.length ? "Every agent is within its limits" : "No usage reading yet" };
  }

  // The page runs older code than the server now serves: "page" is what its own HTML said it is, the
  // state's is what is installed. Not told by the service worker's last copy, nor by an older server.
  function pageStale(own, state) {
    return !!(own && state && state.page && !state.offline && state.page !== own);
  }

  return { KINDS, GROUPS, STATUS, kind, items, homes, plain, shape, repeats, asks, view, taskIds,
    permitReason, permitLead, permitScope, firstLine, standing, visible, ordered, counts, projects, questions, details,
    primary, answerBody, answered, move, ago, agoText, snoozes, search, askText, headline, bulkPlan, range, promote, linkParts, BOARD, boardItems, boardFilter, boardColumns, initiatives, milestones,
    freshItems, notice, noticeTarget, permitLeft, pageStale,
    FLEET_STATES, REST_DAYS, SIGN_IN, fleetState, fleetMap, fleetMeters, fleetProblems, fullness, crewOf, agentLabel, ageText,
    usageRows, usageView, usageSummary, untilText };
})();
if (typeof module !== "undefined" && module.exports) module.exports = AppModel;
