#!/usr/bin/env bats
# Cleaning up after ourselves (lib/core.sh task_branch_judge, `chartroom close`, `chartroom sweep`):
# a task's branch is deleted once its work has landed (merged into its base, on origin at that
# very commit, or a merged PR at it), and kept otherwise. chartroom never deletes unlanded work.

load test_helper

setup() {
  common_setup
  cr init >/dev/null
  export CHARTROOM_SWEEP_SETTLE_MINUTES=0
  # a real origin: a bare repo with main, so the base is origin/main
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare "$ORIGIN"
  git -C "$PROJECT" branch -M main
  git -C "$PROJECT" remote add origin "$ORIGIN"
  git -C "$PROJECT" push -q origin main
  git -C "$PROJECT" remote set-head origin main
}

# A ship task with a worktree and <n> commits on its branch; prints the id.
task_with_commits() { # <n>
  local id wt i
  id="$(new_task)"
  wt="$(cr worktree "$id" 2>/dev/null)"
  for ((i = 1; i <= $1; i++)); do
    echo "change $i" >"$wt/$id-$i.txt"; git -C "$wt" add "$id-$i.txt"; git -C "$wt" commit -qm "feat: change $i"
  done
  printf '%s' "$id"
}
branch_of() { meta_of "$1" branch; }
has_branch() { git -C "$PROJECT" rev-parse --verify -q "refs/heads/$1" >/dev/null; }

@test "close: an unlanded branch is kept, and says why" {
  id="$(task_with_commits 2)"; b="$(branch_of "$id")"
  run cr close "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch $b kept (2 commit(s) ahead of base, not landed: not in origin/main, not on origin; gh is not here to ask about a squash merge)"* ]]
  has_branch "$b"
}

@test "close: a branch merged into its base is deleted, and the record says so" {
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"
  git -C "$PROJECT" merge -q --ff-only "$b"; git -C "$PROJECT" push -q origin main
  run cr close "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch $b deleted (landed: merged into origin/main; it was at "* ]]
  ! has_branch "$b"
  grep -q "note: branch $b deleted (landed: merged into origin/main" "$CHARTROOM_HOME/tasks/$id/events.log"
  # a branch with no commits of its own has nothing to lose
  id2="$(task_with_commits 0)"; b2="$(branch_of "$id2")"
  run cr close "$id2"
  [[ "$output" == *"branch $b2 deleted (landed: no commits of its own;"* ]]
}

@test "close: a branch on origin at the very same commit is deleted; a stale tracking ref is not trusted" {
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"
  git -C "$PROJECT" push -q origin "$b"
  run cr close "$id"
  [[ "$output" == *"branch $b deleted (landed: on origin as $b;"* ]]
  ! has_branch "$b"
  # pushed, then a commit more: origin no longer has the tip, so it is kept
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"
  git -C "$PROJECT" push -q origin "$b"
  wt="$(meta_of "$id" worktree)"; echo more >"$wt/more.txt"; git -C "$wt" add more.txt; git -C "$wt" commit -qm "feat: more"
  run cr close "$id"
  [[ "$output" == *"branch $b kept (2 commit(s) ahead of base, not landed:"* ]]
  has_branch "$b"
  # pushed, then deleted on origin (a PR closed unmerged): the local origin/<branch> left behind
  # by the last fetch is stale, and is not taken as proof
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"
  git -C "$PROJECT" push -q origin "$b"; git -C "$ORIGIN" branch -q -D "$b"
  git -C "$PROJECT" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null
  run cr close "$id"
  [[ "$output" == *"branch $b kept (1 commit(s) ahead of base, not landed:"* ]]
  has_branch "$b"
}

@test "close: a squash-merged PR at that commit counts as landed, only when GitHub says so" {
  use_fake gh
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"; sha="$(git -C "$PROJECT" rev-parse "$b")"
  # merged, but at another commit (the branch moved on after): kept
  printf '[{"number": 41, "headRefName": "%s", "headRefOid": "%s"}]' "$b" 0123456789abcdef0123456789abcdef01234567 >"$BATS_TEST_TMPDIR/merged.json"
  export FAKE_GH_MERGED="$BATS_TEST_TMPDIR/merged.json"
  run cr close "$id"
  [[ "$output" == *"branch $b kept (1 commit(s) ahead of base, not landed: not in origin/main, not on origin, no merged PR at that commit)"* ]]
  has_branch "$b"
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"; sha="$(git -C "$PROJECT" rev-parse "$b")"
  printf '[{"number": 42, "headRefName": "%s", "headRefOid": "%s"}]' "$b" "$sha" >"$FAKE_GH_MERGED"
  run cr close "$id"
  [[ "$output" == *"branch $b deleted (landed: PR #42 merged;"* ]]
  ! has_branch "$b"
}

@test "close: a landed branch checked out in another worktree is kept; a dirty worktree still refuses" {
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"
  git -C "$PROJECT" merge -q --ff-only "$b"; git -C "$PROJECT" push -q origin main
  wt="$(meta_of "$id" worktree)"; echo wip >"$wt/wip.txt"
  run cr close "$id"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to close $id: uncommitted work"* ]]
  has_branch "$b"
  rm "$wt/wip.txt"
  # someone checked the branch out elsewhere after the task's worktree went
  git -C "$PROJECT" worktree remove "$wt"; meta_set_raw() { jq --arg v "$2" '.worktree = $v' "$CHARTROOM_HOME/tasks/$1/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$1/meta.json"; }
  meta_set_raw "$id" ""
  git -C "$PROJECT" worktree add -q "$BATS_TEST_TMPDIR/elsewhere" "$b"
  run cr close "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch $b kept (landed: merged into origin/main; but it is checked out at "*"elsewhere)"* ]]
  has_branch "$b"
}

@test "sweep: a closed task's branch that landed after it closed is deleted on --apply; unlanded ones are left" {
  late="$(task_with_commits 1)"; bl="$(branch_of "$late")"
  open_one="$(task_with_commits 1)"; bo="$(branch_of "$open_one")"
  cr close "$late" >/dev/null
  has_branch "$bl"
  git -C "$PROJECT" branch -q someone-elses "$bl"   # a branch no record names
  run cr sweep
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"landed branch"* ]]
  # its PR merges a day later
  git -C "$PROJECT" merge -q --ff-only "$bl"; git -C "$PROJECT" push -q origin main
  run cr sweep
  [[ "${lines[0]}" == *"1 landed branch(es) of closed tasks to delete"* ]]
  run cr sweep --verbose
  [[ "$output" == *"Branches of closed tasks (deleted only once landed)"* ]]
  [[ "$output" == *"delete"*"$late"*"$bl"*"landed: merged into origin/main"* ]]
  run cr sweep --json
  [ "$(jq -c '[.leftovers[] | [.task, .action]]' <<<"$output")" = "[[\"$late\",\"apply\"]]" ]
  run cr sweep --apply
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"1 landed branch(es) of closed tasks deleted"* ]]
  ! has_branch "$bl"
  grep -q "note: sweep: branch $bl deleted (landed: merged into origin/main" "$CHARTROOM_HOME/tasks/$late/events.log"
  grep -q "deleted: $late branch $bl deleted" "$CHARTROOM_HOME/sweep.log"
  # an open task's branch and a branch no record names are never sweep's to judge
  has_branch "$bo"; has_branch someone-elses
}

@test "close and sweep read a store task through the seams: the same rule with the switch on" {
  printf 'CHARTROOM_STORE=sqlite\n' >>"$CHARTROOM_HOME/config"
  kept="$(task_with_commits 1)"; bk="$(branch_of "$kept")"
  run cr close "$kept"
  [[ "$output" == *"branch $bk kept (1 commit(s) ahead of base, not landed:"* ]]
  git -C "$PROJECT" merge -q --ff-only "$bk"; git -C "$PROJECT" push -q origin main
  run cr sweep --json
  [ "$(jq -c '[.leftovers[] | [.task, .action]]' <<<"$output")" = "[[\"$kept\",\"apply\"]]" ]
  run cr sweep --apply
  ! has_branch "$bk"
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"
  git -C "$PROJECT" merge -q --ff-only "$b"; git -C "$PROJECT" push -q origin main
  run cr close "$id"
  [[ "$output" == *"branch $b deleted (landed: merged into origin/main;"* ]]
}

@test "sweep: a closed task's leftover worktree goes first when clean; with changes in it, nothing is touched" {
  id="$(task_with_commits 1)"; b="$(branch_of "$id")"; wt="$(meta_of "$id" worktree)"
  git -C "$PROJECT" merge -q --ff-only "$b"; git -C "$PROJECT" push -q origin main
  # closed by hand with its worktree left behind (an older chartroom, a crash mid-close)
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.closed = $t' "$CHARTROOM_HOME/tasks/$id/meta.json" >"$BATS_TEST_TMPDIR/m" && mv "$BATS_TEST_TMPDIR/m" "$CHARTROOM_HOME/tasks/$id/meta.json"
  echo wip >"$wt/wip.txt"
  run cr sweep --json
  [ "$(jq -r '.leftovers[0] | "\(.action) \(.reason)"' <<<"$output")" = "keep its worktree $wt is still here, with uncommitted changes" ]
  run cr sweep --apply
  [ -d "$wt" ]; has_branch "$b"
  rm "$wt/wip.txt"
  run cr sweep --apply
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
  ! has_branch "$b"
  grep -q "note: sweep: removed its leftover worktree $wt (clean)" "$CHARTROOM_HOME/tasks/$id/events.log"
}
