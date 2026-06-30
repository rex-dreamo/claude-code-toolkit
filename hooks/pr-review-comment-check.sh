#!/usr/bin/env bash
#
# pr-review-comment-check.sh — UserPromptSubmit hook.
#
# Purpose: when a prompt looks like a code review, remind the model to consult
# the *current* PR's existing comment threads BEFORE forming findings. Built-in
# (/code-review, /review, /security-review) and plugin (code-review:code-review,
# pr-review-toolkit:review-pr) review commands do NOT do this on their own, and
# the pr-comment-aware-review skill only helps if it actually triggers. This hook
# fires deterministically at the harness level, independent of skill triggering.
#
# Output: a UserPromptSubmit additionalContext block on stdout (exit 0) when the
# prompt matches review intent; otherwise nothing. Never blocks — this is a
# sharpening nudge, not a gate. The referenced feedback-map.sh exits quietly
# (code 4) when no PR is resolvable, so an over-eager match costs nothing.
#
# Why over-eager matching is acceptable: a missed review (no nudge) costs a
# duplicate-comment review that ignores the thread; a false match costs one
# ignorable line of context. Recall is cheap; precision is not worth chasing.
#
set -uo pipefail

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

# Lowercase once so the match is case-insensitive without per-branch flags.
LP=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Review-intent signals: explicit command/agent names, plus natural-language
# "review <this|the|my|…> <pull request|pr|diff|changes|branch|commit>" and
# "review #<n>". The leading (^|[^a-z]) guard on the generic branch avoids
# matching "preview"/"interview".
PATTERN='code[ -]?review|security-review|pr-intent-review|pr-review-toolkit|review-pr|code-reviewer|/review|(^|[^a-z])review[ -]+(this |the |my |that |these )?(pull request|pr([^a-z]|$)|diff|changes|branch|commit|code)|(^|[^a-z])(look at|check|critique|give feedback on)[ -]+(this |the |my |that |these )?(pull request|pr([^a-z]|$))|(^|[^a-z])review[ -]+(pr )?#[0-9]'

printf '%s' "$LP" | grep -qE "$PATTERN" || exit 0

read -r -d '' CTX <<'EOF'
[pr-comment-aware-review] This prompt looks like a code review. Built-in and plugin review flows (/code-review, /review, /security-review, code-review:code-review, pr-review-toolkit:review-pr, the code-reviewer agent) do NOT consult the CURRENT PR's existing comment threads on their own. So, if a GitHub PR is in play (an open PR for the current branch, or a PR number/URL in the request), BEFORE forming or posting any findings:
  1. Run: ~/.claude/skills/pr-comment-aware-review/scripts/feedback-map.sh   (it exits quietly if no PR exists — safe to run unconditionally; a 5-min /tmp cache keeps it cheap for review subagents).
  2. Invoke the pr-comment-aware-review skill (Skill tool) and apply its dedup rubric, Steps 2-5 — including the mandatory "Suppressed findings (pr-comment-aware-review)" section in the report you return, even if empty.
  3. If orchestrating multiple review subagents, run step 1 once at the orchestrator level and pass the map to each subagent rather than having each refetch.
If no GitHub PR is involved (local-only diff, solo branch, non-GitHub remote), ignore this entirely.
EOF

jq -cn --arg ctx "$CTX" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
exit 0
