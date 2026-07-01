#!/usr/bin/env bash
#
# guard-secret-paths.sh — PreToolUse guard for file tools (Read|Grep|Glob|Edit|Write).
#
# Blocks access to the pure-secret credential stores listed in
# hooks/secret-paths.txt. This replaces the former inline jq guard in
# settings.json (which covered only ~/.secrets) and generalizes it to the whole
# credential surface — the trailofbits deny-rule lesson, done as a testable script.
#
# Reads the tool call as JSON on stdin; exit 2 (with a stderr reason) blocks it.
# Deliberately bash-3.2 safe: no arrays, no `local var=$(...)`.
#
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS="$DIR/secret-paths.txt"

INPUT="$(cat)"
# Extract EVERY real path field independently — never let one field's `//`
# short-circuit hide another (a Grep with pattern="." + path=<secret> must not
# slip through). `pattern` is search CONTENT, not a path, so it is excluded.
TARGET="$(printf '%s' "$INPUT" | jq -r '[.tool_input.file_path, .tool_input.path, .tool_input.notebook_path] | map(select(. != null and . != "")) | .[]' 2>/dev/null)"

[ -n "$TARGET" ] || exit 0
[ -f "$PATTERNS" ] || exit 0

if printf '%s\n' "$TARGET" | grep -qiE -f <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$PATTERNS"); then
  echo "Blocked: '$TARGET' is a protected credential store (hooks/secret-paths.txt)." >&2
  echo "Reads of secret stores are denied to prevent accidental leak / injection-driven exfil." >&2
  echo "If you truly need it, open it in your own terminal." >&2
  exit 2
fi
exit 0
