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

# bash >= 4 somewhere on PATH (the script itself may be running under macOS's bash 3.2).
nb="$(command -v bash)"
"$nb" -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]' 2>/dev/null ||
  fail "bash >= 4 is required on PATH ($("$nb" --version | head -1)). On macOS: brew install bash"
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
