#!/usr/bin/env bats
# install-skills and install.sh, against a throwaway HOME.

load test_helper
setup() { common_setup; }

@test "install-skills links into each agent dir, idempotently" {
  run cr install-skills --claude --agents --pi
  [ "$status" -eq 0 ]
  for d in .claude/skills .agents/skills .pi/agent/skills; do
    for s in chartroom bearings dashboard continue captain join; do
      [ -L "$HOME/$d/$s" ]
      [ -f "$HOME/$d/$s/SKILL.md" ]
    done
  done
  run cr install-skills --claude
  [[ "$output" == *"ok   $HOME/.claude/skills/chartroom"* ]]
}

@test "install-skills never replaces a real directory or a foreign symlink" {
  mkdir -p "$HOME/.claude/skills/chartroom" "$HOME/.agents/skills"
  ln -s /tmp "$HOME/.agents/skills/bearings"
  run cr install-skills --claude --agents
  [[ "$output" == *"skip $HOME/.claude/skills/chartroom (exists and is not a symlink"* ]]
  [[ "$output" == *"skip $HOME/.agents/skills/bearings (a symlink to"* ]]
  [ ! -L "$HOME/.claude/skills/chartroom" ]
}

@test "install-skills detects agent dirs, supports --dry-run and --uninstall" {
  run cr install-skills
  [ "$status" -ne 0 ]
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  run cr install-skills --dry-run
  [[ "$output" == *"would link $HOME/.claude/skills/chartroom"* ]]
  [[ "$output" == *"would link $HOME/.agents/skills/bearings"* ]]
  [ ! -e "$HOME/.claude/skills/chartroom" ]
  cr install-skills >/dev/null
  run cr install-skills --uninstall
  [[ "$output" == *"removed $HOME/.claude/skills/chartroom"* ]]
  [ ! -e "$HOME/.agents/skills/chartroom" ]
}

@test "install.sh: clone, link, init; rerun is an update" {
  src="$BATS_TEST_TMPDIR/src"
  git clone -q --no-local "$REPO_ROOT" "$src"
  git -C "$src" checkout -q -B main
  export CHARTROOM_REPO="$src" CHARTROOM_REF=main
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/chartroom" ]
  [[ "$output" == *"installed chartroom"* ]]
  [ -f "$CHARTROOM_HOME/commander.md" ]
  run "$HOME/.local/bin/chartroom" version
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updating"* ]]
}

@test "install.sh refuses to overwrite a non-checkout" {
  mkdir -p "$HOME/.local/share/chartroom"; echo x >"$HOME/.local/share/chartroom/file"
  CHARTROOM_REPO="$REPO_ROOT" run bash "$REPO_ROOT/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a chartroom checkout"* ]]
}

@test "skills reference files that exist, and use the XO persona" {
  for f in $(grep -oE 'references/[a-z-]+\.md' "$REPO_ROOT/skills/chartroom/SKILL.md" | sort -u); do
    [ -f "$REPO_ROOT/skills/chartroom/$f" ]
  done
  ! grep -rniE 'first mate|firstmate' "$REPO_ROOT/skills" "$REPO_ROOT/README.md"
}

@test "the captain skill is a legacy alias that defers to the chartroom skill" {
  f="$REPO_ROOT/skills/captain/SKILL.md"
  grep -q '^name: captain$' "$f"
  grep -q 'Load the `chartroom` skill and follow it exactly' "$f"
  [ -f "$REPO_ROOT/skills/captain/../chartroom/SKILL.md" ]
  run cr install-skills --dir "$HOME/skills"
  [[ "$output" == *"link $HOME/skills/captain -> $REPO_ROOT/skills/captain"* ]]
  run cr install-skills --dir "$HOME/skills" --uninstall
  [[ "$output" == *"removed $HOME/skills/captain"* ]]
  [ ! -e "$HOME/skills/captain" ]
}

@test "privacy gate passes on the tracked tree" {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  run "$REPO_ROOT/scripts/privacy-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "privacy gate: clean"* ]]
}
