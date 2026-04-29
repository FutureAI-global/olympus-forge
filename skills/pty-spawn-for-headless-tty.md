---
name: pty-spawn-for-headless-tty
namespace: ci-test
version: 0.1.0
description: |
  Smoke tests that need to validate a TUI (Ink, Blessed, etc.) mounting
  on Linux CI cannot use a plain `spawn(node, args, { stdio: 'pipe' })`
  — `process.stdin.isTTY` will be false, the TUI will bail to a
  line-mode fallback (or exit silently), and the smoke gate will
  report empty stdout. Wrap the spawn through `script -q -c '<cmd>'
  /dev/null` (util-linux PTY emulator) so the child sees a real PTY
  and `stdin.isTTY === true`.
allowed-tools:
  - Bash
  - Read
  - Edit
---

# pty-spawn-for-headless-tty · simulate a TTY in CI

## Why this exists

A TUI's mount path frequently checks `process.stdin.isTTY` and routes to a line-REPL fallback when stdin isn't a terminal. That fallback is the right behavior for non-interactive shell pipes, but it's the WRONG behavior for a CI smoke test trying to verify the TUI's render path.

A plain `spawn` with `stdio: ["pipe", "pipe", "pipe"]` produces a non-TTY stdin. The TUI silently routes to line-REPL, exits when stdin closes, and the smoke harness reports empty stdout for the entire deadline. The bug is invisible — the harness can't distinguish "TUI mount failed" from "TUI bailed to line-REPL because of TTY check."

The fix on Linux: wrap the child through `script` (util-linux), which provides a real PTY and makes `stdin.isTTY === true` for the spawned process.

## Procedure

### Step 1 · detect the symptom

Smoke gate fails with:

- Empty stdout for the entire deadline
- Exit code 0 or 1 with no diagnostic output
- Wall time near-zero (the bundle exits in <1s)
- No "Cannot find module" / no "ReferenceError" / no obvious crash

If the spawned binary normally has a TUI render path, this is the TTY-bail symptom. Verify by grepping the source for `stdin.isTTY` checks; if the codebase routes to a line-REPL fallback on `isTTY !== true`, you've found it.

### Step 2 · wrap the spawn

Linux/macOS:

```ts
// Before
const child = spawn("node", [bundle, "chat", vin], {
  cwd: ROOT,
  env: { ...process.env, NODE_ENV: "test" },
  stdio: ["pipe", "pipe", "pipe"],
});

// After (Linux only — falls back to direct spawn elsewhere)
const useScriptPty =
  process.platform === "linux" &&
  spawnSync("which", ["script"], { stdio: "ignore" }).status === 0;

const child = useScriptPty
  ? spawn(
      "script",
      ["-q", "-c", `node "${bundle}" chat "${vin}"`, "/dev/null"],
      { cwd: ROOT, env: childEnv, stdio: ["pipe", "pipe", "pipe"] },
    )
  : spawn("node", [bundle, "chat", vin], {
      cwd: ROOT,
      env: childEnv,
      stdio: ["pipe", "pipe", "pipe"],
    });
```

### Step 3 · understand the platform matrix

| Platform | `script` syntax | Notes |
|---|---|---|
| Linux (util-linux) | `script -q -c "<cmd>" /dev/null` | -c command, then output file |
| macOS (BSD) | `script -q /dev/null <cmd> <args>` | output file then command (different order!) |
| Windows | not available | direct spawn; stdin.isTTY check will fail |

For CI specifically (typically Linux), the Linux form is what you need. Don't try to make the wrapper cross-platform for dev-machine smoke runs — accept that on dev mac the smoke might not exercise the mount path; the contract is "CI gates the production behavior."

### Step 4 · verify

After the wrap:

- Smoke harness sees non-empty stdout containing TUI mount glyphs (welcome text, brand emoji, frame chars)
- Bundle stays alive for the full deadline (waits for stdin EOF or signal)
- Exit code is 0 on clean shutdown

If you still see empty stdout: the TUI is failing for a different reason (missing module, top-level throw). Check stderr; check `node --print` from the CI runner to confirm the bundle path is correct.

## Failure modes

- **Wrong `script` syntax for the host OS**: BSD vs util-linux. Symptom: `script` runs but doesn't exec the command. Fix: detect platform, use the right form per the table above.
- **`script` not installed on the runner**: rare on standard Linux images, but ARM/minimal images may omit it. Fix: install via `apt-get install bsdutils -y` or fail loud with a clear message.
- **PATH stripped too aggressively**: setting `env: { PATH: "/usr/bin:/bin" }` for a "fresh-env" smoke can drop `node`'s install location (typically `/opt/hostedtoolcache/node/...` on GH runners). Fix: prepend `path.dirname(process.execPath)` to PATH so node is reachable.

## Why this works

`script` is part of util-linux (Linux) and BSD utils (macOS), so it's effectively pre-installed everywhere TUI smokes run. It uses a pseudoterminal pair — the master end is owned by `script`, the slave is `/dev/pts/N`. The child's stdin/stdout/stderr are wired to the slave, which Node sees as a real TTY.

This is the same mechanism used by `tmux`, `screen`, and `expect`. We're getting their PTY infrastructure for free without taking a dependency.

## Seed lessons

- **id**: `ci-test-tty-bail-empty-stdout`
  **scope**: generic
  **pattern**: TUI smoke tests using `spawn(node, args, {stdio: "pipe"})` produce empty stdout because the TUI bails to line-REPL when `stdin.isTTY !== true`. Wrap through `script -q -c <cmd> /dev/null` for a real PTY.
  **evidence**: 6 consecutive CI runs failed with empty stdout + 0.5s exit before the cause was identified. Wrapping with `script` resolved on the next run.
  **fix**: any spawn-based smoke harness for a TUI on Linux CI uses the `script` PTY wrapper; falls back to direct spawn on non-Linux dev machines.
