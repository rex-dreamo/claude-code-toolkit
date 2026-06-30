#!/usr/bin/env bash
# Adversarial: brand-new Mac onboarding (local REAL dirs), NOSHARE-by-bucket,
# dry-run safety, missing/empty maps, mapped bucket with no memory dir.
set -u
LCM="$HOME/.claude/link-claude-memory.sh"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

ROOT=/tmp/onb; rm -rf "$ROOT"
S="$ROOT/store"; SP="$S/projects"; PB="$ROOT/macB/projects"
HB="-Users-userb"
mkdir -p "$SP" "$PB"

echo "============ TEST 1: brand-new Mac, LOCAL REAL dir folds into existing -REPO- ============"
# Mac A already folded R into -REPO-x-R (store has it). Mac B has never linked:
# its clone is a REAL local dir with its own memory + index, NOT a symlink.
mkdir -p "$SP/-REPO-x-R/memory"
printf 'AA\n' > "$SP/-REPO-x-R/memory/a.md"
printf '# Memory Index\n- [A](a.md) — mac A\n' > "$SP/-REPO-x-R/memory/MEMORY.md"
mkdir -p "$PB/${HB}-Development-GitHubProjects-R-01/memory"
printf 'BB\n' > "$PB/${HB}-Development-GitHubProjects-R-01/memory/b.md"
printf '# Memory Index\n- [B](b.md) — mac B\n' > "$PB/${HB}-Development-GitHubProjects-R-01/memory/MEMORY.md"
printf -- '-HOME-Development-GitHubProjects-R-01|-REPO-x-R\n' > "$ROOT/mapB"
cp "$ROOT/mapB" "$ROOT/shared"
: > "$ROOT/noshare"
runB(){ CLAUDE_PROJECTS_OVERRIDE="$PB" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="$HB" \
  CLAUDE_REPO_MAP_OVERRIDE="$ROOT/mapB" CLAUDE_SHARED_MAP_OVERRIDE="$ROOT/shared" CLAUDE_NOSHARE_OVERRIDE="$ROOT/noshare" bash "$LCM" "$@"; }
runB 2>&1 | sed 's/^/   /'
RM="$SP/-REPO-x-R/memory"
chk "onboarding: a.md (existing) preserved"            '[ -f "$RM/a.md" ]'
chk "onboarding: b.md (local) merged into -REPO-"      '[ -f "$RM/b.md" ]'
chk "onboarding: local clone now a symlink -> -REPO-"  '[ -L "$PB/${HB}-Development-GitHubProjects-R-01/memory" ] && [ "$(readlink "$PB/${HB}-Development-GitHubProjects-R-01/memory")" = "$RM" ]'
chk "onboarding: premerge backup of local dir kept"    'ls -d "$PB/${HB}-Development-GitHubProjects-R-01/memory.premerge-backup-"* >/dev/null 2>&1'
chk "onboarding: index reconciled in ONE run (both)"   'grep -q "(a.md)" "$RM/MEMORY.md" && grep -q "(b.md)" "$RM/MEMORY.md"'
chk "onboarding: no leftover index conflicts"          '! ls "$RM"/MEMORY.md.conflict-* >/dev/null 2>&1'

echo ""
echo "============ TEST 2: NOSHARE by exact BUCKET keeps that one clone path-keyed ============"
R2=/tmp/onb2; rm -rf "$R2"; S2="$R2/store"; SP2="$S2/projects"; P2="$R2/proj"
mkdir -p "$SP2/-HOME-Development-GitHubProjects-Q-1/memory" "$SP2/-HOME-Development-GitHubProjects-Q-2/memory"
printf 'q1\n' > "$SP2/-HOME-Development-GitHubProjects-Q-1/memory/q1.md"
printf 'q2\n' > "$SP2/-HOME-Development-GitHubProjects-Q-2/memory/q2.md"
mkdir -p "$P2/-Users-x-Development-GitHubProjects-Q-1" "$P2/-Users-x-Development-GitHubProjects-Q-2"
ln -s "$SP2/-HOME-Development-GitHubProjects-Q-1/memory" "$P2/-Users-x-Development-GitHubProjects-Q-1/memory"
ln -s "$SP2/-HOME-Development-GitHubProjects-Q-2/memory" "$P2/-Users-x-Development-GitHubProjects-Q-2/memory"
printf -- '-HOME-Development-GitHubProjects-Q-1|-REPO-x-Q\n-HOME-Development-GitHubProjects-Q-2|-REPO-x-Q\n' > "$R2/map"
cp "$R2/map" "$R2/shared"
printf -- '-HOME-Development-GitHubProjects-Q-1\n' > "$R2/noshare"   # exclude ONLY Q-1, by bucket
CLAUDE_PROJECTS_OVERRIDE="$P2" CLAUDE_STORE_OVERRIDE="$S2" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R2/map" CLAUDE_SHARED_MAP_OVERRIDE="$R2/shared" CLAUDE_NOSHARE_OVERRIDE="$R2/noshare" bash "$LCM" >/dev/null 2>&1
chk "NOSHARE bucket Q-1 NOT folded (stays -HOME)"      '[ ! -e "$SP2/-HOME-Development-GitHubProjects-Q-1/.superseded-by--REPO-x-Q" ]'
chk "NOSHARE Q-1 local clone keeps -HOME path key"    '[ "$(readlink "$P2/-Users-x-Development-GitHubProjects-Q-1/memory")" = "$SP2/-HOME-Development-GitHubProjects-Q-1/memory" ]'
chk "Q-2 (not excluded) still folds to -REPO-"        '[ -f "$SP2/-REPO-x-Q/memory/q2.md" ] && [ -e "$SP2/-HOME-Development-GitHubProjects-Q-2/.superseded-by--REPO-x-Q" ]'

echo ""
echo "============ TEST 3: --dry-run changes NOTHING on a foldable store ============"
R3=/tmp/onb3; rm -rf "$R3"; S3="$R3/store"; SP3="$S3/projects"; P3="$R3/proj"
mkdir -p "$SP3/-HOME-Development-GitHubProjects-W-1/memory" "$SP3/-HOME-Development-GitHubProjects-W-2/memory"
printf 'w1\n' > "$SP3/-HOME-Development-GitHubProjects-W-1/memory/w.md"
printf 'w2\n' > "$SP3/-HOME-Development-GitHubProjects-W-2/memory/w.md"   # same name diff content
printf -- '-HOME-Development-GitHubProjects-W-1|-REPO-x-W\n-HOME-Development-GitHubProjects-W-2|-REPO-x-W\n' > "$R3/shared"
: > "$R3/map"; : > "$R3/noshare"
before=$(find "$SP3" -type f | sort | md5 2>/dev/null || find "$SP3" -type f | sort | md5sum)
CLAUDE_PROJECTS_OVERRIDE="$P3" CLAUDE_STORE_OVERRIDE="$S3" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R3/map" CLAUDE_SHARED_MAP_OVERRIDE="$R3/shared" CLAUDE_NOSHARE_OVERRIDE="$R3/noshare" bash "$LCM" --dry-run >/dev/null 2>&1
after=$(find "$SP3" -type f | sort | md5 2>/dev/null || find "$SP3" -type f | sort | md5sum)
chk "dry-run: store file set unchanged"               '[ "$before" = "$after" ]'
chk "dry-run: no -REPO- bucket created"               '[ ! -d "$SP3/-REPO-x-W" ]'
chk "dry-run: no superseded markers written"          '[ ! -e "$SP3/-HOME-Development-GitHubProjects-W-1/.superseded-by--REPO-x-W" ]'

echo ""
echo "============ TEST 4: missing shared map + mapped bucket with no memory dir ============"
R4=/tmp/onb4; rm -rf "$R4"; S4="$R4/store"; SP4="$S4/projects"; P4="$R4/proj"
mkdir -p "$SP4" "$P4"
# 4a: no shared map at all -> consolidate is a clean no-op
: > "$R4/map"
rm -f "$R4/shared"   # ensure absent
CLAUDE_PROJECTS_OVERRIDE="$P4" CLAUDE_STORE_OVERRIDE="$S4" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R4/map" CLAUDE_SHARED_MAP_OVERRIDE="$R4/shared" CLAUDE_NOSHARE_OVERRIDE="$R4/nos" bash "$LCM" >/dev/null 2>&1
chk "missing shared map: linker exits 0, no crash"    '[ "$?" = 0 ]'
# 4b: shared map references a bucket that has NO memory dir -> skipped, no empty -REPO-
mkdir -p "$SP4/-HOME-Development-GitHubProjects-Z-1"   # bucket dir but NO memory subdir
printf -- '-HOME-Development-GitHubProjects-Z-1|-REPO-x-Z\n' > "$R4/shared"
CLAUDE_PROJECTS_OVERRIDE="$P4" CLAUDE_STORE_OVERRIDE="$S4" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R4/map" CLAUDE_SHARED_MAP_OVERRIDE="$R4/shared" CLAUDE_NOSHARE_OVERRIDE="$R4/nos" bash "$LCM" >/dev/null 2>&1
chk "bucket w/o memory dir: not folded, no -REPO- made" '[ ! -d "$SP4/-REPO-x-Z" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
