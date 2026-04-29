---
name: ssm-bash
namespace: session-lessons
version: 0.1.0
description: |
  Canonical recipe for running `aws ssm send-command` against an EC2 host
  from PowerShell or bash without UTF-8 mangling, paste line-wrap, or
  polling boilerplate. Encodes UTF-8 console setup, the long-script via
  `.ps1` file pattern, exit-code propagation, and `sudo -u` wrapping for
  repos owned by a non-root user. Forged from a production-DB outage where
  a session ran roughly 30 ad-hoc SSM invocations and hit each sharp edge.
allowed-tools:
  - Bash
  - Read
  - Write
provenance: forged 2026-04-29 from a production-DB outage incident where roughly 30 ad-hoc SSM invocations exposed UTF-8 mangling, PowerShell paste-wrap, and missing exit-code propagation as repeat failure modes
---

# ssm-bash · run shell on EC2 without UTF-8 mangling, paste-wrap, or polling boilerplate

## Why this exists

`aws ssm send-command` is the right tool for ad-hoc EC2 ops, but it has three sharp edges that bit a session 30+ times during a production-DB outage:

1. UTF-8 mangling. Unicode glyphs come back as `?` or wrong characters unless `[Console]::OutputEncoding` and `chcp 65001` are set up.
2. PowerShell paste-wrap. Multi-line `aws ssm send-command --parameters '...'` invocations get line-wrapped on paste, breaking the JSON.
3. Polling boilerplate. `send-command` returns immediately with a CommandId, then you have to poll `get-command-invocation` until `Status=Success|Failed`.

Plus a fourth edge for repo-touching commands: SSM agent runs as root, but repos under `/home/ec2-user/` are owned by `ec2-user`, so git refuses with "dubious ownership" unless you wrap in `sudo -u ec2-user`.

This skill encodes the patterns that worked.

## Preamble (run first)

```bash
# Surface relevant prior lessons
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag ssm-bash --limit 3 2>/dev/null || true
fi
_SESSION_NAME="${OPENCLAW_SESSION:-$(cat ~/.gstack/session-identity 2>/dev/null || echo "$(hostname)-$PPID")}"
```

## Trigger conditions

Fire this skill when about to:

1. Type `aws ssm send-command`
2. Run a script in `scripts/` that issues SSM calls (resync, deploy, build helpers)
3. Issue a remote command on a known EC2 production instance
4. Debug an EC2-side issue from a local machine

Voice triggers: "ssm to ec2", "run on the deploy host", "send-command".

## Workflow

### Phase 1 · UTF-8 setup at session start (PowerShell)

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null
$env:PYTHONIOENCODING = "utf-8"
```

Do this once per PowerShell session before any SSM calls. Without it, EC2's UTF-8 stdout gets transcoded to Windows-1252 and Unicode glyphs break.

### Phase 2 · Long scripts go in `.ps1` files, never inline

```powershell
# BAD: PS line-wraps on paste, breaks the JSON
aws ssm send-command --instance-ids <ec2-instance-id> `
    --document-name AWS-RunShellScript `
    --parameters 'commands=["cd /home/ec2-user/<repo> && long-multi-line-thing"]'

# GOOD: write to .ps1, invoke
@'
$cmds = @(
  "cd /home/ec2-user/<repo>",
  "node scripts/build-cli.js",
  "echo done"
)
$json = @{ commands = $cmds } | ConvertTo-Json -Compress
aws ssm send-command `
  --instance-ids <ec2-instance-id> `
  --document-name AWS-RunShellScript `
  --parameters $json
'@ | Set-Content -Path "$env:TEMP\ssm-build.ps1" -Encoding UTF8
& "$env:TEMP\ssm-build.ps1"
```

The `.ps1` file is not subject to terminal paste-wrap; PowerShell parses the file directly.

### Phase 3 · Capture CommandId, poll, return exit + output

```powershell
function Invoke-SSMCommand {
  param(
    [string]$InstanceId = "<ec2-instance-id>",
    [string[]]$Commands,
    [int]$TimeoutSec = 300
  )

  $params = @{ commands = $Commands } | ConvertTo-Json -Compress
  $send = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name AWS-RunShellScript `
    --parameters $params `
    --output json | ConvertFrom-Json

  $cmdId = $send.Command.CommandId
  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  do {
    Start-Sleep -Seconds 2
    $r = aws ssm get-command-invocation `
      --command-id $cmdId `
      --instance-id $InstanceId `
      --output json | ConvertFrom-Json

    if ((Get-Date) -gt $deadline) {
      Write-Host "[ssm-bash] TIMEOUT after $TimeoutSec s"
      return $null
    }
  } while ($r.Status -in @("Pending", "InProgress", "Delayed"))

  return @{
    Status = $r.Status
    ExitCode = $r.ResponseCode
    Stdout = $r.StandardOutputContent
    Stderr = $r.StandardErrorContent
  }
}
```

### Phase 4 · Surface stderr separately, never silence it

```powershell
$result = Invoke-SSMCommand -Commands @("...")
if ($result.ExitCode -ne 0) {
  Write-Host "STDERR:" -ForegroundColor Red
  Write-Host $result.Stderr
  throw "SSM command failed with exit $($result.ExitCode)"
}
Write-Host $result.Stdout
```

When SSM fails, the stderr is the diagnostic. Always print it on non-zero exit.

### Phase 5 · For destructive commands, dry-run first

```powershell
# Build the command list
$cmds = @(
  "cd /home/ec2-user/<repo>",
  "ls -la dist/cli/<bundle-entrypoint>.js"   # not the destructive thing
)

# Verify the SSM round-trip works for a no-op first
$dry = Invoke-SSMCommand -Commands $cmds
Write-Host "Dry run output: $($dry.Stdout)"

# THEN run the destructive command
$cmds = @("..."); $real = Invoke-SSMCommand -Commands $cmds
```

This catches IAM-role issues, network blips, and instance-state mismatches before you commit to the destructive action.

### Phase 6 · Wrap repo-touching commands in `sudo -u ec2-user`

SSM agent runs as root. Repos under `/home/ec2-user/` are owned by `ec2-user`. Running `git` or `node` against those repos as root yields `fatal: detected dubious ownership in repository at '/home/ec2-user/<repo>'`.

```bash
# WRONG, runs as root, git refuses
"cd /home/ec2-user/<repo> && git fetch origin staging && git reset --hard origin/staging"

# RIGHT, wrap in sudo -u ec2-user
"sudo -u ec2-user bash -c 'cd /home/ec2-user/<repo> && git fetch origin staging && git reset --hard origin/staging'"
```

Use this for ANY command touching `/home/ec2-user/` (git, node, npm, pm2, file edits). Pre-baked rsync scripts already do this; ad-hoc SSM commands forget.

For `STAGING_SHA=$(...)` capture inside SSM, the wrapper pattern is:

```bash
"STAGING_SHA=$(sudo -u ec2-user bash -c 'cd /home/ec2-user/<repo> && git rev-parse HEAD')"
"echo \"post-pull staging HEAD: $STAGING_SHA\""
```

### Phase 7 · bash variant (less ceremony)

```bash
ssm_run() {
  local instance="${1:-<ec2-instance-id>}"
  local cmds=("${@:2}")
  local cmds_json=$(printf '%s\n' "${cmds[@]}" | jq -R . | jq -s .)
  local cmd_id=$(aws ssm send-command \
    --instance-ids "$instance" \
    --document-name AWS-RunShellScript \
    --parameters "$(printf '{"commands":%s}' "$cmds_json")" \
    --output text --query 'Command.CommandId')
  local status="InProgress"
  while [[ "$status" =~ ^(Pending|InProgress|Delayed)$ ]]; do
    sleep 2
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$instance" \
      --output text --query 'Status')
  done
  aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance" \
    --query '{exit:ResponseCode, stdout:StandardOutputContent, stderr:StandardErrorContent}' \
    --output json
}
```

## What NOT to do

- Do NOT paste a multi-line `aws ssm send-command` directly into PowerShell. Use a `.ps1` file.
- Do NOT skip the UTF-8 console setup. Unicode in stdout gets corrupted silently.
- Do NOT run repo-touching commands as root. Wrap in `sudo -u ec2-user` or git refuses.
- Do NOT silence stderr. On non-zero exit, the stderr IS the diagnostic.
- Do NOT pipe massive build output to SSM stdout. Redirect to `/tmp/*.log` and tail on failure (esbuild progress bars can crash the SSM agent's writer with box-drawing chars).
- Do NOT skip the dry-run before destructive commands. IAM and instance-state mismatches surface as failures on no-op probes too.

## Seed lessons (4)

### Lesson 1 · Inline multi-line `--parameters` JSON breaks on paste

A PowerShell session pasted a 6-line `aws ssm send-command --parameters '...'` block. The terminal wrapped lines, the JSON parser failed, the user got a confusing "ValidationException" on the wrong field. Fix: write the call to `$env:TEMP\ssm-*.ps1`, invoke the file. The file parser is not subject to paste-wrap.

### Lesson 2 · `chcp` not set, Unicode comes back as `?`

EC2 stdout containing checkmarks, arrows, or non-ASCII text returned as `?` glyphs. `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` plus `chcp 65001` at session start fixed it permanently. Single setup per session.

### Lesson 3 · Repo-touching command as root yields "dubious ownership"

`cd /home/ec2-user/<repo> && git fetch` ran as root via SSM. Git refused with `fatal: detected dubious ownership`. Wrapping in `sudo -u ec2-user bash -c '...'` resolved it. Applies to git, node, npm, pm2, and any tool that checks file ownership.

### Lesson 4 · Big build stdout crashes SSM agent's writer

`node scripts/build-cli.js` emits esbuild progress bars with box-drawing characters. SSM agent's stdout handler choked, returned partial output, and the polling loop reported "Success" with no actionable diagnostics. Fix: redirect build output to `/tmp/build.log`, tail the last 30 lines on failure, keep SSM stdout small and Unicode-clean.

## Invariants consulted

- `verify-before-claim`. Before claiming "deploy succeeded," produce the SSM exit code + last lines of stdout in the same turn. SSM is the verification surface for EC2-side claims.
- `api-push`. Post-push verification often runs via SSM (rebuild, smoke, swap). The SSM round-trip output is what verifies the pushed PR landed correctly on the deploy host.

## Integration points

- Pairs with `api-push`. Code lands via API push, then ssm-bash drives the post-push rebuild + atomic bundle swap on EC2.
- Pairs with `verify-before-claim`. SSM is the canonical evidence channel for EC2-side claims (file exists on server, process is running, version is current).
- Pairs with destructive-command quarantine flows. SSM dry-run in Phase 5 is the cheapest way to gate a destructive remote action.

## Completeness principle

Run every phase even for "small" SSM calls. The cost of the full recipe is roughly 30 seconds of script setup; the cost of skipping is a corrupted Unicode response, a paste-wrapped JSON parse error, a root-owned git refusal, or a destructive command run against the wrong instance.

False positives are cheap (slightly verbose script for a one-line command). False negatives are expensive (production-DB outage class incidents).

## Changelog

- v0.1.0 (2026-04-29). Initial skill from session-lessons. Forged from a production-DB outage where roughly 30 ad-hoc SSM invocations exposed UTF-8 mangling, paste-wrap, and ownership pitfalls as repeat failure modes.
