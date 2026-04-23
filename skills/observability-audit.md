---
name: observability-audit
namespace: session-lessons
version: 0.1.0
description: |
  Every declared metric has a caller. Every silent-catch has a signal. Before
  declaring a feature shipped, audit: for every Counter/Histogram/Gauge in the
  diff, assert a non-test caller exists. For every `catch (err) {}` + `{ok:false}`
  return + null-fallback, require a metric emission or an explicit audit log. No
  observability claims without `curl /metrics | grep <name>` output in the PR body.
allowed-tools:
  - Bash
  - Read
  - Grep
  - AskUserQuestion
---

# observability-audit · every signal has a caller

## Why this exists

`a validator-finding counter` sat exported from `<metrics-file>` for ≥4 weeks with zero callers. Soft-findings invisible. Rising rates of `fake-tool-narration` / `phantom-reference` / `tier-chip-missing` never registered to ops. The same class of bug kept shipping because nothing signaled it.

That pattern has multiple siblings:
- `a server-side-dispatch function` returned `{ ok: false }` on handler throw → runner coasted → no metric
- `ensureSession` caught 401s with log-only → cookie staleness invisible
- Phase tracking `"unspecified"` when narration lacks `## Phase N` → soft-finding fires but no counter tracks rate

This skill is the pre-ship audit that catches each shape.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag observability-audit --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

- Session is about to declare a PR "shipped" / "observability improved" / "metrics wired"
- Session creates a new `Counter` / `Histogram` / `Gauge` / `recordX` export
- Session writes a `catch (err) {}` block with a silent fallback
- Session adds a handler that returns `{ ok: false }` or `null` on error

Voice triggers: "audit observability", "did we wire the metric", "observability check".

## Workflow

### Phase 1 · Enumerate declared metrics in the PR

```bash
# Find every new metric declaration
git diff <base>...<head> -- '*.ts' | grep -E '(new Counter|new Histogram|new Gauge|registers: \[)' | head
```

List every metric name + its declaring file:line.

### Phase 2 · Verify each has a caller

For every declared metric:

```bash
# Non-test callers
METRIC=<name>
grep -rn "$METRIC" backend/src/ --include='*.ts' | grep -v __tests__ | grep -v '\.test\.' | head
```

Pass: at least one non-test caller exists.
Fail: zero callers → block the PR until a call site is added (or the metric is deleted).

### Phase 3 · Scan for silent catches

```bash
# Find silent-catch shapes in the diff
git diff <base>...<head> -- '*.ts' | grep -E '(catch \(.*\) \{\s*\}|catch \{\s*\}|ok: false|return null;)' | head
```

For each hit, verify ONE of:
- `(a)` Emits a Prometheus counter — `recordXxx(...)` call within the catch block
- `(b)` Writes a structured audit log — `logger.warn`/`error` with structured fields
- `(c)` Has an inline comment explaining why silence is correct

No match across all three → flag as observability debt.

### Phase 4 · PR-body evidence check

Grep the draft PR body for narration claims:

- "metrics wired" → requires `curl /metrics | grep <name>` output cited
- "observability improved" → requires per-metric verification output
- "silent-failure surface closed" → requires before/after trace showing the counter now fires

If any claim lacks inline evidence → AskUserQuestion: "Verify metric `<name>` fires OR demote the claim."

### Phase 5 · Capture lesson if new pattern

For any counter declared without a caller, or silent-catch without a signal:

```bash
~/.claude/skills/session-lessons/bin/capture-lesson \
  --skill observability-audit \
  --pattern "<shape>" \
  --evidence "<file:line>" \
  --fix "<how to resolve>" \
  --severity P1 \
  --scope generic \
  --tags "observability,silent-failure,<stack-tag>"
```

## Seed lessons

1. **Counter declared but never called** · P0 · generic
   - Evidence: `a validator-finding counter` at `<metrics-file>` — 0 callers for ≥4 weeks
   - Fix: every new Counter in a PR must have a grep-verified non-test caller in the same PR

2. **ok:false return silently accepted by caller** · P0 · generic
   - Evidence: `a server-side-dispatch function` catch block returned `{ok:false}`; runner coasted past
   - Fix: emit `*_ok_false_total{tool}` counter in the catch; or require caller to distinguish

3. **401/403 on auth path logged but not counted** · P0 · generic
   - Evidence: `ensureSession` caught authError with `logger.error` only; no metric for cookie expiry
   - Fix: emit `*_auth_failure_total{operation}` in the authError catch

4. **tool_use without tool_result silent** · P0 · generic
   - Evidence: 3 CLI processes stuck 18-22h; no counter for "tool_use turn with no tool_result within N turns"
   - Fix: audit conversation at completion; emit `*_tool_use_orphan_total{tool}` per orphan

5. **Phase / stage tag missing, soft-finding unrecorded** · P1 · <your-project>
   - Evidence: "Phase X" extraction returned "unspecified"; soft-finding fired but no counter tracked the rate
   - Fix: any soft-finding emit path must go through `recordXxx(...)` wrapper

6. **"observability improved" claim without curl output in PR body** · P1 · generic
   - Evidence: PR bodies claiming metrics wiring without showing `/metrics` output proving the counter fires
   - Fix: require verification output in the PR body before merge

## Integration

- **`/verify-before-claim`** — "metric emits" claim requires curl output, enforced by both skills
- **`/two-claude-review`** — reviewer re-runs `grep -rn <metric>` to verify counters have callers
- **`/post-mortem`** — every counter-without-caller finding captured for aggregator

## Invariants consulted

- **Invariant 6 · Every declared metric has a caller**
- **Invariant 7 · Every silent-catch has a signal**

## Completeness Principle

10/10: audit every counter + every catch + every narration claim; require inline evidence.
7/10: audit only the new additions in the diff.
3/10: trust author self-grade on observability; skip the audit.

**Default: 10/10** for any PR that touches metric declarations. **7/10** for unrelated PRs.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version. 6 seed lessons + 5-phase workflow.
