#!/usr/bin/env bash
# Pathological: same relative path holds DIFFERENT repos on two Macs.
# Verify: (a) no crash/loss, (b) fold happens once (superseded stops flip-flop),
# (c) each Mac routes its own foo to its own -REPO- (new memory separates).
set -u
LCM="$HOME/.claude/link-claude-memory.sh"
pass=0; fail=0
chk(){ if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

ROOT=/tmp/sp; rm -rf "$ROOT"
S="$ROOT/store"; SP="$S/projects"; PA="$ROOT/a/projects"; PB="$ROOT/b/projects"
mkdir -p "$SP" "$PA" "$PB"
FOO=-HOME-Development-GitHubProjects-foo

# Pre-existing contaminated shared bucket (the OLD path-key world): both Macs'
# memory already coexisted here under one path key.
mkdir -p "$SP/$FOO/memory"
printf 'from repoX on macA\n' > "$SP/$FOO/memory/x.md"
printf 'from repoY on macB\n' > "$SP/$FOO/memory/y.md"
# local clones: each Mac's foo symlinked to the shared -HOME-foo bucket
mkdir -p "$PA/-Users-a-Development-GitHubProjects-foo" "$PB/-Users-b-Development-GitHubProjects-foo"
ln -s "$SP/$FOO/memory" "$PA/-Users-a-Development-GitHubProjects-foo/memory"
ln -s "$SP/$FOO/memory" "$PB/-Users-b-Development-GitHubProjects-foo/memory"
# per-Mac local maps DISAGREE on what foo is (different remotes)
printf -- "$FOO|-REPO-RepoX\n" > "$ROOT/mapA"
printf -- "$FOO|-REPO-RepoY\n" > "$ROOT/mapB"
: > "$ROOT/nos"

echo "============ Mac A runs (shared map says foo->RepoX) ============"
cp "$ROOT/mapA" "$ROOT/shared"
CLAUDE_PROJECTS_OVERRIDE="$PA" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-a" \
  CLAUDE_REPO_MAP_OVERRIDE="$ROOT/mapA" CLAUDE_SHARED_MAP_OVERRIDE="$ROOT/shared" CLAUDE_NOSHARE_OVERRIDE="$ROOT/nos" bash "$LCM" 2>&1 | sed 's/^/   /'
chk "fold #1: -HOME-foo folded into -REPO-RepoX"        '[ -f "$SP/-REPO-RepoX/memory/x.md" ] && [ -f "$SP/-REPO-RepoX/memory/y.md" ]'
chk "no data loss: source still intact (union-only)"    '[ -f "$SP/$FOO/memory/x.md" ] && [ -f "$SP/$FOO/memory/y.md" ]'
chk "source tagged superseded after first fold"         '[ -e "$SP/$FOO/.superseded-by--REPO-RepoX" ]'
chk "Mac A foo -> RepoX (its own map)"                   '[ "$(readlink "$PA/-Users-a-Development-GitHubProjects-foo/memory")" = "$SP/-REPO-RepoX/memory" ]'

echo ""
echo "============ Mac B runs (its publish flips shared map to foo->RepoY) ============"
cp "$ROOT/mapB" "$ROOT/shared"   # simulate Mac B's build-repo-map upsert
CLAUDE_PROJECTS_OVERRIDE="$PB" CLAUDE_STORE_OVERRIDE="$S" CLAUDE_ENCODED_HOME_OVERRIDE="-Users-b" \
  CLAUDE_REPO_MAP_OVERRIDE="$ROOT/mapB" CLAUDE_SHARED_MAP_OVERRIDE="$ROOT/shared" CLAUDE_NOSHARE_OVERRIDE="$ROOT/nos" bash "$LCM" 2>&1 | sed 's/^/   /'
chk "NO flip-flop: -HOME-foo NOT re-folded into RepoY"   '[ ! -d "$SP/-REPO-RepoY/memory" ] || [ ! -f "$SP/-REPO-RepoY/memory/x.md" ]'
chk "superseded guard held (still tagged RepoX only)"    '[ -e "$SP/$FOO/.superseded-by--REPO-RepoX" ] && [ ! -e "$SP/$FOO/.superseded-by--REPO-RepoY" ]'
chk "historical data still safe in RepoX"               '[ -f "$SP/-REPO-RepoX/memory/x.md" ]'
chk "Mac B foo -> RepoY (its own map; new writes separate)" '[ "$(readlink "$PB/-Users-b-Development-GitHubProjects-foo/memory")" = "$SP/-REPO-RepoY/memory" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
