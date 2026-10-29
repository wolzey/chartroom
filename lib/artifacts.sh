# shellcheck shell=bash
# Artifacts: text the XO drafts for the commander (a message to send, commands to run, a
# note), or a page for them to read (a report as HTML, lib/pages.sh), kept with the task or
# inbox item it belongs to, so it outlives the chat.
#
#   tasks/<id>/artifacts/<slug>.md       the text, verbatim: what `show` prints and `copy` copies
#   tasks/<id>/artifacts/<slug>.html     a page's HTML instead (kind page): one self-contained file
#   tasks/<id>/artifacts/<slug>.json     {schema, title, kind, description, task, project, created,
#                                         updated, done}
#   inbox/<i-xxxx>/artifacts/<slug>.*    the same for an inbox item, under its stable tag, so it
#                                        outlives the item's line in inbox.md
#
# A ref is <owner>/<slug>, the owner as the dashboard shows it (a task's short id, or the
# inbox tag): 21ba/reply-to-review, i-7f3a/release-checklist. A bare owner works when it has
# exactly one open artifact. Adding the same slug again overwrites the text and opens it
# again; `done` (sent, or run) stops it showing as open. There are no versions.
#
# A task's artifacts/ may also hold a worker's own files. Only a sidecar in the shape `add`
# writes, with its text beside it (.html for a page, else .md), is an artifact; anything else
# there is left alone: never listed, never overwritten.

ARTIFACT_KINDS='message|runbook|note|page'
# Is this sidecar one `add` wrote?
ARTIFACT_SHAPE_JQ='type == "object" and (.schema | type) == "number" and (.title | type) == "string"
  and (.kind == "message" or .kind == "runbook" or .kind == "note" or .kind == "page")'
# {open, message, runbook, note, page}: open artifacts counted by kind (status, board, lanes JSON).
ARTIFACT_COUNTS_JQ='{open: length} + ([("message", "runbook", "note", "page") as $k | {($k): map(select(.kind == $k)) | length}] | add)'

artifact_ext() { [[ "$1" == page ]] && printf html || printf md; } # <kind>: its text file's extension

artifact_dir() { # <task|inbox> <owner>
  if [[ "$1" == task ]]; then printf '%s/artifacts' "$(tdir "$2")"; else printf '%s/inbox/%s/artifacts' "$CR_HOME" "$2"; fi
}

# A slug from a title: lowercase words joined by "-", at most 40 characters, cut at a word.
artifact_slug() { # <title>
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if (( ${#s} > 40 )); then s="${s:0:41}"; [[ "$s" == *-* ]] && s="${s%-*}"; s="${s:0:40}"; s="${s%-}"; fi
  printf '%s' "${s:-artifact}"
}

# What an id names, as "task <id>" or "inbox <i-xxxx>": a task (full id, short id or suffix,
# as `resolve` takes them) or an open inbox item. Without --open, an inbox tag whose
# artifacts outlived its line in inbox.md names it too.
artifact_owner() { # <id> [--open]
  local q out
  if out="$(cmd_resolve "$1" 2>&1)"; then
    if [[ "$out" =~ ^i-[0-9a-f]{4,}$ && ! -f "$(tdir "$out")/meta.json" ]]; then echo "inbox $out"; else echo "task $out"; fi
    return 0
  fi
  q="$(tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/^[[:space:]]*\[?//; s/\]?[[:space:]]*$//')"
  if [[ "${2:-}" != --open && "$q" =~ ^i-[0-9a-f]{4,}$ && -d "$(artifact_dir inbox "$q")" ]]; then echo "inbox $q"; return 0; fi
  die "${out#chartroom: }"
}

# The text file of the artifact whose sidecar is <slug>.json (<slug>.md, or <slug>.html for a
# page); fails, printing nothing, when the sidecar is not one `add` wrote or its text is missing.
artifact_text_of() { # <sidecar>
  local k; k="$(jq -r "select($ARTIFACT_SHAPE_JQ) | .kind" "$1" 2>/dev/null)" || return 1
  [[ -n "$k" && -f "${1%.json}.$(artifact_ext "$k")" ]] || return 1
  printf '%s' "${1%.json}.$(artifact_ext "$k")"
}
# Is <slug>.json (with its text beside it) an artifact `add` wrote, not a worker's own file?
artifact_ours() { artifact_text_of "$1" >/dev/null; } # <sidecar>

# Artifacts as a JSON array, newest first: {ref, owner_type, owner, slug, title, kind, description,
# project, created, updated, done, path}. The owner comes from where the files are; ref uses the owner's
# current short id. Files that are not artifacts (see the top) are skipped, one by one, so a
# stray or unreadable file never takes status, board or the dashboard down with it.
artifacts_json() { # [--open] [--owner task|inbox <id>]
  local open=0 t="" o="" files=() f od
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --open) open=1; shift ;;
      --owner) t="$2"; o="$3"; shift 3 ;;
      *) die "artifacts_json: unknown arg $1" ;;
    esac
  done
  shopt -s nullglob
  if [[ -n "$t" ]]; then files=("$(artifact_dir "$t" "$o")"/*.json)
  else files=("$CR_HOME"/tasks/*/artifacts/*.json "$CR_HOME"/inbox/*/artifacts/*.json); fi
  [[ ${#files[@]} -gt 0 ]] || { echo '[]'; return 0; }
  for f in "${files[@]}"; do
    [[ -f "${f%.json}.md" || -f "${f%.json}.html" ]] || continue
    od="${f%/artifacts/*}"
    jq -c --arg type "$([[ "$(basename "$(dirname "$od")")" == tasks ]] && echo task || echo inbox)" --arg owner "${od##*/}" \
      --arg slug "$(basename "$f" .json)" --arg base "${f%.json}" \
      --argjson md "$([[ -f "${f%.json}.md" ]] && echo true || echo false)" --argjson html "$([[ -f "${f%.json}.html" ]] && echo true || echo false)" \
      "select($ARTIFACT_SHAPE_JQ)"' as $m | select(if $m.kind == "page" then $html else $md end)
      | {owner_type: $type, owner: $owner, slug: $slug, title: $m.title, kind: $m.kind,
         description: (if ($m.description // "") == "" then null else $m.description end), project: ($m.project // null),
         created: ($m.created // null), updated: ($m.updated // $m.created // null),
         done: (if ($m.done // "") == "" then null else $m.done end), path: ($base + (if $m.kind == "page" then ".html" else ".md" end))}' "$f" 2>/dev/null || true
  done | jq -s -c --argjson shorts "$(short_ids_json)" --argjson open "$open" '
    map({ref: ((if .owner_type == "task" then ($shorts[.owner] // .owner) else .owner end) + "/" + .slug)} + .
        | select($open == 0 or .done == null))
    | sort_by(.updated // "") | reverse'
}

# One line counting open artifacts by kind, from ARTIFACT_COUNTS_JQ's object (default: computed
# now); prints nothing when there are none.
artifact_line() { # [counts json]
  local counts="${1:-}"
  [[ -n "$counts" ]] || counts="$(artifacts_json --open | jq -c "$ARTIFACT_COUNTS_JQ")"
  jq -r 'select((.open // 0) > 0)
    | "artifacts: \(.open) open (" + ([("message", "runbook", "note", "page") as $k | select((.[$k] // 0) > 0)
        | "\(.[$k]) \($k)\(if .[$k] == 1 then "" else "s" end)"] | join(", ")) + "): chartroom artifact list"' <<<"$counts"
}

# Resolve a ref into AR_TYPE, AR_OWNER, AR_SLUG, AR_REF, AR_FILE, AR_TITLE and AR_KIND, or die
# saying why.
artifact_resolve() { # <ref>
  local ref owner slug o rows n
  ref="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1")"
  [[ -n "$ref" ]] || die "an artifact ref is <id>/<slug>, as 'chartroom artifact list' prints it"
  owner="${ref%%/*}"; slug=""
  if [[ "$ref" == */* ]]; then slug="$(tr '[:upper:]' '[:lower:]' <<<"${ref#*/}")"; slug="${slug%.md}"; slug="${slug%.html}"; fi
  o="$(artifact_owner "$owner")" || exit 1
  AR_TYPE="${o%% *}"; AR_OWNER="${o#* }"
  rows="$(artifacts_json --owner "$AR_TYPE" "$AR_OWNER")"
  if [[ -z "$slug" ]]; then
    rows="$(jq -c '[.[] | select(.done == null)]' <<<"$rows")"
    n="$(jq length <<<"$rows")"
    [[ "$n" -ne 0 ]] || die "$owner has no open artifact (all of them: chartroom artifact list $owner --all)"
    [[ "$n" -eq 1 ]] || die "$owner has $n open artifacts: $(jq -r 'map(.ref) | join(", ")' <<<"$rows"); name one as <id>/<slug>"
  else
    rows="$(jq -c --arg s "$slug" '[.[] | select(.slug == $s)]' <<<"$rows")"
    [[ "$(jq length <<<"$rows")" -eq 1 ]] || die "no artifact '$slug' on $owner (chartroom artifact list $owner --all)"
  fi
  IFS=$'\t' read -r AR_SLUG AR_REF AR_FILE AR_KIND AR_TITLE < <(jq -r '.[0] | [.slug, .ref, .path, .kind, .title] | @tsv' <<<"$rows")
}

# The command `artifact copy` pipes the text into: CHARTROOM_CLIPBOARD (a command line, split
# on spaces; "-" prints instead), else pbcopy (macOS), wl-copy (Wayland), xclip or xsel (X11).
# Empty when there is none.
clipboard_cmd() {
  local c; c="$(cfg CLIPBOARD '' '')"
  if [[ -n "$c" ]]; then printf '%s' "$c"
  elif [[ -n "$(bin_of pbcopy)" ]]; then printf pbcopy
  elif [[ -n "${WAYLAND_DISPLAY:-}" && -n "$(bin_of wl-copy)" ]]; then printf wl-copy
  elif [[ -n "${DISPLAY:-}" && -n "$(bin_of xclip)" ]]; then printf 'xclip -selection clipboard'
  elif [[ -n "${DISPLAY:-}" && -n "$(bin_of xsel)" ]]; then printf 'xsel --clipboard --input'
  fi
}

artifact_add() { # <task-or-inbox-id> --kind K --title T [--description D] [--slug S] [--no-secret-check] <file|->
  local usage='usage: chartroom artifact add <task-or-inbox-id> --kind message|runbook|note|page --title "<one line>" [--description "<one line>"] [--slug S] [--no-secret-check] <file|->'
  local kind="" title="" desc="" slug="" pos=() o type owner d f m project created="" old="" ref mine="" secret_check=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind|--title|--slug|--description)
        [[ $# -ge 2 ]] || die "$usage"
        case "$1" in --kind) kind="$2" ;; --title) title="$2" ;; --slug) slug="$2" ;; --description) desc="$2" ;; esac
        shift 2 ;;
      --no-secret-check) secret_check=0; shift ;;
      -) pos+=("$1"); shift ;;
      -*) die "artifact add: unknown flag $1" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  [[ ${#pos[@]} -eq 2 && -n "$kind" && -n "$title" ]] || die "$usage"
  [[ "$kind" =~ ^($ARTIFACT_KINDS)$ ]] || die "--kind must be message (text to send), runbook (commands to run), note or page (HTML to read), not '$kind'"
  [[ -n "${title//[[:space:]]/}" && "$title" != *[$'\n\r\t']* ]] || die "--title is one line of text"
  [[ "$desc" != *[$'\n\r\t']* ]] || die "--description is one line of text"
  [[ -n "$slug" ]] || slug="$(artifact_slug "$title")"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || die "--slug must be lowercase letters, digits and dashes (at most 48), not '$slug'"
  local src="${pos[1]}"
  [[ "$src" == - || -f "$src" ]] || die "no such file: $src"
  o="$(artifact_owner "${pos[0]}" --open)" || exit 1
  type="${o%% *}"; owner="${o#* }"
  if [[ "$type" == task ]]; then project="$(project_label "$owner")"
  else project="$(dashboard_inbox | jq -r --arg t "$owner" '.waiting[] | select(.short_id == $t) | .project // empty' | head -1)"; fi
  d="$(artifact_dir "$type" "$owner")"; f="$d/$slug.$(artifact_ext "$kind")"; m="$d/$slug.json"
  # Ours to replace: the sidecar `add` wrote and its own text (a page that was a note keeps no .md).
  mine="$(artifact_text_of "$m" || true)"
  if [[ -e "$m" && -z "$mine" ]] || [[ -e "$f" && "$f" != "$mine" ]]; then
    die "$d/$slug.json or .$(artifact_ext "$kind") is there and is not a chartroom artifact (a worker's own file?); pick another --slug"
  fi
  mkdir -p "$d"
  if [[ "$src" == - ]]; then cat >"$f.tmp"; else cat -- "$src" >"$f.tmp"; fi
  [[ -s "$f.tmp" ]] || { rm -f "$f.tmp"; die "nothing to save: the text is empty"; }
  if [[ -f "$m" ]]; then created="$(jq -r '.created // empty' "$m")"; old="$(jq -r '.title // empty' "$m")"; fi
  if [[ "$kind" == page ]]; then
    # (a subshell: page_build dies with the reason, and the partial file must not stay behind)
    local label="$owner"
    [[ "$type" == task ]] && label="$(short_ids_json | jq -r --arg id "$owner" '.[$id] // $id')"
    ( page_build "$f.tmp" "$([[ "$src" == - ]] || dirname -- "$src")" "$secret_check" "$title" "$desc" "$project" "$label/$slug" ) ||
      { rm -f "$f.tmp"; exit 1; }
  fi
  jq -n --argjson schema "$CR_SCHEMA" --arg title "$title" --arg kind "$kind" --arg desc "$desc" --arg project "$project" \
    --arg task "$([[ "$type" == task ]] && printf '%s' "$owner")" --arg created "$created" --arg now "$(now)" \
    '{schema: $schema, title: $title, kind: $kind, description: (if $desc == "" then null else $desc end),
      task: (if $task == "" then null else $task end), project: (if $project == "" then null else $project end),
      created: (if $created == "" then $now else $created end), updated: $now, done: null}' >"$m.tmp"
  mv "$f.tmp" "$f" && mv "$m.tmp" "$m"
  [[ -z "$mine" || "$mine" == "$f" ]] || rm -f -- "$mine"
  ref="$(artifacts_json --owner "$type" "$owner" | jq -r --arg s "$slug" '.[] | select(.slug == $s) | .ref')"
  if [[ "$type" == task ]]; then log_event "$owner" note "artifact $slug ($kind) $([[ -n "$old" ]] && echo updated || echo added): $title"; fi
  [[ -z "$old" ]] || warn "replaced the $([[ "$kind" == page ]] && echo page || echo text) of $ref (was: $old)"
  echo "$ref"
}

artifact_list() { # [<id>] [--all] [--json]
  local all=0 json=0 id="" a o data args=()
  for a in "$@"; do
    case "$a" in
      --all) all=1 ;;
      --json) json=1 ;;
      -*) die "artifact list: unknown arg $a" ;;
      *) [[ -z "$id" ]] || die "usage: chartroom artifact list [<id>] [--all] [--json]"; id="$a" ;;
    esac
  done
  if [[ -n "$id" ]]; then o="$(artifact_owner "$id")" || exit 1; args+=(--owner "${o%% *}" "${o#* }"); fi
  [[ $all -eq 1 ]] || args+=(--open)
  data="$(artifacts_json "${args[@]+"${args[@]}"}")"
  if [[ $json -eq 1 ]]; then jq . <<<"$data"; return 0; fi
  if [[ "$(jq length <<<"$data")" -eq 0 ]]; then
    echo "no $([[ $all -eq 1 ]] || echo 'open ')artifacts${id:+ on $id}"; return 0
  fi
  jq -r --argjson all "$all" '.[] | [.ref, .kind, (.project // "-"), .title, ((.updated // "-") | .[0:16] | sub("T"; " "))]
      + (if $all == 1 then [(.done // "-") | .[0:10]] else [] end) | @tsv' <<<"$data" |
    { printf 'REF\tKIND\tPROJECT\tTITLE\tUPDATED%s\n' "$([[ $all -eq 1 ]] && printf '\tDONE')"; cat; } | table
}

artifact_show() { # <ref> [--path]
  local ref="" path=0 a
  for a in "$@"; do
    case "$a" in --path) path=1 ;; -*) die "artifact show: unknown arg $a" ;; *) ref="$a" ;; esac
  done
  [[ -n "$ref" ]] || die "usage: chartroom artifact show <ref> [--path]"
  artifact_resolve "$ref"
  if [[ $path -eq 1 ]]; then echo "$AR_FILE"; else cat -- "$AR_FILE"; fi
}

# Copies the text, or prints it when there is no clipboard (or it fails). The tool's output goes
# to files, never to ours: xclip and wl-copy stay behind to serve the clipboard, and would hold
# a caller's pipe open.
artifact_copy() { # <ref>
  [[ $# -eq 1 ]] || die "usage: chartroom artifact copy <ref>"
  artifact_resolve "$1"
  local clip argv=() errf why
  clip="$(clipboard_cmd)"
  if [[ "$clip" == - ]]; then cat -- "$AR_FILE"; return 0; fi
  if [[ -n "$clip" ]]; then
    read -ra argv <<<"$clip"
    errf="$(mktemp)"
    if "${argv[@]}" <"$AR_FILE" >/dev/null 2>"$errf"; then
      rm -f "$errf"; echo "copied $AR_REF to the clipboard ($clip): $AR_TITLE"; return 0
    fi
    why="$(head -1 "$errf")"; rm -f "$errf"
    warn "$clip failed${why:+ ($why)}; printing $AR_REF instead"
  else
    warn "no clipboard tool (pbcopy, wl-copy, xclip, xsel; or set CHARTROOM_CLIPBOARD); printing $AR_REF instead"
  fi
  cat -- "$AR_FILE"
}

artifact_done() { # <ref>
  [[ $# -eq 1 ]] || die "usage: chartroom artifact done <ref>"
  artifact_resolve "$1"
  local m="${AR_FILE%.*}.json" was
  was="$(jq -r '.done // empty' "$m")"
  if [[ -n "$was" ]]; then echo "$AR_REF was already done ($was)"; return 0; fi
  jq --arg now "$(now)" '.done = $now' "$m" >"$m.tmp" && mv "$m.tmp" "$m"
  if [[ "$AR_TYPE" == task ]]; then log_event "$AR_OWNER" note "artifact $AR_SLUG done: $AR_TITLE"; fi
  echo "done $AR_REF: $AR_TITLE"
}

cmd_artifact() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add) artifact_add "$@" ;;
    list|ls) artifact_list "$@" ;;
    show) artifact_show "$@" ;;
    copy) artifact_copy "$@" ;;
    done) artifact_done "$@" ;;
    open) artifact_open "$@" ;;
    export) artifact_export "$@" ;;
    pdf) artifact_pdf "$@" ;;
    publish) artifact_publish "$@" ;;
    template) artifact_template "$@" ;;
    *) die "usage: chartroom artifact add|list|show|copy|done|open|export|pdf|publish|template (chartroom help)" ;;
  esac
}
