---
name: backbone-wire-pr-split
namespace: pr-velocity
version: 0.1.0
description: |
  When a feature touches a large central file (5K+ LOC orchestrator,
  router, or state machine), split the work into TWO PRs: (1) a
  testable "backbone" PR that adds types, pure logic, helpers, and
  unit tests in NEW files only — zero edits to the central file;
  (2) a "wire" PR that integrates the backbone into the central file
  via small additive edits. Reduces conflict surface on shared files,
  keeps the backbone reviewable in isolation, and lets sibling
  sessions ship parallel features without ping-ponging the central
  file's merge conflicts.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Grep
  - Glob
---

# backbone-wire-pr-split · keep central-file blast radius small

## Why this exists

Large central files (a TUI's main component, a router's routes, a state machine's reducer) are the natural meeting point of every feature — and the natural conflict surface for any sibling session also touching them. A single 5,000-LOC file can become a serialization bottleneck that stalls 3 sessions waiting on each other's merges.

Splitting one feature into "backbone" + "wire" PRs:

- **Backbone** lives in NEW files only (`feature/loader.ts`, `feature/types.ts`, `feature/__tests__/`). Zero touches on the central file. Tests cover the contract. Reviews focus on logic correctness without ink/ui/router noise.
- **Wire** is small, additive edits to the central file: import the backbone, call its entry, pass through one prop, add 2-3 lines to the dispatch switch. Reviews focus on integration correctness without re-reviewing the backbone.

Both PRs together = the original feature. Either alone = a half-shipped feature, but the half is testable and bisectable.

## Trigger conditions

Fire this skill when the next feature you're about to ship would:

1. Touch a file >2,000 LOC, OR
2. Touch a file that 2+ sibling sessions also have open PRs against, OR
3. Add a new contract (handler, dispatcher, middleware) that has a clear "API surface" + a "wired-in" boundary

If none of these apply, ship as one PR — the splitting overhead isn't worth it.

## Procedure

### Step 1 · identify the boundary

Sketch the feature. Where does NEW code end and EDITS to the central file begin? That's the boundary.

Examples:
- Plugin loader · backbone = `plugins/loader.ts` + `plugins/types.ts` + `plugins/bootstrap.ts`. Wire = `import + initializePlugins()` call at mount + dispatch in handler.
- Script runner · backbone = `scripts/parser.ts` + `scripts/runner.ts` + `scripts/adapter.ts`. Wire = `--script` flag in argv parser + dispatch branch in command entry.
- Export format · backbone = `formatters/<format>.ts` + tests. Wire = case branch in route handler + content-type header.

The wire is usually 20-100 LOC across 1-3 central files. The backbone is usually 200-800 LOC across 3-6 new files. **If the wire is > 200 LOC, the boundary is wrong** — pull more into the backbone.

### Step 2 · ship the backbone PR

Tests over the new files only. CI gates pass. Backbone is callable from a hypothetical caller; the central file isn't yet that caller. Title: `feat(<area>): <feature> backbone — types + <pure-modules> + tests`.

The PR body should explicitly say:
> Follow-up PR will wire this into <central-file>. Splits to keep the
> central-file blast radius small and let backbone review focus on
> contract not integration.

This sets reviewer expectation: the PR is intentionally not user-facing yet.

### Step 3 · ship the wire PR

Open against the same base. Pure additive edits to the central file: import the backbone, call its entry, dispatch through it, pass results back. No backbone-content changes (those would have come back to step 2).

Title: `feat(<area>): <feature> wire-up — mount + dispatch + integration`.

The PR body should reference the backbone PR # and state explicitly:
> Closes <feature> DOD. Backbone shipped in #<n>; this PR wires it
> into <central-file>.

### Step 4 · verification

End-to-end smoke after wire merges:

- The feature works user-facing.
- The backbone tests still pass (they didn't depend on the central file).
- A sibling session's pending PR against the central file rebases cleanly (proves the wire was minimally invasive).

## When NOT to split

- One-line bug fixes
- Feature changes confined to a single new file (no central edits)
- Hotfixes (split adds latency you can't afford)
- Features whose backbone IS the integration (e.g. a small middleware whose contract is "intercept this request type")

## Failure modes

- **Backbone-without-wire stranded**: backbone ships, wire blocked on review/conflicts, feature stays half-shipped. Mitigation: backbone PR title flags "(infrastructure-only; wire follows in #X)" so reviewers don't merge it expecting user-facing impact.
- **Wire too big**: more than ~200 LOC of wire means the backbone didn't extract enough. Mitigation: re-pull the boundary; move the duplication-prone bits into the backbone.
- **Reviewer fatigue across two PRs**: same content shows up twice (the backbone's API in PR-1, the call site in PR-2). Mitigation: PR-2's body should link PR-1 explicitly so the reviewer can focus on integration.

## Why this works

Two-Claude-Review (the broader review pattern) becomes tractable when each PR has a single concern. A 1,000-LOC PR touching a 5K central file with new contracts is hard to review well — the reviewer has to hold both contract-correctness and integration-correctness in their head. Splitting frees each PR to be reviewed against its own bar.

In production we shipped 8 PRs in one session using this pattern (bki-i04 plugin loader: backbone + wire = 2 PRs · bki-i05 script runner: parser + runner + adapter + cli-flag = 4 PRs · bundle-test-suite + others). All 8 merged with zero rollbacks; the central TUI file (5,376 LOC) saw 4 separate small additive edits over 6 hours instead of 1 large concurrent edit.

## Seed lessons

- **id**: `pr-velocity-backbone-wire-split-prevents-conflicts`
  **scope**: generic
  **pattern**: when a feature touches a 5K+ LOC central file, split into backbone (new files only, with tests) + wire (small additive central-file edits) PRs. Reduces conflict surface for sibling sessions.
  **evidence**: 8 PRs shipped in one session against a 5,376-LOC central TUI file; 4 separate small additive edits across 6 hours; zero rollbacks; sibling sessions' parallel PRs rebased cleanly.
  **fix**: any feature touching a >2K-LOC file that 2+ sessions are likely editing should ship as backbone+wire PR pair.
