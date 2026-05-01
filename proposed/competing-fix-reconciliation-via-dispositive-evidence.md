---
name: competing-fix-reconciliation-via-dispositive-evidence
namespace: session-lessons
version: 0.1.0
description: |
  Triggers when two sessions diagnose the same production bug with DIFFERENT
  root-cause mechanisms and propose different fixes. Use the dispositive-
  evidence test ("which hypothesis explains BOTH failing cases?") to converge
  on the right fix without losing time to competing patches. The losing
  hypothesis usually points at a real-but-separate latent issue worth
  filing as a follow-up.
allowed-tools:
  - Bash
  - Read
  - Grep
provenance: forged 2026-05-01 from the Bedrock 400 launch-blocker debug chain where K and E proposed different fix shapes for the same failure mode within minutes of each other on the coord PR thread
---

# competing-fix-reconciliation-via-dispositive-evidence · converge two hypotheses on shared evidence

## Why this exists

Two (or more) autonomous sessions debugging the same failure each capture evidence, post an analysis, and propose a fix. The proposals are different. Without reconciliation:

- Both sessions ship competing PRs
- Reviewers do not know which to merge
- One fix may shadow the other, masking a residual issue
- Trust between sessions erodes

You need to converge fast and pick the live root cause, not the most-confidently-asserted one. The dispositive-evidence test does this with two captured failing cases plus a side-by-side asymmetry table: a correct mechanism must apply to all manifestations of the same bug class. A hypothesis that fits one case but not another is either a different bug that happens to look similar, or a correct observation that has been mis-attributed to root cause. Either way it is not THE fix for the live blocker. The losing hypothesis is almost always pointing at a real (separate) thing; acknowledge it, file it as a follow-up, do not bury it. This is the discipline that closed the 2026-05-01 H7 launch-blocker in roughly 10 minutes after K and E diverged.

## Preamble (run first)

```bash
# Surface top-3 relevant prior lessons for this skill
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag competing-fix-reconciliation --limit 3 2>/dev/null || true
fi

# Session identity (used when capturing new lessons)
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
export _SESSION_NAME

# Slug for the current project's learnings.jsonl
if [ -x ~/.claude/skills/gstack/bin/gstack-slug ]; then
  eval "$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null)"
fi
_LEARNINGS_FILE="${GSTACK_HOME:-$HOME/.gstack}/projects/${SLUG:-unknown}/learnings.jsonl"
export _LEARNINGS_FILE
```

## Trigger conditions

Fire this skill when:

1. Two (or more) autonomous sessions have posted analyses of the same production failure to a coord thread or fix-PR thread within a tight window
2. The proposed fix shapes are mechanistically different (not just stylistic refactors of the same change)
3. Each session has at least one captured failing case (conv ID, log line, repro) attached to its analysis
4. A merge / ship decision is pending and the reviewer (Lee, an orchestrator, or another session) is asking "which fix do we take?"
5. You are tempted to "ship both fixes to be safe"; STOP and run the dispositive test instead

## Workflow

### Phase 1 · Inventory the captured cases

Each session has captured at least ONE failing case. To converge, you need at least TWO independent failing cases. Often you already have them across the proposing sessions. Pull each case into a normalized shape:

```
Case A (proposed by session K, conv 155bf5ea):
  - structure: <what does the failing payload look like>
  - observed error: <exact error string>
  - data points the proposer flagged: <list>

Case B (proposed by session E, conv 0ddc250e):
  - structure: ...
  - observed error: ...
  - data points the proposer flagged: ...
```

If you only have one case, this skill cannot yet fire; collect a second reproduction first.

### Phase 2 · Apply the dispositive test to each hypothesis

For each proposed root-cause hypothesis, ask:

1. Does this hypothesis explain Case A? (The session that proposed it should pass.)
2. Does this hypothesis explain Case B? (The other session's case.)

The hypothesis that explains BOTH cases is the live root cause. The hypothesis that only explains the case its proposer captured is observing a real-but-different phenomenon, probably a latent issue worth tracking, not the live blocker.

### Phase 3 · Build the side-by-side asymmetry table

Lay it out so the asymmetry is obvious to a reader who has not been in the debug chain:

| Hypothesis | Explains Case A? | Explains Case B? |
|---|---|---|
| K (consecutive tool_use) | YES (interleaved blocks at idx=1) | YES (interleaved blocks at idx=1, both have text between tool_uses) |
| E (positional matching) | NO (K's order already matches, yet still 400d) | YES (positions clearly mismatched) |

The hypothesis with two YES rows wins. The hypothesis with a NO row is the latent finding.

### Phase 4 · Write the reconciliation post

Structure the post for fast reviewer scan:

1. Summary in one sentence: "X's hypothesis is the live root cause; Y's observation is a real but separate latent concern."
2. Side-by-side evidence table (Phase 3 output) inline.
3. The dispositive test inline: for each hypothesis, "does it explain case A? case B?" Show your work.
4. The verdict: which hypothesis to ship, why.
5. The follow-up: file the losing hypothesis as a separate ticket / regression-lock test. Do not dismiss it.

### Phase 5 · Verify post-deploy

Reconciliation is necessary but not sufficient for closure. After the chosen fix merges and deploys, re-run the live verifier (see `acceptance-test-after-deploy-not-merge`). Mark the bug resolved only when verifier returns clean against deployed code.

## Seed lessons

```jsonl
{"id":"sha256-cfr-001","ts":"2026-05-01","session":"session-c","skill":"competing-fix-reconciliation-via-dispositive-evidence","pattern":"two sessions proposed different root causes for the same Bedrock 400; without reconciliation both PRs would have shipped","evidence":"K's PR #1993 (consecutive-tool_use partition fix) vs E's 05:04Z post on PR #1989 (positional-matching hypothesis); K's hypothesis explained both convs 155bf5ea and 0ddc250e, E's only explained 0ddc250e","fix":"build the side-by-side asymmetry table; ship the hypothesis with two YES rows; file the other as a separate latent-quirk regression test","severity":"P0","scope":"generic","tags":["multi-session","root-cause","reconciliation","bedrock"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
{"id":"sha256-cfr-002","ts":"2026-05-01","session":"session-c","skill":"competing-fix-reconciliation-via-dispositive-evidence","pattern":"hypothesis only explains the proposer's own captured case, not the other session's","evidence":"E's positional-matching hypothesis explained conv 0ddc250e (tool_result IDs permuted [Y,Z,X] vs tool_use [X,Y,Z]) but did NOT explain conv 155bf5ea where IDs were already in matching order yet still returned Bedrock 400","fix":"a hypothesis that fails on a sibling case is observing a real latent thing, not the live root cause; file it as a follow-up regression-lock test, do not ship it as the live fix","severity":"P1","scope":"generic","tags":["dispositive-evidence","hypothesis-test","latent-bug"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-cfr-001"],"evidence_count":1}
{"id":"sha256-cfr-003","ts":"2026-05-01","session":"session-c","skill":"competing-fix-reconciliation-via-dispositive-evidence","pattern":"7 reproductions across distinct conv IDs accumulated before reconciliation; the asymmetry was already in the data before either session noticed","evidence":"convs e02d6177, dc36b109, f0adc326, e48fce02, 0ddc250e, a2835b69, 155bf5ea all 400d on Bedrock; K's consecutive-tool_use mechanism applied to all 7, E's positional-matching only to a subset","fix":"when N>2 reproductions exist, run the dispositive test against the broadest set, not just the two cases each proposer flagged; the broader the asymmetry holds, the higher confidence in the verdict","severity":"P1","scope":"generic","tags":["evidence-set","hypothesis-test","sample-size"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-cfr-001"],"evidence_count":1}
{"id":"sha256-cfr-004","ts":"2026-05-01","session":"session-c","skill":"competing-fix-reconciliation-via-dispositive-evidence","pattern":"compromise via 'ship both fixes to be safe' adds dead-code risk and confuses future debuggers","evidence":"if only one is the root cause, the other is dead code; worse, it adds a spurious 'this shape was an issue' signal that misleads future debuggers reading the diff history","fix":"ship the winning hypothesis only; track the other as an explicit latent-quirk follow-up with its own PR title so the diff history reads correctly","severity":"P2","scope":"generic","tags":["anti-pattern","dead-code","diff-history"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-cfr-001"],"evidence_count":1}
{"id":"sha256-cfr-005","ts":"2026-05-01","session":"session-c","skill":"competing-fix-reconciliation-via-dispositive-evidence","pattern":"mediating by author seniority instead of by evidence","evidence":"'K usually gets it right' is not an argument; the dispositive test produces a verifiable verdict in 5 minutes and is the canonical signal","fix":"build the asymmetry table even when one hypothesis seems clearly right; forces assumption-checking and surfaces the case where both are partially correct","severity":"P2","scope":"generic","tags":["anti-pattern","authority-bias"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-cfr-001"],"evidence_count":1}
```

## Invariants consulted

- **Invariant 1 · Run the check before claiming**: the asymmetry table IS the check; without it, a "this is the root cause" claim is unverified
- **Invariant 6 · Every declared metric has a caller**: analogous discipline; every claimed mechanism must have a citing case for each manifestation, not just the one the proposer captured

## Integration points

- `verify-before-claim`: the reconciliation post itself must cite the asymmetry table inline; "K's hypothesis is right" without the table is an unverified claim
- `coord-pr-as-message-bus`: the channel where the reconciliation post lands; structure it as a single comment so the auto-tick / reviewers can scan the verdict in 3 seconds
- `bedrock-h7-consecutive-tool-use`: the mechanism-specific skill encoding K's winning hypothesis; this skill is the meta-pattern, that skill is the concrete content
- `two-point-measurement-disambiguates-h5h6h7`: the upstream pattern that produces the second case needed for the dispositive test
- `hypothesis-tree-before-observability`: the upstream skill that lays out which hypotheses are even on the table before evidence collection starts
- `acceptance-test-after-deploy-not-merge`: the downstream skill; reconciliation picks the fix, acceptance verifier closes the bug

## Completeness Principle

Completeness 10/10: collect every captured case across all proposing sessions, build the full asymmetry table, write the reconciliation post with verdict + follow-up, file the losing hypothesis as a tracked ticket, re-run the live verifier post-deploy.

Completeness 7/10: build the asymmetry table for the two strongest cases, ship the winning fix, mention the losing hypothesis in the reconciliation post but skip the formal follow-up ticket.

Completeness 3/10: pick the fix by author seniority or by who posted first, skip the table, leave the residual hypothesis unmentioned.

**Default target: 10/10.** The cost of a 5-minute asymmetry table is trivial against the cost of shipping the wrong fix or losing track of a real latent quirk.

## Changelog

- v0.1.0 (2026-05-01) initial draft from Session C launch-blocker debug; 5 seed lessons covering the dispositive test, asymmetry-table discipline, broad-evidence application, anti-compromise, and anti-authority-bias.
