# FloeScoreKit third-party inputs

Floe-owned implementation files retain MPL-2.0. The distributed editor is an offline bundle built from the repository's pinned `Qualification/HeavyEditors/WebBuild/package-lock.json`. Exact esbuild inputs are in `Web/bundle-inputs.json`; the shared release notice generator must also cover dependencies embedded inside OSMD's prebuilt UMD.

| Input | Fixed version | License / actual use |
| --- | --- | --- |
| OpenSheetMusicDisplay | 2.2.1 | BSD-3-Clause; MusicXML parsing, engraving, page layout, SVG interaction |
| VexFlow | 1.2.93, embedded in OSMD 2.2.1 | MIT; actual notation paths, glyphs, stems, beams, curves and TAB |
| Gonville glyph path data | The exact copy embedded by VexFlow 1.2.93 / OSMD 2.2.1 | Original author's unrestricted font/path grant; generator code is MIT. Preserve that original grant separately from the VexFlow MIT notice. No Bravura/Petaluma font is introduced by this module. |
| VexFlow custom/microtonal glyph data | The exact copy embedded by the same VexFlow build | VexFlow's source/license closure; retain its original notices |
| fflate | 0.8.3 | MIT; actual compressed MusicXML ZIP import/export |
| jsPDF | 4.2.1 | MIT; actual PDF document output |
| svg2pdf.js | 2.9.0 | MIT; SVG-to-PDF vector conversion |

OSMD includes its own locked JSZip/pako and other dependencies; the shared SBOM/notices inventory follows its actual pinned closure, including a permitted MIT branch where JSZip is dual licensed. Do not infer this embedded closure from whatever top-level JSZip/pako version happens to resolve in the build cache. jsPDF/svg2pdf bring their own locked dependency closure; use the actual bundle inventory and shared notices generator.

Primary sources:

- [OSMD 2.2.1 release](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/releases/tag/2.2.1), [OSMD license](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/blob/2.2.1/LICENSE)
- [VexFlow 1.2.93 source and license](https://github.com/0xfe/vexflow/tree/1.2.93)
- [Gonville original author and font/path terms](https://www.chiark.greenend.org.uk/~sgtatham/gonville/)
- [fflate](https://github.com/101arrowz/fflate), [jsPDF](https://github.com/parallax/jsPDF), [svg2pdf.js](https://github.com/yWorks/svg2pdf.js)
- [MusicXML 4.0 reference](https://www.w3.org/2021/06/musicxml40/musicxml-reference/), [official 4.0 schema source](https://github.com/w3c/musicxml/tree/v4.0/schema)

No MuseScore/LilyPond GPL implementation or soundfont is copied. Text fonts are supplied by the OS/viewer and are not redistributed. AVFoundation is an Apple platform framework. The independent fixture is original and CC0-1.0.
