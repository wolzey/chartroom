#!/usr/bin/env python3
"""chartroom app server: the app (app/) and its API for every home on this machine, stdlib only.

Started by `chartroom app serve`; do not run it by hand. It binds 127.0.0.1 only. Tailscale Serve
puts it on the tailnet over HTTPS and names the person at each request (Tailscale-User-Login); only
--user gets in. With --no-auth (this machine's own browser, before Serve is set up) a request must
come straight to 127.0.0.1 or localhost: anything that came through a proxy is refused.

What a task or an item means is never decided here. Each home is read by `chartroom app snapshot
--json` (lib/app.sh, lib/app/snapshot.jq) in a background thread per home, again whenever the
home's change stamp moves and at least every REFRESH_MAX seconds, and the latest snapshot is
served. Every write runs a chartroom verb in that home (FIXED argv; the commander's words go on
stdin), so the CLI stays the one writer of the records and a client home's rules stay the brain's.

  /                         app/index.html
  /app/<path>               app/ files (styles, src, vendor)
  /shared/<file>.js         lib/dashboard's shared scripts (eventfmt.js, markdown.js)
  /healthz                  "ok" (no identity needed)
  GET  /api/v1/state        {api, version, user, homes: [{name, path, ok, error, refreshed_at, snapshot}]}
  GET  /api/v1/stream       server-sent events: "version" when any home's snapshot changes
  GET  /api/v1/homes/<home>/tasks/<id>/files/<brief.md|plan.md|report.md|events.log>
  POST /api/v1/homes/<home>/<tell|answer|accept|close|snooze|unsnooze|done>   (JSON body)
                            202 at once: the verb runs in the background, in order per home;
                            X-Chartroom-Action names it, so a retry is never a second run
Python 3.9+ (macOS /usr/bin/python3 is 3.9).
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

API = 1
LOOPBACK = "127.0.0.1"
POLL = 2.0  # seconds between looks at a home's change stamp
REFRESH_MAX = 20.0  # while someone looks: a snapshot at least this often (live states change with no record written)
IDLE_AFTER = 300.0  # no page has asked for the state this long: read only when records change
IDLE_GAP = 60.0  # and then at most this often
SNAPSHOT_TIMEOUT = 180
VERB_TIMEOUT = 90
BODY_MAX = 256 * 1024
TASK_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,127}$")
HOME_NAME = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
CARD = re.compile(r"^(q-[0-9a-f]{4,}|i-[0-9a-f]{4,}|ev-[a-z0-9][a-z0-9-]{0,127}-[0-9]{1,12})$")
INBOX_ID = re.compile(r"^i-[0-9a-f]{4,}$")
ARTIFACT_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,127}/[a-z0-9][a-z0-9-]{0,79}$")
DURATION = re.compile(r"^[0-9]{1,4}[mhd]$")
UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
TASK_FILES = ("brief.md", "plan.md", "report.md", "events.log")
STATIC_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
                ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json", ".webmanifest": "application/manifest+json",
                ".txt": "text/plain; charset=utf-8", ".woff2": "font/woff2", ".ico": "image/x-icon"}
SHARED = ("eventfmt.js", "markdown.js")
CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
       "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t if t is not None else time.time()))


def child_env(home=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CHARTROOM_TASK", "CLAUDE", "HC_", "HERDR_PANE"))}
    if home:
        env["CHARTROOM_HOME"] = home
    return env


def run(argv, home, stdin=None, timeout=VERB_TIMEOUT):
    """A chartroom verb in <home>: (code, stdout, stderr)."""
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, timeout=timeout, env=child_env(home), cwd=home)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ds" % timeout
    except OSError as exc:
        return 127, "", str(exc)


def last_line(text):
    """What went wrong, from a verb's stderr: its first "chartroom: ..." line (the reason; what
    follows is advice), else its last line."""
    lines = [x for x in text.strip().splitlines() if x.strip()]
    said = [x for x in lines if x.startswith("chartroom: ")]
    return re.sub(r"^chartroom: ", "", (said or lines or [""])[0] if said else lines[-1]) if lines else ""


class Home:
    def __init__(self, name, path):
        self.name, self.path = name, path
        self.snapshot = None  # parsed
        self.raw = None
        self.ok = False
        self.error = None
        self.refreshed_at = None
        self.took = None
        self.wake = threading.Event()

    def stamp(self):
        """What changes when a record does: the home's change stamp and the files the app writes."""
        out = []
        for rel in (".changed", "relays/inbox.ndjson", "snoozes.ndjson", "questions", "inbox.md", "focus.json"):
            try:
                st = os.stat(os.path.join(self.path, rel))
                out.append((rel, st.st_mtime_ns, st.st_size))
            except OSError:
                out.append((rel, None, None))
        return tuple(out)


class Hub:
    """Every home's latest snapshot, a version that moves on each change, and the SSE waiters."""

    def __init__(self, cli):
        self.cli = cli
        self.homes = {}
        self.order = []
        self.version = 0
        self.cond = threading.Condition()
        self.seen_at = 0.0  # when a page last asked for the state or held the stream

    def looked(self):
        self.seen_at = time.time()

    def watched(self):
        return time.time() - self.seen_at < IDLE_AFTER

    def discover(self):
        code, out, err = run([self.cli, "homes", "--json"], os.environ.get("CHARTROOM_HOME"), timeout=30)
        rows = []
        if code == 0:
            try:
                rows = json.loads(out)
            except ValueError:
                rows = []
        found = []
        for r in rows if isinstance(rows, list) else []:
            if not isinstance(r, dict) or not r.get("exists") or not r.get("is_home") or r.get("brain"):
                continue  # a client home's records live on its brain: the app runs there
            name, path = r.get("name") or os.path.basename(str(r.get("path", ""))), r.get("path")
            if name and path and HOME_NAME.match(name) and name not in [n for n, _ in found]:
                found.append((name, path))
        for name, path in found:
            if name not in self.homes:
                self.homes[name] = Home(name, path)
                self.order.append(name)
                threading.Thread(target=self.loop, args=(self.homes[name],), daemon=True).start()
        return found

    def bump(self):
        with self.cond:
            self.version += 1
            self.cond.notify_all()

    def collect(self, h):
        t0 = time.time()
        code, out, err = run([self.cli, "app", "snapshot", "--json"], h.path, timeout=SNAPSHOT_TIMEOUT)
        h.took = round(time.time() - t0, 2)
        if code != 0:
            h.ok, h.error = False, last_line(err) or "snapshot failed (exit %d)" % code
            self.bump()
            return
        try:
            snap = json.loads(out)
        except ValueError:
            h.ok, h.error = False, "the snapshot was not JSON"
            self.bump()
            return
        changed = out != h.raw or not h.ok
        h.snapshot, h.raw, h.ok, h.error, h.refreshed_at = snap, out, True, None, iso()
        if changed:
            self.bump()

    def loop(self, h):
        """Read the home when its records change, when a write was made here, and, while someone
        looks, at least every REFRESH_MAX seconds. A read never starts sooner than its own last
        duration after the previous one (so a big home costs at most half a core), and with nobody
        looking, at most every IDLE_GAP seconds."""
        seen, last = None, 0.0
        while True:
            now = time.time()
            st = h.stamp()
            watched = self.watched()
            gap = (h.took or 0) if watched else max(IDLE_GAP, (h.took or 0) * 4)
            due = h.wake.is_set() or h.snapshot is None or (
                now - last >= gap and (st != seen or (watched and now - last >= max(REFRESH_MAX, (h.took or 0) * 2))))
            if due:
                h.wake.clear()
                last = now
                self.collect(h)
                seen = st  # the stamp from before the read: a change made during it is read next time
            h.wake.wait(POLL)

    def state(self):
        return {"api": API, "version": self.version, "generated_at": iso(),
                "homes": [{"name": h.name, "path": h.path, "ok": h.ok, "error": h.error, "refreshed_at": h.refreshed_at,
                           "took": h.took, "snapshot": h.snapshot} for h in (self.homes[n] for n in self.order)]}

    def refresh(self, name):
        h = self.homes.get(name)
        if h:
            h.wake.set()


ACTION_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")
ACTIONS_KEPT = 400  # finished actions remembered (and journaled) for dedupe and for the page's outbox


class Actions:
    """Writes, accepted at once and run in the background: one queue and one worker per home, so a
    home's actions run in the order they came, and the page never waits on the CLI. Each action has
    the id the page gave it; a retry with the same id is the same action, never a second run. The
    journal (app-actions.ndjson beside the pid file, 0600) keeps them across a restart: an accepted
    action that never finished runs when the server starts again, and a finished one is not rerun."""

    def __init__(self, hub, cli, journal):
        self.hub, self.cli, self.journal = hub, cli, journal
        self.recs = {}
        self.order = []
        self.queues = {}
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        pending = []
        if journal and os.path.isfile(journal):
            with open(journal, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and isinstance(r.get("id"), str):
                        self.remember(dict(self.recs.get(r["id"], {}), **r))
            pending = [r for r in (self.recs[i] for i in self.order) if r.get("state") in ("queued", "running")]
            self.compact()
        for r in pending:
            r["state"] = "queued"
            self.enqueue(r)

    def remember(self, r):
        if r["id"] not in self.recs:
            self.order.append(r["id"])
        self.recs[r["id"]] = r
        while len(self.order) > ACTIONS_KEPT:
            old = self.order.pop(0)
            if self.recs.get(old, {}).get("state") in ("queued", "running"):
                self.order.insert(0, old)
                break
            self.recs.pop(old, None)

    def write(self, r):
        if not self.journal:
            return
        try:
            fd = os.open(self.journal, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(r, separators=(",", ":")) + "\n")
        except OSError:
            pass

    def compact(self):
        if not self.journal:
            return
        tmp = self.journal + ".tmp"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                for i in self.order:
                    fh.write(json.dumps(self.recs[i], separators=(",", ":")) + "\n")
            os.replace(tmp, self.journal)
        except OSError:
            pass

    def submit(self, aid, home, action, argv, stdin, cleanup=None):
        """-> the action's record: a new one queued now, or the one already known by that id."""
        with self.lock:
            known = self.recs.get(aid)
            if known:
                return known
            r = {"id": aid, "home": home, "action": action, "argv": argv,
                 "stdin": stdin.decode("utf-8") if stdin is not None else None, "cleanup": cleanup,
                 "state": "queued", "error": None, "at": iso(), "done_at": None}
            self.remember(r)
            self.write(r)
        self.enqueue(r)
        self.hub.bump()
        return r

    def enqueue(self, r):
        with self.lock:
            q = self.queues.get(r["home"])
            if q is None:
                q = self.queues[r["home"]] = []
                threading.Thread(target=self.worker, args=(r["home"],), daemon=True).start()
            q.append(r["id"])
            self.cond.notify_all()

    def worker(self, home):
        while True:
            with self.lock:
                while not self.queues[home]:
                    self.cond.wait()
                aid = self.queues[home].pop(0)
                r = self.recs.get(aid)
                if not r or r["state"] not in ("queued",):
                    continue
                r["state"] = "running"
            h = self.hub.homes.get(home)
            if not h:
                code, out, err = 1, "", "no home named " + home
            else:
                stdin = r["stdin"].encode("utf-8") if r.get("stdin") is not None else None
                code, out, err = run([self.cli] + r["argv"], h.path, stdin=stdin)
            if r.get("cleanup"):
                try:
                    os.remove(r["cleanup"])
                except OSError:
                    pass
            with self.lock:
                r["state"] = "done" if code == 0 else "failed"
                r["error"] = None if code == 0 else (last_line(err) or "failed (exit %d)" % code)
                r["out"] = out.strip()[-500:] if code == 0 else None
                r["done_at"] = iso()
                self.write(r)
            if h:
                self.hub.refresh(home)
            self.hub.bump()

    def recent(self):
        with self.lock:
            return {i: {k: self.recs[i].get(k) for k in ("state", "error", "at", "done_at", "home", "action")} for i in self.order[-200:]}


# The writes: each is one chartroom verb with a fixed argv shape; text goes on stdin.
def verb_for(action, body):
    """-> (argv after the binary, stdin bytes or None) or raises ValueError with what is wrong."""
    def need(key, pattern, what):
        v = body.get(key)
        if not isinstance(v, str) or not pattern.match(v):
            raise ValueError("%s: %s" % (key, what))
        return v

    if action == "tell":
        text = body.get("text")
        if not isinstance(text, str) or not text.strip():
            raise ValueError("text: the message is empty")
        argv = ["tell", "--via", "app"]
        if body.get("re"):
            argv += ["--re", need("re", REF, "an id")]
        if body.get("project"):
            argv += ["--project", need("project", re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"), "a project name")]
        return argv + ["-"], text.encode("utf-8")
    if action == "answer":
        card = need("card", CARD, "a card id (q-…, i-…, ev-…)")
        ans = {k: body[k] for k in ("answers", "action", "note") if k in body}
        return ["ask", "answer", card, "--via", "app", "-"], json.dumps(ans).encode("utf-8")
    if action in ("accept", "close"):
        return [action, need("task", TASK_ID, "a task id")], None
    if action == "snooze":
        ref = need("ref", REF, "an item's id")
        if body.get("for"):
            return ["snooze", ref, "--for", need("for", DURATION, "30m, 4h or 2d")], None
        return ["snooze", ref, "--until", need("until", UTC, "a UTC time")], None
    if action == "unsnooze":
        return ["snooze", "off", need("ref", REF, "an item's id")], None
    if action == "done":
        ref = body.get("ref")
        if isinstance(ref, str) and INBOX_ID.match(ref):
            return ["todo", "done", ref], None
        if isinstance(ref, str) and ARTIFACT_REF.match(ref):
            return ["artifact", "done", ref], None
        raise ValueError("ref: an inbox item (i-xxxx) or an artifact (<id>/<slug>)")
    raise KeyError(action)


def make_handler(hub, args, root, actions):
    app_dir = os.path.join(root, "app")
    shared_dir = os.path.join(root, "lib", "dashboard")
    user = (args.user or "").strip().lower()

    class Handler(BaseHTTPRequestHandler):
        server_version = "chartroom-app"
        sys_version = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            pass

        def send(self, code, body, ctype, extra=()):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", CSP)
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def json(self, code, obj):
            self.send(code, json.dumps(obj, separators=(",", ":")), "application/json")

        def who(self):
            """The person, or None when this request may not come in."""
            h = self.headers
            if args.no_auth:
                host = (h.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
                if host not in (LOOPBACK, "localhost") or h.get("X-Forwarded-For") or h.get("Tailscale-User-Login"):
                    return None
                return "this machine"
            login = (h.get("Tailscale-User-Login") or "").strip().lower()
            return login if login and login == user else None

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/healthz":
                return self.send(200, "ok\n", "text/plain; charset=utf-8")
            if not self.who():
                return self.send(403, "forbidden: this app opens only for its owner, over the tailnet\n", "text/plain; charset=utf-8")
            if path in ("/", "/index.html"):
                return self.static(os.path.join(app_dir, "index.html"))
            if path.startswith("/app/"):
                return self.static(self.inside(app_dir, path[len("/app/"):]))
            if path.startswith("/shared/") and path[len("/shared/"):] in SHARED:
                return self.static(os.path.join(shared_dir, path[len("/shared/"):]))
            if path == "/api/v1/state":
                hub.looked()
                return self.json(200, dict(hub.state(), user=self.who(), actions=actions.recent()))
            if path == "/api/v1/stream":
                hub.looked()
                return self.stream()
            m = re.match(r"^/api/v1/homes/([^/]+)/tasks/([^/]+)/files/([^/]+)$", path)
            if m:
                return self.task_file(*[unquote(x) for x in m.groups()])
            return self.send(404, "not found\n", "text/plain; charset=utf-8")

        def inside(self, base, rel):
            rel = unquote(rel)
            if not rel or "\x00" in rel or rel.startswith("/") or any(p in ("..", "") for p in rel.split("/")):
                return None
            full = os.path.realpath(os.path.join(base, rel))
            return full if full.startswith(os.path.realpath(base) + os.sep) else None

        def static(self, f):
            ext = os.path.splitext(f or "")[1].lower()
            if not f or ext not in STATIC_TYPES or not os.path.isfile(f):
                return self.send(404, "not found\n", "text/plain; charset=utf-8")
            with open(f, "rb") as fh:
                data = fh.read()
            return self.send(200, data, STATIC_TYPES[ext])

        def task_file(self, home, tid, name):
            h = hub.homes.get(home)
            if not h or not TASK_ID.match(tid) or name not in TASK_FILES:
                return self.send(404, "not found\n", "text/plain; charset=utf-8")
            if not os.path.isfile(os.path.join(h.path, "tasks", tid, "meta.json")):
                return self.send(404, "not found\n", "text/plain; charset=utf-8")
            f = os.path.join(h.path, "tasks", tid, name)
            if not os.path.isfile(f):  # a known task without that file (yet): nothing to show
                return self.send(204, b"", "text/plain; charset=utf-8")
            with open(f, "rb") as fh:
                data = fh.read(4 * 1024 * 1024)
            return self.send(200, data, "text/plain; charset=utf-8")

        def stream(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            seen = -1
            try:
                while True:
                    with hub.cond:
                        if hub.version == seen:
                            hub.cond.wait(25)
                        v = hub.version
                    hub.looked()  # an open stream is someone looking
                    msg = ("event: version\ndata: %d\n\n" % v) if v != seen else ": keep-alive\n\n"
                    seen = v
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return

        def do_POST(self):
            path = urlsplit(self.path).path
            if not self.who():
                return self.json(403, {"error": "forbidden"})
            h = self.headers
            # No cross-site writes: our own header (a form or an image cannot send it), JSON only,
            # and when the browser says where the request came from, it came from this app.
            if h.get("X-Chartroom-App") != "1" or not (h.get("Content-Type") or "").startswith("application/json"):
                return self.json(403, {"error": "writes come from the app only"})
            if h.get("Sec-Fetch-Site") not in (None, "same-origin", "none"):
                return self.json(403, {"error": "cross-site write refused"})
            origin = h.get("Origin")
            if origin and urlsplit(origin).netloc.lower() != (h.get("Host") or "").lower():
                return self.json(403, {"error": "cross-origin write refused"})
            m = re.match(r"^/api/v1/homes/([^/]+)/([a-z]+)$", path)
            if not m:
                return self.json(404, {"error": "not found"})
            home = hub.homes.get(unquote(m.group(1)))
            if not home:
                return self.json(404, {"error": "no such home"})
            try:
                n = int(h.get("Content-Length") or "0")
            except ValueError:
                n = -1
            if n < 0 or n > BODY_MAX:
                return self.json(413, {"error": "the request is too large"})
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self.json(400, {"error": "the body is not JSON"})
            if not isinstance(body, dict):
                return self.json(400, {"error": "the body is a JSON object"})
            try:
                argv, stdin = verb_for(m.group(2), body)
            except KeyError:
                return self.json(404, {"error": "no such action"})
            except ValueError as exc:
                return self.json(400, {"error": str(exc)})
            aid = h.get("X-Chartroom-Action") or ""
            if not ACTION_ID.match(aid):
                aid = "s-%x-%x" % (int(time.time() * 1000), threading.get_ident() & 0xffffff)
            r = actions.submit(aid, home.name, m.group(2), argv, stdin)
            # accepted: the verb runs in the background; its outcome is in /api/v1/state's actions
            return self.json(202, {"ok": True, "id": r["id"], "state": r["state"], "error": r.get("error")})

        do_PUT = do_DELETE = do_PATCH = lambda self: self.json(405, {"error": "method not allowed"})

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=4516)
    ap.add_argument("--pidfile")
    ap.add_argument("--bin", required=True)
    ap.add_argument("--root", required=True, help="the chartroom checkout (app/ and lib/ in it)")
    ap.add_argument("--user", help="the one Tailscale login let in")
    ap.add_argument("--no-auth", action="store_true", help="no identity: requests straight to 127.0.0.1 only")
    args = ap.parse_args()
    if not args.no_auth and not (args.user or "").strip():
        sys.exit("chartroom app: --user (CHARTROOM_APP_USER) or --no-auth")
    # Out of whatever directory started it (a task's worktree, say): sweep reaps what runs in one.
    os.chdir(os.path.dirname(args.pidfile) if args.pidfile else "/")
    hub = Hub(args.bin)
    if not hub.discover():
        sys.exit("chartroom app: no home to show (chartroom homes)")
    try:
        httpd = ThreadingHTTPServer((LOOPBACK, args.port), None)
    except OSError as exc:
        sys.exit("chartroom app: cannot listen on %s:%d: %s" % (LOOPBACK, args.port, exc.strerror or exc))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    actions = Actions(hub, args.bin, os.path.join(os.path.dirname(args.pidfile), "app-actions.ndjson") if args.pidfile else None)
    httpd.RequestHandlerClass = make_handler(hub, args, args.root, actions)

    def cleanup(*_):
        if args.pidfile:
            try:
                with open(args.pidfile) as fh:
                    if fh.read().split()[:1] == [str(os.getpid())]:
                        os.remove(args.pidfile)
            except OSError:
                pass
        os._exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    if args.pidfile:
        tmp = args.pidfile + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("%d %d %s\n" % (os.getpid(), port, "noauth" if args.no_auth else "tailscale"))
        os.replace(tmp, args.pidfile)
    print("chartroom app: http://%s:%d/ (%s; homes: %s)" % (LOOPBACK, port, "no identity check: this machine only" if args.no_auth
          else "only " + args.user, ", ".join(hub.order)), flush=True)

    def rediscover():  # a home registered after start shows up within a minute
        while True:
            time.sleep(60)
            hub.discover()

    threading.Thread(target=rediscover, daemon=True).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
