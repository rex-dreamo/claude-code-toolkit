#!/usr/bin/env bash
#
# run-all.sh — run every review-hook regression suite. Exit non-zero if any fails.
#
# Hermetic: suites drive the hook scripts purely over stdin; the gate suite
# sandboxes its cache dir via CLAUDE_PR_GATE_CACHE_DIR (a symlinked dir, which
# doubles as the regression net for the macOS /tmp-symlink find bug). Nothing
# here reads or writes real /tmp pr-feedback state.
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SUITES="prompt-check-test.sh post-gate-test.sh"

fails=""
for t in $SUITES; do
  [ -f "$DIR/$t" ] || { echo "  SKIP  $t (missing)"; continue; }
  printf '\n═══════════ %s ═══════════\n' "$t"
  if bash "$DIR/$t"; then :; else fails="$fails $t"; fi
done

echo ""
if [ -z "$fails" ]; then echo "ALL SUITES GREEN"; exit 0; fi
echo "FAILED:$fails"; exit 1
