#!/usr/bin/env bash
# Two-Mac simulation: one shared iCloud store, two usernames, different folder names.
set -u
LCM="$HOME/.claude/link-claude-memory.sh"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

ROOT=/tmp/mmac; rm -rf "$ROOT"
S="$ROOT/store"; SP="$S/projects"          # shared iCloud store (both Macs)
PA="$ROOT/macA/projects"; PB="$ROOT/macB/projects"
HA="-Users-usera"; HB="-Users-userb"     # different usernames
SHARED="$ROOT/shared.tsv"
mkdir -p "$SP" "$PA" "$PB"

mem(){ mkdir -p "$1"; }   # helper

# --- Repo R: same repo, DIFFERENT clone folder names on each Mac ---------------
# Mac A folder R-1 ; Mac B folder R-01 ; both remote -> -REPO-x-R
RR=-REPO-x-R
mkdir -p "$SP/-HOME-Development-GitHubProjects-R-1/memory" \
         "$SP/-HOME-Development-GitHubProjects-R-01/memory"
printf 'AA\n'                 > "$SP/-HOME-Development-GitHubProjects-R-1/memory/a.md"
printf '# Memory Index\n- [A](a.md) — from mac A\n' > "$SP/-HOME-Development-GitHubProjects-R-1/memory/MEMORY.md"
printf 'NOTES-A\n'           > "$SP/-HOME-Development-GitHubProjects-R-1/memory/notes.md"
printf 'BB\n'                 > "$SP/-HOME-Development-GitHubProjects-R-01/memory/b.md"
printf '# Memory Index\n- [B](b.md) — from mac B\n' > "$SP/-HOME-Development-GitHubProjects-R-01/memory/MEMORY.md"
printf 'NOTES-B\n'           > "$SP/-HOME-Development-GitHubProjects-R-01/memory/notes.md"   # same name, diff content
# local clones are symlinks to their own store buckets (steady state)
mkdir -p "$PA/${HA}-Development-GitHubProjects-R-1" "$PB/${HB}-Development-GitHubProjects-R-01"
ln -s "$SP/-HOME-Development-GitHubProjects-R-1/memory"  "$PA/${HA}-Development-GitHubProjects-R-1/memory"
ln -s "$SP/-HOME-Development-GitHubProjects-R-01/memory" "$PB/${HB}-Development-GitHubProjects-R-01/memory"

# --- Repo R2: one clone's index carries PROSE (must be flagged, not auto-merged)
mkdir -p "$SP/-HOME-Development-GitHubProjects-R2-1/memory" \
         "$SP/-HOME-Development-GitHubProjects-R2-2/memory"
printf '# Memory Index\n- [X](x.md) — x\n' > "$SP/-HOME-Development-GitHubProjects-R2-1/memory/MEMORY.md"
printf 'XX\n' > "$SP/-HOME-Development-GitHubProjects-R2-1/memory/x.md"
printf '# Project Memory\n## Lessons\n- never do Y\n- [Z](z.md) — z\n' > "$SP/-HOME-Development-GitHubProjects-R2-2/memory/MEMORY.md"
printf 'ZZ\n' > "$SP/-HOME-Development-GitHubProjects-R2-2/memory/z.md"
mkdir -p "$PA/${HA}-Development-GitHubProjects-R2-1"
ln -s "$SP/-HOME-Development-GitHubProjects-R2-1/memory" "$PA/${HA}-Development-GitHubProjects-R2-1/memory"

# --- Different repos stay distinct --------------------------------------------
mkdir -p "$SP/-HOME-Development-GitHubProjects-S1/memory" "$SP/-HOME-Development-GitHubProjects-S2/memory"
printf 's1\n' > "$SP/-HOME-Development-GitHubProjects-S1/memory/s.md"
printf 's2\n' > "$SP/-HOME-Development-GitHubProjects-S2/memory/s.md"

# shared map: both Macs' lines for R + R2 + the two distinct repos
cat > "$SHARED" <<EOF
-HOME-Development-GitHubProjects-R-1|$RR
-HOME-Development-GitHubProjects-R-01|$RR
-HOME-Development-GitHubProjects-R2-1|-REPO-x-R2
-HOME-Development-GitHubProjects-R2-2|-REPO-x-R2
-HOME-Development-GitHubProjects-S1|-REPO-x-S1
-HOME-Development-GitHubProjects-S2|-REPO-x-S2
EOF
# per-Mac local maps (only that Mac's own clones)
cat > "$ROOT/mapA" <<EOF
-HOME-Development-GitHubProjects-R-1|$RR
-HOME-Development-GitHubProjects-R2-1|-REPO-x-R2
-HOME-Development-GitHubProjects-S1|-REPO-x-S1
-HOME-Development-GitHubProjects-S2|-REPO-x-S2
EOF
cat > "$ROOT/mapB" <<EOF
-HOME-Development-GitHubProjects-R-01|$RR
EOF

runA(){ CLAUDE_PROJECTS_OVERRIDE="$PA" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="$HA" \
  CLAUDE_REPO_MAP_OVERRIDE="$ROOT/mapA" CLAUDE_SHARED_MAP_OVERRIDE="$SHARED" CLAUDE_NOSHARE_OVERRIDE="$ROOT/noshare" bash "$LCM" "$@"; }
runB(){ CLAUDE_PROJECTS_OVERRIDE="$PB" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="$HB" \
  CLAUDE_REPO_MAP_OVERRIDE="$ROOT/mapB" CLAUDE_SHARED_MAP_OVERRIDE="$SHARED" CLAUDE_NOSHARE_OVERRIDE="$ROOT/noshare" bash "$LCM" "$@"; }
: > "$ROOT/noshare"

echo "============ Mac A first run (folds + reconciles) ============"
runA 2>&1 | sed 's/^/   /'
RM="$SP/$RR/memory"
chk "R: both clones' content unioned (a.md + b.md)"      '[ -f "$RM/a.md" ] && [ -f "$RM/b.md" ]'
chk "R: same-name diff-content notes.md kept BOTH"       '[ -f "$RM/notes.md" ] && ls "$RM"/notes.md.conflict-* >/dev/null 2>&1'
chk "R: index reconciled — has BOTH bullets"             'grep -q "(a.md)" "$RM/MEMORY.md" && grep -q "(b.md)" "$RM/MEMORY.md"'
chk "R: no MEMORY.md.conflict-* left (pure index merged)" '! ls "$RM"/MEMORY.md.conflict-* >/dev/null 2>&1'
chk "R: Mac A local clone repointed to -REPO-"           '[ "$(readlink "$PA/${HA}-Development-GitHubProjects-R-1/memory")" = "$RM" ]'
chk "R: source R-1 tagged superseded, content intact"    '[ -e "$SP/-HOME-Development-GitHubProjects-R-1/.superseded-by-'"$RR"'" ] && [ -f "$SP/-HOME-Development-GitHubProjects-R-1/memory/a.md" ]'

R2M="$SP/-REPO-x-R2/memory"
chk "R2: prose index NOT auto-merged (conflict kept)"    'ls "$R2M"/MEMORY.md.conflict-* >/dev/null 2>&1'
chk "R2: both content files still present"               '[ -f "$R2M/x.md" ] && [ -f "$R2M/z.md" ]'

chk "distinct repos S1/S2 stay separate buckets"         '[ -f "$SP/-REPO-x-S1/memory/s.md" ] && [ -f "$SP/-REPO-x-S2/memory/s.md" ] && [ "$(cat "$SP/-REPO-x-S1/memory/s.md")" = "s1" ]'

echo ""
echo "============ Mac B run (must NOT re-introduce conflicts) ============"
before_conf=$(ls "$RM"/*.conflict-* 2>/dev/null | wc -l | tr -d ' ')
outB=$(runB 2>&1); echo "$outB" | sed 's/^/   /'
after_conf=$(ls "$RM"/*.conflict-* 2>/dev/null | wc -l | tr -d ' ')
chk "Mac B repointed R-01 clone to -REPO-"               '[ "$(readlink "$PB/${HB}-Development-GitHubProjects-R-01/memory")" = "$RM" ]'
chk "Mac B added NO new content conflict (superseded guard)" '[ "$after_conf" = "$before_conf" ]'
chk "Mac B run did 0 folds"                              'echo "$outB" | grep -q "0 folded"'

echo ""
echo "============ idempotency: Mac A again ============"
outA2=$(runA 2>&1)
chk "Mac A 2nd run: 0 folded, 0 reconciled"              'echo "$outA2" | grep -q "0 folded, 0 index-reconciled"'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
