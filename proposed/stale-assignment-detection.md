---
name: stale-assignment-detection
namespace: session-lessons
version: 0.1.0
description: |
  Probe-production-then-receipt pattern when a factory cron or coordinator
  session re-assigns work that's already been shipped. Avoids redundant
  re-execution + race-conditions. Distinguishes 404-as-method-mismatch
  from 404-as-route-missing.
allowed-tools:
  - Bash
provenance: |
  forged 2026-04-29 from a multi-session push where the cron re-assigned
  a backend deploy to one session after another had already shipped it
  90 minutes earlier.
---

# stale-assignment-detection · probe production first, post receipt, don't re-execute

## Why this exists

- Multi-session coord factories sometimes re-assign work that's already been shipped (the cron's backlog hasn't refreshed since the prior shipper posted).
- If you blindly execute, you either repeat a successful operation (mostly harmless), try to fix something that isn't broken (waste an hour debugging), or step on another session's in-flight work (race conditions, conflicting writes).
- This skill exists because treating cron-fired assignments as factual rather than hypothetical produces the worst outcomes; treating them as claims-about-state requiring verification is the right shape.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag stale-assignment --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Factory cron pings you with an assignment ("@session-X · execute Y").
- Coordinator session assigns you work that "needs to ship today."
- Backlog item references a state-of-the-world claim ("routes are 404, deploy needed").
- You've been idle for 30+ minutes and got pinged with a "you have work" message.

Voice triggers: "your assignment is", "execute this", "run the deploy", "ship this fix".

## Workflow

### Phase 1 · Treat the assignment as a claim, not a directive

Before any tool call, identify the assignment's implicit factual claim:

```
Assignment: "deploy v7 backend; expect routes to flip 404→401"
Implicit claim: routes currently return 404 in production
Verifiable: yes — direct curl against prod
```

### Phase 2 · Verify the claim's negation isn't already true

Probe production BEFORE running the deploy:

```bash
for route in $EXPECTED_NEW_ROUTES; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "https://${PROD}${route}")
  echo "$code $route"
done
```

If ALL routes already return the expected post-deploy code (e.g., 401 instead of 404) → already shipped.

### Phase 3 · Read coord backwards 60 minutes for a prior receipt

```bash
gh api --paginate "repos/$REPO/issues/$COORD/comments?per_page=100" \
  --jq '.[] | select(.created_at > "<60min-ago>") | select(.body | contains("v7 backend deployed") or contains("✅") or contains("✓"))' \
  | head -20
```

If found: post a stale-receipt comment instead of executing.

### Phase 4 · Receipt template

```markdown
## ✓ <TASK> already shipped · factory cron out-of-sync · <TIMESTAMP>

@<assigner> @<other-sessions> — <TASK> was already completed by **@<original-session> at <ORIGINAL-TIMESTAMP>**
(per their receipt comment). Factory cron re-assigning shipped work — same pattern as
[link to a prior occurrence].

### Live verification just now

```
$ curl ... <route 1>                                    → <code>  ✓ <interpretation>
$ curl ... <route 2>                                    → <code>  ✓ <interpretation>
...
```

[session-<X>] receipt · standing by for next assignment
```

The verification probe is the load-bearing part — never just "yeah E already did it." Paste codes.

### Phase 5 · 404 isn't always "route missing"

When verifying routes, distinguish:

- **`404` on `GET /share/:id`** with random `id` → route IS registered, share-not-found is correct behavior.
- **`404` on `POST /share`** → method-not-allowed disguised; might mean route is GET-only or registered correctly.

Disambiguate by testing the correct method against a path that should produce a known auth/not-found response:

```bash
# 401 confirms route is registered + auth gate fired.
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://prod/api/v1/share/abc"
```

## Gotchas

### When to override and execute anyway

- The original receipt is older than the next deploy cycle's reset.
- The deploy is idempotent AND the cost of re-running is < the cost of debugging "did it actually finish."
- Coord explicitly says "re-run as defense-in-depth."

In those cases, run it AND post the receipt. Don't skip the receipt because "we know it's already shipped."

### Don't run the script first then verify

Probe-then-decide. The script may be destructive enough that re-running is its own incident.

### Don't trust the assignment's claimed pre-state

"Routes are missing" might mean "the assigner didn't check 30 minutes ago." Verify yourself.

### Don't silently drop the assignment

Post the receipt; coord needs to know SOMEONE saw it and decided to no-op.

## Invariants consulted

- **Invariant 1 · Cron assignments are claims, not directives** — verify before executing.
- **Invariant 2 · Verification probes are the load-bearing part of receipts** — never "yeah it's done", always pasted codes.
- **Invariant 3 · 404 ≠ route missing** — disambiguate via correct-method probe.
- **Invariant 4 · Stale-receipt posts maintain coord state** — silence is worse than acknowledged-no-op.

## Seed lessons

1. **Factory cron's backlog refresh lags behind shipper receipts** · P1 · generic. Cron re-fires assignments when the shipper's receipt hasn't propagated to the backlog yet.
2. **Probe-before-execute prevents redundant deploys** · P1 · generic. A 30-second curl saves 10+ minutes of redundant deploy work.
3. **404 on `GET /share/:id` with random id = route registered + correct behavior** · P2 · generic. Don't auto-deploy on this signal.
4. **Stale-receipt comment maintains coord visibility** · P2 · generic. Silent no-op leaves coord wondering if the assignment was seen.
5. **`POST` to a route registered for `GET` produces 405-as-404** · P3 · generic. Disambiguate via correct-method probe.

## Integration

- **`./path-symmetric-rerouting.md`** — when the assignment is RIGHT but landed on the wrong-env session.
- **`./defer-with-trigger.md`** — when the assignment is genuinely blocked (data missing, classpath inaccessible).
- **`/verify-before-claim`** — claims about deploy-state require pasted curl-output evidence.

## Completeness principle

10/10: probe-before-execute on every assignment claiming a state-of-the-world fact, paste codes in stale-receipt, distinguish 404-as-route-missing from 404-as-method-mismatch.

7/10: probe but skip pasting codes (less reviewer-friendly receipts).

3/10: trust the assignment as factual and execute without probing (redundant work + race-condition risk).

**Default: 10/10.** A 30-second curl probe saves both work and reviewer trust.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version.
