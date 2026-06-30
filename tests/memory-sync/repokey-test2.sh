#!/usr/bin/env bash
# Tests for the non-destructive repo-identity consolidation.
set -u
BRM="$HOME/.claude/build-repo-map.sh"
LCM="$HOME/.claude/link-claude-memory.sh"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

echo "============ syntax ============"
bash -n "$BRM" && echo "OK build-repo-map.sh"
bash -n "$LCM" && echo "OK link-claude-memory.sh"

echo ""
echo "============ TEST A: build-repo-map upserts shared map (other Macs preserved) ============"
R=/tmp/rk2a; rm -rf "$R"; mkdir -p "$R/dev"
mkrepo(){ mkdir -p "$R/dev/$1"; git -C "$R/dev/$1" init -q; git -C "$R/dev/$1" remote add origin "$2"; }
mkrepo repoA_1 https://github.com/x/repoA.git
mkrepo repoA_2 git@github.com:x/repoA.git
# pre-seed shared map with a DIFFERENT Mac's line
SH="$R/shared.tsv"; printf -- '-HOME-other-dev-repoZ-1|-REPO-z-repoZ\n' > "$SH"
CLAUDE_SCAN_ROOTS_OVERRIDE="$R/dev" CLAUDE_REPO_MAP_OVERRIDE="$R/local.map" \
  CLAUDE_SHARED_MAP_OVERRIDE="$SH" CLAUDE_ENCODED_HOME_OVERRIDE="-tmp-rk2a" bash "$BRM" >/dev/null
echo "  --- shared map after macA publish ---"; sed 's/^/      /' "$SH"
chk "other Mac's repoZ line preserved"        'grep -qxF -- "-HOME-other-dev-repoZ-1|-REPO-z-repoZ" "$SH"'
chk "macA repoA_1 published"                   'grep -q -- "-HOME-dev-repoA-1|-REPO-github-com-x-repoA" "$SH"'
chk "https & ssh collapse to one slug"         '[ "$(grep -c -- "-REPO-github-com-x-repoA" "$SH")" = 2 ]'
# re-publish macA with repoA_1 remote changed -> its line replaced, repoZ still kept
git -C "$R/dev/repoA_1" remote set-url origin https://github.com/x/repoRenamed.git
CLAUDE_SCAN_ROOTS_OVERRIDE="$R/dev" CLAUDE_REPO_MAP_OVERRIDE="$R/local.map" \
  CLAUDE_SHARED_MAP_OVERRIDE="$SH" CLAUDE_ENCODED_HOME_OVERRIDE="-tmp-rk2a" bash "$BRM" >/dev/null
chk "re-publish replaced repoA_1's own line"   '[ "$(awk -F"|" "/repoA-1\\|/{print \$2}" "$SH")" = "-REPO-github-com-x-repoRenamed" ]'
chk "re-publish still keeps other Mac's line"  'grep -qxF -- "-HOME-other-dev-repoZ-1|-REPO-z-repoZ" "$SH"'

echo ""
echo "============ TEST B: consolidation folds clones (union-only) + orphan ============"
L=/tmp/rk2b; rm -rf "$L"; P="$L/proj"; S="$L/store"; SP="$S/projects"
mkdir -p "$SP/-HOME-dev-repoA-1/memory" "$SP/-HOME-dev-repoA-2/memory" "$SP/-HOME-dev-repoA-orphan/memory"
printf 'A1\n' > "$SP/-HOME-dev-repoA-1/memory/a1.md"
printf 'A2\n' > "$SP/-HOME-dev-repoA-2/memory/a2.md"
printf 'A3\n' > "$SP/-HOME-dev-repoA-orphan/memory/a3.md"   # other Mac's clone, no local dir here
# local clones (this Mac) already symlinked to their -HOME store buckets
mkdir -p "$P/-Users-test-dev-repoA-1" "$P/-Users-test-dev-repoA-2"
ln -s "$SP/-HOME-dev-repoA-1/memory" "$P/-Users-test-dev-repoA-1/memory"
ln -s "$SP/-HOME-dev-repoA-2/memory" "$P/-Users-test-dev-repoA-2/memory"
# local map: only THIS Mac's clones; shared map: all three (incl orphan)
printf -- '-HOME-dev-repoA-1|-REPO-x-repoA\n-HOME-dev-repoA-2|-REPO-x-repoA\n' > "$L/local.map"
printf -- '-HOME-dev-repoA-1|-REPO-x-repoA\n-HOME-dev-repoA-2|-REPO-x-repoA\n-HOME-dev-repoA-orphan|-REPO-x-repoA\n' > "$L/shared.map"

run_link(){ CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" \
  CLAUDE_REPO_MAP_OVERRIDE="$L/local.map" CLAUDE_SHARED_MAP_OVERRIDE="$L/shared.map" \
  CLAUDE_NOSHARE_OVERRIDE="$L/noshare" bash "$LCM" "$@"; }
run_link | sed 's/^/      /'

REPO="$SP/-REPO-x-repoA/memory"
chk "all three clones' files unioned into -REPO-" '[ -f "$REPO/a1.md" ] && [ -f "$REPO/a2.md" ] && [ -f "$REPO/a3.md" ]'
chk "union-only: source -1 file NOT deleted"      '[ -f "$SP/-HOME-dev-repoA-1/memory/a1.md" ]'
chk "union-only: orphan file NOT deleted"         '[ -f "$SP/-HOME-dev-repoA-orphan/memory/a3.md" ]'
chk "source -1 tagged superseded"                 '[ -e "$SP/-HOME-dev-repoA-1/.superseded-by--REPO-x-repoA" ]'
chk "orphan tagged superseded"                    '[ -e "$SP/-HOME-dev-repoA-orphan/.superseded-by--REPO-x-repoA" ]'
chk "local clone -1 symlink -> -REPO- bucket"     '[ "$(readlink "$P/-Users-test-dev-repoA-1/memory")" = "$REPO" ]'
chk "local clone -2 symlink -> -REPO- bucket"     '[ "$(readlink "$P/-Users-test-dev-repoA-2/memory")" = "$REPO" ]'
chk "audit log written"                           '[ -f "$S/consolidation.log" ] && grep -q "fold:" "$S/consolidation.log"'

echo "  --- idempotency: 2nd run folds nothing new ---"
out=$(run_link 2>&1)
chk "2nd run: 0 folded"                            'echo "$out" | grep -q "0 folded"'
chk "2nd run: symlinks unchanged"                 '[ "$(readlink "$P/-Users-test-dev-repoA-1/memory")" = "$REPO" ]'

echo ""
echo "============ TEST C: escape hatch (NOSHARE) keeps a clone path-keyed ============"
printf -- '-REPO-x-repoA\n' > "$L/noshare"   # opt the whole repo out
rm -rf "$P" "$SP/-REPO-x-repoA"
mkdir -p "$SP/-HOME-dev-repoA-1/memory"; printf 'A1\n' > "$SP/-HOME-dev-repoA-1/memory/a1.md"
rm -f "$SP/-HOME-dev-repoA-1/.superseded-by-"*
mkdir -p "$P/-Users-test-dev-repoA-1"; ln -s "$SP/-HOME-dev-repoA-1/memory" "$P/-Users-test-dev-repoA-1/memory"
run_link >/dev/null 2>&1
chk "NOSHARE: no -REPO- bucket created"            '[ ! -d "$SP/-REPO-x-repoA" ]'
chk "NOSHARE: clone keeps -HOME path key"          '[ "$(readlink "$P/-Users-test-dev-repoA-1/memory")" = "$SP/-HOME-dev-repoA-1/memory" ]'
: > "$L/noshare"  # clear escape hatch for later

echo ""
echo "============ TEST D: --prune-superseded only deletes verified subsets ============"
D=/tmp/rk2d; rm -rf "$D"; P="$D/proj"; S="$D/store"; SP="$S/projects"
mkdir -p "$SP/-HOME-dev-repoA-1/memory" "$SP/-HOME-dev-repoA-2/memory"
printf 'A1\n' > "$SP/-HOME-dev-repoA-1/memory/a1.md"
printf 'A2\n' > "$SP/-HOME-dev-repoA-2/memory/a2.md"
mkdir -p "$P/-Users-test-dev-repoA-1" "$P/-Users-test-dev-repoA-2"
ln -s "$SP/-HOME-dev-repoA-1/memory" "$P/-Users-test-dev-repoA-1/memory"
ln -s "$SP/-HOME-dev-repoA-2/memory" "$P/-Users-test-dev-repoA-2/memory"
printf -- '-HOME-dev-repoA-1|-REPO-x-repoA\n-HOME-dev-repoA-2|-REPO-x-repoA\n' > "$D/local.map"
cp "$D/local.map" "$D/shared.map"
runD(){ CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" \
  CLAUDE_REPO_MAP_OVERRIDE="$D/local.map" CLAUDE_SHARED_MAP_OVERRIDE="$D/shared.map" \
  CLAUDE_NOSHARE_OVERRIDE="$D/noshare" bash "$LCM" "$@"; }
: > "$D/noshare"
runD >/dev/null 2>&1   # consolidate first
# now corrupt source -2 so it is NOT a byte-identical subset of -REPO-
printf 'A2-CHANGED\n' > "$SP/-HOME-dev-repoA-2/memory/a2.md"
runD --prune-superseded | sed 's/^/      /'
chk "prune removed identical-subset source -1"     '[ ! -d "$SP/-HOME-dev-repoA-1" ]'
chk "prune KEPT diverged source -2"                '[ -d "$SP/-HOME-dev-repoA-2" ]'
chk "prune left -REPO- bucket intact"              '[ -f "$SP/-REPO-x-repoA/memory/a1.md" ] && [ -f "$SP/-REPO-x-repoA/memory/a2.md" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
