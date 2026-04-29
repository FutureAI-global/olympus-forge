---
name: pdf-lib-over-puppeteer
namespace: dependency-choice
version: 0.1.0
description: |
  When generating a PDF that mirrors an existing TEXT artifact
  (audit log, transaction receipt, structured report, monospace
  output), use `pdf-lib` + the bundled `StandardFonts.Courier` to
  render page-by-page. Skips Puppeteer / headless Chromium entirely
  (~300MB of dep weight) and keeps the PDF column-aligned exactly
  like the source text. Adopt Puppeteer only when the source is
  genuinely HTML-styled and column alignment via mono can't carry.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
---

# pdf-lib-over-puppeteer · text-mirroring PDFs without Chromium

## Why this exists

Default reach for "I need a PDF" is Puppeteer because it renders HTML the way browsers do. But Puppeteer pulls ~300MB of bundled Chromium, plus a bunch of native deps, plus DevOps complexity (sandbox flags, `--no-sandbox` debate, CI font availability). For an artifact that's already plain monospace text — audit reports, transaction logs, system-status snapshots — that's three orders of magnitude more dep weight than the job needs.

`pdf-lib` is pure JS, ~5MB installed, zero native deps. It bundles 14 standard fonts (Helvetica, Times, Courier, Symbol, ZapfDingbats) that don't need shipping. For a Letter-sized monospace PDF that mirrors a `.txt` artifact verbatim, `pdf-lib` + `StandardFonts.Courier` does the job.

## Trigger conditions

Use `pdf-lib` when:

- Source artifact is already plain text (you have it as a string)
- Column alignment is preserved by a monospace font
- Output should be reproducible bytes for the same input (audit/diff)
- You want zero shipped font assets

Use Puppeteer (or wkhtmltopdf, or react-pdf) when:

- Source is genuinely HTML or styled markup
- You need proportional fonts, tables with cell merging, embedded images
- You need CSS layouts (flex, grid, multi-column, page-break controls)

If you're already running Puppeteer for other reasons (visual-regression tests, scraping, headless screenshots), reusing it for PDFs is fine. But don't ADD Puppeteer just for PDFs.

## Procedure

### Step 1 · install + import

```bash
npm install pdf-lib  # or yarn / pnpm
```

```ts
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
```

### Step 2 · build the doc

```ts
const PAGE_WIDTH = 612;   // Letter, 8.5" * 72 dpi
const PAGE_HEIGHT = 792;  // Letter, 11" * 72 dpi
const MARGIN = 54;        // 0.75"
const FONT_SIZE = 10;
const LINE_HEIGHT = 12;

export async function renderTextArtifactToPdf(text: string, meta: {
  timestamp?: string;
  title?: string;
  creator?: string;
}): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  if (meta.title) doc.setTitle(meta.title);
  if (meta.creator) doc.setCreator(meta.creator);

  // Pin creation date when supplied — makes the PDF byte-reproducible
  // for the same input. Default new Date() bakes wall-clock into the
  // bytes and breaks snapshot tests.
  if (meta.timestamp) {
    const ts = new Date(meta.timestamp);
    if (!Number.isNaN(ts.getTime())) {
      doc.setCreationDate(ts);
      doc.setModificationDate(ts);
    }
  }

  const font = await doc.embedFont(StandardFonts.Courier);
  // ... pagination + line-by-line rendering, see template below
  return doc.save();
}
```

### Step 3 · pagination + line wrap

```ts
const linesPerPage = Math.floor(
  (PAGE_HEIGHT - 2 * MARGIN - LINE_HEIGHT) / LINE_HEIGHT,
);
const charsPerLine = Math.floor(
  (PAGE_WIDTH - 2 * MARGIN) / (FONT_SIZE * 0.6),
);

function wrapLine(line: string, width: number): string[] {
  if (line.length <= width) return [line];
  // Preserve leading whitespace on continuation lines so columns stay
  // aligned. Without this, wrapped lines drift left and tables collapse.
  const indent = line.match(/^(\s*)/)?.[1] ?? "";
  const out: string[] = [];
  let cursor = 0, firstChunk = true;
  while (cursor < line.length) {
    const slice = firstChunk
      ? line.slice(cursor, cursor + width)
      : indent + line.slice(cursor, cursor + (width - indent.length));
    out.push(slice);
    cursor += firstChunk ? width : (width - indent.length);
    firstChunk = false;
  }
  return out;
}

function paginate(lines: string[], perPage: number): string[][] {
  if (lines.length === 0) return [[]];
  const pages: string[][] = [];
  for (let i = 0; i < lines.length; i += perPage) {
    pages.push(lines.slice(i, i + perPage));
  }
  return pages;
}
```

### Step 4 · ASCII-substitute non-WinAnsi runes

`StandardFonts.Courier` uses WinAnsi (Latin-1) encoding. If your source text contains Unicode box-drawing chars (`─ │ ┌ ┐`), brand glyphs (`✓ ✗ →`), or emoji, drawText throws. ASCII-substitute before wrapping:

```ts
function asciiize(text: string): string {
  return text
    .replace(/[─━]/g, "-")
    .replace(/[│┃║]/g, "|")
    .replace(/[╭╮╯╰┌┐┘└╔╗╝╚]/g, "+")
    .replace(/[┼├┤┬┴╋]/g, "+")
    .replace(/[•·●]/g, "*")
    .replace(/✓/g, "[ok]")
    .replace(/✗/g, "[x]")
    .replace(/→/g, "->")
    .replace(/[\u{1F300}-\u{1FAFF}]/gu, "")
    // Catch-all: drop any remaining non-WinAnsi codepoint (>0xFF)
    .replace(/[^\x00-\xFF]/g, "");
}
```

### Step 5 · per-page render with footer

```ts
function drawPage(
  page: PDFPage,
  font: PDFFont,
  lines: string[],
  pageNumber: number,
  pageCount: number,
): void {
  let y = PAGE_HEIGHT - MARGIN;
  for (const line of lines) {
    page.drawText(line, { x: MARGIN, y, size: FONT_SIZE, font });
    y -= LINE_HEIGHT;
  }
  const footer = `page ${pageNumber} of ${pageCount}`;
  const footerWidth = font.widthOfTextAtSize(footer, FONT_SIZE - 2);
  page.drawText(footer, {
    x: PAGE_WIDTH - MARGIN - footerWidth,
    y: MARGIN - LINE_HEIGHT,
    size: FONT_SIZE - 2,
    font,
    color: rgb(0.5, 0.5, 0.5),
  });
}
```

## Verification

- `Buffer.from(bytes.slice(0, 5)).toString("ascii") === "%PDF-"` — magic header
- `Buffer.from(bytes.slice(-7)).toString("ascii").includes("%%EOF")` — trailer
- Re-load via `PDFDocument.load(bytes)` and check `getTitle()` / `getCreator()` / `getPageCount()` — round-trip
- Render the same input twice with pinned `meta.timestamp` and `Buffer.compare(a, b) === 0` — reproducibility

## Failure modes

- **WinAnsi encoding throws on non-Latin-1**: see Step 4. Box-drawing chars are the most common offenders.
- **Wide emoji renders as garbage**: WinAnsi can't encode multi-byte. ASCII-substitute or use an embedded TTF.
- **Reproducibility breaks**: default `new Date()` bakes wall-clock into the bytes. Pin via `meta.timestamp`.
- **PDF readers complain about corrupt structure**: usually a missing `await` somewhere — pdf-lib's font embed + serialize are async.

## Seed lessons

- **id**: `dep-choice-pdf-lib-saves-300mb`
  **scope**: generic
  **pattern**: text-mirroring PDFs (audit logs, transaction receipts, structured reports) use pdf-lib + StandardFonts.Courier; saves ~300MB of bundled Chromium vs Puppeteer.
  **evidence**: One backend bundle had pdf-lib already installed (~5MB) for other purposes; adding a "PDF export" feature reused it instead of pulling Puppeteer.
  **fix**: when implementing PDF export of an existing TEXT artifact, reach for pdf-lib + Courier first. Only adopt Puppeteer when the source is genuinely HTML-styled and column-alignment via mono won't carry.
