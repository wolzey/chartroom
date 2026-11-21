// sw.js - the app's service worker (slice 6), served at /sw.js so it controls the whole app.
// - The shell (/, /app/, /shared/, the manifest): network first, so a new version shows at once;
//   the last copy when the network is gone (an offline shell).
// - GET /api/v1/state: network first; when the network is gone, the last state read, marked with
//   X-Chartroom-Offline so the page says how old it is. Never served instead of a refusal.
// - Every other /api/ request, and the stream, is never cached or touched.
// - Notifications: a push (Web Push, when it is on) or a message from the open page (local
//   notifications) shows one; tapping it opens the app at the item.
const CACHE = "chartroom-1";
const STATE = "/api/v1/state";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

function shell(path) {
  return path === "/" || path === "/index.html" || path === "/manifest.webmanifest" || path.startsWith("/app/") || path.startsWith("/shared/");
}

async function networkFirst(req, key, offline) {
  const cache = await caches.open(CACHE);
  try {
    const r = await fetch(req);
    if (r.ok) await cache.put(key, r.clone());
    return r;
  } catch (err) {
    const hit = await cache.match(key);
    if (!hit) throw err;
    if (!offline) return hit;
    const h = new Headers(hit.headers);
    h.set("X-Chartroom-Offline", hit.headers.get("Date") || "unknown");
    return new Response(await hit.blob(), { status: 200, headers: h });
  }
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin) return;
  if (url.pathname === STATE) { e.respondWith(networkFirst(req, STATE, true)); return; }
  if (url.pathname.startsWith("/api/")) return;
  // the app's own page is the one navigation kept (as "/"); any other (an attachment opened in a
  // tab, /sw.js typed in the bar) goes to the network untouched, never into the shell's place
  if (req.mode === "navigate") {
    if (url.pathname === "/" || url.pathname === "/index.html") e.respondWith(networkFirst(req, "/", false));
    return;
  }
  if (shell(url.pathname)) e.respondWith(networkFirst(req, url.pathname, false));
});

function show(n) {
  return self.registration.showNotification(n.title || "Chartroom", {
    body: n.body || "", tag: n.tag || undefined, renotify: false,
    icon: "/app/icons/icon-192.png", badge: "/app/icons/icon-192.png", data: { url: n.url || "/" },
  });
}

self.addEventListener("push", (e) => {
  let n = {};
  try { n = e.data ? e.data.json() : {}; } catch (err) { n = { title: "Chartroom", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(show(n));
});

// The page's first load happens before this worker controls it, so the page says what it loaded
// (its shell files) and they are cached here: the shell opens offline with no list to keep in step.
async function keep(paths) {
  const cache = await caches.open(CACHE);
  for (const p of paths) {
    if (typeof p !== "string" || !(shell(p) || p === "/")) continue;
    try { const r = await fetch(p, { cache: "no-store" }); if (r.ok) await cache.put(p, r); } catch (err) { /* offline already */ }
  }
}

// A tap lands on the item, whatever state the app is in:
// - open (in front, behind, or on another page): the window is focused and told where to go, and
//   says it heard (navigate() fails for a window this worker does not control, and Safari has none);
//   a window that does not answer (a page from before this worker) is navigated, or a new one opens;
// - closed: a new window opens at the item. The target is also kept a little while, because an
//   installed app may open at its start page instead: the page asks for it as it starts.
const PENDING = "/__chartroom-open";
const PENDING_MS = 2 * 60 * 1000;

function tell(c, url) {
  return new Promise((resolve) => {
    const ch = new MessageChannel();
    const t = setTimeout(() => resolve(false), 1500);
    ch.port1.onmessage = () => { clearTimeout(t); resolve(true); };
    try { c.postMessage({ type: "open", url }, [ch.port2]); } catch (err) { clearTimeout(t); resolve(false); }
  });
}

async function remember(url) {
  try { await (await caches.open(CACHE)).put(PENDING, new Response(JSON.stringify({ url, at: Date.now() }))); } catch (err) { /* no storage */ }
}
async function pending() {
  try {
    const cache = await caches.open(CACHE);
    const r = await cache.match(PENDING);
    if (!r) return null;
    await cache.delete(PENDING);
    const p = await r.json();
    return p && Date.now() - p.at < PENDING_MS ? p.url : null;
  } catch (err) { return null; }
}

async function openAt(url) {
  const target = new URL(url || "/", self.location.origin).href;
  const cs = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  const c = cs.find((x) => new URL(x.url).origin === self.location.origin);
  if (c) {
    try { await c.focus(); } catch (err) { /* focus is a hint */ }
    if (await tell(c, target)) return "told";
    if (typeof c.navigate === "function") { try { await c.navigate(target); return "navigated"; } catch (err) { /* not controlled */ } }
  }
  await remember(target);
  await self.clients.openWindow(target);
  return "opened";
}
self.openAt = openAt; // for the browser test, which cannot tap a notification

self.addEventListener("message", (e) => {
  if (e.data && e.data.type === "notify") e.waitUntil(show(e.data));
  if (e.data && e.data.type === "keep" && Array.isArray(e.data.paths)) e.waitUntil(keep(e.data.paths.slice(0, 200)));
  // a page starting: the item a tap opened it for, unless it opened there already
  if (e.data && e.data.type === "opened" && e.source) {
    e.waitUntil(pending().then((url) => {
      if (url && new URL(url).hash !== (e.data.hash || "")) e.source.postMessage({ type: "open", url });
    }));
  }
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil(openAt((e.notification.data && e.notification.data.url) || "/"));
});
