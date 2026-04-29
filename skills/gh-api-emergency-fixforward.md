---
name: gh-api-emergency-fixforward
namespace: session-lessons
version: 0.1.0
description: |
  Recovery skill for when a merged PR breaks a base branch by importing files
  that exist only in an unmerged sibling PR. Encodes the two-step fix-forward:
  detect the missing files via gh api contents 404, reuse blob SHAs from the
  open sibling PR, push a minimal blob-identical fix-forward via the gh-API
  recipe. Faster and safer than reverting the merged PR.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a generic parallel-PRs-from-same-base race incident
---

# gh-api-emergency-fixforward · recovery when a merged PR imports from an unmerged sibling

## Why this exists

Two PRs branched from the same base tip in parallel. PR-A (release notes / page edits) imports symbols from PR-B (new shared components). PR-A merges first. The base branch is now broken: PR-A references files that do not exist on the base.

The default reaction is panic-revert. That is wrong when the breaking change is purely missing imports. Fix-forward is faster, safer, and preserves the merged PR's other valuable changes (release notes, tests, security fixes).

This skill encodes the two-step fix-forward and the criteria for choosing it over a revert.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag gh-api --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. A PR just merged to the base branch and the live page returns Next.js 404 / Vercel build error / Module-not-found.
2. CI on the base branch goes red immediately after a merge with errors of shape `Cannot find module '<imported path>'`.
3. A reviewer reports "broken base branch after merge" with no obvious bad logic in the merged diff.
4. You can identify an open sibling PR that contains the missing files.

Voice triggers: "fix forward", "unbreak base", "emergency push", "missing imports after merge", "merged PR broke staging".

## Workflow

### Phase 1 - Detection

```bash
# 1. Verify the imports that the merged PR references
gh api "repos/<repo>/contents/<route>/page.tsx?ref=<base>" --jq '.content' \
  | base64 -d | grep -E 'import .* from' | head -20

# 2. For each imported path, probe whether it exists on the base
gh api "repos/<repo>/contents/<imported/path>?ref=<base>" --jq '.path' 2>&1 | head -2
# 404 -> missing -> fix-forward needed
```

Confirming evidence from the live deploy:

```bash
curl -s -o /tmp/page.html "https://<host>/<route>"
grep -ic "This page could not be found\|Application error\|Module not found" /tmp/page.html
# > 0 -> broken
```

### Phase 2 - Decide: fix-forward or revert

Fix-forward is the right call when:
- The breaking change is purely about missing files, not bad logic.
- The blobs already exist (in the still-open conflicting PR).
- The fix is small (typically <= 3 files).

Revert is the right call when:
- The merged PR has logic bugs, not just missing imports.
- The unmerged PR is far from ready and you cannot trust its blobs.
- The breaking change is in a config / build file (not source).

Default to fix-forward when all three fix-forward criteria hold.

### Phase 3 - Reuse blobs from the unmerged sibling PR

The blobs already exist server-side; you do not need to re-upload. Pull the SHAs from the open sibling PR's tree:

```bash
gh api "repos/<repo>/pulls/<unmerged-PR>/files" \
  --jq '.[] | select(.filename | test("<shared-component>|<shared-tokens>")) | "\(.filename)\t\(.sha)"'
```

If you authored the unmerged PR, reuse the blob SHAs you captured during your push (they do not expire).

### Phase 4 - Build minimal tree + commit + branch + PR

```bash
BASE_SHA=$(gh api "repos/<repo>/git/ref/heads/<base>" --jq '.object.sha')
BASE_TREE=$(gh api "repos/<repo>/git/commits/$BASE_SHA" --jq '.tree.sha')

cat > /tmp/tree.json <<EOF
{
  "base_tree": "$BASE_TREE",
  "tree": [
    {"path": "src/.../<shared-component>.tsx", "mode": "100644", "type": "blob", "sha": "<reused-blob-sha-1>"},
    {"path": "src/.../<shared-tokens>.ts",     "mode": "100644", "type": "blob", "sha": "<reused-blob-sha-2>"}
  ]
}
EOF
TREE_SHA=$(gh api "repos/<repo>/git/trees" --input /tmp/tree.json --jq '.sha')

COMMIT_SHA=$(gh api "repos/<repo>/git/commits" \
  -f message="fix: unbreak <route> · ship missing shared files" \
  -f tree="$TREE_SHA" \
  -f parents[]="$BASE_SHA" \
  --jq '.sha')

gh api "repos/<repo>/git/refs" \
  -f ref="refs/heads/fix/missing-imports" \
  -f sha="$COMMIT_SHA"

gh pr create --repo "<repo>" \
  --head fix/missing-imports --base "<base>" \
  --title "fix: unbreak <route>" \
  --body "Restores missing shared files. Blob-identical to the open sibling PR; sibling rebase will be a no-op on these paths."
```

End-to-end: about five minutes.

### Phase 5 - Verify the sibling PR rebase will be a no-op

After the fix-forward merges, the unmerged sibling PR's diff against the base should show no entries for the recovered files (because they are now blob-identical):

```bash
gh api "repos/<repo>/compare/<base>...<unmerged-branch>" \
  --jq '.files[] | select(.filename | test("<shared-component>|<shared-tokens>"))'
# empty output -> those files now identical between base and sibling-PR-branch
```

If the sibling rebases and the recovered files re-appear in the diff, the blobs were not actually identical; investigate before merging the sibling.

### Phase 6 - Coord posting

Always flag emergency fix-forwards on the coord PR with live evidence:

```markdown
## EMERGENCY merge · fix-forward

`<merged-PR>` merged `<route>/page.tsx` importing X from `<missing/path>`. The file 404s on the base:
$ gh api contents/<missing/path>?ref=<base>  -> 404

Live impact:
$ curl <host>/<route> | grep -c "<known-good-string>"  -> 0
$ curl <host>/<route> | grep -c "This page could not be found"  -> 1

Fix `<fix-forward-PR>` ships the N missing files (blob-identical to open sibling `<unmerged-PR>`).
After merge, the sibling rebase is a no-op on these paths.
```

Live evidence + the "fix-forward not revert" justification is what gets the merge approver to ship fast.

## What NOT to do

1. Do not panic-revert a merged PR that has valuable content (release notes, tests, security fixes) when the only break is missing imports.
2. Do not re-upload blobs you can reuse from the open sibling PR. Server-side blobs do not expire.
3. Do not omit `base_tree` from the tree-create call (see `gh-api-push-pr` lesson 3 - silent deletion of unlisted files).
4. Do not skip the live-evidence step. The merge approver needs the curl + 404 lines, not your assertion.
5. Do not fix-forward if the merged PR has actual logic bugs. Revert in that case.

## Seed lessons

### Lesson 1 - Two parallel PRs from the same base race; first to merge wins, second breaks the base

When PR-A and PR-B both branch from the same base tip and PR-A imports symbols defined in PR-B, the merge order decides whether the base stays green. If PR-A merges first, the base imports from files that do not exist there, and the base is broken until PR-B also merges (or until a fix-forward ships the missing files). The fix-forward path is faster than waiting for PR-B's review and merge.

### Lesson 2 - Reuse server-side blob SHAs across PRs

GitHub's git/blobs are content-addressed and never expire. A blob SHA captured during one PR's push can be reused verbatim in a tree spec on a different branch / PR, as long as the content is identical. Skip the re-upload when emergency-shipping shared files; pull the SHAs from the open sibling PR's `pulls/<num>/files` response.

### Lesson 3 - The fix-forward should ship blob-identical files, not "equivalent" files

If you regenerate the missing files locally and push them, even minor whitespace or encoding differences mean the sibling PR's rebase will not be a no-op on those paths; you get a merge conflict on the rebase, defeating the point. Always reuse the exact blob SHA from the sibling PR.

### Lesson 4 - Confirm the break with both gh-api 404 AND live deploy 404

Either signal alone can be misleading. The gh-api 404 confirms the source path is missing on the base ref; the live deploy 404 confirms the build is actually broken (and not, for example, a tree-shaken import that the bundler dropped silently). Both signals together justify the emergency fix-forward to the merge approver.

### Lesson 5 - Coord-PR posting requires live evidence, not assertions

A coord-PR comment that says "merged PR broke the base, please merge fix-forward" gets ignored or questioned. A coord-PR comment that includes the curl output, the gh-api 404, and the explicit "blob-identical to sibling PR, rebase will be no-op" justification gets merged in minutes. The evidence is the unblock.

## Invariants consulted

- `Invariant 1 - Run the check before claiming` - "fix forward unbroke staging" requires the post-merge curl + gh-api response in the same turn
- `Invariant 3 - Never git push on repos >1 GB` - the fix-forward ships via the gh-API recipe
- `Invariant 4 - Preserve line endings on API push` - reused blob SHAs have the original line endings; do not regenerate locally

## Integration points

- Pairs with `api-push` - the existing canonical recipe; this skill is the emergency-recovery variant
- Pairs with `gh-api-push-pr` - the foundation that defines the four-API-call sequence + base_tree enforcement
- Pairs with `gh-api-push-retry-traps` - if the fix-forward push itself partially fails, the retry-traps skill covers recovery
- Pairs with `verify-before-claim` - the live-evidence step (curl + gh-api) is the verification; cite output before claiming "fixed"

## Completeness principle

10/10: detect with both gh-api 404 + live-deploy 404 + reuse blob SHAs from sibling + push minimal fix-forward + verify sibling-rebase no-op + post coord with live evidence.
7/10: skip the sibling-rebase verification (risk: sibling rebase produces unexpected merge conflict, second emergency).
3/10: revert the merged PR (risk: lose all the merged PR's other valuable changes; longer recovery).

Default: 10/10. The full recovery costs about five minutes; the alternatives cost hours and re-work.

## Changelog

- v0.1.0 (2026-04-29) - initial skill from session-lessons. Forged from a generic parallel-PRs-from-same-base race incident.
