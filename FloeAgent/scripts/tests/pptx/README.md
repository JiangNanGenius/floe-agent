# Build191 rich PPTX/DOCX structure checks (tracked)

Local execution path for the rich deck checks whose canonical tracked suite is
`FloeAgent/Tests/FloeDocumentsTests/RichDeckChecksTests.swift` (Swift Testing,
run by the cloud package build).

- `rich_deck_checks.swift` — standalone `@main` port of that test body. Keep it
  in sync with the Swift Testing file; only the wrapper differs.
- `run_rich_deck_checks.sh` — compiles the current `FloeDocuments` sources
  against freshly compiled `FloeCore`/`FloeModels`/`FloeTools`/`FloeWorkspace`
  and the vendored SMBClient checkout, then runs the checks. With
  `PPT_EVIDENCE_DIR` set it exports the generated deck and validates it with
  `FloeAgent/scripts/tests/validate_rich_pptx.py` (python-pptx + openpyxl,
  independent of Floe code).

Run:

```
PPT_EVIDENCE_DIR=Local/Artifacts/build191-ppt \
  bash FloeAgent/scripts/tests/pptx/run_rich_deck_checks.sh
```

Actual result (2026-09-19, after the chart-workbook marker landed in
`FloeDocuments/OfficeDocumentBuilders.swift:345`):

- Swift structure checks: 77 passed, 0 failed.
- Deck embeds `ppt/embeddings/floe-chart-data-1..3.xlsx`; every chart keeps
  `c:externalData` and `Sheet1!$...` formulas; strict save validation accepts
  the deck and rejects a chart whose workbook was removed.
- Independent python-pptx/openpyxl read-back: 0 failures (18 checks).

Prerequisites: Xcode-beta-compatible `swiftc`, the cached third-party module
objects under `FloeAgent/.build/apple/Products/Debug` (Crypto, ZIPFoundation,
SWCompression, BitByteData) and the SMBClient checkout. Missing prerequisites
produce `SKIP` + exit 2, never a fake pass. A python interpreter with
`python-pptx`/`openpyxl` is required only for the independent read-back leg.

Limits: structure level only. It does not prove the native Office engine
overlay, real Office UI, an App build or a device run.
