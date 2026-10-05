#!/usr/bin/env bats
# The privacy gate against throwaway repos. Personal-looking strings are assembled at
# runtime so this file itself stays clean for the gate.

load test_helper
setup() {
  common_setup
  R="$BATS_TEST_TMPDIR/r"
  git init -q "$R"; mkdir -p "$R/scripts"
  cp "$REPO_ROOT/scripts/privacy-gate.sh" "$R/scripts/"
  echo ok >"$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm "feat: start"
  GATE="$R/scripts/privacy-gate.sh"
}

@test "a clean repo passes, including in-repo symlinks" {
  mkdir -p "$R/sub"; ln -s ../a.txt "$R/sub/link"; ln -s a.txt "$R/top"
  git -C "$R" add -A; git -C "$R" commit -qm "feat: links"
  run "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 symlinks"* ]]
}

@test "an absolute symlink fails even when its target is a harmless path" {
  ln -s /opt/tool/bin/jq "$R/jq"; git -C "$R" add jq; git -C "$R" commit -qm "chore: oops"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink jq points outside the repo (absolute): /opt/tool/bin/jq"* ]]
}

@test "a relative symlink that climbs out of the repo fails" {
  mkdir -p "$R/sub"; ln -s ../../outside "$R/sub/esc"; git -C "$R" add -A; git -C "$R" commit -qm "chore: esc"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink sub/esc points outside the repo: ../../outside"* ]]
}

@test "a symlink target with a local temp path is reported as personal data" {
  t="/priv""ate/tmp/cla""ude-501/x"
  ln -s "$t" "$R/b"; git -C "$R" add b; git -C "$R" commit -qm "chore: b"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink b target has personal data"* ]]
}

@test "personal data in commit author or message fails" {
  n="Eth""an"
  echo x >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" -c user.name="$n" -c user.email="me@example.invalid" commit -qm "fix: thing"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"personal data in commit metadata"* ]]
}

@test "personal data in a tracked file fails" {
  echo "see /Us""ers/someone/x" >"$R/notes.md"; git -C "$R" add -A; git -C "$R" commit -qm "docs: notes"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1"* ]]
}
