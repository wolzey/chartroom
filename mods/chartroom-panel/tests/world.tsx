// A fake world beneath chartroom-panel: env, files, the chartroom CLI and the clock. Generic
// paths only (HOME = /srv/xo), so nothing tracked carries a real machine's layout.
import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

export const HOME = '/srv/xo'

type Row = Record<string, unknown> & { id?: string; state: string; lane?: string }
type Ran = { exitCode: number; stdout: string; stderr: string }

const LANE_KEYS = ['needs_you', 'in_progress', 'on_hold', 'ready', 'recent']

/**
 * `chartroom board --json` output for `cards`: each goes in its `lane` (default needs_you), in the
 * order given, with an `id`, a `short_id` (the id's last 4) and the board's `reason` (default: the state).
 */
export function boardJson(cards: Row[]): string {
  const lanes: Record<string, unknown[]> = Object.fromEntries(LANE_KEYS.map(k => [k, []]))
  cards.forEach((r, i) => {
    const lane = r.lane ?? 'needs_you'
    lanes[lane]?.push({
      type: 'task',
      id: r.id ?? `${r.state}-${i}`,
      short_id: (r.id as string | undefined)?.slice(-4) ?? `t${i}`,
      title: 'A task',
      project: 'shop',
      reason: r.state,
      lane,
      ...r,
    })
  })
  return JSON.stringify({ lanes, counts: Object.fromEntries(LANE_KEYS.map(k => [k, lanes[k]?.length ?? 0])) })
}

export type World = {
  env: Record<string, string>
  /** Paths that `fs.exists` answers true for (commander.md marks the home). */
  files: Record<string, string>
  dirs: string[]
  /** What `chartroom doctor --json` reports as `.home`. */
  doctorHome: string
  /** What `chartroom board --json` prints; a Ran, or 'missing' for a command-not-found. */
  board: () => Ran | 'missing'
  /** What `chartroom close <full_id>` does; default success moves the task to Recently finished. */
  close: (fullId: string) => Ran
  /** What `chartroom accept <full_id>` does; default success moves a review task to Ready for you, done. */
  accept: (fullId: string) => Ran
  /** The prompt box's draft. */
  draft: string
  /** Command names a person's own command/skill already holds: registering one is refused. */
  taken: string[]
  /** The engine's open panes, newest shown; install keeps this in step with open/close. */
  panes: { id: string; title: string; isShown: boolean; isFocused: boolean; isPlaced: boolean }[]
}

export const XO_WORLD = (): World => {
  // The default board; a successful close or accept moves the card the way lanes.jq would.
  const base: Row[] = [{ id: 'auth-108a', state: 'decision', live: 'done', title: 'Auth' }]
  const move = (id: string, to: Partial<Row>) => {
    const i = base.findIndex(t => t.id === id)
    if (i >= 0) base[i] = { ...base[i], ...to } as Row
  }
  const world: World = {
    env: { HOME },
    files: { [`${HOME}/commander.md`]: '# commander\n' },
    dirs: [HOME],
    doctorHome: HOME,
    board: () => ({ exitCode: 0, stdout: boardJson(base), stderr: '' }),
    close: fullId => {
      move(fullId, { state: 'closed', lane: 'recent', reason: 'closed' })
      return { exitCode: 0, stdout: `closed ${fullId}`, stderr: '' }
    },
    accept: fullId => {
      move(fullId, { state: 'done', lane: 'ready', reason: 'accepted' })
      return { exitCode: 0, stdout: `accepted ${fullId}: done (chartroom close ${fullId} removes its worktree)`, stderr: '' }
    },
    draft: '',
    taken: [],
    panes: [],
  }
  return world
}

/**
 * Installs the world; returns the argv of every process run, the CHARTROOM_HOME each named, the
 * commands registered, the opens/closes, what went to the clipboard and the prompt, and the clock.
 */
export function install(on: On, world: World) {
  const runs: string[][] = []
  const homes: (string | undefined)[] = []
  const commands: string[] = []
  const opens: { id: string; focus?: true; backgroundColor?: string }[] = []
  const closes: string[] = []
  const copies: string[] = []
  const fills: string[] = []
  const submits: string[] = []
  const commandRuns: { command: string; args: string }[] = []
  const writes: { path: string; text: string }[] = []
  mock.env(on, world.env)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', () => ({ sessionId: 'test-session' }))
  on('skill.prompt', ($, e) => ({ text: e.text }))
  on('tool.call', () => ({ result: {} }))
  // The engine's own pane beneath the plugin: what a pass-through draws.
  on('ui.render', ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box key="engine">
        <Text>engine</Text>
      </Box>
    )
  })
  const clock = mock.clock(on, { now: Date.parse('2026-10-28T16:00:00Z') })
  on('fs.exists', ($, e) => ({ value: e.path in world.files || world.dirs.includes(e.path) }))
  on('fs.read', ($, e) => {
    const text = world.files[e.path]
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', ($, e) => {
    world.files[e.path] = e.text
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('fs.stat', ($, e) => ({
    value: { kind: world.dirs.includes(e.path) ? ('dir' as const) : ('file' as const), size: 0, mtimeMs: 0, isLink: false, realPath: e.path },
  }))
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    homes.push(e.init?.env?.CHARTROOM_HOME)
    const argv = e.argv
    const isChartroom = argv[0] === 'chartroom' || argv[0] === world.env.CHARTROOM_BIN || /chartroom$/.test(String(argv[0] ?? ''))
    if (!isChartroom) return { deny: `spawn ${argv[0]} ENOENT` }
    if (argv[1] === 'doctor') {
      return { value: { exitCode: 0, stdout: JSON.stringify({ home: world.doctorHome }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (argv[1] === 'board') {
      const out = world.board()
      if (out === 'missing') return { deny: 'spawn chartroom ENOENT' }
      return { value: { ...out, isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (argv[1] === 'close') {
      return { value: { ...world.close(argv[2] ?? ''), isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (argv[1] === 'accept') {
      return { value: { ...world.accept(argv[2] ?? ''), isStdoutTruncated: false, isStderrTruncated: false } }
    }
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', ($, e) => {
    opens.push({ id: e.id, focus: e.focus, backgroundColor: e.backgroundColor })
    const existing = world.panes.find(p => p.id === e.id)
    if (existing) {
      existing.isShown = true
      existing.isPlaced = true
      if (e.focus) existing.isFocused = true
    } else {
      world.panes.push({ id: e.id, title: e.title ?? e.id, isShown: true, isFocused: !!e.focus, isPlaced: true })
    }
    return { value: { isPlaced: true as const } }
  })
  on('ui.close', ($, e) => {
    closes.push(`${e.id}:${e.origin.kind}`)
    world.panes = world.panes.filter(p => p.id !== e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({ value: world.panes.map(p => ({ ...p })) }))
  on('ui.focus', () => ({}))
  on('ui.copy', ($, e) => {
    copies.push(e.text)
    return { value: { isCopied: true as const } }
  })
  on('prompt.read', () => ({ value: { text: world.draft, cursor: world.draft.length } }))
  on('prompt.fill', ($, e) => {
    fills.push(e.text)
    return { isFilled: true }
  })
  // NOTE: the kit rejects a plugin's in-handler $.prompt.submit (it would run as its own turn, once
  // idle), so this stub records a submit only when called from an idle context (e.g. the test's own
  // $). The Enter path's real submit is verified live; see report.md.
  on('prompt.submit', ($, e) => {
    submits.push(e.text)
    return { text: e.text }
  })
  on('command.register', ($, e) => {
    if (world.taken.includes(e.name)) return { deny: `"/${e.name}" refused: it is the user's /${e.name}` }
    commands.push(e.name)
    return { value: { command: e.name } }
  })
  // The bottom for slash commands the plugin runs (e.g. /continue). The plugin's own
  // /chartroom-panel hook answers above this without next, so it never reaches here.
  on('command.run', ($, e) => {
    commandRuns.push({ command: e.command, args: e.args })
    return { text: `ran /${e.command}` }
  })
  return { runs, homes, commands, commandRuns, opens, closes, copies, fills, submits, writes, clock }
}

/** Starts an interactive session at `cwd` (the home by default), as Claude Code does on launch. */
export async function start($: Engine, cwd = HOME, isInteractive = true) {
  return $.session.start({ cwd, surface: 'terminal', isInteractive })
}

/** Loads the XO skill (the chartroom/captain command, the Skill tool, a preload) — the auto-show trigger. */
export async function loadSkill($: Engine, skill = 'chartroom') {
  return $.skill.prompt({ skill, text: `the ${skill} skill` })
}

/** Submits a prompt as the composer does, filling the engine-set fields the kit's type requires. */
export async function submitPrompt($: Engine, text: string, command?: { name: string; args: string }) {
  return $.prompt.submit({ text, wait: false, origin: { kind: 'composer' }, ...(command ? { command } : {}) })
}

/** Starts a session and makes it the XO by loading the skill (how the panel normally comes up). */
export async function startXo($: Engine, cwd = HOME) {
  await start($, cwd)
  return loadSkill($)
}

/** Runs `/chartroom-panel <args>` as the composer does. */
export function panelCommand($: Engine) {
  return (args = '') => $.command.run({ command: 'chartroom-panel', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })
}

export const PANE_PROPS = (bodyColumns: number, over: { isFocused?: boolean; bodyRows?: number } = {}) => ({
  title: 'Chartroom',
  isFocused: over.isFocused ?? false,
  bodyColumns,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: over.bodyRows ?? 30 },
  view: {},
})
