---
name: hypothesis-tree-before-observability
namespace: session-lessons
version: 0.1.0
description: |
  Triggers when you're about to debug a production failure by adding logs.
  Write the hypothesis tree (H1...HN, ranked) BEFORE writing the log line.
  Then design the log to pin which H. This avoids the speculative-fix
  cycle where a session adds a log, sees something interesting, ships a
  fix, and the bug still fires because they fixed the wrong H. Catches
  the failure mode where instrumentation is reactive (designed to see
  whatever is convenient) instead of dispositive (designed to disambiguate
  ranked hypotheses).
allowed-tools:
  - Bash
  - Read
  - Grep
provenance: forged 2026-05-01 from the Bedrock 400 launch-blocker debug chain (PRs #1985 to #1990 to #1991 to #1992 to #1993)
---

# hypothesis-tree-before-observability

## Why this exists

The default flow when production fails is: add a `console.log` near the suspicious code path, redeploy, see something interesting, assume that's the cause, ship a fix. The bug still fires. Add another log, see another interesting thing, ship another fix. The bug still fires.

Each cycle is 10 to 30 minutes (build, merge, deploy, re-test). At five cycles you've burned two hours and haven't fixed anything. Worse, the speculative fixes accumulate as defensive companions in the codebase that are now load-bearing for unclear reasons. PRs #1985 (finalMileSanitize) and #1990 (source-side orphan-guard) on the 2026-05-01 launch-blocker were exactly this: shipped before the H was confirmed, neither resolved the bug, both became defensive-only weight in the source.

A hypothesis tree fixes this. Enumerate the candidate mechanisms BEFORE adding instrumentation. Design the log to disambiguate them in a single re-deploy. The log line is intentional, not reactive. One verifier run produces THE H. You write THE fix, not A fix.

This skill is the meta-discipline: how to debug without burning fix-cycles on the wrong root cause.

## Preamble (run first)

```bash
# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag hypothesis-tree --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
export _SESSION_NAME
```

## Trigger conditions

Fire this skill when:

1. Production is failing with a clear symptom but the mechanism is ambiguous
2. You can reproduce the failure (a known input that deterministically triggers it)
3. A fix-cycle costs 10+ minutes per iteration (build, deploy, re-test)
4. You're tempted to add a `console.log` at a suspicious code path without first enumerating what you're trying to learn

Skip this skill for:

- Trivial bugs with one obvious cause (`undefined is not a function` at a specific line). Just fix it.
- Performance questions ("why is this slow?"). Profile, don't enumerate.
- First production deploy of new code where the failure mode is "it doesn't work at all". Read your own diff first.

## Workflow

### Phase 1 . Enumerate the hypotheses BEFORE writing any log line

For a failure mode with N possible causes, enumerate them as H1, H2, H3, ... HN. For each, specify three things:

1. What it would mean if true (the actual mechanism)
2. What evidence would confirm it (a specific log signature, a specific pattern in data)
3. What evidence would eliminate it (a specific signal that disproves it)

The minimum useful tree has TWO distinct mechanisms that the symptom is consistent with. A "tree" with one H is just a guess.

### Phase 2 . Disprove the cheap Hs first

H1 / H2 are usually "did the deploy actually happen" / "is the new code on the path being exercised". These are cheap to confirm:

- `git log -1` on the deploy host vs expected commit
- A trivially-added log on every entry to the suspect code path, fires on every reproduction

Many post-mortems boil down to "the fix wasn't deployed" or "the recursion bypassed the sanitizer". Confirm the cheap Hs FIRST, before designing deeper-tree instrumentation.

### Phase 3 . Design the log line to disambiguate

For every hypothesis, ask: what is the cheapest test that distinguishes this from the others? That's your log line.

If two hypotheses share the same observable signal, you don't have a useful tree. Decompose further until each H has a unique signal.

If you can't distinguish H_a from H_b with any cheap test, ship a single fix that handles BOTH. Don't burn cycles trying to disambiguate without value.

### Phase 4 . Re-deploy once, re-run the verifier once, read the log against the tree

The log either pins one H or rules out a subset. If it pins one, write THE fix targeting that H. If it rules out a subset, the surviving Hs have already been narrowed by a real signal, not a guess.

## Worked example: Bedrock 400 launch-blocker (2026-05-01)

Before instrumentation, the team enumerated:

- H1: stale code on EC2 (deploy didn't land). Disproved by E confirming `git log -1` matched expected commit.
- H2: recursion bypasses sanitizers. Disproved by adding `[bedrock-shape]` log on EVERY Bedrock send and confirming three fires per verifier run (it WAS being called on every recursion).
- H3: upstream `transcriptToMessages` sanitizer gap. Likely if the post-sanitizer array fails K's structural check.
- H4: `finalMileSanitize` boundary gap. Same evidence shape as H3.
- H5: K's detector has a subtle gap on tool_use_id matching. Likely if WARN ill-formed fires.
- H6: array mutates between detector exit and wire send. Likely if WARN well-formed but wire-bytes hash diverges from detector content.
- H7: Bedrock's pairing check is stricter than the detector. Likely if WARN well-formed AND wire hash matches AND Bedrock 400s anyway.

Designed instrumentation to disambiguate:

- Pre-serialize log emits `WARN/INFO` verdict + `blockSummary` per message. Distinguishes H3 / H4 / H5 (ill-formed) from H6 / H7 (well-formed).
- Post-serialize log emits `byteLength + sha256-prefix`. Distinguishes H6 (hash mismatch) from H7 (hash match).

One re-deploy. One verifier run. Result: detector well-formed + wire hash matches detector content + Bedrock 400d. H7 confirmed. Wrote the fix targeting H7 (consecutive tool_use blocks, see `bedrock-h7-consecutive-tool-use`). Shipped, re-deployed, verifier green.

Total time from hypothesis tree to green-verifier: roughly 30 minutes. Without the tree, this debug would have stretched to multiple hours and several speculative-fix PRs (PRs #1985 and #1990 were exactly that, shipped before the tree was complete).

## Anti-patterns

- Hypothesis-of-one. "It's probably H_X." If you only enumerate one, you're not running a tree, you're just guessing. The minimum is two distinct mechanisms that the symptom is consistent with.
- Hypothesis without evidence-test. "It might be a SDK bug." OK, what would prove it? If you can't say, drop it from the tree. It's untestable.
- Skipping disproof on the early Hs. H1 / H2 are usually "did the deploy actually happen" + "is the path being exercised". Cheap to confirm. Confirm them FIRST.
- Reactive logging. Adding a log at a suspicious site without writing down what you're trying to learn. The log will produce data; you won't know what conclusion the data supports until after the next failed fix-cycle.
- Skipping the tree because "it's faster to just try a fix". A fix-cycle is 10 to 30 minutes. A two-minute hypothesis tree pays for itself after one avoided cycle.

## Seed lessons

```jsonl
{"id":"sha256-hypothesis-tree-001","ts":"2026-05-01","session":"session-c","skill":"hypothesis-tree-before-observability","pattern":"shipped speculative fix before hypothesis tree was complete; fix did not resolve symptom","evidence":"PR #1985 finalMileSanitize and PR #1990 source-side orphan-guard merged before the H1-H7 tree was enumerated. Neither resolved the Bedrock 400. Both shipped as defensive-only companions with unclear load-bearing purpose.","fix":"enumerate the candidate Hs (minimum 2 distinct mechanisms with disprove-conditions) BEFORE writing any log line or shipping any fix; design instrumentation to disambiguate them in one re-deploy","severity":"P0","scope":"generic","tags":["debug","speculative-fix","fix-cycle-burn","launch-blocker"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-bedrock-h7-001","sha256-bedrock-h7-002"],"evidence_count":1}
{"id":"sha256-hypothesis-tree-002","ts":"2026-05-01","session":"session-c","skill":"hypothesis-tree-before-observability","pattern":"hypothesis tree complete + log line designed to disambiguate yields root cause in one verifier run","evidence":"H1-H7 enumerated 2026-05-01. PRs #1991 (pre-serialize log) + #1992 (post-serialize log) shipped together. One verifier run on conv 155bf5ea returned: detector WELL-FORMED + wire hash matches + Bedrock 400. Pinned H7 dispositively. PR #1993 (THE fix) shipped within 30 minutes of the dispositive evidence.","fix":"one re-deploy with intentional dispositive instrumentation beats five re-deploys with reactive logs","severity":"P0","scope":"generic","tags":["debug","dispositive-evidence","one-cycle-fix"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-two-point-measurement-001"],"evidence_count":1}
{"id":"sha256-hypothesis-tree-003","ts":"2026-05-01","session":"session-c","skill":"hypothesis-tree-before-observability","pattern":"H1 (stale deploy) and H2 (recursion bypasses sanitizer) skipped initial disproof; deeper-tree instrumentation built on unconfirmed foundation","evidence":"early debug iterations on the Bedrock 400 jumped to H3-H7 instrumentation without first confirming `git log -1` on EC2 matched expected commit. Took an extra session round to backfill the H1 disproof.","fix":"H1/H2 are usually `did the deploy land` and `is the path being exercised`. Disprove these FIRST with cheap signals (`git log -1`, log on every entry to suspect path) before designing deeper instrumentation.","severity":"P1","scope":"generic","tags":["debug","cheap-disproof","ordering"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
{"id":"sha256-hypothesis-tree-004","ts":"2026-05-01","session":"session-c","skill":"hypothesis-tree-before-observability","pattern":"two hypotheses share the same observable signal at one observation point; tree was insufficiently decomposed","evidence":"H6 (SDK mutation) and H7 (API stricter than detector) both produce `detector well-formed + API rejects` at a single observation point. Required adding the wire-bytes hash to decompose them. Without decomposition, both Hs would have been candidates indefinitely.","fix":"if two Hs share the same observable signal, decompose further until each has a unique signal; if you can't decompose, ship a single fix that handles both","severity":"P1","scope":"generic","tags":["debug","decomposition","disambiguation"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-two-point-measurement-001"],"evidence_count":1}
{"id":"sha256-hypothesis-tree-005","ts":"2026-05-01","session":"session-c","skill":"hypothesis-tree-before-observability","pattern":"defensive companion fixes accumulate when speculative fixes ship before root cause is confirmed","evidence":"PRs #1985 + #1990 shipped during the launch-blocker debug. Post-fix retrospective: both fixes are now load-bearing-for-unclear-reasons in the codebase. Removing them is risky because nobody knows what failure mode they were defending against (they were never the actual fix).","fix":"do not ship defensive guards on hypothetical failure modes; ship the fix that targets the confirmed H. If a guard is needed, ship it WITH the confirmed root-cause fix and document which H it covers.","severity":"P1","scope":"generic","tags":["defensive-only","load-bearing-debt","speculative-fix"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-bedrock-h7-002"],"evidence_count":1}
```

## Invariants consulted

- Invariant 1 . Run the check before claiming. The hypothesis tree IS the structured form of "what check would I run to claim this is the bug?" applied before the fix is written, not after.
- Invariant 8 . Two-Claude Review for ship-candidate changes. The reviewer's first question on a debug PR should be "what's the hypothesis tree, and which H does this PR target?" If the answer is "I just tried something", that's a flag.
- Invariant 10 . Completeness trumps brevity. A complete hypothesis tree (every H with a disprove-condition) is cheap; an incomplete tree leaves you guessing which H is live.

## Integration points

- `two-point-measurement-disambiguates-h5h6h7` - the worked instantiation of designing the log to pin H5 vs H6 vs H7.
- `bedrock-h7-consecutive-tool-use` - the resolution leaf for the H7 path of the worked example.
- `verify-before-claim` - the hypothesis tree's disprove-conditions ARE the verifications that back claims like "this is the root cause".
- `coord-pr-as-message-bus` - in multi-session debug, the hypothesis tree lives in the active coord PR comments so all sessions are working off the same enumeration.

## Completeness Principle

This skill is complete when:

1. The hypothesis tree is written down with at least two distinct mechanisms BEFORE any log is added
2. Every H has a specific disprove-condition expressed as a log signature or data pattern
3. The instrumentation is designed to disambiguate the tree in one re-deploy
4. The fix targets the confirmed H, not a hypothetical one; defensive-only fixes are removed or labeled

In other words: the failure mode is detectable BEFORE it ships, not just after.

## Changelog

- v0.1.0 (2026-05-01) initial draft from Session C launch-blocker debug, hypothesis-first discipline + worked Bedrock 400 example
