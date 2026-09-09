# Native Office roundtrip probe

`office_native_editor_probe.swift` is a separate development test application.
It hosts the qualified `FloeOfficeNative` framework and uses its real editor UI.
It never links Floe app groups or opens original user documents. It copies each
bundled fixture into its own Application Support/OfficeRoundtrip/UUID directory.

Generate `fixture.docx`, `fixture.xlsx`, and `fixture.pptx` with
`make_office_editor_fixtures.py OUTPUT_DIRECTORY`, using Python with python-docx,
openpyxl, and python-pptx. Add these files and the Swift entry point to a separate
iOS target, link/embed the framework pinned in `engine.lock.json`, and copy its
verified `OfficeRuntimeResources` into the main application bundle. Use developer
signing for the selected test device; keep provisioning profiles and signed
application archives outside repository evidence.

The entry screen opens a synthetic Word, Excel, or PowerPoint document. Activate
the native editor, edit directly, then select **Save and reopen**. The probe waits
for the matching native persistence callback, closes the document, and constructs
a new readonly controller for the same working file. `events.json` records these
callbacks. It does not submit a file to Floe's original-file CAS workspace and
cannot prove that separate integration.

`verify_office_editor_roundtrip.py ORIGINAL SAVED --output REPORT.json` performs
independent Word/XLSX fixture checks and exits nonzero when a named property is
wrong. The Word scenario inserts `EDITED_NATIVE_WORD ` into the second paragraph;
the Excel scenario changes B2 to 36 and expects formula C2 to evaluate to 72.
Do not replace a failed format check with a value-only check. PPT and complete
visual fidelity are deliberately not marked passed by this script.

For a process-only English language control, compile with
`FLOE_ENGLISH_PROBE`. The ordinary build uses actual preferred languages; optional
`FloeProbeLanguage` in a test Info.plist also supplies a process-only override.
The volatile preference does not alter system or persistent language settings.
Record the observed language in `events.json`; do not infer it from build intent.

Current evidence and unresolved failures are recorded in
[`docs/evidence/workflow-upgrade-20260909/README.md`](../../../docs/evidence/workflow-upgrade-20260909/README.md).
Mac Designed for iPad, physical iPhone/iPad, full Floe frontend, Microsoft Office
reopen, and original-file conflict/recovery checks remain separate acceptance scopes.
