// The pure logic — the filter, the tone map, width-safe text and paging. Called directly.
import { expect, test } from 'claude-code/testing'

import { CHROME_ROWS, capacityFor, clean, columns, paginate, parseTasks, stateLabel, tone, truncate } from '../hooks/model'

const row = (state: string, extra: Record<string, unknown> = {}) => ({ id: state, state, title: 'A task', ...extra })

test('filter: unfinished rows stay (incl. unknown states); done/closed and any closed value hide', () => {
  // Every unfinished state — including a decision whose worker is live=done, and a state the mod
  // has never heard of — must stay visible. done, closed, and any non-null `closed` must drop off.
  const kept = ['drafting', 'working', 'running', 'waiting', 'decision', 'blocked', 'failed', 'lost', 'stopped-silent', 'awaiting-input', 'waiting-overdue', 'future-state']
  const payload = JSON.stringify([
    ...kept.map(state => row(state, { live: 'done' })), // live=done never hides a visible row
    row('done'),
    row('closed'),
    row('working', { closed: '2026-10-27T00:00:00Z' }), // active state but closed timestamp → hidden
    row('decision', { closed: '' }), // "" is non-null → hidden
    row('working', { closed: null }), // explicit null → kept
  ])
  const got = parseTasks(payload)
  expect(got.filter(t => t.closed == null).map(t => t.state)).toEqual([...kept, 'working'])
  // The last kept row is the closed:null one; nothing with a done/closed state or a closed value remains.
  expect(got.some(t => t.state === 'done' || t.state === 'closed')).toBe(false)
  expect(got.every(t => t.closed == null)).toBe(true)
})

test('filter: malformed payloads throw (so the panel keeps stale rows, never an empty fleet)', () => {
  for (const bad of ['{}', '[null]', '[{"id":"a"}]', '[{"state":"working"}]', 'not json']) {
    expect(() => parseTasks(bad)).toThrow()
  }
})

test('tone: input-needed vs working vs quiet vs unknown', () => {
  for (const s of ['decision', 'blocked', 'awaiting-input', 'waiting-overdue']) expect(tone(s)).toBe('input')
  for (const s of ['working', 'running', 'drafting']) expect(tone(s)).toBe('working')
  for (const s of ['stopped-silent', 'waiting', 'failed', 'lost']) expect(tone(s)).toBe('quiet')
  expect(tone('future-state')).toBe('plain')
})

test('stateLabel: hyphens read as spaces (stopped-silent → stopped silent)', () => {
  expect(stateLabel('stopped-silent')).toBe('stopped silent')
  expect(stateLabel('awaiting-input')).toBe('awaiting input')
  expect(stateLabel('working')).toBe('working')
})

test('columns + truncate: control chars cleaned, emoji two wide, cuts marked with …', () => {
  expect(clean('\x1b[2Jhi\x07')).toBe('hi ')
  expect(columns('🚀🚀')).toBe(4)
  expect(columns(truncate('🚀🚀🚀🚀', 5))).toBeLessThanOrEqual(5)
  expect(truncate('hello world', 6)).toBe('hello…')
  expect(truncate('short', 20)).toBe('short')
  expect(truncate('x', 0)).toBe('')
})

test('paginate: pages, footer range, wrapping and the empty fleet', () => {
  const tasks = Array.from({ length: 23 }, (_, i) => ({ id: String(i), state: 'working' }))
  const cap = capacityFor(30) // (30 - 5) / 2 = 12
  expect(cap).toBe(12)
  const p0 = paginate(tasks, cap, 0)
  expect([p0.pages, p0.tasks.length, p0.footer]).toEqual([2, 12, '1–12 of 23 · page 1/2'])
  const p1 = paginate(tasks, cap, 1)
  expect([p1.start, p1.tasks.length, p1.footer]).toEqual([12, 11, '13–23 of 23 · page 2/2'])
  // next past the last page wraps to the first; prev past the first wraps to the last.
  expect(paginate(tasks, cap, 2).page).toBe(0)
  expect(paginate(tasks, cap, -1).page).toBe(1)
  const empty = paginate([], cap, 3)
  expect([empty.total, empty.pages, empty.footer]).toEqual([0, 1, '0 of 0 · page 1/1'])
})

test('capacityFor: at least one task even on a tiny pane', () => {
  expect(capacityFor(CHROME_ROWS)).toBe(1)
  expect(capacityFor(0)).toBe(1)
  expect(capacityFor(100)).toBeGreaterThan(10)
})
