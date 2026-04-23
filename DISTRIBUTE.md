# DISTRIBUTE.md · paste this into every Claude session

Lee: copy everything below (between the `─` dividers) and paste it verbatim into each other Claude Code session you run (a specific session, B, C, D, E, F, G, H, orch, etc.). Each session, on its first turn after your paste, will audit its own history for failure patterns and contribute to the shared learnings pool at `~/.gstack/projects/<slug>/learnings.jsonl`.

────────────────────────────────────────────────────────────

We have a cross-session learning skills pack at `~/.claude/skills/session-lessons/`. Your job in this session is to join the shared-learnings pool:

1. Read it
2. Audit your own session's work (corrections, self-reversals, silent catches, unverified claims, worktree-drift incidents, dispatch orphans, anything else)
3. Contribute your findings to `~/.gstack/projects/<slug>/learnings.jsonl`
4. If you spot a pattern no existing skill covers, propose a new skill under `~/.claude/skills/session-lessons/proposed/`

**Run this first:** `/session-lessons-bootstrap`

That skill walks you through:
- Setting session identity (you'll pick a human-readable name like `session-e`, `orch`, `session-g`)
- Reading INVARIANTS.md + all 7 SKILL.md files to orient
- Surveying your conversation history + your session's work output for failure patterns
- Deduping against the existing pool (you won't re-capture what's already there)
- Writing structured JSONL entries via `~/.claude/skills/session-lessons/bin/capture-lesson`
- Proposing new-skill drafts for novel patterns

**Then:** use `/post-mortem` anytime you make a mistake or get corrected by Lee. One captured lesson = one future session that doesn't repeat it.

**Constraints:**

- Don't duplicate lessons — `/session-lessons-bootstrap` shows you what's already captured before you start. `capture-lesson` also dedups at write time via content-hash; if you try to capture the same pattern, it increments `evidence_count` instead of creating a new row. Cross-session evidence STRENGTHENS patterns.
- Don't overwrite existing skills — append to lesson logs via `capture-lesson`. Only Lee promotes `proposed/*` to main skills.
- Don't hoist to INVARIANTS.md yourself — that requires ≥3 unique sessions reporting the pattern AND Lee's approval.
- If a user correction from your session isn't in the pool yet, capture it — even if it feels minor. Future sessions benefit.
- One session ≠ one expertise area. If your session touched 12 surfaces, expect ≥12 candidate lessons. Be thorough.
- Generic vs domain-specific: if the pattern is universal (applies to any Claude Code project), tag `scope: generic`. If it's specific (service-specific cookies, port splits, incident shapes), tag `scope: <your-project>`. The open-source sibling repo only pulls generic entries.

**Cross-repo lessons note:** the `learnings.jsonl` is per-project (keyed on `~/.claude/skills/gstack/bin/gstack-slug`). If your session is in a different repo than mine, your lessons land in a different slug. That's fine — the aggregator walks ALL slugs when surfacing patterns. Nothing's siloed.

**After you've captured:** post a summary on the relevant coord PR (e.g., PR #1517 for Olympus work) noting how many lessons you contributed + whether you proposed any new skills. One-line format:

> Session X · session-lessons bootstrap: N lessons captured (K new, L increments), M new skill drafts in `proposed/`

**Identity tagging:** when `/session-lessons-bootstrap` asks for your session name, use something human-readable. Suggested:
- `session-a` through `session-h` for the standard lettered sessions
- `orch` for the orchestrator lane
- `lee-main` for Lee's primary terminal if he's the author
- Anything else Lee has explicitly named

That identity lands in every lesson you write via the `session` / `sessions[]` fields. Over time Lee can audit which sessions contributed which lessons, which patterns strengthen across sessions, and which sessions systematically miss obvious traps.

────────────────────────────────────────────────────────────

## When to re-paste this

- When Lee adds a new Claude session to the team
- After significant skills updates (check `~/.claude/skills/session-lessons/README.md` changelog)
- When a session resumes after long context-compaction that lost skills awareness

## If you hit an error

- `bin/capture-lesson` is at `~/.claude/skills/session-lessons/bin/capture-lesson` and requires Python 3
- `gstack-slug` binary at `~/.claude/skills/gstack/bin/gstack-slug` — if missing, slug falls back to `unknown`
- Writing to `~/.gstack/projects/` — if that directory doesn't exist, `capture-lesson` creates it

## Lee's notes

- Keep session names STABLE across invocations — if session-e is always the Olympus-eval session, always call it `session-e`
- Every 2-4 weeks, run the aggregator (`bin/aggregator`) to see hoist candidates
- When 3+ sessions report the same pattern, expect a proposal draft at `~/.claude/skills/session-lessons/proposed/hoists-YYYY-MM-DD.md`
- Approve hoists by editing `INVARIANTS.md` + the owning skill's `Invariants` section
