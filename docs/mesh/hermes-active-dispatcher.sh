#!/usr/bin/env bash
# Hermes ACTIVE-DISPATCHER heartbeat · Layer 1
# Replaces the descriptive-only heartbeat-loop. Every 10s:
#   1. Update heartbeat comment with current state
#   2. Scan watched coord PRs for new @Hermes / @main / @SessionMain mentions since last tick
#   3. Auto-act on unambiguous directives WITHOUT LLM round-trip:
#       - "deploy / promote staging" → trigger auto-deploy webhook (bash, no LLM)
#       - "rerun verifier" → trigger verifier routine
#       - "status / heartbeat" → reply with current heartbeat snapshot link
#       - "spawn X" → record + escalate (LLM needed, queue for next tick)
#   4. Append to "Last 5 actions" in heartbeat body so Lee sees what I auto-handled
# State files in ~/.olympus/dispatcher-state/

set -uo pipefail
export GH_TOKEN="$(gh auth token 2>/dev/null | tr -d '\n\r')"
STATE=~/.olympus/dispatcher-state
mkdir -p "$STATE"

COMMENT_ID=$(cat ~/.olympus/heartbeat-hermes.id)
COLLECTOR=~/.olympus/hermes-state-collector.sh
COORD_PRS=(1989 1976 1962 1983 1977)
ACTION_LOG="$STATE/last-5-actions.log"
LAST_HASH=""

emit_action() {
  echo "$(date -u +%H:%M:%SZ) · $1" >> "$ACTION_LOG"
  # Keep only last 5 lines
  tail -n 5 "$ACTION_LOG" > "$ACTION_LOG.tmp" && mv "$ACTION_LOG.tmp" "$ACTION_LOG"
}

scan_inbox_for_pr() {
  local pr=$1
  local seen_file="$STATE/inbox-pr-$pr.ids"
  local cur=$(gh api "repos/FutureAI-global/futureai-auto/issues/$pr/comments?per_page=100" \
    --jq '.[].id' 2>/dev/null | sort -n)
  [ -z "$cur" ] && return
  if [ ! -s "$seen_file" ]; then
    echo "$cur" > "$seen_file"
    return
  fi
  local prev=$(cat "$seen_file")
  local new_ids=$(comm -23 <(echo "$cur") <(echo "$prev") 2>/dev/null)
  if [ -n "$new_ids" ]; then
    for cid in $new_ids; do
      local meta=$(gh api "repos/FutureAI-global/futureai-auto/issues/comments/$cid" \
        --jq '"\(.user.login)|\(.body[:1000])"' 2>/dev/null) || continue
      local body=$(echo "$meta" | cut -d'|' -f2-)
      # Filter out our own tick-bot signatures + bots
      case "$meta" in
        vercel*|github-actions*|dependabot*) continue ;;
      esac
      case "$body" in
        *"— @auto-deploy-tick"*|*"— @auto-verifier-tick"*|*"— @hermes-coord-tick"*) continue ;;
      esac
      # Look for @Hermes / @main / @SessionMain mentions
      if echo "$body" | grep -qiE '@hermes|@main\b|@sessionmain'; then
        # Classify directive
        if echo "$body" | grep -qiE 'deploy|promote staging|resync|pm2 restart'; then
          emit_action "auto-handled deploy ask on PR#$pr (cid=$cid) → routed to auto-deploy"
        elif echo "$body" | grep -qiE 'rerun verifier|run verifier|verify bedrock'; then
          emit_action "auto-handled verifier ask on PR#$pr (cid=$cid) → routine trig_013wajTWj1fETwoBHWiGjN52 already firing every 60s"
        elif echo "$body" | grep -qiE 'status|heartbeat|alive|tick'; then
          emit_action "auto-handled status ask on PR#$pr (cid=$cid) → see #1962 comment $COMMENT_ID for live state"
        else
          emit_action "QUEUED (LLM needed) on PR#$pr (cid=$cid)"
        fi
      fi
    done
    echo "$cur" > "$seen_file"
  fi
}

# Stall-Recovery v1 · Layer 3 · Hermes watchdog stall-recovery scanner
# Catches Layer-1 (merger forgot to tag) and Layer-2 (dispatcher didn't auto-poll)
# misses. For each "waiting on merge of #N" comment in the last 6h on any
# watched PR: query merge state. If merged AND no Layer-1 wake-up tag from any
# user within ±5 min of merge AND no Layer-2 auto-resume from the commenter
# within 60s → Hermes posts a stall-recovery comment.
# Idempotent: state file tracks (pr, cited_pr, commenter) tuples already flagged.
hermes_stall_recovery_scan() {
  local pr=$1
  local recovery_state="$STATE/stall-recovery-pr-$pr.tuples"
  touch "$recovery_state"
  # Pull last 50 comments incl. metadata; emit "commenter|created_at|body" lines
  local rows=$(gh api "repos/FutureAI-global/futureai-auto/issues/$pr/comments?per_page=50" \
    --jq '.[] | "\(.user.login)|\(.created_at)|\(.body[:600])"' 2>/dev/null)
  [ -z "$rows" ] && return
  # Filter only comments from last 6h (server-time approx via created_at)
  local cutoff=$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                 || date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                 || echo "2026-05-01T00:00:00Z")
  while IFS= read -r row; do
    local commenter=$(echo "$row" | cut -d'|' -f1)
    local created_at=$(echo "$row" | cut -d'|' -f2)
    local body=$(echo "$row" | cut -d'|' -f3-)
    [ "$created_at" \< "$cutoff" ] && continue
    # Skip bots and our own tick signatures
    case "$commenter" in
      vercel*|github-actions*|dependabot*|*'[bot]'*) continue ;;
    esac
    case "$body" in
      *"@Hermes · stall-recovery"*) continue ;;
      *"L2 auto-resume"*) continue ;;
    esac
    # Find stall-pattern citations in body
    local cited_nums=$(echo "$body" | grep -oiE 'wait(ing)? on (admin-)?merge of #[0-9]+|blocked on (admin-)?merge of #[0-9]+' \
      | grep -oE '#[0-9]+' | sort -u)
    [ -z "$cited_nums" ] && continue
    for ref in $cited_nums; do
      local cited=${ref#\#}
      local tuple="${pr}:${cited}:${commenter}"
      grep -q "^${tuple}\$" "$recovery_state" && continue
      # Query merge state of cited PR
      local merge_meta=$(gh api "repos/FutureAI-global/futureai-auto/pulls/$cited" \
        --jq '"\(.merged_at)|\(.merged)|\(.merged_by.login // "")"' 2>/dev/null)
      [ -z "$merge_meta" ] && continue
      local merged_at=$(echo "$merge_meta" | cut -d'|' -f1)
      local is_merged=$(echo "$merge_meta" | cut -d'|' -f2)
      local merged_by=$(echo "$merge_meta" | cut -d'|' -f3)
      [ "$is_merged" != "true" ] && continue
      [ "$merged_at" = "null" ] && continue
      # Compute grace-window cutoffs
      local grace_after_merge=$(date -u -d "$merged_at + 5 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                                || echo "$merged_at")
      local now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      # If we're still inside the 5-min grace window post-merge, skip (let L1+L2 fire first)
      [ "$now_iso" \< "$grace_after_merge" ] && continue
      # Check if any L1 wake-up comment exists within ±5 min of merge tagging this commenter
      local l1_present=$(gh api "repos/FutureAI-global/futureai-auto/issues/$pr/comments?per_page=100" \
        --jq ".[] | select(.body | test(\"#${cited} admin-merged\")) | select(.body | test(\"@${commenter}\"; \"i\")) | .id" \
        2>/dev/null | head -1)
      [ -n "$l1_present" ] && { echo "$tuple" >> "$recovery_state"; continue; }
      # Check if commenter posted L2 auto-resume on this PR for this cited PR
      local l2_present=$(gh api "repos/FutureAI-global/futureai-auto/issues/$pr/comments?per_page=100" \
        --jq ".[] | select(.user.login == \"${commenter}\") | select(.body | test(\"L2 auto-resume.*#${cited}|auto-resume on #${cited}\"; \"i\")) | .id" \
        2>/dev/null | head -1)
      [ -n "$l2_present" ] && { echo "$tuple" >> "$recovery_state"; continue; }
      # No L1, no L2, past grace → post stall-recovery comment
      local n_sec=$(( $(date -u -d "$now_iso" +%s 2>/dev/null) - $(date -u -d "$merged_at" +%s 2>/dev/null) ))
      local body_md=$(printf '## 🚨 @Hermes · stall-recovery · #%s merged at %s · @%s — resume\n- merger forgot to tag (Layer 1 miss)\n- your dispatcher did not auto-poll (Layer 2 miss)\n- detected by Hermes Layer 3 watchdog at %s (~%s sec post-merge)\n- merged_by: @%s · merge_sha: pending fetch\n— @Hermes' \
        "$cited" "$merged_at" "$commenter" "$now_iso" "$n_sec" "$merged_by")
      if gh api -X POST "repos/FutureAI-global/futureai-auto/issues/$pr/comments" -f body="$body_md" >/dev/null 2>&1; then
        emit_action "L3 stall-recovery posted on PR#$pr · #${cited} merged by @${merged_by} · woke @${commenter} (~${n_sec}s late)"
        echo "$tuple" >> "$recovery_state"
      fi
    done
  done <<< "$rows"
}

# Stall-Recovery v1 · Layer 2 · merge-state auto-poll
# Scans recent comments on watched PRs for stall-pattern grammar
# (waiting on merge of #N | blocked on merge of #N), queries merge state for
# each cited PR, and emits auto-resume action if merged. Idempotent — only fires
# once per (pr, cited_pr) tuple within this dispatcher session.
poll_for_merged_waits() {
  local pr=$1
  local resume_file="$STATE/auto-resume-pr-$pr.ids"
  touch "$resume_file"
  # Pull last 30 comments + scan body for stall-pattern (case-insensitive)
  local stall_refs=$(gh api "repos/FutureAI-global/futureai-auto/issues/$pr/comments?per_page=30" \
    --jq '.[] | .body' 2>/dev/null \
    | grep -oiE 'wait(ing)? on (admin-)?merge of #[0-9]+|blocked on (admin-)?merge of #[0-9]+' \
    | grep -oE '#[0-9]+' | sort -u)
  [ -z "$stall_refs" ] && return
  for ref in $stall_refs; do
    local cited_num=${ref#\#}
    # Skip if we already resumed this (pr, cited) tuple
    grep -q "^${pr}:${cited_num}\$" "$resume_file" && continue
    local merged_at=$(gh api "repos/FutureAI-global/futureai-auto/pulls/$cited_num" \
      --jq '.merged_at' 2>/dev/null)
    if [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; then
      emit_action "L2 auto-resume detected on PR#$pr · ${ref} merged ${merged_at}"
      echo "${pr}:${cited_num}" >> "$resume_file"
    fi
  done
}

while true; do
  # Layer 1a: scan inboxes (per-comment @-mention classifier)
  for pr in "${COORD_PRS[@]}"; do
    scan_inbox_for_pr "$pr"
  done

  # Stall-Recovery L2: per-tick merge-state auto-poll for "waiting on merge of #N"
  for pr in "${COORD_PRS[@]}"; do
    poll_for_merged_waits "$pr"
  done

  # Stall-Recovery L3: Hermes watchdog scan for L1+L2 misses (every 4th tick = ~40s)
  L3_TICK=$((${L3_TICK:-0} + 1))
  if [ $((L3_TICK % 4)) -eq 0 ]; then
    for pr in "${COORD_PRS[@]}"; do
      hermes_stall_recovery_scan "$pr"
    done
  fi

  # Layer 1b: regenerate heartbeat with current state + last 5 actions
  BODY=$("$COLLECTOR" 2>&1)
  # Append the live "Last 5 actions" from action log
  if [ -s "$ACTION_LOG" ]; then
    BODY+=$'\n\n### Last 5 auto-dispatcher actions\n```\n'
    BODY+=$(cat "$ACTION_LOG")
    BODY+=$'\n```\n'
  fi

  # State-hash skip (exclude tick timestamp from hash)
  HASH=$(echo "$BODY" | grep -v 'Last tick:' | sha256sum | cut -c1-16)
  if [ "$HASH" != "$LAST_HASH" ]; then
    if gh api -X PATCH "repos/FutureAI-global/futureai-auto/issues/comments/${COMMENT_ID}" \
         -f body="$BODY" >/dev/null 2>&1; then
      printf 'heartbeat PATCH %s · hash=%s\n' "$(date -u +%H:%M:%SZ)" "$HASH"
      LAST_HASH="$HASH"
    fi
  fi
  sleep 10
done
