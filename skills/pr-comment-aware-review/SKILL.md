---
name: pr-comment-aware-review
visibility: public
description: Use whenever conducting a code review against a GitHub pull request — including via /code-review, /pr-review-toolkit:review-pr, /pr-intent-review, the code-reviewer agent, or any natural-language ask like "review PR #123" or "code review this pull request". Fetches every prior comment, review, and review-comment on the PR (pre-digested into threads with resolution status) before you form findings, then applies a conservative dedup rubric so the review respects what has already been said. Even runs opportunistically on pre-commit reviews if the current branch has an open PR. A review that ignores existing comments wastes the author's attention and looks like the reviewer did not read the thread.
---

# PR-comment-aware review

## Why this exists

A code review that reposts feedback the PR already received is worse than no review — it tells the author "I did not read what is already on the page." That is the primary failure mode this skill prevents.

Other failure modes it prevents:
- Reopening a thread the PR author has already explained ("intentional" / "out-of-scope" / "will address in follow-up")
- Filing a finding the latest commits visibly addressed
- Treating an earlier reviewer's valid concern as your own when you are actually concurring

The *worst* failure of this skill would be the opposite: dropping a real bug because it semantically matched an "intentional" thread that was actually about a different concern. The rubric below biases hard against that — when in doubt, keep. Duplicates are a UX cost; missed bugs are a correctness cost. Asymmetry matters.

## When this skill applies

| Situation | Use this skill? |
|---|---|
| Any review of a PR that exists on GitHub | Yes |
| Pre-commit review on a branch with an open PR | Yes (opportunistically — catches issues already raised) |
| Pre-commit review on a branch with no PR | No-op — skip silently |
| Review of local diff on a project with no GitHub remote | No-op — skip silently |
| Reviewing your own work before requesting review | No-op — skip silently |

If `gh` is not installed, not authenticated, or no PR is resolvable, the script exits quietly and the surrounding review proceeds without a map. This is a sharpening tool, not a gating tool.

## Step 1: Fetch the existing-feedback map

Run the bundled script. It does *all* of: 4 parallel `gh api` calls (PR metadata + 3 comment feeds), thread reconstruction (`in_reply_to` chains), signal detection from PR author replies (regex matches against verb list + commit-hash heuristic), and latest-review extraction. Output is a pre-digested JSON map keyed by file/line — the model does *not* need to redo this work.

```bash
~/.claude/skills/pr-comment-aware-review/scripts/feedback-map.sh
# or, explicit:
~/.claude/skills/pr-comment-aware-review/scripts/feedback-map.sh <owner> <repo> <N>
# or, from URL:
~/.claude/skills/pr-comment-aware-review/scripts/feedback-map.sh https://github.com/owner/repo/pull/123
```

A 5-minute file cache at `/tmp/pr-feedback-{owner}-{repo}-{N}.json` makes repeated invocations (e.g. parallel review subagents) cheap. Pass `--no-cache` as the first arg to bypass.

Exit codes:
- `0` — success, JSON on stdout
- `2` — `gh` or `jq` not installed → skip silently
- `3` — `gh` not authenticated → skip silently
- `4` — no PR resolvable → skip silently
- `5` — API call failed → tell the user, then skip

Output shape (key fields):

```json
{
  "pr": { "owner", "repo", "number", "url", "author" },

  "threads_by_file": {
    "path/to/file.go": [
      {
        "file": "path/to/file.go",
        "line": 25,
        "root_id": 2305162738,
        "root_author": "babakks",
        "topic_hint": "<first 160 chars of the root comment>",
        "html_url": "<jump-to-thread URL>",
        "messages": [{ "author", "body", "is_pr_author", "created_at" }],
        "pr_author_replied": true,
        "resolution": {
          "status":     "fixed | intentional | deferred | disputed | unclear | open",
          "confidence": "high | low | n/a",
          "by":         "<PR-author-username>",
          "at":         "<ISO timestamp>",
          "excerpt":    "<excerpt of the resolving reply>",
          "note":       "<present when ambiguous>"
        }
      }
    ]
  },

  "general_threads": [{ "id", "author", "body", "excerpt", "is_pr_author", "created_at", "html_url" }],

  "reviews": {
    "most_recent": { "state", "author", "submitted_at", "body", "html_url" },
    "state_counts": { "APPROVED": 1, "COMMENTED": 10, "CHANGES_REQUESTED": 0 },
    "total": 11
  },

  "summary": {
    "total_line_threads", "total_general_comments", "total_reviews",
    "files_with_feedback": ["path/...", ...],
    "line_thread_status_counts": { "fixed": 3, "open": 1, ... }
  }
}
```

The script has already classified each thread. Trust its `resolution.status` when `resolution.confidence == "high"`. When `"low"`, verify by reading the thread's `messages` yourself — that is the case where the script could not tell from regex alone.

## Step 2: Match findings against threads, conservatively

For each candidate finding the surrounding review produces:

1. **Look up the file in `threads_by_file`**. If absent → no prior match. Keep the finding as-is.
2. **If file present, look for threads with `|line - finding.line| ≤ 5`**. If none → no prior match. Keep as-is.
3. **For each near-line thread, judge semantic match**. The thread's `topic_hint` and last few `messages` tell you what it was about. Match on *concept*, not wording: "function panics on nil" matches "what if slice is nil here?" even though phrasing differs. **When uncertain whether a finding and a thread are about the same concept, treat as no match** (keep the finding).

Only proceed to Step 3 if all three of these hold: same file, line within ±5, semantic match strong.

## Step 3: Decide drop vs keep (bias hard toward keep)

Drop the finding **only if** the matched thread satisfies *all* of:
- `resolution.status` is one of `fixed`, `intentional`, or `deferred`, **AND**
- `resolution.confidence == "high"`, **AND**
- For `fixed` specifically: you have *also* verified the latest commits address the concern. (Read the relevant code; do not just trust the "fixed in <sha>" claim.)

Every other combination → keep the finding. Specifically:
- `resolution.status == "open"` (PR author never replied) → keep
- `resolution.status == "disputed"` → keep (add evidence either way)
- `resolution.status == "unclear"` (low confidence, short author reply) → keep
- `confidence == "low"` regardless of status → keep
- `fixed` with `high` confidence but commits do not actually address it → keep, but reframe (see Step 4)

This is intentionally conservative. The cost of a duplicate post is a single line on a PR. The cost of dropping a real bug is invisible until it ships.

## Step 4: Frame the surviving findings

How you write the comment depends on what Step 3 determined:

- **Net-new finding** (no matching thread): assert it directly, the standard way.
- **Concurring with an unaddressed prior concern** (matched a status=`open` thread): cite the earlier reviewer. Example: *"still applies — concurring with @babakks's comment on agent_task_test.go:140; the latest commits removed the test in question but moved the same assertion to line 92"*. This adds evidence without claiming the idea.
- **Refining a disputed thread**: bring new evidence the thread did not have. Do not repeat what was already said.
- **Fixed-but-incomplete** (status=`fixed`, but you verified the fix is partial): *"the fix in {sha} addresses {Y} but leaves {X} — same symptom on this new line"*.
- **Same author, second look**: if you (the reviewing model) already left a comment on this PR earlier and the new commits do not address it, your reframe is *"my earlier comment at {url} still applies; the changes in {commit} address {Y} but not {X}"*.

When posting to GitHub, prefer the right channel:
- A net-new structural concern → top-level PR comment (`gh pr comment`)
- A reply to an existing open thread → reply to that thread (`gh api ... /pulls/{N}/comments/{id}/replies` if the surrounding tooling supports it; otherwise quote the thread in a top-level comment).

## Step 5: Surface and log every suppression (mandatory)

The skill is invisible without this step. Two outputs per suppression:

**5a. User-facing report section** — always include in the review report you return to the user, even if empty:

```markdown
### Suppressed findings (pr-comment-aware-review)
- `agent_task.go:25` — semantic match to @babakks's thread (status=fixed, confidence=high, evidence: "Actually, fixed in 2128a297…"); verified latest commits address it.
- `agent_task_test.go:44` — semantic match to @babakks (status=fixed); verified.

(or, if nothing was suppressed:)

### Suppressed findings (pr-comment-aware-review)
None — no candidate findings matched existing PR threads.
```

For each suppressed finding, include: the file:line where you would have flagged, the matched thread reference (author + status + brief evidence), and *whether you verified* the fix in code (required for any status=fixed drop).

**5b. Append a structured record to the suppressions log.** For every drop *and* every reframe, call:

```bash
~/.claude/skills/pr-comment-aware-review/scripts/log-suppression.sh '<json>'
```

Required fields:

```json
{
  "action": "dropped | reframed-concur | reframed-still-applies | fixed-but-incomplete",
  "pr_url": "https://github.com/owner/repo/pull/N",
  "finding": {"file": "...", "line": 27, "summary": "<one short sentence>"},
  "matched_thread": {"html_url": "...", "author": "...", "status": "...", "confidence": "...", "evidence": "<excerpt that drove the decision>"},
  "review_context": "code-review | pr-intent-review | review-pr | code-reviewer-agent | ad-hoc"
}
```

For `action: "dropped"` with a `fixed` thread, also include the verification claim:

```json
"verification": {"checked_sha": "2128a297…", "verdict": "confirmed | partial | none", "note": "<what you checked>"}
```

Why log: the rubric in this skill is an opinion, not a proof. It will be wrong sometimes. The log is the feedback channel that lets us notice. Periodic review of entries answers "is the dedup overdropping (real bugs lost) or underdropping (noise that should have been caught)?" — and feeds back into rubric tightening or eval data.

Log file: `~/.claude/logs/pr-comment-aware-review/suppressions.jsonl` (append-only JSONL, one record per line). The helper enriches each record with timestamp, skill_version, and pid context.

## What this skill is NOT

- **Not a substitute for reading the code.** Existing comments tell you what was *said*, not what is *true*. A reviewer may have been wrong; a "fixed" reply may have been optimistic. The Step 3 verification requirement is there for this reason.
- **Not a way to skip findings.** If a real bug exists and no one mentioned it, file it — even if other reviewers approved.
- **Not for non-PR contexts.** Project-wide audits (`/holistic-review`), local pre-commit review on solo branches, and design reviews do not need this.

## How orchestrators should invoke this skill

For commands that orchestrate multi-agent reviews (e.g. `/pr-intent-review`, `/code-review:code-review`, `/pr-review-toolkit:review-pr`):

1. **Early — before any review subagent starts**: run the script once at the orchestrator level. The 5-minute `/tmp` cache means subagents that re-invoke the script will get the same result for free. Pass the relevant slice (filtered to the files each subagent is reviewing) to that subagent's prompt.
2. **Late — after subagents return findings, before posting**: apply Step 2 + Step 3 across the aggregated findings, then write the mandatory Step 5 suppressed-findings section.

For leaf agents (e.g. the `code-reviewer` agent doing a `git diff` review): run the script once if a PR exists for the current branch; apply Steps 2–5 inline as you form findings.

The deterministic fetch + thread reconstruction + signal detection live in the script. The judgment (semantic match + drop/keep decision + framing) lives in this rubric.
