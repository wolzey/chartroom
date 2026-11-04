// When the band reads the board: only once the home's change stamp moved, or the slow refresh is
// due, so an idle home costs one `chartroom board --json` per 5 minutes instead of one per 15 s.
import { describe, expect, test } from 'claude-code/testing'

import { REFRESH_MS, boardDue, stampKey } from '../hooks/crew'
import { STAMP, XO_WORLD, install, startXo } from './world'

describe('boardDue', () => {
  const last = { stamp: '5:1', at: 1_000 }
  test('reads when none was read yet, when the stamp moved, or when the last read is 5 minutes old', () => {
    expect(boardDue(null, '5:1', 1_000)).toBe(true)
    expect(boardDue(last, '5:1', 1_000 + 15_000)).toBe(false)
    expect(boardDue(last, '6:1', 1_000 + 15_000)).toBe(true)
    expect(boardDue(last, '5:1', 1_000 + REFRESH_MS - 1)).toBe(false)
    expect(boardDue(last, '5:1', 1_000 + REFRESH_MS)).toBe(true)
  })

  test('a missing stamp compares equal to itself: only the slow refresh reads then', () => {
    expect(stampKey(undefined)).toBe('-')
    expect(stampKey({ kind: 'dir', mtimeMs: 0, size: 0 })).toBe('-')
    expect(stampKey({ kind: 'file', mtimeMs: 7, size: 1 })).toBe('7:1')
    expect(boardDue({ stamp: '-', at: 0 }, '-', 60_000)).toBe(false)
  })
})

test('an idle home: no board read between changes, one when the stamp moves, one per 5 minutes', async ($, on) => {
  const world = XO_WORLD()
  world.mtimes[STAMP] = 1
  const w = install(on, world)
  const boards = () => w.runs.filter(r => r[1] === 'board').length
  await startXo($)
  await w.clock.settle()
  expect(boards()).toBe(1)
  // Unchanged rounds: four ticks, no process.
  await w.clock.advance(60_000)
  expect(boards()).toBe(1)
  // A write moves the stamp: the next round reads, once.
  world.mtimes[STAMP] = 2
  await w.clock.advance(15_000)
  expect(boards()).toBe(2)
  await w.clock.advance(45_000)
  expect(boards()).toBe(2)
  // Ten idle minutes: the slow refresh reads twice, where a read per round would be forty.
  await w.clock.advance(10 * 60_000)
  expect(boards()).toBe(4)
})

test('a failed board read is tried again the next round', async ($, on) => {
  const world = XO_WORLD()
  world.mtimes[STAMP] = 1
  let fail = true
  world.board = () => (fail ? { exitCode: 1, stdout: '', stderr: 'chartroom: busy' } : XO_WORLD().board())
  const w = install(on, world)
  const boards = () => w.runs.filter(r => r[1] === 'board').length
  await startXo($)
  await w.clock.settle()
  expect(boards()).toBe(1)
  fail = false
  await w.clock.advance(15_000)
  expect(boards()).toBe(2)
  await w.clock.advance(15_000)
  expect(boards()).toBe(2)
})
