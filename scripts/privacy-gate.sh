#!/usr/bin/env bash
# No-personal-data gate. Fails if anything that would be published mentions the author's
# private machine, employers, or personal tooling:
#   1. tracked file contents (this file is excluded because it holds the pattern)
#   2. committed symlinks: their targets are scanned, and any target that is absolute or
#      climbs out of the repo fails outright (a link into a local temp dir leaks paths)
#   3. commit metadata reachable from HEAD: author/committer names and emails, messages
# The only allowed mention is the public owner handle (wolzey/chartroom).
# Usage: scripts/privacy-gate.sh [repo-dir]   (default: this checkout)
set -euo pipefail
cd "${1:-$(dirname "$0")/..}"
pattern='ethan|wolz[^e]|/Users/|/home/[a-z]|fluid|guardhouse|zenshift|azure.*create-pr|core:|migration:|gh-axi|launchdarkly|work/github\.com|\.captain/tasks|/private/tmp/|claude-501'
fail=0
report() { printf 'privacy gate: %s\n' "$1"; fail=1; }

# 1. file contents
hits="$(git ls-files -z | grep -zv '^scripts/privacy-gate\.sh$' | xargs -0 grep -nEiI "$pattern" -- 2>/dev/null || true)"
[[ -z "$hits" ]] || report "personal data in tracked files:"$'\n'"$hits"

# 2. symlinks (mode 120000): the blob is the link target
while read -r mode sha _ path; do
  [[ "$mode" == 120000 ]] || continue
  target="$(git cat-file blob "$sha")"
  grep -qEi "$pattern" <<<"$target" && report "symlink $path target has personal data: $target"
  if [[ "$target" == /* ]]; then report "symlink $path points outside the repo (absolute): $target"; continue; fi
  depth="$(awk -F/ '{print NF-1}' <<<"$path")"; ups=0; d=0
  IFS=/ read -ra parts <<<"$target"
  for p in "${parts[@]}"; do
    case "$p" in ..) d=$((d - 1)) ;; .|"") ;; *) d=$((d + 1)) ;; esac
    (( d < ups )) && ups=$d
  done
  (( depth + ups < 0 )) && report "symlink $path points outside the repo: $target"
done < <(git ls-files -s)

# 3. commit metadata
if git rev-parse --verify --quiet HEAD >/dev/null; then
  meta="$(git log --format='%h %an <%ae> | %cn <%ce>%n%B' HEAD | grep -nEi "$pattern" || true)"
  [[ -z "$meta" ]] || report "personal data in commit metadata:"$'\n'"$meta"
fi

if [[ $fail -ne 0 ]]; then echo "privacy gate: FAIL"; exit 1; fi
echo "privacy gate: clean ($(git ls-files | wc -l | tr -d ' ') tracked files, $(git ls-files -s | awk '$1==120000' | wc -l | tr -d ' ') symlinks, $(git rev-list --count HEAD 2>/dev/null || echo 0) commits checked)"
