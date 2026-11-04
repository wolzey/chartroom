// crew-view for pi: chartroom's crew, live in the XO's pi session. The pair of mods/crew-view
// (Claude Code), drawn from the same pure helpers (../crew-view/hooks/crew.ts).
//
// Loaded in every pi session, it wakes only when both hold: session_start decided this is the
// XO's session (the interactive TUI, cwd is the chartroom home, not under worktrees/, no
// CHARTROOM_TASK), and the session loads the `captain` or `chartroom` skill (`/skill:captain`,
// or the model reading that skill's SKILL.md). Until then it registers nothing, starts no
// timer, runs no process and draws nothing. Once awake it stays awake for the session: a
// session entry records it, so /reload and a resumed session wake again at session_start.
//
// Awake: a one-line band above the editor, read from `chartroom board --json` when the home's
// change stamp moves (`<home>/.changed`, stat'ed every 15 s; no process between changes) and at
// least every 5 minutes, and `/crew [id]`, a browser of the lanes (up/down, Enter) with an item's detail
// (`chartroom show <id> --json`) and its actions: c continue (`/skill:continue <id>` into the
// editor), y copy the id, p copy a PR, r read the report, a copy an artifact, b back, q close.
// `/crew off` hides the band for the session, `/crew on` brings it back.
//
// The commander's todo list (the board's .todo) sits under the band: the first three items not
// held by focus mode, `+N more`, the focus and its held count. `/todo` opens a browser of all of
// it (up/down; c copy, d done twice, o continue, a the held ones, q close); `/todo off` hides the
// list, `/todo add <text>` and `/todo done <ref>` run the CLI's. A change to focus.json or
// inbox.md polls within 3 s.
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs'

import { copyToClipboard, getMarkdownTheme } from '@earendil-works/pi-coding-agent'
import type { ExtensionAPI, ExtensionContext, Theme } from '@earendil-works/pi-coding-agent'
import { Markdown, matchesKey, truncateToWidth } from '@earendil-works/pi-tui'
import type { Component, TUI } from '@earendil-works/pi-tui'

import type { CrewBoard, CrewDetail, TodoItem, TodoList } from '../crew-view/types'
import { STAMP_FILE, bandSegments, boardDue, configPath, detailActions, detailLines, homesPath, isUnderWorktrees, paneLines, parseBoard, parseDetail, resolveHome, samePath, stampKey } from '../crew-view/hooks/crew'
import type { ActionId, PaneLine, Tone } from '../crew-view/hooks/crew'
import { doneRefusal, parseTodo, todoActions, todoBandLines, todoKey, todoPaneLines } from '../crew-view/hooks/todo'
import type { TodoActionId } from '../crew-view/hooks/todo'

const POLL_MS = 15_000
const XO_SKILLS = /^\/skill:(captain|chartroom)(\s|$)/
const XO_SKILL_FILE = /(^|[\\/])(captain|chartroom)[\\/]SKILL\.md$/
const ENTRY = 'chartroom-crew-view'
const BAND_ENTRY = 'chartroom-crew-view-band'
const TODO_ENTRY = 'chartroom-crew-view-todo'
const WIDGET = 'chartroom-crew'
const WATCH_MS = 3_000

/** The chartroom home when this session is the XO's; reads env and files only, never runs a process. */
function detectXo(ctx: ExtensionContext): string | null {
  if (ctx.mode !== 'tui') return null
  const env = process.env
  if (env.CHARTROOM_TASK) return null
  if (isUnderWorktrees(ctx.cwd)) return null
  const home = env.HOME ?? ''
  if (!home) return null
  const cfg = configPath({ chartroomConfig: env.CHARTROOM_CONFIG, xdgConfigHome: env.XDG_CONFIG_HOME, home })
  const homes = homesPath(cfg)
  const chartroomHome = resolveHome({
    chartroomHome: env.CHARTROOM_HOME,
    capHome: env.CAP_HOME,
    configText: existsSync(cfg) ? readFileSync(cfg, 'utf8') : undefined,
    homesText: existsSync(homes) ? readFileSync(homes, 'utf8') : undefined,
    cwd: ctx.cwd,
    home,
    hasChartroomDir: existsSync(`${home}/.chartroom`),
    hasCaptainDir: existsSync(`${home}/.captain`),
  })
  if (samePath(ctx.cwd, chartroomHome)) return chartroomHome
  try {
    return samePath(realpathSync(ctx.cwd), realpathSync(chartroomHome)) ? chartroomHome : null
  } catch {
    return null
  }
}

const TONE: Record<Tone, 'text' | 'dim' | 'warning' | 'error'> = { plain: 'text', dim: 'dim', warn: 'warning', error: 'error' }

/** The todo browser's rows that hold an item, in the order drawn. */
function todoRows(list: TodoList, withHeld: boolean): { key: string; item: TodoItem }[] {
  const keyed = list.items.map((item, i) => ({ key: todoKey(item, i), item }))
  const next = keyed.filter(r => !r.item.held)
  return withHeld ? [...next, ...keyed.filter(r => r.item.held)] : next
}

function paint(theme: Theme, line: PaneLine, width: number): string {
  const text = theme.fg(TONE[line.tone], line.text)
  return truncateToWidth(line.bold ? theme.bold(text) : text, width)
}

export default function crewView(pi: ExtensionAPI) {
  let xoHome: string | null = null
  let awake = false
  let board: CrewBoard | null = null
  let error: string | null = null
  let timer: ReturnType<typeof setInterval> | undefined
  let watcher: ReturnType<typeof setInterval> | undefined
  let polling = false
  let pollAgain = false
  // `/crew off`: no band (and no poll while the browser is closed) until `/crew on`.
  let bandOff = false
  let browserOpen = false
  // The commander's todo list as last read; `/todo off` hides it until `/todo on`.
  let todo: TodoList | null = null
  let todoOff = false
  // focus.json and inbox.md as last stat'ed, so a change polls at once.
  let watched = ''
  // The change stamp as the last good board read found it when it began, and when it began; null
  // until one succeeds (a failed read is tried again the next round).
  let lastRead: { stamp: string; at: number } | null = null
  // Redraws whatever shows the board: the band's TUI, and the browser while it is open.
  const redraws = new Set<() => void>()
  const redraw = () => redraws.forEach(fn => fn())

  /**
   * The chartroom to run: on PATH, then ~/.local/bin (a thin GUI PATH). Looked up first,
   * since pi's exec reports a command that cannot start as a plain exit 1.
   */
  function chartroomBin(): string | null {
    const dirs = (process.env.PATH ?? '').split(':').filter(Boolean)
    for (const bin of [...dirs.map(d => `${d}/chartroom`), `${process.env.HOME ?? ''}/.local/bin/chartroom`]) {
      if (existsSync(bin)) return bin
    }
    return null
  }

  /** One `chartroom <args>` run. */
  async function runChartroom(args: string[]): Promise<{ stdout: string } | { error: string }> {
    const bin = chartroomBin()
    if (!bin) return { error: 'chartroom not found' }
    const ran = await pi.exec(bin, args, { timeout: 20_000 })
    if (ran.code === 0) return { stdout: ran.stdout }
    if (ran.killed) return { error: `chartroom ${args[0]} timed out` }
    const why = (ran.stderr.trim().split('\n')[0] ?? '').replace(/^chartroom:\s*/, '')
    return { error: `chartroom ${args[0]} failed${why ? `: ${why}` : ` (exit ${ran.code})`}` }
  }

  async function poll(): Promise<void> {
    if (polling) {
      pollAgain = true
      return
    }
    polling = true
    // Taken before the run: a write while it runs moves the stamp past this, and reads again.
    const began = { stamp: stampNow(), at: Date.now() }
    let read: typeof lastRead = null
    try {
      const ran = await runChartroom(['board', '--json'])
      const parsed = 'error' in ran ? ran : parseBoard(ran.stdout)
      if ('error' in parsed) error = parsed.error
      else if (parsed.board.home && xoHome && !samePath(parsed.board.home, xoHome)) error = `chartroom's home is ${parsed.board.home}, not ${xoHome}`
      else {
        board = parsed.board
        todo = 'stdout' in ran ? parseTodo(ran.stdout) : null
        error = null
        read = began
      }
    } finally {
      lastRead = read
      polling = false
      redraw()
    }
    if (pollAgain) {
      pollAgain = false
      return poll()
    }
  }

  /** Something shows the board: the band, the todo list, or a browser. */
  const showing = () => !bandOff || !todoOff || browserOpen

  /** The home's change stamp now (`mtime:size`, `-` while there is none); a stat, no process. */
  function stampNow(): string {
    try {
      return xoHome ? stampKey(statSync(`${xoHome}/${STAMP_FILE}`)) : '-'
    } catch {
      return '-'
    }
  }

  /** The timer's round: a board read once the stamp moved or the slow refresh is due; none while a read runs or nothing shows it. */
  function tick() {
    if (!polling && showing() && boardDue(lastRead, stampNow(), Date.now())) void poll()
  }

  /** Polls at once when focus.json or inbox.md changed (focus on or off, an item added or ticked). */
  function watchFiles() {
    if (!showing() || !xoHome) return
    const stamp = (f: string) => {
      try {
        const st = statSync(`${xoHome}/${f}`)
        return `${st.mtimeMs}:${st.size}`
      } catch {
        return '-'
      }
    }
    const now = `${stamp('focus.json')}|${stamp('inbox.md')}`
    const changed = watched !== '' && now !== watched
    watched = now
    if (changed) void poll()
  }

  /**
   * Above the editor: the band (one line, the needs-you list giving way to the width first),
   * then the todo list, built-in todo style; each hidden by its own `off`.
   */
  function showBand(ctx: ExtensionContext) {
    if (bandOff && todoOff) return ctx.ui.setWidget(WIDGET, undefined)
    ctx.ui.setWidget(WIDGET, (tui: TUI, theme: Theme) => {
      const fn = () => tui.requestRender()
      redraws.add(fn)
      return {
        render(width: number) {
          const out: string[] = []
          if (!bandOff && board) {
            const segs = bandSegments(board, Math.max(10, width - 8))
            const line = segs.map(s => theme.fg(TONE[s.tone], s.text)).join('') + (error ? theme.fg('dim', ` (${error})`) : '')
            out.push(truncateToWidth(`${line}${theme.fg('dim', '  /crew')}`, width))
          } else if (!bandOff && error) out.push(truncateToWidth(theme.fg('dim', `⚓ ${error}`), width))
          if (!todoOff && todo) {
            for (const [i, l] of todoBandLines(todo, Math.max(10, width - 8)).entries()) {
              out.push(truncateToWidth(`${theme.fg(TONE[l.tone], l.text)}${i === 0 ? theme.fg('dim', '  /todo') : ''}`, width))
            }
          }
          return out
        },
        invalidate() {},
        dispose() {
          redraws.delete(fn)
        },
      }
    })
  }

  /** `/crew off` and `/crew on`; a session entry keeps the choice across /reload. */
  function setBand(ctx: ExtensionContext, off: boolean) {
    bandOff = off
    pi.appendEntry(BAND_ENTRY, { off })
    showBand(ctx)
    if (!off) void poll()
  }

  /** `/todo off` and `/todo on`, kept the same way. */
  function setTodo(ctx: ExtensionContext, off: boolean) {
    todoOff = off
    pi.appendEntry(TODO_ENTRY, { off })
    showBand(ctx)
    if (!off) void poll()
  }

  /** Puts `line` in an empty editor; a draft is kept and the line copied instead. */
  async function intoEditor(ctx: ExtensionContext, line: string) {
    if (ctx.ui.getEditorText().trim() === '') return ctx.ui.setEditorText(line)
    await copyToClipboard(line).then(
      () => ctx.ui.notify(`${line} copied (the editor holds a draft, kept): paste it`, 'info'),
      () => ctx.ui.notify(`the editor holds a draft, kept; type ${line}`, 'info'),
    )
  }

  /** Wakes once per runtime: registers /crew, draws the band, starts the poll. */
  function wake(ctx: ExtensionContext, record: boolean) {
    if (awake || !xoHome) return
    awake = true
    if (record) pi.appendEntry(ENTRY, { active: true })
    pi.registerCommand('crew', {
      description: "Browse chartroom's crew (q closes); /crew <id> opens an item, /crew off hides the band",
      handler: async (args, cmdCtx) => {
        const arg = args.trim().replace(/^\[|\]$/g, '')
        if (arg === 'off' || arg === 'on') {
          setBand(cmdCtx, arg === 'off')
          return cmdCtx.ui.notify(arg === 'off' ? 'Crew band off for this session: /crew on brings it back; /crew still opens the browser.' : 'Crew band on.', 'info')
        }
        void poll()
        await openBrowser(cmdCtx, arg)
      },
    })
    pi.registerCommand('todo', {
      description: 'Your todo list (what the crew waits on you for): q closes; /todo off hides it, /todo add <text>, /todo done <ref>',
      handler: async (args, cmdCtx) => {
        const [sub, ...rest] = args.trim().split(/\s+/).filter(Boolean)
        if (sub === 'off' || sub === 'on') {
          setTodo(cmdCtx, sub === 'off')
          return cmdCtx.ui.notify(sub === 'off' ? 'Todo list off for this session: /todo on brings it back; /todo still opens the browser.' : 'Todo list on.', 'info')
        }
        if (sub === 'add' || sub === 'done') {
          const argv = sub === 'add' && rest[0] === '--project' ? ['--project', rest[1] ?? '', rest.slice(2).join(' ')] : [rest.join(' ')]
          if (!argv.at(-1)) return cmdCtx.ui.notify(sub === 'add' ? 'usage: /todo add [--project P] <text>' : 'usage: /todo done <ref>', 'warning')
          const ran = await runChartroom(['todo', sub, ...argv])
          void poll()
          if ('error' in ran) return cmdCtx.ui.notify(ran.error, 'error')
          return cmdCtx.ui.notify(sub === 'add' ? `added ${ran.stdout.trim()}: ${argv.at(-1)}` : ran.stdout.trim(), 'info')
        }
        if (sub) return cmdCtx.ui.notify('usage: /todo [on|off|add [--project P] <text>|done <ref>]', 'warning')
        void poll()
        await openTodo(cmdCtx)
      },
    })
    // The editor's slash-command list is built when its autocomplete provider is: adding one
    // (that changes nothing) rebuilds it, so a /crew registered after startup is offered too.
    ctx.ui.addAutocompleteProvider(current => current)
    showBand(ctx)
    void poll()
    // Nothing shows the board with the band and the list off and no browser open: no read then.
    timer = setInterval(tick, POLL_MS)
    watcher = setInterval(watchFiles, WATCH_MS)
  }

  pi.on('session_start', (_e, ctx) => {
    xoHome = detectXo(ctx)
    if (!xoHome) return
    // /reload, a resumed session: the skill was loaded here before, the band maybe turned off.
    const custom = ctx.sessionManager.getBranch().flatMap(entry => (entry.type === 'custom' ? [entry as { customType?: string; data?: unknown }] : []))
    bandOff = (custom.filter(entry => entry.customType === BAND_ENTRY).at(-1)?.data as { off?: boolean } | undefined)?.off === true
    todoOff = (custom.filter(entry => entry.customType === TODO_ENTRY).at(-1)?.data as { off?: boolean } | undefined)?.off === true
    if (custom.some(entry => entry.customType === ENTRY)) wake(ctx, false)
  })

  pi.on('input', (e, ctx) => {
    if (xoHome && XO_SKILLS.test(e.text.trim())) wake(ctx, true)
    return { action: 'continue' }
  })

  pi.on('tool_call', (e, ctx) => {
    if (xoHome && e.toolName === 'read' && XO_SKILL_FILE.test(String((e.input as { path?: unknown }).path ?? ''))) wake(ctx, true)
    return undefined
  })

  pi.on('session_shutdown', () => {
    if (timer) clearInterval(timer)
    if (watcher) clearInterval(watcher)
    timer = undefined
    watcher = undefined
    redraws.clear()
  })

  /**
   * The browser: the lanes, an item's detail, its report. Resolves when closed; closed by
   * continue, it puts `/skill:continue <id>` in the editor (pi's spelling of /continue), or,
   * when the editor holds a draft, keeps the draft and copies the line.
   */
  async function openBrowser(ctx: ExtensionContext, initial: string) {
    browserOpen = true
    const line = await ctx.ui
      .custom<string | null>((tui, theme, _kb, done) => {
        const browser = new Browser(tui, theme, done)
        redraws.add(browser.refresh)
        if (initial) void browser.open(initial)
        return browser
      })
      .finally(() => {
        browserOpen = false
      })
    if (line) await intoEditor(ctx, line)
  }

  /** The todo browser; closed by `o`, it puts `/skill:continue <id>` in the editor. */
  async function openTodo(ctx: ExtensionContext) {
    browserOpen = true
    const line = await ctx.ui
      .custom<string | null>((tui, theme, _kb, done) => {
        const browser = new TodoBrowser(tui, theme, done)
        redraws.add(browser.refresh)
        return browser
      })
      .finally(() => {
        browserOpen = false
      })
    if (line) await intoEditor(ctx, line)
  }

  class TodoBrowser implements Component {
    selected: string | null = null
    withHeld = false
    armed: string | null = null
    notice: string | null = null

    constructor(
      private tui: TUI,
      private theme: Theme,
      /** Closes the browser; with a line, that line goes to the editor. */
      private done: (line: string | null) => void,
    ) {}

    refresh = () => this.tui.requestRender()

    rows() {
      return todo ? todoRows(todo, this.withHeld) : []
    }

    current() {
      const rows = this.rows()
      return rows.find(r => r.key === this.selected) ?? rows[0] ?? null
    }

    say(text: string | null) {
      this.notice = text
      this.refresh()
    }

    async copy(text: string, what: string) {
      try {
        await copyToClipboard(text)
        this.say(`copied ${what}`)
      } catch (err) {
        this.say(`could not copy ${what} (${String(err).split('\n')[0]}): ${text}`)
      }
    }

    async act(id: TodoActionId) {
      if (id === 'held') {
        this.withHeld = !this.withHeld
        return this.say(null)
      }
      const row = this.current()
      if (!row) return this.say('nothing on the list')
      const { item } = row
      if (id === 'done') {
        const why = doneRefusal(item)
        if (why) return this.say(why.replace('/continue ', '/skill:continue ')) // pi's spelling
        if (this.armed !== row.key) {
          this.armed = row.key
          return this.say(`d again ticks off ${item.ref}: ${item.label}`)
        }
        this.armed = null
        const ran = await runChartroom(['todo', 'done', item.ref ?? ''])
        if ('error' in ran) return this.say(ran.error)
        const rows = this.rows()
        const at = rows.findIndex(r => r.key === row.key)
        this.selected = (rows[at + 1] ?? rows[at - 1])?.key ?? null
        if (todo) todo = { ...todo, items: todo.items.filter(i => i.ref !== item.ref) }
        this.say(ran.stdout.trim().split('\n')[0] || `done ${item.ref}`)
        return poll()
      }
      this.armed = null
      if (id === 'continue') return item.owner ? this.done(`/skill:continue ${item.owner}`) : undefined
      if (item.type === 'artifact' && item.ref) {
        const ran = await runChartroom(['artifact', 'show', item.ref])
        return 'error' in ran ? this.say(ran.error) : this.copy(ran.stdout, `artifact ${item.ref}`)
      }
      if (item.type === 'task') return this.copy(item.owner ?? '', item.owner ?? 'the id')
      return this.copy(item.text, item.ref ?? 'the item')
    }

    handleInput(data: string) {
      if (matchesKey(data, 'escape') || data === 'q') return this.done(null)
      const rows = this.rows()
      const at = Math.max(0, rows.findIndex(r => r.key === this.current()?.key))
      if (matchesKey(data, 'up') || data === 'k') this.selected = rows[Math.max(0, at - 1)]?.key ?? null
      else if (matchesKey(data, 'down') || data === 'j') this.selected = rows[Math.min(rows.length - 1, at + 1)]?.key ?? null
      else {
        const action = todo ? todoActions(this.current()?.item ?? null, todo, this.withHeld).find(a => a.hotkey === data) : undefined
        if (action) void this.act(action.id)
        return
      }
      this.armed = null
      this.refresh()
    }

    render(width: number): string[] {
      const th = this.theme
      const dim = (t: string) => truncateToWidth(th.fg('dim', t), width)
      const head = truncateToWidth(`${th.fg('accent', 'q')}${th.fg('dim', ': close · Esc closes too · /todo off hides the list')}`, width)
      if (!todo) return [head, dim(error ?? (board ? 'This chartroom keeps no todo list: update it (chartroom todo).' : 'Reading the list…'))]
      const current = this.current()
      const actions = todoActions(current?.item ?? null, todo, this.withHeld)
        .map(a => `${th.fg('accent', a.hotkey)}: ${a.label}`)
        .join('  ')
      const lines = todoPaneLines(todo, width, Date.now(), { selected: current?.key ?? null, withHeld: this.withHeld }).map(l =>
        l.key === current?.key ? truncateToWidth(th.inverse(l.text), width) : paint(th, l, width),
      )
      return [head, truncateToWidth(actions, width), ...(this.notice ? [truncateToWidth(th.fg('success', this.notice), width)] : []), ...lines, dim(`↑↓ move · d done (twice), c copy, o continue${error ? ` · last poll: ${error}` : ''}`)]
    }

    invalidate() {}

    dispose() {
      redraws.delete(this.refresh)
    }
  }

  class Browser implements Component {
    view: 'list' | 'detail' | 'report' = 'list'
    cursor = 0
    selected: string | null = null
    detail: CrewDetail | null = null
    detailError: string | null = null
    report: Markdown | null = null
    notice: string | null = null

    constructor(
      private tui: TUI,
      private theme: Theme,
      /** Closes the browser; with a line, that line goes to the editor. */
      private done: (line: string | null) => void,
    ) {}

    close = () => this.done(null)

    refresh = () => this.tui.requestRender()

    /** The ids of the rows, in the order drawn. */
    refs(): string[] {
      return board ? paneLines(board, 80, Date.now()).flatMap(l => (l.ref ? [l.ref] : [])) : []
    }

    async open(ref: string) {
      this.selected = ref
      this.view = 'detail'
      this.notice = null
      this.detailError = null
      if (this.detail?.ref !== ref) this.detail = null
      this.refresh()
      const ran = await runChartroom(['show', ref, '--json'])
      if (this.selected !== ref) return
      const parsed = 'error' in ran ? ran : parseDetail(ran.stdout)
      if ('error' in parsed) this.detailError = parsed.error
      else this.detail = parsed.detail
      this.refresh()
    }

    say(text: string) {
      this.notice = text
      this.refresh()
    }

    async copy(text: string, what: string) {
      try {
        await copyToClipboard(text)
        this.say(`copied ${what}`)
      } catch (err) {
        this.say(`could not copy ${what} (${String(err).split('\n')[0]}): ${text}`)
      }
    }

    async act(id: ActionId) {
      const ref = this.selected
      const d = this.detail
      if (id === 'back') {
        this.view = 'list'
        this.notice = null
        return this.refresh()
      }
      if (id === 'report') {
        if (!d?.report) return this.say('no report yet')
        try {
          this.report = new Markdown(readFileSync(d.report.path, 'utf8'), 1, 0, getMarkdownTheme())
          this.view = 'report'
          return this.refresh()
        } catch (err) {
          return this.say(`could not read ${d.report.path}: ${String(err).split('\n')[0]}`)
        }
      }
      if (id === 'copy-pr' && d?.prs[0]) return this.copy(d.prs[0].url, d.prs[0].url)
      if (id === 'copy-artifact' && d?.artifacts[0]) {
        const ran = await runChartroom(['artifact', 'show', d.artifacts[0].ref])
        return 'error' in ran ? this.say(ran.error) : this.copy(ran.stdout, `artifact ${d.artifacts[0].ref}`)
      }
      if (!ref) return
      if (id === 'copy-id') return this.copy(ref, ref)
      if (id === 'continue') this.done(`/skill:continue ${ref}`)
    }

    handleInput(data: string) {
      if (this.view === 'report') {
        if (data === 'q') return this.close()
        if (matchesKey(data, 'escape') || data === 'b') {
          this.view = 'detail'
          this.refresh()
        }
        return
      }
      if (this.view === 'detail') {
        if (matchesKey(data, 'escape')) return void this.act('back')
        if (data === 'q') return this.close()
        const action = detailActions(this.selected, this.detail).find(a => a.hotkey === data)
        if (action) void this.act(action.id)
        return
      }
      const refs = this.refs()
      if (matchesKey(data, 'escape') || data === 'q') return this.close()
      if (matchesKey(data, 'up') || data === 'k') this.cursor = Math.max(0, this.cursor - 1)
      else if (matchesKey(data, 'down') || data === 'j') this.cursor = Math.min(refs.length - 1, this.cursor + 1)
      else if (matchesKey(data, 'enter')) {
        const ref = refs[this.cursor]
        if (ref) void this.open(ref)
        return
      }
      this.refresh()
    }

    render(width: number): string[] {
      const th = this.theme
      const dim = (t: string) => truncateToWidth(th.fg('dim', t), width)
      // Every view's first line says how to close the browser.
      const head = (hint: string) => truncateToWidth(`${th.fg('accent', 'q')}${th.fg('dim', `: close · ${hint}`)}`, width)
      if (this.view === 'report' && this.report) {
        return [head(`b or Esc back · ${this.detail?.report?.path ?? ''}`), ...this.report.render(width)]
      }
      if (this.view === 'detail' && this.selected) {
        const d = this.detail
        const actions = detailActions(this.selected, d)
          .map(a => `${th.fg('accent', a.hotkey)}: ${a.label}`)
          .join('  ')
        const lines = d ? detailLines(d, width, Date.now()).map(l => paint(th, l, width)) : [dim(`${this.selected} · ${this.detailError ?? 'reading…'}`)]
        return [head('Esc or b back to the lanes'), ...lines.slice(0, 2), truncateToWidth(actions, width), ...(this.notice ? [truncateToWidth(th.fg('success', this.notice), width)] : []), ...lines.slice(2), ...(d && this.detailError ? [dim(`last read: ${this.detailError}`)] : [])]
      }
      const listHead = head('Esc closes too · /crew off hides the band')
      if (!board) return [listHead, dim(error ?? 'Reading the board…')]
      const lines: string[] = [listHead]
      let n = 0
      const all = paneLines(board, width, Date.now())
      this.cursor = Math.min(this.cursor, Math.max(0, all.filter(l => l.ref).length - 1))
      for (const line of all) {
        const here = line.ref !== undefined && n++ === this.cursor
        lines.push(here ? truncateToWidth(th.inverse(line.text), width) : paint(th, line, width))
      }
      lines.push(dim(`updated ${board.generated_at.slice(11, 19) || '?'}Z${error ? ` · last poll: ${error}` : ''} · ↑↓ move, Enter opens`))
      return lines
    }

    invalidate() {
      this.report?.invalidate()
    }

    dispose() {
      redraws.delete(this.refresh)
    }
  }
}
