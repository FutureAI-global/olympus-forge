---
name: drift-guard-test
namespace: session-lessons
version: 0.1.0
description: |
  When a session has shipped 5+ PRs across an epic or coord run, write a
  single drift-guard test file that imports every shipped surface, verifies
  the per-PR invariants, and ends with one end-to-end "primitives compose"
  case. Per-feature tests catch behavior regressions inside one module; the
  drift guard catches cross-module composition breaks (a delete-a-type, a
  rename-a-MUST, a schema-version-bump-without-migration). Fires loudly when
  any sibling session regresses the originating session's surface.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a multi-PR epic delivery where one drift-guard test file (25 cases, ~600 lines) caught composition regressions that 9 separate per-feature suites individually could not see
---

# drift-guard-test · proves a multi-PR batch composes after each lands

## Why this exists

After a session ships 5+ PRs in a coord run, future PRs from sibling sessions can regress the originating surface in subtle ways:

- Delete a type from a shared types file
- Remove or rename a MUST in a system prompt
- Rename a validator rule
- Change a formatter's signature
- Break the demo-replay state machine
- Bump a config schema version without a migration

Per-feature tests catch behavior regressions inside one module. They DO NOT catch cross-module composition breaks. A PII scrubber and a repair-order-formatter can both pass their own per-feature tests in isolation while failing together when scrubbed output is no longer formatable.

The drift guard fires when ANY of these regress, in one place, with one command.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag drift-guard --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

Fire this skill when:

1. The originating session has shipped 5+ PRs in a coord run and the work-stream is wrapping
2. The coord PR's owner is asking "is this batch ready for the next merge train?"
3. New exports have landed across multiple modules and a smoke check that they all wire together is needed
4. Pre-merge: about to admin-merge a stack and want one last "everything composes" assertion
5. About to hand off the epic to a sibling session and want to leave behind a regression tripwire

Voice triggers: "drift guard", "compose check", "epic smoke", "make sure the batch still wires together".

## Workflow

### Phase 1 · Inventory the shipped surface

List every PR in the run with the export(s) it added:

```
PR #X1 → types in <path>/types.ts (Type1, Type2)
PR #X2 → invariants in <path>/system-prompt.ts (MUST-XX, MUST-YY)
PR #X3 → validator rule in <path>/validator.ts (RULE_FOO)
PR #X4 → formatter in <path>/formatters/format-a.ts (formatA)
...
```

The list defines the drift-guard's `describe` blocks: one per PR.

### Phase 2 · Author the single drift-guard file

```typescript
/**
 * <session-tag>-shipped surface · drift guard for <release> (#<coord>).
 *
 * Verifies every PR (#X1, #X2, ...) is wired correctly:
 *   - Types are exported (PR #X1)
 *   - System-prompt invariants present (PR #X2)
 *   - <module> exports + functional (PR #X3)
 *   - ...
 *
 * NOT exhaustive. See per-feature test files for that. This is the
 * smoke check that all surfaces compose together.
 */

import type { TypeFromPR1, TypeFromPR2 } from "../path/types";
import { exportFromPR3, exportFromPR4 } from "../path/module";
// ...

describe("<session-tag>-shipped surface · drift guard for <release> (#<coord>)", () => {
  describe("PR #X1 · types exported with expected fields", () => {
    test("Type1 supports all kinds + optional fields", () => {
      const t: Type1 = { /* ... */ };
      expect(t.field).toBe(/* ... */);
    });
  });

  describe("PR #X2 · system-prompt invariants", () => {
    test("MUST-XX in system-prompt + key invariants", () => {
      expect(SYSTEM_PROMPT).toMatch(/MUST-XX/);
      expect(SYSTEM_PROMPT).toMatch(/KEY_INVARIANT_PHRASE/);
    });
  });

  // ... one describe block per PR ...

  describe("Primitives compose end-to-end (the actual <release> surface)", () => {
    test("real-data scenario: load → process → format → verify", () => {
      const fx = loadDemoFixture('canonical-id');
      const session = createSession(fx);
      let last = null;
      let next = advanceTurn(session);
      while (next !== null) { last = next; next = advanceTurn(session); }
      const dx = (last as any).result;

      const ro = formatA({ id: fx.id, result: dx });
      expect(ro).toMatch(/EXPECTED/);

      const md = formatB({ id: fx.id, result: dx });
      expect(md).toMatch(/EXPECTED/);

      // chain through every shipped primitive
    });
  });
});
```

### Phase 3 · Verify the batch passes together

```bash
npx jest --testPathPatterns "(<feature1>|<feature2>|<feature3>|drift-guard)"
```

The drift guard sits alongside per-feature tests. If everything passes, the batch is shippable.

## What NOT to do

- Do not recapitulate per-feature tests. Each drift-guard case is one or two lightweight assertions, not a re-run of the per-feature suite.
- Do not mock the inputs. Load the real fixture, run the real formatters, check the real output. Mocks defeat the drift purpose because they hide the case where the real fixture's shape diverges from what the consumer expects.
- Do not split the drift guard across N files. The whole point is one place to grep "is the originating session's batch still composing?" Splitting defeats the purpose.
- Do not skip the end-to-end composition case. The last `describe` block must chain primitives with real data; that case catches "PR #X4 broke PR #X7's input shape silently".
- Do not import a sibling session's primitives. Each session's drift guard tests its OWN shipped surface. Cross-session composition is a different skill.

## Seed lessons

### Lesson 1 · One file per session-batch beats one file per PR

The originating session's drift guard for a 13-PR run is ONE file with ~25 tests. Splitting into per-PR drift-guard files defeats the unified "is the batch composing" check. If the file gets unwieldy, group into `describe` blocks per PR; resist splitting into separate files.

### Lesson 2 · Every PR gets at least one drift-guard case

If the drift guard has no case for PR #X3, PR #X3's surface is not covered. Add one, even if it is just `import { exportName } from "..."; expect(typeof exportName).toBe("function")`. The minimum viable drift case is "the export exists and has the expected type shape".

### Lesson 3 · Real fixtures plus real shapes

Load the actual fixture, run the actual formatters, check the actual output strings. The whole point is to exercise the real composition path. Mocks defeat the drift purpose: a mocked input always matches the assertion, including in the case where the real fixture's shape has diverged.

### Lesson 4 · Schema-version assertion is mandatory for JSON config stores

For any JSON config store (per `atomic-json-config-store`), the drift guard MUST include a schema-version assertion:

```typescript
test("PROFILE_SCHEMA_VERSION exported", () => {
  expect(PROFILE_SCHEMA_VERSION).toBe(1);
});
```

If a sibling session bumps the schema without a migration, this fires. Without this case, the bump ships silently and breaks every existing config file in the wild.

### Lesson 5 · End with end-to-end composition

The last `describe` block must demonstrate the primitives chaining together with real data: load fixture → walk turns → extract result → format three ways → scrub → verify each output non-empty. This is the case that catches cross-module breaks. Per-feature tests can not see across modules; this one must.

## Invariants consulted

- `verify-before-claim`: the drift guard is the evidence for "the batch composes". When the coord PR closes with "batch is shippable", the drift guard's jest output is the receipt.
- `fresh-state`: the drift guard runs against the freshest state of every shipped module. If a sibling session has regressed any of them, the next drift-guard run catches it.

## Integration points

- Pairs with `verify-before-claim`: drift-guard jest output is the canonical evidence for the "composes end-to-end" claim. The coord PR's `[verified]` tag in the lane table cites the literal jest output line.
- Pairs with `atomic-json-config-store`: the schema-version assertion case in the drift guard is mandatory for any JSON config store the batch ships.
- Pairs with `epic-assist-primitive`: drift guard is the final step in the assist methodology after primitives have been delivered to the requesting epic.

## Completeness principle

Completeness 10/10: one describe block per PR + the end-to-end composition case + schema-version assertions for every JSON store + jest output cited in the coord PR.
Completeness 7/10: skip the end-to-end composition case (risk: cross-module breaks ship silently).
Completeness 3/10: write per-feature tests only and call the batch "tested". This is the failure mode the skill exists to prevent.

Default target: 10/10. One ~600-line file per epic batch is cheap; the cost of a cross-module composition regression that ships to production is measured in incident hours.

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a multi-PR epic delivery where a single drift-guard file (25 cases) caught composition regressions that the per-feature suites individually could not.
