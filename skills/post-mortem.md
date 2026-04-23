---
name: post-mortem
namespace: session-lessons
version: 0.1.0
description: |
  Capture new lessons on mistake detection. Fires when a user correction lands,
  when a session realizes mid-work its own earlier output was wrong, or when
  another session-lessons skill catches a new pattern. Writes structured JSONL
  to learnings.jsonl; when a pattern accumulates ≥3 sessions of evidence, proposes
  hoisting to the owning skill's Invariants section.
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

# post-mortem · capture lessons the moment they happen

## Why this exists

A user correction ("no that's wrong", "don't do X", "you inflated Y") is not a blocker to resolve and move on. It's a lesson to capture. Without capture, the next session makes the same mistake.

This is the meta-skill. It turns an individual session's failure into shared wisdom.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag post-mortem --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"

# Derive slug for the current project's learnings.jsonl
if [ -x ~/.claude/skills/gstack/bin/gstack-slug ]; then
  eval "$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null)"
fi
_LEARNINGS_FILE="${GSTACK_HOME:-$HOME/.gstack}/projects/${SLUG:-unknown}/learnings.jsonl"
mkdir -p "$(dirname "$_LEARNINGS_FILE")"
touch "$_LEARNINGS_FILE"
```

## Trigger conditions

Fire immediately when ANY of:

1. **User correction detected** — keywords like "no that's wrong", "don't do X", "stop doing Y", "you're lying", "you inflated", "you fabricated", "that's not true", "you got it wrong"

2. **Self-detected error** — session realizes mid-work that its own earlier output was incorrect (e.g., "I just checked and my earlier claim was wrong because...")

3. **Another session-lessons skill flags a new pattern** — `/verify-before-claim`, `/fresh-state`, `/api-push`, `/observability-audit`, `/two-claude-review` all call into this skill when they detect a new failure shape

4. **Manual invocation** — `/post-mortem` with optional args describing the incident

Voice triggers: "capture this lesson", "log this mistake", "post-mortem", "write this down for next time".

## Workflow

### Phase 1 · Confirm the failure shape

Interactively with the user:

```
I caught [myself / this session] doing [failure shape]. Before capturing:

1. One-sentence pattern summary: "[draft]"
2. Evidence (what proves it happened): "[draft]"
3. Fix (the recommended action for future sessions): "[draft]"

Correct any of these? [Y to confirm, edit, or skip]
```

If the user wants to skip (not worth capturing), respect that. Minor polish won't make it into the pool. Only capture what will help another session.

### Phase 2 · Classify

Which skill owns this lesson?

- Unverified factual claim → `verify-before-claim`
- Stale-local-state / worktree-drift → `fresh-state`
- PR / push / diff-shape → `api-push`
- Metric without caller, silent catch → `observability-audit`
- Self-grade inflation / rubber-stamp → `two-claude-review`
- Something else / meta-process → `post-mortem` itself

If none fit: flag as a candidate for a NEW skill. Write a skeleton SKILL.md draft to `~/.claude/skills/session-lessons/proposed/<name>/SKILL.md` and tell the user.

### Phase 3 · Derive severity + scope

**Severity:**
- **P0** — blocks end-to-end correctness, recurs weekly, user-visible impact
- **P1** — causes extra work or subtle quality regression, recurs monthly
- **P2** — minor waste, recurs occasionally
- **P3** — style / consistency

**Scope:**
- **generic** — applies to any Claude Code project
- **<your-project>** — specific to a specific codebase
- **`<project-slug>`** — specific to some other project

Scope is the dual-track flag: generic lessons flow to the open-source sibling repo; <your-project> lessons stay in the private overlay.

### Phase 4 · Derive tags

Free-form, grep-friendly. Common tags:
- **Tech layers**: `bedrock`, `prisma`, `pgvector`, `sse`, `ink-tui`, `nextjs`
- **Project-specific domains**: (your stack tags — e.g., `payments`, `auth`, `db`)
- **Operational**: `worktree`, `github-api`, `ci`, `cookies`
- **Quality**: `self-grade`, `two-claude`, `observability`, `silent-failure`
- **Failure classes**: `inflation`, `staleness`, `dispatch-miss`, `ghost-deletion`, `crlf`, `phantom-reference`

### Phase 5 · Build the JSONL entry

```bash
~/.claude/skills/session-lessons/bin/capture-lesson \
  --skill <owning-skill> \
  --pattern "<one-sentence summary>" \
  --evidence "<file:line or PR# or command output>" \
  --fix "<recommended action>" \
  --severity <P0|P1|P2|P3> \
  --scope <generic|<your-project>|project-slug> \
  --tags "<comma-separated>" \
  --user-quote "<verbatim if applicable, else omit>"
```

The `bin/capture-lesson` helper:
1. Computes `id = sha256(skill + pattern_normalized)`
2. Resolves `session` from `$OPENCLAW_SESSION` / stored identity / fallback
3. Appends to `learnings.jsonl`
4. If an entry with the same `id` already exists, increments its `evidence_count` instead of duplicating

### Phase 6 · Check hoist threshold

After capture:

```bash
# Count unique sessions reporting this pattern
COUNT=$(grep -c "\"id\":\"$ID\"" "$_LEARNINGS_FILE")
UNIQUE_SESSIONS=$(grep "\"id\":\"$ID\"" "$_LEARNINGS_FILE" | python3 -c "
import sys, json
seen = set()
for line in sys.stdin:
    try: seen.add(json.loads(line)['session'])
    except: pass
print(len(seen))
")
```

If `UNIQUE_SESSIONS >= 3` OR (`severity == P0` AND `UNIQUE_SESSIONS >= 2`):

Propose hoisting to the owning skill's `Invariants` section. Write a draft at `~/.claude/skills/session-lessons/proposed/hoists-<date>.md` with:

```markdown
## Proposed hoist: <pattern>

**Skill:** <owning-skill>
**Evidence count:** <N> sessions
**First captured:** <earliest ts>
**Last captured:** <latest ts>

**Proposed invariant text:**
> <draft — 1-2 paragraphs suitable for INVARIANTS.md>

**Contributing sessions:**
- <session-1> at <ts>: "<pattern as they described it>"
- <session-2> at <ts>: "<pattern>"
- <session-3> at <ts>: "<pattern>"

Approve by editing INVARIANTS.md + owning SKILL.md.
```

Do NOT auto-apply — hoisting requires Lee's review + approval.

### Phase 7 · Update the memory feedback layer (optional)

If the pattern is worth surfacing in CLAUDE.md's `memory/feedback_*.md` layer (high-severity, recurrent, specific):

Write a companion `memory/feedback_<short-name>.md` file with prose for human readers. The JSONL entry + the memory file are two views of the same lesson; the JSONL is queryable, the memory file is narrative.

Ask the user: "Also write this as a `memory/feedback_*.md`? [Y/n]"

## Seed lessons (self-referential)

1. **User correction treated as blocker, not lesson** · P1 · generic
   - Evidence: sessions that "acknowledge and move on" without writing the pattern down → next session repeats
   - Fix: every user correction triggers `/post-mortem` in the same turn

2. **Lesson captured without severity classification** · P2 · generic
   - Evidence: ungraded lessons accumulate; aggregator can't prioritize hoists
   - Fix: require severity + scope fields on every entry

3. **Generic lesson mis-tagged as <your-project>** · P2 · generic
   - Evidence: lesson content mentions specific VINs / internal IDs → scope defaults to <your-project>
   - Fix: strip proper nouns first; if the shape is domain-agnostic, tag scope:generic

4. **Hoist threshold auto-applied without review** · P0 · generic
   - Evidence: silent promotion to INVARIANTS.md created rules the user hadn't seen
   - Fix: `proposed/hoists-<date>.md` draft only; Lee approves explicitly

5. **Same pattern captured as duplicate rows instead of evidence_count++** · P2 · generic
   - Evidence: 3 sessions each append a new JSONL row → aggregator sees 3 separate "patterns"
   - Fix: `bin/capture-lesson` computes id + increments existing row if match

## Integration

- **All 6 other skills call into this one** when they detect a new pattern
- **`/learn` (gstack's existing)** can read the JSONL pool via `gstack-learnings-search`
- **Aggregator** (`bin/aggregator`, weekly) dedupes + proposes hoists
- **`memory/feedback_*.md`** is the human-narrative sibling; JSONL is the queryable layer

## Invariants consulted

- **Invariant 9 · User corrections are lessons, not interruptions**
- **Invariant 1 · Run the check before claiming** (applies to self-detected errors)

## Completeness Principle

10/10: capture every mistake, classify, derive severity/scope/tags, check hoist threshold, propose when eligible.
7/10: capture with minimal classification; defer hoist-threshold check to weekly aggregator.
3/10: acknowledge the mistake verbally but don't write anything down — next session repeats.

**Default: 10/10.** The whole point of this skill is making capture frictionless. If it's costly, the capture won't happen.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version. 7-phase workflow. 5 self-referential seed lessons.
