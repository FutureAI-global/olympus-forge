---
name: dispatched-pr-content-verification
namespace: session-lessons
version: 0.1.0
description: |
  Dispatcher-side verification that an executor's PR contains the specific
  delta you sent. Encodes the gh-pr-diff-grep ritual that catches "PR opened"
  not equaling "your specific delta is in the PR." Fire AFTER the receiver
  opens a PR but BEFORE you claim shipment to the user or orchestrator.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a cross-worktree marketing migration where the receiver's atomic 21-file PR shipped at the right shape but missed a v7.4 string bump and ~2400 lines of polish that were sitting uncommitted on the dispatcher's worktree. The PR title, file count, and Vercel preview all looked clean; only `gh pr diff | grep <addendum-string>` revealed the gap.
---

# dispatched-pr-content-verification · PR opened ≠ your delta is in the PR

## Why this exists

You dispatch work via a coord PR comment. The receiver acks, ships a PR. You see the PR title matches the dispatch, the file count matches, the preview environment is green. Looks done. You tell the orchestrator "shipped, preview here."

Then the orchestrator opens the preview and the deployed surface shows the **pre-polish** content. Because the receiver branched from the base ref tip and the polish was sitting uncommitted on the dispatcher's worktree, the PR has the right *shape* but the wrong *content*.

This skill says: **never trust "PR opened" as proof your specific delta is in the PR. Grep for it.**

## The check

For every meaningful addendum or content delta you sent the dispatchee, verify it landed in the diff:

```bash
# 1. Pull the PR diff
gh pr diff <num> --repo <repo>

# 2. Grep for your specific delta strings
gh pr diff <num> --repo <repo> 2>&1 | grep -E '<your-delta-marker>' | head -5

# 3. If empty: the delta is missing.
#    If wrong substitution: the receiver guessed (e.g. you said v7.4, they wrote v7).
```

For multi-file polish that's content-heavy (not just a string bump), spot-check 2-3 files against the worktree source:

```bash
# Compare local worktree (where you made the edits) against the dispatchee's branch
gh pr diff <num> --repo <repo> 2>&1 | sed -n '/path\/to\/file/,/^diff/p' | head -50
diff <(cat ~/worktree/path/to/file) \
     <(gh api repos/<repo>/contents/path/to/file?ref=<branch> --jq '.content' | base64 -d)
```

## What to do when the delta isn't there

1. **Don't tell the orchestrator "shipped"** — that's a lie at this point.
2. **Post a structured addendum on the coord PR** — not the feature PR. Receivers route via the coord PR's autonomous tick. Format per `coord-comment-template`.
3. **Include in the addendum**: file map (worktree source → branch target), evidence (mtimes if "stale" was the receiver's reason for skipping), instruction (apply over current branch HEAD, preserve receiver's other edits).
4. **Tell the merger to NOT merge yet** — explicitly. An auto-merge tick may green-light a CI-passing PR even though the content is wrong.

## The harder case: receiver decided your context was stale

Sometimes the receiver looks at uncommitted worktree mods and concludes they're stale because the *branch* is old (multi-day). The mods may be from this evening; the branch age is irrelevant. See `worktree-uncommitted-polish-trap` for the dispatcher-side fix.

Defeat the misread with **mtime evidence** in the addendum:

```bash
ls -la --time-style=long-iso <worktree-files> 2>&1
# Paste raw output. mtimes from "this evening" defeat "stale 5 days ago" by face.
```

## Why coord PR not feature PR

Sessions on autonomous tick poll the coord PR for assignments and addenda. They don't poll feature-PR comments unless explicitly listening. Coord PR is the contract surface. Feature PR is the artifact surface.

## Worked example

The 2026-04-29 cross-worktree migration:

- T+0 — dispatcher posts a structural assignment on the coord PR
- T+4min — receiver acks, says worktree mods look "stale" (~5 days old by branch age)
- T+13min — dispatcher posts addendum: "bump v7.0 → v7.4 in product/page.tsx"
- T+24min — receiver opens atomic 21-file PR. Title + file count look correct.
- T+25min — dispatcher runs `gh pr diff <num> | grep 'v7'` → only `v7` (not v7.4). Confirmed: addendum missed AND base ref was used instead of worktree.
- T+26min — `git status` of worktree → 19 modified + 3 untracked files of evening polish
- T+27min — `ls -la --time-style=long-iso` → mtimes 4-7 hours old, defeating the receiver's "stale 5 days" misread
- T+29min — full polish-set addendum posted with mtime evidence + file map; receiver folds polish into amended PR

The pattern: every step was a verification, not a vibe.

## Cross-reference

- `worktree-uncommitted-polish-trap` — dispatcher-side prevention before the dispatch goes out
- `dispatch-format-pickup-verification` — verify the dispatch even reached the receiver
- `verify-receipts-before-flawless-claim` — broader receipt-checking pattern
