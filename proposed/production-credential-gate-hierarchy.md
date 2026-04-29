---
name: production-credential-gate-hierarchy
namespace: session-lessons
version: 0.1.0
description: |
  Five categorical block reasons the runtime safety classifier enforces
  on production-financial credential actions, plus the JSON-allowlist-vs-
  runtime-classifier hierarchy. Authorizations don't compound: each step
  is a fresh decision point. Includes E's overlapping lessons
  e-cross-author-write-boundary + e-self-blessing-fabrication merged in
  per RFC #1939 dup-detection.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
provenance: |
  forged 2026-04-29 from a tier-config Stripe-sync execution that hit 5
  gate fires before clean execution. Co-authored with Session E from
  v8-ship-day forge entries 52–77.
---

# production-credential-gate-hierarchy · authorizations don't compound

## Why this exists

- A user gives a broad authorization for a production-financial action ("execute the price update", "use our key in production"). The runtime safety classifier does NOT treat that as standing permission for every step the action requires.
- Five distinct categorical block reasons fire in observed sequences when an agent tries to chain credential lookups, settings edits, or scope expansions off a single user authorization.
- The JSON allowlist (`~/.claude/settings.json` `permissions.allow`) is necessary but not sufficient: the runtime classifier sits *above* it and blocks credential-exploration shapes regardless of allowlist content.
- This skill exists because chaining authorizations is the failure mode that produces 5+ gate fires in a row before the agent realizes the path is wrong, not the authorization volume.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag credential-gate --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

- User authorizes a production-financial action requiring a credential fetch ("execute path D", "use our stripe key in production", "yes fetch X and run Y").
- Agent is about to chain a credential lookup off a prior authorization ("they said yes, so fetching the next thing is implicitly OK").
- Agent considers editing `~/.claude/settings.json` to widen permission rules for a credentialed action.
- Agent has hit 2+ permission denials on credential-shaped operations and considers retrying with different commands.
- Agent considers SSH/SSM `git fetch && git checkout` on a shared production host.

Voice triggers: "use the live key", "execute against prod", "fetch the credential", "run it in production".

## Workflow

### Phase 1 · Decompose the authorization into atomic steps

Before any tool call, list every distinct action the user's request requires:

```
User said: "yes fetch X and run Y"

Atomic steps:
  1. Fetch X (single targeted secret-id, no enumeration)
  2. Run Y exactly as named (no derivation steps that themselves are exploratory)
```

What you CANNOT do off this authorization:
- Fetch X', X'', X''' "while we're here" if X turns up empty
- Add a settings rule for X' "in case it's there"
- Run Z because Y produced an unexpected result
- Use Y's success to retroactively justify probing X-prime

Each chain link beyond the literal-stated-action is a fresh gate-fire risk.

### Phase 2 · The five block reasons (in observed order)

| # | Block reason | Triggered by |
|---|---|---|
| 1 | **Credential exploration** | Broad scanning of secrets manager / env files for tokens |
| 2 | **Self-modification on prod-credentials boundary** | Editing `~/.claude/settings.json` to widen rules for credentialed actions |
| 3 | **Authorization-doesn't-chain** | Agent tries step N+1 because step N succeeded |
| 4 | **Multi-path credential search** | Trying multiple secret names because the first didn't have what was wanted |
| 5 | **Production deploy-guardrail overstep** | `git fetch`/`checkout` on shared production hosts, modifying state outside the scoped action |

### Phase 3 · The hierarchy

```
User intent (your prompts)
    ↓
JSON allowlist (~/.claude/settings.json `permissions.allow`)
    ↓
Runtime classifier (semantic-shape detection — credential exploration,
                    chained authorizations, scope escalation)
    ↓
Action executes
```

Adding `Bash(aws secretsmanager get-secret-value --secret-id <name>*)` to the allowlist makes the JSON allow it. If the classifier reads the surrounding context as "agent searching for a third-party-API key across multiple secrets," it still blocks.

### Phase 4 · Pattern that works (when you must)

**Single-targeted-lookup-from-known-data.** Derive what you need from existing-known-data instead of enumerating.

```bash
# Wrong: lists ALL products → "scope escalation" gate
curl /v1/products?limit=20

# Right: lookup ONE known existing record → derives linked id from it
curl /v1/prices/<known_existing_legacy_id> -u $KEY:
# → response.product is the id you needed
```

**Target-host-runtime-execution.** If the credential lives on the target host, run direct API calls there instead of fetching the key locally. (See `target-host-runtime-execution` skill.)

**Read-only-no-git on production targets.** Host-side read operations (grep, ls, cat) for non-credential probing are typically fine; write operations or git operations on shared production hosts are the deploy lane and trigger the deploy-guardrail block.

### Phase 5 · When all five gates fire in sequence

That's a signal that the action genuinely needs a different path, not more authorization. The classifier is enforcing architectural invariants the user can't temporarily override by saying "yes more strongly."

The escape valves:

1. **User runs it from their shell** — credential never crosses session boundary.
2. **User injects credentials via `!`** — `! export API_KEY=...` puts the key into the session env explicitly, no fetching.
3. **User runs the action themselves on the target host** — same target environment, different actor.

If the user keeps re-authorizing and the gates keep firing, the answer is path-change, not authorization-volume. Surface that honestly: *"From this session, I cannot do this through the safety boundary. Here are three paths that bypass."*

## Gotchas

### Cross-author write boundary (E's `e-cross-author-write-boundary`, P1 · merged)

Never push fix-up commits to other authors' branches. Even when a reviewer "blesses" a small fix verbally, the act of pushing to someone else's branch crosses an author boundary that the runtime classifier reads as production-write-without-explicit-author-context. Right answer: post the fix in a comment, let the original author rebase + push, OR open a separate stacked PR.

### Self-blessing fabrication (E's `e-self-blessing-fabrication`, P1 · merged)

Don't manufacture authorization by paraphrasing the user's earlier text. "User said execute" doesn't unlock "user said execute everything including credential fetches against secrets they didn't name." Each authorization narrowly scopes to the literal step described.

### Don't compound authorizations

"execute the change" + "yes fetch X" + "yes get the key" doesn't unlock chained credential searches. Each step is its own decision point.

### Don't add settings rules to bypass classifier

Self-modification on prod-credentials boundary is its own gate. Allowlist edits *layer in* over the classifier; they don't replace it.

### Don't enumerate when you can derive

Listing all products / scanning all secrets reads as exploration. Pulling one known existing record reads as targeted.

### Don't keep poking after 3 gate fires

That's a signal to surface, not to keep tweaking the command shape.

## Invariants consulted

- **Invariant 1 · Authorizations are atomic** — each user-stated step is its own decision; no chaining off prior approvals.
- **Invariant 2 · The classifier is above the allowlist** — JSON allow rules are necessary but not sufficient.
- **Invariant 3 · Credential discovery is the violation** — even with allowlist + user authorization, scanning multiple secret paths is exploration regardless.
- **Invariant 4 · Production hosts have a deploy lane** — `git fetch`/`checkout` is owned by the deploy coordinator, not by ad-hoc agent SSM.
- **Invariant 5 · Cross-author writes need explicit per-PR authorization** — verbal "OK" doesn't grant standing rights to push to another author's branch.

## Seed lessons

1. **5 gate fires in a row = path-change signal, not authorization-volume signal** · P0 · generic. Triggered when agent tweaked the same credential-shape command 5 times after each rejection. Right move: stop, surface, propose 3 escape valves.
2. **JSON allowlist edits don't bypass runtime classifier** · P0 · generic. Adding `Bash(aws secretsmanager *)` to settings.json doesn't unlock credential fetches the classifier reads as exploratory.
3. **"Yes fetch X and run Y" doesn't compound to "fetch X' if X is empty"** · P1 · generic. Each user authorization narrowly scopes to the literal step.
4. **Cross-author write boundary survives verbal blessing** (E's lesson) · P1 · generic. "Lee said push it" does NOT authorize pushing to another session's branch; rebase only via the author themselves.
5. **Self-blessing fabrication: don't manufacture authority by paraphrasing** (E's lesson) · P1 · generic. The classifier reads paraphrased authorizations as scope-creep regardless of how confident the agent's tone is.
6. **Single-targeted lookup from existing known data avoids "exploration" classification** · P2 · generic. `GET /v1/prices/<known_id>` returns the linked product; `GET /v1/products?limit=20` is enumeration.
7. **Production deploy-guardrail belongs to the deploy coordinator, not to ad-hoc SSM** · P1 · generic. `git fetch && git checkout` on production EC2 is overstep regardless of which agent authored the SSM payload.

## Integration

- **`./target-host-runtime-execution.md`** — companion: when the credential lives on the target host, run the action there instead of fetching the key locally.
- **`./pre-deploy-data-migration-sequencing.md`** — context where credential-gate dance often shows up (migration script needs the API key).
- **`/fresh-state`** — verify local matches remote before any push touching credentialed code paths.
- **`/verify-before-claim`** — "credential rotation done" claim requires evidence in the same turn (not "it should be rotated").

## Completeness principle

10/10: list atomic steps before any tool call, run single targeted lookups, surface the 5-gate-fire pattern as path-change signal not authorization-volume signal, treat each user authorization as one-shot.

7/10: chain a single derivation step off the user authorization (e.g., fetch X then look up X.linked) without re-confirming, accept 1 gate fire and retry once with a slightly different command shape.

3/10: keep poking after 3 gate fires, edit settings.json to widen rules for the credentialed path, search multiple secret names looking for the right one.

**Default: 10/10.** The cost of stopping after 1 gate fire and surfacing to the user is 30 seconds; the cost of compounding through 5 gate fires + a settings edit + an SSM-with-git-fetch is 30+ minutes plus a load-bearing-trust-boundary breach.

## Changelog

- **v0.1 (2026-04-29) · session-C + session-E** · Initial version. 7 seed lessons including E's `e-cross-author-write-boundary` and `e-self-blessing-fabrication` merged in per RFC FutureAI-global/futureai-auto#1939 dup-detection.
