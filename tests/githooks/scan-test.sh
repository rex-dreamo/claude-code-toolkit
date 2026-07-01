#!/usr/bin/env bash
#
# scan-test.sh — regression suite for githooks/pre-commit (the secret/org guard).
#
# Hermetic: builds a throwaway git repo in a temp dir, copies the real hook in,
# stages content, and asserts the hook's exit code. Touches no real repo state.
#
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/githooks/pre-commit"

pass=0; fail=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Build a sandbox repo whose githooks/pre-commit IS the real hook.
G="$SANDBOX/repo"
mkdir -p "$G/githooks"
cp "$HOOK" "$G/githooks/pre-commit"
cp "$REPO/githooks/secret-patterns.sh" "$G/githooks/secret-patterns.sh"
chmod +x "$G/githooks/pre-commit"
git -C "$G" init -q
git -C "$G" config user.email t@t.t
git -C "$G" config user.name t
git -C "$G" config commit.gpgsign false

# stage a file with the given content, return the hook's exit code
run_case() {
  fname="$1"; shift
  printf '%s\n' "$1" > "$G/$fname"
  git -C "$G" add "$fname" >/dev/null 2>&1
  ( cd "$G" && SKIP_SECRET_SCAN=0 bash githooks/pre-commit >/dev/null 2>&1 )
  rc=$?
  git -C "$G" reset -q >/dev/null 2>&1
  rm -f "$G/$fname"
  return $rc
}

assert_block() { run_case "$2" "$3"; [ "$?" -ne 0 ] && ok "$1" || bad "$1 (expected BLOCK, got allow)"; }
assert_allow() { run_case "$2" "$3"; [ "$?" -eq 0 ] && ok "$1" || bad "$1 (expected ALLOW, got block)"; }

echo "── credential patterns (should BLOCK) ──"
assert_block "AWS access key id"      f.txt 'aws_key = AKIA1234567890ABCDEF'
assert_block "GitHub classic token"   f.txt 'token: ghp_0123456789abcdefghijABCDEFGHIJ012345'
assert_block "GitHub fine-grained PAT" f.txt 'github_pat_11ABCDE0000aaaa1111bbbb22'
assert_block "Anthropic-style key"    f.txt 'key=sk-ant-api03-AbCdEf012345678901234567'
assert_block "Google API key"         f.txt 'g=AIzaSyA1234567890abcdefghijklmnopqrstuv'
assert_block "Slack token"            f.txt 'slack=xoxb-1234567890-abcdefABCDEF'
assert_block "private key header"     f.pem2 '-----BEGIN OPENSSH PRIVATE KEY-----'
assert_block "hardcoded password"     f.txt 'password = hunter2hunter2hunter2'
assert_block "Bearer token (auth header)" f.txt 'Authorization: Bearer 0123456789abcdef0123456789abcdef'
assert_block "npm _authToken"         f.txt '_authToken=abc123def456ghi789jklmno'
assert_block "AWS STS temp key"       f.txt 'aws_key = ASIA1234567890ABCDEF'
assert_block "connection string pw"   f.txt 'DATABASE_URL=postgres://admin:SuperSecretPass123@db.prod.internal:5432/app'
assert_block "bare JWT"               f.txt 'var t="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzYXNpZ25hdHVyZXN0cmluZw"'
assert_block "PGP private key block"  f.txt '-----BEGIN PGP PRIVATE KEY BLOCK-----'

echo "── benign / placeholder content (should ALLOW) ──"
assert_allow "env placeholder"        f.txt 'BRAVE_API_KEY=${BRAVE_API_KEY}'
assert_allow "YOUR_ template"         f.txt 'export BRAVE_API_KEY=YOUR_BRAVE_KEY'
assert_allow "angle placeholder"      f.txt 'spreadsheet_id: <IAP_HUB_SHEET_ID>'
assert_allow "ordinary prose"         f.md  'This skill deploys a script into a NAS container.'
assert_allow "shell var ref"          f.sh  'echo "token=$GITHUB_TOKEN"'
assert_allow "Bearer env placeholder" f.txt 'Authorization: Bearer ${AI_GAME_DEV_TOKEN}'

echo "── blocklist.local (org literals) — WARN only at commit, HARD gate at publish ──"
# Org literals legitimately live in this private repo's docs (CLAUDE.md documents
# the NAS host), so a commit only WARNS (allows). The hard "never publish" gate is
# scan-tree.sh, tested in the next block.
cat > "$G/githooks/blocklist.local" <<'EOF'
# test blocklist
secret-host\.example-ddns\.org
my-cloud-project-[0-9]+
EOF
assert_allow "org literal WARNS but does not block commit" f.md 'HostName secret-host.example-ddns.org'
assert_allow "org project regex does not block commit"     f.md 'project = my-cloud-project-1234'
assert_block "real credential still BLOCKS (blocklist present)" f.md 'aws_key = AKIA1234567890ABCDEF'
assert_allow "blocklist miss is fine"                      f.md 'HostName some-other-public-host.org'
rm -f "$G/githooks/blocklist.local"
assert_allow "no blocklist => org line ok" f.md 'HostName secret-host.example-ddns.org'

echo "── scan-tree.sh: org denylist is the HARD gate on the export path ──"
STREE="$REPO/githooks/scan-tree.sh"
TDIR="$SANDBOX/tree"; DENY="$SANDBOX/deny.txt"
printf 'secret-host\\.example-ddns\\.org\n' > "$DENY"
mkdir -p "$TDIR"; printf 'HostName secret-host.example-ddns.org\n' > "$TDIR/doc.md"
bash "$STREE" "$TDIR" "$DENY" >/dev/null 2>&1 \
  && bad "scan-tree should BLOCK an org literal in the export tree" \
  || ok "scan-tree BLOCKS org literal (export hard gate)"
printf 'nothing sensitive here\n' > "$TDIR/doc.md"
bash "$STREE" "$TDIR" "$DENY" >/dev/null 2>&1 \
  && ok "scan-tree passes a clean tree" || bad "scan-tree false-positive on clean tree"
rm -rf "$TDIR"

echo "── path exclusion (guard's own test corpus) ──"
mkdir -p "$G/tests/githooks"
printf '%s\n' 'aws_key = AKIA1234567890ABCDEF' > "$G/tests/githooks/fixture.sh"
git -C "$G" add tests/githooks/fixture.sh >/dev/null 2>&1
( cd "$G" && bash githooks/pre-commit >/dev/null 2>&1 ) \
  && ok "tests/githooks/ fixtures are not scanned" || bad "tests/githooks/ should be excluded"
git -C "$G" reset -q >/dev/null 2>&1
rm -rf "$G/tests"

echo "── rename+modify must still be scanned (diff-filter ACMR) ──"
printf 'line one\nline two\nline three\nline four\n' > "$G/rn_src.txt"
git -C "$G" add rn_src.txt >/dev/null 2>&1
git -C "$G" commit -q -m base >/dev/null 2>&1
git -C "$G" mv rn_src.txt rn_dst.txt >/dev/null 2>&1
printf 'aws_key = AKIA1234567890ABCDEF\n' >> "$G/rn_dst.txt"
git -C "$G" add rn_dst.txt >/dev/null 2>&1
( cd "$G" && bash githooks/pre-commit >/dev/null 2>&1 ) \
  && bad "rename+modify bypass — secret slipped through" || ok "rename+modify is scanned (ACMR)"
git -C "$G" reset -q --hard HEAD >/dev/null 2>&1

echo "── bypass ──"
printf '%s\n' 'AKIAIOSFODNN7EXAMPLE9' > "$G/by.txt"
git -C "$G" add by.txt >/dev/null 2>&1
( cd "$G" && SKIP_SECRET_SCAN=1 bash githooks/pre-commit >/dev/null 2>&1 ) \
  && ok "SKIP_SECRET_SCAN=1 bypasses" || bad "SKIP_SECRET_SCAN=1 should bypass"
git -C "$G" reset -q >/dev/null 2>&1

echo ""
printf 'githooks scan: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
