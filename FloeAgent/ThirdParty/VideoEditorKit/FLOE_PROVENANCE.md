# VideoEditorKit in Floe

Source: https://github.com/didisouzacosta/VideoEditorKit
Pinned commit: `c917b1e99ddc631b754a43704c05dfe3836e8183`
License: MIT; see LICENSE. Retrieved 2026-09-13.

Vendored source and tests. Omitted the 37 MiB preview.mp4 demo asset; runtime editing accepts workspace files. No remote transcription provider is configured by Floe. iPad and real export qualification remain required.

Floe adds one real-export Chinese-caption pixel/timing test to Models/VideoEditorTests.swift. Floe changes resolvedWords to keep captions without measured word timings as full text blocks in both preview and export.
