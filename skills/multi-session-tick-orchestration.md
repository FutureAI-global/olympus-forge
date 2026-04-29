---
name: multi-session-tick-orchestration
namespace: session-lessons
version: 0.1.0
description: |
  N-session autonomous coordination loop. Encodes the 3-iteration cascade
  (idle-tick foundation, dedupe-pagination fix, 3-state tick) that takes a
  naive multi-session coord loop from "30-min false idles + duplicate
  shipments" to deterministic 60s pickup. Fire when designing or debugging
  any cron/loop that polls a shared bus and dispatches work to N peers.
allowed-tools:
  - Bash
provenance: forged 2026-04-29 from a 3-PR cascade in the Olympus multi-session ecosystem (PRs #1900 + #1904 + #1907) where each iteration fixed a specific class of misfire that the naive shape didn't anticipate. The third iteration was needed because long-running sessions kept getting their work re-assigned mid-flight.
---

# multi-session-tick-orchestration · N-session autonomous loop, three lessons

## What this is

A pattern for N coordinated session-Claudes (or N agents of any kind) each running their own 60-second autonomous tick that polls a shared coord-PR thread, posts an `idle` heartbeat when no in-flight work, and gets routed work by a central factory tick when the backlog has matching items.

This skill encodes the three iterations the pattern needed before it stopped misfiring.

## The naive shape (what doesn't work)

```bash
# every session-X cron, every 60s
if [[ $(in_flight_pr_count) -eq 0 ]]; then
  gh pr comment $COORD_PR --body "[session-X] idle"
fi
```

Three bugs the naive shape ships with:

**Bug 1 (pagination):** `gh pr list --paginate` emits one JSON array per page. `jq '. | length'` against a multi-page response gives the LAST page's length, not the total. Sessions with 100+ open PRs across pages report `idle` falsely.

**Bug 2 (lookback window):** A fixed `ASSIGNMENT_WINDOW_SECONDS=300` (5min) is too narrow. A session picking up work at T0 with execution time > 5min is treated as `idle` again at T+5:30, gets re-assigned the same task, ships duplicate PRs.

**Bug 3 (envelope mismatch):** Freeform `@session-x` mentions don't match camel-case `@SessionX` autonomous-tick patterns. Dispatches go invisible. (See `dispatch-format-pickup-verification`.)

## The fix (3-PR cascade)

### PR #1 · session-idle-tick.sh foundation

- Each session installs its own `~/.claude/scripts/session-tick.sh` with a state file at `~/.cache/<ecosystem>/session-X-last-comment.id`
- 60s loop: check open-PR count for self → post `idle` if zero → read coord-PR comments since last seen → execute any matching assignment
- Bash sleep-loop chosen over cron / launchd / Task Scheduler so the loop stays in the user's running shell (lower latency, easier to kill, transcript visible in tail)

### PR #2 · dedupe-pagination fix

- Replace `gh pr list --paginate ... | jq '. | length'` with `gh pr list --paginate ... | jq -s 'add | length'`
- The `-s` (slurp) merges all pages into one array first
- Lesson generalizes: ANY arithmetic on `--paginate` output needs `-s`

### PR #3 · 3-state tick

- Replace boolean `idle / in-flight` with `idle / in-flight / long-running`
- `long-running` = open PR with branch checked out >30min, no new commits >10min, no `idle` post yet
- Long-running sessions skip the `idle` post (so factory doesn't re-assign their current work to a sibling)
- New env: `LONG_RUNNING_THRESHOLD_SECONDS=1800`, `STALE_COMMIT_THRESHOLD_SECONDS=600`

## Anti-patterns (avoid these)

- **Cron at sub-minute intervals** — system cron min granularity is 1 min everywhere (Linux/Mac/Windows). Bash sleep-loop is simpler and more responsive.
- **Polling every comment-fetch with no since-cursor** — burns API quota; coord PRs balloon to 600+ comments. Always use a `since-comment-id` cursor.
- **Posting `idle` every tick regardless of staleness** — generates comment spam. Dedupe: don't repost `idle` if last comment from this session is already an `idle` < 5 min old.
- **Treating coord PR as authoritative for in-flight state** — it's a hint, not a contract. Always cross-check with `gh pr list --search "label:session-X"` before assigning.
- **One global `ASSIGNMENT_WINDOW` for all session types** — coord-fast sessions (merger doing PR merges) need 1-2min; coord-slow (build session shipping bundles) needs 30-60min. Per-session config.
- **Trusting the receiver to handle a freeform dispatch** — see `dispatch-format-pickup-verification`. Receivers' tick patterns are strict; envelopes must match.

## Cross-reference

- `coord-pr-as-message-bus` — the bus the tick polls
- `dispatch-format-pickup-verification` — verify dispatches you send actually get picked up by these ticks
- `stale-assignment-detection` — receiver-side check before executing an assignment
