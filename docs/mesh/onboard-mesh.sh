#!/usr/bin/env bash
# Mesh Protocol v1 · per-session onboarding bootstrapper
# Usage: onboard-mesh.sh <session-name> <coord-pr> [<bucket>] [<domain>]
#
# Examples:
#   onboard-mesh.sh hermes 1962 auto watchdog
#   onboard-mesh.sh session-c 1989 auto sanitizers,validators,parser-fixes
#   onboard-mesh.sh plutus 1983 forge fundraise
#   onboard-mesh.sh vulcan 1978 auto oem-integration
#
# What it does (idempotent):
#   1. Sources GitHub App installation token (15K/hr per bucket; round-robin across auto/forge/brain)
#   2. Pins a heartbeat comment on the session's primary coord PR (or reuses existing)
#   3. Generates session-specific dispatcher script if missing
#   4. Starts active-dispatcher loop in background (PID written to ~/.olympus/dispatcher-<session>.pid)
#   5. Registers domain ownership in the heartbeat body
#
# Idempotency: re-running on a live session is a no-op (detects existing PID + comment ID).
set -uo pipefail

SESSION="${1:?session-name required (e.g. hermes, session-e, plutus, vulcan)}"
COORD_PR="${2:?coord-pr required (e.g. 1962, 1976, 1989)}"
BUCKET="${3:-auto}"
DOMAIN="${4:-general}"

REPO="FutureAI-global/futureai-auto"
OLYMPUS_DIR="$HOME/.olympus"
APP_TOKEN_HELPER="$OLYMPUS_DIR/harness/github-app/get-installation-token.sh"
HEARTBEAT_ID_FILE="$OLYMPUS_DIR/heartbeat-${SESSION}.id"
DISPATCHER_SCRIPT="$OLYMPUS_DIR/dispatcher-${SESSION}.sh"
DISPATCHER_PID_FILE="$OLYMPUS_DIR/dispatcher-${SESSION}.pid"
DISPATCHER_LOG="$OLYMPUS_DIR/dispatcher-${SESSION}.log"

mkdir -p "$OLYMPUS_DIR"

echo "==== mesh onboarding · ${SESSION} · coord PR #${COORD_PR} · bucket=${BUCKET} · domain=${DOMAIN} ===="

# 1 · Source GitHub App token (falls back to gh auth token if App helper missing)
if [ -x "$APP_TOKEN_HELPER" ]; then
  export GH_TOKEN="$($APP_TOKEN_HELPER "$BUCKET" 2>/dev/null)"
  TOKEN_SOURCE="github-app:${BUCKET}"
else
  export GH_TOKEN="$(gh auth token 2>/dev/null | tr -d '\n\r')"
  TOKEN_SOURCE="gh-keyring-fallback"
fi
[ -n "${GH_TOKEN:-}" ] || { echo "FATAL: no GH_TOKEN sourceable (App helper missing AND keyring empty)"; exit 2; }
echo "[1/5] auth · ${TOKEN_SOURCE} · token len=${#GH_TOKEN}"

# 2 · Pin heartbeat comment (or detect existing)
if [ -s "$HEARTBEAT_ID_FILE" ]; then
  COMMENT_ID="$(cat "$HEARTBEAT_ID_FILE")"
  # Verify it still exists
  if gh api "repos/${REPO}/issues/comments/${COMMENT_ID}" --jq '.id' >/dev/null 2>&1; then
    echo "[2/5] heartbeat · existing comment ${COMMENT_ID} on PR #${COORD_PR}"
  else
    echo "[2/5] heartbeat · stale ID ${COMMENT_ID}, re-pinning"
    rm -f "$HEARTBEAT_ID_FILE"
  fi
fi
if [ ! -s "$HEARTBEAT_ID_FILE" ]; then
  INIT_BODY="$(printf '## 🫀 %s live heartbeat · edit-in-place · 10s cadence\n\n**Domain:** %s\n**Last tick:** %s\n**State:** _initializing_\n**Last action:** onboard-mesh\n**Blocked on:** none\n**Open work:** _none yet_\n\n---\n_Auto-refreshed every 10 seconds via active-dispatcher. Comment body edits in place — no scroll flood. State-hash skip drops idle traffic to ~0._\n' "$SESSION" "$DOMAIN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  COMMENT_ID="$(gh api -X POST "repos/${REPO}/issues/${COORD_PR}/comments" -f body="$INIT_BODY" --jq '.id')"
  [ -n "${COMMENT_ID:-}" ] || { echo "FATAL: pin heartbeat failed"; exit 3; }
  echo "$COMMENT_ID" > "$HEARTBEAT_ID_FILE"
  echo "[2/5] heartbeat · pinned comment ${COMMENT_ID} on PR #${COORD_PR}"
fi

# 3 · Generate session-specific dispatcher if missing (copy reference impl, swap session name)
if [ ! -x "$DISPATCHER_SCRIPT" ]; then
  REFERENCE="$OLYMPUS_DIR/hermes-active-dispatcher.sh"
  if [ -r "$REFERENCE" ]; then
    sed -e "s|hermes-state-collector\.sh|${SESSION}-state-collector.sh|g" \
        -e "s|heartbeat-hermes\.id|heartbeat-${SESSION}.id|g" \
        -e "s|dispatcher-state|dispatcher-${SESSION}-state|g" \
        "$REFERENCE" > "$DISPATCHER_SCRIPT"
    chmod +x "$DISPATCHER_SCRIPT"
    echo "[3/5] dispatcher · generated ${DISPATCHER_SCRIPT} from hermes reference"
  else
    cat <<'STUB' > "$DISPATCHER_SCRIPT"
#!/usr/bin/env bash
# Stub dispatcher · replace with full active-dispatcher loop after onboarding.
# Generates an empty heartbeat tick every 10s; no inbox scanning, no auto-act.
set -uo pipefail
COMMENT_ID="$(cat "$HOME/.olympus/heartbeat-${SESSION_ENV:-stub}.id")"
while true; do
  TICK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  BODY="## 🫀 STUB heartbeat · ${TICK}\n\n_Replace this dispatcher with the full active-dispatcher loop. See ~/.olympus/hermes-active-dispatcher.sh for reference._"
  gh api -X PATCH "repos/FutureAI-global/futureai-auto/issues/comments/${COMMENT_ID}" -f body="$BODY" >/dev/null 2>&1 || true
  sleep 10
done
STUB
    chmod +x "$DISPATCHER_SCRIPT"
    echo "[3/5] dispatcher · wrote STUB to ${DISPATCHER_SCRIPT} (replace post-onboard)"
  fi
else
  echo "[3/5] dispatcher · already exists at ${DISPATCHER_SCRIPT}"
fi

# 4 · Start active-dispatcher in background (kill prior PID if alive)
if [ -s "$DISPATCHER_PID_FILE" ]; then
  PRIOR_PID="$(cat "$DISPATCHER_PID_FILE")"
  if kill -0 "$PRIOR_PID" 2>/dev/null; then
    echo "[4/5] dispatcher · prior PID ${PRIOR_PID} alive, killing for restart"
    kill "$PRIOR_PID" 2>/dev/null || true
    sleep 1
  fi
fi
nohup bash "$DISPATCHER_SCRIPT" > "$DISPATCHER_LOG" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$DISPATCHER_PID_FILE"
echo "[4/5] dispatcher · started PID ${NEW_PID} · log=${DISPATCHER_LOG}"

# 5 · Confirm liveness (wait one heartbeat tick + verify dispatcher logged)
sleep 12
if kill -0 "$NEW_PID" 2>/dev/null; then
  TICK_COUNT="$(grep -c 'heartbeat PATCH' "$DISPATCHER_LOG" 2>/dev/null || echo 0)"
  echo "[5/5] alive · ${TICK_COUNT} heartbeat PATCH(es) emitted in last 12s"
else
  echo "[5/5] FATAL · dispatcher PID ${NEW_PID} died within 12s · check ${DISPATCHER_LOG}"
  exit 4
fi

echo ""
echo "==== ✅ mesh onboarding complete ===="
echo "Session:        ${SESSION}"
echo "Coord PR:       https://github.com/${REPO}/pull/${COORD_PR}"
echo "Heartbeat:      https://github.com/${REPO}/pull/${COORD_PR}#issuecomment-${COMMENT_ID}"
echo "Dispatcher PID: ${NEW_PID} (kill via: kill \$(cat ${DISPATCHER_PID_FILE}))"
echo "Domain:         ${DOMAIN}"
echo "Bucket:         ${BUCKET} (App-token-backed; falls back to keyring if App helper missing)"
echo ""
echo "Next: as the LLM session, start a Monitor task on coord PR #${COORD_PR} to wake on @-mentions."
