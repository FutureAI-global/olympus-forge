---
name: gh-api-push-retry-traps
namespace: session-lessons
version: 0.1.0
description: |
  Three traps when retrying a partially-failed gh-api push: branch ref
  pinned to first attempt, Windows shell editor re-injecting CRLF
  post-strip, and Python JSON round-trip mojibakes commit messages on
  cp1252 platforms. Verify GitHub-side, not local.
allowed-tools:
  - Bash
provenance: |
  forged 2026-04-29 from PR #1752 (overnight push redid #1795 + #1807),
  PR #1860 (CRLF re-injection between strip and upload), and the
  cp1252 mojibake incident that turned middle-dot · into Â·.
---

# gh-api-push-retry-traps · trust the remote, not the local

## Why this exists

- The `gh-api-push-pr` recipe covers the happy path. Real pushes partially fail: network blips, branch-existence collisions, encoding round-trips.
- Naive retry shape: assume "I fixed the local file, push it again" — without verifying GitHub-side state, the retry compounds the failure.
- Three traps that bit me twice each:
  1. **"Reference already exists"** pins the branch to your FIRST attempt's commit (with the bug), while subsequent commits become orphans.
  2. **Windows shell editor re-injects CRLF** between local pre-flight check and blob upload — your `tr` check was on a stale file view.
  3. **Python JSON round-trip on cp1252** mangles em-dashes and middle dots into mojibake bytes that render as `Â·`.
- Right shape: **verify the remote state, not the local one.** Local checks are necessary but never sufficient.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag gh-api-retry --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Retrying a `gh api git/refs` or `gh api git/blobs` push that previously failed.
- Source-hygiene gate fires `CRLF detected` after a "successful" push.
- Commit message contains non-ASCII (em-dash `—`, middle dot `·`, smart quotes) and you're on Windows / Git Bash.
- "Reference already exists" 422 after a network-blip retry.
- PR head SHA doesn't match your latest commit SHA.

Voice triggers: "push failed, retry", "I just pushed but the gate fired again", "the commit message has weird characters", "branch is on the wrong commit".

## Workflow

### Trap 1 · "Reference already exists" pins branch to first attempt

The push sequence is blob → tree → commit → ref. If the FIRST attempt failed AT the ref-create step (network blip, branch already existed from earlier session), the COMMIT was created server-side. Subsequent retries see:

```
{"message":"Reference already exists","status":"422"}
```

The trap: looks like "the branch is up-to-date." It's not — branch is pinned to the FIRST attempt's commit (with the bug).

**Detection — query the actual branch tip + PR head**:

```bash
PR_HEAD=$(gh api "repos/$REPO/pulls/$PR_NUM" --jq '.head.sha')
BRANCH_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
[ "$PR_HEAD" = "$BRANCH_HEAD" ] || echo "WARN: PR head ($PR_HEAD) != branch head ($BRANCH_HEAD)"
```

**Fix — PATCH the ref forward**:

```bash
# instead of (which 422s):
gh api repos/$REPO/git/refs -f ref="refs/heads/$BRANCH" -f sha="$NEW_COMMIT"

# use:
gh api "repos/$REPO/git/refs/heads/$BRANCH" -X PATCH -f sha="$NEW_COMMIT"
```

In the canonical push recipe, ALWAYS check whether the branch exists first; PATCH if yes, POST if no.

### Trap 2 · Windows shell editor re-injects CRLF post-strip

Edit a TS/TSX/JS file via Edit tool on Windows → file gets CRLF line endings. Pre-flight strip via `sed -i 's/\r$//'` succeeds — `tr -cd '\r' | wc -c` returns 0. Push the blob. Source-hygiene gate fires:

```
::error::Source-hygiene gate · CRLF detected in tracked source files:
::error::  backend/src/cli/tui/diagnostic-chat-entry.ts (CR=522)
```

What happened: between your local strip and the next `base64 -w0 < file` upload, the file was re-edited (by Edit, by `core.autocrlf=true` on checkout, by the IDE) and CRLF came back. Your `tr` check was on a stale view.

**Detection — verify GitHub-side blob bytes, not local file**:

```bash
NEW_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
gh api "repos/$REPO/contents/$FILE?ref=$NEW_HEAD" --jq '.content' | base64 -d | tr -cd '\r' | wc -c
# must be 0 — what's actually on the remote
```

**Fix workflow — strip, push, verify GitHub-side, then move on**:

```bash
sed -i 's/\r$//' "$FILE"
[ "$(tr -cd '\r' < "$FILE" | wc -c)" -eq 0 ] || { echo "FAIL local"; exit 1; }
# ...push blob, tree, commit, PATCH ref...
sleep 1                                                       # eventual consistency
NEW_HEAD=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha')
REMOTE_CR=$(gh api "repos/$REPO/contents/$FILE?ref=$NEW_HEAD" --jq '.content' | base64 -d | tr -cd '\r' | wc -c)
[ "$REMOTE_CR" -eq 0 ] || { echo "FAIL remote: $REMOTE_CR CR chars"; exit 1; }
```

The remote check is what matters. The source-hygiene gate runs on whatever GitHub serves at PR HEAD; your local file is irrelevant once you've uploaded.

### Trap 3 · Python JSON round-trip mojibakes commit messages on Windows

Building gh-api commit payloads via Python on Git Bash (Windows) → `json.load(open(path))` defaults to cp1252, mangling any non-ASCII (em-dash `—`, middle dot `·`, smart quotes) into mojibake bytes. Pushed commit message renders as `Â·` instead of `·`.

```python
# WRONG — uses platform-default cp1252 on Windows
p = json.load(open(path))
p['tree'] = TREE_SHA
json.dump(p, open(path, 'w'))

# RIGHT — explicit UTF-8 + ensure_ascii=False
p = json.load(open(path, encoding='utf-8'))
p['tree'] = TREE_SHA
json.dump(p, open(path, 'w', encoding='utf-8'), ensure_ascii=False)
```

Or sidestep entirely: keep commit messages ASCII-only when authoring on Windows.

**Detection — verify the commit message rendered correctly server-side**:

```bash
gh api repos/$REPO/git/commits/$COMMIT_SHA --jq '.message' | head -3
# Look for Â·, Ã©, etc. — mojibake gives away the encoding mismatch
```

**Recovery if pushed with mojibake** — re-create the commit ASCII-clean and force-PATCH the branch ref before opening the PR:

```bash
# Edit the JSON to ASCII-only, then:
NEW_COMMIT=$(gh api repos/$REPO/git/commits --input fixed-payload.json --jq '.sha')
gh api repos/$REPO/git/refs/heads/$BRANCH -X PATCH -f sha="$NEW_COMMIT"
gh api repos/$REPO/git/commits/$NEW_COMMIT --jq '.message' | head -3   # verify clean
```

If the PR is already open, the force-PATCH replaces the branch tip; the PR auto-updates.

### Phase 4 · Pre-flight before any Windows push (defensive)

```bash
# 1. Confirm no existing PR/branch covers this work (avoid duplicates)
gh pr list --repo $REPO --state open --search "<file path or symbol>" --limit 5

# 2. Strip CRLF on every file you're about to push
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

## Gotchas

### Don't trust the local file after an editor round-trip

`Edit` tool on Windows can re-inject CRLF. The local `tr` check was correct at strip time; not at upload time.

### Don't force-PATCH without authorization

The recovery flow uses force-PATCH to fix the FIRST commit's branch pin. Only use when the branch is yours alone OR the user authorized it. Otherwise: re-fetch base, add commits as fast-forward.

### Don't keep retrying without checking the actual branch state

The PR-head vs branch-head check is fast and fixes the false sense of "I just retried, it must be fine."

### Don't author non-ASCII commit messages on Windows

Or if you do, use `encoding='utf-8'` + `ensure_ascii=False` everywhere a JSON file touches disk. Easier to keep messages ASCII-clean.

### Don't skip the `sleep 1` before remote verify

GitHub's content API has eventual consistency on contents-by-ref. A `sleep 1` between PATCH and content fetch reduces flakes substantially.

## Invariants consulted

- **Invariant 1 · Trust the remote, not the local** — local checks are necessary but never sufficient.
- **Invariant 2 · Branch existence determines POST vs PATCH** — wrong choice = "Reference already exists" 422.
- **Invariant 3 · Encoding leaks through any JSON round-trip on Windows** — explicit utf-8 everywhere it touches disk.
- **Invariant 4 · PR-head ≠ branch-head means the PR is on stale state** — verify after any retry.

## Seed lessons

1. **"Reference already exists" pins branch to first attempt** · P0 · generic. Looks like idempotent retry; isn't.
2. **Editor round-trip re-injects CRLF post-strip on Windows** · P1 · generic. Verify remote, not local.
3. **Python JSON cp1252 default mangles non-ASCII** · P1 · generic. `encoding='utf-8'` + `ensure_ascii=False`, or stay ASCII-only.
4. **PR-head vs branch-head check catches the silent failure** · P2 · generic. One `gh api` call per side.
5. **Eventual consistency on contents-by-ref** · P2 · generic. `sleep 1` between PATCH and content fetch reduces flakes.

## Integration

- **`./gh-api-push-pr.md`** — companion: the happy-path recipe.
- **`/verify-before-claim`** — "I retried successfully" claim requires PR-head vs branch-head equality + (if Windows) remote-side CRLF=0 check.

## Completeness principle

10/10: PR-head vs branch-head verify after any retry · remote-side CRLF check, not local · ASCII-only commit messages on Windows OR explicit utf-8 in every JSON touch · `sleep 1` before remote-content fetch.

7/10: PR-head vs branch-head verify, but skip remote CRLF check (Windows source-hygiene gate fires repeatedly).

3/10: trust the local file + retry blindly (compounds the failure each time).

**Default: 10/10.** The verifies are 2-3 extra `gh api` calls; the failure mode without them is reviewer-time waste + multi-redo PRs.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version forged from PR #1752 + #1860 + cp1252 mojibake incident.
