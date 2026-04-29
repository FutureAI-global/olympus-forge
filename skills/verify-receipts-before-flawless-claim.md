---
name: verify-receipts-before-flawless-claim
namespace: session-lessons
version: 0.1.0
description: |
  Triggers when the user or orchestrator asks "is everything flawless / all
  sessions executing / shipped to production?" Encodes the fetch-and-show-
  receipts pattern instead of vibes-based answers. Fire BEFORE responding
  to any "is X working?" question so the answer leads with verified receipts
  and surfaces gaps with PR/comment IDs.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-04-29 when answering "is every other session executing flawlessly" required fetching merge log + coord activity + deploy status to discover one session had not picked up a freshly dispatched assignment. The receipt-led answer turned a "yes everything's fine" non-answer into actionable course correction within 30 seconds.
---

# verify-receipts-before-flawless-claim · never answer "is X flawless" with vibes

## Why this exists

The orchestrator asks: "is every session executing flawlessly and deploying everything flawlessly to production?"

The vibes answer: "yes, everything is shipping clean."

The truth (often): one of the sessions is silently stuck. A dispatch wasn't picked up. A PR is open but blocked on CI. A bundle promoted to staging but not main. The "everything is flawless" answer hides the gap and prevents the orchestrator from acting on it.

This skill says: **never answer flawless-claim questions without showing receipts.**

## The receipt set

Pull these in parallel before answering:

```bash
# 1. Recent merges (production = what's actually live)
gh pr list --repo <repo> --state merged --limit 8 \
  --json number,title,mergedAt,baseRefName \
  --jq '.[] | "\(.mergedAt[11:16]) | \(.baseRefName) | #\(.number) | \(.title[0:80])"'

# 2. Open PRs (in-flight work + their CI state)
gh pr list --repo <repo> --state open --limit 20 \
  --json number,title,mergeStateStatus,headRefName

# 3. Recent coord PR activity (sessions saying "idle" vs "shipping")
gh api 'repos/<repo>/issues/<coord-pr>/comments?per_page=100&page=<last>' \
  --jq '.[-15:] | .[] | "\(.created_at) | \(.user.login) | \(.body[0:140])"'

# 4. Latest production deploy SHA / tag
gh release view --json tagName,publishedAt 2>/dev/null || \
  git log origin/main --format='%h %s' -5
```

## The answer shape

Structure the response so the orchestrator can spot a gap in 3 seconds:

```
**Production:**
- <bundle> promoted staging→main at <UTC> (#<num>). Latest live.
- <list of recent merges with timestamps>

**Sessions:**
- A, B, C, D currently <state> per their auto-tick on Coord PR #<num>.
- One snag: <specific gap, with PR # or comment ID and timestamp> — <root cause if known>.

<one-line recommendation if gap exists>
```

Notice: **always lead with what's true and verified, then call out the gap.** Don't bury the gap in a sea of green.

## Anti-patterns

- "Everything looks great!" — meaningless, no receipts, no specific PR/SHA.
- "I think X is shipping." — "I think" = no verification = lie risk.
- "All sessions idle." — incomplete; idle could mean done OR stuck on a dispatch they didn't see.
- "We're at ~80%." — receipts don't have percentages; they have PRs and timestamps.

## Worked example

The 2026-04-29 v8 sprint check-in:

The orchestrator asked: "is every other session executing flawlessly?"

Wrong answer: "Yes, everything is shipping clean — v0.7.4 just promoted to main."

Right answer (what shipped):

> Honest answer — mostly yes, with one stuck thread:
>
> **Production:**
> - v0.7.4 promoted staging→main at 00:12Z (#1935). Latest bundle live.
> - v8 trio (#1925/1926/1927) + plugin loader + script runner + billing migration all merged clean to staging in the last 2 hours.
>
> **Sessions:**
> - All 4 sibling sessions firing "idle, no pending work" auto-ticks every 1-2 min on coord PR.
> - One snag: K hasn't picked up the marketing migration dispatch. Posted at 00:21Z, K's auto-tick fired idle at 00:20:47Z and again at 00:26:09Z — meaning K's autonomous routine isn't recognizing my freeform `@session-k` comment as an assignment.
>
> Want me to repost the dispatch as a structured assignment so K's tick picks it up next cycle?

The honest answer turned a "yes everything is fine" non-answer into actionable course correction within 30 seconds.

## Cross-reference

- `dispatch-format-pickup-verification` — how to detect a dispatch wasn't picked up
- `dispatched-pr-content-verification` — the next-level check after a PR opens
