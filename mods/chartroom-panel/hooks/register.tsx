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
  autoShowEnabled,
  capacityFor,
  clean,
  columns,
  isUnderWorktrees,
  paginate,
  parseTasks,
  setConfigLine,
  stateLabel,
  tone,
  truncate,
} from './model'

const PANE = 'chartroom-panel'
const POLL_MS = 5_000
// How long a first `c` stays armed before the two-press close confirm resets.
const CONFIRM_MS = 5_000
const EMPTY: Snapshot = { tasks: null, error: null, updated: null }
const FOCUSED = 'Chartroom panel focused: ↑↓ to choose, Enter brings a task in, Esc back to chat.'
const WAITING = 'Chartroom panel is waiting for room: widen the terminal.'
// Loading one of these skills makes the session the XO — the auto-show trigger, in any directory.
const XO_SKILLS = ['captain', 'chartroom']

const active = atom({ plugin: 'chartroom-panel', key: 'active' } as const, false)
const closedByUser = atom({ plugin: 'chartroom-panel', key: 'closedByUser' } as const, false)
const snapshot = atom({ plugin: 'chartroom-panel', key: 'snapshot' } as const, EMPTY)
const page = atom({ plugin: 'chartroom-panel', key: 'page' } as const, 0)
const selected = atom({ plugin: 'chartroom-panel', key: 'selected' } as const, null as string | null)
const notice = atom({ plugin: 'chartroom-panel', key: 'notice' } as const, null as string | null)
// The short_id a first `c` armed for close; a second `c` on the same row confirms. null = unarmed.
const armed = atom({ plugin: 'chartroom-panel', key: 'armed' } as const, null as string | null)

/** How each tone draws: input-needed yellow, working green, quiet dim, unknown plain (default colour). */
const TONE_PROPS: Record<Tone, { color?: string; dimColor?: boolean }> = {
  input: { color: 'warning' },
  working: { color: 'success' },
  quiet: { dimColor: true },
  plain: {},
}

// The XO's home for reading status, resolved lazily through `chartroom doctor`. '' when unknown.
let home = ''
// Whether this session may run the panel at all (interactive, not a crew worker); set at session.start.
let eligible = false
// Set once this session has auto-shown (or decided not to), so the several XO-skill triggers
// (skill.prompt, the /chartroom|/captain prompt submit, the Skill tool call) activate it only once.
let autoShown = false
// The poll timer, while one runs; cancelled on off and at session end.
let timer: Timer | undefined
// A poll in flight, and one asked for while it ran (coalesced into a single follow-up).
let polling = false
let pollAgain = false
// Bumped on every off so a late poll result is dropped, never written over a fresh state.
let pollGen = 0
// The reset timer for an armed two-press close; cancelled on confirm, re-arm, off and session end.
let armTimer: Timer | undefined

/**
 * One `chartroom <args>` run: `$CHARTROOM_BIN`, else `chartroom` on PATH, then ~/.local/bin (a
 * thin GUI PATH). Once `home` is known every run names it (`CHARTROOM_HOME`), so the panel reads
 * this session's home whatever the CLI would otherwise resolve. Never throws. On a failure it
 * returns `error` (a one-line summary) and `detail` (the CLI's own stdout+stderr, verbatim and
 * trimmed) so a refusal can be surfaced word for word.
 */
async function runCli($: EngineInterface, args: string[]): Promise<{ stdout: string } | { error: string; detail?: string }> {
  const bin = await $.env.get('CHARTROOM_BIN')
  const userHome = (await $.env.get('HOME')) ?? ''
  const candidates = bin ? [bin] : ['chartroom', `${userHome}/.local/bin/chartroom`]
  for (const path of candidates) {
    try {
      const ran = await $.process.run([path, ...args], { timeoutMs: 8_000, ...(home ? { env: { CHARTROOM_HOME: home } } : {}) })
      if (ran.exitCode === 0) return { stdout: ran.stdout }
      if (ran.exitCode === 127) continue // not this candidate; try the next
      const detail = `${ran.stderr}\n${ran.stdout}`.trim()
      const why = (ran.stderr.trim().split('\n')[0] ?? '').replace(/^chartroom:\s*/, '')
      return { error: `chartroom ${args[0]} failed${why ? `: ${why}` : ` (exit ${ran.exitCode})`}`, ...(detail ? { detail } : {}) }
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

/** The durable, harness-neutral panel config in the home (`autoshow` etc.); read-only here. */
function panelConfPath(): string {
  return `${home}/panel.conf`
}

/** The home's panel.conf text, or null when there is no home or no file. */
async function readPanelConf($: EngineInterface): Promise<string | null> {
  if (!home) return null
  const path = panelConfPath()
  if (!(await $.fs.exists(path).catch(() => false))) return null
  return $.fs.read(path).catch(() => null)
}

/** The durable default: whether auto-show is on for this home (unset = on). */
async function autoShowDefault($: EngineInterface): Promise<boolean> {
  return autoShowEnabled(await readPanelConf($))
}

/**
 * The session has become the XO — auto-show the panel, once. Several triggers call this (the
 * chartroom/captain skill via skill.prompt, the same slash command via prompt.submit when another
 * plugin's skill.prompt handler preempts ours, and the Skill tool call), so it dedupes: it claims
 * `autoShown` synchronously before any await, and respects eligibility, a session already on/closed,
 * and the home's durable default. Intent-based — no working-directory check.
 */
async function maybeAutoShow($: EngineInterface): Promise<void> {
  if (!eligible || autoShown) return
  autoShown = true // claimed before awaiting, so concurrent triggers activate the panel only once
  if ((await read($, active)) || (await read($, closedByUser))) return
  await ensureHome($) // resolve the home so panel.conf (and status) read the right place
  if (await autoShowDefault($)) await activatePanel($, false) // auto-show, without taking the keyboard
}

/** The XO skill a prompt submission names, if any: from the resolved command, else the typed text. */
function xoSkillOf(command: { name: string } | undefined, text: string): string {
  const fromCommand = (command?.name ?? '').split(':').pop() ?? ''
  if (XO_SKILLS.includes(fromCommand)) return fromCommand
  const fromText = (/^\/\s*([A-Za-z0-9_:-]+)/.exec(text) ?? [])[1]
  const name = (fromText ?? '').split(':').pop() ?? ''
  return XO_SKILLS.includes(name) ? name : ''
}

/**
 * Whether this session may run the panel at all: interactive, and not a crew worker (no
 * CHARTROOM_TASK, not under a `worktrees/` path). It is NOT tied to any directory — the XO is run
 * from project repos, so auto-show is triggered by intent (loading the chartroom/captain skill),
 * not by the cwd. The home for reading status is resolved separately, through `chartroom doctor`.
 */
async function isEligible($: EngineInterface, cwd: string, isInteractive: boolean): Promise<boolean> {
  if (!isInteractive) return false
  if (await $.env.get('CHARTROOM_TASK')) return false
  if (isUnderWorktrees(cwd)) return false
  return true
}

async function openPane($: EngineInterface, focus: boolean) {
  // `backgroundColor: 'transparent'` paints nothing under the pane body, so the chat transcript
  // behind it shows through and the panel blends in instead of sitting in the engine's default
  // grey docked-pane surface. Transparent is theme-safe: it shows whatever the terminal paints,
  // in a dark or a light theme alike. It covers the whole body, the empty area below the rows too.
  return $.ui.open({ id: PANE, title: 'Chartroom', backgroundColor: 'transparent', ...(focus ? { focus: true as const } : {}) })
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

/** Stops the refresh (poll timer and any armed-close timer); shared by `off`, the person's close and exit. */
function stopRefresh() {
  pollGen++ // a poll in flight must not write after this
  timer?.cancel()
  timer = undefined
  armTimer?.cancel()
  armTimer = undefined
}

/** Turns the panel off for the session: no draw, no poll; auto-show will not re-open it. */
async function deactivatePanel($: EngineInterface) {
  await update($, active, () => false)
  await update($, closedByUser, () => true)
  await update($, notice, () => null)
  await update($, armed, () => null)
  stopRefresh()
  await closePane($)
}

/** Sets the panel's one-line notice. */
async function say($: EngineInterface, text: string | null) {
  await update($, notice, () => text).catch(() => {})
}

/**
 * Puts `text` into an empty chat prompt via `$.prompt.fill` (the keys then go to the prompt). A
 * draft is never replaced — the text is copied to the clipboard instead. Nothing is ever submitted.
 */
async function putInPrompt($: EngineInterface, text: string, surface?: RenderSurface): Promise<{ via: 'fill' | 'copy' | 'none'; draft: boolean }> {
  const box = await $.prompt.read()
  const draft = box.text.trim() !== ''
  if (!draft) {
    const filled = await $.prompt.fill({ text, mode: 'replace' })
    if (filled.isFilled) return { via: 'fill', draft: false }
  }
  const copied = await $.ui.copy({ text, ...(surface ? { surface } : {}) })
  return { via: copied.isCopied ? 'copy' : 'none', draft }
}

/**
 * Enter / pick: bring the task into the chat by SUBMITTING `/continue <sid>` as its own turn, in one
 * press (focus returns to chat). `/continue` only navigates, so auto-submit is safe.
 *
 * Fire-and-forget on purpose: `$.prompt.submit` runs as a turn once the session is idle, so AWAITING
 * it inside this key handler would deadlock (the handler keeps the session busy). We `void` it (as
 * the API's own example does) and never touch the composer, so any draft is left intact and nothing
 * is copied.
 */
function continueSubmit($: EngineInterface, sid: string): string {
  const line = `/continue ${sid}`
  void $.prompt.submit({ text: line }).catch(() => {})
  return `sent ${line}`
}

/** Selects a task by its short id: records the ring and brings it into the chat (submitting /continue). */
async function pick($: EngineInterface, sid: string) {
  await update($, selected, () => sid)
  await say($, continueSubmit($, sid))
}

/** The highlighted task: the ring's row (tracked via ui.focus), else the first visible task. */
async function currentTask($: EngineInterface): Promise<Task | null> {
  const tasks = (await read($, snapshot)).tasks ?? []
  if (!tasks.length) return null
  const sel = await read($, selected)
  return tasks.find(t => (t.short_id ?? t.id) === sel) ?? tasks[0] ?? null
}

/** Clears an armed close (on timeout, re-arm, off): forgets the arm and its confirm notice. */
async function disarm($: EngineInterface) {
  armTimer?.cancel()
  armTimer = undefined
  if (!(await read($, armed).catch(() => null))) return
  await update($, armed, () => null).catch(() => {})
  await update($, notice, n => (n && n.startsWith('Close ') ? null : n)).catch(() => {})
}

/**
 * `c` on the highlighted task: complete → close, two presses. The first arms it (and shows an
 * inline confirm with a reset timeout); a second `c` on the same row runs `chartroom close <id>`
 * (keeping the branch, never `--discard`) against the resolved home. On refusal the CLI's exact
 * message is shown and nothing is claimed; on success the fleet re-polls and the task drops off.
 */
async function actClose($: EngineInterface) {
  const task = await currentTask($)
  if (!task) return say($, 'no task highlighted')
  const sid = task.short_id ?? task.id // shown to the person and armed on the short id
  if ((await read($, armed)) === sid) {
    armTimer?.cancel()
    armTimer = undefined
    await update($, armed, () => null)
    const ran = await runCli($, ['close', task.id]) // chartroom close takes the FULL id, not the short id
    if ('error' in ran) return say($, ran.detail || ran.error) // the CLI's exact refusal, never a fake success
    await say($, ran.stdout.trim().split('\n')[0] || `closed ${sid}`)
    await poll($) // so it drops off the list
    return
  }
  await update($, armed, () => sid)
  await say($, `Close ${sid}? press c again to confirm`)
  armTimer?.cancel()
  armTimer = $.clock.after(CONFIRM_MS, () => void disarm($))
}

/** `s` on the highlighted task: pre-fill a non-mutating recap request into the chat prompt. */
async function actRecap($: EngineInterface, surface?: RenderSurface) {
  await disarm($) // any other action cancels a pending close
  const task = await currentTask($)
  if (!task) return say($, 'no task highlighted')
  const sid = task.short_id ?? task.id
  const text = `Recap ${sid} (${clean(task.title ?? sid)}): where it stands and what's pending`
  const r = await putInPrompt($, text, surface)
  if (r.via === 'fill') return say($, `recap request is in the prompt — edit or press Enter to send`)
  const why = r.draft ? 'the prompt holds a draft, kept' : 'the prompt cannot take it now'
  await say($, r.via === 'copy' ? `recap copied (${why})` : `${why}; recap: ${text}`)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // A reload resets the module variables; re-decide eligibility. The home is resolved lazily.
    home = ''
    eligible = await isEligible($, e.cwd, e.isInteractive).catch(() => false)
    if (!eligible) return next(e) // non-interactive, or a crew worker: stay fully inert

    await $.command
      .register({
        name: 'chartroom-panel',
        description: 'Live, read-only Chartroom tasks: on|off|toggle|refresh|next|prev|focus|pick <id>|default on|off',
      })
      .catch(() => {})

    // A reload of a session that was already on resumes it; a fresh session waits for the XO skill
    // (skill.prompt) to auto-show — auto-show is triggered by intent, not by the working directory.
    if (await read($, active)) {
      await ensureHome($)
      if (!timer) timer = $.clock.every(POLL_MS, () => void tick($))
      void poll($)
      await openPane($, false)
    }
    return next(e)
  })

  // Becoming the XO is the auto-show trigger, in ANY directory. Three hooks catch it, deduped by
  // maybeAutoShow, because no single one is reliable: a builtin plugin's skill.prompt handler can run
  // first and send the event on past ours (cc-plugin-sec-default does), so the prompt submit of the
  // `/chartroom` (or `/captain`) command and the Skill tool call cover the case where skill.prompt
  // never reaches us.
  on('skill.prompt', async ($, e, next) => {
    if (XO_SKILLS.includes(e.skill.split(':').pop() ?? '')) await maybeAutoShow($)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (xoSkillOf(e.command, e.text)) await maybeAutoShow($)
    return next(e)
  })

  on('tool.call', { tool: 'Skill' }, async ($, e, next) => {
    if (XO_SKILLS.includes((e.skill ?? '').split(':').pop() ?? '')) await maybeAutoShow($)
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
      await update($, armed, () => null)
      stopRefresh()
    }
    return closed
  })

  // The ring follows the person's arrows/Tab; tracking it as `selected` lets `c`/`s` and Enter act
  // on the highlighted row. Moving to a different row cancels a pending two-press close.
  on('ui.focus', async ($, e, next) => {
    const moved = await next(e)
    if (e.requestId === PANE && e.plugin === 'chartroom-panel' && e.element?.startsWith('row-') && !moved?.deny) {
      const sid = e.element.slice(4)
      await update($, selected, () => sid).catch(() => {})
      if ((await read($, armed).catch(() => null)) && (await read($, armed)) !== sid) await disarm($)
    }
    return moved
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
    if (sub === 'default') {
      // The durable, home-level default (across sessions, and readable by the Pi/Codex panels):
      // `$CHARTROOM_HOME/panel.conf`, key `autoshow`. A session on/off still overrides it per session.
      await ensureHome($)
      if (!home) return { text: 'Cannot set the default: no Chartroom home resolved here.' }
      const val = argId.toLowerCase()
      if (val !== 'on' && val !== 'off') {
        const current = (await autoShowDefault($)) ? 'on' : 'off'
        return { text: `Auto-show default is ${current} for this home (${panelConfPath()}). Set it with /chartroom-panel default on|off.` }
      }
      const text = setConfigLine(await readPanelConf($), 'autoshow', val)
      try {
        await $.fs.write(panelConfPath(), text)
      } catch (err) {
        return { text: `Could not write ${panelConfPath()}: ${String(err).split('\n')[0]}` }
      }
      return {
        text: `Auto-show default set to ${val} for this home (${panelConfPath()}) — it governs every session, and the Pi/Codex panels can read the same switch. A session /chartroom-panel on|off still overrides it for the current session.`,
      }
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
    if (sub && sub !== 'toggle') return { text: 'Usage: /chartroom-panel [on|off|toggle|refresh|next|prev|focus|pick <id>|default on|off]' }

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
            onPress={() => void pick($, t.short_id ?? t.id)}
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

    // flexGrow fills the pane's body height and backgroundColor transparent paints nothing, so the
    // area below the rows blends with the chat too — belt-and-suspenders with the open's backgroundColor.
    return (
      <Box flexDirection="column" flexGrow={1} backgroundColor="transparent">
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
          // Focused: the action keys are real Buttons (their hotkeys fire only while the pane holds
          // the keyboard), drawn as `c: close  s: recap`, then the rest of the legend. wrap=truncate
          // keeps it on one line on a narrow pane; the Buttons give way gracefully before the text.
          <Box key="foot-actions" flexDirection="row" flexWrap="wrap">
            <Box marginRight={1}>
              <Button key="act-close" plain hotkey="c" label="close" onPress={() => void actClose($)} />
            </Box>
            <Box marginRight={1}>
              <Button key="act-recap" plain hotkey="s" label="recap" onPress={press => void actRecap($, press.surface)} />
            </Box>
            <Text dimColor wrap="truncate">
              ↑↓ move · Enter /continue · Esc chat
            </Text>
          </Box>
        ) : (
          <Text key="foot-select" dimColor wrap="truncate">
            Ctrl+X Tab to select
          </Text>
        )}
        {note ? (
          <Text key="notice" color="success" wrap="truncate">
            {note}
          </Text>
        ) : null}
      </Box>
    )
  })
}
