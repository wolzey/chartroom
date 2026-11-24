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
  // a finished task waiting to be accepted is not something to read: its own group
  assert.deepStrictEqual([c.all, c.decide, c.unblock, c.read, c.finished, c.sent, c.snoozed], [4, 2, 1, 0, 1, 1, 1]);
  assert.strictEqual(all.find((x) => x.id === "fix-b").group, "finished");
  assert.strictEqual(M.GROUPS[M.GROUPS.length - 1].heading, "Finished, waiting for your nod");
});

test("plain words: chartroom's ids and paths out, the title never repeated, several questions as a list", () => {
  const ids = new Set(["c1e7", "plan-the-routing-c1e7"]);
  // an inbox line: the short id goes, the first question is the title, "Also:" becomes the list
  const v = M.view({ type: "inbox", kind: "inbox", title: "Routing plan c1e7: go for the spike (step 1) + staging build? Also: certificate…",
    text: "Routing plan c1e7: go for the spike (step 1) + staging build? Also: certificate choice, pilot store list, any IP allow-lists on shop.example.com" }, ids);
  assert.strictEqual(v.title, "Routing plan: go for the spike (step 1) + staging build?");
  assert.deepStrictEqual(v.list, ["Certificate choice", "Pilot store list", "Any IP allow-lists on shop.example.com"]);
  assert.strictEqual(v.intro, "Also");
  assert.strictEqual(v.more, null);
  // chartroom's own refs, paths and carry notes; a leading project label; numbers and $ amounts stay
  assert.strictEqual(M.plain("mcp Q192: review the 12 admins (tasks/list-admins-558d/report.md) and say who comes off (carried, 2026-10-17)"),
    "mcp: review the 12 admins (the report) and say who comes off");
  assert.strictEqual(M.plain("shop: buy the 1-yr plan (~$790/mo savings; ruling r-af98) in PR 18404", null, "shop"),
    "Buy the 1-yr plan (~$790/mo savings; ruling) in PR 18404");
  assert.strictEqual(M.plain("done: plan finished (page c1e7/one-app-plan) --detail Report: ~/work/shop/tasks/x-c1e7/report.md. Key points: two", ids),
    "Plan finished. Details: Key points: two");
  // a word that only looks like an id stays
  assert.strictEqual(M.plain("the cafe deal on 2026-11-02", ids), "The cafe deal on 2026-11-02");
  // numbered steps in a later sentence: its opening introduces them
  const s = M.shape("Templates PR 18404 is ready. Before merge, you (admin): (1) allow the build service to tag; (2) require pipeline 79; (3) optional: restrict tags. Then approve.");
  assert.strictEqual(s.lead, "Templates PR 18404 is ready.");
  assert.strictEqual(s.intro, "Before merge, you (admin)");
  assert.deepStrictEqual(s.list, ["allow the build service to tag", "require pipeline 79", "optional: restrict tags."]);
  assert.strictEqual(s.more, "Then approve.");
  // a title that is the text cut short is the same words: never shown twice
  assert.ok(M.repeats("Re-run the review on PR 18 only, or also his 7 earlier…", "Re-run the review on PR 18 only, or also his 7 earlier PRs?"));
  assert.ok(!M.repeats("Pick a cache", "Which cache?"));
});

test("finished work: what got done first, its parts one a line; one that still asks is never accepted in bulk", () => {
  const v = M.view({ type: "task", kind: "review", title: "Fix the badge c1e7",
    summary: "done: PR 18817 into main keeps the rate when pasting; no schema change; 4 of 5 new tests fail on old code, 5 of 5 pass; build 33991 green" }, new Set(["c1e7"]));
  assert.strictEqual(v.title, "Fix the badge");
  assert.strictEqual(v.lead, "PR 18817 into main keeps the rate when pasting");
  assert.deepStrictEqual(v.list, ["no schema change", "4 of 5 new tests fail on old code, 5 of 5 pass", "build 33991 green"]);
  assert.strictEqual(v.asks, false);
  for (const t of ["done: PR open. Needs a call: the date rule", "done: drafted; 11 decisions for the commander", "done: merged. Please confirm the portal rule", "done: ready, go?"]) {
    assert.strictEqual(M.view({ type: "task", kind: "review", title: "T", summary: t }).asks, true, t);
  }
  // the notification's body never repeats its title
  const n = M.notice(Object.assign({ key: "acme:i-1", home: "acme", group: "decide", summary: "Ship it? Also: the date" },
    { view: M.view({ type: "inbox", kind: "inbox", title: "Ship it? Also…", text: "Ship it? Also: the date" }) }));
  assert.deepStrictEqual([n.title, n.body], ["Ship it?", "acme · Decide: The date"]);
});

test("permission card in plain words: what it wants, why it came, what Always allows", () => {
  const card = (extra) => Object.assign({ kind: "permission", tool: "Bash", blocking: true, rule: "commander:secrets", reason: "az token",
    why: "Read who can approve deploys", command: "TOKEN=$(az account get-access-token)\ncurl -s https://dev.example.com/roles", pattern: "x" }, extra);
  assert.strictEqual(M.permitLead(card()), "Wants to use your Azure login to read who can approve deploys.");
  assert.strictEqual(M.permitReason(card()), "it uses your Azure login");
  assert.strictEqual(M.permitLead(card({ rule: "commander:outward", reason: "git-push", why: "Push the sitemap branch" })), "Wants to push the sitemap branch.");
  assert.strictEqual(M.permitReason(card({ rule: "commander:outward", reason: "git-push" })), "it pushes code to a shared repository");
  assert.strictEqual(M.permitLead(card({ rule: "commander:outward", reason: "git-push", why: "CI logs for main" })), "CI logs for main.");
  assert.strictEqual(M.permitLead(card({ rule: "commander:production", reason: "kubectl change", why: "" })), "Wants to run a command that needs your OK.");
  assert.strictEqual(M.permitReason(card({ rule: "commander:unlisted", reason: "" })), "chartroom has no rule for it yet");
  // no rule code ever shows
  for (const c of ["outward", "secrets", "production", "elsewhere", "controls", "flags", "money", "unlisted"]) {
    assert.ok(!/commander:|:/.test(M.permitReason(card({ rule: "commander:" + c, reason: "gh pr create" }))), c);
  }
  // Always never says less than it allows
  assert.strictEqual(M.permitScope(card({ pattern: card().command })), "this exact command, until the task closes");
  assert.deepStrictEqual(M.permitScope(card({ pattern: "git push:*" })), { code: "git push", text: "any command starting with", after: ", until the task closes" });
  assert.deepStrictEqual(M.permitScope(card({ tool: "Write", command: null, pattern: "~/work/shop/.env" })).code, ".env");
  // the call: its first line, and whether there is more
  assert.deepStrictEqual(M.firstLine(card().command), { line: "TOKEN=$(az account get-access-token)", more: true });
  assert.deepStrictEqual(M.firstLine("git push origin HEAD"), { line: "git push origin HEAD", more: false });
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
  // an Azure DevOps PR reads repo#n too, never its whole URL (it ran a row off the page)
  assert.deepStrictEqual(M.linkParts("https://dev.azure.com/acme/shop/_git/web/pullrequest/19636"),
    [{ href: "https://dev.azure.com/acme/shop/_git/web/pullrequest/19636", label: "web#19636" }]);
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

test("initiatives: milestones with progress, the current one open; approved stories without a task are Queued", () => {
  const ini = { id: "in-1", created: "2026-01-01T00:00:00Z", milestones: [{ id: "ms-a", name: "Index" }, { id: "ms-b", name: "Box" }],
    stories: [
      { id: "st-1", title: "Cache", milestone: "ms-a", state: "approved", task: "t1", status: "done" },
      { id: "st-2", title: "Index", milestone: "ms-a", state: "approved", task: "t2", status: "done" },
      { id: "st-3", title: "Box", milestone: "ms-b", state: "approved", task: null, status: "queued" },
      { id: "st-4", title: "Load test", milestone: "ms-b", state: "held", after: ["st-3"], task: null, status: "queued" },
      { id: "st-5", title: "Maybe", state: "proposed", status: "drafting" },
      { id: "st-6", title: "Dropped", state: "dropped", status: "dropped" }] };
  const g = M.milestones(ini);
  assert.deepStrictEqual(g.map((x) => [x.name, x.done, x.total, x.finished, x.current]), [["Index", 2, 2, true, false], ["Box", 0, 2, false, true]]);
  const st = { homes: [{ name: "acme", snapshot: { machine: "m", tasks: [], initiatives: [ini] } }] };
  const queued = M.boardItems(st).filter((x) => x.column === "queued");
  assert.deepStrictEqual(queued.map((x) => [x.title, x.line]), [["Box", "Approved; the XO briefs it"], ["Load test", "Waits for Box"]]);
  assert.strictEqual(M.initiatives(st)[0].key, "acme:in-1");
});

test("fleet: a failed sign-in is in Needs me, of no home, opened on Fleet", () => {
  const st = { homes: [], fleet: { checked_at: "2026-01-01T00:00:00Z", machines: [],
    needs: [{ id: "login-laptop-gh", type: "fleet", kind: "login", group: "unblock", machine: "laptop", title: "gh sign-in expired on laptop", at: null }] } };
  const [it] = M.items(st);
  assert.deepStrictEqual([it.key, it.home, it.at], ["fleet:login-laptop-gh", "fleet", "2026-01-01T00:00:00Z"]);
  assert.strictEqual(M.primary(it).type, "open-round");
  assert.strictEqual(M.items({ homes: [], fleet: null }).length, 0);
});

test("notifications: a home's first read is only remembered; then only new open items; a home not read keeps its keys", () => {
  const it = (home, id, extra) => Object.assign({ home, id, key: home + ":" + id, title: "T " + id, group: "decide" }, extra);
  // the page opens with only acme read
  const first = M.freshItems(null, [it("acme", "q-1"), it("acme", "q-2", { sent: { at: "x" } })], ["acme"]);
  assert.deepStrictEqual([first.fresh.length, first.next], [0, { seen: ["acme:q-1"], read: ["acme"] }]);
  // globex is read for the first time: its items are remembered, not announced; acme's new one is
  const second = M.freshItems(first.next, [it("acme", "q-1"), it("acme", "q-4"), it("globex", "q-3")], ["acme", "globex"]);
  assert.deepStrictEqual(second.fresh.map((x) => x.key), ["acme:q-4"]);
  // globex fails a read (its items are missing): its keys are kept, and do not come back as new
  const third = M.freshItems(second.next, [it("acme", "q-1"), it("acme", "q-4")], ["acme"]);
  assert.deepStrictEqual(third.next.seen.sort(), ["acme:q-1", "acme:q-4", "globex:q-3"]);
  const fourth = M.freshItems(third.next, [it("acme", "q-1"), it("acme", "q-4"), it("globex", "q-3"), it("globex", "q-5")], ["acme", "globex"]);
  assert.deepStrictEqual(fourth.fresh.map((x) => x.key), ["globex:q-5"]);
  // held and snoozed are not announced
  const r = M.freshItems({ seen: [], read: ["acme"] }, [it("acme", "h", { held: true }), it("acme", "s", { snoozed_until: "2999-01-01T00:00:00Z" })], ["acme"]);
  assert.strictEqual(r.fresh.length, 0);
  const n = M.notice(it("acme", "q-9", { summary: "Pick the cache" }));
  assert.deepStrictEqual(n, { title: "T q-9", body: "acme · Decide: Pick the cache", tag: "acme:q-9", url: "/#/n/acme%3Aq-9" });
});

test("a notification's tap lands on the item's own page: a task's details, a round, or the card itself", () => {
  const s = { homes: [{ name: "acme", snapshot: { tasks: [{ id: "fix-b", short_id: "f00d" }, { id: "gift-cards" }], needs: [
    { id: "ev-gift-cards-12", type: "task", kind: "decide", group: "decide", task: "gift-cards", card: "ev-gift-cards-12", title: "Refund to the card?" },
    { id: "fix-b", type: "task", kind: "review", group: "read", task: "fix-b", title: "Fix the badge" },
    { id: "q-77aa", type: "card", kind: "round", group: "decide", card: "q-77aa", title: "Search" },
    { id: "p-3c4d", type: "permit", kind: "permission", group: "decide", task: "gift-cards", permit: "p-3c4d", title: "Gift cards" },
    { id: "i-1a2b", type: "inbox", kind: "inbox", group: "decide", card: "i-1a2b", title: "Sale on Monday?" },
    { id: "stories-in-1", type: "initiative", kind: "stories", group: "approve", initiative: "in-1", title: "Approve the stories" }] } }],
    fleet: { needs: [{ id: "login-laptop-gh", type: "fleet", kind: "login", group: "unblock", machine: "laptop", title: "gh sign-in" }] } };
  const all = M.items(s);
  const at = (key) => M.noticeTarget(all, key, s);
  assert.deepStrictEqual(at("acme:ev-gift-cards-12"), { hash: "#/t/acme/gift-cards" });
  assert.deepStrictEqual(at("acme:fix-b"), { hash: "#/t/acme/fix-b" });
  assert.deepStrictEqual(at("acme:q-77aa"), { hash: "#/q/acme/q-77aa" });
  assert.deepStrictEqual(at("acme:stories-in-1"), { hash: "#/i/acme/in-1" });
  assert.deepStrictEqual(at("fleet:login-laptop-gh"), { hash: "#/fleet/laptop" });
  // a permission card is its own card (Allow or Deny is the point), not the task's page
  assert.deepStrictEqual(at("acme:p-3c4d"), { hash: "#/", select: "acme:p-3c4d" });
  assert.deepStrictEqual(at("acme:i-1a2b"), { hash: "#/", select: "acme:i-1a2b" });
  // answered since: its task, when the key names one; else Needs me
  assert.deepStrictEqual(at("acme:ev-gift-cards-40"), { hash: "#/t/acme/gift-cards", gone: true });
  assert.deepStrictEqual(at("acme:i-9999"), { hash: "#/", gone: true });
});

test("permission cards: first, nearest expiry first; a clock; never allowed by Enter", () => {
  const now = 1_800_000_000_000;
  const p = (id, exp, extra) => Object.assign({ key: "acme:" + id, id, kind: "permission", group: "decide", blocking: true, missed: false,
    expires_epoch: now / 1000 + exp, at: "2026-01-01T00:00:00Z", desc: "Bash \"git push origin main\"", home: "acme", title: "Ship it" }, extra);
  const list = M.ordered([
    { key: "acme:q-1", kind: "decide", group: "decide", at: "2025-01-01T00:00:00Z" },
    p("p-late", 600), { key: "acme:t-1", kind: "review", group: "read", breaking: true, at: "2024-01-01T00:00:00Z" },
    p("p-soon", 90), p("p-retry", 0, { blocking: false }), p("p-missed", -10, { missed: true })]);
  // the live blocking ones first by expiry; a retry card or a missed one is an ordinary Decide item
  assert.deepStrictEqual(list.map((x) => x.id || x.key), ["p-soon", "p-late", "acme:q-1", "p-missed", "p-retry", "acme:t-1"]);
  assert.deepStrictEqual(M.permitLeft(p("a", 725), now), { secs: 725, text: "12m left", over: false });
  assert.deepStrictEqual(M.permitLeft(p("b", 45), now), { secs: 45, text: "45s left", over: false });
  assert.strictEqual(M.permitLeft(p("c", -1), now).over, true);
  assert.strictEqual(M.permitLeft(p("d", 300, { missed: true, state_permit: "lapsed" }), now).text, "the worker went on without it");
  assert.strictEqual(M.permitLeft(p("e", 0, { blocking: false }), now).text, "auto mode refused this");
  assert.strictEqual(M.primary(p("f", 300)).type, "focus-note");
  // no bulk action applies to one
  const plan = M.bulkPlan([p("g", 300)], "done");
  assert.strictEqual(plan.run.length + M.bulkPlan([p("g", 300)], "close").run.length + M.bulkPlan([p("g", 300)], "snooze").run.length, 0);
  assert.deepStrictEqual(M.notice(p("h", 300)), { title: "Allow Bash \"git push origin main\"?", body: "acme · Ship it", tag: "acme:h", url: "/#/n/acme%3Ah" });
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

// Fleet's atom and dashboard (fleetviews.js)
const fleetOf = (over) => ({ machines: [Object.assign({ name: "studio", brain: true, state: "healthy", crew_live: 3, other_agents: 2, agents_live: 5, cores: 10, load: [4, 4, 4],
  cpu_use: 24, mem_used_pct: 40, disk_free_pct: 40, budgets: { cpu: 80, mem: 75, on_battery: "pause" }, logins: [], tools: [], extra: [], failing: [], agents: [] }, over),
  { name: "desk", brain: false, state: "healthy", crew_live: 1, other_agents: 0, device: { aliases: ["desk-old"] }, logins: [], tools: [], extra: [], failing: [], agents: [] }] });
const ft = (task, o) => Object.assign({ type: "task", task, key: "acme:" + task, home: "acme", title: task, status: "working", state: "working", live: "working", last_at: ago(60) }, o);

test("fleetMap: a task sits on its own machine (an alias too), an unlisted one on the brain; only open sessions count", () => {
  const by = M.fleetMap(fleetOf(), [ft("a"), ft("b", { machine: "desk-old" }), ft("c", { machine: "elsewhere" }), ft("d", { live: "parked" }), ft("e", { status: "closed" }),
    { type: "request", key: "r", status: "drafting" }]);
  assert.deepStrictEqual(by.studio.sessions.map((s) => s.task.task), ["a", "c"]);
  assert.deepStrictEqual(by.desk.sessions.map((s) => s.task.task), ["b"]);
  assert.deepStrictEqual(by.studio.tasks.map((t) => t.task), ["a", "c", "d"]);
});

test("fleetMap: agents are named where the machine names them; the rest stay a count, a session at rest never twice", () => {
  const rest = ft("old", { live: "done", last_at: ago(9 * 86400) });
  // a machine that only counts: 3 crew, two of them these tasks (one at rest), so one is unnamed
  let o = M.fleetMap(fleetOf(), [ft("a"), rest]).studio;
  assert.deepStrictEqual([o.sessions.length, o.rest.length, o.agents.length, o.crew, o.others], [1, 1, 0, 1, 2]);
  // the same machine naming them
  const agents = [{ kind: "crew", address: "t1", state: "working", name: "a" }, { kind: "crew", address: "t2", state: "done", name: "old" }, { kind: "crew", address: "t3", state: "working", name: "gone-1a2b" },
    { kind: "xo", address: "t4", state: "done", name: "acme", where: "XO / Acme" }, { kind: "other", address: "t5", state: null, name: "shop" }];
  o = M.fleetMap(fleetOf({ agents }), [ft("a"), rest]).studio;
  assert.deepStrictEqual([o.crew, o.others], [0, 0]);
  assert.deepStrictEqual(o.agents.map((a) => [M.agentLabel(a), a.state]), [["gone-1a2b", "working"], ["XO of acme", "waiting"], ["shop", "other"]]);
  // a closed task's worker whose terminal is still open keeps its title
  o = M.fleetMap(fleetOf({ agents }), [ft("gone-1a2b", { status: "closed", title: "Gone" })]).studio;
  assert.strictEqual(o.agents.find((a) => a.kind === "crew" && a.name === "gone-1a2b").task.title, "Gone");
  // an open task's worker whose terminal says nothing yet stands as its task does
  o = M.fleetMap(fleetOf({ agents: [{ kind: "crew", address: "t3", state: null, name: "quiet" }] }), [ft("quiet", { live: "idle", status: "done", state: "done" })]).studio;
  assert.deepStrictEqual(o.agents.map((a) => [a.state, a.task.task]), [["review", "quiet"]]);
  // an hc that cannot tell the crew apart: what no task accounts for
  o = M.fleetMap(fleetOf({ crew_live: null, other_agents: null, agents_live: 4 }), [ft("a")]).studio;
  assert.deepStrictEqual([o.crew, o.others], [0, 3]);
});

test("fleetState: working, waiting, needs me, stalled, finished; an agent that ended on an error is stalled", () => {
  const st = (o) => M.fleetState(ft("x", o));
  assert.deepStrictEqual([st({}), st({ status: "waiting", state: "waiting" }), st({ status: "needs", state: "decision" }), st({ state: "stopped-silent" }), st({ state: "awaiting-input" }),
    st({ status: "review", state: "review" }), st({ live: "gone" })], ["working", "waiting", "needs", "stalled", "stalled", "review", "stalled"]);
  const agents = [{ kind: "crew", address: "t1", state: "error", name: "a" }, { kind: "crew", address: "t2", state: "error", name: "q" }];
  const o = M.fleetMap(fleetOf({ agents }), [ft("a"), ft("q", { status: "needs", state: "decision" })]).studio;
  assert.deepStrictEqual(o.sessions.map((s) => [s.task.task, s.state, !!s.error]), [["q", "needs", false], ["a", "stalled", true]]);
  assert.deepStrictEqual(M.fleetProblems(fleetOf({ agents }).machines[0], o).map((p) => p.text), ["1 agent ended on an error"]);
});

test("fleetMeters: CPU and memory are the measures placement goes by, each against its limit; load and workers are for information", () => {
  const of = (over) => Object.fromEntries(M.fleetMeters(fleetOf(over).machines[0]).map((x) => [x.id, x]));
  let x = of({});
  assert.deepStrictEqual([x.cpu.used, x.cpu.text, x.cpu.tick, x.cpu.level], [24, "24% in use", 80, null]);
  assert.deepStrictEqual([x.mem.used, x.mem.text, x.mem.tick, x.mem.level], [40, "40% in use", 75, null]);
  assert.deepStrictEqual([x.load.used, x.load.text, x.load.tick, x.load.level], [40, "4.0 on 10 cores", null, null]);
  assert.deepStrictEqual([x.disk.used, x.workers.used, x.workers.text], [60, null, "3"]);
  // not measured there (an older chartroom): said, with no bar, and load is not shown in its place
  x = of({ cpu_use: null, mem_used_pct: null });
  assert.deepStrictEqual([x.cpu.used, x.cpu.text, x.mem.used, x.mem.text, x.load.used], [null, "not measured there yet", null, "not measured there yet", 40]);
  // at a limit; a high load and many workers alone are no warning
  x = of({ cpu_use: 80, mem_used_pct: 74, load: [12, 9, 8], disk_free_pct: 9, crew_live: 30 });
  assert.deepStrictEqual([x.cpu.word, x.mem.word, x.load.word, x.disk.word, x.workers.word], ["at its limit", null, null, "very low", null]);
  // no limits set: high is still said
  x = of({ budgets: null, cpu_use: 90, load: [null, null, null], mem_used_pct: null });
  assert.deepStrictEqual([x.cpu.word, x.cpu.tick, x.load.text, x.mem.text], ["high", null, "not read", "not measured there yet"]);
});

test("fullness: the greater of CPU and memory over their limits; not known without both uses and both limits", () => {
  const f = (over) => M.fullness(fleetOf(over).machines[0]);
  assert.strictEqual(f({ cpu_use: 40, mem_used_pct: 30 }), 0.5);
  assert.strictEqual(f({ cpu_use: 10, mem_used_pct: 75, crew_live: 0 }), 1);
  assert.deepStrictEqual([f({ cpu_use: null }), f({ mem_used_pct: null }), f({ budgets: null })], [null, null, null]);
});

test("fleetProblems: offline, sign-ins with the command, docker, full, stalled and failed tasks; the worst first, the old apart", () => {
  const probs = (over, tasks) => { const f = fleetOf(over); return M.fleetProblems(f.machines[0], M.fleetMap(f, tasks || []).studio); };
  assert.deepStrictEqual(probs({}), []);
  assert.deepStrictEqual(probs({ state: "down", error: "no answer", device: { seen_age_s: 7200 } }).map((p) => [p.level, p.text, p.sub]), [["bad", "Offline: no answer", "last heartbeat 2h ago"]]);
  const p = probs({ failing: ["gh sign-in", "codex"], logins: [{ ok: false, label: "gh sign-in", detail: "token expired" }, { ok: null, label: "codex sign-in", detail: "cannot tell" }],
    tools: [{ ok: false, label: "codex", detail: "missing" }], extra: [{ ok: false, label: "docker", detail: "daemon not answering" }], cpu_use: 83, mem_used_pct: 60, power: "battery", battery_pct: 40 },
    [ft("f", { state: "failed", live: "gone" }), ft("s", { state: "stopped-silent", live: "gone" }), ft("w", { state: "waiting-overdue", status: "waiting" }), ft("z", { state: "failed", live: "gone", last_at: ago(30 * 86400) })]);
  assert.deepStrictEqual(p.map((x) => x.level + ": " + x.text), ["bad: gh sign-in failed", "bad: codex is not working", "bad: 1 failed task", "bad: 1 stopped without reporting",
    "warn: docker is not working", "warn: codex sign-in cannot be told", "warn: On battery, 40%", "warn: Takes no new work: CPU 83% of its 80% limit", "warn: 1 waiting past its time", "old: 1 more stalled, untouched for 7 days"]);
  assert.strictEqual(p[0].cmd, "gh auth login");
});

run();
