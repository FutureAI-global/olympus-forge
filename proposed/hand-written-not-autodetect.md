---
name: hand-written-not-autodetect
namespace: session-lessons
version: 0.1.0
description: |
  Hand-write transparency / privacy / scope / authority descriptors and lock
  them with a stability test. Autodetected descriptors silently drift when
  unrelated PRs add fields. Promise = hand. Enforcement = code. Both.
allowed-tools:
  - Read
  - Write
  - Bash
provenance: |
  forged 2026-04-29 from PR #1867 (Olympus CC5 client privacy descriptor)
  and #1873 (server-side redaction sentinel). The instinct to autogenerate
  the "we send X" list from route handlers was real and was the wrong call.
---

# hand-written-not-autodetect · promise = hand. enforcement = code.

## Why this exists

- Some surfaces are **promises to the user**: privacy descriptor, security scope, AI tool authority, compliance attestation. They look like docs but they're contracts.
- Temptation: autogenerate from code (introspect routes, scrape schema, parse import graph). Always feels like the right engineering call — single source of truth, no drift.
- Wrong call. Autodetected promises silently widen when an unrelated PR adds a debug field. The user was promised X; we now send X+Y without telling them. The descriptor became a code-bug-documenter rather than a contract.
- Right shape: hand-write the descriptor in code, gate changes via PR review, and pin downstream-grep'd literals (sentinels, redaction markers) with a stability test that fails loud on rename.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag hand-written-not-autodetect --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Designing a "transparency", "data-flow", "permission", or "safety" surface.
- Privacy descriptor: "we send X, store Y, never collect Z."
- Security scope: "this token grants A, B, C — never D."
- Tool authority manifest: "tool X is `auto`-tier — read-only, idempotent."
- Compliance attestation: "we redact PII before persistence."
- A reviewer asks "does this auto-update from the code?" — that's the moment to push back.

Voice triggers: "transparency surface", "we should auto-generate this list from the routes", "single source of truth for what we send", "scrape the schema for the descriptor".

## Workflow

### Phase 1 · Hand-write the descriptor as a static export

```typescript
/**
 * Static, hand-written transparency descriptor. Updated by hand when
 * data flows change — DO NOT autodetect from code, that silently
 * drifts. Reviewer reads this and knows exactly what's in scope.
 */
export function getTransparencyDescriptor(): string[] {
  return [
    "Sent to api.example.com on each conversation:",
    "  - VIN (truncated to last 6 in logs)",
    "  - Tech-typed message text",
    // ... explicit, enumerated, bounded
  ];
}
```

Hard rule: **changing this list requires a code change with PR review**. The reviewer sees the diff and either ratifies the new promise or pushes back. The cognitive forcing function IS the value.

### Phase 2 · Stability-test downstream-grep'd literals

When the descriptor names a redaction marker, feature flag, enum value, or sentinel — anything downstream consumers (dashboards, eval scorers, log parsers) will grep for — make it a **named export with a pin test**:

```typescript
export const REDACTED_PII = "[redacted-pii-optout]";

describe("REDACTED_PII sentinel stability", () => {
  it("is the literal string downstream consumers grep for", () => {
    // Stability test — if this changes, dashboard / eval consumers
    // will silently drop redaction visibility. Bump deliberately.
    expect(REDACTED_PII).toBe("[redacted-pii-optout]");
  });
});
```

The test pins the literal. Anyone who renames it sees the test fail and is forced to make the change deliberate (and update downstream consumers in the same PR).

### Phase 3 · Use autodetection for ENFORCEMENT, not the promise itself

Autodetection is fine where it catches drift FROM the hand-written promise, not where it generates the promise:

- **Coverage gate** (see `bidirectional-coverage-gate`): every adapter registered in code must have a row in the safety-case doc. Bidirectional set-diff catches drift in either direction. The DOC is hand-written; the GATE catches drift.
- **Tier check at boot**: every tool registered in code must be tagged with a tier (`auto` / `confirm` / `forbidden`). Boot-time crash if missing. Doesn't replace the human-curated authority manifest — enforces it.

Pattern: **promise = hand. enforcement = code.** Both, together.

### Phase 4 · PR review as the ratification step

The descriptor lives in code (not a wiki, not a Notion page). When the descriptor changes, the diff appears in a PR. The reviewer's checklist:

- Does the new line accurately describe what we now send?
- Does the user-facing docs / consent surface need to update too?
- Is anything dropped from the list because it's no longer sent? (Must verify in code, not just trust the diff.)

If the reviewer can't answer those without reading the implementing PR, the descriptor's commit message has to bridge the gap.

## Gotchas

### Don't scrape route handlers to autogen the privacy descriptor

The first PR that adds a debug-only field silently expands what you're promising. The promise drifted; nobody noticed.

### Don't hash-pin instead of stability-testing

Hashing the file locks it but makes diffs unreviewable. Stability test on each named constant gives explicit failure messages — `expected "[redacted-pii-optout]" to be "[redacted-pii]"` is reviewable; "hash mismatch" is not.

### Don't skip the WHY in the descriptor

Saying "we send X" without explaining the boundary leaves the reader to infer scope. Include the why: "VIN, truncated to last 6 in logs because full VIN is PII when logs are exfiltrated."

### Don't rely on the LLM to write the descriptor without review

Even this skill was written by an LLM. The contract is that *the human commits the version that ships*. The LLM's draft is input, not output.

### Don't put the descriptor in a non-code surface

Wiki / Notion / README descriptors don't get PR review. Code descriptors do. Put it in code, export it from the route, render it server-side.

## Invariants consulted

- **Invariant 1 · Promises are contracts** — silent drift on a contract is worse than no contract.
- **Invariant 2 · Cognitive forcing function = the value** — automation removes the human review step that IS the point.
- **Invariant 3 · Downstream consumers grep for literals** — renaming a sentinel without coordinating breaks dashboards silently.
- **Invariant 4 · Promise hand. Enforcement code.** — both layers; never substitute one for the other.

## Seed lessons

1. **Autogen-from-code descriptor silently widens with unrelated PRs** · P0 · generic. The first debug-field add becomes a privacy expansion nobody approved.
2. **Stability tests beat hash-pinning for sentinels** · P1 · generic. Diff readability matters; explicit assertion failure beats opaque hash mismatch.
3. **Coverage gate ≠ autogen** · P1 · generic. Gate catches drift FROM the hand-written promise; never substitutes for it.
4. **Reviewers must see the descriptor diff in the same PR as the implementation change** · P2 · generic. Otherwise the descriptor is updated weeks later, when context is gone.
5. **Wiki/Notion descriptors evade review** · P2 · generic. If it's a contract, it lives in code with PR review.

## Integration

- **`./bidirectional-coverage-gate.md`** — companion: the gate that catches drift FROM the hand-written list (set-diff registered-vs-documented).
- **`/verify-before-claim`** — claims about "we redact X" require the redaction sentinel test to be in the same PR.

## Completeness principle

10/10: hand-written descriptor in code · stability test on each grep'd literal · companion bidirectional coverage gate · PR review is the ratification step.

7/10: hand-written descriptor in code, but no stability tests on sentinels (downstream consumers can be silently broken).

3/10: autogenerated descriptor from route introspection (silent drift on every unrelated PR).

**Default: 10/10.** The descriptor is ~20 lines; the failure mode is "we silently changed the contract" which is the worst possible class of bug for a promise surface.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version forged from PR #1867 + #1873.
