"""Build the OFL document font with distinct glyph IDs for Unicode aliases.

Core Graphics exports WebKit glyphs without source text; shared cmap entries
otherwise extract as Kangxi radicals instead of the original CJK characters.
Keep outlines and variable weights, but give each encoded character its own ID.
Build dependency: fonttools 4.60.2 with brotli. Input: pinned Noto Sans SC VF.
"""
import copy, hashlib, pathlib, sys
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import otTables
source = pathlib.Path(sys.argv[1])
assert hashlib.sha256(source.read_bytes()).hexdigest() == "d68bafcb48a2707749396aa12bbbd833cb70401f3a9a689fd2902c7e0d295964", "Unexpected upstream font"
font = TTFont(source, recalcTimestamp=False)
font.ensureDecompiled()
order = list(font.getGlyphOrder())
# HVAR without an explicit map uses glyph indices. Make that mapping explicit
# before appending glyphs so every clone keeps its source's variable metrics.
metric_maps = []
for tag, advance in [('HVAR', 'AdvWidthMap'), ('VVAR', 'AdvHeightMap')]:
    if tag not in font: continue
    table = font[tag].table
    if getattr(table, advance) is None:
        mapping = otTables.VarIdxMap()
        mapping.mapping = {glyph: index for index, glyph in enumerate(order)}
        setattr(table, advance, mapping)
    metric_maps += [value.mapping for key, value in vars(table).items() if key.endswith('Map') and value is not None]
seen, replacements = {}, {}
for code, glyph in sorted(font.getBestCmap().items()):
    if glyph in seen:
        new = f"floeUnicode{code:06X}"
        font['glyf'][new] = copy.deepcopy(font['glyf'][glyph])
        font['hmtx'].metrics[new] = font['hmtx'].metrics[glyph]
        if 'vmtx' in font: font['vmtx'].metrics[new] = font['vmtx'].metrics[glyph]
        if 'gvar' in font: font['gvar'].variations[new] = copy.deepcopy(font['gvar'].variations.get(glyph, []))
        for mapping in metric_maps: mapping[new] = mapping[glyph]
        order.append(new)
        replacements[code] = new
    else: seen[glyph] = code
font.setGlyphOrder(order)
for table in font['cmap'].tables:
    if table.isUnicode() and hasattr(table, 'cmap'):
        for code, glyph in replacements.items():
            if code in table.cmap: table.cmap[code] = glyph
# Modified font: do not use upstream reserved family names.
for record in font['name'].names:
    if record.nameID in (1, 2, 3, 4, 6, 16, 17, 25):
        value = 'Regular' if record.nameID in (2,17) else 'FloeDocumentSans'
        record.string = value.encode(record.getEncoding())
# Export only encoded horizontal glyphs. GSUB alternates have no Unicode cmap
# entry and Core Graphics can otherwise assign unrelated fallback characters.
if 'GSUB' in font: del font['GSUB']
font.flavor = 'woff2'
output = pathlib.Path(__file__).resolve().parents[2] / 'FloeApp/Resources/DocumentConversion/FloeDocumentSans.woff2'
font.save(output)
print(f'{len(replacements)} distinct mappings; {output.stat().st_size} bytes; SHA256={hashlib.sha256(output.read_bytes()).hexdigest()}')
