// Pure helpers for the commander's todo list (`board --json`'s .todo, lib/todo.jq): the band's
// rows, the /todo pane's rows and the actions. No `$`, so the tests and pi call them directly.
import type { TodoFocus, TodoItem, TodoList } from '../types'
import { age, columns, fit } from './crew'
import type { Tone } from './crew'

function str(v: unknown): string | null {
  return typeof v === 'string' && v !== '' ? v : null
}

function focusOf(raw: unknown): TodoFocus | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  const words = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x !== '') : [])
  const projects = words(r.projects)
  if (!projects.length) return null
  const scope = words(r.scope)
  return { name: `${projects.join(', ')}${scope.length ? ` (${scope.join(', ')})` : ''}`, since: str(r.since), until: str(r.until) }
}

function itemOf(raw: unknown): TodoItem | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  const label = str(r.label) ?? str(r.text)
  if (!label) return null
  return {
    ref: str(r.ref),
    type: str(r.type) ?? 'inbox',
    kind: str(r.kind) ?? 'inbox',
    owner: str(r.owner),
    project: str(r.project),
    text: str(r.text) ?? label,
    label,
    due: str(r.due),
    since: str(r.since),
    breaking: r.breaking === true,
    held: r.held === true,
    tickable: r.tickable === true,
  }
}

/** `chartroom board --json` output to its todo list; null when it has none (an older chartroom) or is unreadable. */
export function parseTodo(stdout: string): TodoList | null {
  let raw: unknown
  try {
    raw = JSON.parse(stdout)
  } catch {
    return null
  }
  const t = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>).todo : undefined
  if (typeof t !== 'object' || t === null) return null
  const r = t as Record<string, unknown>
  const items = Array.isArray(r.items) ? r.items.map(itemOf).filter((x): x is TodoItem => x !== null) : []
  return { focus: focusOf(r.focus), held: items.filter(i => i.held).length, items }
}

/** The items the list shows: those focus mode does not hold, or all of them. */
export function shownItems(list: TodoList, withHeld = false): TodoItem[] {
  return withHeld ? list.items : list.items.filter(i => !i.held)
}

/** A due date as the rows print it: `10-22`, or `10-22 06:00Z` when it has a time. */
export function dueText(iso: string): string {
  const day = iso.slice(5, 10)
  return /T00:00:00Z$/.test(iso) ? day : `${day} ${iso.slice(11, 16)}Z`
}

/** The row's key: by ref, so it follows the item when the list reorders. */
export function todoKey(item: TodoItem, index: number): string {
  return `todo-${item.ref ?? `n${index}`}`
}

/** `☐ [project] owner label`, then ` · due …`, fitted to `width` (the label gives way first). */
export function todoText(item: TodoItem, width: number): string {
  const head = `☐ ${item.project ? `[${item.project}] ` : ''}${item.owner ? `${item.owner} ` : ''}`
  const tail = item.due ? ` · due ${dueText(item.due)}` : ''
  const room = width - columns(head) - columns(tail)
  if (room < 8) return fit(`${head}${item.label}${tail}`, width).trimEnd()
  return `${head}${columns(item.label) > room ? fit(item.label, room) : item.label}${tail}`
}

/** One line of the todo band or pane; an item's row carries its key (a Button in the pane). */
export type TodoLine = { key: string; text: string; tone: Tone; bold?: boolean; item?: TodoItem }

function itemTone(item: TodoItem): Tone {
  return item.breaking ? 'error' : item.held ? 'dim' : 'plain'
}

/** `🎯 shop (IR-6) · 4 held`, or nothing while focus is off. */
export function focusText(list: TodoList): string {
  return list.focus ? `🎯 ${list.focus.name} · ${list.held} held` : ''
}

/**
 * The band's rows, built-in todo style: the first `max` items not held, then one line with
 * `+N more` and, while focus mode is on, the focus and how many it holds. Nothing at all when
 * nothing is owed and focus is off.
 */
export function todoBandLines(list: TodoList, width: number, max = 3): TodoLine[] {
  const shown = shownItems(list)
  const focus = focusText(list)
  if (!shown.length) return focus ? [{ key: 'todo-summary', text: fit(`${focus} · nothing in focus waiting on you`, width).trimEnd(), tone: 'warn' }] : []
  const n = Math.max(1, max)
  const rows: TodoLine[] = shown.slice(0, n).map((item, i) => ({ key: todoKey(item, i), text: todoText(item, width), tone: itemTone(item), item }))
  const more = shown.length - rows.length
  const summary = [more > 0 ? `+${more} more` : '', focus].filter(Boolean).join(' · ')
  if (summary) rows.push({ key: 'todo-summary', text: fit(`  ${summary}`, width).trimEnd(), tone: focus ? 'warn' : 'dim' })
  return rows
}

/**
 * The /todo pane's lines: the focus line while focus is on, then NEXT STEPS, one row per item
 * (`☐ [project] owner label due age`, the selected one marked `▸`), and the held ones under
 * HELD when `withHeld`.
 */
export function todoPaneLines(list: TodoList, width: number, nowMs: number, opts: { selected?: string | null; withHeld?: boolean } = {}): TodoLine[] {
  const all = shownItems(list, opts.withHeld)
  const proj = (i: TodoItem) => (i.project ? `[${i.project}]` : '')
  const projW = Math.max(0, ...all.map(i => columns(proj(i))))
  const idW = Math.max(4, ...all.map(i => columns(i.owner ?? '-')))
  const dueW = Math.max(0, ...all.map(i => (i.due ? columns(`due ${dueText(i.due)}`) : 0)))
  const fixed = 4 + (projW ? projW + 1 : 0) + idW + 1 + (dueW ? dueW + 1 : 0) + 1 + 3
  const labelW = Math.max(8, width - fixed)
  const lines: TodoLine[] = []
  const focus = focusText(list)
  if (focus) lines.push({ key: 'todo-focus', text: fit(`${focus}${list.held && !opts.withHeld ? ' · a shows them' : ''}`, width).trimEnd(), tone: 'warn', bold: true })
  const row = (item: TodoItem, i: number): TodoLine => {
    const key = todoKey(item, i)
    const mark = key === opts.selected ? '▸' : ' '
    const due = item.due ? `due ${dueText(item.due)}` : ''
    const parts = [`${mark} ☐`, ...(projW ? [proj(item).padEnd(projW)] : []), (item.owner ?? '-').padEnd(idW), fit(item.label, labelW), ...(dueW ? [due.padEnd(dueW)] : []), age(item.since, nowMs).padStart(3)]
    return { key, text: parts.join(' '), tone: itemTone(item), item }
  }
  const shown = list.items.map((item, i) => ({ item, i })).filter(x => !x.item.held)
  lines.push({ key: 'todo-h-next', text: `NEXT STEPS (${shown.length})`, tone: 'plain', bold: true })
  if (!shown.length) lines.push({ key: 'todo-empty', text: '  nothing waiting on you', tone: 'dim' })
  for (const { item, i } of shown) lines.push(row(item, i))
  if (opts.withHeld && list.held) {
    lines.push({ key: 'todo-h-held', text: `HELD BY FOCUS (${list.held})`, tone: 'dim', bold: true })
    for (const [i, item] of list.items.entries()) if (item.held) lines.push(row(item, i))
  }
  return lines
}

export type TodoActionId = 'copy' | 'done' | 'continue' | 'held'
export type TodoAction = { id: TodoActionId; hotkey: string; label: string }

/** The pane's actions for the selected item: copy, done, continue; show or hide the held ones. */
export function todoActions(item: TodoItem | null, list: TodoList, withHeld: boolean): TodoAction[] {
  const out: TodoAction[] = []
  if (item) {
    out.push({ id: 'copy', hotkey: 'c', label: item.type === 'artifact' ? 'copy text' : item.type === 'task' ? 'copy id' : 'copy' })
    out.push({ id: 'done', hotkey: 'd', label: 'done' })
    if (item.owner) out.push({ id: 'continue', hotkey: 'o', label: 'continue' })
  }
  if (list.held) out.push({ id: 'held', hotkey: 'a', label: withHeld ? 'hide held' : 'show held' })
  return out
}

/** Why `d` cannot tick this item off, or null when it can. */
export function doneRefusal(item: TodoItem): string | null {
  if (item.tickable && item.ref) return null
  if (item.type === 'task') {
    if (item.kind === 'ready') return `${item.owner ?? 'this task'} is finished work awaiting your review: it clears when you accept or close it (o: /continue ${item.owner ?? ''})`.replace(/ \)$/, ')')
    const what = item.kind === 'decision' ? 'waits on your decision' : 'is blocked on you'
    return `${item.owner ?? 'this task'} ${what}: it clears when the XO relays your answer (o: /continue ${item.owner ?? ''})`.replace(/ \)$/, ')')
  }
  return 'this inbox line has no id yet, so it cannot be ticked (chartroom inbox tag gives it one)'
}
