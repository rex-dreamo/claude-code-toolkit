# Review-hook regression tests

Regression net for the "every code review checks PR comments" enforcement —
[`hooks/pr-review-comment-check.sh`](../../hooks/pr-review-comment-check.sh)
(UserPromptSubmit nudge) and
[`hooks/pr-post-gate.sh`](../../hooks/pr-post-gate.sh) (PreToolUse posting
gate), plus the failure-skip markers in
[`feedback-map.sh`](../../skills/pr-comment-aware-review/scripts/feedback-map.sh).

## Run

```bash
bash ~/.claude/tests/hooks/run-all.sh     # all suites; non-zero exit if any fail
```

## Hermetic by construction

Suites drive the real scripts purely over stdin. The gate suite sandboxes its
cache dir via `CLAUDE_PR_GATE_CACHE_DIR` — and the sandbox path is itself a
**symlink**, so every assertion doubles as the regression net for the macOS bug
where `find /tmp -maxdepth 1` returns nothing (`/tmp` → `private/tmp`; BSD find
doesn't follow CLI symlinks — fixed via trailing slash). Nothing reads or
writes real `/tmp` pr-feedback state.

## Suites

| File | Covers |
|---|---|
| `prompt-check-test.sh` | Review-intent prompts match (slash commands, expanded plugin text, natural language incl. prompt-final "review this pr", "review this code"); non-review prompts stay quiet ("preview", "interview", document review); malformed/empty input fail-open; UserPromptSubmit JSON shape. |
| `post-gate-test.sh` | Posting denied without a fresh map (`gh pr comment/review`, `gh api` writes, compound/piped/timeout-/env-wrapped forms); reads and innocent mentions always pass; per-PR precision (PR-32 map ≠ PR-51 unlock); stale (>60 min) map re-blocks; failure-skip markers (created by feedback-map.sh on genuine fetch failure, honored ≤60 min, never leaked in the deny message); MCP posting tools incl. the `add_issue_comment` PR-vs-issue distinction; self-referential guard; executable bits; fail-open on malformed stdin. |

## Known, accepted limitations (asserted in the suite so they can't drift silently)

- **Heredoc false positive**: a data line starting with `gh pr comment` inside a
  multi-line Bash command is denied (grep is line-oriented). Cost: one deny on a
  rare shape; write such files with the Write tool instead of heredocs.
- **`bash -c "gh pr comment …"` false negative**: posting hidden inside a quoted
  subshell string is not detected. The command-position anchor that creates this
  gap is what keeps `echo "gh pr comment"` / `git commit -m "fix gh pr comment"`
  from false-denying; the threat model is a *forgetful* model, not an evasive one.
- The gate proves a map was **fetched** recently, not **read** — consultation
  semantics live in the `pr-comment-aware-review` skill rubric + the
  UserPromptSubmit nudge.
