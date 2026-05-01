## 🗺️ Mesh Protocol v1 · canonical domain-ownership table · Lee approved 2026-05-01T05:50Z

This is the SOURCE OF TRUTH for which session owns which domain. Sessions read this when peer-routing. If your finding falls in someone's lane, tag them — don't tag Hermes.

### Local-box sessions (Lee's machines)

| Session | Domain | Coord PR (primary) | Box |
|---|---|---|---|
| **@Hermes** (`@main`, `@SessionMain`) | watchdog · stall escalation · human-gate ask · meta-orchestration | #1962 (v8 ship) | local Win11 |
| **@SessionE** | admin merges · deploy chain · EC2 ops · production readiness | #1989 (active) / #1962 | local Mac |
| **@SessionC** | sanitizers · validators · parser fixes · upstream type-shape correctness | #1989 / #1977 | local Win11 |
| **@SessionK** | orchestrator rules · Constitution · structured logging · TUI streaming path | #1989 / forge | local Mac |
| **@SessionI** | verifier scenarios · TUI / UX components · docs · acceptance tests | #1962 (smoke / docs) | local Mac |
| **@session-l** | harness · smoke runs · ground-truth capture · canonical verifier | #1962 / #1989 | local Mac |

### EC2 pillar leads + lane workers

| Session | Domain | Coord PR | Box |
|---|---|---|---|
| **@Prometheus** | building pillar root · 8 lanes · 47 workers | #1976 | EC2 i-05f74eb0c9a3be7ec |
| **@Plutus** | fundraising pillar root · 12 workers · cap table + raise + close | #1983 | EC2 (Prometheus host) |
| **@Vulcan** | OEM-INTEG lane (10 workers · GM/Stellantis/Hyundai/Toyota/Nissan/Honda/VW/Subaru/MB/BMW) | #1978 | EC2 |
| **@Janus** | MCP lane (4 workers · MCP server + agent SDK + connectors) | #1979 | EC2 |
| **@Apollo** | Models lane (4 workers · prompt eng + fine-tune + eval) | #1980 | EC2 |
| **@Themis** | Constitution lane (3 workers · MUST-rules + § sections + amendments + ingestion) | #1981 | EC2 |
| **@Daedalus** | Surfaces lane (6 workers · TUI + web + mobile + brand) | #1982 | EC2 |
| **@Asclepius** | Stabilization lane (4 workers · regression + flake + perf) | #1986 | EC2 |
| **@Athena** | Strategy lane (4 workers · corp dev + acquisitions + frontier-vehicles + frontier-fleet) | #1987 | EC2 |
| **@Hera** | Talent / Admin lane (3 workers · recruiting + ops-compliance + legal-ops) | #1988 | EC2 |

### Bash autonomy (no LLM, EC2 cron)

| Daemon | Domain | Wake source |
|---|---|---|
| **@bedrock-400-watcher** | tail pm2 logs, post `[bedrock-shape]` WARNs to PR with hypothesis classification | every 1 min cron on i-09b8c27f4be7c9891 |
| **@auto-deploy-tick** | main HEAD diff → resync `futureai-new` → pm2 restart `backend` + `backend-api` (gated B+C) | every 1 min cron, time-window + co-sign |
| **@auto-verifier-tick** | run scenario, capture shape evidence, dispatch C+K on H1/H2/H3 or @lee on smoke-clear | RemoteTrigger hourly with 55-iter loop |
| **@prometheus-heartbeat** | edit-in-place 9-lane status comment | EC2 cron 10s |

### Routing examples (peer-to-peer chain · Hermes appears 0 times)

| Trigger | Tag next |
|---|---|
| Sanitizer fix authored | @SessionE for admin-merge |
| Sanitizer PR merged green | (no tag — auto-deploy fires) |
| Bedrock 400 shape captured | @SessionC + @SessionK with hypothesis classification |
| Verifier confirms 3 consecutive PASS | @lee on #1962 — SMOKE-CLEAR ping |
| Constitution amendment proposed | @session-i for verifier-acceptance + @SessionE for admin-merge |
| TUI streaming-render bug found | @SessionI for fix · CC @SessionK if streaming-path |
| OEM-INTEG worker ships GM PR | @SessionE for admin-merge |
| Plutus absorption doc ready | @lee on #1983 (G1 burn approval gate) |
| Hera recruiter intake ready | @lee for hiring decision |
| Athena strategy memo ready | @lee on #1987 |
| Lane onboarding doc ready | @Prometheus on #1976 |

### Hermes escape valves (when @Hermes IS pulled in)

| Trigger | Hermes action |
|---|---|
| Session stalls > 30 min on a peer-tag (no acknowledge) | Hermes pings session for ETA + alt routing if loaded |
| Automated tick reports failure 3× consecutively | Hermes investigates EC2 / log root cause + redispatches |
| Lee tags @Hermes / @main / @SessionMain directly | immediate respond |
| G1-G9 Prometheus gate / Plutus board gate / Vulcan OEM-bridge merge needs decision | Hermes routes to @lee with summary |
| Cross-pillar conflict (e.g. Prometheus + Plutus disagree on a shared resource) | Hermes mediates |

Otherwise Hermes is silent. **The 24-min Bedrock-400 fix tonight (#1993) had Hermes intervene exactly 0 times.** That's the target.

### How to update this table

If your domain shifts or a new lane spawns, post the diff on #1976 with `@Hermes · domain-ownership update`. Hermes commits the change to `olympus-forge/docs/mesh/domain-ownership-canonical.md` (after Phase 1.2 ships).

— Hermes 2026-05-01T05:50Z
