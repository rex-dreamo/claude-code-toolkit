---
name: review-suppressions
visibility: public
description: Use to audit whether pr-comment-aware-review's drop and reframe decisions were right. Reads recent entries from ~/.claude/logs/pr-comment-aware-review/suppressions.jsonl, fetches each PR thread and current code state, presents an audit card per entry, and captures human verdicts to verdicts.jsonl. Trigger on natural-language asks like "audit my recent suppressions", "review the dedup decisions", "did pr-comment-aware-review drop anything wrong", "check whether the skill missed real bugs", or periodic invocations. Without this read-side the dedup rubric is frozen with no learning channel — the suppression log piles up unread and the skill cannot improve from production.
---

# Review suppressions

## Why this exists

The `pr-comment-aware-review` skill drops PR-review findings it judges to be duplicates of comments the PR already received. Each drop (and each reframe) is written as a structured record to `~/.claude/logs/pr-comment-aware-review/suppressions.jsonl`. The log exists specifically so those decisions can be audited later.

This skill is the read side of that promise: sample recent entries, re-fetch the PR thread and the code as it stands today, ask the human whether each decision was right, capture the verdicts as data. Without it, every drop is a one-way decision and the rubric in `pr-comment-aware-review/SKILL.md` is frozen at whatever felt right when it was written.

The verdicts file built up by this skill is the corpus from which future rubric refinements will be drawn. v1 just gathers the data; rubric editing is a separate, later move that earns its weight only once there is enough evidence to act on.

## When this skill applies

| Situation | Use this skill? |
|---|---|
| User asks to audit recent suppressions | Yes |
| User wants to spot-check one specific drop | Yes (sample N=1 or filter by PR) |
| Suppression log does not exist or is empty | No-op silently — print "no suppressions to audit" |
| User invokes `/review-suppressions` directly | Yes |
| Periodic self-check after several PR reviews | Yes — encourage on a weekly cadence |
| User wants the skill to act on the verdicts and edit the rubric | **No.** This skill only captures verdicts. Rubric editing is out of scope until verdicts.jsonl has ≥10 rows and a separate decision is made. |

If `gh` is not installed, not authenticated, or the suppressions log is missing, the script exits quietly and the surrounding session proceeds.

## Step 1: Sample recent entries

Run the bundled script. It does *all* of: read last N entries, parse the PR URL + comment ID, fetch PR state, fetch the current thread comment (if any), fetch the file as it stands at the merge-or-head sha, slice ±5 lines of context around the cited line.

```bash
~/.claude/skills/review-suppressions/scripts/sample.sh        # default N=5
~/.claude/skills/review-suppressions/scripts/sample.sh 10     # last 10
```

Output is a JSON array of audit cards on stdout. Empty array if the log is empty.

Each card joins:

```json
{
  "suppression":     { "...the original record from suppressions.jsonl..." },
  "pr_current":      { "state": "open|closed", "merged": true|false },
  "current_thread":  { "...gh api comment response..." } | null,
  "current_code":    {
    "ref": "<merge_commit_sha or head sha>",
    "sha": "<file blob sha at that ref>",
    "context_lines": "<line-numbered ±5 lines as a single string>",
    "cited_line_text": "<the exact line at finding.line>"
  } | null
}
```

`current_thread` is null if the suppression record lacked an `html_url` (typical for reframe-still-applies entries) or if the comment was deleted upstream. `current_code` is null if the PR's ref is unresolvable or the file was deleted.

## Step 2: Present each card to the human

For each card, surface in this order:

1. **The finding I would have raised** — `<file>:<line>` — `<suppression.finding.summary>`
2. **The thread I matched** — by `<matched_thread.author>`, status=`<status>` (confidence=`<confidence>`), evidence: "`<evidence>`". If `html_url` present, include the link.
3. **My verification at suppression time** (only when `action == "dropped"` and `verification` present) — "checked sha `<verification.checked_sha>`; verdict=`<verification.verdict>`; note=`<verification.note>`"
4. **The code as it stands today** — show `current_code.context_lines`. Highlight `current_code.cited_line_text`. Note that line numbers may have shifted since the suppression was recorded.
5. **PR state today** — `pr_current.state` / merged=`pr_current.merged`. If merged, the verification target was the merge commit; if still open, it was the latest head.
6. **Action taken at suppression time** — `<suppression.action>` (`dropped` / `reframed-concur` / `reframed-still-applies` / `fixed-but-incomplete`).

Keep the rendering compact — one tight block per card, not a wall of JSON. The user needs to scan quickly to judge each one.

## Step 3: Ask for one verdict per card

For each card, ask the human to pick exactly one verdict:

- **`right_drop`** — the cited fix did address the finding. Drop was correct.
- **`wrong_drop`** — the cited fix does not actually address the finding. A real bug was lost.
- **`right_but_for_wrong_reason`** — the symptom is gone but for a different reason than the matched thread claimed. Brittle: a future change to the unrelated cause could regress.
- **`unclear`** — needs deeper inspection than this audit pass can support.

Always offer a brief free-text `reason` field. Even one sentence per verdict is useful corpus.

For `reframed-*` actions, adapt the verdict semantics:
- `right_drop` → "the reframe added the right evidence"
- `wrong_drop` → "the reframe missed the point the prior reviewer made"
- `right_but_for_wrong_reason` → "the reframe was correct but the framing oversold it"

## Step 4: Record each verdict

For every card the human verdicts, call:

```bash
~/.claude/skills/review-suppressions/scripts/record-verdict.sh '<json>'
```

Required shape:

```json
{
  "verdict": "right_drop | wrong_drop | right_but_for_wrong_reason | unclear",
  "suppression_ref": {
    "pr_url": "<from the suppression record>",
    "file":   "<from suppression.finding.file>",
    "line":   "<from suppression.finding.line>",
    "ts":     "<from suppression.ts — pinpoints which suppression in case the same file:line was suppressed twice>"
  },
  "reason": "<one short sentence — why this verdict>"
}
```

The script enriches with `audit_ts`, `skill_version`, `_pid`, `_ppid` and appends one JSON line to `~/.claude/logs/pr-comment-aware-review/verdicts.jsonl` (flock-protected). One verdict per card.

## Step 5: Closing tally

After all cards are verdicted, print a short summary:

```
Audited N entries on YYYY-MM-DD:
  right_drop:                 X
  wrong_drop:                 Y
  right_but_for_wrong_reason: Z
  unclear:                    W

Logged to ~/.claude/logs/pr-comment-aware-review/verdicts.jsonl.
```

If any `wrong_drop` verdicts were captured, append a one-line nudge: "consider posting the wrong-dropped findings manually to the original PRs if still applicable."

**Do not** edit `pr-comment-aware-review/SKILL.md` from this skill. Rubric tightening is a separate, deliberate move that should wait for ≥10 verdicts and explicit user instruction.

## What this skill is NOT

- **Not an automatic rubric updater.** The verdicts file is data; rubric edits are a separate human decision.
- **Not a way to re-post the dropped finding silently.** If `wrong_drop`, surface that fact so the user can decide whether to comment on the PR manually.
- **Not for PR review itself.** This is meta — reviewing the previous reviewer (the `pr-comment-aware-review` skill).
- **Not for suppressions written by other tools.** Only operates on `~/.claude/logs/pr-comment-aware-review/suppressions.jsonl`.

## Future moves this enables

Once verdicts.jsonl has enough rows (rough threshold: 10), patterns will surface:

- "drops with `status=fixed` + commit-hash evidence are nearly always right" → tighten the rubric to require less verification on those
- "drops with `status=intentional` are wrong N% of the time because the model conflated different concerns" → require the model to verify semantic match more carefully on intentional threads
- "reframes-still-applies are uniformly right when based on `status=open` threads" → confirm and codify

That analysis lives in a *future* skill — possibly `tighten-dedup-rubric` — not in this one.
