// app/src/read.js, through the initiative page: a slow read is shown though the home's version moves
// while it is under way (a busy crew moves it every few seconds). The real page runs here with a
// stand-in for React's hooks and for fetch; on a page that threw such an answer away it never loads.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const SRC = path.join(__dirname, "../../app/src");

// A module's source as a plain script: its imports and the word export gone.
const plain = (f) => (fs.existsSync(path.join(SRC, f)) ? fs.readFileSync(path.join(SRC, f), "utf8") : "")
  .replace(/^import [^;]*;$/gm, "").replace(/^export /gm, "");

// One mounted component: render(props) runs it and its effects as React would; a set state marks it stale.
function mount(load) {
  const cells = []; let at = 0, effects = [];
  const same = (a, b) => a && b && a.length === b.length && a.every((x, i) => Object.is(x, b[i]));
  const hooks = {
    useState: (v) => { const i = at++; if (!(i in cells)) cells[i] = v; return [cells[i], (x) => { cells[i] = typeof x === "function" ? x(cells[i]) : x; }]; },
    useRef: (v) => { const i = at++; if (!(i in cells)) cells[i] = { current: v }; return cells[i]; },
    useEffect: (fn, deps) => { const i = at++; if (!cells[i] || !same(cells[i].deps, deps)) effects.push(() => { if (cells[i] && cells[i].off) cells[i].off(); cells[i] = { deps, off: fn() }; }); },
  };
  hooks.useMemo = (fn) => fn();
  const C = load(hooks);
  return (props) => { at = 0; effects = []; const out = C(props); for (const e of effects) e(); return out; };
}
const text = (x) => (x == null || x === false || typeof x === "function" ? "" : Array.isArray(x) ? x.map(text).join(" ")
  : typeof x === "object" ? (x.parts ? x.parts.map(text).join(" ") : "") : String(x));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const asked = [];
  const fetch = (url) => new Promise((ok) => asked.push({ url, answer: (j) => ok({ ok: true, json: async () => j }) }));
  const page = mount((hooks) => {
    const ctx = vm.createContext(Object.assign({ fetch, setTimeout, clearTimeout, Date, Promise, Error, console, encodeURIComponent,
      html: (s, ...v) => ({ parts: s.flatMap((x, i) => [x, v[i]]) }),
      window: { AppModel: require("../../app/src/model.js"), Markdown: null }, React: { Fragment: "f" } }, hooks));
    vm.runInContext(["HomeTag", "Status", "Linked", "linkifyDom", "PrBadges", "Tabs", "DecisionList"].map((n) => `const ${n} = () => null;`).join("")
      + plain("read.js") + plain("initiatives.js") + ";globalThis.Page = InitiativePage;", ctx);
    return ctx.Page;
  });
  const show = (version) => text(page({ home: "acme", id: "in-0a1b", version, prs: {}, tasksByHome: {}, cardHref: () => null }));
  const ini = (name) => ({ id: "in-0a1b", name, status: "active", stories: [], decisions: [], task_decisions: [], comments: [], milestones: [], plan: null, progress: { done: 0, total: 0, needs: 0, blocked: 0, proposed: 0 } });

  assert.match(show(1), /Reading the initiative/);
  await wait(20);
  assert.strictEqual(asked.length, 1);
  // the crew moves on three times while that read is under way
  for (const v of [2, 3, 4]) { show(v); await wait(20); }
  asked[0].answer(ini("Fast search"));
  await wait(20);
  assert.match(show(4), /Fast search/, "the answer is shown, though the version moved on");
  assert.strictEqual(asked.length, 1, "no second read beside the first");
  // and it is read again, once, for what changed meanwhile
  await wait(400);
  show(4);
  assert.strictEqual(asked.length, 2, "read again once");
  asked[1].answer(ini("Faster search"));
  await wait(20);
  assert.match(show(4), /Faster search/);
  console.log("ok   a slow read is shown though the version moves, one read at a time");
})().catch((e) => { console.log("FAIL " + String(e.stack || e).split("\n").slice(0, 6).join("\n")); process.exit(1); });
