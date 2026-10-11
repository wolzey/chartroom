#!/usr/bin/env bats
# GUI launchers (Claude Desktop, IDEs) start the agent from a login, non-interactive shell:
# a thin PATH where `env bash` is the system bash 3.2 on macOS and Homebrew's dirs may be
# missing. chartroom re-runs itself under a newer bash and fills in the PATH.

load test_helper
setup() {
  common_setup
  # Just jq and git: no bash, so the only bash on the GUI PATH is the system one.
  TOOLS="$BATS_TEST_TMPDIR/tools"; mkdir -p "$TOOLS"
  NEWER="$BATS_TEST_TMPDIR/newer/bin"; mkdir -p "$NEWER"
  case "${OSTYPE:-}" in
    msys*|cygwin*) # (Git Bash: the test tools are wrapper scripts, not symlinks)
      cp "$BIN/jq" "$BIN/git" "$TOOLS/"; cp "$BIN/bash" "$NEWER/bash" ;;
    *)
      ln -sf "$(readlink "$BIN/jq")" "$TOOLS/jq"; ln -sf "$(readlink "$BIN/git")" "$TOOLS/git"
      # Where a package manager put a newer bash (stands in for /opt/homebrew/bin).
      ln -sf "$(readlink "$BIN/bash")" "$NEWER/bash" ;;
  esac
  EMPTY="$BATS_TEST_TMPDIR/empty"; mkdir -p "$EMPTY"
}

needs_bash3() {
  [[ -x /bin/bash ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]' || skip "/bin/bash is not bash 3"
}

# Run like a GUI-launched login shell: a cleared environment, a system-only PATH.
#   gui <PATH> <CHARTROOM_BASH_SEARCH> <cmd...>
gui() {
  local path="$1" search="$2"; shift 2
  env -i HOME="$HOME" PATH="$path" CHARTROOM_HOME="$CHARTROOM_HOME" CHARTROOM_CONFIG="$CHARTROOM_CONFIG" \
    XDG_STATE_HOME="$XDG_STATE_HOME" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" CHARTROOM_PATH_APPEND="" \
    CHARTROOM_BASH_SEARCH="$search" ${LOOP_LOG:+LOOP_LOG="$LOOP_LOG"} "$@"
}

@test "bash 3 re-runs itself under a newer bash from the install dirs" {
  needs_bash3
  run gui "$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" "$EMPTY:$NEWER" /bin/bash "$CHARTROOM" doctor --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.bash.version|split(".")[0]|tonumber >= 4' <<<"$output")" = true ]
  [ "$(jq -r .bash.path <<<"$output")" = "$NEWER/bash" ]
  [[ "$(jq -r .bash.rerun_from <<<"$output")" == "3."*" at /bin/bash" ]]
  run gui "$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" "$NEWER" /bin/bash "$CHARTROOM" doctor
  [[ "$output" == *"bash:     "*" at $NEWER/bash (re-run from 3."*"/bin/bash; the bash on PATH is older than 4)"* ]]
}

@test "a newer bash later on PATH than /bin is found too" {
  needs_bash3
  run gui "$TOOLS:/usr/bin:/bin:$NEWER" "$EMPTY" /bin/bash "$CHARTROOM" version
  [ "$status" -eq 0 ]
  [[ "$output" == "chartroom "* ]]
}

@test "no bash >= 4 anywhere: the error stays and says how to fix it" {
  needs_bash3
  run gui "$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" "$EMPTY" /bin/bash "$CHARTROOM" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 4 required (this is 3."*"at /bin/bash)"* ]]
  [[ "$output" == *"brew install bash"*"CHARTROOM_BASH_SEARCH"* ]]
}

@test "the re-run cannot loop: a candidate that is still bash 3 stops with the error" {
  needs_bash3
  # Claims >= 4 when probed, but runs the system bash 3. (rm first: it is a symlink to
  # the real bash, which a redirect would overwrite.)
  rm -f "$NEWER/bash"
  cat >"$NEWER/bash" <<'EOF'
#!/bin/sh
echo "$*" >>"$LOOP_LOG"
[ "$(wc -l <"$LOOP_LOG")" -gt 5 ] && exit 99
[ "$1" = -c ] && exit 0
exec /bin/bash "$@"
EOF
  chmod +x "$NEWER/bash"
  export LOOP_LOG="$BATS_TEST_TMPDIR/loop.log"
  run gui "$TOOLS:/usr/bin:/bin" "$NEWER" /bin/bash "$CHARTROOM" version
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 4 required"*"re-run from 3."* ]]
  [ "$(wc -l <"$LOOP_LOG")" -eq 2 ] # one probe, one re-run
}

@test "workers of a re-run chartroom do not inherit its loop guard" {
  needs_bash3
  id="$(new_task --backend command --command "env >{task_dir}/env.txt")"
  run gui "$TOOLS:/usr/bin:/bin" "$NEWER" /bin/bash "$CHARTROOM" dispatch "$id"
  [ "$status" -eq 0 ]
  wait_event "$id" 'exited: command ended'
  grep -q '^CHARTROOM_TASK=' "$CHARTROOM_HOME/tasks/$id/env.txt"
  ! grep -q '_CHARTROOM_REEXEC' "$CHARTROOM_HOME/tasks/$id/env.txt"
}

@test "PATH hygiene appends missing dirs after the user's own, and doctor flags the thin PATH" {
  extra="$BATS_TEST_TMPDIR/pkg/bin"; mkdir -p "$extra"
  run cr doctor --json
  [ "$(jq -r .path.thin <<<"$output")" = false ]
  run cr doctor
  [[ "$output" == *"path:     ok"* ]]
  # Present-but-missing is appended; absent and already-on-PATH dirs are left alone.
  CHARTROOM_PATH_APPEND="$extra:$BATS_TEST_TMPDIR/nope:$BIN" run cr doctor --json
  [ "$(jq -r .path.thin <<<"$output")" = true ]
  [ "$(jq -c .path.added <<<"$output")" = "[\"$extra\"]" ]
  CHARTROOM_PATH_APPEND="$extra" run cr doctor
  [[ "$output" == *"path:     thin: added $extra (missing from the launching shell's PATH"* ]]
}

@test "workers inherit the filled-in PATH, with the user's entries first" {
  extra="$BATS_TEST_TMPDIR/pkg/bin"; mkdir -p "$extra"
  id="$(new_task --backend command --command "printenv PATH >{task_dir}/path.txt")"
  CHARTROOM_PATH_APPEND="$extra" cr dispatch "$id" >/dev/null
  wait_event "$id" 'exited: command ended'
  [ "$(cat "$CHARTROOM_HOME/tasks/$id/path.txt")" = "$PATH:$extra" ]
}
