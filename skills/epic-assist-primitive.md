---
name: epic-assist-primitive
namespace: session-lessons
version: 0.1.0
description: |
  Shipping pattern for sessions that want to contribute to an epic owned by
  another session without stepping on owner territory. Identify the
  pure-function piece (formatter, scrubber, state machine, JSON config store,
  drift guard) in the epic's file list. Ship that primitive plus tests as a
  single-file or all-new-files PR. Hand off the route, slash, TUI wiring to
  the epic owner via an explicit "hands off to" line in the PR body.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a multi-epic sprint where one session shipped over a dozen PRs across multiple epics owned by sibling sessions, all by isolating the pure-function pieces and handing wiring back to the owners.
---

# epic-assist-primitive · ship the pure piece, hand off the wiring

## Why this exists

When a coord PR splits work across N sessions and each session "owns" an epic, sibling sessions still want to contribute. Naively claiming part of someone else's epic causes merge conflicts, blurred review responsibility, and stepped-on owner territory.

The pattern that scales: identify the pure-function piece in each epic's file list. A formatter, a scrubber, a state machine, a JSON config store, a drift guard. These have no service-layer or UI-layer concerns. They can be shipped in isolation, tested in isolation, reviewed in isolation. The epic owner's wiring (route handler, slash command, TUI component, reducer state) becomes a 5-line import-and-call against the assisting session's tested API.

This collapses what would be a single 500-line owner PR into one small primitive PR plus one small wiring PR, both reviewable independently, both shippable in parallel without merge conflicts.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag epic-assist --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. Reading a coord PR with multiple epics across multiple session owners
2. About to claim work on an epic owned by another session
3. Seeing a `**Files**:` list with both pure-function pieces and integration pieces
4. Considering a PR that mixes primitive code plus owner-territory wiring code
5. Finished shipping a batch of primitives and need a final integration verification test

Voice triggers: "what can I ship on the other epic", "assist on the epic", "primitive PR", "hand off to the owner".

## Workflow

### Phase 1 · Read the coord PR's plan and file list per epic

Find each epic's `**Files**:` section. Identify which files are pure-function shape and which are owner-territory.

| Pure-function (assist-eligible) | Owner-territory (do not touch) |
|---|---|
| Formatter (input: typed data; output: string) | HTTP route handlers |
| Scrubber / sanitizer (input: data; output: redacted data) | Slash command handlers |
| State machine (`load()`, `advance()`, `isComplete()`) | TUI components, reducer state |
| JSON config store (`load()` / `save()` / `update()` against `~/<install-dir>/*.json`) | MCP tool dispatcher |
| Drift guard test (imports every shipped surface, verifies invariants) | Backend SSE wire |

### Phase 2 · Ship the primitive plus per-feature tests as one PR

```
backend/src/services/<area>/<epic>/<feature>.ts          ← primitive
backend/src/services/<area>/__tests__/<feature>.test.ts  ← tests
```

For JSON-store primitives, expose a `<NAME>_PATH` env var override so tests do not touch the real `~/<install-dir>/<name>.json`. Per-test `mkdtempSync` plus cleanup.

Tests in the same PR, never "tests follow in another PR". The follow-up PR never happens.

### Phase 3 · Single-file or all-new-files PRs only

Each assist primitive ships as a single-file PR (just the primitive) OR an all-new-files PR (primitive plus its test). The owner's wiring is their separate PR. This minimizes merge-conflict surface; the owner can rebase after your PR lands without touching your file.

### Phase 4 · Hand off explicitly in the PR body

```markdown
## Hands off to: <owner-session> (<epic> owner)

<owner-session> wires `/<slash> <args>` slash plus `routes/<feature>.routes.ts`. Sample:

\`\`\`typescript
const profile = loadProfile();
const out = format({ input, meta: profile });
return reply.send({ format: '<feature>', body: out });
\`\`\`

Pure function, no service-layer concerns. Drop into the route handler.
```

The owner reading the PR body sees a 5-line import-and-call. They write their wiring against your tested API; you do not write theirs.

### Phase 5 · Drift guard at the end of the batch

After all primitives ship, write a single drift-guard test file that imports every primitive plus verifies they compose end-to-end:

```typescript
describe("assist-shipped surface · drift guard", () => {
  describe("PR <N>", () => {
    test("export X is callable plus returns expected shape", () => { ... });
  });
  describe("End-to-end: primitives compose", () => {
    test("fixture → primary fn → format → scrub all chain together", () => { ... });
  });
});
```

If anyone deletes a type, removes a MUST, renames a function, the drift guard fires loudly.

## What NOT to do

- Mixing primitive code plus owner-territory wiring in one PR. Reviewer cannot tell what is assist work vs owner work. Merge conflicts likely.
- Shipping the primitive without its test. "Tests follow in another PR" is a workaround that never happens. Three weeks later someone refactors and breaks the function silently.
- Admin-merging your own assist PR. Assists are still part of the epic. The merge owner per the lane-table admin-merges. Do not queue-jump.
- Stacking assist PRs (primitive A depends on primitive B in flight). If your PR cannot be reviewed without three other PRs landing first, it is not an assist primitive, it is a coupled change. Re-scope or ship one bigger PR.
- Forgetting the explicit "hands off to" line. Cold-context reviewers cannot tell who is responsible for the integration without it.

## Seed lessons

### Lesson 1 · primitive landing without consumer-side fix-forward causes silent regression

A pure-function primitive shipped, tested, merged. The owner's existing wiring code silently filtered the new return shape (an adapter was string-coercing a typed object), dropping the primitive's output. The fix: when this happens, the assisting session ships a one-line consumer fix as a fix-forward PR. Coordinate via comment on the coord PR; do not silently touch owner territory without an explicit handoff.

### Lesson 2 · stacked-coupled assist PRs are not assists

A session tried to ship five assist PRs where each depended on the prior one being merged. Reviewers had to load all five into context before any could ship. The fix: re-scope each PR to be independently reviewable, OR collapse to one larger PR. Stacked-coupled is the worst of both shapes.

### Lesson 3 · drift-guard end-to-end test catches what per-feature tests miss

Per-feature tests verified each primitive in isolation. A renamed function broke the integration but every per-feature test still passed because each test imported its own copy of the type. The fix: a final drift-guard test file that imports every primitive plus runs them through a real fixture end-to-end. Pairs with per-feature tests, does not replace them.

### Lesson 4 · "Hands off to" line is what the cold-context reviewer needs

Without the explicit handoff line in the PR body, reviewers reading cold could not tell whether the primitive expected a follow-up wiring PR or whether it was supposed to wire itself somewhere. The fix: every assist PR body includes `Hands off to: <owner-session> (<epic> owner) wires <slash/route/component>`. Boilerplate, cheap, prevents review-thread back-and-forth.

### Lesson 5 · admin-merging your own assist PR breaks the lane-table

A session admin-merged its own assist PR to "unblock" a sibling. The merge owner's lane-table tracking went stale, the next sibling-PR conflicted on a base SHA the merge owner did not know had moved. The fix: assists go through the same merge owner as the rest of the epic. No queue-jumping.

## Invariants consulted

- `Invariant 1 · Run the check before claiming`. Drift-guard test in the final PR is the verification anchor; "the primitives compose" is a claim that requires the test in the same turn.
- `Invariant 8 · Two-Claude Review for ship-candidate changes`. Single-file or all-new-files PRs are easy for an independent reviewer to load cold; stacked-coupled PRs are not.
- `Invariant 11 · Never touch shared / orch-gated surfaces without explicit green-light`. Owner-territory files are gated; touch them only with an explicit handoff comment from the owner.

## Integration points

- Pairs with `coord-pr-as-message-bus`. The bus is where the `[assist] <session> · #<N>` handoff comments get posted so the owner sees the primitive landed.
- Pairs with `verify-receipts-before-flawless-claim`. Every assist PR ships with raw test output in the body so the receipt skill can verify "182 tests pass" rather than treating it as a claim.
- Pairs with `multi-session-tick-orchestration`. The session tick that posts `shipped: PR #<n>` is what announces the assist primitive to the rest of the bus.

## Completeness principle

This skill DOES NOT fire for solo-session epics where there is no other owner to hand off to. It also does not fire for refactor PRs that span pure plus owner-territory by intent (those are coupled changes by design and need the owner's PR all along).

False-negative cost (mixing primitive plus wiring in one PR): merge conflicts with the owner's in-flight work, blurred review, two sessions arguing over the same diff. False-positive cost (splitting a tiny change into primitive plus wiring PRs when one would do): one extra PR's worth of overhead. Default to splitting unless the change is genuinely a single 5-line edit.

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a multi-epic sprint where one session shipped over a dozen PRs across multiple epics owned by sibling sessions, all by isolating the pure-function pieces and handing wiring back to the owners.
