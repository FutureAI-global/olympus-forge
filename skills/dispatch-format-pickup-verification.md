---
name: dispatch-format-pickup-verification
namespace: session-lessons
version: 0.1.0
description: |
  Triggers after dispatching work to another session via @mention on a coord PR.
  Encodes the "watch ticks for pickup confirmation, not just acceptance"
  pattern. Acceptance (comment posted, no API error) is not pickup (receiver's
  autonomous tick recognized the dispatch and acked it). Fire after every
  cross-session dispatch.
allowed-tools:
  - Bash
provenance: forged 2026-04-29 from a coord-PR dispatch where the dispatcher posted `## main → @session-k · ...` (freeform) and the receiver's autonomous tick kept firing `[session-K] idle, no pending work` for 5+ minutes because the receiver's auto-routine pattern-matches on a different envelope shape (`[session-K] assigned:` or `@SessionK` camel-case). Without manual orchestrator intervention, the dispatch would have stayed invisible indefinitely.
---

# dispatch-format-pickup-verification · acceptance ≠ pickup

## Why this exists

You post a dispatch on the coord PR:

```
## main → @session-k · marketing site migration · 2026-04-29T00:20Z

@session-k — orchestrator approved migrating the new tree to root URLs...
```

The comment goes through. The dispatch is "accepted" (no error, comment ID returned). You report to the orchestrator "K dispatched, standing by."

But K's autonomous tick keeps firing `[session-K] idle, no pending work` every 1-2 minutes. Five minutes later, K hasn't acked. Why? Because K's auto-routine pattern-matches on `@SessionK` (camel case) or `[session-K] assigned: ...` (structured envelope), not freeform `@session-k` (lowercase-hyphen). The dispatch is invisible to K's tick.

Every minute K's tick fires idle is a minute the dispatch is silently un-picked-up. The "PR opened, orchestrator informed" delusion compounds.

## The verification ritual

After every dispatch on a coord PR, watch the receiving session's next 2-3 ticks:

```bash
# 1. Note the dispatch timestamp
DISPATCH_TS="2026-04-29T00:20:00Z"

# 2. Wait ~2-3 ticks (1-3 min depending on session's tick interval)

# 3. Check what the receiver said most recently:
gh api 'repos/<repo>/issues/<coord-pr>/comments?per_page=100&page=<last>' \
  --jq '.[-15:] | .[] | "\(.created_at) | \(.user.login) | \(.body[0:140])"'
```

The receiver's next-tick comment tells you which case you're in:

| Receiver's next comment | Meaning |
|---|---|
| `[session-X] idle, no pending work` (after your dispatch) | **DISPATCH NOT PICKED UP** — your envelope didn't match their pattern |
| `## X · ack <task> · <UTC>` | Picked up cleanly, working |
| `## X · clarification: <something>` | Picked up but has a question |

If the receiver shows `idle` 2+ ticks AFTER your dispatch:

1. **Don't wait longer** — it's not coming
2. **Check their tick's pattern matcher** — what envelope does it look for? (Often: structured `[session-X] assigned: <task-id>` or camel-case `@SessionX` with explicit task-id)
3. **Repost in the matching format** — use their canonical envelope, not freeform prose

## Each session's pickup envelope (verify empirically per ecosystem)

Different ecosystems wire different envelopes. Some patterns observed:

- Bracketed structured envelope: `[session-X] assigned: <task-id> ...`
- Camel-case mention: `@SessionX` plus explicit task-id
- Reaction-driven: receiver picks up when a specific reaction emoji appears on a comment
- Label-driven: receiver greps `gh pr list --search "label:session-X-todo"` instead of comments

Freeform `@session-x`, `@session_x`, `Hey X, ...` etc. typically match NONE of these.

## Cross-machine note

Sessions running on remote-cron auto-tick (the ones spawned via cloud schedule) only see what `gh api` returns at tick time. They have no chat context, no thread memory. Every dispatch must be self-contained AND pattern-matchable in the autonomous routine's grep.

## Worked example

The 2026-04-29 marketing migration:

- 00:21:01Z — dispatcher posted `## main → @session-k · marketing site migration ...` (freeform)
- 00:20:47Z — receiver's tick fired `[session-K] idle, no pending work` (already pre-dispatch)
- 00:26:09Z — receiver's tick fired `[session-K] idle, no pending work` (5 min after dispatch — not picked up)
- 00:28:55Z — orchestrator manually intervened ("session k is executing it now") — orchestrator's intervention bridged the gap, not the dispatcher's pattern matching

Without manual intervention, the receiver would have stayed idle indefinitely. The dispatch envelope was the bug.

## Cross-reference

- `coord-pr-as-message-bus` — the bus this verification protects
- `multi-session-tick-orchestration` — the receiver-side loop that does the pattern matching
- `dispatched-pr-content-verification` — the next-level check after pickup is confirmed
- `stale-assignment-detection` — receiver-side counterpart (verify before executing)
