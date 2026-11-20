// outbox.js - every action the commander takes, queued: the page shows it done at once, the outbox
// sends it in the background (retrying while the server cannot be reached), and the server's
// state says when the chartroom verb behind it ran, or why it failed. The page keeps the outbox in
// localStorage, so a reload, a closed laptop or a dropped tunnel loses nothing. Pure: no fetch, no
// storage; main.js does those. test/js/app-outbox.test.js runs it under node.
//
// An entry: {id, home, action, body, key, label, state, tries, next, at, error, sent_at}
//   state: queued (not yet accepted by the server) -> accepted (the server has it; its verb runs)
//          -> done | failed (the server said so; failed keeps the error and can be retried)
var Outbox = (function () {
  "use strict";

  const BACKOFF_MAX = 30000;
  const LOST_AFTER = 30000; // accepted, yet the server has never heard of it this long: send again
  const KEEP_DONE = 60000;

  function uid(now) {
    return "a-" + (now || Date.now()).toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  }

  function create(home, action, body, key, label, now) {
    const t = now || Date.now();
    return { id: uid(t), home, action, body, key: key || null, label: label || action, state: "queued", tries: 0,
      next: 0, at: t, error: null, sent_at: null };
  }

  function backoff(tries) { return Math.min(BACKOFF_MAX, 1000 * Math.pow(2, Math.max(0, tries - 1))); }

  // The entries to send now, oldest first.
  function due(entries, now) {
    return entries.filter((e) => e.state === "queued" && e.next <= now).sort((a, b) => a.at - b.at);
  }

  // After a POST: status 202 (accepted), 0 (no answer: offline, the tunnel down), 4xx (refused: never
  // retried by itself), or 5xx (retried).
  function posted(e, status, error, now) {
    if (status === 202 || status === 200) return Object.assign({}, e, { state: "accepted", sent_at: now, error: null });
    if (status >= 400 && status < 500) return Object.assign({}, e, { state: "failed", error: error || "refused (" + status + ")" });
    const tries = e.tries + 1;
    return Object.assign({}, e, { state: "queued", tries, next: now + backoff(tries), error: error || "the server did not answer; retrying" });
  }

  // The server's view of its actions ({id: {state, error}}): accepted entries become done or failed.
  function reconcile(entries, server, now) {
    return entries.map((e) => {
      if (e.state !== "accepted") return e;
      const s = server && server[e.id];
      if (s && s.state === "done") return Object.assign({}, e, { state: "done", done_at: now });
      if (s && s.state === "failed") return Object.assign({}, e, { state: "failed", error: s.error || "failed" });
      if (!s && now - (e.sent_at || 0) > LOST_AFTER) return Object.assign({}, e, { state: "queued", next: now });
      return e;
    });
  }

  function retry(e, now) { return Object.assign({}, e, { state: "queued", tries: 0, next: now, error: null }); }

  function prune(entries, now) {
    return entries.filter((e) => !(e.state === "done" && now - (e.done_at || now) > KEEP_DONE));
  }

  // Where an item stands because of the outbox: "pending" (queued or accepted), "done", "failed", or null.
  function standing(entries, key) {
    let st = null;
    for (const e of entries) {
      if (e.key !== key) continue;
      if (e.state === "failed") return "failed";
      st = e.state === "done" ? (st || "done") : "pending";
    }
    return st;
  }

  function load(raw) {
    try {
      const v = JSON.parse(raw || "[]");
      return Array.isArray(v) ? v.filter((e) => e && typeof e.id === "string" && typeof e.action === "string") : [];
    } catch (e) { return []; }
  }

  return { create, due, posted, reconcile, retry, prune, standing, load, backoff, LOST_AFTER };
})();
if (typeof module !== "undefined" && module.exports) module.exports = Outbox;
