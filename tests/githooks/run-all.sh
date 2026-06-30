#!/usr/bin/env bash
#
# run-all.sh — run every git-hook regression suite. Exit non-zero if any fails.
#
# Hermetic: each suite builds a throwaway git repo in a temp dir and drives the
# real githooks/pre-commit against staged content. No real repo state is touched.
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SUITES="scan-test.sh scan-tree-test.sh"

fails=""
for t in $SUITES; do
  [ -f "$DIR/$t" ] || { echo "  SKIP  $t (missing)"; continue; }
  printf '\n═══════════ %s ═══════════\n' "$t"
  if bash "$DIR/$t"; then :; else fails="$fails $t"; fi
done

echo ""
if [ -z "$fails" ]; then echo "ALL SUITES GREEN"; exit 0; fi
echo "FAILED:$fails"; exit 1
