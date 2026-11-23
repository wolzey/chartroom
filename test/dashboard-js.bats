#!/usr/bin/env bats
# The dashboard's shared page scripts (lib/dashboard/*.js), unit-tested under node: the event
# formatter and the feed's threads (eventfmt.js), the report renderer (markdown.js) and the
# radar's stacks and archive (stacks.js); and the Herdr app Tasks panel's XO lookup and refresh
# schedule (mods/herdr-chartroom/xo.js, schedule.js). Each suite is a plain node script
# (test/js/); node is only a test dependency, so without it these skip.

load test_helper

setup() {
  # the real binary, before common_setup narrows PATH and HOME (a version manager's shim needs both)
  NODE="$(node -p process.execPath 2>/dev/null || true)"
  common_setup
}

js() { # <suite>
  [[ -n "$NODE" ]] || skip "node not available"
  run "$NODE" "$REPO_ROOT/test/js/$1.test.js"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "eventfmt: the parser, inline tokens, threads and runs, and the render" { js eventfmt; }
@test "markdown: report.md blocks, tables, nested lists, sanitized render" { js markdown; }
@test "stacks: related tasks stack deterministically; the archive cutoffs" { js stacks; }
@test "herdr-xo: the Tasks panel finds a home's XO and what to type into it" { js herdr-xo; }
@test "herdr-schedule: the Tasks panel reads the radar only while shown, after a change" { js herdr-schedule; }
@test "app-model: the app's Needs me across homes, a card's questions, Enter, an answer's body" { js app-model; }
@test "app-outbox: actions are instant, sent in the background, retried, failed and kept across a reload" { js app-outbox; }
@test "app-contrast: every text colour of the app is at least 4.5:1, light and dark" { js app-contrast; }
@test "app-push: the Web Push sender (RFC 8291 vector, VAPID, a send a browser can decrypt)" { js app-push; }
@test "app-read: a slow read is shown though the version moves while it is under way" { js app-read; }
@test "app-sw: a notification's tap lands on the item, the app closed, open, or on another page" { js app-sw; }
