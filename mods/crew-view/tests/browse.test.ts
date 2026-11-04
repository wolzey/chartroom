// The /crew pane as a browser: rows open an item's detail, and its actions continue, copy
// and read the report.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { detailActions, detailLines, parseDetail } from '../hooks/crew'
import { HOME, PANE_PROPS, STAMP, XO_WORLD, install, showJson, startXo } from './world'
import type { World } from './world'

const NOW = Date.parse('2026-10-12T15:12:30Z')
const REPORT = `${HOME}/.chartroom/tasks/auth-project-manager-108a/report.md`

/** The XO with the skill loaded and the board read; the pane mounted. */
async function pane($: Engine, on: Parameters<typeof install>[0], world: World = XO_WORLD()) {
  const w = install(on, world)
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  await startXo($)
  await w.clock.settle()
  const ui = await $.ui.mount({ plugin: 'crew-view', surface: 'terminal', component: 'Pane', requestId: 'crew', props: PANE_PROPS(90) })
  return { w, ui }
}

test('a row opens its item: chartroom show runs and the detail draws; back returns to the lanes', async ($, on) => {
  const { w, ui } = await pane($, on)
  expect(await ui.find({ type: 'Button', key: 'row-4d10' })).toBeDefined()
  await ui.press({ key: 'row-108a' })
  expect(w.runs).toContainEqual(['chartroom', 'show', '108a', '--json'])
  expect(await ui.find({ type: 'Text', text: '108a  [shop] Auth project-manager' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '🙋 decision · needs you · live running · herdr:claude' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '  Make login use passkeys.' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}12m decision: pick A or B \(recommend A\)$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: `REPORT  ${REPORT}` })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '  herdr tab w1:t2 · chartroom attach auth-project-manager-108a' })).toBeDefined()
  const buttons = (await ui.findAll({ type: 'Button' })).map(b => [b.key, b.props.hotkey ?? null])
  expect(buttons).toEqual([
    ['act-close', 'q'],
    ['act-continue', 'c'],
    ['act-copy-id', 'y'],
    ['act-copy-pr', 'p'],
    ['act-report', 'r'],
    ['act-back', 'b'],
    ['pr-0', null],
  ])
  await ui.press({ key: 'act-back' })
  expect(await ui.find({ key: 'row-108a' })).toBeDefined()
  expect(await ui.find({ key: 'act-back' })).toBeUndefined()
})

test('an open detail follows the board while the pane is open, and rests once it closes', async ($, on) => {
  let open = true
  on('ui.panes', () => ({ value: open ? [{ id: 'crew', title: 'Crew', isShown: true, isFocused: true, isPlaced: true }] : [] }))
  const world = XO_WORLD()
  world.mtimes[STAMP] = 1
  const { w, ui } = await pane($, on, world)
  await ui.press({ key: 'row-108a' })
  const shows = () => w.runs.filter(r => r[1] === 'show').length
  expect(shows()).toBe(1)
  world.mtimes[STAMP] = 2
  await w.clock.advance(15_000)
  expect(shows()).toBe(2)
  open = false
  world.mtimes[STAMP] = 3
  await w.clock.advance(15_000)
  expect(shows()).toBe(2)
})

test('continue puts /continue <id> in an empty prompt; a draft is kept and the line copied', async ($, on) => {
  const world = XO_WORLD()
  const { w, ui } = await pane($, on, world)
  await ui.press({ key: 'row-108a' })
  await ui.press({ key: 'act-continue' })
  expect(w.fills).toEqual(['/continue 108a'])
  expect(await ui.find({ type: 'Text', text: '/continue 108a is in the prompt: press Enter to run it' })).toBeDefined()
  world.draft = 'half a thought'
  await ui.press({ key: 'act-continue' })
  expect(w.fills).toEqual(['/continue 108a'])
  expect(w.copies).toEqual(['/continue 108a'])
  expect(await ui.find({ type: 'Text', text: '/continue 108a copied (the prompt holds a draft, kept): paste it at the prompt' })).toBeDefined()
})

test('copy the id, a PR and an artifact; read the report and come back', async ($, on) => {
  const world = XO_WORLD()
  world.show = () => ({ exitCode: 0, stdout: showJson({ artifacts: [{ ref: '108a/note-for-chris', title: 'Note for Chris', kind: 'message' }] }), stderr: '' })
  world.files[REPORT] = '# Report\n\n## Outcome\n\nPR 7 is open.\n'
  const { w, ui } = await pane($, on, world)
  await ui.press({ key: 'row-108a' })
  await ui.press({ key: 'act-copy-id' })
  await ui.press({ key: 'act-copy-pr' })
  await ui.press({ key: 'artifact-0' })
  expect(w.runs).toContainEqual(['chartroom', 'artifact', 'show', '108a/note-for-chris'])
  expect(w.copies).toEqual(['108a', 'https://github.com/acme/shop/pull/7', 'the text of 108a/note-for-chris\n'])
  expect(await ui.find({ type: 'Text', text: 'copied artifact 108a/note-for-chris' })).toBeDefined()
  await ui.press({ key: 'act-report' })
  expect((await ui.find({ type: 'Markdown' }))?.props.text).toBe('# Report\n\n## Outcome\n\nPR 7 is open.\n')
  await ui.press({ key: 'act-back' })
  expect(await ui.find({ key: 'act-report' })).toBeDefined()
})

test('/crew <id> opens that item; an id chartroom does not know says why', async ($, on) => {
  const { ui } = await pane($, on)
  const run = (args: string) => $.command.run({ command: 'crew', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })
  await run('108a')
  expect(await ui.find({ type: 'Text', text: '108a  [shop] Auth project-manager' })).toBeDefined()
  await run('zzzz')
  expect(await ui.find({ type: 'Text', text: "zzzz · chartroom show failed: unknown id 'zzzz'" })).toBeDefined()
})

test('an inbox item: its question in full, no worker, continue and copy id only', () => {
  const parsed = parseDetail(showJson({
    type: 'inbox', id: 'inbox-0', short_id: 'i-7f3a', project: null, title: 'Waiting on legal', text: 'Waiting on legal', date: '2026-10-12',
    state: 'inbox', reason: 'waiting on you (inbox)', prs: [], intent: null, events: [], report: null, attach: null, worktree: null,
  }))
  if ('error' in parsed) throw new Error(parsed.error)
  const lines = detailLines(parsed.detail, 60, NOW).map(l => l.text)
  expect(lines).toEqual(['i-7f3a  [inbox] Waiting on legal', '🙋 inbox · waiting on you (inbox) · needs you', 'since 2026-10-12', 'QUESTION', '  Waiting on legal'])
  expect(detailActions('i-7f3a', parsed.detail).map(a => a.id)).toEqual(['continue', 'copy-id', 'back'])
})
