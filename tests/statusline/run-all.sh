#!/usr/bin/env bash
#
# run-all.sh — run every statusline regression suite. Non-zero exit if any fail.
#
# Hermetic: suites drive statusline-command.sh purely over stdin with payloads
# shaped like the documented statusLine schema. The only real-world dependency
# is `git -C ~/.claude` (to prove the branch renders without a `git:` prefix),
# which reads nothing and is guarded for the no-branch case.
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SUITES="render-test.sh"

fails=""
for t in $SUITES; do
  [ -f "$DIR/$t" ] || { echo "  SKIP  $t (missing)"; continue; }
  printf '\n═══════════ %s ═══════════\n' "$t"
  if bash "$DIR/$t"; then :; else fails="$fails $t"; fi
done

echo ""
if [ -z "$fails" ]; then echo "ALL SUITES GREEN"; exit 0; fi
echo "FAILED:$fails"; exit 1
