---
name: defer-with-trigger
namespace: session-lessons
version: 0.1.0
description: |
  Clean deferral with re-pickup trigger condition when a backlog item is
  blocked on data, classpath, prod state, or another session's prerequisite.
  Beats stubbing or shipping incomplete code. Names the specific signal
  that would unblock pickup.
allowed-tools:
  - Bash
provenance: |
  forged 2026-04-29 from a backlog item that needed deferral when the
  underlying schema-table didn't exist yet — shipping today would have
  produced a UX worse than not shipping (cold-start data void).
---

# defer-with-trigger · clean deferral beats stubbing

## Why this exists

- You picked up a backlog item. You start. You discover it's blocked on data, classpath, library, API, or another session's prerequisite.
- Three temptations: stub it ("ship a skeleton that does nothing"), guess ("make plausible types and hope"), or silently drop it ("don't pick it up, don't tell anyone").
- All three produce worse outcomes than naming the deferral with a specific re-pickup trigger condition.
- This skill exists because "we'll get to it later" rots; "when X observable signal fires, kick off the PR" is a structured handoff to a future event.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag defer-with-trigger --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Backlog item references data that doesn't exist yet (no rows, no table, no fixture).
- Classpath / library / API the feature needs isn't accessible from your environment.
- A peer session's prerequisite hasn't merged yet.
- The work would be wasted when the prerequisite arrives in known-shape form.

Voice triggers: "block on data", "schema doesn't have", "no classpath access", "waiting on K's PR".

## Workflow

### Phase 1 · Schema/classpath probe

Before deferring, *concretely* check the blocker. Don't defer based on guess:

```bash
# Example: probe the schema for the expected table
gh api "repos/$REPO/contents/<repo>/prisma/schema.prisma?ref=staging" \
  --jq '.content' | base64 -d | grep -E "^model (Repair|History|Pattern)" | head -5

# Example: probe for the classpath
java -cp <jar> -version 2>&1 | head -3
```

The probe result goes in the deferral comment as evidence.

### Phase 2 · Decide: defer or push through

Defer when:
- Shipping today would create a UX worse than not shipping (cold-start data void, broken surface).
- The work would be wasted when the prerequisite arrives.

Push through when:
- The blocker is "I don't know the answer" — find out (the answer exists somewhere).
- The blocker is "it's tedious" — tedious is not blocking.
- The blocker is "it would take longer than I want" — time is a budget, not a blocker.

The deferral comment must make this judgment defensible.

### Phase 3 · Deferral comment template

```markdown
## Session <YOUR> — feature X · deferring per plan §<feature>

The plan said: *"verify on day 1; defer if empty."*

### Schema probe result

There is no `<expected_table>` table on staging. The closest analogues are:

| Model | Domain | Suitable for "shop pattern library"? |
|---|---|---|
| `<event_log_table>` | terminal events (1 row per session) | Yes in principle — but production data is sparse |
| `<other_pattern_table>` | adjacent-domain patterns | No — different data model |

### Decision: defer

Building the pattern library service against `<event_log_table>` today would yield a cold-start
library with effectively zero patterns to surface — UX worse than not having it, because
the surface would tell users "no pattern matches" repeatedly and they'd stop trusting it.
Better: ship it once the data has accumulated.

### Trigger to re-pick-up

When `<event_log_table>` has ≥ 200 rows with `terminalKind="diagnosis"` per shop (org), kick off
the feature PR. Operator can query the row count anytime; I (Session <YOUR>) will re-probe
weekly via factory cron. Until then, **no feature PR**.

### Status table delta

| Epic | Was | Now |
|---|---|---|
| **<feature>** Shop pattern library | tbd · blocked on data | ⏸ deferred — re-evaluate at ≥200 rows per org |
```

### Phase 4 · Spec-as-issue when classpath-blocked

If the deferral is because YOU can't ship it (missing classpath, missing prod access) but ANOTHER session can, file a complete spec as an issue, not a comment. The issue carries the spec into the other session's queue without losing context. This pattern is the spec-as-issue equivalent of the migration-PR-with-pre-deploy-warning shape.

## Gotchas

### Don't stub the missing piece

A skeleton that "looks like" the feature is worse than no feature, because future you trusts it.

### Don't guess the spec details

Vendor classpath, schema column types, API contracts — guessing is a 10-minute fix that costs hours when the actual shape lands.

### Don't defer silently

A deferral nobody knows about is the same as dropping the work.

### Don't defer without a trigger

"We'll revisit" with no condition is rot. Always: "when X, then Y."

## Invariants consulted

- **Invariant 1 · Trigger conditions are observable** — a cron / probe / coord signal can detect when the trigger fires.
- **Invariant 2 · Deferrals are public** — coord knows the work is on hold, not dropped.
- **Invariant 3 · Schema/classpath probes are evidence** — name the concrete absence, not "I think it's not there yet".
- **Invariant 4 · Spec-as-issue beats spec-in-comment when handing off cross-session** — issues carry context across sessions; comments fade into the thread.

## Seed lessons

1. **Trigger condition turns deferral into observable handoff** · P1 · generic. "When ≥200 rows with terminalKind=diagnosis" is concrete; "we'll get to it later" is rot.
2. **Stubbing is worse than no-feature** · P1 · generic. Future you reads the skeleton as if it works.
3. **Guessing classpath details costs hours** · P2 · generic. Actual class FQCN + constructor signature must come from `javap` or live probe, not assumption.
4. **Spec-as-issue for cross-session handoff** · P2 · generic. The issue carries spec into the next session's queue without losing context.
5. **Trigger must be observable, not aspirational** · P2 · generic. "When data accumulates" → wrong; "when row count ≥ 200" → right.

## Integration

- **`./stale-assignment-detection.md`** — when the assignment is already done, no defer needed.
- **`./path-symmetric-rerouting.md`** — when the assignment is right for the right session, just wrong env.
- **`/verify-before-claim`** — deferral claims require pasted probe evidence (schema query, classpath check).

## Completeness principle

10/10: concrete schema/classpath probe pasted in the deferral, observable trigger condition, public coord post.

7/10: deferral with rationale but vague trigger ("when data is ready").

3/10: silently drop the assignment OR stub a skeleton that "ships."

**Default: 10/10.** A 30-second probe + a structured deferral comment is what turns "I'll get to it" into a real handoff.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version.
