---
name: codegen-at-install
namespace: bundle-distribution
version: 0.1.0
description: |
  When a runtime package requires CODE GENERATION against a schema
  (Prisma, GraphQL Codegen, OpenAPI generators, gRPC stubs, Protobuf,
  Drizzle), `npm install <package>` alone is NOT enough. The generator
  must run at install-time against the schema. If your distributable
  bundle externalizes such a package, you must (1) ship the schema
  inside the bundle, (2) include the generator CLI as a runtime dep,
  (3) emit a `postinstall` script that runs the generator against the
  shipped schema. Skipping any of the three lets `require()` succeed
  on the package wrapper but fail at first generated-client access.
allowed-tools:
  - Bash
  - Read
  - Edit
---

# codegen-at-install · ship schema + run generator at install-time

## Why this exists

Several modern packages ship a TWO-STAGE design:

- A wrapper package (e.g. `@prisma/client`) that's the public API surface
- A generator CLI (e.g. `prisma`) that produces a SCHEMA-SPECIFIC client into `node_modules/.prisma/client/` (or `node_modules/<pkg>/generated/`)

The wrapper at runtime imports the generated client. Without the generator having run, the wrapper's `require()` returns the wrapper, but the FIRST property access on that wrapper triggers a load of the generated artifact — which doesn't exist, throwing `Cannot find module '.prisma/client/default'`.

If you bundle the wrapper as an externalized runtime dep but never run the generator at install-time, your bundle ships a broken state: `npm install` succeeds, the wrapper loads, the FIRST query crashes.

This is a recurring distribution bug class. The fix is structural: bundle ships the schema, install-time runs the generator.

## Trigger conditions

You're shipping a CLI/server binary that:

1. Externalizes (does NOT inline) a code-generated runtime dep — Prisma, GraphQL Codegen, OpenAPI generators, gRPC stubs, Drizzle ORM
2. Distributes via a "drop on disk + npm install" flow (zip bundle, tarball, single-binary-with-sidecar-package.json)
3. Has a per-bundle schema that's stable (changes only at release time)

If you inline the generated client into the bundle (rare but possible), you don't need this skill — you've baked in the schema's worth of code at build-time.

## Procedure

### Step 1 · audit which packages need codegen

For every externalized runtime dep, check its package.json + docs:

| Package | Generator CLI | Output path |
|---|---|---|
| `@prisma/client` | `prisma` | `node_modules/.prisma/client/` |
| `@apollo/client` (codegen) | `@graphql-codegen/cli` | varies by config |
| `openapi-typescript` | (same package) | per `--output` flag |
| `@bufbuild/protoc-gen-es` | `protoc` + plugin | per `output_path` |
| `drizzle-orm` (some flows) | `drizzle-kit` | `node_modules/drizzle-kit/...` |

If the package has a build-step in its README/install docs ("after install, run X to generate Y"), that's your signal.

### Step 2 · ship the schema in the bundle

Add a copy step to your build pipeline:

```js
// build-cli.js (or your equivalent)
function copyAssetIntoSubdir(srcFile, bundleOutfile, subdir, label) {
  const destDir = path.join(path.dirname(bundleOutfile), subdir);
  fs.mkdirSync(destDir, { recursive: true });
  const destFile = path.join(destDir, path.basename(srcFile));
  fs.copyFileSync(srcFile, destFile);
  console.log(`[build] copied ${label}: ${path.relative(ROOT, destFile)}`);
}

const PRISMA_SCHEMA = path.join(ROOT, 'prisma/schema.prisma');
copyAssetIntoSubdir(PRISMA_SCHEMA, OUTFILE, 'prisma', 'prisma schema (for postinstall generate)');
```

Result: `dist/cli/prisma/schema.prisma` shipped alongside the bundle.

### Step 3 · include the generator CLI in the bundle's runtime manifest

Whatever generates the bundle's runtime `package.json`:

```js
const dependencies = {
  // wrapper package (the runtime API)
  '@prisma/client': pinFromBackendPackageJson('@prisma/client'),
  // GENERATOR CLI — needed at install-time only, but include in
  // dependencies (not devDependencies) so install.ps1's npm install
  // picks it up.
  'prisma': pinFromBackendPackageJson('prisma'),
  // ... other runtime deps
};
```

Pinning to a concrete version (not `*` or unpinned) is non-negotiable here — if the generator floats to a major incompatible with the wrapper, the install-time generation fails or produces broken output.

### Step 4 · emit the postinstall script

```js
const manifest = {
  name: 'mybundle-runtime',
  dependencies,
  scripts: {
    // Runs at install-time as part of npm install. Materializes the
    // schema-specific generated client into node_modules/.prisma/client.
    // Without this script, @prisma/client loads but its first property
    // access fails with "Cannot find module '.prisma/client/default'".
    postinstall: 'prisma generate --schema=./prisma/schema.prisma',
  },
};
```

### Step 5 · verify the bundle's smoke test runs the postinstall

If you have a CI smoke that simulates a fresh-install of the bundle:

```bash
# In your smoke harness
npm install \
  --omit=dev \
  --omit=optional \
  --no-audit \
  --no-fund
  # NOT --ignore-scripts — that disables postinstall, defeating the point
```

`--ignore-scripts` is a common reflex (faster, "safer") but in this context it's exactly wrong. The postinstall IS the install-time generation. Skipping it ships a smoke that passes while real installs fail.

### Step 6 · cover the unhappy path

A regression test should fail when:

- Schema is missing from the bundle
- Generator CLI is missing from runtime manifest
- Postinstall script is missing or wrong

```js
test("bundle ships prisma schema", () => {
  expect(fs.existsSync(`${BUNDLE_DIR}/prisma/schema.prisma`)).toBe(true);
});

test("bundle runtime manifest pins prisma generator", () => {
  const manifest = readBundleRuntimeManifest();
  expect(manifest.dependencies?.prisma).toMatch(/^\^?\d+\.\d+/);
});

test("bundle runtime manifest emits postinstall generate", () => {
  const manifest = readBundleRuntimeManifest();
  expect(manifest.scripts?.postinstall).toContain("prisma generate");
});
```

## Failure modes

- **`Cannot find module '.prisma/client/default'` at runtime**: schema not shipped OR postinstall didn't run OR generator CLI missing. Check all three.
- **Wrong major version of generator vs wrapper**: e.g. `prisma@7.x` against `@prisma/client@^6.19`. Symptom: postinstall succeeds but generated client has incompatible signatures. Pin the generator's major to match the wrapper's.
- **`--ignore-scripts` in install command**: postinstall doesn't run. CI smoke passes (because it ignored scripts) but real installs fail. Drop the flag.
- **Schema in source-control but not in build artifact**: build script doesn't copy. Add explicit copy step + a regression test that asserts schema presence in `dist/`.

## Why this works

The two-stage design (wrapper + generator) is an intentional compromise: it lets the wrapper ship as a small package on npm, while the schema-specific code (potentially MB of generated TS) gets created at install-time per consumer. That's good economics — but it puts a contract on the consumer to run the generator.

When you re-distribute via a bundle, you're now the consumer's intermediary. Your bundle's install flow inherits the contract. Honoring it = ship schema + postinstall. Ignoring it = ship a broken bundle.

## Seed lessons

- **id**: `bundle-codegen-three-piece-contract`
  **scope**: generic
  **pattern**: bundles externalizing code-generated runtime deps (Prisma, GraphQL Codegen, OpenAPI generators) must (1) ship the schema, (2) pin the generator CLI in runtime deps, (3) emit a postinstall that runs the generator. Missing any of the three breaks at first wrapper-property access.
  **evidence**: A bundle shipped @prisma/client without the schema or postinstall. `npm install` succeeded; the FIRST query crashed with `Cannot find module '.prisma/client/default'`. Three fixes (schema copy + prisma in runtime deps + postinstall script) shipped together.
  **fix**: when an externalized runtime dep has a generator CLI, all three pieces ship together. CI smoke must NOT use `--ignore-scripts` against bundle installs — that's the exact path real installs DO run.
