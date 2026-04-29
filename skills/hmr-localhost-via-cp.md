---
name: hmr-localhost-via-cp
namespace: session-lessons
version: 0.1.0
description: |
  Time-to-blessing trick when the worktree containing your in-progress edits
  has broken or incomplete deps and will not start a Next.js dev server.
  Copy the in-progress files into a sibling worktree that already has a
  healthy dev server running, let HMR pick them up, browse the sibling's
  localhost. Never commit from the target worktree. Use only for short
  preview windows; long-term, fix the source worktree's deps. Creates the
  upstream condition that `worktree-mtime-not-branch-date` and
  `worktree-uncommitted-polish-trap` exist to defend against.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a v-release marketing preview where the source worktree had a corrupt sub-import under hoisted node_modules and a sibling worktree's running dev server provided the preview surface in under two minutes
---

# hmr-localhost-via-cp · preview broken-dep edits via a sibling worktree

## Why this exists

You have edits in worktree A. The user wants to see them on localhost. But:

- A's `node_modules/` is missing or has a broken install (a sub-import inside a hoisted package is unresolvable)
- Re-running `npm install` in A would take 5-10 minutes and might still fail
- A different worktree B has a healthy install AND a dev server already running on `localhost:3000` (or another local port)

The trick: copy A's in-progress files into B, let B's dev server HMR pick them up, the user browses B's localhost.

Default reaction when "my worktree's deps are broken" is to fix the deps. That is 5-30 minutes of tooling debug. The cp-into-running-worktree pattern gets the user blessing in under a minute. Time-to-blessing matters more than worktree purity for short-lived previews.

The downside: this pattern leaves uncommitted state in B. Future sessions that read B will see fresh files on a multi-day-old branch and may classify them as "stale" if they do not check mtimes. That is why `worktree-mtime-not-branch-date` and `worktree-uncommitted-polish-trap` exist.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag hmr-cp --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

Fire this skill when about to:

1. Tell the user "I cannot show you on localhost because deps are broken" while a sibling worktree has a working dev server
2. Spend more than five minutes debugging `npm install` in the source worktree purely to enable a preview
3. Reach for "let me just commit and check Vercel preview" as a workaround when local preview is the goal
4. Notice the source worktree's `node_modules/` is missing a hoisted sub-path while a sibling's is intact

Voice triggers: "show me on localhost", "preview this", "the deps are broken", "use the other worktree's server".

## Workflow

### Phase 1 · Confirm B is healthy enough to host A's content

```bash
# B is the target worktree (the one with the running dev server).
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/<route>
# Expect 200, not 500. A 500 means B is also broken; do not proceed.

# Confirm B has the critical sub-imports A's files reference.
ls B/node_modules/<critical-dep>/<sub-path>/some-file.mjs
# Exists means A's files are likely to compose with B's tree.
```

If either check fails, do NOT proceed. Fix A's deps or use a Vercel preview instead.

### Phase 2 · Copy A's in-progress files into B

```bash
SRC=/path/to/worktree-A
DST=/path/to/worktree-B
for f in $FILES; do
  mkdir -p "$(dirname "$DST/$f")"
  cp "$SRC/$f" "$DST/$f" && echo "  cp $f"
done
```

Preserve directory structure. Do NOT touch files in B that A does not modify.

### Phase 3 · Wait for HMR and verify the change is live

```bash
sleep 5
curl -s http://localhost:3000/<route> | grep -ic "<expected-string-from-A's-edits>"
# 1 or higher means A's content is live on B's localhost.
```

Hand off the URL to the user for blessing.

### Phase 4 · Cleanup after blessing

```bash
cd B
git checkout -- src/<paths-you-touched>/

git status --short
# Find any ?? entries (untracked files A added that B did not have)
rm <each-untracked-from-A>
```

The cp'd files were never committed in B; reverting B's working tree is a one-command revert plus a few targeted `rm`s.

### Phase 5 · Note the residue for future sessions

After cleanup, B should be back to its tracked state. But during the preview window, B's files were fresher than B's branch tip. If a future session reads B before cleanup completes, they may hit the `worktree-uncommitted-polish-trap`. Mention in coord notes:

```
hmr-cp preview active on B. Cleanup pending. Do not pull source from B until cleanup confirmed.
```

## What NOT to do

- Do not commit from B. The cp'd files belong to A's branch, not B's. Committing them in B mixes branch contents and is hard to unwind.
- Do not run this for windows longer than one hour. Long-term residue in B confuses other sessions and erodes the cleanup discipline.
- Do not use this when B is being actively used by another session for committing. Your `cp` shadows their state and they lose work.
- Do not skip Phase 1's health check. A 500 on B's `<route>` means B has its own breakage; cp'ing A's files in will not fix it.
- Do not skip the cleanup step. Untracked residue in B is the upstream of the polish-trap pattern.

## Seed lessons

### Lesson 1 · Corrupt hoisted sub-import blocked dev server

Source worktree had a missing file under `node_modules/<framer-style-pkg>/<dist-path>/<file>.mjs` (a sub-import resolution failure inside a hoisted package). `npm install` in the source did not restore the missing file. A sibling worktree's hoisted `node_modules/` had the file intact. Cp'ing the in-progress route files into the sibling and browsing its `localhost:3000` got user blessing in two minutes vs an estimated 15-30 min of dep debug.

### Lesson 2 · cp-residue confuses a future session

After a cp-preview session, the target worktree had untracked `??` entries and modified ` M` entries from the source's edits. A later session, dispatched to read source from the target worktree, classified the worktree as "stale uncommitted mods" based on branch tip age, branched from the base ref, and shipped pre-edit content. Caused a regression PR. Cleanup of the cp residue (Phase 4) would have prevented the misclassification entirely.

### Lesson 3 · "Vercel preview will be canonical" framing

The user is browsing localhost served by the target worktree (post-cp). The actual PR is the same content from the source worktree pushed via the GitHub API. If the target's deps differ subtly from the source's intended deps, what the user sees on localhost may not match what deploys. Always note explicitly: "you are previewing on the sibling worktree (post-cp); the actual PR is the same content from the source worktree, and the Vercel preview will be the canonical artifact for review."

### Lesson 4 · Time-to-blessing budget

A two-minute cp-preview that gets the user nodding "looks good" beats a thirty-minute dep debug that yields the same result. For preview-grade questions ("does the layout work", "does the copy read"), localhost fidelity within reason is enough. For correctness-grade questions ("does the form submit", "does the API call return the right shape"), use the Vercel preview against the actual deployed bundle.

## Invariants consulted

- `verify-before-claim`: Phase 3's `curl | grep` is the verification that the cp landed and HMR fired; without it, "the change is on localhost" is an unverified claim.
- `fresh-state`: Phase 5's coord note is the freshness signal future sessions need to avoid reading cp residue as canonical.

## Integration points

- Pairs with `worktree-mtime-not-branch-date` (executor-side defense): that skill is the downstream check that protects future sessions from misreading cp residue as stale. This skill creates the residue; that skill defuses it.
- Pairs with `worktree-uncommitted-polish-trap` (dispatcher-side defense): when a dispatcher is also the one who ran cp-preview, the polish-trap skill fires on the dispatch step. This skill is the upstream cause; that skill is the upstream guard.
- Pairs with `dispatched-pr-content-verification`: backstop for when both upstream defenses miss the residue and a regression PR ships.

## Completeness principle

This skill fires only when localhost preview is needed AND the source worktree cannot start a dev server. It does NOT fire on:
- Routine dev work in a healthy worktree
- Production preview (use Vercel)
- Long-term work where fixing the source worktree's deps is the right investment

False positives are cheap (you considered the trick, decided npm install was fast enough, moved on). False negatives are expensive (you spent 30 minutes debugging deps when a two-minute cp would have unblocked the user). Cleanup discipline (Phase 4 plus Phase 5) is what keeps the trick from creating downstream regressions.

## Changelog

- v0.1.0 (2026-04-29): initial skill from session-lessons. Forged from a v-release marketing preview where the source worktree had a corrupt sub-import under hoisted node_modules and a sibling worktree's running dev server provided the preview surface in under two minutes.
