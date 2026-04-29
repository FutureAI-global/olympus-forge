---
name: nextjs-route-group-marketing-migration
namespace: session-lessons
version: 0.1.0
description: |
  Recipe for migrating a Next.js App Router subtree (e.g. `/<feature>/*`) to
  root URLs (e.g. `/`, `/pricing`) without breaking existing root pages or
  auth-gated routes. Encodes the `(marketing)` route group plus
  `_archive/old-marketing/` plus href-rewrite-regex pattern, and the
  staying-routes negative lookahead that prevents accidentally rewriting
  deferred auxiliary URLs. Forged from a marketing-site root migration.
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
provenance: forged 2026-04-29 from a marketing-site migration that moved a feature subtree to root URLs while keeping auxiliary routes at the feature path; rewrote hrefs across nav, footer, and per-page Links in a single atomic API push
---

# nextjs-route-group-marketing-migration · move a subtree to root URLs without collisions

## Why this exists

When a marketing redesign lives at `/<feature>/*` and needs to take over root URLs (`/`, `/pricing`, `/careers`), the move has three failure modes:

1. Route collisions at root. Existing `/pricing` page and the new one both resolve.
2. Href-rewrite over-reach. Regex rewrites `/<feature>/customers` to `/customers` even though `customers` is a deferred page that stays at `/<feature>/`.
3. Double-rendered nav/footer. Root `layout.tsx` already mounts a header; the new `(marketing)/layout.tsx` mounts another.

The canonical path:

1. Create a `(marketing)/` route group. Next.js parens-wrapped dirs do not appear in URLs but still organize files.
2. Place new pages inside `(marketing)/` so they resolve to root URLs.
3. Archive existing root collisions to `_archive/old-marketing/<path>` (preserve content, do not delete).
4. Update hrefs in the moved components/pages to point to root URLs, with an explicit STAYING_ROUTES allowlist.

This is conventionally a 4-7 file move plus 5-15 href edits across nav, footer, and per-page Links.

## Preamble (run first)

```bash
# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag route-group-migration --limit 3 2>/dev/null || true
fi

# Resolve sibling worktrees that may hold fresher source content
git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}'
```

## Trigger conditions

Fire this skill when about to:

1. Migrate a Next.js subtree to different URL paths
2. Read a coord post that says "move /<feature>/* to /*"
3. Plan a marketing-site reorg where new routes collide with existing root pages
4. Set up a `(marketing)` or `(landing)` route group

Voice triggers: "move feature to root", "marketing migration", "route group reshuffle".

## Workflow

### Phase 1 · Map collisions BEFORE moving

```bash
# Identify which root URLs the new pages would collide with
for d in pricing careers blog enterprise company contact ; do
  if [ -d "src/app/$d" ] ; then
    echo "$d/  EXISTS at root, archive needed"
  else
    echo "$d/  ABSENT at root, just move"
  fi
done
```

This determines which files go to `_archive/old-marketing/` (collisions) vs which routes are net-new (just move into `(marketing)/`).

### Phase 2 · Build the tree spec atomically

Use a single API push that combines:

- New `(marketing)/` files (with edited hrefs)
- `_archive/old-marketing/` files (existing content, just relocated)
- Deletions of the original root collisions (`sha=null` in tree spec)

Do not split into multiple PRs. Interim states leave 404s or duplicate routes.

### Phase 3 · Href-rewrite regex with explicit allowlist

Critical: you may be moving SOME routes to root but keeping OTHERS at `/<feature>/*` (auxiliary pages, deferred for a later move). The regex must distinguish.

```python
MOVING_ROUTES = ["product", "pricing", "company", "careers", "contact"]
STAYING_ROUTES = ["blog", "customers", "diagnose", "enterprise"]

# Routes that move to root: /<feature>/<route>  ->  /<route>
for route in MOVING_ROUTES:
    text = re.compile(rf"/<feature>/{re.escape(route)}\b").sub(f"/{route}", text)

# Bare /<feature>  ->  / (followed by ", #, end-of-line, or whitespace)
# Negative lookahead avoids /<feature>/(staying-route)
staying_alt = "|".join(STAYING_ROUTES)
text = re.compile(rf"/<feature>(?!/(?:{staying_alt})\b)(?=[\"#\s)])").sub("/", text)
```

The negative lookahead on `STAYING_ROUTES` is critical. Without it, you accidentally rewrite `/<feature>/customers` to `/customers` even though customers is a deferred page that stays at `/<feature>/`.

### Phase 4 · COPY auxiliary `_components/` rather than MOVE

If the deferred `/<feature>/{auxiliary}` pages still need the components, COPY components to `(marketing)/_components/` instead of moving. The duplication is intentional and short-lived; cleanup happens when the auxiliary pages also move in a follow-up PR.

```python
# Tree spec: same blob SHAs at TWO paths
tree.append({"path": "src/app/(marketing)/_components/<NavComponent>.tsx", "sha": NAV_BLOB})
tree.append({"path": "src/app/<feature>/_components/<NavComponent>.tsx", "sha": NAV_BLOB})
```

Both URLs (`/` AND `/<feature>/`) render with the same nav. Hrefs in the nav point to root URLs in both cases (because the goal is to drive users to the new root URLs regardless of where they entered).

### Phase 5 · Verify root layout.tsx will not double-render

Check `src/app/layout.tsx` BEFORE assuming the `(marketing)/layout.tsx` can nest cleanly. If root layout imports a Nav, Header, or Footer, you get double-rendered headers.

```bash
# rg / Grep tool: import patterns in root layout
grep -E "import.*Nav|import.*Header|import.*Footer" src/app/layout.tsx
# If non-empty: scope root layout to non-marketing route group, OR remove
# nav/footer from root layout if it's only used by marketing routes
```

### Phase 6 · Verify auth-gated routes still resolve

`(auth)/*` and `[orgSlug]/*` (or whatever your auth-gated convention is) use a different layout. The `(marketing)/layout.tsx` does not apply to them. Verify after migration on a Vercel preview:

```
/dashboard           still works (auth-gated)
/login               still works
/[orgSlug]/...       still works
```

### Phase 7 · Document the source-of-truth choice

If you read source content from a sibling worktree rather than `?ref=<branch>`, state it explicitly in the PR body. See the integration with `worktree-mtime-not-branch-date` below.

```
Source: <worktree-path> (mtimes confirmed fresher than branch tip)
NOT: ?ref=<branch> blobs
```

## What NOT to do

- Do NOT delete the `_components/` originals. Auxiliary pages still need them.
- Do NOT ship multi-PR migration. Interim states have route collisions or 404s.
- Do NOT update hrefs without the `STAYING_ROUTES` negative lookahead. You break deferred auxiliary links.
- Do NOT skip the root `layout.tsx` check. Double-rendered nav looks broken on the Vercel preview.
- Do NOT assume `_archive/old-marketing/<path>` redirects from the original `/<path>`. It does not. Add `next.config.js` redirects separately if needed.
- Do NOT pull source content via `?ref=<branch>` blobs without first checking sibling worktree file mtimes (see integration with `worktree-mtime-not-branch-date`).

## Seed lessons (4)

### Lesson 1 · Single atomic tree spec, not split PRs

A session split a route migration into "add new pages" PR + "delete old pages" PR. Between merges, both `/pricing` routes resolved (Next.js compiled both, picked one nondeterministically). The fix was always a single atomic push that adds `(marketing)/`, archives originals to `_archive/old-marketing/`, and deletes the original collisions in one tree spec.

### Lesson 2 · Negative lookahead on STAYING_ROUTES

A session ran a regex `re.sub(r'/<feature>/(\w+)', r'/\1', text)` over the nav file. Result: every nav link got rewritten, including `/<feature>/customers` (a deferred auxiliary page). Customers 404'd in production. The fix is the negative lookahead `(?!/(?:{staying_alt})\b)` plus an explicit per-route `MOVING_ROUTES` loop.

### Lesson 3 · Copy `_components/` to both paths

After the migration, the auxiliary pages still living at `/<feature>/{aux}` import nav and footer from `(marketing)/_components/`. If you MOVE rather than COPY, the auxiliary pages break their imports. Tree spec uses the same blob SHA at two paths so both routes share the nav until the auxiliary cleanup PR.

### Lesson 4 · Diff smaller than expected is a signal

If the user described a substantial copy-rewrite session (multiple hours of polish content), and the migration PR diff is small (under 200 lines for what should be 2000+), the diff is wrong. Either the source-of-truth was misidentified (you pulled from `?ref=<branch>` over fresher worktree files) or content was lost in conversion. Stop, verify worktree mtimes against branch tip, re-source if needed.

## Invariants consulted

- `verify-before-claim`. Before claiming "migration shipped clean," produce a `gh pr view --json additions,deletions,changedFiles` snapshot in the same turn so the diff shape is auditable.
- `api-push`. The atomic tree spec rides the canonical API push recipe (CRLF preservation, fresh base SHA, blob -> tree -> commit -> ref).

## Integration points

- Pairs with `worktree-mtime-not-branch-date`. ALWAYS run a file-mtime check on sibling worktrees before pulling source content for the migration. A worktree on a "stale" branch may hold hours of fresh uncommitted polish that `?ref=<branch>` would silently overwrite.
- Pairs with `api-push`. The migration push uses the canonical blob -> tree -> commit -> ref recipe with `sha=null` deletion entries.
- Pairs with HMR-localhost preview patterns. If reviewing pre-merge in a sibling worktree, the worktree files become source-of-truth and the branch ref is stale by definition.

## Completeness principle

Run every phase even for "small" route migrations. The cost of skipping the collision map (Phase 1) or the staying-routes lookahead (Phase 3) or the root-layout check (Phase 5) is a multi-PR recovery and a production rollback.

False positives are cheap (a few minutes of `ls` and `grep`). False negatives are expensive (production 404s on auxiliary pages, double-rendered headers, route-collision nondeterminism).

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a marketing-site migration that moved a feature subtree to root URLs while keeping auxiliary routes at the feature path; the `STAYING_ROUTES` negative lookahead was the load-bearing detail.
