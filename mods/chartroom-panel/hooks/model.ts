// Pure helpers for chartroom-panel: no `$`, so the tests can call them directly.
//
// The heart of the mod is parseTasks: the filter that decides which rows the panel shows.
// It is deliberately the Pi panel's (adapters/pi-panel/model.ts) filter, so the two siblings
// hide and keep exactly the same rows.

import type { Snapshot, Task, Tone } from '../types'

/**
 * Parses `chartroom status --json` and keeps only the unfinished rows.
 *
 * Hide a task when `state ∈ {done, closed}` OR `closed` is non-null (`closed == null` keeps a
 * row whose `closed` is null or absent; any non-null value, a timestamp or even "", hides it).
 * The filter never looks at `live`: a `state: decision` row with `live: done` stays visible.
 *
 * Throws on anything that is not an array of rows each carrying a string `id` and `state`, so a
 * malformed payload surfaces as an error (stale rows kept) rather than an empty fleet.
 */
export function parseTasks(text: string): Task[] {
  const rows: unknown = JSON.parse(text)
  if (
    !Array.isArray(rows) ||
    rows.some(row => !row || typeof (row as Task).id !== 'string' || typeof (row as Task).state !== 'string')
  ) {
    throw new Error('invalid status JSON')
  }
  return (rows as Task[]).filter(row => row.state !== 'done' && row.state !== 'closed' && row.closed == null)
}

// ---------------------------------------------------------------- state → label and tone

// "needing input" (decision/blocked/awaiting-input and the overdue-wait), per the brief's filtering map.
const INPUT = new Set(['decision', 'blocked', 'awaiting-input', 'waiting-overdue'])
// "being worked on".
const WORKING = new Set(['working', 'running', 'drafting'])
// Quiet/attention states that stay visible but recede.
const QUIET = new Set(['stopped-silent', 'waiting', 'failed', 'lost'])

/** The tone for a state; an UNKNOWN unfinished state is `plain` — visible in the default colour, never dimmed away. */
export function tone(state: string): Tone {
  if (INPUT.has(state)) return 'input'
  if (WORKING.has(state)) return 'working'
  if (QUIET.has(state)) return 'quiet'
  return 'plain'
}

/** The human label for a state: `stopped-silent` reads `stopped silent`. */
export function stateLabel(state: string): string {
  return state.replaceAll('-', ' ')
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

/** The chrome rows the panel always draws: header, status, gap, two footer lines. */
export const CHROME_ROWS = 5

/** How many tasks fit given the body's rows: two lines each, after the chrome. At least one. */
export function capacityFor(bodyRows: number): number {
  return Math.max(1, Math.floor((bodyRows - CHROME_ROWS) / 2))
}

export type Page = {
  /** Total visible tasks. */
  total: number
  /** Number of pages (at least 1). */
  pages: number
  /** The resolved page index (0-based), the request wrapped into range. */
  page: number
  /** 0-based index of the first task shown. */
  start: number
  /** The tasks on this page. */
  tasks: Task[]
  /** The footer's range line: `first–last of total · page p/pages`. */
  footer: string
}

/** The slice for `page` (wrapping out-of-range requests), with the footer range line. */
export function paginate(tasks: Task[], capacity: number, page: number): Page {
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

export type { Snapshot, Task, Tone }
