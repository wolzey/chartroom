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

self.addEventListener("message", (e) => {
  if (e.data && e.data.type === "notify") e.waitUntil(show(e.data));
  if (e.data && e.data.type === "keep" && Array.isArray(e.data.paths)) e.waitUntil(keep(e.data.paths.slice(0, 200)));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const target = new URL((e.notification.data && e.notification.data.url) || "/", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
    const c = cs.find((x) => new URL(x.url).origin === self.location.origin);
    if (c) return c.focus().then((w) => (w || c).navigate(target));
    return self.clients.openWindow(target);
  }));
});
