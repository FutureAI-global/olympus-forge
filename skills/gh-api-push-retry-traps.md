---
name: gh-api-push-retry-traps
namespace: session-lessons
version: 0.1.0
description: |
  Trap-catching skill for retrying a partially failed gh-api push. Covers three
  specific traps: (1) "Reference already exists" pinning the branch to the
  failed first attempt, (2) Windows shell editor re-injecting CRLF after a
  local strip but before the blob upload, and (3) Python JSON round-trip
  mojibake-ing commit messages on Windows. Use BEFORE retrying any failed
  push, not after the second failure.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 from a generic mid-sequence push-failure retry incident on Windows
---

# gh-api-push-retry-traps · verify GitHub-side, not local, before retry

## Why this exists

`api-push` and `gh-api-push-pr` cover the happy path. This skill covers the traps that surface when a push partially fails and the next attempt is built on stale assumptions.

The lesson generalizes: **trust the remote state, not the local one. Local checks are necessary but never sufficient.**

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag gh-api --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. The previous `gh api git/refs` POST returned `Reference already exists` (HTTP 422) and you are about to retry.
2. The previous `gh api git/blobs` upload succeeded but the source-hygiene gate fired with `CRLF detected in tracked source files`.
3. You are pushing from Windows / MSYS2 / Git Bash and any prior step had a non-zero exit.
4. A pushed commit's message rendered with mojibake (`A.` instead of a middle dot, `A(c)` instead of an accented letter).
5. The PR head SHA does not match the branch head SHA after a push.

Voice triggers: "retry the push", "branch already exists error", "source-hygiene CRLF after push", "mojibake commit message".

## Workflow

### Phase 1 - Trap 1: "Reference already exists" pins the branch to the failed first attempt

The push sequence is blob -> tree -> commit -> ref. If the FIRST attempt failed AT the ref-create step (network blip, branch existed from a much earlier session, etc.), the COMMIT was already created server-side. The branch ref may still be created pointing at the OLD commit (or no commit at all), and your subsequent retry sees:

```
{"message":"Reference already exists","status":"422"}
```

The trap: this looks like "the branch is up-to-date." It is not. The branch is pinned to the commit from your FIRST attempt, which had the bug you were trying to fix.

Detection - after the retry, query the actual branch tip:

```bash
PR_HEAD=$(gh api "repos/$REPO/pulls/$PR_NUM" --jq '.head.sha')
BRANCH_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
[ "$PR_HEAD" = "$BRANCH_HEAD" ] || echo "WARN: PR head ($PR_HEAD) != branch head ($BRANCH_HEAD)"
```

If they differ, the PR is not on your latest commit.

Fix - PATCH the ref forward instead of trying to create it:

```bash
# instead of:
gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$NEW_COMMIT"   # 422 if exists

# do this:
gh api "repos/$REPO/git/refs/heads/$BRANCH" -X PATCH -f sha="$NEW_COMMIT"
```

In the canonical push recipe, ALWAYS check whether the branch already exists first; PATCH if yes, POST if no.

### Phase 2 - Trap 2: Windows shell editor re-injects CRLF post-strip

Edit a TS / TSX / JS file via Edit tool on Windows -> file gets CRLF line endings (Windows default). Pre-flight strip via `sed -i 's/\r$//'` succeeds; `tr -cd '\r' | wc -c` returns 0. Push the blob. The source-hygiene gate fires:

```
::error::Source-hygiene gate · CRLF detected in tracked source files:
::error::  <path/to/file>.ts (CR=522)
```

What happened: between your local strip and the next `base64 -w0 < file` upload, the file was re-edited (by Edit, by autocrlf-on-checkout, or by another tool) and CRLF came back. Your `tr` check was on a stale view of the file.

Detection - verify the GitHub-side blob bytes, not the local file:

```bash
NEW_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
gh api "repos/$REPO/contents/$FILE?ref=$NEW_HEAD" --jq '.content' | base64 -d | tr -cd '\r' | wc -c
# must be 0 - what is actually on the remote
```

Fix workflow - strip CRLF, push, then verify GitHub-side, then move on:

```bash
sed -i 's/\r$//' "$FILE"                                      # local strip
[ "$(tr -cd '\r' < "$FILE" | wc -c)" -eq 0 ] || { echo "FAIL local"; exit 1; }
# ... push blob, tree, commit, PATCH ref ...
sleep 1                                                       # eventual consistency
NEW_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
REMOTE_CR=$(gh api "repos/$REPO/contents/$FILE?ref=$NEW_HEAD" --jq '.content' | base64 -d | tr -cd '\r' | wc -c)
[ "$REMOTE_CR" -eq 0 ] || { echo "FAIL remote: $REMOTE_CR CR chars"; exit 1; }
```

The remote check is the one that matters. The source-hygiene gate runs on whatever GitHub serves at the PR HEAD; your local file is irrelevant once you have uploaded.

### Phase 3 - Trap 3: Python JSON round-trip mojibakes commit messages on Windows

Building gh-api commit payloads via Python on Git Bash (Windows): `json.load(open(path))` defaults to cp1252, mangling any non-ASCII (middle dot, smart quotes, accented letters) into mojibake bytes. Pushed commit message renders as `A.` instead of the intended middle dot.

```python
# WRONG - uses platform-default cp1252 on Windows
p = json.load(open(path))
p['tree'] = TREE_SHA
json.dump(p, open(path, 'w'))

# RIGHT - explicit UTF-8 + ensure_ascii=False
p = json.load(open(path, encoding='utf-8'))
p['tree'] = TREE_SHA
json.dump(p, open(path, 'w', encoding='utf-8'), ensure_ascii=False)
```

Or sidestep entirely: keep commit messages strict ASCII when authoring on Windows.

Detection - verify the commit message rendered correctly server-side:

```bash
gh api "repos/$REPO/git/commits/$COMMIT_SHA" --jq '.message' | head -3
# Look for A., A(c), etc - mojibake gives away the encoding mismatch
```

Recovery if pushed with mojibake - re-create the commit with the ASCII-only message and PATCH the branch ref:

```bash
# Edit the JSON to ASCII-only (or re-build with explicit UTF-8 + ensure_ascii=False), then:
NEW_COMMIT=$(gh api "repos/$REPO/git/commits" --input fixed-payload.json --jq '.sha')
gh api "repos/$REPO/git/refs/heads/$BRANCH" -X PATCH -f sha="$NEW_COMMIT"
gh api "repos/$REPO/git/commits/$NEW_COMMIT" --jq '.message' | head -3   # verify clean
```

If the PR is already open, the PATCH replaces the branch tip; the PR auto-updates.

### Phase 4 - Pre-flight checklist before opening any PR from Windows

Add to the gh-api-push-pr recipe (Windows-specific safety net):

```bash
# 1. Confirm no existing PR / branch covers this work
gh pr list --repo "$REPO" --state open --search "<file path or symbol>" --limit 5

# 2. Strip CRLF on every file you are about to push (text-shape extensions)
for f in "${FILES[@]}"; do
  case "$f" in *.ts|*.tsx|*.js|*.json|*.md) sed -i 's/\r$//' "$f" ;; esac
done

# 3. Local CR-count check
for f in "${FILES[@]}"; do
  c=$(tr -cd '\r' < "$f" | wc -c)
  [ "$c" -eq 0 ] || { echo "FAIL: $f has $c CR chars"; exit 1; }
done

# 4. Push (blob -> tree -> commit -> ref via POST or PATCH per existing-branch check)

# 5. Remote verify post-push
sleep 1
for f in "${FILES[@]}"; do
  c=$(gh api "repos/$REPO/contents/$f?ref=$NEW_HEAD" --jq '.content' | base64 -d | tr -cd '\r' | wc -c)
  [ "$c" -eq 0 ] || { echo "FAIL remote: $f has $c CR chars"; exit 1; }
done
```

## What NOT to do

1. Do not retry a failed push without first checking whether the previous attempt left server-side state (commit created, ref pinned, branch present).
2. Do not trust local file state as proof of remote file state. Editors, autocrlf, and other tools can mutate the file between your check and the upload.
3. Do not POST to `git/refs` for a branch that already exists. Always check first; PATCH if it exists.
4. Do not force-push on a `Reference already exists` retry without confirming the existing ref points at YOUR last attempt and not someone else's commit.
5. Do not assume `json.load` / `json.dump` default to UTF-8 on Windows. They default to cp1252.

## Seed lessons

### Lesson 1 - Reference already exists pins the branch to the failed attempt

When a push sequence fails at the ref-create step, the commit may have been created server-side, and the branch ref may have been created pointing at the prior attempt's commit. Re-trying the POST gets HTTP 422 `Reference already exists`, which looks like "branch is up-to-date" but actually means "branch is pinned to the buggy first attempt." Always check `PR head == branch head == intended commit` after a retry.

### Lesson 2 - Local CRLF check is necessary but not sufficient

Stripping CRLF locally with `sed -i 's/\r$//'` and confirming `tr -cd '\r' | wc -c` is 0 does not guarantee the upload contains LF. Editors, autocrlf-on-write, and other tools can re-inject CRLF between the local check and the `base64 -w0 < file` upload. The only reliable check is to read the bytes back from `gh api contents/<path>?ref=<branch-head>` and grep for CR characters.

### Lesson 3 - Python on Windows defaults to cp1252 for file IO

`json.load(open(path))` and `json.dump(obj, open(path, 'w'))` use the platform's default encoding, which is cp1252 on Windows. Any non-ASCII in the JSON gets mojibake-d on round-trip. Always pass `encoding='utf-8'` to `open` and `ensure_ascii=False` to `json.dump`. Or keep authored content strict ASCII when on Windows.

### Lesson 4 - PATCH refs / heads / branch is the correct retry primitive

POST to `git/refs` is for branch CREATE only. Branch UPDATE (follow-up commit, retry after a partial failure) is `PATCH refs/heads/<branch>`. Habit-form the existence check: query the ref first, branch on POST vs PATCH. Skipping the check is what produces the "Reference already exists" trap.

### Lesson 5 - Source-hygiene gate is GitHub-side, not local

The CI gate that rejects CRLF runs on whatever GitHub serves at the PR head SHA. Your local file's line endings are irrelevant once the blob is uploaded. The verify step must be `gh api contents/<path>?ref=<head-sha>`, not `cat <local-file>`.

## Invariants consulted

- `Invariant 1 - Run the check before claiming` - "push succeeded" requires the server-side verification, not the local exit code
- `Invariant 4 - Preserve line endings on API push` - this skill enforces verification of that invariant after the push, not just before

## Integration points

- Pairs with `api-push` - the existing canonical recipe; this skill is the retry-recovery variant
- Pairs with `gh-api-push-pr` - the foundation that defines the pre-push safety check + branch-existence-aware ref op
- Pairs with `gh-api-emergency-fixforward` - the recovery skill for when a successful push leaves a base branch broken via missing imports
- Pairs with `verify-before-claim` - server-side verification (gh api contents, git/commits message render) is the evidence

## Completeness principle

10/10: existence-check the branch ref before POST vs PATCH + verify PR head == branch head after push + verify CRLF count via gh-api contents (not local file) + verify commit message render via gh-api git/commits.
7/10: skip the commit-message render check (risk: ship mojibake commit subject lines that downstream tooling parses incorrectly).
3/10: re-try the push naively without any server-side verification (risk: PR pinned to first-attempt commit; CI red on CRLF; mojibake in commit history).

Default: 10/10. Each verification call is a single `gh api` round-trip; the failure modes cost reviewer round-trips and force-push recovery.

## Changelog

- v0.1.0 (2026-04-29) - initial skill from session-lessons. Forged from a generic mid-sequence push-failure retry incident on Windows / MSYS2.
