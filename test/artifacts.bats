#!/usr/bin/env bats
# Artifacts: drafts for the commander (a message to send, a runbook to run, a note) kept with
# a task or an inbox item; listed, shown, copied and marked done by ref. And how status, board
# and the dashboard's lanes JSON count them and attach them to cards.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
  unset CHARTROOM_CLIPBOARD DISPLAY WAYLAND_DISPLAY
  # never the real clipboard: a pbcopy first on PATH that keeps what it was given
  CLIP="$BATS_TEST_TMPDIR/clipboard"
  fake_clip pbcopy
  MSG="$BATS_TEST_TMPDIR/msg.md"
  printf 'Hi team,\n\nthe fix is in: `make test` passes.\n' >"$MSG"
}

fake_clip() { # <name>: a clipboard tool that keeps its input in $CLIP and logs its argv
  printf '#!/bin/sh\necho "%s $*" >>"%s"\ncat >"%s"\n' "$1" "$FAKE_LOG" "$CLIP" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

@test "add keeps the text verbatim with its title and kind; show, list and list --json" {
  local id sid ref
  id="$(TITLE="fix login" new_task)"; sid="${id: -4}"
  run cr artifact add "$id" --kind message --title "Reply to the review" "$MSG"
  [ "$status" -eq 0 ]
  ref="$sid/reply-to-the-review"
  [ "$output" = "$ref" ]
  local d="$CHARTROOM_HOME/tasks/$id/artifacts"
  cmp "$MSG" "$d/reply-to-the-review.md"
  [ "$(jq -c '[.schema, .title, .kind, .project, .done]' "$d/reply-to-the-review.json")" = '[1,"Reply to the review","message","proj",null]' ]
  events "$id" | grep -qE ' note: artifact reply-to-the-review \(message\) added: Reply to the review$'
  # show prints exactly the text; --path its file
  cr artifact show "$ref" >"$BATS_TEST_TMPDIR/shown"
  cmp "$MSG" "$BATS_TEST_TMPDIR/shown"
  [ "$(cr artifact show "$ref" --path)" = "$d/reply-to-the-review.md" ]
  # the full id, a bare owner with one open artifact, case and a .md suffix all name it
  [ "$(cr artifact show "$id/reply-to-the-review" --path)" = "$d/reply-to-the-review.md" ]
  [ "$(cr artifact show "$sid" --path)" = "$d/reply-to-the-review.md" ]
  [ "$(cr artifact show "$sid/Reply-To-The-Review.md" --path)" = "$d/reply-to-the-review.md" ]
  # from stdin, with an explicit slug
  run cr artifact add "$sid" --kind runbook --title "Deploy steps" --slug deploy - <<<"git push origin main"
  [ "$status" -eq 0 ]; [ "$output" = "$sid/deploy" ]
  [ "$(cr artifact show "$sid/deploy")" = "git push origin main" ]
  # two open now: a bare owner is ambiguous and says which refs there are
  run cr artifact show "$sid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$sid has 2 open artifacts: "* && "$output" == *"$sid/deploy"* && "$output" == *"$ref"* ]]
  run cr artifact list
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == REF*KIND*PROJECT*TITLE*UPDATED ]]
  [ "${#lines[@]}" -eq 3 ]
  [[ "$output" == *"$ref"*"message"*"proj"*"Reply to the review"* ]]
  run cr artifact list --json
  [ "$(jq -c 'map([.ref, .owner_type, .owner, .kind, .title]) | sort' <<<"$output")" = \
    "$(jq -nc --arg id "$id" --arg s "$sid" '[[$s + "/deploy", "task", $id, "runbook", "Deploy steps"], [$s + "/reply-to-the-review", "task", $id, "message", "Reply to the review"]]')" ]
  [ "$(cr artifact list "$sid" --json | jq length)" -eq 2 ]
}

@test "copy pipes the text into the clipboard tool, or prints it" {
  local id ref
  id="$(new_task)"
  ref="$(cr artifact add "$id" --kind message --title "Note" "$MSG")"
  run cr artifact copy "$ref"
  [ "$status" -eq 0 ]
  [ "$output" = "copied $ref to the clipboard (pbcopy): Note" ]
  cmp "$MSG" "$CLIP"
  # CHARTROOM_CLIPBOARD names the command, split on spaces
  fake_clip myclip; rm -f "$CLIP"
  CHARTROOM_CLIPBOARD="myclip --from chartroom" cr artifact copy "$ref" >/dev/null
  cmp "$MSG" "$CLIP"
  grep -qx 'myclip --from chartroom' "$FAKE_LOG"
  # "-" prints, and only the text
  CHARTROOM_CLIPBOARD=- cr artifact copy "$ref" >"$BATS_TEST_TMPDIR/printed"
  cmp "$MSG" "$BATS_TEST_TMPDIR/printed"
  # a tool that fails: say so, then print
  CHARTROOM_CLIPBOARD=false cr artifact copy "$ref" >"$BATS_TEST_TMPDIR/printed" 2>"$BATS_TEST_TMPDIR/err"
  cmp "$MSG" "$BATS_TEST_TMPDIR/printed"
  grep -q "false failed; printing $ref instead" "$BATS_TEST_TMPDIR/err"
}

@test "copy falls back to wl-copy, xclip, or printing when there is no pbcopy" {
  local id ref
  id="$(new_task)"
  ref="$(cr artifact add "$id" --kind message --title "Note" "$MSG")"
  rm -f "$BIN/pbcopy"
  if type -P pbcopy >/dev/null; then skip "this machine has a real pbcopy"; fi
  cr artifact copy "$ref" >"$BATS_TEST_TMPDIR/printed" 2>"$BATS_TEST_TMPDIR/err"
  cmp "$MSG" "$BATS_TEST_TMPDIR/printed"
  grep -q "no clipboard tool" "$BATS_TEST_TMPDIR/err"
  fake_clip xclip; fake_clip wl-copy
  [ "$(DISPLAY=:0 cr artifact copy "$ref")" = "copied $ref to the clipboard (xclip -selection clipboard): Note" ]
  grep -qx 'xclip -selection clipboard' "$FAKE_LOG"
  [ "$(WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 cr artifact copy "$ref")" = "copied $ref to the clipboard (wl-copy): Note" ]
  cmp "$MSG" "$CLIP"
}

@test "done stops it showing as open; adding it again overwrites the text and opens it again" {
  local id sid ref d
  id="$(new_task)"; sid="${id: -4}"; d="$CHARTROOM_HOME/tasks/$id/artifacts"
  ref="$(cr artifact add "$id" --kind runbook --title "Rotate the key" - <<<"echo one")"
  local created; created="$(jq -r .created "$d/rotate-the-key.json")"
  run cr artifact done "$ref"
  [ "$status" -eq 0 ]; [ "$output" = "done $ref: Rotate the key" ]
  [ "$(jq -r .done "$d/rotate-the-key.json")" != null ]
  events "$id" | grep -qE ' note: artifact rotate-the-key done: Rotate the key$'
  [ "$(cr artifact list)" = "no open artifacts" ]
  [ "$(cr artifact list "$sid")" = "no open artifacts on $sid" ]
  run cr artifact list --all
  [[ "${lines[0]}" == *DONE ]]
  [[ "${lines[1]}" == "$ref"*"$(date -u +%F)" ]]
  run cr artifact done "$ref"
  [ "$status" -eq 0 ]; [[ "$output" == "$ref was already done ("* ]]
  # a bare owner names only an open artifact
  run cr artifact show "$sid"
  [ "$status" -ne 0 ]; [[ "$output" == *"$sid has no open artifact"* ]]
  # done artifacts still show by full ref
  [ "$(cr artifact show "$ref")" = "echo one" ]
  # the same title again: new text, same created, open again, and a note that it replaced one
  sleep 1
  run cr artifact add "$id" --kind runbook --title "Rotate the key" - <<<"echo two"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced the text of $ref (was: Rotate the key)"* ]]
  [ "$(cr artifact show "$ref")" = "echo two" ]
  [ "$(jq -r .created "$d/rotate-the-key.json")" = "$created" ]
  [ "$(jq -r '.done, (.updated > .created)' "$d/rotate-the-key.json" | tr '\n' ' ')" = "null true " ]
  events "$id" | grep -qE ' note: artifact rotate-the-key \(runbook\) updated: Rotate the key$'
}

@test "inbox items: attach by tag; the artifact outlives the item's line" {
  local tag ref
  tag="$(cr inbox add --project webapp "send the release note?")"
  run cr artifact add "$tag" --kind message --title "Release note" "$MSG"
  [ "$status" -eq 0 ]; ref="$tag/release-note"; [ "$output" = "$ref" ]
  cmp "$MSG" "$CHARTROOM_HOME/inbox/$tag/artifacts/release-note.md"
  [ "$(jq -r .project "$CHARTROOM_HOME/inbox/$tag/artifacts/release-note.json")" = webapp ]
  [ "$(cr artifact list --json | jq -c '.[0] | [.ref, .owner_type, .owner, .project]')" = "[\"$ref\",\"inbox\",\"$tag\",\"webapp\"]" ]
  [ "$(cr artifact show "[$(tr '[:lower:]' '[:upper:]' <<<"$tag")]")" = "$(cat "$MSG")" ]
  # answered: the line goes, the draft stays until it is done
  sed -i.bak "/\[$tag\]/d" "$CHARTROOM_HOME/inbox.md"
  [ "$(cr artifact show "$ref")" = "$(cat "$MSG")" ]
  [[ "$(cr artifact list)" == *"$ref"* ]]
  run cr artifact done "$tag"
  [ "$status" -eq 0 ]; [ "$output" = "done $ref: Release note" ]
  # but a new artifact needs an open item
  run cr artifact add "$tag" --kind note --title "x" "$MSG"
  [ "$status" -ne 0 ]; [[ "$output" == *"unknown id '$tag'"* ]]
}

@test "bad input is refused and nothing is written" {
  local id; id="$(new_task)"
  run cr artifact add "$id" --title "t" "$MSG"
  [ "$status" -ne 0 ]; [[ "$output" == *usage* ]]
  run cr artifact add "$id" --kind email --title "t" "$MSG"
  [ "$status" -ne 0 ]; [[ "$output" == *"--kind must be message"* ]]
  run cr artifact add "$id" --kind note --title "$(printf 'two\nlines')" "$MSG"
  [ "$status" -ne 0 ]; [[ "$output" == *"one line"* ]]
  run cr artifact add "$id" --kind note --title "t" --slug "Bad/Slug" "$MSG"
  [ "$status" -ne 0 ]; [[ "$output" == *"--slug must be"* ]]
  run cr artifact add "$id" --kind note --title "t" "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -ne 0 ]; [[ "$output" == *"no such file"* ]]
  run cr artifact add "$id" --kind note --title "t" - </dev/null
  [ "$status" -ne 0 ]; [[ "$output" == *"the text is empty"* ]]
  run cr artifact add nope-0000 --kind note --title "t" "$MSG"
  [ "$status" -ne 0 ]; [[ "$output" == *"unknown id 'nope-0000'"* ]]
  run cr artifact add "$id" --kind note --title "t" "$MSG" extra
  [ "$status" -ne 0 ]; [[ "$output" == *usage* ]]
  [ -z "$(ls -A "$CHARTROOM_HOME/tasks/$id/artifacts" 2>/dev/null)" ]
  run cr artifact show "$id/nope"
  [ "$status" -ne 0 ]; [[ "$output" == *"no artifact 'nope' on $id"* ]]
  run cr artifact copy
  [ "$status" -ne 0 ]; [[ "$output" == *usage* ]]
  run cr artifact frob
  [ "$status" -ne 0 ]; [[ "$output" == *usage* ]]
}

@test "status and board count open artifacts; the lanes JSON attaches them to task and inbox cards" {
  local id sid tag a b c board
  id="$(new_task)"; sid="${id: -4}"
  tag="$(cr inbox add --project webapp "send the release note?")"
  other="$(cr inbox add "no draft here")"
  [ -z "$(cr status | grep '^artifacts:' || true)" ]
  a="$(cr artifact add "$id" --kind message --title "Reply" "$MSG")"
  b="$(cr artifact add "$id" --kind runbook --title "Deploy" - <<<"make deploy")"
  c="$(cr artifact add "$tag" --kind message --title "Release note" "$MSG")"
  [ "$(cr status | tail -1)" = "artifacts: 3 open (2 messages, 1 runbook): chartroom artifact list" ]
  board="$(cr dashboard --json)"
  [ "$(jq -c .artifacts <<<"$board")" = '{"open":3,"message":2,"runbook":1,"note":0,"page":0}' ]
  [ "$(jq -c --arg id "$id" '.lanes[][] | select(.id == $id) | .artifacts | map([.ref, .kind, .title, .owner_type, .owner, .slug]) | sort' <<<"$board")" = \
    "$(jq -nc --arg id "$id" --arg a "$a" --arg b "$b" '[[$b, "runbook", "Deploy", "task", $id, "deploy"], [$a, "message", "Reply", "task", $id, "reply"]]')" ]
  [ "$(jq -c --arg t "$tag" '.lanes.needs_you[] | select(.short_id == $t) | .artifacts | map([.ref, .owner_type, .owner])' <<<"$board")" = "[[\"$c\",\"inbox\",\"$tag\"]]" ]
  [ "$(jq -c --arg t "$other" '.lanes.needs_you[] | select(.short_id == $t) | .artifacts' <<<"$board")" = '[]' ]
  # board: the refs on the card's line, and the count at the end
  run cr board --no-color
  grep -qE "^  $sid +\[proj\] stub task  \[drafting the brief\]  \[artifacts ($a, $b|$b, $a)\]" <<<"$output"
  grep -qE "^  $tag +\[webapp\] send the release note\?  \[waiting on you \(inbox\)\]  \[artifact $c\]  since " <<<"$output"
  [ "${lines[${#lines[@]}-1]}" = "artifacts: 3 open (2 messages, 1 runbook): chartroom artifact list" ]
  # done ones leave the cards and the count
  cr artifact done "$a" >/dev/null; cr artifact done "$c" >/dev/null
  board="$(cr dashboard --json)"
  [ "$(jq -c .artifacts <<<"$board")" = '{"open":1,"message":0,"runbook":1,"note":0,"page":0}' ]
  [ "$(jq -c --arg id "$id" '.lanes[][] | select(.id == $id) | .artifacts | map(.ref)' <<<"$board")" = "[\"$b\"]" ]
  [ "$(cr status | tail -1)" = "artifacts: 1 open (1 runbook): chartroom artifact list" ]
  cr artifact done "$b" >/dev/null
  [ -z "$(cr board --no-color | grep '^artifacts:' || true)" ]
}

@test "a worker's own files in a task's artifacts/ are never listed, counted or overwritten" {
  local id sid d; id="$(new_task)"; sid="${id: -4}"; d="$CHARTROOM_HOME/tasks/$id/artifacts"
  # what a worker may keep there itself: JSON of any shape, broken JSON, a .md/.json pair
  mkdir -p "$d"
  echo '[{"case": 1}, {"case": 2}]' >"$d/inputs.json"
  echo '{"not json' >"$d/broken.json"
  echo 'per-case notes' >"$d/per-case.txt"
  echo '# worker summary' >"$d/summary.md"; echo '{"cases": 2}' >"$d/summary.json"
  echo '# no sidecar' >"$d/report.md"
  run cr status
  [ "$status" -eq 0 ]; [[ "$output" != *"artifacts:"* ]]
  run cr dashboard --json
  [ "$status" -eq 0 ]
  [ "$(jq -c --arg id "$id" '[.artifacts.open, (.lanes[][] | select(.id == $id) | .artifacts)]' <<<"$output")" = '[0,[]]' ]
  [ "$(cr artifact list)" = "no open artifacts" ]
  [ "$(cr artifact list --all --json)" = "[]" ]
  # an artifact beside them is listed alone
  [ "$(cr artifact add "$id" --kind note --title "Ours" - <<<"ours")" = "$sid/ours" ]
  [ "$(cr artifact list --json | jq -c 'map(.ref)')" = "[\"$sid/ours\"]" ]
  [ "$(cr board --no-color | tail -1)" = "artifacts: 1 open (1 note): chartroom artifact list" ]
  # a slug that names a worker's file is refused, and the file is untouched
  for s in summary report inputs; do
    run cr artifact add "$id" --kind note --title "$s" - <<<"would clobber"
    [ "$status" -ne 0 ]; [[ "$output" == *"is not a chartroom artifact"* ]]
  done
  [ "$(cat "$d/summary.md")" = "# worker summary" ]; [ "$(cat "$d/summary.json")" = '{"cases": 2}' ]
  [ "$(cat "$d/report.md")" = "# no sidecar" ]; [ ! -e "$d/report.json" ]
  [ "$(cat "$d/inputs.json")" = '[{"case": 1}, {"case": 2}]' ]; [ ! -e "$d/inputs.md" ]
  run cr artifact show "$id/summary"
  [ "$status" -ne 0 ]; [[ "$output" == *"no artifact 'summary'"* ]]
}
