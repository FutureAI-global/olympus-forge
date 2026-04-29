---
name: release-promote-pattern
namespace: release-engineering
version: 0.1.0
description: |
  When a project has a staging branch as the integration point and
  main as production, the "promote staging → main" PR is a recurring,
  high-cadence operation. Rather than relying solely on a
  deployment-dashboard UI (single point of failure, gated by web app
  uptime), establish a `gh pr create --base main --head staging` +
  `gh pr merge --admin --merge` pattern with a stable title format
  (`promote: staging → main · vX.Y.Z`). It completes in seconds, has a
  clear audit trail, and survives dashboard outages.
allowed-tools:
  - Bash
---

# release-promote-pattern · gh-CLI promote pattern alongside the dashboard

## Why this exists

Many teams have a "production deploys ONLY via the deployment-dashboard" rule in their docs. That rule is sound for new code that hasn't yet been validated on staging. But it's overkill for the recurring "promote staging → main" operation, which:

- Has nothing new to validate (staging already passed CI + smoke + integration)
- Is high-cadence (multiple times per week or per day during sprints)
- Has a stable shape (same source, same target, just a version bump)
- Needs to be fast (release windows are minutes, not hours)

A dashboard-only path adds friction. It's also a single point of failure: if the dashboard's web app is down, releases can't ship. The gh-CLI pattern is a peer to the dashboard, not a replacement — both work, the dashboard handles new-code review, the CLI handles validated-staging promote.

## When to use this pattern

Use the gh-CLI promote when:

- The code has already merged through a feature-PR review cycle into staging
- Staging passed all required CI gates
- A smoke test against staging confirms end-to-end behavior
- The promote is "merge what's on staging, no new code"

Use the deployment-dashboard when:

- New code that bypassed staging (rare, usually emergency hotfix)
- Code that requires additional approval (compliance, security review)
- Releases that need coordination with non-eng (marketing, support, legal)
- First-of-a-kind release shapes that haven't been formalized yet

Both surfaces should leave the same audit trail: a merge commit on main, a tag, a release notes entry.

## Procedure

### Step 1 · verify staging is at the version you want

```bash
gh api repos/$OWNER/$REPO/contents/$VERSION_FILE_PATH \
  -f ref=staging --jq '.content' | base64 -d | grep -E "version|VERSION"
```

The version string in the source-of-truth file should match what you're about to promote. If staging's version manifest says `0.7.4` but the most recent merge was `0.7.5`, someone forgot to bump the manifest — fix before promoting.

### Step 2 · check the diff against main

```bash
gh api "repos/$OWNER/$REPO/compare/main...staging" \
  --jq '{ahead: .ahead_by, behind: .behind_by, files: (.files | length)}'
```

Expected:

- `ahead_by` > 0: staging has commits not on main (the work you're promoting)
- `behind_by` > 0 is FINE: those are typically the merge commits from PRIOR promotes that didn't get pulled back to staging. They're already in the staging tree via merge resolution.
- `files` count: sanity-check it matches your expectation. A 200-file diff for a "small fix" promote means staging accumulated more than expected — pause + read the changelog.

### Step 3 · open the promote PR

Title format: `promote: staging → main · <product>-v<X.Y.Z>` (or your project's equivalent stable shape).

```bash
gh pr create --repo $OWNER/$REPO \
  --head staging --base main \
  --title "promote: staging → main · myproduct-v$VERSION" \
  --body "$(cat <<EOF
## Promotion

Staging tip → main · \`myproduct-v$VERSION\`.

$AHEAD commits / $FILES files since last promote (#$LAST_PROMOTE_PR).

## What landed since v$LAST_VERSION

<bulleted list of major arcs — copy from changelog or recent merge titles>

## Activation in production

<one-liner on what users see post-merge — banner, version probe, etc.>

## Test plan

- [x] All staging gates green at staging tip
- [x] N PRs merged this cycle, 0 reverts
- [ ] Post-deploy smoke against prod
EOF
)"
```

### Step 4 · admin-merge

If the PR's mergeable state is `MERGEABLE` (CI may still be running — that's `UNSTABLE`, also fine for a promote since CI already gated staging):

```bash
gh pr merge $PR_NUMBER --repo $OWNER/$REPO \
  --merge --admin \
  --subject "promote: staging → main · myproduct-v$VERSION (#$PR_NUMBER)"
```

Admin-merge bypasses required-status-checks because the checks already passed on staging. Don't admin-merge if the staging-side CI was actually red — that's a different problem.

### Step 5 · verify

```bash
gh pr view $PR_NUMBER --json state,mergedAt,mergeCommit --jq '.'
gh api repos/$OWNER/$REPO/git/ref/heads/main --jq '.object.sha'
```

State should be `MERGED`. Main tip should be the new merge commit.

## Anti-patterns

- **Force-merging unstable CI**: only do this for promote PRs where CI was already gated on staging. For NEW code, unstable means "verify before merging."
- **Skipping the title format**: the stable shape (`promote: staging → main · v0.7.4`) is greppable in audit logs + matches what the dashboard generates. Don't drift the format ad-hoc.
- **Bundling unrelated changes into the promote**: a promote PR's diff should be exactly "staging minus main, no extras". If you cherry-pick around, audit becomes harder.

## Failure modes

- **`MERGEABLE: false`**: actual file conflicts. Means staging has commits that conflict with main's recent direct edits. Resolve by merging main into staging first, fixing conflicts, then re-opening the promote.
- **`MERGEABLE: UNKNOWN`**: GitHub is still computing. Wait 15s, retry. If it stays UNKNOWN >2min, the repo's mergeability calculator is in a bad state — open + close the PR or push an empty commit to retrigger.
- **Admin-merge denied**: token doesn't have admin scope OR the repo's branch protection forbids admin override. Check token scopes; check branch protection settings.

## Why this works

The deployment-dashboard rule exists to prevent unreviewed code from reaching production. A staging→main promote isn't unreviewed — every commit went through PR review when it merged INTO staging. The promote is a roll-up, not a bypass.

The gh-CLI pattern's value is speed + auditability. The PR shows up in the same list as feature PRs, with the same stable title format, mergeable from a terminal in <30s. The dashboard remains the right surface for reviewed-and-approved-code paths; the CLI handles the integration-point promote.

## Seed lessons

- **id**: `release-eng-cli-promote-pattern`
  **scope**: generic
  **pattern**: when a project has staging→main release flow, establish a `gh pr create + gh pr merge --admin` pattern with stable title format (`promote: staging → main · vX.Y.Z`) alongside the deployment-dashboard. Faster + survives dashboard outages.
  **evidence**: A repo's recent promote history showed 5+ PRs over a month, all admin-merged within 30s of opening. The dashboard remained the preferred path for new-code review.
  **fix**: write the promote pattern into your release runbook so it's documented as a peer to the dashboard, not a backdoor. Both have legitimate use cases.
