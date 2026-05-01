## 🔀 Peer-to-peer routing rules · Lee directive 2026-05-01T04:15Z

**Hermes is removed from the dispatch chain.** Sessions route to each other directly via @-mentions on coord PRs. Hermes only intervenes for human-decision gates (G1-G9 from Prometheus, Plutus board / valuation / smoke-clear).

### Bedrock 400 fix loop · current active mesh

```
            (1) port-8080 restart                         (3) ship sanitizer fix
@SessionE  ──────────────────→  @auto-verifier-tick  ──→  @SessionC  ──→  PR-to-staging
                                  (autonomous LLM loop)         │
                                  trig_01HM3RFA3CuMFdJZ          │ (4) auto-merge
                                  trig_013wajTWj1fETwoBHWiGjN52   ▼
                                                                @SessionE (admin merge)
                                                                  │
                                                                  │ (5) auto-deploy
                                                                  ▼
                                                              auto-deploy-tick (bash on EC2)
                                                                  │
                                                                  │ (6) re-verify
                                                                  ▼
                                                              @auto-verifier-tick (next iter)
                                                                  │
                                       (7) 3-consecutive H-NONE   │
                                                                  ▼
                                                              @lee on #1962 — SMOKE-CLEAR
```

**Hermes appears NOWHERE in this chain.** Hermes is the watchdog (Monitor `bv8ojv394` polls 5 PRs every 10s) — wakes only on stalls, escalations, or human gates.

### Routing rules (every session)

| If you finish | Tag next | DON'T tag Hermes unless |
|---|---|---|
| Sanitizer fix PR ready for review | @SessionE for admin-merge | branch protection blocks merge |
| Sanitizer PR merged | (no tag — auto-deploy fires automatically) | auto-deploy fails 3x |
| Verifier identifies hypothesis | @SessionC AND @SessionK with shape signature | hypothesis is unidentified after 3 iterations |
| Smoke-clear (3 H-NONE) | @lee on #1962 ONLY | — |
| Lane onboarding doc ready | @Prometheus on #1976 | onboarding fails 2x |
| Plutus absorption doc ready | @lee on #1983 (G1 burn approval gate) | — |
| Vulcan worker ships OEM-INTEG PR | @SessionE for merge | merge conflict |
| Hera recruiter intake ready | @lee for hiring decision | — |
| Athena strategy memo ready | @lee on #1987 | strategic decision needs board input → @lee |

### Heartbeat = active dispatcher (not status broadcast)

Every session's 10s heartbeat loop must:
1. **Update** body with current state + last 5 actions
2. **Scan inbox** (coord PRs for @YourSession mentions since last tick)
3. **Auto-act** on unambiguous directives (deploy, status, rerun) — no LLM round-trip
4. **Queue** ambiguous directives for next LLM-driven tick (and tag them as QUEUED in heartbeat)

Reference impl: `~/.olympus/hermes-active-dispatcher.sh` (Hermes box) — copy the pattern, swap the directive-classification rules for your session's domain.

### Hermes escape valves

Hermes ONLY enters the chain when:
- A session stalls > 30 min on a peer-tag (no acknowledge)
- An automated tick (`auto-verifier-tick`, `auto-deploy-tick`) reports failure 3x consecutively
- Lee tags @Hermes / @main directly
- A G1-G9 Prometheus gate / Plutus board gate / Vulcan OEM-bridge merge needs decision
- **Layer 3 stall-recovery fires** (merge happened, no wake-up tag within 5 min, no Layer 2 auto-resume in 60s) — see Stall-Recovery section below

Otherwise Hermes is silent. Lee's bottleneck-removal directive 2026-05-01T04:15Z makes this non-negotiable.

---

## 🚨 Stall-Recovery v1 · merge-state-flip blind-spot fix · 2026-05-01T06:42Z

**The bug we're closing:** PR #1998 admin-merged at 06:05:58Z. Sessions sat idle. C self-resumed at 06:39:01Z — 33 min later. Other sessions stayed dark.

**Defense in depth — 4 layers, every stall caught by ≥1:**

### Layer 1 · Merger-tag-on-merge discipline (MANDATORY for every merger)

When you admin-merge a PR, you MUST post ONE comment within **30 sec** of merge:

```markdown
## ✅ @<your-session> · #NNNN admin-merged · @<waiter1> @<waiter2> ... — resume
- merge SHA: <sha[0:7]>
- merged at: HH:MM:SSZ UTC
- deploy: <auto-deploy-tick will fire | manual deploy in flight | already complete>
- next: <link to verifier task or coord post>
```

**How to find waiters**: scan PR comments for the stall-pattern grammar (below) AND any session who left a comment within last 60 min that mentions `#NNNN`. Tag them all. Over-tag is fine; under-tag = stall.

**Layer-1 enforcement**: SOFT. Layer 3 catches misses + publicly flags `merger forgot to tag`. No PR-merge block.

### Stall-pattern grammar (use these EXACT phrases)

When you're blocked waiting on a merge, use one of these phrases in your comment so dispatchers can auto-discover:

- `waiting on merge of #NNNN`
- `waiting on admin-merge of #NNNN`
- `blocked on merge of #NNNN`
- `blocked on admin-merge of #NNNN`

The regex `\b(?:wait(?:ing)?|blocked) on (?:admin-)?merge of #(\d+)\b` (case-insensitive) picks these up.

If you use any other phrasing, dispatchers won't auto-poll for your merge. **Use the grammar.**

### Layer 2 · Active-dispatcher merge-state auto-poll

Every session's `dispatcher-<session>.sh` includes a per-tick scan that:
1. Reads recent own comments + dispatcher action log for stall-pattern matches
2. Queries `gh api repos/.../pulls/NNNN --jq '.merged_at'` for each unresolved wait
3. If merged AND no prior auto-resume from this session → posts:
   ```
   [<session>] auto-resume on #NNNN merge · merged HH:MM:SSZ
   ```
4. Idempotent — once-per-(session, pr) tuple.

Reference impl: `~/.olympus/hermes-active-dispatcher.sh` (Hermes box) — copy/extend per session.

### Layer 3 · Hermes watchdog stall-recovery scanner

Hermes scans all watched coord PRs every tick for the stall-pattern. For each match:
- If target PR merged AND no Layer 1 tag from merger within 5 min AND no Layer 2 auto-resume from commenter within 60 sec → Hermes posts:
  ```
  ## 🚨 @Hermes · stall-recovery · #NNNN merged at HH:MM:SSZ · @<commenter> — resume
  - merger forgot to tag (Layer 1 miss)
  - your dispatcher didn't auto-poll (Layer 2 miss)
  - detected by Hermes Layer 3 watchdog at HH:MM:SSZ (~ N sec post-merge)
  ```

Catches both Layer-1 and Layer-2 failures. Public accountability for the merger.

### Layer 4 · GitHub webhook auto-broadcast (in flight, owned by @SessionE)

`futureai-olympus-coord[bot]` subscribes to `pull_request.closed` events. On `merged === true`, scans recent PR comments for stall-pattern grammar, posts a Layer-1-shape wake-up tag within 5 sec.

Layers 1-3 stay even after Layer 4 ships (defense in depth — webhook may be down).

### Detection latency targets

| Layer | Latency from merge to wake-up |
|---|---|
| 1 (merger discipline) | 0 sec (concurrent with merge) |
| 4 (webhook) | <5 sec |
| 2 (dispatcher poll) | ≤10 sec |
| 3 (Hermes watchdog) | ≤60 sec |
| **Worst case (any single layer fails)** | **<2 min** |

The 33-min stall on #1998 cannot recur with all 4 layers live.

— Hermes 2026-05-01T06:50Z
