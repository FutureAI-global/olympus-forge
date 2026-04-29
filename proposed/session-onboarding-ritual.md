---
name: session-onboarding-ritual
namespace: session-lessons
version: 0.1.0
description: |
  First action in any new Claude session that joins the multi-session coord
  ecosystem. Install the 60s autonomous idle-detection tick so the factory
  cron can see your idle state. Without it, your session is invisible to
  the assignment backlog.
allowed-tools:
  - Bash
provenance: |
  forged 2026-04-29 from PR #1900 (install-session-tick.sh introduced),
  #1904 (dedupe pagination fix), and #1907 (state-file path normalization).
  Pattern stabilized after sessions running pre-#1904 had broken dedupe.
---

# session-onboarding-ritual · install the tick first, before any other work

## Why this exists

- Multi-session coord depends on a factory cron that polls each session's idle state and dispatches assignments to whoever's free.
- A session without the tick installed is **invisible to the cron** — it never gets work, even when nothing else is in flight.
- Wrong shape: assume "the prior session's tick is still running" — it died with the prior shell.
- Right shape: re-install the tick at the start of every new session, before any other work, before reading coord, before opening files.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag session-onboarding --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- New Claude session opens; you're operating as a coord lane (K, C, I, E, L, or current sprint's lane names).
- Prior shell exited (cleanly or via crash); the tick PID is stale.
- A merge to `backend/scripts/session-idle-tick.sh` or `install-session-tick.sh` shipped — your local loop is the pre-merge buggy version.
- Tick log shows the loop went silent for >2 minutes.

Voice triggers: "I'm starting Session X", "fresh session", "bootstrapping the coord lane", "first action".

## Workflow

### Phase 1 · Install the tick (canonical path)

If the working tree has the script:

```bash
bash backend/scripts/install-session-tick.sh <SESSION_NAME>
```

Where `<SESSION_NAME>` ∈ `{K, C, I, E, L, ...}` per the current sprint's lane definitions.

This installs a 60-second autonomous idle-detection loop that posts `[session-<X>] idle, no pending work · auto-tick @ <timestamp>` on the active coord PR when the session has nothing in flight.

### Phase 2 · Install the tick (fresh-box path)

If the working tree doesn't have the script (fresh box, no repo cloned), pull from staging:

```bash
mkdir -p ~/.olympus/scripts
gh api "repos/<ORG>/<REPO>/contents/backend/scripts/install-session-tick.sh?ref=staging" \
  --jq '.content' | base64 -d > ~/.olympus/scripts/install-session-tick.sh
gh api "repos/<ORG>/<REPO>/contents/backend/scripts/session-idle-tick.sh?ref=staging" \
  --jq '.content' | base64 -d > ~/.olympus/scripts/session-idle-tick.sh
chmod +x ~/.olympus/scripts/*.sh
bash ~/.olympus/scripts/install-session-tick.sh <SESSION_NAME>
```

The two scripts must be in the same directory — `install-session-tick.sh` calls `session-idle-tick.sh` from `$(dirname $0)`.

### Phase 3 · Verify the install worked

```bash
ps -p $(cat ~/.olympus/session-<X>.tick.pid)   # should show /usr/bin/bash
tail -5 ~/.olympus/session-<X>.tick.log        # within 60s should show a tick entry
```

If `ps` shows nothing, the loop died — re-run the installer. The script is idempotent; it kills any prior loop with the same SESSION_NAME and starts fresh.

### Phase 4 · Read coord state second

Only after the tick is verified:

- Read the current coord PR (top thread in your assignment lane).
- Scan for `@<your-session>` mentions in the last 60 minutes.
- Apply `stale-assignment-detection` (probe production before re-executing) and `path-symmetric-rerouting` (re-route if your env can't satisfy the assignment) as needed.

### Phase 5 · State files reference

| Path | Purpose |
|---|---|
| `~/.olympus/session-<X>.tick.pid` | PID for stop/restart |
| `~/.olympus/session-<X>.tick.log` | Append-only tick log |
| `~/.olympus/session-<X>.tick.state.json` | Last idle-post timestamp (dedupe state) |

Stop the loop: `kill $(cat ~/.olympus/session-<X>.tick.pid)`

## Gotchas

### Don't try to "fix" the tick by editing locally

Pull from staging. Local edits drift; everyone's tick should run the same canonical script. If you find a bug, ship a PR; don't hot-patch your local copy.

### Don't run two ticks for the same session name

The installer kills the prior loop, but if you `bash` the script twice in two different shells, you'll race; only the second wins. Idempotency holds, but you don't know which loop is current without `ps`.

### Don't skip the install because "I'm only here for one task"

The tick takes 5 seconds to install and gives the coord factory a signal that you exist. Without it, your session is invisible — even one-task sessions need the tick so the factory knows when you're done.

### Don't forget to re-install after a session-idle-tick.sh merge

PR #1904 fixed dedupe pagination. Sessions running pre-#1904 had broken dedupe and posted duplicate idle messages. Whenever the canonical script changes, re-install.

### Don't expect the tick to survive machine restart

Detached `nohup` bash loop dies on machine restart by design. Re-install on next session start is the ritual.

## Invariants consulted

- **Invariant 1 · Tick precedes work** — install before reading coord, before any other action.
- **Invariant 2 · Canonical script, not local edits** — pull from staging if your tree's version drifts.
- **Invariant 3 · Visibility = liveness** — without the tick, the cron treats your session as nonexistent.
- **Invariant 4 · Idempotency by design** — re-running the installer is always safe; the script kills the prior loop deliberately.

## Seed lessons

1. **Tick install is the first action, not the second** · P0 · generic. Reading coord before installing the tick means the factory still can't see you when you finish processing the assignment.
2. **Detached bash > cron/launchd/Task Scheduler/agents** · P1 · generic. Tested all of those; platform quirks + minimum-interval limits made them inferior to the portable bash loop.
3. **Pre-#1904 sessions had broken dedupe** · P2 · scoped (specific to this codebase). Re-install whenever the canonical scripts change.
4. **Idempotency is a load-bearing feature** · P2 · generic. The installer killing the prior loop is what makes "re-run on confusion" the right move.
5. **State files belong in `~/.olympus/`, not `/tmp/`** · P3 · generic. `/tmp/` clears on reboot; `~/.olympus/` persists, so the dedupe state survives across sessions.

## Integration

- **`./stale-assignment-detection.md`** — what to do AFTER the tick is installed and you read coord.
- **`./path-symmetric-rerouting.md`** — also AFTER coord-read; re-route if your env can't satisfy the assignment.
- **`/verify-before-claim`** — claims like "session is online" require the tick `ps` + log evidence.

## Completeness principle

10/10: install before any other action, verify with `ps` + tail of log, re-install on every new session and after any canonical-script merge.

7/10: install but skip verification (loop might be dead silently).

3/10: assume the prior session's tick is still running (it isn't; you're invisible to the cron).

**Default: 10/10.** The tick takes 5 seconds; the failure mode (invisible session) is silent and persistent until someone notices nothing is being assigned.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version forged from #1900, #1904, #1907.
