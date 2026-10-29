#!/usr/bin/env python3
"""chartroom dashboard server: read-only, standard library only, loopback unless told otherwise.

Started by `chartroom dashboard`; do not run it by hand. It binds 127.0.0.1 unless --host
names another IPv4 address (0.0.0.0 is every interface). Bound beyond loopback, every request
but /healthz needs the access token in $CHARTROOM_HOME/.dashboard.token (made here, 0600, on
first use): `?token=` once, then an HttpOnly cookie. --no-token turns that off. It serves:
  /                     the page (index.html next to this file, read per request; inline CSS/JS, no CDNs)
  /api/dashboard        `chartroom dashboard --json`, cached for a few seconds
  /task/<id>/<file>     a task's brief/report/plan/final/events as plain text
  /task/<id>/artifacts/<slug>.md, /inbox/<i-xxxx>/artifacts/<slug>.md
                        an artifact's text (a draft for the commander), as plain text
  /task/<id>/artifacts/<slug>.html (and /inbox/...)
                        a page artifact's HTML: crew-written, so untrusted, served sandboxed
                        under PAGE_CSP and only into a frame of this dashboard
  /task/<id>/artifacts/<slug>.pdf (and /inbox/...)
                        that page printed now by `chartroom artifact pdf`, as a download
  /pages, /pages/<task|inbox>/<id>/<slug>
                        the pages list and the viewer (pages.html, beside index.html)
  /api/pages            `chartroom artifact list --all --json`, cached like the board
  /healthz              "ok"
  /radar                the fleet radar (radar.html next to this file): every agent on every machine
  /task/<home>/<id>     one task as a page (task.html; ?m=<machine> for another machine's): a thin
                        client of /api/radar, its files and its peek, or of the board for a task
                        the radar does not show (closed, drafting)
  /api/radar            its data: `chartroom radar --json` per machine, collected off the request path
  /api/radar/peek, /api/radar/file
                        one radar agent's recent events and pane, or one of its task files (read-only)
Lane logic lives in the CLI (lib/dashboard.sh + lanes.jq), never here; so does the radar's state
table (lib/radar.sh + radar.jq). The optional gh
enrichment only looks up the state of PR links already found in task files.
Python 3.8+ (macOS /usr/bin/python3 is 3.9).
"""
import argparse
import glob
import hashlib
import hmac
import ipaddress
import json
import os
import platform
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, unquote, urlencode

LOOPBACK = "127.0.0.1"
TOKEN_FILE = ".dashboard.token"
TOKEN_COOKIE = "chartroom_dashboard"
TOKEN_MAX_AGE = 30 * 24 * 3600
CACHE_SECONDS = 3
GH_REFRESH_SECONDS = 300
TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
# A home as the radar labels it: a registered name (lib/homes.sh CR_HOME_NAME_RE), "default" (an
# older chartroom's one home), or "(this home)" (an unregistered one).
HOME_LABEL = re.compile(r"^(?:[a-z][a-z0-9-]{0,31}|\(this home\))$")
# A task id on a task's page: never a dot (ids are [a-z][a-z0-9_-]), so /task/<id>/meta.json or any
# other file name is never read as /task/<home>/<id>
PAGE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
TASK_FILES = ("brief.md", "report.md", "plan.md", "final.md", "events.log")
INBOX_TAG = re.compile(r"^i-[0-9a-f]{4,16}$")
ARTIFACT_FILE = re.compile(r"^([a-z0-9][a-z0-9-]{0,63})\.(md|html|pdf)$")
GITHUB_PR = re.compile(r"^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$")
HERE = os.path.dirname(os.path.abspath(__file__))
THEMES = ("chartroom", "hud")  # the page's themes; lib/dashboard.sh validates against the same list
THEME_SLOT = b'<html lang="en" data-theme="chartroom">'
# The pages' shared scripts and styles (eventfmt.js, markdown.js, stacks.js, eventfmt.css), spliced
# in where a page says <!--@include:name--> so every page stays one self-contained document under
# its CSP (inline script and style only).
INCLUDE = re.compile(rb"<!--@include:([a-z0-9-]+\.(js|css))-->")
# The page and the viewer: inline script and style, fetches to this server only, and (the viewer)
# frames of this server only.
PAGE_SHELL_CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; "
                  "img-src 'self' data:; base-uri 'none'; form-action 'none'")
VIEWER_CSP = PAGE_SHELL_CSP + "; frame-src 'self'"
# A page artifact (lib/pages.sh PAGE_CSP, plus sandbox): no scripts, nothing fetched, an opaque
# origin even when opened by itself, and framed only by this dashboard.
PAGE_CSP = ("sandbox allow-popups allow-popups-to-escape-sandbox; default-src 'none'; style-src 'unsafe-inline'; "
            "img-src data:; font-src data:; media-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'self'")
PDF_SECONDS = 120  # a print (the CLI's own timeout is CHARTROOM_PDF_TIMEOUT, 60s) and the wait for the one before it


class Board:
    """Runs the CLI for the lanes, caches the result, and keeps gh PR states on the side."""

    def __init__(self, cli, home, use_gh, bash=None):
        # On Windows a native python cannot run bin/chartroom (a bash script) by itself.
        self.cli, self.home = ([bash] if bash else []) + [cli], home
        self.lock = threading.Lock()
        self.cached, self.cached_at = None, 0.0
        fd, self.pr_file = tempfile.mkstemp(prefix="chartroom-dashboard-prs-", suffix=".json")
        os.close(fd)
        self.pr_states = {}
        self.gh = shutil.which(os.environ.get("CHARTROOM_GH") or "gh") if use_gh else None
        self.gh_status = {"enabled": bool(self.gh), "error": None if self.gh or not use_gh else "gh not on PATH",
                          "checked_at": None}
        if not use_gh:
            self.gh_status["error"] = "disabled (--no-gh)"
        self.gh_wake = threading.Event()
        self.last_urls = []
        self.arts, self.arts_at = None, 0.0
        self.pdf_lock = threading.Lock()  # one print at a time: each runs a Chrome

    def get(self):
        with self.lock:
            if self.cached is not None and time.time() - self.cached_at < CACHE_SECONDS:
                return self.cached
            proc = subprocess.run(self.cli + ["dashboard", "--json", "--pr-states", self.pr_file],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            if proc.returncode != 0:
                raise RuntimeError("chartroom dashboard --json failed: " + proc.stderr.decode("utf-8", "replace").strip())
            data = json.loads(proc.stdout.decode("utf-8"))
            data["pr_enrichment"] = dict(self.gh_status)
            body = json.dumps(data).encode("utf-8")
            self.cached, self.cached_at = body, time.time()
            self.last_urls = sorted({p["url"] for lane in data["lanes"].values() for c in lane for p in c.get("prs", [])})
            if any(GITHUB_PR.match(u) and u not in self.pr_states for u in self.last_urls):
                self.gh_wake.set()  # a new PR link: look it up now rather than at the next round
            return body

    def artifacts(self):
        """Every artifact, done ones too (the pages list and the viewer), cached like the board."""
        with self.lock:
            if self.arts is not None and time.time() - self.arts_at < CACHE_SECONDS:
                return self.arts
        proc = subprocess.run(self.cli + ["artifact", "list", "--all", "--json"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if proc.returncode != 0:
            raise RuntimeError("chartroom artifact list failed: " + proc.stderr.decode("utf-8", "replace").strip())
        body = json.dumps({"artifacts": json.loads(proc.stdout.decode("utf-8"))}).encode("utf-8")
        with self.lock:
            self.arts, self.arts_at = body, time.time()
        return body

    def pdf(self, ref):
        """The page <ref> printed now, as bytes; RuntimeError says why not."""
        if not self.pdf_lock.acquire(timeout=PDF_SECONDS):
            raise RuntimeError("another PDF is still printing; try again in a moment")
        fd, out = tempfile.mkstemp(prefix="chartroom-page-", suffix=".pdf")
        os.close(fd)
        try:
            # (forward slashes: on Git Bash the CLI is bash, and C:/... is a path to it)
            proc = subprocess.run(self.cli + ["artifact", "pdf", ref, "--out", out.replace("\\", "/")],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=PDF_SECONDS)
            if proc.returncode != 0:
                raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip().replace("chartroom: ", "") or "the print failed")
            with open(out, "rb") as fh:
                return fh.read()
        except subprocess.TimeoutExpired:
            raise RuntimeError("the print took longer than %ds" % PDF_SECONDS)
        finally:
            self.pdf_lock.release()
            try:
                os.remove(out)
            except OSError:
                pass

    def gh_loop(self):
        """Looks up PR states with gh in the background; any failure only disables enrichment."""
        while True:
            urls = [u for u in self.last_urls if GITHUB_PR.match(u)]
            if not urls:
                self.gh_wake.wait(GH_REFRESH_SECONDS)
                self.gh_wake.clear()
                continue
            errors = []
            for url in urls:
                try:
                    proc = subprocess.run([self.gh, "pr", "view", url, "--json", "state,isDraft,reviewDecision"],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
                except (OSError, subprocess.TimeoutExpired) as exc:
                    errors.append(str(exc))
                    break
                if proc.returncode != 0:
                    lines = proc.stderr.decode("utf-8", "replace").strip().splitlines()
                    errors.append(lines[-1] if lines else "gh pr view failed")
                    continue
                try:
                    self.pr_states[url] = json.loads(proc.stdout.decode("utf-8"))
                except ValueError:
                    errors.append("unreadable gh output")
            tmp = self.pr_file + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(self.pr_states, fh)
            os.replace(tmp, self.pr_file)
            self.gh_status["checked_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            self.gh_status["error"] = (str(errors[0]) if errors else None)
            with self.lock:
                self.cached = None
            self.gh_wake.wait(GH_REFRESH_SECONDS)
            self.gh_wake.clear()


# ---------------------------------------------------------------- the fleet radar (/radar)

RADAR_WATCH_SECONDS = 90      # a page that asked this recently keeps the collectors running
RADAR_GATE_SECONDS = 5        # how often this machine's change gate is checked
RADAR_CACHE_SECONDS = 5       # a peek or file is served from cache this long
RADAR_MACHINES_SECONDS = 300  # how often the list of machines is read again
RADAR_TIMEOUT = 90            # one machine's collection, at most
RADAR_PEEK_TIMEOUT = 25
RADAR_BACKOFF_MAX = 300
PANE_ID = re.compile(r"^[A-Za-z0-9:_-]{1,64}$")


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else None


def run_cli(argv, timeout):
    """argv in a process group of its own, the whole group killed on timeout, so an ssh it started
    never outlives it. Returns (returncode, stdout, stderr); raises subprocess.TimeoutExpired."""
    kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
        proc.communicate()
        raise
    return proc.returncode, out, err


def last_line(b):
    lines = [x.strip() for x in b.decode("utf-8", "replace").splitlines() if x.strip()]
    return lines[-1] if lines else ""


class RadarSource:
    """One machine the radar reads: its last good snapshot and how the latest run went."""

    def __init__(self, spec):
        self.spec, self.label = spec, spec["machine"]
        self.wake = threading.Event()
        self.good = None        # the last snapshot whose contact was ok
        self.latest = None      # the machine record of the latest run, whatever its contact
        self.attempt_at = self.ok_at = 0.0
        self.fails = 0
        self.gate = None        # this machine's change fingerprint at its last run
        self.retired = False


class Radar:
    """The radar's data. One collector thread per machine runs `chartroom radar --json` off the
    request path, and only while a page has asked in the last RADAR_WATCH_SECONDS: an idle
    dashboard runs nothing and never reaches another machine. This machine re-reads when its
    change gate (the task files' mtimes and herdr's agent states) moves, and at least every
    local_max seconds; another machine every `remote` seconds; failures back off. The last good
    snapshot is kept and marked stale while a machine cannot be read. What a state means is the
    CLI's (lib/dashboard/radar.jq); this schedules, caches and merges."""

    def __init__(self, cli):
        self.cli = cli
        self.lock = threading.Lock()
        self.sources = {}
        # how often to collect, and the radar's archive cutoffs (`chartroom radar machines` sets them all)
        self.settings = {"local_min": 15, "local_max": 60, "remote": 60, "done_hours": 24, "stale_days": 3}
        self.watched_at = 0.0
        self.discovered_at = 0.0
        self.discover_lock = threading.Lock()
        self.discover_error = None
        self.cache, self.flight = {}, {}
        self.herdr = shutil.which("herdr")

    def watched(self):
        return time.time() - self.watched_at < RADAR_WATCH_SECONDS

    # -- the machines
    def discover(self):
        if not self.discover_lock.acquire(blocking=False):
            return
        try:
            rc, out, err = run_cli(self.cli + ["radar", "machines", "--json"], 30)
            if rc != 0:
                raise RuntimeError(last_line(err) or "chartroom radar machines exited %d" % rc)
            listing = json.loads(out.decode("utf-8"))
            for k, v in (listing.get("settings") or {}).items():
                if k in self.settings and isinstance(v, int) and v > 0:
                    self.settings[k] = v
            specs = listing.get("machines") or []
            with self.lock:
                labels = [m["machine"] for m in specs]
                for label, src in list(self.sources.items()):
                    if label not in labels:
                        src.retired = True
                        src.wake.set()
                        del self.sources[label]
                for spec in specs:
                    if spec["machine"] not in self.sources:
                        src = RadarSource(spec)
                        self.sources[spec["machine"]] = src
                        threading.Thread(target=self.loop, args=(src,), daemon=True).start()
            self.discover_error = None
            self.discovered_at = time.time()
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired) as exc:
            self.discover_error = "could not list the machines: %s" % exc
            self.discovered_at = time.time() - RADAR_MACHINES_SECONDS + 15  # try again soon, not in 5 minutes
        finally:
            self.discover_lock.release()

    # -- collecting
    def fingerprint(self, src):
        """This machine's change gate: every home's task files (mtime, size) and herdr's agent states."""
        h = hashlib.sha1()
        for home in ((src.good or {}).get("machine") or {}).get("homes") or []:
            p = home.get("path")
            if not p:
                continue
            base = os.path.join(glob.escape(p), "tasks", "*")
            for f in sorted(glob.glob(os.path.join(base, "events.log")) + glob.glob(os.path.join(base, "meta.json"))):
                try:
                    st = os.stat(f)
                except OSError:
                    continue
                h.update(("%s %d %d\n" % (f, st.st_mtime_ns, st.st_size)).encode("utf-8", "replace"))
        if self.herdr:
            try:
                rc, out, _ = run_cli([self.herdr, "agent", "list"], 10)
                agents = json.loads(out.decode("utf-8")).get("result", {}).get("agents", []) if rc == 0 else []
                for a in sorted((str(a.get("pane_id")), str(a.get("agent_status"))) for a in agents):
                    h.update(("%s %s\n" % a).encode())
            except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired):
                pass
        return h.hexdigest()

    def due(self, src, now):
        if not src.attempt_at:
            return True
        if src.spec.get("local"):
            base, floor = self.settings["local_max"], self.settings["local_min"]
        else:
            base = floor = self.settings["remote"]
        if src.fails:
            return now - src.attempt_at >= min(base * (2 ** min(src.fails, 8)), RADAR_BACKOFF_MAX)
        if now - src.attempt_at >= base:
            return True
        return bool(src.spec.get("local")) and now - src.attempt_at >= floor and self.fingerprint(src) != src.gate

    def loop(self, src):
        while not src.retired:
            if not self.watched():
                src.wake.wait(RADAR_WATCH_SECONDS)
                src.wake.clear()
                continue
            if self.due(src, time.time()):
                self.collect(src)
                continue
            src.wake.wait(RADAR_GATE_SECONDS)
            src.wake.clear()

    def collect(self, src):
        spec = src.spec
        args = ["radar", "--json"]
        if not spec.get("local"):
            args += ["--machine", spec["machine"], "--ssh", spec["target"], "--via", spec.get("via") or "config"]
        else:
            src.gate = self.fingerprint(src)  # taken first: a change during the run brings the next one
        src.attempt_at = time.time()
        try:
            rc, out, err = run_cli(self.cli + args, RADAR_TIMEOUT)
            if rc != 0:
                raise RuntimeError(last_line(err) or "chartroom radar exited %d" % rc)
            snap = json.loads(out.decode("utf-8"))
            machine = snap["machine"]
        except subprocess.TimeoutExpired:
            return self.failed(src, "no answer within %ds" % RADAR_TIMEOUT)
        except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
            return self.failed(src, str(exc))
        with self.lock:
            src.latest = machine
            if machine.get("contact") == "ok":
                src.good, src.ok_at, src.fails = snap, src.attempt_at, 0
            else:
                src.fails += 1
        return None

    def failed(self, src, why):
        with self.lock:
            src.fails += 1
            base = dict(src.latest or {k: src.spec.get(k) for k in ("machine", "local", "target", "via")})
            src.latest = dict(base, contact="error", error=why, fetched_at=iso(time.time()))

    # -- serving
    def get(self):
        now = time.time()
        woke = not self.watched()
        self.watched_at = now
        if now - self.discovered_at > RADAR_MACHINES_SECONDS:
            threading.Thread(target=self.discover, daemon=True).start()
        machines, agents, flagships = [], [], []
        with self.lock:
            for src in self.sources.values():
                if woke:
                    src.wake.set()
                stale = src.good is not None and (src.latest or {}).get("contact") != "ok"
                m = dict(src.latest or {k: src.spec.get(k) for k in ("machine", "local", "target", "via")})
                m.setdefault("contact", "sounding")
                m.update(stale=stale, ok_at=iso(src.ok_at), attempt_at=iso(src.attempt_at))
                machines.append(m)
                if src.good:
                    agents += [dict(a, stale=stale) for a in src.good.get("agents") or []]
                    flagships += [dict(f, stale=stale) for f in src.good.get("flagships") or []]
        return json.dumps({"generated_at": iso(now), "machines": machines, "agents": agents, "flagships": flagships,
                           "settings": {k: self.settings[k] for k in ("done_hours", "stale_days")},
                           "error": self.discover_error}).encode("utf-8")

    def find(self, machine, home, tid=None, pane=None):
        """The agent (or flagship) the radar shows for these keys, and its machine; else (None, None)."""
        with self.lock:
            src = self.sources.get(machine)
            if not src or not src.good:
                return None, None
            if pane:
                return src, next((f for f in src.good.get("flagships") or [] if f.get("home") == home and f.get("pane") == pane), None)
            return src, next((a for a in src.good.get("agents") or [] if a.get("home") == home and a.get("id") == tid), None)

    def cached(self, key, fetch):
        """fetch() at most once per RADAR_CACHE_SECONDS per key, one call at a time per key."""
        hit = self.cache.get(key)
        if hit and time.time() - hit[0] < RADAR_CACHE_SECONDS:
            return hit[1]
        with self.lock:
            lock = self.flight.setdefault(key, threading.Lock())
        with lock:
            hit = self.cache.get(key)
            if hit and time.time() - hit[0] < RADAR_CACHE_SECONDS:
                return hit[1]
            val = fetch()
            now = time.time()
            for k in [k for k, v in self.cache.items() if now - v[0] > 60]:
                self.cache.pop(k, None)
            self.cache[key] = (now, val)
            return val

    def peek(self, machine, home, tid, pane, n):
        src, rec = self.find(machine, home, tid, pane)
        if rec is None:
            return 404, {"error": "no such agent on the radar"}

        def fetch():
            args = ["radar", "peek", "--machine", machine]
            if not src.spec.get("local"):
                args += ["--ssh", src.spec["target"]]
            if pane:
                args += ["--pane", pane]
            else:
                if rec.get("home_path"):
                    args += ["--home", rec["home_path"]]
                args += [tid, str(n)]
            try:
                rc, out, err = run_cli(self.cli + args, RADAR_PEEK_TIMEOUT)
            except subprocess.TimeoutExpired:
                return {"machine": machine, "fetched_at": iso(time.time()), "text": "", "error": "no answer within %ds" % RADAR_PEEK_TIMEOUT}
            except OSError as exc:
                return {"machine": machine, "fetched_at": iso(time.time()), "text": "", "error": str(exc)}
            return {"machine": machine, "fetched_at": iso(time.time()), "text": out.decode("utf-8", "replace"),
                    "error": None if rc == 0 else (last_line(err) or "peek exited %d" % rc)}
        return 200, self.cached(("peek", machine, home, tid or "", pane or "", n), fetch)

    def file(self, machine, home, tid, name):
        src, rec = self.find(machine, home, tid)
        if rec is None or name not in TASK_FILES:
            return 404, "not found\n"
        if src.spec.get("local"):
            try:
                with open(os.path.join(rec["home_path"], "tasks", tid, name), "rb") as fh:
                    return 200, fh.read()
            except (OSError, TypeError):
                return 404, "%s has no %s\n" % (tid, name)

        def fetch():
            args = ["radar", "file", "--machine", machine, "--ssh", src.spec["target"]]
            if rec.get("home_path"):
                args += ["--home", rec["home_path"]]
            try:
                rc, out, err = run_cli(self.cli + args + [tid, name], RADAR_PEEK_TIMEOUT)
            except (OSError, subprocess.TimeoutExpired) as exc:
                return 504, "could not read %s from %s: %s\n" % (name, machine, exc)
            return (200, out) if rc == 0 else (404, "could not read %s from %s: %s\n" % (name, machine, last_line(err)))
        return self.cached(("file", machine, home, tid, name), fetch)


class Page:
    """index.html as it is on disk now, read per request: an update (install.sh fast-forwards
    the checkout) shows on the next load, not only after the server restarts. A read that
    fails or looks half-written keeps the last good page."""

    def __init__(self, path, theme):
        self.path, self.theme = path, theme
        self.good = self.load()

    def load(self):
        with open(self.path, "rb") as fh:
            page = fh.read()
        # The default theme is written into the page, so it renders without a flash; a
        # browser's own choice from the page's switcher still wins.
        name = os.path.basename(self.path)
        if page.count(THEME_SLOT) != 1:
            raise ValueError("%s has no single theme slot %r" % (name, THEME_SLOT.decode()))
        if not page.rstrip().endswith(b"</html>"):
            raise ValueError("%s is incomplete (no closing </html>)" % name)
        page = INCLUDE.sub(self.include, page)
        return page.replace(THEME_SLOT, THEME_SLOT.replace(b'"chartroom"', b'"%s"' % self.theme.encode()))

    def include(self, m):
        """One shared file, read now like the page; one that is missing, empty, or could end its
        <script> or <style> early keeps the last good page."""
        name, ext = m.group(1).decode(), m.group(2)
        with open(os.path.join(os.path.dirname(self.path), name), "rb") as fh:
            body = fh.read()
        # what would end the element early, or (in a script) make the HTML parser misread the rest
        bad = (b"</script", b"<script", b"<!--") if ext == b"js" else (b"</style", b"<!--")
        hit = next((b for b in bad if b in body.lower()), None)
        if not body.strip() or hit:
            raise ValueError("%s cannot be included (%s)" % (name, "it holds " + hit.decode() if hit else "empty"))
        return b"/* " + name.encode() + b" */\n" + body

    def get(self):
        try:
            self.good = self.load()
        except (OSError, ValueError):
            pass
        return self.good


def is_loopback(host):
    return ipaddress.ip_address(host).is_loopback


def interface_addrs():
    """This machine's non-loopback IPv4 addresses (LAN, VPN and overlay interfaces alike)."""
    if os.name == "nt":  # no ip or ifconfig; Windows resolves its own host name to every adapter's address
        try:
            found = [ai[4][0] for ai in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)]
        except OSError:
            found = []
        addrs = []
        for a in found:
            ip = ipaddress.ip_address(a)
            if not (ip.is_loopback or ip.is_link_local) and a not in addrs:
                addrs.append(a)
        return addrs
    cmds = [["ifconfig", "-a"]] if platform.system() == "Darwin" else [["ip", "-o", "-4", "addr", "show"], ["ifconfig", "-a"]]
    for cmd in cmds:
        exe = shutil.which(cmd[0]) or next((d + "/" + cmd[0] for d in ("/sbin", "/usr/sbin")
                                            if os.access(d + "/" + cmd[0], os.X_OK)), None)
        if not exe:
            continue
        try:
            out = subprocess.run([exe] + cmd[1:], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        addrs = []
        for a in re.findall(r"\binet (?:addr:)?([0-9]+(?:\.[0-9]+){3})", out.decode("utf-8", "replace")):
            ip = ipaddress.ip_address(a)
            if not (ip.is_loopback or ip.is_link_local) and a not in addrs:
                addrs.append(a)
        return addrs
    return []


def load_token(home, create=False):
    """The access token, or None when there is none. With create, makes one (0600) first."""
    path = os.path.join(home, TOKEN_FILE)
    if create:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, "w") as fh:
                fh.write(secrets.token_urlsafe(32) + "\n")
    try:
        with open(path) as fh:
            token = fh.read().strip()
    except OSError:
        return None
    return token or None


def page_sidecar(path):
    """True when <slug>.html beside its <slug>.json is a page artifact `add` wrote, not a worker's
    own file (the shape lib/artifacts.sh checks)."""
    try:
        with open(path[:-len(os.path.splitext(path)[1])] + ".json") as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        return False
    return (isinstance(m, dict) and m.get("kind") == "page" and isinstance(m.get("title"), str)
            and isinstance(m.get("schema"), (int, float)) and not isinstance(m.get("schema"), bool))


def make_handler(board, port, page, viewer, host, use_token, home):
    # DNS-rebinding guard. With a token it is moot (a rebound page carries no cookie, and its
    # own origin never saw the token), so any name for this machine works; without one, only
    # its addresses and its host name do.
    allowed_hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
    # Cookies are per host, not per port: one name per port keeps two homes' dashboards on one
    # machine from overwriting each other's token.
    cookie = "%s_%d" % (TOKEN_COOKIE, port)
    if not is_loopback(host):
        names = ([host] if host != "0.0.0.0" else interface_addrs()) + [socket.gethostname()]
        names += [n + ".local" for n in names[-1:] if not n.endswith(".local")]
        allowed_hosts |= {"%s:%d" % (n, port) for n in names}
    # the fleet radar's data and page, and the task page (main sets them on the board)
    radar, radar_page = getattr(board, "radar", None), getattr(board, "radar_page", None)
    task_page = getattr(board, "task_page", None)

    class Handler(BaseHTTPRequestHandler):
        server_version = "chartroom-dashboard"
        sys_version = ""

        def log_message(self, fmt, *args):  # quiet: one line per request is noise
            pass

        def send(self, code, body, ctype, csp=PAGE_SHELL_CSP, frame="DENY", extra=()):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", frame)
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", csp)
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def authorized(self, path, query):
            """True to serve the request; otherwise the response has been sent."""
            token = load_token(home)  # read per request: a rotated token applies at once
            given = dict(parse_qsl(query)).get("token")
            if given is not None:
                if token and hmac.compare_digest(given.encode(), token.encode()):
                    # once in the URL, then a cookie: the token leaves the address bar at once
                    rest = urlencode([(k, v) for k, v in parse_qsl(query) if k != "token"])
                    self.send_response(303)
                    self.send_header("Location", path + ("?" + rest if rest else ""))
                    self.send_header("Set-Cookie", "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax"
                                     % (cookie, token, TOKEN_MAX_AGE))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return False
            else:
                for part in (self.headers.get("Cookie") or "").split(";"):
                    k, _, v = part.strip().partition("=")
                    if k == cookie and token and hmac.compare_digest(v.encode(), token.encode()):
                        return True
            msg = ("access token required: open the URL `chartroom dashboard` printed (it ends in ?token=...); "
                   "`chartroom dashboard status` on the host prints it again")
            if path.startswith("/api/"):
                self.send(401, json.dumps({"error": msg}), "application/json")
            else:
                self.send(401, msg + "\n", "text/plain; charset=utf-8")
            return False

        def do_GET(self):
            path, _, query = self.path.partition("?")
            if path == "/healthz":  # liveness only, so the CLI can check without the token
                return self.send(200, "ok\n", "text/plain; charset=utf-8")
            if use_token:
                if not self.authorized(path, query):
                    return None
            else:
                # DNS-rebinding guard: a page on another origin that resolves to this machine
                # still sends its own Host header.
                host_hdr = self.headers.get("Host")
                if host_hdr is not None and host_hdr not in allowed_hosts:
                    return self.send(403, "forbidden host\n", "text/plain; charset=utf-8")
            if path in ("/", "/index.html"):
                return self.send(200, page.get(), "text/html; charset=utf-8")
            if path == "/radar" and radar_page:
                return self.send(200, radar_page.get(), "text/html; charset=utf-8")
            if path.startswith("/api/radar") and radar:
                return self.radar_get(path, dict(parse_qsl(query)))
            if path == "/api/dashboard":
                try:
                    return self.send(200, board.get(), "application/json")
                except Exception as exc:  # surfaced on the page, not swallowed
                    return self.send(500, json.dumps({"error": str(exc)}), "application/json")
            if path == "/api/pages":
                try:
                    return self.send(200, board.artifacts(), "application/json")
                except Exception as exc:
                    return self.send(500, json.dumps({"error": str(exc)}), "application/json")
            parts = path.split("/")
            # the pages list and the viewer; the viewer finds its page in /api/pages
            if path in ("/pages", "/pages/") or (len(parts) == 5 and parts[1] == "pages" and ARTIFACT_FILE.match(parts[4] + ".md")
                                                 and ((parts[2] == "task" and TASK_ID.match(parts[3]))
                                                      or (parts[2] == "inbox" and INBOX_TAG.match(parts[3])))):
                return self.send(200, viewer.get(), "text/html; charset=utf-8", csp=VIEWER_CSP)
            # a task's page: /task/<home>/<id> (a task file's own route, /task/<id>/<file>, wins)
            if (len(parts) == 4 and parts[1] == "task" and PAGE_ID.match(parts[3])
                    and HOME_LABEL.match(unquote(parts[2])) and task_page):
                return self.send(200, task_page.get(), "text/html; charset=utf-8")
            f, art = None, None
            if len(parts) == 4 and parts[1] == "task" and TASK_ID.match(parts[2]) and parts[3] in TASK_FILES:
                f = os.path.join(board.home, "tasks", parts[2], parts[3])
            elif (len(parts) == 5 and parts[3] == "artifacts" and ARTIFACT_FILE.match(parts[4])
                  and ((parts[1] == "task" and TASK_ID.match(parts[2])) or (parts[1] == "inbox" and INBOX_TAG.match(parts[2])))):
                art = ARTIFACT_FILE.match(parts[4])
                f = os.path.join(board.home, "tasks" if parts[1] == "task" else "inbox", parts[2], "artifacts", parts[4])
            if art and art.group(2) == "pdf":
                # The one request that starts something (a Chrome): never for another site's page,
                # which could ask for it without the token on loopback (an <img> to this URL).
                # Browsers say where a request comes from; curl and older browsers say nothing.
                if self.headers.get("Sec-Fetch-Site") not in (None, "same-origin", "none"):
                    return self.send(403, "a PDF is printed only from this dashboard\n", "text/plain; charset=utf-8")
                # printed from the page beside it, never a .pdf file that happens to be there
                src = f[:-4] + ".html"
                if not (os.path.isfile(src) and page_sidecar(src)):
                    return self.send(404, "not found\n", "text/plain; charset=utf-8")
                try:
                    pdf = board.pdf(parts[2] + "/" + art.group(1))
                except RuntimeError as exc:
                    return self.send(500, "could not print the PDF: %s\n" % exc, "text/plain; charset=utf-8")
                return self.send(200, pdf, "application/pdf",
                                 extra=[("Content-Disposition", 'attachment; filename="%s.pdf"' % art.group(1))])
            if f and os.path.isfile(f):
                if art and art.group(2) == "html":
                    if not page_sidecar(f):
                        return self.send(404, "not found\n", "text/plain; charset=utf-8")
                    with open(f, "rb") as fh:
                        return self.send(200, fh.read(), "text/html; charset=utf-8", csp=PAGE_CSP, frame="SAMEORIGIN")
                with open(f, "rb") as fh:
                    return self.send(200, fh.read(), "text/plain; charset=utf-8")
            return self.send(404, "not found\n", "text/plain; charset=utf-8")

        def radar_get(self, path, q):
            if path == "/api/radar":
                return self.send(200, radar.get(), "application/json")
            m, h, tid, pane = q.get("m", ""), q.get("h", ""), q.get("id", ""), q.get("pane", "")
            if not m or not h or bool(tid) == bool(pane) or (tid and not TASK_ID.match(tid)) or (pane and not PANE_ID.match(pane)):
                return self.send(400, json.dumps({"error": "needs m, h and one of id or pane"}), "application/json")
            if path == "/api/radar/peek":
                n = q.get("n", "15")
                n = int(n) if n.isdigit() and 0 < int(n) <= 200 else 15
                code, payload = radar.peek(m, h, tid or None, pane or None, n)
                return self.send(code, json.dumps(payload), "application/json")
            if path == "/api/radar/file" and tid:
                code, body = radar.file(m, h, tid, q.get("f", ""))
                return self.send(code, body, "text/plain; charset=utf-8")
            return self.send(404, "not found\n", "text/plain; charset=utf-8")

        def do_POST(self):
            self.send(405, "read-only\n", "text/plain; charset=utf-8")

        do_PUT = do_DELETE = do_PATCH = do_POST

    return Handler


class Server(ThreadingHTTPServer):
    """On Windows, SO_REUSEADDR (http.server's default) lets a second server bind a port that
    one is already listening on; ask for the port exclusively there instead."""
    if os.name == "nt":
        allow_reuse_address = False

        def server_bind(self):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            super().server_bind()


def main():
    if os.name == "nt":  # LF in the log on Windows too: bash greps it, line ends included
        sys.stdout.reconfigure(newline="\n")
        sys.stderr.reconfigure(newline="\n")
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=4517)
    ap.add_argument("--host", default=LOOPBACK, help="IPv4 address to bind (0.0.0.0: every interface)")
    ap.add_argument("--no-token", action="store_true", help="beyond loopback, serve without the access token")
    ap.add_argument("--pidfile")
    ap.add_argument("--bin", required=True, help="path to bin/chartroom")
    ap.add_argument("--bash", help="run --bin with this bash (Git Bash on Windows)")
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--no-gh", action="store_true")
    ap.add_argument("--theme", choices=THEMES, default="chartroom", help="the page's default theme")
    args = ap.parse_args()

    home = os.environ.get("CHARTROOM_HOME")
    if not home:
        sys.exit("chartroom dashboard: CHARTROOM_HOME is not set (start it with `chartroom dashboard`)")
    try:
        if ipaddress.ip_address(args.host).version != 4:
            raise ValueError
    except ValueError:
        sys.exit("chartroom dashboard: --host must be an IPv4 address (0.0.0.0 for every interface), not %r" % args.host)
    exposed = not is_loopback(args.host)
    use_token = exposed and not args.no_token
    token = load_token(home, create=True) if use_token else None
    if use_token and not token:
        sys.exit("chartroom dashboard: cannot read or create the access token %s" % os.path.join(home, TOKEN_FILE))
    try:
        page = Page(os.path.join(HERE, "index.html"), args.theme)
        viewer = Page(os.path.join(HERE, "pages.html"), args.theme)
    except (OSError, ValueError) as exc:
        sys.exit("chartroom dashboard: %s" % exc)
    board = Board(args.bin, home, not args.no_gh, args.bash)
    board.radar = Radar(board.cli)  # the fleet radar's data and page ride on the board into the handler
    try:
        board.radar_page = Page(os.path.join(HERE, "radar.html"), args.theme)
    except (OSError, ValueError) as exc:  # the board still serves; /radar is a 404
        print("chartroom dashboard: no radar page: %s" % exc, flush=True)
        board.radar_page = None
    try:
        board.task_page = Page(os.path.join(HERE, "task.html"), args.theme)
    except (OSError, ValueError) as exc:  # likewise: /task/<home>/<id> is a 404
        print("chartroom dashboard: no task page: %s" % exc, flush=True)
        board.task_page = None
    try:
        httpd = Server((args.host, args.port), None)
    except OSError as exc:
        sys.exit("chartroom dashboard: cannot listen on %s:%d: %s" % (args.host, args.port, exc.strerror or exc))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    httpd.RequestHandlerClass = make_handler(board, port, page, viewer, args.host, use_token, home)

    def cleanup(*_):
        if args.pidfile:
            try:
                with open(args.pidfile) as fh:
                    if fh.read().split()[:1] == [str(os.getpid())]:
                        os.remove(args.pidfile)
            except OSError:
                pass
        try:
            os.remove(board.pr_file)
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    if args.pidfile:
        tmp = args.pidfile + ".tmp"
        with open(tmp, "w", newline="\n") as fh:  # LF on Windows too: bash reads it
            # the bound host only when it is not the default, so a default pid file reads as before
            fh.write("%d %d%s\n" % (os.getpid(), port, "" if args.host == LOOPBACK else " " + args.host))
        os.replace(tmp, args.pidfile)
    q = "?token=" + token if token else ""
    url = "http://%s:%d/%s" % (LOOPBACK if args.host == "0.0.0.0" else args.host, port, q)
    print("chartroom dashboard: %s (home %s, %s)" % (url, home, "gh enrichment on" if board.gh else "no gh enrichment"),
          flush=True)
    if exposed:
        where = "every interface" if args.host == "0.0.0.0" else "this address only"
        print("chartroom dashboard: WARNING: listening on %s:%d (%s), beyond this machine; %s" % (
            args.host, port, where, "the access token is the only lock" if use_token
            else "NO access token (--no-token): anyone who can reach it can read the fleet"), flush=True)
        for a in (interface_addrs() if args.host == "0.0.0.0" else [args.host]):
            print("chartroom dashboard: on the network: http://%s:%d/%s" % (a, port, q), flush=True)
    if board.gh:
        threading.Thread(target=board.gh_loop, daemon=True).start()
    if args.open:
        threading.Timer(0.3, lambda: webbrowser.open(url)).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
