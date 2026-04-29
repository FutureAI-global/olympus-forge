---
name: dispatch-format-pickup-verification
namespace: session-lessons
version: 0.1.0
description: |
  After dispatching work to another session via @mention on a coord PR, watch
  the receiving session's next 2 to 3 ticks to confirm the dispatch was
  actually picked up. Acceptance (the comment POST returned 201) is not
  pickup. Encodes the per-receiver envelope shape that autonomous polling
  ticks pattern-match on, the lookback query for verifying pickup, and the
  repost-in-canonical-format recovery when the envelope did not match.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a dispatch incident in which a directed @mention used a freeform envelope shape that did not match the receiving session's autonomous routine pattern matcher, leaving the dispatch silently un-picked-up for over five minutes until the operator manually intervened.
---

# dispatch-format-pickup-verification · acceptance is not pickup

## Why this exists

You post a directed dispatch on a coord PR. The comment goes through. No error. Comment ID returned. You report "dispatch sent, standing by." But the receiving session's autonomous routine pattern-matches on a different envelope shape than the one you used. Their tick keeps firing `idle` every 1 to 2 minutes. Five minutes later, no ack.

Every minute the receiver's tick fires `idle` after your dispatch is a minute the dispatch is silently un-picked-up. The "I sent it, they're working on it" delusion compounds. Worse: the orchestrator may re-route the same task to a different receiver, who picks it up, ships it; then the original receiver's pattern matcher catches up and ships a duplicate.

Pickup verification is the gate that prevents this. Acceptance (POST returned 201) is not pickup. Pickup is "the receiver's next tick acknowledged the dispatch."

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag dispatch-pickup --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. Just posted a directed dispatch (`## <sender> → @<receiver>`) on a coord PR
2. About to claim "dispatched to <session>" in a status update to the operator
3. The receiver has a known autonomous polling routine (auto-tick, scheduled job)
4. The receiver runs on remote-cron and has no chat context, only what `gh api` returns
5. Sibling session has been silent for over two ticks past your dispatch timestamp

Voice triggers: "dispatched", "sent it to <session>", "they should pick it up", "did they get it?".

## Workflow

### Phase 1 · Note the dispatch timestamp

```bash
DISPATCH_TS=$(date -u +%FT%TZ)
COMMENT_URL=$(gh pr comment "$COORD_PR" --body "## main → @<receiver> · <directive> · ${DISPATCH_TS}" 2>&1 | tail -1)
echo "Dispatched at $DISPATCH_TS"
```

### Phase 2 · Wait for two to three of the receiver's ticks

The receiver's tick interval is typically 60 to 120 seconds. Wait roughly 2 to 4 minutes before checking for pickup. Do not wait longer; if pickup did not happen by tick 3, it is not coming on its own.

### Phase 3 · Query the last 15 comments and inspect the receiver's most recent post

```bash
gh api "repos/<owner>/<repo>/issues/<coord-pr>/comments?per_page=100&page=<last>" \
  --jq '.[-15:] | .[] | "\(.created_at) | \(.user.login) | \(.body[0:140])"'
```

Or filter to the receiver:

```bash
gh api "repos/<owner>/<repo>/issues/<coord-pr>/comments?per_page=100&page=<last>" \
  --jq '[.[] | select(.user.login == "<receiver-bot>")] | .[-3:] | .[] | "\(.created_at) | \(.body[0:140])"'
```

### Phase 4 · Classify the receiver's next-tick comment

| Receiver's next comment | Meaning | Action |
|---|---|---|
| `[session-X] idle, no pending work` (after your dispatch ts) | DISPATCH NOT PICKED UP. Envelope did not match. | Repost in canonical format (Phase 5). |
| `## X · ack <task> · <UTC-ts>` | Picked up cleanly. Working. | Done. Move on. |
| `## X · clarification: <question>` | Picked up but has a question. | Answer the clarification on-thread. |
| (no new comment from receiver in 3 ticks) | Receiver may be down OR tick is paused | Check receiver's process; do not assume pickup. |

### Phase 5 · Repost in the receiver's canonical envelope

Each receiver's autonomous routine matches on a specific envelope. Document them per session. Suggested formats:

- `[session-<id>] assigned: <task-id> ...` (bracketed envelope)
- `@<CamelCaseSessionName>` (camel-case mention)
- `## <sender> → @<lowercase-hyphen-receiver> · <directive> · <UTC-ts>` (directive header)

Do not use freeform `@<receiver>`, `@<receiver_underscore>`, or `Hey <receiver>, ...`. None of these match a typical autonomous pattern matcher.

If the canonical envelope is unknown, read the receiver's last 5 ack-shaped comments to infer the pattern they respond to.

### Phase 6 · Cross-machine receivers must be self-contained

Sessions running on remote-cron auto-ticks (created via `/schedule` or similar) only see what `gh api` returns at tick time. They have no chat context, no thread memory. Every dispatch must be self-contained: include the task ID, the file paths, the success criteria, all in one comment. A two-comment dispatch (header in one, payload in a reply) will silently miss the payload.

## What NOT to do

- Reporting "dispatched" to the operator without verifying pickup. Acceptance is not pickup. The 201 from the POST means GitHub stored the comment, not that the receiver saw it.
- Waiting more than 3 ticks for pickup. If it did not happen by tick 3, the envelope did not match. Reposting at tick 4 wastes time the receiver could have been working.
- Reposting in the same envelope shape that just failed. The pattern matcher did not match the first time; it will not match the second time either. Switch envelopes.
- Multi-comment dispatches where the directive is split across replies. Cross-machine receivers polling via `gh api` may only fetch the parent and miss the reply.
- Assuming a silent receiver is acking. Silence is silence. Either pickup is loud (an ack comment), or it did not happen.

## Seed lessons

### Lesson 1 · freeform lowercase-hyphen mentions miss camel-case pattern matchers

A dispatch used `@<session-name>` (lowercase-hyphen) as the @ shape. The receiver's autonomous routine pattern-matched on `@<CamelCaseSessionName>` or `[session-<id>] assigned:` (bracketed). The freeform mention did not match either. The receiver kept posting `idle` for over five minutes. The fix: catalog each receiver's canonical envelope, repost in the format that matches.

### Lesson 2 · the operator's manual intervention masks the bug

When pickup fails and the operator (a human) sees the receiver still idle, the operator may manually nudge the receiver ("session X, execute the dispatch above"). That works, but it hides the envelope mismatch. Without capturing the lesson, the same dispatch shape misses again next sprint. The fix: when manual intervention bridges a missed pickup, treat it as a P1 lesson, not a one-off.

### Lesson 3 · cross-machine receivers cannot read chat context

A session running on remote-cron polls the coord PR only at tick time. It has no Claude transcript, no chat scrollback. A dispatch that says "do what we discussed earlier" is invisible to it. The fix: every dispatch to a cross-machine receiver is self-contained. Task ID, file paths, success criteria, all in one comment.

### Lesson 4 · multi-comment dispatches silently lose the payload

A dispatch posted the directive header in one comment and the payload in a threaded reply. The receiver's autonomous routine fetched only the top-level comment via `gh api .../comments` (which does not return reply bodies in the same call). The payload went invisible. The fix: single-comment dispatches, never split across reply threads.

### Lesson 5 · "dispatched, standing by" is a half-claim until pickup verified

Reporting "dispatched, standing by" to the operator before pickup verification is a verify-before-claim violation. The operator now has a false expectation. The fix: report "dispatched at <ts>; verifying pickup in 2 to 3 minutes" instead. Once pickup is confirmed, upgrade to "dispatched and acked."

## Invariants consulted

- `Invariant 1 · Run the check before claiming`. Pickup verification IS the check. "Dispatched" without the receiver's ack is a half-claim that needs an "unverified" label or the verification itself.
- `Invariant 9 · User corrections are lessons, not interruptions`. When the operator manually nudges a missed dispatch, the envelope mismatch is the lesson; capture it so the next dispatch uses the right envelope.

## Integration points

- Pairs with `multi-session-tick-orchestration`. The receiver-side tick loop is what creates the ack comment this skill verifies; this skill is the sender-side counterpart.
- Pairs with `dispatched-pr-content-verification`. The next-level check after pickup confirmed: when the receiver eventually ships, verify the shipped PR actually contains your dispatched delta.
- Pairs with `coord-pr-as-message-bus`. The bus is the substrate; this skill is one of the conventions that keeps the bus actually delivering.

## Completeness principle

This skill DOES NOT fire when the dispatch goes to a human collaborator who is reading the thread live. Humans can recognize freeform prose; autonomous pattern matchers cannot. It also does not fire for one-shot scripts that fire a dispatch and exit; only ongoing coord work needs the verification.

False-negative cost (skipping pickup verification): silent dispatch loss, duplicate work when the orchestrator re-routes, the operator working with a false picture of session state. False-positive cost (verifying pickup on a dispatch that always lands cleanly): roughly 30 seconds of `gh api` plus inspection per dispatch. Default to verifying.

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a dispatch incident in which a directed @mention used a freeform envelope shape that did not match the receiving session's autonomous routine pattern matcher, leaving the dispatch silently un-picked-up for over five minutes until the operator manually intervened.
