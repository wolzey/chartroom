// The shared types of chartroom-panel, and the values it keeps in $.state.
//
// $.state survives a hot reload; the module's own variables reset. So the panel's on/off choice,
// its last-known board, the page and the selection live here, and a reload picks up where it was.

/** A lane of the board (`chartroom board --json`, lib/dashboard/lanes.jq), in its order. */
export type LaneKey = 'needs_you' | 'in_progress' | 'on_hold' | 'ready' | 'recent'

/** One card of `chartroom board --json`, trimmed to the fields the panel reads. */
export type Card = {
  /** `task`, or `inbox` (a "Waiting on the commander" item: on the board, not a task). */
  type?: string
  id: string
  /** What /continue takes; null on an inbox line with no tag yet. */
  short_id?: string | null
  title?: string
  project?: string | null
  /** The task state (`decision`, `review`, `done`, ...), or `inbox`. */
  state?: string
  /** The board's one-word why (`decision`, `PR to review`, `accepted`, ...): its bracket. */
  reason?: string
  /** The lane the board put it in; set by parseBoard from the lane it came under. */
  lane: LaneKey
  /** Focus mode holds it (out of focus): still shown, marked held, as the board does. */
  held?: boolean
  last_event?: string | null
}

/** The colour band a lane draws in. */
export type Tone = 'input' | 'working' | 'quiet' | 'plain'

/** What the render reads: the last board's cards (null before the first read), an error, and when it last succeeded. */
export type Snapshot = {
  /** The board's cards as last parsed, in board order; null before the first successful read. Kept through a later failure. */
  tasks: Card[] | null
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
      /** The last board read: its cards (kept stale on failure), the error, and when it last succeeded. */
      snapshot: Snapshot
      /** The page the panel shows; `next`/`prev` move it, the render wraps it into range. */
      page: number
      /** The short_id the focus ring rests on (the last opened/selected), or null. */
      selected: string | null
      /** What the last selection/action did (pre-filled, copied, closed, a refusal, or why not), or null. */
      notice: string | null
      /** `<action>:<key>` a first `c` (close) or `a` (complete) armed; the same key again on the same row confirms. null = unarmed. */
      armed: string | null
    }
  }
}
