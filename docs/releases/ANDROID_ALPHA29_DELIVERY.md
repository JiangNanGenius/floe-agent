# Android Alpha29 delivery — 2026-11-06

- Release: [android/v0.1.0-alpha.29](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.29), GitHub Full prerelease, code48.
- Immutable APK source: `2006fe34c71eae66919102536dce0e88d36f7add`. Full APK: 162,695,401 bytes, SHA-256 `c5341f1613dfc97c92f1bf25bc98cf7dd79d2f6cd459ef8f19e300a01ec8111a`.
- Six allowlisted assets: one Full ARM64 APK, optional Office component, exact Alpha28→29 delta and manifest, corresponding source, checksums. Remote tag/object/source and all six anonymous download bodies matched; iOS Latest remains `v1.7.74`.
- Full/Play targeted compilation and 11 SVG/preview checks passed. Unchanged native05 production inputs were reused with 58 raw/packaged bindings and package/signature/ARM64/16 KiB checks. The delta reconstructed the signed target exactly.

## Samsung acceptance

- Android13/API33: App code47 downloaded the public full APK, showed progress and verified completion, and used the system installer. Installed code48 base APK matched the public SHA-256 above. Existing tasks, selected model and files remained visible; no uninstall/downgrade or host APK installation was used.
- Real local SVG preview displayed the retained green file. After opening Linux through the selected SVG, the software choice was Inkscape rather than the old text tab.
- App48 initially had runtime47, so Linux startup failed. The original failure was preserved. Settings → Execution → Local Environment updated the embedded runtime through system confirmation/security scanning. Runtime48 matched the embedded public APK's bytes; the existing rootfs and Inkscape remained installed.
- A fresh Linux graphical session opened the file, accepted real touch input, changed green to red and saved. The granted original automatically changed before any manual reconciliation or Stop: 1,181 bytes, SHA-256 `6e99051e60a3006230dcbb1b0c219b0333d75b9ca6489d978d774ae2193e73bc`. After actual Stop, the native SVG preview reopened red, with the original digest retained.
- No paid provider/model calls and no emulator runs were needed for this batch. These are one Samsung/one SVG/provider results, not a claim for every format, device or the complete N01–N08 goal.

## Known issues and subsequent source

Alpha29 may require the separate runtime update above after the main App update. Its Linux screen only gives a generic startup failure for this condition. A direct existing setup entry, gated by actual environment state, is implemented and Full/Play compiled in subsequent source, **not in Alpha29**.

Some update-notice Chinese characters were corrupted at network chunk boundaries, and the known-issues excerpt included the subsequent bilingual section. Subsequent source accumulates bounded bytes before UTF-8 decoding and stops the excerpt at the Markdown divider; three focused regression cases passed. This fix is **not in Alpha29** and does not change the published APK/tag.

Static SVG filters/external resources/active content and over-budget content are refused explicitly; TIFF is not implemented. Original failures, recovery copies and exact production records remain retained. The overall N01–N08 delivery goal stays active.
