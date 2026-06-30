#!/usr/bin/env bash
#
# pr-post-gate.sh — PreToolUse hook: the enforcement half of the
# "every code review consults existing PR comments" invariant.
#
# Matches GitHub-posting actions (gh pr comment / gh pr review, gh api writes
# to comment/review endpoints, github-MCP posting tools) and denies them unless
# a fresh PR feedback map (produced by pr-comment-aware-review's feedback-map.sh)
# exists for that PR. The deny message tells the model exactly how to comply,
# so the gate is self-healing — and it reaches even subagents that prompt-level
# nudges (UserPromptSubmit) cannot.
#
# SCOPE OF THE GUARANTEE: the gate proves a map was *fetched* recently, not
# *read*. Consultation semantics (the dedup rubric) live in the
# pr-comment-aware-review skill + the UserPromptSubmit nudge. Do not "tighten"
# this gate expecting it to prove the model read the map.
#
# Freshness window is 60 min — deliberately looser than feedback-map.sh's 5-min
# refetch TTL, because multi-agent reviews routinely exceed 5 min between the
# fetch (review start) and the post (review end).
#
# Escape hatch: feedback-map.sh itself creates pr-feedback-skip[-<N>] markers
# when a fetch was attempted and genuinely failed (gh missing/unauthenticated/
# API error). The deny message never mentions the marker, so the model cannot
# learn to bypass preemptively.
#
# macOS gotcha encoded below: /tmp is a symlink to private/tmp and BSD find
# defaults to -P (no symlink follow) — `find /tmp -maxdepth 1` returns NOTHING.
# The trailing slash in `find "$CACHE_DIR/"` forces traversal. Covered by a
# symlinked-cache-dir case in tests/hooks/post-gate-test.sh.
#
# Env: CLAUDE_PR_GATE_CACHE_DIR overrides /tmp (hermetic tests).
#
set -uo pipefail

CACHE_DIR="${CLAUDE_PR_GATE_CACHE_DIR:-/tmp}"
WINDOW_MIN=60

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$TOOL" ] && exit 0

# First fresh (< WINDOW_MIN old) file matching the glob, or empty.
fresh() {
    find "$CACHE_DIR/" -maxdepth 1 -name "$1" -mmin -"$WINDOW_MIN" 2>/dev/null | head -1
}

# Allow (exit 0) if a fresh map or failure-skip marker covers PR $1.
# Empty $1 = PR number unparseable -> any fresh map passes (e.g. `gh pr comment`
# resolving the PR from the current branch; the hook can't cheaply resolve it).
# When $1 is known, match the trailing -<N>.json only — owner/repo segments are
# hyphen-ambiguous in the cache filename.
allow_if_covered() {
    local n="${1:-}"
    if [ -n "$n" ]; then
        [ -n "$(fresh "pr-feedback-*-${n}.json")" ] && exit 0
        [ -n "$(fresh "pr-feedback-skip-${n}")" ] && exit 0
    else
        [ -n "$(fresh 'pr-feedback-*.json')" ] && exit 0
    fi
    [ -n "$(fresh 'pr-feedback-skip')" ] && exit 0
    return 1
}

deny() {
    echo "PR-posting gate: no fresh feedback map for this PR — posting review feedback without reading the existing comment threads risks duplicating prior reviewers. As its own command FIRST, run: ~/.claude/skills/pr-comment-aware-review/scripts/feedback-map.sh <pr-url> (or no args inside the PR's repo). Then invoke the pr-comment-aware-review skill and apply its dedup rubric to your findings against the existing threads, and retry this command." >&2
    exit 2
}

case "$TOOL" in
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -z "$CMD" ] && exit 0

    # Self-referential guard: developing/testing the gate must not trip the gate.
    case "$CMD" in
      *pr-post-gate.sh*|*tests/hooks/*) exit 0 ;;
    esac

    # Posting detection — three checks, all BSD-grep-verified.
    # Command-position anchored (line start or after ; & | ( `) so that quoted
    # mentions — echo "gh pr comment", git commit -m "fix gh pr comment" — never
    # false-deny. The anchor also accepts one timeout/env wrapper prefix:
    # CLAUDE.md conditions models to timeout-wrap commands, so
    # `timeout 30 gh pr comment …` is a realistic posting shape here.
    # KNOWN LIMITATION (accepted): `bash -c "gh pr comment …"` and xargs-built
    # invocations are not detected — see tests/hooks/README.md.
    RE_PRE='(^|[;&|(`][[:space:]]*)'
    RE_WRAP='((timeout[[:space:]]+[0-9]+[smhd]?|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)+)[[:space:]]+)?'
    RE_PR="${RE_PRE}${RE_WRAP}"'gh[[:space:]]+pr[[:space:]]+(comment|review)([[:space:]]|$)'
    # gh api is a write ONLY when all three hold (gh api defaults to GET and
    # auto-POSTs with -f/-F; bare reads of comment endpoints are the compliance
    # action itself and must pass):
    RE_API_CMD="${RE_PRE}${RE_WRAP}"'gh[[:space:]]+api([[:space:]]|$)'
    RE_API_EP='(pulls|issues)/[0-9]+/(comments|reviews)|pulls/comments/[0-9]+/replies'
    RE_API_WRITE='(^|[[:space:]])(-X[[:space:]]*(POST|post)|--method(=|[[:space:]]+)(POST|post)|-f([[:space:]]|$)|-F([[:space:]]|$)|--field|--raw-field|--input)'

    posting=0
    if printf '%s\n' "$CMD" | grep -qE "$RE_PR"; then
        posting=1
    elif printf '%s\n' "$CMD" | grep -qE "$RE_API_CMD" \
      && printf '%s\n' "$CMD" | grep -qE "$RE_API_EP" \
      && printf '%s\n' "$CMD" | grep -qE "$RE_API_WRITE"; then
        posting=1
    fi
    [ "$posting" -eq 0 ] && exit 0

    # PR-number extraction for precision (cross-PR maps must not unlock):
    # positional `gh pr comment 32`, api paths `pulls/32/`, URLs `pull/32`.
    N=$(printf '%s\n' "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+(comment|review)[[:space:]]+[0-9]+' | head -1 | grep -oE '[0-9]+$')
    [ -z "$N" ] && N=$(printf '%s\n' "$CMD" | grep -oE '(pulls|issues)/[0-9]+/' | head -1 | grep -oE '[0-9]+')
    [ -z "$N" ] && N=$(printf '%s\n' "$CMD" | grep -oE 'pull/[0-9]+' | head -1 | grep -oE '[0-9]+')

    allow_if_covered "$N" || deny
    ;;

  mcp__plugin_github_github__add_issue_comment)
    # PRs are issues, so this is the canonical MCP path for a general PR
    # comment — but it's also how plain issue comments are posted. Gate ONLY
    # when a cache file for this exact owner/repo/number exists at ANY age:
    # its existence proves the number is a PR that was reviewed on this Mac.
    # Plain issue comments never have a map -> zero friction.
    owner=$(printf '%s' "$INPUT" | jq -r '.tool_input.owner // empty' 2>/dev/null)
    repo=$(printf '%s' "$INPUT" | jq -r '.tool_input.repo // empty' 2>/dev/null)
    n=$(printf '%s' "$INPUT" | jq -r '.tool_input.issue_number // empty' 2>/dev/null)
    if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$n" ] && [ -e "$CACHE_DIR/pr-feedback-${owner}-${repo}-${n}.json" ]; then
        allow_if_covered "$n" || deny
    fi
    exit 0
    ;;

  mcp__plugin_github_github__pull_request_review_write|mcp__plugin_github_github__add_comment_to_pending_review|mcp__plugin_github_github__add_reply_to_pull_request_comment)
    # Unambiguously PR-review posting tools.
    n=$(printf '%s' "$INPUT" | jq -r '.tool_input.pullNumber // .tool_input.pull_number // .tool_input.prNumber // empty' 2>/dev/null)
    allow_if_covered "$n" || deny
    ;;
esac

exit 0
