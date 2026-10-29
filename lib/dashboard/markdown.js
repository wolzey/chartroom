// markdown.js - a task's report.md (and its brief's intent) as a readable page section, on the
// task page (task.html) and in the radar's file viewer. Spliced into those pages by the server
// like eventfmt.js; test/js/markdown.test.js runs it under node.
//
// The CommonMark most reports use: headings, paragraphs, nested lists (task boxes too), fenced
// code, block quotes, rules and GFM tables; inline code, emphasis, strikethrough and links.
// Sanitized by construction: parse() yields a tree of plain values and render() builds nodes
// with textContent, so raw HTML in a report is shown as text; a link goes out only to http(s),
// or to an anchor on this page; an image is named, never fetched.
var Markdown = (function () {
  "use strict";

  const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([\w+-]*)/;
  const HEADING = /^ {0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*$/;
  const RULE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
  const QUOTE = /^ {0,3}> ?/;
  const ITEM = /^( *)([-*+]|\d{1,9}[.)])(\s+|$)/;
  const TABLE_SEP = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;

  function cells(line) {
    let s = line.trim();
    if (s.startsWith("|")) s = s.slice(1);
    if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
    const out = [];
    let cur = "", tick = false;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c === "\\" && s[i + 1] === "|") { cur += "|"; i++; continue; }
      if (c === "`") tick = !tick;
      if (c === "|" && !tick) { out.push(cur.trim()); cur = ""; continue; }
      cur += c;
    }
    out.push(cur.trim());
    return out;
  }
  function starts(line) {
    return FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line) || ITEM.test(line) || /^\s*<!--/.test(line);
  }

  // markdown text -> [block]: {t: "h", level, c} | {t: "p", c} | {t: "code", lang, v} | {t: "quote", b}
  // | {t: "hr"} | {t: "list", ordered, start, items: [{check: null|true|false, b}]} | {t: "table", align, head, rows}
  function parse(md) {
    const lines = String(md == null ? "" : md).replace(/\r\n?/g, "\n").replace(/\t/g, "    ").split("\n");
    return blocks(lines);
  }
  function blocks(lines) {
    const out = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      let m;
      if (!line.trim()) { i++; continue; }
      if (/^\s*<!--/.test(line)) { // an HTML comment (briefs carry them): skipped, not shown
        while (i < lines.length && !lines[i].includes("-->")) i++;
        i++; continue;
      }
      if ((m = FENCE.exec(line))) {
        const close = new RegExp("^ {0,3}" + m[1][0] + "{" + m[1].length + ",}\\s*$"), body = [];
        i++;
        while (i < lines.length && !close.test(lines[i])) body.push(lines[i++]);
        i++;
        out.push({ t: "code", lang: m[2] || "", v: body.join("\n") });
        continue;
      }
      if ((m = HEADING.exec(line))) { out.push({ t: "h", level: m[1].length, c: inline(m[2] || "") }); i++; continue; }
      if (RULE.test(line) && !(ITEM.test(line) && /^\s*[-*]\s+\S/.test(line) && !/^\s*([-*])(\s*\1){2,}\s*$/.test(line))) { out.push({ t: "hr" }); i++; continue; }
      if (QUOTE.test(line)) {
        const body = [];
        while (i < lines.length && lines[i].trim() && (QUOTE.test(lines[i]) || !starts(lines[i]))) body.push(lines[i++].replace(QUOTE, ""));
        out.push({ t: "quote", b: blocks(body) });
        continue;
      }
      if (line.includes("|") && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]) && lines[i + 1].includes("-")) {
        const head = cells(line), align = cells(lines[i + 1]).map((c) => /^:-+:$/.test(c) ? "center" : /-:$/.test(c) ? "right" : /^:-/.test(c) ? "left" : null);
        i += 2;
        const rows = [];
        while (i < lines.length && lines[i].trim() && lines[i].includes("|")) rows.push(cells(lines[i++]));
        const n = head.length;
        out.push({ t: "table", align: align.slice(0, n), head: head.map(inline), rows: rows.map((r) => Array.from({ length: n }, (_, k) => inline(r[k] || ""))) });
        continue;
      }
      if ((m = ITEM.exec(line))) { i = list(lines, i, out); continue; }
      const para = [];
      while (i < lines.length && lines[i].trim() && !(para.length && starts(lines[i])) &&
             !(lines[i].includes("|") && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]) && lines[i + 1].includes("-"))) {
        para.push(lines[i++]);
        if (para.length === 1 && starts(para[0]) && !ITEM.test(para[0])) break;
      }
      if (!para.length) para.push(lines[i++]);
      out.push({ t: "p", c: inline(para.map((l, k) => (k < para.length - 1 && / {2,}$|\\$/.test(l) ? l.replace(/\\$/, "") + "\u2028" : l.trim())).join(" ").replace(/\u2028 /g, "\u2028")) });
    }
    return out;
  }
  // One list from lines[i], into out; returns the index after it. An item's own lines (indented
  // past its marker) are parsed as blocks of their own, so lists nest.
  function list(lines, i, out) {
    const first = ITEM.exec(lines[i]);
    const ordered = /\d/.test(first[2]), base = first[1].length;
    const node = { t: "list", ordered, start: ordered ? parseInt(first[2], 10) : 1, items: [] };
    while (i < lines.length) {
      const m = ITEM.exec(lines[i]);
      if (!m || m[1].length !== base || /\d/.test(m[2]) !== ordered) break;
      const pad = m[1].length + m[2].length + Math.min(m[3].length || 1, 4);
      const body = [lines[i].slice(m[0].length)];
      i++;
      while (i < lines.length) {
        const l = lines[i];
        if (!l.trim()) {
          const next = lines.slice(i + 1).find((x) => x.trim());
          if (next != null && (next.length - next.trimStart().length) >= pad) { body.push(""); i++; continue; }
          break;
        }
        const ind = l.length - l.trimStart().length;
        if (ind >= pad) { body.push(l.slice(Math.min(pad, ind))); i++; continue; }
        const im = ITEM.exec(l);
        if (im && im[1].length <= base) break;
        if (im && im[1].length > base) { body.push(l.slice(Math.min(pad, ind))); i++; continue; }
        if (starts(l)) break;
        body.push(l.trim()); i++; // a lazy continuation of the item's paragraph
      }
      let check = null;
      const box = /^\[([ xX])\]\s+/.exec(body[0]);
      if (box) { check = box[1] !== " "; body[0] = body[0].slice(box[0].length); }
      node.items.push({ check, b: blocks(body) });
      while (i < lines.length && !lines[i].trim()) {
        const next = lines.slice(i).find((x) => x.trim());
        const nm = next != null && ITEM.exec(next);
        if (nm && nm[1].length === base && /\d/.test(nm[2]) === ordered) i++; else break;
      }
    }
    out.push(node);
    return i;
  }

  // inline text -> [node]: {t: "text", v} | {t: "code", v} | {t: "strong"|"em"|"del", c}
  // | {t: "link", href, title, c} | {t: "img", alt} | {t: "br"}
  function inline(s) {
    const out = [];
    let buf = "";
    const flush = () => { if (buf) { out.push({ t: "text", v: buf }); buf = ""; } };
    let i = 0, m;
    while (i < s.length) {
      const rest = s.slice(i), c = s[i], prev = i ? s[i - 1] : " ";
      if (c === "\u2028") { flush(); out.push({ t: "br" }); i++; continue; }
      if (c === "\\" && /[\\`*_{}\[\]()#+\-.!|~<>]/.test(s[i + 1] || "")) { buf += s[i + 1]; i += 2; continue; }
      if (c === "`" && (m = /^(`+)([\s\S]*?[^`])\1(?!`)/.exec(rest))) { flush(); out.push({ t: "code", v: m[2].replace(/^ (.*) $/, "$1") }); i += m[0].length; continue; }
      if (c === "!" && (m = /^!\[([^\]]*)\]\(([^)]*)\)/.exec(rest))) { flush(); out.push({ t: "img", alt: m[1] }); i += m[0].length; continue; }
      if (c === "[" && (m = /^\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\(\s*<?([^\s<>()]*(?:\([^\s<>()]*\)[^\s<>()]*)*)>?(?:\s+["']([^"']*)["'])?\s*\)/.exec(rest))) {
        flush(); out.push({ t: "link", href: m[2], title: m[3] || null, c: inline(m[1]) }); i += m[0].length; continue;
      }
      if (c === "<" && (m = /^<(https?:\/\/[^\s<>]+)>/.exec(rest))) { flush(); out.push({ t: "link", href: m[1], title: null, c: [{ t: "text", v: m[1] }] }); i += m[0].length; continue; }
      if ((c === "*" || c === "_") && (m = (c === "*" ? /^\*\*(?=\S)([\s\S]*?\S)\*\*/ : /^__(?=\S)([\s\S]*?\S)__(?![A-Za-z0-9])/).exec(rest)) && (c === "*" || !/[A-Za-z0-9]/.test(prev))) {
        flush(); out.push({ t: "strong", c: inline(m[1]) }); i += m[0].length; continue;
      }
      if ((c === "*" || c === "_") && (m = (c === "*" ? /^\*(?=[^\s*])([\s\S]*?[^\s*])\*(?!\*)/ : /^_(?=[^\s_])([\s\S]*?[^\s_])_(?![A-Za-z0-9])/).exec(rest)) && (c === "*" || !/[A-Za-z0-9]/.test(prev))) {
        flush(); out.push({ t: "em", c: inline(m[1]) }); i += m[0].length; continue;
      }
      if (c === "~" && (m = /^~~(?=\S)([\s\S]*?\S)~~/.exec(rest))) { flush(); out.push({ t: "del", c: inline(m[1]) }); i += m[0].length; continue; }
      buf += c; i++;
    }
    flush();
    return out;
  }

  // ---------------------------------------------------------------- rendering (browser only)

  function h(tag, attrs, ...kids) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === "class") n.className = v; else if (k === "text") n.textContent = v; else n.setAttribute(k, String(v));
    }
    for (const k of kids) if (k != null) n.append(k);
    return n;
  }
  function safeHref(href) { return /^https?:\/\//i.test(href) ? href : /^#[\w-]*$/.test(href) ? href : null; }

  // opts: {text(string) -> node}: how plain text runs are drawn (the task page passes
  // EventFmt.inline, so paths and SHAs read as code there too); default, as text.
  function renderInline(nodes, opts) {
    const frag = document.createDocumentFragment();
    for (const n of nodes) {
      if (n.t === "text") frag.append(opts && opts.text ? opts.text(n.v) : n.v);
      else if (n.t === "code") frag.append(h("code", { text: n.v }));
      else if (n.t === "br") frag.append(h("br"));
      else if (n.t === "img") frag.append(h("span", { class: "md-img", text: "[image" + (n.alt ? ": " + n.alt : "") + "]" }));
      else if (n.t === "link") {
        const href = safeHref(n.href);
        const kids = renderInline(n.c, href ? null : opts);
        if (href) frag.append(h("a", Object.assign({ href, title: n.title }, /^#/.test(href) ? {} : { target: "_blank", rel: "noopener noreferrer" }), kids));
        else frag.append(h("span", { class: "md-link", title: n.href || null }, kids));
      } else frag.append(h(n.t === "strong" ? "strong" : n.t === "em" ? "em" : "del", {}, renderInline(n.c, opts)));
    }
    return frag;
  }
  // blocks -> a fragment. opts.shift moves heading levels down (a report's "#" under the page's own h2).
  function render(bs, opts) {
    opts = opts || {};
    const shift = opts.shift || 0, frag = document.createDocumentFragment();
    for (const b of bs) {
      if (b.t === "h") frag.append(h("h" + Math.min(6, b.level + shift), { class: "md-h" }, renderInline(b.c, opts)));
      else if (b.t === "p") frag.append(h("p", {}, renderInline(b.c, opts)));
      else if (b.t === "code") frag.append(h("pre", { class: "md-code", "data-lang": b.lang || null }, h("code", { text: b.v })));
      else if (b.t === "quote") frag.append(h("blockquote", {}, render(b.b, opts)));
      else if (b.t === "hr") frag.append(h("hr"));
      else if (b.t === "list") {
        const l = h(b.ordered ? "ol" : "ul", { start: b.ordered && b.start !== 1 ? b.start : null });
        for (const it of b.items) {
          const li = h("li", { class: it.check == null ? null : "md-task" });
          if (it.check != null) li.append(h("span", { class: "md-box", role: "img", "aria-label": it.check ? "done" : "not done", text: it.check ? "☑ " : "☐ " }));
          // a tight item's one paragraph is its text, without a <p> around it
          if (it.b.length === 1 && it.b[0].t === "p") li.append(renderInline(it.b[0].c, opts)); else li.append(render(it.b, opts));
          l.append(li);
        }
        frag.append(l);
      } else if (b.t === "table") {
        const al = (k) => b.align[k] ? "al-" + b.align[k] : null;
        frag.append(h("div", { class: "md-table" }, h("table", {},
          h("thead", {}, h("tr", {}, ...b.head.map((c, k) => h("th", { scope: "col", class: al(k) }, renderInline(c, opts))))),
          h("tbody", {}, ...b.rows.map((r) => h("tr", {}, ...r.map((c, k) => h("td", { class: al(k) }, renderInline(c, opts)))))))));
      }
    }
    return frag;
  }

  // The text of one "## <title>" section of a brief (e.g. the commander's intent), or "".
  function section(md, title) {
    const lines = String(md || "").replace(/\r\n?/g, "\n").split("\n");
    const re = new RegExp("^##\\s+" + title + "\\s*$", "i");
    const at = lines.findIndex((l) => re.test(l));
    if (at < 0) return "";
    const out = [];
    for (let i = at + 1; i < lines.length && !/^##?\s/.test(lines[i]); i++) out.push(lines[i]);
    return out.join("\n").replace(/<!--[\s\S]*?-->/g, "").trim();
  }

  return { parse, inline, render, renderInline, section, safeHref };
})();
if (typeof module !== "undefined" && module.exports) module.exports = Markdown;
