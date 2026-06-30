#!/usr/bin/env bash
set -u
BRM="$HOME/.claude/build-repo-map.sh"
LCM="$HOME/.claude/link-claude-memory.sh"
# HERMETIC GUARD: default the shared map + scan root to sandbox paths so a forgotten
# per-call override can't publish test lines into the real store map. (Per-call
# CLAUDE_REPO_MAP_OVERRIDE values below still take precedence where set.)
export CLAUDE_SHARED_MAP_OVERRIDE="/tmp/repokey-test.sbx-shared"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

echo "============ syntax ============"
bash -n "$BRM" && echo "OK build-repo-map.sh"
bash -n "$LCM" && echo "OK link-claude-memory.sh"

echo ""
echo "============ TEST 1: build-repo-map derives shared keys from git remotes ============"
R=/tmp/rmtest; rm -rf "$R"; mkdir -p "$R/dev"
mkrepo(){ mkdir -p "$R/dev/$1"; git -C "$R/dev/$1" init -q; git -C "$R/dev/$1" remote add origin "$2"; }
mkrepo repoA_1   https://github.com/x/repoA.git
mkrepo repoA_2   https://github.com/x/repoA.git
mkrepo repoA_ssh git@github.com:x/repoA.git
mkrepo repoB_1   https://github.com/x/repoB.git
mkdir -p "$R/dev/plainfolder"   # no git

CLAUDE_SCAN_ROOTS_OVERRIDE="$R/dev" CLAUDE_REPO_MAP_OVERRIDE="$R/map" \
  CLAUDE_ENCODED_HOME_OVERRIDE="-tmp-rmtest" bash "$BRM" >/dev/null
echo "  --- generated map ---"; sed 's/^/      /' "$R/map"
keyA=$(grep -F -e '-HOME-dev-repoA-1|' "$R/map" | cut -d'|' -f2)
chk "repoA_1 -> a -REPO- key"                       '[ -n "$keyA" ] && [ "${keyA#-REPO-}" != "$keyA" ]'
chk "repoA_2 shares repoA_1 key"                    '[ "$(grep -F -e "-HOME-dev-repoA-2|" "$R/map"|cut -d"|" -f2)" = "$keyA" ]'
chk "ssh remote collapses to SAME key as https"     '[ "$(grep -F -e "-HOME-dev-repoA-ssh|" "$R/map"|cut -d"|" -f2)" = "$keyA" ]'
chk "repoB gets a DIFFERENT key"                    '[ "$(grep -F -e "-HOME-dev-repoB-1|" "$R/map"|cut -d"|" -f2)" != "$keyA" ]'
chk "non-git plainfolder excluded from map"         '! grep -q plainfolder "$R/map"'
chk "exactly 2 distinct repo keys"                  '[ "$(cut -d"|" -f2 "$R/map"|sort -u|wc -l|tr -d " ")" = 2 ]'

echo ""
echo "============ TEST 2: linker collapses all clones to ONE bucket via the map ============"
L=/tmp/lctest; rm -rf "$L"; P="$L/proj"; S="$L/store"
mkdir -p "$P/-Users-test-dev-repoA-1/memory" "$P/-Users-test-dev-repoA-2/memory" "$P/-Users-test-dev-plain/memory"
printf 'A1\n' > "$P/-Users-test-dev-repoA-1/memory/fileA1.md"
printf 'A2\n' > "$P/-Users-test-dev-repoA-2/memory/fileA2.md"
printf 'PL\n' > "$P/-Users-test-dev-plain/memory/plain.md"
printf -- '-HOME-dev-repoA-1|-REPO-x-repoA\n-HOME-dev-repoA-2|-REPO-x-repoA\n' > "$L/map"

CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" \
  CLAUDE_REPO_MAP_OVERRIDE="$L/map" bash "$LCM" | sed 's/^/      /'

M1="$P/-Users-test-dev-repoA-1/memory"; M2="$P/-Users-test-dev-repoA-2/memory"
MP="$P/-Users-test-dev-plain/memory"; REPO="$S/projects/-REPO-x-repoA/memory"
t1=$(readlink "$M1" 2>/dev/null); t2=$(readlink "$M2" 2>/dev/null)
chk "clone repoA-1 symlinks to the -REPO- bucket"   '[ "$t1" = "$REPO" ]'
chk "clone repoA-2 symlinks to the SAME -REPO- bucket" '[ "$t2" = "$REPO" ]'
chk "both clones' files unioned in shared bucket"   '[ -f "$REPO/fileA1.md" ] && [ -f "$REPO/fileA2.md" ]'
chk "clone-1 sees clone-2's memory through symlink" '[ -f "$M1/fileA2.md" ]'
chk "non-repo project keeps PATH key (not -REPO-)"  '[ "$(readlink "$MP")" = "$S/projects/-HOME-dev-plain/memory" ]'

echo "  --- idempotency: second run ---"
out=$(CLAUDE_PROJECTS_OVERRIDE="$P" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-test" \
  CLAUDE_REPO_MAP_OVERRIDE="$L/map" bash "$LCM" 2>&1)
chk "second run: 0 merged (idempotent)"             'echo "$out" | grep -q "0 merged"'
chk "second run: clones still point to -REPO-"      '[ "$(readlink "$M1")" = "$REPO" ] && [ "$(readlink "$M2")" = "$REPO" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
