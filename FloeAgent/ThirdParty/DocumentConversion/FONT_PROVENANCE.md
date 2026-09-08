# FloeDocumentSans

Derived from Noto Sans SC VF (Noto CJK Sans 2.004), distributed under SIL OFL 1.1. Original license ships in `Resources/DocumentConversion/FONT-LICENSE.txt`.

Pinned upstream: https://github.com/notofonts/noto-cjk/tree/523d033d6cb47f4a80c58a35753646f5c3608a78

Input: `Sans/Variable/TTF/Subset/NotoSansSC-VF.ttf`. SHA-256: `d68bafcb48a2707749396aa12bbbd833cb70401f3a9a689fd2902c7e0d295964`.

`build_font.py` retains outlines and variable weights, clones 497 glyph aliases so distinct Unicode code points have distinct glyph IDs, preserves variable advance metrics for the cloned glyphs, removes unencoded GSUB alternates from this horizontal export font, and renames the modified font to FloeDocumentSans. This prevents WebKit/Core Graphics PDF export from replacing ordinary CJK letters with Kangxi radical aliases in copied/extracted text. It does not normalize or rewrite the document's source text. PDF layout continues to use WebKit's paginated print formatter. Default PDF typography uses this bundled font; unsupported scripts use system fallback fonts.

Rebuild with Python, fonttools 4.60.2 and Brotli, then run:

```sh
python build_font.py /path/to/NotoSansSC-VF.ttf
```

Generated WOFF2 SHA-256: `b2e2e4ebe4d906e00046b3b32392dabc2c2f40f38c92457a91661ad826f8b3e4`.

The font is loaded from the app bundle as bytes. Conversion never fetches fonts or document resources from the network.
