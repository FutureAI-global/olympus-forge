---
name: worktree-uncommitted-polish-trap
namespace: session-lessons
version: 0.1.0
description: |
  Dispatcher-side guard for cross-worktree work. When the orchestrator
  dispatches structural work to another session and the dispatcher's worktree
  has uncommitted polish, the dispatchee will often classify the worktree as
  stale (branch age is multi-day) and ship pre-polish content from the base
  ref. This skill encodes the pre-dispatch ritual: announce the uncommitted
  mods explicitly with mtime evidence, file map, and a "pull from worktree,
  not blob ref" instruction. Fire BEFORE composing any cross-worktree dispatch.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a cross-worktree migration where the dispatcher's worktree carried hours of uncommitted copy polish, the executor branched from the base ref, and shipped pre-polish content in an atomic-looking PR
---

# worktree-uncommitted-polish-trap · announce uncommitted mods before dispatching

## Why this exists

You spend an evening polishing files on a local worktree (copy rewrites, layout tweaks, new components). The polish lives entirely in the working tree:

- Modified files: `git status --short` shows ` M` against a chunk of files
- New files: `git status --short` shows `??` against new components

Then you dispatch a structural task ("migrate this content to root URLs") to another session. The dispatchee:

1. Sees `git status` showing dirty mods in a worktree on a multi-day-old branch
2. Concludes the mods are stale leftover from earlier work
3. Branches fresh from the base ref tip
4. Pulls each file's content from the base blob ref, not the worktree
5. Ships an atomic, beautifully-shaped PR with the pre-polish content

The PR shape looks correct. The structure is correct. The content is the wrong revision. The user sees a regression.

This skill blocks the trap on the dispatcher side. The executor-side counterpart is `worktree-mtime-not-branch-date`.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag worktree-dispatch --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

Fire this skill when about to:

1. Compose a cross-worktree or cross-repo dispatch where the source content lives in a worktree you've recently edited
2. Hand off "migrate / restructure / refactor" work whose inputs are files in a sibling worktree at `~/<repo>-<feature>/`
3. Notice `git status --short` shows ` M` or `??` entries on the dispatchable worktree at the moment of dispatch
4. Send any assignment that says "the source is at <worktree-path>" without specifying whether the worktree is canonical vs the base ref

Voice triggers: "dispatch this to another session", "tell the executor where the source is", "send the migration".

## Workflow

### Phase 1 · Inventory the dispatchable worktree

Before sending any dispatch, run on the worktree the dispatchee will read from:

```bash
cd <worktree-path>
git status --short
git diff --stat -- <area>
ls -la --time-style=long-iso <key-files>
```

Capture the output verbatim. The mtimes are evidence the executor will need.

### Phase 2 · Pick a strategy

Three options when the worktree has uncommitted polish:

**Option A · Commit it first** (cleanest, adds a round trip)
- Commit + push the polish as its own PR
- Wait for it to land on the base branch
- THEN dispatch the structural change (executor branches from updated base tip)

**Option B · Tell the executor explicitly** (faster, requires explicit instruction)
- Include in the dispatch:
  - "WORKTREE HAS UNCOMMITTED POLISH" flagged in caps
  - File map: worktree-source-path then executor-target-path
  - Mtime evidence to defeat the "looks stale" inference: paste the `ls -la --time-style=long-iso` output
  - Instruction: "pull file content from the worktree, not the base blob ref"

**Option C · Separate-PR strategy** (good when polish and structural change are both big)
- Dispatch the structural change (file moves)
- After the executor's PR lands, push the polish as a follow-up PR against the new paths
- Risk: there is a window where deployed content is unpolished

### Phase 3 · Compose the dispatch with mtime evidence

In the dispatch body, include a raw mtime block the executor can read at a glance:

```
WORKTREE HAS UNCOMMITTED POLISH (do not pull from base ref blobs).

mtimes:
  2026-04-28 15:17 src/<route>/page.tsx
  2026-04-28 15:51 src/<route>/<sub>/page.tsx
  2026-04-28 16:20 src/<route>/<sub2>/page.tsx
  2026-04-28 17:31 src/<route>/<sub3>/page.tsx

File map:
  <worktree>/src/<route>/page.tsx -> <target>/page.tsx
  ...

Source-of-truth: the worktree files at the paths above. NOT base ref blobs.
```

Files modified in the past hours defeats the "stale" face on inspection.

### Phase 4 · Confirm receipt before walking away

Watch for the executor's ack. If their ack contains words like "stale", "5+ days old", "leftover", that is the trap firing. Reply immediately re-asserting the file map and mtimes, and (if needed) link them to `worktree-mtime-not-branch-date`.

## What NOT to do

- Do not assume the executor will check mtimes on their own. Branch age is the default signal they will reach for; mtime check is the exception.
- Do not paste only the file list without mtimes. The mtimes are what defeat the stale inference; the list alone does not.
- Do not dispatch and then immediately context-switch. Watch for the ack and intercept the trap if it fires.
- Do not say "the worktree has some local mods" in passing. That is the exact phrasing executors round down to "stale". Use caps and explicit instruction.
- Do not skip Phase 1 because "it is obvious which files are fresh." If you cannot paste a `ls -la` block, the executor cannot verify the claim.

## Seed lessons

### Lesson 1 · Atomic PR with pre-polish content from base ref

Orchestrator polished a chunk of route content on a sibling worktree across an evening (multi-hour copy-rewrite session, no commits). Dispatched a sub-90-min structural migration to another session. The dispatch said "source is at <worktree>" without specifying canonical vs base ref.

Executor checked branch age (multi-day-old branch tip), classified the worktree as stale, branched from the base ref, built a tree spec from base blob SHAs. PR opened with correct structure, pre-polish content. Auto-merged within minutes. Orchestrator caught the regression via mtime audit and posted a polish overlay follow-up PR.

Cost: an extra PR plus recovery time plus production push held until follow-up landed.

### Lesson 2 · "Source is at <worktree>" is ambiguous

A dispatch line that names a worktree path is not enough. The executor reads it as "the working directory for this task" and still pulls content from whatever ref they think is canonical. Without an explicit "pull from the worktree filesystem, NOT the blob ref" instruction, the trap is wide open.

### Lesson 3 · Multi-day branch with hour-old files is normal

A worktree's branch tip date is independent of any file's mtime inside the worktree. Direct Edit, `cp` from another worktree (HMR preview pattern), or manual editing all bump file mtimes without moving the branch. Treating branch tip date as a freshness proxy is the root failure mode.

### Lesson 4 · Caps + raw mtime block beats prose

A paragraph that says "by the way some of the files have recent edits" loses to "WORKTREE HAS UNCOMMITTED POLISH" plus a literal `ls -la --time-style=long-iso` block. Executors triaging an inbox of dispatches scan for caps and verbatim evidence; they round prose down to "ambient noise".

## Invariants consulted

- `verify-before-claim`: the executor's "looks stale" assessment is itself a claim that needs evidence; mtime is the evidence. Pre-loading the mtime in the dispatch removes the need for them to verify.
- `fresh-state`: pre-flight check that the worktree state being dispatched is actually current (no other session has overwritten it since you last edited).

## Integration points

- Pairs with `worktree-mtime-not-branch-date` (the executor-side counterpart): that skill teaches the executor to CHECK mtimes; this skill teaches the dispatcher to ANNOUNCE them. Both are needed; either one alone leaves a gap.
- Pairs with `hmr-localhost-via-cp`: the upstream pattern that creates the most common form of "worktree files fresher than branch" state. If you used that pattern recently, the trap is loaded.
- Pairs with `dispatched-pr-content-verification`: the post-PR audit that catches the regression when prevention fails. Use as backstop, not primary defense.

## Completeness principle

This skill fires only when dispatching cross-worktree work. It does NOT fire on:
- Same-worktree work (no executor handoff)
- Read-only research dispatches
- Dispatches whose inputs are committed and pushed

False positives are cheap (30 seconds of `git status` plus pasting an mtime block). False negatives are expensive (a regressed atomic PR plus follow-up PR plus production-push hold plus the executor learning the wrong lesson).

## Changelog

- v0.1.0 (2026-04-29): initial skill from session-lessons. Forged from a cross-worktree migration where the dispatcher's worktree carried uncommitted polish, the executor branched from the base ref, and shipped pre-polish content in an atomic-looking PR.
