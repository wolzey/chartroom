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
  // "(B, recommended)" is a marker too
  const q2 = M.questions({ type: "task", kind: "decide", text: "Count how? Details: Options: (A) per key. (B, recommended) per partner. Need: which." }, EF)[0];
  assert.deepStrictEqual(q2.options.map((o) => [o.label, o.rec]), [["Per key", false], ["Per partner", true]]);
  assert.deepStrictEqual(M.details(it, EF), [{ label: "Need", text: "Your pick." }]);
  // an ask with no options is one free-text question
  const free = M.questions({ type: "task", kind: "blocked", text: "the sandbox key expired" }, EF)[0];
  assert.ok(free.free && free.options.length === 0);
});

test("recommended: only an explicit marker counts, one per card at most, and --detail is not the headline", () => {
  // the commander's feedback 1: option 2's own words say "Not recommended", and both showed the tag
  const text = "The switch PR is green except the slow suite; merging needs you --detail PR: restore deploys. " +
    "Decision for you: (1) Recommended: you turn on auto-merge. That runs the suite. (2) An admin bypass. Not recommended; it needs your say-so.";
  const q = M.questions({ type: "task", kind: "decide", text }, EF)[0];
  assert.deepStrictEqual(q.options.map((o) => o.rec), [true, false]);
  assert.strictEqual(q.text, "The switch PR is green except the slow suite; merging needs you");
  assert.ok(!/--detail/.test(q.text));
  assert.deepStrictEqual(M.primary({ type: "task", kind: "decide", text }, EF).type, "answer");
  // a mention in the text, lowercase or not, never recommends
  const q3 = M.questions({ type: "task", kind: "decide", text: "Which? Options: (1) keep it, as recommended by the docs. (2) drop it." }, EF)[0];
  assert.deepStrictEqual(q3.options.map((o) => o.rec), [false, false]);
  // two markers: neither, so Enter never picks one of them on its own
  const two = { type: "task", kind: "decide", text: "Which? Options: (1) RECOMMENDED: a. (2) RECOMMENDED: b." };
  assert.deepStrictEqual(M.questions(two, EF)[0].options.map((o) => o.rec), [false, false]);
  assert.strictEqual(M.primary(two, EF).type, "focus-note");
  assert.strictEqual(M.headline("Report written to /tmp/x/report.md --detail all the rest"), "Report written to /tmp/x/report.md");
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

test("bulk: each verb applies to the items it fits, skips the rest with why; ranges run in list order", () => {
  const all = M.items(state);
  const list = M.ordered(M.visible(all, { tab: "all" }));
  const keys = list.map((x) => x.key);
  // shift-click from the last row to the second selects the rows between, either way round
  assert.deepStrictEqual(M.range(list, keys[3], keys[1]), keys.slice(1, 4));
  assert.deepStrictEqual(M.range(list, keys[1], keys[3]), keys.slice(1, 4));
  const inbox = { key: "a:i-1", kind: "inbox", type: "inbox", ref: "i-1" };
  const review = { key: "a:t1", kind: "review", type: "task", ref: "t1", task: "t1" };
  const decide = { key: "a:ev", kind: "decide", type: "task", ref: "ev-t2-9", card: "ev-t2-9", task: "t2" };
  const card = { key: "a:q", kind: "round", type: "card", ref: "q-1", card: "q-1" };
  const pick = [inbox, review, decide, card];
  const done = M.bulkPlan(pick, "done");
  assert.deepStrictEqual(done.run.map((r) => [r.action, r.body]), [["done", { ref: "i-1" }], ["accept", { task: "t1" }]]);
  assert.deepStrictEqual(done.skip.map((x) => x.item.key), ["a:ev", "a:q"]);
  assert.match(done.skip[0].why, /answer/);
  assert.deepStrictEqual(M.bulkPlan(pick, "close").run.map((r) => r.body.task), ["t1", "t2"]);
  assert.deepStrictEqual(M.bulkPlan(pick, "accept").run.map((r) => r.item.key), ["a:t1"]);
  assert.deepStrictEqual(M.bulkPlan(pick, "snooze", { for: "4h" }).run.map((r) => r.body), [
    { ref: "i-1", for: "4h" }, { ref: "t1", for: "4h" }, { ref: "ev-t2-9", for: "4h" }, { ref: "q-1", for: "4h" }]);
  // close never asks for a discard: the body is the task alone
  assert.ok(M.bulkPlan(pick, "close").run.every((r) => Object.keys(r.body).join() === "task"));
});

test("links: every URL is one, punctuation stays text, a GitHub PR or issue reads repo#n", () => {
  assert.deepStrictEqual(M.linkParts("Q133: merge https://github.com/acme/shop/pull/35969. Then (see https://example.com/a_(b)), done"), [
    { text: "Q133: merge " }, { href: "https://github.com/acme/shop/pull/35969", label: "shop#35969" },
    { text: ". Then (see " }, { href: "https://example.com/a_(b)", label: "https://example.com/a_(b)" }, { text: "), done" }]);
  assert.deepStrictEqual(M.linkParts("https://github.com/acme/api/issues/7#note"), [{ href: "https://github.com/acme/api/issues/7#note", label: "api#7" }]);
  assert.deepStrictEqual(M.linkParts("no link here"), [{ text: "no link here" }]);
  assert.deepStrictEqual(M.linkParts("javascript:alert(1) is text"), [{ text: "javascript:alert(1) is text" }]);
});

test("rounds: an ask with several option lists is a grilling, answered with each question's words", () => {
  const it = { key: "a:ev", type: "task", kind: "decide", card: "ev-t-1", text:
    "Two calls before I build. Options: (1) RECOMMENDED: keep the flag. (2) drop the flag. Storage: (1) Postgres. (2) RECOMMENDED: SQLite. Need: both." };
  const r = M.promote(it, EF);
  assert.strictEqual(r.kind, "round");
  assert.strictEqual(r.questions.length, 2);
  assert.deepStrictEqual(r.questions.map((q) => q.options.map((o) => o.rec)), [[true, false], [false, true]]);
  assert.strictEqual(r.questions[1].text, "Storage");
  assert.deepStrictEqual(M.primary(r, EF), { type: "open-round" });
  const body = M.answerBody(r, { 1: "Keep the flag", 2: "SQLite" }, {});
  assert.deepStrictEqual(body.answers.map((a) => [a.q, a.choice, typeof a.question]), [[1, "Keep the flag", "string"], [2, "SQLite", "string"]]);
  // one list of options stays a single card in the quick view
  assert.strictEqual(M.promote({ key: "a:x", type: "task", kind: "decide", card: "ev-x-1", text: "Which? Options: (1) a. (2) b." }, EF).kind, "decide");
});

test("board: every home's tasks and unbriefed requests, in the seven columns, filtered by home, project and machine", () => {
  const st = { homes: [
    { name: "acme", snapshot: { machine: "studio", tasks: [
      { id: "a1", title: "Working one", status: "working", project: "shop", last_event: "progress: indexing the catalogue. Details: 40k rows", last_at: "2026-01-02T00:00:00Z" },
      { id: "a2", title: "Closed one", status: "closed", project: "shop", last_at: "2026-01-01T00:00:00Z" },
      { id: "a3", title: "Review one", status: "review", project: "api", last_at: "2026-01-03T00:00:00Z" }],
      requests: [{ id: "rq-1a2b", title: "Gift wrap", project: "shop", at: "2026-01-04T00:00:00Z" }] } },
    { name: "globex", snapshot: { machine: "m5", tasks: [{ id: "g1", title: "Their one", status: "needs", project: "api" }] } }] };
  const all = M.boardItems(st);
  const cols = M.boardColumns(all);
  assert.deepStrictEqual(cols.map((c) => c.status), ["drafting", "queued", "working", "waiting", "needs", "review", "done"]);
  assert.deepStrictEqual(cols.map((c) => c.cards.map((x) => x.id)), [["rq-1a2b"], [], ["a1"], [], ["g1"], ["a3"], ["a2"]]);
  assert.strictEqual(cols[2].cards[0].line, "Indexing the catalogue");
  assert.strictEqual(cols[0].cards[0].type, "request");
  assert.deepStrictEqual(M.boardFilter(all, { home: "acme", project: "shop" }).map((x) => x.id).sort(), ["a1", "a2", "rq-1a2b"]);
  assert.deepStrictEqual(M.boardFilter(all, { machine: "m5" }).map((x) => x.id), ["g1"]);
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
