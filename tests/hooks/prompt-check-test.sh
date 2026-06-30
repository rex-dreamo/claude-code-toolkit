#!/usr/bin/env bash
#
# prompt-check-test.sh — hermetic regression suite for
# hooks/pr-review-comment-check.sh (the UserPromptSubmit review nudge).
#
# Drives the REAL script over stdin — no regex re-declaration here, so the
# script stays the single source of truth.
#
set -u
HOOK="$HOME/.claude/hooks/pr-review-comment-check.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

run_hook() { # $1 = prompt text; output on stdout
    printf '{"prompt":%s}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK"
}

expect_match() {
    if run_hook "$1" | grep -q additionalContext; then ok "match: $1"; else bad "expected MATCH: $1"; fi
}
expect_quiet() {
    if [ -z "$(run_hook "$1")" ]; then ok "quiet: $1"; else bad "expected QUIET: $1"; fi
}

echo "TEST executable bit (exit 126/127 in the harness = silent fail-open on a fresh Mac)"
[ -x "$HOOK" ] && ok "hook is executable" || bad "hook is NOT executable"

echo "TEST review-intent prompts must match"
expect_match "/code-review"
expect_match "/code-review:code-review"
expect_match "/security-review"
expect_match "/pr-review-toolkit:review-pr"
expect_match "review-pr"
expect_match "review PR #32"
expect_match "please code review this"
expect_match "Provide a code review for the given pull request."
expect_match "review the pull request"
expect_match "review my changes"
expect_match "can you review this diff"
expect_match "review the branch before merge"
expect_match "please review this pr"
expect_match "check this pr"
expect_match "look at the pull request"
expect_match "give feedback on this pr"
expect_match "review this code"
expect_match "review the codebase"

echo "TEST non-review prompts must stay quiet"
expect_quiet "preview the design"
expect_quiet "interview notes"
expect_quiet "review the document for typos"
expect_quiet "give me a preview"
expect_quiet "check the weather"
expect_quiet "look at the logs"
expect_quiet "summarize this channel"
expect_quiet "deploy to NAS"

echo "TEST edge inputs"
out=$(printf '{"prompt":""}' | bash "$HOOK"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "empty prompt: quiet, exit 0" || bad "empty prompt: out='$out' rc=$rc"
out=$(printf '{}' | bash "$HOOK"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "missing prompt field: quiet, exit 0" || bad "missing prompt: out='$out' rc=$rc"
out=$(printf 'not json at all' | bash "$HOOK"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "malformed json: quiet, exit 0" || bad "malformed json: out='$out' rc=$rc"

echo "TEST JSON shape of a match"
if run_hook "/code-review" | jq -e '.hookSpecificOutput.hookEventName=="UserPromptSubmit" and (.hookSpecificOutput.additionalContext|test("feedback-map.sh"))' >/dev/null 2>&1; then
    ok "UserPromptSubmit shape + feedback-map pointer present"
else
    bad "JSON shape wrong"
fi

echo ""
echo "prompt-check-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
