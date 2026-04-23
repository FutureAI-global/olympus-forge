---
name: two-claude-review
namespace: session-lessons
version: 0.1.0
description: |
  Enforceable implementer-reviewer protocol. Before a ship-candidate PR merges:
  implementer self-grades P0-P8 with file:line evidence per row, then an
  independent Claude agent (cold context) re-runs every verifiable claim and
  produces a delta-tagged reviewer grade. Block on any P0-P4 grade below A-.
  Rejects rubber-stamps.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Agent
  - AskUserQuestion
---

# two-claude-review · implementer + independent reviewer protocol

## Why this exists

Empirical basis: a single session made 3 consecutive false "tsc clean" claims across 3 self-directed cycles in April 2026. Independent cold-context review would have caught it on cycle 1. CLAUDE.md codified this as the Two-Claude Review Protocol — this skill operationalizes it.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag two-claude-review --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

Fire when ALL of:

1. A PR is about to be marked ready-to-merge, OR
2. Self-grade table is posted

AND any of:
- PR modifies `src/` / `backend/` / `services/` / any production path
- PR ships behind a feature flag
- PR adds ≥50 LOC
- PR edits a system prompt / tool manifest / safety case / capability-gated config

**Skip for** (per CLAUDE.md):
- Typo-only doc fixes
- Single-variable rename ≤3 files no behavior change
- Test-only import swaps

Voice triggers: "two claude review", "independent review", "second set of eyes", "2c review".

## Workflow

### Phase 1 · Implementer self-grade

Implementer posts a P0-P8 table with file:line evidence per row:

```
| Principle | Grade | Evidence | Gap |
|---|---|---|---|
| P0 Safety | A | No cap-eval triggered | — |
| P1 Correctness | A- | tsc clean <output>; 6/6 jest <output> | CLI smoke untested |
| P2 Failure modes | A | Handler catches 401/403/timeout | — |
| P3 Observability | A | <metric-name> wired at <file:line>; `curl /metrics` cited | — |
| P4 Reversibility | A | Single-commit revert | — |
| P5 Intent | A | Named fns match behavior | — |
| P6 Min abstraction | A | +29 LOC across 3 files; no framework | — |
| P7 Security | A | No trust-boundary change | — |
| P8 Cost | A | Zero inference cost | — |

Overall: A-. Author self-assessment.
```

**Rules:**
- Overall grade = min across rows
- Any F on any row = STOP, don't ship
- Missing evidence bounds P1 at A-
- Tests authored but not run → P1 ≤ A-

If self-grade is < A-, remediate first. Don't request review on a B+ self-grade.

### Phase 2 · Reviewer (cold context)

Spawn a fresh Claude agent via the `Agent` tool with `subagent_type: "general-purpose"`. The reviewer gets:

- The PR diff (via `gh pr diff <num>`)
- The commit message
- The implementer's self-grade table
- Links to relevant INVARIANTS.md entries
- NO access to the implementer's conversation transcript

Prompt template:

```
You are conducting an independent Two-Claude review per CLAUDE.md Section X. The
implementer posted this self-grade table:

[implementer table]

Your job:
1. Read the diff at <url-or-path>
2. RE-RUN every verifiable claim:
   - If implementer claims "tsc clean": run `npx tsc --noEmit` yourself, cite output
   - If implementer claims "tests pass": run the test command yourself, cite output
   - If implementer claims "metric emits": grep for the metric + find the call site
   - If implementer claims "bundle grep shows X": grep yourself
3. Produce a reviewer-grade table with the SAME rows as implementer's.
   For each row, output: reviewer-grade + delta from implementer.
4. If reviewer-grade < implementer-grade on any P0-P4 principle, BLOCK.
5. If reviewer-grade = implementer-grade across all rows, GREEN.
6. Report deltas explicitly. Do NOT implement fixes yourself (breaks independence
   on the next cycle).

Constraints:
- Read the diff, not the narrative. The implementer may have inflated.
- Flag specific false claims by quoting the implementer's text.
- Grade the DIFF against the P0-P8 rubric, not the author's intent.
```

### Phase 3 · Reviewer posts delta

Reviewer outputs:

```
## Two-Claude review · delta table

| Principle | Implementer | Reviewer | Delta |
|---|---|---|---|
| P0 | A | A | — |
| P1 | A- | B+ | ⬇ CLI smoke not run; I ran it, 2 bugs caught |
| P2 | A | A | — |
...

Overall implementer: A-
Overall reviewer: B+ (bounded by P1 after re-running smoke)

Findings:
- [specific false claim] the implementer claimed "tsc clean" but running
  `backend/node_modules/.bin/tsc --noEmit src/...` returns 3 errors (output below)
- [specific gap] metric `X` declared but has zero non-test callers per
  `grep -rn X backend/src/ | grep -v __tests__`
- [missing coverage] integration test for Y absent; P1 capped at A-

Verdict: BLOCK on P1 < A-. Implementer fix + repost.
```

### Phase 4 · Disposition

Three outcomes:

- **GREEN (no delta or reviewer ≥ implementer):** ship
- **RED (reviewer < implementer on any P0-P4):** implementer remediates, reposts self-grade, reviewer re-runs
- **DISPUTE (implementer disagrees with reviewer finding):** escalate to user (Lee) for call

### Phase 5 · Capture as lesson

Every review — regardless of outcome — appends to `learnings.jsonl`:

```json
{
  "skill": "two-claude-review",
  "pattern": "<implementer-grade> vs <reviewer-grade> delta on <principle> for PR #<num>",
  "evidence": "<specific false claim or missing check>",
  "fix": "<what implementer did to close>",
  "tags": ["inflation", "<principle>", "<stack-tag>"]
}
```

Over time the aggregator identifies sessions that systematically inflate on specific principles (e.g., "Session X consistently over-grades P1 by 0.5 letters"). That finding hoists as an invariant.

## Reviewer rules (strict)

- **Cold context.** Reviewer MUST NOT have access to the implementer's conversation. Only the diff + commit + self-grade.
- **Re-run every verifiable claim.** Grep isn't enough — actually execute `tsc`, `jest`, `curl`.
- **Grade the DIFF, not the narrative.** The PR description may inflate; the diff is what ships.
- **Name false claims in specific language.** "I ran X and got Y; implementer claimed Z" — not "I disagree on P1."
- **No rubber-stamps.** If the implementer's grade is A, either you give A with evidence OR you give < A with delta. Never "looks good."
- **Do NOT implement fixes yourself.** That breaks independence on the next cycle; let the implementer repost.

## Implementer rules (strict)

- **Self-grade honestly.** Inflation = rejecting the honesty tax = CLAUDE.md anti-pattern #22.
- **Run the check before you claim it.** `/verify-before-claim` is the first-line defense.
- **Acknowledge reviewer feedback, don't defend.** "I was wrong about X, here's the updated grade."
- **Bundle fixes into one 'round N ready' post.** Don't spam the reviewer with per-finding replies.

## Exceptions

- **Solo-author emergency:** ship with `SELF-REVIEWED` tag in the PR body; retroactive review within 24h.
- **Trivial test-only changes:** skip per the "Skip for" list above.

## Seed lessons

1. **Implementer inflated B+ to A-** · P0 · generic
   - Evidence: PR #1406 "self-graded A-" was "honestly B+ per my remediation loop"
   - Fix: run `/verify-before-claim` BEFORE posting the self-grade

2. **Self-grade tsc-clean shipped with runtime bugs** · P0 · generic
   - Evidence: PR #1534 tsc clean but 2 runtime bugs caught only in e2e run
   - Fix: integration test in CI before merge, not tsc alone

3. **Reviewer rubber-stamped without re-running** · P1 · generic
   - Evidence: "LGTM" on PR with unrun tests → bugs shipped
   - Fix: reviewer MUST cite specific test outputs; "LGTM" alone is insufficient

4. **Cold-context broken by agent with prior state** · P1 · generic
   - Evidence: reviewer agent had lingering memory of implementer's narration → biased
   - Fix: spawn via `Agent` tool with a fresh prompt; never via conversation continuation

5. **Implementer defended inflated grade, wasted review cycle** · P2 · generic
   - Evidence: 2 rounds of "but I meant..." before grade corrected
   - Fix: on first delta, acknowledge + repost; don't negotiate

## Invariants consulted

- **Invariant 1 · Run the check before claiming**
- **Invariant 8 · Two-Claude Review for ship-candidate changes** (this skill IS the invariant)

## Integration

- **`/verify-before-claim`** — implementer's first-line defense; reviewer re-runs the same checks
- **`/post-mortem`** — every grade delta captured for cross-session pattern analysis
- **`/observability-audit`** — reviewer re-runs observability grep during P3 grading

## Completeness Principle

10/10: cold-context reviewer re-runs every verifiable claim; produces full delta table.
7/10: reviewer spot-checks top 3 claims; skips bundle-grep re-run.
3/10: "LGTM" without any re-run.

**Default: 10/10** for all ship-candidate PRs.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version. 5 seed lessons + 5-phase workflow + explicit reviewer/implementer rules.
