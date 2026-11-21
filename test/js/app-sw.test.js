// app/sw.js, a notification's tap: it lands on the item whether the app is closed, open in front or
// behind, or open on another page. The real sw.js runs here against stand-ins for the browser's
// clients, caches and windows (a browser test cannot tap a notification).
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SRC = fs.readFileSync(path.join(__dirname, "../../app/sw.js"), "utf8");
const ORIGIN = "https://studio.example.ts.net";
let n = 0, failed = 0;
async function t(name, fn) {
  n++;
  try { await fn(); console.log("ok   " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + String(e.stack || e).split("\n").slice(0, 5).join("\n     ")); }
}

// A window of the app: answers the worker's "open" (a page running this version) or not (an older
// page, or one with no listener), and may or may not take navigate().
function win(url, { listens = true, navigates = true } = {}) {
  const w = { url, focused: 0, told: [], navigated: [] };
  w.focus = async () => { w.focused++; return w; };
  w.postMessage = (msg, ports) => { w.told.push(msg); if (listens && ports && ports[0]) ports[0].postMessage("ok"); };
  w.navigate = async (u) => { if (!navigates) throw new TypeError("not controlled"); w.navigated.push(u); w.url = u; return w; };
  return w;
}

function worker(windows) {
  const handlers = {}, store = new Map(), opened = [];
  const caches = {
    open: async () => ({
      put: async (k, r) => { store.set(String(k), await r.text()); },
      match: async (k) => (store.has(String(k)) ? new Response(store.get(String(k))) : undefined),
      delete: async (k) => store.delete(String(k)),
    }),
    keys: async () => [],
  };
  const self = {
    location: { origin: ORIGIN },
    addEventListener: (type, fn) => { handlers[type] = fn; },
    clients: { matchAll: async () => windows.slice(), openWindow: async (u) => { opened.push(u); return win(u); }, claim: async () => {} },
    registration: { showNotification: async () => {} },
    skipWaiting: () => {},
  };
  vm.runInNewContext(SRC, { self, caches, Response, Headers, URL, MessageChannel, setTimeout, clearTimeout, fetch: async () => { throw new Error("offline"); }, console });
  const fire = async (type, e) => { const ps = []; handlers[type](Object.assign({ waitUntil: (p) => ps.push(p) }, e)); await Promise.all(ps); };
  const tap = (url) => { const note = { data: { url }, closed: 0, close() { this.closed++; } }; return fire("notificationclick", { notification: note }).then(() => note); };
  const starts = (hash) => { const page = { got: [], postMessage(m) { this.got.push(m); } }; return fire("message", { data: { type: "opened", hash }, source: page }).then(() => page); };
  return { tap, starts, opened, store };
}

// the worker builds its messages in its own realm: compare them as data
const plain = (x) => JSON.parse(JSON.stringify(x));
const LINK = "/#/n/acme%3Aev-gift-cards-12";
const TARGET = ORIGIN + LINK;

(async () => {
  await t("closed: a tap opens a window at the item, and a page that starts elsewhere is sent there once", async () => {
    const w = worker([]);
    const note = await w.tap(LINK);
    assert.strictEqual(note.closed, 1);
    assert.deepStrictEqual(w.opened, [TARGET]);
    // the installed app opened at its start page instead: the page asks, and goes to the item
    const p = await w.starts("");
    assert.deepStrictEqual(plain(p.got), [{ type: "open", url: TARGET }]);
    // asked once: a later start is not sent anywhere
    assert.deepStrictEqual((await w.starts("")).got, []);
  });

  await t("closed: a window that opened at the item is not sent there again", async () => {
    const w = worker([]);
    await w.tap(LINK);
    assert.deepStrictEqual((await w.starts("#/n/acme%3Aev-gift-cards-12")).got, []);
  });

  await t("open (in front, behind, or on another page): the window is focused and told where to go; nothing new opens", async () => {
    const page = win(ORIGIN + "/#/board");
    const w = worker([page]);
    await w.tap(LINK);
    assert.strictEqual(page.focused, 1);
    assert.deepStrictEqual(plain(page.told), [{ type: "open", url: TARGET }]);
    assert.deepStrictEqual(page.navigated, []);
    assert.deepStrictEqual(w.opened, []);
  });

  await t("open, but a page that does not answer (one from before this version): it is navigated to the item", async () => {
    const page = win(ORIGIN + "/#/", { listens: false });
    const w = worker([page]);
    await w.tap(LINK);
    assert.deepStrictEqual(page.navigated, [TARGET]);
    assert.deepStrictEqual(w.opened, []);
  });

  await t("open, but neither answering nor navigable: a new window opens at the item", async () => {
    const page = win(ORIGIN + "/#/", { listens: false, navigates: false });
    const w = worker([page]);
    await w.tap(LINK);
    assert.deepStrictEqual(w.opened, [TARGET]);
  });

  await t("another site's window is never used", async () => {
    const other = win("https://elsewhere.example.com/");
    const w = worker([other]);
    await w.tap(LINK);
    assert.deepStrictEqual(other.told, []);
    assert.deepStrictEqual(w.opened, [TARGET]);
  });

  console.log(`${n - failed}/${n} passed`);
  process.exit(failed ? 1 : 0);
})();
