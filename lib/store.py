"""chartroom's store: the one SQLite database per machine that holds every record born after a home
turned the store on (CHARTROOM_STORE=sqlite in its own config). Records born before stay files and
are read as files (lib/store.sh); nothing here reads, moves or rewrites them.

This is the only code that opens the database. bin/chartroom runs it through lib/store.sh as
`python3 -I -S lib/store.py <command> ...`; nothing else names the file. Every value is a bound
parameter, every write is one short BEGIN IMMEDIATE transaction, and the database runs in WAL mode
with a busy timeout, so many workers' `chartroom event` calls at once queue instead of failing.

Stdlib only, Python 3.8 or later (macOS's /usr/bin/python3 included).

A home is known by its uid (<home>/.home-id, written once), never by its path, so a renamed or
moved home keeps its records; its name and path are refreshed on each write.

Tables (PRAGMA user_version 2; each version is a forward-only migration in MIGRATIONS):
  homes   one row per home: hid, uid, name, path, store_since
  tasks   one row per task born in the store: the meta.json keys chartroom reads by name as
          columns, every other key in `extra` (JSON), plus spool_offset (bytes of the task's
          events.spool taken in). Meta columns have no declared type, so a value keeps the JSON
          type it was given ("1" stays a string, 1 a number), as in a meta.json.
  events  append-only, never updated or deleted: seq (one counter for the machine), the task, the
          time and kind and text as the worker wrote them, and where it came from (src: cli, spool).
  marks   (2) done and removed marks on any item, file-born or store-born: (kind, ref) -> when, by
          whom, why. The item itself is never written (lib/marks.sh).
  inbox   (2) inbox items born in the store, read beside inbox.md's lines
  focus   (2) the home's focus while the switch is on (lib/focus.sh), one row

The task's events render as the exact lines an events.log holds, "<ts> <kind>: <text>\\n", in seq
order. Rendering is deterministic and append-only, so a byte offset into the rendered text stays
valid as events are added (watch's cursor, hc's prompt check, a worker's card id).
"""

import calendar
import json
import os
import re
import sqlite3
import sys
import time

SCHEMA_VERSION = 2

# meta.json keys kept as columns (the rest go in `extra`). The order is the one `chartroom new`
# writes a meta.json in, which the rendered file keeps; later columns follow the extra keys.
FIRST_COLS = ("id", "title", "kind", "backend", "backend_source", "project", "base", "base_sha",
              "branch", "plan_gate", "worktree", "created", "updated")
LATER_COLS = ("dispatched", "closed", "parked", "session_id")
META_COLS = FIRST_COLS + LATER_COLS

MIGRATIONS = {
    1: """
CREATE TABLE homes (
  hid INTEGER PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  path TEXT NOT NULL,
  store_since TEXT NOT NULL
);
CREATE TABLE tasks (
  hid INTEGER NOT NULL REFERENCES homes(hid),
  id, title, kind, backend, backend_source, project, base, base_sha, branch, plan_gate, worktree,
  created, updated, dispatched, closed, parked, session_id,
  extra TEXT NOT NULL DEFAULT '{}',
  spool_offset INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hid, id)
);
CREATE INDEX tasks_open ON tasks(hid, closed);
CREATE TABLE events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  hid INTEGER NOT NULL,
  task TEXT NOT NULL,
  ts TEXT NOT NULL,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  src TEXT NOT NULL,
  FOREIGN KEY (hid, task) REFERENCES tasks(hid, id)
);
CREATE INDEX events_task ON events(hid, task, seq);
CREATE INDEX events_home ON events(hid, seq);
""",
    2: """
CREATE TABLE marks (
  hid INTEGER NOT NULL REFERENCES homes(hid),
  kind TEXT NOT NULL,
  ref TEXT NOT NULL,
  removed_at TEXT, removed_by TEXT, removed_why TEXT,
  done_at TEXT, done_by TEXT,
  PRIMARY KEY (hid, kind, ref)
);
CREATE TABLE inbox (
  hid INTEGER NOT NULL REFERENCES homes(hid),
  id TEXT NOT NULL,
  section TEXT NOT NULL,
  created TEXT NOT NULL,
  project TEXT,
  text TEXT NOT NULL,
  PRIMARY KEY (hid, id)
);
CREATE TABLE focus (
  hid INTEGER PRIMARY KEY REFERENCES homes(hid),
  doc TEXT NOT NULL
);
""",
}

ID_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
# A spool line: what the brief's fallback and the launch wrappers append with printf.
SPOOL_RE = re.compile(r"^(\S+) ([a-z]+): ?(.*)$")
SPOOL_LINE_MAX = 65536


class Fail(Exception):
    def __init__(self, msg, code=1):
        Exception.__init__(self, msg)
        self.code = code


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def db_path():
    p = os.environ.get("CHARTROOM_DB", "")
    if not p:
        raise Fail("CHARTROOM_DB is not set (lib/store.sh sets it)")
    return p


def connect(create):
    path = db_path()
    if not os.path.exists(path):
        if not create:
            return None
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    conn.execute("PRAGMA busy_timeout = 10000")
    conn.execute("PRAGMA foreign_keys = ON")
    if conn.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal":
        conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    migrate(conn)
    return conn


def migrate(conn):
    v = conn.execute("PRAGMA user_version").fetchone()[0]
    if v >= SCHEMA_VERSION:
        if v > SCHEMA_VERSION:
            raise Fail("the store at %s is schema %d, newer than this chartroom (%d): update chartroom" % (db_path(), v, SCHEMA_VERSION))
        return
    conn.execute("BEGIN IMMEDIATE")
    try:
        v = conn.execute("PRAGMA user_version").fetchone()[0]
        while v < SCHEMA_VERSION:
            v += 1
            for stmt in MIGRATIONS[v].split(";"):
                if stmt.strip():
                    conn.execute(stmt)
            conn.execute("PRAGMA user_version = %d" % v)
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


class Tx:
    """BEGIN IMMEDIATE ... COMMIT (ROLLBACK on any error)."""

    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        self.conn.execute("BEGIN IMMEDIATE")
        return self.conn

    def __exit__(self, kind, value, tb):
        self.conn.execute("ROLLBACK" if kind else "COMMIT")
        return False


# ------------------------------------------------------------------ homes


class Home:
    def __init__(self, uid, name, path):
        if not uid:
            raise Fail("no home uid")
        self.uid, self.name, self.path = uid, name or os.path.basename(path.rstrip("/")), path

    def hid(self, conn, create=False):
        """The home's row id: None when it has none (read), made or refreshed (write, in a tx)."""
        row = conn.execute("SELECT hid, name, path FROM homes WHERE uid = ?", (self.uid,)).fetchone()
        if row is None:
            if not create:
                return None
            cur = conn.execute("INSERT INTO homes(uid, name, path, store_since) VALUES (?, ?, ?, ?)",
                               (self.uid, self.name, self.path, now()))
            return cur.lastrowid
        if create and (row[1] != self.name or row[2] != self.path):
            conn.execute("UPDATE homes SET name = ?, path = ? WHERE hid = ?", (self.name, self.path, row[0]))
        return row[0]

    def task_dir(self, tid):
        return os.path.join(self.path, "tasks", tid)


# ------------------------------------------------------------------ tasks


def check_id(tid):
    if not ID_RE.match(tid or ""):
        raise Fail("task id '%s' must match [a-z][a-z0-9_-]{0,31}" % tid)


def task_new(conn, home, doc):
    if not isinstance(doc, dict):
        raise Fail("task-new: the record must be a JSON object")
    tid = doc.get("id")
    check_id(tid)
    # One place per id: a task born as files is never also born here.
    if os.path.exists(os.path.join(home.task_dir(tid), "meta.json")):
        raise Fail("task %s already exists (as files)" % tid, 4)
    cols = {k: doc[k] for k in META_COLS if k in doc}
    extra = {k: v for k, v in doc.items() if k not in META_COLS}
    with Tx(conn):
        hid = home.hid(conn, create=True)
        if conn.execute("SELECT 1 FROM tasks WHERE hid = ? AND id = ?", (hid, tid)).fetchone():
            raise Fail("task %s already exists" % tid, 4)
        names = ["hid"] + list(cols) + ["extra"]
        conn.execute("INSERT INTO tasks(%s) VALUES (%s)" % (", ".join(names), ", ".join("?" * len(names))),
                     [hid] + list(cols.values()) + [json.dumps(extra)])


def task_row(conn, hid, tid):
    cur = conn.execute("SELECT * FROM tasks WHERE hid = ? AND id = ?", (hid, tid))
    row = cur.fetchone()
    if row is None:
        return None
    return dict(zip([c[0] for c in cur.description], row))


def meta_doc(row):
    """The task's meta.json, as chartroom has always read it."""
    extra = json.loads(row["extra"] or "{}")
    doc = {}
    if "schema" in extra:
        doc["schema"] = extra["schema"]
    for k in FIRST_COLS:
        if row.get(k) is not None:
            doc[k] = row[k]
    for k, v in extra.items():
        if k != "schema":
            doc[k] = v
    for k in LATER_COLS:
        if row.get(k) is not None:
            doc[k] = row[k]
    return doc


def meta_set(conn, home, tid, key, value):
    if not KEY_RE.match(key or "") or key == "id":
        raise Fail("meta-set: '%s' is not a key chartroom sets" % key)
    with Tx(conn):
        hid = home.hid(conn, create=True)
        row = task_row(conn, hid, tid)
        if row is None:
            raise Fail("no such task: %s" % tid, 3)
        stamp = now()
        if key in META_COLS:
            conn.execute("UPDATE tasks SET %s = ?, updated = ? WHERE hid = ? AND id = ?" % key, (value, stamp, hid, tid))
        else:
            extra = json.loads(row["extra"] or "{}")
            extra[key] = value
            conn.execute("UPDATE tasks SET extra = ?, updated = ? WHERE hid = ? AND id = ?", (json.dumps(extra), stamp, hid, tid))


# ------------------------------------------------------------------ events


def ingest_spool(conn, home, hid, tid):
    """Take in the task's events.spool past its offset: lines a worker or a launch wrapper appended
    with printf. Call inside a transaction. Only whole lines are taken; the file is never written."""
    path = os.path.join(home.task_dir(tid), "events.spool")
    try:
        size = os.path.getsize(path)
    except OSError:
        return 0
    row = conn.execute("SELECT spool_offset FROM tasks WHERE hid = ? AND id = ?", (hid, tid)).fetchone()
    if row is None or size <= row[0]:
        return 0
    off = row[0]
    with open(path, "rb") as f:
        f.seek(off)
        data = f.read(size - off)
    end = data.rfind(b"\n")
    if end < 0:
        return 0
    n = 0
    for raw in data[:end].split(b"\n"):
        line = raw.decode("utf-8", "replace").rstrip("\r")
        if not line.strip():
            continue
        m = SPOOL_RE.match(line[:SPOOL_LINE_MAX])
        if m:
            ts, kind, text = m.group(1), m.group(2), m.group(3)
        else:
            ts, kind, text = now(), "note", "unparsed spool line: " + line[:SPOOL_LINE_MAX]
        conn.execute("INSERT INTO events(hid, task, ts, kind, text, src) VALUES (?, ?, ?, ?, ?, 'spool')",
                     (hid, tid, ts, kind, text.replace("\n", " ")))
        n += 1
    conn.execute("UPDATE tasks SET spool_offset = ? WHERE hid = ? AND id = ?", (off + end + 1, hid, tid))
    return n


def add_event(conn, home, tid, kind, text, src):
    if not re.match(r"^[a-z]+$", kind or ""):
        raise Fail("event: bad kind '%s'" % kind)
    with Tx(conn):
        hid = home.hid(conn, create=True)
        if not conn.execute("SELECT 1 FROM tasks WHERE hid = ? AND id = ?", (hid, tid)).fetchone():
            raise Fail("no such task: %s" % tid, 3)
        # What a worker spooled came first.
        ingest_spool(conn, home, hid, tid)
        conn.execute("INSERT INTO events(hid, task, ts, kind, text, src) VALUES (?, ?, ?, ?, ?, ?)",
                     (hid, tid, now(), kind, text.replace("\n", " "), src))


def add_events(conn, home, items, src):
    """Several tasks' events in one transaction: [(id, kind, text)]; every task must be in the store."""
    with Tx(conn):
        hid = home.hid(conn, create=True)
        for tid, kind, text in items:
            if not re.match(r"^[a-z]+$", kind or "") or not conn.execute("SELECT 1 FROM tasks WHERE hid = ? AND id = ?", (hid, tid)).fetchone():
                raise Fail("events: no such task %s (nothing was written)" % tid, 3)
            ingest_spool(conn, home, hid, tid)
            conn.execute("INSERT INTO events(hid, task, ts, kind, text, src) VALUES (?, ?, ?, ?, ?, ?)",
                         (hid, tid, now(), kind, text.replace("\n", " "), src))


def event_lines(conn, hid, tid):
    for ts, kind, text in conn.execute("SELECT ts, kind, text FROM events WHERE hid = ? AND task = ? ORDER BY seq", (hid, tid)):
        yield "%s %s: %s\n" % (ts, kind, text)


def event_epoch(line):
    """The epoch seconds of an event line's timestamp, or None."""
    ts = line.split(" ", 1)[0]
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ"):
        try:
            return calendar.timegm(time.strptime(ts, fmt))
        except ValueError:
            pass
    return None


def spooled_ids(home, ids):
    """The tasks among ids whose events.spool holds more than the store has taken in."""
    return [t for t in ids if os.path.exists(os.path.join(home.task_dir(t), "events.spool"))]


# ------------------------------------------------------------------ rendering


def write_atomic(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(data)
    os.replace(tmp, path)


def render_meta(conn, home, outdir, ids):
    """<outdir>/<id>/meta.json for each of ids in the store; 3 when none of them is."""
    hid = home.hid(conn)
    found = 0
    for t in ids:
        row = task_row(conn, hid, t) if hid is not None else None
        if row is None:
            continue
        d = os.path.join(outdir, t)
        os.makedirs(d, exist_ok=True)
        write_atomic(os.path.join(d, "meta.json"), json.dumps(meta_doc(row)) + "\n")
        found += 1
    return 0 if found else 3


def render(conn, home, outdir, meta_all, events_which, ids):
    """Write <outdir>/<id>/meta.json and events.log for the tasks asked for. Prints, for --meta-all,
    one "<id>\\t<open|closed>\\t<updated>" line per task in the store."""
    hid = home.hid(conn)
    if hid is None:
        return
    rows = {}
    if meta_all:
        for row in iter_rows(conn, hid):
            rows[row["id"]] = row
    want_events = []
    if events_which == "all":
        want_events = [r[0] for r in conn.execute("SELECT id FROM tasks WHERE hid = ?", (hid,))]
    elif events_which == "open":
        want_events = [r[0] for r in conn.execute("SELECT id FROM tasks WHERE hid = ? AND COALESCE(closed, '') = ''", (hid,))]
    want_events += ids
    spooled = spooled_ids(home, want_events)
    if spooled:
        with Tx(conn):
            for t in spooled:
                ingest_spool(conn, home, hid, t)
    if events_which and not meta_all:
        for row in iter_rows(conn, hid):
            if row["id"] in want_events:
                rows[row["id"]] = row
    for t in ids:
        if t not in rows:
            r = task_row(conn, hid, t)
            if r is not None:
                rows[t] = r
    for t, row in rows.items():
        d = os.path.join(outdir, t)
        os.makedirs(d, exist_ok=True)
        write_atomic(os.path.join(d, "meta.json"), json.dumps(meta_doc(row)) + "\n")
    sizes = []
    for t in want_events:
        if t not in rows:
            continue
        d = os.path.join(outdir, t)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "events.log")
        lines = list(event_lines(conn, hid, t))
        text = "".join(lines)
        write_atomic(path, text)
        sizes.append("%s\t%d\n" % (t, len(text.encode("utf-8"))))
        # Its time is the newest event's, as a file task's events.log has the time of its last
        # append: what "nothing in its log for N minutes" reads (park).
        last = event_epoch(lines[-1]) if lines else None
        if last is not None:
            os.utime(path, (last, last))
    if events_which:
        # Each rendered log's size, for the watch (no `wc -c` per task).
        write_atomic(os.path.join(outdir, ".sizes"), "".join(sizes))
    if meta_all:
        # The home's marks, store inbox items and focus, read with the records (lib/store.sh).
        write_atomic(os.path.join(outdir, ".marks.json"), json.dumps(marks_doc(conn, hid)) + "\n")
        write_atomic(os.path.join(outdir, ".inbox.json"), json.dumps(inbox_rows(conn, hid)) + "\n")
        f = conn.execute("SELECT doc FROM focus WHERE hid = ?", (hid,)).fetchone()
        write_atomic(os.path.join(outdir, ".focus.json"), (f[0] + "\n") if f else "")
        out = sys.stdout
        for t, row in rows.items():
            out.write("%s\t%s\t%s\n" % (t, "closed" if (row.get("closed") or "") != "" else "open", row.get("updated") or ""))


def iter_rows(conn, hid):
    cur = conn.execute("SELECT * FROM tasks WHERE hid = ? ORDER BY id", (hid,))
    cols = [c[0] for c in cur.description]
    for r in cur:
        yield dict(zip(cols, r))


# ------------------------------------------------------------------ status rows
# What `status_rows` (bin/chartroom) derives from a task's record and events, for every store task
# at once: the same rules as state_of, waiting_info, breaking_of and its own last-line and mentions
# reads, which read a file task's events.log (test/store-parity.bats holds the two together).

EV_RE = re.compile(r"^(?P<ts>[^ ]+) (?P<kind>[a-z]+): ?(?P<text>.*)$")
ISO_IN_TEXT = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?Z")
REPORT_KINDS = ("progress", "waiting", "decision", "blocked", "done", "failed", "steered")


def first_word(text):
    w = text.split(None, 1)
    return w[0] if w else ""


def state_of(lines):
    """state_of's awk, for a dispatched task that is not closed."""
    s = ""
    for line in lines:
        f = line.split()
        k, w = (f[1] if len(f) > 1 else ""), (f[2] if len(f) > 2 else "")
        if (k == "note:" and w == "dispatched") or k == "steered:":
            s = "working"
        if k in ("decision:", "blocked:", "failed:"):
            s = k[:-1]
        if k == "done:":
            s = "review"
        if k == "note:" and w == "accepted" and s == "review":
            s = "done"
    return s or "working"


def iso_epoch(t):
    """waiting_info's epoch: a fraction dropped, a missing seconds field taken as :00."""
    t = re.sub(r"\.[0-9]+Z$", "Z", t)
    t = re.sub(r"T([0-9]{2}:[0-9]{2})Z$", r"T\1:00Z", t)
    try:
        return calendar.timegm(time.strptime(t, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


def todate(e):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))


def waiting_info(lines, grace, wmax, now_s):
    """waiting_info's jq: the open `waiting` event, or None."""
    if not any(" waiting: " in l for l in lines):
        return None
    ev = [m.groupdict() for m in (EV_RE.match(l) for l in lines) if m]
    idx = [j for j, e in enumerate(ev) if e["kind"] in REPORT_KINDS or (e["kind"] == "note" and e["text"].startswith("dispatched"))]
    if not idx or ev[idx[-1]]["kind"] != "waiting":
        return None
    i = idx[-1]
    rs = [j for j in range(i) if ev[j]["kind"] == "steered" or (ev[j]["kind"] == "note" and ev[j]["text"].startswith("dispatched"))]
    r = rs[-1] if rs else -1
    if any(e["kind"] in ("decision", "blocked", "failed", "done") for e in ev[r + 1:i]):
        return None
    w = ev[i]
    m = ISO_IN_TEXT.search(w["text"])
    until = iso_epoch(m.group(0)) if m else None
    if until is not None:
        deadline = until + grace * 60
    else:
        since = iso_epoch(w["ts"])
        deadline = (since if since is not None else now_s) + wmax * 60
    return {"on": w["text"], "since": w["ts"], "until": todate(until) if until is not None else None,
            "deadline": todate(deadline), "overdue": now_s > deadline,
            "announced": any(e["kind"] == "note" and e["text"].startswith("waiting overdue") for e in ev[i + 1:])}


BREAKING_SRC = re.compile(r"^[^ ]+ (decision|blocked|done|failed): ")
BREAKING_MARK = re.compile(r"^[^ ]+ [a-z]+: \[breaking\] ")


def mentions(home, tid, lines, pool):
    """The other open tasks the brief or events name, as whole words (grep -ow)."""
    try:
        with open(os.path.join(home.task_dir(tid), "brief.md"), encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        text = ""
    text += "".join(lines)
    found = set()
    for o in pool:
        if o != tid and o in text and re.search(r"(?<![A-Za-z0-9_])" + re.escape(o) + r"(?![A-Za-z0-9_])", text):
            found.add(o)
    return sorted(found)


def status_rows(conn, home, which, only, since, pool, grace, wmax, with_removed=False):
    """One JSON object per store task, for status_rows to finish (live, focus marks, short id)."""
    hid = home.hid(conn)
    if hid is None:
        return
    now_s = time.time()
    rows = [task_row(conn, hid, only)] if only else list(iter_rows(conn, hid))
    rows = [r for r in rows if r is not None]
    if not with_removed:
        gone = {r[0] for r in conn.execute("SELECT ref FROM marks WHERE hid = ? AND kind = 'task' AND removed_at IS NOT NULL", (hid,))}
        rows = [r for r in rows if r["id"] not in gone]
    pool = set(pool) | {r["id"] for r in rows if (r.get("closed") or "") == ""}
    spooled = spooled_ids(home, [r["id"] for r in rows])
    if spooled:
        with Tx(conn):
            for t in spooled:
                ingest_spool(conn, home, hid, t)
    out = sys.stdout
    for row in rows:
        closed = str(row.get("closed") or "")
        if closed:
            if which != "all":
                continue
            if since is not None:
                e = iso_epoch(closed)
                if e is None or e < since:
                    continue
        lines = list(event_lines(conn, hid, row["id"]))
        if closed:
            st = "closed"
        elif not row.get("dispatched"):
            st = "drafting"
        else:
            st = state_of(lines)
        wait = waiting_info(lines, grace, wmax, now_s) if st != "closed" else None
        last = ""
        for l in reversed(lines):
            if " note: " not in l:
                last = l.rstrip("\n")
                break
        brk_src = [l for l in lines if BREAKING_SRC.match(l)]
        try:
            has_report = os.path.getsize(os.path.join(home.task_dir(row["id"]), "report.md")) > 0
        except OSError:
            has_report = False
        doc = meta_doc(row)
        doc["_cr"] = {"state": st, "wait": wait, "last": last[21:], "last_at": last[0:20],
                      "breaking_mark": bool(brk_src) and bool(BREAKING_MARK.match(brk_src[-1])),
                      "mentions": mentions(home, row["id"], lines, pool) if st != "closed" else [],
                      "has_report": has_report}
        out.write(json.dumps(doc) + "\n")


# ------------------------------------------------------------------ marks: done and removed
# A mark says an item is done or removed, without touching the item: a task (by id), an inbox item
# (i-xxxx) or an artifact (<owner>/<slug>, the owner a task id or an inbox tag), born as files or in
# the store alike. Readers leave a removed item out and take a done mark as done. A remove can be
# undone for RESTORE_DAYS; after that the mark stays (the item stays hidden) and restore refuses.

RESTORE_DAYS = 30
MARK_KINDS = ("task", "inbox", "artifact")


def apply_marks(conn, home, op, by, why, items):
    """remove | restore | done on [(kind, ref)], in one transaction: each ref applies or fails on
    its own. Returns (applied, failed)."""
    applied, failed = [], []
    stamp = now()
    window = time.time() - RESTORE_DAYS * 86400
    with Tx(conn):
        hid = home.hid(conn, create=True)
        for kind, ref in items:
            if kind not in MARK_KINDS or not ref:
                failed.append({"ref": ref, "why": "not a task, inbox item or artifact"})
                continue
            row = conn.execute("SELECT removed_at, done_at FROM marks WHERE hid = ? AND kind = ? AND ref = ?", (hid, kind, ref)).fetchone()
            removed, done = row if row else (None, None)
            if op == "remove":
                if removed:
                    failed.append({"ref": ref, "why": "already removed (%s)" % removed})
                    continue
                conn.execute("INSERT INTO marks(hid, kind, ref, removed_at, removed_by, removed_why) VALUES (?, ?, ?, ?, ?, ?) "
                             "ON CONFLICT(hid, kind, ref) DO UPDATE SET removed_at = excluded.removed_at, "
                             "removed_by = excluded.removed_by, removed_why = excluded.removed_why",
                             (hid, kind, ref, stamp, by, why or None))
            elif op == "restore":
                if not removed:
                    failed.append({"ref": ref, "why": "not removed"})
                    continue
                e = iso_epoch(removed)
                if e is not None and e < window:
                    failed.append({"ref": ref, "why": "removed %s, past the %d days a remove can be undone" % (removed, RESTORE_DAYS)})
                    continue
                conn.execute("UPDATE marks SET removed_at = NULL, removed_by = NULL, removed_why = NULL WHERE hid = ? AND kind = ? AND ref = ?",
                             (hid, kind, ref))
            elif op == "done":
                if removed:
                    failed.append({"ref": ref, "why": "removed (restore it first)"})
                    continue
                if done:
                    failed.append({"ref": ref, "why": "already done (%s)" % done})
                    continue
                conn.execute("INSERT INTO marks(hid, kind, ref, done_at, done_by) VALUES (?, ?, ?, ?, ?) "
                             "ON CONFLICT(hid, kind, ref) DO UPDATE SET done_at = excluded.done_at, done_by = excluded.done_by",
                             (hid, kind, ref, stamp, by))
            elif op == "reopen":
                # (an artifact added again: open, as its sidecar's done goes back to null)
                conn.execute("UPDATE marks SET done_at = NULL, done_by = NULL WHERE hid = ? AND kind = ? AND ref = ?", (hid, kind, ref))
            else:
                raise Fail("mark: unknown op %s" % op)
            applied.append({"kind": kind, "ref": ref})
        conn.execute("DELETE FROM marks WHERE hid = ? AND removed_at IS NULL AND done_at IS NULL", (hid,))
    return applied, failed


def marks_doc(conn, hid):
    """{task: {ref: mark}, inbox: {...}, artifact: {...}}; a mark is {removed, by, why, done}."""
    out = {k: {} for k in MARK_KINDS}
    for kind, ref, ra, rb, rw, da in conn.execute(
            "SELECT kind, ref, removed_at, removed_by, removed_why, done_at FROM marks WHERE hid = ?", (hid,)):
        out.setdefault(kind, {})[ref] = {"removed": ra, "by": rb, "why": rw, "done": da}
    return out


# ------------------------------------------------------------------ inbox items and focus
# An inbox item born in the store: {id, section (waiting), created (date), project, text}, read
# beside inbox.md's lines (lib/dashboard.sh dashboard_inbox). Its id is unique across both.
# They are listed in the order they were added (rowid), as inbox.md's lines are.

INBOX_TAG = re.compile(r"^- \[(i-[0-9a-f]{4,})\] ", re.M)


def inbox_add(conn, home, project, text):
    import random
    try:
        with open(os.path.join(home.path, "inbox.md"), encoding="utf-8", errors="replace") as f:
            taken = set(INBOX_TAG.findall(f.read()))
    except OSError:
        taken = set()
    with Tx(conn):
        hid = home.hid(conn, create=True)
        taken |= {r[0] for r in conn.execute("SELECT id FROM inbox WHERE hid = ?", (hid,))}
        for _ in range(1000):
            tag = "i-%04x" % random.randrange(65536)
            if tag not in taken:
                break
        else:
            raise Fail("inbox: no free id")
        conn.execute("INSERT INTO inbox(hid, id, section, created, project, text) VALUES (?, ?, 'waiting', ?, ?, ?)",
                     (hid, tag, time.strftime("%Y-%m-%d", time.localtime()), project or None, text))
    return tag


def inbox_project(conn, home, tag, project):
    with Tx(conn):
        hid = home.hid(conn, create=True)
        cur = conn.execute("UPDATE inbox SET project = ? WHERE hid = ? AND id = ?", (project, hid, tag))
        if cur.rowcount == 0:
            raise Fail("no open inbox item %s" % tag, 3)


def inbox_rows(conn, hid):
    return [{"id": i, "section": s, "date": c, "project": p, "text": t}
            for i, s, c, p, t in conn.execute("SELECT id, section, created, project, text FROM inbox WHERE hid = ? ORDER BY rowid", (hid,))]


def focus_set(conn, home, doc):
    with Tx(conn):
        hid = home.hid(conn, create=True)
        if doc is None:
            conn.execute("DELETE FROM focus WHERE hid = ?", (hid,))
        else:
            conn.execute("INSERT INTO focus(hid, doc) VALUES (?, ?) ON CONFLICT(hid) DO UPDATE SET doc = excluded.doc", (hid, json.dumps(doc)))


# ------------------------------------------------------------------ upkeep (sweep --apply)


def purge(conn, home):
    """What a remove leaves that nothing needs any more: a store inbox item removed past the window
    (row and mark), and a mark on a file-born item whose file is gone (the commander's own clean-out). A task's row
    and its events are never deleted. Prints the counts."""
    hid = home.hid(conn)
    if hid is None:
        print(json.dumps({"inbox": 0, "marks": 0}))
        return
    window = time.time() - RESTORE_DAYS * 86400
    try:
        with open(os.path.join(home.path, "inbox.md"), encoding="utf-8", errors="replace") as f:
            tags = set(INBOX_TAG.findall(f.read()))
    except OSError:
        tags = set()
    n_inbox = n_marks = 0
    with Tx(conn):
        store_inbox = {r[0] for r in conn.execute("SELECT id FROM inbox WHERE hid = ?", (hid,))}
        for kind, ref, removed in list(conn.execute("SELECT kind, ref, removed_at FROM marks WHERE hid = ?", (hid,))):
            gone = False
            if kind == "inbox" and ref in store_inbox:
                e = iso_epoch(removed) if removed else None
                if e is not None and e < window:
                    conn.execute("DELETE FROM inbox WHERE hid = ? AND id = ?", (hid, ref))
                    n_inbox += 1
                    gone = True
            elif kind == "inbox":
                gone = ref not in tags
            elif kind == "task":
                gone = not os.path.exists(os.path.join(home.task_dir(ref), "meta.json")) and \
                    conn.execute("SELECT 1 FROM tasks WHERE hid = ? AND id = ?", (hid, ref)).fetchone() is None
            elif kind == "artifact":
                owner, _, slug = ref.partition("/")
                base = home.task_dir(owner) if not owner.startswith("i-") else os.path.join(home.path, "inbox", owner)
                gone = not os.path.exists(os.path.join(base, "artifacts", slug + ".json"))
            if gone:
                conn.execute("DELETE FROM marks WHERE hid = ? AND kind = ? AND ref = ?", (hid, kind, ref))
                n_marks += 1
    print(json.dumps({"inbox": n_inbox, "marks": n_marks}))


def backup(conn, outdir, keep):
    """One copy a day of the whole database (SQLite's online backup: safe while workers write)."""
    os.makedirs(outdir, mode=0o700, exist_ok=True)
    path = os.path.join(outdir, "chartroom-%s.db" % time.strftime("%Y-%m-%d", time.gmtime()))
    made = False
    if not os.path.exists(path):
        tmp = path + ".tmp"
        dest = sqlite3.connect(tmp)
        with dest:
            conn.backup(dest)
        dest.close()
        os.replace(tmp, path)
        made = True
    old = sorted(f for f in os.listdir(outdir) if re.match(r"^chartroom-\d{4}-\d{2}-\d{2}\.db$", f))
    for f in old[:-keep] if keep > 0 else []:
        os.remove(os.path.join(outdir, f))
    print(json.dumps({"backup": path, "made": made}))


# ------------------------------------------------------------------ doctor / check / legacy


def doctor(home):
    out = {"db": db_path(), "sqlite": sqlite3.sqlite_version, "python": sys.version.split()[0], "exists": os.path.exists(db_path())}
    conn = connect(create=False)
    if conn is not None:
        out["schema"] = conn.execute("PRAGMA user_version").fetchone()[0]
        out["journal"] = conn.execute("PRAGMA journal_mode").fetchone()[0]
        out["integrity"] = conn.execute("PRAGMA quick_check").fetchone()[0]
        out["size"] = os.path.getsize(db_path())
        out["homes"] = conn.execute("SELECT COUNT(*) FROM homes").fetchone()[0]
        if home is not None:
            hid = home.hid(conn)
            out["home_tasks"] = conn.execute("SELECT COUNT(*) FROM tasks WHERE hid = ?", (hid,)).fetchone()[0] if hid else 0
            out["home_open"] = conn.execute("SELECT COUNT(*) FROM tasks WHERE hid = ? AND COALESCE(closed, '') = ''", (hid,)).fetchone()[0] if hid else 0
    print(json.dumps(out))


def check(conn, home):
    """Problems as lines: an id born in both places, a spool not yet taken in."""
    hid = home.hid(conn) if conn is not None else None
    if hid is None:
        return 0
    bad = 0
    for row in iter_rows(conn, hid):
        t = row["id"]
        if os.path.exists(os.path.join(home.task_dir(t), "meta.json")):
            print("both: task %s is in the store and has a meta.json" % t)
            bad += 1
    return bad


def legacy(home):
    """What this home still keeps as files from before the store, by kind."""
    tasks_dir = os.path.join(home.path, "tasks")
    tasks = open_tasks = 0
    try:
        names = os.listdir(tasks_dir)
    except OSError:
        names = []
    for n in names:
        m = os.path.join(tasks_dir, n, "meta.json")
        if os.path.isfile(m):
            tasks += 1
            try:
                with open(m, encoding="utf-8") as f:
                    if str(json.load(f).get("closed") or "") == "":
                        open_tasks += 1
            except (OSError, ValueError):
                open_tasks += 1
    print(json.dumps({"tasks": tasks, "open_tasks": open_tasks}))


# ------------------------------------------------------------------ main


def parse(argv):
    """--key value pairs (repeatable --events), and bare flags."""
    opts = {"events": [], "meta": []}
    flags = {"--meta-all", "--events-open", "--events-all", "--all", "--pool-stdin", "--with-removed"}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in flags:
            opts[a[2:]] = True
            i += 1
        elif a.startswith("--") and i + 1 < len(argv):
            k = a[2:]
            if k in ("events", "meta"):
                opts[k].append(argv[i + 1])
            else:
                opts[k] = argv[i + 1]
            i += 2
        else:
            raise Fail("store: unexpected argument '%s'" % a)
    return opts


def home_of(opts, required=True):
    if not opts.get("uid"):
        if required:
            raise Fail("store: --uid is required")
        return None
    return Home(opts["uid"], opts.get("name", ""), opts.get("path", ""))


def main(argv):
    if not argv:
        raise Fail("usage: store.py <command> [--uid U --name N --path P] ...")
    cmd, opts = argv[0], parse(argv[1:])
    if cmd == "doctor":
        doctor(home_of(opts, required=False))
        return 0
    if cmd == "legacy":
        legacy(home_of(opts))
        return 0
    home = home_of(opts)
    if cmd == "task-new":
        task_new(connect(True), home, json.loads(opts.get("json", "null")))
        return 0
    if cmd == "meta-set":
        meta_set(connect(True), home, opts.get("id", ""), opts.get("key", ""), opts.get("value", ""))
        return 0
    if cmd == "event":
        add_event(connect(True), home, opts.get("id", ""), opts.get("kind", ""), opts.get("text", ""), opts.get("src", "cli"))
        return 0
    conn = connect(False)
    if cmd == "exists":
        if conn is None:
            return 3
        hid = home.hid(conn)
        return 0 if hid is not None and conn.execute("SELECT 1 FROM tasks WHERE hid = ? AND id = ?", (hid, opts.get("id", ""))).fetchone() else 3
    if cmd == "render" and opts["meta"]:
        return render_meta(conn, home, opts["dir"], opts["meta"]) if conn is not None else 3
    if cmd == "render":
        if conn is None:
            return 0
        which = "all" if opts.get("events-all") else ("open" if opts.get("events-open") else "")
        render(conn, home, opts["dir"], bool(opts.get("meta-all")), which, opts["events"])
        return 0
    if cmd == "events":
        if conn is None:
            return 3
        hid = home.hid(conn)
        if hid is None or task_row(conn, hid, opts.get("id", "")) is None:
            return 3
        if os.path.exists(os.path.join(home.task_dir(opts["id"]), "events.spool")):
            with Tx(conn):
                ingest_spool(conn, home, hid, opts["id"])
        sys.stdout.write("".join(event_lines(conn, hid, opts["id"])))
        return 0
    if cmd == "rows":
        if conn is None:
            return 0
        pool = [l.strip() for l in sys.stdin if l.strip()] if opts.get("pool-stdin") else []
        status_rows(conn, home, "all" if opts.get("all") else "open", opts.get("id", ""),
                    int(opts["since"]) if opts.get("since") else None, pool,
                    int(opts.get("grace", "15")), int(opts.get("max", "120")), bool(opts.get("with-removed")))
        return 0
    if cmd == "events-add":
        items = [tuple(l.rstrip("\n").split("\t", 2)) for l in sys.stdin if l.count("\t") >= 2]
        add_events(connect(True), home, items, opts.get("src", "cli"))
        return 0
    if cmd == "mark":
        items = [tuple(l.rstrip("\n").split("\t", 1)) for l in sys.stdin if "\t" in l]
        applied, failed = apply_marks(connect(True), home, opts.get("op", ""), opts.get("by", ""), opts.get("why", ""), items)
        print(json.dumps({"applied": applied, "failed": failed}))
        return 0
    if cmd == "inbox-add":
        print(inbox_add(connect(True), home, opts.get("project", ""), opts.get("text", "")))
        return 0
    if cmd == "inbox-project":
        inbox_project(connect(True), home, opts.get("id", ""), opts.get("project", ""))
        return 0
    if cmd == "focus-set":
        doc = json.loads(opts.get("json", "null"))
        focus_set(connect(True), home, doc)
        return 0
    if cmd == "purge":
        if conn is not None:
            purge(conn, home)
        return 0
    if cmd == "backup":
        if conn is not None:
            backup(conn, opts["dir"], int(opts.get("keep", "14")))
        return 0
    if cmd == "check":
        return 1 if check(conn, home) else 0
    raise Fail("store: unknown command '%s'" % cmd)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        sys.stderr.write("chartroom: %s\n" % e)
        sys.exit(e.code)
    except sqlite3.Error as e:
        sys.stderr.write("chartroom: the store (%s): %s\n" % (os.environ.get("CHARTROOM_DB", "?"), e))
        sys.exit(1)
    except BrokenPipeError:
        sys.exit(0)
