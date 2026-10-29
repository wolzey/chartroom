// lib/dashboard/stacks.js: which radar records stack together, which one leads, and the archive.
"use strict";
const assert = require("assert");
const { test, run } = require("./harness");
const S = require("../../lib/dashboard/stacks.js");

const NOW = Date.parse("2026-10-29T12:00:00Z");
const hoursAgo = (h) => new Date(NOW - h * 3600e3).toISOString().replace(/\.\d+Z$/, "Z");
let n = 0;
function rec(id, x) {
  return Object.assign({ key: "mac/acme/" + id, machine: "mac", home: "acme", id, title: "Task " + id, project: "web",
    sector: "underway", state: "working", live: "working", last_activity_at: hoursAgo(++n), breaking: false,
    branch: "cap/" + id, base: "origin/main", mentions: [] }, x || {});
}
const stackOf = (units, id) => units.find((u) => u.kind === "stack" && u.members.some((m) => m.id === id));
const ids = (u) => u.members.map((m) => m.id);
function shuffle(a, seed) { const b = a.slice(); let s = seed; for (let i = b.length - 1; i > 0; i--) { s = (s * 16807) % 2147483647; const j = s % (i + 1); [b[i], b[j]] = [b[j], b[i]]; } return b; }

const FLEET = [
  rec("ir-006-fix-fail-closed-p-a84f", { title: "IR-006 fix: fail-closed push guard", sector: "decision", state: "decision" }),
  rec("ir-006-backend-push-kill-f66d", { title: "IR-006 backend: push kill switch", sector: "holding", state: "waiting" }),
  rec("eng-2752-give-app-t-651a", { title: "Give app tokens the API role", branch: "cap/eng-2752-give-app-t-651a" }),
  rec("tokens-follow-up-aa11", { title: "Token rotation follow-up", mentions: ["eng-2752-give-app-t-651a"], sector: "blocked", state: "blocked" }),
  rec("qa-dashboard-t1-0001", { title: "QA dashboard T1", project: "board" }),
  rec("qa-dashboard-t2-0002", { title: "QA dashboard T2", project: "board", sector: "docked", state: "review" }),
  rec("qa-dashboard-t3-0003", { title: "QA dashboard t3", project: "board" }),
  rec("stacked-pr-two-0004", { title: "Second PR on top", base: "cap/stacked-pr-one-0005" }),
  rec("stacked-pr-one-0005", { title: "First PR" }),
  rec("plan-alpha-0006", { title: "Plan: tear down the old region", project: "infra" }),
  rec("plan-beta-0007", { title: "Plan: right-size the database", project: "infra" }),
  rec("fix-1-0008", { title: "fix 1", project: "web" }),
  rec("fix-2-0009", { title: "fix 2", project: "web" }),
  rec("utf-8-cleanup-000a", { title: "UTF-8 cleanup" }),
  rec("utf-8-headers-000b", { title: "UTF-8 headers" }),
  rec("other-machine-000c", { title: "IR-006 on studio", machine: "studio", key: "studio/acme/other-machine-000c" }),
];

test("tickets: from the title, the slug or the branch; never UTF-8 or SHA-256", () => {
  assert.deepStrictEqual(S.tickets({ id: "eng-61-google-cert-f131", title: "ENG-61 Google Certificate Manager", branch: "" }), ["ENG-61"]);
  assert.deepStrictEqual(S.tickets({ id: "x-1234", title: "fix", branch: "feature/gh-9869-auth" }), ["GH-9869"]);
  assert.deepStrictEqual(S.tickets({ id: "utf-8-cleanup-000a", title: "UTF-8 and SHA-256 cleanup" }), []);
  assert.deepStrictEqual(S.tickets({ id: "ir-006-x-a84f", title: "IR-006 fix" }), ["IR-006"]);
});
test("stems: a trailing number goes; a short or one-word stem never stacks", () => {
  assert.deepStrictEqual(S.stem("QA dashboard T2"), { stem: "qa dashboard", numbered: true });
  assert.deepStrictEqual(S.stem("Release notes phase 4"), { stem: "release notes", numbered: true });
  assert.deepStrictEqual(S.stem("Migrate part 2 of 3"), { stem: "migrate", numbered: true });
  assert.strictEqual(S.stem("Phase 4 rollout plan").numbered, false);
});
test("group: ticket, follow-up, series and stacked branches stack; look-alikes do not", () => {
  const u = S.group(FLEET);
  assert.deepStrictEqual(ids(stackOf(u, "ir-006-fix-fail-closed-p-a84f")), ["ir-006-fix-fail-closed-p-a84f", "ir-006-backend-push-kill-f66d", "other-machine-000c"]);
  assert.deepStrictEqual(ids(stackOf(u, "tokens-follow-up-aa11")), ["tokens-follow-up-aa11", "eng-2752-give-app-t-651a"]);
  assert.deepStrictEqual(stackOf(u, "tokens-follow-up-aa11").reasons, ["follow-up"]);
  assert.deepStrictEqual(ids(stackOf(u, "qa-dashboard-t1-0001")).sort(), ["qa-dashboard-t1-0001", "qa-dashboard-t2-0002", "qa-dashboard-t3-0003"]);
  assert.deepStrictEqual(stackOf(u, "qa-dashboard-t1-0001").reasons, ["series"]);
  assert.deepStrictEqual(ids(stackOf(u, "stacked-pr-one-0005")).sort(), ["stacked-pr-one-0005", "stacked-pr-two-0004"]);
  for (const alone of ["plan-alpha-0006", "plan-beta-0007", "fix-1-0008", "fix-2-0009", "utf-8-cleanup-000a", "utf-8-headers-000b"]) {
    assert.ok(!stackOf(u, alone), alone + " stacked");
  }
  assert.strictEqual(u.filter((x) => x.kind === "stack").length, 4);
});
test("group: the stack wears its most urgent member's sector and state, and its newest activity", () => {
  const u = S.group(FLEET);
  const ir = stackOf(u, "ir-006-backend-push-kill-f66d");
  assert.deepStrictEqual([ir.lead.id, ir.sector, ir.state], ["ir-006-fix-fail-closed-p-a84f", "decision", "decision"]);
  const qa = stackOf(u, "qa-dashboard-t2-0002");
  assert.strictEqual(qa.sector, "underway"); // a review behind two working ones: the working one leads
  const latest = qa.members.map((m) => m.last_activity_at).sort().pop();
  assert.strictEqual(qa.last_activity_at, latest);
});
test("group: deterministic; the same set in any order gives the same stacks and keys", () => {
  const want = JSON.stringify(S.group(FLEET));
  for (let seed = 1; seed < 30; seed++) assert.strictEqual(JSON.stringify(S.group(shuffle(FLEET, seed))), want);
});
test("group: an older chartroom's records (no branch, base or mentions) still stack by ticket and series", () => {
  const old = FLEET.map((r) => { const c = Object.assign({}, r); delete c.branch; delete c.base; delete c.mentions; return c; });
  const u = S.group(old);
  assert.ok(stackOf(u, "ir-006-backend-push-kill-f66d") && stackOf(u, "qa-dashboard-t3-0003"));
  assert.ok(!stackOf(u, "stacked-pr-one-0005") && !stackOf(u, "tokens-follow-up-aa11"));
  assert.deepStrictEqual(S.group([]), []);
});
test("archive: docked past done_hours, or session gone and quiet past stale_days; never breaking", () => {
  const st = { done_hours: 24, stale_days: 3 };
  const A = (x) => S.archived(rec("a", x), NOW, st);
  assert.strictEqual(A({ sector: "docked", state: "done", last_activity_at: hoursAgo(25) }), "docked");
  assert.strictEqual(A({ sector: "docked", state: "review", last_activity_at: hoursAgo(23) }), null);
  assert.strictEqual(A({ sector: "decision", state: "decision", live: "gone", last_activity_at: hoursAgo(73) }), "stale");
  assert.strictEqual(A({ sector: "decision", state: "decision", live: "idle", last_activity_at: hoursAgo(300) }), null);
  assert.strictEqual(A({ sector: "adrift", state: "lost", live: "gone", last_activity_at: hoursAgo(71) }), null);
  assert.strictEqual(A({ sector: "docked", state: "done", breaking: true, last_activity_at: hoursAgo(999) }), null);
  assert.strictEqual(A({ sector: "docked", last_activity_at: null, dispatched: null, created: null }), null);
  // the cutoffs are the settings', not fixed
  assert.strictEqual(S.archived(rec("b", { sector: "docked", last_activity_at: hoursAgo(5) }), NOW, { done_hours: 4, stale_days: 3 }), "docked");
  assert.strictEqual(S.archived(rec("c", { live: "stopped", last_activity_at: hoursAgo(30) }), NOW, { done_hours: 24, stale_days: 1 }), "stale");
});

run();
