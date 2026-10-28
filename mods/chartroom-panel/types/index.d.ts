// The shared types of chartroom-panel, and the values it keeps in $.state.
//
// $.state survives a hot reload; the module's own variables reset. So the panel's on/off choice,
// its last-known tasks, the page and the selection live here, and a reload picks up where it was.

/** One row of `chartroom status --json`, trimmed to the fields the panel reads. */
export type Task = {
  id: string
  short_id?: string
  title?: string
  project?: string
  kind?: string
  /** The task state (`decision`, `working`, `done`, ...): the field the filter keys on. */
  state: string
  /** The worker's live value. NEVER filtered on: a decision is routinely live=done. */
  live?: string
  /** Non-null once the task is closed/finished; the filter hides any such row. */
  closed?: unknown
  /** The newest event line, surfaced for context. */
  last?: string
  waiting_on?: string | null
  waiting_until?: string | null
}

/** The colour band a state draws in. */
export type Tone = 'input' | 'working' | 'quiet' | 'plain'

/** What the render reads: the last tasks (null before the first read), an error, and when it last succeeded. */
export type Snapshot = {
  /** The unfinished tasks as last parsed; null before the first successful read. Kept through a later failure. */
  tasks: Task[] | null
  /** Why the last read failed, or null. Set with stale `tasks` still in place. */
  error: string | null
  /** Epoch ms of the last successful read, or null. */
  updated: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'chartroom-panel': {
      /** True while the panel is on (drawing + polling) this session; a reload resumes from it. */
      active: boolean
      /** True once the commander turned the panel off: auto-show never re-opens it after that. */
      closedByUser: boolean
      /** The last status read: tasks (kept stale on failure), the error, and when it last succeeded. */
      snapshot: Snapshot
      /** The page the panel shows; `next`/`prev` move it, the render wraps it into range. */
      page: number
      /** The short_id the focus ring rests on (the last opened/selected), or null. */
      selected: string | null
      /** What the last selection/action did (pre-filled, copied, closed, a refusal, or why not), or null. */
      notice: string | null
      /** The short_id a first `c` armed for close; a second `c` on the same row confirms. null = unarmed. */
      armed: string | null
    }
  }
}
