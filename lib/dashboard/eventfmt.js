// eventfmt.js - a crew event as a readable status note, and a task's events as a timeline. Shared
// by the radar's side panel (radar.html) and the task page (task.html): the server splices this
// file into each page at its include marker (lib/dashboard/server.py, Page), so the pages stay
// self-contained under their CSP. test/js/eventfmt.test.js runs the same file under node.
//
// The parser is pure and tolerant. It finds light structure in what workers write: a [breaking]
// mark and shouted flags (URGENT:) as tags, a headline (the first sentence or clause, up to the
// first ":" or "."), labelled parts ("Cause:", "Options:", "Need:", "Report:" ...) as headed
// blocks, numbered options ((1) (2), (A) (B), 1) 2) ...) as a list with the recommended one
// marked, and "; "-separated facts as bullets when there are several. Whatever it cannot place
// stays the worker's own words, as paragraphs: plain() gives every word back, in order, and the
// tests hold it to that. Nothing here builds HTML from text: rendering creates nodes and sets
// textContent, so markup a worker writes (a script tag, say) is only ever shown as text.
var EventFmt = (function () {
  "use strict";

  const WORKER_KINDS = ["decision", "blocked", "failed", "waiting", "progress", "done"];
  const FILTERS = ["decision", "blocked", "progress", "waiting", "done", "failed", "steered", "system"];
  const ISO = "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?Z";
  const LINE = new RegExp("^(" + ISO + ") (?:([a-z][a-z-]{0,23}):(?: |$))?([\\s\\S]*)$");

  // ---------------------------------------------------------------- lines

  // One events.log line -> {at, kind, text, breaking}; null for a line that is not an event (a
  // continuation of the one before, which parseLog joins on).
  function parseLine(line) {
    const m = LINE.exec(String(line == null ? "" : line).replace(/\r$/, ""));
    if (!m) return null;
    return mark({ at: m[1], kind: m[2] || null, text: m[3] || "" });
  }
  function mark(ev) {
    const b = /^\[breaking\]\s*/i.exec(ev.text);
    ev.breaking = !!b;
    if (b) ev.text = ev.text.slice(b[0].length);
    return ev;
  }

  // A whole events.log (or the events section of a peek) -> [{i, at, kind, text, breaking}],
  // oldest first. A line without a timestamp continues the event before it (the printf fallback
  // can write a newline into the text); one before any event becomes an event with no time.
  function parseLog(text) {
    const out = [];
    for (const raw of String(text == null ? "" : text).split("\n")) {
      if (!raw.trim()) continue;
      const ev = parseLine(raw);
      if (ev) { ev.i = out.length; out.push(ev); continue; }
      if (out.length) out[out.length - 1].text += "\n" + raw.replace(/\r$/, "");
      else out.push(mark({ i: 0, at: null, kind: null, text: raw.replace(/\r$/, "") }));
    }
    return out;
  }

  // What an event is to the feed: a worker's report, the XO's steer, or the system's own record.
  function role(ev) {
    if (WORKER_KINDS.includes(ev.kind)) return "worker";
    if (ev.kind === "steered") return "steer";
    return "system";
  }
  // System events worth a line of their own; the rest (prompts received, turns ended, records
  // created, worktrees, dispatches) fold into a "N system events" toggle.
  function noisy(ev) {
    if (role(ev) !== "system") return false;
    if (ev.kind === "exited") return false;
    if (ev.kind === "agent") return !/^awaiting-input\b/.test(ev.text);
    if (ev.kind === "note") return !/^(closed\b|accepted\b|stopped\b|answered\b)/.test(ev.text);
    return true;
  }
  function filterKind(ev) { return role(ev) === "system" ? "system" : ev.kind; }

  // ---------------------------------------------------------------- text scanning

  const ABBREV = /(?:^|[\s(])(?:e\.g|i\.e|vs|etc|incl|approx|cf|est|no|nos|inc|mr|mrs|ms|dr|st|fig|ca|resp)$/i;

  // Calls visit(i, depth) for every character outside backticks, with the bracket depth there.
  function scan(text, visit) {
    let depth = 0, tick = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (c === "`") { tick = !tick; continue; }
      if (tick) continue;
      if (c === "(" || c === "[" || c === "{") depth++;
      else if ((c === ")" || c === "]" || c === "}") && depth > 0) depth--;
      if (visit(i, depth) === false) return;
    }
  }
  function balanced(text) { let ok = true; scan(text, () => true); let d = 0; scan(text, (i, depth) => { d = depth; }); ok = d === 0; return ok; }

  // Where the sentence ending at text[i] (".", "!" or "?") really ends a sentence: a space follows
  // and then a capital, a digit, a bracket or a quote, and it is no abbreviation (e.g., vs.).
  function sentenceEnd(text, i) {
    const c = text[i];
    if (c !== "." && c !== "!" && c !== "?" && c !== "\n") return false;
    if (c === "\n") return true;
    if (!/\s/.test(text[i + 1] || "")) return false;
    const next = text.slice(i + 1).replace(/^\s+/, "")[0] || "";
    if (!/[A-Z0-9(\["'`#*~/]/.test(next)) return false;
    if (c === "." && ABBREV.test(text.slice(Math.max(0, i - 8), i))) return false;
    return true;
  }

  // The first boundary at bracket depth 0 (or anywhere, when the brackets never balance):
  // {at, end, kind: "sentence" | "colon"} or null.
  function firstBoundary(text, colon) {
    let found = null;
    const pass = (anyDepth) => {
      scan(text, (i, depth) => {
        if (depth > 0 && !anyDepth) return true;
        if (colon && text[i] === ":" && /\s/.test(text[i + 1] || "") && i > 0) { found = { at: i, end: i + 1, kind: "colon" }; return false; }
        if (sentenceEnd(text, i)) { found = { at: i, end: i + 1, kind: "sentence" }; return false; }
        return true;
      });
    };
    pass(false);
    if (!found && !balanced(text)) pass(true);
    return found;
  }

  // text -> sentences (each keeps its own terminator).
  function sentences(text) {
    const out = [];
    let start = 0;
    scan(text, (i, depth) => {
      if (depth === 0 && sentenceEnd(text, i)) { out.push(text.slice(start, i + 1).trim()); start = i + 1; }
      return true;
    });
    const rest = text.slice(start).trim();
    if (rest) out.push(rest);
    return out.filter(Boolean);
  }

  // Splits text at sep (a string) wherever it sits at depth 0.
  function splitTop(text, sep) {
    const out = [];
    let start = 0;
    scan(text, (i, depth) => {
      if (depth === 0 && text.startsWith(sep, i)) { out.push(text.slice(start, i)); start = i + sep.length; }
      return true;
    });
    out.push(text.slice(start));
    return out.map((s) => s.trim()).filter(Boolean);
  }

  // A lowercase prose word at the start becomes capitalized for display; an identifier
  // (acme-web, v2, api_key) is left exactly as written.
  function cap(s) {
    const m = /^([a-z]+)(?=[\s,;:]|$)/.exec(s || "");
    return m ? s[0].toUpperCase() + s.slice(1) : s;
  }

  // ---------------------------------------------------------------- the note

  const STRUCTURAL = ["options", "option", "choices", "cause", "root cause", "need", "needs", "needed", "ask", "recommend",
    "recommendation", "report", "details", "detail"];
  const LABELS = new Set(STRUCTURAL.concat(["also", "also needed", "background", "blocker", "blockers", "caveat", "caveats",
    "changes", "changed", "ci", "context", "decision", "default", "done", "eta", "evidence", "finding", "findings", "fix",
    "follow-up", "follow-ups", "found", "impact", "next", "next step", "next steps", "note", "notes", "open",
    "open questions", "outcome", "plan", "pr", "prs", "problem", "proposal", "question", "questions", "recommended",
    "result", "results", "risk", "risks", "rollback", "scope", "status", "summary", "symptom", "symptoms", "tests",
    "then", "timeline", "todo", "until", "update", "validation", "verified", "waiting on", "why", "workaround"]));
  const NOT_LABEL = /^(i|we|it|he|she|they|you|and|but|so|or|if|this|that|these|those|there|here|my|our|your|its|the|a|an)\b/i;
  // a label: up to three words, the first capitalized ("v0.6" is a word, "merged." is not), an
  // optional (note), then ": "
  const LABEL_AT = /^([A-Z][A-Za-z0-9+\/'-]*(?:\.[A-Za-z0-9]+)*(?: [A-Za-z0-9+\/'-]+(?:\.[A-Za-z0-9]+)*){0,2})(?: \(([^()]{1,60})\))?: (?=\S)/;

  // A label starting at text[i]: {label, note, end} or null. Only at the start of the text or of a
  // sentence or clause (after ". ", "; ", "! ", "? "), at depth 0.
  function labelAt(text, i, depth) {
    if (depth > 0) return null;
    if (i > 0) {
      const before = text.slice(0, i);
      if (!/[.;!?]\s+$|\n\s*$/.test(before)) return null;
      if (/[.]\s+$/.test(before) && ABBREV.test(before.replace(/[.]\s+$/, ""))) return null;
      if (i > 0 && !/\s/.test(text[i - 1])) return null;
    }
    const m = LABEL_AT.exec(text.slice(i));
    if (!m) return null;
    const word = m[1].toLowerCase();
    if (!LABELS.has(word)) {
      if (m[1].length > 28 || NOT_LABEL.test(m[1]) || /^[A-Z][A-Z0-9]{1,9}-\d+$/.test(m[1])) return null;
    }
    return { label: m[1], note: m[2] || null, end: i + m[0].length };
  }

  // Leading tags: "[breaking]" is taken by parseLine; shouted flags such as "URGENT:",
  // "TIME-SENSITIVE:" or "READY (staging):" come off the front here, as do a steer's "XO:".
  const FLAG = /^([A-Z][A-Z-]{2,}(?: [A-Z][A-Z-]{2,})?)(?: \(([^()]{1,80})\))?: +(?=\S)/;
  function takeTags(text, kind) {
    const tags = [];
    let speaker = null, m;
    if (kind === "steered" && (m = /^(XO|Captain|Commander)\s*:\s+(?=\S)/i.exec(text))) { speaker = m[1]; text = text.slice(m[0].length); }
    while (tags.length < 3 && (m = FLAG.exec(text)) && !/\d/.test(m[1]) && !LABELS.has(m[1].toLowerCase())) {
      tags.push({ text: m[1], note: m[2] || null });
      text = text.slice(m[0].length);
    }
    return { tags, speaker, text };
  }

  // The headline: the first sentence or clause. One that runs on past ~200 characters is cut at
  // its first "; " or " — " instead, so the headline stays a line and the rest reads as the body.
  function headline(text) {
    const b = firstBoundary(text, true);
    let head = b ? text.slice(0, b.at + (text[b.at] === "?" || text[b.at] === "!" ? 1 : 0)) : text;
    let rest = b ? text.slice(b.end) : "";
    if (head.length > 200) {
      for (const sep of ["; ", " — ", " -- "]) {
        let at = -1;
        scan(head, (i, depth) => { if (depth === 0 && i > 30 && head.startsWith(sep, i)) { at = i; return false; } return true; });
        if (at > 0 && at <= 200) { rest = head.slice(at + sep.length) + (b ? text.slice(b.at) : ""); head = head.slice(0, at); break; }
      }
    }
    return { head: head.trim(), rest: rest.trim(), cut: b ? b.kind : "whole" };
  }

  // Numbered options. A run of markers of one style, consecutive from its first value, two or more.
  const MARKERS = [
    { style: "paren", re: /\((\d{1,2}|[A-Za-z])(\)|, *(recommended|preferred|default)\))/gi },
    { style: "close", re: /(?:^|[\s:;,])(\d{1,2}|[A-Za-z])\) /g },
    { style: "option", re: /\bOption (\d{1,2}|[A-Z])[:)]? /g },
  ];
  function seqValue(v) { return /^\d+$/.test(v) ? { n: +v, t: "1" } : { n: v.toLowerCase().charCodeAt(0) - 96, t: v === v.toUpperCase() ? "A" : "a" }; }
  function findOptions(text, labelled) {
    let best = null;
    const styles = MARKERS.slice();
    if (labelled) styles.push({ style: "bare", re: /(?:^|[;.] )([A-F])(?= (?:\(|[a-z]))/g });
    for (const { style, re } of styles) {
      const marks = [];
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(text))) {
        const lead = m[0].length - m[0].replace(/^[\s:;,.]+/, "").length;
        const at = m.index + lead;
        let depth = 0;
        scan(text.slice(0, at), (i, d) => { depth = d; });
        if (text[at - 1] === "(" || (style !== "paren" && depth > 0) || (style === "paren" && depth > 0)) {
          // a marker inside other brackets ("(see (2))") is text
          if (!(style === "paren" && depth === 0)) continue;
        }
        marks.push({ at, end: m.index + m[0].length, v: m[1], rec: !!m[3], word: m[3] || null, ...seqValue(m[1]) });
        if (m[0].length === 0) re.lastIndex++;
      }
      // the longest consecutive run starting at 1 / a / A
      for (let s = 0; s < marks.length; s++) {
        if (marks[s].n !== 1) continue;
        const run = [marks[s]];
        for (let k = s + 1; k < marks.length && run.length < 12; k++) {
          const last = run[run.length - 1];
          if (marks[k].t === last.t && marks[k].n === last.n + 1) run.push(marks[k]);
        }
        if (run.length >= 2 && (!best || run.length > best.run.length || (run.length === best.run.length && run[0].at < best.run[0].at))) best = { style, run };
      }
    }
    if (!best) return null;
    const { run } = best;
    const items = run.map((mk, k) => {
      let body = text.slice(mk.end, k + 1 < run.length ? run[k + 1].at : text.length).trim();
      // "...; or (2)": the joiner is kept, shown faint after the item, never dropped
      const j = /[;,]?\s*\b(or|and|then)\s*$/i.exec(body);
      const join = j && k + 1 < run.length ? j[1] : null;
      if (join) body = body.slice(0, j.index);
      body = body.replace(/[;,]+\s*$/, "").trim();
      return Object.assign(optionItem(mk, body), { join });
    });
    const intro = text.slice(0, run[0].at).trim();
    return { intro: intro || null, items };
  }
  // An option: {marker, title, text, recommended, recword}. "RECOMMENDED x" or "recommended: x"
  // at its start becomes the mark (kept in recword, so nothing is lost); "x: details" splits into
  // a short title and its details.
  function optionItem(mk, body) {
    let recommended = mk.rec, recword = mk.word, m;
    if ((m = /^\(?(RECOMMENDED|recommended|Recommended|preferred)\)?[:,]?\s+/.exec(body))) {
      recommended = true; recword = (recword ? recword + " " : "") + m[1]; body = body.slice(m[0].length);
    } else if (/\b(recommended|RECOMMENDED)\b/.test(body)) recommended = true;
    let title = null, text = body;
    const b = firstBoundary(body, true);
    if (b && b.kind === "colon" && b.at <= 90) { title = body.slice(0, b.at).trim(); text = body.slice(b.end).trim(); }
    return { marker: mk.v, title: title ? cap(title) : null, text: title ? text : cap(text), recommended, recword };
  }

  // A block's prose: sentences, with any sentence of several "; "-separated facts as bullets, and
  // long runs of plain sentences broken into paragraphs.
  function prose(text) {
    const parts = [];
    let para = [];
    const flush = () => {
      if (!para.length) return;
      let cur = "";
      for (const s of para) {
        if (cur && cur.length + s.length > 340) { parts.push({ type: "p", text: cur }); cur = ""; }
        cur = cur ? cur + " " + s : s;
      }
      if (cur) parts.push({ type: "p", text: cur });
      para = [];
    };
    for (const s of sentences(text)) {
      const facts = splitTop(s.replace(/[.]$/, ""), "; ");
      if ((facts.length >= 3 || (facts.length === 2 && s.length > 160)) && facts.every((f) => f.length <= 320)) {
        flush();
        parts.push({ type: "ul", items: facts.map(cap) });
      } else para.push(s);
    }
    flush();
    return parts;
  }

  function block(label, note, text) {
    const parts = [];
    const opts = findOptions(text, !!label && /^(options?|choices)$/i.test(label));
    if (opts) {
      if (opts.intro) parts.push(...prose(cap(opts.intro)));
      parts.push({ type: "options", items: opts.items });
    } else if (text) parts.push(...prose(cap(text)));
    return { label, note, parts };
  }

  // The body after the headline -> blocks: the lead (no label), then one per label.
  function blocks(text) {
    const cuts = [];
    scan(text, (i, depth) => {
      const l = labelAt(text, i, depth);
      if (l && !(cuts.length && cuts[cuts.length - 1].end > i)) cuts.push(Object.assign({ at: i }, l));
      return true;
    });
    const out = [];
    const lead = text.slice(0, cuts.length ? cuts[0].at : text.length).trim();
    if (lead) out.push(block(null, null, lead));
    cuts.forEach((c, k) => {
      const body = text.slice(c.end, k + 1 < cuts.length ? cuts[k + 1].at : text.length).trim();
      out.push(block(c.label, c.note, body));
    });
    return out;
  }

  // kind + text -> {kind, breaking, tags, speaker, headline, blocks}. Never throws: a text it
  // cannot read comes back whole as one paragraph.
  function parseEvent(kind, text, breaking) {
    const base = { kind: kind || null, breaking: !!breaking, tags: [], speaker: null, headline: "", blocks: [] };
    try {
      let t = String(text == null ? "" : text).replace(/\s*\n\s*/g, "\n").trim();
      const b = /^\[breaking\]\s*/i.exec(t);
      if (b) { base.breaking = true; t = t.slice(b[0].length); }
      const tg = takeTags(t, kind);
      base.tags = tg.tags; base.speaker = tg.speaker; t = tg.text.replace(/\n/g, " ");
      if (!t) return base;
      const first = labelAt(t, 0, 0);
      if (first && STRUCTURAL.includes(first.label.toLowerCase())) { base.blocks = blocks(t); return base; }
      const h = headline(t);
      base.headline = cap(h.head);
      if (h.rest) base.blocks = blocks(h.rest);
      return base;
    } catch (e) {
      return Object.assign(base, { headline: "", blocks: [{ label: null, note: null, parts: [{ type: "p", text: String(text) }] }] });
    }
  }

  // Every word the note holds, in reading order (for tests, and for a copy as plain text).
  function plain(p) {
    const out = [];
    if (p.breaking) out.push("[breaking]");
    for (const t of p.tags) out.push(t.text + (t.note ? " (" + t.note + ")" : "") + ":");
    if (p.speaker) out.push(p.speaker + ":");
    if (p.headline) out.push(p.headline);
    for (const b of p.blocks) {
      if (b.label) out.push(b.label + (b.note ? " (" + b.note + ")" : "") + ":");
      for (const part of b.parts) {
        if (part.type === "p") out.push(part.text);
        else if (part.type === "ul") out.push(part.items.join("; "));
        else for (const it of part.items) out.push("(" + it.marker + ")" + (it.recword ? " " + it.recword : "") + (it.title ? " " + it.title + ":" : "") + " " + it.text + (it.join ? " " + it.join : ""));
      }
    }
    return out.join(" ");
  }

  // ---------------------------------------------------------------- inline tokens

  const EXT = "md|markdown|html?|log|json|jsonl|ya?ml|toml|ini|cfg|conf|txt|csv|sh|bash|zsh|bats|jq|py|rb|go|rs|js|mjs|cjs|ts|tsx|jsx|css|scss|java|kt|swift|cs|csproj|sln|sql|tf|tfvars|lock|xml|proto|pdf|png";
  const TOKEN = new RegExp([
    "`(?<code>[^`\\n]{1,240})`",
    "(?<url>\\bhttps?:\\/\\/[^\\s<>\"'`]+)",
    "(?<abs>(?<![\\w.\\/-])(?:~|\\$HOME)?\\/(?:[\\w.@%+{}-]+\\/)+[\\w.@%+{}-]*)",
    "(?<rel>(?<![\\w.\\/-])[\\w.-]+(?:\\/[\\w.@%+{}-]+){2,})",
    "(?<file>\\b[\\w-]+(?:\\.[\\w-]+)*\\.(?:" + EXT + ")(?::\\d+)?)(?![\\w/])",
    "(?<cmd>(?:^|(?<=\\s))\\/(?:continue|chartroom|captain|bearings|sweep|dashboard|join)(?: [a-z0-9][\\w-]{0,40})?)",
    "(?<id>\\b[a-z][a-z0-9]*(?:-[a-z0-9]+){2,}-[0-9a-f]{4}\\b)",
    "(?<sha>\\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\\d)[0-9a-f]{7,40}\\b)",
    "(?<ticket>\\b[A-Z][A-Z0-9]{1,9}-\\d{1,6}\\b)",
    "(?<rec>\\b(?:RECOMMENDED|recommended)\\b)",
  ].join("|"), "g");
  const NOT_TICKET = /^(UTF|SHA|ISO|AES|RSA|TLS|SSL|HTTP|HTTPS|IPV|MD|X|PR\d?)-/;
  const TASK_FILE = /(?:^|\/)tasks\/([A-Za-z0-9][A-Za-z0-9_.-]{0,63})\/(report\.md|brief\.md|plan\.md|final\.md|events\.log)$/;

  // Trailing sentence punctuation is not part of a URL or a path, and neither is a closing
  // bracket the token never opened.
  function trimTail(v) {
    let s = v;
    for (;;) {
      const t = s.replace(/[.,;:!?'"]+$/, "");
      if (/[)\]]$/.test(t)) {
        const open = (t.match(/[([]/g) || []).length, close = (t.match(/[)\]]/g) || []).length;
        if (close > open) { s = t.slice(0, -1); continue; }
      }
      if (t === s) return s;
      s = t;
    }
  }

  // text -> [{t, v, ...}]: t is text | code | url | path | sha | id | ticket | rec. A path that
  // names a task file carries {task, file}; a bare task file name carries {file}.
  function tokens(text) {
    const s = String(text == null ? "" : text), out = [];
    let last = 0, m;
    const push = (tok) => { if (tok.t === "text" && out.length && out[out.length - 1].t === "text") out[out.length - 1].v += tok.v; else out.push(tok); };
    TOKEN.lastIndex = 0;
    while ((m = TOKEN.exec(s))) {
      const g = m.groups;
      let v = m[0], tok = null;
      if (g.code != null) tok = { t: "code", v: g.code, raw: v };
      else if (g.url) { v = trimTail(v); tok = { t: "url", v, href: v }; }
      else if (g.abs || g.rel) {
        v = trimTail(v);
        if ((g.rel && !/\.[A-Za-z0-9]{1,8}(?::\d+)?$/.test(v)) || /^\/\d/.test(v) || !/[A-Za-z]/.test(v) ||
            (g.abs && v.split("/").filter(Boolean).length < 2 && !/\.[A-Za-z]/.test(v))) {
          // "flag/config", "89/103", "/x": prose, not a path
          v = m[0].slice(0, 1); tok = null;
        } else {
          tok = { t: "path", v };
          const f = TASK_FILE.exec(v);
          if (f) { tok.task = f[1]; tok.file = f[2]; }
        }
      } else if (g.file) {
        tok = { t: "path", v };
        if (/^(report|brief|plan|final)\.md$|^events\.log$/.test(v)) tok.file = v;
      } else if (g.cmd) tok = { t: "code", v };
      else if (g.id) tok = { t: "id", v };
      else if (g.sha) tok = { t: "sha", v };
      else if (g.ticket) tok = NOT_TICKET.test(v) ? null : { t: "ticket", v };
      else if (g.rec) tok = { t: "rec", v };
      if (m.index > last) push({ t: "text", v: s.slice(last, m.index) });
      if (tok) { push(tok); last = m.index + (tok.raw || tok.v).length; TOKEN.lastIndex = last; }
      else { push({ t: "text", v }); last = m.index + v.length; TOKEN.lastIndex = last; }
      if (TOKEN.lastIndex === m.index) TOKEN.lastIndex++;
    }
    if (last < s.length) push({ t: "text", v: s.slice(last) });
    return out;
  }

  // ---------------------------------------------------------------- the feed

  function sig(ev) {
    let h = 2166136261;
    const s = (ev.at || "") + "|" + (ev.kind || "") + "|" + ev.text.slice(0, 160);
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
    return (h >>> 0).toString(36);
  }

  // events (oldest first) -> the timeline's items, newest first:
  //   thread  a decision or blocker, the XO's steers that answer it, and the worker's next report
  //           (a `waiting` while it waits for the answer belongs to it too);
  //   run     consecutive progress reports, collapsed to the newest;
  //   noise   consecutive system events (prompts, turn ends, records), behind one toggle;
  //   single  anything else: a report, a steer, an exit or a prompt the agent stopped at.
  // System noise between a thread's or a run's members does not break it. Items are ordered by
  // their newest event; two noise items that end up side by side merge.
  function feed(events) {
    const items = [];
    let thread = null, run = null;
    const close = () => { thread = null; run = null; };
    const add = (type, ev) => { const it = { type, key: type[0] + ":" + sig(ev), events: [ev] }; items.push(it); return it; };
    for (const ev of events) {
      if (noisy(ev)) {
        const lastItem = items[items.length - 1];
        if (lastItem && lastItem.type === "noise") lastItem.events.push(ev); else add("noise", ev);
        continue;
      }
      const r = role(ev);
      if (r === "system") { add("single", ev); continue; }
      if (thread) {
        if (r === "steer") { thread.events.push(ev); thread.answered = true; continue; }
        // the worker's follow-up closes the thread; a new decision or blocker opens its own
        if (thread.answered && ev.kind !== "decision" && ev.kind !== "blocked") { thread.events.push(ev); close(); continue; }
        if (ev.kind === "waiting") { thread.events.push(ev); continue; }
        close();
      }
      if (ev.kind === "decision" || ev.kind === "blocked") { close(); thread = add("thread", ev); thread.answered = false; continue; }
      if (ev.kind === "progress") {
        if (run) { run.events.push(ev); continue; }
        close(); run = add("run", ev); continue;
      }
      close();
      add("single", ev);
    }
    for (const it of items) {
      if (it.type === "run" && it.events.length === 1) it.type = "single";
      if (it.type === "thread" && it.events.length === 1) it.type = "single";
      it.last = it.events[it.events.length - 1].i;
      it.kinds = [...new Set(it.events.map(filterKind))];
      it.breaking = it.events.some((e) => e.breaking);
    }
    items.sort((a, b) => b.last - a.last);
    const merged = [];
    for (const it of items) {
      const prev = merged[merged.length - 1];
      if (prev && prev.type === "noise" && it.type === "noise") { prev.events = it.events.concat(prev.events); continue; }
      merged.push(it);
    }
    for (const it of merged) if (it.type === "noise") it.events.sort((a, b) => a.i - b.i);
    return merged;
  }

  // The newest decision or blocker in the log, or null.
  function latestAsk(events) {
    for (let i = events.length - 1; i >= 0; i--) if (events[i].kind === "decision" || events[i].kind === "blocked") return events[i];
    return null;
  }

  // ---------------------------------------------------------------- time

  function ms(iso) { return iso ? Date.parse(iso) : NaN; }
  function ago(iso, now) {
    const t = ms(iso);
    if (isNaN(t)) return "";
    const s = Math.max(0, Math.floor(((now == null ? Date.now() : now) - t) / 1000));
    if (s < 45) return "just now";
    if (s < 3600) return Math.round(s / 60) + "m ago";
    if (s < 86400) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m ago";
    if (s < 86400 * 14) return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h ago";
    return Math.floor(s / 86400) + "d ago";
  }
  function absolute(iso) {
    const t = ms(iso);
    if (isNaN(t)) return iso || "";
    const d = new Date(t);
    return d.toLocaleString([], { weekday: "short", year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" }) + "  (" + iso + ")";
  }

  // ---------------------------------------------------------------- rendering (browser only)

  let uid = 0; // ids that tie a toggle to what it shows

  function h(tag, attrs, ...kids) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === "class") n.className = v; else if (k === "text") n.textContent = v; else n.setAttribute(k, v === true ? "" : String(v));
    }
    for (const k of kids) if (k != null && k !== false) n.append(k);
    return n;
  }

  // Inline text -> nodes. opts.link(token) -> href or null, for task files and paths.
  function inline(text, opts) {
    const frag = document.createDocumentFragment();
    for (const tok of tokens(text)) {
      if (tok.t === "text") { frag.append(tok.v); continue; }
      if (tok.t === "rec") { frag.append(h("mark", { class: "evx-rec", text: tok.v })); continue; }
      if (tok.t === "url") {
        frag.append(h("a", { href: tok.href, target: "_blank", rel: "noopener noreferrer", class: "evx-url", text: tok.v.replace(/^https?:\/\/(www\.)?/, "") }));
        continue;
      }
      const href = tok.t === "path" && opts && opts.link ? opts.link(tok) : null;
      // a linked task file reads as its name ("report.md", "<task>/report.md"), the full path in the title
      const shown = href && tok.task ? (opts.task && tok.task === opts.task ? tok.file : tok.task + "/" + tok.file) : tok.v;
      const code = h("code", { class: "evx-c evx-" + tok.t, text: shown, title: shown !== tok.v ? tok.v : null });
      frag.append(href ? h("a", { href, class: "evx-path", title: "open " + tok.v }, code, " ↗") : code);
    }
    return frag;
  }

  // A parsed note -> an <article>. opts: {at, link, compact, label}.
  function renderNote(p, opts) {
    opts = opts || {};
    const head = h("div", { class: "evx-meta" });
    if (opts.label) head.append(h("span", { class: "evx-who", text: opts.label }));
    if (p.kind && !opts.label) head.append(h("span", { class: "evx-kind", text: p.kind }));
    if (p.breaking) head.append(h("span", { class: "evx-tag evx-brk", text: "breaking" }));
    for (const t of p.tags) head.append(h("span", { class: "evx-tag", text: t.text.toLowerCase() + (t.note ? " · " + t.note : "") }));
    if (p.speaker && !(opts.label && /^xo$/i.test(p.speaker))) head.append(h("span", { class: "evx-tag", text: p.speaker }));
    if (opts.at) head.append(timeNode(opts.at));
    const art = h("article", { class: "evx" + (opts.compact ? " compact" : ""), "data-kind": p.kind || "none" }, head);
    if (p.headline) art.append(h("p", { class: "evx-head" }, inline(p.headline, opts)));
    let into = art;
    if (opts.compact && p.headline && p.blocks.length) {
      // compact (the radar's panel): the headline; the rest one click away, kept open across
      // re-renders in opts.open (by the event's own key) like the feed's threads
      const id = "evx-" + (++uid), n = p.blocks.length, key = opts.detailKey, open = !!(key && opts.open && opts.open.has(key));
      const more = h("div", { class: "evx-more", id, hidden: !open });
      const btn = h("button", { type: "button", class: "tl-toggle evx-details", "aria-expanded": String(open), "aria-controls": id,
        text: "details (" + n + " part" + (n === 1 ? "" : "s") + ")" });
      btn.addEventListener("click", () => {
        const on = btn.getAttribute("aria-expanded") !== "true"; btn.setAttribute("aria-expanded", String(on)); more.hidden = !on;
        if (key && opts.open) { if (on) opts.open.add(key); else opts.open.delete(key); }
      });
      art.append(btn, more);
      into = more;
    }
    for (const b of p.blocks) {
      const sec = b.label ? h("section", { class: "evx-sec", "data-label": b.label.toLowerCase() },
        h("h5", {}, b.label, b.note ? h("span", { class: "evx-note", text: " (" + b.note + ")" }) : null)) : h("div", { class: "evx-lead" });
      for (const part of b.parts) {
        if (part.type === "p") sec.append(h("p", {}, inline(part.text, opts)));
        else if (part.type === "ul") sec.append(h("ul", { class: "evx-facts" }, ...part.items.map((t) => h("li", {}, inline(t, opts)))));
        else sec.append(h("ol", { class: "evx-opts" }, ...part.items.map((it) => h("li", { class: it.recommended ? "rec" : null },
          h("span", { class: "evx-mk", "aria-hidden": "true", text: it.marker }),
          h("div", { class: "evx-opt" },
            h("span", { class: "sr", text: "option " + it.marker + (it.recommended ? ", recommended" : "") + ": " }),
            it.recword ? h("span", { class: "evx-badge", text: it.recword.toLowerCase() }) : null,
            it.title ? h("b", { class: "evx-otitle" }, inline(it.title, opts)) : null,
            it.text ? h("span", { class: "evx-otext" }, it.title ? " " : null, inline(it.text, opts)) : null,
            it.join ? h("span", { class: "evx-join", text: " " + it.join }) : null)))));
      }
      into.append(sec);
    }
    return art;
  }
  function renderEvent(ev, opts) {
    return renderNote(parseEvent(ev.kind, ev.text, ev.breaking), Object.assign({}, opts, { at: ev.at, detailKey: "d:" + sig(ev) }));
  }

  function timeNode(iso) {
    return h("time", { class: "evx-time", datetime: iso, title: absolute(iso), "data-ago": iso, text: ago(iso) });
  }
  // Keeps every relative time under root current; call it from the page's clock.
  function refreshTimes(root) {
    const now = Date.now();
    for (const n of (root || document).querySelectorAll("[data-ago]")) { const t = ago(n.dataset.ago, now); if (n.textContent !== t) n.textContent = t; }
  }

  // One system event as a small line (kind and text, as written).
  function systemLine(ev) {
    return h("div", { class: "evx-sys" }, ev.at ? timeNode(ev.at) : null, h("span", { class: "evx-syskind", text: (ev.kind || "line") + ":" }), " ", ev.text);
  }

  function toggle(open, label, controls) {
    return h("button", { type: "button", class: "tl-toggle", "aria-expanded": String(open), "aria-controls": controls, text: label });
  }

  function renderItem(it, opts) {
    const li = h("li", { class: "tl-i tl-" + it.type + (it.breaking ? " brk" : ""), "data-kind": it.events[it.events.length - 1].kind || "none" });
    const open = opts.open && opts.open.has(it.key);
    const id = "tl-" + (++uid);
    const flip = (btn, box, labels) => btn.addEventListener("click", () => {
      const now = btn.getAttribute("aria-expanded") !== "true";
      btn.setAttribute("aria-expanded", String(now)); box.hidden = !now;
      if (labels) btn.textContent = now ? labels[1] : labels[0];
      if (opts.open) { if (now) opts.open.add(it.key); else opts.open.delete(it.key); }
    });
    const ev0 = it.events[0], evN = it.events[it.events.length - 1];
    // opts.compactIf(ev): this one compact even in a full feed (the page shows it in full above)
    const asNote = (ev) => role(ev) === "steer" ? renderEvent(ev, Object.assign({}, opts, { label: "XO → worker" }))
      : role(ev) === "system" ? systemLine(ev)
      : renderEvent(ev, opts.compactIf && opts.compactIf(ev) ? Object.assign({}, opts, { compact: true }) : opts);
    if (it.type === "single") {
      li.classList.add("tl-" + role(ev0));
      li.append(asNote(ev0));
    } else if (it.type === "noise") {
      const box = h("div", { class: "tl-more", id, hidden: !open }, ...it.events.map(systemLine));
      const n = it.events.length, labels = [n + " system event" + (n === 1 ? "" : "s"), "hide " + n + " system event" + (n === 1 ? "" : "s")];
      const btn = toggle(open, open ? labels[1] : labels[0], id);
      flip(btn, box, labels);
      li.append(btn, box);
    } else if (it.type === "run") {
      const older = it.events.slice(0, -1).reverse();
      const box = h("div", { class: "tl-more", id, hidden: !open }, ...older.map((e) => renderEvent(e, Object.assign({}, opts, { compact: true }))));
      const n = older.length, labels = [n + " earlier progress update" + (n === 1 ? "" : "s"), "hide " + n + " earlier update" + (n === 1 ? "" : "s")];
      const btn = toggle(open, open ? labels[1] : labels[0], id);
      flip(btn, box, labels);
      li.append(asNote(evN), btn, box);
    } else {
      // a thread: collapsed, the newest line and who has spoken; expanded, the conversation in order
      const replies = it.events.filter((e) => role(e) === "steer").length;
      const follow = it.answered === false || role(evN) !== "worker" || evN === ev0 ? null : evN;
      const path = [ev0.kind, replies ? "XO" + (replies > 1 ? " ×" + replies : "") : null, follow ? "worker" : null].filter(Boolean).join(" → ");
      const summary = parseEvent(evN.kind, evN.text, evN.breaking);
      const latest = h("div", { class: "tl-latest" }, h("span", { class: "evx-kind", text: role(evN) === "steer" ? "XO → worker" : evN.kind }), " ",
        summary.headline || plain(summary).slice(0, 160), evN.at ? h("span", {}, " · ", timeNode(evN.at)) : null);
      const box = h("ol", { class: "tl-thread-list", id, hidden: !open }, ...it.events.map((e) => h("li", { class: "tl-" + role(e) }, asNote(e))));
      const btn = h("button", { type: "button", class: "tl-head", "aria-expanded": String(!!open), "aria-controls": id },
        h("span", { class: "tl-path", text: "thread · " + path + " · " + it.events.length + " messages" }), latest);
      btn.addEventListener("click", () => {
        const now = btn.getAttribute("aria-expanded") !== "true";
        btn.setAttribute("aria-expanded", String(now)); box.hidden = !now; latest.hidden = now;
        if (opts.open) { if (now) opts.open.add(it.key); else opts.open.delete(it.key); }
      });
      latest.hidden = !!open;
      li.append(btn, box);
    }
    return li;
  }

  // The timeline for events (oldest first) -> a <div class="feed">: kind filters, then the items
  // newest first. opts: {link, open: Set of expanded item keys (kept across renders by the page),
  // filters: Set of hidden kinds (likewise), compact, limit}.
  function renderFeed(events, opts) {
    opts = opts || {};
    const items = feed(events);
    const hidden = opts.filters || new Set();
    const present = FILTERS.filter((k) => items.some((it) => it.kinds.includes(k)));
    const list = h("ol", { class: "tl", "aria-label": "events, newest first" });
    const bar = h("div", { class: "tl-filters", role: "group", "aria-label": "show events of kind" });
    const apply = () => {
      for (const li of list.children) li.hidden = !li._kinds.some((k) => !hidden.has(k));
      const shown = [...list.children].filter((li) => !li.hidden).length;
      empty.hidden = shown > 0;
    };
    for (const k of present) {
      const b = h("button", { type: "button", class: "chip tl-f", "data-k": k, "aria-pressed": String(!hidden.has(k)), text: k === "steered" ? "XO" : k });
      b.addEventListener("click", () => {
        if (hidden.has(k)) hidden.delete(k); else hidden.add(k);
        b.setAttribute("aria-pressed", String(!hidden.has(k)));
        apply();
      });
      bar.append(b);
    }
    const shownItems = opts.limit ? items.slice(0, opts.limit) : items;
    for (const it of shownItems) { const li = renderItem(it, opts); li._kinds = it.kinds; list.append(li); }
    const empty = h("p", { class: "tl-empty", text: items.length ? "nothing of the chosen kinds" : "no events yet", hidden: !!items.length });
    const root = h("div", { class: "feed" + (opts.compact ? " compact" : "") }, present.length > 1 ? bar : null, list, empty);
    apply();
    return root;
  }

  return { WORKER_KINDS, FILTERS, parseLine, parseLog, parseEvent, plain, tokens, feed, latestAsk, role, noisy, sentences,
    ago, absolute, inline, renderNote, renderEvent, renderFeed, refreshTimes, systemLine };
})();
if (typeof module !== "undefined" && module.exports) module.exports = EventFmt;
