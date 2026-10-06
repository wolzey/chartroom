#!/usr/bin/env python3
"""chartroom dashboard server: loopback only, read-only, standard library only.

Started by `chartroom dashboard`; do not run it by hand. It serves:
  /                     the page (index.html next to this file; inline CSS/JS, no CDNs)
  /api/dashboard        `chartroom dashboard --json`, cached for a few seconds
  /task/<id>/<file>     a task's brief/report/plan/final/events as plain text
  /healthz              "ok"
Lane logic lives in the CLI (lib/dashboard.sh + lanes.jq), never here. The optional gh
enrichment only looks up the state of PR links already found in task files.
Python 3.8+ (macOS /usr/bin/python3 is 3.9).
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"  # never configurable: the page has no auth because nothing else can reach it
CACHE_SECONDS = 3
GH_REFRESH_SECONDS = 300
TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
TASK_FILES = ("brief.md", "report.md", "plan.md", "final.md", "events.log")
GITHUB_PR = re.compile(r"^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$")
HERE = os.path.dirname(os.path.abspath(__file__))


class Board:
    """Runs the CLI for the lanes, caches the result, and keeps gh PR states on the side."""

    def __init__(self, cli, home, use_gh):
        self.cli, self.home = cli, home
        self.lock = threading.Lock()
        self.cached, self.cached_at = None, 0.0
        fd, self.pr_file = tempfile.mkstemp(prefix="chartroom-dashboard-prs-", suffix=".json")
        os.close(fd)
        self.pr_states = {}
        self.gh = shutil.which("gh") if use_gh else None
        self.gh_status = {"enabled": bool(self.gh), "error": None if self.gh or not use_gh else "gh not on PATH",
                          "checked_at": None}
        if not use_gh:
            self.gh_status["error"] = "disabled (--no-gh)"
        self.gh_wake = threading.Event()
        self.last_urls = []

    def get(self):
        with self.lock:
            if self.cached is not None and time.time() - self.cached_at < CACHE_SECONDS:
                return self.cached
            proc = subprocess.run([self.cli, "dashboard", "--json", "--pr-states", self.pr_file],
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


def make_handler(board, port, page):
    allowed_hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}

    class Handler(BaseHTTPRequestHandler):
        server_version = "chartroom-dashboard"
        sys_version = ""

        def log_message(self, fmt, *args):  # quiet: one line per request is noise
            pass

        def send(self, code, body, ctype):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                             "connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            # DNS-rebinding guard: a page on another origin that resolves to 127.0.0.1 still
            # sends its own Host header.
            host = self.headers.get("Host")
            if host is not None and host not in allowed_hosts:
                return self.send(403, "forbidden host\n", "text/plain; charset=utf-8")
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                return self.send(200, page, "text/html; charset=utf-8")
            if path == "/healthz":
                return self.send(200, "ok\n", "text/plain; charset=utf-8")
            if path == "/api/dashboard":
                try:
                    return self.send(200, board.get(), "application/json")
                except Exception as exc:  # surfaced on the page, not swallowed
                    return self.send(500, json.dumps({"error": str(exc)}), "application/json")
            parts = path.split("/")
            if len(parts) == 4 and parts[1] == "task" and TASK_ID.match(parts[2]) and parts[3] in TASK_FILES:
                f = os.path.join(board.home, "tasks", parts[2], parts[3])
                if os.path.isfile(f):
                    with open(f, "rb") as fh:
                        return self.send(200, fh.read(), "text/plain; charset=utf-8")
            return self.send(404, "not found\n", "text/plain; charset=utf-8")

        def do_POST(self):
            self.send(405, "read-only\n", "text/plain; charset=utf-8")

        do_PUT = do_DELETE = do_PATCH = do_POST

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=4517)
    ap.add_argument("--pidfile")
    ap.add_argument("--bin", required=True, help="path to bin/chartroom")
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--no-gh", action="store_true")
    args = ap.parse_args()

    home = os.environ.get("CHARTROOM_HOME")
    if not home:
        sys.exit("chartroom dashboard: CHARTROOM_HOME is not set (start it with `chartroom dashboard`)")
    with open(os.path.join(HERE, "index.html"), "rb") as fh:
        page = fh.read()
    board = Board(args.bin, home, not args.no_gh)
    try:
        httpd = ThreadingHTTPServer((HOST, args.port), None)
    except OSError as exc:
        sys.exit("chartroom dashboard: cannot listen on %s:%d: %s" % (HOST, args.port, exc.strerror or exc))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    httpd.RequestHandlerClass = make_handler(board, port, page)

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
        with open(tmp, "w") as fh:
            fh.write("%d %d\n" % (os.getpid(), port))
        os.replace(tmp, args.pidfile)
    url = "http://%s:%d/" % (HOST, port)
    print("chartroom dashboard: %s (home %s, %s)" % (url, home, "gh enrichment on" if board.gh else "no gh enrichment"),
          flush=True)
    if board.gh:
        threading.Thread(target=board.gh_loop, daemon=True).start()
    if args.open:
        threading.Timer(0.3, lambda: webbrowser.open(url)).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
