---
name: instrument-then-fix
namespace: session-lessons
version: 0.1.0
description: |
  When a structural invariant is violated in production but the source of
  the violation is unknown, ship observability FIRST as multiple layered
  PRs (in-memory detector + enrichment + wire-side fingerprint), use the
  data to disambiguate competing hypotheses, THEN ship a targeted fix.
  Resists the temptation to ship a speculative fix or chase the bug
  through static-analysis alone. Fire when a verifier reproduces a bug
  that source-trace audits cannot explain.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Grep
provenance: |
  forged 2026-05-01 from the Olympus launch-blocker arc that resolved a
  Bedrock 400 ("messages.N: tool_use ids found without tool_result blocks
  immediately after"). Three observability PRs (#1989, #1991, #1992)
  shipped before the actual fix (#1993, +20 LOC). Without the staged
  observability the team would have shipped the wrong fix; with it, the
  root cause was identified in one verifier run.
---

# instrument-then-fix · ship observability before the fix when the bug source is unknown

## Why this exists

When a verifier deterministically reproduces a production bug but every code-reading audit says "this case shouldn't be reachable," the bug is in a layer the audit doesn't see. Speculation produces wrong fixes. The right move is to add **enough observability to make the bug speak** before changing any logic.

The Olympus Bedrock 400 was the canonical case:

- Verifier reproduced `messages.3: tool_use_id without tool_result blocks immediately after` on every DTC-rich first turn
- Static-analysis audit (multiple sessions) found NO production-path bypass of the upstream sanitizer
- Three competing hypotheses with no way to distinguish:
  - **H5** sanitizer logic gap on a specific shape
  - **H6** mid-flight mutation between sanitizer-output and SDK-send
  - **H7** Bedrock applies a stricter pairing rule than the sanitizer checks

Speculative fixes shipped to "address H1/H2/H4" (#1974, #1977, #1985, #1990) each closed real holes, but each was followed by another `messages.N` 400 in a new position. Position-improvement (`messages.1` → `messages.3`) suggested progress, but didn't prove root cause.

What worked: **three observability PRs across two log layers** (in-memory shape detector → enriched per-message detail → post-serialize wire-byte fingerprint). One verifier run with all three layers active showed `[bedrock-shape] well-formed` + `[bedrock-wire] hash=X bytes=N` + Bedrock 400 simultaneously on the same call. That triangulation eliminated H5 + H6 in 90 seconds. H7 confirmed. The fix was 20 LOC.

The instinct to skip ahead to "just ship a fix and see if it works" looks like speed. It's not. Each speculative fix is a deploy + EC2 resync + verifier rerun cycle. Three speculative fixes cost ~45 minutes of cycle time AND polluted the source tree with adjacent-but-not-root-cause changes that needed regression tests of their own. Three observability PRs shipped in parallel cost the same wall time and produced data instead of new questions.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag instrument-then-fix --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

Fire this skill when ALL of the following are true:

- A verifier (synthetic or production) deterministically reproduces a structural-invariant bug
- A code-reading audit (one or more sessions) found NO source-level path that should produce the violation
- The team has ≥2 competing hypotheses with no way to distinguish them from existing logs
- The bug is in a layer with both an in-memory representation AND a wire/serialization boundary (any orchestrator → SDK → external API path qualifies)

Voice triggers: "we need more logs", "I can't see why this is happening", "audit says clean but it's still broken", "what is actually being sent".

Negative triggers (skip this skill, ship the fix directly):

- The bug shape EXACTLY matches an existing failure pattern with a known fix
- The verifier reproduces a stack-trace pointing at a specific line
- The audit found a clear bypass path

## Workflow

### Phase 1 · Identify the two boundaries

Every system in scope has at least two boundaries where the data shape can be inspected:

1. **In-memory representation** · the data structure JUST BEFORE it gets serialized for the wire (e.g., `messages` array passed to a Bedrock client, the request body before `JSON.stringify`)
2. **Wire bytes** · the bytes the SDK transmits to the external API (e.g., the body inside the AWS SDK's `InvokeModelCommand.input.body`)

These can differ. The whole point of this skill is that you don't yet know whether they differ. Instrumenting both boundaries proves it.

### Phase 2 · Ship the in-memory detector first (PR 1)

A pre-serialize structured shape skeleton:

- Captures roles, content-block types, internal IDs, structural pairing
- Does NOT capture raw text, tool args, or content bodies (privacy-conscious fingerprint)
- Emits as a structured `logger.info`/`logger.warn` line on EVERY external-API call
- WARN branch when the detector finds something it considers ill-formed; INFO branch otherwise
- ALWAYS includes the orchestrator's understanding of what's well-formed

Example (Bedrock case): `summarizeMessagesShape(messages)` returning `{ roleSequence, blockSummary, hasConsecutiveSameRole, orphanToolUseIds }`. Emitted as `[bedrock-shape] ill-formed` or `[bedrock-shape] well-formed` immediately before the SDK call.

### Phase 3 · Ship enrichment for the well-formed branch too (PR 2)

The first PR likely emits a thin payload on the well-formed branch (count + sequence + booleans) to keep log volume sane. Once you're investigating, the well-formed branch needs the FULL detail too. Drop the warn/info conditional and emit the full per-message blockSummary (or equivalent) on EVERY call. Without this, a "false-well-formed" report (detector says clean, external API rejects) is unreadable.

This PR exists because PR 1 was right to be conservative on log volume in steady state. The investigation-mode enrichment is its own deploy.

### Phase 4 · Ship the wire-byte fingerprint (PR 3)

A post-serialize log AT the SDK boundary, immediately before `<sdkClient>.send(<command>)`:

```ts
const wireBody = command.input.body;
logger.info('[bedrock-wire] body about to send', {
  path: 'streaming-raw',
  bodyByteLength: typeof wireBody === 'string' ? wireBody.length : -1,
  bodyHash16: typeof wireBody === 'string'
    ? createHash('sha256').update(wireBody).digest('hex').slice(0, 16)
    : '<non-string-body>',
});
```

Hash + byte length, no raw bytes. The hash is a privacy-safe fingerprint that uniquely identifies the wire content. Without this, **H6 (mid-flight mutation) and H7 (external-API stricter than detector) are indistinguishable** · both produce "detector says clean, API 400s."

### Phase 5 · Run the verifier once with all three layers active

Capture both the verifier's client-side response AND the EC2-side log lines for the same conversation. Cross-reference timestamps.

The decision tree from the same call's logs:

| Layer 1 (in-memory detector) | Layer 2 (wire fingerprint) | + external 400 → | Hypothesis confirmed |
|---|---|---|---|
| WARN ill-formed (orphans listed) | hash X | yes | Detector matches API; sanitizer gap exists upstream |
| INFO well-formed | hash X (matches in-memory) | yes | API stricter than detector · read API docs / file with vendor |
| INFO well-formed | hash Y (diverges from in-memory) | yes | Mid-flight mutation in SDK serialization or downstream consumer |

Without Layer 2, the bottom two rows are indistinguishable.

### Phase 6 · Ship the targeted fix (PR 4)

The data tells you which layer the fix belongs in. The fix is usually small (the Olympus arc was 20 LOC). It includes:

- A regression test that asserts the previously-failing shape is now produced correctly
- A reference to the layer-by-layer log evidence in the PR body
- Verification of the fix using THE SAME verifier and instrumentation that diagnosed the bug

### Phase 7 · Post the closure receipt

Post on the coordination thread with:

- The pre-fix log (in-memory + wire) showing the bad shape
- The post-fix log showing the good shape
- The verifier's clean exit (`conversationComplete: true` or equivalent)
- The "X verified the fix on production" claim with both client AND server-side evidence

## Seed lessons

### lesson 1 · the verifier proved it but no source-trace did

```yaml
incident: olympus-bedrock-400-launch-blocker-2026-05-01
shape: |
  Verifier reproduced messages.3 orphan deterministically. Three independent
  audits (K, C, E) found no source-level path that should produce it.
  Speculative-fix-and-deploy cycles were tried (#1974, #1977, #1985, #1990)
  and each closed real but adjacent issues without resolving the verifier.
diagnosis: |
  The bug was in a strictness gap between the orchestrator's in-memory
  pairing detector (which matched the existing sanitizer logic) and the
  external API's pairing rule (which required tool_use blocks to be
  CONSECUTIVE within an assistant message · no text interleaving). No
  source-trace would catch it because the source matched the detector;
  only a wire-side observation revealed the API's stricter rule.
fix: |
  Three observability PRs (#1989, #1991, #1992) shipped in parallel, then
  one verifier run produced ground truth, then a 20-LOC fix (#1993) closed
  the gap.
prevention: |
  Recognize the failure mode: when audit and reproducer disagree, the bug
  is in a layer the audit can't see. Ship observability before fixes.
```

### lesson 2 · the well-formed branch was lying

The first observability PR (#1989) emitted a thin INFO payload on the well-formed branch (`roleSequence + messageCount`) to keep log volume sane. The second PR (#1991) was forced-shipped within an hour because the thin payload couldn't distinguish "API rejects despite detector clean" from "detector saw an orphan I missed." If you ship the in-memory detector and skip the enriched-on-well-formed payload, you're shipping observability that hides exactly the case you're investigating.

Always emit the full per-message detail on the well-formed branch when you're in investigation mode. Trim it back AFTER the fix lands.

### lesson 3 · don't compute the wire bytes in two places

The wire-byte log captures `command.input.body` (the bytes already inside the SDK's command object), not a fresh `JSON.stringify(requestBody)`. Computing the hash from a re-stringify would NOT prove anything · it'd just confirm that the in-memory detector and your second stringify produce the same bytes (which they would). The whole point is to capture what the SDK has already serialized, not what you'd serialize independently.

### lesson 4 · privacy contract is non-negotiable

Production traffic contains DTC pastes, customer complaints, VINs, internal-tool args. The shape skeleton MUST capture roles + content-block types + IDs + ID-references only. Never raw text, tool input, or tool_result content body. The wire-byte log captures `length + sha256-prefix`, never the bytes themselves.

Verify privacy at PR-author time with explicit unit tests that assert sensitive strings DON'T appear in the structured log output. The Olympus #1989 PR had 3 such tests; they prevent a future contributor from regressing the contract.

### lesson 5 · post the decision tree before the data lands

In a multi-session debugging thread, post the decision tree in advance:

```
| Log result                                     | Hypothesis confirmed | Next move          |
| WARN ill-formed (orphans listed)               | sanitizer gap        | Author upstream fix |
| INFO well-formed + wire hash matches in-memory | external stricter    | Read API docs       |
| INFO well-formed + wire hash diverges          | mid-flight mutation  | Instrument SDK      |
```

This pre-commits the team to a next-action regardless of what the data shows. Without it, the data lands and everyone re-litigates what to do next; with it, the next PR's owner is unambiguous.

## Invariants consulted

- `every-claim-has-evidence` (`verify-before-claim`) · the staged observability is what GENERATES the evidence the fix-PR cites
- `coord-pr-as-message-bus` · instrument-then-fix is naturally a multi-session pattern; the coord thread holds the decision tree

## Integration points

- Triggers `verify-receipts-before-flawless-claim` after the fix lands · the closure receipt requires both client + server evidence
- May trigger `gh-api-push-pr` for the rapid-fire instrumentation PRs
- May trigger `coord-pr-as-message-bus` when multiple sessions debug in parallel

## Completeness Principle

This skill is complete when, for any production bug whose source-trace audit and reproducer disagree, the team's first instinct is "ship N observability PRs THEN one fix" rather than "ship a speculative fix."

A successful invocation should produce a verifier run whose log lines and wire fingerprints, taken together, eliminate every competing hypothesis except one.

## Changelog

- v0.1.0 (2026-05-01) · initial · forged from the Olympus Bedrock launch-blocker arc
