---
name: path-symmetric-rerouting
namespace: session-lessons
version: 0.1.0
description: |
  Capability-matrix re-route comment when an assignment lands on a session
  whose environment can't satisfy it (Mac-bound script on Windows session,
  AWS-credentialed task on no-creds session). Names a path-symmetric
  session who has already executed the same shape successfully.
allowed-tools:
  - Bash
provenance: |
  forged 2026-04-29 from a Mac-bound resync re-route from a Windows session
  to a Mac session that had successfully run the same script earlier the
  same day.
---

# path-symmetric-rerouting · re-route to a session whose env actually fits

## Why this exists

- Multi-session coord doesn't always know each session's environment. Mac-bound scripts get assigned to Windows sessions; AWS-credentialed tasks land on sessions without prod creds; live-vehicle smoke gets routed to a session that's not at the bench.
- Trying to execute through the wrong env wastes time on debugging that's actually environmental, not logic.
- Silently dropping the assignment leaves coord wondering; asking the user to manually triage adds latency.
- "Path-symmetric" means a session that has *already executed* an assignment of the same shape against the same target. Their receipt history proves they have the working environment.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag rerouting --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Assignment includes a hardcoded path that doesn't exist in your env (Mac vs Windows).
- Assignment requires a credential or capability you don't have (AWS creds, SSM access, physical hardware).
- Assignment requires running a script whose dependencies aren't installed locally.
- You'd need to set up infrastructure just to satisfy the assignment, when another session has the infrastructure already.

Voice triggers: "the script wants Mac path", "I don't have the creds for", "this needs SSH to prod".

## Workflow

### Phase 1 · Identify the capability mismatch

Concretely list what the assignment requires vs what your session has:

| Capability | YOUR session | Required |
|---|---|---|
| `/Users/leelee2/Developer/<repo>/` checkout | ❌ Windows; only `~/<repo>/` | ✅ |
| `aws ssm send-command` to `i-xxxxxxxxxxxxxxxxx` | ⚠ no creds wired | ✅ |
| Prior successful execution of this same script | — | ✅ |

### Phase 2 · Find the path-symmetric session

A session that has already executed an assignment of the same shape against the same target. Don't guess — use coord PR history:

```bash
gh api --paginate "repos/$REPO/issues/$COORD/comments?per_page=100" \
  --jq '.[] | select(.body | contains("'<script-name>'") and contains("DEPLOY") and contains("✅")) | "\(.created_at[:10]) \(.user.login) \(.body[:100])"'
```

If E ran `resync-ec2-src.sh` against `i-xxxxxxxxxxxxxxxxx` successfully at 13:51Z, E has the working env for the next resync. That's path-symmetric.

### Phase 3 · The re-route comment template

```markdown
## <YOUR-SESSION> → @<ASSIGNER> · re-routing <TASK> to @<TARGET-SESSION> · <TIMESTAMP>

@<assigner> — your <TIMESTAMP> assignment landed on Session <YOUR>, but <TARGET-CAPABILITY-SHORT-NAME>
and Session <YOUR> is on <YOUR-ENV>. Re-routing per directive.

### Why <TARGET> (not <YOUR>)

| Capability | <YOUR> this session | <TARGET> |
|---|---|---|
| <capability 1> | ❌ <reason> | ✅ <evidence> |
| <capability 2> | ❌ <reason> | ✅ <evidence> |
| Prior successful execution | — | ✅ <link/timestamp of receipt> |

<TARGET> already completed <prior-task>; <THIS-TASK> is the same script with the same target. Path-symmetric.

### Asks

- **@<TARGET>** — execute <TASK> per <ASSIGNER>'s scope:
  ```bash
  <verbatim commands from original assignment>
  ```
- **@<assigner>** — bless <TARGET> for the re-routed action.

### What <YOUR> does after

<verification step or follow-up YOUR-session can do without the missing capability>

[session-<YOUR>] re-route posted · standing by for <TARGET>'s receipt
```

### Phase 4 · Offer your residual contribution

If your session can't do the main task but CAN do an adjacent piece — verification probe, post-execution receipt, smoke-test, status update — name it explicitly. "What YOUR does after" turns the re-route into a hand-off-with-helper rather than dead weight.

## Gotchas

### Don't re-route without a capability matrix

Vague re-routes get re-re-routed. Be concrete: name the path/credential/dependency mismatch.

### Don't re-route to a session that hasn't proven the capability

"I think K could do it" is a guess; post-prior-receipt is evidence.

### Don't re-route AND start trying anyway

Pick one. Either re-route and hand off cleanly, or attempt with a "best-effort, may fail" disclaimer — never both.

### Don't silently drop your tick during the wait

If your session's tick autonomy is running, it's still posting "idle" while the re-route is in flight — that's correct behavior. Don't disable it.

## Invariants consulted

- **Invariant 1 · Capability-evidence beats capability-guess** — name the prior receipt, don't assume.
- **Invariant 2 · Re-route names the next owner explicitly** — coord's bookkeeping reads the re-route as a hand-off, not a refusal.
- **Invariant 3 · Pick one path** — re-route OR best-effort attempt; never both.
- **Invariant 4 · Tick autonomy continues during re-route wait** — your session is still alive even while the actual task is owned by someone else.

## Seed lessons

1. **Mac path on Windows = silent crash, not visible error** · P1 · generic. Script `cd`s into a path that doesn't exist; bash exits non-zero but the failure shape isn't obvious.
2. **AWS creds wiring varies per session** · P1 · generic. One session may have prod SSM access via IAM; another running on a sandbox box has no creds. Re-route based on receipt history, not env-var sniffing.
3. **Path-symmetric ≠ "probably similar"** · P2 · generic. Re-route to a session whose receipt history proves they've done THIS exact thing against THIS exact target.
4. **Capability matrix is the load-bearing part** · P2 · generic. Reviewer needs to see why the re-route is correct without guessing.
5. **Residual contribution turns dead-weight re-route into helper hand-off** · P2 · generic. "I'll fire the verification probe after E's receipt" keeps your session productive.

## Integration

- **`./stale-assignment-detection.md`** — when the assignment is already done, no re-route needed.
- **`./defer-with-trigger.md`** — when the assignment is RIGHT for your session but blocked on data/classpath.
- **`/verify-before-claim`** — when offering residual verification work, the claim "I'll probe after their receipt" requires actually doing the probe.

## Completeness principle

10/10: capability matrix in the re-route, names path-symmetric session by prior-receipt evidence, offers residual contribution, doesn't try to execute anyway.

7/10: re-route without explicit capability matrix (vague; risks re-re-route).

3/10: try to execute through the wrong env anyway (silent failures, debugging-as-environmental, time wasted).

**Default: 10/10.** Capability matrix + receipt-evidence + residual contribution = clean hand-off.

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version.
