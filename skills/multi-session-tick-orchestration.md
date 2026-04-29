---
name: multi-session-tick-orchestration
namespace: session-lessons
version: 0.1.0
description: |
  Pattern for N coordinated autonomous sessions each running their own
  60-second polling tick against a shared coord-PR bus. Encodes the three
  iterations the loop needed before it stopped misfiring: per-session idle
  heartbeat with last-seen cursor, slurped pagination for arithmetic on
  multi-page responses, and a 3-state tick (idle, in-flight, long-running)
  that prevents re-assignment of work already in progress.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a 3-PR cascade in which a multi-session autonomous coordination loop misfired with false-idle reports, dropped dispatches, and duplicate ships before the per-session tick was hardened.
---

# multi-session-tick-orchestration · N-session autonomous loop, three lessons

## Why this exists

A naive "every session posts idle when it has no in-flight PRs" loop looks correct on paper and fails three different ways in practice. Each failure mode wastes a sprint until it gets caught: false-idle reports trigger duplicate assignments, freeform mentions silently bypass pattern matchers, and long-running work gets re-assigned to siblings while the original session is still shipping.

This skill encodes the three iterations the pattern needed: the foundation tick with state-cursor, the pagination-arithmetic fix, and the 3-state tick with a `long-running` band that keeps the factory from stealing in-progress work.

The cost of getting this wrong is duplicate PRs, conflicting branches, and wall-clock minutes burned on "did anyone get this assignment?" debugging. The cost of getting it right is one weekend of skill-encoding plus 60 seconds of per-session install.

## Preamble (run first)

```bash
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')

if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag tick-orchestration --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

1. About to design or operate an N-session autonomous coordination loop on a shared bus
2. About to write a per-session polling script that posts heartbeat plus reads dispatches
3. About to count open PRs across multiple pages of `gh pr list --paginate` output
4. A session has reported `idle` while actually shipping a long-running PR
5. A session has been re-assigned a task it already accepted within the last assignment window
6. Considering moving the polling loop to system cron versus an in-shell sleep loop

Voice triggers: "set up the auto-tick", "sessions keep double-claiming", "false idle", "the factory re-dispatched".

## Workflow

### Phase 1 · Per-session tick foundation

```bash
# Each session installs ~/.claude/scripts/session-tick.sh with a state file
STATE_FILE="$HOME/.cache/<coord-cache-dir>/session-${SESSION_ID}-last-comment.id"
mkdir -p "$(dirname "$STATE_FILE")"

while true; do
  IN_FLIGHT=$(gh pr list --author "@me" --search 'is:open label:active' --json number | jq 'length')
  if [ "$IN_FLIGHT" -eq 0 ]; then
    # heartbeat (with dedupe, see Phase 4)
    gh pr comment "$COORD_PR" --body "[session-${SESSION_ID}] idle, no pending work · auto-tick @ $(date -u +%FT%TZ)"
  fi

  # Read new comments since cursor and execute matching assignments
  LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  # ... process comments with id > LAST, then update STATE_FILE
  sleep 60
done
```

Bash chosen over cron / launchd / Task Scheduler because the loop stays in the user's running shell. Lower latency, easier to kill, transactions visible in tail.

### Phase 2 · Slurp before counting paginated output

```bash
# WRONG: returns last page's length only
COUNT=$(gh pr list --paginate --json number | jq '. | length')

# RIGHT: -s slurps all pages into one array first
COUNT=$(gh pr list --paginate --json number | jq -s 'add | length')
```

Any arithmetic on `--paginate` output requires `jq -s`. Without it, sessions with over 100 open PRs across pages report false-idle and get re-assigned in-flight work.

### Phase 3 · Adopt the 3-state tick

Replace boolean `idle / in-flight` with `idle / in-flight / long-running`:

| State | Definition | Heartbeat behavior |
|---|---|---|
| `idle` | Zero open PRs labeled active | Post `idle` (with dedupe) |
| `in-flight` | One or more open PRs, last commit under threshold | Skip heartbeat |
| `long-running` | Open PR with branch checked out > LONG_RUNNING_THRESHOLD_SECONDS, no new commits > STALE_COMMIT_THRESHOLD_SECONDS, no `idle` post yet | Skip heartbeat (factory MUST NOT re-assign) |

Suggested defaults: `LONG_RUNNING_THRESHOLD_SECONDS=1800`, `STALE_COMMIT_THRESHOLD_SECONDS=600`. Tune per session-class: fast sessions doing merges need 1 to 2 minutes, slow sessions shipping bundles need 30 to 60.

### Phase 4 · Dedupe heartbeats

Do not repost `idle` if the most recent comment from this session is already an `idle` younger than 5 minutes. Without dedupe, the bus fills with redundant heartbeats and human readers cannot find dispatches in the noise.

### Phase 5 · Cross-check before assigning

The coord PR's heartbeat stream is a hint, not a contract. Before the factory dispatches a task to a session, cross-check with `gh pr list --author <session> --state open --search 'label:active'`. If anything matches, the session is busy; pick another receiver.

## What NOT to do

- Cron at sub-minute intervals. System cron's minimum granularity is one minute on Linux, macOS, and Windows Task Scheduler (with workarounds). A bash sleep-loop is simpler and more responsive.
- Polling every comment-fetch with no since-cursor. Burns API quota; a long-lived coord PR has hundreds of comments. Always use a `since-comment-id` cursor.
- Posting `idle` every tick regardless of staleness. Generates comment spam that buries directed dispatches.
- Treating the coord PR as authoritative for in-flight state. It is a hint, not ground truth. Always cross-check with `gh pr list` before assigning.
- One global `ASSIGNMENT_WINDOW_SECONDS` for all session classes. Coord-fast sessions and coord-slow sessions need different windows. Per-session config.

## Seed lessons

### Lesson 1 · `--paginate | jq '. | length'` reports last-page count

A session's tick used `--paginate` piped to `jq '. | length'` to count its own open PRs. The arithmetic returned only the last page's count. Sessions with over 100 open PRs across pages reported false-idle and were re-assigned in-flight work. The fix: `jq -s 'add | length'`. Generalizes to all paginated arithmetic.

### Lesson 2 · narrow assignment window re-dispatches in-progress work

`ASSIGNMENT_WINDOW_SECONDS=300` (5 minute lookback) was too narrow for sessions whose tasks took longer than 5 minutes. A session picking up work at T0 with execution time over 5 minutes was treated as `idle` again at T+5min30s, got re-assigned the same task, shipped duplicate PRs. The fix: 3-state tick with explicit `long-running` band that signals "still working, do not steal."

### Lesson 3 · freeform mentions bypass autonomous pattern matchers

Freeform `@<session-name>` mentions did not match the camel-case or bracketed envelope pattern the autonomous tick was greping for. Dispatches went invisible. The fix: enforce the canonical envelope shape, verify pickup within two to three ticks, repost in canonical format if the receiver keeps posting `idle`.

### Lesson 4 · in-shell loop beats system cron for autonomous sessions

A first-pass design used cron to fire the tick. Cron's minute-granularity, plus the cost of restarting the Claude shell each fire, plus invisible failures when cron's environment differed from the user's shell, made the loop unreliable. The fix: bash sleep-loop in the user's running Claude shell, killable with Ctrl-C, output visible in tail.

### Lesson 5 · heartbeat dedupe is not optional past 5 sessions

With 5 sessions ticking every 60 seconds and no dedupe, the coord PR accumulates 300 idle posts per hour. Human readers cannot find dispatches; autonomous siblings have to walk past each idle to find the next directed message. The fix: do not repost `idle` if the most recent comment from self is already an `idle` younger than 5 minutes.

## Invariants consulted

- `Invariant 1 · Run the check before claiming`. The cross-check step (`gh pr list --author <session>`) is a "run the check" gate before dispatch lands.
- `Invariant 10 · Completeness trumps brevity (Boil the Lake)`. The 3-state tick costs 30 lines more than the boolean tick and prevents an entire class of duplicate-ship bugs.

## Integration points

- Pairs with `coord-pr-as-message-bus`. The substrate the ticks run on; this skill defines the polling cadence, that one defines the envelope conventions.
- Pairs with `dispatch-format-pickup-verification`. The sender-side ritual that confirms a dispatch landed; this skill is the receiver-side polling that does the landing.
- Pairs with `verify-receipts-before-flawless-claim`. After the tick fires a `shipped: PR #<n>` heartbeat, the receipt-verification skill catches false claims before they reach the operator.

## Completeness principle

This skill DOES NOT fire for single-session workflows or for short-lived helper scripts that fire once and exit. It fires the moment a second session is ticking against the same bus.

False-negative cost (skipping the 3-state tick on a real multi-session loop): duplicate PRs, conflicting branches, wall-clock hours debugging "who shipped that?". False-positive cost (running the 3-state tick on a solo workflow): the boolean check and the 3-state check are both O(1) per tick. Default to the 3-state shape.

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a 3-PR cascade in which a multi-session autonomous coordination loop misfired with false-idle reports, dropped dispatches, and duplicate ships before the per-session tick was hardened.
