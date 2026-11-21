# shellcheck shell=bash
# store.sh - where a task's record lives, and the seams every reader and writer goes through.
#
# A home whose own config sets CHARTROOM_STORE=sqlite has every task born after that in the
# machine's store (lib/store.py: one SQLite database, $CHARTROOM_DB, default
# ${XDG_STATE_HOME:-~/.local/state}/chartroom/chartroom.db). A task's place is fixed at birth:
#   file   tasks/<id>/meta.json and events.log, as always (every task from before the switch, and
#          every task while the switch is off). Read and written as files, to the end.
#   db     a row in the store. tasks/<id>/ still holds what stays a file (brief.md, plan.md,
#          report.md, artifacts/, messages/, launch.sh), but no meta.json and no events.log: a
#          process that must append without chartroom (a launch wrapper's `exited:` line, the
#          brief's fallback) appends to tasks/<id>/events.spool, which the store takes in.
# An id lives in one place only: the store refuses one that has a meta.json, and `new` one whose
# directory exists.
#
# Readers ask for a path (meta_path, events_path) and read it as they always read a meta.json or
# an events.log. For a store task that path is a rendering of its row and events in this
# process's own cache, $(bell_root)/store/<pid>.<start>/<home uid>/<id>/ (never inside a home, so
# the brain's copy, a backup or a grep never meets it). The rendering is the exact text a file
# task would hold and only ever grows, so a byte offset into it (watch's cursor, hc's prompt
# check) stays valid. A process renders once and keeps it; its own writes drop what they change,
# and a long-running loop (watch's rounds, a poll) calls store_reset to read the store again.
#
# A home is known to the store by <home>/.home-id, written once when its first store task is born:
# its uid, and on a second line the database that record went into. Every later command uses that
# database for the home, unless CHARTROOM_DB is set: a default that moved with the environment
# (XDG_STATE_HOME set in a terminal's rc file, not in an ssh session or a GUI launcher's) would
# otherwise read and write a second, empty store. No .home-id: the home has nothing in the store,
# and nothing here runs python.

CR_STORE=files CR_DB="" CR_STORE_PY=""
STORE_RUN="" STORE_UID_FOR="" STORE_UID="" STORE_DB="" STORE_D="" TASK_KIND="" META_PATH="" EVENTS_PATH=""
STORE_HOME_ARGS=()

store_settings() { # (load_config)
  cfg_set CR_STORE STORE '' files
  [[ "$CR_STORE" =~ ^(files|sqlite)$ ]] || die "CHARTROOM_STORE must be files or sqlite (got $CR_STORE)"
  CR_DB="${CHARTROOM_DB:-${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/chartroom.db}"
  local r="${CHARTROOM_RUNTIME_DIR:-/tmp}"
  [[ -n "$STORE_RUN" ]] || STORE_RUN="${r%/}/chartroom-$EUID/store/$$.${EPOCHREALTIME:-$RANDOM$RANDOM}"
  STORE_RUN="${STORE_RUN//[^A-Za-z0-9._\/-]/_}"
}

store_on() { [[ "$CR_STORE" == sqlite ]]; }

store_python() {
  [[ -z "$CR_STORE_PY" ]] || return 0
  CR_STORE_PY="${CHARTROOM_PYTHON:-}"
  [[ -n "$CR_STORE_PY" ]] || CR_STORE_PY="$(type -P python3 || true)"
  [[ -n "$CR_STORE_PY" ]] || die "the store needs python3 with its sqlite3 module, and there is none on PATH (CHARTROOM_PYTHON names one; chartroom store doctor)"
}
store_py() { store_python; CHARTROOM_DB="${STORE_DB:-$CR_DB}" "$CR_STORE_PY" -I -S "$CR_ROOT/lib/store.py" "$@"; }

# The home's uid into STORE_UID ("" when it has nothing in the store), and STORE_HOME_ARGS.
store_uid_of() { # [home]
  local h="${1:-$CR_HOME}"
  [[ "$STORE_UID_FOR" == "$h" ]] && return 0
  local rec=""
  STORE_UID=""; STORE_UID_FOR="$h"; STORE_DB="$CR_DB"
  if [[ -f "$h/.home-id" ]]; then { read -r STORE_UID; read -r rec; } <"$h/.home-id" || true; fi
  [[ "$STORE_UID" =~ ^[A-Za-z0-9-]{8,64}$ ]] || STORE_UID=""
  # (the database this home's records went into, unless CHARTROOM_DB says otherwise)
  [[ -z "${CHARTROOM_DB:-}" && -n "$STORE_UID" && "$rec" == /* && -f "$rec" ]] && STORE_DB="$rec"
  STORE_HOME_ARGS=(--uid "$STORE_UID" --name "${h##*/}" --path "$h")
}

# Before the first store task of a home is born: its uid, written once (never replaced).
store_home_ensure() {
  store_uid_of
  [[ -z "$STORE_UID" ]] || return 0
  [[ -d "$CR_HOME" ]] || die "no chartroom home at $CR_HOME"
  local f="$CR_HOME/.home-id"
  [[ -s "$f" ]] || { set -o noclobber; { printf '%s\n%s\n' "$(new_uuid)" "$CR_DB" >"$f"; } 2>/dev/null || true; set +o noclobber; }
  STORE_UID_FOR=""; store_uid_of
  [[ -n "$STORE_UID" ]] || die "could not give $CR_HOME a store id ($f)"
}

# STORE_D: this process's cache for the home; 1 when the home has nothing in the store.
store_dir() {
  store_uid_of
  [[ -n "$STORE_UID" ]] || { STORE_D=""; return 1; }
  STORE_D="$STORE_RUN/$STORE_UID"
  [[ -d "$STORE_D" ]] && return 0
  local root="${STORE_RUN%/*}" d p
  if [[ ! -d "$STORE_RUN" ]]; then
    mkdir -p "$root" && chmod 700 "${root%/*}" 2>/dev/null || true
    # What dead processes left behind.
    for d in "$root"/*/; do
      p="${d%/}"; p="${p##*/}"; p="${p%%.*}"
      [[ "$p" =~ ^[0-9]+$ ]] && ! kill -0 "$p" 2>/dev/null && rm -rf "${d%/}"
    done
  fi
  mkdir -p "$STORE_D"
}

# The store's tasks of this home, rendered once per process: a directory per task, with its
# meta.json. 1 when the home has nothing in the store.
store_load() {
  store_dir || return 1
  [[ -f "$STORE_D/.ids" ]] && return 0
  store_py render "${STORE_HOME_ARGS[@]}" --dir "$STORE_D" --meta-all >"$STORE_D/.ids.tmp.$BASHPID" || { rm -f "$STORE_D/.ids.tmp.$BASHPID"; die "could not read the store (${STORE_DB:-$CR_DB})"; }
  mv "$STORE_D/.ids.tmp.$BASHPID" "$STORE_D/.ids"
}

# Read the store again on the next look (a watch round, a poll; after a write of this process).
# (The directory is found again here, not taken from STORE_D: a read in a subshell, $(...), fills
# this process's cache without setting STORE_D out here.)
store_reset() {
  STORE_UID_FOR=""; store_uid_of
  [[ -z "$STORE_UID" ]] || rm -rf "${STORE_RUN:?}/$STORE_UID"
  STORE_D=""; STORE_UID_FOR=""; return 0
}
store_forget_events() { # <id>
  store_uid_of; [[ -n "$STORE_UID" ]] || return 0
  local d="$STORE_RUN/$STORE_UID"
  rm -f "$d/$1/events.log" "$d/.events-open" "$d/.events-all"
}

# Where a task's record lives: TASK_KIND=file|db, or "" for no such task. One task is looked up
# on its own (its record rendered, not every task's): store_load is for listing them all.
task_kind() { # <id>
  if [[ -f "$CR_HOME/tasks/$1/meta.json" ]]; then TASK_KIND="file"; return 0; fi
  TASK_KIND=""
  [[ -n "$1" && "$1" != */* && "$1" != .* ]] || return 0
  store_dir || return 0
  if [[ -d "$STORE_D/$1" ]]; then TASK_KIND=db; return 0; fi
  # Not rendered by this process yet (or born in the store since it listed them).
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 0
  local rc=0
  store_py render "${STORE_HOME_ARGS[@]}" --dir "$STORE_D" --meta "$1" || rc=$?
  # (3: not in the store. Anything else is the store failing, never "no such task": a write
  # would land in the wrong place.)
  case "$rc" in 0) TASK_KIND=db ;; 3) ;; *) die "could not read the store (${STORE_DB:-$CR_DB})" ;; esac
  return 0
}
task_exists() { task_kind "$1"; [[ -n "$TASK_KIND" ]]; } # <id>
is_store_task() { task_kind "$1"; [[ "$TASK_KIND" == db ]]; } # <id>

store_render() { # <id>...: its meta.json and events.log, now
  local a=() i
  for i in "$@"; do a+=(--events "$i"); done
  store_py render "${STORE_HOME_ARGS[@]}" --dir "$STORE_D" "${a[@]}" || die "could not read the store (${STORE_DB:-$CR_DB})"
}

# META_PATH: the task's meta.json to read ("" for no such task).
meta_path() { # <id>
  task_kind "$1"
  case "$TASK_KIND" in
    file) META_PATH="$CR_HOME/tasks/$1/meta.json" ;;
    db) META_PATH="$STORE_D/$1/meta.json"; [[ -f "$META_PATH" ]] || store_render "$1" ;;
    *) META_PATH="" ;;
  esac
}
# EVENTS_PATH: the task's events.log to read (a file task's own path even before it exists).
events_path() { # <id>
  task_kind "$1"
  if [[ "$TASK_KIND" == db ]]; then
    EVENTS_PATH="$STORE_D/$1/events.log"; [[ -f "$EVENTS_PATH" ]] || store_render "$1"
  else EVENTS_PATH="$CR_HOME/tasks/$1/events.log"; fi
}
# The same, read again from the store first (another process may have written it since).
meta_path_fresh() { # <id>
  task_kind "$1"
  [[ "$TASK_KIND" != db ]] || rm -f "$STORE_D/$1/meta.json"
  meta_path "$1"
}
# The same, read again from the store first (a poll waiting on another process's event).
events_path_fresh() { # <id>
  task_kind "$1"
  [[ "$TASK_KIND" != db ]] || store_forget_events "$1"
  events_path "$1"
}
# The file a process outside chartroom appends event lines to (printf >>): a file task's
# events.log, a store task's events.spool (taken into the store on its next read).
events_append_path() { # <id>
  task_kind "$1"
  if [[ "$TASK_KIND" == db ]]; then printf '%s/tasks/%s/events.spool' "$CR_HOME" "$1"
  else printf '%s/tasks/%s/events.log' "$CR_HOME" "$1"; fi
}
task_events() { events_path "$1"; cat "$EVENTS_PATH" 2>/dev/null || true; } # <id>: its event lines

# Every store task's events.log rendered at once (status, a watch round): open ones, or all.
store_render_events() { # open|all
  store_load || return 0
  [[ -f "$STORE_D/.events-$1" || -f "$STORE_D/.events-all" ]] && return 0
  store_py render "${STORE_HOME_ARGS[@]}" --dir "$STORE_D" "--events-$1" || die "could not read the store (${STORE_DB:-$CR_DB})"
  : >"$STORE_D/.events-$1"
}

# Has a line been appended to any store task's spool since <file>'s time?
store_spools_newer() { # <file>
  local f
  for f in "$CR_HOME"/tasks/*/events.spool; do [[ -f "$f" && ! "$f" -ot "$1" ]] && return 0; done
  return 1
}

# TASK_METAS: every task's meta.json to read, file tasks then store tasks.
task_meta_files() {
  local had; had="$(shopt -p nullglob)" || true
  shopt -s nullglob
  TASK_METAS=("$CR_HOME"/tasks/*/meta.json)
  if store_load; then
    local d m missing=()
    for d in "$STORE_D"/*/; do [[ -f "$d/meta.json" ]] || missing+=("$(basename "$d")"); done
    (( ${#missing[@]} == 0 )) || store_render "${missing[@]}"
    local store=("$STORE_D"/*/meta.json)
    if (( ${#store[@]} > 0 )); then
      # One list in id order, as the directory glob of a home of file tasks gives it.
      TASK_METAS+=("${store[@]}")
      mapfile -t TASK_METAS < <(for d in "${TASK_METAS[@]}"; do m="${d%/meta.json}"; printf '%s\t%s\n' "${m##*/}" "$d"; done | LC_ALL=C sort | cut -f2-)
    fi
  fi
  eval "$had"
}

# The same for another home on this machine (homes, sweep --all-homes): prints NUL-separated paths.
task_meta_files_of() { # <home>
  ( CR_HOME="$1"; STORE_UID_FOR=""; task_meta_files; (( ${#TASK_METAS[@]} == 0 )) || printf '%s\0' "${TASK_METAS[@]}" )
}

# A task is born where the switch says: as files (meta.json and an empty events.log), or as a
# store row. Its directory, for the files that stay files, either way.
task_record_new() { # <id> <meta json>
  local d; d="$(tdir "$1")"
  if store_on; then store_task_new "$2"; mkdir -p "$d"; return; fi
  mkdir -p "$d"; printf '%s\n' "$2" >"$d/meta.json"; : >"$d/events.log"
}

# A store task is born: its row, then its directory for the files that stay files.
store_task_new() { # <meta json>
  store_on || die "the store is off in this home (CHARTROOM_STORE=sqlite in its config turns it on)"
  store_home_ensure
  store_py task-new "${STORE_HOME_ARGS[@]}" --json "$1" || exit 1
  store_reset; store_stamp
}
store_meta_set() { # <id> <key> <value>
  store_py meta-set "${STORE_HOME_ARGS[@]}" --id "$1" --key "$2" --value "$3" || exit 1
  store_reset; store_stamp
}
# The app's records born in the store (store.py docs): one JSON doc per (kind, id).
store_doc_put() { # <kind> <id> <json> [upsert|insert]: insert returns 4, quietly, when there is one
  store_home_ensure
  local rc=0 err
  err="$(store_py doc-put "${STORE_HOME_ARGS[@]}" --kind "$1" --id "$2" --json "$3" --mode "${4:-upsert}" 2>&1 >/dev/null)" || rc=$?
  (( rc == 4 )) && return 4
  (( rc == 0 )) || { printf '%s\n' "$err" >&2; exit 1; }
  store_stamp
}
store_doc_list() { # <kind> [id]: its docs, one JSON line each, oldest first; nothing for a home not in the store
  store_uid_of; [[ -n "$STORE_UID" ]] || return 0
  store_py doc-list "${STORE_HOME_ARGS[@]}" --kind "$1" ${2:+--id "$2"} || die "could not read the store (${STORE_DB:-$CR_DB})"
}
store_meta_set_json() { # <id> <key> <json value | "">: "" takes the key out
  if [[ -z "$3" ]]; then store_py meta-set "${STORE_HOME_ARGS[@]}" --id "$1" --key "$2" --delete || exit 1
  else store_py meta-set "${STORE_HOME_ARGS[@]}" --id "$1" --key "$2" --json "$3" || exit 1; fi
  store_reset; store_stamp
}
# A store write changes nothing under tasks/, which a view may watch (the Herdr panel watches the
# folder: mods/herdr-chartroom/schedule.js), so each one rewrites tasks/.store-stamp; the home's
# own change stamp (.changed) moves as for every write.
store_stamp() { { printf . >"$CR_HOME/tasks/.store-stamp"; } 2>/dev/null || true; }
# An event into the store; when the store cannot take it (locked past its timeout, a damaged
# database), it goes to the task's spool instead, which the store takes in later: never lost.
store_event() { # <id> <kind> <text>
  if ! store_py event "${STORE_HOME_ARGS[@]}" --id "$1" --kind "$2" --text "$3"; then
    printf '%s %s: %s\n' "$(now)" "$2" "$3" >>"$CR_HOME/tasks/$1/events.spool"
    warn "the store did not take this event; it waits in tasks/$1/events.spool"
  fi
  store_forget_events "$1"; store_stamp
}

# sweep --apply's part (lib/sweep.sh): what removes no longer need (lib/store.py purge: an inbox
# item removed past the 30 days, a mark on a file item that is gone), and one backup of the
# database a day beside it (backups/, the newest 14 kept). Each logged to sweep.log.
store_upkeep() {
  store_uid_of; [[ -n "$STORE_UID" ]] || return 0
  local db="${STORE_DB:-$CR_DB}" out
  [[ -f "$db" ]] || return 0
  out="$(store_py purge "${STORE_HOME_ARGS[@]}" 2>&1)" && [[ "$out" != '{"inbox": 0, "marks": 0}' ]] && sweep_log "store purge: $out"
  out="$(store_py backup "${STORE_HOME_ARGS[@]}" --dir "${db%/*}/backups" --keep 14 2>&1)" || { sweep_log "store backup failed: $out"; return 0; }
  jq -e '.made' <<<"$out" >/dev/null 2>&1 && sweep_log "store backup: $(jq -r .backup <<<"$out")"
  return 0
}

# ---------------------------------------------------------------- chartroom store

store_usage() {
  cat <<'EOF'
usage: chartroom store doctor [--json]   the database, its python and sqlite, this home's tasks in it
       chartroom store check            problems: an id both in the store and as files
       chartroom store legacy [--json]  what this home still keeps as files from before the store
       chartroom store events <id>      a task's event lines, from wherever it lives
       chartroom store meta <id>        a task's record (its meta.json), from wherever it lives
       chartroom store mail             this home's mailbox records (relays, told words, acks), file then store
EOF
}

cmd_store() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    doctor)
      local out; store_uid_of; store_python
      if [[ -n "$STORE_UID" ]]; then out="$(store_py doctor "${STORE_HOME_ARGS[@]}")" || exit 1
      else out="$(store_py doctor)" || exit 1; fi
      if [[ "${1:-}" == --json ]]; then jq . <<<"$out"; return; fi
      jq -r --arg mode "$CR_STORE" --arg uid "$STORE_UID" --arg py "$CR_STORE_PY" '
        "store: \($mode) for new work in this home" + (if $uid == "" then " (nothing of this home in the store yet)" else "" end),
        "database: \(.db)" + (if .exists then " (\(.size) bytes, schema \(.schema), \(.journal), \(.integrity))" else " (not created yet)" end),
        "python: \($py) \(.python), sqlite \(.sqlite)",
        (if .home_tasks != null then "this home: \(.home_tasks) task(s) in the store, \(.home_open) open" else empty end)' <<<"$out" ;;
    check)
      store_uid_of; [[ -n "$STORE_UID" ]] || { echo "store: nothing of this home in the store"; return 0; }
      if store_py check "${STORE_HOME_ARGS[@]}"; then echo "store: no problems"; else exit 1; fi ;;
    legacy)
      local out; out="$(store_py legacy --uid legacy --path "$CR_HOME")" || exit 1
      if [[ "${1:-}" == --json ]]; then jq . <<<"$out"; return; fi
      jq -r '"files from before the store: \(.tasks) task(s), \(.open_tasks) open; \(.inbox_lines) inbox line(s); \(.artifacts) artifact(s)"' <<<"$out" ;;
    events)
      [[ $# -eq 1 ]] || die "usage: chartroom store events <id>"
      task_exists "$1" || die "no such task: $1"
      task_events "$1" ;;
    mail)
      [[ $# -eq 0 ]] || die "usage: chartroom store mail"
      mailbox_lines ;;
    meta)
      [[ $# -eq 1 ]] || die "usage: chartroom store meta <id>"
      meta_path_fresh "$1"; [[ -n "$META_PATH" ]] || die "no such task: $1"
      jq . "$META_PATH" ;;
    ""|-h|--help) store_usage; [[ -n "$sub" ]] ;;
    *) store_usage >&2; exit 1 ;;
  esac
}
