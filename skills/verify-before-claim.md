---
name: verify-before-claim
namespace: session-lessons
version: 0.1.0
description: |
  Anti-inflation enforcement. Before any factual claim in a response ("tsc clean",
  "tests pass", "fix works", "metric emits", "PR opened", "file exists"), require
  either the verifying command's output in the SAME turn OR an explicit "unverified"
  tag. Blocks sessions from shipping claims that lack evidence. The primary fix for
  the inflation failure mode that Two-Claude Review catches eventually.
allowed-tools:
  - Bash
  - Read
  - Grep
  - AskUserQuestion
---

# verify-before-claim · anti-inflation enforcement

## Why this exists

A single session made 3 consecutive false "tsc clean" claims across 3 cycles in April 2026 before independent review caught them. That incident kicked off the Two-Claude Review Protocol — but the primary defense is never making the false claim in the first place.

This skill fires **before** a session's final response is sent. It scans the draft for claim shapes ("tsc clean", "tests pass", "fix works", etc.) and requires evidence in the same message. Sessions that would have inflated get blocked before inflation reaches the user.

## Preamble (run first)

```bash
# Surface top-3 relevant prior lessons for this skill
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag verify-before-claim --limit 3 2>/dev/null || true
fi

# Session identity (used when capturing new lessons)
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
export _SESSION_NAME

# Slug for the current project's learnings.jsonl
if [ -x ~/.claude/skills/gstack/bin/gstack-slug ]; then
  eval "$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null)"
fi
_LEARNINGS_FILE="${GSTACK_HOME:-$HOME/.gstack}/projects/${SLUG:-unknown}/learnings.jsonl"
export _LEARNINGS_FILE
```

## Trigger conditions

Fire this skill when the session is about to:

1. Emit a final response containing any of these claim-shapes:
   - `tsc clean` / `typecheck passes` / `no type errors`
   - `tests pass` / `N/N passed` / `jest green`
   - `fixed` / `works` / `verified` / `shipped` / `green`
   - `PR opened` / `PR #N` / `branch pushed`
   - `metric emits` / `counter fires` / `log appears`
   - `file exists` / `endpoint returns` / `login succeeds`
   - `backend healthy` / `deploy succeeded` / `smoke passed`
   - `X% coverage` / `N rows returned` / `Y bytes saved`

2. Make a numeric claim (latency, row count, percentage) without a source

3. Reference a fact that could only be known by running a check (a file's contents, a DB row, a running process's state)

Voice triggers (speech-to-text aliases for manual invocation): "verify my claims", "check before I ship", "anti-inflation", "run the check".

## Workflow

### Phase 1 · Scan the draft response

Parse the last planned response text for claim-patterns. Build a list:

```
[
  { claim: "tsc clean", evidence: null, line: 23 },
  { claim: "6/6 tests pass", evidence: "jest output cited at line 18", line: 26 },
  { claim: "PR #1555 opened", evidence: "url cited at line 30", line: 30 },
]
```

### Phase 2 · Verify each claim

For each entry with `evidence: null`:

**Option A — run the check now:**
- `tsc clean` → `cd <project>/backend && ./node_modules/.bin/tsc --noEmit 2>&1 | tail -5`
- `tests pass` → `cd <project>/backend && ./node_modules/.bin/jest --testPathPatterns="<pattern>" 2>&1 | tail -10`
- `PR opened` → `gh pr view <num> --json state,url,title`
- `metric emits` → `curl -sS <metrics-endpoint> | grep <metric-name>`
- `file exists` → `ls -la <path>` or `Read` tool
- `endpoint returns X` → `curl -sS -w "HTTP=%{http_code}" <url>`

**Option B — demote the claim:**
- Replace `"tsc clean"` → `"code changed, tsc not yet verified"`
- Replace `"tests pass"` → `"tests authored, not yet run"`
- Replace `"fixed"` → `"code changed, not yet verified end-to-end"`
- Replace `"metric emits"` → `"counter wired, not yet observed firing"`

**Option C — AskUserQuestion if unsure:**
Format: "Before I claim `<claim>`, I can (1) run `<command>` now to verify, (2) ship with 'unverified' label, (3) drop the claim. Recommend [1]."

### Phase 3 · Block the response

If any claim still lacks evidence AND the user hasn't approved Option B/C:

```
🔒 verify-before-claim blocked completion · N unverified claim(s):
  1. "tsc clean" at line 23 — no tsc output in this turn
  2. "backend healthy" at line 29 — no health-check output in this turn

To continue:
  (a) Run the check and cite output inline
  (b) Demote to "unverified" labels
  (c) AskUserQuestion for the user's call
```

### Phase 4 · Capture lesson if new pattern

If the scan catches a claim-shape not yet in `verify-before-claim`'s lesson file, append it via `/post-mortem`:

```bash
~/.claude/skills/session-lessons/bin/capture-lesson \
  --skill verify-before-claim \
  --pattern "claimed '<shape>' without running '<command>'" \
  --evidence "<this turn's context>" \
  --fix "always run <command> and cite output before claiming <shape>" \
  --severity P1 \
  --scope generic \
  --tags "self-grade,<shape-specific-tag>"
```

## Invariants consulted

- **Invariant 1 · Run the check before claiming** (`~/.claude/skills/session-lessons/INVARIANTS.md`)
- **Invariant 8 · Two-Claude Review for ship-candidate changes** (this skill is the first-line defense; Two-Claude is the backstop)
- **Invariant 9 · User corrections are lessons** (if a user flags an inflated claim, capture as new lesson)

## Seed lessons (shipped with v0.1)

1. **claimed "tsc clean" without running tsc** · P1 · generic
   - Evidence: multiple PRs in April 2026 shipped with runtime bugs that tsc would never catch
   - Fix: cite `backend/node_modules/.bin/tsc --noEmit` exit code + trailing stderr

2. **claimed "tests pass" with tests authored but not run** · P1 · generic
   - Evidence: PR #1534 shipped with 2 runtime bugs (path wrong, loadCorpus flat) caught only when e2e tests ran for the first time
   - Fix: `jest --testPathPatterns="..."` must show exit 0 + non-zero test count

3. **claimed "metric emits" without curl /metrics** · P2 · generic
   - Evidence: `a validator-finding counter` declared in `<metrics-file>` but never called for weeks
   - Fix: `curl -sS http://localhost:<port>/metrics | grep <metric-name>` must return a row

4. **claimed "fix works" without end-to-end reproduction** · P0 · generic
   - Evidence: 3 stuck CLI processes (a recent incident) hit a pre-a server-side-dispatch fix backend; "fix shipped" meant the code changed, not that the hang was resolved on the stale-backend path
   - Fix: reproduce the original failure condition, apply the fix, reproduce again → confirm different outcome

5. **claimed PR opened without the URL** · P2 · generic
   - Evidence: "PR opened for review" without citing the `#1234` or URL means the reader can't even navigate to confirm
   - Fix: every PR claim carries the `#N` or the full URL in the same turn

6. **numeric claim without a source** · P1 · generic
   - Evidence: "15-30s latency", "70% coverage", "3x faster" — none of these mean anything without a measurement command and its output
   - Fix: if the number wasn't measured in this turn, label it "estimated" or drop it

## Integration points

- **`/post-mortem`** — when this skill catches a new claim-shape, capture it via post-mortem for the next session
- **`/two-claude-review`** — the reviewer runs the same scan against the implementer's self-grade, catching inflations the implementer missed
- **`/observability-audit`** — shares the "does this signal actually fire?" mindset; counter-caller check reuses the same "run the grep" discipline

## Honesty anchor (from CLAUDE.md)

This skill is the operational expression of the "Absolute Truth" section in CLAUDE.md:

> Never claim you measured something you didn't measure. If you didn't time an API call, don't say "15-30s." Say "I don't know — I didn't measure it."
>
> Never grade your own work higher than reality. If you didn't test a feature end-to-end (create → save → reload → verify), don't call it "A++." Call it "untested."
>
> Never say "fixed" without proving it works. A code change is not a fix until verified.

## Completeness Principle

Completeness 10/10: run every check for every claim, cite every output, leave no claim unverified.
Completeness 7/10: run the high-leverage checks (tsc, jest, smoke); label the low-leverage ones "unverified."
Completeness 3/10: ship claims with no evidence and hope the reviewer catches it.

**Default target: 10/10.** The cost of running a check is ~30 seconds; the cost of shipping an inflated claim is an incident. Completeness is near-free.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version with 6 seed lessons + 4-phase workflow.
