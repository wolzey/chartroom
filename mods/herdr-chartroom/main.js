// Every open chartroom task on this machine, in radar's sectors, most urgent first.
// Reads `chartroom radar --json` only while the panel is shown. Click a task to pass it to its
// home's XO: `/continue <id>` typed into that XO's terminal, which then comes to the front.
// Its chevron shows the details: the last event, PRs, and "Open worker".

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, hc, theme, layout, run, spaces, terminals } from "herdr";
import { findXo, continueLine, sendRefusal } from "./xo.js";

const MOD = "chartroom";
const EVERY = 60000;
// Radar's own order (lib/dashboard/radar.jq), most urgent first.
const SECTORS = [
  { id: "decision", label: "Decision", color: "blocked" },
  { id: "blocked", label: "Blocked", color: "blocked" },
  { id: "adrift", label: "Adrift", color: "ansi3" },
  { id: "holding", label: "Holding", color: "idle" },
  { id: "underway", label: "Underway", color: "working" },
  { id: "docked", label: "Docked", color: "done" },
];
const CAP = 500;
// How long an outcome line stays under the header.
const NOTICE_MS = 12000;

const clip = (s) => (s && s.length > CAP ? `${s.slice(0, CAP)}…` : s ?? "");
const firstLine = (e) => String(e?.message ?? e).trim().split("\n")[0];
const prLabel = (url) => {
  const m = /\/(?:_git\/)?([^/]+)\/(?:pull|pullrequest)\/(\d+)/.exec(url);
  return m ? `${m[1]}#${m[2]}` : url;
};

function duration(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// A worker that can be opened: an hc worker on this machine (`chartroom attach` shows its
// terminal in this app), or a herdr one (chartroom names its herdr agent after the task).
// "herdr-claude" and "herdr-codex" are chartroom's older names for herdr:claude and herdr:codex.
const isHc = (task) => /^hc:/.test(String(task.backend ?? ""));
const isHerdr = (task) => /^herdr[:-]/.test(String(task.backend ?? ""));
const canOpen = (task) => task.live !== "gone" && ((isHc(task) && task.local !== false) || isHerdr(task));

// Opens a herdr worker as a tab attached to its herdr agent, in a space named for its crew as
// terminal Herdr has it ("captain-crew"). A tab already open for it is shown again instead.
// `chartroom attach` can't do this one: it focuses the tab in herdr's own window, not here.
// (The radar mod keeps the same function.)
function openHerdrWorker(task) {
  const machine = task.local === false ? task.machine : null;
  const crew = `${task.home}-crew`;
  const name = `${task.short_id} · ${task.title}`.slice(0, 48);
  const argv = ["herdr", "agent", "attach", task.id];
  const space = spaces().find((s) => s.named && s.name === crew && (s.machine ?? null) === machine);
  const tab = space?.tabs.find((t) => t.name.startsWith(`${task.short_id} ·`));
  if (tab) {
    run("space.select", { id: space.id });
    run("tab.select", { id: tab.id });
  } else if (space) {
    run("tab.new", { space: space.id, name, argv });
    run("space.select", { id: space.id });
  } else {
    run("space.new", { name: crew, tab: name, argv, ...(machine ? { machine } : {}) });
  }
}

// Is a block showing this mod on screen? Hidden nodes and other stack children aren't.
function present(node) {
  return node?.content?.mod === MOD || (node?.children ?? []).some(present);
}
function shown(node) {
  if (!node || node.hidden) return false;
  if (node.content?.mod === MOD) return true;
  const kids = node.children ?? [];
  if (node.type === "stack") return shown(kids.find((c) => c.id === node.active) ?? kids[0]);
  return kids.some(shown);
}

export default class Chartroom extends View {
  init(_props, cx) {
    this.tasks = [];
    this.error = null;
    this.busy = false;
    this.fetchedAt = null;
    this.triedAt = 0;
    this.open = new Set();
    this.details = {};
    // The last outcome of a click ({ level: "info" | "ok" | "error", text, at }), and the tasks
    // being passed right now (a second click while one is on its way sends nothing).
    this.notice = null;
    this.passing = new Set();
    // What needs you starts open; the long sections start folded, which also keeps a pass short
    // (Herdr interrupted drawing all ~45 rows at once).
    this.folded = new Set(JSON.parse(localStorage.getItem("folded") ?? '["adrift","holding","underway","docked"]'));
    // A cheap check; the fetch itself runs at most once a minute, and only while shown.
    cx.timer.every(3000, (cx) => this.tick(cx));
    this.tick(cx);
  }

  visible() {
    const l = layout();
    return !present(l) || shown(l);
  }

  tick(cx) {
    if (this.notice && this.passing.size === 0 && Date.now() - this.notice.at > NOTICE_MS) {
      this.notice = null;
      cx.notify();
    }
    if (!this.busy && this.visible() && Date.now() - this.triedAt > EVERY) this.refresh(cx);
  }

  say(cx, level, text) {
    this.notice = { level, text, at: Date.now() };
    cx.notify();
  }

  // Hands a task to its home's XO: the continue skill with the task's full id, typed into the XO's
  // terminal with `hc send` (paste, then Enter once nobody is typing), and that terminal shown.
  // Never into a blocked agent (hc refuses without --force, which this never passes), never into
  // a bare shell, and it never starts an XO: each of those says why instead.
  pass(task, cx) {
    if (this.passing.has(task.key)) return;
    if (task.local === false) return this.say(cx, "error", `${task.short_id} is on ${task.machine}: pass it to the XO there`);
    const found = findXo(terminals(), task.home_path);
    if (found.why === "none") return this.say(cx, "error", `No ${task.home} XO open: no terminal in ${task.home_path}`);
    if (found.why === "shell") return this.say(cx, "error", `The ${task.home} XO isn't running: ${found.terminal.address} is a shell, not an agent`);
    const t = found.xo.address;
    if (found.status === "blocked") return this.say(cx, "error", `The ${task.home} XO (${t}) ${sendRefusal(9)}`);
    const line = continueLine(task.id, found.app);
    this.passing.add(task.key);
    this.say(cx, "info", `Passing ${task.short_id} to the ${task.home} XO (${t})…`);
    cx.spawn(async (cx) => {
      try {
        const r = await hc(["send", t, "--json", line]);
        if (r.code === 0) {
          run("agent.focus", { terminal: t });
          this.notice = { level: "ok", text: `Sent ${line} to the ${task.home} XO (${t})`, at: Date.now() };
        } else {
          this.notice = { level: "error", text: `The ${task.home} XO (${t}) ${sendRefusal(r.code, r.stderr || r.stdout)}`, at: Date.now() };
        }
      } catch (e) {
        this.notice = { level: "error", text: `Could not reach the ${task.home} XO (${t}): ${firstLine(e)}`, at: Date.now() };
      }
      this.passing.delete(task.key);
      cx.notify();
    });
  }

  // Shows a task's worker: an hc worker through `chartroom attach` in its own home (it focuses the
  // worker's terminal here, as the hc runner does), a herdr one as a tab attached to it.
  openWorker(task, cx) {
    if (!isHc(task)) return openHerdrWorker(task);
    cx.spawn(async (cx) => {
      try {
        const r = await exec("env", [`CHARTROOM_HOME=${task.home_path}`, "chartroom", "attach", task.id]);
        if (r.code !== 0) throw new Error(r.stderr.trim() || `chartroom exited ${r.code}`);
      } catch (e) {
        this.notice = { level: "error", text: `Could not open ${task.short_id}'s worker: ${firstLine(e).replace(/^chartroom: /, "")}`, at: Date.now() };
        cx.notify();
      }
    });
  }

  refresh(cx) {
    if (this.busy) return;
    this.busy = true;
    this.triedAt = Date.now();
    cx.spawn(async (cx) => {
      cx.notify();
      try {
        const r = await exec("chartroom", ["radar", "--json"]);
        if (r.code !== 0) throw new Error(r.stderr.trim() || `chartroom exited ${r.code}`);
        const d = JSON.parse(r.stdout);
        this.tasks = d.agents ?? [];
        this.error = null;
        this.fetchedAt = Date.now();
        // Details are a snapshot; reopened rows fetch them again.
        this.details = {};
      } catch (e) {
        // Keep the last board: a slow or failed read shouldn't blank the panel.
        this.error = String(e?.message ?? e).split("\n")[0];
      }
      this.busy = false;
      cx.notify();
    });
  }

  // PRs come from `chartroom show`, which answers for one home at a time.
  loadDetail(task, cx) {
    if (this.details[task.key] || !task.local) return;
    this.details[task.key] = { loading: true };
    cx.spawn(async (cx) => {
      try {
        const r = await exec("env", [`CHARTROOM_HOME=${task.home_path}`, "chartroom", "show", task.id, "--json"]);
        if (r.code !== 0) throw new Error(r.stderr.trim() || `chartroom exited ${r.code}`);
        const d = JSON.parse(r.stdout);
        this.details[task.key] = { prs: d.prs ?? [] };
      } catch (e) {
        this.details[task.key] = { error: String(e?.message ?? e).split("\n")[0] };
      }
      cx.notify();
    });
  }

  toggle(task, cx) {
    if (this.open.has(task.key)) this.open.delete(task.key);
    else {
      this.open.add(task.key);
      this.loadDetail(task, cx);
    }
    cx.notify();
  }

  fold(id, cx) {
    this.folded.has(id) ? this.folded.delete(id) : this.folded.add(id);
    localStorage.setItem("folded", JSON.stringify([...this.folded]));
    cx.notify();
  }

  link(url) {
    exec("open", [url]).catch(() => {});
  }

  mark(t, task, sector) {
    const color = t[sector.color] ?? t.dim;
    const box = div().size(14).mt(2).flex_none().flex().items_center().justify_center();
    if (task.sector === "underway" && task.live === "working") return box.child(svg("mods/workspace-chrome/spinner.svg").size(12).text_color(color).spin(900));
    if (task.sector === "docked") return box.child(svg("mods/workspace-chrome/check.svg").size(13).text_color(color));
    if (task.sector === "holding" || task.sector === "underway") return box.child(div().size(7).rounded(4).border(1.5).border_color(color));
    return box.child(div().size(7).rounded(4).bg(color));
  }

  detail(t, task) {
    const d = this.details[task.key];
    const ev = task.last_event;
    const block = (label, text) =>
      v_flex().gap(2)
        .child(div().text_size(10.5).font_medium().text_color(t.dim).child(label))
        .child(div().text_size(12).text_color(t.muted).child(clip(text)));
    const prs = d?.prs ?? [];
    return v_flex()
      .pl(23)
      .pr(4)
      .pb(8)
      .gap(8)
      .when(Boolean(task.why), (el) => el.child(block("Why", task.why)))
      .when(Boolean(ev?.text), (el) => el.child(block(`Last ${ev.kind ?? "event"}${ev.at ? ` · ${duration(Date.now() - Date.parse(ev.at))} ago` : ""}`, ev.text)))
      .when(d?.loading === true, (el) => el.child(div().text_size(11).text_color(t.dim).child("Loading PRs…")))
      .when(Boolean(d?.error), (el) => el.child(div().text_size(11).text_color(t.blocked).truncate().child(d.error)))
      .when(prs.length > 0, (el) => el.child(h_flex().flex_wrap().gap(5).children(prs.map((p, i) =>
        div()
          .id(`pr-${task.key}-${i}`)
          .px(6)
          .h(18)
          .rounded(5)
          .flex()
          .items_center()
          .bg(t.raised)
          .text_size(11)
          .text_color(/MERGED|CLOSED/.test(p.state ?? "") ? t.dim : t.foreground)
          .cursor_pointer()
          .hover((s) => s.bg(t.hover))
          .tooltip(p.url)
          .on_click((_e, cx) => {
            cx.stop_propagation();
            this.link(p.url);
          })
          .child(prLabel(p.url))))))
      .when(canOpen(task), (el) => el.child(h_flex().child(div()
        .id(`open-${task.key}`)
        .text_size(11.5)
        .text_color(t.accent)
        .cursor_pointer()
        .hover((s) => s.underline())
        .tooltip("Show the worker's terminal")
        .on_click((_e, cx) => {
          cx.stop_propagation();
          this.openWorker(task, cx);
        })
        .child("Open worker"))))
      .child(div().text_size(10.5).text_color(t.dim).child(`${task.id} · ${task.backend} · worker ${task.live}`));
  }

  row(t, task, sector, now) {
    const isOpen = this.open.has(task.key);
    const where = task.project && task.project !== task.home ? `${task.home}/${task.project}` : task.home;
    const at = task.last_activity_at ? Date.parse(task.last_activity_at) : null;
    const chevron = div()
      .id(`more-${task.key}`)
      .p(2)
      .mt(1)
      .flex_none()
      .rounded(4)
      .text_color(t.dim)
      .cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        this.toggle(task, cx);
      })
      .text_size(13)
      .child(isOpen ? "⌄" : "›");
    return v_flex()
      .flex_none()
      .rounded(8)
      .when(isOpen, (el) => el.bg(t.raised))
      .child(h_flex()
        .id(`task-${task.key}`)
        .px(8)
        .py(6)
        .gap(9)
        .items_start()
        .rounded(8)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover))
        .tooltip(`Pass ${task.short_id} to the ${task.home} XO`)
        .on_click((_e, cx) => this.pass(task, cx))
        .child(this.mark(t, task, sector))
        .child(v_flex().flex_1().min_w(0).gap(2)
          .child(h_flex().gap(6).items_center()
            .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(task.title))
            .when(at != null, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(duration(now - at)))))
          .child(div().truncate().text_size(11).text_color(t.dim).child(`${task.short_id} · ${where} · ${task.why ?? task.state}`)))
        .child(chevron))
      .when(isOpen, (el) => el.child(this.detail(t, task)));
  }

  header(t, sector, list) {
    const open = !this.folded.has(sector.id);
    return h_flex()
      .id(`sector-${sector.id}`)
      .px(8)
      .pt(8)
      .h(30)
      .flex_none()
      .gap(6)
      .items_center()
      .text_size(11)
      .font_medium()
      .cursor_pointer()
      .hover((s) => s.text_color(t.foreground))
      .on_click((_e, cx) => this.fold(sector.id, cx))
      .child(div().text_color(t[sector.color] ?? t.dim).child(sector.label))
      .child(div().text_color(t.dim).child(String(list.length)))
      .child(div().flex_1())
      .when(!open, (el) => el.child(svg("mods/workspace-chrome/chevron-right.svg").size(11).flex_none().text_color(t.dim)));
  }

  render(cx) {
    const t = theme();
    const now = Date.now();
    const known = new Set(SECTORS.map((s) => s.id));
    // A sector radar adds later still shows, after the known ones.
    const extra = [...new Set(this.tasks.map((x) => x.sector).filter((s) => !known.has(s)))].map((id) => ({ id, label: id, color: "dim" }));
    const rows = [...SECTORS, ...extra].flatMap((sector) => {
      const list = this.tasks.filter((x) => x.sector === sector.id);
      if (!list.length) return [];
      return [this.header(t, sector, list), ...(this.folded.has(sector.id) ? [] : list.map((x) => this.row(t, x, sector, now)))];
    });

    const refresh = div()
      .id("cr-refresh")
      .p(2)
      .rounded(4)
      .text_color(t.dim)
      .cursor_pointer()
      .hover((s) => s.text_color(t.foreground))
      .tooltip("Refresh")
      .on_click((_e, cx) => this.refresh(cx))
      .child(this.busy ? svg("mods/chartroom/refresh.svg").size(13).spin(900) : svg("mods/chartroom/refresh.svg").size(13));

    return v_flex()
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .text_size(13)
      .child(
        h_flex()
          .px(16)
          .h(41)
          .pt(14)
          .pb(5)
          .flex_none()
          .items_center()
          .gap(6)
          .child(div().text_size(11.5).font_medium().text_color(t.dim).child("Chartroom"))
          .when(this.fetchedAt != null, (el) => el.child(div().text_size(11).text_color(t.dim).child(`${this.tasks.length} open`)))
          .child(div().flex_1())
          .when(this.fetchedAt != null, (el) => el.child(div().text_size(11).text_color(t.dim).child(duration(now - this.fetchedAt))))
          .child(refresh),
      )
      .when(Boolean(this.error), (el) =>
        el.child(div().id("cr-error").px(16).pb(4).flex_none().text_size(11).text_color(t.blocked).truncate().tooltip(this.error).child(this.error)),
      )
      // What the last click did, in full (it says why when nothing was sent); a click dismisses it.
      .when(Boolean(this.notice), (el) =>
        el.child(div()
          .id("cr-notice")
          .px(16)
          .pb(6)
          .flex_none()
          .text_size(11.5)
          .text_color({ ok: t.done, error: t.blocked }[this.notice.level] ?? t.dim)
          .cursor_pointer()
          .on_click((_e, cx) => {
            this.notice = null;
            cx.notify();
          })
          .child(this.notice.text)),
      )
      .when(this.fetchedAt == null && !this.error, (el) =>
        el.child(div().px(16).text_size(12).text_color(t.dim).child("Reading the radar…")),
      )
      .when(this.fetchedAt != null && rows.length === 0, (el) =>
        el.child(div().px(16).text_size(12).text_color(t.dim).child("No open tasks.")),
      )
      .child(v_flex().id("cr-list").flex_1().min_h(0).px(8).pb(8).overflow_y_scrollbar().mode("always").children(rows));
  }
}
