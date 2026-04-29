---
name: headless-cli-flag-dispatch-order
namespace: cli-design
version: 0.1.0
description: |
  When adding a CLI flag that bypasses the default interactive flow
  (e.g. `--script <path>` for batch/CI use, `--export <fmt>` for
  one-shot output, `--dry-run` for validate-without-execute), dispatch
  the flag's branch BEFORE any network probes (service discovery,
  health checks, auth-token refresh, capability negotiation). Otherwise
  non-network use cases hang waiting for the probe's timeout against
  unreachable services — the exact flow the flag was supposed to skip.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Grep
---

# headless-cli-flag-dispatch-order · branch before probing

## Why this exists

A CLI's default flow often involves probing external services at startup: discovering which backend is reachable, checking auth-token validity, querying capability flags. Those probes are right for the interactive default path — they catch misconfiguration early and route to the right service.

But probes have a cost: a probe with a 5-second timeout against an unreachable service stalls startup by 5 seconds. For an interactive user that's annoying but tolerable. For a CI smoke test running 100 invocations in parallel, that's 500 seconds of wasted clock. For a batch job that's "I just want to render this template, no network needed", it's pure waste.

The fix is dispatch-order: when a flag indicates "headless / batch / CI", branch into the headless flow BEFORE any probe runs. The probe never fires; the headless path gets its <100ms startup.

## Trigger conditions

You're adding a CLI flag that:

1. Bypasses the interactive UI (`--script`, `--no-tui`, `--batch`, `--quiet`)
2. Doesn't need the network probe to function correctly
3. Will be invoked frequently from CI / cron / scripts (not just one-off humans)

If the flag still needs the probe (e.g. `--no-tui` falls back to a line-REPL that still talks to the backend), the dispatch order doesn't matter — branch wherever it's most readable. But if the flag short-circuits the entire default flow, dispatch early.

## Procedure

### Step 1 · find the existing dispatch site

Grep for where the CLI parses commands and routes to handlers. Typical shape:

```ts
async function main(rawArgs: readonly string[]): Promise<number> {
  const args = parseArgs(rawArgs);
  switch (args.command) {
    case "chat": {
      // <-- probe usually lives here
      const probe = await probeBackend();
      return cmdChat({ ...args, mode: probe.mode });
    }
    case "doctor":
      return cmdDoctor();
    // ...
  }
}
```

The probe is usually inside the `case` for the most common command. Other commands skip it — they have their own minimal startup paths.

### Step 2 · place the flag dispatch BEFORE the probe

```ts
case "chat": {
  // Headless dispatch goes FIRST. Doesn't need the network probe;
  // probe would just stall startup by its timeout against an
  // unreachable backend in CI.
  if (args.scriptPath) {
    const { cmdChatScript } = await import("./cmd-chat-script.js");
    return cmdChatScript({
      scriptPath: args.scriptPath,
      vin: args.vin,
    });
  }
  // Interactive default — probe + cmdChat as before
  const probe = await probeBackend();
  return cmdChat({ ...args, mode: probe.mode });
}
```

Document the WHY in a comment so a future maintainer doesn't reflex-move it back below the probe ("symmetry" reasoning).

### Step 3 · verify with a smoke

Run the headless flag against an environment WITHOUT the backend reachable:

```bash
# Stub the backend to be unreachable
export BACKEND_URL="http://127.0.0.1:65535"
time mycli command --headless-flag /path/to/input
```

Expected: completes in <500ms (no probe stall). If it hangs, the flag dispatch is still after the probe; verify the placement.

### Step 4 · cover with a unit test

The cleanest test for dispatch order doesn't need to mock the probe — it needs to verify that the headless path doesn't ATTEMPT the probe. A spy on the probe function should record zero calls:

```ts
test("--script bypasses backend probe", async () => {
  const probeSpy = jest.fn();
  await main(["chat", "VIN", "--script", "/tmp/script.yaml"], {
    probeBackend: probeSpy,
  });
  expect(probeSpy).not.toHaveBeenCalled();
});
```

## When NOT to apply

- The flag still needs the probe (e.g. `--no-tui` falls back to a line-REPL that talks to backend)
- The probe is cheap (<50ms) and uniform across all commands
- You've benchmarked probe-cost in the CI use case and it's acceptable

If any of those apply, dispatch ordering doesn't matter — write for readability.

## Failure modes

- **Reflexive "all dispatchers go here" refactor**: a future maintainer consolidates all command branches into a single function, putting the probe before the dispatcher. Symptom: CI smoke time-budget regressions. Mitigation: in-line comment + a test that proves the headless path doesn't probe.
- **New flag added without considering order**: e.g. `--export-only` gets added to the interactive path, doesn't realize the probe isn't needed. Mitigation: PR review checklist for new CLI flags includes "does this need the probe?"
- **Probe migrated to lower in the call stack**: someone moves probe logic into a service-client constructor; dispatch-order at the CLI layer is now correct but the probe still fires later. Mitigation: trace the probe's actual call site post-refactor.

## Seed lessons

- **id**: `cli-design-dispatch-before-probe`
  **scope**: generic
  **pattern**: CLI flags that bypass the default interactive flow (`--script`, `--export`, `--dry-run`) must dispatch BEFORE network probes (service discovery, health checks, auth refresh). Otherwise non-network use cases hang on the probe timeout.
  **evidence**: A `--script` flag for headless YAML script execution was originally placed after the network probe. CI smoke runs from a developer machine without the backend reachable hung for the probe's full timeout. Moving the dispatch BEFORE the probe brought startup to <100ms regardless of backend availability.
  **fix**: any new `--<flag>` triggering a non-network branch in the CLI dispatcher places it BEFORE the probe call. Document the intent in an in-line comment; cover with a unit test that the headless path doesn't call the probe.
