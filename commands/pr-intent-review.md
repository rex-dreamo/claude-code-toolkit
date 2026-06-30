---
allowed-tools: Bash(gh issue view:*), Bash(gh search:*), Bash(gh issue list:*), Bash(gh pr comment:*), Bash(gh pr diff:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh api:*), Bash(gh pr checkout:*)
visibility: public
description: Purpose-aligned PR review — model the PR's stated intent first, then audit whether all changes (and untouched artifacts) serve it.
disable-model-invocation: false
---

Review a pull request for **alignment between stated intent and actual implementation**, not just for code-level bugs. The motivating premise: most code reviews default to bug-hunting on the diff, which is good for catching logic errors but blind to *drift* — dead files left after a deliberate removal, docs that claim something the code no longer does, half-finished cleanups, contradictions between commit-message intent and surviving artifacts. Drift bugs typically live on lines the PR did *not* touch, so they slip past a diff-scoped reviewer. This review flips the order: build an intent model first, then audit the artifact state (changed *and* unchanged) against it.

Follow these steps precisely:

1. **Eligibility** (Haiku agent): check if the PR is (a) closed, (b) draft, (c) clearly trivial / automated, or (d) already has an intent-review comment from you. If so, stop.

2. **Context gathering**: do two things in parallel.

   a. Haiku agent — return file paths (no contents yet) for:
   - The root `CLAUDE.md`, if present
   - Any `CLAUDE.md` files in directories the PR touches
   - Any folder-level context docs (`*.md` matching the folder name — e.g., `src/checkout/checkout.md`) in directories the PR touches
   - Any docs explicitly referenced from the PR title/body or commit messages (e.g., "see checkout.md:194")

   b. Invoke the **`pr-comment-aware-review`** skill to fetch the existing-feedback map (all prior comments, reviews, and review-comments on the PR). The skill bundles the dedup rubric for later steps. Cache its output for steps 3, 4, and the final post.

3. **Intent extraction — the core of this review** (Sonnet agent): produce a structured intent model. The agent must read:
   - PR title + body
   - **Every commit message on the branch** (not just the latest) — drift often hides between commits
   - The full diff (for what was actively changed)
   - The context docs from step 2a, especially lines the diff also modifies (those edits *are* declarations of intent)
   - **The existing-feedback map from step 2b.** Comment threads are an active *intent surface* (above and beyond dedup): when a reviewer asks "is X intentional?" and the author confirms, that's an explicit out-of-scope declaration carrying the same weight as a commit message. When the author replies "will address in follow-up", that's deliberately punted scope. Fold these into the intent model.

   The output must be a short structured doc with these sections:
   - **Stated goal**: 1-2 sentences on what this PR is trying to accomplish
   - **Things being added**: new behaviors, files, APIs the PR introduces
   - **Things being removed / deprecated**: behaviors, files, APIs, symbols the PR is deliberately taking out — quote the exact words from commits or docs that establish this intent
   - **Things explicitly out-of-scope**: anything the PR or its docs say is deliberately not addressed (these are *not* findings — respect them)
   - **Doc claims**: every assertion made in the PR's doc changes that the code is now expected to satisfy (e.g., "telemetry is intentionally excluded" → code must contain no live wiring for telemetry)

4. **Alignment audit** (4 parallel Sonnet agents — each takes the intent model from step 3 and the existing-feedback map from step 2b as input. Apply the dedup rubric from the `pr-comment-aware-review` skill as you go: skip findings already raised in a prior comment unless the latest commits visibly fail to address them):

   a. **Agent A — Removal completeness**: For every "thing being removed / deprecated" in the intent model, search the *entire codebase* (not just the diff) for surviving artifacts. Include:
      - String references to removed symbols/files
      - For Unity projects: **GUID references** in `.meta` files, prefabs, ScriptableObjects (Unity refs are GUID-based; a name-only grep gives false negatives)
      - Doc lines describing the removed behavior as if still alive
      - Comments / asset descriptions that "self-advertise" wiring that no longer exists (these are time bombs — future devs grep them and revive the dead path)

      **Drift findings on files the PR did not touch are valid.** The whole point of this agent is to catch them.

   b. **Agent B — Addition coherence**: For every "thing being added" in the intent model, verify the diff actually implements it end-to-end. Look for half-finished implementations: a new method declared but no call site, a new field saved but never read, a new doc section claiming a feature whose code is still TODO.

   c. **Agent C — Doc vs. code consistency**: For every "doc claim" in the intent model, verify the code actually satisfies it. Doc-as-spec: if a doc the PR updates says "X is no longer called from Y", grep for the call. If a doc says "this method always returns Z when W", read the method.

   d. **Agent D — Conventional bug scan (secondary)**: Standard logic/bug check on the diff. Kept here so we don't regress on bug-finding, but treated as supplementary, not primary. Same false-positive filters as a normal review (linter-catchable, pre-existing, pedantic style, intentional behavior change).

5. **Confidence scoring** (parallel Haiku agents — one per issue from step 4). Score 0-100:
   - **0**: False positive. Doesn't survive light scrutiny, or is pre-existing, or contradicts intent that this agent missed.
   - **25**: Plausible but unverified. Couldn't confirm whether the artifact is actually dead, or whether the doc claim is actually violated.
   - **50**: Verified real, but minor. The drift exists but the practical impact is small (e.g., a comment that's slightly out of date but harmless).
   - **75**: Verified real and consequential. A future developer grepping this artifact would likely reach a wrong conclusion, or the inconsistency could cause a regression. **Drift in files the PR didn't touch belongs here when intent says they should have been touched.**
   - **100**: Direct contradiction with the PR's own stated intent. The PR claims X is removed; X is still present and referenced.

6. **Filter**: drop issues scored below 75, then apply the `pr-comment-aware-review` skill's dedup rubric one more time across the survivors (the agents in step 4 already filtered as they went; this is a belt-and-suspenders pass over the aggregated set). If nothing remains, stop.

7. **Re-check eligibility** (Haiku agent, same as step 1) — PR state may have changed during the review.

8. **Post the comment** using `gh pr comment`. Format:

---

### PR intent-alignment review

**Stated intent** (extracted from PR body + commits + docs): <1-2 sentences>

Found <N> alignment issues:

1. **<type>: <short description>** — <why this contradicts the stated intent; quote the intent source: "[commit X says] / [docs/foo.md:NN says]">

   <link to the offending artifact with full SHA + line range>

2. **<type>: <...>** — <...>

   <link>

`<type>` is one of: `drift` (artifact survives a documented removal), `incomplete` (claimed addition is half-implemented), `doc-vs-code` (doc and code disagree), `bug` (conventional logic issue).

🤖 Generated with [Claude Code](https://claude.ai/code) — purpose-aligned review

<sub>If this caught something a normal review wouldn't have, react with 👍. If it was noise, react with 👎.</sub>

---

If no issues remain after filtering:

---

### PR intent-alignment review

**Stated intent**: <1-2 sentences>

No alignment issues found. Audited: removal completeness, addition coherence, doc/code consistency, secondary bug scan.

🤖 Generated with [Claude Code](https://claude.ai/code) — purpose-aligned review

---

**Important rules** (these differ from a conventional review):

- **Files the PR did not touch can be valid finding sites.** A normal review treats "issue on an unmodified line" as a false positive; this review does not, as long as the issue contradicts an intent the PR did declare. The prototype case: a feature's asset/file survives in the tree even though a doc the PR edits declares that feature deliberately removed — the dead artifact lives on an untouched line, so a diff-scoped reviewer never sees it.
- **Quote the intent source.** Every finding must cite the commit message, doc line, or PR-body sentence that establishes the intent it contradicts. No intent source → not a valid finding; downgrade or drop.
- **Respect explicit out-of-scope declarations** wherever they appear — commit message, doc, or comment-thread reply. If the PR author said "intentional" / "will address in follow-up" in *any* of those, treat X as out-of-scope. The `pr-comment-aware-review` skill formalizes this for thread replies.
- **For Unity projects: always GUID-check.** Asset references in prefabs / ScriptableObjects / scenes use GUIDs from `.meta` files, not names. A name-only grep misses real references and misses duplicate-GUID problems (two `.meta` files with the same GUID is a silent hazard). Read the `.meta`, grep the GUID.
- **Do not run builds / typechecks / tests.** CI handles those; they are not the focus here.
- **Link with full SHA + line range**, format: `https://github.com/<owner>/<repo>/blob/<full-sha>/<path>#L<start>-L<end>` (≥1 line of context each side). The full SHA is required for Markdown rendering — `$(git rev-parse HEAD)` shell substitution does not work inside the eventual comment body.

Make a todo list before starting. Cite and link every finding.
