// mods/herdr-chartroom/schedule.js: when the Tasks panel reads the radar. Only while on screen
// (a layout block that's shown, an open overlay, a pane in the shown tab), after a change to a
// task's row files or a worker's live state, at most once per floor, and on a slow fallback.
// Loaded like herdr-xo.test.js: its `export`s dropped, run in a fresh context.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { test, run } = require("./harness");

const src = fs.readFileSync(path.join(__dirname, "../../mods/herdr-chartroom/schedule.js"), "utf8").replace(/^export /gm, "");
const S = vm.runInNewContext(`${src}\n;({ ROW_FILES, FLOOR_MS, QUIET_MS, FALLBACK_MS, RETRY_MS, present, shown, paneShown, onScreen, touches, taskDirs, workerSig, due })`, {});

const MOD = "chartroom";
// The shape of a layout with the panel as one child of a right-hand stack, as the README's
// example and the commander's own layout place it: a column that can be hidden, holding a stack.
function layout({ hidden = false, active = "chartroom" } = {}) {
  return {
    id: "root", type: "row",
    children: [
      { id: "sidebar", type: "block", content: { mod: "spaces" } },
      { id: "work", type: "block", content: { tab: "active" } },
      { id: "panel", type: "column", hidden,
        children: [{ id: "panel-body", type: "stack", active,
          children: [
            { id: "files", type: "block", content: { mod: "files" } },
            { id: "changes", type: "block", content: { mod: "changes" } },
            { id: "chartroom", type: "block", content: { mod: MOD } }] }] }],
  };
}
const noPanel = { id: "root", type: "row", children: [{ id: "work", type: "block", content: { tab: "active" } }] };

test("shown: the panel's block on screen, not in a hidden column or behind a stack's other child", () => {
  assert.strictEqual(S.shown(layout(), MOD), true);
  assert.strictEqual(S.shown(layout({ hidden: true }), MOD), false);
  assert.strictEqual(S.shown(layout({ active: "files" }), MOD), false);
  assert.strictEqual(S.shown(layout({ hidden: true, active: "files" }), MOD), false);
  // a stack without an active child shows its first
  const l = layout({ active: null });
  assert.strictEqual(S.shown(l, MOD), false);
  l.children[2].children[0].children.reverse();
  assert.strictEqual(S.shown(l, MOD), true);
  assert.strictEqual(S.present(layout({ hidden: true }), MOD), true);
  assert.strictEqual(S.present(noPanel, MOD), false);
  assert.strictEqual(S.shown(null, MOD), false);
});

test("onScreen: a layout without the panel no longer counts as shown", () => {
  // the old visible() was !present(l) || shown(l): true here, so a copy outside the layout polled
  assert.strictEqual(S.onScreen({ layout: noPanel, spaces: [], panes: [] }, MOD), false);
  assert.strictEqual(S.onScreen({ layout: layout(), spaces: [], panes: [] }, MOD), true);
  assert.strictEqual(S.onScreen({ layout: layout({ active: "files" }), spaces: [], panes: [] }, MOD), false);
  assert.strictEqual(S.onScreen({}, MOD), false);
});

test("onScreen: an open overlay copy is shown, whatever the layout holds", () => {
  assert.strictEqual(S.onScreen({ overlay: "ov1", layout: noPanel }, MOD), true);
  assert.strictEqual(S.onScreen({ overlay: "ov1", layout: layout({ hidden: true }) }, MOD), true);
  assert.strictEqual(S.onScreen({ overlay: undefined, layout: noPanel }, MOD), false);
});

test("onScreen: a pane copy only while its tab is the shown space's shown tab", () => {
  const spaces = [
    { id: "sp1", active: true, tabs: [{ id: "tb1", active: true }, { id: "tb2", active: false }] },
    { id: "sp2", active: false, tabs: [{ id: "tb3", active: true }] }];
  const pane = (tab, mod = MOD) => [{ pane: "p1", terminal: null, mod, tab }];
  assert.strictEqual(S.onScreen({ layout: noPanel, spaces, panes: pane("tb1") }, MOD), true);
  assert.strictEqual(S.onScreen({ layout: noPanel, spaces, panes: pane("tb2") }, MOD), false);
  assert.strictEqual(S.onScreen({ layout: noPanel, spaces, panes: pane("tb3") }, MOD), false);
  assert.strictEqual(S.onScreen({ layout: noPanel, spaces, panes: pane("tb1", "files") }, MOD), false);
  // in the layout, the layout decides: a pane elsewhere doesn't make a hidden block shown
  assert.strictEqual(S.onScreen({ layout: layout({ hidden: true }), spaces, panes: pane("tb1") }, MOD), false);
});

const ROOT = "/srv/chartroom/acme/tasks";
test("touches: a task's row files, a task folder, or the root itself", () => {
  for (const f of ["meta.json", "events.log", "report.md", "brief.md"]) assert.strictEqual(S.touches([`${ROOT}/fix-21ba/${f}`], ROOT), true, f);
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba`], ROOT), true);
  assert.strictEqual(S.touches([ROOT], ROOT), true);
  assert.strictEqual(S.touches([`${ROOT}/`], ROOT), true);
  // one relevant path in a batch is enough
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba/claude.jsonl`, `${ROOT}/fix-21ba/events.log`], ROOT), true);
});

test("touches: nothing the panel shows (a headless stream, scratch, meta.json.tmp, an artifact)", () => {
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba/claude.jsonl`], ROOT), false);
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba/meta.json.tmp`], ROOT), false);
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba/inbox.md`, `${ROOT}/fix-21ba/launch.sh`], ROOT), false);
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba/artifacts/page.html`], ROOT), false);
  // a deeper file named like a row file is still a row-file write (FSEvents names the file)
  assert.strictEqual(S.touches([`${ROOT}/fix-21ba/artifacts/events.log`], ROOT), true);
  assert.strictEqual(S.touches([], ROOT), false);
  assert.strictEqual(S.touches(null, ROOT), false);
});

test("touches: macOS's /private/var spelling of the same root", () => {
  assert.strictEqual(S.touches(["/private/var/h/tasks"], "/var/h/tasks"), true);
  assert.strictEqual(S.touches(["/private/var/h/tasks/x"], "/var/h/tasks"), true);
  assert.strictEqual(S.touches(["/private/var/h/tasks/x/claude.jsonl"], "/var/h/tasks/"), false);
});

test("taskDirs: this machine's homes the radar read, without the ones it couldn't", () => {
  const radar = { machine: { local: true, homes: [
    { name: "harbor", path: "/srv/x/.harbor", open: 23, error: null },
    { name: "personal", path: "/srv/x/chartroom/personal/", open: 7, error: null },
    { name: "broken", path: "/srv/x/nope", open: 0, error: "not a chartroom home (no /srv/x/nope/tasks)" },
    { name: "odd", path: "relative/home", open: 0, error: null }] } };
  assert.deepStrictEqual([...S.taskDirs(radar)], ["/srv/x/.harbor/tasks", "/srv/x/chartroom/personal/tasks"]);
  assert.deepStrictEqual([...S.taskDirs({ machine: { local: false, homes: radar.machine.homes } })], []);
  assert.deepStrictEqual([...S.taskDirs({})], []);
  assert.deepStrictEqual([...S.taskDirs(null)], []);
});

// A terminal as the app's terminals() gives it: status a word, labels as hc keeps them.
const term = (address, status, task, x) => Object.assign({ address, state: "live", status, labels: task ? { "chartroom.task": task } : {} }, x || {});
test("workerSig: the listed tasks' workers on this machine, by state; done and idle are the same", () => {
  const ids = new Set(["fix-21ba", "docs-7f3a", "far-0001"]);
  const sig = (ts) => S.workerSig(ts, ids);
  const a = [term("t1", "working", "fix-21ba"), term("t2", "idle", "docs-7f3a")];
  assert.strictEqual(sig(a), sig([...a].reverse()));
  assert.notStrictEqual(sig(a), sig([term("t1", "idle", "fix-21ba"), a[1]]));
  assert.notStrictEqual(sig(a), sig([term("t1", "blocked", "fix-21ba"), a[1]]));
  assert.notStrictEqual(sig(a), sig([a[0]])); // a worker's terminal went away
  assert.notStrictEqual(sig(a), sig([a[0], term("t2", "idle", "docs-7f3a", { state: "replaced" })]));
  // looking at a worker that finished (done -> idle) is no change
  assert.strictEqual(sig([a[0], term("t2", "done", "docs-7f3a")]), sig(a));
  // the XO's own terminal, plain shells and another machine's terminals are not workers here
  assert.strictEqual(sig([...a, term("t3", "working", null), term("studio/t1", "working", "far-0001")]), sig(a));
  // nor a worker of a task the panel doesn't list (closed, or in a home the radar didn't read)
  assert.strictEqual(sig([...a, term("t4", "working", "closed-9999")]), sig(a));
  assert.strictEqual(S.workerSig(a, new Set()), "");
  assert.strictEqual(S.workerSig(a, undefined), "");
  assert.strictEqual(sig([]), "");
  assert.strictEqual(sig(null), "");
});

const T0 = 1_000_000_000;
const base = (x) => Object.assign({ busy: false, shown: true, dirty: false, changedAt: 0, dirtyAt: 0, triedAt: T0, retry: false }, x);
test("due: never while hidden or busy; the first read at once", () => {
  assert.strictEqual(S.due(base({ triedAt: 0 }), T0), true);
  assert.strictEqual(S.due(base({ triedAt: 0, shown: false }), T0), false);
  assert.strictEqual(S.due(base({ triedAt: 0, busy: true }), T0), false);
  assert.strictEqual(S.due(base({ dirty: true, changedAt: T0, dirtyAt: T0, shown: false }), T0 + S.FALLBACK_MS * 10), false);
});

test("due: nothing changed reads only on the fallback", () => {
  assert.strictEqual(S.FALLBACK_MS, 300000);
  assert.strictEqual(S.FLOOR_MS, 60000); // a busy crew reads no more often than the old poll
  assert.strictEqual(S.due(base(), T0 + 60000), false); // the old once-a-minute poll is gone
  assert.strictEqual(S.due(base(), T0 + S.FALLBACK_MS - 1), false);
  assert.strictEqual(S.due(base(), T0 + S.FALLBACK_MS), true);
});

test("due: a change reads once writes are quiet, but never within the floor of the last read", () => {
  const at = T0 + 120000; // long after the last read
  assert.strictEqual(S.due(base({ dirty: true, changedAt: at, dirtyAt: at }), at), false); // still writing
  assert.strictEqual(S.due(base({ dirty: true, changedAt: at, dirtyAt: at }), at + S.QUIET_MS), true);
  // a change right after a read waits out the floor
  assert.strictEqual(S.due(base({ dirty: true, changedAt: T0 + 1000, dirtyAt: T0 + 1000 }), T0 + S.FLOOR_MS - 1), false);
  assert.strictEqual(S.due(base({ dirty: true, changedAt: T0 + 1000, dirtyAt: T0 + 1000 }), T0 + S.FLOOR_MS), true);
  // writes that never go quiet still read, a floor after they began
  const now = T0 + 120000;
  assert.strictEqual(S.due(base({ dirty: true, changedAt: now, dirtyAt: now - S.FLOOR_MS + 1 }), now), false);
  assert.strictEqual(S.due(base({ dirty: true, changedAt: now, dirtyAt: now - S.FLOOR_MS }), now), true);
});

test("due: after a failed read, or with a home no watch covers, the old minute", () => {
  assert.strictEqual(S.due(base({ retry: true }), T0 + S.RETRY_MS - 1), false);
  assert.strictEqual(S.due(base({ retry: true }), T0 + S.RETRY_MS), true);
  assert.strictEqual(S.RETRY_MS, 60000);
});

run();
