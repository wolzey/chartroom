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
  POST /api/v1/homes/<home>/<tell|answer|accept|close|snooze|unsnooze|done|remove|restore>   (JSON body)
                            202 at once: the verb runs in the background, in order per home;
                            X-Chartroom-Action names it, so a retry is never a second run
  POST /api/v1/device/join       a device enrols with a one-time code: `chartroom fleet join`
  POST /api/v1/device/heartbeat  a device's probe, every 15 s (Authorization: Bearer <its token>)
  POST /api/v1/device/rotate     a device swaps its token for one it made: `chartroom fleet rotate`
  POST /api/v1/device/commands   long-poll (up to 25 s): the commands queued for that device
  POST /api/v1/device/result     a device's answer to one of its own commands
  POST /api/v1/device/<events|files|permits>   what a worker there wrote, for a task pinned to that
                                 device at that attempt: `chartroom fleet ingest` in the task's home
  POST /api/v1/device/bundle     a pinned task's branch, as a git bundle (raw body; X-Home, X-Task,
                                 X-Attempt, X-Branch, X-Sha, X-Device): fetched into its own branch
                            The device routes (lib/fleet.sh, lib/device.sh) open by a device's own
                            token alone: the Tailscale login is ignored there (every device carries
                            the owner's), and a device token opens nothing else. The server writes
                            only what a device said (devices/<id>.seen.json); who a device is, its
                            token's hash, and what its silence means are the CLI's.
Python 3.9+ (macOS /usr/bin/python3 is 3.9).
"""
import argparse
import hashlib
import hmac
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit

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
PERMIT_ID = re.compile(r"^p-[0-9a-f]{4,16}$")
INBOX_ID = re.compile(r"^i-[0-9a-f]{4,}$")
ARTIFACT_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,127}/[a-z0-9][a-z0-9-]{0,79}$")
DURATION = re.compile(r"^[0-9]{1,4}[mhd]$")
UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
TASK_FILES = ("brief.md", "plan.md", "report.md", "events.log")
ATT_ID = re.compile(r"^att-[0-9a-f]{4,}$")
ATTACH_MAX = 25 * 1024 * 1024
# An attachment is shown in the page only when it is a kind a browser renders without running
# anything; every other kind (HTML, SVG, ...) is only ever downloaded.
INLINE_TYPES = ("image/png", "image/jpeg", "image/gif", "image/webp", "video/mp4", "video/quicktime", "video/webm",
                "application/pdf", "text/plain", "text/csv", "application/json")
GITHUB_PR = re.compile(r"^https://github\.com/([^/\s]+/[^/\s]+)/pull/([0-9]+)$")
PR_TTL = 600  # an open PR's state is looked up again after this long
PR_PASS = 60  # a pass over the PRs at most this often
PR_PER_PASS = 30  # and this many lookups in one pass
TICKET_CACHE = 2.0
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


# A file task's own record. A store task has none: its record is in the store (lib/store.sh), so
# whether it exists, and its events, are asked of chartroom.
FILE_RECORD = "meta.json"


def task_known(bin_, home, tid):
    """Whether <tid> is a task of <home>, file-born or store-born."""
    d = os.path.join(home, "tasks", tid)
    if os.path.isfile(os.path.join(d, FILE_RECORD)):
        return True
    return os.path.isdir(d) and run([bin_, "store", "meta", tid], home, timeout=30)[0] == 0


def store_task_events(bin_, home, tid):
    """A store task's event lines (it has no events.log of its own), or None."""
    code, out, _ = run([bin_, "store", "events", tid], home, timeout=30)
    return out.encode("utf-8") if code == 0 else None


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
        self.read_from = 0.0  # when the last finished read (even a failed one) began
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


XO_CHECK_EVERY = 300.0
_xo = {"at": 0.0, "value": None}


def xo_reads_app(own_bin):
    """Can the XOs' own chartroom read what the app tells them? An XO runs the installed chartroom
    (CHARTROOM_XO_BIN, else `chartroom` on PATH or in ~/.local/bin); only one with `tell` wakes on
    the commander's words from the app. Until it is installed, an answer is kept but read by nobody,
    and the page must say so. -> {"reads_app": True|False|None, "bin": path or None}."""
    now = time.time()
    if _xo["value"] is not None and now - _xo["at"] < XO_CHECK_EVERY:
        return _xo["value"]
    path = os.environ.get("CHARTROOM_XO_BIN") or shutil.which("chartroom", path=os.environ.get("PATH", "") + os.pathsep + os.path.expanduser("~/.local/bin"))
    value = {"reads_app": None, "bin": path}
    if path:
        if os.path.realpath(path) == os.path.realpath(own_bin):
            value["reads_app"] = True
        else:
            try:
                p = subprocess.run([path, "help"], capture_output=True, timeout=20, env=child_env())
                value["reads_app"] = b"chartroom tell" in p.stdout
            except (OSError, subprocess.TimeoutExpired):
                value["reads_app"] = None
    _xo["at"], _xo["value"] = now, value
    return value


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
                began = time.time()  # (after the clear: a read asked for from here on is another one)
                self.collect(h)
                h.read_from = began
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


FLEET_EVERY = 60.0  # while someone looks: devices' heartbeats are read from disk; a machine still probed over ssh is asked this often


class Fleet:
    """The machines' health for Fleet: `chartroom app fleet --json` (lib/app/fleet.jq over `chartroom
    nodes`), read in the background every FLEET_EVERY seconds while someone looks, and at once when
    the page asks (Check again). Its failed sign-ins are Needs me items."""

    def __init__(self, hub, cli):
        self.hub, self.cli = hub, cli
        self.value = None
        self.wake = threading.Event()

    def loop(self):
        last = 0.0
        while True:
            due = self.wake.is_set() or (self.hub.watched() and time.time() - last >= FLEET_EVERY)
            if due:
                self.wake.clear()
                last = time.time()
                home = next(iter(self.hub.homes.values()), None)
                code, out, err = run([self.cli, "app", "fleet", "--json"], home.path if home else None, timeout=180)
                try:
                    v = json.loads(out) if code == 0 else None
                except ValueError:
                    v = None
                if v is None:
                    v = dict(self.value or {"machines": [], "needs": []}, error=last_line(err) or "the fleet check failed", checked_at=iso())
                else:
                    v["error"] = None
                self.value = v
                self.hub.bump()
            self.wake.wait(5)


DEVICE_ID = re.compile(r"^n-[0-9a-f]{12}$")
DEVICE_TOKEN = re.compile(r"^[0-9a-f]{64}$")
DEVICE_PROTOCOL = 1
DEVICE_BODY_MAX = 256 * 1024
DEVICE_EXIT = {0: 200, 2: 400, 3: 401, 4: 409}  # lib/fleet.sh's exit codes
JOIN_FAILS = 10  # failed codes a minute before joins are refused for the rest of it
CMD_ID = re.compile(r"^c-[0-9]{13}-[0-9a-f]{6}$")
POLL_MAX = 25  # seconds a device's long-poll is held
CMD_BATCH = 5
OUT_MAX = 64 * 1024
GUEST_TASK = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
BUNDLE_MAX = 512 * 1024 * 1024


class Devices:
    """The device routes' state: the registry's directory (lib/fleet.sh owns it), the endpoint's own
    uptime (so a device's silence while this server was down is never held against it), and the
    seen files this server writes."""

    def __init__(self, cli, fleet_dir, fleet):
        self.cli, self.dir, self.fleet = cli, fleet_dir, fleet
        self.since = int(time.time())
        self.fails = []
        self.lock = threading.Lock()

    def start(self):
        os.makedirs(os.path.join(self.dir, "devices"), mode=0o700, exist_ok=True)
        self.write(os.path.join(self.dir, "endpoint"), "%d %d\n" % (os.getpid(), self.since))

    def stop(self):
        try:
            with open(os.path.join(self.dir, "endpoint")) as fh:
                if fh.read().split()[:1] == [str(os.getpid())]:
                    os.remove(os.path.join(self.dir, "endpoint"))
        except OSError:
            pass

    @staticmethod
    def write(path, text):
        tmp = "%s.tmp.%d.%d" % (path, os.getpid(), threading.get_ident())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)

    def read(self, did, suffix=".json"):
        try:
            with open(os.path.join(self.dir, "devices", did + suffix)) as fh:
                v = json.load(fh)
            return v if isinstance(v, dict) else None
        except (OSError, ValueError):
            return None

    def auth(self, did, token):
        """(the sha256 that let it in, or None; its record)"""
        rec = self.read(did)
        if not rec or rec.get("revoked"):
            return None, rec
        h = hashlib.sha256(token.encode()).hexdigest()
        cur, prev = rec.get("token_sha256") or "", rec.get("prev_sha256") or ""
        if cur and hmac.compare_digest(h, cur):
            return h, rec
        if prev and (rec.get("prev_until") or 0) > time.time() and hmac.compare_digest(h, prev):
            return h, rec
        return None, rec

    def heartbeat(self, did, body, addr):
        now = int(time.time())
        before = self.read(did, ".seen.json")
        clock = body.get("clock")
        probe = body.get("probe")
        doc = {"last_seen": now, "clock": clock if isinstance(clock, int) else None,
               "version": str(body.get("version") or "")[:80] or None, "protocol": body.get("protocol"),
               "probe": probe if isinstance(probe, str) else None, "addr": addr,
               "agent_started": body.get("started") if isinstance(body.get("started"), int) else None,
               "rev": body["rev"] if isinstance(body.get("rev"), str) and re.match(r"^[0-9a-f]{7,40}$", body["rev"]) else None,
               "caps": [c for c in body.get("caps") or [] if isinstance(c, str) and re.match(r"^[a-z-]{1,32}$", c)][:32]
               if isinstance(body.get("caps"), list) else [],
               "tasks": self.tasks_of(body.get("tasks"))}
        self.write(os.path.join(self.dir, "devices", did + ".seen.json"), json.dumps(doc, separators=(",", ":")) + "\n")
        # a device that (re)appears: Fleet reads the machines again now, not at its next turn
        if not before or now - int(before.get("last_seen") or 0) > 45:
            self.fleet.wake.set()

    @staticmethod
    def tasks_of(v):
        """A heartbeat's word on each of its tasks: {"<home>/<id>": live word}, shapes checked."""
        if not isinstance(v, dict):
            return {}
        out = {}
        for k, w in list(v.items())[:200]:
            if isinstance(k, str) and re.match(r"^[a-z][a-z0-9-]{0,31}/[a-z][a-z0-9_-]{0,31}$", k) and isinstance(w, str) and re.match(r"^[a-z-]{1,32}$", w):
                out[k] = w
        return out

    def queue(self, did):
        return os.path.join(self.dir, "queue", did)

    def pending(self, did):
        """The device's queued commands, oldest first; one whose ttl ran out is answered "expired"."""
        d = self.queue(did)
        try:
            names = sorted(n for n in os.listdir(d) if n.endswith(".json") and CMD_ID.match(n[:-5]))
        except OSError:
            return []
        out, now = [], time.time()
        for n in names:
            try:
                with open(os.path.join(d, n)) as fh:
                    c = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(c, dict):
                continue
            if isinstance(c.get("expires"), int) and c["expires"] < now:
                self.answer(did, n[:-5], {"rc": 124, "out": "", "err": "expired before the device took it"})
                continue
            out.append({"id": n[:-5], "type": c.get("type"), "payload": c.get("payload")})
            if len(out) >= CMD_BATCH:
                break
        return out

    def answer(self, did, cid, res):
        """A device's answer to one of its own commands: False when it has none by that id."""
        q = os.path.join(self.queue(did), cid + ".json")
        r = os.path.join(self.dir, "results", cid + ".json")
        if not os.path.isfile(q):
            return os.path.isfile(r)  # (an answer sent twice: the first one stands)
        os.makedirs(os.path.dirname(r), mode=0o700, exist_ok=True)
        doc = {"id": cid, "device": did, "at": int(time.time()), "rc": res.get("rc") if isinstance(res.get("rc"), int) else 1,
               "out": str(res.get("out") or "")[-OUT_MAX:], "err": str(res.get("err") or "")[-OUT_MAX:]}
        self.write(r, json.dumps(doc, separators=(",", ":")) + "\n")
        try:
            os.remove(q)
        except OSError:
            pass
        return True

    def pinned(self, did, home, task, attempt):
        """The pin of <home>/<task> when it is this device's at this attempt, else None."""
        if not isinstance(home, str) or not HOME_NAME.match(home) or not isinstance(task, str) or not GUEST_TASK.match(task):
            return None
        try:
            with open(os.path.join(self.dir, "tasks", home, task + ".json")) as fh:
                m = json.load(fh)
        except (OSError, ValueError):
            return None
        if not isinstance(m, dict) or m.get("device") != did or m.get("attempt") != attempt:
            return None
        return m

    def join_refused(self):
        with self.lock:
            now = time.time()
            self.fails = [t for t in self.fails if now - t < 60]
            return len(self.fails) >= JOIN_FAILS

    def join_failed(self):
        with self.lock:
            self.fails.append(time.time())


PUSH_DEVICES = 20  # subscriptions kept at most (each device that turned notifications on)
PUSH_GROUP = {"decide": "To decide", "approve": "To approve", "unblock": "Blocked", "read": "To read"}
B64U = re.compile(r"^[A-Za-z0-9_-]+={0,2}$")


class Pusher:
    """Web Push for new Needs me items (slice 6). Off unless the brain's config says
    CHARTROOM_APP_PUSH=on, and available only where node runs lib/app/push.mjs (node:crypto; its
    self-test is the RFC 8291 vector). The VAPID keys and the devices' subscriptions live beside
    the pid file, 0600. An item is pushed once, when it first appears: what is open when the server
    starts, or when a home is first read, is only remembered. Payloads are encrypted end to end;
    the browser maker's push service sees the endpoint, the size and the time, never the words.

    The XO answers first. A worker's permission card or decision (or plan approval) wakes the XO at
    once, and is pushed only if it is still open after `hold` seconds (CHARTROOM_APP_PUSH_HOLD):
    at once if it is breaking, the XO handed it over (`chartroom permit escalate`), or a card has
    less than the hold left on its clock. An item answered first is never pushed: when its hold is
    over, its home is read once more and only what is still open then is pushed (a home is read
    minutes apart when nobody looks, so the last read may be older than the answer). One pushed and
    then answered is withdrawn: a "close" push to the devices that got it (never to Apple's
    service, which revokes a subscription whose push shows nothing; the app clears it there when
    it opens)."""

    def __init__(self, hub, fleet, root, state_dir, mode, subject, hold=120):
        self.hub, self.fleet = hub, fleet
        self.hold = max(0, int(hold))
        self.first, self.pushed, self.cur = {}, {}, {}
        self.asked = {}  # a held item whose hold is over -> when the read that confirms it was asked for
        self.withdrawn = 0
        self.script = os.path.join(root, "lib", "app", "push.mjs")
        self.keys = os.path.join(state_dir, "app-push-keys.json") if state_dir else None
        self.subs_file = os.path.join(state_dir, "app-push-subs.json") if state_dir else None
        self.on, self.subject = mode == "on", subject
        # tests only: a fake push service on this machine (never a real one) may be plain http
        self.allow_http = os.environ.get("CHARTROOM_APP_PUSH_ALLOW_HTTP") == "1"
        self.public, self.reason, self.error = None, None, None
        self.lock = threading.Lock()
        self.subs = self.load()
        self.seen, self.ready = set(), set()
        self.sent = 0

    def setup(self):
        node = shutil.which("node")
        if not self.on:
            self.reason = "off: CHARTROOM_APP_PUSH=on in the brain's config turns it on"
        elif not self.keys:
            self.reason = "no state directory for its keys"
        elif not node:
            self.reason = "node is not installed on the brain"
        else:
            code, out, err = run([node, self.script, "selftest"], None, timeout=30)
            if code != 0 or out.strip() != "ok":
                self.reason = "node's crypto failed the push self-test: " + (last_line(err) or out.strip() or "exit %d" % code)
            else:
                old = os.umask(0o077)
                try:
                    code, out, err = run([node, self.script, "keys", self.keys], None, timeout=30)
                finally:
                    os.umask(old)
                if code == 0 and out.strip():
                    self.public, self.node = out.strip(), node
                else:
                    self.reason = "could not make the push keys: " + (last_line(err) or "exit %d" % code)

    def info(self):
        return {"available": bool(self.public), "on": self.on, "key": self.public, "reason": self.reason,
                "devices": len(self.subs), "sent": self.sent, "withdrawn": self.withdrawn, "hold": self.hold,
                "holding": len(self.first), "error": self.error}

    def load(self):
        try:
            with open(self.subs_file) as fh:
                v = json.load(fh)
            return [s for s in v if isinstance(s, dict) and s.get("endpoint")] if isinstance(v, list) else []
        except (OSError, ValueError, TypeError):
            return []

    def save(self):
        if not self.subs_file:
            return
        tmp = self.subs_file + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(self.subs, fh)
        os.replace(tmp, self.subs_file)

    def valid_endpoint(self, ep):
        if not isinstance(ep, str) or len(ep) > 2048:
            return False
        u = urlsplit(ep)
        if u.scheme == "https" and u.hostname:
            return True
        return self.allow_http and u.scheme == "http" and u.hostname == LOOPBACK

    def subscribe(self, body):
        keys = body.get("keys") if isinstance(body.get("keys"), dict) else {}
        ep, p256dh, auth = body.get("endpoint"), keys.get("p256dh"), keys.get("auth")
        if not self.public:
            return 409, {"error": "push is not available on this brain: " + (self.reason or "unknown")}
        if not self.valid_endpoint(ep):
            return 400, {"error": "a push endpoint is an https URL"}
        if not (isinstance(p256dh, str) and B64U.match(p256dh) and 80 <= len(p256dh) <= 100
                and isinstance(auth, str) and B64U.match(auth) and 16 <= len(auth) <= 32):
            return 400, {"error": "the subscription's keys are not valid"}
        with self.lock:
            self.subs = [s for s in self.subs if s["endpoint"] != ep][-(PUSH_DEVICES - 1):] + [
                {"endpoint": ep, "keys": {"p256dh": p256dh, "auth": auth}, "at": iso()}]
            self.save()
        return 200, {"ok": True, "devices": len(self.subs)}

    def unsubscribe(self, body):
        with self.lock:
            n = len(self.subs)
            self.subs = [s for s in self.subs if s["endpoint"] != body.get("endpoint")]
            if len(self.subs) != n:
                self.save()
        return 200, {"ok": True, "devices": len(self.subs)}

    def scan(self):
        """The open items now; those not seen before, from a source read before, are new."""
        now, cur, read = iso(), {}, set()
        for name in list(self.hub.order):
            h = self.hub.homes.get(name)
            if not h or h.snapshot is None:
                continue
            read.add(name)
            for it in h.snapshot.get("needs") or []:
                if it.get("held") or it.get("sent") or (it.get("snoozed_until") or "") > now:
                    continue
                cur[name + ":" + str(it.get("id"))] = (name, it)
        fv = self.fleet.value
        if fv is not None:
            read.add("fleet")
            for it in fv.get("needs") or []:
                cur["fleet:" + str(it.get("id"))] = ("fleet", it)
        new = [k for k in cur if k not in self.seen and cur[k][0] in self.ready]
        self.ready |= read
        self.seen = set(cur) | {k for k in self.seen if k.split(":", 1)[0] not in read}
        # what a source not read this time had open stays open: never withdrawn for a failed read
        self.cur = dict(cur, **{k: v for k, v in self.cur.items() if v[0] not in read})
        return [(k, cur[k][0], cur[k][1]) for k in new]

    @staticmethod
    def xo_first(it):
        """A worker's call or question the XO may answer before the commander sees it."""
        return it.get("kind") == "permission" or (it.get("type") == "task" and it.get("kind") in ("decide", "approve"))

    def due(self, it, first):
        """When an item seen first at `first` is pushed (epoch seconds)."""
        if not self.xo_first(it) or it.get("breaking") or it.get("escalated"):
            return first
        if it.get("kind") == "permission" and it.get("blocking") and not it.get("missed"):
            try:
                if float(it.get("expires_epoch")) - time.time() <= self.hold:
                    return first
            except (TypeError, ValueError):
                pass
        return first + self.hold

    def step(self, now=None):
        """One round after a read: hold what is new, push what is due and still open, withdraw
        what was pushed and is open no more."""
        now = time.time() if now is None else now
        # before the scan: a read that ends during it confirms the next round, not this older list
        reads = {n: h.read_from for n, h in list(self.hub.homes.items())}
        for key, home, it in self.scan():
            self.first[key] = now
        for key in list(self.first):
            hit = self.cur.get(key)
            if hit is None:  # answered (or gone) before it was pushed: never pushed
                del self.first[key]
                self.asked.pop(key, None)
                continue
            due = self.due(hit[1], self.first[key])
            if now >= due and (due == self.first[key] or self.confirmed(key, hit[0], now, reads)):
                del self.first[key]
                self.asked.pop(key, None)
                if self.subs:
                    got = self.send(self.payload(key, hit[0], hit[1]))
                    if got:
                        self.pushed[key] = got
        for key in list(self.pushed):
            if key not in self.cur:
                self.withdraw(key, self.pushed.pop(key))

    def confirmed(self, key, home, now, reads):
        """Whether the home was read since this item's hold was over; asks for that read the first
        time. A read that fails counts: an unanswered question is never kept back by one."""
        if key not in self.asked:
            self.asked[key] = now
            self.hub.refresh(home)
        return home not in reads or reads[home] >= self.asked[key]

    def next_due(self):
        """Seconds until the first held item is due, or None."""
        now = time.time()
        ds = [now + 1 if k in self.asked else self.due(self.cur[k][1], t) for k, t in self.first.items() if k in self.cur]
        return max(0.2, min(ds) - time.time()) if ds else None

    def withdraw(self, key, endpoints):
        # Apple's push service revokes a subscription whose push shows no notification
        only = [e for e in endpoints if not (urlsplit(e).hostname or "").endswith("push.apple.com")]
        if only:
            self.withdrawn += len(self.send({"type": "close", "tag": key}, only=only, count=False))

    def payload(self, key, home, it):
        if it.get("kind") == "permission":  # a worker's call, waiting on the commander
            body = "%s · %s" % (home, it.get("title") or "")
            if it.get("escalated"):
                body += " · the XO left this one to you" + (": " + it["escalated"]["note"] if it["escalated"].get("note") else "")
            return {"title": ("Allow %s?" % (it.get("desc") or "a call"))[:100], "body": body[:180],
                    "tag": key, "url": "/#/n/" + quote(key, safe="")}
        title = str(it.get("title") or "Chartroom")
        body = home + " · " + PUSH_GROUP.get(it.get("group"), "Needs you")
        if it.get("summary"):
            body += ": " + str(it["summary"])
        return {"title": title[:100], "body": body[:180], "tag": key, "url": "/#/n/" + quote(key, safe="")}

    def send(self, payload, only=None, count=True):
        """Push to every device (or those whose endpoint is in `only`); the endpoints that took it."""
        got = []
        for s in list(self.subs):
            if only is not None and s["endpoint"] not in only:
                continue
            code, out, err = run([self.node, self.script, "send", self.keys, self.subject], None,
                                 stdin=json.dumps({"subscription": s, "payload": payload, "ttl": 6 * 3600}).encode(), timeout=40)
            try:
                status = json.loads(out).get("status") if code == 0 else None
            except ValueError:
                status = None
            if status in (404, 410):  # the device unsubscribed, or its subscription expired
                with self.lock:
                    self.subs = [x for x in self.subs if x["endpoint"] != s["endpoint"]]
                    self.save()
            elif status is None or status >= 400:
                self.error = "%s: %s" % (urlsplit(s["endpoint"]).hostname, status or last_line(err) or "failed")
            else:
                if count:
                    self.sent += 1
                self.error = None
                got.append(s["endpoint"])
        return got

    def loop(self):
        self.setup()
        if not self.public:
            return
        last = -1
        while True:
            with self.hub.cond:
                # a new read, or the first held item coming due, whichever is first
                if self.hub.version == last:
                    nd = self.next_due()
                    self.hub.cond.wait(30 if nd is None else min(30, nd))
                last = self.hub.version
            self.step()


class Prs:
    """GitHub PR states for the PRs the snapshots name, looked up with gh in the background while
    someone looks at the app. A merged or closed PR is final and never looked up again; an open one
    is looked up again after PR_TTL. No gh, or gh failing, only means no state ("No check data")."""

    def __init__(self, hub):
        self.hub = hub
        self.gh = os.environ.get("CHARTROOM_GH") or "gh"
        self.states = {}
        self.error = None

    def urls(self):
        seen = []
        for h in list(self.hub.homes.values()):
            for t in ((h.snapshot or {}).get("tasks") or []):
                for u in t.get("prs") or []:
                    if isinstance(u, str) and GITHUB_PR.match(u) and u not in seen:
                        seen.append(u)
        return seen

    @staticmethod
    def shape(url, d):
        state = (d.get("state") or "").upper()
        if state == "MERGED":
            st = "merged"
        elif state == "CLOSED":
            st = "closed"
        elif d.get("isDraft"):
            st = "draft"
        elif d.get("reviewDecision") == "APPROVED":
            st = "approved"
        elif d.get("reviewDecision") == "CHANGES_REQUESTED":
            st = "changes"
        else:
            st = "open"
        checks = None
        roll = d.get("statusCheckRollup") or []
        if roll:
            c = {"total": len(roll), "pass": 0, "fail": 0, "run": 0}
            for r in roll:
                v = (r.get("conclusion") or r.get("state") or r.get("status") or "").upper()
                if v in ("SUCCESS", "NEUTRAL", "SKIPPED"):
                    c["pass"] += 1
                elif v in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"):
                    c["fail"] += 1
                else:
                    c["run"] += 1
            checks = c
        m = GITHUB_PR.match(url)
        reviewers = []
        for r in d.get("latestReviews") or []:
            who = ((r.get("author") or {}).get("login")) or "someone"
            rs = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes"}.get((r.get("state") or "").upper(), "commented")
            reviewers.append({"name": who, "state": rs})
        return {"url": url, "repo": m.group(1) if m else "", "num": "#" + (m.group(2) if m else str(d.get("number", ""))),
                "title": d.get("title") or "", "state": st, "automerge": bool(d.get("autoMergeRequest")),
                "branch": d.get("headRefName"), "base": d.get("baseRefName"), "checks": checks,
                "reviewers": reviewers, "merged_at": d.get("mergedAt"), "checked_at": time.time()}

    def lookup(self, url):
        try:
            p = subprocess.run([self.gh, "pr", "view", url, "--json",
                                "number,title,state,isDraft,reviewDecision,statusCheckRollup,headRefName,baseRefName,mergedAt,autoMergeRequest,latestReviews"],
                               capture_output=True, timeout=25, env=child_env())
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.error = str(exc)
            return False
        if p.returncode != 0:
            self.error = last_line(p.stderr.decode("utf-8", "replace")) or "gh pr view failed"
            return p.returncode != 4  # 4: not signed in, nothing more will work this pass
        try:
            self.states[url] = self.shape(url, json.loads(p.stdout.decode("utf-8")))
            self.error = None
        except ValueError:
            self.error = "unreadable gh output"
        return True

    def loop(self):
        while True:
            time.sleep(PR_PASS)
            if not self.hub.watched():
                continue
            now, done, changed = time.time(), 0, False
            for url in self.urls():
                st = self.states.get(url)
                if st and (st["state"] in ("merged", "closed") or now - st["checked_at"] < PR_TTL):
                    continue
                if done >= PR_PER_PASS:
                    break
                done += 1
                before = json.dumps(st, sort_keys=True, default=str) if st else None
                if not self.lookup(url):
                    break
                if json.dumps(self.states.get(url), sort_keys=True, default=str) != before:
                    changed = True
            if changed:
                self.hub.bump()


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
    if action == "permit":
        # a permission card (lib/permit.sh): allow once, always for this task, or deny; the first
        # answer wins, and the verb's refusal says who won
        pid = need("id", PERMIT_ID, "a permission card (p-…)")
        ans = need("answer", re.compile(r"^(once|always|deny)$"), "once, always or deny")
        argv = ["permit", "answer", pid, ans, "--by", "app", "--via", "app"]
        note = body.get("note")
        if note is not None:
            if not isinstance(note, str) or len(note) > 2000:
                raise ValueError("note: at most 2000 characters")
            note = " ".join(note.split())
            if note:
                argv += ["--note", note]
        return argv, None
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
    if action in ("remove", "restore"):
        # Out of every view by a mark, nothing written to the item; 30 days to restore (lib/marks.sh).
        # A task whose worker is live is refused (no --stop from here: that stays a terminal word).
        ref = body.get("ref")
        if not isinstance(ref, str) or not (TASK_ID.match(ref) or INBOX_ID.match(ref) or ARTIFACT_REF.match(ref)):
            raise ValueError("ref: a task, an inbox item (i-xxxx) or an artifact (<id>/<slug>)")
        argv = [action, ref]
        why = body.get("why")
        if action == "remove" and isinstance(why, str) and why.strip():
            argv += ["--why", re.sub(r"[\x00-\x1f\x7f]+", " ", why.strip())[:500]]
        return argv, None
    if action == "comment":
        task = need("task", TASK_ID, "a task id")
        text = body.get("text")
        if not isinstance(text, str) or not text.strip() or len(text) > 16000:
            raise ValueError("text: a comment of at most 16000 characters")
        # "@xo ..." goes to the XO; anything else steers the worker, in the commander's words
        if re.match(r"^\s*@xo\b", text, re.I):
            return ["tell", "--via", "app", "--re", task, "-"], re.sub(r"^\s*@xo\b[:,]?\s*", "", text, flags=re.I).encode("utf-8")
        return ["steer", task, "The commander: " + text.strip()], None
    if action == "link":
        task = need("task", TASK_ID, "a task id")
        url = body.get("url")
        if not isinstance(url, str) or not re.match(r"^https?://[^\s\"'<>]{3,2000}$", url):
            raise ValueError("url: an http(s) URL")
        argv = ["link", task, url, "--by", "commander"]
        if isinstance(body.get("title"), str) and body["title"].strip():
            argv += ["--title", body["title"].strip()[:200]]
        return argv, None
    if action == "unlink":
        task = need("task", TASK_ID, "a task id")
        url = body.get("url")
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            raise ValueError("url: a linked URL")
        return ["link", "rm", task, url], None
    if action == "unattach":
        return ["attachment", "rm", need("task", TASK_ID, "a task id"), need("att", ATT_ID, "an attachment id")], None
    if action == "set":
        task = need("task", TASK_ID, "a task id")
        argv = ["set", task]
        if "priority" in body:
            argv.append("priority=" + need("priority", re.compile(r"^(urgent|high|medium|low|none)$"), "urgent, high, medium, low or none"))
        if "labels" in body:
            labels = body["labels"]
            if not isinstance(labels, list) or not all(isinstance(x, str) and re.match(r"^[a-z0-9][a-z0-9._-]{0,31}$", x) for x in labels):
                raise ValueError("labels: a list of lowercase labels")
            argv.append("labels=" + ",".join(labels))
        if len(argv) == 2:
            raise ValueError("nothing to set")
        return argv, None
    if action.startswith("initiative-"):
        sub = action[len("initiative-"):]
        if sub == "new":
            name = body.get("name")
            if not isinstance(name, str) or not name.strip() or len(name) > 120:
                raise ValueError("name: at most 120 characters")
            argv = ["initiative", "new", "--name", name.strip(), "--via", "app"]
            if isinstance(body.get("intent"), str) and body["intent"].strip():
                argv += ["--intent", body["intent"].strip()[:2000]]
            if body.get("target"):
                argv += ["--target", need("target", re.compile(r"^\d{4}-\d{2}-\d{2}$"), "YYYY-MM-DD")]
            return argv, None
        iid = need("id", re.compile(r"^in-[0-9a-f]{4,}$"), "an initiative id")
        if sub == "approve":
            if not isinstance(body.get("stories"), list):
                raise ValueError("stories: the checklist")
            return ["initiative", "approve", iid, "-", "--via", "app"], json.dumps({"stories": body["stories"]}).encode("utf-8")
        if sub == "comment":
            text = body.get("text")
            if not isinstance(text, str) or not text.strip() or len(text) > 8000:
                raise ValueError("text: a comment of at most 8000 characters")
            argv = ["initiative", "comment", iid, "--via", "app"]
            if isinstance(body.get("section"), str) and body["section"].strip():
                argv += ["--section", body["section"].strip()[:200]]
            return argv + ["-"], text.encode("utf-8")
        if sub == "propose":
            plan = body.get("plan")
            if not isinstance(plan, str) or not plan.strip() or len(plan) > 200000:
                raise ValueError("plan: the plan's text")
            return ["initiative", "propose", iid, "-", "--via", "app"], plan.encode("utf-8")
        if sub == "close":
            return ["initiative", "close", iid, "--confirm", "--via", "app"], None
        raise KeyError(action)
    if action == "request":
        title = body.get("title")
        if not isinstance(title, str) or not title.strip() or len(title) > 200:
            raise ValueError("title: a title of at most 200 characters")
        argv = ["request", "--via", "app", "--title", title.strip()]
        if body.get("project"):
            argv += ["--project", need("project", re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"), "a project name")]
        if body.get("priority"):
            argv += ["--priority", need("priority", re.compile(r"^(urgent|high|medium|low)$"), "urgent, high, medium or low")]
        desc = body.get("description")
        if desc is not None and (not isinstance(desc, str) or len(desc) > 16000):
            raise ValueError("description: at most 16000 characters")
        return argv + ["-"], (desc or "").encode("utf-8")
    if action == "brief":
        task = need("task", TASK_ID, "a task id")
        sec = body.get("sections")
        if not isinstance(sec, dict) or not sec or not all(isinstance(k, str) and isinstance(v, str) for k, v in sec.items()):
            raise ValueError("sections: {heading: text}")
        return ["brief", task, "--sections", "-"], json.dumps(sec).encode("utf-8")
    raise KeyError(action)


def make_handler(hub, args, root, actions, prs, fleet, pusher, devices=None):
    app_dir = os.path.join(root, "app")
    shared_dir = os.path.join(root, "lib", "dashboard")
    user = (args.user or "").strip().lower()
    tickets = {}  # (home, task) -> (time, hub version, body): a ticket asked for twice in a row is read once

    class Handler(BaseHTTPRequestHandler):
        server_version = "chartroom-app"
        sys_version = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):
            pass

        def parse_request(self):
            self.body_done = False  # (one handler serves every request of a kept-alive connection)
            return super().parse_request()

        def read_body(self, n):
            data = self.rfile.read(n) if n > 0 else b""
            self.body_done = len(data) == n
            return data

        def send(self, code, body, ctype, extra=()):
            if isinstance(body, str):
                body = body.encode("utf-8")
            # A write answered before its body was read (refused, too large) ends its connection:
            # Tailscale Serve reuses connections, and the unread body would be read as the start
            # of the next request on it.
            if self.command in ("POST", "PUT", "DELETE", "PATCH") and not self.body_done:
                self.close_connection = True
                extra = tuple(extra) + (("Connection", "close"),)
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
            if path in ("/sw.js", "/manifest.webmanifest"):
                # at the root, so the service worker's scope is the whole app
                return self.static(os.path.join(app_dir, path[1:]))
            if path == "/api/v1/push":
                return self.json(200, pusher.info())
            if path.startswith("/app/"):
                return self.static(self.inside(app_dir, path[len("/app/"):]))
            if path.startswith("/shared/") and path[len("/shared/"):] in SHARED:
                return self.static(os.path.join(shared_dir, path[len("/shared/"):]))
            if path == "/api/v1/state":
                hub.looked()
                return self.json(200, dict(hub.state(), user=self.who(), actions=actions.recent(), prs=prs.states, gh_error=prs.error,
                                           xo=xo_reads_app(args.bin), fleet=fleet.value))
            if path == "/api/v1/stream":
                hub.looked()
                return self.stream()
            m = re.match(r"^/api/v1/homes/([^/]+)/tasks/([^/]+)/files/([^/]+)$", path)
            if m:
                return self.task_file(*[unquote(x) for x in m.groups()])
            m = re.match(r"^/api/v1/homes/([^/]+)/tasks/([^/]+)$", path)
            if m:
                return self.ticket(*[unquote(x) for x in m.groups()])
            m = re.match(r"^/api/v1/homes/([^/]+)/initiatives/(in-[0-9a-f]{4,})$", path)
            if m:
                return self.initiative(*[unquote(x) for x in m.groups()])
            m = re.match(r"^/api/v1/homes/([^/]+)/tasks/([^/]+)/attachments/([^/]+)$", path)
            if m:
                return self.attachment(*[unquote(x) for x in m.groups()])
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
            if not task_known(args.bin, h.path, tid):
                return self.send(404, "not found\n", "text/plain; charset=utf-8")
            f = os.path.join(h.path, "tasks", tid, name)
            if name == "events.log" and not os.path.isfile(f):  # a store task's, from the store
                data = store_task_events(args.bin, h.path, tid)
                if data:
                    return self.send(200, data[:4 * 1024 * 1024], "text/plain; charset=utf-8")
            if not os.path.isfile(f):  # a known task without that file (yet): nothing to show
                return self.send(204, b"", "text/plain; charset=utf-8")
            with open(f, "rb") as fh:
                data = fh.read(4 * 1024 * 1024)
            return self.send(200, data, "text/plain; charset=utf-8")

        def ticket(self, home, tid):
            h = hub.homes.get(home)
            if not h or not TASK_ID.match(tid) or not task_known(args.bin, h.path, tid):
                return self.json(404, {"error": "no such task"})
            key = (home, tid)
            hit = tickets.get(key)
            if hit and hit[1] == hub.version and time.time() - hit[0] < TICKET_CACHE:
                return self.send(200, hit[2], "application/json")
            code, out, err = run([args.bin, "app", "task", tid, "--json"], h.path, timeout=60)
            if code != 0:
                return self.json(500, {"error": last_line(err) or "could not read the task"})
            tickets[key] = (time.time(), hub.version, out.encode("utf-8"))
            return self.send(200, out, "application/json")

        def initiative(self, home, iid):
            h = hub.homes.get(home)
            if not h or not os.path.isfile(os.path.join(h.path, "initiatives", iid, "initiative.json")):
                return self.json(404, {"error": "no such initiative"})
            key = (home, iid)
            hit = tickets.get(key)
            if hit and hit[1] == hub.version and time.time() - hit[0] < TICKET_CACHE:
                return self.send(200, hit[2], "application/json")
            code, out, err = run([args.bin, "initiative", "show", iid, "--json"], h.path, timeout=60)
            if code != 0:
                return self.json(500, {"error": last_line(err) or "could not read the initiative"})
            tickets[key] = (time.time(), hub.version, out.encode("utf-8"))
            return self.send(200, out, "application/json")

        def attachment(self, home, tid, att):
            h = hub.homes.get(home)
            if not h or not TASK_ID.match(tid) or not ATT_ID.match(att):
                return self.send(404, "not found\n", "text/plain; charset=utf-8")
            d = os.path.join(h.path, "tasks", tid, "attachments", att)
            rec = None
            try:
                with open(os.path.join(h.path, "tasks", tid, "attachments.ndjson"), encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        try:
                            r = json.loads(line)
                        except ValueError:
                            continue
                        if isinstance(r, dict) and r.get("id") == att:
                            rec = None if r.get("removed") else r
            except OSError:
                pass
            names = os.listdir(d) if rec and os.path.isdir(d) else []
            if not rec or rec.get("name") not in names:
                return self.send(404, "not found\n", "text/plain; charset=utf-8")
            f = os.path.join(d, rec["name"])
            size = os.path.getsize(f)
            inline = rec.get("type") in INLINE_TYPES
            ctype = rec["type"] if inline else "application/octet-stream"
            if ctype.startswith("text/") or ctype == "application/json":
                ctype += "; charset=utf-8"
            start, end, code = 0, size - 1, 200
            rng = re.match(r"^bytes=(\d*)-(\d*)$", self.headers.get("Range") or "")
            if rng and size:
                a, b = rng.groups()
                if a:
                    start, end = int(a), min(int(b), size - 1) if b else size - 1
                elif b:
                    start, end = max(0, size - int(b)), size - 1
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                code = 206
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            if code == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.send_header("Content-Disposition", "%s; filename*=UTF-8''%s" % ("inline" if inline else "attachment", quote(rec["name"])))
            self.send_header("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Cache-Control", "private, max-age=3600")
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(f, "rb") as fh:
                fh.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = fh.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)

        def upload(self, home, tid):
            """A file the commander attaches: the raw body, at most 25 MB, streamed to a temporary file
            in the task's folder, then `chartroom attachment add`, which keeps it and steers the worker."""
            h = hub.homes.get(home)
            if not h or not TASK_ID.match(tid) or not task_known(args.bin, h.path, tid):
                return self.json(404, {"error": "no such task"})
            try:
                n = int(self.headers.get("Content-Length") or "-1")
            except ValueError:
                n = -1
            if n < 0:
                return self.json(411, {"error": "the upload needs a length"})
            if n > ATTACH_MAX:
                return self.json(413, {"error": "attachments hold at most 25 MB; link a bigger file instead"})
            name = unquote(self.headers.get("X-Filename") or "") or "file"
            caption = unquote(self.headers.get("X-Caption") or "")[:500]
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            d = os.path.join(h.path, "tasks", tid, "attachments")
            os.makedirs(d, mode=0o700, exist_ok=True)
            aid = self.headers.get("X-Chartroom-Action") or ""
            if not ACTION_ID.match(aid):
                aid = "s-%x-%x" % (int(time.time() * 1000), threading.get_ident() & 0xffffff)
            known = actions.recs.get(aid)
            if known:  # a retry of an upload the server already has: never a second copy
                return self.json(202, {"ok": True, "id": aid, "state": known["state"], "error": known.get("error")})
            tmp = os.path.join(d, ".incoming-" + aid)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as fh:
                left = n
                while left > 0:
                    chunk = self.rfile.read(min(65536, left))
                    if not chunk:
                        break
                    fh.write(chunk)
                    left -= len(chunk)
            self.body_done = left == 0
            if left > 0:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                return self.json(400, {"error": "the upload was cut short"})
            argv = ["attachment", "add", tid, "--by", "commander", "--name", name]
            if re.match(r"^[a-z]+/[a-z0-9.+-]+$", ctype) and ctype != "application/octet-stream":
                argv += ["--type", ctype]
            if caption.strip():
                argv += ["--caption", caption.strip()]
            if self.headers.get("X-Silent") == "1":
                argv.append("--silent")
            # queued like every write: the file waits in the task's folder until the verb keeps it
            r = actions.submit(aid, home, "attach", argv + [tmp], None, cleanup=tmp)
            return self.json(202, {"ok": True, "id": r["id"], "state": r["state"], "error": r.get("error")})

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

        def device_auth(self, did, token):
            if not isinstance(did, str) or not DEVICE_ID.match(did) or not DEVICE_TOKEN.match(token or ""):
                return None, None
            return devices.auth(did, token)

        def ingest(self, kind, did, home, task, attempt, doc):
            """A push for a pinned task: the pin checked here and again by the verb, in its home."""
            pin = devices.pinned(did, home, task, attempt)
            hm = hub.homes.get(home)
            if not pin or not hm or os.path.realpath(hm.path) != os.path.realpath(pin.get("home_path") or ""):
                return self.json(403, {"error": "that task is not this device's (at that attempt)"})
            doc = dict(doc, home=home, id=task, attempt=attempt, device=did)
            code, out, err = run([devices.cli, "fleet", "ingest", kind], hm.path, stdin=json.dumps(doc).encode(), timeout=120)
            if code != 0:
                return self.json(DEVICE_EXIT.get(code, 500), {"error": last_line(err) or "the push failed"})
            return self.send(200, out.strip() + "\n", "application/json")

        def bundle(self):
            h = self.headers
            auth = h.get("Authorization") or ""
            used, rec = self.device_auth(h.get("X-Device"), auth[7:].strip() if auth.startswith("Bearer ") else "")
            if not used:
                return self.json(401, {"error": "unauthorized"})
            try:
                n = int(h.get("Content-Length") or "-1")
                attempt = int(h.get("X-Attempt") or "0")
            except ValueError:
                n, attempt = -1, 0
            if n <= 0 or n > BUNDLE_MAX:
                return self.json(413, {"error": "a bundle is 1 byte to 512 MB"})
            home, task = h.get("X-Home") or "", h.get("X-Task") or ""
            if not devices.pinned(h.get("X-Device"), home, task, attempt):
                return self.json(403, {"error": "that task is not this device's (at that attempt)"})
            d = os.path.join(devices.dir, "bundles")
            os.makedirs(d, mode=0o700, exist_ok=True)
            tmp = os.path.join(d, "%s.%s.%d.bundle" % (home, task, attempt))
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            left = n
            with os.fdopen(fd, "wb") as fh:
                while left > 0:
                    chunk = self.rfile.read(min(65536, left))
                    if not chunk:
                        break
                    fh.write(chunk)
                    left -= len(chunk)
            self.body_done = left == 0
            try:
                if left > 0:
                    return self.json(400, {"error": "the bundle was cut short"})
                return self.ingest("bundle", h.get("X-Device"), home, task, attempt,
                                   {"path": tmp, "branch": h.get("X-Branch") or "", "sha": h.get("X-Sha") or ""})
            finally:
                try:
                    os.remove(tmp)
                except OSError:
                    pass

        def device(self, path):
            """A device's request: its own token, never the Tailscale login (lib/fleet.sh)."""
            h = self.headers
            if path == "/api/v1/device/bundle" and devices is not None:
                return self.bundle()
            try:
                n = int(h.get("Content-Length") or "0")
            except ValueError:
                n = -1
            if n < 0 or n > DEVICE_BODY_MAX:
                return self.json(413, {"error": "the request is too large"})
            try:
                body = json.loads(self.read_body(n) or b"{}")
            except ValueError:
                return self.json(400, {"error": "the body is not JSON"})
            if not isinstance(body, dict):
                return self.json(400, {"error": "the body is a JSON object"})
            if devices is None:
                return self.json(404, {"error": "this server takes no devices"})
            route = path[len("/api/v1/device/"):]
            if route == "join":
                if devices.join_refused():
                    return self.json(429, {"error": "too many wrong codes this minute; wait one"})
                keep = {k: body.get(k) for k in ("code", "id", "host", "hw_uuid", "version", "protocol")}
                code, out, err = run([devices.cli, "fleet", "join"], None, stdin=json.dumps(keep).encode(), timeout=30)
                if code == 3:
                    devices.join_failed()
                if code != 0:
                    return self.json(DEVICE_EXIT.get(code, 500), {"error": last_line(err) or "the join failed"})
                return self.send(200, out.strip() + "\n", "application/json")
            if route not in ("heartbeat", "rotate", "commands", "result", "events", "files", "permits"):
                return self.json(404, {"error": "not found"})
            auth = h.get("Authorization") or ""
            token = auth[7:].strip() if auth.startswith("Bearer ") else ""
            did = body.get("id")
            if not isinstance(did, str) or not DEVICE_ID.match(did) or not DEVICE_TOKEN.match(token):
                return self.json(401, {"error": "unauthorized"})
            used, rec = devices.auth(did, token)
            if not used:
                return self.json(401, {"error": "revoked" if rec and rec.get("revoked") else "unauthorized"})
            if body.get("protocol") != DEVICE_PROTOCOL:
                return self.json(409, {"error": "this brain speaks device protocol %d; update chartroom on the device" % DEVICE_PROTOCOL})
            if route in ("events", "files", "permits"):
                attempt = body.get("attempt")
                keep = {"events": ("offset", "lines"), "files": ("name", "content"), "permits": ("cards",)}[route]
                return self.ingest(route, did, body.get("home"), body.get("task"), attempt if isinstance(attempt, int) else -1,
                                   {k: body.get(k) for k in keep})
            if route == "commands":
                try:
                    wait = max(0, min(POLL_MAX, int(body.get("wait") or 0)))
                except (TypeError, ValueError):
                    wait = 0
                end = time.time() + wait
                while True:
                    cmds = devices.pending(did)
                    if cmds or time.time() >= end:
                        return self.json(200, {"commands": cmds})
                    time.sleep(0.5)
            if route == "result":
                cid = body.get("cmd")
                if not isinstance(cid, str) or not CMD_ID.match(cid):
                    return self.json(400, {"error": "cmd is a command id"})
                if not devices.answer(did, cid, body):
                    return self.json(404, {"error": "no such command for this device"})
                return self.json(200, {"ok": True})
            if route == "heartbeat":
                devices.heartbeat(did, body, self.client_address[0])
                return self.json(200, {"ok": True, "name": rec.get("name"), "rotate": bool(rec.get("rotate")),
                                       "brain_time": int(time.time()), "protocol": DEVICE_PROTOCOL})
            new = body.get("token")
            if not isinstance(new, str) or not DEVICE_TOKEN.match(new):
                return self.json(400, {"error": "a new token is 64 hex characters"})
            code, out, err = run([devices.cli, "fleet", "rotate"], None,
                                 stdin=json.dumps({"id": did, "auth_sha256": used, "token": new}).encode(), timeout=30)
            if code != 0:
                return self.json(DEVICE_EXIT.get(code, 500), {"error": last_line(err) or "the rotate failed"})
            return self.json(200, {"ok": True})

        def do_POST(self):
            path = urlsplit(self.path).path
            if path.startswith("/api/v1/device/"):
                return self.device(path)
            if not self.who():
                return self.json(403, {"error": "forbidden"})
            h = self.headers
            # No cross-site writes: our own header (a form or an image cannot send it), JSON only,
            # and when the browser says where the request came from, it came from this app.
            if h.get("X-Chartroom-App") != "1":
                return self.json(403, {"error": "writes come from the app only"})
            if h.get("Sec-Fetch-Site") not in (None, "same-origin", "none"):
                return self.json(403, {"error": "cross-site write refused"})
            origin = h.get("Origin")
            if origin and urlsplit(origin).netloc.lower() != (h.get("Host") or "").lower():
                return self.json(403, {"error": "cross-origin write refused"})
            up = re.match(r"^/api/v1/homes/([^/]+)/tasks/([^/]+)/attachments$", path)
            if up:
                return self.upload(unquote(up.group(1)), unquote(up.group(2)))
            if not (h.get("Content-Type") or "").startswith("application/json"):
                return self.json(403, {"error": "writes come from the app only"})
            if path in ("/api/v1/push/subscribe", "/api/v1/push/unsubscribe"):
                try:
                    n = int(h.get("Content-Length") or "0")
                except ValueError:
                    n = -1
                if n < 0 or n > 8192:
                    return self.json(413, {"error": "the request is too large"})
                try:
                    body = json.loads(self.read_body(n) or b"{}")
                except ValueError:
                    return self.json(400, {"error": "the body is not JSON"})
                if not isinstance(body, dict):
                    return self.json(400, {"error": "the body is a JSON object"})
                code, out = pusher.subscribe(body) if path.endswith("/subscribe") else pusher.unsubscribe(body)
                return self.json(code, out)
            if path == "/api/v1/fleet/check":
                # Check again: every machine's probe now (ssh to the others), so a write's checks.
                # Its body is read (and ignored), or the next request on this connection starts inside it.
                try:
                    n = int(h.get("Content-Length") or "0")
                except ValueError:
                    n = -1
                if n < 0 or n > BODY_MAX:
                    return self.json(413, {"error": "the request is too large"})
                self.read_body(n)
                hub.looked()
                fleet.wake.set()
                return self.json(202, {"ok": True})
            m = re.match(r"^/api/v1/homes/([^/]+)/([a-z]+(?:-[a-z]+)?)$", path)
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
                body = json.loads(self.read_body(n) or b"{}")
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
    ap.add_argument("--push", choices=("on", "off"), default="off", help="Web Push for new Needs me items (CHARTROOM_APP_PUSH)")
    ap.add_argument("--push-subject", default="mailto:chartroom@example.com", help="the VAPID contact (CHARTROOM_APP_PUSH_SUBJECT)")
    ap.add_argument("--push-hold", type=int, default=120, help="seconds a worker's card or decision waits for the XO before it is pushed (CHARTROOM_APP_PUSH_HOLD)")
    ap.add_argument("--fleet-dir", help="the device registry (lib/fleet.sh): device routes are served only with it")
    args = ap.parse_args()
    if not args.no_auth and not (args.user or "").strip():
        sys.exit("chartroom app: --user (CHARTROOM_APP_USER) or --no-auth")
    # Out of whatever directory started it (a task's worktree, say): sweep reaps what runs in one.
    os.chdir(os.path.dirname(args.pidfile) if args.pidfile else "/")
    hub = Hub(args.bin)
    if not hub.discover():
        sys.exit("chartroom app: no registered home to show (chartroom homes; register one with: chartroom homes add <name> <path>)")
    try:
        httpd = ThreadingHTTPServer((LOOPBACK, args.port), None)
    except OSError as exc:
        sys.exit("chartroom app: cannot listen on %s:%d: %s" % (LOOPBACK, args.port, exc.strerror or exc))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    actions = Actions(hub, args.bin, os.path.join(os.path.dirname(args.pidfile), "app-actions.ndjson") if args.pidfile else None)
    prs = Prs(hub)
    fleet = Fleet(hub, args.bin)
    pusher = Pusher(hub, fleet, args.root, os.path.dirname(args.pidfile) if args.pidfile else None, args.push, args.push_subject, args.push_hold)
    devices = None
    if args.fleet_dir:
        os.environ["CHARTROOM_FLEET_DIR"] = args.fleet_dir  # the fleet verbs this server runs read the same registry
        devices = Devices(args.bin, args.fleet_dir, fleet)
        devices.start()
    httpd.RequestHandlerClass = make_handler(hub, args, args.root, actions, prs, fleet, pusher, devices)

    def cleanup(*_):
        if devices:
            devices.stop()
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
    threading.Thread(target=prs.loop, daemon=True).start()
    threading.Thread(target=fleet.loop, daemon=True).start()
    threading.Thread(target=pusher.loop, daemon=True).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
