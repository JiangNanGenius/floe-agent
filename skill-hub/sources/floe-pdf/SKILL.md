---
name: floe-pdf
display_name: PDF Workbench
description: Closed-loop PDF workflow: inspect, render, merge, split, edit, fill forms, verify.
---

## PDF workbench
Follow this closed loop for PDF tasks:
1. **Inspect first**: `document.pdf.inspect` for page count, metadata, text, and query matches before planning any edit.
2. **Render only relevant pages** with `document.pdf.render` (single page or a spec like "1-3,5") when visual evidence is needed.
3. **Compose**: `document.pdf.merge` (2-10 PDFs in order), `document.pdf.split` (extract pages "1-3,5,8-10"), `document.pdf.fromImages` (one image per page).
4. **Edit** with `document.pdf.edit`: page removal, per-page rotations, positioned watermarks, page numbers and password protection. `replaceText` now performs exact case-sensitive **native content-stream edits**, never a white cover. Current text-object editing requires an encodable existing font and replacement within the original bounds; scanned, nested/cross-object matches and overflow fail without saving. This is not secure redaction or general paragraph reflow. Signed PDFs require an explicitly authorized unsigned-copy workflow. Never claim an unsupported edit succeeded.
5. **Forms**: `document.pdf.fillForm` lists AcroForm fields (name + type) and fills text/checkbox/dropdown/radio/option-list fields with per-type validation. Unknown fields and invalid options are reported, never silently applied.
6. **Save to a new output** unless the user explicitly asked for overwrite, then reopen the saved file with `document.pdf.inspect` and render the changed pages to verify.
