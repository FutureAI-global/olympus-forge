---
name: ssm-send-command-c-side
namespace: session-lessons
version: 0.1.0
description: |
  Companion to /ssm-bash for the C-side debug-session use case. When debugging
  a production failure and waiting on the ops session (E in our coord rotation)
  to grep production logs, an IAM user with ssm:SendCommand can run the grep
  directly via aws ssm send-command + get-command-invocation, no Session
  Manager plugin or interactive shell needed. Eliminates ops-session
  bottleneck for read-only diagnostics.
allowed-tools:
  - Bash
  - Read
provenance: forged 2026-05-01 during the Bedrock 400 launch-blocker debug; C confirmed self-sufficient SSM SendCommand against `i-09b8c27f4be7c9891` (futureai-streaming-backend) via the futureai-deployer IAM user, eliminating an E-bottleneck on log greps
---

# ssm-send-command-c-side · debug-session log greps without ops bottleneck

## Why this exists

`/ssm-bash` is the canonical recipe for the deploy/ops idiom: long scripts in `.ps1` files, build output redirected to `/tmp/build.log`, `sudo -u ec2-user` wrapping for repo-touching writes, dry-runs before destructive commands. That recipe assumes the SSM caller IS the ops session.

The C-side debug-session use case is different. C (the debug session in our coord rotation) is investigating a production failure, needs a read-only diagnostic on the EC2 host (a `pm2 logs` grep, a `git log -1`, a `curl localhost:8080/health`), and would otherwise have to wait on E (the ops session) to drop their deploy work and run the grep. That round-trip is the bottleneck.

If C has an AWS CLI authenticated as an IAM user with `ssm:SendCommand` and `ssm:GetCommandInvocation`, C can run the read-only diagnostic directly. No Session Manager plugin install, no interactive shell, no SSH. The whole loop is roughly 5 to 10 seconds.

This skill is the read-only, debug-session-driven variant. It complements `/ssm-bash`, which retains ownership of the deploy idiom (UTF-8 setup, `.ps1` files for long scripts, `sudo -u ec2-user`, dry-runs). Read `/ssm-bash` first; this skill assumes it and adds C-side-specific pre-flight, send-and-poll, and debug-routing gotchas on top.

## Preamble (run first)

```bash
# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag ssm-send-command-c-side --limit 3 2>/dev/null || true
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag ssm-bash --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
export _SESSION_NAME
```

## Trigger conditions

Fire this skill when the debug session is about to:

1. Ask the ops session (E) to grep production logs for a known error string, conv ID, request ID, or shape
2. Wait on E for a `pm2 logs` tail, a `git log -1` on the EC2 checkout, or any read-only EC2 diagnostic
3. Block the debug investigation on E being available, when the diagnostic is fully read-only
4. Run a one-off `aws ssm send-command` for a read-only grep without yet having confirmed C-side IAM auth
5. Repeat the same grep across multiple iterations of a hypothesis tree (E-bottleneck compounds across rounds)

Voice triggers: "ask E to grep", "wait on the deploy session", "need a log line from prod", "C-side ssm".

## Workflow

### Phase 1 · Pre-flight (verify auth + find instance)

Confirm C is authenticated as an IAM user with SSM permissions, in the right region, and identify the target instance.

```bash
# 1. Verify AWS CLI present + authenticated
aws --version
aws sts get-caller-identity
# Look for Arn like arn:aws:iam::<acct>:user/<deployer-user>
# (NOT a federated/SSO role unless you've explicitly granted ssm:SendCommand on it)

# 2. Confirm region (us-east-1 for the streaming-api fleet)
echo "${AWS_REGION:-} ${AWS_DEFAULT_REGION:-}"

# 3. List SSM-enabled instances
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,ComputerName,IPAddress]' \
  --output table

# 4. Match the instance by Name tag
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Name,Values=*streaming*" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
  --output table

# 5. Cross-check by DNS
nslookup streaming-api.futureai.com
# Compare returned IP to PublicIpAddress from step 4
```

If `describe-instance-information` returns instances and your `Arn` is an IAM user (not a guess at a role), proceed. If the call returns `AccessDenied`, stop here and post in the coord PR that C's IAM user lacks `ssm:SendCommand`; ask E for the grep this round and ask Lee to grant the permission for next time.

### Phase 2 · Send-and-poll pattern

For one-off read-only greps, the inline send-and-poll is simpler than the full `Invoke-SSMCommand` function from `/ssm-bash` (which is the right shape for ops scripts but overkill for C-side debug).

```bash
INSTANCE=i-09b8c27f4be7c9891  # futureai-streaming-backend, confirmed via Phase 1

# 1. Send the command (returns a CommandId)
CMD_ID=$(aws ssm send-command --region us-east-1 \
  --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo -u ec2-user pm2 logs backend-api --lines 4000 --nostream 2>&1 | grep -E \"\\[bedrock-shape\\]\" | head -10"]' \
  --query 'Command.CommandId' --output text)

# 2. Wait briefly (read-only greps return in 2 to 8 seconds typically)
sleep 5

# 3. Fetch stdout (and stderr separately if exit != 0)
aws ssm get-command-invocation --region us-east-1 \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE" \
  --query '{exit:ResponseCode,stdout:StandardOutputContent,stderr:StandardErrorContent}' \
  --output json
```

For multi-step debug iterations, write the command list to a small bash function so subsequent greps reuse the polling loop without re-pasting:

```bash
ssm_grep() {
  local pattern="$1"
  local proc="${2:-backend-api}"
  local lines="${3:-4000}"
  local cmd_id status
  cmd_id=$(aws ssm send-command --region us-east-1 \
    --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript \
    --parameters "$(jq -nc --arg c "sudo -u ec2-user pm2 logs $proc --lines $lines --nostream 2>&1 | grep -E '$pattern' | head -20" '{commands:[$c]}')" \
    --query 'Command.CommandId' --output text)
  status="InProgress"
  while [[ "$status" =~ ^(Pending|InProgress|Delayed)$ ]]; do
    sleep 2
    status=$(aws ssm get-command-invocation --region us-east-1 \
      --command-id "$cmd_id" --instance-id "$INSTANCE" \
      --query 'Status' --output text)
  done
  aws ssm get-command-invocation --region us-east-1 \
    --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --query 'StandardOutputContent' --output text
}
```

For quoting traps with regex backslashes, see `/ssm-bash` Phase 2. The C-side variant hits the same JSON+shell escaping issues and the resolution (use `jq -nc` to build the JSON, not hand-quoted strings) is identical.

### Phase 3 · Process-routing gotcha (backend vs backend-api on the Olympus stack)

The Olympus orchestrator route handler `/api/v1/olympus/conversations/<id>/turns` runs on the `backend-api` pm2 process (port 8082), NOT the `backend` pm2 process (port 8080). A grep targeting `pm2 logs backend` will return zero hits for any Olympus-relevant log line, even if the request landed on the host.

Always check the right process. Either scope to `backend-api` directly:

```bash
sudo -u ec2-user pm2 logs backend-api --lines 4000 --nostream 2>&1 | grep -E "<pattern>"
```

Or check both and disambiguate by line content:

```bash
sudo -u ec2-user pm2 logs backend backend-api --lines 4000 --nostream 2>&1 | grep -E "<pattern>"
```

This bit E during the 2026-05-01 launch-blocker debug at 04:54Z: a grep against `backend` returned nothing, and the assumed conclusion was "the request never landed." Re-running against `backend-api` returned the request immediately. Always check the process before concluding the log line is missing.

### Phase 4 · pm2 buffer caveat (rolls on restart)

`pm2 logs --lines N` reads the in-memory ring buffer, which RESETS on every `pm2 restart` or `pm2 reload`. If a deploy or restart happened between the verifier emitting the log line and your grep, the line is gone from the buffer even though it ran successfully.

Two workarounds:

1. **Capture before restart.** If a deploy is imminent, grep IMMEDIATELY after the verifier emits, before the restart. Window is whatever the deploy lag is (typically 10 to 60 seconds).
2. **Read the persistent log files.** pm2 mirrors stdout/stderr to disk under `~ec2-user/.pm2/logs/`. These files survive restarts until log rotation runs.

   ```bash
   sudo -u ec2-user cat /home/ec2-user/.pm2/logs/backend-api-out.log | grep -E "<pattern>"
   sudo -u ec2-user cat /home/ec2-user/.pm2/logs/backend-api-error.log | grep -E "<pattern>"
   ```

   Slower to grep across (the file can be large), but durable across restarts.

This bit C at 05:04Z on 2026-05-01: K's verifier emitted at 04:59:30Z, pm2 restarted at 04:56Z (deploy landed between K's emit and C's query), C's grep against the in-memory buffer returned nothing. Falling back to `cat ~ec2-user/.pm2/logs/backend-api-out.log | grep` recovered the line.

## Seed lessons (4)

### Lesson 1 · C-side SSM SendCommand removes the E-bottleneck for read-only diagnostics

2026-05-01 launch-blocker debug. Coord PR #1989 was blocked on E's grep of `[bedrock-shape]` for a specific conv ID, multiple times across the night. C ran `aws sts get-caller-identity` and saw a `futureai-deployer` IAM user. `aws ssm describe-instance-information` in `us-east-1` returned 4 SSM-enabled instances. `aws ec2 describe-instances` matched `i-09b8c27f4be7c9891` to `futureai-streaming-backend` (PublicIpAddress matched DNS for `streaming-api.futureai.com`). `aws ssm send-command` returned `Success` status in roughly 5 seconds. C is now self-sufficient on read-only greps for the rest of the debug; E stays focused on deploys. Captured: when the debug session has the IAM user, asking E for a read-only grep is pure overhead; just run it.

### Lesson 2 · pm2 in-memory buffer rolls on restart, persistent logs do not

2026-05-01 launch-blocker debug. K's verifier emitted at 04:59:30Z. Deploy restart hit pm2 at 04:56Z (deploy landed between emit and query). C's grep against `pm2 logs backend-api --lines 4000 --nostream` at 05:04Z returned zero hits. Falling back to `cat /home/ec2-user/.pm2/logs/backend-api-out.log | grep` recovered the line. Captured: never trust `pm2 logs --lines N` after a known restart in the window; read the persistent file instead.

### Lesson 3 · Olympus orchestrator runs on backend-api, NOT backend

2026-05-01 launch-blocker debug, 04:54Z. E grepped `pm2 logs backend --lines 4000 --nostream` for a conv ID, got zero hits, momentarily concluded the request never reached the host. Re-running against `pm2 logs backend-api --lines 4000 --nostream` returned the request immediately. Captured: the `/api/v1/olympus/conversations/<id>/turns` route handler runs on the `backend-api` pm2 process (port 8082), not `backend` (port 8080). Olympus log greps must scope to `backend-api` or include both processes; never assume which one a route lives on without checking the route mount.

### Lesson 4 · Coord PR bottleneck recurs without C-side capability

2026-05-01 coord PR #1989 stalled on E-grep at least 3 times before C established C-side SSM. Each cycle cost roughly 4 to 8 minutes of debug-session idle time waiting for E to context-switch off deploys. After C confirmed C-side SSM, the same grep round-trip was roughly 10 seconds and zero E-touch. Captured: the bottleneck cost compounds across iterations; the cost of teaching C to run SSM directly is paid once and the savings recur for every subsequent debug round.

## Invariants consulted

- **Invariant 1 · Run the check before claiming.** A C-side SSM grep IS the verification surface for "log line landed on the host"; cite the `StandardOutputContent` in the same coord-PR comment as the claim, never claim the log shape without showing it.
- **Invariant 9 · User corrections are lessons, not interruptions.** If Lee or E flags that a C-side SSM grep was wrong (wrong process, wrong region, stale buffer), capture the correction as a new lesson under this skill or `/verify-before-claim`.

## Integration points

- **`/ssm-bash`** is the canonical SSM recipe; this skill is the C-side read-only variant. Read `/ssm-bash` first for UTF-8 setup, `.ps1` patterns, `sudo -u ec2-user` wrapping, and dry-runs. Do not duplicate that content here.
- **`/coord-pr-as-message-bus`** is where C posts grep findings once they exist. Format: paste the exact `aws ssm send-command` invocation, the resulting `CommandId`, and the `StandardOutputContent` (truncated to relevant lines) inside a fenced block.
- **`bedrock-h7-consecutive-tool-use`, `two-point-measurement-disambiguates-h5h6h7`, `hypothesis-tree-before-observability`** (the H7-debug cluster from the same 2026-05-01 incident) all benefit from C-side SSM; each hypothesis-tree round needs a fresh grep, and the E-bottleneck compounds across rounds.
- **`/verify-before-claim`** is the anti-inflation backstop. Every C-side SSM grep produces verifiable output; cite it inline before claiming "log line landed" or "request never hit the host."

## Completeness Principle

Run the full pre-flight (Phase 1) once at the start of the debug session, even if you "know" the IAM user works. The cost is roughly 30 seconds; the cost of skipping is discovering mid-debug that the IAM user lost `ssm:SendCommand` permission, or that the wrong region is the default, or that the wrong instance was assumed. After the pre-flight passes, individual greps cost roughly 10 seconds each.

False positives are cheap (one extra `aws sts get-caller-identity` call per session). False negatives are expensive (mid-debug discovery of broken IAM, plus the E-bottleneck reasserting itself).

## Changelog

- v0.1.0 (2026-05-01) initial draft from Session C launch-blocker debug. Forged when C confirmed self-sufficient SSM SendCommand against `i-09b8c27f4be7c9891` via the `futureai-deployer` IAM user, eliminating recurring E-bottleneck on read-only log greps for coord PR #1989.
