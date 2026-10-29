// The pure logic — the board parse, the lane helpers, width-safe text and paging. Called directly.
import { expect, test } from 'claude-code/testing'

import {
  CHROME_ROWS,
  LANES,
  autoShowEnabled,
  capacityFor,
  cardDetail,
  cardKey,
  clean,
  columns,
  configValue,
  laneCounts,
  laneHeader,
  laneTone,
  paginate,
  parseBoard,
  setConfigLine,
  truncate,
} from '../hooks/model'
import type { Card } from '../hooks/model'

test('lanes: the board\'s five, in its order, under its names', () => {
  expect(LANES.map(l => l.key)).toEqual(['needs_you', 'in_progress', 'on_hold', 'ready', 'recent'])
  expect(LANES.map(l => l.name)).toEqual(['Needs you', 'In progress', 'On hold', 'Ready for you', 'Recently finished'])
})

test('parseBoard: cards flat in board order, each tagged with its lane; keys absent lanes as empty', () => {
  const board = {
    lanes: {
      recent: [{ id: 'r-0001', state: 'closed' }],
      needs_you: [{ id: 'd-0002', state: 'decision' }, { id: 'v-0003', state: 'review', reason: 'PR to review' }, { type: 'inbox', id: 'inbox-0', short_id: null, state: 'inbox' }],
      in_progress: [{ id: 'w-0004', state: 'working' }],
    },
  }
  const got = parseBoard(JSON.stringify(board))
  expect(got.map(c => [c.id, c.lane])).toEqual([
    ['d-0002', 'needs_you'],
    ['v-0003', 'needs_you'],
    ['inbox-0', 'needs_you'],
    ['w-0004', 'in_progress'],
    ['r-0001', 'recent'],
  ])
})

test('parseBoard: malformed payloads throw (so the panel keeps stale cards, never an empty board)', () => {
  for (const bad of ['[]', '{}', 'null', '{"lanes":{"needs_you":{}}}', '{"lanes":{"ready":[null]}}', '{"lanes":{"ready":[{"state":"done"}]}}', 'not json']) {
    expect(() => parseBoard(bad)).toThrow()
  }
})

test('cards: key, counts with held, the header and the detail line read like the board', () => {
  const cards: Card[] = [
    { id: 'fix-21ba', short_id: '21ba', lane: 'needs_you', state: 'review', reason: 'PR to review', project: 'shop' },
    { id: 'pay-7f3a', short_id: '7f3a', lane: 'needs_you', state: 'blocked', reason: 'blocked', held: true, project: 'billing' },
    { id: 'inbox-1', short_id: null, lane: 'needs_you', type: 'inbox', reason: 'waiting on you (inbox)' },
  ]
  expect(cards.map(cardKey)).toEqual(['21ba', '7f3a', 'inbox-1'])
  const n = laneCounts(cards)
  expect(n.needs_you).toEqual({ count: 3, held: 1 })
  expect(n.recent).toEqual({ count: 0, held: 0 })
  expect(laneHeader('Needs you', n.needs_you)).toBe('Needs you (3, 1 held)')
  expect(laneHeader('On hold', n.on_hold)).toBe('On hold (0)')
  expect(cards.map(cardDetail)).toEqual(['PR to review · shop', 'blocked · held · billing', 'waiting on you (inbox)'])
})

test('laneTone: needs-you yellow, in-progress green, on-hold/recent dim, ready plain', () => {
  expect(['needs_you', 'in_progress', 'on_hold', 'ready', 'recent'].map(laneTone)).toEqual(['input', 'working', 'quiet', 'plain', 'quiet'])
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
  const tasks: Card[] = Array.from({ length: 23 }, (_, i) => ({ id: String(i), state: 'working', lane: 'in_progress' as const }))
  const cap = 12
  expect(capacityFor(30)).toBe(9) // (30 - 6 chrome - 5 lane headers) / 2
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

test('config: autoShowEnabled (default/on/off), configValue (last wins), setConfigLine (preserves keys)', () => {
  expect(autoShowEnabled(null)).toBe(true) // unset = default on
  expect(autoShowEnabled('')).toBe(true)
  expect(autoShowEnabled('autoshow=on')).toBe(true)
  expect(autoShowEnabled('autoshow=off')).toBe(false)
  expect(autoShowEnabled('autoshow=OFF\n')).toBe(false)
  expect(autoShowEnabled('autoshow=false')).toBe(false)
  expect(autoShowEnabled('autoshow=0')).toBe(false)
  expect(autoShowEnabled('other=1')).toBe(true) // an unrelated key leaves the default on
  expect(configValue('a=1\nautoshow=off\nautoshow=on', 'autoshow')).toBe('on') // last line wins
  const t = setConfigLine('theme=dark\nautoshow=on\n', 'autoshow', 'off')
  expect(t).toContain('theme=dark') // other keys preserved
  expect(autoShowEnabled(t)).toBe(false)
  expect(setConfigLine(null, 'autoshow', 'off')).toBe('autoshow=off\n')
  expect(setConfigLine('autoshow=off\nautoshow=off', 'autoshow', 'on')).toBe('autoshow=on\n') // collapses dupes
})

test('capacityFor: at least one card even on a tiny pane', () => {
  expect(capacityFor(CHROME_ROWS)).toBe(1)
  expect(capacityFor(0)).toBe(1)
  expect(capacityFor(100)).toBeGreaterThan(10)
})
