#!/usr/bin/env bash
#
# scan-tree.sh — whole-tree secret/org backstop for the publish pipeline.
#
# Unlike githooks/pre-commit (which scans a staged DIFF), this scans EVERY line
# of every text file under a directory. publish.sh runs it over the exported
# public subset as a final gate: nothing ships unless this is clean.
#
#   bash githooks/scan-tree.sh <dir> [denylist-file]
#
# Exit 0 = clean, 1 = found something (printed to stderr), 2 = bad usage.
#
set -uo pipefail

DIR="${1:-}"
DENY="${2:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: scan-tree.sh <dir> [denylist-file]" >&2; exit 2; }

HOOKDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=secret-patterns.sh
. "$HOOKDIR/secret-patterns.sh"

found=0

# The guards' own test corpora deliberately contain fake credential fixtures and
# secret-store PATHS (tests/hooks/ drives the secret-path guards; tests/githooks/
# drives the commit scanner) — exempt both, same rationale as pre-commit's
# EXCLUDE_RE. Narrow on purpose: anything excluded here is a scan blind spot, and
# pre-commit's CRED_RE still scans tests/hooks/ so real credentials can't hide.
EXCLUDE_RE='/tests/(hooks|githooks)/'

# 1) Credential-shaped content (drop placeholder/example lines + excluded paths).
cred="$(grep -rIEn -e "$CRED_RE" "$DIR" 2>/dev/null | grep -viE -e "$ALLOW_RE" | grep -vE -e "$EXCLUDE_RE" || true)"
if [ -n "$cred" ]; then
  printf '\033[31m✖ credential-like content:\033[0m\n' >&2
  printf '%s\n' "$cred" | cut -c1-160 | sed 's/^/  /' >&2
  found=1
fi

# 2) Org denylist (literals/regexes that must never appear in the public subset).
if [ -n "$DENY" ] && [ -f "$DENY" ]; then
  pats="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$DENY" 2>/dev/null || true)"
  if [ -n "$pats" ]; then
    deny="$(grep -rIEn -i -f <(printf '%s\n' "$pats") "$DIR" 2>/dev/null | grep -vE -e "$EXCLUDE_RE" || true)"
    if [ -n "$deny" ]; then
      printf '\033[31m✖ org-denylisted literal in public subset:\033[0m\n' >&2
      printf '%s\n' "$deny" | cut -c1-160 | sed 's/^/  /' >&2
      found=1
    fi
  fi
fi

exit $found
