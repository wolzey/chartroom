#!/usr/bin/env bats
# Pages: artifacts of kind page, a report as one self-contained HTML file. How `add` keeps them
# (the default page around a fragment, the page policy, inlined images, refused secrets), export,
# pdf (a fake Chrome for the plumbing, a real one when there is one), publish's refusal, and how
# the dashboard serves them: sandboxed, under their own policy, behind the token when exposed.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
  PY="$(type -P python3 || true)"
  case "${OSTYPE:-}" in msys*|cygwin*) PY="${CR_TEST_PYTHON:-}" ;; esac
  SRC="$BATS_TEST_TMPDIR/src"; mkdir -p "$SRC"
  CSP="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; base-uri 'none'; form-action 'none'"
}

teardown() { cr dashboard stop >/dev/null 2>&1 || true; }

# A task with one page from a small fragment; sets ID, SID, D (its artifacts dir), REF and PAGE.
page_task() {
  ID="$(TITLE="report task" new_task)"; SID="${ID: -4}"; D="$CHARTROOM_HOME/tasks/$ID/artifacts"
  printf '<h2>Findings</h2>\n<p>All good.</p>\n' >"$SRC/frag.html"
  REF="$(cr artifact add "$ID" --kind page --title "Weekly report" "$SRC/frag.html")"
  PAGE="$D/weekly-report.html"
}

@test "add: a fragment is wrapped in the default page, headed with its title, description, project and date" {
  local id sid d f ref
  id="$(TITLE="report task" new_task)"; sid="${id: -4}"; d="$CHARTROOM_HOME/tasks/$id/artifacts"
  mkdir -p "$SRC/img"
  printf 'PNGDATA' >"$SRC/img/chart.png"
  printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$SRC/dot.svg"
  cat >"$SRC/page.html" <<'EOF'
<h2>Findings</h2>
<p>Three <b>things</b> & one more; {{title}} and {{body}} stay as written.</p>
<p>Text about CSS is not a reference: <code>@import "tailwindcss"</code>.</p>
<img src="img/chart.png" alt="chart"><img src='dot.svg'>
<img src="data:image/gif;base64,R0lGOD==">
EOF
  run cr artifact add "$id" --kind page --title 'Q3 <review> "draft"' --description "What we found & why" "$SRC/page.html"
  [ "$status" -eq 0 ]
  ref="$sid/q3-review-draft"; [ "$output" = "$ref" ]
  f="$d/q3-review-draft.html"
  [ -f "$f" ]; [ ! -e "$d/q3-review-draft.md" ]
  [ "$(jq -c '[.schema, .kind, .description, .task, .project, .done]' "$d/q3-review-draft.json")" = \
    "[1,\"page\",\"What we found & why\",\"$id\",\"proj\",null]" ]
  [ "$(jq -r .title "$d/q3-review-draft.json")" = 'Q3 <review> "draft"' ]
  # the default page: the page policy, the title and description escaped, the stylesheet inline
  [ "$(head -1 "$f")" = "<!doctype html>" ]
  grep -qF "<meta http-equiv=\"Content-Security-Policy\" content=\"$CSP\">" "$f"
  grep -qF '<base target="_blank">' "$f"
  grep -qF '<title>Q3 &lt;review&gt; &quot;draft&quot;</title>' "$f"
  grep -qF '<h1>Q3 &lt;review&gt; &quot;draft&quot;</h1>' "$f"
  grep -qF '<p class="cr-desc">What we found &amp; why</p>' "$f"
  grep -qF '<p class="cr-kicker"><span>proj</span><span>' "$f"
  grep -qF "chartroom page $ref · updated " "$f"
  grep -qF '<style data-chartroom="page">' "$f"
  grep -qF '@media print' "$f"; grep -qF 'prefers-color-scheme: dark' "$f"; grep -qF 'display: table-header-group' "$f"
  grep -qF '<body class="cr-page">' "$f"
  # the body as given: nothing in it is taken for a slot of the template
  grep -qF '<p>Three <b>things</b> & one more; {{title}} and {{body}} stay as written.</p>' "$f"
  # images beside the source become data: URIs; a data: URI is left alone
  grep -qF "src=\"data:image/png;base64,$(printf PNGDATA | base64)\"" "$f"
  grep -qF "src='data:image/svg+xml;base64," "$f"
  grep -qF 'src="data:image/gif;base64,R0lGOD=="' "$f"
  [ -z "$(grep -E "src=[\"'](img/|dot)" "$f" || true)" ]
  # listed and shown by ref like any artifact
  [ "$(cr artifact list --json | jq -c 'map([.ref, .kind, .description, .path])')" = "[[\"$ref\",\"page\",\"What we found & why\",\"$f\"]]" ]
  [[ "$(cr artifact list)" == *"$ref"*page*proj*'Q3 <review> "draft"'* ]]
  [ "$(cr artifact show "$ref" --path)" = "$f" ]
  [ "$(cr artifact show "$ref.html" --path)" = "$f" ]
  cr artifact show "$ref" >"$BATS_TEST_TMPDIR/shown"; cmp "$BATS_TEST_TMPDIR/shown" "$f"
  CHARTROOM_CLIPBOARD=- cr artifact copy "$ref" >"$BATS_TEST_TMPDIR/copied"; cmp "$BATS_TEST_TMPDIR/copied" "$f"
  events "$id" | grep -qE ' note: artifact q3-review-draft \(page\) added: Q3 <review> "draft"$'
  # from stdin too (no images to read there: a relative src is left, and said)
  run cr artifact add "$id" --kind page --title "From stdin" - <<<'<p>hi</p><img src="x.png">'
  [ "$status" -eq 0 ]; [[ "$output" == *"not inlined: x.png"* ]]; [[ "${lines[${#lines[@]}-1]}" == "$sid/from-stdin" ]]
  grep -qF '<p>hi</p><img src="x.png">' "$d/from-stdin.html"
}

@test "add: a whole document is kept as written, with the page policy first; what will not load or run is said" {
  local id d f
  id="$(new_task)"; d="$CHARTROOM_HOME/tasks/$id/artifacts"
  printf '<!DOCTYPE html>\n<html lang="fr"><head><title>Mine</title><link rel="stylesheet" href="https://cdn.example/x.css"></head>\n<body><script>alert(1)</script><img src="https://cdn.example/a.png"><img src="../secret.png"></body></html>\n' >"$SRC/doc.html"
  printf 'x' >"$BATS_TEST_TMPDIR/secret.png"
  run cr artifact add "$id" --kind page --title "Mine" "$SRC/doc.html"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 line(s) of the page refer to other sites"* ]]
  [[ "$output" == *"the page has a <script>: it will not run"* ]]
  [[ "$output" == *"not inlined: ../secret.png"* ]]
  f="$d/mine.html"
  [ "$(sed -n 1p "$f")" = "<!DOCTYPE html>" ]
  [ "$(sed -n 2p "$f")" = "<meta http-equiv=\"Content-Security-Policy\" content=\"$CSP\">" ]
  [ "$(sed -n '3,$p' "$f")" = "$(sed -n '2,$p' "$SRC/doc.html")" ]
  [ -z "$(grep -E 'cr-head|data-chartroom' "$f" || true)" ]
  # without a doctype the policy goes on top; a byte-order mark does not hide the doctype
  printf '<html><body><p>x</p></body></html>\n' >"$SRC/bare.html"
  cr artifact add "$id" --kind page --title "Bare" "$SRC/bare.html" >/dev/null
  [ "$(sed -n 1p "$d/bare.html")" = "<meta http-equiv=\"Content-Security-Policy\" content=\"$CSP\">" ]
  [ "$(sed -n 2p "$d/bare.html")" = "<html><body><p>x</p></body></html>" ]
  printf '\xef\xbb\xbf<!doctype html><p>bom</p>\n' >"$SRC/bom.html"
  cr artifact add "$id" --kind page --title "Bom" "$SRC/bom.html" >/dev/null
  [ "$(sed -n 1p "$d/bom.html")" = "<!doctype html>" ]
  # `artifact template` prints a whole document, kept as is
  cr artifact template --title "From the template" >"$SRC/tpl.html"
  cr artifact add "$id" --kind page --title "From the template" "$SRC/tpl.html" >/dev/null
  [ "$(grep -c 'Content-Security-Policy' "$d/from-the-template.html")" -eq 2 ]
  grep -qF '<title>From the template</title>' "$d/from-the-template.html"
}

@test "add: a page that looks like it holds a secret is refused and nothing is kept; --no-secret-check keeps it" {
  local id d tok
  id="$(new_task)"; d="$CHARTROOM_HOME/tasks/$id/artifacts"
  tok="ghp_$(printf 'a%.0s' {1..36})"
  printf '<p>the token is %s</p>\n' "$tok" >"$SRC/leak.html"
  run cr artifact add "$id" --kind page --title "Leak" "$SRC/leak.html"
  [ "$status" -ne 0 ]
  [[ "$output" == *"page refused: it looks like it holds a GitHub token"*"Nothing was saved"* ]]
  [ -z "$(ls -A "$d" 2>/dev/null)" ]
  run cr artifact add "$id" --kind page --title "Leak" --no-secret-check "$SRC/leak.html"
  [ "$status" -eq 0 ]; grep -qF "$tok" "$d/leak.html"
  # image data is never read as text: a data: URI that happens to look like a key is fine
  printf '<img src="data:image/png;base64,AKIAABCDEFGHIJKLMNOP">\n' >"$SRC/img.html"
  run cr artifact add "$id" --kind page --title "Img" "$SRC/img.html"
  [ "$status" -eq 0 ]
  # the other kinds are unchanged: no check there
  run cr artifact add "$id" --kind note --title "Note" "$SRC/leak.html"
  [ "$status" -eq 0 ]
}

@test "add: a slug changes kind cleanly (one text file at a time); a worker's own .html is never taken or listed" {
  local id sid d
  id="$(new_task)"; sid="${id: -4}"; d="$CHARTROOM_HOME/tasks/$id/artifacts"
  [ "$(cr artifact add "$id" --kind note --title "Summary" - <<<"plain")" = "$sid/summary" ]
  run cr artifact add "$id" --kind page --title "Summary" - <<<"<p>rich</p>"
  [ "$status" -eq 0 ]; [[ "$output" == *"replaced the page of $sid/summary (was: Summary)"* ]]
  [ ! -e "$d/summary.md" ]; [ -f "$d/summary.html" ]
  [ "$(cr artifact list --json | jq -c 'map([.ref, .kind])')" = "[[\"$sid/summary\",\"page\"]]" ]
  cr artifact add "$id" --kind note --title "Summary" - <<<"plain again" >/dev/null 2>&1
  [ ! -e "$d/summary.html" ]; [ "$(cat "$d/summary.md")" = "plain again" ]
  # a worker's own HTML, alone or beside one of ours, is never listed or overwritten
  echo '<p>worker</p>' >"$d/notes.html"
  echo '<p>worker</p>' >"$d/summary.html"
  [ "$(cr artifact list --json | jq -c 'map([.ref, .kind])')" = "[[\"$sid/summary\",\"note\"]]" ]
  for s in notes summary; do
    run cr artifact add "$id" --kind page --title "$s" - <<<"<p>mine</p>"
    [ "$status" -ne 0 ]; [[ "$output" == *"is not a chartroom artifact"* ]]
    [ "$(cat "$d/$s.html")" = '<p>worker</p>' ]
  done
  # a page's sidecar without its .html is no artifact; neither is a note's sidecar with only an .html
  rm "$d/summary.md"
  echo '{"schema":1,"title":"Ghost","kind":"page"}' >"$d/ghost.json"
  [ "$(cr artifact list --all --json)" = "[]" ]
  [ "$(cr status | grep -c '^artifacts:' || true)" -eq 0 ]
}

@test "status, board and the lanes JSON count pages; a card carries its page; the todo list does not owe one" {
  page_task
  [ "$(cr status | tail -1)" = "artifacts: 1 open (1 page): chartroom artifact list" ]
  local board; board="$(cr dashboard --json)"
  [ "$(jq -c .artifacts <<<"$board")" = '{"open":1,"message":0,"runbook":0,"note":0,"page":1}' ]
  [ "$(jq -c --arg id "$ID" '.lanes[][] | select(.id == $id) | .artifacts | map([.ref, .kind])' <<<"$board")" = "[[\"$REF\",\"page\"]]" ]
  [ "$(cr todo --json | jq '[.items[] | select(.type == "artifact")] | length')" -eq 0 ]
  cr artifact done "$REF" >/dev/null
  [ "$(cr dashboard --json | jq -c .artifacts.page)" = 0 ]
}

@test "export: writes the page's file there, by name or into a directory; a text artifact's .md likewise" {
  page_task
  mkdir -p "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/cwd"
  run cr artifact export "$REF" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]; [ "$output" = "exported $REF to $BATS_TEST_TMPDIR/out/weekly-report.html" ]
  cmp "$PAGE" "$BATS_TEST_TMPDIR/out/weekly-report.html"
  run cr artifact export "$REF" --out "$BATS_TEST_TMPDIR/out/named.html"
  [ "$status" -eq 0 ]; cmp "$PAGE" "$BATS_TEST_TMPDIR/out/named.html"
  (cd "$BATS_TEST_TMPDIR/cwd" && "$CHARTROOM" artifact export "$REF" >/dev/null 3>&-)
  cmp "$PAGE" "$BATS_TEST_TMPDIR/cwd/weekly-report.html"
  local note; note="$(cr artifact add "$ID" --kind note --title "Plain" - <<<"plain")"
  cr artifact export "$note" --out "$BATS_TEST_TMPDIR/out" >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/out/plain.md")" = plain ]
  run cr artifact export "$REF" --out "$BATS_TEST_TMPDIR/nope/x.html"
  [ "$status" -ne 0 ]; [[ "$output" == *"no such directory"* ]]
  run cr artifact export
  [ "$status" -ne 0 ]; [[ "$output" == *usage* ]]
}

@test "pdf: Chrome prints a copy of the page, with the policy first and the paper size last, in a throwaway profile" {
  use_fake chrome
  export CHARTROOM_CHROME=chrome TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  page_task
  run cr artifact pdf "$REF" --out "$BATS_TEST_TMPDIR/r.pdf"
  [ "$status" -eq 0 ]; [ "$output" = "wrote $BATS_TEST_TMPDIR/r.pdf ($REF, letter)" ]
  local p="$BATS_TEST_TMPDIR/r.pdf"
  [ "$(sed -n 1p "$p")" = "%PDF-1.4" ]
  [ "$(sed -n 2p "$p")" = "<!doctype html>" ]
  [ "$(sed -n 3p "$p")" = "<meta http-equiv=\"Content-Security-Policy\" content=\"$CSP\">" ]
  [ "$(tail -1 "$p")" = "<style>@page { size: letter; }</style>" ]
  grep -qF '<h2>Findings</h2>' "$p"
  # headless, in a profile of its own that never asks the system keychain (macOS would prompt the
  # commander for "Chrome Safe Storage") nor goes to the network; no header or footer; nothing left behind
  local call f; call="$(grep '^chrome ' "$FAKE_LOG" | tail -1)"
  [[ "$call" == "chrome --headless=new "* ]]
  for f in --use-mock-keychain --password-store=basic --disable-background-networking --disable-component-update \
           --hide-scrollbars --no-first-run --no-default-browser-check --no-pdf-header-footer; do
    [[ " $call " == *" $f "* ]] || { echo "missing $f in: $call"; false; }
  done
  [[ "$call" == *" --user-data-dir=$TMPDIR/chartroom-pdf."*"/profile --print-to-pdf=$TMPDIR/chartroom-pdf."*"/out.pdf file://$TMPDIR/chartroom-pdf."*"/page.html" ]]
  [ -z "$(ls -A "$TMPDIR")" ]
  # the page itself is untouched
  [ "$(grep -c 'Content-Security-Policy' "$PAGE")" -eq 1 ]
  # paper: --paper and --landscape, else CHARTROOM_PDF_PAPER; into a directory, or here by default
  cr artifact pdf "$REF" --out "$BATS_TEST_TMPDIR" --paper A4 --landscape >/dev/null
  [ "$(tail -1 "$BATS_TEST_TMPDIR/weekly-report.pdf")" = "<style>@page { size: a4 landscape; }</style>" ]
  mkdir -p "$BATS_TEST_TMPDIR/cwd"
  (cd "$BATS_TEST_TMPDIR/cwd" && CHARTROOM_PDF_PAPER=legal "$CHARTROOM" artifact pdf "$REF" >/dev/null 3>&-)
  [ "$(tail -1 "$BATS_TEST_TMPDIR/cwd/weekly-report.pdf")" = "<style>@page { size: legal; }</style>" ]
  run cr artifact pdf "$REF" --paper huge
  [ "$status" -ne 0 ]; [[ "$output" == *"--paper is one of letter legal"*"not 'huge'"* ]]
  # a print that fails leaves the PDF that was there
  cp "$p" "$BATS_TEST_TMPDIR/before.pdf"
  FAKE_CHROME_FAIL=1 run cr artifact pdf "$REF" --out "$p"
  [ "$status" -ne 0 ]; [[ "$output" == *"Chrome printed no PDF ("*"chrome): fake chrome: nothing printed"* ]]
  cmp "$p" "$BATS_TEST_TMPDIR/before.pdf"
  [ -z "$(ls -A "$TMPDIR")" ]
  # only a page prints
  local note; note="$(cr artifact add "$ID" --kind note --title "Plain" - <<<"plain")"
  run cr artifact pdf "$note"
  [ "$status" -ne 0 ]; [[ "$output" == *"pdf prints a page (--kind page); $note is a note"* ]]
  # no Chrome: CHARTROOM_CHROME names one that is not there (nothing else is tried)
  CHARTROOM_CHROME="$BATS_TEST_TMPDIR/no-chrome" run cr artifact pdf "$REF" --out "$BATS_TEST_TMPDIR/x.pdf"
  [ "$status" -ne 0 ]; [[ "$output" == *"CHARTROOM_CHROME is '$BATS_TEST_TMPDIR/no-chrome', which is not a program here"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/x.pdf" ]
}

# Opt-in only: every other test prints with the fake. A real Chrome is a real browser on the
# machine running the tests, so it never runs in a loop or by default.
@test "pdf: a real Chrome or Chromium prints a page, and the page's scripts never run (CHARTROOM_TEST_REAL_CHROME=1)" {
  [[ "${CHARTROOM_TEST_REAL_CHROME:-}" == 1 ]] || skip "a real Chrome only with CHARTROOM_TEST_REAL_CHROME=1"
  unset CHARTROOM_CHROME
  local chrome; chrome="$(cr doctor --json | jq -r '.pdf.chrome // empty')"
  [[ -n "$chrome" ]] || skip "no Chrome or Chromium here"
  local id; id="$(new_task)"
  # a script that would add twenty pages: printed with it off, the PDF has one
  cat >"$SRC/doc.html" <<'EOF'
<!doctype html>
<html><head><script>for (let i = 0; i < 20; i++) document.write('<div style="break-after: page">x' + i + '</div>')</script></head>
<body><p>one page</p><script>for (let i = 0; i < 20; i++) document.body.insertAdjacentHTML('beforeend', '<div style="break-after: page">y' + i + '</div>')</script></body></html>
EOF
  local ref; ref="$(cr artifact add "$id" --kind page --title "Scripted" "$SRC/doc.html" 2>/dev/null)"
  run cr artifact pdf "$ref" --out "$BATS_TEST_TMPDIR/real.pdf"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -c 5 "$BATS_TEST_TMPDIR/real.pdf")" = "%PDF-" ]
  [ "$(LC_ALL=C grep -acE '/Type ?/Page([^s]|$)' "$BATS_TEST_TMPDIR/real.pdf")" -eq 1 ]
  # the paper size reaches the PDF: A4 is 595 x 842 points (Chrome rounds them down a little)
  cr artifact pdf "$ref" --out "$BATS_TEST_TMPDIR/a4.pdf" --paper a4 >/dev/null
  LC_ALL=C grep -aqE 'MediaBox \[0 0 59[45](\.[0-9]+)? 84[12](\.[0-9]+)?\]' "$BATS_TEST_TMPDIR/a4.pdf"
}

@test "doctor: names the Chrome that prints PDFs, or says why there is none" {
  use_fake chrome
  run env CHARTROOM_CHROME=chrome "$CHARTROOM" doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.pdf.chrome, .pdf.why]' <<<"$output")" = "[\"$BIN/chrome\",null]" ]
  [[ "$(CHARTROOM_CHROME=chrome cr doctor)" == *$'\n'"pdf:      $BIN/chrome (chartroom artifact pdf)"$'\n'* ]]
  run env CHARTROOM_CHROME=/nonexistent/chrome "$CHARTROOM" doctor --json
  [ "$(jq -r .pdf.chrome <<<"$output")" = null ]
  [[ "$(jq -r .pdf.why <<<"$output")" == "CHARTROOM_CHROME is '/nonexistent/chrome', which is not a program here"* ]]
  [[ "$(CHARTROOM_CHROME=/nonexistent/chrome cr doctor)" == *$'\n'"pdf:      - CHARTROOM_CHROME is '/nonexistent/chrome'"* ]]
}

@test "publish: refuses until a provider is set up, and nothing is uploaded or changed; template prints the default page" {
  page_task
  local before; before="$(snapshot "$CHARTROOM_HOME/tasks")"
  run cr artifact publish "$REF" --to vercel
  [ "$status" -eq 1 ]
  [[ "$output" == *"publishing is not configured: there is no 'vercel' provider"*"Nothing was uploaded; chartroom artifact export $REF"* ]]
  [ "$(snapshot "$CHARTROOM_HOME/tasks")" = "$before" ]
  run cr artifact publish "$REF"
  [ "$status" -ne 0 ]; [[ "$output" == *"usage: chartroom artifact publish <ref> --to <provider>"* ]]
  run cr artifact publish "$REF" --to "Bad Name"
  [ "$status" -ne 0 ]; [[ "$output" == *"--to names a provider"* ]]
  local note; note="$(cr artifact add "$ID" --kind note --title "Plain" - <<<"plain")"
  run cr artifact publish "$note" --to vercel
  [ "$status" -ne 0 ]; [[ "$output" == *"publish takes a page"* ]]
  # template: the default page around the sample body; --body the sample alone
  run cr artifact template --title "Weekly" --description "The week in one page"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "<!doctype html>" ]
  [[ "$output" == *"<title>Weekly</title>"*'<p class="cr-desc">The week in one page</p>'*'class="cr-kpis"'*"</html>" ]]
  [ "$(cr artifact template --body)" = "$(cat "$REPO_ROOT/templates/page-sample.html")" ]
}

# ---------------------------------------------------------------- the dashboard

need_python() { [[ -n "$PY" ]] || skip "python3 not available"; link_tool "$PY" python3; }
CURL_MAX=10; case "${OSTYPE:-}" in msys*|cygwin*) CURL_MAX=60 ;; esac
get() { curl -s --max-time "$CURL_MAX" "$@"; }
code() { curl -s -o /dev/null --max-time "$CURL_MAX" -w '%{http_code}' "$@"; }
# (an "end" line after them, so the last header keeps its newline through $(...))
headers() { curl -s -D - -o /dev/null --max-time "$CURL_MAX" "$@" | tr -d '\r'; echo end; }
start_daemon() {
  run cr dashboard --daemon --port 0 --no-gh "$@"
  [ "$status" -eq 0 ] || { echo "$output"; cat "$CHARTROOM_HOME/.dashboard.log" 2>/dev/null; false; }
  read -r _ PORT _ <"$CHARTROOM_HOME/.dashboard.pid"
  URL="http://127.0.0.1:$PORT"
}

@test "server: a page is served sandboxed under its own policy, only into this dashboard's frames; nothing else as HTML" {
  need_python
  page_task
  local note; note="$(cr artifact add "$ID" --kind note --title "Plain" - <<<"plain")"
  echo '<p>worker</p>' >"$D/own.html"
  echo '<p>worker</p>' >"$D/plain.html"
  start_daemon
  local h; h="$(headers "$URL/task/$ID/artifacts/weekly-report.html")"
  [[ "$h" == "HTTP/1."*" 200 "* ]]
  [[ "$h" == *$'\nContent-Type: text/html; charset=utf-8\n'* ]]
  [[ "$h" == *$'\nContent-Security-Policy: sandbox allow-popups allow-popups-to-escape-sandbox; '"$CSP; frame-ancestors 'self'"$'\n'* ]]
  [[ "$h" == *$'\nX-Frame-Options: SAMEORIGIN\n'* && "$h" == *$'\nX-Content-Type-Options: nosniff\n'* && "$h" == *$'\nReferrer-Policy: no-referrer\n'* ]]
  get "$URL/task/$ID/artifacts/weekly-report.html" >"$BATS_TEST_TMPDIR/served"; cmp "$BATS_TEST_TMPDIR/served" "$PAGE"
  # only a page's own .html: not a worker's file, not one beside a note, not a sidecar
  [ "$(code "$URL/task/$ID/artifacts/own.html")" = 404 ]
  [ "$(code "$URL/task/$ID/artifacts/plain.html")" = 404 ]
  [ "$(code "$URL/task/$ID/artifacts/weekly-report.json")" = 404 ]
  [ "$(code --path-as-is "$URL/task/$ID/artifacts/../brief.html")" = 404 ]
  [ "$(code -X POST "$URL/task/$ID/artifacts/weekly-report.html")" = 405 ]
  # the other kinds stay plain text that no frame may hold
  h="$(headers "$URL/task/$ID/artifacts/plain.md")"
  [[ "$h" == *$'\nContent-Type: text/plain; charset=utf-8\n'* && "$h" == *$'\nX-Frame-Options: DENY\n'* ]]
  # the list and the viewer: one page that frames only this server; the frame is sandboxed too
  local p
  for p in /pages /pages/ "/pages/task/$ID/weekly-report" "/pages/task/$ID/plain"; do
    h="$(headers "$URL$p")"
    [[ "$h" == "HTTP/1."*" 200 "* && "$h" == *$'\nX-Frame-Options: DENY\n'* ]]
    [[ "$h" == *$'\nContent-Security-Policy: default-src \'none\'; script-src \'unsafe-inline\'; '*"; frame-src 'self'"$'\n'* ]]
  done
  [[ "$(get "$URL/pages")" == *'sandbox: "allow-popups allow-popups-to-escape-sandbox"'* ]]
  [ "$(code "$URL/pages/task/$ID/Bad%20Slug")" = 404 ]
  [ "$(code "$URL/pages/other/$ID/weekly-report")" = 404 ]
  # /api/pages: every artifact, done ones too
  cr artifact done "$note" >/dev/null
  [ "$(get "$URL/api/pages" | jq -c '.artifacts | map([.ref, .kind, (.done != null)]) | sort')" = "[[\"$note\",\"note\",true],[\"$REF\",\"page\",false]]" ]
  # the board links to the list, and a page's chip to its viewer
  local page; page="$(get "$URL/")"
  [[ "$page" == *'href="/pages"'* && "$page" == *'if (a.kind === "page")'* ]]
  # no external requests from the viewer either
  [ -z "$(get "$URL/pages" | grep -Ei '(src|href)=["'"'"']?(https?:)?//|@import|url\(https?:' || true)" ]
}

@test "server: a page's PDF is printed on request by the CLI, as a download; failures say why" {
  need_python
  use_fake chrome
  export CHARTROOM_CHROME=chrome FAKE_CHROME_FAIL="$BATS_TEST_TMPDIR/fail-now"
  page_task
  local note; note="$(cr artifact add "$ID" --kind note --title "Plain" - <<<"plain")"
  start_daemon
  local h; h="$(curl -s -D - -o "$BATS_TEST_TMPDIR/dl.pdf" --max-time "$CURL_MAX" "$URL/task/$ID/artifacts/weekly-report.pdf" | tr -d '\r'; echo end)"
  [[ "$h" == "HTTP/1."*" 200 "* ]]
  [[ "$h" == *$'\nContent-Type: application/pdf\n'* && "$h" == *$'\nContent-Disposition: attachment; filename="weekly-report.pdf"\n'* ]]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/dl.pdf")" = "%PDF-1.4" ]
  grep -qF '<h2>Findings</h2>' "$BATS_TEST_TMPDIR/dl.pdf"
  grep -q '^chrome --headless=new ' "$FAKE_LOG"
  # the viewer's own fetch says same-origin, a typed URL none; another site's page (an <img> to
  # this URL, which needs no token on loopback) never starts a print
  [ "$(code -H 'Sec-Fetch-Site: same-origin' "$URL/task/$ID/artifacts/weekly-report.pdf")" = 200 ]
  [ "$(code -H 'Sec-Fetch-Site: none' "$URL/task/$ID/artifacts/weekly-report.pdf")" = 200 ]
  local n; n="$(grep -c '^chrome ' "$FAKE_LOG")"
  [ "$(code -H 'Sec-Fetch-Site: cross-site' "$URL/task/$ID/artifacts/weekly-report.pdf")" = 403 ]
  [ "$(code -H 'Sec-Fetch-Site: same-site' "$URL/task/$ID/artifacts/weekly-report.pdf")" = 403 ]
  [[ "$(get -H 'Sec-Fetch-Site: cross-site' "$URL/task/$ID/artifacts/weekly-report.pdf")" == "a PDF is printed only from this dashboard" ]]
  # not a page, or no page at all: 404; and none of these printed anything
  [ "$(code "$URL/task/$ID/artifacts/plain.pdf")" = 404 ]
  [ "$(code "$URL/task/$ID/artifacts/nope.pdf")" = 404 ]
  [ "$(grep -c '^chrome ' "$FAKE_LOG")" -eq "$n" ]
  # a print that fails: 500 with the CLI's reason
  touch "$FAKE_CHROME_FAIL"
  [ "$(code "$URL/task/$ID/artifacts/weekly-report.pdf")" = 500 ]
  [[ "$(get "$URL/task/$ID/artifacts/weekly-report.pdf")" == "could not print the PDF: Chrome printed no PDF"* ]]
}

@test "server: exposed, the pages, the viewer, a page and its PDF need the token like the rest" {
  need_python
  use_fake chrome
  export CHARTROOM_CHROME=chrome
  page_task
  start_daemon --expose
  local t p jar="$BATS_TEST_TMPDIR/jar"
  t="$(cat "$CHARTROOM_HOME/.dashboard.token")"
  for p in /pages "/pages/task/$ID/weekly-report" /api/pages "/task/$ID/artifacts/weekly-report.html" "/task/$ID/artifacts/weekly-report.pdf"; do
    [ "$(code "$URL$p")" = 401 ]
  done
  # the token once, then the cookie: the viewer keeps its path through the redirect
  local h; h="$(headers "$URL/pages/task/$ID/weekly-report?token=$t")"
  [[ "$h" == *$'\nLocation: /pages/task/'"$ID"$'/weekly-report\n'* ]]
  [ "$(code -L -c "$jar" -b "$jar" "$URL/pages?token=$t")" = 200 ]
  for p in /pages "/pages/task/$ID/weekly-report" /api/pages "/task/$ID/artifacts/weekly-report.html" "/task/$ID/artifacts/weekly-report.pdf"; do
    [ "$(code -b "$jar" "$URL$p")" = 200 ]
  done
}

@test "open: shows the artifact in the dashboard's viewer, starting the dashboard when it is not up" {
  need_python
  export CHARTROOM_OPENER="$BATS_TEST_TMPDIR/opener" CHARTROOM_DASHBOARD_PORT=0
  printf '#!/bin/sh\necho "$@" >>"%s"\n' "$BATS_TEST_TMPDIR/opened" >"$CHARTROOM_OPENER"; chmod +x "$CHARTROOM_OPENER"
  page_task
  run cr artifact open "$REF"
  [ "$status" -eq 0 ]
  read -r _ PORT _ <"$CHARTROOM_HOME/.dashboard.pid"
  [[ "$output" == *"dashboard open: http://127.0.0.1:$PORT/pages/task/$ID/weekly-report" ]]
  [ "$(tail -1 "$BATS_TEST_TMPDIR/opened")" = "http://127.0.0.1:$PORT/pages/task/$ID/weekly-report" ]
  [ "$(code "http://127.0.0.1:$PORT/pages/task/$ID/weekly-report")" = 200 ]
  # an inbox item's, through the same running dashboard
  local tag ref; tag="$(cr inbox add --project webapp "read this?")"
  ref="$(cr artifact add "$tag" --kind page --title "For you" - <<<"<p>hi</p>")"
  run cr artifact open "$ref"
  [ "$status" -eq 0 ]; [[ "$output" == *"/pages/inbox/$tag/for-you" ]]
  run cr artifact open
  [ "$status" -ne 0 ]; [[ "$output" == *"usage: chartroom artifact open <ref>"* ]]
}
