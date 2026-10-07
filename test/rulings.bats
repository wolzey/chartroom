#!/usr/bin/env bats
# The rulings ledger: append-only rulings.log, latest wins per topic, a generated block in
# the preferences file, and a one-time import of hand-written preferences.

load test_helper
setup() { common_setup; cr init >/dev/null; }

prefs() { cat "$CHARTROOM_HOME/commander.md"; }
hand() { sed '/^<!-- chartroom:rulings/,/^<!-- \/chartroom:rulings -->/d' "$CHARTROOM_HOME/commander.md"; }
block() { sed -n '/^<!-- chartroom:rulings/,/^<!-- \/chartroom:rulings -->/p' "$CHARTROOM_HOME/commander.md"; }

@test "a fresh home has an empty generated block" {
  block | grep -qx -- '- (none yet)'
  run cr rule list
  [ "$status" -eq 0 ]
  [ "$output" = "no rulings" ]
}

@test "add appends a line, prints its id and renders it" {
  run cr rule add --topic deploys "never deploy on Fridays"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^r-[0-9a-f]{4}$ ]]
  local id="$output"
  grep -qE "^[0-9T:Z-]+ \[$id\] topic=deploys supersedes=- src=chat :: never deploy on Fridays$" "$CHARTROOM_HOME/rulings.log"
  block | grep -qF -- "- never deploy on Fridays (deploys; $id, "
  [ -z "$(block | grep '(none yet)' || true)" ]
}

@test "latest wins within a topic and the chain is recorded" {
  a="$(cr rule add --topic merge-bar "bot approval; never merge")"
  b="$(cr rule add --topic merge-bar "green CI plus one human approval")"
  c="$(cr rule add --topic merge-bar "bot approval again")"
  grep -q "\[$b\] topic=merge-bar supersedes=$a " "$CHARTROOM_HOME/rulings.log"
  grep -q "\[$c\] topic=merge-bar supersedes=$b " "$CHARTROOM_HOME/rulings.log"
  run cr rule list
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "$c "*"merge-bar :: bot approval again" ]]
  [ "$(block | grep -c '^- ')" -eq 1 ]
  run cr rule list --all
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "  $a "* ]]
  [[ "${lines[1]}" == "  $b "*"(supersedes $a)"* ]]
  [[ "${lines[2]}" == "* $c "*"(supersedes $b)"* ]]
}

@test "explicit --supersedes retires a ruling in another topic; - starts fresh" {
  a="$(cr rule add --topic old-name "use the old wording")"
  cr rule add --topic new-name --supersedes "$a" "use the new wording" >/dev/null
  run cr rule list --json
  [ "$(jq length <<<"$output")" -eq 1 ]
  [ "$(jq -r '.[0].topic' <<<"$output")" = new-name ]
  cr rule add --topic t2 "first" >/dev/null
  run cr rule add --topic t2 --supersedes - "second, unlinked"
  grep -q "topic=t2 supersedes=- src=chat :: second, unlinked" "$CHARTROOM_HOME/rulings.log"
}

@test "retire ends a topic without deleting anything" {
  a="$(cr rule add --topic quota "ignore quota")"
  run cr rule retire "$a" "no longer true"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CHARTROOM_HOME/rulings.log")" -eq 2 ]
  grep -q "supersedes=$a src=chat :: (retired) no longer true" "$CHARTROOM_HOME/rulings.log"
  [ "$(cr rule list)" = "no rulings" ]
  run cr rule retire r-ffff
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such ruling: r-ffff"* ]]
}

@test "bad input is refused and nothing is written" {
  run cr rule add --topic "Not A Slug" "x"
  [ "$status" -ne 0 ]; [[ "$output" == *"lowercase slug"* ]]
  run cr rule add --topic ok
  [ "$status" -ne 0 ]; [[ "$output" == *"usage"* ]]
  run cr rule add --topic ok --supersedes r-0000 "x"
  [ "$status" -ne 0 ]; [[ "$output" == *"no such ruling"* ]]
  run cr rule add --topic ok "$(printf 'two\nlines')"
  [ "$status" -ne 0 ]
  [ ! -s "$CHARTROOM_HOME/rulings.log" ]
}

@test "a malformed ledger line fails loudly with its line number" {
  cr rule add --topic a "fine" >/dev/null
  echo "garbage" >>"$CHARTROOM_HOME/rulings.log"
  run cr rule list
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2 is malformed"* ]]
}

@test "render is idempotent and keeps hand-written text around the block" {
  cr rule add --topic a "rule a" >/dev/null
  echo "Trailing hand note." >>"$CHARTROOM_HOME/commander.md"
  cp "$CHARTROOM_HOME/commander.md" "$BATS_TEST_TMPDIR/once"
  cr rule render >/dev/null
  cr rule render >/dev/null
  cmp "$CHARTROOM_HOME/commander.md" "$BATS_TEST_TMPDIR/once"
  prefs | grep -qx 'Trailing hand note.'
  prefs | grep -q '^- Delivery default:'
  [ "$(grep -c '^<!-- chartroom:rulings' "$CHARTROOM_HOME/commander.md")" -eq 1 ]
}

@test "a preferences file without a block gets one appended" {
  printf '# Prefs\n\n- hand rule\n' >"$CHARTROOM_HOME/commander.md"
  cr rule add --topic a "rule a" >/dev/null
  prefs | grep -qx -- '- hand rule'
  prefs | grep -qx '## Rulings'
  block | grep -q -- '- rule a (a; '
}

@test "a legacy captain.md is the preferences file when there is no commander.md" {
  rm "$CHARTROOM_HOME/commander.md"
  printf '# Captain preferences\n\n- old rule\n' >"$CHARTROOM_HOME/captain.md"
  cr rule add --topic a "rule a" >/dev/null
  [ ! -e "$CHARTROOM_HOME/commander.md" ]
  grep -q -- '- rule a (a; ' "$CHARTROOM_HOME/captain.md"
  run cr init
  [ ! -e "$CHARTROOM_HOME/commander.md" ]
}

@test "draft turns hand bullets into an editable map with dates pulled out" {
  cat >"$CHARTROOM_HOME/commander.md" <<'EOF'
# Commander preferences

- Delivery default: commit on a branch.
- Ask with the question tool. (2026-01-05)
- 2026-01-06: Bot reviews are off; CI plus one human approval.
- 2026-01-06 (later): Bot reviews are back on.
EOF
  run cr rule draft
  [ "$status" -eq 0 ]
  rows="$(grep -v '^#' <<<"$output")"
  [ "$(wc -l <<<"$rows")" -eq 4 ]
  [ "$(sed -n 1p <<<"$rows" | cut -f2,3)" = "auto	-" ]
  [ "$(sed -n 2p <<<"$rows" | cut -f3,4)" = "2026-01-05	Ask with the question tool." ]
  [ "$(sed -n 3p <<<"$rows" | cut -f3,4)" = "2026-01-06	Bot reviews are off; CI plus one human approval." ]
  [ "$(sed -n 4p <<<"$rows" | cut -f3,4)" = "2026-01-06	Bot reviews are back on." ]
  [ "$(sed -n 4p <<<"$rows" | cut -f5)" = "2026-01-06 (later): Bot reviews are back on." ]
}

@test "import: dry run writes nothing; --apply backs up, chains, removes bullets, renders" {
  cat >"$CHARTROOM_HOME/commander.md" <<'EOF'
# Commander preferences

- Delivery default: commit on a branch.

- 2026-01-05: Bot approval loop on web PRs; never merge.
- 2026-01-06: Bot reviews are off; CI plus one human approval.
- An idea we liked, not adopted.
- 2026-01-06 (later): Bot reviews are back on.
EOF
  cr rule draft >"$BATS_TEST_TMPDIR/map"
  # The XO's edit: topics, a keep row, and a self-contained final text.
  awk -F'\t' -v OFS='\t' '/^#/ { print; next }
    { n++ }
    n == 1 { $1 = "delivery" } n == 2 || n == 3 { $1 = "web-merge-bar" }
    n == 4 { $1 = "keep" } n == 5 { $1 = "web-merge-bar"; $4 = "Bot reviews are back on: bot approval loop on web PRs; never merge." }
    { print }' "$BATS_TEST_TMPDIR/map" >"$BATS_TEST_TMPDIR/map2"
  cp "$CHARTROOM_HOME/commander.md" "$BATS_TEST_TMPDIR/orig"
  run cr rule import "$BATS_TEST_TMPDIR/map2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run"* ]]
  cmp "$CHARTROOM_HOME/commander.md" "$BATS_TEST_TMPDIR/orig"
  [ ! -e "$CHARTROOM_HOME/rulings.log" ]

  run cr rule import "$BATS_TEST_TMPDIR/map2" --apply
  [ "$status" -eq 0 ]
  bak="$(ls "$CHARTROOM_HOME"/records/commander-before-rulings-*.md)"
  cmp "$bak" "$BATS_TEST_TMPDIR/orig"
  [ "$(wc -l <"$CHARTROOM_HOME/rulings.log")" -eq 4 ]
  grep -q '^2026-01-05T00:00:00Z \[r-[0-9a-f]*\] topic=web-merge-bar supersedes=- src=import :: Bot approval loop' "$CHARTROOM_HOME/rulings.log"
  run cr rule list
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"web-merge-bar :: Bot reviews are back on: bot approval loop on web PRs; never merge."* ]]
  [[ "$output" == *"delivery :: Delivery default: commit on a branch."* ]]
  # Imported bullets left the hand-written text; the keep row stayed.
  prefs | grep -qx -- '- An idea we liked, not adopted.'
  [ -z "$(hand | grep -- '^- 2026-01-0' || true)" ]
  [ -z "$(hand | grep -- '^- Delivery default' || true)" ]
  block | grep -q -- '- Bot reviews are back on: bot approval loop'
  [ -z "$(awk 'prev ~ /^$/ && /^$/ { print NR } { prev = $0 }' "$CHARTROOM_HOME/commander.md")" ]
}

@test "import refuses a map that does not match the file" {
  printf -- '- a rule\n' >"$CHARTROOM_HOME/commander.md"
  printf 'x\tauto\t-\ttext\tnot in the file\n' >"$BATS_TEST_TMPDIR/map"
  run cr rule import "$BATS_TEST_TMPDIR/map" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"bullet not found"* ]]
  printf 'x\t#2\t-\ttext\ta rule\n' >"$BATS_TEST_TMPDIR/map"
  run cr rule import "$BATS_TEST_TMPDIR/map" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"earlier row"* ]]
  printf 'keep\tauto\t-\ta rule\ta rule\nx\t#1\t-\ttext\ta rule\n' >"$BATS_TEST_TMPDIR/map"
  run cr rule import "$BATS_TEST_TMPDIR/map" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"keep row"* ]]
  printf 'x\tauto\t-\t\ta rule\n' >"$BATS_TEST_TMPDIR/map"
  run cr rule import "$BATS_TEST_TMPDIR/map" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"5 non-empty"* ]]
  [ ! -e "$CHARTROOM_HOME/rulings.log" ]
  [ ! -d "$CHARTROOM_HOME/records" ]
}

@test "import resolves #N to an earlier row's ruling" {
  printf -- '- first\n- second\n' >"$CHARTROOM_HOME/commander.md"
  printf 'one\tauto\t-\tfirst\tfirst\ntwo\t#1\t-\tsecond\tsecond\n' >"$BATS_TEST_TMPDIR/map"
  cr rule import "$BATS_TEST_TMPDIR/map" --apply >/dev/null
  first="$(sed -n 's/^.*\[\(r-[0-9a-f]*\)\] topic=one .*/\1/p' "$CHARTROOM_HOME/rulings.log")"
  grep -q "topic=two supersedes=$first " "$CHARTROOM_HOME/rulings.log"
  [ "$(cr rule list --json | jq -r '.[].topic')" = two ]
}
