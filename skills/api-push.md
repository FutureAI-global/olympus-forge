---
name: api-push
namespace: session-lessons
version: 0.1.0
description: |
  Canonical GitHub-API push workflow for large repos where `git push` hangs.
  Enforces CRLF preservation, base-SHA freshness, and the blob→tree→commit→ref
  pattern. Prevents ghost-deletion diffs from `gh pr edit --base` on squash-merged
  parents.
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

# api-push · canonical GitHub API push workflow

## Why this exists

- `git push` on a 5.6GB repo hangs 10+ minutes packing objects, blocking other sessions.
- `gh pr edit --base <new>` produces 20k-line ghost-deletion diffs when the original parent was squash-merged. Burned on #1518 / #1519 (a recent incident).
- LF-written patches against CRLF source make every line show as "changed" in the diff. Caught my first PR B push.

This skill is the enforced recipe.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag api-push --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

- User asks to "push", "commit + push", "create a PR", "open a PR"
- Session is about to run `git push` on a repo >1GB
- PR needs a follow-up commit on an existing branch
- PR base branch is being changed

Voice triggers: "push via api", "api push", "github push", "create PR safely".

## Workflow

### Phase 1 · Determine parent SHA

```bash
# Target branch (usually `staging` or `main` per your repo's convention)
BRANCH=staging   # or from user context

# CURRENT parent — never assume, always fetch fresh
BASE_SHA=$(gh api "repos/$REPO/git/refs/heads/$BRANCH" --jq '.object.sha')
echo "Base: $BASE_SHA"
```

**Gotcha:** if the PR is a follow-up (updating an existing branch), parent is the branch's last commit SHA, not the base branch HEAD.

### Phase 2 · Preserve line endings

```bash
# Detect source file line-ending
file <path>
# If "CRLF line terminators" — keep CRLF on patch:
python3 -c "
c = open('<path>').read()
c = c.replace('\r\n','\n').replace('\n','\r\n')
open('<path>','w',newline='').write(c)
"
```

### Phase 3 · Build + push via API

```python
#!/usr/bin/env python3
"""Canonical API push. Based on the gh api recipe in CLAUDE.md."""
import base64, json, subprocess, sys

REPO = "<your-org>/<your-repo>"
PARENT_SHA = "..."  # from Phase 1
BRANCH = "feat/<name>"

FILES = {
    "path/in/repo.ts": "/tmp/local/file.ts",
    # ...
}

COMMIT_MSG = """feat(area): one-line summary

Body explaining why.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"""

def api(method, path, body=None):
    args = ["gh", "api", f"repos/{REPO}/{path}", "-X", method]
    if body is not None:
        args.extend(["--input", "-"])
    r = subprocess.run(args, capture_output=True, text=True,
                       input=json.dumps(body) if body else None)
    if r.returncode != 0:
        print(f"API {method} {path} failed:", r.stderr, file=sys.stderr)
        sys.exit(r.returncode)
    return json.loads(r.stdout) if r.stdout.strip() else {}

def main():
    tree_entries = []
    for remote, local in FILES.items():
        with open(local, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        blob = api("POST", "git/blobs", {"content": b64, "encoding": "base64"})
        tree_entries.append({"path": remote, "mode": "100644",
                             "type": "blob", "sha": blob["sha"]})
    tree = api("POST", "git/trees", {"base_tree": PARENT_SHA, "tree": tree_entries})
    commit = api("POST", "git/commits", {
        "message": COMMIT_MSG, "tree": tree["sha"], "parents": [PARENT_SHA]
    })
    print(f"commit: {commit['sha']}")
    # New branch:
    api("POST", "git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": commit["sha"]})
    # OR follow-up on existing branch:
    # api("PATCH", f"git/refs/heads/{BRANCH}", {"sha": commit["sha"]})
    print(f"branch: {BRANCH}")

if __name__ == "__main__": main()
```

### Phase 4 · Open the PR

```bash
gh pr create --repo $REPO --base $BRANCH --head $NEW_BRANCH \
  --title "feat(area): summary" \
  --body "$(cat <<'EOF'
<PR body>

🤖 Session <name> · lift-off · PR <N>/M
EOF
)"
```

### Phase 5 · Verify the diff is clean

After create, check for ghost-deletion signatures:

```bash
gh pr view <num> --json additions,deletions,changedFiles --jq .
```

Expected:
- `additions` ≈ LOC you intended
- `deletions` ≈ 0 (for additive PRs) OR matches your removed files

If `deletions` is in the thousands on a small PR, STOP — that's a ghost-deletion signature. See "Recovery" below.

## Gotchas

### Ghost-deletion diff recovery

If you see the phantom-deletion shape:

```bash
# Delete the bad branch
gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH"
# Wait 2 seconds, then push again with a fresh parent SHA
# (parent = current remote HEAD, not a stale SHA)
```

### Never use `gh pr edit --base`

Instead, delete + recreate the branch with a new parent:

```bash
# WRONG:
gh pr edit 1234 --base staging

# RIGHT:
# 1. Fetch current staging SHA
# 2. Delete old branch
# 3. Create fresh commit parented on new SHA
# 4. Push to same branch name — PR auto-updates
```

### `git push` is banned on large repos

```bash
# NEVER on <your-repo> (5.6GB)
git push origin feat/x

# Use the API recipe above
```

## Invariants consulted

- **Invariant 3 · Never `git push` on repos >1GB**
- **Invariant 4 · Preserve line endings on API push**
- **Invariant 5 · Never `gh pr edit --base` on squash-merged parents**

## Seed lessons

1. **`gh pr edit --base` produces 20k ghost-deletions** · P0 · generic
2. **LF patches against CRLF source = every line changed** · P2 · generic
3. **`git push` on 5.6GB <your-repo> hangs 10+ min** · P0 · <your-project>
4. **Stale parent SHA yields silent revert of newer commits** · P0 · generic
5. **Follow-up commit on open PR requires `PATCH refs/heads/<branch>`, not POST** · P1 · generic
6. **Delete+recreate is the only safe retarget** · P0 · generic
7. **File deletion via API push: use `"sha": null` in the tree entry** · P2 · generic

## Integration

- **`/fresh-state`** — must run FIRST to confirm local matches remote before push
- **`/verify-before-claim`** — "PR opened" claim requires the PR URL in the same turn

## Completeness Principle

10/10: follow the full recipe including CRLF preservation + base-SHA fresh-fetch + diff verification.
7/10: skip the diff-verification (risk: ship ghost-deletion without noticing).
3/10: use `git push` anyway — wait 10 minutes, block other sessions.

**Default: 10/10.** The cost of the full recipe is ~30 seconds of script setup; the cost of `git push` is 10 minutes + session collision.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version. 7 seed lessons + ghost-deletion recovery path.
