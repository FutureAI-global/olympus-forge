---
name: two-point-measurement-disambiguates-h5h6h7
namespace: session-lessons
version: 0.1.0
description: |
  Triggers when a layer says "the data looks fine" but a downstream system
  rejects with a structural error. To diagnose whether the bug is a
  detector gap (H5), an in-flight mutation between detector exit and wire
  send (H6), or the downstream system being stricter than the detector
  knows about (H7), you need TWO observation points: pre-serialize and
  post-serialize. Without both, H6 and H7 are indistinguishable and
  sessions ship speculative fixes for the wrong root cause. Catches the
  failure mode where one observation point lies and the other is missing.
allowed-tools:
  - Bash
  - Read
  - Grep
provenance: forged 2026-05-01 from the Bedrock 400 launch-blocker debug chain (PRs #1985 to #1990 to #1991 to #1992 to #1993)
---

# two-point-measurement-disambiguates-h5h6h7

## Why this exists

When a sanitizer says "well-formed" but a downstream API rejects with a structural error, the next move is usually wrong. Sessions assume detector gap (H5) and add more sanitizer code, or assume API stricter-than-detector (H7) and hand-write a fix, or assume in-flight mutation (H6) and rebuild the SDK call site. Each is a 10 to 30 minute fix-cycle and the bug still fires after each one because the H was wrong.

You can't ship a fix until you know which H. A speculative fix for H5 won't help if the bug is H7. Without two observation points (one pre-serialize, one post-serialize), H6 and H7 are indistinguishable: in both, the detector says well-formed, and the API rejects. The only difference is whether the bytes mutated between the two observation points.

This skill defines the two-point measurement setup, the decision tree for H5 / H6 / H7 disambiguation, and the privacy contract that lets you log structural shape without leaking content.

## Preamble (run first)

```bash
# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag two-point-measurement --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
export _SESSION_NAME
```

## Trigger conditions

Fire this skill when:

1. A sanitizer or detector reports the in-memory data structure as well-formed
2. A downstream API rejects the same payload with a structural error
3. You have at least one reproducible failing call (correlation key tied to the rejection)
4. The hypothesis tree has at least three candidate Hs that share the same observable signal at a single observation point

If the symptom is "the detector says ill-formed AND the API rejects", you have H5 already; you don't need two-point measurement. If the symptom is "the detector never logs at all", fix that first; this skill assumes the detector exists.

## Workflow

### Phase 1 . Place the two observation points

```
[ source data ]
     |
     v
+---------------------+         POINT 1: detector log
|  sanitizer/detector |  ---->  emit `[detector] <verdict> + structural-summary`
+---------------------+
     |
     v
+---------------------+
|   serializer/SDK    |
+---------------------+
     |
     v
+---------------------+         POINT 2: wire-bytes log
|   pre-wire layer    |  ---->  emit `[wire] byteLength + sha256-prefix-of-payload`
+---------------------+
     |
     v
[ downstream API ]
     |
     v
[ rejection ]
```

Both logs MUST tag with the same correlation key (request-id, conversation-id, etc.) so you can pair them across N requests.

### Phase 2 . Read the decision tree

For a given failing call, check both signals together:

| Detector verdict | Wire-bytes hash | Conclusion |
|---|---|---|
| `WARN ill-formed` | (irrelevant) | H5: detector flagged the orphan but didn't auto-fix it. Sanitizer gap. |
| `INFO well-formed` | hash matches detector content | H7: detector and wire agree, API is stricter than detector knows. |
| `INFO well-formed` | hash diverges from detector content | H6: something between detector exit and wire mutated the payload. |

Without BOTH points, H6 and H7 are indistinguishable. You'll waste a fix-cycle.

### Phase 3 . Implement the detector log

At the sanitizer's exit, emit per-message structure (no content):

- Per-message `blockSummary`: role, block-types in order, tool_use_ids per assistant, tool_result_refs per user
- Verdict (WARN if any orphan detected, INFO otherwise)
- Correlation key (conversation_id or equivalent)

The detector log MUST emit on every send, not just on errors. The well-formed cases are the comparisons that prove H7.

### Phase 4 . Implement the wire log

Immediately before the SDK send call, emit:

- byteLength of the serialized body
- First 16 chars of sha256(body) (full hash is overkill; prefix collisions on a tiny set of requests are negligible)
- Same correlation key as the detector log

Hash-of-bytes is dispositive. If `sha256(detector_view) === sha256(wire_bytes)`, no mutation. If not, you have H6.

### Phase 5 . Privacy contract: shape only, never content

Both logs emit STRUCTURE, not content. No raw text, no tool args, no tool result payload. The schema (role + block-types + ids + correlation key) is enough to debug pairing / ordering bugs; user data leaks would violate the privacy contract. Any field that COULD contain user data is replaced with a type tag.

## Why one observation point is insufficient

Pre-serialize alone: the detector operates on the in-memory data structure. JSON.stringify + content-block transformation in some SDKs (notably AWS SDK content-block discriminated unions) can drop fields, reorder, or normalize values. If the detector sees `[text, tool_use]` blocks but the SDK serializer emits `[tool_use, text]` for some opaque reason, the detector log lies about the wire. You'll think you have H7 when you actually have H6.

Post-serialize alone: if the detector never logs structural summary, you can't tell whether the wire bytes are correct-but-rejected (H7) or already-malformed (H5). The post-serialize log gives you "what hit the wire". The pre-serialize log gives you "what the sanitizer thought it was sending". You need both halves to know which one lied.

## Worked example

PRs #1989 + #1991 = pre-serialize log (`[bedrock-shape]` with full blockSummary on the well-formed branch). PR #1992 = post-serialize log (`[bedrock-wire]` with byteLength + bodyHash16). Together, K's verifier on conv `155bf5ea-f522-4b12-a131-123c97948cbf` produced:

```
[bedrock-shape] WELL-FORMED . roleSequence: user>assistant>user
  blockSummary[1] assistant blocks=[text,tool_use,text,tool_use] toolUseIds=[A,B]
  blockSummary[2] user      blocks=[tool_result,tool_result]    toolResultRefs=[A,B]
[bedrock-wire] bodyByteLength=61639  bodyHash16=680fda6068608847
Bedrock 400: messages.1: tool_use ids without tool_result blocks ... A
```

Detector well-formed + wire-bytes hash matches detector content + Bedrock still 400d. H7 confirmed (Bedrock stricter), no detector gap, no SDK mutation. The structural summary at idx=1 (`[text,tool_use,text,tool_use]`) revealed the actual rule: tool_uses must be consecutive (see `bedrock-h7-consecutive-tool-use`).

## Anti-patterns

- Logging only on the WARN path. "We only log when something looks wrong." But the failing case may be on the well-formed-yet-rejected branch (H6 / H7). Log every send.
- Conditional structural detail. "Emit blockSummary only on ill-formed." Same problem. The structural summary on well-formed cases is what proves H7.
- Logging payload hash without the structural summary. You'll know the SDK didn't mutate, but you won't know the structure. You'll be stuck guessing why the API rejected.
- Logging structural summary without the wire hash. You'll see what the detector thought, but not what shipped. H6 invisible.

## Seed lessons

```jsonl
{"id":"sha256-two-point-measurement-001","ts":"2026-05-01","session":"session-c","skill":"two-point-measurement-disambiguates-h5h6h7","pattern":"detector reports well-formed and API rejects; one observation point cannot distinguish H6 (mutation) from H7 (API stricter)","evidence":"7 reproduction conv IDs across K/I/C: e02d6177, dc36b109, f0adc326, e48fce02, 0ddc250e, a2835b69, 155bf5ea. PRs #1989 + #1991 + #1992 added two-point logs that resolved H7 in one verifier run.","fix":"emit detector log (verdict + blockSummary + correlation key) at sanitizer exit AND wire log (byteLength + sha256-prefix + correlation key) at SDK pre-send. Decision tree on the two signals together yields H5/H6/H7.","severity":"P0","scope":"generic","tags":["observability","two-point","disambiguation","sanitizer","sdk-mutation"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-bedrock-h7-001","sha256-hypothesis-tree-001"],"evidence_count":1}
{"id":"sha256-two-point-measurement-002","ts":"2026-05-01","session":"session-c","skill":"two-point-measurement-disambiguates-h5h6h7","pattern":"detector log emits only on the WARN branch; well-formed-yet-rejected calls have no structural summary","evidence":"early iterations of the bedrock-shape log fired only when verdict was WARN. Failing calls were on the WELL-FORMED branch and produced no blockSummary. PR #1991 moved the blockSummary emission to the WELL-FORMED branch as well.","fix":"detector log emits on every send, not just on errors. Well-formed cases ARE the comparison data that proves H7.","severity":"P1","scope":"generic","tags":["observability","conditional-logging-trap","every-send"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
{"id":"sha256-two-point-measurement-003","ts":"2026-05-01","session":"session-c","skill":"two-point-measurement-disambiguates-h5h6h7","pattern":"wire log captures byteLength only without hash; cannot rule out H6","evidence":"intermediate observability state had byteLength but no hash. Two failing calls with byteLength=61639 were assumed identical; H6 (SDK mutation that preserves length but reorders) was invisible. PR #1992 added bodyHash16.","fix":"wire log includes both byteLength AND first-16-of-sha256. Identical length with different hash = SDK mutation = H6.","severity":"P1","scope":"generic","tags":["observability","wire-log","sha256-prefix"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
{"id":"sha256-two-point-measurement-004","ts":"2026-05-01","session":"session-c","skill":"two-point-measurement-disambiguates-h5h6h7","pattern":"observability log includes raw content (tool args, text); privacy regression","evidence":"draft of the bedrock-shape log included tool args and message text in the structural summary. Caught in review before merge. Final shape emits only role + block-types + ids + correlation key.","fix":"both logs emit STRUCTURE (role, block-type, id, correlation-key) only. No raw text, no tool args, no tool_result payload. Type tags only for fields that could contain user data.","severity":"P1","scope":"generic","tags":["privacy","observability","structural-only"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
```

## Invariants consulted

- Invariant 1 . Run the check before claiming. The two-point logs are the verification surface for any claim about pairing or wire-shape correctness.
- Invariant 6 . Every declared metric has a caller. Both `[bedrock-shape]` and `[bedrock-wire]` log lines are the callers that make the structural assertions visible; without them, claims about wire shape are unverifiable.
- Invariant 7 . Every silent-catch has a signal. Detector verdicts are the structured signal that distinguishes "we silently dropped a malformed call" from "we shipped a well-formed call that the API rejected".

## Integration points

- `bedrock-h7-consecutive-tool-use` - the resolution leaf when this skill's decision tree returns H7 with a `[text, tool_use, text, tool_use]` blockSummary.
- `hypothesis-tree-before-observability` - this skill is the worked instantiation of "design the log to pin which H" for sanitizer-vs-mutation-vs-stricter-API debugging.
- `verify-before-claim` - the two logs ARE the evidence that backs claims like "wire shape is correct" or "no SDK mutation between detector exit and send".
- `coord-pr-as-message-bus` - the disambiguation output (H7 confirmed) was relayed across sessions on the active coord PR with the structural summary as the dispositive evidence.

## Completeness Principle

This skill is complete when:

1. Both observation points emit on every send (not just errors) with the same correlation key
2. The decision tree resolves to a single H for every failing call
3. The privacy contract holds: no raw content in either log
4. A fresh failing call can be diagnosed in one verifier run, not multiple speculative-fix cycles

In other words: the failure mode is detectable BEFORE it ships, not just after.

## Changelog

- v0.1.0 (2026-05-01) initial draft from Session C launch-blocker debug, two-point setup + decision tree + privacy contract
