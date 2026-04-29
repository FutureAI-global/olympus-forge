---
name: atomic-json-config-store
namespace: session-lessons
version: 0.1.0
description: |
  Canonical 7-field pattern for any user-local persistent JSON store
  (preferences, pattern library, plugin registry, recent-items list).
  Schema-versioned, atomic-ish save (.tmp + rename), env override for tests,
  defaults helper, type guards on load, idempotent updates. Each field
  exists for a specific failure mode the pattern blocks. Two PRs proved the
  shape with ~140 lines of code plus 26+ tests when followed exactly.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from two sibling PRs that shipped near-identical config-store modules; the second PR was a copy-paste-with-edits of the first, which surfaced the 7-field pattern as the stable shape
---

# atomic-json-config-store · the canonical user-local JSON store pattern

## Why this exists

When a feature needs a user-local persistent JSON store (preferences, pattern library, plugin registry, recent-items list), every store re-derives the same seven fields. The cost of getting any one wrong is a corrupted config file on the user's machine, an unmigrated schema bump, or a test suite that pollutes the developer's actual config.

This skill encodes the pattern so the next store is a copy-paste-with-edits, not a re-derivation.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag json-config-store --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

Fire this skill when shipping any of:

1. A user-local preferences file (`~/<install-dir>/<config>.json`)
2. A pattern library / teach store (`~/<install-dir>/<patterns>.json`)
3. A recent-items list (`~/<install-dir>/<recents>.json`)
4. A plugin registry (`~/<install-dir>/<plugins>.json`)
5. A macro library (`~/<install-dir>/<macros>.json`)
6. ANY persistent JSON file under `~/<install-dir>/`

Voice triggers: "config store", "JSON file under user home", "preferences file".

## Workflow

### Phase 1 · Author the seven fields

```typescript
// 1. Schema version constant
export const PROFILE_SCHEMA_VERSION = 1 as const;

// 2. Type with required schemaVersion + optional fields
export interface UserProfile {
  schemaVersion: typeof PROFILE_SCHEMA_VERSION;
  // ... all other fields optional
}

// 3. Path resolver with env override (tests + scripted installs)
export function resolveProfilePath(): string {
  return process.env.<APP_PROFILE_PATH> ??
    join(homedir(), ".<install-dir>", "profile.json");
}

// 4. Existence check (first-launch gating)
export function profileExists(): boolean {
  return existsSync(resolveProfilePath());
}

// 5. Load with defaults + schema-version guard
export function loadProfile(): UserProfile {
  const path = resolveProfilePath();
  if (!existsSync(path)) return createDefaultProfile();
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (!isProfileLike(parsed)) throw new Error("malformed profile");
  if (parsed.schemaVersion > PROFILE_SCHEMA_VERSION) {
    throw new Error("profile schemaVersion newer than this binary supports");
  }
  return mergeWithDefaults(parsed);
}

// 6. Atomic-ish save (.tmp + renameSync)
export function saveProfile(profile: UserProfile): void {
  if (profile.schemaVersion !== PROFILE_SCHEMA_VERSION) {
    throw new Error("schemaVersion mismatch on save");
  }
  const path = resolveProfilePath();
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(profile, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
}

// 7. updateProfile convenience (load → patch → save → return)
export function updateProfile(patch: Partial<UserProfile>): UserProfile {
  const next = { ...loadProfile(), ...patch, schemaVersion: PROFILE_SCHEMA_VERSION };
  saveProfile(next);
  return next;
}
```

### Phase 2 · Author the test suite with per-test isolation

```typescript
let tmpDir: string;
let tmpFile: string;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "profile-test-"));
  tmpFile = join(tmpDir, "profile.json");
  process.env.<APP_PROFILE_PATH> = tmpFile;
});

afterEach(() => {
  delete process.env.<APP_PROFILE_PATH>;
  rmSync(tmpDir, { recursive: true, force: true });
});
```

26+ tests against a real filesystem with full isolation. No fixture path. No hardcoded `/tmp/test-profile.json`. Per-test `mkdtempSync` prevents flakes and keeps the developer's real config untouched.

### Phase 3 · Document the cross-feature consumers

In the file's docstring, list every consumer of the store and how it reads / writes. Future consumers see the dependency graph at a glance, and the next session that needs to bump the schema knows who to coordinate with.

## What NOT to do

- Do not make any field required besides `schemaVersion`. Required fields force migrations on every backward-compat addition. `Partial<UserProfile>` plus `mergeWithDefaults` is the right shape.
- Do not skip the env override on the path. Without it, every test touches the developer's real config and pollutes their actual setup.
- Do not direct-`writeFileSync` the path. A crash mid-write produces a truncated file and the next load throws. Always `.tmp` plus `renameSync`.
- Do not validate every field in the type guard. `isProfileLike(v)` checks the minimal contract (object shape, `schemaVersion: number`); per-field validation belongs in caller territory.
- Do not encrypt this store. For credentials, use a separate file with a bearer-token shape, not this pattern. PII goes here only if the user accepts laptop-trust.

## Seed lessons

### Lesson 1 · Schema version constant prevents inline drift

Never inline `1` in the code. `as const` makes it a type-narrowable literal. When v2 needs migration, bump the constant and add a migration shim; every load goes through one decision point. Inline literals scatter the bump across the codebase and make migration partial.

### Lesson 2 · Optional-everywhere except schemaVersion

Adding fields is non-breaking: the loader fills with defaults. Renaming or removing requires a `schemaVersion` bump plus a migration. Marking any field required besides `schemaVersion` forecloses the cheapest backward-compat additions.

### Lesson 3 · Atomic-ish save is the difference between "preferences gone" and "preferences saved"

`.tmp` plus `renameSync` makes the swap atomic on POSIX (always) and best-effort on Windows (still better than direct overwrite). The 3 lines of overhead are cheap; the cost of a corrupted config is the user's afternoon plus a "your profile is gone" support ticket.

### Lesson 4 · Per-test temp file plus env override beats fixture path

Tests that touch the developer's real `~/<install-dir>/<config>.json` pollute their actual config and produce flakes when the test runs in parallel. `mkdtempSync` plus env override plus cleanup gives full isolation. Fixture paths and hardcoded `/tmp/test-profile.json` both fail this bar.

### Lesson 5 · Both load AND save guard the schema version

Load throws on a future version (older binary, newer config file). Save throws on a mismatched version (caller forgot to bump). Both gates prevent silent corruption. A skipped-on-save guard ships stale-version writes; a skipped-on-load guard silently downgrades the file.

## Invariants consulted

- `verify-before-claim`: "the config persists across restarts" is a claim; the per-test temp-file suite is the evidence. The tests must run and pass before the store ships.
- `fresh-state`: the env override is the test-side application: every test gets a fresh, isolated config path, never inheriting state from the developer's real machine.

## Integration points

- Pairs with `api-push`: the `.tmp` + `renameSync` pattern is the same shape as the base_tree-safe blob upload pattern. Both make the write atomic against partial-failure modes.
- Pairs with `drift-guard-test`: every JSON config store the batch ships gets a mandatory schema-version assertion in the drift guard so a sibling session's silent bump fires loudly.
- Pairs with `verify-before-claim`: the `mergeWithDefaults` helper is exported (not private) so tests and edge-case callers can verify the merge logic without reaching into the load path.

## Completeness principle

Completeness 10/10: all seven fields present + per-test `mkdtempSync` isolation + env override + schema-version guards on both load and save + cross-feature consumer documented in the docstring.
Completeness 7/10: skip the existence check (first-launch flows pay a tiny load + parse round-trip).
Completeness 3/10: direct `writeFileSync` plus required fields plus shared test fixture path. This is the failure mode the skill exists to prevent.

Default target: 10/10. The seven-field pattern is ~140 lines; the cost of a corrupted config file or an unmigrated schema bump is the user's afternoon.

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from two sibling PRs that shipped near-identical config-store modules and surfaced the 7-field pattern as the stable shape.
