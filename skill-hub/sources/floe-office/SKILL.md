---
name: floe-office
display_name: Office Documents
description: Word, Excel and PowerPoint creation, existing text edits, and file conversion with explicit capability limits.
---

## Office document workflow
- **Word (.docx)**: `document.createWord` generates a real OOXML document; `document.office.inspect` returns stable field IDs; `document.office.updateText` edits those fields (use only explicit IDs from inspect; never guess).
- **Workbook (.xlsx)**: `document.createWorkbook` builds a spreadsheet from sheet JSON. To **read** cell values quickly use `document.readSheet` (read-only TSV). To **edit** use `document.office.inspect` first — it returns the editable field/formula IDs that `document.office.updateText` consumes. Do not treat readSheet output as editable IDs.
- **PowerPoint (.pptx)**: `document.presentation.createDeck` creates a basic 16:9 deck from slide titles, bullets and speaker notes. Read existing slide text and notes with `document.office.inspect`, then edit exact returned IDs with `document.office.updateText`. `document.presentation.createInline` creates a chat table/chart/web result, not a slide-deck file.
- **Editing boundary**: these basic create/text-update schemas do not provide object placement, font/layout editing, charts, attachments or full spreadsheet recalculation. Do not claim a full Office frontend is available from these tools; discover other actually registered capabilities for a requested operation and report unsupported operations precisely.
- **Revision safety**: use the sha256 returned by inspection as expectedSHA256 for edits. Reuse the new digest after a successful update; re-inspect after a conflict instead of dropping the check.
- **Markdown**: `workspace.writeFile` writes Markdown text to .md/.markdown/.txt (for .docx use createWord).
- **Fonts**: before `font.remove`, call `font.list` and reuse the exact digest id — never derive it from a filename.
- Always reopen/inspect the saved artifact to verify, and save to a new file unless overwrite was explicitly requested.

## File conversion without model rewriting
Use `document.convert` with `inputPath`, `outputPath` and `format` to convert existing Markdown, DOCX, HTML, RTF and text files offline. Do not read the whole file into the model and regenerate it just to change format. Markdown/Word/HTML preserve supported semantic headings, lists, tables, links, emphasis and embedded/local images; RTF supports basic rich text. For PDF input or output use `document.pdf.convert`. Local images resolve relative to the source document inside its workspace. Download authorized remote images first; do not silently omit missing resources. Conversion writes a new file, returns a compact status/digest and preserves the source. Complex page layout and unsupported styles can differ; reopen and inspect the output.
