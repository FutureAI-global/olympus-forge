---
name: pre-deploy-data-migration-sequencing
namespace: session-lessons
version: 0.1.0
description: |
  Load-bearing-order pattern for code changes that silently degrade
  existing rows: data migration MUST land + run before code deploy.
  Coord-receipt warning shape + idempotency template + dry-run-first
  protocol. Direct merge with E's e-migrate-before-deploy-sequencing.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: |
  forged 2026-04-29 from a tier-config change where existing customers
  would have silently dropped from 2.5M to 100k token allocation if the
  deploy ran before the migration. Direct dup-merge with E's
  e-migrate-before-deploy-sequencing (P1) per RFC #1939 dup-detection.
---

# pre-deploy-data-migration-sequencing · order matters and the deploy lane needs to know

## Why this exists

- Code change A modifies the meaning of a field that's already populated in production. Without a one-time data migration, existing rows silently take on the new behavior.
- The code change is mechanically safe (no crash, no data loss) but semantically harmful to existing users.
- Auto-resync coordinators that ship main-merges to prod the moment a PR lands turn the merge of a tier-config change into the deploy event. If the migration script merges before the data-prep run, the next coordinator-driven resync ships the regression.
- This skill exists because "remember to run the migration before the deploy" is what production runbooks promise but auto-resync coordinators can't see runbooks.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag migration-sequencing --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Shipping a code change that changes the meaning of a populated field (tier-config, schema-flag, enum collapse).
- Adding a `default()` branch that handles new enum values but silently catches retired-enum rows.
- Refactoring a config file where existing rows already cache the field's old semantic.
- The auto-resync coordinator is going to run within minutes of merge; the deploy IS the next merge to main.

Voice triggers: "tier-config change", "schema-flag flip", "enum collapse", "rename existing tier".

## Workflow

### Phase 1 · Determine if a migration is needed

```
For each existing row whose field-of-interest is non-null:
  - Will the new code path produce the same observable behavior as the old?
  - If YES: no migration needed. Code change is purely additive.
  - If NO: write the migration. Compute scope: COUNT(*) WHERE field='<old-value>'.
  - If COUNT > 0: migration is required pre-deploy.
  - If COUNT = 0: migration ships as a no-op safety net (still required for audit trail).
```

### Phase 2 · The migration script template

One-shot script in `<repo>/scripts/<purpose>.ts`. Required invariants:

```typescript
#!/usr/bin/env tsx
// 1. Default to DRY-RUN. Require explicit --execute to write.
const dryRun = !process.argv.includes('--execute');

// 2. Refuse to run without required env vars.
if (!process.env.API_SECRET_KEY) { process.exit(2); }

// 3. Print account context BEFORE any writes.
console.log(`livemode: ${secretKey.startsWith('sk_live_') ? 'LIVE' : 'TEST'}`);

// 4. Iterate and PLAN every row to flip — log each prospective change.
for (const row of rows) {
  if (shouldFlip(row)) {
    console.log(`PLAN  ${row.id}  ${fromValue} -> ${toValue}`);
    plans.push({ id: row.id, fromValue, toValue });
  }
}

// 5. Skip-already-migrated rows (idempotency).
if (currentValue === targetValue) { skipsAlreadyMigrated++; continue; }

// 6. Single-column mutation only.
await db.user.update({
  where: { id: p.userId },
  data: { tierKey: p.toTier }, // ← only this
});

// 7. Print summary: plans, skips per-category, errors.
console.log(`=== plans=${N} skips=${M} errors=${K} mode=${dryRun ? 'DRY-RUN' : 'EXECUTED'} ===`);

// 8. db.$disconnect() in finally — no hanging connections.
```

### Phase 3 · The required ordering

```
Step 1: Migration script lands in repo (one-shot, dry-run capable)
Step 2: Operator runs --dry-run against staging DB → reviews PLAN
Step 3: Operator runs --dry-run against prod DB → reviews PLAN
Step 4: Operator runs --execute against prod DB (maintenance window)
Step 5: Code change deploys to prod app servers

Step 4 MUST precede Step 5. If 4 and 5 are flipped, every existing row regresses
until 4 lands.
```

### Phase 4 · The coord-receipt warning shape

Posting on the active deploy-coordination thread BEFORE the migration PR auto-merge could trigger auto-resync:

```markdown
## 🚨 STILL CRITICAL: do NOT auto-resync the tier-config change until migration script lands AND runs

Existing standard-tier subscribers will silently lose their 2.5M token allocations the
moment the source change hits prod, because their `tierKey='STANDARD'` now points at
the new 100k row.

The grandfather logic only fires at activation time (webhook). Existing users already
have `tierKey='STANDARD'` cached; their tier doesn't get re-resolved on subsequent
requests.

### Required ordering

1. Migration PR (#XXXX) merges
2. Operator --dry-run against staging DB → review PLAN
3. Operator --dry-run against prod DB → review PLAN
4. Operator --execute against prod DB in a maintenance window
5. Coordinator resync of code change (post-step-4 only)

Steps 4 and 5 must NOT be flipped.
```

Make the warning load-bearing for the coord-merger's decision: spell out concrete numbers (24× drop in token allocation) and numbered steps with explicit failure mode if flipped.

## Gotchas

### Don't ship the code change without the migration PR open

Once the code lands in main, the next auto-resync is your deadline. Migration as a separate PR makes "merge code without migration" a deliberate choice, not an accident.

### Don't use --execute as the default mode

DRY-RUN default + explicit --execute flag. Misclicks shouldn't write.

### Don't omit the account/db-host context print

Operators run scripts against the wrong environment more often than you'd think. Print before write.

### Don't write the migration as part of the code-change PR

Separate PR. The code change can pass review with the migration as its blocker.

## Invariants consulted

- **Invariant 1 · Migrations land before their referenced code change reaches prod**.
- **Invariant 2 · Migrations are idempotent** — detect already-migrated rows by their target state, not a "was-migrated" flag.
- **Invariant 3 · Migrations write only the field that's changing** — single-column mutation; never touch unrelated fields.
- **Invariant 4 · Migrations default to DRY-RUN** — explicit --execute required.

## Seed lessons

1. **Auto-resync coordinator IS the deploy** · P0 · generic. If the migration PR merges before the data-prep run, the next coordinator resync ships the regression.
2. **Existing rows cache the old field semantic** · P0 · generic. Grandfather logic only fires at activation/registration time; existing rows already have the field cached; their tier doesn't get re-resolved on subsequent requests.
3. **Migration ran no-op = best case, not skip** · P2 · generic. Even if zero affected rows, the migration still ships for audit trail + insurance against the next time a code change touches a tier with N>0 subscribers.
4. **Detect already-migrated by target state, not flag** · P1 · generic. If `user.tierKey === 'STANDARD_LEGACY'` already, skip — same as if we never had to touch this row.
5. **Coord-receipt makes the ordering load-bearing** · P1 · generic. Concrete numbers (24× drop) + numbered steps + explicit failure-mode-if-flipped. Two-read-throughs from any reviewer.

## Integration

- **`./production-credential-gate-hierarchy.md`** — credential-gate taxonomy for the API key the migration uses.
- **`./target-host-runtime-execution.md`** — when the migration runs on a host that already has the key.
- **`/verify-before-claim`** — "migration ran clean" claim requires the script's PLAN/EXECUTED summary in the same turn.

## Completeness principle

10/10: separate PR for the migration · DRY-RUN default · account-context print before writes · single-column mutation · re-run idempotent · coord-receipt with concrete numbers + numbered ordering steps.

7/10: skip the coord-receipt (risk: coord-merger auto-resyncs before operator runs --execute).

3/10: bake migration into the code-change PR (risk: code merges, auto-resync ships, migration "we'll get to later" turns into customer regression).

**Default: 10/10.** The 30-minute cost of writing the migration as a separate PR + coord-receipt is preventive insurance against an outage that takes hours to detect + reverse.

## Changelog

- **v0.1 (2026-04-29) · session-C + session-E** · Initial version. Direct dup-merge with E's `e-migrate-before-deploy-sequencing` per RFC #1939 dup-detection.
