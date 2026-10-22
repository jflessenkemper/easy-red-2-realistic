#!/usr/bin/env bash
# Run the offline gates on EVERY feature/* and test/* branch without touching the working tree:
# each branch is checked out into a throwaway git worktree under /tmp, then removed.
# Per branch: check.sh (pass/fail counts + which fail), local budget, luacheck globals, and every
# tests/offline_*.lua harness on that branch.  Output: artifacts/review/branches.txt
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/env.sh
REPO=$PWD; OUT=$REPO/artifacts/review/branches.txt; mkdir -p "$(dirname "$OUT")"; : > "$OUT"
for b in $(git branch --format='%(refname:short)' | grep -E '^(feature|test)/'); do
  wt=$(mktemp -d /tmp/er2-wt.XXXX)
  git worktree add -q --detach "$wt" "$b" >/dev/null 2>&1 || { echo "$b: worktree failed" >> "$OUT"; continue; }
  (
    cd "$wt" || exit 1
    c=$(bash tests/check.sh 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    cp=$(echo "$c" | grep -c '^  PASS'); cf=$(echo "$c" | grep -c '^  FAIL')
    fails=$(echo "$c" | grep '^  FAIL' | cut -c9-70 | tr '\n' '|')
    lc=$(python3 "$REPO/tests/local_count.py" Realistic.lua RealisticEvents.lua | awk '{print $3}' | tr '\n' ' ')
    gl=$(luacheck --config "$REPO/.luacheckrc" --only 1 -- Realistic.lua RealisticEvents.lua 2>&1 | tail -1)
    h=""; for f in tests/offline_*.lua; do luajit "$f" >/dev/null 2>&1 && h="$h ${f#tests/offline_}:ok" || h="$h ${f#tests/offline_}:FAIL"; done
    printf '%s\n  check.sh %s/%s  fails: %s\n  locals %s\n  luacheck-globals: %s\n  harnesses:%s\n' "$b" "$cp" "$cf" "${fails:-none}" "$lc" "$gl" "$h"
  ) >> "$OUT" 2>&1
  git worktree remove --force "$wt" >/dev/null 2>&1
done
git worktree prune
cat "$OUT"
