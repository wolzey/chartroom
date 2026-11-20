// app/src/model.js: Needs me across homes (standing, tabs, filters, order), a card's questions from
// a worker's own words (through eventfmt.js), what Enter does, and an answer's body.
"use strict";
const assert = require("assert");
const { test, run } = require("./harness");
const M = require("../../app/src/model.js");
const EF = require("../../lib/dashboard/eventfmt.js");

const ago = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
const state = {
  homes: [
    { name: "acme", snapshot: { needs: [
      { id: "ev-a-1", card: "ev-a-1", ref: "ev-a-1", type: "task", kind: "decide", group: "decide", title: "Pick a cache", at: ago(600),
        text: "Which cache? Details: Options: (1) RECOMMENDED: an in-process LRU: no new service. (2) Redis. Need: your pick.", project: "shop" },
      { id: "fix-b", ref: "fix-b", type: "task", kind: "review", group: "read", title: "Fix the badge", task: "fix-b", at: ago(60), project: "shop" },
      { id: "i-1a2b", card: "i-1a2b", ref: "i-1a2b", type: "inbox", kind: "inbox", group: "decide", title: "Sale on Monday?", at: ago(9000),
        sent: { at: ago(30), via: "app", read_by_xo: false } },
      { id: "ev-c-9", card: "ev-c-9", ref: "ev-c-9", type: "task", kind: "blocked", group: "unblock", title: "Gift cards", at: ago(100),
        snoozed_until: ago(-3600) },
      { id: "ev-d-2", card: "ev-d-2", ref: "ev-d-2", type: "task", kind: "approve", group: "approve", title: "Checkout plan", at: ago(50), held: true },
    ] } },
    { name: "globex", snapshot: { needs: [
      { id: "q-77aa", card: "q-77aa", ref: "q-77aa", type: "card", kind: "round", group: "decide", title: "Search", at: ago(20), breaking: false,
        questions: [{ id: 1, text: "Who first?", options: [{ label: "Shoppers", rec: true }, { label: "Staff" }] }, { id: 2, text: "Out of scope?", options: [] }] },
      { id: "ev-e-3", card: "ev-e-3", ref: "ev-e-3", type: "task", kind: "failed", group: "unblock", title: "Webhooks", at: ago(5000), breaking: true, project: "api" },
    ] } },
    { name: "initech", ok: false, error: "snapshot failed", snapshot: null },
  ],
};

test("items: every home's items in one list, each keyed by home and given its home's hue", () => {
  const all = M.items(state);
  assert.strictEqual(all.length, 7);
  assert.deepStrictEqual([...new Set(all.map((x) => x.home))], ["acme", "globex"]);
  assert.strictEqual(all.find((x) => x.id === "q-77aa").key, "globex:q-77aa");
  assert.strictEqual(all.find((x) => x.home === "globex").hue, 2);
  assert.deepStrictEqual(M.homes(state).map((h) => [h.name, h.ok === false]), [["acme", false], ["globex", false], ["initech", true]]);
});

test("visible: open items only; sent, snoozed and held ones have their own places", () => {
  const all = M.items(state);
  const open = M.visible(all, { tab: "all" }).map((x) => x.id).sort();
  assert.deepStrictEqual(open, ["ev-a-1", "ev-e-3", "fix-b", "q-77aa"]);
  assert.deepStrictEqual(M.visible(all, { tab: "sent" }).map((x) => x.id), ["i-1a2b"]);
  assert.deepStrictEqual(M.visible(all, { tab: "snoozed" }).map((x) => x.id), ["ev-c-9"]);
  // acted on here a moment ago: out of the list before the next snapshot says so
  assert.ok(!M.visible(all, { tab: "all", local: { "acme:fix-b": "gone" } }).some((x) => x.id === "fix-b"));
});

test("visible: a group tab and the home and project filters narrow it", () => {
  const all = M.items(state);
  assert.deepStrictEqual(M.visible(all, { tab: "unblock" }).map((x) => x.id), ["ev-e-3"]);
  assert.deepStrictEqual(M.visible(all, { tab: "all", filters: { home: "globex" } }).map((x) => x.id).sort(), ["ev-e-3", "q-77aa"]);
  assert.deepStrictEqual(M.visible(all, { tab: "all", filters: { project: "shop" } }).map((x) => x.id).sort(), ["ev-a-1", "fix-b"]);
  const c = M.counts(all, {});
  assert.deepStrictEqual([c.all, c.decide, c.unblock, c.read, c.sent, c.snoozed], [4, 2, 1, 1, 1, 1]);
});

test("ordered: by group, then breaking first, then oldest first", () => {
  const all = M.items(state);
  const list = M.ordered(M.visible(all, { tab: "all" }));
  assert.deepStrictEqual(list.map((x) => x.id), ["ev-a-1", "q-77aa", "ev-e-3", "fix-b"]);
});

test("questions: a worker's options come from its own words, the recommendation marked", () => {
  const it = M.items(state).find((x) => x.id === "ev-a-1");
  const qs = M.questions(it, EF);
  assert.strictEqual(qs.length, 1);
  assert.strictEqual(qs[0].text, "Which cache?");
  assert.deepStrictEqual(qs[0].options.map((o) => [o.label, o.rec]), [["An in-process LRU", true], ["Redis", false]]);
  assert.strictEqual(qs[0].options[0].detail, "no new service.");
  // "per partner, recommended" keeps the mark as a tag, not in the label
  const q2 = M.questions({ type: "task", kind: "decide", text: "Count how? Details: Options: (A) per key. (B) per partner, recommended: one bucket. Need: which." }, EF)[0];
  assert.deepStrictEqual(q2.options.map((o) => [o.label, o.rec]), [["Per key", false], ["Per partner", true]]);
  assert.deepStrictEqual(M.details(it, EF), [{ label: "Need", text: "Your pick." }]);
  // an ask with no options is one free-text question
  const free = M.questions({ type: "task", kind: "blocked", text: "the sandbox key expired" }, EF)[0];
  assert.ok(free.free && free.options.length === 0);
});

test("primary: Enter answers with the recommendation, approves, accepts, or opens the round", () => {
  const all = M.items(state);
  const by = (id) => all.find((x) => x.id === id);
  assert.deepStrictEqual(M.primary(by("ev-a-1"), EF), { type: "answer", choice: "An in-process LRU" });
  assert.deepStrictEqual(M.primary(by("q-77aa"), EF), { type: "open-round" });
  assert.deepStrictEqual(M.primary(by("fix-b"), EF), { type: "accept" });
  assert.deepStrictEqual(M.primary(by("ev-d-2"), EF), { type: "approve" });
  assert.deepStrictEqual(M.primary(by("ev-e-3"), EF), { type: "focus-note" });
});

test("answerBody: one answer per question, picks and trimmed notes; an approval carries its note", () => {
  const round = M.items(state).find((x) => x.id === "q-77aa");
  assert.strictEqual(M.answered(round, { 1: "Shoppers" }, { 2: "  " }), 1);
  assert.deepStrictEqual(M.answerBody(round, { 1: "Shoppers" }, { 2: " admin search " }),
    { card: "q-77aa", answers: [{ q: 1, choice: "Shoppers", note: null }, { q: 2, choice: null, note: "admin search" }] });
  assert.deepStrictEqual(M.answerBody({ card: "ev-d-2" }, null, { 1: "ship it" }, "approve"), { card: "ev-d-2", action: "approve", note: "ship it" });
});

test("move, ago and search: the keyboard's selection, short times, the palette's matches", () => {
  assert.strictEqual(M.move(null, 1, 3), 0);
  assert.strictEqual(M.move(2, 1, 3), 2);
  assert.strictEqual(M.move(0, -1, 3), 0);
  assert.strictEqual(M.move(1, 1, 0), 0);
  assert.strictEqual(M.ago(ago(30)), "now");
  assert.strictEqual(M.ago(ago(7200)), "2h");
  assert.strictEqual(M.agoText(ago(3 * 86400)), "3d ago");
  const entries = [{ label: "Needs me" }, { label: "Rate limits for the public API", sub: "globex" }, { label: "Only globex" }];
  assert.deepStrictEqual(M.search(entries, "rate api").map((e) => e.label), ["Rate limits for the public API"]);
  assert.deepStrictEqual(M.search(entries, "globex").map((e) => e.label), ["Only globex", "Rate limits for the public API"]);
});

run();
