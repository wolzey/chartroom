#!/usr/bin/env python3
"""chartroom dashboard server: read-only, standard library only, loopback unless told otherwise.

Started by `chartroom dashboard`; do not run it by hand. It binds 127.0.0.1 unless --host
names another IPv4 address (0.0.0.0 is every interface). Bound beyond loopback, every request
but /healthz needs the access token in $CHARTROOM_HOME/.dashboard.token (made here, 0600, on
first use): `?token=` once, then an HttpOnly cookie. --no-token turns that off. It serves:
  /                     the page (index.html next to this file; inline CSS/JS, no CDNs)
  /api/dashboard        `chartroom dashboard --json`, cached for a few seconds
  /task/<id>/<file>     a task's brief/report/plan/final/events as plain text
  /healthz              "ok"
Lane logic lives in the CLI (lib/dashboard.sh + lanes.jq), never here. The optional gh
enrichment only looks up the state of PR links already found in task files.
Python 3.8+ (macOS /usr/bin/python3 is 3.9).
"""
import argparse
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
from urllib.parse import parse_qsl, urlencode

LOOPBACK = "127.0.0.1"
TOKEN_FILE = ".dashboard.token"
TOKEN_COOKIE = "chartroom_dashboard"
TOKEN_MAX_AGE = 30 * 24 * 3600
CACHE_SECONDS = 3
GH_REFRESH_SECONDS = 300
TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
TASK_FILES = ("brief.md", "report.md", "plan.md", "final.md", "events.log")
GITHUB_PR = re.compile(r"^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$")
HERE = os.path.dirname(os.path.abspath(__file__))
THEMES = ("chartroom", "hud")  # the page's themes; lib/dashboard.sh validates against the same list
THEME_SLOT = b'<html lang="en" data-theme="chartroom">'


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


def make_handler(board, port, page, host, use_token, home):
    # DNS-rebinding guard. With a token it is moot (a rebound page carries no cookie, and its
    # own origin never saw the token), so any name for this machine works; without one, only
    # its addresses and its host name do.
    allowed_hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
    if not is_loopback(host):
        names = ([host] if host != "0.0.0.0" else interface_addrs()) + [socket.gethostname()]
        names += [n + ".local" for n in names[-1:] if not n.endswith(".local")]
        allowed_hosts |= {"%s:%d" % (n, port) for n in names}

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
                                     % (TOKEN_COOKIE, token, TOKEN_MAX_AGE))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return False
            else:
                for part in (self.headers.get("Cookie") or "").split(";"):
                    k, _, v = part.strip().partition("=")
                    if k == TOKEN_COOKIE and token and hmac.compare_digest(v.encode(), token.encode()):
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
                return self.send(200, page, "text/html; charset=utf-8")
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
    with open(os.path.join(HERE, "index.html"), "rb") as fh:
        page = fh.read()
    # The default theme is written into the page once, so it renders without a flash; a
    # browser's own choice from the page's switcher still wins.
    if page.count(THEME_SLOT) != 1:
        sys.exit("chartroom dashboard: index.html has no single theme slot %r" % THEME_SLOT.decode())
    page = page.replace(THEME_SLOT, THEME_SLOT.replace(b'"chartroom"', b'"%s"' % args.theme.encode()))
    board = Board(args.bin, home, not args.no_gh, args.bash)
    try:
        httpd = Server((args.host, args.port), None)
    except OSError as exc:
        sys.exit("chartroom dashboard: cannot listen on %s:%d: %s" % (args.host, args.port, exc.strerror or exc))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    httpd.RequestHandlerClass = make_handler(board, port, page, args.host, use_token, home)

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
