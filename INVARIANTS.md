# INVARIANTS · cross-skill rules every session-lessons skill references

This file captures the rules that cut across ALL 7 skills. Every skill's preamble sources this file. When a pattern passes the `≥3 sessions` hoist threshold (per `LESSONS-SCHEMA.md`), it lands here as a new invariant.

Keep this file **short + dense.** If it balloons past 200 lines, split it.

---

## Invariant 1 · Run the check before claiming

**Never say "tsc clean", "tests pass", "fix works", "metric emits", "PR opened", "file exists", "logged in"** without either:

(a) The tool-invocation output in the SAME turn as the claim, OR
(b) An explicit "**unverified**" label.

**Ownership:** `/verify-before-claim`

**Why:** the Two-Claude Review Protocol exists specifically because a single session made 3 consecutive false "tsc clean" claims across 3 cycles. Independent review catches this eventually, but the primary fix is never making the claim in the first place.

**Evidence floor:** if this invariant is violated, the session MUST capture a lesson and demote the claim in a correction message.

---

## Invariant 2 · Fetch fresh HEAD before editing shared files

**Before editing any file that could be modified by another session** (anything in `<backend>/services/<harness>/`, `backend/src/services/ford-pts-*`, `<your-schema>.prisma`, files flagged "shared" in CLAUDE.md, or any file in a shared worktree), **fetch the file's current state from remote** via:

```bash
gh api "repos/<owner>/<repo>/contents/<path>?ref=<remote-branch>" --jq '.content' | base64 -d
```

If the local copy differs from remote, pick ONE of:
- Use the remote version as the edit base (preserve remote changes)
- Explicit override with rationale logged

**Ownership:** `/fresh-state`

**Why:** multiple sessions on one machine share worktrees. One session's unstaged edit becomes another session's invisible base state, which then appears to vanish when pushed via the GitHub API. Burned on `#1500` / `#1502` silent regressions; burned again when 3 CLI processes hit a 2-day-stale backend.

---

## Invariant 3 · Never `git push` on repos >1 GB

On any large repo (current trigger: <your-repo> at 5.6GB), **`git push` hangs for 10+ minutes** packing objects. Use the GitHub API recipe instead:

```
gh api git/blobs → git/trees → git/commits → git/refs
```

See `/api-push` for the exact pattern. Uploads only changed files, completes in seconds.

**Exception:** tiny repos (<100MB) where `git push` is still fast.

**Ownership:** `/api-push`

---

## Invariant 4 · Preserve line endings on API push

Source files with CRLF line endings (check via `file <path>`) must be written back with CRLF when patching via the GitHub API. Python example:

```python
content = content.replace('\r\n', '\n').replace('\n', '\r\n')
```

**Violation shape:** LF-content pushed against CRLF source → GitHub diff shows every line changed → PR review becomes unusable.

**Ownership:** `/api-push`

---

## Invariant 5 · Never `gh pr edit --base` on PRs with squash-merged parents

Retargeting a PR's base branch via `gh pr edit --base <new-base>` produces **ghost-deletion diffs** when the original parent SHA was squash-merged into the new base. Git compares trees including unrelated files → 20k-line phantom deletions.

**Fix:** delete + recreate the branch with a fresh commit parented on the new base HEAD.

```bash
# WRONG — produces ghost-deletion diff
gh pr edit 1234 --base staging

# RIGHT — delete + recreate
gh api -X DELETE "repos/<owner>/<repo>/git/refs/heads/<branch>"
# Then push a fresh commit parented on staging via blob → tree → commit → ref
```

**Ownership:** `/api-push`

**Evidence:** PRs #1518 / #1519 showed this exact 20k-deletion shape on a recent incident after the fork → staging squash-merge. Cost: 45 minutes of confusion before root-cause.

---

## Invariant 6 · Every declared metric has a caller

**Before declaring a PR "observability improved"**: for every `Counter` / `Histogram` / `Gauge` in the diff, verify a non-test caller exists in the same PR or an existing code path.

```bash
# Verify pattern
grep -rn '<metric-name>' backend/src/ --include='*.ts' | grep -v __tests__
```

**Violation shape:** `a validator-finding counter` exported at `<metrics-file>` for ≥4 weeks with zero callers → soft-findings invisible to ops → same class of error keeps shipping because no metric signals it.

**Ownership:** `/observability-audit`

---

## Invariant 7 · Every silent-catch has a signal

Any `catch (err) {}` that deliberately returns a silent fallback (empty array, `{ ok: false }`, `null`) MUST either:

(a) Emit a Prometheus counter (`recordXxxFailure(...)`)
(b) Write a structured audit log line
(c) Include an inline comment explaining why silence is correct for this specific catch

Silent-catch without ANY of the three = implicit observability debt. Log it as a lesson so the pattern stops shipping.

**Ownership:** `/observability-audit`

---

## Invariant 8 · Two-Claude Review for ship-candidate changes

Every PR that ships behind a feature flag OR modifies `src/` / `backend/` / `services/` OR adds ≥50 LOC goes through two Claude sessions: implementer + independent reviewer. The reviewer runs with **cold context** (no transcript from the implementer) and **RE-RUNS every verifiable claim** (`tsc`, `jest`, bundle greps) before signing off.

**Ownership:** `/two-claude-review`

**Skip only for:** typo fixes, single-variable renames ≤3 files with no behavior change, test-only import swaps.

---

## Invariant 9 · User corrections are lessons, not interruptions

When a user says "no that's wrong", "don't do X", "you inflated Y", or equivalent: that's not a blocker to resolve and move on — that's a lesson to capture.

Within the same turn as the correction:

1. Acknowledge the correction + the specific mistake
2. Invoke `/post-mortem` to capture the pattern into `learnings.jsonl`
3. Apply the correction + continue

Without capture, the next session makes the same mistake. Compounding failure.

**Ownership:** `/post-mortem`

---

## Invariant 10 · Completeness trumps brevity (Boil the Lake)

When the cost of the complete implementation vs the shortcut is ≤10x, always choose complete. AI makes completeness near-free. A lake (100% coverage) is boilable in one session with Claude Code; an ocean (full rewrite) is not.

**Ownership:** cross-cutting; reinforced by `/verify-before-claim` (no half-checks) and `/observability-audit` (no half-coverage on metrics).

**Guideline:** if an option has Completeness ≤5/10, flag it. If both options are 8+, pick higher.

---

## Invariant 11 · Never touch shared / orch-gated surfaces without explicit green-light

Files flagged in CLAUDE.md as `constitution/v1/**`, `conversation-runner.service.ts`, `conversation-validator.service.ts`, or other orch-gated surfaces: **never edit without an explicit @orch green-light posted in a coord PR**.

**Ownership:** cross-cutting; domain-specific (scope: `<your-project>`)

**Enforced by:** `/fresh-state` pre-flight (detects the path) + a coord-PR-comment check.

---

## How to add a new invariant

1. A pattern must pass the hoist threshold (see `LESSONS-SCHEMA.md`): ≥3 unique sessions contributing evidence OR ≥2 for P0 severity
2. The weekly aggregator (`bin/aggregator`) proposes a draft at `~/.claude/skills/session-lessons/proposed/hoists-YYYY-MM-DD.md`
3. Lee reviews + approves (or rejects with rationale — rejection itself becomes a lesson)
4. Approved invariants get appended here + cross-linked from the owning skill's `Invariants` section

**No invariant is ever deleted.** If an invariant becomes obsolete (tech stack change, tool upgrade), mark it `**SUPERSEDED by <new-invariant>**` inline but keep the text.

---

## Changelog

- **a recent incident · v1** — 11 invariants. a specific session authored. Derived from this session's lessons + 21 pre-existing `memory/feedback_*.md` seeds.
