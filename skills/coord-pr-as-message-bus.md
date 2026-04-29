---
name: coord-pr-as-message-bus
namespace: session-lessons
version: 0.1.0
description: |
  Pattern for using one long-lived GitHub PR thread as a poll-based message
  bus for N autonomous Claude/agent sessions. Lowest-friction multi-agent
  coordination when sessions already use `gh` CLI for PR work and you don't
  want to stand up Slack / Redis / SQS. Fire when designing multi-session
  coord and the alternative is provisioning real infrastructure.
allowed-tools:
  - Bash
provenance: forged 2026-04-29 from Coord PR FutureAI-global/futureai-auto#1828 which carried 600+ comments across 5 sessions over 20 hours. Three dispatch envelope shapes were tried; only the structured `[session-X]` envelope was reliably picked up by autonomous ticks.
---

# coord-pr-as-message-bus · when a GitHub PR thread is your bus

## When to reach for this

You have N (3-20) autonomous Claude / agent sessions that need to:

- Announce `idle` state for work-stealing
- Receive routed assignments from a factory
- Post receipts on completed work
- Read each other's status without standing up Slack / Redis / SQS

If the sessions are already using `gh` auth for PR work, the GitHub PR thread is the lowest-friction bus: every session can read + write, comments are timestamped + addressable, the thread is searchable + diffable, and the audit trail is free.

## The shape

```
ONE long-lived PR (the "coord PR") on the main repo. Title: coord(<project>): <sprint name>.
  ├── Body: machine-readable state (JSON in a fenced block, optional)
  ├── Comments: one per session-event
  │     ├── [session-X] idle, no pending work · auto-tick @ <ts>
  │     ├── [session-X] assigned: <task-id>
  │     ├── [session-X] shipped: PR #<n>
  │     └── ## main → @session-X · <directive> · <UTC-ts>  (assignment)
  └── Reactions: optional ack signals (👀 = picked up, ✅ = done)
```

Each session has its own poll loop (see `multi-session-tick-orchestration`) that reads new comments since-cursor and pattern-matches the envelopes it cares about.

## Conventions that make it work

### Envelope shape per message type

- `[session-X] idle, no pending work · auto-tick @ <ts>` — heartbeat, dedupe-suppress within 5min
- `[session-X] assigned: <task-id> ...` — claim broadcast (informs siblings work is in flight)
- `[session-X] shipped: PR #<n>` — completion broadcast
- `## <sender> → @<receiver> · <directive> · <UTC-ts>` — directed assignment, large markdown allowed

The structured prefix (`[session-X]` or `## main →`) is what each session's autonomous tick greps for. Freeform prose without the envelope IS INVISIBLE to autonomous ticks.

### Pickup verification

After dispatching, watch the receiver's next 2-3 ticks. If they continue posting `idle` without acking your message, the envelope didn't match. Repost in the canonical format. (See `dispatch-format-pickup-verification`.)

### Pagination

Coord PRs balloon fast. After 100 comments use `gh api repos/$REPO/issues/$PR/comments?per_page=100&page=N` and walk pages. Do NOT use `--paginate` for arithmetic without `jq -s` (see `multi-session-tick-orchestration`).

### Last-seen cursor

Each session persists `~/.cache/<ecosystem>/last-comment-id` so it only processes new comments. Without this, every tick re-processes the entire thread (slow + double-action risk).

## Why not Slack / a real queue?

Tradeoffs:

- **Slack** — needs OAuth per-session, message-edit history is poor, no native mention parsing, threading is shallow
- **Redis pub/sub** — needs cluster + auth + heartbeat for each session, no audit trail
- **SQS** — needs IAM per-session, polling cost, message TTL forces archival
- **GitHub coord PR** — every session already has `gh` auth, audit is free, comments are addressable URLs, history persists forever, free tier covers this volume

The GitHub bus loses to a real queue when:

- You need >100 messages/minute throughput (GitHub API rate limits matter)
- You need exactly-once semantics (PR comments are at-least-once; sessions must dedupe by ID)
- You need ordering guarantees across writers (PR comments are timestamp-ordered, but clock skew exists)

For ~5 sessions × 1 message/min, the GitHub bus is the right call.

## Anti-patterns

- **Two coord PRs simultaneously** — sessions don't know which is canonical. One per sprint. New sprint = explicit "succeeded by #N" comment on old + locked.
- **Edit message body to update state** — comment-edit doesn't fire webhooks the same way; ticks may miss. Always post a NEW comment.
- **Mix human-readable and machine-parseable in the same paragraph** — split into clearly-marked sections (`### Receipts` vs prose intro).
- **Use the PR for >1000 messages** — the GitHub UI gets sluggish. Roll to a successor PR per sprint with a hand-off comment.
- **Skip the structured envelope** — freeform `@session-x` mentions WILL be invisible to autonomous ticks. Always use the canonical envelope.

## Worked example

A 2026-04-28+ multi-session sprint:

- Opened by orchestrator role with title `coord(<project>): <sprint name>`
- Carried 3 sub-sprints (initial ship → post-smoke fixes → next-version trio)
- 5 sessions polling
- ~602 comments over 20 hours
- 3 dispatch formats observed: structured `[session-X] assigned:`, freeform `@session-x`, narrative `## main → @session-x`
- Lesson learned: only the structured `[session-X]` envelope gets reliably picked up by auto-ticks (see `dispatch-format-pickup-verification`)

## Cross-reference

- `multi-session-tick-orchestration` — the per-session loop that polls this bus
- `coord-comment-template` — the standard format for messages posted to the bus
- `dispatch-format-pickup-verification` — how to know if your message got picked up
- `dispatched-pr-content-verification` — how to verify the work that came back actually contains your delta
