## Heartbeat Protocol v1 · 10s edit-in-place · per-session

**Goal:** every active session (Hermes, E, C, K, I, every Prometheus lane lead, Plutus) maintains a single pinned comment on its coord PR that updates in place every 10s. Lee can glance at any coord PR and see live state without scrolling. No scroll flood.

### Shape (copy from Prometheus on PR #1976 comment 4357751288)

```
## 🫀 <SESSION-NAME> live heartbeat · edit-in-place · 10s cadence

**Last tick:** HH:MM:SSZ
**State:** <ONE-LINE summary — what you're doing right now>
**Last action:** <YYYY-MM-DDTHH:MMZ — last GH activity / commit / dispatch>
**Blocked on:** <none / @other-session / @lee gate / external>
**Open work:** <PR numbers in flight, comma-separated>

### Last 5 actions
- HH:MM:SSZ · <verb> · <target>
- HH:MM:SSZ · <verb> · <target>
- ...

---
_Auto-refreshed every 10 seconds. Comment body edits in place — no scroll flood._
```

### Reference implementation (bash + gh CLI)

One-time pin:
```bash
SESSION="hermes"  # or "session-e", "session-c", etc.
COORD_PR=1976     # session's primary coord PR
BODY="## 🫀 ${SESSION} live heartbeat · edit-in-place · 10s cadence\n\n_initializing..._\n"
COMMENT_ID=$(gh api -X POST "repos/FutureAI-global/futureai-auto/issues/${COORD_PR}/comments" \
  -f body="$(printf "$BODY")" --jq '.id')
echo "$COMMENT_ID" > ~/.olympus/heartbeat-${SESSION}.id
```

10s loop (run via Monitor / pm2 / nohup / cron):
```bash
COMMENT_ID=$(cat ~/.olympus/heartbeat-${SESSION}.id)
while true; do
  STATE=$(your-state-collector-script.sh)  # session-specific
  TICK=$(date -u +%H:%M:%SZ)
  BODY=$(generate-body.sh "$TICK" "$STATE")
  gh api -X PATCH "repos/FutureAI-global/futureai-auto/issues/comments/${COMMENT_ID}" \
    -f body="$BODY" >/dev/null
  sleep 10
done
```

### API budget

10s cadence × 1 PATCH = 360 calls/hr per session. With ~15 sessions = 5,400 calls/hr. Authenticated GitHub limit = 5,000/hr. **Close to ceiling.** Mitigation: skip PATCH if state hash unchanged. That drops idle sessions to near-zero traffic.

### State-hash skip (recommended)

```bash
LAST_HASH=""
while true; do
  STATE=$(collect-state.sh)
  HASH=$(echo "$STATE" | sha256sum | cut -c1-16)
  if [ "$HASH" != "$LAST_HASH" ]; then
    gh api -X PATCH "...comments/${COMMENT_ID}" -f body="$(generate-body.sh "$STATE")"
    LAST_HASH="$HASH"
  fi
  sleep 10
done
```

### Per-session coord PR mapping

| Session | Coord PR | Owner machine |
|---|---|---|
| Hermes | #1962 (v8 bug-squash) | local Windows |
| Prometheus | #1976 | EC2 i-05f74eb0c9a3be7ec |
| Plutus | #1983 | EC2 (Prometheus host) |
| Asclepius | #1986 | EC2 |
| Athena | #1987 | EC2 |
| Hera | #1988 | EC2 |
| Vulcan | #1978 | EC2 |
| Janus | #1979 | EC2 |
| Apollo | #1980 | EC2 |
| Themis | #1981 | EC2 |
| Daedalus | #1982 | EC2 |
| Session E | #1989 (active) / #1962 | local Mac |
| Session C | #1989 / #1977 | local Windows |
| Session K | #1989 / forge | local Mac |
| Session I | #1962 (smoke / docs) | local Mac |

### Why this matters

Without heartbeats: Lee has to ask "what are you doing?" every N min. Each ask costs Lee context + a session round-trip.

With heartbeats: Lee glances at the coord PR top-comment for live state. No round-trip. Sessions that go idle for >2 min show stale `Last tick:` → Lee can spot stalled sessions instantly.

— Hermes 2026-05-01T04:10Z
