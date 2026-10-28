// The live panel: auto-show gating, the timer poll, stale-on-error, on/off/toggle, paging,
// cleanup at session end, and selection into the prompt. Drives the mod through the test kit.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { HOME, PANE_PROPS, XO_WORLD, install, panelCommand, start, statusJson } from './world'

const mountPane = ($: Engine, width = 90, over = {}) =>
  $.ui.mount({ plugin: 'chartroom-panel', surface: 'terminal', component: 'Pane', requestId: 'chartroom-panel', props: PANE_PROPS(width, over) })

const polls = (runs: string[][]) => runs.filter(r => r[1] === 'status').length

test('auto-shows at the home: registers the command, opens the pane, polls, draws the fleet', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($)
  await w.clock.settle()
  expect(w.commands).toEqual(['chartroom-panel'])
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel'])
  expect(w.opens[0]?.focus).toBeUndefined() // auto-show never grabs the keyboard
  // Every status read names this session's home (the doctor probe runs before home is known).
  const statusHomes = w.runs.map((r, i) => (r[1] === 'status' ? w.homes[i] : null)).filter(h => h !== null)
  expect(statusHomes.length).toBeGreaterThan(0)
  expect(statusHomes.every(h => h === HOME)).toBe(true)

  const ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: /^Chartroom · 1 unfinished/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Live · updated / })).toBeDefined()
  // A state:decision, live:done row MUST be visible — the filter never looks at live.
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /decision · shop/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '/chartroom-panel next|prev|off' })).toBeDefined()
  await ui.unmount()
})

test('does not auto-show in a worktree, with CHARTROOM_TASK set, or non-interactively', async ($, on) => {
  const worktree = install(on, XO_WORLD())
  await start($, `${HOME}/worktrees/shop/task-abcd`)
  await worktree.clock.settle()
  expect(worktree.opens).toEqual([]) // interactive, command exists, but no auto pane
  expect(worktree.commands).toEqual(['chartroom-panel'])
  expect(polls(worktree.runs)).toBe(0)
})

test('a crew-worker session (CHARTROOM_TASK set) stays fully inert', async ($, on) => {
  const world = XO_WORLD()
  world.env = { ...world.env, CHARTROOM_TASK: 'some-task-1234' }
  const w = install(on, world)
  await start($)
  await w.clock.settle()
  expect(w.opens).toEqual([])
  expect(polls(w.runs)).toBe(0)
})

test('a non-interactive (-p) run registers no command, opens no pane and never polls', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, HOME, false)
  await w.clock.settle()
  expect(w.commands).toEqual([])
  expect(w.opens).toEqual([])
  expect(polls(w.runs)).toBe(0)
})

test('active → done disappears without closure; the count follows', async ($, on) => {
  const world = XO_WORLD()
  world.status = () => ({ exitCode: 0, stdout: statusJson([{ id: 'auth-108a', state: 'working', title: 'Auth' }]), stderr: '' })
  const w = install(on, world)
  await start($)
  await w.clock.settle()
  let ui = await mountPane($)
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /1 unfinished/ })).toBeDefined()
  await ui.unmount()

  // The worker finishes: the next poll drops it, with no close event anywhere.
  world.status = () => ({ exitCode: 0, stdout: statusJson([{ id: 'auth-108a', state: 'done', title: 'Auth' }]), stderr: '' })
  await w.clock.advance(5_000)
  ui = await mountPane($)
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /0 unfinished/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /No unfinished tasks/ })).toBeDefined()
  await ui.unmount()
})

test('a refresh failure keeps the last known tasks, shown STALE — never an empty fleet', async ($, on) => {
  const world = XO_WORLD()
  world.status = () => ({ exitCode: 0, stdout: statusJson([{ id: 'auth-108a', state: 'blocked', title: 'Auth' }]), stderr: '' })
  const w = install(on, world)
  await start($)
  await w.clock.settle()

  world.status = () => 'missing' // chartroom vanishes
  await w.clock.advance(5_000)
  let ui = await mountPane($)
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined() // stale row still shown
  expect(await ui.find({ type: 'Text', text: /^STALE:/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /1 unfinished/ })).toBeDefined()
  await ui.unmount()

  world.status = () => ({ exitCode: 0, stdout: '{ not json', stderr: '' }) // malformed
  await w.clock.advance(5_000)
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: /STALE: malformed status JSON/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined()
  await ui.unmount()
})

test('off stops the refresh work and closes the pane; on brings it back', async ($, on) => {
  const w = install(on, XO_WORLD())
  const panel = panelCommand($)
  await start($)
  await w.clock.settle()
  const before = polls(w.runs)
  expect((await panel('off')).text).toMatch(/off for this session/)
  expect(w.closes).toEqual(['chartroom-panel:plugin'])
  await w.clock.advance(20_000)
  expect(polls(w.runs)).toBe(before) // no polling while off
  expect((await panel('on')).text).toMatch(/on\.?$/)
  await w.clock.advance(5_000)
  expect(polls(w.runs)).toBeGreaterThan(before)
})

test('toggle: closes when shown, opens-and-asks-for-focus when hidden; focus re-asks for the keys', async ($, on) => {
  const w = install(on, XO_WORLD())
  const panel = panelCommand($)
  await start($) // auto-shown
  await w.clock.settle()
  // Shown → the bare command closes it (the composer holds the keys, so the pane is never focused here).
  expect((await panel()).text).toBe('Chartroom panel closed.')
  expect(w.closes.at(-1)).toBe('chartroom-panel:plugin')
  // Hidden → it opens and requests the keyboard.
  const reopened = await panel()
  expect(reopened.text).toMatch(/focused/)
  expect(w.opens.at(-1)?.focus).toBe(true)
  // `focus` opens/refocuses without ever closing.
  expect((await panel('focus')).text).toMatch(/focused/)
  expect(w.opens.at(-1)?.focus).toBe(true)
})

// The person's own pane-close (the frame's ✕ / ctrl+x x) raises ui.close with origin 'person',
// which turns the panel off (see the ui.close hook). The test kit cannot synthesize the engine's
// own person-close (it exposes no $.ui.close and the mounted ui has no dismiss), so that path is
// covered by `claude plugin validate` (the hook is registered) and the live smoke test.

test('paging: next and prev move the window; the footer reports the range', async ($, on) => {
  const world = XO_WORLD()
  const rows = Array.from({ length: 15 }, (_, i) => ({ id: `task-${1000 + i}`, state: 'working', title: `Task ${i}` }))
  world.status = () => ({ exitCode: 0, stdout: statusJson(rows), stderr: '' })
  const w = install(on, world)
  const panel = panelCommand($)
  await start($)
  await w.clock.settle()
  let ui = await mountPane($) // bodyRows 30 → capacity 12 → 2 pages
  expect(await ui.find({ type: 'Text', text: '1–12 of 15 · page 1/2' })).toBeDefined()
  await ui.unmount()
  await panel('next')
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: '13–15 of 15 · page 2/2' })).toBeDefined()
  await ui.unmount()
  await panel('prev')
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: '1–12 of 15 · page 1/2' })).toBeDefined()
  await ui.unmount()
})

test('renders width-safe at a narrow pane with a long Unicode title', async ($, on) => {
  const world = XO_WORLD()
  world.status = () => ({ exitCode: 0, stdout: statusJson([{ id: 'u-9z9z', state: 'decision', title: '長い👩🏽‍💻タイトル'.repeat(8) }]), stderr: '' })
  const w = install(on, world)
  await start($)
  await w.clock.settle()
  const ui = await mountPane($, 40)
  expect(await ui.find({ type: 'Text', text: /Chartroom · 1 unfinished/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'row-9z9z' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '/chartroom-panel next|prev|off' })).toBeDefined()
  await ui.unmount()
})

test('selection pre-fills /continue into an empty prompt; a draft is copied instead', async ($, on) => {
  const world = XO_WORLD()
  const w = install(on, world)
  await start($)
  await w.clock.settle()

  // Empty prompt: Enter on the row pre-fills /continue <short_id>, nothing submitted.
  let ui = await mountPane($)
  await ui.press({ key: 'row-108a' })
  expect(w.fills).toEqual(['/continue 108a'])
  await ui.unmount()
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: /\/continue 108a is in the prompt/ })).toBeDefined()
  await ui.unmount()

  // A draft in the prompt is never replaced: the line is copied instead.
  world.draft = 'half-written thought'
  ui = await mountPane($)
  await ui.press({ key: 'row-108a' })
  expect(w.fills).toEqual(['/continue 108a']) // no new fill
  expect(w.copies).toContain('/continue 108a')
  await ui.unmount()
})

test('pick <id> selects a task from the command line', async ($, on) => {
  const w = install(on, XO_WORLD())
  const panel = panelCommand($)
  await start($)
  await w.clock.settle()
  expect((await panel('pick 108a')).text).toBe('Chartroom panel: picked 108a.')
  expect(w.fills).toEqual(['/continue 108a'])
  expect((await panel('pick')).text).toMatch(/Usage/)
})

test('cleanup: session end cancels the timer, so no poll runs afterwards', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($)
  await w.clock.settle()
  const before = polls(w.runs)
  await $.session.end({ reason: 'other', sessionId: 'test-session', resume: { id: 'test-session' } })
  await w.clock.advance(30_000)
  expect(polls(w.runs)).toBe(before) // the timer is gone
})
