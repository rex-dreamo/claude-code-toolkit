#!/usr/bin/env bash
# backup-test.sh — weekly rotating store backup (link-claude-memory.sh weekly_backup).
#
# Verifies: (a) a backup is taken when due and contains the store contents + maps;
# (b) the .last marker gates a same-run re-invocation to a no-op (not due again);
# (c) when the marker is stale (>interval) a fresh backup is taken;
# (d) rotation keeps exactly BACKUP_KEEP newest snapshots;
# (e) --dry-run takes no backup;
# (f) backups land OUTSIDE the store (no recursive re-sync).
#
# Hermetic: everything via CLAUDE_*_OVERRIDE under /tmp; never touches real iCloud.
set -u
LCM="$HOME/.claude/link-claude-memory.sh"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

ROOT=/tmp/bk; rm -rf "$ROOT"
S="$ROOT/store"; SP="$S/projects"; P="$ROOT/proj"; BK="$ROOT/backups"
mkdir -p "$SP/-REPO-x-A/memory" "$P"
printf 'mem A\n' > "$SP/-REPO-x-A/memory/a.md"
printf '# Memory Index\n- [A](a.md)\n' > "$SP/-REPO-x-A/memory/MEMORY.md"
printf -- '-HOME-x|-REPO-x-A\n' > "$S/repo-map.tsv"
printf 'log line\n' > "$S/consolidation.log"
: > "$ROOT/map"; : > "$ROOT/shared"; : > "$ROOT/nos"

# env-prefix so per-call "$@" assignments (expanded post-parse) still take effect.
run(){ env CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$ROOT/map" CLAUDE_SHARED_MAP_OVERRIDE="$ROOT/shared" CLAUDE_NOSHARE_OVERRIDE="$ROOT/nos" \
  CLAUDE_BACKUP_DIR_OVERRIDE="$BK" "$@" bash "$LCM" >/dev/null 2>&1; }

echo "============ TEST 1: first run takes a backup ============"
run CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=4
nbk(){ ls -d "$BK"/store-* 2>/dev/null | wc -l | tr -d ' '; }
chk "backup dir created"                       '[ -d "$BK" ]'
chk "exactly one snapshot taken"               '[ "$(nbk)" = 1 ]'
chk "marker .last written (epoch)"             '[ -s "$BK/.last" ] && grep -qE "^[0-9]+$" "$BK/.last"'
D1="$(ls -d "$BK"/store-* 2>/dev/null | head -1)"
chk "snapshot has the store memory file"       '[ -f "$D1/-REPO-x-A/memory/a.md" ]'
chk "snapshot has repo-map.tsv"                '[ -f "$D1/repo-map.tsv" ]'
chk "snapshot has consolidation.log"           '[ -f "$D1/consolidation.log" ]'
chk "backups live OUTSIDE the store"           'case "$BK" in "$S"/*) false;; *) true;; esac'

echo ""
echo "============ TEST 2: not due again -> no second backup ============"
run CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=4
chk "marker gates: still exactly one snapshot" '[ "$(nbk)" = 1 ]'

echo ""
echo "============ TEST 3: stale marker -> a new backup is taken ============"
# Force the marker far into the past so the interval has elapsed.
printf '0\n' > "$BK/.last"
sleep 1   # ensure a distinct ts-second so the new dir name differs
run CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=4
chk "stale marker -> second snapshot exists"   '[ "$(nbk)" = 2 ]'
chk "marker refreshed (no longer 0)"           '[ "$(cat "$BK/.last")" != 0 ]'

echo ""
echo "============ TEST 4: rotation keeps newest BACKUP_KEEP ============"
R4=/tmp/bk4; rm -rf "$R4"
S4="$R4/store"; SP4="$S4/projects"; P4="$R4/proj"; BK4="$R4/backups"
mkdir -p "$SP4/-REPO-x-A/memory" "$P4" "$BK4"
printf 'm\n' > "$SP4/-REPO-x-A/memory/a.md"
: > "$R4/map"; : > "$R4/shared"; : > "$R4/nos"
# Pre-seed 5 old backups with lexically-earlier names (older) than any new one.
for n in 1 2 3 4 5; do mkdir -p "$BK4/store-2000010$n-000000"; done
run4(){ CLAUDE_PROJECTS_OVERRIDE="$P4" CLAUDE_STORE_OVERRIDE="$S4" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R4/map" CLAUDE_SHARED_MAP_OVERRIDE="$R4/shared" CLAUDE_NOSHARE_OVERRIDE="$R4/nos" \
  CLAUDE_BACKUP_DIR_OVERRIDE="$BK4" CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=3 bash "$LCM" >/dev/null 2>&1; }
# marker absent -> due. One real new backup is created, then rotation trims to KEEP=3.
run4
nbk4="$(ls -d "$BK4"/store-* 2>/dev/null | wc -l | tr -d ' ')"
chk "rotation trims to exactly BACKUP_KEEP=3"  '[ "'"$nbk4"'" = 3 ]'
chk "newest (the just-made real) backup kept"  '[ -f "$(ls -dt "$BK4"/store-* | head -1)/-REPO-x-A/memory/a.md" ]'
chk "oldest seeded backups rotated out"        '[ ! -d "$BK4/store-20000101-000000" ]'

echo ""
echo "============ TEST 5: --dry-run takes no backup ============"
R5=/tmp/bk5; rm -rf "$R5"
S5="$R5/store"; SP5="$S5/projects"; P5="$R5/proj"; BK5="$R5/backups"
mkdir -p "$SP5/-REPO-x-A/memory" "$P5"
printf 'm\n' > "$SP5/-REPO-x-A/memory/a.md"
: > "$R5/map"; : > "$R5/shared"; : > "$R5/nos"
CLAUDE_PROJECTS_OVERRIDE="$P5" CLAUDE_STORE_OVERRIDE="$S5" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R5/map" CLAUDE_SHARED_MAP_OVERRIDE="$R5/shared" CLAUDE_NOSHARE_OVERRIDE="$R5/nos" \
  CLAUDE_BACKUP_DIR_OVERRIDE="$BK5" CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=4 bash "$LCM" --dry-run >/dev/null 2>&1
chk "dry-run: no backup dir / no snapshot"     '[ ! -d "$BK5" ] || [ -z "$(ls -d "$BK5"/store-* 2>/dev/null)" ]'

echo ""
echo "============ TEST 6: rotation is NAME-based, not mtime-based ============"
# A backup with a far-FUTURE name but an OLDER mtime must be KEPT over a real
# backup with a newer mtime but older name — iCloud can rewrite mtimes, so the
# timestamped name is authoritative. (This would FAIL under the old `ls -dt`.)
R6=/tmp/bk6; rm -rf "$R6"
S6="$R6/store"; SP6="$S6/projects"; P6="$R6/proj"; BK6="$R6/backups"
mkdir -p "$SP6/-REPO-x-A/memory" "$P6" "$BK6"
printf 'm\n' > "$SP6/-REPO-x-A/memory/a.md"
: > "$R6/map"; : > "$R6/shared"; : > "$R6/nos"
mkdir -p "$BK6/store-29991231-235959"      # newest NAME, but created now (older mtime than the run's)
printf 'future\n' > "$BK6/store-29991231-235959/marker"
sleep 1                                     # ensure the run's backup gets a strictly newer mtime
CLAUDE_PROJECTS_OVERRIDE="$P6" CLAUDE_STORE_OVERRIDE="$S6" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R6/map" CLAUDE_SHARED_MAP_OVERRIDE="$R6/shared" CLAUDE_NOSHARE_OVERRIDE="$R6/nos" \
  CLAUDE_BACKUP_DIR_OVERRIDE="$BK6" CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=1 bash "$LCM" >/dev/null 2>&1
# marker proves a REAL backup ran this invocation (written only on cp success) —
# so the two assertions below can't false-green on a silent no-op.
chk "name-based: a real backup actually ran"   '[ -f "$BK6/.last" ]'
chk "name-based: future-named backup KEPT"     '[ -d "$BK6/store-29991231-235959" ]'
chk "name-based: only BACKUP_KEEP=1 remains"   '[ "$(ls -d "$BK6"/store-* 2>/dev/null | wc -l | tr -d " ")" = 1 ]'

echo ""
echo "============ TEST 7: spaced backup path (mimics 'Mobile Documents') ============"
# The REAL iCloud path contains a space; the other tests use space-free /tmp paths.
# This guards the while-read loop + quoted `case` rm-guard against a regression to
# a word-splitting `for x in $(ls …)`. A canary outside the backups dir must survive.
R7="/tmp/bk7 spaced"; rm -rf "$R7"
S7="$R7/store"; SP7="$S7/projects"; P7="$R7/proj"; BK7="$R7/Mobile Documents/backups"
mkdir -p "$SP7/-REPO-x-A/memory" "$P7" "$BK7" "$R7/Mobile Documents/PRECIOUS"
printf 'data\n' > "$SP7/-REPO-x-A/memory/a.md"
printf 'keepme\n' > "$R7/Mobile Documents/PRECIOUS/file"   # canary OUTSIDE backups dir
: > "$R7/map"; : > "$R7/shared"; : > "$R7/nos"
for n in 1 2 3 4; do mkdir -p "$BK7/store-2001010$n-000000"; done
env CLAUDE_PROJECTS_OVERRIDE="$P7" CLAUDE_STORE_OVERRIDE="$S7" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R7/map" CLAUDE_SHARED_MAP_OVERRIDE="$R7/shared" CLAUDE_NOSHARE_OVERRIDE="$R7/nos" \
  CLAUDE_BACKUP_DIR_OVERRIDE="$BK7" CLAUDE_BACKUP_INTERVAL_DAYS=7 CLAUDE_BACKUP_KEEP=2 bash "$LCM" >/dev/null 2>&1
chk "spaced path: rotation trims to KEEP=2"    '[ "$(ls -d "$BK7"/store-* 2>/dev/null | wc -l | tr -d " ")" = 2 ]'
chk "spaced path: newest kept has memory file" '[ -f "$(ls -d "$BK7"/store-* 2>/dev/null | sort -r | head -1)/-REPO-x-A/memory/a.md" ]'
chk "spaced path: oldest seeded rotated out"   '[ ! -d "$BK7/store-20010101-000000" ]'
chk "spaced path: canary OUTSIDE dir survived" '[ -f "$R7/Mobile Documents/PRECIOUS/file" ]'

echo ""
echo "============ TEST 8: bad numeric env must NOT abort the run (set -u hardening) ============"
# A non-numeric / negative / zero BACKUP_KEEP or INTERVAL must be sanitized, not
# fed raw into $(( )) where `set -u` would throw "unbound variable" (exit 127) and
# abort the whole SessionStart --auto run. Each sub-run must exit 0 and still link.
R8=/tmp/bk8; rm -rf "$R8"
S8="$R8/store"; SP8="$S8/projects"; P8="$R8/proj"; BK8="$R8/backups"
mkdir -p "$SP8/-REPO-x-A/memory" "$P8"
printf 'm\n' > "$SP8/-REPO-x-A/memory/a.md"
: > "$R8/map"; : > "$R8/shared"; : > "$R8/nos"
run8(){ env CLAUDE_PROJECTS_OVERRIDE="$P8" CLAUDE_STORE_OVERRIDE="$S8" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-x" \
  CLAUDE_REPO_MAP_OVERRIDE="$R8/map" CLAUDE_SHARED_MAP_OVERRIDE="$R8/shared" CLAUDE_NOSHARE_OVERRIDE="$R8/nos" \
  CLAUDE_BACKUP_DIR_OVERRIDE="$BK8" "$@" bash "$LCM" >/dev/null 2>&1; }
run8 CLAUDE_BACKUP_KEEP=abc CLAUDE_BACKUP_INTERVAL_DAYS=7
chk "non-numeric KEEP: run exits 0 (no abort)"  '[ "$?" = 0 ]'
chk "non-numeric KEEP: backup still taken"      '[ -f "$BK8/.last" ] && [ -n "$(ls -d "$BK8"/store-* 2>/dev/null)" ]'
rm -rf "$BK8"
run8 CLAUDE_BACKUP_INTERVAL_DAYS=xyz CLAUDE_BACKUP_KEEP=4
chk "non-numeric INTERVAL: run exits 0"         '[ "$?" = 0 ]'
rm -rf "$BK8"
# KEEP=0 must be floored to 1 (always retain a snapshot), not delete the just-made one.
run8 CLAUDE_BACKUP_KEEP=0 CLAUDE_BACKUP_INTERVAL_DAYS=7
chk "KEEP=0 floored to 1: one backup retained" '[ "$(ls -d "$BK8"/store-* 2>/dev/null | wc -l | tr -d " ")" = 1 ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
