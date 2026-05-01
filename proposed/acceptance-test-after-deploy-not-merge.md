---
name: acceptance-test-after-deploy-not-merge
namespace: session-lessons
version: 0.1.0
description: |
  Triggers when you are tempted to claim a bug-fix PR has resolved a
  production failure based on PR-merge state alone. Merge to staging is
  necessary but not sufficient. The acceptance gate is the live verifier
  running clean against deployed code on the production host. Until that
  verifier returns clean, the PR is "fix shipped, awaiting acceptance",
  not "fixed".
allowed-tools:
  - Bash
  - Read
  - Grep
provenance: forged 2026-05-01 from the Bedrock 400 launch-blocker debug chain where multiple "fix shipped" claims were premature until the post-deploy verifier (acceptance conv ccd45118) proved closure on the production host
---

# acceptance-test-after-deploy-not-merge · merge starts the deploy clock, the verifier ends the bug

## Why this exists

A PR that fixes a production failure was just merged. Someone (you, a coord pane, an agent, an orchestrator scanning auto-ticks) is tempted to declare the bug resolved. The bug is not resolved until BOTH:

1. The merged code is deployed to the production host
2. A live reproducer (verifier) runs clean against that deployed code

Until both happen, the merge is just a candidate fix. Common ways merge-state misleads: PR is merged to staging but production deploys from main; main is updated but EC2 hosts pull from a flat copy that requires manual rsync; rsync runs but PM2 has not restarted, so on-disk code is not running; route handlers are split across processes (`backend` vs `backend-api`) and only one restarted; edge cache or in-memory module cache serves old responses for a window after deploy. Any of these mean a "merged" PR may not be exercisable yet, and premature "bug closed" claims erode trust in coord signals. The acceptance gate is the live verifier hitting the production endpoint with a deterministic reproducer that 400d (or otherwise failed) pre-fix, returning clean post-fix. That is the canonical bug-closure signal, not the merge button.

## Preamble (run first)

```bash
# Surface top-3 relevant prior lessons for this skill
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag acceptance-test-after-deploy --limit 3 2>/dev/null || true
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

1. A bug-fix PR has merged (to staging or main) and someone is about to post "bug resolved" / "launch-blocker closed" / "fixed"
2. The deploy chain (staging promote, main rsync to host, PM2 restart, cache flush) has not yet been verified end-to-end
3. The live reproducer that triggered the bug pre-fix has not yet been re-run against the deployed code
4. CI is green, but CI tests proved the fix passes the test suite, not that it works against the actual production system
5. Two or more processes share route handlers (e.g. `backend` plus `backend-api`) and only one has been observed to restart

## Workflow

### Phase 1 · Confirm the deploy chain landed

Before running the verifier, confirm each step:

```bash
# Staging promoted to main?
gh release view --json tagName,publishedAt 2>/dev/null
git log origin/main --format='%h %s' -5

# EC2 host has the new code on disk?
# (run via the C-side log-grep / ssm-send-command)
ssm-send-command "ls -la /opt/<service>/futureai-backend/src/<changed-file>"
ssm-send-command "stat -c '%Y' /opt/<service>/futureai-backend/src/<changed-file>"

# PM2 process restarted?
ssm-send-command "pm2 list | head"
# uptime should be < deploy timestamp; if not, restart did not happen
```

If any step is unverified, stop and resolve it before claiming the fix landed.

### Phase 2 · Run the live verifier against the production host

A good acceptance verifier is:

1. **Authoritative**: hits the production endpoint, not a local copy or staging
2. **Deterministic**: same inputs reproduce the failure pre-fix and the success post-fix
3. **Self-contained**: runs in <60s, no manual setup beyond credentials
4. **Logs-friendly**: outputs include correlation keys (request-id, conversation-id) so you can grep prod logs for the matching observation

For the 2026-05-01 launch-blocker, this was `/tmp/verify_bedrock_shape.sh`: hits prod streaming-api with a DTC-rich prompt that 400d 5+ times pre-fix; success criterion is "real `narration-delta` SSE frames stream, no abstain-terminal".

```bash
# 1. Run the verifier and tee its output
bash /tmp/verify_bedrock_shape.sh 2>&1 \
  | tee /tmp/verifier-post-<PR>-$(date -u +%Y%m%dT%H%M%SZ).log

# 2. Inspect the output against pass criteria
#   - SSE frames with kind=narration-delta or kind=tool-use stream
#   - NO kind=abstain-terminal with reason=tool-unavailable
#   - NO Bedrock 400 in the SSE body
```

### Phase 3 · Confirm the fix is general, not coincidental

A passing verifier on a single conv ID is one data point. If you have N reproductions pre-fix across different shapes, re-run the verifier with at least 2-3 different shapes post-fix to confirm the fix is general:

```bash
for shape in dtc-rich narrative-only mixed-shape; do
  bash /tmp/verify_bedrock_shape.sh "$shape" \
    2>&1 | tee /tmp/verifier-post-<PR>-${shape}.log
done
```

### Phase 4 · Post the acceptance receipt to the coord thread

Acceptance receipts go to the coord PR (or the relevant fix-PR thread) with a canonical machine-readable prefix so auto-ticks watching the thread can mark the bug resolved when this lands:

```
## <session> · ACCEPTANCE VERIFIER GREEN · <PR> fix verified on prod · <UTC>

Conv: <new-conv-id>
Repro: <same prompt that failed pre-fix>

Before / after table:
  Pre-fix  : <abstain-terminal SSE in <1s>
  Post-fix : <real narration-delta streaming, no error>

Sample SSE excerpt: <a few frames>

Launch-blocker closed.
```

### Phase 5 · Handle verifier failure

If the verifier does not pass:

- **Same error**: fix did not land. Check the deploy chain (was main promoted? did rsync run? did pm2 restart? `pm2 logs --nostream | head` to confirm fresh start time).
- **Different error**: residual bug at a different layer. Capture, post to coord, write a follow-up. Do not roll back the original fix; it may still be necessary even if not sufficient.
- **Inconclusive output** (timeout, partial response): increase verifier timeout or extend the prompt. Do not claim a result either way until you have a definitive frame.

## Seed lessons

```jsonl
{"id":"sha256-atadnm-001","ts":"2026-05-01","session":"session-c","skill":"acceptance-test-after-deploy-not-merge","pattern":"claimed 'bug fixed' on PR merge before EC2 rsync + PM2 restart had been verified","evidence":"PR #1993 merged to staging; verifier conv ccd45118 only returned clean once main was promoted, EC2 host had the new file on disk, and PM2 had restarted; the merge-time claim would have been false","fix":"never mark bug-resolved on merge alone; require a post-deploy verifier conv ID + clean output cited in the same comment","severity":"P0","scope":"generic","tags":["deploy-chain","acceptance-gate","verifier","bug-closure"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
{"id":"sha256-atadnm-002","ts":"2026-05-01","session":"session-c","skill":"acceptance-test-after-deploy-not-merge","pattern":"verifier passed on a single repro shape; without sweeping multiple shapes, fix-generality is unproven","evidence":"7 reproductions pre-fix (e02d6177, dc36b109, f0adc326, e48fce02, 0ddc250e, a2835b69, 155bf5ea) across different prompt shapes; running the verifier against only one shape post-fix would have left fix-generality untested","fix":"when N>2 reproductions exist pre-fix, sweep at least 2-3 shapes post-fix; cite each conv ID in the acceptance receipt","severity":"P1","scope":"generic","tags":["fix-generality","verifier-sweep","sample-size"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-atadnm-001"],"evidence_count":1}
{"id":"sha256-atadnm-003","ts":"2026-05-01","session":"session-c","skill":"acceptance-test-after-deploy-not-merge","pattern":"PM2 not restarted after rsync, on-disk code is fresh but running code is stale","evidence":"`pm2 list` showed uptime older than the rsync timestamp; restart had silently failed; verifier returned the same 400 even though the file on disk had the fix","fix":"always cite `pm2 list | head` post-restart with uptime less than rsync timestamp; verifier failures with same-error post-merge usually trace to this","severity":"P0","scope":"generic","tags":["deploy-chain","pm2","restart-verification"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-atadnm-001"],"evidence_count":1}
{"id":"sha256-atadnm-004","ts":"2026-05-01","session":"session-c","skill":"acceptance-test-after-deploy-not-merge","pattern":"verifier run against staging or local box instead of the production host","evidence":"tests against staging while prod is still on old code give a false-positive signal; the bug is on prod, the verifier must hit prod","fix":"verifier MUST hit the production endpoint by URL; reject any verifier that defaults to localhost / staging unless explicitly overridden with rationale","severity":"P0","scope":"generic","tags":["verifier-design","authoritative-target","staging-drift"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-atadnm-001"],"evidence_count":1}
{"id":"sha256-atadnm-005","ts":"2026-05-01","session":"session-c","skill":"acceptance-test-after-deploy-not-merge","pattern":"two-process split with only one process restarted leaves half the routes on old code","evidence":"backend vs backend-api deploy split; pm2 restart on backend left backend-api on previous SHA; verifier intermittently passed depending on which process the request landed on","fix":"always restart all processes that share route-handler code; verify each process's uptime independently before declaring deploy complete","severity":"P1","scope":"generic","tags":["deploy-chain","two-process","pm2"],"user_quote":null,"auto_captured":false,"related_ids":["sha256-atadnm-001"],"evidence_count":1}
```

## Invariants consulted

- **Invariant 1 · Run the check before claiming**: "bug fixed" is a claim; the verifier output is the check; no verifier conv ID, no claim
- **Invariant 6 · Every declared metric has a caller**: analogous discipline; every "this fix landed" claim must cite a verifier output, not just a green CI badge

## Integration points

- `verify-before-claim`: the parent invariant; this skill is the bug-fix-specific application of it
- `competing-fix-reconciliation-via-dispositive-evidence`: picks WHICH fix to ship; this skill confirms the chosen fix actually closes the bug on the deployed host
- `coord-pr-as-message-bus`: the channel where the acceptance receipt lands; the `ACCEPTANCE VERIFIER GREEN` prefix is the canonical machine-readable signal
- `prod-smoke`: the broader smoke-test pattern; this skill is the bug-fix-specific variant focused on a single repro

## Completeness Principle

Completeness 10/10: confirm staging promote to main, EC2 rsync, all PM2 processes restarted, run verifier against production endpoint, sweep 2-3 prompt shapes, cite every conv ID inline, post the acceptance receipt with the canonical prefix.

Completeness 7/10: confirm deploy chain via PM2 uptime, run verifier against production endpoint with one prompt shape, post receipt.

Completeness 3/10: rely on CI green plus PR merge state, skip the verifier, claim "bug fixed" on the merge button alone.

**Default target: 10/10.** The cost of a 60-second verifier run against prod is trivial against the cost of a false "fixed" claim that erodes coord-signal trust and lets a residual bug ride into the next sprint.

## Changelog

- v0.1.0 (2026-05-01) initial draft from Session C launch-blocker debug; 5 seed lessons covering merge-vs-deploy distinction, fix-generality sweep, PM2 restart verification, authoritative-target requirement, and two-process split pitfalls.
