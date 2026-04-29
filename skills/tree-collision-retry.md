---
name: tree-collision-retry
namespace: gh-api
version: 0.1.0
description: |
  GitHub's `POST /repos/:owner/:repo/git/trees` endpoint can return
  `422 'tree.sha <sha> is not a valid blob'` when an uploaded blob's
  SHA-1 collides with an existing TREE object's SHA in the repo's
  object database. Git uses the same hash namespace for blobs, trees,
  commits, and tags — collisions across types are rare but real. The
  fix is trivial once recognized: modify the offending file's content
  slightly (add a trailing newline, add a comment line) to get a fresh
  blob SHA, re-upload, retry the tree creation.
allowed-tools:
  - Bash
---

# tree-collision-retry · when a blob SHA collides with a tree object

## Why this exists

Git's object store uses SHA-1 (or SHA-256 in newer repos) for blobs, trees, commits, and tags as a unified namespace. Most of the time you never see a cross-type collision because (a) the hashes are 40 hex chars and (b) the input domains rarely overlap.

But `POST /git/trees` validates that every entry marked `type: blob` actually points to a blob object in the repo. If the SHA you're claiming as a `blob` happens to be an existing TREE object (e.g. an old subdirectory of the repo), the API rejects with `422`:

```
{"message":"tree.sha <sha> is not a valid blob","status":"422"}
```

The blob you just uploaded is real. The blob's bytes are correct. The SHA is correct. But the repo's object database had a tree with the same SHA from a long time ago, and the API enforces the type constraint.

The fix is one line of file edit. Cost: 30 seconds of confusion if you've never seen it before. Cost if you don't recognize the pattern: an hour of debugging the JSON payload, the auth header, the encoding.

## Trigger conditions

You hit this skill when:

- You're pushing files via `gh api repos/.../git/blobs` then `gh api repos/.../git/trees`
- The blob upload returns a clean SHA + size
- The tree creation returns `422` with `tree.sha <sha> is not a valid blob`
- The SHA in the error message matches the blob you just uploaded

## Procedure

### Step 1 · verify the blob actually uploaded

Don't assume the upload succeeded. Confirm the blob exists:

```bash
gh api "repos/$OWNER/$REPO/git/blobs/$BLOB_SHA" --jq '{size, encoding, sha}'
```

Should return a JSON with the size + encoding + sha. If 404, the blob never made it; the tree-creation error is misleading and you have a different bug.

### Step 2 · modify the source file

The cheapest fix is the smallest possible content change that produces a different SHA:

```bash
echo "" >> path/to/file.ext
```

For files where a trailing newline is undesirable (or already present), add a no-op comment in the file's syntax:

```bash
# Python / shell / yaml
echo "# bki" >> file.py

# JavaScript / TypeScript / Java
echo "// bki" >> file.ts

# Markdown — append a non-rendered HTML comment
echo "" >> file.md
echo "<!-- v0.1 -->" >> file.md
```

Anything that makes the file's bytes differ from the previous attempt produces a fresh SHA.

### Step 3 · re-upload + retry

```bash
NEW_BLOB_SHA=$(gh api repos/$OWNER/$REPO/git/blobs \
  -f content="$(base64 < path/to/file.ext)" \
  -f encoding="base64" --jq '.sha')

# Confirm new SHA differs from the colliding one
[ "$NEW_BLOB_SHA" != "$OLD_BLOB_SHA" ] || { echo "FATAL: same SHA"; exit 1; }

# Build the tree with the new blob SHA
# ... rest of the push pipeline
```

The tree creation should now succeed. Continue with commit + ref update.

## When the collision is NOT a SHA-namespace issue

If you keep getting `422` after multiple file edits with verifiably different SHAs, the issue isn't a collision — it's something else:

- **Stale tree cache**: rare but possible if the API is in a degraded state. Wait 30s, retry.
- **Auth scope**: the token doesn't have `repo` scope; the tree-creation endpoint requires write access. Check `gh auth status`.
- **Branch protection on the parent**: some repos forbid tree creation on protected branches via API. Use a feature branch.

The collision case has a specific signature: ONE specific SHA fails consistently, OTHER SHAs (the rest of the tree's entries) succeed. If multiple SHAs fail, it's not a collision.

## Why this works

Git's hash namespace is unified by design — Linus's original design lets you address any object via its SHA without distinguishing types at the lookup layer. The type is recorded INSIDE the object header, not in the SHA. So you can have a blob and a tree with the same SHA in the same repo (vanishingly unlikely with random content; possible with carefully-crafted content; encountered in practice when repo history has many distinct subtree-of-files arrangements).

GitHub's API enforces type-constraints at the request level (`type: "blob"` in the tree-creation payload) but doesn't pre-check the SHA matches that type. The 422 is the type-mismatch surfacing.

Modifying the source content gives you a different blob SHA, dodges the collision. There's no way to "force" the API to accept a colliding SHA — git's design doesn't let you have two objects of different types with the same SHA, so the API's constraint is correct.

## Seed lessons

- **id**: `gh-api-tree-collision-existing-object`
  **scope**: generic
  **pattern**: `gh api git/trees` returns 422 'tree.sha X is not a valid blob' when the blob's SHA collides with an existing tree object's SHA. Git uses the same hash namespace for all object types.
  **evidence**: A 4974-byte TypeScript file's blob SHA collided with a tree object somewhere in the repo's history. Appending a single newline produced a different SHA, retry succeeded.
  **fix**: on '422 not a valid blob' from git/trees, modify the offending file's content trivially (trailing newline, comment line), re-upload, retry. Don't waste time debugging JSON payload — the API is correctly reporting a real type-namespace collision.
