# 🔨 Olympus Forge

**Cross-session learning skills for Claude Code.**

When you run multiple Claude sessions against the same codebase, each one starts with an empty head. Session A loses 30 minutes to stale-local-state drift. Session B makes the same mistake three hours later. Session C makes a third variant next week. None of them learn from each other — because every session starts fresh.

Olympus Forge is the fix. A skills pack that (a) encodes the most-common failure patterns as enforceable pre-flight / post-flight workflows, and (b) writes structured lessons to a shared pool every session reads at startup. Patterns hit by ≥3 sessions get hoisted into the skill's `Invariants` section — the skill itself gets smarter over time.

**Status:** v0.1 · EXPERIMENTAL DRAFT · breaking changes permitted until v1.0.

## The 7 skills

| Skill | Fires when | What it enforces |
|---|---|---|
| `verify-before-claim` | Before making a factual claim ("tsc clean", "tests pass", "PR opened") | Claim carries tool-invocation evidence or an explicit `unverified` tag |
| `fresh-state` | Before editing a shared-code file | Local state matches current remote HEAD for that file |
| `api-push` | Before pushing to a large-repo remote | Uses the GitHub API blob→tree→commit→ref recipe; CRLF-safe; no ghost-deletion diffs |
| `observability-audit` | Before declaring a feature shipped | Every declared counter has a caller; every silent-catch has a signal |
| `two-claude-review` | Before a PR merges | Independent reviewer re-runs every implementer-claim; grade delta logged |
| `post-mortem` | When a user correction lands | Mistake captured as structured JSONL → shared pool |
| `session-lessons-bootstrap` | First action in a new session joining the ecosystem | Audit current session for failure patterns; contribute to shared pool |

Each invoked via slash command (`/verify-before-claim`, `/fresh-state`, etc.) or auto-suggested by Claude Code when trigger patterns fire.

## Why this exists (the patterns)

Across weeks of multi-session work, these were the most common failure modes:

- **Inflated self-grades** — claim "tsc clean" without running tsc
- **Stale-local-state** — edit a file based on a worktree ≥1 commit behind remote; silent-revert when pushed
- **Ghost-deletion diffs** — `gh pr edit --base` on squash-merged parents
- **Silent dispatch drops** — tool_use emitted without matching tool_result; session spins forever
- **Declared metrics never called** — counter exported; zero call sites; rising failure rate invisible
- **CRLF vs LF mismatch** — huge phantom-diff on first push
- **Premature abstraction** — dead-code branches shipped and abandoned

Each skill encodes one or more of these failure shapes as a pre-flight / post-flight check. Sessions that hit new patterns capture them via `/post-mortem` → the pool grows.

## Install

```bash
# Clone to the Olympus-branded root, then symlink into Claude Code's skill-discovery path
mkdir -p ~/.olympus
git clone https://github.com/FutureAI-global/olympus-forge.git ~/.olympus/forge
mkdir -p ~/.claude/skills
ln -s ~/.olympus/forge ~/.claude/skills/olympus-forge

# Add routing rules to your CLAUDE.md (append this block):
cat >> ~/.claude/CLAUDE.md <<'EOF'

## Olympus Forge routing (auto-suggested skills)

- User correction → `/post-mortem`
- Before claiming "tsc clean" / "tests pass" / etc. without command output → `/verify-before-claim`
- Before editing a shared multi-session file → `/fresh-state`
- Before `git push` on a large repo → `/api-push`
- Before declaring a feature shipped → `/observability-audit`
- Before a PR merges → `/two-claude-review`
- First action when joining an ecosystem → `/session-lessons-bootstrap`

Install location: `~/.olympus/forge/` (symlinked into `~/.claude/skills/olympus-forge/` so Claude Code auto-discovers the skills).
EOF
```

## Usage

Write a lesson (usually invoked by `/post-mortem` — but available standalone):

```bash
~/.olympus/forge/bin/capture-lesson \
  --skill verify-before-claim \
  --pattern "claimed 'tests pass' with tests authored but not run" \
  --evidence "PR #<N> shipped; 2 runtime bugs caught in the first e2e run" \
  --fix "run jest before claiming; cite exit code + test count" \
  --severity P1 \
  --scope generic \
  --tags "self-grade,jest,two-claude"
```

Read the shared pool:

```bash
~/.olympus/forge/bin/aggregator --dry-run
```

Generate weekly hoist proposals:

```bash
~/.olympus/forge/bin/aggregator
# → writes proposed/hoists-YYYY-MM-DD.md with ≥3-session patterns
```

## How it grows

Every invocation of `/post-mortem` writes to `~/.gstack/projects/<slug>/learnings.jsonl`. The aggregator (weekly cron or manual) dedupes by content-hash, counts contributing sessions, and proposes hoisting any pattern that passes threshold:

- **≥3 unique sessions** reporting the same pattern, OR
- **≥2 sessions** for severity P0 (blocks end-to-end correctness)

Hoist proposals land at `proposed/hoists-<date>.md` for maintainer review. Approved proposals move into the owning skill's `Invariants` section + `INVARIANTS.md`. No auto-applies.

## Shared infrastructure

- [`LESSONS-SCHEMA.md`](LESSONS-SCHEMA.md) — canonical JSONL schema + dedup logic
- [`INVARIANTS.md`](INVARIANTS.md) — 11 cross-skill invariants shipped with v0.1
- [`DISTRIBUTE.md`](DISTRIBUTE.md) — paste-ready message to onboard other Claude sessions into the pool
- [`bin/`](bin/) — helper binaries: `lesson-id`, `capture-lesson`, `aggregator`, `backfill-gstack-aliases`

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Submissions welcome: new skills, new seed lessons, bug fixes, clarifications. Governance at [`GOVERNANCE.md`](GOVERNANCE.md) — single-author v0.1, RFC-based at v0.2.

## License

Apache-2.0. See [`LICENSE`](LICENSE).

## Status + changelog

- **v0.1 (2026-04)** — initial release. 7 skills, 11 invariants, schema v1, aggregator, helpers.

## Contact

GitHub issues welcome. For design-level questions: maintainer at [@leehnetinka2033](https://github.com/leehnetinka2033).

## From the makers of Olympus

Olympus Forge is a sibling project to [Olympus](https://github.com/FutureAI-global), FutureAI's AI diagnostic product. The techniques encoded here emerged from building the Olympus harness — a multi-session, multi-model, multi-tool system where the "same mistake, different session" problem hurts every day. Forge encodes what we've learned. It's ours, but it's everyone's.

🔨
