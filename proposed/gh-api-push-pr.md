---
name: gh-api-push-pr
namespace: session-lessons
version: 0.1.0
description: |
  Push commits + open PRs via GitHub API blob+tree+commit+ref recipe.
  Bypasses `git push` hangs on large repos, handles JSON-via-stdin for
  large files, branch-create vs branch-update branching, and base_tree
  inheritance so unchanged files aren't dropped.
allowed-tools:
  - Bash
provenance: |
  forged 2026-04-29 from the canonical CLAUDE.md recipe + corner cases
  hit on PR #1763 (argv-too-long, multi-line commit JSON parse errors).
  Step 0 pre-push safety check added 2026-04-28 after PR #1493 + #1860
  required force-push recovery.
---

# gh-api-push-pr · push via API, never `git push` on the big repo

## Why this exists

- `git push` on a 5+ GB repo hangs 10+ minutes packing objects. The GitHub API uploads only the changed blobs in seconds.
- Naive shape — `gh api -f content="$(base64 < file)"` — fails with `Argument list too long` for files past ~131 KB on Linux (less on macOS).
- Naive commit shape — `printf` with embedded newlines/quotes — fails with `Problems parsing JSON` because `\n` doesn't expand the way you expect and `$` / backticks are shell-substituted.
- Tree-without-`base_tree` shape DELETES every file not listed in your spec. Worst possible API mistake — looks like a successful push and silently drops half the repo.
- Right shape: the recipe below, in this order, every time. Plus the Step 0 pre-push safety check that catches CRLF/LF mismatches and stale-copy reverts before they hit the wire.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag gh-api-push --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- About to run `git push` on a 5+ GB working tree.
- Using `gh api repos/.../git/blobs` with a >100 KB file.
- Building a multi-line commit message.
- Creating a branch via `gh api`.
- Updating an existing branch ref (PATCH, not POST).

Voice triggers: "push the PR", "open the PR", "git push hangs", "blob upload too long", "commit message too long".

## Workflow

### Phase 0 · Pre-push safety check (MANDATORY, added 2026-04-28)

Run `~/.claude/scripts/gh-blob-push-safe.sh` against every file BEFORE building blobs. Catches:

- **Stale-copy reverts** (PR #1493 / #1860 shape — local lags upstream, push silently deletes sibling changes).
- **CRLF/LF mismatches** (PR #1860 schema.prisma — 2-line edit explodes to +6626 lines).
- **CRLF-on-local** (source-hygiene gate REJECTS).

```bash
for file in "${FILES[@]}"; do
  ~/.claude/scripts/gh-blob-push-safe.sh "$REPO" "$BASE" "$file" || exit 1
done
```

Skipping is what produced PR #1493 (-126 silent regression) and #1860 (+7017 inflation). Both required force-push recovery. Pass `--force` only after manual review.

### Phase 1 · Setup variables, get base SHA + base tree

```bash
REPO="<org>/<repo>"
BRANCH="<type>/<short-desc>"   # feat/, fix/, chore/, refactor/, docs/
BASE="<default-branch>"
FILES=( "path/to/file1.ts" "path/to/file2.ts" )

BASE_SHA=$(gh api repos/$REPO/git/ref/heads/$BASE --jq '.object.sha')
BASE_TREE=$(gh api repos/$REPO/git/commits/$BASE_SHA --jq '.tree.sha')
```

### Phase 2 · Upload each file as a blob (stdin JSON, never argv)

```bash
upload_blob() {
  local file="$1"
  printf '{"content":"%s","encoding":"base64"}' "$(base64 -w0 < "$file")" | \
    gh api repos/$REPO/git/blobs --input - --jq '.sha'
}

declare -A BLOBS
for file in "${FILES[@]}"; do
  BLOBS[$file]=$(upload_blob "$file")
  echo "  $file -> ${BLOBS[$file]}"
done
```

Why stdin: `-f content=...` puts the value on argv. Base64-encoded source files exceed `MAX_ARG_STRLEN` (~131 KB Linux, less macOS). `--input -` reads from stdin, no argv limit.

### Phase 3 · Build tree spec WITH base_tree inheritance

```bash
TREE_JSON='['
for file in "${FILES[@]}"; do
  TREE_JSON+="{\"path\":\"$file\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"${BLOBS[$file]}\"},"
done
TREE_JSON="${TREE_JSON%,}]"

NEW_TREE=$(printf '{"base_tree":"%s","tree":%s}' "$BASE_TREE" "$TREE_JSON" | \
  gh api repos/$REPO/git/trees --input - --jq '.sha')
```

**Critical:** `base_tree` makes files NOT in your `FILES` array inherit from `$BASE_TREE`. Without it, your tree spec replaces the entire tree — every other file gets DELETED.

### Phase 4 · Build commit JSON via Node (multi-line safe)

```bash
COMMIT_PAYLOAD=$(node -e '
process.stdout.write(JSON.stringify({
  message: [
    "fix(cli): ...",
    "",
    "Body paragraph here. Single-quoted heredocs in shell are tricky;",
    "build the JSON in Node where escaping is automatic.",
    "",
    "Co-Authored-By: Claude <noreply@anthropic.com>"
  ].join("\n"),
  tree: process.argv[1],
  parents: [process.argv[2]],
}));
' "$NEW_TREE" "$BASE_SHA")

NEW_COMMIT=$(echo "$COMMIT_PAYLOAD" | gh api repos/$REPO/git/commits --input - --jq '.sha')
```

Why Node: commit messages have newlines (printf's `\n` embeds literal `\n`, not a newline), backticks (shell-substituted), `$` (shell expansion), quotes (escape hell). `JSON.stringify` handles all of it.

### Phase 5a · Branch is NEW: POST the ref

```bash
gh api repos/$REPO/git/refs \
  -f ref="refs/heads/$BRANCH" \
  -f sha="$NEW_COMMIT" \
  --jq '.ref'
```

### Phase 5b · Branch already EXISTS (follow-up commit): PATCH the ref

```bash
gh api repos/$REPO/git/refs/heads/$BRANCH -X PATCH \
  -f sha="$NEW_COMMIT" \
  --jq '.object.sha'
```

`Update is not a fast forward` (HTTP 422) means another session pushed between your `BASE_SHA` fetch and your push. Re-fetch `BASE_SHA`, rebuild commit, retry. Don't force-push without authorization.

### Phase 6 · Open the PR

```bash
gh pr create --repo $REPO --head "$BRANCH" --base $BASE \
  --title "fix(cli): ..." --body "$(cat <<'EOF'
## Summary
- Bullet 1
- Bullet 2

## Verification
- ...
EOF
)"
```

## Gotchas

### Argv-too-long failure (PR #1763)

```bash
# WRONG
BLOB=$(gh api repos/$REPO/git/blobs \
  -f content="$(base64 -w0 < src/cli/conversation-client.ts)" \
  -f encoding="base64" --jq '.sha')
# -> "Argument list too long" for files >~131 KB
```

Fix: use `--input -` with stdin JSON.

### JSON parse failure on multi-line commit (PR #1763)

```bash
# WRONG
NEW_COMMIT=$(printf '{"message":"%s","tree":"%s","parents":["%s"]}' \
  "fix(cli): foo

multi-line body" "$TREE" "$PARENT" | \
  gh api repos/$REPO/git/commits --input - --jq '.sha')
# -> "Problems parsing JSON" (newline not escaped, quotes mangled)
```

Fix: build via `node -e` + `JSON.stringify`.

### Tree without base_tree DELETES every other file

```bash
# WRONG
TREE_JSON='[{"path":"backend/foo.ts","sha":"abc"}]'
NEW_TREE=$(printf '{"tree":%s}' "$TREE_JSON" | \
  gh api repos/$REPO/git/trees --input - --jq '.sha')
# -> all OTHER files deleted from this tree
```

Fix: always include `"base_tree":"$BASE_TREE"`.

### Force-push without authorization

`-X PATCH` with a sha that's not a fast-forward is destructive — it overwrites another session's commits. Use only when:
- The user explicitly authorized the force-push.
- You confirmed the overwritten commits are recoverable.
- You're cleaning up your own malformed commit, not someone else's.

If unsure: re-fetch + add commits as fast-forward. Always recoverable.

### File deletion via tree spec uses `null` SHA

To DELETE a file in the tree: `{"path":"...","mode":"100644","type":"blob","sha":null}`. Note `null`, not empty string.

To ADD a new file: same shape as modify; the API doesn't distinguish.

To RENAME: delete old path + add new path in the same tree spec.

## Invariants consulted

- **Invariant 1 · stdin for blob uploads, always** — habit-form it; argv limits surface unpredictably.
- **Invariant 2 · base_tree always present** — without it, you delete the rest of the repo.
- **Invariant 3 · Node + JSON.stringify for multi-line commit messages** — printf-escaping is a debugging tax.
- **Invariant 4 · POST creates, PATCH updates** — branch existence determines which one.
- **Invariant 5 · Force-push requires authorization** — overwrites another session's work otherwise.

## Seed lessons

1. **`-f content=...` with large base64 blob hits argv limit** · P0 · generic. `Argument list too long` at >~131 KB on Linux.
2. **`base_tree` omission deletes all other files** · P0 · generic. Looks like a successful push; tree silently truncated.
3. **`printf` for multi-line commit messages = JSON parse hell** · P1 · generic. Use Node's JSON.stringify.
4. **POST creates ref; PATCH updates ref** · P1 · generic. 422 on POST means branch already exists.
5. **Step 0 pre-push safety wrapper catches CRLF + stale-copy** · P1 · scoped (this codebase). Saves hours of force-push recovery.

## Integration

- **`./gh-api-push-retry-traps.md`** — companion: what to do when a push partially fails and you retry.
- **`/verify-before-claim`** — "PR is open" claim requires the PR URL pasted, AND a `gh pr view --json mergeable` confirmation.

## Completeness principle

10/10: Step 0 safety check · stdin blob upload · `base_tree` always present · Node-built commit JSON · POST/PATCH branch-existence branching.

7/10: skip Step 0 (CRLF and stale-copy slip through; force-push recovery later).

3/10: `git push` on a 5+ GB repo (10+ minute hang; might also CRLF-corrupt).

**Default: 10/10.** The recipe is ~30 LOC; failure modes range from "PR is wrong" (annoying) to "you deleted every other file" (catastrophic).

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version. Step 0 pre-push wrapper from 2026-04-28 incidents. Body of recipe stable since PR #1763 (2026 · earlier).
