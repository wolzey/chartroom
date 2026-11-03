// mods/herdr-chartroom/xo.js: which terminal is a home's XO, and what the Tasks panel types into it.
// The mod is an ES module (the Herdr app loads it so); its helpers import nothing, so this loads
// the file with its `export`s dropped and runs it in a fresh context.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { test, run } = require("./harness");

const src = fs.readFileSync(path.join(__dirname, "../../mods/herdr-chartroom/xo.js"), "utf8").replace(/^export /gm, "");
const X = vm.runInNewContext(`${src}\n;({ normPath, statusOf, appOf, findXo, continueLine, sendRefusal })`, {});

const HOME = "/srv/chartroom/acme";
const claude = { key: "claude", name: "Claude Code", shell: false, agent: true };
const codex = { key: "codex", name: "Codex", shell: false, agent: true };
const zsh = { key: "shell", name: "zsh", shell: true, agent: false };
// A terminal as the app's terminals() gives it: status a word, the agent's report in `report`.
function term(address, x) {
  return Object.assign({ address, state: "live", cwd: HOME, status: null, report: null, program: zsh, labels: {}, status_ms: 0 }, x || {});
}
const xoClaude = (address, x) => term(address, Object.assign({ status: "idle", report: { app: "claude-code", state: "idle" }, program: claude, labels: { "herdr.tab": "tb1" } }, x || {}));

test("normPath: trailing slashes and macOS's /private/tmp and /private/var", () => {
  assert.strictEqual(X.normPath("/srv/chartroom/acme/"), HOME);
  assert.strictEqual(X.normPath("/private/tmp"), "/tmp");
  assert.strictEqual(X.normPath("/private/var/folders/x"), "/var/folders/x");
  assert.strictEqual(X.normPath("/private/etc"), "/private/etc");
  assert.strictEqual(X.normPath("/"), "/");
  assert.strictEqual(X.normPath(null), "");
});

test("findXo: the agent in the home's own folder; workers in worktrees never match", () => {
  const ts = [
    term("t1", { cwd: "/srv/chartroom/acme/worktrees/web/fix-1-0001", program: claude, status: "working", report: { app: "claude-code" } }),
    term("t2", { cwd: "/srv/chartroom/other", program: claude, status: "idle", report: { app: "claude-code" } }),
    xoClaude("t3"),
  ];
  const r = X.findXo(ts, HOME + "/");
  assert.strictEqual(r.xo.address, "t3");
  assert.strictEqual(r.app, "claude-code");
  assert.strictEqual(r.status, "idle");
});

test("findXo: no terminal there, or only finished ones and other machines' -> none", () => {
  // (.why, not deepStrictEqual: the helpers' objects come from another vm context)
  assert.strictEqual(X.findXo([], HOME).why, "none");
  assert.strictEqual(X.findXo([xoClaude("t3", { state: "finished" }), xoClaude("studio/t4")], HOME).why, "none");
  assert.strictEqual(X.findXo([xoClaude("t3")], "").why, "none");
  assert.strictEqual(X.findXo(null, HOME).why, "none");
});

test("findXo: only a shell prompt in the home (the XO exited) -> shell, nothing to type into", () => {
  const r = X.findXo([term("t26")], HOME);
  assert.strictEqual(r.why, "shell");
  assert.strictEqual(r.terminal.address, "t26");
  // A plain program (an editor) is no XO either.
  assert.strictEqual(X.findXo([term("t9", { program: { key: "nvim", shell: false, agent: false } })], HOME).why, "shell");
});

test("findXo: Claude Code or Codex over another agent and a shell, then the one the app shows, then the latest", () => {
  const pi = term("t5", { status: "idle", report: { app: "pi" }, program: { key: "pi", shell: false, agent: true }, labels: { "herdr.tab": "tb5" } });
  assert.strictEqual(X.findXo([term("t4"), pi, xoClaude("t6", { labels: {} })], HOME).xo.address, "t6");
  assert.strictEqual(X.findXo([xoClaude("t7", { labels: {} }), xoClaude("t8")], HOME).xo.address, "t8");
  assert.strictEqual(X.findXo([xoClaude("t7", { status_ms: 5 }), xoClaude("t8", { status_ms: 9 })], HOME).xo.address, "t8");
  assert.strictEqual(X.findXo([term("t4"), pi], HOME).xo.address, "t5");
});

test("findXo: a blocked XO is still found (the caller shows it and types nothing); its status says so", () => {
  const r = X.findXo([xoClaude("t2v", { status: "blocked", report: { app: "claude-code", state: "blocked", kind: "question" } })], HOME);
  assert.strictEqual(r.xo.address, "t2v");
  assert.strictEqual(r.status, "blocked");
});

test("findXo: hc get's shape too (status as an object), and a folder only the foreground reports", () => {
  const r = X.findXo([term("t3", { cwd: "/somewhere/else", foreground: { cwd: HOME }, status: { app: "codex", state: "working" }, program: undefined })], HOME);
  assert.strictEqual(r.xo.address, "t3");
  assert.strictEqual(r.app, "codex");
  assert.strictEqual(r.status, "working");
});

test("appOf: the agent's report, else the program table's key", () => {
  assert.strictEqual(X.appOf(term("t1", { program: codex })), "codex");
  assert.strictEqual(X.appOf(term("t1", { program: claude })), "claude-code");
  assert.strictEqual(X.appOf(term("t1")), "shell");
  assert.strictEqual(X.appOf(term("t1", { program: { key: "program", shell: false, agent: false } })), "program");
});

test("continueLine: the full id, with Codex's $ and Claude Code's /", () => {
  assert.strictEqual(X.continueLine("fix-login-redirect-21ba", "claude-code"), "/continue fix-login-redirect-21ba");
  assert.strictEqual(X.continueLine("fix-login-redirect-21ba", "codex"), "$continue fix-login-redirect-21ba");
  assert.strictEqual(X.continueLine("fix-login-redirect-21ba", "pi"), "/continue fix-login-redirect-21ba");
});

test("sendRefusal: hc send's exit codes, then its JSON message, then its first line", () => {
  assert.match(X.sendRefusal(9, ""), /waiting on a question or permission, so nothing was sent/);
  assert.strictEqual(X.sendRefusal(3, ""), "is gone");
  assert.strictEqual(X.sendRefusal(11, ""), "is gone");
  assert.strictEqual(X.sendRefusal(1, '{"error":{"kind":"x","message":"core not running"}}'), "refused: core not running");
  assert.strictEqual(X.sendRefusal(1, "boom\nmore"), "refused: boom");
  assert.strictEqual(X.sendRefusal(2, ""), "refused (hc send exited 2)");
});

run();
