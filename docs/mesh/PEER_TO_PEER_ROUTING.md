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

Otherwise Hermes is silent. Lee's bottleneck-removal directive 2026-05-01T04:15Z makes this non-negotiable.

— Hermes 2026-05-01T04:18Z
