---
name: bedrock-h7-consecutive-tool-use
namespace: session-lessons
version: 0.1.0
description: |
  Triggers when Bedrock 400s with `messages.N: tool_use ids were found
  without tool_result blocks immediately after` AND your sanitizer says
  the array is well-formed (every tool_use_id has a paired tool_result_id
  in the next user message). Anthropic / Bedrock require `tool_use` blocks
  WITHIN a single assistant message to be CONSECUTIVE; a `text` block
  interleaved between two `tool_use` blocks triggers the 400 even when the
  next user message has every paired `tool_result`. Catches the failure
  mode where pairing detectors mark a transcript well-formed but Bedrock
  rejects on intra-message block-order rules.
allowed-tools:
  - Bash
  - Read
  - Grep
provenance: forged 2026-05-01 from the Bedrock 400 launch-blocker debug chain (PRs #1985 to #1990 to #1991 to #1992 to #1993)
---

# bedrock-h7-consecutive-tool-use, what your detector misses

## Why this exists

A pairing detector that only checks "does every tool_use_id in assistant[N] have a matching tool_result_id in user[N+1]" will mark a transcript well-formed when Bedrock will still 400 on it. Bedrock enforces an additional intra-message rule: within a single assistant message's `content` array, all `tool_use` blocks must be CONSECUTIVE. A `text` block sitting between two `tool_use` blocks triggers `messages.N: tool_use ids were found without tool_result blocks immediately after`, even though every matching tool_result is present in the next user turn.

The error string is misleading. The tool_results ARE in the next user message. The violation is about block ordering INSIDE the assistant message, not pairing across messages. Sessions that trust the pairing detector spend hours hunting nonexistent sanitizer gaps.

This skill fires when the symptom is the Bedrock 400 above AND your sanitizer reports well-formed. It captures the rule, the source of the bug, the fix shape, and the test invariant that locks against regression.

## Preamble (run first)

```bash
# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag bedrock-h7 --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
export _SESSION_NAME
```

## Trigger conditions

Fire this skill when:

1. Bedrock 400 surfaces with `messages.N: tool_use ids were found without tool_result blocks immediately after: toolu_bdrk_<id>`
2. Your detector / sanitizer reports the assistant[N] / user[N+1] pair as well-formed (every tool_use_id has a paired tool_result_id)
3. Wire-bytes hash matches detector content (no SDK mid-flight mutation; see `two-point-measurement-disambiguates-h5h6h7` for how to confirm)
4. blockSummary at the failing index shows interleaved blocks like `[text, tool_use, text, tool_use]`

If items 1 and 2 fire but blocks are already consecutive, the bug is elsewhere (look at H5 detector gap or H6 SDK mutation, not H7).

## Workflow

### Phase 1 . Confirm this is H7 not H5 or H6

Walk the diagnosis-first checklist. All three signals must be present together:

- Detector log says `WELL-FORMED` for the failing call. If it says ill-formed, you have a sanitizer gap (H5), not H7.
- Wire-bytes hash matches detector content. If the bytes diverge between detector exit and SDK send, you have SDK mutation (H6), not H7.
- blockSummary at the failing idx shows interleaved tool_use blocks: `["text","tool_use","text","tool_use",...]`. If blocks are already consecutive, the bug is elsewhere.

See `two-point-measurement-disambiguates-h5h6h7` for the observation-point setup that produces these three signals.

### Phase 2 . Locate the merge site

Models like Claude Opus emit responses shaped `narration_1, tool_use_A, narration_2, tool_use_B`. Stream-parsers split this into N typed turns. Somewhere downstream, a message-builder merges consecutive assistant turns into ONE Bedrock-shaped assistant message. The naive append produces:

```typescript
lastOut.content.push(...newBlocks);   // [text_1, tool_use_A, text_2, tool_use_B]
```

Failing shape on the wire:

```
assistant: [text, tool_use_X, text, tool_use_Y]   <- text BETWEEN tool_uses, REJECTED
user:      [tool_result_X, tool_result_Y]
```

Accepted shape:

```
assistant: [text, text, tool_use_X, tool_use_Y]   <- non-tool_use first, tool_use last
user:      [tool_result_X, tool_result_Y]
```

### Phase 3 . Apply the stable-partition fix

Stable-partition the merged assistant content: all non-tool_use blocks first (preserving order), then all tool_use blocks (preserving order). One filter per category, both preserve insertion order:

```typescript
lastOut.content.push(...newBlocks);
const nonToolUse = lastOut.content.filter((b) => b?.type !== "tool_use");
const toolUse    = lastOut.content.filter((b) => b?.type === "tool_use");
lastOut.content  = [...nonToolUse, ...toolUse];
```

Order within each category is preserved (text narrations stay in model-emission order; tool_uses stay in dispatch order). Only the within-message position is normalized.

### Phase 4 . Lock the rule with a per-block walk invariant

```typescript
for (let i = 0; i < content.length; i++) {
  if (content[i].type === "tool_use") {
    const next = content[i + 1]?.type;
    // Either at end of message, or next is tool_use. Never text after.
    if (next !== undefined) expect(next).toBe("tool_use");
  }
}
```

This invariant catches any future regression where text gets re-interleaved by another merge path.

## What this is NOT

- Not a tool_result ordering issue. Bedrock accepts tool_results in any order within the next user message, as long as every tool_use_id has a match.
- Not a "tool_use must be the last block in assistant content" rule. Multiple consecutive `tool_use` blocks at the end is fine; the rule is no-text-between-tool_uses.
- Not a streaming-only quirk. Both streaming-raw and non-streaming raw paths enforce the same rule.

## Seed lessons

```jsonl
{"id":"sha256-bedrock-h7-001","ts":"2026-05-01","session":"session-c","skill":"bedrock-h7-consecutive-tool-use","pattern":"sanitizer reports well-formed but Bedrock 400s on `tool_use ids were found without tool_result blocks immediately after`","evidence":"PR #1993 merged 2026-05-01T05:08:58Z. 5 deterministic Bedrock 400 reproductions across 3 sessions on conv IDs e02d6177, dc36b109, f0adc326, e48fce02, 0ddc250e, a2835b69, 155bf5ea. blockSummary[1] showed [text,tool_use,text,tool_use] on every failing call.","fix":"stable-partition merged assistant content: nonToolUse blocks first then toolUse blocks, both preserving insertion order","severity":"P0","scope":"generic","tags":["bedrock","tool-use","intra-message-order","launch-blocker"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-two-point-measurement-001"],"evidence_count":1}
{"id":"sha256-bedrock-h7-002","ts":"2026-05-01","session":"session-c","skill":"bedrock-h7-consecutive-tool-use","pattern":"defensive source-side orphan-guard added before root cause was known","evidence":"PR #1990 source-side orphan-guard merged before H7 was confirmed. Did not fix the bug because the array was already well-formed; the guard removed nothing. Net cost: a load-bearing defensive companion in the codebase with unclear purpose.","fix":"do not ship defensive guards on hypothetical failure modes; ship the fix that targets the confirmed H","severity":"P1","scope":"generic","tags":["speculative-fix","defensive-only","h7"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-hypothesis-tree-001"],"evidence_count":1}
{"id":"sha256-bedrock-h7-003","ts":"2026-05-01","session":"session-c","skill":"bedrock-h7-consecutive-tool-use","pattern":"Bedrock error string `tool_use ids were found without tool_result blocks immediately after` misread as a pairing-across-messages bug","evidence":"PRs #1985, #1990 both targeted the assistant-then-user pairing surface (finalMileSanitize, source-side orphan-guard). Both shipped, neither resolved the 400. Actual rule was intra-message block ordering inside the assistant message.","fix":"read Bedrock errors as candidate-not-conclusion. The string can describe an intra-message ordering rule even when it sounds like a cross-message pairing rule.","severity":"P1","scope":"generic","tags":["bedrock","error-string-trap","root-cause"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
{"id":"sha256-bedrock-h7-004","ts":"2026-05-01","session":"session-c","skill":"bedrock-h7-consecutive-tool-use","pattern":"merging consecutive assistant turns via naive `lastOut.content.push(...newBlocks)` interleaves text and tool_use","evidence":"transcriptToMessages assistant-merge branch in the bedrock service: model emits narration_1 / tool_use_A / narration_2 / tool_use_B; stream parser splits into 4 turns; merge produced [text, tool_use, text, tool_use]; Bedrock rejected.","fix":"after push, stable-partition: const nonToolUse = content.filter(b => b.type !== 'tool_use'); const toolUse = content.filter(b => b.type === 'tool_use'); content = [...nonToolUse, ...toolUse]","severity":"P0","scope":"generic","tags":["bedrock","stable-partition","merge-site"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
```

## Invariants consulted

- Invariant 1 . Run the check before claiming. PR #1993 was claimed merged with raw verifier-stream output (`narration-delta` events, no Bedrock 400 in the same window) cited inline. Pre-fix the same verifier produced the deterministic 400.
- Invariant 6 . Every declared metric has a caller. The `[bedrock-shape]` and `[bedrock-wire]` logs (PRs #1991, #1992) are observability primitives; without them the H5 / H6 / H7 disambiguation is impossible.

## Integration points

- `two-point-measurement-disambiguates-h5h6h7` - the observation-point setup that confirms this is H7 and not H5 or H6. PRs #1991 + #1992 implement that setup; this skill consumes its output.
- `hypothesis-tree-before-observability` - the hypothesis tree this skill is the resolution leaf of. H7 was one of seven enumerated hypotheses; this skill captures what to do once H7 is confirmed.
- `verify-before-claim` - PR #1993 ships only after the live verifier produces normal `narration-delta` events with no Bedrock 400, cited in the PR body.
- `coord-pr-as-message-bus` - the cross-session coordination on PR #1903 (v8 coord) carried the H1 to H7 enumeration and the dispositive evidence packet.

## Completeness Principle

This skill is complete when:

1. The Bedrock 400 fires deterministically on a known-bad input (interleaved blocks)
2. The detector reports well-formed for that same input
3. The wire-bytes hash matches the detector content for that input
4. The fix changes the wire bytes such that Bedrock returns 200, with the per-block walk invariant covering it as a unit test

In other words: the failure mode is detectable BEFORE it ships, not just after.

## Changelog

- v0.1.0 (2026-05-01) initial draft from Session C launch-blocker debug, Bedrock 400 root-cause + fix shape + per-block walk invariant
