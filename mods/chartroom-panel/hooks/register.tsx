// chartroom-panel: the commander's live, read-only Chartroom tasks, in a pane beside the chat.
//
// The sibling of the Pi panel (adapters/pi-panel). It shows the unfinished fleet from
// `chartroom status --json` and nothing else: completed/closed rows drop off, everything still
// open stays, with the ones needing the commander's input (yellow) and the ones being worked on
// (green) set apart. It polls on a timer with no model call, keeps the last tasks visibly STALE
// on a failure, and never touches a task record.
//
// Activation: installed at user scope it loads in every Claude Code session. It does nothing
// (no command, no timer, no process, no pane) unless the session is interactive. When the cwd is
// the configured Chartroom home (resolved through `chartroom doctor --json`) it auto-shows; the
// `/chartroom-panel` command turns it on anywhere. A crew worker's session — CHARTROOM_TASK set,
// or a `worktrees` path segment — never auto-shows.
//
// Selection: `/chartroom-panel` focuses the pane; the arrows walk the task rows and Enter brings
// the task into the chat as the next prompt's focus, pre-filling `/continue <short_id>` (the
// existing chartroom continue skill) without submitting. Esc hands the keys back to the chat and
// leaves the pane open. Nothing is auto-submitted and normal typing is never captured.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderSurface, Timer } from 'claude-code'

import type { Snapshot, Task, Tone } from '../types'
import {
  CONTROLS,
  capacityFor,
  clean,
  columns,
  isUnderWorktrees,
  paginate,
  parseTasks,
  samePath,
  stateLabel,
  tone,
  truncate,
} from './model'

const PANE = 'chartroom-panel'
const POLL_MS = 5_000
const EMPTY: Snapshot = { tasks: null, error: null, updated: null }
const FOCUSED = 'Chartroom panel focused: ↑↓ to choose, Enter brings a task in, Esc back to chat.'
const WAITING = 'Chartroom panel is waiting for room: widen the terminal.'

const active = atom({ plugin: 'chartroom-panel', key: 'active' } as const, false)
const closedByUser = atom({ plugin: 'chartroom-panel', key: 'closedByUser' } as const, false)
const snapshot = atom({ plugin: 'chartroom-panel', key: 'snapshot' } as const, EMPTY)
const page = atom({ plugin: 'chartroom-panel', key: 'page' } as const, 0)
const selected = atom({ plugin: 'chartroom-panel', key: 'selected' } as const, null as string | null)
const notice = atom({ plugin: 'chartroom-panel', key: 'notice' } as const, null as string | null)

/** How each tone draws: input-needed yellow, working green, quiet dim, unknown plain (default colour). */
const TONE_PROPS: Record<Tone, { color?: string; dimColor?: boolean }> = {
  input: { color: 'warning' },
  working: { color: 'success' },
  quiet: { dimColor: true },
  plain: {},
}

// The XO's home, resolved at session.start; a reload re-runs it. '' when unknown.
let home = ''
// Whether this session's cwd is that home (so it auto-shows).
let homeIsCwd = false
// The poll timer, while one runs; cancelled on off and at session end.
let timer: Timer | undefined
// A poll in flight, and one asked for while it ran (coalesced into a single follow-up).
let polling = false
let pollAgain = false
// Bumped on every off so a late poll result is dropped, never written over a fresh state.
let pollGen = 0

/**
 * One `chartroom <args>` run: `$CHARTROOM_BIN`, else `chartroom` on PATH, then ~/.local/bin (a
 * thin GUI PATH). Once `home` is known every run names it (`CHARTROOM_HOME`), so the panel reads
 * this session's home whatever the CLI would otherwise resolve. Never throws.
 */
async function runCli($: EngineInterface, args: string[]): Promise<{ stdout: string } | { error: string }> {
  const bin = await $.env.get('CHARTROOM_BIN')
  const userHome = (await $.env.get('HOME')) ?? ''
  const candidates = bin ? [bin] : ['chartroom', `${userHome}/.local/bin/chartroom`]
  for (const path of candidates) {
    try {
      const ran = await $.process.run([path, ...args], { timeoutMs: 8_000, ...(home ? { env: { CHARTROOM_HOME: home } } : {}) })
      if (ran.exitCode === 0) return { stdout: ran.stdout }
      if (ran.exitCode === 127) continue // not this candidate; try the next
      const why = (ran.stderr.trim().split('\n')[0] ?? '').replace(/^chartroom:\s*/, '')
      return { error: `chartroom ${args[0]} failed${why ? `: ${why}` : ` (exit ${ran.exitCode})`}` }
    } catch (err) {
      // A rejection is a command that could not start (try the next), or one still running at the timeout.
      if (/timed? ?out/i.test(String(err))) return { error: `chartroom ${args[0]} timed out` }
    }
  }
  return { error: 'chartroom not found' }
}

/** Reads `chartroom status --json` into the snapshot; never throws, never overlaps, drops late results. */
async function poll($: EngineInterface): Promise<void> {
  // `.catch` guards a read made while the module is being torn down (a reload, or a test env ending).
  if (!(await read($, active).catch(() => false))) return
  if (polling) {
    pollAgain = true
    return
  }
  polling = true
  const gen = pollGen
  try {
    const ran = await runCli($, ['status', '--json'])
    if (gen !== pollGen || !(await read($, active))) return // turned off, or a newer run owns the state
    if ('error' in ran) {
      await update($, snapshot, s => ({ ...s, error: ran.error }))
    } else {
      try {
        const tasks = parseTasks(ran.stdout)
        const now = await $.clock.now()
        await update($, snapshot, () => ({ tasks, error: null, updated: now }))
      } catch {
        await update($, snapshot, s => ({ ...s, error: 'malformed status JSON' }))
      }
    }
  } catch (err) {
    if (gen === pollGen) {
      await update($, snapshot, s => ({ ...s, error: `chartroom-panel: ${String(err).split('\n')[0]}` })).catch(() => {})
    }
  } finally {
    polling = false
  }
  if (pollAgain) {
    pollAgain = false
    return poll($)
  }
}

/** The timer's tick: poll only while the panel is on, so turning it off stops the refresh work. */
async function tick($: EngineInterface): Promise<void> {
  if (await read($, active).catch(() => false)) await poll($)
}

/** Resolves the XO's home through the CLI, once, for manual activation away from session.start. */
async function ensureHome($: EngineInterface): Promise<void> {
  if (home) return
  const ran = await runCli($, ['doctor', '--json'])
  if ('error' in ran) return
  try {
    const h = (JSON.parse(ran.stdout) as { home?: unknown }).home
    if (typeof h === 'string' && h) home = h
  } catch {
    // doctor gave no usable home; status will let the CLI resolve it.
  }
}

/**
 * True when this session should auto-show: interactive, not a crew worker, and the cwd is the
 * Chartroom home (resolved through `chartroom doctor --json`). Reads env and one file before
 * spawning doctor, so an unrelated session costs nothing.
 */
async function detectHomeCwd($: EngineInterface, cwd: string, isInteractive: boolean): Promise<boolean> {
  if (!isInteractive) return false
  if (await $.env.get('CHARTROOM_TASK')) return false
  if (isUnderWorktrees(cwd)) return false
  if (!(await $.fs.exists(`${cwd}/commander.md`))) return false // cheap pre-gate: a home has commander.md
  const ran = await runCli($, ['doctor', '--json'])
  if ('error' in ran) return false
  let h: unknown
  try {
    h = (JSON.parse(ran.stdout) as { home?: unknown }).home
  } catch {
    return false
  }
  if (typeof h !== 'string' || !h) return false
  home = h
  if (samePath(cwd, h)) return true
  const real = async (p: string) => (await $.fs.stat(p, { resolve: true }).catch(() => undefined))?.realPath
  const [a, b] = await Promise.all([real(cwd), real(h)])
  return !!a && !!b && samePath(a, b)
}

async function openPane($: EngineInterface, focus: boolean) {
  return $.ui.open({ id: PANE, title: 'Chartroom', ...(focus ? { focus: true as const } : {}) })
}

async function closePane($: EngineInterface) {
  await $.ui.close({ id: PANE }).catch(() => {})
}

/** The pane's state with the person: open at all, and holding the keyboard. */
async function paneState($: EngineInterface): Promise<{ open: boolean; focused: boolean }> {
  const panes = await $.ui.panes().catch(() => [])
  const p = panes.find(x => x.id === PANE)
  return { open: !!p, focused: !!p?.isFocused }
}

/** Starts the timer (once), ensures the snapshot polls, and opens the pane. */
async function activatePanel($: EngineInterface, focus: boolean) {
  await ensureHome($)
  await update($, active, () => true)
  await update($, closedByUser, () => false)
  if (!timer) timer = $.clock.every(POLL_MS, () => void tick($))
  void poll($)
  return openPane($, focus)
}

/** Stops the refresh and forgets the selection notice; shared by `off` and the person's close. */
function stopRefresh() {
  pollGen++ // a poll in flight must not write after this
  timer?.cancel()
  timer = undefined
}

/** Turns the panel off for the session: no draw, no poll; auto-show will not re-open it. */
async function deactivatePanel($: EngineInterface) {
  await update($, active, () => false)
  await update($, closedByUser, () => true)
  await update($, notice, () => null)
  stopRefresh()
  await closePane($)
}

/**
 * Brings `sid` into the chat as the next prompt's focus: `/continue <sid>` into an empty prompt
 * (the keys then go to the prompt, so Enter runs it). A draft is never replaced — it is copied
 * instead, with a note. Returns what happened.
 */
async function continued($: EngineInterface, sid: string, surface?: RenderSurface): Promise<string> {
  const line = `/continue ${sid}`
  const box = await $.prompt.read()
  if (box.text.trim() === '') {
    const filled = await $.prompt.fill({ text: line, mode: 'replace' })
    if (filled.isFilled) return `${line} is in the prompt — press Enter to run it`
  }
  const copied = await $.ui.copy({ text: line, ...(surface ? { surface } : {}) })
  const why = box.text.trim() ? 'the prompt holds a draft, kept' : 'the prompt cannot take it now'
  return copied.isCopied ? `${line} copied (${why}): paste it at the prompt` : `${why}; type ${line}`
}

/** Selects a task by its short id: records the ring and brings it into the chat. */
async function pick($: EngineInterface, sid: string, surface?: RenderSurface) {
  await update($, selected, () => sid)
  await update($, notice, () => `${sid}…`)
  const said = await continued($, sid, surface)
  await update($, notice, () => said)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // A reload resets the module variables; re-resolve the home and whether the cwd is it.
    home = ''
    homeIsCwd = await detectHomeCwd($, e.cwd, e.isInteractive).catch(() => false)
    if (!e.isInteractive) return next(e)

    await $.command
      .register({
        name: 'chartroom-panel',
        description: 'Live, read-only Chartroom tasks: on|off|toggle|refresh|next|prev|focus|pick <id>',
      })
      .catch(() => {})

    if (await read($, active)) {
      // Resume after a reload: restart the timer and poll, redraw the pane (never steal focus).
      if (!timer) timer = $.clock.every(POLL_MS, () => void tick($))
      void poll($)
      await openPane($, false)
    } else if (homeIsCwd && !(await read($, closedByUser))) {
      // Fresh start at the home: auto-show, without taking the keyboard.
      await activatePanel($, false)
    }
    return next(e)
  })

  // Exits stay fast; just stop the refresh. The engine takes the pane down with the session.
  on('session.end', async (_$, e, next) => {
    stopRefresh()
    return next(e)
  })

  // The person's own close (the frame's ✕, ctrl+x x) turns the panel off like `off` does: without
  // it, polling would run on with no pane, and a reload would re-open it. The plugin's own close
  // (deactivatePanel) carries origin `plugin` and is left alone.
  on('ui.close', async ($, e, next) => {
    const closed = await next(e)
    if (e.id === PANE && e.origin.kind === 'person') {
      await update($, active, () => false)
      await update($, closedByUser, () => true)
      await update($, notice, () => null)
      stopRefresh()
    }
    return closed
  })

  on('command.run', { command: 'chartroom-panel' }, async ($, e) => {
    const [sub = '', ...rest] = e.args.trim().split(/\s+/).filter(Boolean)
    const argId = rest.join(' ').replace(/^\[|\]$/g, '')

    if (sub === 'off') {
      await deactivatePanel($)
      return { text: 'Chartroom panel off for this session: /chartroom-panel on brings it back.' }
    }
    if (sub === 'on') {
      const opened = await activatePanel($, false)
      return { text: opened.isPlaced ? 'Chartroom panel on.' : 'Chartroom panel is waiting for room: widen the terminal.' }
    }
    if (sub === 'refresh') {
      if (!(await read($, active))) await activatePanel($, false)
      await poll($)
      return { text: 'Chartroom panel refreshed.' }
    }
    if (sub === 'next' || sub === 'prev') {
      if (!(await read($, active))) await activatePanel($, false)
      await update($, page, p => p + (sub === 'next' ? 1 : -1))
      return { text: `Chartroom panel: ${sub} page.` }
    }
    if (sub === 'pick') {
      if (!argId) return { text: 'Usage: /chartroom-panel pick <short_id>' }
      if (!(await read($, active))) await activatePanel($, false)
      await pick($, argId)
      return { text: `Chartroom panel: picked ${argId}.` }
    }
    if (sub === 'focus') {
      const opened = await activatePanel($, true)
      return { text: opened.isPlaced ? FOCUSED : WAITING }
    }
    if (sub && sub !== 'toggle') return { text: 'Usage: /chartroom-panel [on|off|toggle|refresh|next|prev|focus|pick <id>]' }

    // Bare /chartroom-panel (and `toggle`) is show/hide: open-and-focus when hidden, close when
    // shown. The pane is never focused when a composer command runs (the composer holds the keys
    // to type it), so there is no "focused → close" state; ctrl+x tab (the engine's own focus
    // chord) or `/chartroom-panel focus` takes the keyboard, and Esc hands it back.
    if ((await read($, active)) && (await paneState($)).open) {
      await deactivatePanel($)
      return { text: 'Chartroom panel closed.' }
    }
    const opened = await activatePanel($, true)
    return { text: opened.isPlaced ? FOCUSED : WAITING }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    if (!(await read($, active))) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const snap = await read($, snapshot)
    const pg = await read($, page)
    const sel = await read($, selected)
    const note = await read($, notice)
    const width = Math.max(4, e.props.bodyColumns)
    const cap = capacityFor(e.props.scroll?.bodyRows ?? 24)
    const tasks = snap.tasks ?? []
    const view = paginate(tasks, cap, pg)

    const header =
      snap.tasks === null ? (
        <Text key="header" weight="bold" color="success" wrap="truncate">
          Chartroom · task status
        </Text>
      ) : (
        <Text key="header" weight="bold" color="success" wrap="truncate">
          Chartroom · {tasks.length} unfinished
        </Text>
      )

    const status = snap.error ? (
      <Text key="status" color="warning" wrap="truncate">
        {snap.tasks === null ? 'Unavailable' : 'STALE'}: {clean(snap.error)}
      </Text>
    ) : (
      <Text key="status" dimColor wrap="truncate">
        {snap.updated ? `Live · updated ${new Date(snap.updated).toLocaleTimeString()}` : 'Loading…'}
      </Text>
    )

    // The ring rests on the selected row when it is on this page, else the first row.
    const onPage = view.tasks.map(t => t.short_id ?? t.id)
    const ringId = (sel && onPage.includes(sel) ? sel : onPage[0]) ?? ''

    const rows = view.tasks.map((t: Task) => {
      const sid = clean(t.short_id ?? t.id)
      const title = clean(t.title ?? t.id)
      const titleWidth = Math.max(0, width - columns(sid) - 1)
      const key = `row-${t.short_id ?? t.id}`
      const line2 = `  ${stateLabel(t.state)}${t.project ? ` · ${clean(t.project)}` : ''}`
      return (
        <Box key={key} flexDirection="column">
          <Button
            key={key}
            plain
            {...((t.short_id ?? t.id) === ringId ? { autoFocus: true as const } : {})}
            onPress={press => void pick($, t.short_id ?? t.id, press.surface)}
          >
            <Text color="subtle">{sid}</Text>
            {' '}
            {truncate(title, titleWidth)}
          </Button>
          <Text wrap="truncate" {...TONE_PROPS[tone(t.state)]}>
            {line2}
          </Text>
        </Box>
      )
    })

    const body =
      view.tasks.length === 0
        ? [
            <Text key="empty" dimColor>
              {snap.tasks === null ? 'Waiting for task status' : snap.error ? 'Last known: no unfinished tasks' : 'No unfinished tasks'}
            </Text>,
          ]
        : rows

    return (
      <Box flexDirection="column">
        {header}
        {status}
        <Text key="gap"> </Text>
        {body}
        <Text key="foot-range" dimColor wrap="truncate">
          {view.footer}
        </Text>
        <Text key="foot-controls" dimColor wrap="truncate">
          {CONTROLS}
        </Text>
        {e.props.isFocused ? (
          <Text key="foot-nav" dimColor wrap="truncate">
            ↑↓ move · Enter → /continue · Esc → chat
          </Text>
        ) : null}
        {note ? (
          <Text key="notice" color="success" wrap="truncate">
            {note}
          </Text>
        ) : null}
      </Box>
    )
  })
}
