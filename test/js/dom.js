// Just enough DOM for the render functions to run under node: elements, text nodes, fragments,
// attributes, classList, hidden, textContent and listeners. Installed as global.document.
"use strict";
class Node_ {
  constructor(type) { this.nodeType = type; this.childNodes = []; this.parentNode = null; }
  append(...kids) {
    for (const k of kids) {
      if (k == null) continue;
      const n = typeof k === "string" ? new Text_(k) : k;
      if (n instanceof Fragment_) { for (const c of n.childNodes.slice()) this.append(c); n.childNodes = []; continue; }
      n.parentNode = this; this.childNodes.push(n);
    }
  }
  get textContent() { return this.childNodes.map((c) => c.textContent).join(""); }
  set textContent(v) { this.childNodes = []; if (v !== "" && v != null) this.append(String(v)); }
}
class Text_ extends Node_ { constructor(v) { super(3); this.data = v; } get textContent() { return this.data; } set textContent(v) { this.data = String(v); } }
class Fragment_ extends Node_ { constructor() { super(11); } }
class Element_ extends Node_ {
  constructor(tag) {
    super(1); this.tagName = tag.toUpperCase(); this.attributes = {}; this.listeners = {}; this.hidden = false;
    const el = this;
    this.classList = {
      add: (...c) => { const s = new Set(el.className.split(/\s+/).filter(Boolean)); c.forEach((x) => s.add(x)); el.className = [...s].join(" "); },
      contains: (c) => el.className.split(/\s+/).includes(c),
      toggle: (c, on) => { const has = el.classList.contains(c); if (on === undefined ? !has : on) { if (!has) el.classList.add(c); } else el.className = el.className.split(/\s+/).filter((x) => x !== c).join(" "); },
    };
  }
  get className() { return this.attributes.class || ""; }
  set className(v) { this.attributes.class = v; }
  setAttribute(k, v) { this.attributes[k] = String(v); if (k === "hidden") this.hidden = true; }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  click() { for (const fn of this.listeners.click || []) fn({ preventDefault() {} }); }
  get children() { return this.childNodes.filter((c) => c instanceof Element_); }
  get dataset() { const el = this; return new Proxy({}, { get: (_, k) => el.attributes["data-" + String(k).replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())] }); }
  // every element below this one, depth first
  all() { const out = []; const walk = (n) => { for (const c of n.children) { out.push(c); walk(c); } }; walk(this); return out; }
}
const document = {
  createElement: (t) => new Element_(t),
  createDocumentFragment: () => new Fragment_(),
  createTextNode: (v) => new Text_(v),
};
global.document = document;
module.exports = { document, Element_ };
