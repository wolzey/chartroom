// model.js - what the app shows, from the server's state: every home's Needs me items as one list,
// the filters and tabs over it, a card's options, and the keyboard's selection. Pure: no DOM, no
// fetch. The page loads it as a plain script (window.AppModel); test/js/app-model.test.js runs it
// under node. What an item *is* (its kind, group, whether it was answered) comes from the CLI's
// snapshot (lib/app/snapshot.jq); this file only arranges it.
var AppModel = (function () {
  "use strict";

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
    review: { label: "Review", glyph: "read" },
    artifact: { label: "To send", glyph: "tidy" },
  };
  const GROUPS = [
    { id: "decide", label: "Decide", hint: "Questions and choices waiting on you" },
    { id: "approve", label: "Approve", hint: "Plans ready for a yes" },
    { id: "unblock", label: "Unblock", hint: "Work that can't move without you" },
    { id: "read", label: "Read", hint: "Reports, PRs and drafts" },
  ];
  const STATUS = {
    drafting: "Drafting", queued: "Queued", working: "Working", waiting: "Waiting",
    needs: "Needs you", review: "Review", done: "Done", closed: "Closed",
  };

  function kind(k) { return KINDS[k] || { label: k || "Item", glyph: "read" }; }

  // Every home's items, each tagged with its home (and the home's hue, 1-5 in the order homes come).
  function items(state) {
    const out = [];
    ((state && state.homes) || []).forEach((h, i) => {
      const snap = h.snapshot;
      if (!snap || !Array.isArray(snap.needs)) return;
      for (const it of snap.needs) out.push(Object.assign({}, it, { home: h.name, hue: (i % 5) + 1, key: h.name + ":" + it.id }));
    });
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
    if (local && local[it.key]) return local[it.key];
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
  function ordered(list) {
    const rank = {}; GROUPS.forEach((g, i) => { rank[g.id] = i; });
    return list.slice().sort((a, b) =>
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
  // detail, rec}], free}]. A worker's ask is parsed by EventFmt (lib/dashboard/eventfmt.js), the
  // dashboard's own reader of "Options: (1) ... (2) ... RECOMMENDED"; an ask with no options is one
  // free-text question.
  function questions(it, EventFmt) {
    if (Array.isArray(it.questions)) {
      return it.questions.map((q) => ({ id: q.id, text: q.text, context: q.context || null, why: q.why || null,
        options: (q.options || []).map((o) => ({ label: o.label, detail: o.detail || null, rec: !!o.rec })), free: !(q.options || []).length }));
    }
    const text = it.text || it.summary || "";
    let parsed = null;
    if (EventFmt && it.type === "task") {
      try { parsed = EventFmt.parseEvent(it.kind === "decide" || it.kind === "approve" ? "decision" : it.kind, text); } catch (e) { parsed = null; }
    }
    const options = [];
    let lead = text;
    if (parsed) {
      lead = parsed.headline || text;
      for (const b of parsed.blocks || []) {
        for (const p of b.parts || []) {
          if (p.type !== "options") continue;
          for (const o of p.items) {
            // the mark is shown as a tag, so "per partner, recommended" reads "Per partner"
            const label = (o.title || o.text || "").replace(/[,;:]?\s*\(?(recommended|preferred)\)?\s*$/i, "").replace(/[.\s]+$/, "");
            if (label) options.push({ label, detail: o.title ? o.text || null : null, rec: !!o.recommended });
          }
        }
        if (options.length) break;
      }
    }
    return [{ id: 1, text: lead, context: null, why: null, options, free: options.length === 0 }];
  }

  // The parts of a worker's ask after its headline, as label + text pairs, for the quick view.
  function details(it, EventFmt) {
    if (!EventFmt || it.type !== "task" || !(it.text || it.summary)) return [];
    let parsed;
    try { parsed = EventFmt.parseEvent("decision", it.text || it.summary); } catch (e) { return []; }
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
  function primary(it, EventFmt) {
    if (it.kind === "round") return { type: "open-round" };
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
    const qs = Array.isArray(it.questions) ? it.questions.map((q) => q.id) : [1];
    return { card: it.card, answers: qs.map((id) => ({ q: id, choice: picks && picks[id] != null ? picks[id] : null,
      note: notes && notes[id] && notes[id].trim() ? notes[id].trim() : null })) };
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

  return { KINDS, GROUPS, STATUS, kind, items, homes, standing, visible, ordered, counts, projects, questions, details,
    primary, answerBody, answered, move, ago, agoText, snoozes, search };
})();
if (typeof module !== "undefined" && module.exports) module.exports = AppModel;
