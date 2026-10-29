// The live panel: intent-based auto-show (the XO skill, any directory), the timer poll,
// stale-on-error, on/off/toggle, paging, action keys, the durable default, and selection into the
// chat. Drives the mod through the test kit.
import { expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { HOME, PANE_PROPS, XO_WORLD, boardJson, install, loadSkill, panelCommand, start, startXo, submitPrompt } from './world'

const mountPane = ($: Engine, width = 90, over = {}) =>
  $.ui.mount({ plugin: 'chartroom-panel', surface: 'terminal', component: 'Pane', requestId: 'chartroom-panel', props: PANE_PROPS(width, over) })

const polls = (runs: string[][]) => runs.filter(r => r[1] === 'board').length

test('auto-shows when the XO skill loads — in any directory, not tied to the home', async ($, on) => {
  const w = install(on, XO_WORLD())
  // The commander runs the XO from a project repo, not the home.
  await start($, '/srv/project-repo')
  await w.clock.settle()
  expect(w.opens).toEqual([]) // session start alone does not auto-show
  expect(w.commands).toEqual(['chartroom-panel']) // the command is registered though

  await loadSkill($, 'chartroom') // becoming the XO is the trigger
  await w.clock.settle()
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel'])
  expect(w.opens[0]?.focus).toBeUndefined() // auto-show never grabs the keyboard
  expect(w.opens[0]?.backgroundColor).toBe('transparent') // blends with the chat
  // The board still reads the resolved home (via chartroom doctor), though the cwd was a project repo.
  const statusHomes = w.runs.map((r, i) => (r[1] === 'board' ? w.homes[i] : null)).filter(h => h !== null)
  expect(statusHomes.length).toBeGreaterThan(0)
  expect(statusHomes.every(h => h === HOME)).toBe(true)

  const ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: /^Chartroom · 1 need you/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Live · updated / })).toBeDefined()
  // The board's five lanes, its names and order, every one with its count (empty ones too).
  for (const lane of ['Needs you (1)', 'In progress (0)', 'On hold (0)', 'Ready for you (0)', 'Recently finished (0)']) {
    expect(await ui.find({ type: 'Text', text: lane })).toBeDefined()
  }
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /decision · shop/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '/chartroom-panel next|prev|off' })).toBeDefined()
  await ui.unmount()
})

test('the legacy captain skill also triggers auto-show', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, '/srv/another-repo')
  await loadSkill($, 'captain')
  await w.clock.settle()
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel'])
})

test('prompt-submitting /chartroom auto-shows even when skill.prompt is preempted by another plugin', async ($, on) => {
  // The real bug: a builtin plugin's skill.prompt handler runs first and sends the event past ours.
  // Here skill.prompt is never delivered to us; the submitted slash command still triggers auto-show.
  const w = install(on, XO_WORLD())
  await start($, '/srv/project-repo')
  await w.clock.settle()
  expect(w.opens).toEqual([])
  await submitPrompt($, '/chartroom')
  await w.clock.settle()
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel'])
})

test('the Skill tool loading chartroom auto-shows the panel', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, '/srv/project-repo')
  await w.clock.settle()
  await $.tool.call({ tool: 'Skill', skill: 'chartroom' })
  await w.clock.settle()
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel'])
})

test('dedupe: several XO triggers for one invocation auto-show the panel exactly once', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, '/srv/project-repo')
  await w.clock.settle()
  await loadSkill($) // skill.prompt
  await submitPrompt($, '/chartroom') // prompt.submit
  await $.tool.call({ tool: 'Skill', skill: 'chartroom' }) // Skill tool
  await w.clock.settle()
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel']) // one open, one pane
})

test('an ordinary prompt submit (or /continue) does not auto-show the panel', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, '/srv/project-repo')
  await w.clock.settle()
  await submitPrompt($, 'just a normal message')
  await submitPrompt($, '/continue 108a') // not an XO skill
  await w.clock.settle()
  expect(w.opens).toEqual([])
})

test('inert in a crew worktree even when the XO skill loads', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, `${HOME}/worktrees/shop/task-abcd`)
  await loadSkill($)
  await w.clock.settle()
  expect(w.opens).toEqual([]) // never auto-shows in a worker
  expect(w.commands).toEqual([]) // not even the command
  expect(polls(w.runs)).toBe(0)
})

test('inert in a crew-worker session (CHARTROOM_TASK set) even when the skill loads', async ($, on) => {
  const world = XO_WORLD()
  world.env = { ...world.env, CHARTROOM_TASK: 'some-task-1234' }
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  expect(w.opens).toEqual([])
  expect(w.commands).toEqual([])
  expect(polls(w.runs)).toBe(0)
})

test('a non-interactive (-p) run registers no command, opens no pane and never polls', async ($, on) => {
  const w = install(on, XO_WORLD())
  await start($, HOME, false)
  await loadSkill($)
  await w.clock.settle()
  expect(w.commands).toEqual([])
  expect(w.opens).toEqual([])
  expect(polls(w.runs)).toBe(0)
})

test('the board decides the lanes: working, then review in Needs you, then accepted in Ready for you', async ($, on) => {
  const world = XO_WORLD()
  const at = (card: { state: string; lane: string; reason: string }) => () => ({ exitCode: 0, stdout: boardJson([{ id: 'auth-108a', title: 'Auth', ...card }]), stderr: '' })
  world.board = at({ state: 'working', lane: 'in_progress', reason: 'running' })
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  let ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: 'In progress (1)' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /running · shop/ })).toBeDefined()
  await ui.unmount()

  // The worker reports done: the board has it in Needs you, awaiting the commander's review.
  world.board = at({ state: 'review', lane: 'needs_you', reason: 'PR to review' })
  await w.clock.advance(5_000)
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: 'Needs you (1)' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /PR to review · shop/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /1 need you/ })).toBeDefined()
  await ui.unmount()

  // Accepted: the board moves it to Ready for you; the panel follows, with no rule of its own.
  world.board = at({ state: 'done', lane: 'ready', reason: 'accepted' })
  await w.clock.advance(5_000)
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: 'Ready for you (1)' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /accepted · shop/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /0 need you/ })).toBeDefined()
  await ui.unmount()
})

test('inbox items and held cards show as the board shows them', async ($, on) => {
  const world = XO_WORLD()
  world.board = () => ({
    exitCode: 0,
    stdout: boardJson([
      { id: 'inbox-0', type: 'inbox', short_id: 'i-7f3a', state: 'inbox', reason: 'waiting on you (inbox)', title: 'which region?', project: null },
      { id: 'pay-21ba', state: 'blocked', held: true, project: 'billing' },
    ]),
    stderr: '',
  })
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 90, { isFocused: true })
  expect(await ui.find({ type: 'Text', text: 'Needs you (2, 1 held)' })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'row-i-7f3a' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /waiting on you \(inbox\)/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /blocked · held · billing/ })).toBeDefined()
  // an inbox item is not a task: close/complete refuse it and run nothing
  await ui.press({ key: 'act-close' })
  expect(await ui.find({ type: 'Text', text: /i-7f3a is an inbox item, not a task/ })).toBeDefined()
  expect(w.runs.some(r => r[1] === 'close' || r[1] === 'accept')).toBe(false)
  await ui.unmount()
})

test('a refresh failure keeps the last known tasks, shown STALE — never an empty fleet', async ($, on) => {
  const world = XO_WORLD()
  world.board = () => ({ exitCode: 0, stdout: boardJson([{ id: 'auth-108a', state: 'blocked', title: 'Auth' }]), stderr: '' })
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()

  world.board = () => 'missing' // chartroom vanishes
  await w.clock.advance(5_000)
  let ui = await mountPane($)
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined() // stale row still shown
  expect(await ui.find({ type: 'Text', text: /^STALE:/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /1 need you/ })).toBeDefined()
  await ui.unmount()

  world.board = () => ({ exitCode: 0, stdout: '{ not json', stderr: '' }) // malformed
  await w.clock.advance(5_000)
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: /STALE: malformed board JSON/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined()
  await ui.unmount()
})

test('off stops the refresh work and closes the pane; on brings it back', async ($, on) => {
  const w = install(on, XO_WORLD())
  const panel = panelCommand($)
  await startXo($)
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
  await startXo($) // auto-shown
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
  const rows = Array.from({ length: 15 }, (_, i) => ({ id: `task-${1000 + i}`, state: 'working', lane: 'in_progress', title: `Task ${i}` }))
  world.board = () => ({ exitCode: 0, stdout: boardJson(rows), stderr: '' })
  const w = install(on, world)
  const panel = panelCommand($)
  await startXo($)
  await w.clock.settle()
  let ui = await mountPane($) // bodyRows 30 → capacity 9 (after the chrome and 5 lane headers) → 2 pages
  expect(await ui.find({ type: 'Text', text: '1–9 of 15 · page 1/2' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'In progress (15)' })).toBeDefined() // the count is the lane's, not the page's
  await ui.unmount()
  await panel('next')
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: '10–15 of 15 · page 2/2' })).toBeDefined()
  await ui.unmount()
  await panel('prev')
  ui = await mountPane($)
  expect(await ui.find({ type: 'Text', text: '1–9 of 15 · page 1/2' })).toBeDefined()
  await ui.unmount()
})

test('renders width-safe at a narrow pane with a long Unicode title', async ($, on) => {
  const world = XO_WORLD()
  world.board = () => ({ exitCode: 0, stdout: boardJson([{ id: 'u-9z9z', state: 'decision', title: '長い👩🏽‍💻タイトル'.repeat(8) }]), stderr: '' })
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 40)
  expect(await ui.find({ type: 'Text', text: /Chartroom · 1 need you/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'row-9z9z' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '/chartroom-panel next|prev|off' })).toBeDefined()
  await ui.unmount()
})

test('Enter RUNS /continue for the highlighted task via command.run (not a text submit); no fill, no copy', async ($, on) => {
  // Enter dispatches `/continue <id>` with $.command.run (runs the command as if typed), which
  // actually starts the continue turn — unlike $.prompt.submit, which only submitted the text and
  // showed a false "sent". It never touches the composer. (command.run, like any queued-till-idle
  // call, isn't dispatched by the kit mid-handler, so the turn running is verified live; here we
  // assert the observable contract and that the notice is the honest "running …", never "sent".)
  const w = install(on, XO_WORLD())
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($)
  await ui.press({ key: 'row-108a' })
  await w.clock.settle()
  expect(w.fills).toEqual([]) // the composer is never written (no fill)
  expect(w.copies).toEqual([]) // nothing copied to the clipboard
  expect(w.submits).toEqual([]) // no text submit — the old broken path is gone
  expect(await ui.find({ type: 'Text', text: /copied|paste|sent/i })).toBeUndefined() // no false success / stale guidance
  expect(await ui.find({ type: 'Text', text: /running \/continue 108a/ })).toBeDefined()
  await ui.unmount()
})

test('Enter never touches a draft in the composer (fire-and-forget submit)', async ($, on) => {
  const world = XO_WORLD()
  world.draft = 'half-written thought'
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($)
  await ui.press({ key: 'row-108a' })
  await w.clock.settle()
  expect(w.fills).toEqual([]) // the composer is never written, so the draft is safe
  expect(w.copies).toEqual([])
  await ui.unmount()
})

test('pick <id> brings a task in via /continue (usage on a bare pick)', async ($, on) => {
  const w = install(on, XO_WORLD())
  const panel = panelCommand($)
  await start($) // pick activates on demand; no skill needed
  await w.clock.settle()
  expect((await panel('pick 108a')).text).toBe('Chartroom panel: picked 108a.')
  expect(w.fills).toEqual([]) // submits (live), never fills
  expect((await panel('pick')).text).toMatch(/Usage/)
})

test('c: two-press confirm closes the highlighted task (one press only arms); it moves to Recently finished', async ($, on) => {
  const w = install(on, XO_WORLD())
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 90, { isFocused: true })
  // first c: arms with an inline confirm, runs no close, the task stays
  await ui.press({ key: 'act-close' })
  expect(await ui.find({ type: 'Text', text: /Close 108a\? press c again to confirm/ })).toBeDefined()
  expect(w.runs.some(r => r[1] === 'close')).toBe(false)
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined()
  // second c: runs chartroom close auth-108a (the FULL id, keeping the branch, no --discard)
  await ui.press({ key: 'act-close' })
  const closeRuns = w.runs.filter(r => r[1] === 'close')
  expect(closeRuns.map(r => r.slice(1))).toEqual([['close', 'auth-108a']])
  // the re-poll shows it where the board now puts it
  expect(await ui.find({ type: 'Text', text: 'Recently finished (1)' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /closed · shop/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /0 need you/ })).toBeDefined()
  // a closed task cannot be closed again from the pane
  await ui.press({ key: 'act-close' })
  expect(await ui.find({ type: 'Text', text: /108a is already closed/ })).toBeDefined()
  expect(w.runs.filter(r => r[1] === 'close').length).toBe(1)
  await ui.unmount()
})

test('a: complete is a two-press chartroom accept; the task moves to Ready for you', async ($, on) => {
  const world = XO_WORLD()
  world.board = (() => {
    let state = { state: 'review', lane: 'needs_you', reason: 'report to read' }
    world.accept = id => {
      state = { state: 'done', lane: 'ready', reason: 'accepted' }
      return { exitCode: 0, stdout: `accepted ${id}: done (chartroom close ${id} removes its worktree)`, stderr: '' }
    }
    return () => ({ exitCode: 0, stdout: boardJson([{ id: 'auth-108a', title: 'Auth', ...state }]), stderr: '' })
  })()
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 120, { isFocused: true })
  await ui.press({ key: 'act-complete' }) // arm
  expect(await ui.find({ type: 'Text', text: /Complete 108a \(accept it as done\)\? press a again to confirm/ })).toBeDefined()
  expect(w.runs.some(r => r[1] === 'accept')).toBe(false)
  // c on the same row arms close instead: one arm at a time, the confirm needs the same key
  await ui.press({ key: 'act-close' })
  expect(await ui.find({ type: 'Text', text: /Close 108a\?/ })).toBeDefined()
  await ui.press({ key: 'act-complete' }) // re-arm complete
  await ui.press({ key: 'act-complete' }) // confirm
  expect(w.runs.filter(r => r[1] === 'accept').map(r => r.slice(1))).toEqual([['accept', 'auth-108a']]) // the FULL id
  expect(w.runs.some(r => r[1] === 'close')).toBe(false)
  expect(await ui.find({ type: 'Text', text: /accepted auth-108a: done/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Ready for you (1)' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /accepted · shop/ })).toBeDefined()
  await ui.unmount()
})

test('a: a chartroom accept refusal (not in review) is surfaced verbatim', async ($, on) => {
  const world = XO_WORLD()
  world.accept = id => ({ exitCode: 1, stdout: '', stderr: `chartroom: ${id} is decision, not awaiting review: accept marks a worker's finished work done` })
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 160, { isFocused: true })
  await ui.press({ key: 'act-complete' })
  await ui.press({ key: 'act-complete' })
  expect(await ui.find({ type: 'Text', text: /auth-108a is decision, not awaiting review/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Needs you (1)' })).toBeDefined()
  await ui.unmount()
})

test('c: a chartroom close refusal is surfaced verbatim and the task stays', async ($, on) => {
  const world = XO_WORLD()
  world.close = () => ({ exitCode: 1, stdout: '', stderr: 'chartroom: refusing to close: uncommitted work in the worktree' })
  const w = install(on, world)
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 120, { isFocused: true })
  await ui.press({ key: 'act-close' }) // arm
  await ui.press({ key: 'act-close' }) // confirm → refused
  expect(await ui.find({ type: 'Text', text: /refusing to close: uncommitted work in the worktree/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'row-108a' })).toBeDefined() // not closed
  await ui.unmount()
})

test('s: pre-fills a non-mutating recap request for the highlighted task', async ($, on) => {
  const w = install(on, XO_WORLD())
  await startXo($)
  await w.clock.settle()
  const ui = await mountPane($, 90, { isFocused: true })
  await ui.press({ key: 'act-recap' })
  expect(w.fills).toContain("Recap 108a (Auth): where it stands and what's pending")
  expect(w.runs.some(r => r[1] === 'close')).toBe(false) // never mutates
  await ui.unmount()
})

test('action keys exist only when focused; the footer shows how to get in and act (both states)', async ($, on) => {
  const w = install(on, XO_WORLD())
  await startXo($)
  await w.clock.settle()
  // Unfocused: no action Buttons (keys inert), and the footer says how to get in.
  let ui = await mountPane($, 90, { isFocused: false })
  expect(await ui.find({ type: 'Button', key: 'act-complete' })).toBeUndefined()
  expect(await ui.find({ type: 'Button', key: 'act-close' })).toBeUndefined()
  expect(await ui.find({ type: 'Button', key: 'act-recap' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /Ctrl\+X Tab to select/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '/chartroom-panel next|prev|off' })).toBeDefined()
  await ui.unmount()
  // Focused: the action Buttons carry their single-letter hotkeys, and the legend lists them.
  ui = await mountPane($, 90, { isFocused: true })
  const a = await ui.find({ type: 'Button', key: 'act-complete' })
  const c = await ui.find({ type: 'Button', key: 'act-close' })
  const s = await ui.find({ type: 'Button', key: 'act-recap' })
  expect([a?.props.hotkey, a?.props.label]).toEqual(['a', 'complete'])
  expect([c?.props.hotkey, c?.props.label]).toEqual(['c', 'close'])
  expect([s?.props.hotkey, s?.props.label]).toEqual(['s', 'recap'])
  expect(await ui.find({ type: 'Text', text: /↑↓ move · Enter \/continue · Esc chat/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Ctrl\+X Tab to select/ })).toBeUndefined()
  await ui.unmount()
})

test('durable default off: the XO skill does not auto-show, but /chartroom-panel on still opens it', async ($, on) => {
  const world = XO_WORLD()
  world.files[`${HOME}/panel.conf`] = 'autoshow=off\n' // the home's durable setting
  const w = install(on, world)
  const panel = panelCommand($)
  await startXo($) // loads the skill, but the default is off
  await w.clock.settle()
  expect(w.opens).toEqual([]) // config off → no auto-show
  expect(w.commands).toEqual(['chartroom-panel']) // but the command is still there
  expect(polls(w.runs)).toBe(0) // and nothing polls until it is opened
  expect((await panel('on')).text).toMatch(/on\.?$/) // manual on works despite the default
  expect(w.opens.map(o => o.id)).toEqual(['chartroom-panel'])
})

test('precedence: a session on overrides a durable default off for that session', async ($, on) => {
  const world = XO_WORLD()
  world.files[`${HOME}/panel.conf`] = 'autoshow=off\n'
  const w = install(on, world)
  const panel = panelCommand($)
  await startXo($)
  await w.clock.settle()
  expect(w.opens).toEqual([]) // default off wins at startup
  await panel('on') // session action overrides
  await w.clock.advance(5_000)
  expect(polls(w.runs)).toBeGreaterThan(0) // now it polls for the session
})

test('default on|off writes the durable home config; default with no arg reports it', async ($, on) => {
  const w = install(on, XO_WORLD()) // no panel.conf → default on
  const panel = panelCommand($)
  await start($)
  await w.clock.settle()
  const off = await panel('default off')
  expect(off.text).toMatch(/default set to off/)
  expect(w.writes.some(x => x.path === `${HOME}/panel.conf` && /autoshow=off/.test(x.text))).toBe(true)
  expect((await panel('default')).text).toMatch(/Auto-show default is off/) // reports current
  await panel('default on')
  expect(w.writes.at(-1)?.text).toMatch(/autoshow=on/)
  expect((await panel('default')).text).toMatch(/Auto-show default is on/)
})

test('cleanup: session end cancels the timer, so no poll runs afterwards', async ($, on) => {
  const w = install(on, XO_WORLD())
  await startXo($)
  await w.clock.settle()
  const before = polls(w.runs)
  await $.session.end({ reason: 'other', sessionId: 'test-session', resume: { id: 'test-session' } })
  await w.clock.advance(30_000)
  expect(polls(w.runs)).toBe(before) // the timer is gone
})
