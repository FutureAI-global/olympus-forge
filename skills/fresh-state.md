---
name: fresh-state
namespace: session-lessons
version: 0.1.0
description: |
  Anti-stale-local enforcement. Before editing any file that could be modified by
  another session — shared multi-session files, anything in orch-gated paths,
  anything on a worktree's branch that's behind remote — fetch the file's current
  state from remote and confirm local matches. Prevents silent regressions from
  editing against stale bases.
allowed-tools:
  - Bash
  - Read
  - Grep
  - AskUserQuestion
---

# fresh-state · anti-stale-local enforcement

## Why this exists

On a machine with 25+ git worktrees across a 5.6GB repo, stale local state is the default. A session that reads a local file and plans an edit is, at any moment, >50% likely to be reading state that's ≥1 commit behind remote.

Consequences observed:

- **PRs #1500 / #1502** silently dropped 4 emit calls because the local worktree pre-#1499 still had the older version; the patch, when pushed via GitHub API, effectively reverted #1499's emits.
- **3 stuck CLI processes** (a recent incident) hit a backend at commit `6043856e` from a recent incident — 2+ days stale, missing the a grounding-enforcement fixx grounding stack that was on staging.
- **Agent 3 vs Agent 4 contradiction** (forensic session): Agent 3 read `runner-tool-specs.ts` (VDP-4.2 dead code) as the source when `tool-specs.ts` was the actual wired path. No freshness check would have caught the bad guess.

## Preamble (run first)

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag fresh-state --limit 3 2>/dev/null || true
fi

_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

Fire when the session is about to edit (via `Write`, `Edit`, `Bash sed/awk`, or API-push):

1. **Shared multi-session files** — CLAUDE.md explicitly flags these:
   - `<backend>/services/<harness>/constitution/v1/**`
   - `<backend>/services/<harness>/conversation-runner.service.ts`
   - `<backend>/services/<harness>/conversation-validator.service.ts`
   - `<backend>/services/<harness>/tool-specs.ts`
   - Anything in `<your-schema>.prisma`
   - Anything in `backend/src/services/ford-pts-*`

2. **Files in a worktree that's behind remote** — if `git rev-parse HEAD` in the active worktree differs from `gh api .../git/refs/heads/<branch> --jq .object.sha`, ALL files in that worktree are suspect.

3. **Files referenced in a recent PR** — any file touched in the last 5 PRs on the target branch is likely mid-evolution; treat as shared.

Voice triggers: "check freshness", "fresh head", "is this stale", "fetch before edit".

## Workflow

### Phase 1 · Identify what's being edited

Enumerate every `path` the session is about to Write / Edit / patch via API push. For each:

- Determine the relevant branch (usually `staging`; varies by repo)
- Resolve the repo (`gh repo view --json nameWithOwner`)

### Phase 2 · Compare local to remote

For each file:

```bash
# Get remote SHA for the file's blob
REMOTE_BLOB=$(gh api "repos/<owner>/<repo>/contents/<path>?ref=<branch>" --jq '.sha' 2>/dev/null)

# Get local SHA of the same path
LOCAL_BLOB=$(git -C <worktree> hash-object <path> 2>/dev/null)

# If different, local is stale OR local has unpushed changes
if [ "$REMOTE_BLOB" != "$LOCAL_BLOB" ]; then
  echo "STALE: $path (remote=$REMOTE_BLOB local=$LOCAL_BLOB)"
fi
```

**Interpretation:**
- Remote differs, local unchanged from last pull → **stale**, fetch fresh
- Remote differs, local has unpushed changes → **diverged**, needs merge or rebase
- Same SHA → **fresh**, proceed

### Phase 3 · Worktree sanity

Before editing anything in a worktree:

```bash
# Which worktree is active + is its branch behind?
git -C <cwd> branch --show-current
git -C <cwd> rev-parse HEAD
git -C <cwd> fetch origin <branch> --quiet
git -C <cwd> rev-list --count HEAD..origin/<branch>  # 0 means up-to-date
git worktree list | grep <cwd>

# Detect collision: is any other worktree on the same branch?
git worktree list | awk '{print $NF}' | sort | uniq -c | awk '$1 > 1 {print "COLLISION:", $2}'
```

### Phase 4 · Three paths to proceed

Based on Phase 2 + 3 findings:

**Path A — fetch fresh from remote:**
```bash
mkdir -p /tmp/fresh-state
gh api "repos/<owner>/<repo>/contents/<path>?ref=<branch>" --jq '.content' | base64 -d > /tmp/fresh-state/<basename>
# Edit /tmp/fresh-state/<basename>, then push via API — never copy back to local worktree
```

**Path B — switch to a fresh worktree:**
```bash
cd <main-repo-root>
git fetch origin <branch>
git worktree add /Users/leelee2/Developer/<repo>-<feature> <branch>
# Work from new worktree; never touch the stale one
```

**Path C — explicit override with rationale:**
```
I'm proceeding with the local-stale version because <specific reason>.
Risk: the edit may produce a patch that conflicts with remote HEAD.
Captured as learning: <id> for future aggregator review.
```

Use AskUserQuestion when the path isn't obvious from context.

### Phase 5 · Log the check into learnings.jsonl

After every invocation — regardless of whether staleness was detected — append a lesson:

```json
{
  "id": "sha256-<hash>",
  "ts": "<iso>",
  "session": "<session-name>",
  "skill": "fresh-state",
  "pattern": "pre-edit freshness check for <path>",
  "evidence": "remote=<sha1> local=<sha2> delta=<N commits>",
  "fix": "<path-taken: fetch/switch/override>",
  "severity": "P2",
  "scope": "generic",
  "tags": ["worktree", "<repo>", "<branch>"],
  "user_quote": null,
  "auto_captured": true,
  "related_ids": [],
  "evidence_count": 1
}
```

Over time the aggregator surfaces which files are staleness magnets → candidates for invariant promotion.

## Invariants consulted

- **Invariant 2 · Fetch fresh HEAD before editing shared files** (primary)
- **Invariant 11 · Never touch orch-gated surfaces without green-light**

## Seed lessons (shipped with v0.1)

1. **PR silently reverts prior emits when local worktree is behind** · P0 · generic
   - Evidence: `#1500` / `#1502` dropped 4 `brand.input-history.*` emit calls that #1499 had added, because the worktree's base was pre-#1499
   - Fix: always `gh api contents/<file>?ref=<HEAD>` before editing; use that as base

2. **backend running from stale worktree causes CLI hangs** · P0 · <your-project>
   - Evidence: 3 olympus CLI processes stuck multi-hour against backend at commit `6043856e` (a recent incident, 2+ days stale) missing a server-side-dispatch fix
   - Fix: before starting a backend from a worktree, `git fetch origin staging && git rev-list --count HEAD..origin/staging` must be 0

3. **wrong-file-picked when duplicate source paths exist** · P1 · generic
   - Evidence: forensic agent read `runner-tool-specs.ts` (VDP-4.2 dead) instead of `tool-specs.ts` (wired)
   - Fix: when multiple candidate files could be "the source", grep for the actual `import ... from "./tool-specs"` site first; trust imports over file names

4. **worktree collision on shared branch** · P1 · generic
   - Evidence: multiple worktrees checked out at `staging` at once → one session's uncommitted edit becomes another session's invisible base
   - Fix: `git worktree list | awk '{print $NF}' | sort | uniq -c | awk '$1 > 1'` — never allow >1 worktree on the same branch

5. **assumed staging was current without checking** · P1 · generic
   - Evidence: agent-produced findings referenced staging at one SHA while the actual staging was several commits ahead
   - Fix: every fetch cites the exact SHA; compare against that specific SHA in later writes

6. **local `.git/index.lock` from a dead git process blocks all checks** · P2 · generic
   - Evidence: `git status` hangs indefinitely when a prior git process crashed
   - Fix: `pgrep -fl git` first; if no live git, `rm -f .git/index.lock`

## Integration points

- **`/api-push`** — after fresh-state confirms local matches remote, api-push rebuilds the commit against the exact SHA (no ghost-deletion)
- **`/verify-before-claim`** — claim "I edited file X" requires a fresh-state check output as evidence
- **`/post-mortem`** — any staleness-caused incident (silent revert, diverged worktree, missing a grounding-enforcement fixx on a backend) becomes a lesson

## Completeness Principle

Completeness 10/10: check every file + every worktree + every branch before any edit.
Completeness 7/10: check the high-risk files (orch-gated, shared multi-session) + worktree behind-status.
Completeness 3/10: skip the check, trust the local, ship the patch.

**Default target: 10/10** for orch-gated files. **7/10** for all other files. The check is 5 seconds; the cost of silent regression is hours to debug.

## Changelog

- **v0.1 (a recent incident) · a specific session** · Initial version. 6 seed lessons. 5-phase workflow including worktree collision detection.
