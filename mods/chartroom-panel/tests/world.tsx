// A fake world beneath chartroom-panel: env, files, the chartroom CLI and the clock. Generic
// paths only (HOME = /srv/xo), so nothing tracked carries a real machine's layout.
import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

export const HOME = '/srv/xo'

type Row = Record<string, unknown> & { id?: string; state: string }
type Ran = { exitCode: number; stdout: string; stderr: string }

/** `chartroom status --json` output for `rows`; each row gets an `id` and a `short_id` if absent. */
export function statusJson(rows: Row[]): string {
  return JSON.stringify(
    rows.map((r, i) => ({
      id: r.id ?? `${r.state}-${i}`,
      short_id: (r.id as string | undefined)?.slice(-4) ?? `t${i}`,
      title: 'A task',
      project: 'shop',
      kind: 'ship',
      live: 'running',
      ...r,
    })),
  )
}

export type World = {
  env: Record<string, string>
  /** Paths that `fs.exists` answers true for (commander.md marks the home). */
  files: Record<string, string>
  dirs: string[]
  /** What `chartroom doctor --json` reports as `.home`. */
  doctorHome: string
  /** What `chartroom status --json` prints; a Ran, or 'missing' for a command-not-found. */
  status: () => Ran | 'missing'
  /** The prompt box's draft. */
  draft: string
  /** Command names a person's own command/skill already holds: registering one is refused. */
  taken: string[]
  /** The engine's open panes, newest shown; install keeps this in step with open/close. */
  panes: { id: string; title: string; isShown: boolean; isFocused: boolean; isPlaced: boolean }[]
}

export const XO_WORLD = (): World => ({
  env: { HOME },
  files: { [`${HOME}/commander.md`]: '# commander\n' },
  dirs: [HOME],
  doctorHome: HOME,
  status: () => ({ exitCode: 0, stdout: statusJson([{ id: 'auth-108a', state: 'decision', live: 'done', title: 'Auth' }]), stderr: '' }),
  draft: '',
  taken: [],
  panes: [],
})

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
  mock.env(on, world.env)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', () => ({ sessionId: 'test-session' }))
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
    if (argv[1] === 'status') {
      const out = world.status()
      if (out === 'missing') return { deny: 'spawn chartroom ENOENT' }
      return { value: { ...out, isStdoutTruncated: false, isStderrTruncated: false } }
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
  on('command.register', ($, e) => {
    if (world.taken.includes(e.name)) return { deny: `"/${e.name}" refused: it is the user's /${e.name}` }
    commands.push(e.name)
    return { value: { command: e.name } }
  })
  return { runs, homes, commands, opens, closes, copies, fills, clock }
}

/** Starts an interactive session at `cwd` (the home by default), as Claude Code does on launch. */
export async function start($: Engine, cwd = HOME, isInteractive = true) {
  return $.session.start({ cwd, surface: 'terminal', isInteractive })
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
