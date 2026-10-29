// A minimal test runner for the dashboard's shared scripts (test/dashboard-js.bats runs each
// *.test.js under node): test(name, fn) records, run() prints one line per test and exits 1 on
// any failure. Node's own assert does the checking.
"use strict";
const tests = [];
function test(name, fn) { tests.push({ name, fn }); }
function run() {
  let failed = 0;
  for (const { name, fn } of tests) {
    try { fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + String(e && e.stack || e).split("\n").slice(0, 6).join("\n     ")); }
  }
  console.log(tests.length - failed + "/" + tests.length + " passed");
  if (failed) process.exit(1);
}
// Letters and digits only, lowercased: what "no word lost" compares.
function words(s) { return String(s).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(); }
module.exports = { test, run, words };
