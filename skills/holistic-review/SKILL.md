---
name: holistic-review
visibility: public
description: Zoom out and review a project comprehensively — architecture, structural overlaps, drift, gaps, inconsistencies — AND propose creative, fundamental improvements. This is both a backward-looking audit (what's wrong?) and a forward-looking vision (what could this become?). Use when the user signals an altitude shift — phrases like "review the project deeply", "any overlap or duplication?", "step back", "look at the whole thing", "audit", "structural review", "am I missing anything?", "what's the big picture?", "any creative ideas to fundamentally improve this?", "if you redesigned this from scratch, what would change?", or after a focused work session ends and the user wants a higher-altitude assessment. Do not skip this skill just because you've already reviewed code in the session — focused review and holistic review serve different purposes and surface different issues. Always include both critique AND creative reframes; an audit without vision misses half the value.
---

# Holistic Project Review

A microscope view fixes typos. A bird's-eye view finds the wrong abstraction — and sees what the project could become. This skill is for both.

## Why this exists

When Claude reviews code in normal flow, it tends to stay near the cursor — read the files mentioned, fix what's visible, miss structural patterns that only become obvious from altitude. That's appropriate for focused work but useless when the user actually wants strategic assessment.

The structural issues that matter most — repeated logic across N files that should be one, hierarchies that look like duplication but aren't, gaps that only appear when you compare the project's parts to each other — are invisible from microscope altitude. They emerge only when you stop looking at the lines and start looking at the shape.

But finding issues is only half the job. The other half is **vision**: what does this project look like reframed? What single architectural shift would collapse five separate problems into one? What would a future version of this — built knowing what you know now — look different about? A holistic review that only critiques is a checklist; one that also imagines is a partnership.

This skill encodes both postures so the user doesn't have to ask twice.

## Process

### Step 1: Map before diving

Before reading any specific file in detail, build an index. The point is to fight the impulse to dive into the first interesting file.

- List the top-level structure (`ls`, `tree -L 2`, etc.)
- Identify components, languages, and entry points
- Identify the layers (CLI / library / config / tests / docs / scripts / agents / hooks / etc.)
- Note naming patterns — and pattern violations

State the topography back to the user in 2–3 sentences before going further. This both forces you to actually look and gives the user a chance to correct your mental model.

### Step 2: Sweep the categories

Walk through these categories explicitly. For each, scan the project for instances. Don't go deep on any one yet — collect candidates first.

| Category | What to look for |
|---|---|
| **Redundancy** | Multiple things doing the same job |
| **Duplication** | Byte-identical or near-identical files |
| **Drift** | Same concept implemented in N places that have diverged |
| **Missing pieces** | Tests that don't exist; component with no error handling; logs unstructured; no docs for non-obvious flows |
| **Inconsistency** | Naming/conventions/patterns varying without reason |
| **Coupling** | Things that should be independent but cross-reference |
| **Stale code** | Leftover from a previous design — dead exports, commented-out blocks, unimported files |
| **Missing layer** | Project has CLI + lib but no integration tests; has agents but no docs about which to pick when |

This sweep is shallow on purpose. Going deep on the first redundancy you find means missing the other six categories.

### Step 3: Distinguish intentional from accidental

This is the most important step. Surface similarity does not mean semantic duplication.

Before flagging something as a problem, ask:

- **Is this a generalist-vs-specialist hierarchy?** (e.g. global `code-reviewer` + project `unity-conventions-reviewer`). Healthy, not redundant — the generalist is a portable fallback, the specialist is the deep expert when you're in that project.
- **Is duplication a feature?** (e.g. independent project copies meant to drift). The cost of unification (loss of independence) might exceed the cost of duplication.
- **Is "missing" actually "intentionally absent"?** (e.g. a one-off script with no tests because the cost of testing exceeds the cost of bugs).

When in doubt, **read the actual content** — not just descriptions or filenames. The classic mistake: two agents look like duplicates by their one-line descriptions, but reading the bodies reveals one of them is a Korean-language specialist with extraction patterns the other lacks. Surface similarity ≠ semantic duplication.

### Step 4: Categorize findings

Each finding goes into one of four buckets:

- **🔴 Fix recommended** — clear improvement, low risk, high impact
- **🟡 Design decision** — looks like an issue but the user may have intended it; surface for confirmation
- **🟢 Healthy pattern** — superficially looks like a smell but is actually fine; record so future-you doesn't re-flag it
- **🔵 Open question** — needs user judgment

Each finding includes: what + where (concrete file paths), why it matters (or why it's actually fine), and a proposed action or a question for the user.

### Step 5: Order by leverage, not by category

Don't dump findings under headers in the order you found them. Lead with the highest-leverage one — the fix that ripples through the most other things. Then work down.

If two findings have similar leverage, prefer the one with lower implementation risk.

### Step 6: Creative ideation — what could this become?

Auditing alone produces a checklist. Vision produces a partnership. After categorizing what's *wrong*, do a separate pass asking what's *possible*.

Three prompts to drive this pass — work through each, even if briefly:

1. **The collapse question.** Look at your 🔴 findings. Is there a single architectural shift that would make multiple of them disappear at once? (Example: five separate verifier agents → one parametric verifier with declarative checks per container.)

2. **The fresh-start question.** If you started this project today, knowing what you know from reading it, what would be structurally different? Not "would I do X better" — "would the *shape* be different?" (Example: a tier system of "global generalist + project specialists" might become "one configurable agent with project-aware policy injection.")

3. **The 10× question.** What would 10× the current scope look like? If the project supported 10× the projects, 10× the users, 10× the deploy targets — what breaks? The thing that breaks first is often the hidden architectural assumption worth surfacing now.

Creative ideas should be:

- **Concrete** — "make it more extensible" is bikeshedding; "replace the per-project agent dirs with a single config file declaring which rules apply" is a reframe.
- **Anchored in the actual project** — not generic advice (e.g. "consider microservices"), but ideas that reference the project's specific constraints, files, and naming.
- **Honest about cost** — every reframe has a price (migration effort, risk of regression, learning curve). State the price.
- **Optional from the user's view** — these are *possibilities*, not recommendations. The user decides what's worth pursuing.

If after honest effort no creative reframe emerges, say so explicitly: "No fundamental reframe surfaced — the current architecture appears well-fitted to the constraints." Don't fabricate vision for the sake of completeness.

## Output template

Use this structure. Adjust headings to fit but keep the shape.

```markdown
## Holistic Review: <project>

### Project topography
<one short paragraph: shape, components, layers>

### Findings

#### 🔴 Fix recommended
1. **<short title>** — <one sentence: what + where>
   - Evidence: <file paths, line numbers>
   - Why it matters: <impact>
   - Proposed action: <one sentence>

#### 🟡 Design decision (confirm with user)
<same shape>

#### 🟢 Healthy pattern (do not re-flag)
<same shape — recorded so the next holistic review doesn't waste time on these>

#### 🔵 Open questions
<same shape>

### 💡 Creative possibilities (vision)

What this project could become if reframed. Each one cites:
- The reframe (one sentence)
- What it would collapse / unlock (impact)
- The honest cost (migration effort, risk, learning curve)

These are possibilities, not recommendations. The user decides which to pursue.

If no fundamental reframe surfaces, say so explicitly — don't fabricate vision.

### Top 3 actions, ordered by leverage
1. <highest leverage — usually a 🔴 fix or a small 💡 reframe with low cost>
2. ...
3. ...

### What I deliberately did NOT flag (include only if non-trivial)
<short list of surface-similarities that turn out to be intentional, one sentence each — saves the user from second-guessing whether you considered them>
```

The "did NOT flag" section is a feature when there *are* obvious patterns the user might wonder if you considered (especially after a related focused review, or on larger projects where adjacent looking-alike things are common). Skip it on small projects where there's nothing meaningful to record — filler hurts.

## Anti-patterns

These are mistakes from past holistic reviews. Avoid them.

- **Microscope drift** — getting pulled into fixing one specific thing in detail mid-review. If you're reading the body of one function for the third time, zoom out.
- **Surface similarity = duplication** — flagging two things as duplicate based on names or descriptions without reading the bodies.
- **Mass-change recommendation** — "rename all 47 files for consistency" is rarely the right answer; pick the highest-leverage fix and stop.
- **Confidence theater** — listing 30 findings to look thorough. 3 well-sorted findings beat 30 unsorted ones.
- **Recommending changes the user will reject** — if a duplication is intentional (project independence, language specialization, etc.) and unification has real costs, do not recommend unifying. Accept the duplication and document why.
- **Bikeshed creativity** — proposing vague, generic reframes ("consider event-driven architecture", "make it more modular"). Creative ideas must be specific, anchored in the project's files and constraints, and honest about cost. If you can't be specific, omit the section.
- **Audit without vision** — listing 8 things wrong without proposing a single forward-looking reframe. The user asked for both halves; deliver both.
- **Vision without audit** — jumping straight to "you should rebuild X" without first showing you understand the current shape. Creative reframes earn their weight only after the topography step grounds them.

## Mode reminder

If you started this review in microscope mode (because the conversation up to this point was focused), explicitly switch modes:

> "Switching to holistic mode. I'll set aside the current task and look at the whole project."

State it. Then do the topography step. The verbal switch helps prevent silently drifting back to microscope.
