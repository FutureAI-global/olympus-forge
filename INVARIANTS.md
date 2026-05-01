# INVARIANTS · cross-skill rules every session-lessons skill references

This file captures the rules that cut across ALL 7 skills. Every skill's preamble sources this file. When a pattern passes the `≥3 sessions` hoist threshold (per `LESSONS-SCHEMA.md`), it lands here as a new invariant.

Keep this file **short + dense.** If it balloons past 200 lines, split it.

---

## Invariant 1 · Run the check before claiming

**Never say "tsc clean", "tests pass", "fix works", "metric emits", "PR opened", "file exists", "logged in"** without either:

(a) The tool-invocation output in the SAME turn as the claim, OR
(b) An explicit "**unverified**" label.

**Ownership:** `/verify-before-claim`

**Why:** the Two-Claude Review Protocol exists specifically because a single session made 3 consecutive false "tsc clean" claims across 3 cycles. Independent review catches this eventually, but the primary fix is never making the claim in the first place.

**Evidence floor:** if this invariant is violated, the session MUST capture a lesson and demote the claim in a correction message.

---

## Invariant 2 · Fetch fresh HEAD before editing shared files

**Before editing any file that could be modified by another session** (anything in `<backend>/services/<harness>/`, `backend/src/services/ford-pts-*`, `<your-schema>.prisma`, files flagged "shared" in CLAUDE.md, or any file in a shared worktree), **fetch the file's current state from remote** via:

```bash
gh api "repos/<owner>/<repo>/contents/<path>?ref=<remote-branch>" --jq '.content' | base64 -d
```

If the local copy differs from remote, pick ONE of:
- Use the remote version as the edit base (preserve remote changes)
- Explicit override with rationale logged

**Ownership:** `/fresh-state`

**Why:** multiple sessions on one machine share worktrees. One session's unstaged edit becomes another session's invisible base state, which then appears to vanish when pushed via the GitHub API. Burned on `#1500` / `#1502` silent regressions; burned again when 3 CLI processes hit a 2-day-stale backend.

---

## Invariant 3 · Never `git push` on repos >1 GB

On any large repo (current trigger: <your-repo> at 5.6GB), **`git push` hangs for 10+ minutes** packing objects. Use the GitHub API recipe instead:

```
gh api git/blobs → git/trees → git/commits → git/refs
```

See `/api-push` for the exact pattern. Uploads only changed files, completes in seconds.

**Exception:** tiny repos (<100MB) where `git push` is still fast.

**Ownership:** `/api-push`

---

## Invariant 4 · Preserve line endings on API push

Source files with CRLF line endings (check via `file <path>`) must be written back with CRLF when patching via the GitHub API. Python example:

```python
content = content.replace('\r\n', '\n').replace('\n', '\r\n')
```

**Violation shape:** LF-content pushed against CRLF source → GitHub diff shows every line changed → PR review becomes unusable.

**Ownership:** `/api-push`

---

## Invariant 5 · Never `gh pr edit --base` on PRs with squash-merged parents

Retargeting a PR's base branch via `gh pr edit --base <new-base>` produces **ghost-deletion diffs** when the original parent SHA was squash-merged into the new base. Git compares trees including unrelated files → 20k-line phantom deletions.

**Fix:** delete + recreate the branch with a fresh commit parented on the new base HEAD.

```bash
# WRONG — produces ghost-deletion diff
gh pr edit 1234 --base staging

# RIGHT — delete + recreate
gh api -X DELETE "repos/<owner>/<repo>/git/refs/heads/<branch>"
# Then push a fresh commit parented on staging via blob → tree → commit → ref
```

**Ownership:** `/api-push`

**Evidence:** PRs #1518 / #1519 showed this exact 20k-deletion shape on a recent incident after the fork → staging squash-merge. Cost: 45 minutes of confusion before root-cause.

---

## Invariant 6 · Every declared metric has a caller

**Before declaring a PR "observability improved"**: for every `Counter` / `Histogram` / `Gauge` in the diff, verify a non-test caller exists in the same PR or an existing code path.

```bash
# Verify pattern
grep -rn '<metric-name>' backend/src/ --include='*.ts' | grep -v __tests__
```

**Violation shape:** `a validator-finding counter` exported at `<metrics-file>` for ≥4 weeks with zero callers → soft-findings invisible to ops → same class of error keeps shipping because no metric signals it.

**Ownership:** `/observability-audit`

---

## Invariant 7 · Every silent-catch has a signal

Any `catch (err) {}` that deliberately returns a silent fallback (empty array, `{ ok: false }`, `null`) MUST either:

(a) Emit a Prometheus counter (`recordXxxFailure(...)`)
(b) Write a structured audit log line
(c) Include an inline comment explaining why silence is correct for this specific catch

Silent-catch without ANY of the three = implicit observability debt. Log it as a lesson so the pattern stops shipping.

**Ownership:** `/observability-audit`

---

## Invariant 8 · Two-Claude Review for ship-candidate changes

Every PR that ships behind a feature flag OR modifies `src/` / `backend/` / `services/` OR adds ≥50 LOC goes through two Claude sessions: implementer + independent reviewer. The reviewer runs with **cold context** (no transcript from the implementer) and **RE-RUNS every verifiable claim** (`tsc`, `jest`, bundle greps) before signing off.

**Ownership:** `/two-claude-review`

**Skip only for:** typo fixes, single-variable renames ≤3 files with no behavior change, test-only import swaps.

---

## Invariant 9 · User corrections are lessons, not interruptions

When a user says "no that's wrong", "don't do X", "you inflated Y", or equivalent: that's not a blocker to resolve and move on — that's a lesson to capture.

Within the same turn as the correction:

1. Acknowledge the correction + the specific mistake
2. Invoke `/post-mortem` to capture the pattern into `learnings.jsonl`
3. Apply the correction + continue

Without capture, the next session makes the same mistake. Compounding failure.

**Ownership:** `/post-mortem`

---

## Invariant 10 · Completeness trumps brevity (Boil the Lake)

When the cost of the complete implementation vs the shortcut is ≤10x, always choose complete. AI makes completeness near-free. A lake (100% coverage) is boilable in one session with Claude Code; an ocean (full rewrite) is not.

**Ownership:** cross-cutting; reinforced by `/verify-before-claim` (no half-checks) and `/observability-audit` (no half-coverage on metrics).

**Guideline:** if an option has Completeness ≤5/10, flag it. If both options are 8+, pick higher.

---

## Invariant 11 · Never touch shared / orch-gated surfaces without explicit green-light

Files flagged in CLAUDE.md as `constitution/v1/**`, `conversation-runner.service.ts`, `conversation-validator.service.ts`, or other orch-gated surfaces: **never edit without an explicit @orch green-light posted in a coord PR**.

**Ownership:** cross-cutting; domain-specific (scope: `<your-project>`)

**Enforced by:** `/fresh-state` pre-flight (detects the path) + a coord-PR-comment check.

---
---

## Invariant 12 · Bedrock messages-array validation rules (the full set)

Anthropic's Bedrock API enforces FIVE structural rules on every messages-array request. Violating any one fires a 400 with a misleading "tool_use ids were found without tool_result blocks immediately after" — same symptom, different rule. Sanitizers MUST audit ALL five at PR-author time, not "we'll patch the next one when it fires" (cost on a recent launch-blocker incident: 7 verifier-failed runs + 3 PRs that didn't fix the live bug).

**The five rules:**

| # | Rule | Sanitizer that pins it |
|---|---|---|
| 1 | **Strict role alternation** — no consecutive same-role messages | any-assistant-merge in the transcript-to-messages path |
| 2 | **tool_use → tool_result pairing by id** — every assistant tool_use has a matching tool_result_id in the immediately-following user message | forward-orphan sanitizer + boundary final-mile sanitizer |
| 3 | **tool_result → tool_use existence by id** — every user tool_result_id must match some prior assistant tool_use id | reverse-orphan sanitizer |
| 4 | **Block-order within assistant: tool_use blocks must be CONSECUTIVE** — no text/non-tool_use block between any two tool_use blocks within one assistant message | text-then-tool_use stable partition in any consecutive-assistant-merge |
| 5 | **No empty messages** — drop any message whose content array is empty post-sanitize | boundary sanitizer continue-on-empty |

**Ownership:** `/two-claude-review` (PR-author-time audit) + `/observability-audit` (detector for each rule).

**Why all five:** rules 1-3 alone don't guarantee Bedrock acceptance. The block-order rule (#4) was discovered via a structured-logging chain on 2026-05-01: a pairing-only detector said `well-formed` on the same call Bedrock 400'd. Wire-bytes hash matched detector content (eliminates SDK mid-flight mutation). Only the block-order interleave was rejected.

**Pre-merge audit checklist for any sanitizer/merge fix that touches the Bedrock messages-array path:**

- [ ] Add a regression test for EACH of the 5 rules to the relevant `__tests__/` file
- [ ] Run a live verifier (synthetic-conversation harness against the live API) post-deploy as the acceptance gate — clean smoke (exit 0) or DO NOT MERGE
- [ ] Update the structural detector at the API send-site to flag any new rule

**Scope:** `bedrock` (Anthropic Bedrock API specific; applies to any project that uses Bedrock with tool-use)

---

## Invariant 13 · Ship observability before another fix attempt

When a debate cycle runs ≥2 rounds across ≥2 sessions on a sanitizer-gap or contract-gap hypothesis without converging on root cause, **pause the fix lane and ship structured logging instead**. Ground-truth observability resolves H-trees in one capture, often eliminating multiple hypotheses simultaneously.

**Ownership:** `/observability-audit`

**Why:** on a recent launch-blocker incident, H1-H4 sanitizer-gap hypotheses were chased across 4 PRs over ~70 min — none was the live bug. Three observability layers (pre-serialize structural detector, post-serialize wire-bytes hash, sanitizer entry/exit logs) took ~25 min to ship and surfaced the actual rule (a stricter-than-detector API contract) in the FIRST verifier capture post-deploy.

**Three layers most useful for any contract-gap debug:**

1. **Pre-serialize structural detector** — privacy-safe shape skeleton (roles, block types, IDs, refs). Privacy contract: NO raw text, NO tool args, NO result bodies.
2. **Post-serialize wire-bytes hash + byteLength** — proves bytes the API receives match what the detector saw (eliminates mid-flight mutation hypothesis).
3. **Entry/exit logs at every sanitizer pass** — separates "sanitizer didn't fire" from "sanitizer fired but didn't catch this case".

**Decision tree (with all three layers):**

| Detector | Wire-hash matches | API response | Diagnosis |
|---|---|---|---|
| WARN ill-formed | — | 4xx | sanitizer gap (rule X missed in detection logic) |
| INFO well-formed | matches | 4xx | API stricter than detector (new rule needed) |
| INFO well-formed | diverges | 4xx | mid-flight mutation (SDK / serializer bug) |

**Scope:** `generic`

---

## Invariant 14 · Source-trace inference is NOT live evidence

A source-trace "best hypothesis" before live (production / log) evidence has a high false-positive rate. Shipping a fix from a source-trace alone risks defensive churn while the real bug is elsewhere.

**Ownership:** `/verify-before-claim`

**Why:** on a recent launch-blocker incident, a source-trace at T+0 identified hypothesis A as the cause; ground-truth log capture at T+45min proved the live failure had a different shape entirely. The source-trace fix landed but didn't fix the live bug; the real root cause was a different rule, fixed in a follow-up PR.

**Two-path rule:**

- (a) **Ship as defensive companion** with explicit scope caveat in PR body — "fixes a real but latent hole; live failure root cause TBD" — preserves honesty + parallel progress
- (b) **Wait for log evidence** if the source-trace is the only hypothesis — "I have a source-trace hypothesis but no live evidence yet; ship observability first OR wait for grep, your call?"

**Forbidden:** claiming the fix addresses the live failure when the live failure shape might not match the hypothesis.

**Scope:** `generic`


## How to add a new invariant

1. A pattern must pass the hoist threshold (see `LESSONS-SCHEMA.md`): ≥3 unique sessions contributing evidence OR ≥2 for P0 severity
2. The weekly aggregator (`bin/aggregator`) proposes a draft at `~/.claude/skills/session-lessons/proposed/hoists-YYYY-MM-DD.md`
3. Lee reviews + approves (or rejects with rationale — rejection itself becomes a lesson)
4. Approved invariants get appended here + cross-linked from the owning skill's `Invariants` section

**No invariant is ever deleted.** If an invariant becomes obsolete (tech stack change, tool upgrade), mark it `**SUPERSEDED by <new-invariant>**` inline but keep the text.

---

## Changelog

- **a recent incident · v1** — 11 invariants. a specific session authored. Derived from this session's lessons + 21 pre-existing `memory/feedback_*.md` seeds.
- **a recent incident · v2** — added Invariants 12 (Bedrock 5-rule set), 13 (ship observability after 2 rounds), 14 (source-trace ≠ live evidence). Derived from a launch-blocker chain on 2026-05-01 where H1-H4 sanitizer-gap hypotheses didn't fix the live bug; structured logging surfaced the actual rule (Bedrock block-order strict requirement) in one capture. Hoist threshold satisfied: P0 + 2-session evidence.
