// chartroom-panel: the commander's live Chartroom board, in a pane beside the chat.
//
// It mirrors `chartroom board` and the dashboard: it reads `chartroom board --json` (the board's
// own lane logic, lib/dashboard/lanes.jq) and draws the same five lanes, in the same order, under
// the same names, each card with the board's reason: Needs you (yellow; a worker's finished work
// awaiting review is there), In progress (green), On hold, Ready for you, Recently finished. It
// polls on a timer with no model call and keeps the last board visibly STALE on a failure. It
// changes a task only on the commander's two-press keys, through the CLI the XO uses:
// `a` complete (`chartroom accept`) and `c` close (`chartroom close`).
//
// Activation: installed at user scope it loads in every Claude Code session. It does nothing
// (no command, no timer, no process, no pane) unless the session is interactive. When the cwd is
// the configured Chartroom home (resolved through `chartroom doctor --json`) it auto-shows; the
// `/chartroom-panel` command turns it on anywhere. A crew worker's session — CHARTROOM_TASK set,
// or a `worktrees` path segment — never auto-shows.
//
// Selection: `/chartroom-panel` focuses the pane; the arrows walk the cards and Enter runs
// `/continue <short_id>` (the chartroom continue skill) for the highlighted one. Esc hands the keys
// back to the chat and leaves the pane open. Normal typing is never captured.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderSurface, Timer } from 'claude-code'

import type { Card, Snapshot, Tone } from '../types'
import {
  CONTROLS,
  LANES,
  autoShowEnabled,
  capacityFor,
  cardDetail,
  cardKey,
  clean,
  columns,
  isUnderWorktrees,
  laneCounts,
  laneHeader,
  laneTone,
  paginate,
  parseBoard,
  setConfigLine,
  truncate,
} from './model'

const PANE = 'chartroom-panel'
const POLL_MS = 5_000
// `chartroom board` reads every task, the inbox and the artifacts: give it longer than a one-task action.
const BOARD_TIMEOUT_MS = 20_000
// How long a first `c`/`a` stays armed before the two-press confirm resets.
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
// `<action>:<key>` a first `c` (close) or `a` (complete) armed; the same key again on that row confirms.
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
async function runCli($: EngineInterface, args: string[], timeoutMs = 8_000): Promise<{ stdout: string } | { error: string; detail?: string }> {
  const bin = await $.env.get('CHARTROOM_BIN')
  const userHome = (await $.env.get('HOME')) ?? ''
  const candidates = bin ? [bin] : ['chartroom', `${userHome}/.local/bin/chartroom`]
  for (const path of candidates) {
    try {
      const ran = await $.process.run([path, ...args], { timeoutMs, ...(home ? { env: { CHARTROOM_HOME: home } } : {}) })
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

/** Reads `chartroom board --json` into the snapshot; never throws, never overlaps, drops late results. */
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
    const ran = await runCli($, ['board', '--json'], BOARD_TIMEOUT_MS)
    if (gen !== pollGen || !(await read($, active))) return // turned off, or a newer run owns the state
    if ('error' in ran) {
      await update($, snapshot, s => ({ ...s, error: ran.error }))
    } else {
      try {
        const tasks = parseBoard(ran.stdout)
        const now = await $.clock.now()
        await update($, snapshot, () => ({ tasks, error: null, updated: now }))
      } catch {
        await update($, snapshot, s => ({ ...s, error: 'malformed board JSON' }))
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
 * Enter / pick: bring the task into the chat by RUNNING `/continue <sid>` in one press (focus returns
 * to chat). `/continue` only navigates, so auto-running it is safe.
 *
 * Uses `$.command.run`, which dispatches the slash command "as if the person typed `/continue <sid>`"
 * — unlike `$.prompt.submit`, which submits the text and does NOT re-parse it as a command, so the
 * continue skill never ran (it only showed a false "sent"). Fire-and-forget: the command is queued
 * and runs once the session is idle, so awaiting it inside this key handler would deadlock. The
 * composer is never touched (a draft is safe), and a rejection (unknown command, Stop, a limit)
 * corrects the notice — success is never faked.
 */
function continueSubmit($: EngineInterface, sid: string): string {
  const line = `/continue ${sid}`
  void $.command.run({ command: 'continue', args: sid }).catch(() => void say($, `could not run ${line}`))
  return `running ${line}…`
}

/** Selects a card by its key: records the ring and brings it into the chat (running /continue). */
async function pick($: EngineInterface, key: string) {
  await update($, selected, () => key)
  const card = ((await read($, snapshot)).tasks ?? []).find(c => cardKey(c) === key)
  // An inbox line with no tag has no id /continue could take (`chartroom inbox tag` gives it one).
  if (card && !card.short_id && card.type === 'inbox') return say($, 'this inbox item has no id yet (chartroom inbox tag gives it one)')
  await say($, continueSubmit($, key))
}

/** The highlighted card: the ring's row (tracked via ui.focus), else the first card. */
async function currentCard($: EngineInterface): Promise<Card | null> {
  const cards = (await read($, snapshot)).tasks ?? []
  if (!cards.length) return null
  const sel = await read($, selected)
  return cards.find(c => cardKey(c) === sel) ?? cards[0] ?? null
}

/** Clears an armed action (on timeout, re-arm, off): forgets the arm and its confirm notice. */
async function disarm($: EngineInterface) {
  armTimer?.cancel()
  armTimer = undefined
  if (!(await read($, armed).catch(() => null))) return
  await update($, armed, () => null).catch(() => {})
  await update($, notice, n => (n && n.endsWith('again to confirm') ? null : n)).catch(() => {})
}

/** The two state-changing keys: each runs the CLI the XO and the dashboard's commander use. */
const ACTIONS = {
  close: { key: 'c', ask: (sid: string) => `Close ${sid}? press c again to confirm`, argv: (id: string) => ['close', id] },
  complete: { key: 'a', ask: (sid: string) => `Complete ${sid} (accept it as done)? press a again to confirm`, argv: (id: string) => ['accept', id] },
} as const

/**
 * `c` (close) or `a` (complete) on the highlighted card, two presses. The first arms it (an inline
 * confirm with a reset timeout); the same key again on the same row runs the CLI against the
 * resolved home with the task's FULL id: `chartroom close <id>` (keeping the branch, never
 * `--discard`) or `chartroom accept <id>` (a task in review becomes done; nothing is removed). A
 * refusal is shown in the CLI's exact words and nothing is claimed; on success the board re-polls,
 * so the card moves lane as the board says. Inbox items and closed tasks are refused here.
 */
async function act($: EngineInterface, action: keyof typeof ACTIONS) {
  const card = await currentCard($)
  if (!card) return say($, 'nothing highlighted')
  const sid = cardKey(card)
  if (card.type === 'inbox') return say($, `${sid} is an inbox item, not a task: Enter brings it in to answer`)
  if (card.state === 'closed') return say($, `${sid} is already closed`)
  const spec = ACTIONS[action]
  if ((await read($, armed)) === `${action}:${sid}`) {
    armTimer?.cancel()
    armTimer = undefined
    await update($, armed, () => null)
    const ran = await runCli($, [...spec.argv(card.id)]) // the CLI takes the FULL id
    if ('error' in ran) return say($, ran.detail || ran.error) // the CLI's exact refusal, never a fake success
    await say($, ran.stdout.trim().split('\n')[0] || `${action === 'close' ? 'closed' : 'accepted'} ${sid}`)
    await poll($) // so the card moves (or leaves) as the board now says
    return
  }
  await update($, armed, () => `${action}:${sid}`)
  await say($, spec.ask(sid))
  armTimer?.cancel()
  armTimer = $.clock.after(CONFIRM_MS, () => void disarm($))
}

/** `s` on the highlighted task: pre-fill a non-mutating recap request into the chat prompt. */
async function actRecap($: EngineInterface, surface?: RenderSurface) {
  await disarm($) // any other action cancels a pending close
  const card = await currentCard($)
  if (!card) return say($, 'nothing highlighted')
  const sid = cardKey(card)
  const text = `Recap ${sid} (${clean(card.title ?? sid)}): where it stands and what's pending`
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
        description: 'The live Chartroom board (complete/close from the pane): on|off|toggle|refresh|next|prev|focus|pick <id>|default on|off',
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

  // The ring follows the person's arrows/Tab; tracking it as `selected` lets `a`/`c`/`s` and Enter
  // act on the highlighted row. Moving to a different row cancels a pending two-press action.
  on('ui.focus', async ($, e, next) => {
    const moved = await next(e)
    if (e.requestId === PANE && e.plugin === 'chartroom-panel' && e.element?.startsWith('row-') && !moved?.deny) {
      const sid = e.element.slice(4)
      await update($, selected, () => sid).catch(() => {})
      const arm = await read($, armed).catch(() => null)
      if (arm && arm.slice(arm.indexOf(':') + 1) !== sid) await disarm($)
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

    const counts = laneCounts(tasks)
    const header = (
      <Text key="header" weight="bold" color="success" wrap="truncate">
        {snap.tasks === null ? 'Chartroom · board' : `Chartroom · ${counts.needs_you.count} need you`}
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

    // The ring rests on the selected card when it is on this page, else the first card.
    const onPage = view.tasks.map(cardKey)
    const ringId = (sel && onPage.includes(sel) ? sel : onPage[0]) ?? ''

    const cardRows = (c: Card) => {
      const key = cardKey(c)
      const sid = clean(c.short_id ?? '-')
      const title = clean(c.title ?? c.id)
      const titleWidth = Math.max(0, width - columns(sid) - 1)
      return (
        <Box key={`row-${key}`} flexDirection="column">
          <Button key={`row-${key}`} plain {...(key === ringId ? { autoFocus: true as const } : {})} onPress={() => void pick($, key)}>
            <Text color="subtle">{sid}</Text>
            {' '}
            {truncate(title, titleWidth)}
          </Button>
          <Text wrap="truncate" {...TONE_PROPS[laneTone(c.lane)]}>
            {`  ${clean(cardDetail(c))}`}
          </Text>
        </Box>
      )
    }

    // Every lane's header, in the board's order with its total count, then this page's cards in it.
    const body =
      snap.tasks === null
        ? [
            <Text key="empty" dimColor>
              Waiting for the board
            </Text>,
          ]
        : LANES.flatMap(l => [
            <Text key={`lane-${l.key}`} weight="bold" wrap="truncate" {...TONE_PROPS[laneTone(l.key)]}>
              {laneHeader(l.name, counts[l.key])}
            </Text>,
            ...view.tasks.filter(c => c.lane === l.key).map(cardRows),
          ])

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
          // the keyboard), drawn as `a: complete  c: close  s: recap`, then the legend. wrap=truncate
          // keeps it on one line on a narrow pane; the Buttons give way gracefully before the text.
          <Box key="foot-actions" flexDirection="row" flexWrap="wrap">
            <Box marginRight={1}>
              <Button key="act-complete" plain hotkey="a" label="complete" onPress={() => void act($, 'complete')} />
            </Box>
            <Box marginRight={1}>
              <Button key="act-close" plain hotkey="c" label="close" onPress={() => void act($, 'close')} />
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
