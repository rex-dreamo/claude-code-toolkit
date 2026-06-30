#!/usr/bin/env bash
#
# scan-tree-test.sh — regression suite for githooks/scan-tree.sh (publish gate).
#
# Hermetic: builds throwaway trees under mktemp with FAKE literals + a fake
# denylist. Touches no real repo state and contains no real org strings.
#
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCAN="$REPO/githooks/scan-tree.sh"

pass=0; fail=0
ok(){  printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# A fake denylist (no real org strings).
DENY="$SB/deny.txt"
printf '%s\n' 'acme-secret-host\.example' 'widget-project-[0-9]+' > "$DENY"

# clean tree
mkdir -p "$SB/clean"
printf 'This is ordinary public documentation.\n' > "$SB/clean/readme.md"
printf 'export KEY=${KEY}\n' > "$SB/clean/run.sh"
bash "$SCAN" "$SB/clean" "$DENY" >/dev/null 2>&1 && ok "clean tree passes" || bad "clean tree should pass"

# credential in tree
mkdir -p "$SB/cred"
printf 'token = ghp_0123456789abcdefghijABCDEFGHIJ012345\n' > "$SB/cred/x.txt"
bash "$SCAN" "$SB/cred" "$DENY" >/dev/null 2>&1 && bad "credential should block" || ok "credential blocks"

# denylisted org literal in tree
mkdir -p "$SB/org"
printf 'HostName acme-secret-host.example\n' > "$SB/org/conf.md"
bash "$SCAN" "$SB/org" "$DENY" >/dev/null 2>&1 && bad "denylist literal should block" || ok "denylist literal blocks"

# denylist regex match
mkdir -p "$SB/org2"
printf 'deploying widget-project-42 now\n' > "$SB/org2/d.md"
bash "$SCAN" "$SB/org2" "$DENY" >/dev/null 2>&1 && bad "denylist regex should block" || ok "denylist regex blocks"

# tests/githooks exclusion: fake creds under that path are exempt
mkdir -p "$SB/exc/tests/githooks"
printf 'token = ghp_0123456789abcdefghijABCDEFGHIJ012345\n' > "$SB/exc/tests/githooks/fixture.sh"
printf 'clean line\n' > "$SB/exc/other.md"
bash "$SCAN" "$SB/exc" "$DENY" >/dev/null 2>&1 && ok "tests/githooks/ fixtures exempt" || bad "tests/githooks/ should be exempt"

# usage error on bad dir
bash "$SCAN" "$SB/does-not-exist" >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "bad dir => exit 2" || bad "bad dir should exit 2"

echo ""
printf 'scan-tree: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
