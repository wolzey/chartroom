// lib/dashboard/markdown.js: a report.md as page nodes, tables included, and sanitized.
"use strict";
const assert = require("assert");
const { test, run } = require("./harness");
require("./dom");
const M = require("../../lib/dashboard/markdown.js");

const REPORT = [
  "# Report: DOL outage",
  "",
  "## Outcome",
  "",
  "Cause found: **GH-8414** treats every _Employee_ caller as a portal user. See [the PR](https://example.com/pull/1).",
  "",
  "| Region | Companies | Users |",
  "|:-------|----------:|:-----:|",
  "| UK | 89/103 | 735 |",
  "| AU | 50/55 | `n/a` \\| none |",
  "",
  "1. hotfix",
  "   - gates for portal accounts only",
  "   - [x] tests",
  "2. swap back",
  "",
  "```sh",
  "chartroom event x done \"<b>not bold</b>\"",
  "```",
  "",
  "> quoted *line*",
  "",
  "---",
  "<script>alert(1)</script>",
  "[bad](javascript:alert(1)) and ![chart](https://example.com/x.png) and [anchor](#outcome)",
].join("\n");

test("blocks: headings, paragraph, table, nested list, code, quote, rule", () => {
  const b = M.parse(REPORT);
  assert.deepStrictEqual(b.map((x) => x.t), ["h", "h", "p", "table", "list", "code", "quote", "hr", "p"]);
  const t = b[3];
  assert.deepStrictEqual(t.align, ["left", "right", "center"]);
  assert.strictEqual(t.rows.length, 2);
  assert.deepStrictEqual(t.rows[1][2].map((n) => n.t), ["code", "text"]);
  assert.strictEqual(t.rows[1][2][1].v, " | none");
  const l = b[4];
  assert.strictEqual(l.ordered, true);
  assert.strictEqual(l.items.length, 2);
  assert.deepStrictEqual(l.items[0].b.map((x) => x.t), ["p", "list"]);
  assert.deepStrictEqual(l.items[0].b[1].items.map((i) => i.check), [null, true]);
  assert.strictEqual(b[5].v, 'chartroom event x done "<b>not bold</b>"');
});
test("inline: strong, em, code, links; snake_case is not emphasis", () => {
  const n = M.inline("a **b** _c_ `d` [e](https://x.y) snake_case_name ~~f~~");
  assert.deepStrictEqual(n.map((x) => x.t), ["text", "strong", "text", "em", "text", "code", "text", "link", "text", "del"]);
  assert.ok(n.some((x) => x.t === "text" && x.v.includes("snake_case_name")));
});
test("render: sanitized; raw HTML is text, only http(s) and #anchors link, images are named", () => {
  const root = document.createElement("div");
  root.append(M.render(M.parse(REPORT), { shift: 1 }));
  const all = root.all();
  assert.ok(!all.some((n) => /^(SCRIPT|IMG|IFRAME|STYLE)$/.test(n.tagName)));
  assert.ok(root.textContent.includes("<script>alert(1)</script>"));
  const hrefs = all.filter((n) => n.tagName === "A").map((a) => a.getAttribute("href"));
  assert.deepStrictEqual(hrefs, ["https://example.com/pull/1", "#outcome"]);
  assert.ok(root.textContent.includes("[image: chart]"));
  assert.deepStrictEqual(all.filter((n) => /^H\d$/.test(n.tagName)).map((n) => n.tagName), ["H2", "H3"]);
  assert.strictEqual(all.filter((n) => n.tagName === "TH").length, 3);
  const ext = all.find((a) => a.tagName === "A" && /^https/.test(a.getAttribute("href")));
  assert.strictEqual(ext.getAttribute("rel"), "noopener noreferrer");
});
test("section: a brief's commander's intent, without its HTML comment", () => {
  const brief = "# T\n\n## Commander's intent\n\n<!-- The commander's own words -->\nPlease make it readable.\n\nAnd printable.\n\n## Spec\n\nstuff";
  assert.strictEqual(M.section(brief, "Commander's intent"), "Please make it readable.\n\nAnd printable.");
  assert.strictEqual(M.section(brief, "Nope"), "");
});
test("garbage: never throws", () => {
  for (const g of ["", "|", "| a |\n|---|", "```", "* ", "1.", "> > >", "[x](", "**", "~~~\nx", "\u0000", "#".repeat(9), "- [ ]", "|a|b|\n|-|-|\n" + "|x".repeat(500)]) {
    const root = document.createElement("div");
    root.append(M.render(M.parse(g)));
  }
});

run();
