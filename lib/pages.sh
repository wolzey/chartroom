# shellcheck shell=bash
# Pages: artifacts of kind page (lib/artifacts.sh), a report as HTML for the commander to read in
# the dashboard instead of in chat, and to print to PDF.
#
# A page is one self-contained file, tasks/<id>/artifacts/<slug>.html: inline CSS, images as
# data: URIs, no scripts, nothing fetched. `add` makes it so:
#   - a fragment (no <html> or doctype) is wrapped in the default page (templates/page.html
#     and templates/page.css: light and dark, print styles), headed with its title, description,
#     project and date;
#   - a whole document is kept as written, with the page policy (PAGE_CSP) put first in it;
#   - images given as files beside the source (src="chart.png") are inlined as data: URIs;
#   - text that looks like a secret is refused (relay_secret_kind; --no-secret-check overrides).
# The HTML is crew-written, so it is untrusted wherever it is shown: the dashboard serves it
# sandboxed under PAGE_CSP (lib/dashboard/server.py), and `pdf` prints a copy with scripts off.

PAGE_MAX_BYTES=$((16 * 1024 * 1024))
# The policy a page is read under, everywhere: inline styles and data: images, fonts and media;
# no scripts, nothing fetched. (server.py serves pages under the same, plus sandbox.)
PAGE_CSP="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; base-uri 'none'; form-action 'none'"
PAGE_PAPERS='letter legal ledger tabloid a3 a4 a5 b4 b5'
# Chrome's flags for a print: headless (the new mode, where Chrome has one), in a throwaway profile
# that never touches the system keychain (macOS asks for "Chrome Safe Storage" for every new
# profile otherwise) and never goes to the network by itself; no first-run or default-browser
# prompts, no scrollbars, no header or footer on the pages. test/pages.bats pins them.
PAGE_CHROME_FLAGS=(--headless=new --use-mock-keychain --password-store=basic --disable-background-networking
  --disable-component-update --disable-sync --disable-extensions --disable-gpu --hide-scrollbars
  --no-first-run --no-default-browser-check --no-pdf-header-footer --print-to-pdf-no-header)

# A file's text, exactly, into the caller's variable (command substitution would drop its
# trailing newlines).
page_read() { local s; s="$(cat -- "$1"; printf x)"; printf -v "$2" '%s' "${s%x}"; } # <file> <variable>

# Is it a whole document (a doctype or an <html> tag near the top), not a fragment to wrap?
page_is_document() { # <html file>
  local h re='<(!doctype[[:space:]]+html|html)([[:space:]>]|$)'
  h="$(head -c 4096 -- "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$h" =~ $re ]]
}

# Put the page policy first in a document: right after its doctype (before it would put the page
# in quirks mode), else at the very top, so it governs everything after it.
page_csp_insert() { # <html file>
  local html meta re='^([[:space:]]*<![Dd][Oo][Cc][Tt][Yy][Pp][Ee][^>]*>)'
  meta="<meta http-equiv=\"Content-Security-Policy\" content=\"$PAGE_CSP\">"
  page_read "$1" html; html="${html#$'\xef\xbb\xbf'}"
  if [[ "$html" =~ $re ]]; then html="${BASH_REMATCH[1]}"$'\n'"$meta${html:${#BASH_REMATCH[1]}}"
  else html="$meta"$'\n'"$html"; fi
  printf '%s' "$html" >"$1"
}

# Images given as files beside the source (src="chart.png", src='img/a.svg') become data: URIs,
# so the page stays one file. Only plain relative paths under the source's directory, of image
# types, are read; any other relative src is left as written, and said.
page_inline_images() { # <html file> <source dir, or "" for stdin>
  local f="$1" dir="$2" html m q v p ext mime data
  page_read "$f" html
  while IFS= read -r m; do
    q="${m:4:1}"; v="${m:5:${#m}-6}"
    [[ -z "$v" || "$v" =~ ^[A-Za-z][A-Za-z0-9+.-]*: || "$v" == /* || "$v" == '#'* ]] && continue # data:, https:, /x, #x
    ext="$(tr '[:upper:]' '[:lower:]' <<<"${v##*.}")"
    case "$ext" in
      png) mime=image/png ;; jpg|jpeg) mime=image/jpeg ;; gif) mime=image/gif ;; svg) mime=image/svg+xml ;;
      webp) mime=image/webp ;; avif) mime=image/avif ;; *) mime="" ;;
    esac
    p="$dir/$v"
    if [[ -z "$dir" || -z "$mime" || "$v" == *..* || ! "$v" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ || ! -f "$p" || -L "$p" ]]; then
      warn "not inlined: $v (a page loads nothing: give an image as a file beside the source, or as a data: URI)"; continue
    fi
    data="$(base64 <"$p" | tr -d '\r\n')"
    html="${html//"$m"/"src=$q""data:$mime;base64,$data""$q"}"
  done < <(grep -oE "src=(\"[^\"]*\"|'[^']*')" "$f" | sort -u || true)
  printf '%s' "$html" >"$f"
}

# The default page around a fragment (templates/page.html), in place. The body goes in last, so
# nothing in it is taken for a slot.
page_wrap() { # <fragment file> <title> <description> <project> <ref label>
  jq -Rrs --arg tpl "$(cat "$CR_ROOT/templates/page.html")" --arg css "$(cat "$CR_ROOT/templates/page.css")" \
    --arg csp "$PAGE_CSP" --arg title "$2" --arg desc "$3" --arg project "$4" --arg ref "$5" --arg stamp "$(now)" '
    . as $body
    | ($stamp | sub("T"; " ") | sub(":[0-9]{2}Z$"; " UTC")) as $when
    | [["{{csp}}", $csp], ["{{style}}", $css], ["{{title}}", ($title | @html)],
       ["{{kicker}}", ([$project, $when] | map(select(. != "") | "<span>" + (. | @html) + "</span>") | join(""))],
       ["{{description}}", (if $desc == "" then "" else "<p class=\"cr-desc\">" + ($desc | @html) + "</p>" end)],
       ["{{footer}}", ("chartroom page " + ($ref | @html) + " · updated " + $when)],
       ["{{body}}", $body]]
    | reduce .[] as [$k, $v] ($tpl; split($k) | join($v))' <"$1" >"$1.wrap"
  mv -- "$1.wrap" "$1"
}

# What `add --kind page` does to the text before it is kept (see the top); dies saying why.
page_build() { # <html file> <source dir or ""> <secret check 1|0> <title> <description> <project> <ref label>
  local f="$1" kind n
  if [[ "$3" == 1 ]] && kind="$(relay_secret_kind "$(sed -E 's#data:[A-Za-z0-9.+/-]+;base64,[A-Za-z0-9+/=]+##g' "$f")")"; then
    die "page refused: it looks like it holds $kind. A page never carries a secret: say where it is kept instead (--no-secret-check if it is not one). Nothing was saved"
  fi
  page_inline_images "$f" "$2"
  n="$(grep -ciE "(src|srcset|poster)=[\"']?(https?:)?//|<link[^>]+href=[\"']?(https?:)?//|@import[[:space:]]+(url\\()?[\"']?(https?:)?//|url\\([\"']?(https?:)?//" "$f" || true)"
  [[ "$n" == 0 ]] || warn "$n line(s) of the page refer to other sites (src, <link>, @import, url()): they will not load, a page fetches nothing"
  if grep -qiE '<script([[:space:]>]|$)' "$f"; then warn "the page has a <script>: it will not run, a page runs no scripts"; fi
  if page_is_document "$f"; then page_csp_insert "$f"; else page_wrap "$f" "$4" "$5" "$6" "$7"; fi
  n="$(wc -c <"$f" | tr -d ' ')"
  (( n <= PAGE_MAX_BYTES )) || die "the page is $n bytes, over the $PAGE_MAX_BYTES-byte limit (smaller images?)"
}

# ---------------------------------------------------------------- printing

# The Chrome (or Chromium, or Edge) that prints PDFs: CHARTROOM_CHROME (a path or a command name;
# nothing else is tried when it is set), else the first of these on PATH, else the usual app
# locations. Prints nothing when there is none.
page_chrome() {
  local c p
  c="$(cfg CHROME '' '')"
  if [[ -n "$c" ]]; then
    if [[ "$c" == */* ]]; then [[ -f "$c" && -x "$c" ]] && printf '%s' "$c"; else bin_of "$c"; fi
    return 0
  fi
  for c in google-chrome google-chrome-stable chromium chromium-browser chrome chrome-headless-shell microsoft-edge msedge; do
    p="$(bin_of "$c")"; [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  for p in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "/Applications/Chromium.app/Contents/MacOS/Chromium" "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
           "/c/Program Files/Google/Chrome/Application/chrome.exe" "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
           "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"; do
    [[ -f "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 0
}
page_chrome_missing() {
  local c; c="$(cfg CHROME '' '')"
  if [[ -n "$c" ]]; then echo "CHARTROOM_CHROME is '$c', which is not a program here: set it to Chrome or Chromium, or unset it to look for one"
  else echo "no Chrome or Chromium to print PDFs with (looked for google-chrome, chromium, chrome and msedge on PATH, and in the usual app folders): install one, or set CHARTROOM_CHROME to its path"; fi
}
# For `doctor`: {chrome: path or null, why: null or why not}.
page_doctor_json() {
  local c; c="$(page_chrome)"
  jq -cn --arg c "$c" --arg why "$([[ -n "$c" ]] || page_chrome_missing)" '{chrome: (if $c == "" then null else $c end), why: (if $why == "" then null else $why end)}'
}

# Every process still running on a throwaway profile (a helper Chrome left behind): ended.
page_chrome_reap() { # <profile dir>
  command -v pkill >/dev/null 2>&1 || return 0
  pkill -f -- "--user-data-dir=$1( |$)" 2>/dev/null || true
}

# Print a page to PDF with headless Chrome: a copy of it, with the page policy first and the paper
# size last, scripts off, in a throwaway profile. Writes <out> only once a PDF came out, and leaves
# no Chrome running.
page_print() { # <page file> <out pdf> <css page size>
  local chrome tmp t u i pid secs why
  chrome="$(page_chrome)"
  [[ -n "$chrome" ]] || die "$(page_chrome_missing)"
  secs="$(cfg PDF_TIMEOUT '' 60)"
  [[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]] || die "CHARTROOM_PDF_TIMEOUT must be a whole number of seconds"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chartroom-pdf.XXXXXX")"
  cp -- "$1" "$tmp/page.html"
  page_csp_insert "$tmp/page.html"
  printf '\n<style>@page { size: %s; }</style>\n' "$3" >>"$tmp/page.html"
  t="$(win_path "$tmp")"; u="$t/page.html"; [[ "$u" == /* ]] || u="/$u"; u="${u// /%20}"
  "$chrome" "${PAGE_CHROME_FLAGS[@]}" "--user-data-dir=$t/profile" "--print-to-pdf=$t/out.pdf" "file://$u" \
    >"$tmp/chrome.log" 2>&1 </dev/null &
  pid=$!
  for ((i = 0; i < secs * 10; i++)); do pid_alive "$pid" || break; sleep 0.1; done
  if pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true; page_chrome_reap "$t/profile"; rm -rf "$tmp"
    die "Chrome did not finish printing within ${secs}s (CHARTROOM_PDF_TIMEOUT; $chrome)"
  fi
  wait "$pid" 2>/dev/null || true
  page_chrome_reap "$t/profile"
  if [[ "$(head -c 5 "$tmp/out.pdf" 2>/dev/null || true)" != %PDF- ]]; then
    why="$(grep -vE '^\[[0-9:/.]+:' "$tmp/chrome.log" | grep -v '^[[:space:]]*$' | tail -1 || true)"
    rm -rf "$tmp"
    die "Chrome printed no PDF ($chrome)${why:+: $why}"
  fi
  mv -- "$tmp/out.pdf" "$2"
  rm -rf "$tmp"
}

# The file to write for --out: the default name in the current directory, or in the directory
# --out names.
page_out_path() { # <--out value or ""> <default file name>
  local out="${1:-.}"
  [[ -d "$out" ]] && out="${out%/}/$2"
  [[ -d "$(dirname -- "$out")" ]] || die "no such directory: $(dirname -- "$out")"
  printf '%s' "$out"
}

# ---------------------------------------------------------------- commands

artifact_open() { # <ref>
  [[ $# -eq 1 && "$1" != -* ]] || die "usage: chartroom artifact open <ref>"
  artifact_resolve "$1"
  find_python
  [[ ${#CR_PY[@]} -gt 0 ]] || die "artifact open shows it in the dashboard, which needs python3; chartroom artifact export $AR_REF (or pdf) works without it"
  CR_DASHBOARD_PATH="pages/$AR_TYPE/$AR_OWNER/$AR_SLUG" dashboard_open
}

artifact_export() { # <ref> [--out FILE|DIR]
  local ref="" out="" usage="usage: chartroom artifact export <ref> [--out FILE|DIR]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) [[ $# -ge 2 ]] || die "$usage"; out="$2"; shift 2 ;;
      -*) die "artifact export: unknown flag $1" ;;
      *) [[ -z "$ref" ]] || die "$usage"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || die "$usage"
  artifact_resolve "$ref"
  out="$(page_out_path "$out" "$AR_SLUG.${AR_FILE##*.}")"
  cp -- "$AR_FILE" "$out.tmp" && mv -- "$out.tmp" "$out"
  echo "exported $AR_REF to $out"
}

artifact_pdf() { # <ref> [--out FILE|DIR] [--paper SIZE] [--landscape]
  local ref="" out="" paper landscape="" usage="usage: chartroom artifact pdf <ref> [--out FILE|DIR] [--paper ${PAGE_PAPERS// /|}] [--landscape]"
  paper="$(cfg PDF_PAPER '' letter)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out|--paper) [[ $# -ge 2 ]] || die "$usage"; if [[ "$1" == --out ]]; then out="$2"; else paper="$2"; fi; shift 2 ;;
      --landscape) landscape=" landscape"; shift ;;
      -*) die "artifact pdf: unknown flag $1" ;;
      *) [[ -z "$ref" ]] || die "$usage"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || die "$usage"
  paper="$(tr '[:upper:]' '[:lower:]' <<<"$paper")"
  [[ " $PAGE_PAPERS " == *" $paper "* ]] || die "--paper is one of $PAGE_PAPERS (set the default with CHARTROOM_PDF_PAPER), not '$paper'"
  artifact_resolve "$ref"
  [[ "$AR_KIND" == page ]] || die "pdf prints a page (--kind page); $AR_REF is a $AR_KIND (chartroom artifact show $AR_REF prints it)"
  out="$(page_out_path "$out" "$AR_SLUG.pdf")"
  page_print "$AR_FILE" "$out" "$paper$landscape"
  echo "wrote $out ($AR_REF, $paper$landscape)"
}

# The hosting hook, not built yet: one page, one provider, one link back. A provider would upload
# the page's single file (and nothing else), check it for secrets again, record
# {provider, url, at} in the sidecar's `published` and note it in the task's events. Until one is
# configured it refuses, and nothing leaves the machine.
artifact_publish() { # <ref> --to <provider>
  local ref="" to="" usage="usage: chartroom artifact publish <ref> --to <provider>"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) [[ $# -ge 2 ]] || die "$usage"; to="$2"; shift 2 ;;
      -*) die "artifact publish: unknown flag $1" ;;
      *) [[ -z "$ref" ]] || die "$usage"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" && -n "$to" ]] || die "$usage"
  [[ "$to" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "--to names a provider (such as vercel), not '$to'"
  artifact_resolve "$ref"
  [[ "$AR_KIND" == page ]] || die "publish takes a page (--kind page); $AR_REF is a $AR_KIND"
  die "publishing is not configured: there is no '$to' provider (hosting is not built yet). Nothing was uploaded; chartroom artifact export $AR_REF writes the file to share by hand"
}

# The default page around a sample body (templates/page-sample.html), to start a page from or to
# see the classes; --body prints the sample body alone (what `add` takes and wraps).
artifact_template() { # [--title T] [--description D] [--body]
  local title="Title of the page" desc="One line on what this page is for." body=0 tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title|--description)
        [[ $# -ge 2 ]] || die "usage: chartroom artifact template [--title T] [--description D] [--body]"
        if [[ "$1" == --title ]]; then title="$2"; else desc="$2"; fi; shift 2 ;;
      --body) body=1; shift ;;
      *) die "usage: chartroom artifact template [--title T] [--description D] [--body]" ;;
    esac
  done
  if [[ $body -eq 1 ]]; then cat "$CR_ROOT/templates/page-sample.html"; return 0; fi
  tmp="$(mktemp)"
  cp "$CR_ROOT/templates/page-sample.html" "$tmp"
  page_wrap "$tmp" "$title" "$desc" "project" "21ba/slug"
  cat "$tmp"; rm -f "$tmp"
}
