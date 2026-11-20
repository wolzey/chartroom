// api.js - the server's API (lib/app/server.py): the state of every home, a stream that says when
// it changed, and the writes. Every write carries X-Chartroom-App, which the server requires.
const WRITE = { "Content-Type": "application/json", "X-Chartroom-App": "1" };

export async function getState() {
  const r = await fetch("/api/v1/state", { cache: "no-store", credentials: "same-origin" });
  if (!r.ok) throw new Error(r.status === 403 ? "This app opens only for its owner." : "The server answered " + r.status);
  return r.json();
}

export async function act(home, action, body) {
  const r = await fetch("/api/v1/homes/" + encodeURIComponent(home) + "/" + action, {
    method: "POST", headers: WRITE, credentials: "same-origin", body: JSON.stringify(body || {}),
  });
  let j = {};
  try { j = await r.json(); } catch (e) { j = {}; }
  if (!r.ok) throw new Error(j.error || "failed (" + r.status + ")");
  return j;
}

export async function taskFile(home, id, name) {
  const r = await fetch("/api/v1/homes/" + encodeURIComponent(home) + "/tasks/" + encodeURIComponent(id) + "/files/" + name,
    { cache: "no-store", credentials: "same-origin" });
  if (r.status === 404 || r.status === 204) return null;
  if (!r.ok) throw new Error("failed (" + r.status + ")");
  return r.text();
}

// Calls onChange whenever the server says a home changed; onLink(true|false) as the stream comes
// and goes. Without a stream (a proxy that buffers it, a phone waking up) it falls back to polling.
export function subscribe(onChange, onLink) {
  let es = null, timer = null, closed = false;
  const poll = () => { if (!closed) { onChange(); timer = setTimeout(poll, 10000); } };
  const open = () => {
    if (closed) return;
    try { es = new EventSource("/api/v1/stream"); } catch (e) { es = null; }
    if (!es) { onLink(false); poll(); return; }
    es.addEventListener("version", () => { onLink(true); onChange(); });
    es.onopen = () => { onLink(true); if (timer) { clearTimeout(timer); timer = null; } };
    es.onerror = () => {
      onLink(false);
      es.close(); es = null;
      if (!timer) timer = setTimeout(() => { timer = null; onChange(); open(); }, 5000);
    };
  };
  open();
  const wake = () => { if (document.visibilityState === "visible") onChange(); };
  document.addEventListener("visibilitychange", wake);
  return () => { closed = true; if (es) es.close(); if (timer) clearTimeout(timer); document.removeEventListener("visibilitychange", wake); };
}
