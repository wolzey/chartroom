// The app's text is readable: every text colour of direction A, light and dark, measures at least
// 4.5:1 (WCAG AA for body text) against every surface it is drawn on, as the browser would resolve
// the custom properties: app/styles/tokens.css first, then app/styles/app.css's overrides.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const { test, run } = require("./harness");

const STYLES = path.join(__dirname, "..", "..", "app", "styles");
const css = ["tokens.css", "app.css"].map((f) => fs.readFileSync(path.join(STYLES, f), "utf8")).join("\n");

// The custom properties a theme of direction A ends up with: the matching rules, in source order.
function vars(theme) {
  const out = {};
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  const clean = css.replace(/\/\*[\s\S]*?\*\//g, "");
  while ((m = re.exec(clean))) {
    const sel = m[1].trim();
    const applies = sel === ":root" || sel === '[data-dir="a"]' || (theme === "dark" && sel === '[data-dir="a"][data-theme="dark"]');
    if (!applies) continue;
    for (const d of m[2].split(";")) {
      const kv = /^\s*(--[a-z0-9-]+)\s*:\s*(.+?)\s*$/.exec(d);
      if (kv) out[kv[1]] = kv[2];
    }
  }
  // a later, more specific rule wins over an earlier one for the dark theme
  if (theme === "dark") {
    let mm;
    re.lastIndex = 0;
    while ((mm = re.exec(clean))) {
      if (mm[1].trim() !== '[data-dir="a"][data-theme="dark"]') continue;
      for (const d of mm[2].split(";")) {
        const kv = /^\s*(--[a-z0-9-]+)\s*:\s*(.+?)\s*$/.exec(d);
        if (kv) out[kv[1]] = kv[2];
      }
    }
  }
  return out;
}

function parse(c) {
  let m = /^#([0-9a-f]{6})$/i.exec(c);
  if (m) return { rgb: [0, 2, 4].map((i) => parseInt(m[1].substr(i, 2), 16)), a: 1 };
  m = /^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([.\d]+)\s*\)$/i.exec(c);
  if (m) return { rgb: [+m[1], +m[2], +m[3]], a: +m[4] };
  throw new Error("unparsed colour " + c);
}
function over(fg, bg) { return fg.rgb.map((v, i) => v * fg.a + bg[i] * (1 - fg.a)); }
function lum(rgb) {
  const c = rgb.map((v) => v / 255).map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
function ratio(a, b) { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }

const SURFACES = ["--bg", "--surface", "--sunken", "--hover", "--selected"];
// text colours, and the tinted fill each is also drawn on (a pill, a chip, a status line)
const TEXTS = { "--text": null, "--text-2": null, "--text-3": null, "--accent-text": "--accent-soft",
  "--amber": "--amber-soft", "--rose": "--rose-soft", "--green": "--green-soft", "--blue": "--blue-soft", "--purple": "--purple-soft" };

for (const theme of ["light", "dark"]) {
  test(theme + ": every text colour is at least 4.5:1 on every surface and on its own tint", () => {
    const v = vars(theme);
    const fails = [];
    for (const [t, tint] of Object.entries(TEXTS)) {
      const fg = parse(v[t]).rgb;
      const backs = SURFACES.map((s) => [s, parse(v[s]).rgb]);
      if (tint) for (const s of ["--surface", "--bg"]) backs.push([tint + " on " + s, over(parse(v[tint]), parse(v[s]).rgb)]);
      for (const [name, bg] of backs) {
        const r = ratio(fg, bg);
        if (r < 4.5) fails.push(t + " on " + name + " = " + r.toFixed(2) + ":1");
      }
    }
    assert.deepStrictEqual(fails, []);
  });
}

test("the override is real: the prototype's own --text-3 would fail, so the test can", () => {
  assert.ok(ratio(parse("#8b8e97").rgb, parse("#ffffff").rgb) < 4.5);
  assert.ok(ratio(parse("#6e717a").rgb, parse("#15161a").rgb) < 4.5);
});

run();
