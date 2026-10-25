# Cupertino Icons (derived glyph source)

Floe's shared Android icon family takes its generated `FloeGlyphs.kt` outlines
from `CupertinoIcons.ttf` in the Flutter third_party package `cupertino_icons`
2.0.0 (MIT; text in `LICENSE`). The font is a development-time converter input
only: the APK ships generated vector path strings, not the font, not Flutter,
and no new Gradle dependency.

- `LICENSE` — upstream MIT text (glyph artwork/font), byte-identical.
- `upstream/Flutter-BSD-LICENSE` — BSD-3-Clause text for the pinned
  codepoint-name table `upstream/flutter-3.35.0-icons.dart` (The Flutter
  Authors). Separate license from the MIT glyph artwork.
- `PROVENANCE.json` — pinned archive/font/codepoint hashes, generator,
  transform constants, per-glyph map and honest fallback roles.
- `upstream/CupertinoIcons.ttf` — pinned font (regeneration input).
- `upstream/flutter-3.35.0-icons.dart` — pinned codepoint-name table.

Regenerate: `FONTTOOLS_WHEEL=/path/fonttools-4.60.1-py3-none-any.whl python3 tools/icons/generate_floe_glyphs.py` (add `--check` to verify the committed file is byte-identical; hashes are enforced by the script).
