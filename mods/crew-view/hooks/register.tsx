// crew-view: chartroom's crew, live in the XO's Claude Code session.
//
// Installed at user scope it loads in every Claude session, crew workers' included. It wakes
// only when both hold: session.start decided this is the XO's session (interactive, cwd is the
// chartroom home, not under worktrees/, not a task's session), and the session has loaded the
// `captain` or `chartroom` skill (skill.prompt: `/captain`, the Skill tool, or a preload). Until
// then it registers nothing, starts no timer, runs no process and draws nothing. Once awake it
// stays awake for the session; $.state keeps that across a hot reload.
//
// The /crew pane browses the board: each item is a Button (Tab or the arrows walk them, Enter
// opens one), and an item opens into its detail (`chartroom show <id> --json`) with actions
// on one-letter hotkeys: continue (`/continue <id>` into the prompt), copy the id or a PR,
// read the report, copy an artifact, back. `q` or Esc closes the pane, `/crew` toggles it,
// and `/crew off` hides the band for the session (`/crew on` brings it back).
//
// The commander's todo list (the board's .todo, lib/todo.jq) sits under the band, built-in todo
// style: the first three items not held by focus mode, `+N more`, and the focus with its held
// count. `/todo` (or `/crew todo`, the same command) toggles a pane of all of it: Tab or the arrows walk the rows, and the row with
// the ring takes `c` (copy: an artifact's text, an inbox item's, a task's id), `d` (done, pressed
// twice: `chartroom todo done`; a task's decision only clears when the XO relays the answer), `o`
// (`/continue <id>` into the prompt) and `a` (show the held items too). `/todo off` hides the
// list, `/todo add <text>` and `/todo done <ref>` run the CLI's. The list follows focus.json and
// inbox.md within seconds (a stat every 3 s, no process), the rest with the board.
//
// The board (`chartroom board --json`) is read when the mod wakes, when a pane opens or a command
// changes something, and otherwise only when the home's change stamp moved: every 15 s the mod
// stats `<home>/.changed` (no process), which chartroom rewrites after each write of what the
// board shows, and reads the board when its mtime differs from the one the last read began with.
// A read at least every 5 minutes, stamp or not, keeps ages and waiting windows current and
// catches what writes without chartroom. An idle home costs one board run per 5 minutes.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderSurface } from 'claude-code'

import type { CrewBoard, CrewDetail, CrewView, TodoItem, TodoList } from '../types'
import { STAMP_FILE, bandSegments, boardDue, configPath, detailActions, detailLines, homesPath, isUnderWorktrees, paneLines, parseBoard, parseDetail, resolveHome, samePath, stampKey } from './crew'
import type { ActionId, Tone } from './crew'
import { doneRefusal, parseTodo, shownItems, todoActions, todoBandLines, todoKey, todoPaneLines } from './todo'
import type { TodoActionId } from './todo'

const PANE = 'crew'
const TODO_PANE = 'todo'
const POLL_MS = 15_000
const WATCH_MS = 3_000

const XO_SKILLS = ['captain', 'chartroom']

const isXo = atom({ plugin: 'crew-view', key: 'isXo' } as const, false)
const active = atom({ plugin: 'crew-view', key: 'active' } as const, false)
const board = atom({ plugin: 'crew-view', key: 'board' } as const, null as CrewBoard | null)
const error = atom({ plugin: 'crew-view', key: 'error' } as const, null as string | null)
const view = atom({ plugin: 'crew-view', key: 'view' } as const, 'list' as CrewView)
const selected = atom({ plugin: 'crew-view', key: 'selected' } as const, null as string | null)
const detail = atom({ plugin: 'crew-view', key: 'detail' } as const, null as CrewDetail | null)
const detailError = atom({ plugin: 'crew-view', key: 'detailError' } as const, null as string | null)
const report = atom({ plugin: 'crew-view', key: 'report' } as const, null as { path: string; text: string } | null)
const notice = atom({ plugin: 'crew-view', key: 'notice' } as const, null as string | null)
const bandOff = atom({ plugin: 'crew-view', key: 'bandOff' } as const, false)
const todo = atom({ plugin: 'crew-view', key: 'todo' } as const, null as TodoList | null)
const todoOff = atom({ plugin: 'crew-view', key: 'todoOff' } as const, false)
const todoSelected = atom({ plugin: 'crew-view', key: 'todoSelected' } as const, null as string | null)
const todoHeld = atom({ plugin: 'crew-view', key: 'todoHeld' } as const, false)
const todoArmed = atom({ plugin: 'crew-view', key: 'todoArmed' } as const, null as string | null)
const todoNotice = atom({ plugin: 'crew-view', key: 'todoNotice' } as const, null as string | null)

const COLOR: Record<Tone, { color?: string; dimColor?: boolean }> = {
  plain: {},
  dim: { dimColor: true },
  warn: { color: 'warning' },
  error: { color: 'error' },
}

/** True when this session is the XO's; reads env and files only, never runs a process. */
async function detectXo($: EngineInterface, cwd: string, isInteractive: boolean): Promise<string | null> {
  if (!isInteractive) return null
  if (await $.env.get('CHARTROOM_TASK')) return null
  if (isUnderWorktrees(cwd)) return null
  const home = (await $.env.get('HOME')) ?? ''
  if (!home) return null
  const cfg = configPath({
    chartroomConfig: await $.env.get('CHARTROOM_CONFIG'),
    xdgConfigHome: await $.env.get('XDG_CONFIG_HOME'),
    home,
  })
  const homes = homesPath(cfg)
  const chartroomHome = resolveHome({
    chartroomHome: await $.env.get('CHARTROOM_HOME'),
    capHome: await $.env.get('CAP_HOME'),
    configText: (await $.fs.exists(cfg)) ? await $.fs.read(cfg) : undefined,
    homesText: (await $.fs.exists(homes)) ? await $.fs.read(homes) : undefined,
    cwd,
    home,
    hasChartroomDir: await $.fs.exists(`${home}/.chartroom`),
    hasCaptainDir: await $.fs.exists(`${home}/.captain`),
  })
  if (samePath(cwd, chartroomHome)) return chartroomHome
  const real = async (p: string) => (await $.fs.stat(p, { resolve: true }).catch(() => undefined))?.realPath
  const [a, b] = await Promise.all([real(cwd), real(chartroomHome)])
  return a && b && samePath(a, b) ? chartroomHome : null
}

/** One `chartroom <args>` run: `chartroom` on PATH, then ~/.local/bin (a thin GUI PATH). It
 * names the XO's home outright, so a session that found its home by its directory (a registered
 * home, no CHARTROOM_HOME) reads that home whatever the CLI would resolve. */
async function runChartroom($: EngineInterface, args: string[]): Promise<{ stdout: string } | { error: string }> {
  const userHome = (await $.env.get('HOME')) ?? ''
  for (const bin of ['chartroom', `${userHome}/.local/bin/chartroom`]) {
    try {
      const ran = await $.process.run([bin, ...args], { timeoutMs: 20_000, ...(home ? { env: { CHARTROOM_HOME: home } } : {}) })
      if (ran.exitCode === 0) return { stdout: ran.stdout }
      if (ran.exitCode === 127) continue
      const why = (ran.stderr.trim().split('\n')[0] ?? '').replace(/^chartroom:\s*/, '')
      return { error: `chartroom ${args[0]} failed${why ? `: ${why}` : ` (exit ${ran.exitCode})`}` }
    } catch (err) {
      // A rejection is a command that could not start, or one still running at the timeout.
      if (/timed? ?out/i.test(String(err))) return { error: `chartroom ${args[0]} timed out` }
    }
  }
  return { error: 'chartroom not found' }
}

// The XO's chartroom home, set by session.start; a reload re-runs it.
let home = ''
let polling = false
// A poll asked for while one runs (after `d`, a file change): it runs again once that one ends.
let pollAgain = false
// focus.json and inbox.md as last stat'ed ("mtime:size" each), so a change polls at once.
let watched = ''
// The change stamp as the last good board read found it when it began, and when it began; null
// until one succeeds (a failed read is tried again the next round).
let lastRead: { stamp: string; at: number } | null = null
// Whether this load of the module has registered /crew and started the timer.
let started = false
// Whether this plugin holds /todo: a person's own /todo (a skill, a command file) keeps the name,
// and then `/crew todo` alone reaches the list.
let hasTodo = false

/** Reads the board into $.state; never throws, never overlaps a run still going. */
async function poll($: EngineInterface): Promise<void> {
  if (polling) {
    pollAgain = true
    return
  }
  polling = true
  try {
    // Taken before the run: a write while it runs moves the stamp past this, and reads again.
    const began = { stamp: await stampNow($), at: await $.clock.now() }
    const ran = await runChartroom($, ['board', '--json'])
    const parsed = 'error' in ran ? ran : parseBoard(ran.stdout)
    if ('error' in parsed) {
      lastRead = null
      await update($, error, () => parsed.error)
    } else if (parsed.board.home && !samePath(parsed.board.home, home)) {
      lastRead = null
      await update($, error, () => `chartroom's home is ${parsed.board.home}, not ${home}`)
    } else {
      const list = 'stdout' in ran ? parseTodo(ran.stdout) : null
      await update($, board, () => parsed.board)
      await update($, todo, () => list)
      await update($, error, () => null)
      lastRead = began
    }
  } catch (err) {
    lastRead = null
    await update($, error, () => `crew view: ${String(err).split('\n')[0]}`).catch(() => {})
  } finally {
    polling = false
  }
  if (pollAgain) {
    pollAgain = false
    return poll($)
  }
  // A detail on screen follows the board; one left open in a closed pane waits for /crew.
  const ref = await read($, selected).catch(() => null)
  if (!ref || (await read($, view)) === 'list') return
  const shown = await $.ui.panes().then(
    panes => panes.some(p => p.id === PANE),
    () => true,
  )
  if (shown) await loadDetail($, ref)
}

// The ids whose `chartroom show` is running, so a poll never stacks a second one.
const loading = new Set<string>()

/** Reads one item's detail into $.state; a reply for an item no longer selected is dropped. */
async function loadDetail($: EngineInterface, ref: string): Promise<void> {
  if (loading.has(ref)) return
  loading.add(ref)
  try {
    const ran = await runChartroom($, ['show', ref, '--json'])
    if ((await read($, selected)) !== ref) return
    const parsed = 'error' in ran ? ran : parseDetail(ran.stdout)
    if ('error' in parsed) {
      await update($, detailError, () => parsed.error)
    } else {
      await update($, detail, () => parsed.detail)
      await update($, detailError, () => null)
    }
  } catch (err) {
    await update($, detailError, () => `crew view: ${String(err).split('\n')[0]}`).catch(() => {})
  } finally {
    loading.delete(ref)
  }
}

/** Moves the pane's focus ring onto `key`; a pane not holding the keys says no, which is fine. */
function focusOn($: EngineInterface, key: string) {
  void $.ui.focus({ requestId: PANE, key }).catch(() => {})
}

/** Opens an item's detail: the board's card at once, `chartroom show` when it answers. */
async function openItem($: EngineInterface, ref: string): Promise<void> {
  await update($, selected, () => ref)
  await update($, view, () => 'detail')
  await update($, notice, () => null)
  await update($, detailError, () => null)
  await update($, detail, d => (d?.ref === ref ? d : null))
  focusOn($, 'act-continue')
  await loadDetail($, ref)
}

async function back($: EngineInterface): Promise<void> {
  const from = await read($, view)
  const ref = await read($, selected)
  await update($, notice, () => null)
  if (from === 'report') {
    await update($, view, () => 'detail')
    focusOn($, 'act-report')
    return
  }
  await update($, view, () => 'list')
  if (ref) focusOn($, `row-${ref}`)
}

async function say($: EngineInterface, text: string) {
  await update($, notice, () => text)
}

/** Puts `text` on the clipboard of the surface the press came from; returns how it went. */
async function copied($: EngineInterface, text: string, what: string, surface?: RenderSurface): Promise<string> {
  const done = await $.ui.copy({ text, ...(surface ? { surface } : {}) })
  return done.isCopied ? `copied ${what}` : `could not copy ${what} (${done.reason}): ${text}`
}

async function copy($: EngineInterface, text: string, what: string, surface?: RenderSurface) {
  await say($, await copied($, text, what, surface))
}

/** `/continue <id>` into an empty prompt; a draft is never replaced: then it is copied. Returns what happened. */
async function continued($: EngineInterface, ref: string, surface?: RenderSurface): Promise<string> {
  const line = `/continue ${ref}`
  const box = await $.prompt.read()
  if (box.text.trim() === '') {
    const filled = await $.prompt.fill({ text: line, mode: 'replace' })
    // The fill hands the keys to the prompt: Enter runs it.
    if (filled.isFilled) return `${line} is in the prompt: press Enter to run it`
  }
  const done = await $.ui.copy({ text: line, ...(surface ? { surface } : {}) })
  const why = box.text.trim() ? 'the prompt holds a draft, kept' : 'the prompt cannot take it now'
  return done.isCopied ? `${line} copied (${why}): paste it at the prompt` : `${why}; type ${line}`
}

async function continueItem($: EngineInterface, ref: string, surface?: RenderSurface) {
  await say($, await continued($, ref, surface))
}

async function openReport($: EngineInterface) {
  const d = await read($, detail)
  if (!d?.report) return say($, 'no report yet')
  try {
    const text = await $.fs.read(d.report.path)
    await update($, report, () => ({ path: d.report?.path ?? '', text }))
    await update($, view, () => 'report')
    focusOn($, 'act-back')
  } catch (err) {
    await say($, `could not read ${d.report.path}: ${String(err).split('\n')[0]}`)
  }
}

async function copyArtifact($: EngineInterface, index: number, surface?: RenderSurface) {
  const a = (await read($, detail))?.artifacts[index]
  if (!a) return
  const ran = await runChartroom($, ['artifact', 'show', a.ref])
  if ('error' in ran) return say($, ran.error)
  await copy($, ran.stdout, `artifact ${a.ref}`, surface)
}

async function act($: EngineInterface, id: ActionId, surface?: RenderSurface) {
  const ref = await read($, selected)
  const d = await read($, detail)
  if (id === 'back') return back($)
  if (id === 'report') return openReport($)
  if (id === 'copy-artifact') return copyArtifact($, 0, surface)
  if (id === 'copy-pr') return d?.prs[0] ? copy($, d.prs[0].url, d.prs[0].url, surface) : undefined
  if (!ref) return
  if (id === 'continue') return continueItem($, ref, surface)
  if (id === 'copy-id') return copy($, ref, ref, surface)
}

async function openPane($: EngineInterface) {
  void poll($)
  // One chartroom pane at a time: the crew's takes the todo list's place.
  if (await isOpen($, false, TODO_PANE)) await closePane($, TODO_PANE)
  // Esc closes it, from the pane or from an idle, empty prompt, as `q` and `/crew` do.
  return $.ui.open({ id: PANE, title: 'Crew', focus: true, closeOnEscape: true })
}

/** True while the pane (`id`, the crew's by default) is open, shown or behind another pane's tab. */
async function isOpen($: EngineInterface, shownOnly = false, id = PANE): Promise<boolean> {
  const panes = await $.ui.panes().catch(() => [])
  return panes.some(p => p.id === id && (!shownOnly || p.isShown))
}

/** A closed pane opens next on the lanes; a closed todo pane forgets its notice and a half-done `d`. */
async function rest($: EngineInterface, id = PANE) {
  if (id === TODO_PANE) {
    await update($, todoNotice, () => null)
    await update($, todoArmed, () => null)
    return
  }
  await update($, view, () => 'list')
  await update($, notice, () => null)
}

/** Closes a pane. The plugin's own close passes beneath its ui.close hook: it rests here. */
async function closePane($: EngineInterface, id = PANE) {
  await $.ui.close({ id }).catch(() => {})
  await rest($, id)
}

/** True while something shows the board: the band, the todo list, or either pane. */
async function showing($: EngineInterface): Promise<boolean> {
  if (!(await read($, bandOff).catch(() => false)) || !(await read($, todoOff).catch(() => false))) return true
  return (await isOpen($)) || (await isOpen($, false, TODO_PANE))
}

/** The home's change stamp now (`mtime:size`, `-` while there is none); a stat, no process. */
async function stampNow($: EngineInterface): Promise<string> {
  return $.fs.stat(`${home}/${STAMP_FILE}`).then(stampKey, () => '-')
}

/** The timer's round: reads the board once the stamp moved or the slow refresh is due; nothing while nothing shows it. */
async function tick($: EngineInterface) {
  // A read under way took the stamp as it began; what moves it meanwhile shows the next round.
  if (polling || !(await showing($))) return
  if (boardDue(lastRead, await stampNow($), await $.clock.now())) await poll($)
}

/** Polls at once when focus.json or inbox.md changed: focus mode turned on or off, an item added or ticked. */
async function watchFiles($: EngineInterface) {
  if (!(await showing($))) return
  const stamp = (f: string) => $.fs.stat(`${home}/${f}`).then(s => `${s.mtimeMs}:${s.size}`, () => '-')
  const now = (await Promise.all([stamp('focus.json'), stamp('inbox.md')])).join('|')
  const changed = watched !== '' && now !== watched
  watched = now
  if (changed) await poll($)
}

// ---------------------------------------------------------------- the todo list

async function todoSay($: EngineInterface, text: string | null) {
  await update($, todoNotice, () => text)
}

/** The /todo pane's rows that hold an item, as drawn, with their keys. */
function todoRows(list: TodoList, withHeld: boolean): { key: string; item: TodoItem }[] {
  const keyed = list.items.map((item, i) => ({ key: todoKey(item, i), item }))
  const next = keyed.filter(r => !r.item.held)
  return withHeld ? [...next, ...keyed.filter(r => r.item.held)] : next
}

/** The selected row: the one the ring or a press last chose, else the first. */
async function todoCurrent($: EngineInterface): Promise<{ key: string; item: TodoItem } | null> {
  const list = await read($, todo)
  if (!list) return null
  const rows = todoRows(list, await read($, todoHeld))
  const sel = await read($, todoSelected)
  return rows.find(r => r.key === sel) ?? rows[0] ?? null
}

async function openTodo($: EngineInterface) {
  void poll($)
  // One chartroom pane at a time: the todo list takes the crew pane's place.
  if (await isOpen($)) await closePane($)
  return $.ui.open({ id: TODO_PANE, title: 'Todo', focus: true, closeOnEscape: true })
}

async function toggleTodo($: EngineInterface): Promise<{ text: string }> {
  if (await isOpen($, true, TODO_PANE)) {
    await closePane($, TODO_PANE)
    return { text: 'Todo pane closed.' }
  }
  const opened = await openTodo($)
  return { text: opened.isPlaced ? 'Todo pane opened.' : 'Todo pane is waiting for room: widen the terminal.' }
}

/**
 * `/todo` (or the name it got) toggles the pane; `off` hides the list above the prompt (and the
 * pane) for the session, `on` brings it back; `add <text>` and `done <ref>` run the CLI's.
 */
async function todoRun($: EngineInterface, argText: string, name: string): Promise<{ text: string }> {
  const words = argText.trim().split(/\s+/).filter(Boolean)
  const [sub, ...rest] = words
  if (sub === 'off') {
    await update($, todoOff, () => true)
    await closePane($, TODO_PANE)
    return { text: `Todo list off for this session: /${name} on brings it back; /${name} still opens the pane.` }
  }
  if (sub === 'on') {
    await update($, todoOff, () => false)
    void poll($)
    return { text: 'Todo list on.' }
  }
  if (sub === 'add' || sub === 'done') {
    const flagged = sub === 'add' && rest[0] === '--project'
    const args = flagged ? ['--project', rest[1] ?? '', rest.slice(2).join(' ')] : [rest.join(' ')]
    if (!args.at(-1)) return { text: sub === 'add' ? `usage: /${name} add [--project P] <text>` : `usage: /${name} done <ref> (as the list shows it: i-7f3a, 21ba/reply-to-review)` }
    const ran = await runChartroom($, ['todo', sub, ...args])
    void poll($)
    if ('error' in ran) return { text: ran.error }
    return { text: sub === 'add' ? `added ${ran.stdout.trim()}: ${args.at(-1)}` : ran.stdout.trim() }
  }
  if (sub) return { text: `usage: /${name} [on|off|add [--project P] <text>|done <ref>]` }
  return toggleTodo($)
}

/** `/todo`, or `/crew todo` where the person's own /todo holds the name: what the hints say. */
function todoName(): string {
  return hasTodo ? '/todo' : '/crew todo'
}

/** Ticks the row off: a first `d` arms it, a second runs `chartroom todo done`, then the ring moves on. */
async function todoDone($: EngineInterface, row: { key: string; item: TodoItem }) {
  const why = doneRefusal(row.item)
  if (why) return todoSay($, why)
  if ((await read($, todoArmed)) !== row.key) {
    await update($, todoArmed, () => row.key)
    return todoSay($, `d again ticks off ${row.item.ref}: ${row.item.label}`)
  }
  await update($, todoArmed, () => null)
  const ran = await runChartroom($, ['todo', 'done', row.item.ref ?? ''])
  if ('error' in ran) return todoSay($, ran.error)
  const list = await read($, todo)
  const rows = list ? todoRows(list, await read($, todoHeld)) : []
  const at = rows.findIndex(r => r.key === row.key)
  const nextKey = (rows[at + 1] ?? rows[at - 1])?.key ?? null
  await update($, todo, l => (l ? { ...l, items: l.items.filter(i => i.ref !== row.item.ref) } : l))
  await update($, todoSelected, () => nextKey)
  await todoSay($, ran.stdout.trim().split('\n')[0] || `done ${row.item.ref}`)
  if (nextKey) void $.ui.focus({ requestId: TODO_PANE, key: nextKey }).catch(() => {})
  await poll($)
}

async function todoAct($: EngineInterface, id: TodoActionId, surface?: RenderSurface) {
  if (id === 'held') {
    await update($, todoHeld, h => !h)
    return todoSay($, null)
  }
  const row = await todoCurrent($)
  if (!row) return todoSay($, 'nothing on the list')
  if (id === 'done') return todoDone($, row)
  await update($, todoArmed, () => null)
  const { item } = row
  if (id === 'continue') return item.owner ? todoSay($, await continued($, item.owner, surface)) : undefined
  if (item.type === 'artifact' && item.ref) {
    const ran = await runChartroom($, ['artifact', 'show', item.ref])
    return todoSay($, 'error' in ran ? ran.error : await copied($, ran.stdout, `artifact ${item.ref}`, surface))
  }
  if (item.type === 'task') return todoSay($, await copied($, item.owner ?? '', item.owner ?? 'the id', surface))
  await todoSay($, await copied($, item.text, item.ref ?? 'the item', surface))
}

/** True when this is the XO's session and it has loaded the captain or chartroom skill. */
async function isActive($: EngineInterface): Promise<boolean> {
  return (await read($, isXo)) && (await read($, active))
}

/** Registers /crew, reads the board and starts the poll; once per load of the module. */
async function start($: EngineInterface): Promise<void> {
  if (started) return
  started = true
  await $.command.register({ name: 'crew', description: "Toggle chartroom's crew pane; /crew <id> opens an item, /crew todo the todo list, /crew off hides the band" }).catch(() => {})
  hasTodo = await $.command
    .register({ name: 'todo', description: 'Toggle your todo list (what the crew waits on you for); /todo off hides it, /todo add <text>, /todo done <ref>' })
    .then(
      () => true,
      () => false,
    )
  void poll($)
  $.clock.every(POLL_MS, () => void tick($))
  $.clock.every(WATCH_MS, () => void watchFiles($))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const xo = await detectXo($, e.cwd, e.isInteractive).catch(() => null)
    await update($, isXo, () => xo !== null)
    if (xo === null) return next(e)
    home = xo
    // A hot reload of a session that already loaded the skill picks up where it was.
    if (await read($, active)) await start($)
    return next(e)
  })

  // `/captain`, `/chartroom`, the Skill tool or a preload: the session is the XO's in earnest.
  // A plugin's skill arrives as `plugin:skill`. The prompt text passes through untouched.
  on('skill.prompt', async ($, e, next) => {
    const name = e.skill.split(':').pop() ?? ''
    if (XO_SKILLS.includes(name) && (await read($, isXo))) {
      await update($, active, () => true)
      await start($)
    }
    return next(e)
  })

  // /crew exists only once start() registered it. Bare, it toggles the pane; `/crew <id>`
  // opens that item; `/crew off` hides the band (and the pane) for the session, `/crew on`
  // brings the band back.
  on('command.run', { command: 'crew' }, async ($, e) => {
    const ref = e.args.trim().replace(/^\[|\]$/g, '')
    if (ref === 'todo' || ref.startsWith('todo ')) return todoRun($, ref.slice(4), 'crew todo')
    if (ref === 'off') {
      await update($, bandOff, () => true)
      await closePane($)
      return { text: 'Crew band off for this session: /crew on brings it back; /crew still opens the pane.' }
    }
    if (ref === 'on') {
      await update($, bandOff, () => false)
      void poll($)
      return { text: 'Crew band on.' }
    }
    if (ref) void openItem($, ref)
    else if (await isOpen($, true)) {
      await closePane($)
      return { text: 'Crew pane closed.' }
    }
    const opened = await openPane($)
    return { text: opened.isPlaced ? 'Crew pane opened.' : 'Crew pane is waiting for room: widen the terminal.' }
  })

  // The todo command (todoRun), when this plugin holds /todo; a person's own /todo passes by
  // untouched.
  on('command.run', { command: 'todo' }, async ($, e, next) => (hasTodo ? todoRun($, e.args, 'todo') : next(e)))


  // The person's close (Esc, the close mark) rests the pane as closePane does.
  on('ui.close', async ($, e, next) => {
    const closed = await next(e)
    if (e.id === PANE || e.id === TODO_PANE) await rest($, e.id)
    return closed
  })

  // The todo pane's selection follows the ring, so `d` and `c` act on the row it is on.
  on('ui.focus', async ($, e, next) => {
    const moved = await next(e)
    if (e.requestId === TODO_PANE && e.plugin === 'crew-view' && e.element?.startsWith('todo-') && !moved?.deny) {
      await update($, todoSelected, () => e.element ?? null).catch(() => {})
    }
    return moved
  })

  // The band: the crew's line, then the todo list nearest the prompt (each hidden by its `off`).
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || !(await isActive($))) return next(e)
    const b = (await read($, bandOff)) ? null : await read($, board)
    const err = (await read($, bandOff)) ? null : await read($, error)
    const list = (await read($, todoOff)) ? null : await read($, todo)
    const width = Math.max(10, e.props.bodyColumns - 9)
    const crew = b || err
    const rows = list ? todoBandLines(list, width, Math.min(3, Math.max(1, e.props.maxRows - (crew ? 2 : 1)))) : []
    if (!crew && !rows.length) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {crew ? (
          <Box key="crew" flexDirection="row">
            <Box flexGrow={1}>
              {b ? (
                <Text wrap="truncate">
                  {bandSegments(b, width).map(s => (
                    <Text {...COLOR[s.tone]}>{s.text}</Text>
                  ))}
                  {err ? <Text dimColor> ({err})</Text> : null}
                </Text>
              ) : (
                <Text dimColor wrap="truncate">
                  ⚓ {err}
                </Text>
              )}
            </Box>
            <Button key="open" label="crew" hotkey="c" onPress={() => void openPane($)} />
          </Box>
        ) : null}
        {rows.map((r, i) =>
          i === 0 ? (
            <Box key="todo-band" flexDirection="row">
              <Box flexGrow={1}>
                <Text wrap="truncate" {...COLOR[r.tone]}>
                  {r.text}
                </Text>
              </Box>
              <Button key="todo-open" label="todo" hotkey="t" onPress={() => void openTodo($)} />
            </Box>
          ) : (
            <Text key={r.key} wrap="truncate" {...COLOR[r.tone]}>
              {r.text}
            </Text>
          ),
        )}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: TODO_PANE }, async ($, e, next) => {
    if (!(await isActive($))) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, todo)
    const err = await read($, error)
    const withHeld = await read($, todoHeld)
    const note = await read($, todoNotice)
    const b = await read($, board)
    const width = e.props.bodyColumns
    const head = (
      <Box key="head" flexDirection="row">
        <Box flexShrink={0}>
          <Button key="todo-close" plain hotkey="q" label="close" role="dismiss" onPress={() => void closePane($, TODO_PANE)} />
        </Box>
        <Text dimColor wrap="truncate">
          {'  '}Esc closes too · {todoName()} toggles · {todoName()} off hides the list
        </Text>
      </Box>
    )
    if (!list) {
      return (
        <Box flexDirection="column">
          {head}
          <Text dimColor>{err ?? (b ? 'This chartroom keeps no todo list: update it (chartroom todo).' : 'Reading the list…')}</Text>
        </Box>
      )
    }
    const current = await todoCurrent($)
    const lines = todoPaneLines(list, width, await $.clock.now(), { selected: current?.key ?? null, withHeld })
    return (
      <Box flexDirection="column">
        {head}
        <Box flexDirection="row" flexWrap="wrap">
          {todoActions(current?.item ?? null, list, withHeld).map(a => (
            <Box key={`box-${a.id}`} marginRight={2}>
              <Button key={`todo-act-${a.id}`} plain hotkey={a.hotkey} label={a.label} onPress={press => void todoAct($, a.id, press.surface)} />
            </Box>
          ))}
        </Box>
        {note ? (
          <Text key="todo-notice" color="success" wrap="truncate">
            {note}
          </Text>
        ) : null}
        {lines.map(line =>
          line.item ? (
            <Button
              key={line.key}
              plain
              label={line.text}
              {...(line.tone === 'dim' ? { dimColor: true } : {})}
              {...(line.key === current?.key ? { autoFocus: true as const } : {})}
              onPress={() => void update($, todoSelected, () => line.key).then(() => update($, todoArmed, () => null))}
            />
          ) : (
            <Text key={line.key} bold={line.bold} wrap="truncate" {...COLOR[line.tone]}>
              {line.text}
            </Text>
          ),
        )}
        <Text dimColor wrap="truncate">
          {shownItems(list, withHeld).length ? 'the row with the ring: d done (twice), c copy, o continue · ' : ''}
          {e.props.isFocused ? 'Tab/arrows move' : `${todoName()} closes, ctrl+x tab to use the keys`}
          {err ? ` · last poll: ${err}` : ''}
        </Text>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    if (!(await isActive($))) return next(e)
    const { Box, Text, Button, Markdown } = $.ui.resolve(e)
    const b = await read($, board)
    const err = await read($, error)
    const shown = await read($, view)
    const ref = await read($, selected)
    const note = await read($, notice)
    const width = e.props.bodyColumns
    const now = await $.clock.now()
    const noticeLine = note ? (
      <Text key="notice" color="success" wrap="truncate">
        {note}
      </Text>
    ) : null
    // Every view's first row says how to close the pane; `q` presses it. The buttons keep
    // their width: the row's text is what gives way.
    const closeButton = (
      <Box flexShrink={0}>
        <Button key="act-close" plain hotkey="q" label="close" role="dismiss" onPress={() => void closePane($)} />
      </Box>
    )
    const head = (hint: string) => (
      <Box key="head" flexDirection="row">
        {closeButton}
        <Text dimColor wrap="truncate">
          {'  '}
          {hint}
        </Text>
      </Box>
    )

    if (shown === 'report' && ref) {
      const r = await read($, report)
      return (
        <Box flexDirection="column">
          <Box key="head" flexDirection="row">
            <Box flexShrink={0} marginRight={2}>
              <Button key="act-back" plain autoFocus hotkey="b" label="back" onPress={() => void back($)} />
            </Box>
            {closeButton}
            <Text dimColor wrap="truncate">
              {'  '}
              {r?.path ?? ''}
            </Text>
          </Box>
          <Markdown text={r?.text ?? ''} />
        </Box>
      )
    }

    if (shown === 'detail' && ref) {
      const d = await read($, detail)
      const dErr = await read($, detailError)
      const card = d ? null : b ? paneLines(b, width, now).find(l => l.ref === ref) : undefined
      const lines = d ? detailLines(d, width, now) : []
      const draw = (line: (typeof lines)[number]) =>
        line.press ? (
          <Button
            key={line.key}
            plain
            label={line.text}
            onPress={press =>
              void (line.press?.kind === 'pr'
                ? copy($, d?.prs[line.press.index]?.url ?? '', 'the PR URL', press.surface)
                : copyArtifact($, line.press?.index ?? 0, press.surface))
            }
          />
        ) : (
          <Text key={line.key} bold={line.bold} wrap="truncate" {...COLOR[line.tone]}>
            {line.text}
          </Text>
        )
      // The head (title, state), then the actions and what the last one did, then the sections:
      // the actions stay in sight however long the detail, and lead the focus ring.
      return (
        <Box flexDirection="column">
          {head('Esc closes too · b back to the lanes')}
          {d ? (
            lines.slice(0, 2).map(draw)
          ) : (
            <Text key="loading" dimColor wrap="truncate">
              {card ? card.text.trim() : ref} · {dErr ?? 'reading…'}
            </Text>
          )}
          <Box flexDirection="row" flexWrap="wrap">
            {detailActions(ref, d).map(a => (
              <Box key={`box-${a.id}`} marginRight={2}>
                <Button key={`act-${a.id}`} plain {...(a.id === 'continue' ? { autoFocus: true as const } : {})} hotkey={a.hotkey} label={a.label} onPress={press => void act($, a.id, press.surface)} />
              </Box>
            ))}
          </Box>
          {noticeLine}
          {lines.slice(2).map(draw)}
          {d && dErr ? (
            <Text key="detail-error" dimColor wrap="truncate">
              last read: {dErr}
            </Text>
          ) : null}
        </Box>
      )
    }

    const listHead = head('Esc closes too · /crew toggles · /crew off hides the band')
    if (!b) {
      return (
        <Box flexDirection="column">
          {listHead}
          <Text dimColor>{err ?? 'Reading the board…'}</Text>
        </Box>
      )
    }
    const lines = paneLines(b, width, now)
    // The ring starts on the row last opened, else the first, never on close.
    const first = lines.find(l => l.ref === ref)?.ref ?? lines.find(l => l.ref)?.ref
    return (
      <Box flexDirection="column">
        {listHead}
        {lines.map(line =>
          line.ref ? (
            <Button key={`row-${line.ref}`} plain label={line.text} {...(line.tone === 'dim' ? { dimColor: true } : {})} {...(line.ref === first ? { autoFocus: true as const } : {})} onPress={() => void openItem($, line.ref ?? '')} />
          ) : (
            <Text key={line.key} bold={line.bold} wrap="truncate" {...COLOR[line.tone]}>
              {line.text}
            </Text>
          ),
        )}
        <Text dimColor wrap="truncate">
          updated {b.generated_at.slice(11, 19) || '?'}Z{err ? ` · last poll: ${err}` : ''} ·{' '}
          {e.props.isFocused ? 'Tab/arrows move, Enter opens' : '/crew closes, ctrl+x tab to browse'}
        </Text>
      </Box>
    )
  })
}
