#!/usr/bin/env bash
# sample.sh — read last N entries from the pr-comment-aware-review
# suppressions log, enrich each with: (a) the PR's current state, (b) the
# referenced thread comment as it stands today, (c) the current code at
# the cited file:line (±5 lines context). Emit one JSON audit card per
# entry to stdout as a JSON array.
#
# Usage:
#   sample.sh [N]                     # default N=5
#
# Output: JSON array of audit cards to stdout. Each card shape:
#   {
#     "suppression":    { ...the original suppression record... },
#     "pr_current":     { "state": "open|closed", "merged": bool },
#     "current_thread": { ...gh api response... } | null,
#     "current_code":   { "ref", "sha", "context_lines", "cited_line_text" } | null
#   }
#
# Exit codes:
#   0  success (also 0 on empty log — silent no-op)
#   2  gh or jq not available
#   3  gh not authenticated
#   4  suppressions log not found

set -uo pipefail

N="${1:-5}"
CONTEXT_LINES=5

SUPPRESSIONS_LOG="${HOME}/.claude/logs/pr-comment-aware-review/suppressions.jsonl"

err() { printf '%s\n' "$*" >&2; }

command -v gh >/dev/null 2>&1 || { err "gh CLI not installed"; exit 2; }
command -v jq >/dev/null 2>&1 || { err "jq not installed"; exit 2; }
gh auth status >/dev/null 2>&1 || { err "gh not authenticated"; exit 3; }
[ -f "$SUPPRESSIONS_LOG" ] || { err "suppressions log not found: $SUPPRESSIONS_LOG"; exit 4; }

entries=$(tail -n "$N" "$SUPPRESSIONS_LOG")
if [ -z "$entries" ]; then
    printf '[]\n'
    exit 0
fi

cards=()
while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    pr_url=$(printf '%s' "$entry"   | jq -r '.pr_url // ""')
    file_path=$(printf '%s' "$entry" | jq -r '.finding.file // ""')
    line_no=$(printf '%s' "$entry"   | jq -r '.finding.line // 0')
    thread_url=$(printf '%s' "$entry"| jq -r '.matched_thread.html_url // ""')

    # owner/repo/N from pr_url: https://github.com/<owner>/<repo>/pull/<N>
    owner=$(printf '%s' "$pr_url" | awk -F/ '{print $4}')
    repo=$(printf '%s' "$pr_url"  | awk -F/ '{print $5}')
    pr_num=$(printf '%s' "$pr_url"| awk -F/ '{print $7}')

    # comment_id from thread_url: ...#discussion_r<ID>
    comment_id=""
    if [ -n "$thread_url" ]; then
        comment_id=$(printf '%s' "$thread_url" | grep -oE 'discussion_r[0-9]+' | sed 's/discussion_r//')
    fi

    # PR state + ref to use for file fetch (merge_commit_sha if merged, else head.sha)
    pr_meta=$(gh api "repos/${owner}/${repo}/pulls/${pr_num}" 2>/dev/null) || pr_meta="null"
    ref=$(printf '%s' "$pr_meta" | jq -r '.merge_commit_sha // .head.sha // ""')
    pr_state=$(printf '%s' "$pr_meta"  | jq -r '.state // "unknown"')
    pr_merged=$(printf '%s' "$pr_meta" | jq -r '.merged // false')

    # Current thread comment state (null if comment_id unknown or comment deleted)
    current_thread="null"
    if [ -n "$comment_id" ]; then
        ct=$(gh api "repos/${owner}/${repo}/pulls/comments/${comment_id}" 2>/dev/null) || ct=""
        [ -n "$ct" ] && current_thread="$ct"
    fi

    # Current code at file:line (±CONTEXT_LINES) at ref
    current_code="null"
    if [ -n "$ref" ] && [ -n "$file_path" ] && [ "$line_no" -gt 0 ]; then
        content_json=$(gh api "repos/${owner}/${repo}/contents/${file_path}?ref=${ref}" 2>/dev/null) || content_json=""
        if [ -n "$content_json" ]; then
            decoded=$(printf '%s' "$content_json" | jq -r '.content // ""' | base64 -d 2>/dev/null || true)
            sha=$(printf '%s' "$content_json" | jq -r '.sha // ""')
            if [ -n "$decoded" ]; then
                start=$((line_no - CONTEXT_LINES))
                end=$((line_no   + CONTEXT_LINES))
                [ "$start" -lt 1 ] && start=1
                context=$(printf '%s' "$decoded" | awk -v s="$start" -v e="$end" 'NR>=s && NR<=e {printf "%d: %s\n", NR, $0}')
                cited_text=$(printf '%s' "$decoded" | awk -v n="$line_no" 'NR==n {print}')
                current_code=$(jq -n \
                    --arg ref "$ref" --arg sha "$sha" \
                    --arg context "$context" --arg cited "$cited_text" \
                    '{ref: $ref, sha: $sha, context_lines: $context, cited_line_text: $cited}')
            fi
        fi
    fi

    card=$(jq -n \
        --argjson sup "$entry" \
        --argjson thread "$current_thread" \
        --argjson code "$current_code" \
        --arg pr_state "$pr_state" --argjson pr_merged "$pr_merged" \
        '{
            suppression: $sup,
            pr_current:  {state: $pr_state, merged: $pr_merged},
            current_thread: $thread,
            current_code: $code
        }')
    cards+=("$card")
done <<< "$entries"

# Emit as JSON array (jq -s slurps stdin into an array)
printf '%s\n' "${cards[@]}" | jq -s '.'
