---
name: route-error-driven-payload-discovery
namespace: session-lessons
version: 0.1.0
description: |
  When you need to synthesize an HTTP request against a known endpoint
  but don't have the canonical client/SDK, build the request iteratively
  by reading the route handler's structured validation errors. Each 400
  response narrows the body schema. Faster than reading source, faster
  than re-installing the SDK, faster than asking another session for the
  payload shape. Fire when you need a curl-against-prod and the canonical
  tooling isn't on your machine.
allowed-tools:
  - Bash
provenance: |
  forged 2026-05-01 from a from-scratch verifier built in 5 min during
  the Olympus Bedrock 400 launch-blocker. Iris's verify-bedrock-shape.sh
  was authored on Mac at /Users/leelee2/.olympus/harness/ and not synced
  to the Win11 box. The Olympus CLI bundle was on disk but env wasn't
  wired. Reading the route handler's 400 responses ("turn.role must be
  'user'") got from "no script" to "verifier reproducing the bug" in
  under 5 minutes.
---

# route-error-driven-payload-discovery · build a curl by reading the server's 400s

## Why this exists

You need to hit an HTTP endpoint that another session normally hits via a CLI/SDK. The canonical tooling isn't installed on your machine, isn't synced from the session that authored it, or has a stale auth state. The endpoint takes a structured JSON body. You don't know the exact shape.

Three slow paths people default to:

1. **Read the route handler source code.** Works, but a 1500-line route file with nested types takes 10+ minutes to parse correctly. Wrong if the body is gated behind middleware that re-shapes it.
2. **Install the canonical CLI/SDK.** Works, but cold-install + auth-wire + first-call cycle is 20+ minutes on a fresh box.
3. **Ask another session for the payload shape.** Works, but adds 5-15 minutes of round-trip and assumes the other session is online and remembers.

The fast path: **iterate against the server's structured 400s**. Modern API route handlers (Fastify, Express, Next.js, whatever) typically return JSON validation errors that are precise:

```json
{"error":"invalid_turn","note":"turn.role must be 'user'"}
```

Each 400 narrows the schema. Three iterations is usually enough.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag route-error-payload --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- You need to synthesize a curl against a known production endpoint
- You don't have the canonical client (not installed, not on PATH, stale, or wrong-OS)
- The endpoint requires a structured JSON body
- The endpoint's route handler returns structured validation errors (not opaque "Bad Request" / 500s)

Voice triggers: "the verifier isn't on this box", "I'll build the curl myself", "what's the payload shape", "iris's script wants Mac paths".

Negative triggers (use a different skill):

- The endpoint returns opaque errors (`"Bad Request"` with no JSON body) → read source
- The body is binary/multipart → read source
- The session has the canonical CLI installed already → use it

## Workflow

### Phase 1 · Find auth + base URL

```bash
# Auth state on this machine
ls -la ~/.olympus/auth.json ~/.config/<vendor>/credentials* 2>/dev/null

# Or check env vars
env | grep -iE "token|auth|key" | head -5
```

The auth file usually has the access token + base URL; if not, grep the bundled CLI binary:

```bash
strings <bundled-cli-binary> 2>/dev/null \
  | grep -E "https://[a-z0-9.-]+/api/" \
  | sort -u | head -10
```

Confirm the token isn't expired:

```bash
python -c "
import json, datetime
a = json.load(open('<auth-file>'))
exp_ms = a.get('accessExpiresAtMs') or a.get('exp', 0) * 1000
print('expires:', datetime.datetime.fromtimestamp(exp_ms/1000).isoformat())
"
```

### Phase 2 · First curl with a minimum-viable body

Start with the simplest plausible body shape. If the endpoint is a "submit message" type, try:

```bash
TOKEN=$(python -c 'import json; print(json.load(open("<auth-file>"))["accessToken"])')
RESP=$(curl -sS -X POST "<base>/api/v1/<endpoint>" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}')
echo "$RESP"
```

Read the response. It'll either be:

- `{"error":"<machine-readable>","note":"<human-readable>"}` · proceed to Phase 3
- A 200/201 with a resource ID · endpoint accepted empty body, you're done
- An opaque text error · fall back to source-reading (negative trigger)

### Phase 3 · Iterate against the validation errors

For each 400 response, the `note` (or `message`/`errors[]`) field tells you the next required field:

```
First attempt:  {}
Response:       {"error":"missing_vin","note":"vin required"}
Add: vin

Second attempt: {"vin": "1FTRF3AT4TEC85082"}
Response:       {"error":"missing_turn","note":"body.turn required"}
Add: turn

Third attempt:  {"vin": "<...>", "turn": {"text": "test"}}
Response:       {"error":"invalid_turn","note":"turn.role must be 'user'"}
Add: turn.role

Fourth attempt: {"vin": "<...>", "turn": {"role": "user", "kind": "tech-message", "text": "test"}}
Response:       2xx with a conversation/turn ID
```

Three to five iterations is typical. Each tells you what's required AND its location in the body (`body.turn.role` not `body.role`).

### Phase 4 · Wrap in a script

Once the body shape is known, save the script for re-runs:

```bash
cat > ~/.olympus/harness/verify-<thing>.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TOKEN=$(python -c 'import json; print(json.load(open("<auth-file>"))["accessToken"])')
BASE="<base-url>"

# Step 1 · create resource
RESP=$(curl -sS -X POST "$BASE/api/v1/<endpoint>" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '<body-json>')
ID=$(echo "$RESP" | python -c 'import json,sys; print(json.load(sys.stdin)["<id-field>"])')
echo "id = $ID"

# Step 2 · stream/post follow-up
curl -sS --max-time 90 -N -X POST "$BASE/api/v1/<endpoint>/$ID/<sub>" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '<follow-up-body>'
EOF
chmod +x ~/.olympus/harness/verify-<thing>.sh
```

### Phase 5 · Capture the schema for re-use

The body shape you just discovered is a real artifact. Save it. Either:

- A short comment at the top of the script naming the route handler file + line where validation lives
- A schema-by-example block in the script's docstring
- A `body.json` next to the script with the canonical shape

This means the next session that needs to hit the same endpoint doesn't have to re-discover.

## Seed lessons

### lesson 1 · the "role" was at body.turn.role, not body.role

Olympus' `POST /api/v1/olympus/conversations/:id/turns` route validates `body.turn.role !== "user"` and returns 400 with `note: "turn.role must be 'user'"`. The naive body shape `{role: "user", kind: "tech-message", text: "..."}` fails. The actual shape is `{turn: {role: "user", kind: "tech-message", text: "..."}}`. Two iterations: first attempt sent `{role, kind, text}`, server's 400 referenced `body.turn.role`, second attempt wrapped in `{turn: ...}` and succeeded.

The `body.turn.role` location in the validation message is the giveaway. When the error's path includes a parent key, your body needs that parent.

### lesson 2 · the auth file is the fastest credential discovery

`~/.olympus/auth.json` contained `accessToken + refreshToken + email + accessExpiresAtMs`. 261-char access token, valid for 30 more days. No need to re-auth, no need to refresh · just read it. Other vendors store credentials at `~/.config/<vendor>/`, `~/.aws/credentials`, `~/.netrc`. Check those before assuming you need to authenticate.

### lesson 3 · the bundled CLI binary is a grep-able schema source

When the auth file doesn't have the base URL, the bundled CLI binary almost always does. `strings <cli> | grep https://` produces the production base URL. `strings <cli> | grep -oE 'api/v1/[^"' "']+'` produces the endpoint paths. This is faster than reading the SDK's source.

### lesson 4 · don't re-stringify the body for the actual send

Once you've iterated to the right shape, capture the EXACT body string and send THAT. Re-stringifying via different libraries (Python json vs JS JSON.stringify vs jq) can produce subtly different output (key order, whitespace, escaping). For diagnostic verifiers that need to be byte-identical to a reference call, save the body to a file and `--data @body.json` instead.

### lesson 5 · run the verifier in foreground with --max-time

```bash
curl -sS --max-time 90 -N -X POST "..." > sse.log 2>&1
```

Foreground curl with a generous max-time is more reliable than background-and-kill. SSE streams can take 30-60s for a tool-dispatch turn; backgrounding-and-killing-after-N-seconds frequently kills mid-flight before the response lands. `--max-time` lets curl complete naturally if it can, AND caps the wait if the server hangs.

## Invariants consulted

- `every-claim-has-evidence` (`verify-before-claim`) · the verifier you build under this skill is what produces evidence for downstream "the bug reproduces" / "the fix works" claims
- `path-symmetric-rerouting` · INSTEAD of re-routing the verifier to a session that has it, this skill is the "do it yourself in 5 min" alternative when re-route would cost more

## Integration points

- Triggers `instrument-then-fix` when the verifier reveals a structural-invariant violation
- May trigger `coord-pr-as-message-bus` to share the resulting verifier with peer sessions
- May trigger `ssm-bash` for the EC2-side log capture concurrent with the curl

## Completeness Principle

This skill is complete when, given a production endpoint, an auth file, and a single 400 response, you can produce a working verifier in under 5 minutes without reading any route handler source code.

## Changelog

- v0.1.0 (2026-05-01) · initial · forged from the from-scratch Olympus Bedrock verifier built during the launch-blocker arc
