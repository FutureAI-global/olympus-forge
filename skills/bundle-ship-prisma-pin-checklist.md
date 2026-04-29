---
name: bundle-ship-prisma-pin-checklist
namespace: session-lessons
version: 0.1.0
description: |
  Pre-flight checklist that fires BEFORE shipping a CLI bundle through an
  S3-upload + remote-swap pipeline. Encodes the three-layer prisma version-pin
  agreement (generated client, install-script hardcoded deps, in-bundle
  package.json) plus the post-swap public-download SHA verification gate.
  Prevents the iteration cascade where each "fix" reveals the next pin
  mismatch only after the operator's smoke run on the target box.
allowed-tools:
  - Bash
  - Read
  - Edit
provenance: forged 2026-04-29 from a 4-iteration ship cascade where prisma version mismatches across staged layers bricked successive bundle releases until a pre-upload checklist enforced agreement.
---

# bundle-ship-prisma-pin-checklist · verify before swap, not after

## Why this exists

A CLI bundle that resolves `@prisma/client` at install time on the target box only works when three layers agree on the prisma version: the generated client output, the install script's hardcoded dependency list, and the in-bundle `package.json`. Any disagreement surfaces as a cryptic runtime error on the operator's box, not at build time, not at upload time, not at swap time.

The trap is that the install script's hardcoded deps list is the authoritative source. It overwrites whatever the bundle's own `package.json` declares before running `npm install`. Pinning in the bundle without pinning in the install script is a no-op on every retry.

Each ship iteration costs roughly 15-20 minutes of build, S3 upload, remote swap, and operator-side verify. A 4-iteration cascade burns an hour of wall time plus the operator's smoke window. With this checklist run pre-upload, the cascade collapses to a single ship.

## Preamble (run first)

```bash
# Resolve repo + worktree paths
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag bundle-ship --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. About to run `aws s3 cp <bundle>.zip s3://<artifact-bucket>/bundle-uploads/`
2. About to dispatch an SSM command that moves a staged bundle into the live-serve directory
3. Opening a PR that bumps a `<BUNDLE_VERSION>` manifest entry
4. Building via the bundle-build script (e.g. `node backend/scripts/build-cli.js`)
5. Any time the prisma schema or generated client has changed since the last shipped bundle

Voice triggers: "ship the bundle", "deploy the cli", "swap latest.zip", "push the bundle".

## Workflow

### Phase 1 · Confirm generator output is real

```bash
cd backend
ls -la node_modules/.prisma/client/query_engine-windows.dll.node
# Must exist (>20 MB, real generator output, not stubs)
ls -la node_modules/.prisma/client/default.js
# Must contain real generated code, not just `module.exports = require('.prisma/...')`
```

If the file is missing or under 1 KB, run `npx prisma generate` BEFORE building anything.

### Phase 2 · Confirm install-script pin matches generator target

```bash
grep -A2 '"@modelcontextprotocol/sdk"' backend/src/routes/install/install.ps1
# Expected:
#   "@modelcontextprotocol/sdk": "*",
#   "@prisma/client": "^6.19.1",        ← MUST be pinned, NOT "*"
#   "bufferutil": "*",
```

If `"@prisma/client": "*"` appears in the install script: STOP. The operator's `npm install` will resolve to whatever npm-latest happens to be that hour, not the major version your generator targeted. Generator/runtime mismatch surfaces as `Cannot find runtime/library.js` on the target box.

The pin floor is whatever `backend/package.json` declares. Match it exactly.

### Phase 3 · Confirm bundle zip ships the generated client

```bash
unzip -l <bundle>.zip | grep -E "node_modules/\.prisma/client/(default\.js|query_engine)" | head -3
# Must have BOTH default.js and query_engine-windows.dll.node entries
```

The bundle build defaults frequently DON'T include `.prisma/`. Add the staging step:

```bash
cp -r backend/node_modules/.prisma backend/dist/bundle-stage/node_modules/
```

Without this, the install script's `npm install` resolves `@prisma/client` but the generator output isn't there, surfacing as `Cannot find module '.prisma/client/default'`.

### Phase 4 · Defensive pin in bundle's own package.json

```bash
unzip -p <bundle>.zip cli/package.json | jq -r '.dependencies."@prisma/client"'
# MUST be ^6.19.x (NOT "*")
```

Even though the install script overrides this, pinning here makes the bundle self-sufficient. The next install-script fix doesn't have to be coordinated with a bundle ship.

### Phase 5 · Version output matches staging tip

```bash
node backend/dist/cli/<bundle-entry>.js --version
# Expected: <bundle-name> <bumped-version> (<staging-tip-prefix> · <today>)
```

If either the version or the SHA prefix is wrong, rebuild with the explicit `<BUNDLE_VERSION>` env var set.

### Phase 6 · Post-swap public-download SHA verification

```bash
TOKEN=$(jq -r .accessToken ~/<install-dir>/auth.json)
curl -fsL -H "Authorization: Bearer $TOKEN" \
  https://<api-host>/api/v1/install/<bundle>/bundle.zip \
  -o /tmp/probe.zip
sha256sum /tmp/probe.zip
# MUST equal the local zip's SHA exactly
```

If the SHAs differ after swap, the CDN or fronting server is serving stale. Reload the relevant service via SSM.

## What NOT to do

- Skipping Phase 2 because "the bundle's own package.json is pinned." The install script overrides the bundle's package.json before npm install runs. The bundle pin alone is a no-op.
- Trusting `unzip -l` alone for Phase 3. List view shows the path entries but says nothing about file size. A 0-byte placeholder passes the grep. Use `-p` to extract and inspect a known file.
- Verifying via `--version` output of a locally-built CLI without re-running on the target box. Local Node resolves modules from your dev `node_modules`, not from the bundle staging dir.
- Treating Phase 6 as optional. CDN cache invalidation lag is real, and a stale serve means the operator downloads the previous bundle while your local SHA matches the new one.
- Bumping the version manifest BEFORE Phases 1 through 5 pass. Version bump is the last commit, not the first.

## Seed lessons

### Lesson 1 · install script's hardcoded deps list overrides the bundle's own package.json

A bundle ship pinned `@prisma/client` in the in-bundle `cli/package.json` and shipped. The operator's smoke run still failed with `Cannot find runtime/library.js`. Forensics revealed the install script writes its own hardcoded deps list to the install dir BEFORE running `npm install`, overwriting the bundle's pin with `"*"`. Fix: pin in the install script source, not just the bundle.

### Lesson 2 · generated client must be staged into the bundle, not assumed-present

A bundle build produced a zip with `cli/package.json` correctly listing `@prisma/client`, but no `.prisma/client/` directory. On the target box, npm resolved the runtime fine but couldn't find the generated client output. Fix: explicit `cp -r node_modules/.prisma dist/bundle-stage/node_modules/` step in the build, with `unzip -l` verification before upload.

### Lesson 3 · `--version` output is generated at build time, must match staging tip

A bundle shipped with the version string baked from a stale env var, so the operator's `<bundle> --version` output reported the previous version. Confused everyone for 20 minutes about whether the swap actually landed. Fix: check `--version` against expected before upload, and re-build with explicit env var if wrong.

### Lesson 4 · post-swap SHA mismatch on public download means CDN cache lag

After SSM swap completed, the public download URL still served the old bundle for 90 seconds. Local zip SHA didn't match the public-fetched SHA. Fix: include a `sha256sum` comparison gate in the post-swap verify, and reload the fronting service if the SHAs don't agree.

### Lesson 5 · iteration cost compounds when checklist runs post-upload

A 4-iteration ship cascade revealed each pin mismatch only when the operator hit the next failure mode. Total wasted: roughly an hour of build/upload/swap/verify cycles plus the operator's smoke window. Fix: run all gates BEFORE the first `aws s3 cp`. The checklist cost is roughly 60 seconds; the cascade cost is roughly 60 minutes.

## Invariants consulted

- `Invariant 1 · Run the check before claiming`: every gate produces verifiable output before the upload commits to the next layer
- `Invariant 10 · Completeness trumps brevity (Boil the Lake)`: a 6-gate checklist that takes 60 seconds beats a 4-iteration cascade that takes 60 minutes
- `Invariant 2 · Fetch fresh HEAD before editing shared files`: the install script is shared surface, check remote state before editing the pin

## Integration points

- Pairs with `api-push`: when a gate fails and you need to fix-forward via PR, use the API-push recipe rather than `git push`
- Pairs with `verify-before-claim`: every "bundle shipped" claim requires the post-swap SHA match cited in the same turn
- Pairs with `fresh-state`: if multiple sessions might touch the install script, fetch its remote state before editing the pin

## Completeness principle

This skill DOES NOT fire for hot-patch flows where the operator is fixing the install dir in place on the target box (no S3 upload, no SSM swap). It also does not fire for documentation-only PRs against the bundle directory.

False-negative cost (skipping the checklist on a real ship): operator-visible regression, hour-scale iteration cascade, lost smoke window. False-positive cost (running it when not needed): roughly 60 seconds of grep and unzip. Default to running it.

## Changelog

- v0.1.0 (2026-04-29): initial skill from session-lessons. Forged from a 4-iteration ship cascade where prisma version-pin disagreements across the generated client, install script, and bundle package.json bricked successive releases until a pre-upload checklist enforced three-layer agreement.
