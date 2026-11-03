// Which terminal is a home's XO, and what to type into it. Pure (no Herdr imports), so
// test/js/herdr-xo.test.js runs it under node; main.js hands it the app's terminals().
//
// An XO is the agent session started in its home's folder. Workers run in worktrees, so their
// terminals never sit in a home's own folder. radar's XO list is not used: it reads the old
// herdr server, not herdr-core.

// The XOs chartroom knows how to address, best first.
const XO_APPS = ["claude-code", "codex"];

// One spelling per folder: no trailing slash, and macOS's /private/tmp and /private/var as
// /tmp and /var (a terminal reports the resolved folder; a home path may not be).
export function normPath(p) {
  if (!p) return "";
  const s = String(p).replace(/\/+$/, "").replace(/^\/private(?=\/(?:tmp|var)(?:\/|$))/, "");
  return s || "/";
}

// terminals() gives status as a word; `hc get` as { state, app }. Either way, the word.
export function statusOf(t) {
  const s = t?.status;
  return (typeof s === "string" ? s : s?.state) ?? null;
}

// What the terminal runs: the agent's own word ("claude-code", "codex", ...) when it reports one,
// "shell" for a bare shell, else "program".
export function appOf(t) {
  const app = t?.report?.app ?? (typeof t?.status === "object" ? t.status?.app : null);
  if (app) return app;
  const key = t?.program?.key;
  if (key === "claude") return "claude-code";
  if (key === "codex") return "codex";
  if (t?.program?.shell) return "shell";
  if (t?.program?.agent) return key || "agent";
  return "program";
}

const isAgent = (t) => Boolean(t?.report?.app || t?.program?.agent || (typeof t?.status === "object" && t.status?.app));

// The XO terminal for a home: a live terminal on this machine (an address with no "machine/"
// prefix) whose folder is the home's. Among several, one running Claude Code or Codex wins, then
// one the app shows (it carries a herdr.tab label), then the one whose status changed last.
// Returns { xo, app, status }, or { why: "none" } when no terminal sits there, or
// { why: "shell", terminal } when the ones that do run no agent (an XO that has exited leaves
// its shell prompt): typing `/continue` there would run it as a shell command.
export function findXo(terminals, homePath) {
  const home = normPath(homePath);
  if (!home) return { why: "none" };
  const here = (terminals ?? []).filter((t) =>
    t && t.state === "live" && !String(t.address ?? "").includes("/") &&
    (normPath(t.cwd) === home || normPath(t.foreground?.cwd) === home));
  if (!here.length) return { why: "none" };
  const agents = here.filter(isAgent);
  if (!agents.length) return { why: "shell", terminal: here[0] };
  const rank = (t) => {
    const i = XO_APPS.indexOf(appOf(t));
    return [i < 0 ? XO_APPS.length : i, t.labels?.["herdr.tab"] ? 0 : 1, -(t.status_ms ?? 0)];
  };
  const best = agents
    .map((t) => ({ t, r: rank(t) }))
    .sort((a, b) => a.r[0] - b.r[0] || a.r[1] - b.r[1] || a.r[2] - b.r[2] || String(a.t.address).localeCompare(String(b.t.address)))[0].t;
  return { xo: best, app: appOf(best), status: statusOf(best) };
}

// What the XO is given: the continue skill with the task's full id. Codex invokes a skill
// with `$`, Claude Code (and anything else) with `/`.
export function continueLine(taskId, app) {
  return `${app === "codex" ? "$" : "/"}continue ${taskId}`;
}

// Why `hc send` did not type: its exit code (9 blocked, 3 no such terminal, 11 finished; the same
// codes chartroom's hc runner reads), else hc's own message (`--json` prints
// {"error":{"kind","message"}} on stderr), else the first line it printed.
export function sendRefusal(code, stderr) {
  if (code === 9) return "is waiting on a question or permission: answer it there, then click again";
  if (code === 3 || code === 11) return "is gone";
  const text = String(stderr ?? "").trim();
  let line = text.split("\n")[0];
  try { line = JSON.parse(text)?.error?.message || line; } catch { /* not JSON: the first line */ }
  return line ? `refused: ${line}` : `refused (hc send exited ${code})`;
}
