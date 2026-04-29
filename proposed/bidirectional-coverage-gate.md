---
name: bidirectional-coverage-gate
namespace: session-lessons
version: 0.1.0
description: |
  Symmetric set-diff CI gate enforcing parity between two sources of truth
  (code registry vs doc, generator vs schema, route list vs SDK). Includes
  self-explanatory failure diagnostics and a sanity floor to catch
  regex-broke-silently false-greens.
allowed-tools:
  - Read
  - Write
  - Bash
provenance: |
  forged 2026-04-29 from PR #1878 (FDRS Layer 2 safety-case-coverage.test.ts).
  Caught 3 silent drift incidents within 2 weeks of landing.
---

# bidirectional-coverage-gate · symmetric set-diff with self-explanatory failures

## Why this exists

- Two sources of truth must stay in sync: code registry vs documentation, schema vs generator, backend route list vs frontend SDK.
- Without a gate they drift silently. By the time someone reads the doc to make a real decision (tier promotion, safety review, deploy), it underrepresents reality and the decision is ungrounded.
- One-direction gates fail half the time: only "every code item has a doc row" → doc accumulates dead rows for removed code; only "every doc row has a code item" → new code lands undocumented.
- Right shape: enforce **both directions** as separate test cases, with diagnostic messages that name what's missing on which side AND give the operator a verb. Plus a sanity-floor assertion that catches the false-green when a regex silently stops matching.

## Preamble

```bash
if [ -x ~/.claude/skills/gstack/bin/gstack-learnings-search ]; then
  ~/.claude/skills/gstack/bin/gstack-learnings-search --tag bidirectional-coverage-gate --limit 3 2>/dev/null || true
fi
```

## Trigger conditions

- Code registry that declares N items (adapter `register()` calls, route definitions, tool tier tags, etc.).
- A companion doc inventorying those items (safety case, API reference, manifest).
- Generator + consumed schema (codegen output should match the schema).
- Backend route list ↔ frontend client SDK that should mirror it.
- Two sources where drift between them produces silent quality degradation, not loud test failures.

Voice triggers: "make sure the doc stays in sync", "we keep forgetting to update X when we add Y", "the safety-case is out of date", "drift gate".

## Workflow

### Phase 1 · Identify the two sources, their parsers, their canonical IDs

| Side A (registry) | Side B (doc) | Canonical ID |
|---|---|---|
| `register(new XAdapter())` calls | safety-case §2 table rows | adapter class name |
| route definitions | OpenAPI doc paths | URL pattern |
| tool tier-tag exports | authority manifest rows | tool name |

The canonical ID must be unambiguous on both sides — pick the form that's easiest to extract via regex/parser from each.

### Phase 2 · Write tight, narrow parsers (regex OK for stable structural forms)

```typescript
import * as fs from "node:fs";
import * as path from "node:path";

const REGISTRY_PATH = path.resolve(__dirname, "../../../<source>");
const DOC_PATH = path.resolve(__dirname, "../../../<doc>");

function parseRegistry(src: string): string[] {
  // Tight regex matching only the structural form — not a full parser.
  // If the source format is stable, regex is fine; if it changes, the
  // gate failure surfaces it immediately.
  const re = /register\s*\(\s*new\s+([A-Z][A-Za-z0-9]*Adapter)\s*\(\s*\)\s*\)/g;
  const found = new Set<string>();
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) found.add(m[1]);
  return [...found].sort();
}

function parseDoc(md: string): string[] {
  // Walk to the relevant section, then collect canonical IDs from each row.
  // Use unique anchors (e.g. "## §2") so the parser doesn't pick up
  // references in §3+.
  const start = md.indexOf("## §2");
  if (start < 0) throw new Error("doc missing '## §2' section");
  const end = md.indexOf("## §3", start);
  const section = end > 0 ? md.slice(start, end) : md.slice(start);
  const re = /^\|[^\n]*?`([A-Z][A-Za-z0-9]*Adapter)`/gm;
  const found = new Set<string>();
  let m: RegExpExecArray | null;
  while ((m = re.exec(section)) !== null) found.add(m[1]);
  return [...found].sort();
}
```

### Phase 3 · Symmetric assertions with operator-actionable diagnostics

```typescript
describe("coverage gate", () => {
  let registered: string[];
  let documented: string[];

  beforeAll(() => {
    if (!fs.existsSync(REGISTRY_PATH)) throw new Error(`missing ${REGISTRY_PATH}`);
    if (!fs.existsSync(DOC_PATH)) throw new Error(`missing ${DOC_PATH}`);
    registered = parseRegistry(fs.readFileSync(REGISTRY_PATH, "utf-8"));
    documented = parseDoc(fs.readFileSync(DOC_PATH, "utf-8"));
  });

  it("every registered item has a doc row", () => {
    const missing = registered.filter((a) => !documented.includes(a));
    if (missing.length > 0) {
      throw new Error(
        `doc is missing ${missing.length} row(s):\n` +
          missing.map((a) => `  - ${a}`).join("\n") +
          `\n\nAdd a row for each (with <required-fields>) before merging.`,
      );
    }
  });

  it("every doc row corresponds to a registered item (no orphans)", () => {
    const orphan = documented.filter((a) => !registered.includes(a));
    if (orphan.length > 0) {
      throw new Error(
        `doc has ${orphan.length} orphan row(s) for items no longer registered:\n` +
          orphan.map((a) => `  - ${a}`).join("\n") +
          `\n\nRemove these rows or re-add the items if removed by mistake.`,
      );
    }
  });

  // Sanity floor — guards against regex-broke-silently bugs.
  it("registry parser finds at least N items (baseline)", () => {
    expect(registered.length).toBeGreaterThanOrEqual(BASELINE_N);
  });

  it("doc parser finds at least N rows (baseline)", () => {
    expect(documented.length).toBeGreaterThanOrEqual(BASELINE_N);
  });
});
```

### Phase 4 · Land the gate FIRST against passing state, then add the new item

Land the gate as its own PR against current state — green. THEN add new items in a follow-up PR. This proves the gate works the way you think. Landing the gate + the breaking change in the same PR means a failed test is ambiguous: did the gate break, or did the change break it correctly?

## Gotchas

### Don't parse YAML/JSON sources with regex

Use a real parser. Regex is fine ONLY for narrow, stable structural forms (registration calls, table rows with a fixed delimiter). For YAML/JSON, use the language's parser.

### Don't fail with `expect(a).toEqual(b)` for ID arrays

Jest's diff for arrays of names is unreadable for >5 items. Roll your own diagnostic that names what's missing on which side, with a verb.

### Don't skip the floor assertion

A 0==0 pass is the worst kind of false-green. If your regex silently breaks (someone refactors the registration syntax), both sides return `[]`, the symmetric checks pass vacuously, and the gate has stopped enforcing anything.

### Don't put the gate and the breaking change in the same PR

Land the gate against current state first. Then the next PR's test failure is unambiguously "the change broke the gate" rather than "the gate doesn't work yet."

### Don't make the parser overly permissive

A regex that matches both `register(new XAdapter())` AND `// register(new XAdapter())` (commented-out code) gives false-positives. Match only the structural form you actually mean.

## Invariants consulted

- **Invariant 1 · Both directions, always** — A→B and B→A; one-way gates fail half the time.
- **Invariant 2 · Diagnostic IS the documentation** — failing run must be self-explanatory without reading test source.
- **Invariant 3 · Sanity floor catches false-greens** — empty == empty is a vacuous pass.
- **Invariant 4 · Gate lands first against passing state** — proves the gate works before the change exercises it.

## Seed lessons

1. **One-direction gates miss half the drift class** · P0 · generic. Either dead rows accumulate or new code lands undocumented; pick one disaster.
2. **Floor assertion catches regex-broke-silently** · P1 · generic. The single most likely silent-failure mode for any regex-based gate.
3. **Operator-actionable diagnostic > Jest array diff** · P1 · generic. Reviewer reads the failure message; if they need to read the test source to understand it, you've lost.
4. **Land the gate first; ship the change second** · P2 · generic. Avoids ambiguity when the gate fires.
5. **Real parsers for structured formats** · P2 · generic. Regex on YAML/JSON is fragile; the structural form might be stable, but escapes/quotes vary.

## Integration

- **`./hand-written-not-autodetect.md`** — companion: the hand-written promise, with the gate as its enforcement layer.
- **`/verify-before-claim`** — claims like "this gate enforces drift" require the gate's failing-output pasted in the PR body for both directions.

## Completeness principle

10/10: bidirectional set-diff · operator-actionable diagnostic with names + verb · sanity floor on each parser · gate lands first against passing state.

7/10: bidirectional set-diff but no sanity floor (false-greens slip through when regex breaks).

3/10: one-direction gate (either dead rows accumulate or new code lands undocumented).

**Default: 10/10.** The gate is ~50 LOC; the failure mode without it is silent doc rot that surfaces at the worst possible time (during a real decision based on the rotted doc).

## Changelog

- **v0.1 (2026-04-29) · session-C** · Initial version forged from PR #1878.
