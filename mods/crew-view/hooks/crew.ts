// Pure helpers for crew-view: no `$`, so the tests can call them directly.
import type { CrewBoard, CrewDetail, CrewFocus, CrewItem } from '../types'

// ---------------------------------------------------------------- home and scope

/** The environment and files `resolveHome` reads, gathered by the caller through `$`. */
export type HomeInputs = {
  chartroomHome?: string
  capHome?: string
  /** The config file's text, when it exists. */
  configText?: string
  /** The homes file's text (the homes on this machine), when it exists. */
  homesText?: string
  /** The session's working directory. */
  cwd?: string
  home: string
  hasChartroomDir: boolean
  hasCaptainDir: boolean
}

/** Where the chartroom config file lives, as lib/core.sh's CR_CONFIG_FILE. */
export function configPath(env: { chartroomConfig?: string; xdgConfigHome?: string; home: string }): string {
  return env.chartroomConfig || `${env.xdgConfigHome || `${env.home}/.config`}/chartroom/config`
}

/** The homes file, next to the config file, as lib/core.sh's CR_HOMES_FILE. */
export function homesPath(configFile: string): string {
  return `${configFile.replace(/\/[^/]*$/, '')}/homes`
}

/** The registered homes as lib/core.sh's homes_entries reads them: `name=path`, ~ expanded. */
export function homeEntries(text: string, home: string): { name: string; path: string }[] {
  const byName = new Map<string, string>()
  for (const raw of text.split('\n')) {
    const m = /^\s*([a-z][a-z0-9-]*)\s*=\s*(.*\S)\s*$/.exec(raw.replace(/\r$/, ''))
    if (!m) continue
    let p = m[2] ?? ''
    const quoted = /^"(.*)"$/.exec(p) ?? /^'(.*)'$/.exec(p)
    if (quoted) p = quoted[1] ?? ''
    if (p === '~' || p.startsWith('~/')) p = home + p.slice(1)
    p = p.replace(/\/+$/, '')
    if (p) byName.set(m[1] ?? '', p)
  }
  return [...byName].map(([name, path]) => ({ name, path }))
}

/** A KEY=VALUE line's value as lib/core.sh's cfg_file_value reads it: last line wins. */
export function configValue(text: string, key: string): string {
  let value = ''
  for (const line of text.split('\n')) {
    const m = new RegExp(`^\\s*${key}\\s*=\\s*(.*)$`).exec(line)
    if (m) value = m[1] ?? ''
  }
  value = value.replace(/\r$/, '')
  const quoted = /^"(.*)"$/.exec(value) ?? /^'(.*)'$/.exec(value)
  return quoted ? (quoted[1] ?? '') : value
}

/** The chartroom home, resolved in lib/core.sh resolve_home's order. */
export function resolveHome(i: HomeInputs): string {
  if (i.chartroomHome) return i.chartroomHome
  if (i.capHome) return i.capHome
  // The registered home the working directory is, or lies inside (the nearest).
  if (i.cwd && i.homesText !== undefined) {
    const cwd = i.cwd.length > 1 ? i.cwd.replace(/\/+$/, '') : i.cwd
    const hit = homeEntries(i.homesText, i.home)
      .filter((h) => cwd === h.path || cwd.startsWith(`${h.path}/`))
      .sort((a, b) => b.path.length - a.path.length)[0]
    if (hit) return hit.path
  }
  const fromConfig = i.configText === undefined ? '' : configValue(i.configText, 'CHARTROOM_HOME')
  if (fromConfig) return fromConfig.replace(/^~/, i.home)
  if (i.hasChartroomDir || !i.hasCaptainDir) return `${i.home}/.chartroom`
  return `${i.home}/.captain`
}

export function isUnderWorktrees(cwd: string): boolean {
  return cwd.split('/').includes('worktrees')
}

export function samePath(a: string, b: string): boolean {
  const norm = (p: string) => (p.length > 1 ? p.replace(/\/+$/, '') : p)
  return norm(a) === norm(b)
}

// ---------------------------------------------------------------- when to read the board

/**
 * The home's change stamp, `<home>/.changed`: chartroom rewrites it after each write of what the
 * board shows (lib/core.sh stamp_changed; README "State format and event protocol"). Its mtime
 * is all that counts.
 */
export const STAMP_FILE = '.changed'

/**
 * The slow refresh: a board read at least this often, stamp or not, for what moves with the
 * clock alone (ages, waiting windows, a focus running out) and for what writes without the CLI
 * (a worker's `printf >>` fallback, a hand edit).
 */
export const REFRESH_MS = 5 * 60_000

/** A stat of the stamp as the views compare it: `mtime:size`, or `-` while there is none. */
export function stampKey(stat: { kind?: string; mtimeMs: number; size: number } | null | undefined): string {
  return stat && stat.kind !== 'dir' ? `${stat.mtimeMs}:${stat.size}` : '-'
}

/**
 * Whether a round reads the board: none read yet (or the last one failed), the stamp moved since
 * the last read began, or that read is REFRESH_MS old. A missing stamp (an older chartroom, or
 * nothing written since the update) reads `-` every round, so only the slow refresh reads then.
 */
export function boardDue(last: { stamp: string; at: number } | null, stamp: string, nowMs: number): boolean {
  return last === null || stamp !== last.stamp || nowMs - last.at >= REFRESH_MS
}

// ---------------------------------------------------------------- board

const LANES = ['needs_you', 'in_progress', 'on_hold', 'ready', 'recent'] as const

function str(v: unknown): string | null {
  return typeof v === 'string' && v !== '' ? v : null
}

function trimItem(raw: unknown): CrewItem | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  const id = str(r.id) ?? ''
  const type = str(r.type) ?? 'task'
  return {
    type,
    ref: str(r.short_id),
    short_id: str(r.short_id) ?? id.slice(-4),
    project: str(r.project),
    title: str(r.title) ?? id,
    state: str(r.state) ?? (type === 'inbox' ? 'inbox' : '?'),
    last_at: str(r.last_at),
    in_focus: r.in_focus !== false,
    held: r.held === true,
  }
}

function parseFocus(raw: unknown): CrewFocus | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  const projects = Array.isArray(r.projects) ? r.projects.filter((p): p is string => typeof p === 'string') : []
  if (!projects.length) return null
  const scope = Array.isArray(r.scope) ? r.scope.filter((p): p is string => typeof p === 'string') : []
  return { projects, scope, since: str(r.since) ?? '', until: str(r.until), held: typeof r.held === 'number' ? r.held : 0 }
}

/** The focus's name: `shop`, or `shop (IR-006)` with a scope. */
export function focusName(f: CrewFocus): string {
  return `${f.projects.join(', ')}${f.scope.length ? ` (${f.scope.join(', ')})` : ''}`
}

/** `chartroom board --json` output to the trimmed board, or an error line. */
export function parseBoard(stdout: string): { board: CrewBoard } | { error: string } {
  let raw: unknown
  try {
    raw = JSON.parse(stdout)
  } catch {
    return { error: 'chartroom board: unreadable output' }
  }
  if (typeof raw !== 'object' || raw === null) return { error: 'chartroom board: unreadable output' }
  const r = raw as Record<string, unknown>
  const lanes = (typeof r.lanes === 'object' && r.lanes !== null ? r.lanes : {}) as Record<string, unknown>
  const lane = (name: (typeof LANES)[number]) => {
    const list = lanes[name]
    return Array.isArray(list) ? list.map(trimItem).filter((x): x is CrewItem => x !== null) : []
  }
  return {
    board: {
      generated_at: str(r.generated_at) ?? '',
      home: str(r.home) ?? '',
      needs_you: lane('needs_you'),
      in_progress: lane('in_progress'),
      on_hold: lane('on_hold'),
      ready: lane('ready'),
      recent: lane('recent'),
      focus: parseFocus(r.focus),
    },
  }
}

/** The board as focus mode shows it: only the items in focus (every item while focus is off). */
export function focusedBoard(board: CrewBoard): CrewBoard {
  if (!board.focus) return board
  const keep = (items: CrewItem[]) => items.filter(i => i.in_focus)
  return { ...board, needs_you: keep(board.needs_you), in_progress: keep(board.in_progress), on_hold: keep(board.on_hold), ready: keep(board.ready), recent: keep(board.recent) }
}

/** `[project]` for an item; an inbox item without one reads `[inbox]`. */
export function label(item: CrewItem): string {
  return `[${item.project ?? (item.type === 'inbox' ? 'inbox' : '?')}]`
}

function tag(item: CrewItem): string {
  return item.short_id ? `${label(item)} ${item.short_id}` : label(item)
}

// ---------------------------------------------------------------- band

/**
 * One emoji per lane, the band's and the pane's. Each is East Asian Wide on its own code
 * point (no variation selector), so every terminal draws it two columns wide.
 */
export const LANE_EMOJI = {
  needsYou: '🙋',
  running: '🏃',
  onHold: '💤',
  landed: '✅',
  failed: '❌',
} as const

/** Focus mode's mark, wide on its own code point like the lane emoji. */
export const FOCUS_EMOJI = '🎯'

export const LEGEND = `${LANE_EMOJI.needsYou} needs you · ${LANE_EMOJI.running} running · ${LANE_EMOJI.onHold} on hold · ${LANE_EMOJI.landed} landed · ${LANE_EMOJI.failed} failed`

export type Tone = 'plain' | 'dim' | 'warn' | 'error'
export type Segment = { text: string; tone: Tone }

/**
 * The band's line, fitted to `width` columns (the needs-you list gives way first):
 * `⚓ 🏃 3 · 🙋 2 [shop] 108a, [api] 1b91 · 💤 1 · ✅ 1 · ❌ 1`. While focus mode is on it leads
 * with the focus and its held count, which never give way, and counts only what is in focus:
 * `⚓ 🎯 shop · 3 held · 🏃 1 · 🙋 1 [shop] 108a`.
 */
export function bandSegments(board: CrewBoard, width: number): Segment[] {
  const lanes = paneLanes(focusedBoard(board))
  const [needs, running, onHold, landed, failed] = lanes.map(l => l.items) as [CrewItem[], CrewItem[], CrewItem[], CrewItem[], CrewItem[]]
  const head: Segment = { text: '⚓ ', tone: 'plain' }
  const sep: Segment = { text: ' · ', tone: 'dim' }
  const count = (emoji: string, n: number, tone: Tone): Segment[] => (n ? [{ text: `${emoji} ${n}`, tone }] : [])
  const before = count(LANE_EMOJI.running, running.length, 'dim')
  const after = [
    ...count(LANE_EMOJI.onHold, onHold.length, 'dim'),
    ...count(LANE_EMOJI.landed, landed.length, 'dim'),
    ...count(LANE_EMOJI.failed, failed.length, 'error'),
  ]

  const focus: Segment[] = board.focus ? [{ text: `${FOCUS_EMOJI} ${focusName(board.focus)} · ${board.focus.held} held`, tone: 'warn' }] : []

  const build = (shown: number): Segment[] => {
    const parts = [...focus, ...before]
    if (needs.length) {
      const listed = needs.slice(0, shown).map(tag)
      const more = needs.length - shown
      if (more > 0) listed.push(`+${more} more`)
      parts.push({ text: `${LANE_EMOJI.needsYou} ${needs.length} ${listed.join(', ')}`, tone: 'warn' })
    }
    parts.push(...after)
    if (!parts.length) return [head, { text: 'crew idle', tone: 'dim' }]
    return [head, ...parts.flatMap((p, i) => (i ? [sep, p] : [p]))]
  }

  for (let shown = needs.length; shown > 0; shown--) {
    const segs = build(shown)
    if (cells(segs) <= width) return segs
  }
  return build(0)
}

export function bandText(board: CrewBoard, width: number): string {
  return bandSegments(board, width).map(s => s.text).join('')
}

function cells(segs: Segment[]): number {
  return segs.reduce((n, s) => n + columns(s.text), 0)
}

// Zero columns: combining marks, variation selectors, the zero-width joiner and friends.
const ZERO = /^[\p{Mn}\p{Me}\u200B-\u200F\uFE00-\uFE0F]$/u
// Two columns: emoji drawn as emoji by default, and the East Asian wide blocks.
const WIDE = /^[\p{Emoji_Presentation}\u1100-\u115F\u2E80-\u303E\u3041-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFF60\uFFE0-\uFFE6\u{20000}-\u{3FFFD}]$/u

/** How many terminal columns `text` takes: emoji and CJK are two, joiners and selectors none. */
export function columns(text: string): number {
  let n = 0
  for (const ch of text) n += ZERO.test(ch) ? 0 : WIDE.test(ch) ? 2 : 1
  return n
}

// ---------------------------------------------------------------- pane

/** How long ago an ISO time was: `40s`, `12m`, `3h`, `2d`; `-` when unknown. */
export function age(iso: string | null, nowMs: number): string {
  if (!iso) return '-'
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return '-'
  const s = Math.max(0, Math.round((nowMs - t) / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

export type PaneLane = { title: string; emoji: string; items: CrewItem[] }

/** The pane's lanes in order: needs you, running, on hold, landed, failed. */
export function paneLanes(board: CrewBoard): PaneLane[] {
  return [
    { title: 'NEEDS YOU', emoji: LANE_EMOJI.needsYou, items: board.needs_you.filter(i => i.state !== 'failed') },
    { title: 'RUNNING', emoji: LANE_EMOJI.running, items: board.in_progress },
    { title: 'ON HOLD', emoji: LANE_EMOJI.onHold, items: board.on_hold },
    { title: 'LANDED', emoji: LANE_EMOJI.landed, items: [...board.ready, ...board.recent] },
    { title: 'FAILED', emoji: LANE_EMOJI.failed, items: board.needs_you.filter(i => i.state === 'failed') },
  ]
}

/** `text` padded or cut (with `…`) to exactly `width` columns. */
export function fit(text: string, width: number): string {
  const used = columns(text)
  if (used <= width) return text + ' '.repeat(width - used)
  let out = ''
  let n = 0
  for (const ch of text) {
    const w = columns(ch)
    if (n + w > width - 1) break
    out += ch
    n += w
  }
  return `${out}…${' '.repeat(Math.max(0, width - 1 - n))}`
}

/** One line of the pane; an item's row carries the item's `ref` (pressing it opens the item). */
export type PaneLine = { key: string; text: string; tone: Tone; bold?: boolean; ref?: string }

/** Focus mode's line, `🎯 focus: shop · 3 held (since 2h)`; null while focus is off. */
export function focusText(board: CrewBoard, nowMs: number): string | null {
  const f = board.focus
  if (!f) return null
  return `${FOCUS_EMOJI} focus: ${focusName(f)} · ${f.held} held (since ${age(f.since, nowMs)}${f.until ? `, until ${f.until.slice(11, 16)}Z` : ''})`
}

/**
 * The pane's lines sized to `width` columns: the emoji legend (and focus mode's line), then a
 * header per lane with items, NEEDS YOU always, each followed by one row per item:
 * `[project] short_id title state age`. Out of focus, a row is dim.
 */
export function paneLines(board: CrewBoard, width: number, nowMs: number): PaneLine[] {
  const lanes = paneLanes(board)
  const all = lanes.flatMap(l => l.items)
  const projW = Math.max(3, ...all.map(i => label(i).length))
  const idW = Math.max(4, ...all.map(i => i.short_id.length))
  const stateW = Math.max(5, ...all.map(i => i.state.length))
  const ageW = 3
  const fixed = 2 + projW + 1 + idW + 1 + 1 + stateW + 1 + ageW
  const titleW = Math.max(8, width - fixed)
  const lines: PaneLine[] = [{ key: 'legend', text: LEGEND, tone: 'dim' }]
  const focus = focusText(board, nowMs)
  if (focus) lines.push({ key: 'focus', text: focus, tone: 'warn', bold: true })
  for (const lane of lanes) {
    if (!lane.items.length && lane.title !== 'NEEDS YOU') continue
    lines.push({ key: `h-${lane.title}`, text: `${lane.emoji} ${lane.title} (${lane.items.length})`, tone: lane.title === 'NEEDS YOU' && lane.items.length ? 'warn' : lane.title === 'FAILED' ? 'error' : 'plain', bold: true })
    for (const [n, item] of lane.items.entries()) {
      const row = `  ${label(item).padEnd(projW)} ${item.short_id.padEnd(idW)} ${fit(item.title, titleW)} ${item.state.padEnd(stateW)} ${age(item.last_at, nowMs).padStart(ageW)}`
      lines.push({ key: `r-${lane.title}-${n}`, text: row, tone: lane.title === 'LANDED' || !item.in_focus ? 'dim' : 'plain', ...(item.ref ? { ref: item.ref } : {}) })
    }
  }
  return lines
}

// ---------------------------------------------------------------- detail

function arr(v: unknown): Record<string, unknown>[] {
  return Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => typeof x === 'object' && x !== null) : []
}

function event(v: unknown): CrewDetail['outcome'] {
  if (typeof v !== 'object' || v === null) return null
  const r = v as Record<string, unknown>
  return { at: str(r.at) ?? '', kind: str(r.kind) ?? '?', text: str(r.text) ?? '' }
}

/** `chartroom show <id> --json` output to the detail the views draw, or an error line. */
export function parseDetail(stdout: string): { detail: CrewDetail } | { error: string } {
  let raw: unknown
  try {
    raw = JSON.parse(stdout)
  } catch {
    return { error: 'chartroom show: unreadable output' }
  }
  if (typeof raw !== 'object' || raw === null) return { error: 'chartroom show: unreadable output' }
  const r = raw as Record<string, unknown>
  const type = str(r.type) ?? 'task'
  const report = typeof r.report === 'object' && r.report !== null ? (r.report as Record<string, unknown>) : null
  const attach = typeof r.attach === 'object' && r.attach !== null ? (r.attach as Record<string, unknown>) : null
  return {
    detail: {
      type,
      id: str(r.id) ?? '',
      ref: str(r.short_id),
      title: str(r.title) ?? str(r.id) ?? '?',
      project: str(r.project),
      state: str(r.state) ?? '?',
      reason: str(r.reason),
      lane: str(r.lane),
      live: str(r.live),
      backend: str(r.backend),
      date: str(r.date),
      text: str(r.text),
      waiting_on: str(r.waiting_on),
      waiting_until: str(r.waiting_until),
      intent: str(r.intent),
      events: arr(r.events).map(event).filter((x): x is NonNullable<typeof x> => x !== null),
      outcome: event(r.outcome),
      report: report && str(report.path) ? { path: str(report.path) ?? '', summary: str(report.summary) } : null,
      prs: arr(r.prs).flatMap(p => (str(p.url) ? [{ url: str(p.url) ?? '', state: str(p.state) ?? 'UNKNOWN' }] : [])),
      artifacts: arr(r.artifacts).flatMap(a => (str(a.ref) ? [{ ref: str(a.ref) ?? '', title: str(a.title) ?? '', kind: str(a.kind) ?? 'note' }] : [])),
      attach: attach ? { where: str(attach.where) ?? '?', command: str(attach.command) } : null,
      worktree: str(r.worktree),
    },
  }
}

/** `text` word-wrapped to `width` columns, at most `max` lines (the last cut with `…`). */
export function wrap(text: string, width: number, max: number): string[] {
  const out: string[] = []
  for (const para of text.split('\n')) {
    let line = ''
    for (const word of para.split(/\s+/).filter(Boolean)) {
      const next = line ? `${line} ${word}` : word
      if (columns(next) <= width || !line) line = next
      else {
        out.push(line)
        line = word
      }
    }
    out.push(line)
  }
  const lines = out.map(l => (columns(l) > width ? fit(l, width).trimEnd() : l))
  if (lines.length <= max) return lines
  return [...lines.slice(0, max - 1), fit(`${lines[max - 1] ?? ''} …`, width).trimEnd()]
}

/** The lane's name as the pane's lanes say it. */
function laneName(d: CrewDetail): string {
  if (d.state === 'failed') return 'failed'
  return { needs_you: 'needs you', in_progress: 'running', on_hold: 'on hold', ready: 'landed', recent: 'landed' }[d.lane ?? ''] ?? 'off the board'
}

/** A detail line; a PR or artifact line is pressable (`press` says which one). */
export type DetailLine = PaneLine & { press?: { kind: 'pr' | 'artifact'; index: number } }

/**
 * The detail view's lines sized to `width` columns: the item's head, then its sections
 * (intent or text, last events, report or outcome, PRs, artifacts, worker), each only when
 * it has something.
 */
export function detailLines(d: CrewDetail, width: number, nowMs: number): DetailLine[] {
  const w = Math.max(20, width)
  const lines: DetailLine[] = []
  const tone: Tone = d.state === 'failed' ? 'error' : d.lane === 'needs_you' ? 'warn' : d.lane === 'ready' || d.lane === 'recent' ? 'dim' : 'plain'
  const head = `${d.ref ?? '-'}  ${d.project ? `[${d.project}] ` : d.type === 'inbox' ? '[inbox] ' : ''}${d.title}`
  lines.push({ key: 'head', text: fit(head, w).trimEnd(), tone: 'plain', bold: true })
  const facts = [d.state, d.reason && d.reason !== d.state ? d.reason : null, laneName(d), d.type === 'task' && d.live ? `live ${d.live}` : null, d.type === 'task' ? d.backend : null]
  lines.push({ key: 'state', text: fit(`${LANE_EMOJI[laneEmoji(d)]} ${facts.filter(Boolean).join(' · ')}`, w).trimEnd(), tone })
  if (d.date && d.type === 'inbox') lines.push({ key: 'since', text: `since ${d.date}`, tone: 'dim' })
  if (d.waiting_on) {
    for (const [n, l] of wrap(`waiting on: ${d.waiting_on}${d.waiting_until ? ` · until ${d.waiting_until}` : ''}`, w, 3).entries()) {
      lines.push({ key: `wait-${n}`, text: l, tone: 'warn' })
    }
  }
  const section = (title: string, body: string[], key: string, bodyTone: Tone = 'plain') => {
    if (!body.length) return
    lines.push({ key: `h-${key}`, text: title, tone: 'dim', bold: true })
    for (const [n, l] of body.entries()) lines.push({ key: `${key}-${n}`, text: `  ${l}`, tone: bodyTone })
  }
  if (d.type === 'inbox') section('QUESTION', wrap(d.text ?? d.title, w - 2, 10), 'text')
  else section('INTENT', d.intent ? wrap(d.intent, w - 2, 6) : [], 'intent')
  section('LAST EVENTS', d.events.slice(-5).map(e => fit(`${age(e.at, nowMs).padStart(3)} ${e.kind}: ${e.text.replace(/\s+/g, ' ')}`, w - 2).trimEnd()), 'event')
  if (d.report) section(`REPORT  ${d.report.path}`, d.report.summary ? wrap(d.report.summary, w - 2, 8) : ['(no summary)'], 'report')
  else if (d.outcome) section('OUTCOME', wrap(`${d.outcome.kind}: ${d.outcome.text}`, w - 2, 4), 'outcome')
  if (d.prs.length) {
    lines.push({ key: 'h-prs', text: 'PRS', tone: 'dim', bold: true })
    for (const [n, p] of d.prs.entries()) {
      const state = p.state && p.state !== 'UNKNOWN' ? ` (${p.state.toLowerCase()})` : ''
      lines.push({ key: `pr-${n}`, text: fit(`  ${p.url}${state}`, w).trimEnd(), tone: 'plain', press: { kind: 'pr', index: n } })
    }
  }
  if (d.artifacts.length) {
    lines.push({ key: 'h-artifacts', text: 'ARTIFACTS', tone: 'dim', bold: true })
    for (const [n, a] of d.artifacts.entries()) {
      lines.push({ key: `artifact-${n}`, text: fit(`  ${a.ref}  ${a.title} (${a.kind})`, w).trimEnd(), tone: 'plain', press: { kind: 'artifact', index: n } })
    }
  }
  if (d.attach) {
    const worker = [`${d.attach.where}${d.attach.command ? ` · ${d.attach.command}` : ''}`, ...(d.worktree ? [`worktree ${d.worktree}`] : [])]
    section('WORKER', worker.flatMap(l => wrap(l, w - 2, 2)), 'worker', 'dim')
  }
  return lines
}

function laneEmoji(d: CrewDetail): keyof typeof LANE_EMOJI {
  if (d.state === 'failed') return 'failed'
  return ({ needs_you: 'needsYou', in_progress: 'running', on_hold: 'onHold', ready: 'landed', recent: 'landed' } as const)[d.lane as 'needs_you'] ?? 'onHold'
}

// ---------------------------------------------------------------- actions

export type ActionId = 'continue' | 'copy-id' | 'copy-pr' | 'report' | 'copy-artifact' | 'back'
export type Action = { id: ActionId; hotkey: string; label: string }

/**
 * The detail view's actions, in order, each with its one-letter hotkey: continue and copy
 * the id need the item's id; copy a PR, the report and copy an artifact need one to exist.
 * `detail` is null while `chartroom show` runs, so the actions that need it wait.
 */
export function detailActions(ref: string | null, detail: CrewDetail | null): Action[] {
  const out: Action[] = []
  if (ref) out.push({ id: 'continue', hotkey: 'c', label: 'continue' }, { id: 'copy-id', hotkey: 'y', label: 'copy id' })
  if (detail?.prs.length) out.push({ id: 'copy-pr', hotkey: 'p', label: detail.prs.length > 1 ? 'copy 1st PR' : 'copy PR' })
  if (detail?.report) out.push({ id: 'report', hotkey: 'r', label: 'report' })
  if (detail?.artifacts.length) out.push({ id: 'copy-artifact', hotkey: 'a', label: detail.artifacts.length > 1 ? 'copy 1st artifact' : 'copy artifact' })
  out.push({ id: 'back', hotkey: 'b', label: 'back' })
  return out
}
