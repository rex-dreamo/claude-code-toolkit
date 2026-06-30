#!/usr/bin/env bash
# record-verdict.sh — append one human verdict on a pr-comment-aware-review
# suppression to the verdicts log. Read-side companion to log-suppression.sh:
# the suppression log captures what the skill decided, this log captures
# whether the human thought that decision was right.
#
# Usage:
#   record-verdict.sh '<json object>'
#   echo '<json>' | record-verdict.sh -      # also accepts stdin
#
# The caller supplies:
#   {
#     "verdict":         "right_drop" | "wrong_drop" |
#                        "right_but_for_wrong_reason" | "unclear",
#     "suppression_ref": { "pr_url": "...", "file": "...", "line": 27, "ts": "..." },
#     "reason":          "<one short sentence>"
#   }
#
# `suppression_ref` is a back-pointer into suppressions.jsonl — the four
# fields together uniquely identify the suppression entry being audited.
#
# This script enriches with `audit_ts`, `skill_version`, `_pid`, and
# `_ppid`, then appends one line of JSON to:
#   ~/.claude/logs/pr-comment-aware-review/verdicts.jsonl
#
# Exit codes:
#   0  success
#   2  jq not installed
#   3  invalid JSON input
#   4  no input provided

set -uo pipefail

SKILL_VERSION="0.1.0"
LOG_DIR="${HOME}/.claude/logs/pr-comment-aware-review"
LOG_FILE="${LOG_DIR}/verdicts.jsonl"

err() { printf '%s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { err "jq not installed"; exit 2; }

# Resolve input: arg, "-" (stdin), or empty stdin pipe
input=""
if [ "$#" -ge 1 ] && [ "$1" != "-" ]; then
    input=$1
elif [ "$#" -eq 1 ] && [ "$1" = "-" ] || [ ! -t 0 ]; then
    input=$(cat)
fi

[ -n "$input" ] || { err "no input: pass JSON as arg or via stdin"; exit 4; }

printf '%s' "$input" | jq -e . >/dev/null 2>&1 || { err "invalid JSON input"; exit 3; }

mkdir -p "$LOG_DIR"

enriched=$(printf '%s' "$input" | jq -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg ver "$SKILL_VERSION" \
    --arg pid "$$" --arg ppid "${PPID:-0}" \
    '. + {audit_ts: $ts, skill_version: $ver, _pid: ($pid | tonumber), _ppid: ($ppid | tonumber)}')

exec 9>>"$LOG_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -x 9
fi
printf '%s\n' "$enriched" >&9
exec 9>&-
