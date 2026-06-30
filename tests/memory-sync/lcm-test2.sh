#!/usr/bin/env bash
set -u
LCM="$HOME/.claude/link-claude-memory.sh"
# HERMETIC GUARD: never touch real maps/store. A set REPO_MAP also disables the
# linker's auto build-repo-map call (so no real scan / no real local-map write).
export CLAUDE_REPO_MAP_OVERRIDE="/tmp/lcm-test2.sbx-norepomap"
export CLAUDE_SHARED_MAP_OVERRIDE="/tmp/lcm-test2.sbx-shared"
export CLAUDE_SCAN_ROOTS_OVERRIDE="/tmp/lcm-test2.sbx-noscan"

echo "=== TEST A: --auto self-heals a conflict losslessly (SessionStart hook path) ==="
rm -rf /tmp/lcm-test2 && mkdir -p /tmp/lcm-test2
P=/tmp/lcm-test2/proj; S=/tmp/lcm-test2/store
mkdir -p "$P/-Users-test-p/memory" "$S/projects/-HOME-p/memory"
printf 'local-unique\n' > "$P/-Users-test-p/memory/onlylocal.md"
printf 'canon-unique\n' > "$S/projects/-HOME-p/memory/onlycanon.md"

echo "--- auto run output (stderr should announce the merge) ---"
CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" \
  bash "$LCM" --auto
M="$P/-Users-test-p/memory"; C="$S/projects/-HOME-p/memory"
a_ok=$([ -L "$M" ] && [ -f "$C/onlylocal.md" ] && [ -f "$C/onlycanon.md" ] && echo PASS || echo FAIL)
echo "  $a_ok  auto: symlinked + both unique files preserved in canonical"

echo ""
echo "=== TEST B: idempotency — second run is a no-op (already linked) ==="
out=$(CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" bash "$LCM" 2>&1)
echo "$out" | grep -q '1 linked' && b1=PASS || b1=FAIL   # already=1 reported as "1 linked"
echo "$out" | grep -q '0 merged' && b2=PASS || b2=FAIL
echo "  $b1  second run reports already-linked (no re-merge)"
echo "  $b2  second run does 0 merges (idempotent)"
echo "  full line: $(echo "$out" | grep 'link-claude-memory:')"

echo ""
[ "$a_ok" = PASS ] && [ "$b1" = PASS ] && [ "$b2" = PASS ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
