#!/usr/bin/env bash
#
# run-all.sh — run every memory-sharing regression suite. Exit non-zero if any fails.
#
# All suites are HERMETIC: they drive link-claude-memory.sh / build-repo-map.sh
# entirely through CLAUDE_*_OVERRIDE sandboxes under /tmp and never read or write
# the real ~/.claude maps, the real iCloud store, or the real backups. As a
# belt-and-suspenders check, this runner snapshots the real maps before/after and
# fails loudly if anything changed.
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SUITES="lcm-test.sh lcm-test2.sh repokey-test.sh repokey-test2.sh multimac-test.sh onboard-test.sh samepath-test.sh backup-test.sh"

REAL_LOCAL="$HOME/.claude/.memory-repo-map"
REAL_SHARED="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory/repo-map.tsv"
REAL_BACKUPS="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeMemory-backups"
fp()    { [ -f "$1" ] && (md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | awk '{print $1}') || echo "ABSENT"; }
# fpdir: fingerprint a dir's entry LISTING (names+structure) — enough to catch any
# stray backup the backup-test suite might leak into the REAL backups dir.
fpdir() { [ -d "$1" ] && (cd "$1" && find . | sort | (md5 2>/dev/null || md5sum 2>/dev/null | awk '{print $1}')) || echo "ABSENT"; }
before_local="$(fp "$REAL_LOCAL")"; before_shared="$(fp "$REAL_SHARED")"
before_backups="$(fpdir "$REAL_BACKUPS")"

fails=""
for t in $SUITES; do
  [ -f "$DIR/$t" ] || { echo "  SKIP  $t (missing)"; continue; }
  printf '\n═══════════ %s ═══════════\n' "$t"
  if bash "$DIR/$t"; then :; else fails="$fails $t"; fi
done

# hermeticity check
after_local="$(fp "$REAL_LOCAL")"; after_shared="$(fp "$REAL_SHARED")"
after_backups="$(fpdir "$REAL_BACKUPS")"
echo ""
echo "═══════════ hermeticity ═══════════"
if [ "$before_local" = "$after_local" ] && [ "$before_shared" = "$after_shared" ] && [ "$before_backups" = "$after_backups" ]; then
  echo "  OK — real maps + backups dir untouched by the suite"
else
  echo "  FAIL — a suite mutated REAL state (local: $before_local->$after_local, shared: $before_shared->$after_shared, backups: $before_backups->$after_backups)"
  fails="$fails HERMETICITY"
fi

echo ""
if [ -z "$fails" ]; then echo "ALL SUITES GREEN"; exit 0; fi
echo "FAILED:$fails"; exit 1
