# Olympus Forge Governance

**Status:** v0.1 · single-author governance. Evolves to RFC-based at v0.2.

## v0.1 · Single-author governance

Olympus Forge v0.1 is authored + maintained by Lee Hnetinka (`@leehnetinka2033`) with technical drafting by Claude Opus 4.7. The author has final say on all schema + skill + invariant changes.

**Rationale:** shipping v0.1 fast without RFC ceremony is a conscious choice. Get the mechanics working, get real feedback, iterate. Similar pattern to MCP's early versions.

**What this means in practice:**

- The author merges all PRs. No second-reviewer gate.
- Breaking changes ship with a version bump (v0.1 → v0.2) and no migration grace period.
- Discussion is welcome in issues; decisions are made by the author with rationale posted on the decision thread.
- No SLA beyond the 3-business-day `question`-label response.

## v0.2 · Migrating to RFC-based

Triggers to migrate from single-author to RFC-based:

- **≥ 3 independent adopters** using Olympus Forge in their own Claude Code workflows
- **≥ 1 year since v0.1** — time for the patterns to mature through real usage
- **Author saturation** — maintainer load too high for same-week merges

Any of those three triggers the migration.

### v0.2 process (draft, subject to change before v0.2 ships)

1. **RFCs live in the repo** at `rfcs/NNNN-<short-name>.md`, numbered sequentially
2. **RFC template** includes: motivation, design, alternatives considered, migration path, verification plan
3. **Review window** is 14 calendar days minimum
4. **Acceptance** requires:
   - Maintainer approval (author or designated delegate)
   - ≥1 adopter maintainer signed off that the RFC doesn't break their setup OR provides a migration path
   - No unresolved "this breaks us with no migration" comments from current adopters
5. Post-acceptance, the RFC is merged, the spec is updated, version bumps.

RFCs that fundamentally rework the pack (new skill slots, changing the schema, changing the hoist threshold) follow the process with extra review time + explicit sign-off from listed adopters.

## Maintainer delegation (v0.2+)

Under v0.2, the author may delegate per-skill maintainer responsibilities:

- **Per-skill maintainers** — one per skill. Owns PRs against `skills/<skill-name>.md` + its seed lessons.
- **Schema maintainer** — owns `LESSONS-SCHEMA.md` changes. One person total.
- **Aggregator maintainer** — owns `bin/aggregator` + the hoist-proposal flow.

Delegation is at the author's discretion. Delegates are named in a footer of each file they own.

## Versioning

Olympus Forge follows loose semver:

- **v0.X** during DRAFT. Any change permitted. Adopters pin to exact version.
- **v1.0** when the pack is considered production-ready. Breaking changes require major bump.
- **v1.X** minor — additive (new skills, new seed lessons, new invariants)
- **v1.X.Y** patch — clarifications, typo fixes, bug fixes that don't change semantics

A "breaking change" is defined as:

- Removing a required field from the JSONL schema
- Changing the semantics of an existing skill's workflow
- Removing a skill without a migration path
- Any change that would cause a previously-working session setup to fail without updates

## Conflict resolution

If two reasonable readings of a skill spec conflict, the author's interpretation wins. If a reader believes the author's interpretation is wrong:

1. Open an issue with the `clarification` label and cite the conflict
2. Propose a skill edit that makes the intended reading unambiguous
3. PR the edit

The author may publish an official interpretation as a footnote before the edit lands.

## Code of conduct

Per CONTRIBUTING.md. Author enforcement during v0.1; v0.2+ delegates to a 3-person panel.

## License

Apache-2.0 (see [`LICENSE`](LICENSE)). License does not change at version bumps.

## History

- **2026-04 · v0.1 drafted.** Single-author governance. Author: Lee Hnetinka (with technical drafting by Claude Opus 4.7).
