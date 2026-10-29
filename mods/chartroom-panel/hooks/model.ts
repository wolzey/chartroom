// Pure helpers for chartroom-panel: no `$`, so the tests can call them directly.
//
// The heart of the mod is parseBoard: the panel shows exactly what `chartroom board` and the
// dashboard show, from the same source (`chartroom board --json`, built by lib/dashboard/lanes.jq):
// the same five lanes, in the same order, under the same names, each card with the board's reason.
// The panel decides nothing about which lane a task belongs in.

import type { Card, LaneKey, Snapshot, Tone } from '../types'

/** The board's lanes, in its order and under its names (`chartroom board`, the dashboard page). */
export const LANES: readonly { key: LaneKey; name: string }[] = [
  { key: 'needs_you', name: 'Needs you' },
  { key: 'in_progress', name: 'In progress' },
  { key: 'on_hold', name: 'On hold' },
  { key: 'ready', name: 'Ready for you' },
  { key: 'recent', name: 'Recently finished' },
]

/**
 * Parses `chartroom board --json` into its cards, flat, in board order (lane by lane, each lane in
 * the board's own order), each carrying the lane it sits in. Cards are tasks and inbox items alike.
 *
 * Throws on anything that is not a board (an object whose `lanes` holds an array per lane, each card
 * an object with a string `id`), so a malformed payload surfaces as an error (stale cards kept)
 * rather than an empty board.
 */
export function parseBoard(text: string): Card[] {
  const board: unknown = JSON.parse(text)
  const lanes = (board as { lanes?: unknown } | null)?.lanes as Record<string, unknown> | undefined
  if (!lanes || typeof lanes !== 'object') throw new Error('invalid board JSON')
  const out: Card[] = []
  for (const { key } of LANES) {
    const items = lanes[key] ?? []
    if (!Array.isArray(items) || items.some(c => !c || typeof (c as Card).id !== 'string')) throw new Error('invalid board JSON')
    for (const c of items as Card[]) out.push({ ...c, lane: key })
  }
  return out
}

/** A card's key: its short id (what /continue and the ring take), else its id. */
export function cardKey(card: Card): string {
  return card.short_id ?? card.id
}

/** How many cards sit in each lane. */
export function laneCounts(cards: Card[]): Record<LaneKey, { count: number; held: number }> {
  const out = Object.fromEntries(LANES.map(l => [l.key, { count: 0, held: 0 }])) as Record<LaneKey, { count: number; held: number }>
  for (const c of cards) {
    const n = out[c.lane]
    if (!n) continue
    n.count++
    if (c.held) n.held++
  }
  return out
}

/** A lane's header line, as `chartroom board` prints it: `Needs you (3, 1 held)`. */
export function laneHeader(name: string, n: { count: number; held: number }): string {
  return `${name} (${n.count}${n.held ? `, ${n.held} held` : ''})`
}

/** The card's second line: the board's reason (its bracket), held, and the project. */
export function cardDetail(card: Card): string {
  const reason = card.reason ?? card.state ?? ''
  return `${reason}${card.held ? ' · held' : ''}${card.project ? ` · ${card.project}` : ''}`
}

// ---------------------------------------------------------------- lane → tone

/** The colour band a lane draws in: needs-you yellow, in-progress green, on-hold and recent dim. */
export function laneTone(lane: string): Tone {
  if (lane === 'needs_you') return 'input'
  if (lane === 'in_progress') return 'working'
  if (lane === 'on_hold' || lane === 'recent') return 'quiet'
  return 'plain'
}

// ---------------------------------------------------------------- width-safe text
//
// These patterns are built from strings (doubled backslashes) so this source file carries only
// ASCII escapes — never a literal control character or line separator, which would break parsing.

// ANSI escape sequences, then the C0/C1 control characters and the line/paragraph separators.
// A title the panel draws must carry none of them: they would corrupt the frame.
const ANSI = new RegExp('\\u001b\\[[0-9;]*[A-Za-z]', 'g')
const CONTROL = new RegExp('[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]', 'g')

/** `text` with ANSI stripped and every control character turned to a space. */
export function clean(text: unknown): string {
  return String(text ?? '')
    .replace(ANSI, '')
    .replace(CONTROL, ' ')
}

// Zero columns: combining marks, variation selectors, the zero-width joiner and friends.
const ZERO = new RegExp('^[\\p{Mn}\\p{Me}\\u200B-\\u200F\\uFE00-\\uFE0F]$', 'u')
// Two columns: emoji drawn as emoji by default, and the East Asian wide blocks.
const WIDE = new RegExp(
  '^[\\p{Emoji_Presentation}\\u1100-\\u115F\\u2E80-\\u303E\\u3041-\\uA4CF\\uAC00-\\uD7A3\\uF900-\\uFAFF\\uFE30-\\uFE4F\\uFF00-\\uFF60\\uFFE0-\\uFFE6\\u{20000}-\\u{3FFFD}]$',
  'u',
)

/** How many terminal columns `text` takes: emoji and CJK are two, joiners and selectors none. */
export function columns(text: string): number {
  let n = 0
  for (const ch of text) n += ZERO.test(ch) ? 0 : WIDE.test(ch) ? 2 : 1
  return n
}

/** `text` cut to at most `width` columns, an `…` marking a cut (never padded). */
export function truncate(text: string, width: number): string {
  if (width <= 0) return ''
  if (columns(text) <= width) return text
  let out = ''
  let n = 0
  for (const ch of text) {
    const w = columns(ch)
    if (n + w > width - 1) break
    out += ch
    n += w
  }
  return `${out}…`
}

// ---------------------------------------------------------------- the panel's data and paging

/** The chrome rows the panel always draws: header, status, gap, two footer lines, the controls hint. */
export const CHROME_ROWS = 6

/** How many cards fit given the body's rows: two lines each, after the chrome and one header per lane. At least one. */
export function capacityFor(bodyRows: number): number {
  return Math.max(1, Math.floor((bodyRows - CHROME_ROWS - LANES.length) / 2))
}

export type Page = {
  /** Total cards. */
  total: number
  /** Number of pages (at least 1). */
  pages: number
  /** The resolved page index (0-based), the request wrapped into range. */
  page: number
  /** 0-based index of the first card shown. */
  start: number
  /** The cards on this page. */
  tasks: Card[]
  /** The footer's range line: `first–last of total · page p/pages`. */
  footer: string
}

/** The slice for `page` (wrapping out-of-range requests), with the footer range line. */
export function paginate(tasks: Card[], capacity: number, page: number): Page {
  const cap = Math.max(1, capacity)
  const total = tasks.length
  const pages = Math.max(1, Math.ceil(total / cap))
  const p = ((Math.trunc(page) % pages) + pages) % pages
  const start = p * cap
  const slice = tasks.slice(start, start + cap)
  const last = start + slice.length
  const range = total ? `${start + 1}–${last} of ${total}` : '0 of 0'
  return { total, pages, page: p, start, tasks: slice, footer: `${range} · page ${p + 1}/${pages}` }
}

/** The command the footer advertises as the available controls. */
export const CONTROLS = '/chartroom-panel next|prev|off'

// ---------------------------------------------------------------- the home's panel config
//
// A durable, harness-neutral setting lives in `$CHARTROOM_HOME/panel.conf` as KEY=VALUE lines, so
// the Pi panel and a future Codex panel can read the same switch. The panel reads `autoshow`
// (unset/default = on; `off`/`false`/`0`/`no` = off) to decide whether to auto-show on session start.

const OFF_VALUES = new Set(['off', 'false', '0', 'no', 'n'])

/** A KEY=VALUE config value (last line wins, quotes stripped), or '' when absent. */
export function configValue(text: string, key: string): string {
  let value = ''
  const re = new RegExp(`^\\s*${key}\\s*=\\s*(.*)$`)
  for (const line of text.split('\n')) {
    const m = re.exec(line.replace(/\r$/, ''))
    if (m) value = (m[1] ?? '').trim()
  }
  const quoted = /^"(.*)"$/.exec(value) ?? /^'(.*)'$/.exec(value)
  return quoted ? quoted[1] ?? '' : value
}

/** `text` with `key` set to `value`: replaces every existing `key=` line and drops blanks, else appends. */
export function setConfigLine(text: string | null | undefined, key: string, value: string): string {
  const re = new RegExp(`^\\s*${key}\\s*=`)
  const kept = (text ?? '').split('\n').filter(line => line.trim() !== '' && !re.test(line.replace(/\r$/, '')))
  kept.push(`${key}=${value}`)
  return `${kept.join('\n')}\n`
}

/** Whether the panel should auto-show, from `panel.conf` text: true unless `autoshow` reads off. */
export function autoShowEnabled(configText: string | null | undefined): boolean {
  if (!configText) return true
  return !OFF_VALUES.has(configValue(configText, 'autoshow').toLowerCase())
}

// ---------------------------------------------------------------- paths (gating)

/** Two paths are the same once their trailing slashes are dropped. */
export function samePath(a: string, b: string): boolean {
  const norm = (p: string) => (p.length > 1 ? p.replace(/\/+$/, '') : p)
  return norm(a) === norm(b)
}

/** True when `worktrees` is a path segment: a crew worker's directory, never the XO's home. */
export function isUnderWorktrees(cwd: string): boolean {
  return cwd.split('/').includes('worktrees')
}

export type { Card, LaneKey, Snapshot, Tone }
