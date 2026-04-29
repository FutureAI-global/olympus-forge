---
name: gh-api-push-pr
namespace: session-lessons
version: 0.1.0
description: |
  Extension to `api-push` for the corner cases that hit on real pushes:
  large-payload escape via JSON-on-stdin (avoids Windows MSYS2 argv limit),
  branch-update vs branch-create branching with PATCH-on-422 retry,
  base_tree inheritance so unlisted files are not silently deleted,
  and multi-line commit-message construction that does not mojibake.
  Pre-push safety check is mandatory before any blob upload.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a generic large-payload + multi-author-branch push incident
---

# gh-api-push-pr · large-payload, multi-author, base-tree-safe extension to api-push

## Why this exists

`api-push` covers the canonical blob -> tree -> commit -> ref recipe. This skill is the
hardened follow-on for the corner cases that surface on real pushes:

1. `Argument list too long` when `gh api -f content="$(base64 < file)"` exceeds the platform argv limit (notably Windows MSYS2 argv-limit on files larger than roughly 30 KB; Linux MAX_ARG_STRLEN is around 131 KB; macOS is smaller).
2. JSON parse errors when commit messages have embedded newlines, quotes, backticks, or `$`.
3. Silent deletion of every file not listed in the tree, when `base_tree` is omitted.
4. `Update is not a fast forward` (HTTP 422) when another session pushed to the same branch between your base-SHA fetch and your push.
5. Mojibake in commit messages when Python on a Windows shell defaults to cp1252 instead of UTF-8.

Apply this skill on top of `api-push` whenever any of those conditions can apply.

## Relationship to api-push

`api-push` is the foundation; this skill is the extension.

- `api-push` defines the four-API-call sequence and the line-ending preservation rule.
- This skill adds: stdin-only blob upload, branch-create vs branch-update PATCH branching, base_tree inheritance enforcement, Node-built commit JSON, fast-forward-fail retry protocol, and a mandatory pre-push safety check.
- Net-new content: the JSON-via-stdin escape, the Windows MSYS2 argv-limit notes, the PATCH-on-422 retry, and the file-rename / file-delete tree-entry shapes.

If you only need the happy-path recipe, use `api-push`. If you are pushing on Windows, pushing files larger than ~30 KB, pushing follow-up commits to an existing branch, or pushing with a multi-line commit body, route through this skill.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag gh-api --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. About to push commits or open a PR on a large monorepo (>5 GB) where `git push` is banned.
2. About to call `gh api repos/.../git/blobs` with a file larger than ~30 KB.
3. About to build a multi-line commit message (newlines, quotes, backticks, or `$`).
4. About to create a branch via `gh api git/refs` that may already exist.
5. About to update an existing branch ref (follow-up commit on an open PR).
6. Pushing from Windows / MSYS2 / Git Bash where argv limits are tighter.

Voice triggers: "push via api with body", "follow-up commit on existing branch", "push large file via gh api", "rebuild branch ref".

## Workflow

### Phase 1 - Pre-push safety check (MANDATORY)

Before any blob upload, run a pre-push safety check against every file in `FILES[]`. The check catches:

- Stale-copy reverts (local lags base, push silently deletes sibling changes).
- CRLF / LF mismatches (small edit explodes into thousand-line diffs).
- CRLF on local source files (source-hygiene gate REJECTS).

```bash
for file in "${FILES[@]}"; do
  ~/.claude/scripts/gh-blob-push-safe.sh "$REPO" "$BASE" "$file" || exit 1
done
```

The script exits non-zero on any problem with a diagnostic naming the fix. Skipping this step is what produces silent reverts and diff inflation. Re-run with `--force` only after manual review of the warnings.

### Phase 2 - Get base SHA + base tree

```bash
REPO="<owner>/<repo>"
BRANCH="<type>/<short-desc>"
BASE="staging"
FILES=( "<path/in/repo>" )

BASE_SHA=$(gh api "repos/$REPO/git/ref/heads/$BASE" --jq '.object.sha')
BASE_TREE=$(gh api "repos/$REPO/git/commits/$BASE_SHA" --jq '.tree.sha')
```

### Phase 3 - Upload each file as a blob via stdin JSON

```bash
upload_blob() {
  local file="$1"
  printf '{"content":"%s","encoding":"base64"}' "$(base64 -w0 < "$file")" | \
    gh api "repos/$REPO/git/blobs" --input - --jq '.sha'
}

declare -A BLOBS
for file in "${FILES[@]}"; do
  BLOBS[$file]=$(upload_blob "$file")
  echo "  $file -> ${BLOBS[$file]}"
done
```

Why stdin, not `-f content=...`: the `-f` form passes the value as a CLI argv arg. Base64-encoded source files routinely exceed the platform argv limit (Windows MSYS2 around 30 KB, Linux around 131 KB, macOS smaller). `--input -` reads from stdin, no argv limit.

### Phase 4 - Build the tree spec with base_tree inheritance

```bash
TREE_JSON='['
for file in "${FILES[@]}"; do
  TREE_JSON+="{\"path\":\"$file\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"${BLOBS[$file]}\"},"
done
TREE_JSON="${TREE_JSON%,}]"

NEW_TREE=$(printf '{"base_tree":"%s","tree":%s}' "$BASE_TREE" "$TREE_JSON" | \
  gh api "repos/$REPO/git/trees" --input - --jq '.sha')
```

Critical: `base_tree` ensures files NOT in your `FILES` array inherit from `$BASE_TREE`. Without it, your tree spec replaces the entire tree, and files you did not list get DELETED. This is the single most catastrophic API mistake.

Tree-entry shapes for non-modify operations:
- DELETE a file: `{"path":"...","mode":"100644","type":"blob","sha":null}`
- ADD a file: same as modify; the API does not distinguish "new" from "modified."
- RENAME: delete old path + add new path in the same tree spec.

### Phase 5 - Build commit JSON via Node (multi-line safe)

```bash
COMMIT_PAYLOAD=$(node -e '
process.stdout.write(JSON.stringify({
  message: [
    "fix(area): one-line summary",
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

NEW_COMMIT=$(echo "$COMMIT_PAYLOAD" | gh api "repos/$REPO/git/commits" --input - --jq '.sha')
```

Why Node, not `printf`: commit messages frequently contain newlines (printf needs literal escapes), backticks (shell substitutes them), `$` (shell expansion), and quotes (escape hell). Node's `JSON.stringify` handles all of it correctly.

Alternative on platforms without Node: write the JSON via Python writing UTF-8 to a tempfile, then `--input <file>`. Always pass `encoding='utf-8'` and `ensure_ascii=False` on Windows, or non-ASCII bytes mojibake to cp1252.

### Phase 6a - Branch is NEW: create the ref

```bash
gh api "repos/$REPO/git/refs" \
  -f ref="refs/heads/$BRANCH" \
  -f sha="$NEW_COMMIT" \
  --jq '.ref'
```

### Phase 6b - Branch already EXISTS (follow-up commit): PATCH the ref

```bash
gh api "repos/$REPO/git/refs/heads/$BRANCH" -X PATCH \
  -f sha="$NEW_COMMIT" \
  --jq '.object.sha'
```

Common pitfall: `Update is not a fast forward` (HTTP 422) means another session pushed to the same branch between your `BASE_SHA` fetch and your push. Re-fetch `BASE_SHA`, rebuild commit, retry. Never force-push without explicit user authorization.

### Phase 7 - Open the PR

```bash
gh pr create --repo "$REPO" --head "$BRANCH" --base "$BASE" \
  --title "fix(area): summary" --body "$(cat <<'EOF'
## Summary

- Bullet 1

## Verification

- ...

Generated with Claude Code
EOF
)"
```

For PR bodies with the same multi-line escaping issues, use the Node JSON pattern instead of a heredoc.

## What NOT to do

1. Do not pass `-f content="$(base64 < file)"` for blob upload. Always stdin.
2. Do not omit `base_tree` from the tree-create call. Files not listed get deleted.
3. Do not `printf` a multi-line commit message. Use Node, or Python writing UTF-8 with `ensure_ascii=False`, or a tempfile.
4. Do not force-push (`-f force=true`) without explicit user authorization. Re-fetch + fast-forward instead.
5. Do not POST to `git/refs` for a branch that already exists. Use `PATCH refs/heads/<branch>`.

## Seed lessons

### Lesson 1 - Argument list too long on blob upload via -f content

Pushing a single source file with `gh api git/blobs -f content="$(base64 -w0 < file)" -f encoding=base64` fails with `Argument list too long` on Windows MSYS2 for files past roughly 30 KB. The fix is to switch to stdin JSON: `printf '{"content":"%s","encoding":"base64"}' "$(base64 -w0 < file)" | gh api git/blobs --input -`. Habit-form stdin even on small files; the day you forget on a 200 KB file, you debug for ten minutes.

### Lesson 2 - JSON parse failure on multi-line commit message via printf

Building a commit JSON via `printf '{"message":"%s",...}' "$msg"` fails parse when `$msg` has embedded newlines, quotes, backticks, or `$`. Symptom: GitHub returns `Problems parsing JSON` or accepts the message but renders it with literal `\n` instead of newlines. Fix: build the JSON via Node `JSON.stringify` or Python `json.dumps`. Both auto-escape correctly.

### Lesson 3 - Tree without base_tree silently deletes every unlisted file

Calling `gh api git/trees` with `{"tree":[<your files>]}` and no `base_tree` builds a tree containing ONLY your listed files. Every other file in the repo is absent, which the commit interprets as DELETED. The PR diff explodes to thousands of deletions. Always pass `{"base_tree":"<base-tree-sha>","tree":[...]}` so unlisted files inherit.

### Lesson 4 - Update is not a fast forward on retry

Two sessions pushing to the same feature branch race: session A fetches base SHA X, builds commit, pushes; session B (with the same stale base SHA X) tries to PATCH and gets HTTP 422 `Update is not a fast forward`. The fix is never force-push. Re-fetch `BASE_SHA`, rebuild your commit with the NEW base as parent, retry the PATCH. Recoverable in seconds; force-push silently overwrites the other session's work.

### Lesson 5 - Mojibake in commit message from Python on Windows

Building a commit JSON in Python on Git Bash with `json.load(open(path))` defaults to cp1252 on Windows. Non-ASCII bytes in the message (smart quotes, middle dots, accented letters) get re-encoded as mojibake. The pushed commit renders as `A.` instead of the intended character. Fix: always pass `encoding='utf-8'` to `open()` and `ensure_ascii=False` to `json.dump`, or keep commit messages strict ASCII when authoring on Windows.

## Invariants consulted

- `Invariant 3 - Never git push on repos >1 GB` - this skill is one of the executable forms
- `Invariant 4 - Preserve line endings on API push` - the pre-push safety check enforces this
- `Invariant 1 - Run the check before claiming` - verify the PR diff after push, do not claim "pushed" without `gh pr view`

## Integration points

- Pairs with `api-push` - existing canonical for the four-API-call recipe; this skill adds the corner-case hardening
- Pairs with `gh-api-push-retry-traps` - what to do when the push partially fails and you have to retry
- Pairs with `gh-api-emergency-fixforward` - when a successful push leaves a base branch broken because it imports from an unmerged sibling PR
- Pairs with `verify-before-claim` - after push, run `gh pr view --json additions,deletions,changedFiles` and cite the numbers before claiming "pushed clean"
- Pairs with `fresh-state` - run BEFORE this skill to confirm local matches remote

## Completeness principle

10/10: pre-push safety check + stdin blob upload + base_tree inheritance + Node-built commit JSON + branch-existence-aware ref op + post-push diff verification.
7/10: skip the post-push diff verification (risk: ship a base_tree omission or CRLF inflation without noticing).
3/10: skip the pre-push safety check and use `-f content=...` for blobs (risk: argv-limit failure mid-push, silent revert, source-hygiene gate failure).

Default: 10/10. The full recipe costs ~30 seconds of script setup; the failure modes cost hours of force-push recovery and reviewer round-trips.

## Changelog

- v0.1.0 (2026-04-29) - initial skill from session-lessons. Forged from a generic large-payload + multi-author-branch push incident on a large monorepo (>5 GB) running on Windows MSYS2.
