#!/usr/bin/env bash
# chartroom installer:  curl -fsSL https://raw.githubusercontent.com/wolzey/chartroom/main/install.sh | bash
#
# Clones (or fast-forwards) chartroom into $CHARTROOM_INSTALL_DIR (default
# ~/.local/share/chartroom), links bin/chartroom into $CHARTROOM_BIN_DIR (default
# ~/.local/bin), checks dependencies and runs `chartroom init`. Idempotent. It does not touch
# your agents' skill directories; it prints the `chartroom install-skills` command instead.
#   CHARTROOM_REPO     git URL or local path to install from (default: the GitHub repo)
#   CHARTROOM_REF      branch or tag (default: main)
set -euo pipefail

REPO="${CHARTROOM_REPO:-https://github.com/wolzey/chartroom.git}"
REF="${CHARTROOM_REF:-main}"
DIR="${CHARTROOM_INSTALL_DIR:-$HOME/.local/share/chartroom}"
BIN_DIR="${CHARTROOM_BIN_DIR:-$HOME/.local/bin}"

say() { printf 'chartroom-install: %s\n' "$*"; }
fail() { printf 'chartroom-install: %s\n' "$*" >&2; exit 1; }

# A GUI launcher's login shell may lack Homebrew's bin dirs on macOS: append them as
# bin/chartroom does (same CHARTROOM_PATH_APPEND override), so the checks below see what
# chartroom itself will see.
pdef=""; [[ "${OSTYPE:-}" == darwin* ]] && pdef="/opt/homebrew/bin:/usr/local/bin"
IFS=: read -r -a pdirs <<<"${CHARTROOM_PATH_APPEND-$pdef}"
for d in ${pdirs[@]+"${pdirs[@]}"}; do
  [[ -n "$d" && -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"
done
# bash >= 4 on PATH or in the usual install dirs (this script may be running under macOS's
# bash 3.2; bin/chartroom finds and re-runs itself under the newer one).
has_bash4() {
  local IFS=: d
  for d in $PATH /opt/homebrew/bin /usr/local/bin /run/current-system/sw/bin \
    "$HOME/.nix-profile/bin" /nix/var/nix/profiles/default/bin /opt/local/bin; do
    # shellcheck disable=SC2016
    [[ -n "$d" && -f "$d/bash" && -x "$d/bash" ]] && "$d/bash" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null && return 0
  done
  return 1
}
has_bash4 || fail "bash >= 4 is required (found $(bash --version | head -1)). On macOS: brew install bash"
command -v git >/dev/null || fail "git is required"
command -v jq >/dev/null || fail "jq is required (macOS: brew install jq; Debian/Ubuntu: apt install jq)"

if [[ -d "$DIR/.git" ]]; then
  say "updating $DIR"
  git -C "$DIR" fetch --quiet origin "$REF"
  git -C "$DIR" merge --quiet --ff-only FETCH_HEAD || fail "$DIR has local changes or diverged; update it by hand"
elif [[ -e "$DIR" ]]; then
  fail "$DIR exists and is not a chartroom checkout; set CHARTROOM_INSTALL_DIR or move it"
else
  say "cloning into $DIR"
  mkdir -p "$(dirname "$DIR")"
  git clone --quiet --branch "$REF" "$REPO" "$DIR"
fi

mkdir -p "$BIN_DIR"
link="$BIN_DIR/chartroom"
# Where symlinks are unavailable (Git Bash's `ln -s` copies, and a copy cannot find lib/),
# the link is a launcher script carrying this marker instead; a re-run rewrites it.
marker="# chartroom launcher, written by install.sh"
if [[ -L "$link" || ! -e "$link" ]] || grep -qxF "$marker" "$link" 2>/dev/null; then
  ln -sfn "$DIR/bin/chartroom" "$link" 2>/dev/null || true
  if [[ -L "$link" ]]; then say "linked $link"
  else
    rm -f "$link"
    printf '#!/usr/bin/env bash\n%s\nexec %q "$@"\n' "$marker" "$DIR/bin/chartroom" >"$link"
    chmod +x "$link"
    say "wrote launcher $link (symlinks are unavailable here)"
  fi
else fail "$link exists and is not a symlink; not replacing it"; fi

"$DIR/bin/chartroom" init
case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
  say "add $BIN_DIR to your PATH"
  case "${OSTYPE:-}" in msys*|cygwin*) say "  Git Bash: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc" ;; esac ;;
esac
say "installed $("$DIR/bin/chartroom" version)"
cat <<MSG

Next:
  chartroom doctor                     # what can run on this machine
  chartroom install-skills             # link the skills into your agents (--claude, --agents, --pi, --all)
  cd ~/.chartroom && claude            # or codex, gemini, ...: that session is your XO
MSG
