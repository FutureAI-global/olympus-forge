# Plan · Mesh Protocol v1 · standardize the autonomous collaboration pattern · 2026-05-01T05:42Z

## Context

Tonight (2026-05-01) we executed an autonomous Bedrock-400 fix in **24 minutes end-to-end** with Lee in the loop only twice (initial directive + final SMOKE-CLEAR ping). The chain that worked:

| Time | Event | Owner | Hermes role |
|---|---|---|---|
| 04:25Z | K posts smoking-gun finding (sanitizer NOT the bug) | @SessionK | watchdog |
| 04:31Z | I claims blockSummary upgrade | @session-i (peer-claim) | none |
| 04:37Z | #1991 opened (logging upgrade) | @session-i | none |
| 04:39Z | #1991 admin-merged | @session-e (peer-acted) | none |
| 04:42Z | L re-runs verifier post-deploy, bug still fires | @session-l (peer-acted) | none |
| 04:55Z | E rsyncs + pm2 restarts backend (manual) | @session-e | none (Lee implicit) |
| 05:01Z | K posts H7 root cause + offers fix | @SessionK | none |
| 05:07Z | #1993 opened + admin-merged + deployed | @SessionK + @session-e | none |
| 05:11Z | E posts deploy-complete via GitHub App bot | @session-e + futureai-olympus-coord[bot] | none |
| 05:12Z | Verifier confirms exit 0, no Bedrock 400 | @session-l | watchdog → PushNotification @lee |

Hermes (orchestrator) appeared in the chain ZERO times. Sessions self-claimed, peer-routed, and self-verified. Lee got pinged once when the result was actionable (smoke-clear).

This worked because we built ad-hoc tonight: heartbeat protocol v1 (10s edit-in-place, `~/.olympus/heartbeat-protocol-v1.md`), peer-to-peer routing rules (#1976 comment), 10s coord-PR Monitor (`buoybdaas`), GitHub App tokens (E shipped scaffold, ~15K/hr available across 3 installs), EC2 bedrock-400-watcher (cron), autonomous-verifier CCR routine. We need to **standardize** this into a protocol every session adopts BEFORE the next bug, not invented during it. Lee's role compresses to: human-decision gates (G1-G9, board, valuation, smoke-clear) + (maybe) EC2 resync if we don't fix that gap.

## Mesh Protocol v1 — formal specification

```
                            ┌──────┐
                            │ LEE  │  human-gate decisions only
                            └──┬───┘
                               │ PushNotification on smoke-clear or escalation
                               │
        ┌────────────────────  Coord PR (per-track) ────────────────────┐
        │                                                                │
        ▼                                                                ▼
   pinned heartbeat                                                 inbox poll Monitor
   (edit-in-place 10s)                                              (10s, all coord PRs)
        │                                                                │
        ├──── state-hash skip                                            ├── filter bots + own ticks
        ├──── 5-action log                                               └── wake session on @SessionX
        └──── active-dispatcher: scans inbox + auto-acts                          │
                                                                                  ▼
                                                                            classify directive:
                                                                            ├─ unambiguous → bash auto-act
                                                                            ├─ domain match → claim + start
                                                                            ├─ overload → @session-Y handoff
                                                                            └─ ambiguous → QUEUE for LLM tick

  Domain ownership (canonical)
  ┌──────────────────────────────────────────────────────────┐
  │  @SessionC  — sanitizers, validators, parser fixes       │
  │  @SessionK  — orchestrator rules, Constitution, logging  │
  │  @SessionE  — admin merges, deploy chain, EC2 ops        │
  │  @SessionI  — verifier scenarios, TUI/UX, docs           │
  │  @session-l — harness, smoke runs, ground-truth capture  │
  │  @Hermes    — watchdog, stall escalation, human-gate ask │
  │  @Prometheus — building pillar (8 lanes, 47 sessions)    │
  │  @Plutus    — fundraising pillar (12 sessions)           │
  │  Lane leads — Vulcan/Janus/Apollo/Themis/Daedalus/etc    │
  │              auto-claim within their lane scope          │
  └──────────────────────────────────────────────────────────┘

  Bash autonomy (no LLM in loop, runs on EC2 cron)
  ┌──────────────────────────────────────────────────────────┐
  │  bedrock-400-watcher.sh    — tail pm2 logs, post shape   │
  │  auto-verifier-tick        — run scenario, classify,     │
  │                              dispatch C+K or @lee        │
  │  auto-deploy-tick          — main HEAD diff → resync +   │
  │                              pm2 restart (gated · TBD)   │
  │  prometheus-heartbeat      — Prometheus + lane leads     │
  │                              edit-in-place every 10s     │
  └──────────────────────────────────────────────────────────┘

  Auth: 3× GitHub App installations = 15K/hr aggregate
  ─────────────────────────────────────────────────────────
    auto bucket   (futureai-auto · 5K/hr) · primary code
    forge bucket  (olympus-forge · 5K/hr) · skills + harness
    brain bucket  (futureai-brain · 5K/hr) · docs + RFCs
    Sessions round-robin via `get-installation-token.sh <bucket>`
    Bypasses Win11 keyring corruption, isolates from Lee's PAT.
```

## Components (stack)

| Layer | Component | Status today | Owner | File location |
|---|---|---|---|---|
| **L1 · Auth** | GitHub App `FutureAI-Olympus-Coord` (3 installs = 15K/hr) | E shipped scaffold, Lee installs (~10 min) | E + Lee | `~/.olympus/harness/github-app/{manifest.json, get-installation-token.sh, INSTALL.md}` (E's Mac) |
| **L2 · Heartbeat** | 10s edit-in-place pinned comment per session | Hermes piloted live, Prometheus piloted live | each session | `~/.olympus/heartbeat-protocol-v1.md` |
| **L3 · Inbox poll** | 10s coord-PR Monitor that wakes session on @-mention | Hermes piloted (`buoybdaas`) | each session | `~/.olympus/coord-state/watch-coord-prs.sh` |
| **L4 · Active-dispatcher** | Heartbeat loop reads inbox + auto-acts on unambiguous directives | Hermes piloted (PID 140479) | each session | `~/.olympus/hermes-active-dispatcher.sh` (reference impl) |
| **L5 · Peer-routing rules** | Sessions tag each other; Hermes only on stall/gate | posted on #1976 | mesh-wide | `~/.olympus/peer-to-peer-routing-rules.md` |
| **L6 · EC2 cron watchers** | Bash daemons that observe + post (no LLM) | bedrock-400-watcher INSTALLED but no gh-auth; auto-deploy-tick GATED | E + Hermes | `~/.olympus/ec2-bedrock-400-watcher.sh`, `~/.olympus/ec2-auto-deploy-tick.sh` |
| **L7 · CCR autonomous routines** | 1-hour cron with internal 55-iter loop | `trig_01HM3RFA3CuMFdJZPjU393zM` (one-shot) + `trig_013wajTWj1fETwoBHWiGjN52` (hourly) live | Hermes spawns, sessions consume | `RemoteTrigger create` recipe in this plan |
| **L8 · Stall escalation** | >30 min no peer ack → Hermes intervenes; >30 min Hermes can't unblock → @lee | embedded in routing rules | Hermes | rules in §peer-to-peer-routing-rules.md |
| **L9 · Notify-once-on-action** | PushNotification only when Lee can act | piloted at smoke-clear | every session | TBD: shared `notify-lee.sh` helper (proposed) |

## Per-session adoption checklist (every Claude session, local + EC2)

Each session, when it boots, runs this onboarding script (~5 min):

1. **Pin heartbeat comment** on its primary coord PR
   - Local sessions (E/C/K/I/L): `~/.olympus/onboard-mesh.sh <session-name> <coord-pr>`
   - EC2 sessions (Prometheus/lane-leads/Plutus): `prometheus-spawn.sh` includes onboarding
2. **Source GitHub App token helper** so all `gh` calls draw from App bucket, not Lee's keyring
   - `export GH_TOKEN=$(~/.olympus/harness/github-app/get-installation-token.sh <bucket>)`
3. **Start active-dispatcher loop** in background (`nohup` or pm2)
   - Reads inbox, scans @-mentions, auto-acts, updates heartbeat with action log
4. **Start coord-PR Monitor** (10s polling its watched PRs)
   - On @-mention, wakes the LLM session for non-trivial classification
5. **Register domain ownership** — session declares its lane in initial heartbeat body
   - Lets peer-routing rules pick the right next session automatically

Onboarding script `~/.olympus/onboard-mesh.sh` (proposed, ships in rollout Phase 2):

```bash
#!/usr/bin/env bash
# Usage: onboard-mesh.sh <session-name> <coord-pr> <bucket=auto>
SESSION=$1; COORD_PR=$2; BUCKET=${3:-auto}
# 1. App token
export GH_TOKEN=$(~/.olympus/harness/github-app/get-installation-token.sh $BUCKET)
# 2. Pin heartbeat
COMMENT_ID=$(gh api -X POST "repos/FutureAI-global/futureai-auto/issues/${COORD_PR}/comments" \
  -f body="$(printf '## 🫀 %s live heartbeat · edit-in-place · 10s cadence\n\n_initializing %s_\n' "$SESSION" "$(date -u +%H:%MZ)")" --jq '.id')
echo "$COMMENT_ID" > ~/.olympus/heartbeat-${SESSION}.id
# 3. Start active-dispatcher loop in background
nohup bash ~/.olympus/dispatcher-${SESSION}.sh > ~/.olympus/dispatcher-${SESSION}.log 2>&1 &
echo $! > ~/.olympus/dispatcher-${SESSION}.pid
# 4. Start coord-PR Monitor (Claude-side, via Monitor tool — handled by session itself)
echo "Mesh onboarding complete: heartbeat=#${COORD_PR}/${COMMENT_ID}, dispatcher=PID $(cat ~/.olympus/dispatcher-${SESSION}.pid)"
```

## The single open architectural question · auto-deploy

**Today's friction**: After PR merges to staging → main, EC2's running backend src tree (`/home/ec2-user/futureai-backend/src/`) does NOT auto-update. Someone (E, manually) must rsync from `/home/ec2-user/futureai-new/` (which DOES auto-pull from main every 5 min) AND `pm2 restart backend`. That's the one human-touch in the #1993 chain.

**Two options for closing the gap:**

| Option | Risk | Latency | Lee's involvement |
|---|---|---|---|
| **A · auto-deploy-tick installed unconditionally** | High (CLAUDE.md says NEVER restart pm2 backend during business hours; ELB-routed live tech sessions die) | <2 min from main HEAD diff to running | none after install |
| **B · time-gated auto-deploy** (00:00-12:00 UTC = 5pm-5am PT) | Medium (off-hours window) | <2 min during window; manual outside | none in window; E manual outside |
| **C · co-sign auto-deploy** (require comment from latest commit author within 5 min OR @lee tag on the PR) | Low (every restart has explicit human acknowledgment) | <5 min when co-sign present | E or Lee tags within 5 min |
| **D · keep manual** (status quo, accept E handles it) | None | 5-15 min when E available | Lee asks E to deploy when needed |

**Recommendation**: B (time-gated) + C (co-sign) combined → installs as cron `* * * * *` but only fires when (current UTC ∈ [00:00, 12:00] OR a co-sign comment from the merge-commit author exists within 5 min of merge). Best of both: zero-touch off-hours, co-sign during business hours, never blind.

## Rollout phases

### Phase 0 · Lee gate (~10 min, blocks all subsequent phases)

Lee actions:
1. **Install GitHub App** 3 times (futureai-auto + olympus-forge + futureai-brain), per E's INSTALL.md → unlocks 15K/hr aggregate budget
2. **Approve auto-deploy option B+C** (or pick A or D) → unlocks Layer 6 install
3. **Approve mesh-onboard rollout** to all sessions

### Phase 1 · Hermes consolidates artifacts (~30 min after Phase 0)

Hermes (this session, locally):
1. Commit existing mesh artifacts to repo at `docs/mesh/`:
   - `heartbeat-protocol-v1.md`
   - `peer-to-peer-routing-rules.md`
   - `MESH_ROLLOUT.md` (this plan)
2. Add `~/.olympus/onboard-mesh.sh` (per-session onboarding script) to `olympus-forge` repo
3. Update domain-ownership table on #1976 (canonical source of truth)
4. Rotate Hermes's own dispatcher to use App token (drop Lee's PAT)

### Phase 2 · E ships infrastructure (~30 min, parallel to Phase 1)

E owns:
1. Update `get-installation-token.sh` for multi-install (per my earlier dispatch on #1962/4357876910)
2. Push GitHub App scaffold to `olympus-forge` so all sessions can pull
3. Author + ship auto-deploy-tick.sh (option B+C per Lee's pick)
4. Install bedrock-400-watcher with App token (currently no gh-auth blocks posting)

### Phase 3 · Each session adopts (~5 min per session, parallel)

Sessions onboard one-by-one or in parallel:
- **Local**: E, C, K, I, L each run `onboard-mesh.sh <name> <pr>` from their box
- **EC2 Prometheus + lane leads**: FutureClaw spawns lane leads with onboarding baked in (`prometheus-spawn.sh` includes mesh init)
- **EC2 Plutus + 12 workers**: same — spawn includes onboarding

Verification per session: heartbeat appears on coord PR within 30s, dispatcher PID alive, App token pulled successfully.

### Phase 4 · Verify mesh end-to-end (~30 min)

Synthetic test scenario: drop a deliberate bug-shaped PR (e.g. small TypeScript error, easily fixed). Watch the mesh:
- bedrock-400-watcher OR auto-verifier OR a session detects
- session that detects posts smoking-gun finding tagging domain owner
- domain owner self-claims via active-dispatcher
- ships fix → another session reviews → E auto-merges → auto-deploy fires → re-verify clean → @lee notified once

Acceptance: full chain executes <30 min without Hermes intervention.

### Phase 5 · Pheme (PR pillar) added (post-launch · separate plan)

Third triangle pillar (PR / press / marketing) is OUT OF SCOPE for this plan; mentioned only because mesh extends naturally — Pheme + lane workers onboard the same way.

## Critical files

| File | Owner | State |
|---|---|---|
| `~/.olympus/heartbeat-protocol-v1.md` | Hermes | Written, in-flight commit to `olympus-forge/docs/mesh/` |
| `~/.olympus/peer-to-peer-routing-rules.md` | Hermes | Written, posted on #1976, in-flight commit |
| `~/.olympus/onboard-mesh.sh` | Hermes | DRAFT, ships in Phase 1 |
| `~/.olympus/coord-state/watch-coord-prs.sh` | Hermes | Live, reference impl for other sessions |
| `~/.olympus/hermes-active-dispatcher.sh` | Hermes | Live (PID 140479), reference impl |
| `~/.olympus/harness/github-app/{manifest.json, get-installation-token.sh, INSTALL.md}` | E | On E's Mac, not pushed yet · Phase 2 |
| `~/.olympus/ec2-bedrock-400-watcher.sh` | Hermes | Installed on i-09b8c27f4be7c9891 cron, no gh-auth · Phase 2 fix |
| `~/.olympus/ec2-auto-deploy-tick.sh` | Hermes | Drafted, install gated on Lee's option pick · Phase 2 |
| `RemoteTrigger trig_01HM3RFA3CuMFdJZPjU393zM` | Hermes | Live one-shot autonomous-verifier (~50 min) |
| `RemoteTrigger trig_013wajTWj1fETwoBHWiGjN52` | Hermes | Live hourly autonomous-verifier (recurring) |

## Delegated execution (which sessions own which rollout pieces)

| Phase | Owner | What they do | Dependency |
|---|---|---|---|
| 0 | Lee | App installs, auto-deploy option pick | none — manual |
| 1 | Hermes | Commit mesh docs to repo, write onboard-mesh.sh, update domain-ownership table | Phase 0 |
| 2a | E | Multi-install token helper, push App scaffold to forge, install bedrock-400-watcher with App auth, ship auto-deploy-tick (option B+C if approved) | Phase 0 |
| 2b | K | Constitution amendment for paper-only first-principles ranking (in-flight from #1989/4357992641) | none — already dispatched |
| 2c | I | NarrationBlock streaming flicker fix (in-flight from #1962/4357962487) | none — already dispatched |
| 3 | every session | run `onboard-mesh.sh` from their box | Phases 1 + 2a |
| 4 | Hermes + L | author synthetic-bug verification scenario, observe full mesh chain | Phase 3 |

## Verification

| Gate | Passes when |
|---|---|
| **G-Mesh-1 · Heartbeat live** | Every session has a pinned `🫀` comment on its coord PR with `Last tick:` <30s old |
| **G-Mesh-2 · Inbox poll alive** | Each session's Monitor task ID is registered + emits notifications on @-mention within 10s |
| **G-Mesh-3 · Active-dispatcher routing** | At least one auto-handled action per session per 5 min (bash, no LLM) — visible in heartbeat's "Last 5 actions" |
| **G-Mesh-4 · Peer-routing without Hermes** | Verify a synthetic bug-fix chain completes in <30 min with Hermes not intervening |
| **G-Mesh-5 · API budget under ceiling** | 15K/hr ceiling holds across all sessions × 10s heartbeat × state-hash skip |
| **G-Mesh-6 · Lee notified only on actionable** | PushNotification fires only on smoke-clear or genuine escalation; routine progress = silent |
| **G-Mesh-7 · Auto-deploy gap closed** | Lee's role for routine deploys = zero (Phase 0 option B+C live) |

## Risk register

| Risk | Mitigation |
|---|---|
| Two sessions claim same task simultaneously | First-comment-wins protocol: claiming session posts `🚧 claiming X · @<session>` comment within 5s of detection. Other sessions defer on observing. Active-dispatcher reads claim comments before claiming. |
| API budget blow-out (15K/hr) | State-hash skip mandatory; per-session bucket assignment; live budget-meter in each heartbeat body |
| Active-dispatcher mis-classifies + auto-acts wrong | Conservative classifier — defaults to QUEUE not auto-act on ambiguous; escalates to LLM if confidence <90% |
| EC2 cron daemons drift / get killed | pm2 manages them under `pm2 save` so they survive reboots; weekly health-check via Prometheus heartbeat |
| GitHub App token expires (60-min cache) | `get-installation-token.sh` auto-refreshes when within 5 min of expiry; transparent to consumer |
| Auto-deploy fires during business hours, kills tech | Option B time-gate + Option C co-sign protect both directions |
| Mesh becomes "auto-narration spam" — Lee can't find signal | Heartbeats use edit-in-place (no scroll flood); push-notification gating discipline; Lee can mute coord PRs and rely on smoke-clear-only PushNotifications |
| Sessions disagree on domain ownership | #1976 holds canonical domain-ownership table; ambiguous PRs default to round-robin within the lane |

## Out of scope (for this plan)

- Pheme PR pillar (separate plan)
- Visual TUI flicker fix (in-flight from session-i, separate concern)
- Constitution amendment for paper-only ranking (in-flight from K, separate concern)
- Plutus fundraise execution (separate Plutus plan, mesh adoption inherits)
- Anthropic API budget management (separate from GH budget)
- Bedrock cost ceilings (separate)

## Lee's input — needed before Phase 1 fires

| Item | Lee's call |
|---|---|
| Install GitHub App 3× (auto, forge, brain) | YES / NO / DELEGATE TO E? |
| Auto-deploy option | A / B / C / B+C / D |
| Mesh rollout to all sessions | YES — proceed Phase 1 / WAIT — let me review first |
| Push-notification policy | smoke-clear only / smoke-clear + escalations / verbose during pilot |
