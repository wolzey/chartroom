#!/usr/bin/env bats
# The privacy gate against throwaway repos. Personal-looking strings are assembled at
# runtime so this file itself stays clean for the gate.

load test_helper
setup() {
  common_setup
  R="$BATS_TEST_TMPDIR/r"
  git init -q "$R"; mkdir -p "$R/scripts"
  cp "$REPO_ROOT/scripts/privacy-gate.sh" "$R/scripts/"
  OWNER="11860354+wolzey@users.noreply.github.com"
  git -C "$R" config user.name wolzey; git -C "$R" config user.email "$OWNER"
  echo ok >"$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm "feat: start"
  GATE="$R/scripts/privacy-gate.sh"
}

@test "a clean repo passes, including in-repo symlinks" {
  real_symlinks || skip "ln -s does not make symlinks here"
  mkdir -p "$R/sub"; ln -s ../a.txt "$R/sub/link"; ln -s a.txt "$R/top"
  git -C "$R" add -A; git -C "$R" commit -qm "feat: links"
  run "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 symlinks"* ]]
}

@test "an absolute symlink fails even when its target is a harmless path" {
  real_symlinks || skip "ln -s does not make symlinks here"
  ln -s /opt/tool/bin/jq "$R/jq"; git -C "$R" add jq; git -C "$R" commit -qm "chore: oops"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink jq points outside the repo (absolute): /opt/tool/bin/jq"* ]]
}

@test "a relative symlink that climbs out of the repo fails" {
  real_symlinks || skip "ln -s does not make symlinks here"
  mkdir -p "$R/sub"; ln -s ../../outside "$R/sub/esc"; git -C "$R" add -A; git -C "$R" commit -qm "chore: esc"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink sub/esc points outside the repo: ../../outside"* ]]
}

@test "a symlink target with a local temp path is reported as personal data" {
  real_symlinks || skip "ln -s does not make symlinks here"
  t="/priv""ate/tmp/cla""ude-501/x"
  ln -s "$t" "$R/b"; git -C "$R" add b; git -C "$R" commit -qm "chore: b"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink b target has personal data"* ]]
}

@test "personal data in commit author or message fails" {
  n="Eth""an"
  echo x >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" -c user.name="$n" commit -qm "fix: thing"
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

@test "an author email other than the owner's noreply fails, even one the pattern misses" {
  e="someone@order""protection.com"
  echo x >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" -c user.name=someone -c user.email="$e" commit -qm "fix: thing"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"personal data in commit metadata"* ]]
  [[ "$output" == *"commit identity other than $OWNER"* ]]
  [[ "$output" == *"author <$e>"* && "$output" == *"committer <$e>"* ]]
}

@test "a committer email alone fails, as a web rebase-merge stamps it" {
  e="someone@order""protection.com"
  echo x >>"$R/a.txt"; git -C "$R" add -A
  GIT_COMMITTER_NAME=someone GIT_COMMITTER_EMAIL="$e" git -C "$R" commit -qm "fix: merged on the web"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"committer <$e>"* ]]
  [[ "$output" != *"author <"* ]]
}

@test "a listed collaborator's noreply passes as author, committer and trailer; any other email still fails" {
  c="198639793+cbrannelly@users.noreply.github.com"
  echo x >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" -c user.name=cbrannelly -c user.email="$c" commit -qm "feat: by a collaborator" -m "Co-Authored-By: cbrannelly <$c>"
  git -C "$R" commit -q --allow-empty -m "feat: paired with one" -m "Co-Authored-By: cbrannelly <$c>"
  run "$GATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # the list is exact: the same name under another address, or another account's noreply, fails
  e="cbrannelly@order""protection.com"
  echo y >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" -c user.name=cbrannelly -c user.email="$e" commit -qm "fix: work email"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"commit identity other than $OWNER or a listed collaborator"* && "$output" == *"author <$e>"* ]]
  [[ "$output" != *"<$c>"* ]]
}

@test "a Co-Authored-By trailer passes for noreply@anthropic.com and fails for anyone else" {
  echo x >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" commit -qm "feat: pair" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
  run "$GATE"
  [ "$status" -eq 0 ]
  e="someone@order""protection.com"
  echo y >>"$R/a.txt"; git -C "$R" add -A
  git -C "$R" commit -qm "feat: pair again" -m "Co-Authored-By: Someone <$e>"
  run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"trailer email not in trailer_ok"* && "$output" == *"Co-Authored-By: Someone <$e>"* ]]
}
