// read.js - one record (a task's, an initiative's) read from the server and kept fresh. One read at
// a time, and an answer is always shown: the home's version may move while a slow read is under way
// (a busy crew moves it every few seconds), and then it is read again after, with a pause as long as
// the read took, instead of throwing the answer away.
import { useState, useEffect, useRef } from "./html.js";

const SOON = 250, MOST = 30000, GIVE_UP = 70000; // ms; the server gives up on a read at 60 s

// -> {value, err} for the url asked now; value stays up while it is read again.
export function useRead(url, version) {
  const [got, setGot] = useState({ url: null, value: null, err: null });
  const reader = useRef(null);
  useEffect(() => {
    let stopped = false, busy = false, again = false, timer = null;
    const read = () => {
      timer = null; busy = true; again = false;
      const at = Date.now();
      const show = (g) => { if (!stopped) setGot((o) => Object.assign({ url, value: o.url === url ? o.value : null, err: null }, g)); };
      fetch(url, { cache: "no-store", credentials: "same-origin", signal: typeof AbortSignal !== "undefined" && AbortSignal.timeout ? AbortSignal.timeout(GIVE_UP) : undefined })
        .then((r) => (r.ok ? r.json() : r.json().then((j) => Promise.reject(new Error(j.error || r.status)))))
        .then((value) => show({ value }), (e) => show({ err: e.message }))
        .then(() => { busy = false; if (again) soon(Math.min(MOST, Math.max(SOON, Date.now() - at))); });
    };
    const soon = (ms) => { if (!stopped && !timer) timer = setTimeout(read, ms); };
    let first = true;
    reader.current = () => { if (busy) again = true; else soon(first ? 0 : SOON); first = false; };
    return () => { stopped = true; clearTimeout(timer); };
  }, [url]);
  useEffect(() => { reader.current(); }, [url, version]);
  return got.url === url ? got : { value: null, err: null };
}
