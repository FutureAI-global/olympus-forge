# Contributing to Olympus Forge

v0.1 is EXPERIMENTAL. Contributions welcome — fixes, new skills, new seed lessons, clarifications. This doc covers how.

## What you can contribute

| Kind | How | Review |
|---|---|---|
| Typo / formatting | PR against `main` | Maintainer merge, same-week |
| New seed lesson | PR adding to a skill's seed-lessons section | Maintainer review, 1–3 business days |
| New skill | PR adding `skills/<name>.md` + update to `CLAUDE.md` routing block in README | Full review, 1 week |
| Clarification to a SKILL.md | PR with `[clarification]` tag in title | Maintainer review, 1–3 business days |
| Breaking change to the schema | Open an issue first · v0.1 accepts these; post-v1.0 requires RFC | Per RFC (defined at v0.2) |

## Before you open a PR

1. Read the skill you're modifying end-to-end
2. Run the existing helper bins against the pool to confirm your change doesn't break them
3. If adding a seed lesson, make sure the `scope` is `generic` (FutureAI-specific content belongs in a private overlay, not here)
4. Bump the version marker if the change is non-additive

## PR template

```
## Change summary
<1–3 sentences>

## Kind
- [ ] Typo / formatting
- [ ] New seed lesson
- [ ] New skill
- [ ] Clarification
- [ ] Breaking change to schema
- [ ] Other

## Motivation
<why this matters — ideally a concrete incident shape>

## Impact on existing users
<does this break anyone's existing setup? migration path?>

## Version bump
- [ ] No version bump needed
- [ ] v0.N → v0.N+1 (EXPERIMENTAL period, breaking OK)
- [ ] Requires RFC (post-v1.0)
```

## Adding a new skill

A new skill SHOULD include:

- `skills/<skill-name>.md` — SKILL.md shape per the existing 7 skills. Structure: frontmatter (name/version/description/allowed-tools), Preamble, Trigger conditions, Workflow phases, Seed lessons, Invariants consulted, Integration points, Completeness Principle, Changelog.
- 3–5 seed lessons demonstrating the failure mode the skill catches
- A routing-rules entry added to the README's install block

Don't clone from the existing 7 skills wholesale — each needs its own trigger conditions + workflow. Copy the STRUCTURE, not the content.

## Adding a new invariant

Invariants are cross-skill rules that multiple skills reference. New invariants SHOULD come from the hoist-proposal flow (≥3 unique sessions reporting a pattern → aggregator proposes → maintainer approves → hoist to `INVARIANTS.md`). One-off invariant additions via direct PR are discouraged unless the case is overwhelming.

## Testing locally before PR

```bash
# Clone + install your fork
git clone <your-fork-url> ~/.claude/skills/olympus-forge-dev

# Run the aggregator against a sample pool (create one if you don't have one)
~/.claude/skills/olympus-forge-dev/bin/aggregator --dry-run

# Test capture-lesson with your fork's helpers
~/.claude/skills/olympus-forge-dev/bin/capture-lesson --skill <existing-skill> --pattern "test" --evidence "test" --fix "test" --severity P3 --scope generic --tags "test"
```

## Code of conduct

Be excellent to each other:

- **Critique patterns, not people.** "This invariant has a gap" is fine. "The author of this invariant is wrong" is not.
- **Assume good faith.** Breaking changes to a draft spec happen; they're not personal.
- **Respect reviewer time.** Before opening a large-scope PR, open an issue first. Don't land 500 LOC of markdown and expect the maintainer to chase the thread.
- **Walk away from flame wars.** If a discussion has gone past three contentious replies, the maintainer may close the thread and ask for a re-draft.

## Getting help

- Open an issue with the `question` label
- Tag `@leehnetinka2033` for governance questions

Response SLA: 3 business days for `question`-label issues. No SLA for open-ended discussions.

## License

By contributing, you agree your contributions are licensed under Apache-2.0 (see [`LICENSE`](LICENSE)). No CLA required at v0.1; may change at v1.0.
