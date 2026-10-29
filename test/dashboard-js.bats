#!/usr/bin/env bats
# The dashboard's shared page scripts (lib/dashboard/*.js), unit-tested under node: the event
# formatter and the feed's threads (eventfmt.js), the report renderer (markdown.js) and the
# radar's stacks and archive (stacks.js). Each suite is a plain node script (test/js/); node is
# only a test dependency, so without it these skip.

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
