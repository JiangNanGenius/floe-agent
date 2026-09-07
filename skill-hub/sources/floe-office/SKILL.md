---
name: floe-office
display_name: Office Documents
description: Word, workbook and Markdown creation/inspection/editing with the right tool for each job.
---

## Office document workflow
- **Word (.docx)**: `document.createWord` generates a real OOXML document; `document.office.inspect` returns stable field IDs; `document.office.updateText` edits those fields (use only explicit IDs from inspect; never guess).
- **Workbook (.xlsx)**: `document.createWorkbook` builds a spreadsheet from sheet JSON. To **read** cell values quickly use `document.readSheet` (read-only TSV). To **edit** use `document.office.inspect` first — it returns the editable field/formula IDs that `document.office.updateText` consumes. Do not treat readSheet output as editable IDs.
- **Markdown**: `document.createMarkdown` writes .md/.markdown/.txt only (for .docx use createWord).
- **Fonts**: before `font.remove`, call `font.list` and reuse the exact digest id — never derive it from a filename.
- Always reopen/inspect the saved artifact to verify, and save to a new file unless overwrite was explicitly requested.