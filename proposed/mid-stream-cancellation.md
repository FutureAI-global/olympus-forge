---
name: mid-stream-cancellation
namespace: session-lessons
version: 0.1.0
description: |
  Process-local AbortController-registry pattern for cancelling an in-flight
  LLM call when the user hits /park or /exit. Runner's catch-path classifier
  distinguishes signal.aborted (typed abstain, no partial-turn persistence)
  from upstream errors. Includes fork-mode-pm2 cluster caveat.
allowed-tools:
  - Read
  - Write
  - Bash
provenance: |
  forged 2026-04-29 from a mid-stream park feature where DB-flag-only
  cancellation left the in-flight LLM call running to completion, burning
  tokens and trying to persist partial state after the user already left.
---

# mid-stream-cancellation · process-local registry, classify aborts as a typed terminal

## Why this exists

- A user is mid-conversation with an LLM. The route is streaming SSE frames token-by-token. The user wants to interrupt: hit `/park`, `/exit`, `/abort`.
- Naive approach (DB-flag-only) leaves the in-flight upstream call running until normal completion, burning tokens and trying to persist a partial turn after the user already left.
- Right shape: process-local `Map<conversationId, AbortController>` shared between the SSE-streaming runner and the cancel route. Cancel calls `signal.abort()`. Runner's catch-path inspects `signal.aborted` to distinguish "user parked" from "upstream errored" and returns a typed terminal turn (e.g., `tech-aborted` abstain) instead of a generic error.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag mid-stream-cancellation --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Adding a `/park`, `/cancel`, `/abort`, or `/exit` slash to an SSE-streaming workflow.
- Wrapping a long-running upstream call (Bedrock, OpenAI, etc.) and need to interrupt it from a separate route.
- DB-flag-only cancellation isn't enough; you need the upstream call to actually halt.
- Want to distinguish user-cancelled from network-failed in the runner's catch path.

Voice triggers: "add /park", "cancel mid-stream", "abort the in-flight call", "stop the LLM mid-response".

## Workflow

### Phase 1 · Module shape (canonical)

Small standalone module, no imports from route OR runner (avoids cyclic dep — both import this):

```typescript
// services/.../park-registry.ts
const inflight = new Map<string, AbortController>();

export function registerInFlightRun(
  conversationId: string,
  controller: AbortController,
): void {
  // Defense-in-depth: if a stale controller is registered for the same
  // conversation, abort it before replacing.
  const prior = inflight.get(conversationId);
  if (prior && prior !== controller) {
    try { prior.abort(); } catch { /* best-effort */ }
  }
  inflight.set(conversationId, controller);
}

export function clearInFlightRun(
  conversationId: string,
  controller: AbortController,
): void {
  // MATCH-CONTROLLER GUARD — only clear if the registered controller is
  // OURS. A stale clear racing a fresh registration must NOT delete the
  // fresh one. This is the load-bearing race-protection branch.
  const current = inflight.get(conversationId);
  if (current === controller) {
    inflight.delete(conversationId);
  }
}

export function signalParkOfConversation(conversationId: string): boolean {
  const controller = inflight.get(conversationId);
  if (!controller) return false;          // idempotent: double-call returns false
  try { controller.abort(); } catch { /* best-effort */ }
  inflight.delete(conversationId);
  return true;
}

export function inFlightCount(): number {
  return inflight.size;                   // test-only — assert no leaks
}
```

### Phase 2 · Runner integration

```typescript
const parkController = new AbortController();
registerInFlightRun(input.conversationId, parkController);

try {
  // Thread signal through the SDK call. AWS SDK takes options.abortSignal
  // as second arg to send():
  modelResponse = await bedrockClient.send(command, {
    abortSignal: parkController.signal,
  });
} catch (err) {
  // CLASSIFY by signal, not error name. DOMException-AbortError vs
  // node-AbortError vs SDK-wrapped all surface differently; the only
  // reliable signal is the controller's own state.
  const wasParked = parkController.signal.aborted;
  if (wasParked) {
    return {
      newAssistantTurns: [{
        role: "assistant",
        kind: "abstain-terminal",
        reason: "tech-aborted",      // typed reason — NOT "bedrock-error"
        rationale: "Conversation parked mid-turn. Resume via /resume.",
      }],
      // ... no partial turn persisted
    };
  }
  // Real upstream error → existing error path (typed differently)
} finally {
  clearInFlightRun(input.conversationId, parkController);
}
```

### Phase 3 · Route integration

```typescript
// /park handler — flips DB status AND aborts in-flight upstream call
await prisma.conversation.update({
  where: { id }, data: { status: "parked" },
});
const wasInFlight = signalParkOfConversation(id);
return reply.send({
  ok: true,
  status: "parked",
  abortedInFlight: wasInFlight,   // tells caller park-mid-stream vs park-between-turns
});
```

### Phase 4 · Cluster-mode caveat (document in module header)

The registry is per-process. Under fork-mode pm2 (one backend instance per node process), the `/park` request and the SSE stream are served by the same worker because Fastify keeps connections on the accepting worker. So this is naturally correct under typical deployments.

If you ever go cluster-mode (multiple workers per process), this needs Redis pubsub or similar. **Document the caveat in the module header** — future readers shouldn't have to rediscover it.

## Gotchas

### Don't classify by error name

`err instanceof DOMException && err.name === "AbortError"` is unreliable across SDK wrappings. Use `controller.signal.aborted`.

### Don't persist partial turns on park

The user explicitly bailed. Persisting partial state is hostile to resumability.

### Don't forget the match-controller guard in `clearInFlightRun`

A normal-completion clear racing a park abort would erase the wrong registration.

### Don't put the registry in a test-shared module

Process-local Map is fine; making it shared (Redis, in-memory queue) before you actually need cluster-mode is over-engineering.

## Invariants consulted

- **Invariant 1 · Cancel propagates through the SDK** — abortSignal threaded into the upstream `.send(command, {abortSignal})` call.
- **Invariant 2 · Classify by signal state, not error name** — SDK wrappings vary; controller is canonical.
- **Invariant 3 · Match-controller guard prevents stale clears** — a normal completion's clear must not erase a fresh registration.
- **Invariant 4 · Registry is per-process** — fork-mode pm2 makes this naturally correct; cluster-mode requires Redis.

## Seed lessons

1. **DB-flag-only cancel = upstream call still runs to completion** · P0 · generic. Burns tokens; persists partial state after user left.
2. **Signal.aborted is the only reliable cancel-vs-error classifier** · P1 · generic. SDK wrappings produce different error shapes; signal state is canonical.
3. **Match-controller guard is load-bearing** · P1 · generic. A normal-completion clear racing a park abort erases the wrong registration without it.
4. **Re-register aborts the prior controller** · P2 · generic. Defense-in-depth; ensures stale controllers don't keep upstream calls alive.
5. **`inFlightCount()` test-only export catches leaks** · P3 · generic. Unit test asserts count returns to 0 after every test.

## Integration

- **`./hand-written-not-autodetect.md`** — companion: when describing the cancel behavior in user-facing surface, hand-write the description; don't autogenerate.
- **`/verify-before-claim`** — "park aborts in-flight call" claim requires a test that asserts `signal.aborted === true` after the park route fires.

## Completeness principle

10/10: process-local registry · abortSignal threaded into SDK · classify by signal state · match-controller guard · idempotent signal · unit test for `inFlightCount()` · cluster-mode caveat documented in module header.

7/10: process-local registry without the match-controller guard (race conditions on rare clears).

3/10: DB-flag-only cancel (upstream call runs to completion regardless).

**Default: 10/10.** The registry is ~50 LOC; the failure mode without it is hours of token-cost surprise + partial-turn corruption.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version.
