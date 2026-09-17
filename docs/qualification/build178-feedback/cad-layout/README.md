# CAD save controls — browser qualification

Source `3eecf7359bd82ee7f84c46ddfce3dce6b0c280ce`, 2026-09-17. The primary agent operated the real bundled CAD viewer and WASM engine with synthetic DWG input, added text, scrolled the panel and saved the result. Parsing the written DWG found `FLOE-CAD-179` and four entities. [Manifest and output hash](manifest.json).

The original Pencil block pushed basic edit fields outside the panel. Moving it below those fields fixed the iPad layout; a narrower browser check showed that scrolling could still hide Save, so the primary agent also made Undo/Redo/Save stay visible while the panel scrolls.

| Screenshot | Browser viewport |
| --- | --- |
| [Scrolled save controls](iphone-dwg-saved.png) | 402 × 688 |
| [Basic fields and saved text](ipad-dwg-saved.png) | 1133 × 638 |

These are browser component screenshots, **not native device evidence**. The host saves bytes locally through a qualification bridge; native App persistence and keyboard behavior require the separate dual-device XCTest run. Original CI failures remain retained.
