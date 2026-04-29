---
name: time-pressured-fix-bundle-split
namespace: session-lessons
version: 0.1.0
description: |
  Fires when an orchestrator post assigns multiple distinct fixes to one
  session under a sub-N-minute target. Encodes the split-into-focused-PRs
  pattern: ack with a split plan up front, ship each PR independently with
  raw test stdout in the body, post receipts to the coordination thread
  after each open. Prevents the mega-PR anti-pattern where one slow fix
  blocks the merge of three ready ones.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a time-boxed multi-fix assignment delivered as four parallel single-purpose PRs in roughly a quarter of the budgeted window.
---

# time-pressured-fix-bundle-split · focused PRs over one mega-PR

## Why this exists

When a coordination post says "fix N runtime issues, sub-N-minute target", the temptation is to batch the fixes into one PR. That choice is wrong for three reasons. A single mega-PR delays ALL fixes until the slowest one is ready. CI on small parallel PRs runs concurrently; CI on one big PR runs once and gates the whole batch. The merge owner can clear focused PRs in seconds; mega-PRs require a careful read.

The pattern that wins under time pressure is: split early, ack the split publicly, ship each PR with full receipts, post a coordination receipt after each open, and finish with a complete table. The merge owner sees the queue forming and starts merging while later PRs are still being authored.

## Preamble (run first)

```bash
# Resolve repo + worktree paths
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag fix-bundle --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. Reading a coordination PR comment that lists 3 or more distinct fixes assigned to one session
2. The post mentions a time target (sub-N-minute, "by N o'clock", "ship-day", "before the next smoke run")
3. The fixes are independent (no inter-dependency mentioned in the assignment)
4. The orchestrator or merge owner is online and able to clear PRs as they arrive
5. Test surfaces for each fix can be authored in isolation (no cross-fix shared fixtures)

Voice triggers: "ship the fix bundle", "split into PRs", "v-N-fix bundle", "knock these out".

## Workflow

### Phase 1 · Ack with the split plan in 60 seconds

Reply on the coordination PR with the split structure BEFORE coding anything. This commits you to the order, gives the merge owner advance notice, and lets a sibling session redirect if priorities have shifted:

```markdown
## ack v-N fix bundle · splitting into 4 PRs

| Order | Issue | Why first | Est |
|---|---|---|---|
| 1 | Issue A | Provided diff + tests verified locally | 15 min |
| 2 | Issue B | Well-bounded render-path intercept | 25 min |
| 3 | Issue C | Orchestrator timeout fallthrough | 25 min |
| 4 | Issue D | Streaming patch-vs-remount | 25 min |

Total: roughly 90 min. Each PR independent; merge owner can land in any order.
```

Order rule: easiest first. Provided diffs and clear scope land quick wins while harder fixes are still being investigated.

### Phase 2 · Ship each PR with full receipts in the body

Per the standing tests-mandatory rule: every PR includes raw test runner stdout in the body, test counts in the summary table at top, the verbatim user-observed bug as a regression test case, and a coord section tagging the merge owner.

Each PR must be independently mergeable. NO "this PR depends on Issue C landing first" unless the orchestrator explicitly said so.

### Phase 3 · Post receipts to the coordination thread after each open

Don't batch. Each new PR gets a coord-thread comment within 30 seconds of opening:

```markdown
## v-N · 2 of 4 done · <timestamp>

| Fix | PR | State |
|---|---|---|
| Issue A | <pr-link> | OPEN · MERGEABLE · 12/12 jest |
| Issue B | <pr-link> | OPEN · MERGEABLE · 21/21 jest |

Both single-purpose, isolated, with raw jest output in PR bodies.
```

The merge owner sees the queue forming and starts clearing while you author the rest.

### Phase 4 · Final receipt with complete table

When all PRs are open, post a completion receipt to the coordination thread:

```markdown
## v-N fix bundle COMPLETE · 4/4 shipped

| # | PR | Title | Tests |
|---|---|---|---|
| A | <pr-link> | issue A summary | 12/12 |
| B | <pr-link> | issue B summary | 21/21 |
| C | <pr-link> | issue C summary | 16/16 |
| D | <pr-link> | issue D summary | 12/12 |

12 files · +920/-21 · 61 jest cases all passing · <minutes> total
(target was sub-N-min)
```

Note total time vs target so the orchestrator can verify the rate.

### Phase 5 · Test selection per fix type

Choose the cheapest test surface that proves the fix:

| Fix type | Test type | Why |
|---|---|---|
| Pure function (sanitizer, comparator, version-pin) | unit cases on the function directly | Fast, cheap, exhaustive coverage of patterns |
| Reducer wire-up | reducer test (no React, no rendering) | Tests the action dispatch + state update path without rendering |
| Adapter integration | integration with mocked deps | Tests cross-module wiring without live services |
| TUI render | extract comparator to .ts and unit-test that | Avoids ts-jest integration weight; covers the memo logic |

## What NOT to do

- One mega-PR with all N fixes. Cannot be partial-merged; one failing CI gate blocks all. Worst-of-both-worlds outcome.
- Sequential ship-and-wait-for-merge. CI is parallel infrastructure; your shipping should be too. Don't serialize what the platform can run concurrently.
- "Tests follow in another PR." Tests-mandatory is a standing rule; same-PR tests are non-negotiable. Bumping tests to a follow-up loses the regression-as-test-case anchor.
- Skipping coord receipts. The merge owner does not watch your branches; they watch the coordination thread. A PR that exists but isn't surfaced may sit unread until the owner notices.
- Picking hardest first to "get it out of the way." When the hard one stalls, NO PRs land and the orchestrator sees zero progress. Easiest first guarantees motion.

## Seed lessons

### Lesson 1 · mega-PR blocks the entire batch on the slowest fix

A session bundled four runtime fixes into one PR. CI failed on the third fix's test (a flaky integration), and the other three fixes (which were CI-green and ready) sat un-merged for 40 minutes while the flaky test was diagnosed. Splitting would have let three land immediately and the fourth retry in isolation.

### Lesson 2 · ack post commits the session to a plan and surfaces it for redirection

A session started coding a fix bundle without acking the split. The orchestrator, watching for movement, assumed the session was idle and reassigned two of the fixes to a sibling session. Both sessions then opened conflicting PRs. A 60-second ack post would have prevented the duplicate work.

### Lesson 3 · raw test stdout in PR body upgrades grade-table from "claimed" to "verified"

A merge-gate reviewer tagged a PR as "tests claimed but not in body, marking unverified" and held the merge until the author re-pasted the raw runner output. Pasting it up front saves the round-trip. Treat raw stdout as a required field, not a nice-to-have.

### Lesson 4 · per-PR coord receipt creates the queue the merge owner watches

A session opened four PRs in 20 minutes but only posted a single batch receipt at the end. The merge owner missed the first three opens entirely (no coord-thread notification) and only started clearing after the batch receipt landed, costing roughly 15 minutes of pipeline idle. Per-PR receipts within 30 seconds of open would have parallelized the merge work.

### Lesson 5 · easiest-first ordering keeps the queue moving even when the hard fix stalls

A session ordered fixes by perceived "importance" and put the hardest fix first. The hard fix took 60 minutes to investigate; the orchestrator saw zero PRs for an hour and escalated. Ordering by ease (provided diffs first, well-bounded scope second, hardest last) means the queue starts filling within the first 15 minutes regardless of how the hard ones go.

## Invariants consulted

- `Invariant 1 · Run the check before claiming`: raw test stdout in PR body is the verifying-output requirement
- `Invariant 8 · Two-Claude Review for ship-candidate changes`: focused PRs are reviewable, mega-PRs are not
- `Invariant 9 · User corrections are lessons, not interruptions`: if the orchestrator redirects mid-bundle, capture the routing change as a lesson rather than treating it as friction

## Integration points

- Pairs with `api-push`: each focused PR uses the API-push recipe to avoid `git push` collisions across the parallel branches
- Pairs with `verify-before-claim`: the per-PR receipts are the verifying output for the "PR opened" claim
- Pairs with `epic-assist-primitive`: the same single-purpose-PR discipline applies to shared primitives across epics

## Completeness principle

This skill DOES NOT fire for single-fix assignments, for fixes with explicit inter-dependencies (those need stacked PRs, not parallel), or for refactors that touch shared surface across all the fix sites (those need one PR by design). It also does not fire when the orchestrator has explicitly asked for a single bundle PR.

False-negative cost (treating a multi-fix bundle as a mega-PR): the slowest fix blocks the rest, the orchestrator escalates, the merge window closes. False-positive cost (splitting when batching was fine): a few extra PRs in the merge queue, cheap. Default to splitting when in doubt.

## Changelog

- v0.1.0 (2026-04-29): initial skill from session-lessons. Forged from a time-boxed multi-fix assignment delivered as four parallel single-purpose PRs in roughly a quarter of the budgeted window.
