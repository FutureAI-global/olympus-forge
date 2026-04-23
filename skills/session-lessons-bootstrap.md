---
name: session-lessons-bootstrap
namespace: session-lessons
version: 0.1.0
description: |
  Onboarding skill every new Claude session runs to join the shared-learnings pool.
  Audits the current session's history for failure patterns, buckets findings into
  the 6 skill taxonomies, proposes new-skill candidates for unique patterns, and
  contributes lessons to learnings.jsonl with session identity tagged. The entry
  point for any session joining the session-lessons ecosystem.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Write
  - AskUserQuestion
---

# session-lessons-bootstrap · onboard a new session into the shared-learnings pool

## Why this exists

Lee distributes the session-lessons pack to every Claude session he runs. a specific session, B, C... Z. Each session has a unique perspective (different PRs authored, different files edited, different user corrections). This skill is the stock-taking ritual: what has THIS session learned that the pool doesn't yet know?

## Preamble

```bash
# Top-3 current-pool entries (what's already captured)
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  echo "=== Current learnings pool (top 3) ==="
  ~/.claude/skills/gstack/bin/gstack-learnings-search --limit 3 2>/dev/null || echo "(empty)"
fi

# Session identity
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
echo "Session: $_SESSION_NAME"

# Read the 6 skill SKILL.md files + INVARIANTS
echo "=== Loaded skills ==="
ls ~/.claude/skills/session-lessons/ | grep -v -E '(README|LESSONS|INVARIANTS|DISTRIBUTE|bin|lessons|proposed)'
```

## Trigger conditions

- First action in any new session that Lee has pasted `DISTRIBUTE.md` into
- Manual invocation `/session-lessons-bootstrap`
- After any context-compaction event when session needs to re-orient

Voice triggers: "bootstrap session lessons", "onboard to lessons pool", "contribute my lessons".

## Workflow

### Phase 1 · Establish identity

If no session identity is set:

```
AskUserQuestion:
  question: "What's your session's role/name? (e.g., session-e, orch, lee-main)"
  options:
    - "session-<letter>" — maps to Lee's named sessions
    - "<custom>" — Lee writes in
    - "machine-generated" — use $(hostname)-$PPID
  default: "machine-generated"
```

Store the chosen name to `~/.gstack/session-identity` so subsequent sessions on this terminal/shell reuse it.

### Phase 2 · Read the 6 skills + INVARIANTS

Before scanning the session, load the existing taxonomy:

```bash
for skill in verify-before-claim fresh-state api-push observability-audit two-claude-review post-mortem; do
  echo "=== $skill ==="
  cat ~/.claude/skills/session-lessons/$skill/SKILL.md
done
cat ~/.claude/skills/session-lessons/INVARIANTS.md
```

This primes the session on which patterns are already covered + the INVARIANTS that have been hoisted.

### Phase 3 · Survey the current session

Walk the conversation history (or the session's work output) looking for failure patterns:

**Signals to look for:**

- **User corrections** — any message from the user containing "no", "wrong", "don't", "stop", "you're", "actually", "that's not" — extract the surrounding context
- **Self-reversals** — any time the session said "I was wrong" or "let me correct that"
- **Silent catches you wrote** — `catch (err) {}`, `{ ok: false }` returns, `null` fallbacks in any code you authored
- **Unverified claims you made** — "tsc clean" / "tests pass" without tool output in the same turn
- **Stale-state incidents** — moments you edited from a worktree that was behind remote
- **Dispatch orphans** — tool_use turns in your work history without matching tool_result

For each signal, capture:
1. Rough pattern summary
2. Evidence (file:line, PR#, user quote)
3. Recommended fix for future sessions

### Phase 4 · Classify into skill taxonomy

For each detected failure pattern:

- **Unverified factual claim** → `verify-before-claim`
- **Stale-local-state / worktree-drift** → `fresh-state`
- **PR / push / diff-shape** → `api-push`
- **Metric without caller, silent catch** → `observability-audit`
- **Self-grade inflation / rubber-stamp** → `two-claude-review`
- **Something novel** → propose a new skill

### Phase 5 · Dedup against the existing pool

For each classified pattern:

```bash
PATTERN_ID=$(~/.claude/skills/session-lessons/bin/lesson-id <skill> "<pattern>")
if grep -q "\"id\":\"$PATTERN_ID\"" "$_LEARNINGS_FILE"; then
  echo "ALREADY CAPTURED — will increment evidence_count"
else
  echo "NEW — will append"
fi
```

### Phase 6 · Propose contributions to the user

Present a structured proposal:

```
Session <name> bootstrap findings:

Existing patterns (will strengthen via evidence_count):
  [existing-1] "claimed tsc clean without running tsc"
  [existing-2] "worktree 2+ days behind staging when editing"

New patterns (not yet in pool):
  [new-1] "<description>" → skill: <owner> — capture?
  [new-2] "<description>" → skill: <owner> — capture?

Novel patterns (no existing skill fits):
  [novel-1] "<description>" → propose NEW skill?

Approve each? [Y] write all, [E] edit list, [N] skip
```

Use AskUserQuestion for any non-obvious classification call.

### Phase 7 · Write approved entries

For each approved pattern, invoke `bin/capture-lesson`:

```bash
for pattern in approved_patterns:
  ~/.claude/skills/session-lessons/bin/capture-lesson \
    --skill <owner> \
    --pattern "<summary>" \
    --evidence "<proof>" \
    --fix "<recommendation>" \
    --severity <P0|P1|P2|P3> \
    --scope <generic|<your-project>|project>  \
    --tags "<comma-list>" \
    --user-quote "<if applicable>"
```

For novel patterns proposing new skills, write a skeleton SKILL.md draft to `~/.claude/skills/session-lessons/proposed/<name>/SKILL.md` with:
- Frontmatter (name, namespace, version, description)
- Trigger conditions (3-5 bullets)
- Initial workflow sketch
- 2-3 seed lessons from the current session's evidence

### Phase 8 · Report

Produce a summary for the user + optionally for the coord PR where the session's work landed:

```
Session <name> · bootstrap summary

- Read: 6 skills + INVARIANTS
- Surveyed: ~<N> turns of conversation history + <M> PRs authored
- Captured: <K> new lessons, <L> evidence_count increments on existing patterns
- Proposed: <J> new-skill drafts in `proposed/` for Lee's review

Top patterns contributed:
  1. <pattern> → <skill> (new)
  2. <pattern> → <skill> (new)
  3. <pattern> → <skill> (increment)

Next actions for Lee:
- Review `~/.claude/skills/session-lessons/proposed/` for new-skill drafts
- Next session run `/session-lessons-bootstrap` as first action
```

## Constraints

- **Never duplicate captures.** `bin/capture-lesson` handles dedup; the bootstrap just shouldn't try to append the same pattern twice.
- **Never overwrite existing skills.** Append to lessons, don't edit other skills' SKILL.md files.
- **Respect the hoist threshold.** Don't promote to INVARIANTS.md even if this session alone has "3 examples" — the threshold is 3 unique SESSIONS, not 3 examples from one session.
- **Propose new skills generously but honestly.** If the pattern seems novel to you but might fit an existing skill's taxonomy, default to "append to existing" rather than proposing a new skill.
- **Scope tagging matters.** Strip proper nouns before deciding `generic` vs domain-specific.

## Seed lessons

1. **Bootstrap contributed 0 lessons because nothing new to say** · P3 · generic
   - Evidence: a session whose work closely mirrored a prior session might legitimately have nothing novel
   - Fix: ship the report anyway; 0 is a valid outcome + a signal the pool is saturating

2. **Bootstrap contributed 50+ lessons because session was first** · P2 · generic
   - Evidence: first session into the pool dumps everything; subsequent sessions contribute less
   - Fix: that's expected; the aggregator surfaces high-evidence patterns regardless of when they landed

3. **Bootstrap misclassified a fresh-state issue as verify-before-claim** · P2 · generic
   - Evidence: overlap between skills can lead to wrong-bucket capture; aggregator catches but only at weekly cadence
   - Fix: when in doubt, ask the user which skill owns it via AskUserQuestion

4. **Identity not set → lessons tagged with unreadable $PPID-timestamp** · P2 · generic
   - Evidence: aggregator can't identify same-session follow-ups vs different sessions
   - Fix: always resolve `_SESSION_NAME` via `~/.gstack/session-identity`; set it if missing

5. **Ran bootstrap mid-session instead of at start → missed early-session patterns** · P2 · generic
   - Evidence: corrections from turn 1-5 lost to context before bootstrap ran at turn 40
   - Fix: bootstrap is the FIRST action after Lee pastes DISTRIBUTE.md, not a middle-of-session add-on

## Integration

- **`/post-mortem`** — bootstrap invokes post-mortem for each detected pattern
- **`/learn`** — gstack's existing search skill reads the JSONL this skill writes to
- **INVARIANTS.md** — bootstrap reads it to understand what's already hoisted
- **DISTRIBUTE.md** — Lee's paste-ready message that points sessions to this skill

## Completeness Principle

10/10: survey every signal, capture every novel pattern, dedupe precisely, report clearly.
7/10: focus on the top 5 user corrections + top 3 self-reversals; skip minor signals.
3/10: quick-and-dirty capture of obvious failures only; miss the subtle ones.

**Default: 10/10** for first-time bootstrap. **7/10** for mid-session re-invocations.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version. 8-phase workflow. 5 seed lessons. Designed to be the first skill every Lee-distributed session invokes.
