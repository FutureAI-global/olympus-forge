---
name: lazy-homedir-for-tests
namespace: session-lessons
version: 0.1.0
description: |
  Resolve `os.homedir()` lazily per function call, not at module top.
  Capturing it at import-time freezes the path before jest's tmp-dir
  fixtures override `$HOME` / `$USERPROFILE`, silently making tests read
  the dev's real `~/`. Pairs with HOME+USERPROFILE override fixture template.
allowed-tools:
  - Read
  - Write
provenance: |
  forged 2026-04-29 from privacy.ts (PR #1867 Olympus CC5). The naive
  module-top constant pattern made every privacy test silently read the
  developer's real ~/.olympus.
---

# lazy-homedir-for-tests · resolve $HOME per call, not at module top

## Why this exists

- Modules with `~/` paths typically grab `os.homedir()` at module load and bind it to a const: `const PRIVACY_FILE = path.join(os.homedir(), ".olympus", "privacy.json")`.
- That const is evaluated when jest first imports the module — long before any `beforeEach` overrides `$HOME` / `$USERPROFILE`.
- Result: tests that try to redirect to `/tmp/test-home-xyz` silently read from the dev's real `~/.olympus/privacy.json`. Passes if the file is absent, leaks/corrupts if present.
- Right shape: resolve `homedir()` lazily inside each function. Pair with a fixture that overrides BOTH `$HOME` and `$USERPROFILE` (Node reads HOME on POSIX, USERPROFILE on Windows; tests run in CI on both).

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag lazy-homedir --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Writing a module that reads/writes paths under `~/` (`~/.olympus/foo.json`, `~/.config/X/Y`).
- Adding a unit test for a module that touches `~/`.
- The module has any unit tests touching its filesystem behavior.
- A test that "passes locally but produces stray files in `~/`" complaint surfaces.

Voice triggers: "test reads from real home directory", "tmp-dir override doesn't take effect", "where is this test writing", "we polluted my home dir during test runs".

## Workflow

### Phase 1 · Identify the bug shape (naive module-top binding)

```typescript
import * as os from "node:os";
import * as path from "node:path";

const PRIVACY_FILE = path.join(os.homedir(), ".olympus", "privacy.json");
//    ^^^^^^^^^^^^ FROZEN at module import — tmp-dir overrides come too late
```

Jest test trying to override:

```typescript
beforeEach(() => {
  process.env.HOME = "/tmp/test-home-xyz";        // too late
  process.env.USERPROFILE = "/tmp/test-home-xyz"; // too late
});

it("returns defaults when file is missing", async () => {
  const s = await loadPrivacyState();   // reads from REAL ~/.olympus
  expect(s).toEqual({ ... });
});
```

The const at module top was evaluated during the test runner's first `require()`. The test reads from the real home directory.

### Phase 2 · Fix shape — wrap path resolution in a function

```typescript
import * as os from "node:os";
import * as path from "node:path";

/**
 * Resolve the file path lazily so tests overriding $HOME / $USERPROFILE
 * after module load (the standard pattern in jest tmp-dir fixtures)
 * actually see their override. Caching this at module top freezes the
 * path to wherever the test runner started.
 */
function privacyFile(): string {
  return path.join(os.homedir(), ".olympus", "privacy.json");
}

export async function loadPrivacyState(): Promise<PrivacyState> {
  const raw = await fs.readFile(privacyFile(), "utf-8");
  // ...
}

export async function setOptOut(value: boolean): Promise<PrivacyState> {
  await fs.mkdir(path.dirname(privacyFile()), { recursive: true });
  await fs.writeFile(privacyFile(), JSON.stringify(...), { mode: 0o600 });
}
```

`os.homedir()` runs per function invocation now. `process.env.HOME` overrides are honored.

### Phase 3 · Test fixture — override BOTH HOME and USERPROFILE

```typescript
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

let tmpHome: string;
let originalHome: string | undefined;
let originalUserprofile: string | undefined;

beforeEach(async () => {
  tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "myapp-test-"));
  originalHome = process.env.HOME;
  originalUserprofile = process.env.USERPROFILE;
  // homedir() reads HOME on POSIX, USERPROFILE on Windows — override both.
  process.env.HOME = tmpHome;
  process.env.USERPROFILE = tmpHome;
});

afterEach(async () => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  if (originalUserprofile === undefined) delete process.env.USERPROFILE;
  else process.env.USERPROFILE = originalUserprofile;
  await fs.rm(tmpHome, { recursive: true, force: true });
});
```

Both vars must be set — Node's `os.homedir()` consults HOME on POSIX, USERPROFILE on Windows. CI runs both.

### Phase 4 · Companion patterns for filesystem state files

Once the lazy-homedir is in place, layer in these defensive patterns:

```typescript
// Default-on-missing — read function never throws, returns sane defaults.
export async function loadState(): Promise<State> {
  try {
    const raw = await fs.readFile(privacyFile(), "utf-8");
    return parseState(raw);
  } catch {
    return { ...DEFAULT_STATE };
  }
}
```

- **Atomic write**: `tmp + rename`, not direct write. Crash-safe.
- **Mode `0600`** for any file holding user-secret/preference data.
- **Default-on-missing** in the read function: corrupted or absent file returns sensible defaults instead of throwing — the file's job is to record state, not gate functionality.

## Gotchas

### Don't cache `homedir()` at module load

The single most common shape of this bug. Module-top consts feel right; they break every tmp-dir test silently.

### Don't mock `os.homedir()` via `jest.mock`

Works, but couples tests to internals; env-var override is more honest and matches real-world behavior. The mock approach also fails when test infrastructure spawns subprocesses that re-import the module fresh.

### Don't skip `USERPROFILE` override

POSIX-only fixtures pass on Mac/Linux CI but pollute Windows dev's home directory when they run the test locally.

### Don't write to `~/` from a test that doesn't override HOME

Even one such test pollutes the dev's real home. If you can't guarantee the override took effect, fail loud rather than write.

### Don't skip lazy resolution for "test-only" modules

If the module has any tests touching its filesystem behavior, lazy is the default. The performance cost (`os.homedir()` per call ≈ microseconds) is negligible.

## Invariants consulted

- **Invariant 1 · Module-top consts evaluate at import time** — overrides set later don't apply retroactively.
- **Invariant 2 · `os.homedir()` is platform-keyed** — HOME on POSIX, USERPROFILE on Windows; both must be overridden in tests.
- **Invariant 3 · Lazy resolution is cheap** — function-call overhead is microseconds; not a perf concern.
- **Invariant 4 · Tests must not pollute the dev's real `~/`** — failure mode is invisible until the dev sees stray files.

## Seed lessons

1. **Module-top homedir() freezes the path before tmp-dir overrides** · P0 · generic. The test reads the real `~/`, silently.
2. **Override BOTH HOME and USERPROFILE** · P1 · generic. POSIX-only fixtures pollute Windows dev dirs.
3. **Lazy resolution is the default for any test-touched module** · P1 · generic. Cheap and prevents an entire class of silent test bugs.
4. **Default-on-missing pairs with lazy** · P2 · generic. State files shouldn't gate functionality; missing/corrupted → defaults.
5. **Atomic write + mode 0600 for preference files** · P3 · generic. Prevents partial writes on crash + scopes file readability.

## Integration

- **`./hand-written-not-autodetect.md`** — preference/privacy state files are often the consumed surface for hand-written privacy descriptors.
- **`/verify-before-claim`** — claims like "test fixture isolates the home directory" require asserting `process.env.HOME` and `process.env.USERPROFILE` were both set.

## Completeness principle

10/10: lazy `homedir()` resolution per function · fixture overrides BOTH HOME and USERPROFILE · default-on-missing read · atomic write + mode 0600.

7/10: lazy resolution + HOME-only override (passes on POSIX CI, pollutes Windows dev `~/`).

3/10: module-top `homedir()` capture (every tmp-dir test silently reads the real home directory).

**Default: 10/10.** The cost is one function instead of one const; the failure mode without it is dev-home pollution + silently-passing tests that don't actually exercise their fixture.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version forged from privacy.ts in PR #1867.
