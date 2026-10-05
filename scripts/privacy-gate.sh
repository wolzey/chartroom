#!/usr/bin/env bash
# No-personal-data gate: fails if any tracked file mentions the author's private
# machine, employers, or personal tooling. The only allowed hit is the public
# repo URL (wolzey/chartroom). This file is excluded because it holds the pattern.
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='ethan|wolz[^e]|/Users/|fluid|guardhouse|zenshift|azure.*create-pr|core:|migration:|gh-axi|launchdarkly|work/github\.com|\.captain/tasks'
hits="$(git ls-files -z | grep -zv '^scripts/privacy-gate\.sh$' | xargs -0 grep -nEiI "$pattern" -- 2>/dev/null || true)"
# wolzey/chartroom is the public URL; "wolze" is not matched by wolz[^e] already.
if [[ -n "$hits" ]]; then
  printf 'privacy gate: FAIL\n%s\n' "$hits"; exit 1
fi
echo "privacy gate: clean ($(git ls-files | wc -l | tr -d ' ') tracked files checked)"
