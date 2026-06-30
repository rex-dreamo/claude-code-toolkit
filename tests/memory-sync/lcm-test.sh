#!/usr/bin/env bash
# Sandboxed test for link-claude-memory.sh union-on-conflict fix.
set -u
LCM="$HOME/.claude/link-claude-memory.sh"
# HERMETIC GUARD: never touch real maps/store. A set REPO_MAP also disables the
# linker's auto build-repo-map call (so no real scan / no real local-map write).
export CLAUDE_REPO_MAP_OVERRIDE="/tmp/lcm-test.sbx-norepomap"
export CLAUDE_SHARED_MAP_OVERRIDE="/tmp/lcm-test.sbx-shared"
export CLAUDE_SCAN_ROOTS_OVERRIDE="/tmp/lcm-test.sbx-noscan"

echo "=== syntax check ==="
bash -n "$LCM" && echo "OK: valid bash"
echo ""

echo "=== sandboxed union-on-conflict test ==="
rm -rf /tmp/lcm-test && mkdir -p /tmp/lcm-test
P=/tmp/lcm-test/proj
S=/tmp/lcm-test/store

# local project dir (real dir, never linked): local-only + a differing shared file
mkdir -p "$P/-Users-test-myproj/memory"
printf 'A-local\n'               > "$P/-Users-test-myproj/memory/a.md"
printf 'LOCAL ONLY\n'            > "$P/-Users-test-myproj/memory/localonly.md"
printf 'SHARED-local-version\n'  > "$P/-Users-test-myproj/memory/shared.md"

# canonical store dir: canon-only + a differing shared file
mkdir -p "$S/projects/-HOME-myproj/memory"
printf 'B-canon\n'               > "$S/projects/-HOME-myproj/memory/b.md"
printf 'CANON ONLY\n'            > "$S/projects/-HOME-myproj/memory/canononly.md"
printf 'SHARED-canon-version\n'  > "$S/projects/-HOME-myproj/memory/shared.md"

CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" \
  bash "$LCM"

echo ""
echo "=== ASSERTIONS ==="
M="$P/-Users-test-myproj/memory"
C="$S/projects/-HOME-myproj/memory"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

chk "local memory is now a symlink -> canonical"      '[ -L "$M" ] && [ "$(readlink "$M")" = "$C" ]'
chk "local-only file survived into canonical"          '[ -f "$C/localonly.md" ]'
chk "canon-only file still present"                     '[ -f "$C/canononly.md" ]'
chk "local a.md merged into canonical"                 '[ -f "$C/a.md" ]'
chk "canon b.md still present"                          '[ -f "$C/b.md" ]'
chk "canon shared.md kept (canon version intact)"      'grep -q SHARED-canon-version "$C/shared.md"'
chk "clashing local shared.md kept BOTH (.conflict)"   'ls "$C"/shared.md.conflict-* >/dev/null 2>&1 && grep -q SHARED-local-version "$C"/shared.md.conflict-*'
chk "pre-merge backup exists (mid-union safety)"       'ls -d "$M".premerge-backup-* >/dev/null 2>&1'
chk "local a.md reachable through the symlink"          '[ -f "$M/a.md" ]'
chk "local localonly.md reachable through the symlink"  '[ -f "$M/localonly.md" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
