#!/usr/bin/env bash
# log-suppression.sh — append a structured record of one suppress/reframe
# decision to the suppressions log. The log is the feedback channel that
# makes the rubric evolvable: periodic review of entries reveals whether
# the dedup is overdropping (real bugs lost) or underdropping (noise).
#
# Usage:
#   log-suppression.sh '<json object>'
#   echo '<json>' | log-suppression.sh -    # also accepts stdin
#
# The caller supplies whichever of these fields apply:
#   {
#     "action":        "dropped" | "reframed-concur" | "reframed-still-applies" | "fixed-but-incomplete",
#     "pr_url":        "https://github.com/owner/repo/pull/N",
#     "finding":       { "file": "...", "line": 27, "summary": "..." },
#     "matched_thread": { "html_url": "...", "author": "...", "status": "...", "confidence": "...", "evidence": "..." },
#     "verification":  { "checked_sha": "...", "verdict": "confirmed|partial|none", "note": "..." },
#     "review_context": "code-review | pr-intent-review | review-pr | code-reviewer-agent | ad-hoc"
#   }
#
# This script enriches with `ts` (ISO timestamp), `skill_version`, and the
# pid/parent for forensic context, then appends one line of JSON to:
#   ~/.claude/logs/pr-comment-aware-review/suppressions.jsonl
#
# Exit codes:
#   0  success
#   2  jq not installed
#   3  invalid JSON input
#   4  no input provided

set -uo pipefail

SKILL_VERSION="0.2.0"
LOG_DIR="${HOME}/.claude/logs/pr-comment-aware-review"
LOG_FILE="${LOG_DIR}/suppressions.jsonl"

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

# Validate JSON before doing anything else
printf '%s' "$input" | jq -e . >/dev/null 2>&1 || { err "invalid JSON input"; exit 3; }

mkdir -p "$LOG_DIR"

# Enrich with timestamp, skill version, and pid context for forensics
enriched=$(printf '%s' "$input" | jq -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg ver "$SKILL_VERSION" \
    --arg pid "$$" --arg ppid "${PPID:-0}" \
    '. + {ts: $ts, skill_version: $ver, _pid: ($pid | tonumber), _ppid: ($ppid | tonumber)}')

# Append one line of JSON. Use >> with flock to be safe against parallel
# subagents writing simultaneously.
exec 9>>"$LOG_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -x 9
fi
printf '%s\n' "$enriched" >&9
exec 9>&-
