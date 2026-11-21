// notify.js - the installable app and its notifications (slice 6).
// - register(): the service worker (/sw.js), where the browser allows one (https, or localhost).
// - Local notifications: while the app is open in the background, a new Needs me item shows one,
//   through the service worker (a phone allows no page-made notification). No third party.
// - Web Push: when the brain has it on (APP_PUSH=on) and this device subscribed, the server sends
//   new items through the browser's push service, encrypted end to end, even with the app closed.
// Permission is asked only from a click.
const WRITE = { "Content-Type": "application/json", "X-Chartroom-App": "1" };

export function supported() {
  return typeof window !== "undefined" && "Notification" in window && "serviceWorker" in navigator && window.isSecureContext;
}
export function permission() { return supported() ? Notification.permission : "unsupported"; }

let reg = null;
export async function register() {
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return null;
  try { reg = await navigator.serviceWorker.register("/sw.js", { scope: "/" }); } catch (e) { reg = null; }
  if (reg) {
    // the shell this page loaded, for the worker to keep (it opens offline from these)
    const paths = ["/"].concat(performance.getEntriesByType("resource").map((r) => new URL(r.name))
      .filter((u) => u.origin === location.origin && !u.pathname.startsWith("/api/")).map((u) => u.pathname));
    navigator.serviceWorker.ready.then((r) => r.active && r.active.postMessage({ type: "keep", paths: [...new Set(paths)] })).catch(() => null);
  }
  return reg;
}

export async function enable() {
  if (!supported()) return "unsupported";
  const p = await Notification.requestPermission();
  return p;
}

// One notification per item, the item's key as its tag (a push of the same item replaces it).
export async function show(n) {
  if (permission() !== "granted") return false;
  const r = reg || (await navigator.serviceWorker.getRegistration("/"));
  if (!r) return false;
  await r.showNotification(n.title, { body: n.body, tag: n.tag, icon: "/app/icons/icon-192.png", badge: "/app/icons/icon-192.png", data: { url: n.url } });
  return true;
}

// Web Push: the brain's state (available on this brain, on in its config, its public key).
export async function pushInfo() {
  try { const r = await fetch("/api/v1/push", { cache: "no-store", credentials: "same-origin" }); return r.ok ? r.json() : null; } catch (e) { return null; }
}

function keyBytes(b64) {
  const s = atob(b64.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (b64.length % 4)) % 4));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

export async function subscribe(publicKey) {
  const r = reg || (await navigator.serviceWorker.ready);
  let sub = await r.pushManager.getSubscription();
  if (!sub) sub = await r.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(publicKey) });
  const res = await fetch("/api/v1/push/subscribe", { method: "POST", headers: WRITE, credentials: "same-origin", body: JSON.stringify(sub.toJSON()) });
  if (!res.ok) throw new Error("the server refused the subscription (" + res.status + ")");
  return true;
}

export async function unsubscribe() {
  const r = reg || (await navigator.serviceWorker.getRegistration("/"));
  const sub = r && (await r.pushManager.getSubscription());
  if (!sub) return false;
  await fetch("/api/v1/push/unsubscribe", { method: "POST", headers: WRITE, credentials: "same-origin", body: JSON.stringify({ endpoint: sub.endpoint }) });
  await sub.unsubscribe();
  return true;
}

export async function subscribed() {
  try {
    const r = reg || (await navigator.serviceWorker.getRegistration("/"));
    return !!(r && r.pushManager && (await r.pushManager.getSubscription()));
  } catch (e) { return false; }
}
