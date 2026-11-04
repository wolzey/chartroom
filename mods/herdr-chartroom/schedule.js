// When the Tasks panel reads `chartroom radar --json`: only while it is on screen, soon after a
// change to a task's records or to a worker's state, at most once per FLOOR_MS, and every
// FALLBACK_MS whatever happened (for what nothing announces: a waiting window running out, a
// home no watch covers, a missed change). Pure: main.js feeds it the app's live data, and
// test/js/herdr-schedule.test.js runs it under node.

// The files a task's radar row is read from (status_rows in bin/chartroom): meta.json and
// events.log, report.md (has_report) and brief.md (mentions). Nothing else under tasks/ shows in
// the panel: not a headless worker's claude.jsonl, scratch files, or meta.json.tmp before its
// rename to meta.json.
export const ROW_FILES = ["meta.json", "events.log", "report.md", "brief.md"];

// A read costs a few seconds of CPU (status in every home), so changes never read more than one
// every FLOOR_MS, the old poll's pace: a busy crew writes something more often than that (measured:
// a 30 s floor read every 30 s). A burst of writes (an event, then meta.json) waits QUIET_MS.
export const FLOOR_MS = 60000;
export const QUIET_MS = 1500;
export const FALLBACK_MS = 300000;
// After a failed read, or while a home has no watch: the old once-a-minute poll.
export const RETRY_MS = 60000;

// Is a block showing <mod> anywhere in this layout tree?
export function present(node, mod) {
  return node?.content?.mod === mod || (node?.children ?? []).some((c) => present(c, mod));
}

// Is that block on screen? Hidden nodes and a stack's other children aren't.
export function shown(node, mod) {
  if (!node || node.hidden) return false;
  if (node.content?.mod === mod) return true;
  const kids = node.children ?? [];
  if (node.type === "stack") return shown(kids.find((c) => c.id === node.active) ?? kids[0], mod);
  return kids.some((c) => shown(c, mod));
}

// A copy in a tab's pane (`tab.new {mod}`), not in the layout: on screen while its tab is the one
// the shown space shows.
export function paneShown(spaces, panes, mod) {
  const tabs = new Set((spaces ?? []).filter((s) => s.active).flatMap((s) => (s.tabs ?? []).filter((t) => t.active).map((t) => t.id)));
  return (panes ?? []).some((p) => p.mod === mod && tabs.has(p.tab));
}

// Is this copy on screen? An overlay is while it is open (it closes with its copy); a layout
// block when shown() says so; anything else only as a pane in the shown tab. `where`:
// {overlay, layout, spaces, panes}, from props(), layout(), spaces() and panes().
export function onScreen(where, mod) {
  if (where?.overlay != null) return true;
  if (present(where?.layout, mod)) return shown(where.layout, mod);
  return paneShown(where?.spaces, where?.panes, mod);
}

// macOS reports /tmp and /var under /private; a trailing slash changes nothing.
const norm = (p) => String(p ?? "").replace(/^\/private(?=\/(?:tmp|var)(?:\/|$))/, "").replace(/(.)\/+$/, "$1");

// Does one watchFolder batch for <root> (a home's tasks/ folder) touch what the panel shows?
// The root itself means the app dropped paths and everything may have changed; a folder right
// under the root is a task created, removed or renamed.
export function touches(paths, root) {
  const r = norm(root);
  return (paths ?? []).some((p) => {
    const q = norm(p);
    const cut = q.lastIndexOf("/");
    return q === r || ROW_FILES.includes(q.slice(cut + 1)) || q.slice(0, cut) === r;
  });
}

// The tasks/ folders to watch, from a radar read: this machine's homes that it read. A home it
// could not read (no tasks/ folder) gets no watch. (A home-level change stamp, <home>/.changed,
// is coming: one file in the home root, which watchFolder can't watch without the whole home and
// its worktrees, so it would be a stat in main.js's tick instead, through fs/promises.)
export function taskDirs(radar) {
  if (radar?.machine?.local === false) return [];
  return (radar?.machine?.homes ?? [])
    .filter((h) => h && !h.error && typeof h.path === "string" && h.path.startsWith("/"))
    .map((h) => `${norm(h.path)}/tasks`);
}

// The live state of this machine's workers for the tasks the panel lists (<ids>, a Set), as the
// app sees them: a radar row's `live` comes from it, and an hc worker's turn ending writes nothing
// under tasks/. A new task's worker counts from the read its meta.json brings. "done" is an
// "idle" nobody has looked at yet, the same to the radar, so looking at a worker reads nothing.
export function workerSig(terminals, ids) {
  return (terminals ?? [])
    .filter((t) => ids?.has(t?.labels?.["chartroom.task"]) && !String(t.address ?? "").includes("/"))
    .map((t) => [t.address, t.labels["chartroom.task"], t.state ?? "", t.status === "done" ? "idle" : t.status ?? ""].join(" "))
    .sort()
    .join("\n");
}

// Read now? s: {busy, shown, dirty (a change since the last read began), changedAt (the latest
// change), dirtyAt (the first one), triedAt (the last read began), retry (read at RETRY_MS)}.
export function due(s, now) {
  if (s.busy || !s.shown) return false;
  const since = now - (s.triedAt ?? 0);
  if (s.dirty && since >= FLOOR_MS && (now - s.changedAt >= QUIET_MS || now - s.dirtyAt >= FLOOR_MS)) return true;
  return since >= (s.retry ? RETRY_MS : FALLBACK_MS);
}
