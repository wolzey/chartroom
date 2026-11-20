// app/src/outbox.js: an action is done in the page at once, sent in the background, retried while the
// server cannot be reached, failed (and retryable) when refused, and kept across a reload.
"use strict";
const assert = require("assert");
const { test, run } = require("./harness");
const O = require("../../app/src/outbox.js");

const T0 = 1_000_000;

test("an action is pending at once, before anything is sent", () => {
  const e = O.create("acme", "done", { ref: "i-1a2b" }, "acme:i-1a2b", "Marked done", T0);
  assert.strictEqual(e.state, "queued");
  assert.strictEqual(O.standing([e], "acme:i-1a2b"), "pending");
  assert.deepStrictEqual(O.due([e], T0).map((x) => x.id), [e.id]);
});

test("no answer from the server: retried with growing waits; a refusal fails it for good", () => {
  let e = O.create("acme", "done", { ref: "i-1a2b" }, "acme:i-1a2b", "Marked done", T0);
  e = O.posted(e, 0, null, T0);
  assert.strictEqual(e.state, "queued");
  assert.strictEqual(e.next, T0 + 1000);
  assert.deepStrictEqual(O.due([e], T0 + 500), []);
  e = O.posted(e, 503, "busy", T0 + 1000);
  assert.strictEqual(e.next, T0 + 1000 + 2000);
  assert.strictEqual(O.backoff(20), 30000);
  const refused = O.posted(e, 400, "card: a card id", T0 + 3000);
  assert.strictEqual(refused.state, "failed");
  assert.strictEqual(O.standing([refused], "acme:i-1a2b"), "failed");
  const again = O.retry(refused, T0 + 4000);
  assert.strictEqual(again.state, "queued");
  assert.deepStrictEqual(O.due([again], T0 + 4000).map((x) => x.id), [refused.id]);
});

test("accepted, then the server's state says done or failed; one it never heard of is sent again", () => {
  const a = O.posted(O.create("acme", "accept", { task: "t" }, "acme:t", "Accepted", T0), 202, null, T0);
  const b = O.posted(O.create("acme", "close", { task: "u" }, "acme:u", "Closed", T0), 202, null, T0);
  const c = O.posted(O.create("acme", "done", { ref: "i-9" }, "acme:i-9", "Marked done", T0), 202, null, T0);
  const after = O.reconcile([a, b, c], { [a.id]: { state: "done" }, [b.id]: { state: "failed", error: "worktree not clean" } }, T0 + 1000);
  assert.deepStrictEqual(after.map((x) => x.state), ["done", "failed", "accepted"]);
  assert.strictEqual(after[1].error, "worktree not clean");
  // the server restarted and lost it before running it: sent again, under the same id
  const lost = O.reconcile([c], {}, T0 + O.LOST_AFTER + 1);
  assert.strictEqual(lost[0].state, "queued");
  assert.strictEqual(lost[0].id, c.id);
  // done ones are kept a minute, so the item stays out of the list until the next snapshot drops it
  assert.strictEqual(O.prune(after, T0 + 30000).length, 3);
  assert.strictEqual(O.prune(after, T0 + 1000 + 61000).length, 2);
});

test("the outbox survives a reload; junk in storage is dropped", () => {
  const e = O.create("acme", "snooze", { ref: "x", for: "1h" }, "acme:x", "Snoozed", T0);
  assert.deepStrictEqual(O.load(JSON.stringify([e, { nope: 1 }, null])), [e]);
  assert.deepStrictEqual(O.load("not json"), []);
});

run();
