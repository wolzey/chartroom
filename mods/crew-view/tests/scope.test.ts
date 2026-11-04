// Scoping: the mod is installed at user scope, so it must be inert in workers, and inert in the
// XO's own session until the captain or chartroom skill is loaded there.
import { expect, test } from 'claude-code/testing'

import { homeEntries, homesPath, resolveHome } from '../hooks/crew'
import { BAND_PROPS, HOME, STAMP, XO_WORLD, install, startXo } from './world'

const XO = `${HOME}/.captain`

for (const skill of ['captain', 'chartroom', 'chartroom:captain']) {
  test(`the XO session wakes when it loads ${skill}: registers /crew and /todo, polls, polls again on a change`, async ($, on) => {
    const world = XO_WORLD()
    world.mtimes[STAMP] = 1
    const w = install(on, world)
    const expanded = await startXo($, XO, skill)
    expect(expanded.text).toBe(`the ${skill} skill`)
    await w.clock.settle()
    expect(w.commands).toEqual(['crew', 'todo'])
    expect(w.runs).toEqual([['chartroom', 'board', '--json']])
    world.mtimes[STAMP] = 2
    await w.clock.advance(15_000)
    expect(w.runs).toHaveLength(2)
    const ui = await $.ui.mount({ plugin: 'crew-view', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS(100) })
    expect(await ui.find({ key: 'open' })).toBeDefined()
  })
}

test('the XO session stays inert until the skill loads: no command, no process, no timer, no band', async ($, on) => {
  const w = install(on, XO_WORLD())
  await $.session.start({ cwd: XO, surface: 'terminal', isInteractive: true })
  await $.skill.prompt({ skill: 'commit', text: 'another skill' })
  await w.clock.advance(60_000)
  expect(w.commands).toEqual([])
  expect(w.runs).toEqual([])
  for (const component of ['AbovePrompt', 'Pane'] as const) {
    const ui = await $.ui.mount({ plugin: 'crew-view', surface: 'terminal', component, requestId: 'crew', props: BAND_PROPS(100) as never })
    expect(await ui.find({ key: 'engine' })).toBeDefined()
    expect(await ui.find({ key: 'open' })).toBeUndefined()
    await ui.unmount()
  }
})

test('loading the skill twice starts one poll, not two', async ($, on) => {
  const world = XO_WORLD()
  world.mtimes[STAMP] = 1
  const w = install(on, world)
  await startXo($)
  await $.skill.prompt({ skill: 'chartroom', text: 'again' })
  await w.clock.settle()
  expect(w.commands).toEqual(['crew', 'todo'])
  world.mtimes[STAMP] = 2
  await w.clock.advance(15_000)
  expect(w.runs).toHaveLength(2)
})

test('a session whose state already says active (a hot reload) wakes at session.start', async ($, on) => {
  const w = install(on, XO_WORLD())
  on('state.get', ($, e, next) => (e.plugin === 'crew-view' && e.key === 'active' ? { value: { value: true, version: 1 } } : next(e)))
  await $.session.start({ cwd: XO, surface: 'terminal', isInteractive: true })
  await w.clock.settle()
  expect(w.commands).toEqual(['crew', 'todo'])
  expect(w.runs).toEqual([['chartroom', 'board', '--json']])
})

for (const [name, cwd, isInteractive, env] of [
  ['a crew worker in a worktree', `${XO}/worktrees/chartroom/x-98e2`, true, {}],
  ['a crew worker in its project checkout', `${HOME}/code/shop`, true, {}],
  ['a headless claude -p worker in the home', XO, false, {}],
  ['a task session (CHARTROOM_TASK set) in the home', XO, true, { CHARTROOM_TASK: 'x-98e2' }],
  ['a session in the default home when the config names another', `${HOME}/.chartroom`, true, {}],
] as const) {
  test(`inert in ${name}, even after the skill loads: no command, no process, no timer, no band`, async ($, on) => {
    const world = XO_WORLD()
    world.env = { ...world.env, ...env }
    world.dirs.push(`${HOME}/.chartroom`)
    const w = install(on, world)
    await $.session.start({ cwd, surface: 'terminal', isInteractive })
    for (const skill of ['captain', 'chartroom']) await $.skill.prompt({ skill, text: 'x' })
    await w.clock.advance(60_000)
    expect(w.commands).toEqual([])
    expect(w.runs).toEqual([])
    const ui = await $.ui.mount({ plugin: 'crew-view', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS(100) })
    expect(await ui.find({ key: 'engine' })).toBeDefined()
    expect(await ui.find({ key: 'open' })).toBeUndefined()
  })
}

test('CHARTROOM_HOME in the environment wins over the config file', async ($, on) => {
  const world = XO_WORLD()
  world.env = { ...world.env, CHARTROOM_HOME: '/srv/crew' }
  const w = install(on, world)
  await startXo($, '/srv/crew')
  expect(w.commands).toEqual(['crew', 'todo'])
})

test('with no config file, a pre-existing ~/.captain (and no ~/.chartroom) is the home', async ($, on) => {
  const world = XO_WORLD()
  world.files = {}
  const w = install(on, world)
  await startXo($, XO)
  expect(w.commands).toEqual(['crew', 'todo'])
})

// Several homes on one machine: a session started in a registered home's directory is that
// home's XO without CHARTROOM_HOME, as the CLI resolves it (lib/core.sh resolve_home).
const ACME = `${HOME}/chartroom/acme`
const HOMES = `# homes\nacme=~/chartroom/acme\nglobex = "${HOME}/chartroom/globex/"\n`

test('a session in a registered home wakes as that home, and names it to every chartroom run', async ($, on) => {
  const world = XO_WORLD()
  world.files[`${HOME}/.config/chartroom/homes`] = HOMES
  world.dirs.push(ACME)
  const w = install(on, world)
  await startXo($, ACME, 'chartroom')
  await w.clock.settle()
  expect(w.commands).toEqual(['crew', 'todo'])
  expect(w.runs).toEqual([['chartroom', 'board', '--json']])
  expect(w.homes).toEqual([ACME])
})

for (const [name, cwd] of [
  ['a worker in a registered home\'s worktree', `${ACME}/worktrees/shop/x-98e2`],
  ['a session in a subdirectory of a registered home', `${ACME}/tasks`],
] as const) {
  test(`inert in ${name}, even after the skill loads`, async ($, on) => {
    const world = XO_WORLD()
    world.files[`${HOME}/.config/chartroom/homes`] = HOMES
    const w = install(on, world)
    await $.session.start({ cwd, surface: 'terminal', isInteractive: true })
    await $.skill.prompt({ skill: 'chartroom', text: 'x' })
    await w.clock.advance(60_000)
    expect(w.commands).toEqual([])
    expect(w.runs).toEqual([])
  })
}

test('resolveHome: env first, then the registered home the directory is or lies in, then the config file', () => {
  const base = { home: HOME, configText: 'CHARTROOM_HOME=~/.captain\n', homesText: HOMES, hasChartroomDir: false, hasCaptainDir: true }
  expect(resolveHome({ ...base, cwd: ACME })).toBe(ACME)
  expect(resolveHome({ ...base, cwd: `${ACME}/tasks/x` })).toBe(ACME)
  expect(resolveHome({ ...base, cwd: `${HOME}/chartroom/globex` })).toBe(`${HOME}/chartroom/globex`)
  expect(resolveHome({ ...base, cwd: `${HOME}/chartroom/acme-two` })).toBe(`${HOME}/.captain`)
  expect(resolveHome({ ...base, cwd: ACME, chartroomHome: '/elsewhere' })).toBe('/elsewhere')
  expect(resolveHome({ ...base, cwd: ACME, homesText: undefined })).toBe(`${HOME}/.captain`)
  expect(homesPath(`${HOME}/.config/chartroom/config`)).toBe(`${HOME}/.config/chartroom/homes`)
  expect(homeEntries('a=~/x\na=/y\n# c=/z\nB=/w\n', HOME)).toEqual([{ name: 'a', path: '/y' }])
})
