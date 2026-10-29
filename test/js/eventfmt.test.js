// lib/dashboard/eventfmt.js: the event parser, the inline tokens, the feed's threads and runs,
// and the render, against fixtures. The DOL decision is the radar screenshot's case, word for
// word but for the service name and the home path.
"use strict";
const assert = require("assert");
const { test, run, words } = require("./harness");
const { document } = require("./dom");
const E = require("../../lib/dashboard/eventfmt.js");

const DOL = "2026-10-20T17:01:15Z decision: [breaking] DOL outage cause found: since the API swaps (AU 18 Oct 19:05Z, UK 19 Oct 03:22Z) acme-web returns 400 to guards opening or exporting a DOL (getpagedDetail/export; UK 89/103 companies, 735 users; AU 50/55 companies). Mobile shows an endless spinner. Submits and uploads are healthy. Cause: GH-8414 (PR 17439, unflagged) treats every Employee-role caller as a portal user. No flag/config switch; trunk still has it. Options: (1) RECOMMENDED hotfix PR to trunk: apply portal gates only to portal accounts (CustomerAccountId==1 OR has customer-site grants), guards get the pre-GH-8414 read (scope a; tighter site scope as a follow-up), fix the GH-9391 list pins in the same PR, then the normal RC/promote/swap chain in both regions; (2) swap production-green back (AU 3f31b3a5f, UK 52073a295): fastest, but reopens the V2 cross-tenant PDF leak, V5/V6 and GH-9391, and drops the release. Need: pick 1 or 2, and the guard scope (a/b/c). Report: ~/.chartroom/tasks/customers-can-t-upload-d-3da1/report.md";

// Shapes seen in real crew logs, with names changed.
const CASES = {
  short: "progress: started",
  done: "done: shipped the fix; tests green (page b821/report)",
  waiting: "waiting: CI on PR 12 until 2026-01-05T15:30:00Z",
  blocked: "blocked: need staging credentials for the deploy role",
  letters: "decision: Replay needs a choice. Options: (A, recommended) copy only each PR's changed files at base and head; (B) mirror the full repo at each base; (C) don't copy code: build synthetic cases instead. Also: only one staging org exists.",
  bare: "decision: Approve plan+diff 88eacef (committed, NOT pushed)? Guard always on. Options: A (recommended) legacy apns stays a validated tag send; B flag also moves legacy apns to direct on PnsHandle. Details: tasks/ir-006-fix-fail-closed-p-a84f/report.md",
  close: "decision: Pick a region. 1) us-east, cheapest 2) eu-west, nearest the users 3) both, double the cost. Recommend: 2.",
  flagged: "decision: TIME-SENSITIVE: a teammate dispatched the production plan at 18:44Z on 8554d4f (run 39655401170). Options: (A) let it go and watch; (B) ask them to hold. Default unless told otherwise: (A).",
  urgent: "decision: URGENT (separate from migration): prod web-ssl cert renewal is wedged since 09-14. Options: (1) recommended: remove the dead host from the ingress; (2) do nothing and cut over before 11-29. Details in report.md",
  facts: "done: Token H revoked (id 426 expired, env var removed, old value 401); Token M rotated zero-downtime (new id 920 same role, deploy READY, old value 401). Soak ends 2026-10-22 for both. ENG-2754 covers both; ENG-2755; ENG-2758 filed.",
  steer: "steered: XO: the reviewer left 4 [low] findings inline (two admins aren't deployers; await-stage fails open). Fix them on this branch, then report.",
  colonTime: "progress: Stage on #27560 (5 s poll, 30 s kill switch) since 04:29:17Z: 0 stale, 0 evaluation failures, 0 errors. Real failover in stage: the leader was evicted at 04:19:56Z.",
  url: "progress: PR0 opened: https://github.com/acme/otto/pull/267 (bench + judge prompt). Starting PR1 on a new branch.",
  labelFirst: "decision: Options: (1) ship it; (2) wait for review.",
  question: "decision: Merge call on PR 26147 head d38e758? CI green: 16 pass, 9 skipped, 0 failing.",
  joiner: "steered: The commander decided both: (1) you do the removal now, and (2) you write the cutover up as a ticket.",
  sentenceThenLabel: "decision: Options: merge after v0.6.2 is cut (recommended) / hold. Not merged. Report: report.md",
};
const GARBAGE = ["", "   ", "((((", ":::: ;;;; ....", "a".repeat(5000), "\u0000\u0001 binary ÿþ", "<script>alert(1)</script>",
  "(1) (2) (3)", "Options:", "Options: (1)", "1) 2) 3)", "[breaking]", ". . . : : :", "foo (bar. Baz: qux", "🚀 shipped 🎉; done; ok",
  "Cause: Cause: Cause:", "(A) (A) (B) (B)", "x".repeat(300) + ": y", "e.g. this vs. that etc. and so on: fine", "`unclosed code and (paren"];

const stamp = (line) => E.parseLine(/^\d{4}-/.test(line) ? line : "2026-10-29T10:00:00Z " + line);
function parsed(line) { const ev = stamp(line); return E.parseEvent(ev.kind, ev.text, ev.breaking); }
function find(p, label) { return p.blocks.find((b) => (b.label || "").toLowerCase() === label); }

test("DOL decision: breaking, a headline, then the lead, Cause, Options, Need, Report", () => {
  const p = parsed(DOL);
  assert.strictEqual(p.kind, "decision");
  assert.strictEqual(p.breaking, true);
  assert.strictEqual(p.headline, "DOL outage cause found");
  assert.deepStrictEqual(p.blocks.map((b) => b.label), [null, "Cause", "Options", "Need", "Report"]);
  assert.match(p.blocks[0].parts[0].text, /^Since the API swaps/);
});
test("DOL decision: two options, the first recommended, each with a short title", () => {
  const opts = find(parsed(DOL), "options").parts.find((x) => x.type === "options");
  assert.strictEqual(opts.items.length, 2);
  assert.deepStrictEqual(opts.items.map((i) => [i.marker, i.recommended]), [["1", true], ["2", false]]);
  assert.strictEqual(opts.items[0].title, "Hotfix PR to trunk");
  assert.strictEqual(opts.items[0].recword, "RECOMMENDED");
  assert.match(opts.items[0].text, /^apply portal gates.*both regions$/);
  assert.strictEqual(opts.items[1].title, "Swap production-green back (AU 3f31b3a5f, UK 52073a295)");
  assert.match(opts.items[1].text, /drops the release\.$/);
});
test("DOL decision: the report path is a task file; the SHAs and tickets are code", () => {
  const rep = E.tokens(find(parsed(DOL), "report").parts[0].text).find((t) => t.t === "path");
  assert.deepStrictEqual([rep.task, rep.file], ["customers-can-t-upload-d-3da1", "report.md"]);
  const t = E.tokens(DOL);
  assert.deepStrictEqual(t.filter((x) => x.t === "sha").map((x) => x.v), ["3f31b3a5f", "52073a295"]);
  assert.deepStrictEqual([...new Set(t.filter((x) => x.t === "ticket").map((x) => x.v))], ["GH-8414", "GH-9391"]);
  // prose with slashes stays prose
  for (const prose of ["flag/config", "89/103", "a/b/c", "RC/promote/swap", "V5/V6", "getpagedDetail/export"]) {
    assert.ok(!t.some((x) => x.t === "path" && x.v.includes(prose)), prose + " read as a path");
  }
});
test("short events: the whole text is the headline", () => {
  assert.deepStrictEqual([parsed(CASES.short).headline, parsed(CASES.short).blocks.length], ["Started", 0]);
  const w = parsed(CASES.waiting);
  assert.strictEqual(w.headline, "CI on PR 12 until 2026-01-05T15:30:00Z");
  assert.strictEqual(parsed(CASES.blocked).headline, "Need staging credentials for the deploy role");
});
test("options in every style workers use", () => {
  const items = (k, label) => find(parsed(CASES[k]), label).parts.find((x) => x.type === "options").items;
  assert.deepStrictEqual(items("letters", "options").map((i) => [i.marker, i.recommended]), [["A", true], ["B", false], ["C", false]]);
  assert.deepStrictEqual(items("bare", "options").map((i) => [i.marker, i.recommended]), [["A", true], ["B", false]]);
  const close = parsed(CASES.close).blocks[0].parts.find((x) => x.type === "options");
  assert.deepStrictEqual(close.items.map((i) => i.marker), ["1", "2", "3"]);
  assert.deepStrictEqual(items("urgent", "options").map((i) => [i.marker, i.recommended, i.recword]), [["1", true, "recommended"], ["2", false, null]]);
  assert.deepStrictEqual(parsed(CASES.labelFirst).blocks.map((b) => b.label), ["Options"]);
  assert.strictEqual(parsed(CASES.labelFirst).headline, "");
});
test("an option's trailing 'and' / 'or' is kept as its joiner; a label never swallows the sentence before it", () => {
  const items = parsed(CASES.joiner).blocks[0].parts.find((x) => x.type === "options").items;
  assert.deepStrictEqual(items.map((i) => [i.text, i.join]), [["You do the removal now", "and"], ["You write the cutover up as a ticket.", null]]);
  assert.deepStrictEqual(parsed(CASES.sentenceThenLabel).blocks.map((b) => b.label), ["Options", "Report"]);
});
test("shouted flags and a steer's speaker are tags, not the headline", () => {
  const f = parsed(CASES.flagged);
  assert.deepStrictEqual(f.tags.map((t) => t.text), ["TIME-SENSITIVE"]);
  assert.match(f.headline, /^A teammate dispatched the production plan/);
  const u = parsed(CASES.urgent);
  assert.deepStrictEqual(u.tags, [{ text: "URGENT", note: "separate from migration" }]);
  const s = parsed(CASES.steer);
  assert.strictEqual(s.speaker, "XO");
  assert.match(s.headline, /^The reviewer left 4 \[low\] findings inline/);
});
test("several ;-separated facts become bullets; a time's colon is no headline break", () => {
  const f = parsed(CASES.facts);
  const lists = f.blocks.flatMap((b) => b.parts).filter((x) => x.type === "ul");
  assert.ok(lists.some((l) => l.items.length === 3 && l.items[0] === "ENG-2754 covers both"), JSON.stringify(lists));
  assert.match(f.headline, /^Token H revoked/);
  const c = parsed(CASES.colonTime);
  assert.strictEqual(c.headline, "Stage on #27560 (5 s poll, 30 s kill switch) since 04:29:17Z");
  assert.strictEqual(parsed(CASES.question).headline, "Merge call on PR 26147 head d38e758?");
  assert.strictEqual(parsed(CASES.url).headline, "PR0 opened");
});
test("inline tokens: URLs lose trailing punctuation, commands and files are code, UTF-8 is no ticket", () => {
  const t = E.tokens("see https://example.com/a/pull/9). Run `make test`, then /continue 3da1; UTF-8 and SHA-256 are fine; read report.md.");
  assert.deepStrictEqual(t.filter((x) => x.t !== "text").map((x) => [x.t, x.v]),
    [["url", "https://example.com/a/pull/9"], ["code", "make test"], ["code", "/continue 3da1"], ["path", "report.md"]]);
  assert.strictEqual(t.find((x) => x.t === "path").file, "report.md");
  assert.deepStrictEqual(E.tokens("javascript:alert(1) and data:text/html,x").filter((x) => x.t === "url"), []);
  assert.strictEqual(E.tokens("task customers-can-t-upload-d-3da1 is open").find((x) => x.t === "id").v, "customers-can-t-upload-d-3da1");
});
test("no word is ever lost: plain() gives every word back, in order", () => {
  for (const line of [DOL, ...Object.values(CASES)]) {
    const ev = stamp(line);
    const p = E.parseEvent(ev.kind, ev.text, ev.breaking);
    assert.strictEqual(words(E.plain(p)), words((ev.breaking ? "[breaking] " : "") + ev.text), line);
  }
});
test("garbage in: never throws, never loses or invents a word", () => {
  for (const g of GARBAGE) for (const kind of ["decision", "steered", null]) {
    const p = E.parseEvent(kind, g);
    assert.strictEqual(words(E.plain(p)), words(g), JSON.stringify(g));
  }
  assert.deepStrictEqual(E.parseLine("not an event"), null);
});
test("parseLog: a line without a timestamp continues the event before it", () => {
  const evs = E.parseLog("orphan line\n2026-10-29T10:00:00Z progress: one\nsecond line\n\n2026-10-29T10:01:00Z note: created\n");
  assert.deepStrictEqual(evs.map((e) => [e.kind, e.text]), [[null, "orphan line"], ["progress", "one\nsecond line"], ["note", "created"]]);
  assert.deepStrictEqual(evs.map((e) => e.i), [0, 1, 2]);
});

// ---------------------------------------------------------------- the feed

const LOG = [
  "2026-10-20T16:39:39Z note: created (scout via auto)",
  "2026-10-20T16:39:55Z note: dispatched via herdr:claude",
  "2026-10-20T16:40:03Z agent: prompt-received sig=9a8e65b97dbe len=158",
  "2026-10-20T16:45:18Z progress: UK API returns 400 for ~85% of calls",
  "2026-10-20T16:50:00Z progress: checking AU next",
  "2026-10-20T16:52:48Z agent: prompt-received sig=b711be5fe3f7 len=11155",
  "2026-10-20T16:55:00Z progress: AU confirmed",
  "2026-10-20T17:01:15Z decision: [breaking] DOL outage cause found: pick 1 or 2",
  "2026-10-20T17:02:00Z agent: turn-ended",
  "2026-10-20T17:03:00Z waiting: on the commander's call",
  "2026-10-20T17:10:00Z steered: XO: the commander chose (1); go",
  "2026-10-20T17:10:05Z agent: prompt-received sig=c98aa8413573 len=13456",
  "2026-10-20T17:20:00Z progress: hotfix PR opened",
  "2026-10-20T17:30:00Z blocked: need the deploy role",
  "2026-10-20T17:31:00Z agent: awaiting-input: permission prompt",
  "2026-10-20T17:40:00Z decision: ship now or after review?",
  "2026-10-20T17:50:00Z steered: hold for review",
].join("\n");

test("feed: a decision, its waiting, the XO's steer and the next report form one thread", () => {
  const items = E.feed(E.parseLog(LOG));
  const th = items.filter((it) => it.type === "thread");
  assert.deepStrictEqual(th.map((t) => t.events.map((e) => e.kind)), [["decision", "steered"], ["decision", "waiting", "steered", "progress"]]);
  assert.strictEqual(th[1].breaking, true);
});
test("feed: progress runs collapse; noise folds into system-event items, merged across a thread; newest first", () => {
  const items = E.feed(E.parseLog(LOG));
  assert.deepStrictEqual(items.map((it) => it.type + ":" + it.events.length),
    ["thread:2", "single:1", "single:1", "thread:4", "noise:2", "run:3", "noise:4"]);
  assert.deepStrictEqual(items[1].events.map((e) => e.text), ["awaiting-input: permission prompt"]); // visible, not noise
  for (let k = 1; k < items.length; k++) assert.ok(items[k - 1].last > items[k].last);
  assert.ok(items.every((it) => it.key && it.kinds.length));
  assert.strictEqual(E.latestAsk(E.parseLog(LOG)).text, "ship now or after review?");
});
test("feed: keys hold while the log grows, so an opened thread stays open", () => {
  const a = E.feed(E.parseLog(LOG)).map((it) => it.key);
  const b = E.feed(E.parseLog(LOG + "\n2026-10-20T18:00:00Z progress: waiting on CI")).map((it) => it.key);
  for (const k of a.filter((k) => !k.startsWith("n:"))) assert.ok(b.includes(k), k);
});

// ---------------------------------------------------------------- render

// the text a reader sees: every text node, with a break between nodes
function texts(n) { const out = []; const walk = (x) => { if (x.nodeType === 3) out.push(x.data); else x.childNodes.forEach(walk); }; walk(n); return out.join(" "); }
function inOrder(hay, needle) {
  const h = words(hay).split(" "), w = words(needle).split(" ").filter(Boolean);
  let i = 0; for (const x of h) if (x === w[i]) i++;
  return i === w.length;
}
test("render: every word of the event is on the page, in order; links are safe", () => {
  for (const line of [DOL, ...Object.values(CASES)]) {
    const ev = stamp(line);
    const node = E.renderEvent(ev, { link: (t) => t.file ? "/task/acme/x#report" : null });
    assert.ok(inOrder(texts(node), ev.text), line);
    for (const a of node.all().filter((n) => n.tagName === "A")) {
      assert.match(a.getAttribute("href"), /^(https?:\/\/|\/task\/)/);
      if (/^https?:/.test(a.getAttribute("href"))) assert.strictEqual(a.getAttribute("rel"), "noopener noreferrer");
    }
  }
  const evil = E.renderEvent({ kind: "progress", text: "<script>alert(1)</script><img src=x onerror=alert(1)>", at: null });
  assert.ok(!evil.all().some((n) => /^(SCRIPT|IMG)$/.test(n.tagName)));
  assert.ok(texts(evil).includes("<script>alert(1)</script>"));
});
test("render: the DOL options are a list with the recommended one marked", () => {
  const node = E.renderEvent(E.parseLine(DOL), {});
  const lis = node.all().filter((n) => n.tagName === "OL")[0].children;
  assert.strictEqual(lis.length, 2);
  assert.ok(lis[0].classList.contains("rec") && !lis[1].classList.contains("rec"));
  assert.ok(node.all().some((n) => n.className === "evx-tag evx-brk"));
});
test("render: the feed's toggles are buttons with aria-expanded, and remember what was opened", () => {
  const open = new Set();
  const root = E.renderFeed(E.parseLog(LOG), { open });
  const btns = root.all().filter((n) => n.tagName === "BUTTON" && n.getAttribute("aria-expanded") !== null);
  assert.ok(btns.length >= 4);
  assert.ok(btns.every((b) => b.getAttribute("aria-expanded") === "false" && b.getAttribute("aria-controls")));
  btns[0].click();
  assert.strictEqual(btns[0].getAttribute("aria-expanded"), "true");
  assert.strictEqual(open.size, 1);
  const again = E.renderFeed(E.parseLog(LOG), { open });
  assert.strictEqual(again.all().filter((n) => n.getAttribute("aria-expanded") === "true").length, 1);
  // the filters: one per kind present, pressed; turning one off hides its items
  const chips = root.all().filter((n) => n.classList.contains("tl-f"));
  assert.deepStrictEqual(chips.map((c) => c.getAttribute("data-k")), ["decision", "blocked", "progress", "waiting", "steered", "system"]);
  const sys = chips.find((c) => c.getAttribute("data-k") === "system");
  sys.click();
  const list = root.all().find((n) => n.tagName === "OL" && n.className === "tl");
  assert.ok(list.children.filter((li) => li.className.includes("tl-noise")).every((li) => li.hidden));
});

run();
