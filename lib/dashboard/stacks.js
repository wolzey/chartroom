// stacks.js - the radar's grouping and its archive (radar.html; spliced in by the server like
// eventfmt.js; test/js/stacks.test.js runs it under node). Pure functions of the radar's records.
//
// Related tasks stand in one stack: one robot with the others in a row behind it and a count,
// fanned out on a click. Two tasks are related when they share
//   a ticket key   ENG-2752, GH-9869: from the title, the id's slug or the branch;
//   a family       one's brief or events name the other's id (a handoff, a follow-up: the CLI's
//                  `mentions`), one was cut from the other's branch, or both from one feature branch;
//   a series       the same project and the same title once a trailing number is dropped
//                  ("QA dashboard T1", "... T2"), or the very same title.
// Relations chain (A~B and B~C stack all three). A stack sits in the sector of its most urgent
// member and wears that member's state. The result depends only on the set of records, never on
// their order: a ship keeps its stack from poll to poll.
var Stacks = (function () {
  "use strict";

  // most urgent first: what needs the commander, then what may, then what runs, then what is done
  const SECTOR_URGENCY = { decision: 0, blocked: 1, adrift: 2, holding: 3, underway: 4, docked: 5 };
  const STATE_URGENCY = { decision: 0, blocked: 1, "awaiting-input": 2, lost: 3, overdue: 4, "stopped-silent": 5, unknown: 6,
    waiting: 7, working: 8, failed: 9, review: 10, done: 11 };
  const MAINLINE = /^(?:(?:origin|upstream)\/)?(?:main|master|trunk|develop|development|HEAD)$/;
  const NOT_TICKET = /^(?:UTF|SHA|ISO|AES|RSA|TLS|SSL|HTTP|HTTPS|IPV|MD|PR|V|X|Q|H)$/;
  const SESSION_GONE = new Set(["gone", "stopped", "done", "exited", "dead"]);

  function ms(iso) { const t = iso ? Date.parse(iso) : NaN; return isNaN(t) ? null : t; }
  function lastAt(r) { return ms(r.last_activity_at) || ms(r.dispatched) || ms(r.created); }

  // Ticket keys, upper-cased: written as KEY-123 in a title or branch, or leading a slug (eng-61-...).
  function tickets(r) {
    const out = new Set();
    const add = (k, n) => { if (!NOT_TICKET.test(k)) out.add(k + "-" + n); };
    for (const s of [r.title, r.branch]) for (const m of String(s || "").matchAll(/\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b/g)) add(m[1], m[2]);
    for (const s of [r.id, String(r.branch || "").replace(/^.*\//, "")]) {
      const m = /^([a-z][a-z0-9]{1,9})-(\d{2,6})(?:-|$)/.exec(String(s || ""));
      if (m && !/\d/.test(m[1])) add(m[1].toUpperCase(), m[2]);
    }
    return [...out].sort();
  }

  // A title without its trailing number: "QA dashboard T2" -> "qa dashboard". {stem, numbered}.
  function stem(title) {
    let s = String(title || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(), numbered = false;
    const tail = /\s+(?:(?:t|pt|part|phase|step|stage|wave|w|batch|round|r|pr|v|no|n|item|slice|chunk)\s*)?\d{1,3}[a-z]?(?:\s+(?:of\s+)?\d{1,3})?$/;
    for (let k = 0; k < 2 && tail.test(s); k++) { s = s.replace(tail, ""); numbered = true; }
    return { stem: s, numbered };
  }
  function seriesKey(r) {
    if (!r.project) return null;
    const { stem: st } = stem(r.title || r.id);
    const words = st.split(" ").filter(Boolean);
    if (words.length < 2 || st.length < 6) return null;
    return r.project + "\u0000" + st;
  }

  function urgency(a, b) {
    return (SECTOR_URGENCY[a.sector] ?? 9) - (SECTOR_URGENCY[b.sector] ?? 9) ||
      (STATE_URGENCY[a.state] ?? 20) - (STATE_URGENCY[b.state] ?? 20) ||
      (b.breaking ? 1 : 0) - (a.breaking ? 1 : 0) ||
      (lastAt(b) || 0) - (lastAt(a) || 0) ||
      (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  }

  // records -> units: each one record ({kind: "agent", rec}) or a stack ({kind: "stack", key,
  // members (most urgent first), lead, reasons, sector, state}). Units come in key order.
  function group(records) {
    const recs = [...records].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
    const parent = recs.map((_, i) => i);
    const find = (i) => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
    const reasons = recs.map(() => new Set());
    const join = (i, j, reason) => {
      reasons[i].add(reason); reasons[j].add(reason);
      const a = find(i), b = find(j);
      if (a !== b) parent[Math.max(a, b)] = Math.min(a, b);
    };
    const bucket = (keyOf, reasonOf) => {
      const by = new Map();
      recs.forEach((r, i) => { for (const k of [].concat(keyOf(r) || [])) { if (!by.has(k)) by.set(k, []); by.get(k).push(i); } });
      for (const [k, ix] of by) for (let n = 1; n < ix.length; n++) join(ix[0], ix[n], reasonOf(k));
    };
    bucket(tickets, (k) => k);
    bucket(seriesKey, () => "series");
    // family: mentions, and branches cut from one another or from one feature branch
    const byId = new Map(recs.map((r, i) => [(r.machine || "") + "\u0000" + (r.home || "") + "\u0000" + r.id, i]));
    recs.forEach((r, i) => {
      for (const m of r.mentions || []) {
        const j = byId.get((r.machine || "") + "\u0000" + (r.home || "") + "\u0000" + m);
        if (j != null && j !== i) join(i, j, "follow-up");
      }
    });
    bucket((r) => r.branch && !MAINLINE.test(r.branch) ? [(r.machine || "") + "\u0000" + r.branch] : null, () => "family");
    recs.forEach((r, i) => {
      if (!r.base || MAINLINE.test(r.base)) return;
      recs.forEach((o, j) => { if (j !== i && o.branch === r.base && (o.machine || "") === (r.machine || "")) join(i, j, "family"); });
    });
    bucket((r) => r.base && !MAINLINE.test(r.base) ? [(r.machine || "") + "\u0000base:" + r.base] : null, () => "family");
    const groups = new Map();
    recs.forEach((r, i) => { const g = find(i); if (!groups.has(g)) groups.set(g, []); groups.get(g).push(i); });
    const units = [];
    for (const ix of groups.values()) {
      if (ix.length === 1) { units.push({ kind: "agent", key: recs[ix[0]].key, rec: recs[ix[0]] }); continue; }
      const members = ix.map((i) => recs[i]).sort(urgency);
      const rs = new Set(); for (const i of ix) for (const x of reasons[i]) rs.add(x);
      const lead = members[0];
      units.push({ kind: "stack", key: "stack:" + recs[ix[0]].key, members, lead, reasons: [...rs].sort(),
        sector: lead.sector, state: lead.state, machine: lead.machine, breaking: members.some((m) => m.breaking),
        last_activity_at: members.map((m) => m.last_activity_at).filter(Boolean).sort().pop() || null,
        stale: members.every((m) => m.stale) });
    }
    return units.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }

  // Why the "active only" view leaves a record out, or null to show it:
  //   "docked"  docked (review, done, failed) and quiet for settings.done_hours;
  //   "stale"   its session is gone and it has been quiet for settings.stale_days.
  // A breaking report is never archived.
  function archived(r, now, settings) {
    if (r.breaking || r.kind === "xo") return null;
    const t = lastAt(r);
    if (t == null) return null;
    const age = now - t, s = settings || {};
    if (r.sector === "docked" && age > (s.done_hours || 24) * 3600e3) return "docked";
    if (SESSION_GONE.has(r.live) && age > (s.stale_days || 3) * 86400e3) return "stale";
    return null;
  }

  return { group, tickets, stem, urgency, archived, SECTOR_URGENCY };
})();
if (typeof module !== "undefined" && module.exports) module.exports = Stacks;
