---
name: worktree-mtime-not-branch-date
namespace: session-lessons
version: 0.1.0
description: |
  Anti-regression check before pulling source content. When a sibling worktree
  exists alongside a primary checkout, its branch tip's commit date is NOT
  sufficient evidence that the files inside are stale. Files can be edited
  any time via direct edit OR `cp` from another worktree (the HMR-localhost
  preview pattern), making the files fresher than the branch they sit on.
  Shipping `?ref=<branch>` blob content over those uncommitted edits causes
  production regressions. Use this skill BEFORE shipping work that depends
  on whether worktree content is current.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a marketing-site migration regression where a session classified a worktree as "5+ days stale" based on branch tip date and shipped pre-edit content over post-edit content; orchestrator caught the regression via mtime audit
---

# worktree-mtime-not-branch-date · check file mtimes, not branch commit date

## Why this exists

A sibling worktree at `~/<repo>-<feature>/` lives on a feature branch with its own commit history. The branch tip may be days or weeks old. The files INSIDE the worktree can still be edited any time:

- Directly via Edit tool (no `git add`, mtime updates, branch unchanged)
- `cp`'d in from another worktree for HMR-localhost preview (the `hmr-localhost-via-cp` pattern)
- The user's manual editing during in-session work

A 5-day-old branch tip can sit alongside files with one-hour-ago mtimes. Both states are valid; one doesn't imply the other.

A session looking at the worktree sees "branch 5 days old" and assumes the files are stale. They're not. There may be hours of fresh uncommitted content sitting inside. Shipping `?ref=<branch>` content (which doesn't include those edits) regresses whatever was edited.

This skill blocks the false-stale assumption before it leads to a regression.

## Preamble (run first)

```bash
# Resolve sibling worktree paths if any exist
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag worktree-mtime --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

Fire this skill when about to:

1. Ack an assignment whose source content lives in a sibling worktree
2. Pull file content via `gh api contents/...?ref=<branch>` when a worktree at `~/<repo>-<feature>/` mirrors the same files
3. Classify a worktree as "stale" or "5+ days old uncommitted local mods" based purely on branch commit date
4. Build a tree spec / migration / refactor that depends on the canonical content of files that also exist in a sibling worktree

Voice triggers: "is this worktree stale", "should I pull from staging or the worktree", "what content is current".

## Workflow

### Phase 1 · `ls -la` the actual files

For every file the upcoming work touches, check the file's mtime in the worktree:

```bash
ls -la ~/<repo>-<feature>/path/to/file.ts
# -rw-r--r-- ... Apr 28 17:31 file.ts
```

Compare to "now":

```bash
date -u
# 2026-04-29 03:25:00 UTC
```

If mtime is within recent hours and the file is in a worktree being assessed for staleness, the file is likely UNCOMMITTED FRESH content, NOT stale.

### Phase 2 · Diff against the supposed source-of-truth

Even if mtimes look recent, confirm content differs from `?ref=<branch>`:

```bash
diff <(cat ~/<repo>-<feature>/path/to/file.ts) \
     <(gh api 'repos/<repo>/contents/path/to/file.ts?ref=<branch>' --jq '.content' | base64 -d)
```

- Empty diff: worktree matches branch tip; safe to ship from either source
- Non-empty diff: worktree has uncommitted edits; ship the worktree version (or ask the orchestrator)

### Phase 3 · Decide source-of-truth

Three options when worktree is fresher than branch:

1. **Read the worktree files as truth.** Prefer worktree content over `?ref=<branch>` for the upcoming work.
2. **Ask the orchestrator to confirm.** Post on the coord channel: "Worktree at <path> has files with <hour>:00 mtimes. Branch tip is <date>. Are these recent edits or stale-from-cp-experiment?"
3. **Block on ambiguity.** If ownership is unclear, don't ship until orchestrator confirms.

### Phase 4 · Document the source-of-truth choice in the PR

In the PR body, state explicitly:

```
Source: <worktree-path> (mtimes 17:31, fresher than branch tip dated 2026-04-23)
NOT: ?ref=<branch> blobs (would have shipped staging-tip content; regression risk)
```

This makes the choice auditable and gives reviewers a chance to flag if it was wrong.

## What NOT to do

- ❌ **Classify as "stale" based on branch age alone.** Branch age is necessary but not sufficient evidence.
- ❌ **Ship `?ref=<branch>` content over worktree content** when the worktree has fresher files. The branch ref doesn't include uncommitted work.
- ❌ **`git stash` or `git reset --hard` in the worktree** to "clean it up" before pulling source. That destroys uncommitted work permanently.
- ❌ **Skip the `ls -la` check** because "the branch tip looks ancient." Branch tip date is independent of file mtime.

## Seed lessons

### Lesson 1 · Marketing-site root migration shipped pre-edit content

A session was assigned a sub-90-min marketing-site root migration. The session's ack said "the worktree is 5+ days of uncommitted local mods" based on the branch tip's commit date.

The files inside the worktree had been edited TONIGHT during the orchestrator's 4-7 hour copy-rewrite session, via direct Edit + `cp`-into-running-worktree HMR pattern. Branch tip stayed at the original commit date.

The session built a tree from `?ref=staging` blob SHAs, missing tonight's edits. PR auto-merged within 5 min. Orchestrator caught the regression 12 min later via `ls -la` mtime audit, posted addendum showing tonight's mtimes, session opened follow-up polish overlay PR.

Cost: 1 extra PR + 10 min recovery + production push held until follow-up landed.

### Lesson 2 · `cp`-into-running-worktree leaves uncommitted state

Worktree A had broken deps preventing `npm run dev` from starting. Session copied in-progress files from A into Worktree B which had a working dev server, for HMR-localhost preview. User blessed the preview.

Source of truth at that moment was Worktree B's filesystem (the cp'd files). Worktree B's branch was untouched (no `git add`). A future session looking at B sees "branch 4 days old" and assumes stale; the files are actually 30 minutes old.

### Lesson 3 · Branch tip date is independent of file mtime

`git -C <worktree> log -1 --format=%ci` returns the commit date. `ls -la <worktree>/<file>` returns the filesystem mtime. These are separate. Editing a file with the Edit tool updates mtime but doesn't move the branch tip. Cp'ing a file in updates mtime. Multi-day-old branch with one-hour-old files is normal.

### Lesson 4 · "Diff smaller than expected" is a signal

If the user described a substantial copy-rewrite session (4-7 hours of polish), and the PR diff comes out small (<200 lines for what should be 2000+), the diff is wrong. Either the source-of-truth was misidentified or content was lost in conversion. Stop and re-verify before merging.

## Invariants consulted

- `verify-before-claim`. Before claiming "worktree is stale," produce evidence (mtime check)
- `gh-api-push-pr`. The recipe this skill protects from regression

## Integration points

- Pairs with `worktree-uncommitted-polish-trap` (dispatcher-side counterpart). That skill teaches the orchestrator to ANNOUNCE mods with mtime evidence; this skill teaches the executor to CHECK for them
- Pairs with `hmr-localhost-via-cp`. The upstream pattern that creates the worktree-files-fresher-than-branch state

## Completeness principle

This skill fires only on assignments that touch sibling worktrees. It does NOT fire on:
- Assignments in repos with no worktrees
- Read-only research tasks
- Direct edits within the primary checkout

False positives are cheap (a 30-second `ls -la` per file). False negatives are expensive (a regressed PR + orchestrator forensics + a follow-up PR + production-push hold).

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a marketing-site migration regression that shipped pre-edit content over post-edit content.
