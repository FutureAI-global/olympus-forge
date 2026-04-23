# LESSONS-SCHEMA · canonical JSONL format for the shared lessons pool

## Location

Lessons are written to **`~/.gstack/projects/${SLUG}/learnings.jsonl`** where `${SLUG}` is derived by `~/.claude/skills/gstack/bin/gstack-slug` from the current repo's top-level dir. This path is where `gstack-learnings-search` already reads from — nothing new to stand up.

One lesson per line. Append-only. No inline mutation. Deduplication runs in the aggregator (weekly), not at write time.

## Required fields

```jsonc
{
  // ─── Identity ────────────────────────────────────────────────
  "id":          "string",  // SHA-256(skill + pattern) — dedup key
  "ts":          "string",  // ISO-8601 UTC — "a recent incident"
  "session":     "string",  // session identifier — see "Session identity" below
  "skill":       "string",  // which skill owns this lesson (one of the 7, or "proposed/<name>")

  // ─── The lesson itself ───────────────────────────────────────
  "pattern":     "string",  // 1-sentence summary of the failure mode
  "evidence":    "string",  // what proves it happened — file:line, PR #, command output, error msg
  "fix":         "string",  // the action the session took (or recommended) to resolve

  // ─── Classification ──────────────────────────────────────────
  "severity":    "P0" | "P1" | "P2" | "P3",  // impact if repeated
  "scope":       "generic" | "<your-project>" | "<project-slug>",  // dual-track flag for open-source filtering
  "tags":        ["string"],  // free-form tags: "bedrock", "pts", "sse", "validator", "prisma", etc.

  // ─── Provenance ──────────────────────────────────────────────
  "user_quote":  "string | null",  // verbatim correction from user (if any)
  "auto_captured": boolean,  // true if caught by hook, false if manual /post-mortem
  "related_ids": ["string"],  // other lesson ids this one references or supersedes
  "evidence_count": number  // dedup counter — increments when duplicate id is captured
}
```

## Example entries

### verify-before-claim (generic)
```jsonl
{"id":"sha256-abc123","ts":"a recent incident","session":"session-i","skill":"verify-before-claim","pattern":"claimed 'tsc clean' without running tsc","evidence":"PR #1534 shipped; 2 runtime bugs (path wrong, loadCorpus flat) surfaced only when e2e tests ran","fix":"always cite the exact tsc command + its output before claiming clean","severity":"P1","scope":"generic","tags":["typescript","self-grade","two-claude"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
```

### fresh-state (<your-project>-scoped)
```jsonl
{"id":"sha256-def456","ts":"a recent incident","session":"session-i","skill":"fresh-state","pattern":"edited file based on stale local worktree; remote had moved ≥2 commits since","evidence":"3 stuck CLI processes on this machine; backend at commit 6043856e (a recent incident) vs staging at 87839a96 (a recent incident)","fix":"always run gh api repos/<repo>/git/refs/heads/staging --jq '.object.sha' and compare to local HEAD for the file being edited","severity":"P0","scope":"<your-project>","tags":["worktree","staging-drift","multi-session"],"user_quote":"you see our sessions making the same mistakes over and over","auto_captured":false,"related_ids":[],"evidence_count":1}
```

### api-push (generic)
```jsonl
{"id":"sha256-789abc","ts":"a recent incident","session":"session-i","skill":"api-push","pattern":"gh pr edit --base <branch> produces ghost-deletion diffs when the original base was squash-merged","evidence":"PRs #1518/#1519 showed 20k-deletion phantom diffs after retargeting to staging post fork-squash","fix":"delete + recreate the branch with a fresh commit parented on current base HEAD; never use gh pr edit --base","severity":"P0","scope":"generic","tags":["github-api","ghost-deletion","squash-merge"],"user_quote":null,"auto_captured":false,"related_ids":[],"evidence_count":1}
```

## Session identity (the `session` field)

Priority order for determining session ID:

1. **`$OPENCLAW_SESSION`** env var, if set (this is gstack's existing convention for spawned sessions)
2. **Human-readable name** passed as `--session-name=<name>` to `/session-lessons-bootstrap` on first invocation (e.g., `session-a`, `orch`, `lee-main`). Stored in `~/.gstack/session-identity` for the machine.
3. **Fallback**: `$(hostname)-$PPID-$(date +%s)` — ugly but unique

If the same machine has identity recorded, subsequent sessions reuse that name unless overridden. Each terminal / Claude Code instance can be tagged independently.

## The `id` field (deduplication)

`id = sha256(skill + "\n" + pattern_normalized)` where `pattern_normalized` lowercases + strips punctuation + collapses whitespace. Identical patterns across sessions produce identical IDs → the aggregator merges by incrementing `evidence_count` rather than duplicating rows.

Python snippet (used by `bin/lesson-id`):

```python
import hashlib, re, sys, json
def lesson_id(skill: str, pattern: str) -> str:
    normalized = re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", pattern.lower())).strip()
    return "sha256-" + hashlib.sha256(f"{skill}\n{normalized}".encode()).hexdigest()[:24]
```

## Severity ladder

| Level | Criteria | Example |
|---|---|---|
| **P0** | Blocks end-to-end correctness; recurs at least weekly; direct user-visible impact | Tool_use without tool_result → silent CLI hang for multi-hour |
| **P1** | Causes extra work or subtle quality regression; recurs at least monthly | Claim "tsc clean" without running tsc; tests authored but not run |
| **P2** | Minor waste (time, tokens, cognitive overhead); recurs occasionally | CRLF vs LF line-ending mismatch on first push |
| **P3** | Nice-to-have; opinionated style or consistency | Emoji usage; comment style |

Severity is the author's judgment at capture time. Aggregator can re-rate based on evidence_count later.

## Scope (`generic` vs `<your-project>` vs project-slug)

- **`generic`** — applies to any Claude Code project. Goes into the open-source `claude-session-lessons` repo when Phase B ships.
- **`<your-project>`** — specific to a specific codebase (backend port split, a third-party authenticated service cookies, a production-fabrication incident incident shape, a grounding-enforcement fixx regex evolution, worktree collisions specific to `<your-main-clone>`). Stays in this private overlay.
- **`<project-slug>`** — specific to another project Lee works on. Stays local to that project's slug namespace.

The dual-track aggregator reads this field when deciding what to promote to the public repo.

## Tags (free-form)

Tags are grep-friendly dimensions. Common ones observed in the seed data:
- **Tech layers**: `bedrock`, `prisma`, `pgvector`, `sse`, `ink-tui`, `nextjs`, `fastify`
- **Project-specific domains**: (your stack tags — e.g., `payments`, `auth`, `db`)
- **Operational surfaces**: `worktree`, `github-api`, `ci`, `cron`, `cookies`, `cache`
- **Quality dimensions**: `self-grade`, `two-claude`, `observability`, `silent-failure`, `lint`, `test-coverage`
- **Failure classes**: `inflation`, `staleness`, `dispatch-miss`, `ghost-deletion`, `crlf`, `phantom-reference`

Tags are UNSTRUCTURED — aggregator canonicalizes them weekly by folding common misspellings / synonyms.

## Hoisting to `INVARIANTS.md`

A pattern passes the hoist threshold when:

1. `evidence_count ≥ 3` (appeared in at least 3 distinct session logs), OR
2. `severity = P0` AND `evidence_count ≥ 2`

When threshold is passed, the weekly aggregator (`bin/aggregator`) proposes hoisting by writing a draft PR-style markdown at `~/.claude/skills/session-lessons/proposed/hoists-YYYY-MM-DD.md`. Lee reviews + approves; approved hoists land in the owning skill's `Invariants` section.

No auto-hoisting without approval. The aggregator proposes, Lee disposes.

## Read API

Sessions read via `gstack-learnings-search`:

```bash
# Top-3 relevant lessons for current context
~/.claude/skills/gstack/bin/gstack-learnings-search --limit 3

# Filter by skill
~/.claude/skills/gstack/bin/gstack-learnings-search --tag verify-before-claim --limit 5

# Filter by scope (for public-repo contributors, filter to generic-only)
~/.claude/skills/gstack/bin/gstack-learnings-search --scope generic

# High-severity recent
~/.claude/skills/gstack/bin/gstack-learnings-search --severity P0 --since 7d
```

The binary already exists; we're feeding it, not rebuilding it.

## Write API

Sessions write via `/post-mortem` skill (primary) or the helper `bin/capture-lesson`:

```bash
~/.claude/skills/session-lessons/bin/capture-lesson \
  --skill verify-before-claim \
  --pattern "claimed tests pass without running jest" \
  --evidence "PR #1534 line 107-141 failed 6 smoke tests on first real run" \
  --fix "run jest before claiming; cite exit code + test count" \
  --severity P1 \
  --scope generic \
  --tags "self-grade,two-claude,jest"
```

The helper:
1. Computes `id` via `bin/lesson-id`
2. Resolves `session` via `$OPENCLAW_SESSION` / stored identity / fallback
3. Appends to `~/.gstack/projects/${SLUG}/learnings.jsonl`
4. If the same `id` exists, increments `evidence_count` in the existing row instead of appending a duplicate

## Validation

Entries must pass basic JSON shape + required-field presence. Invalid entries are moved to `~/.gstack/projects/${SLUG}/learnings-quarantine.jsonl` with a rationale and don't block new writes. Aggregator reports quarantined entries weekly.

## Privacy + secrets

Lessons NEVER contain:
- Cookies, tokens, API keys, passwords
- VINs or customer identifiers (even fabricated ones get scrubbed in dual-track promotion to public)
- Private URLs (use placeholders like `<internal-api>`)
- Specific customer-shop names

The open-source aggregator runs a secret-scrubbing pass before promoting anything from `scope: generic` to the public repo. Runs on lesson text + evidence field. If a regex match hits, the lesson is quarantined pending manual review.

## Schema versioning

This is schema **v1**. Future versions must be additive — existing fields never remove or rename. The `schema_version: 1` field may be added implicitly by the aggregator when upgrading old entries.

v2 considerations (not shipped):
- `fix_verified: boolean` — whether the recommended fix was subsequently observed to work
- `superseded_by: string | null` — forward-link from deprecated lessons to their replacements
- `freshness_score: number` — time-decay for lessons that may become stale (e.g., tech stack change)

## Changelog

- **v1 (a recent incident)** — Initial schema. a specific session authored. 14 seed fields, dual-track scope, evidence-count dedup.
