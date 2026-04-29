---
name: coord-pr-as-message-bus
namespace: session-lessons
version: 0.1.0
description: |
  Coordinate N (3 to 20) autonomous Claude or agent sessions through a single
  long-lived GitHub PR thread used as a poll-based message bus. Avoids standing
  up Slack, Redis pub/sub, or SQS infrastructure when every session already
  has gh CLI auth. Encodes the envelope conventions, pickup verification, and
  pagination patterns that keep the thread usable past 600 comments without
  losing dispatches.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a multi-session sprint where one long-lived coord PR carried over 600 comments across 5 sessions and three competing dispatch envelope shapes revealed which formats reliably get picked up by autonomous polling ticks.
---

# coord-pr-as-message-bus · when a GitHub PR thread is your bus

## Why this exists

When N autonomous sessions need to announce idle state, receive routed assignments, post receipts, and read each other's status, the obvious answer is "real infrastructure" (Slack, queues, pub/sub). That answer is wrong when every session already has `gh` CLI auth and zero appetite for OAuth dances.

A single long-lived GitHub PR thread is the lowest-friction bus. Every session can read and write. Comments are timestamped and addressable URLs. The thread is searchable, diffable, and the audit trail is free. The trade-off is rate-limited throughput and at-least-once delivery semantics, which is fine for under 100 messages per minute across a handful of sessions.

The trap is that a coord PR works only if the conventions are enforced. Mixed envelope shapes, edited bodies, parallel coord PRs, and unbounded pagination each silently break pickup. This skill codifies the conventions so the bus stays operable past the first sprint.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag coord-pr --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. About to coordinate three or more autonomous sessions on a shared sprint
2. About to open a new "coord(...)" PR for sprint orchestration
3. About to post a dispatch directed at another session via @mention on a coord PR
4. About to read coord PR comments to determine sibling-session status
5. The existing coord PR has crossed 100 comments and pagination matters
6. A new sprint is starting and the prior coord PR needs to be retired

Voice triggers: "post on the coord PR", "dispatch to a session", "read the coord thread", "open a coord PR", "the bus is full".

## Workflow

### Phase 1 · Confirm one canonical coord PR exists

```bash
gh pr list --state open --search 'in:title "coord("' --json number,title,createdAt
# Must return exactly ONE entry for the active sprint
```

If two open coord PRs match, sessions cannot tell which is canonical. Pick one, post `succeeded by #<N>` on the loser, and lock it.

### Phase 2 · Use the canonical envelope shapes

Every machine-actionable comment uses one of these four shapes:

```
[session-X] idle, no pending work · auto-tick @ <UTC-ts>
[session-X] assigned: <task-id> ...
[session-X] shipped: PR #<n>
## <sender> → @<receiver> · <directive> · <UTC-ts>
```

The structured prefix (`[session-X]` or `## <sender> →`) is what each session's autonomous tick greps for. Freeform prose without the envelope is invisible to autonomous polling.

### Phase 3 · Verify pickup before claiming dispatch landed

After posting a directed assignment, watch the receiver's next two to three ticks. If they keep posting `idle` without acking, the envelope did not match their pattern matcher. Repost in the canonical format. See `dispatch-format-pickup-verification` for the full ritual.

### Phase 4 · Paginate correctly past 100 comments

```bash
gh api "repos/$REPO/issues/$PR/comments?per_page=100&page=$PAGE"
# Walk pages explicitly. Do NOT use --paginate piped to jq arithmetic
# without -s (slurp), or you will get only the last page's count.
```

### Phase 5 · Persist a last-seen cursor per session

Each session writes `~/.cache/<coord-cache-dir>/last-comment-id` so it only processes new comments. Without this, every tick re-processes the entire thread, burning API quota and risking double-action on already-handled assignments.

### Phase 6 · Roll the PR per sprint

Once a coord PR crosses ~1000 comments the GitHub UI gets sluggish. Open a successor coord PR, post a "succeeded by #<N>" comment on the old one, and update each session's `COORD_PR` env var. New sprint = new PR.

## What NOT to do

- Running two open coord PRs simultaneously. Sessions race on which is canonical and dispatches go to the wrong thread.
- Editing the PR body to update state. Comment-edit webhooks fire differently and ticks miss the change. Always post a NEW comment.
- Mixing human-readable prose and machine-parseable envelopes in the same paragraph. Split into clearly-marked sections so the auto-tick grep does not catch human commentary.
- Pushing the bus past 100 messages per minute throughput. GitHub API rate limits are real. If you need that throughput, the bus is the wrong tool, switch to a real queue.
- Assuming pickup just because the comment POST returned 201. Acceptance is not pickup. See `dispatch-format-pickup-verification`.

## Seed lessons

### Lesson 1 · freeform @mentions are invisible to autonomous ticks

A session posted `@<receiver>` (lowercase-hyphen freeform) directing a sibling to start work. The receiver's autonomous routine pattern-matched on a different envelope shape (camel-case @ or bracketed `[session-X] assigned:`). The receiver's next ticks reported `idle` for five minutes after the dispatch. The fix: every dispatch uses the canonical envelope, never freeform prose, and the sender verifies pickup within two to three ticks.

### Lesson 2 · two parallel coord PRs split the bus

A new sprint opened a new coord PR while the old one still had unresolved dispatches. Sessions cached the old `COORD_PR` env var and kept polling the dead thread. Result: directives posted on the new PR went unread for hours. The fix: explicit "succeeded by #<N>" comment on the retiring PR, locked thread, and an env-var update broadcast to all running sessions.

### Lesson 3 · `gh pr list --paginate | jq '. | length'` reports last-page count, not total

A session's tick used `--paginate` piped to `jq '. | length'` to count its own open PRs. The arithmetic returned only the last page's length. Sessions with over 100 open PRs across pages reported `idle` falsely and were re-assigned in-flight work. The fix: `jq -s 'add | length'` (slurp), or walk pages explicitly.

### Lesson 4 · processing the entire thread every tick burns quota and risks double-action

A session without a last-seen cursor re-read every comment on each tick. Past 600 comments, this both ate API quota and re-fired actions on assignments already handled. The fix: persist `last-comment-id` per session and only process comments past that cursor.

### Lesson 5 · the bus loses to a real queue past a throughput threshold

The PR-as-bus shape is correct for under 100 messages per minute and a handful of sessions. Past that, GitHub API rate limits start dropping comments, ordering guarantees fail under clock skew, and the UI becomes unusable. The fix: know the threshold up front. Pick the bus shape deliberately, not by default.

## Invariants consulted

- `Invariant 1 · Run the check before claiming`. Pickup verification is a check; "dispatched" without verifying the receiver acked is a half-claim.
- `Invariant 9 · User corrections are lessons, not interruptions`. When the operator manually bridges a missed dispatch, capture the envelope mismatch as a lesson; do not just move on.

## Integration points

- Pairs with `multi-session-tick-orchestration`. The per-session polling cadence that runs ON this bus.
- Pairs with `dispatch-format-pickup-verification`. How to confirm a dispatch you posted actually got picked up by the receiver.
- Pairs with `epic-assist-primitive`. One shipping pattern that uses the bus to hand off primitives between sessions.

## Completeness principle

This skill DOES NOT fire when a single session is shipping solo and there is no coordination with siblings. It also does not fire for one-shot dispatches over Slack DM or email, where the sender knows the receiver is human and will read prose.

False-negative cost (skipping the conventions on real multi-session coord): silent dispatch loss, duplicate work, hours of "I sent it" / "I never got it" debugging. False-positive cost (running the conventions on a solo workflow): roughly 20 seconds of structured-envelope formatting overhead. Default to running it the moment a second session joins.

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a multi-session sprint where one long-lived coord PR carried over 600 comments across 5 sessions and three competing dispatch envelope shapes revealed which formats reliably get picked up by autonomous polling ticks.
