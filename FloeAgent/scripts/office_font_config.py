#!/usr/bin/env python3
"""Floe's Office font-substitution configuration, validated against real fonts.

Build 232 shipped no Floe-owned font substitution reachability for the
Windows/Chinese families documents actually name: the engine's own VCL
substitution table (present in `share/registry/main.xcd`) lists targets such
as `fzsongti`/`msunglightsc`/`nsimsun` that are not installed, so an imported
PPTX/DOCX naming 宋体/SimSun, 黑体/SimHei, 微软雅黑/Microsoft YaHei, 楷体/KaiTi,
仿宋/FangSong, 等线/DengXian or the Latin defaults falls through the whole list
into whatever fallback the engine picks.

This module owns the bounded repair:

* `FloeOfficeFontSubstitutions.xcu` is an additive `user:` configuration
  layer (the host loads `${BRAND_BASE_DIR}/coolkitconfig.xcu` last). It uses
  the pinned VCL registry hierarchy: `FontSubstitutions` is a set of locale
  members (`org.openoffice.VCL:LocalizedFontSubstitutions['en']`), and each
  locale member is a set of `LFonts` alias records. An existing alias is
  addressed as `.../FontSubstitutions/<locale>['en']/<LFonts>['simsun']` and
  only its `SubstFonts` property is replaced (the vendor `SubstFontsMS`,
  `FontWeight`, `FontWidth` and `FontType` are retained); an alias the pinned
  table has no record for is added as a `oor:op="fuse"` node under the
  existing locale member, which the pinned `XcuParser::handleSetNode` creates
  or merges without touching the sibling locales or alias records.
* Every alias key is stored in the exact normalized form the pinned engine
  looks up: `fontdefs.cxx GetEnglishSearchFontName` lowercases ASCII, strips
  whitespace and all special characters except `;` `(` `)`, folds fullwidth
  ASCII, then translates localized names (`宋体`->`simsun`, `方正仿宋`->
  `fzfangsong`, `微软雅黑`->`microsoftyahei`, ...). `fontcfg.cxx
  getSubstInfo` lowercases the query and prefix-matches the configured keys,
  so a mixed-case or space-bearing key would never match.
* Every substitution target must be a *font family* the process resolves
  (`Source Han Serif SC`, `LXGW WenKai`, `Sarasa Mono SC`, ...), never a
  PostScript filename such as `SourceHanSerifSC-Regular`; the two differ for
  every bundled family.

The module is deliberately dependency-free (no fontTools) so it can run in
the native-host workflow and in plain `python3` tests. It parses the real
sfnt `name` tables of the staged fonts instead of trusting file names.
"""
from __future__ import annotations

import struct
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OVERLAY = ROOT / "ThirdParty/Collabora/FloeOfficeFontSubstitutions.xcu"
BUNDLED_FONTS = ROOT / "FloeApp/Resources/Fonts/Bundled"
VCL_PACKAGE = "org.openoffice.VCL"
FONT_SUBSTITUTIONS_NODE = "FontSubstitutions"
LOCALIZED_FONT_SUBSTITUTIONS_TYPE = "org.openoffice.VCL:LocalizedFontSubstitutions"
LFONTS_TYPE = "org.openoffice.VCL:LFonts"
DEFAULT_FONTS_NODE = "DefaultFonts"
LOCALIZED_DEFAULT_FONTS_TYPE = "org.openoffice.VCL:LocalizedDefaultFonts"
SUBSTITUTIONS_NODE = FONT_SUBSTITUTIONS_NODE  # kept for callers by name

# The pinned `engine/unotools/source/config/fontcfg.cxx` `getSubstInfo` falls
# back to `en` for every UI language, and the pinned `share/registry/main.xcd`
# (host artifact for commit 27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc) carries
# only that locale's `FontSubstitutions` data. Every Floe alias therefore has
# to be registered under this locale to be read by the engine.
ENGINE_SUBSTITUTION_FALLBACK_LOCALE = "en"

# `LocalizedDefaultFonts` keys declared by the pinned VCL schema; they are
# properties of the locale member, not child nodes.
DEFAULT_FONT_KEYS = frozenset({
    "CJK_DISPLAY", "CJK_HEADING", "CJK_PRESENTATION", "CJK_SPREADSHEET",
    "CJK_TEXT", "CTL_DISPLAY", "CTL_HEADING", "CTL_PRESENTATION",
    "CTL_SPREADSHEET", "CTL_TEXT", "FIXED", "LATIN_DISPLAY", "LATIN_FIXED",
    "LATIN_HEADING", "LATIN_PRESENTATION", "LATIN_SPREADSHEET", "LATIN_TEXT",
    "SANS", "SANS_UNICODE", "SERIF", "SYMBOL", "UI_FIXED", "UI_SANS",
})

ALLOWED_SUBST_PROPS = ("SubstFonts", "SubstFontsMS", "FontWeight", "FontWidth", "FontType")
REQUIRED_SUBST_PROPS = ("SubstFonts",)

BEGIN_MARK = "FLOE_OFFICE_FONT_SUBSTITUTIONS_BEGIN"
END_MARK = "FLOE_OFFICE_FONT_SUBSTITUTIONS_END"

OOR = "{http://openoffice.org/2001/registry}"

# Registry files use unprefixed element names (`item`, `prop`, `node`, `value`)
# with `oor:` attributes; some producers qualify the elements instead. Match on
# local names so both spellings validate identically.
def _local(tag) -> str:
    return tag.rsplit("}", 1)[-1]

# The pinned engine configures resources for these languages.
CONFIGURED_ENGINE_LANGUAGES = ("en-US", "zh-CN", "zh-TW")

# Localized family names the pinned `fontdefs.cxx` dictionary maps to their
# normalized English ASCII search name before substitution lookup. Only the
# entries relevant to the aliases Floe configures are mirrored here.
LOCALIZED_NAME_DICTIONARY = {
    "宋体": "simsun",
    "新宋体": "nsimsun",
    "黑体": "simhei",
    "楷体": "simkai",
    "中易宋体": "zycjksun",
    "中易黑体": "zycjkhei",
    "中易楷体": "zycjkkai",
    "方正黑体": "fzhei",
    "方正楷体": "fzkai",
    "方正书宋": "fzshusong",
    "方正仿宋": "fzfangsong",
    "方正宋一": "fzsong",
    "方正宋体": "fzsongti",
    "微软雅黑": "microsoftyahei",
    "微软正黑体": "microsoftjhenghei",
    "细明体": "mingliu",
    "新细明体": "pmingliu",
}

# Font families that ship inside the pinned LibreOffice bundle
# (`share/fonts/truetype`, e.g. Carlito/Caladea/Liberation). They are part of
# the pinned host artifact, not of FloeApp/Resources/Fonts/Bundled, so the
# local validator accepts them only when the engine resource directory is
# supplied; the app-embedding gate checks them against the real files.
KNOWN_ENGINE_BUNDLED_FAMILIES = {
    "carlito": "Carlito",
    "caladea": "Caladea",
    "liberationsans": "Liberation Sans",
    "liberationserif": "Liberation Serif",
    "liberationmono": "Liberation Mono",
}

# Every alias a common Office document can name must have a Floe substitution
# whose first resolvable target is a bundled family. This is the executable
# contract the release gates and the overlay test share.
REQUIRED_SUBSTITUTIONS = {
    "simsun": "sourcehanserifsc",
    "nsimsun": "sourcehanserifsc",
    "simhei": "sourcehansanssc",
    "simkai": "lxgwwenkai",
    "kaiti": "lxgwwenkai",
    "fangsong": "sourcehanserifsc",
    "fzfangsong": "sourcehanserifsc",
    "song": "sourcehanserifsc",
    "hei": "sourcehansanssc",
    "kai": "lxgwwenkai",
    "microsoftyahei": "sourcehansanssc",
    "yahei": "sourcehansanssc",
    "msyh": "sourcehansanssc",
    "dengxian": "sourcehansanssc",
    "microsoftjhenghei": "sourcehansanstc",
    "pmingliu": "sourcehanseriftc",
    "mingliu": "sourcehanseriftc",
    "pingfangsc": "sourcehansanssc",
    "pingfangtc": "sourcehansanstc",
    "stheiti": "sourcehansanssc",
    "stsong": "sourcehanserifsc",
    "songtisc": "sourcehanserifsc",
    "calibri": "carlito",
    "cambria": "caladea",
    "arial": "liberationsans",
    "timesnewroman": "liberationserif",
    "couriernew": "liberationmono",
    "consolas": "sarasamonosc",
}


def normalize_font_name(name: str) -> str:
    """Mirror the pinned `GetEnglishSearchFontName` ASCII normalization.

    Lowercases ASCII, strips whitespace/control/special characters (keeping
    digits, `;`, `(`, `)`), folds fullwidth ASCII to halfwidth and leaves
    non-ASCII characters in place for the localized-name translation.
    """
    out = []
    for char in name.rstrip("".join(chr(code) for code in range(0x20))):
        code = ord(char)
        if code > 127 and 0xFF00 <= code <= 0xFF5E:
            code -= 0xFF00 - 0x0020
            char = chr(code)
        if code > 127:
            out.append(char)
            continue
        if "A" <= char <= "Z":
            char = char.lower()
        if ("a" <= char <= "z") or ("0" <= char <= "9") or char in ";()":
            out.append(char)
    return "".join(out)


def english_search_name(name: str) -> str:
    """`GetEnglishSearchFontName`: normalization plus the localized dictionary."""
    normalized = normalize_font_name(name)
    return LOCALIZED_NAME_DICTIONARY.get(normalized, normalized)


def _utf16be(raw: bytes) -> str:
    return raw.decode("utf-16-be", "ignore")


def _sfnt_table(data: bytes, offset: int) -> dict:
    if data[offset:offset + 4] == b"ttcf":
        raise ValueError("ttcf handled by caller")
    num_tables = struct.unpack_from(">H", data, offset + 4)[0]
    tables = {}
    for index in range(num_tables):
        record = offset + 12 + index * 16
        tag, _checksum, table_offset, length = struct.unpack_from(">4sIII", data, record)
        tables[tag] = (table_offset, length)
    return tables


def _name_records(data: bytes, offset: int, length: int):
    if length < 6:
        return
    _format, count, string_offset = struct.unpack_from(">HHH", data, offset)
    for index in range(count):
        record = offset + 6 + index * 12
        if record + 12 > offset + length:
            return
        platform, encoding, language, name_id, text_length, text_offset = struct.unpack_from(
            ">HHHHHH", data, record)
        start = offset + string_offset + text_offset
        end = start + text_length
        if end > offset + length or text_length == 0:
            continue
        raw = data[start:end]
        if platform == 3:
            text = _utf16be(raw)
        else:
            text = raw.decode("mac-roman", "ignore")
        yield name_id, platform, language, text


def font_name_facts(path: Path) -> dict:
    """Family and PostScript names parsed from one font file's name table.

    Returns `families` (nameIDs 1 and 16) and `postscript` (nameID 6). The
    distinction matters: the engine resolves the family name, and a
    substitution target that only looks like a PostScript filename resolves
    to nothing.
    """
    data = Path(path).read_bytes()
    if data[:4] == b"ttcf":
        count = struct.unpack_from(">I", data, 8)[0]
        offsets = [struct.unpack_from(">I", data, 12 + index * 4)[0] for index in range(count)]
    else:
        offsets = [0]
    families, postscript = set(), set()
    for offset in offsets:
        tables = _sfnt_table(data, offset)
        if b"name" not in tables:
            continue
        name_offset, name_length = tables[b"name"]
        for name_id, platform, _language, text in _name_records(data, name_offset, name_length):
            text = text.strip()
            if not text:
                continue
            if name_id in (1, 16):
                families.add(text)
            elif name_id == 6:
                postscript.add(text)
    return {"families": families, "postscript": postscript}


_FONT_EXTENSIONS = (".ttf", ".otf", ".ttc", ".otc")


def staged_font_facts(font_dirs) -> dict:
    """Normalized family -> facts for every font file under the given roots."""
    facts = {}
    for root in font_dirs:
        root = Path(root)
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.suffix.lower() not in _FONT_EXTENSIONS or not path.is_file():
                continue
            names = font_name_facts(path)
            for family in names["families"]:
                normalized = normalize_font_name(family)
                if not normalized:
                    continue
                entry = facts.setdefault(normalized, {
                    "family": family, "files": [], "postscript": set()
                })
                entry["files"].append(str(path))
                entry["postscript"].update(names["postscript"])
    return facts


def load_overlay(path=OVERLAY):
    """Parse the overlay and return its items with attribute facts."""
    root = ET.parse(Path(path)).getroot()
    if _local(root.tag) != "items":
        raise ValueError("font substitution overlay must be an oor:items document")
    items = []
    for item in [element for element in root if _local(element.tag) == "item"]:
        item_path = item.get(OOR + "path") or ""
        props = []
        for prop in [element for element in item if _local(element.tag) == "prop"]:
            value = next((element for element in prop if _local(element.tag) == "value"), None)
            props.append({
                "name": prop.get(OOR + "name") or "",
                "op": prop.get(OOR + "op") or "",
                "value": (value.text or "") if value is not None else "",
            })
        nodes = []
        for node in [element for element in item if _local(element.tag) == "node"]:
            node_props = []
            for prop in [element for element in node if _local(element.tag) == "prop"]:
                value = next((element for element in prop if _local(element.tag) == "value"), None)
                node_props.append({
                    "name": prop.get(OOR + "name") or "",
                    "op": prop.get(OOR + "op") or "",
                    "value": (value.text or "") if value is not None else "",
                })
            nodes.append({"name": node.get(OOR + "name") or "",
                          "op": node.get(OOR + "op") or "",
                          "props": node_props})
        items.append({"path": item_path, "props": props, "nodes": nodes})
    return items


def _member_key(segment: str, template: str):
    """The key of a `Type['key']` set-member path segment, or None.

    Mirrors the pinned `configmgr/source/data.cxx` `Data::parseSegment` /
    `createSegment` grammar, where the template name may be fully qualified
    (`org.openoffice.VCL:LFonts`) or short (`LFonts`).
    """
    short = template.rsplit(":", 1)[-1]
    for name in (template, short):
        prefix = f"{name}['"
        if segment.startswith(prefix) and segment.endswith("']"):
            return segment[len(prefix):-2]
    return None


def parse_vcl_font_path(item_path: str) -> dict:
    """Classify one registry item path against the pinned VCL font schema.

    The pinned `engine/officecfg/registry/schema/org/openoffice/VCL.xcs`
    (commit 27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc) declares
    `FontSubstitutions` as a set of `LocalizedFontSubstitutions`, that
    template as a set of `LFonts`, and `DefaultFonts` as a set of
    `LocalizedDefaultFonts`. `fontcfg.cxx readLocaleSubst` reads a locale
    member first and then its alias records, so an alias is addressed
    canonically at
    `/org.openoffice.VCL/FontSubstitutions/<locale set member>/LFonts['alias']`.

    Returns `{"kind", "locale", "alias", "error"}`; `kind` is None when the
    path is not a valid VCL font path and `error` explains why.
    """
    result = {"kind": None, "locale": None, "alias": None, "error": None}
    if not item_path or not item_path.startswith("/"):
        result["error"] = "path must start with '/'"
        return result
    segments = item_path[1:].split("/")
    if len(segments) < 2 or segments[0] != VCL_PACKAGE:
        result["error"] = f"path must start with /{VCL_PACKAGE}/"
        return result
    root = segments[1]
    if root not in (FONT_SUBSTITUTIONS_NODE, DEFAULT_FONTS_NODE):
        result["error"] = (
            f"{item_path}: the VCL font root is {FONT_SUBSTITUTIONS_NODE} or "
            f"{DEFAULT_FONTS_NODE}, not {root!r}; node children at the set root "
            f"become locales, not fonts")
        return result
    if len(segments) < 3:
        result["error"] = (
            f"{item_path}: missing locale member (the set's children are "
            f"locales); use .../{root}/"
            f"{LOCALIZED_FONT_SUBSTITUTIONS_TYPE if root == FONT_SUBSTITUTIONS_NODE else LOCALIZED_DEFAULT_FONTS_TYPE}"
            f"['{ENGINE_SUBSTITUTION_FALLBACK_LOCALE}']")
        return result
    expected_type = (LOCALIZED_FONT_SUBSTITUTIONS_TYPE if root == FONT_SUBSTITUTIONS_NODE
                     else LOCALIZED_DEFAULT_FONTS_TYPE)
    locale = _member_key(segments[2], expected_type)
    if locale is None:
        result["error"] = (
            f"{item_path}: expected a locale member {expected_type}['<locale>'], "
            f"got {segments[2]!r}")
        return result
    if not locale:
        result["error"] = f"{item_path}: empty locale key"
        return result
    if root == DEFAULT_FONTS_NODE:
        if len(segments) != 3:
            result["error"] = (
                f"{item_path}: DefaultFonts keys are properties of the locale "
                f"member; there is no per-key node level")
            return result
        result.update(kind=root, locale=locale)
        return result
    if len(segments) == 3:
        result.update(kind=root, locale=locale)
        return result
    if len(segments) == 4:
        alias = _member_key(segments[3], LFONTS_TYPE)
        if alias is None:
            result["error"] = (
                f"{item_path}: expected an alias member {LFONTS_TYPE}['<alias>'] "
                f"under the locale, got {segments[3]!r}")
            return result
        if not alias:
            result["error"] = f"{item_path}: empty alias key"
            return result
        result.update(kind=root, locale=locale, alias=alias)
        return result
    result["error"] = f"{item_path}: unexpected segments after the alias member"
    return result


def vcl_font_facts(main_xcd_path) -> dict:
    """The pinned compiled registry's VCL font schema and data.

    Parses the `component-schema`/`component-data` pair for
    `org.openoffice.VCL` in the shipped `share/registry/main.xcd`, so callers
    verify paths and merge behaviour against the real reader schema instead of
    a self-consistent invented hierarchy.
    """
    root = ET.parse(Path(main_xcd_path)).getroot()
    if _local(root.tag) != "data":
        raise ValueError(f"{main_xcd_path}: not a compiled registry root")
    schema = data = None
    for child in root:
        if (child.get(OOR + "package") != "org.openoffice"
                or child.get(OOR + "name") != "VCL"):
            continue
        if _local(child.tag) == "component-schema":
            schema = child
        elif _local(child.tag) == "component-data":
            data = child
    if schema is None or data is None:
        raise ValueError(f"{main_xcd_path}: no org.openoffice.VCL schema/data pair")
    templates, component = None, None
    for part in schema:
        if _local(part.tag) == "templates":
            templates = part
        elif _local(part.tag) == "component":
            component = part
    if templates is None or component is None:
        raise ValueError(f"{main_xcd_path}: incomplete VCL component schema")
    component_sets = {}
    for element in component:
        if _local(element.tag) == "set":
            component_sets[element.get(OOR + "name")] = element.get(OOR + "node-type")
    template_facts = {}
    for element in templates:
        name = element.get(OOR + "name") or ""
        template_facts[name.rsplit(":", 1)[-1]] = {
            "kind": _local(element.tag),
            "nodeType": (element.get(OOR + "node-type") or "").rsplit(":", 1)[-1],
            "extensible": element.get(OOR + "extensible") == "true",
            "props": [prop.get(OOR + "name") for prop in element
                      if _local(prop.tag) == "prop"],
        }
    substitutions = {}
    for top in data:
        if _local(top.tag) != "node" or top.get(OOR + "name") != FONT_SUBSTITUTIONS_NODE:
            continue
        for locale in top:
            if _local(locale.tag) != "node":
                continue
            aliases = {}
            for alias in locale:
                if _local(alias.tag) != "node":
                    continue
                props = {}
                for prop in alias:
                    if _local(prop.tag) != "prop":
                        continue
                    value = next((element for element in prop
                                  if _local(element.tag) == "value"), None)
                    props[prop.get(OOR + "name")] = (value.text or "") if value is not None else ""
                aliases[alias.get(OOR + "name")] = props
            substitutions[locale.get(OOR + "name")] = aliases
    return {
        "fontSubstitutionsNodeType": component_sets.get(FONT_SUBSTITUTIONS_NODE),
        "localizedFontSubstitutionsNodeType": template_facts.get(
            "LocalizedFontSubstitutions", {}).get("nodeType"),
        "lfontsProps": template_facts.get("LFonts", {}).get("props", []),
        "defaultFontsNodeType": component_sets.get(DEFAULT_FONTS_NODE),
        "localizedDefaultFontsExtensible": template_facts.get(
            "LocalizedDefaultFonts", {}).get("extensible", False),
        "locales": {locale: sorted(aliases) for locale, aliases in substitutions.items()},
        "substitutions": substitutions,
    }


def simulate_font_overlay(vendor_config, path=OVERLAY) -> dict:
    """Apply the overlay to the pinned table with the pinned reader semantics.

    Mirrors `XcuParser::handleSetNode` (`oor:op="fuse"` creates a missing set
    member or merges into an existing one, leaving siblings untouched) and
    `handleGroupProp` (a property modification replaces that property value).
    Returns the merged substitution map plus what the overlay added,
    overrode, and left untouched, so tests can prove unrelated aliases and
    locales are retained by the real merge semantics.
    """
    vendor = vcl_font_facts(vendor_config)
    merged = {locale: {alias: dict(props) for alias, props in aliases.items()}
              for locale, aliases in vendor["substitutions"].items()}
    added, overridden = set(), set()
    for item in load_overlay(path):
        parsed = parse_vcl_font_path(item["path"])
        if parsed["kind"] != FONT_SUBSTITUTIONS_NODE or parsed["error"]:
            continue
        aliases = merged.setdefault(parsed["locale"], {})
        if parsed["alias"] is not None:
            target = aliases.setdefault(parsed["alias"], {})
            overridden.add(parsed["alias"])
            for prop in item["props"]:
                target[prop["name"]] = prop["value"]
            continue
        for node in item["nodes"]:
            name = node["name"]
            if name in aliases:
                overridden.add(name)
            else:
                aliases[name] = {}
                added.add(name)
            for prop in node["props"]:
                aliases[name][prop["name"]] = prop["value"]
    vendor_aliases = {alias for aliases in vendor["substitutions"].values()
                      for alias in aliases}
    merged_aliases = {alias for aliases in merged.values() for alias in aliases}
    return {
        "merged": merged,
        "vendor": vendor,
        "added": sorted(added),
        "overridden": sorted(overridden),
        "retained": sorted(vendor_aliases - added - overridden),
        "vendorAliasCount": len(vendor_aliases),
        "mergedAliasCount": len(merged_aliases),
        "locales": sorted(merged),
    }


def validate_overlay(path=OVERLAY, font_dirs=None, allow_engine_bundled=True,
                     require_targets=True, vendor_config=None):
    """Validate every overlay item against the real VCL schema and fonts.

    `font_dirs` are scanned for actual family names. Font families that live
    in the pinned LibreOffice bundle (Carlito/Caladea/Liberation) are accepted
    from `KNOWN_ENGINE_BUNDLED_FAMILIES` when `allow_engine_bundled` is true;
    the app-embedding gate re-checks them against the shipped resource tree.

    `require_targets=False` performs the structural pass only (path hierarchy,
    alias normalization, schema property names, non-empty target lists). The
    native host packaging step uses it because the Floe staged fonts are added
    to the app later by `embed_office_host.py`; the app-embedding gate and the
    test suite resolve every target against the real font trees.

    `vendor_config` is the pinned `share/registry/main.xcd`. When supplied,
    every alias override has to address an alias that really exists in that
    table's locale set, and the schema node types have to match the paths this
    overlay produces. A new alias is only accepted as a `oor:op="fuse"` node
    under an existing locale member.
    """
    font_dirs = list(font_dirs) if font_dirs else [BUNDLED_FONTS]
    facts = staged_font_facts(font_dirs)
    known = set(facts)
    if allow_engine_bundled:
        known |= set(KNOWN_ENGINE_BUNDLED_FAMILIES)
    vendor = vcl_font_facts(vendor_config) if vendor_config else None
    failures = []
    aliases = {}
    alias_overrides, alias_additions, locales = [], [], set()
    for index, item in enumerate(load_overlay(path)):
        item_path = item["path"]
        parsed = parse_vcl_font_path(item_path)
        if parsed["kind"] is None:
            failures.append(f"item {index}: {parsed['error']}")
            continue
        kind, locale, alias = parsed["kind"], parsed["locale"], parsed["alias"]
        locales.add(locale)
        if kind == DEFAULT_FONTS_NODE:
            # DefaultFonts locale members carry key/value properties; the keys
            # are the localized default-font lists, not alias records.
            if item["nodes"]:
                failures.append(
                    f"{item_path}: DefaultFonts locale members carry properties, "
                    f"not child nodes")
            if not item["props"]:
                failures.append(f"{item_path}: DefaultFonts item has no properties")
            for prop in item["props"]:
                if prop["name"] not in DEFAULT_FONT_KEYS:
                    failures.append(
                        f"{item_path}: {prop['name']!r} is not a LocalizedDefaultFonts key")
                if prop["op"] and prop["op"] not in ("replace", "fuse"):
                    failures.append(f"{item_path}: unsupported oor:op {prop['op']}")
            continue
        if locale != ENGINE_SUBSTITUTION_FALLBACK_LOCALE:
            failures.append(
                f"{item_path}: locale {locale!r} is not the fallback locale "
                f"{ENGINE_SUBSTITUTION_FALLBACK_LOCALE!r} the pinned "
                f"fontcfg.cxx reads for every UI language")
        entries = []
        if alias is not None:
            if item["nodes"]:
                failures.append(
                    f"{item_path}: an alias item overrides properties; child "
                    f"nodes belong under the locale member")
            entries.append((alias, item["props"], item_path, "override"))
        else:
            if item["props"]:
                failures.append(
                    f"{item_path}: properties on the FontSubstitutions locale "
                    f"set are ignored by the pinned reader; put them on the "
                    f"alias member {LFONTS_TYPE}['<alias>']")
            for node in item["nodes"]:
                where = f"{item_path}/{LFONTS_TYPE}['{node['name']}']"
                if node["op"] != "fuse":
                    failures.append(
                        f"{where}: alias nodes must use oor:op='fuse' so an "
                        f"existing alias or sibling locale is retained")
                entries.append((node["name"], node["props"], where, "addition"))
        if not entries:
            failures.append(f"{item_path}: no alias properties and no alias nodes")
            continue
        for name, props, where, mode in entries:
            if mode == "addition":
                alias_additions.append(name)
            else:
                alias_overrides.append(name)
            normalized = normalize_font_name(name)
            if not name or normalized != name:
                failures.append(f"{where}: alias must be stored normalized ({normalized!r})")
                continue
            prop_names = {prop["name"] for prop in props}
            for prop in props:
                if prop["name"] not in ALLOWED_SUBST_PROPS:
                    failures.append(f"{where}: unsupported property {prop['name']}")
                if prop["op"] and prop["op"] not in ("replace", "fuse"):
                    failures.append(f"{where}: unsupported oor:op {prop['op']}")
            missing = [flag for flag in REQUIRED_SUBST_PROPS if flag not in prop_names]
            if missing:
                failures.append(f"{where}: entry is missing {', '.join(missing)}")
            subst = next((prop["value"] for prop in props if prop["name"] == "SubstFonts"), "")
            targets = [target.strip() for target in subst.split(";") if target.strip()]
            if not targets:
                failures.append(f"{where}: SubstFonts is empty")
                continue
            resolved = []
            for target in targets:
                normalized_target = normalize_font_name(target)
                if normalized_target in known:
                    resolved.append(normalized_target)
                elif not require_targets:
                    resolved.append(normalized_target)
                else:
                    postscript = [
                        ps for entry in facts.values() for ps in entry["postscript"]
                        if normalize_font_name(ps) == normalized_target
                    ]
                    hint = " (matches a PostScript name, not a family)" if postscript else ""
                    failures.append(f"{where}: target family {target!r} is not installed{hint}")
            if resolved:
                aliases.setdefault(name, resolved)
    if vendor is not None:
        if (vendor["fontSubstitutionsNodeType"] or "").rsplit(":", 1)[-1] != "LocalizedFontSubstitutions" \
                or (vendor["localizedFontSubstitutionsNodeType"] or "").rsplit(":", 1)[-1] != "LFonts":
            failures.append(
                "pinned main.xcd does not declare FontSubstitutions as a set of "
                "LocalizedFontSubstitutions / LFonts; the overlay paths are not "
                "valid for this artifact")
        vendor_locales = vendor["locales"]
        if ENGINE_SUBSTITUTION_FALLBACK_LOCALE not in vendor_locales:
            failures.append(
                f"pinned main.xcd has no {ENGINE_SUBSTITUTION_FALLBACK_LOCALE!r} "
                f"FontSubstitutions locale member")
        for name in alias_overrides:
            if not any(name in vendor_locales.get(locale, []) for locale in vendor_locales):
                failures.append(
                    f"alias override {name!r} does not exist under any pinned "
                    f"locale; create it with a '{LFONTS_TYPE}' node using "
                    f"oor:op='fuse' under an existing locale")
        for name in alias_additions:
            if any(name in vendor_locales.get(locale, []) for locale in vendor_locales):
                failures.append(
                    f"alias addition {name!r} already exists in the pinned table; "
                    f"override its '{LFONTS_TYPE}' member instead")
    return {
        "aliases": aliases,
        "aliasCount": len(aliases),
        "fontFamilies": {normalized: entry["family"] for normalized, entry in facts.items()},
        "failures": failures,
        "locales": sorted(locales),
        "aliasOverrides": sorted(set(alias_overrides)),
        "aliasAdditions": sorted(set(alias_additions)),
        "vendor": None if vendor is None else {
            "locales": sorted(vendor["locales"]),
            "aliasCount": sum(len(items) for items in vendor["locales"].values()),
        },
    }


def overlay_body(path=OVERLAY) -> str:
    """The inner XML of the overlay document (items only, no root/declaration)."""
    text = Path(path).read_text(encoding="utf-8")
    start = text.index(">", text.index("<oor:items")) + 1
    end = text.rindex("</oor:items>")
    return text[start:end].strip("\n")


def merge_font_config(original: bytes, path=OVERLAY):
    """Append (or refresh) the Floe substitution block in a coolkitconfig.xcu.

    Idempotent: an existing marked block is replaced, never duplicated, and
    every pre-existing item in the vendor file is preserved byte-for-byte.
    """
    text = original.decode("utf-8")
    body = overlay_body(path)
    block = (f"<!-- {BEGIN_MARK} (generated from {Path(path).name}; "
             f"do not edit the merged copy in place) -->\n{body}\n<!-- {END_MARK} -->")
    if BEGIN_MARK in text and END_MARK in text:
        start = text.index(f"<!-- {BEGIN_MARK}")
        end = text.index(f"<!-- {END_MARK}") + len(f"<!-- {END_MARK} -->")
        merged = text[:start] + block + text[end:]
    else:
        closing = text.rindex("</oor:items>")
        merged = text[:closing].rstrip() + "\n\n" + block + "\n" + text[closing:]
    return merged.encode("utf-8"), {
        "fontSubstitutionAliases": len(overlay_aliases(path)),
        "fontSubstitutionItems": len(load_overlay(path)),
        "markerStart": BEGIN_MARK,
    }


def configured_substitutions(coolkit_path) -> dict:
    """Read the merged config's locale-aware alias -> target family mapping.

    Only item paths that match the pinned VCL hierarchy are read: an alias
    override addresses `.../FontSubstitutions/<locale>/LFonts['alias']`, and a
    fused alias addition is a `node` child of the locale member.
    """
    text = Path(coolkit_path).read_text(encoding="utf-8")
    root = ET.fromstring(text)
    found = {}
    for item in [element for element in root if _local(element.tag) == "item"]:
        parsed = parse_vcl_font_path(item.get(OOR + "path") or "")
        if parsed["kind"] != FONT_SUBSTITUTIONS_NODE or parsed["error"]:
            continue
        entries = []
        if parsed["alias"] is not None:
            entries.append((parsed["alias"], [element for element in item
                                              if _local(element.tag) == "prop"]))
        for node in [element for element in item if _local(element.tag) == "node"]:
            entries.append((node.get(OOR + "name") or "",
                            [element for element in node if _local(element.tag) == "prop"]))
        for name, props in entries:
            for prop in props:
                if prop.get(OOR + "name") != "SubstFonts":
                    continue
                value = next((element for element in prop if _local(element.tag) == "value"), None)
                targets = [target.strip() for target in (value.text or "").split(";") if target.strip()]
                if targets:
                    found.setdefault(normalize_font_name(name), []).extend(targets)
    return found


def overlay_aliases(path=OVERLAY) -> set:
    """The normalized FontSubstitutions alias keys the overlay defines."""
    aliases = set()
    for item in load_overlay(path):
        parsed = parse_vcl_font_path(item["path"])
        if parsed["kind"] != FONT_SUBSTITUTIONS_NODE or parsed["error"]:
            continue
        if parsed["alias"]:
            aliases.add(normalize_font_name(parsed["alias"]))
        for node in item["nodes"]:
            aliases.add(normalize_font_name(node["name"]))
    return aliases


def validate_merged_config(coolkit_path, font_dirs=None, path=OVERLAY,
                           require_targets=True, allow_engine_bundled=True,
                           vendor_config=None):
    """Verify a merged coolkitconfig.xcu resolves every Floe alias.

    Only Floe-owned aliases are checked; the vendor table contains many
    substitutions for fonts no iOS host installs, which is exactly the gap
    this overlay repairs and must not be misread as a Floe failure.

    `vendor_config` (the app's pinned `share/registry/main.xcd`) additionally
    re-validates the overlay's item-path hierarchy and alias existence against
    the real table, so a locale-less path can never pass as repaired.
    """
    font_dirs = list(font_dirs) if font_dirs else [BUNDLED_FONTS]
    facts = staged_font_facts(font_dirs)
    known = set(facts)
    if allow_engine_bundled:
        known |= set(KNOWN_ENGINE_BUNDLED_FAMILIES)
    failures = []
    if vendor_config is not None:
        overlay_report = validate_overlay(path, font_dirs=font_dirs,
                                          allow_engine_bundled=allow_engine_bundled,
                                          require_targets=False,
                                          vendor_config=vendor_config)
        failures.extend(overlay_report["failures"])
    expected = overlay_aliases(path)
    if not expected:
        failures.append(
            "overlay declares no FontSubstitutions aliases; its item paths do "
            "not match the pinned VCL locale hierarchy")
        return {
            "expectedAliases": 0,
            "resolvedAliases": {},
            "resolvedCount": 0,
            "failures": failures,
        }
    configured = configured_substitutions(coolkit_path)
    resolved = {}
    for alias in sorted(expected):
        targets = configured.get(alias)
        if not targets:
            failures.append(f"merged config is missing the Floe alias {alias}")
            continue
        first = normalize_font_name(targets[0])
        if first in known:
            resolved[alias] = first
        elif require_targets:
            failures.append(
                f"merged config alias {alias} resolves first to {targets[0]!r}, "
                f"which is not an installed family")
    return {
        "expectedAliases": len(expected),
        "resolvedAliases": resolved,
        "resolvedCount": len(resolved),
        "failures": failures,
    }


def language_resource_report(resources_root) -> dict:
    """Which configured-language UI resources exist in a host/app resource tree.

    Reports reality: the pinned upstream engine artifact only emits en-US
    registry/langpack files, so zh-CN/zh-TW appear as a recorded gap rather
    than as fabricated files. A file that *is* present in the source must be
    present in the app; that packaging check lives in
    `verify_office_app_embedding.py`.
    """
    resources_root = Path(resources_root)
    registry = resources_root / "share/registry"
    found = {}
    for path in sorted(registry.glob("**/*.xcd")) if registry.is_dir() else []:
        name = path.name
        language = None
        if name.startswith("Langpack-") and name.endswith(".xcd"):
            language = name[len("Langpack-"):-len(".xcd")]
        elif name.startswith("fcfg_langpack_") and name.endswith(".xcd"):
            language = name[len("fcfg_langpack_"):-len(".xcd")]
        elif name.startswith("registry_") and name.endswith(".xcd"):
            language = name[len("registry_"):-len(".xcd")]
        if language:
            found.setdefault(language, []).append(str(path.relative_to(resources_root)))
    return {
        "configuredLanguages": list(CONFIGURED_ENGINE_LANGUAGES),
        "availableLanguages": sorted(found),
        "files": {language: sorted(paths) for language, paths in sorted(found.items())},
        "missingLanguages": [language for language in CONFIGURED_ENGINE_LANGUAGES
                             if language not in found],
    }


def language_packaging_failures(host_report, app_report) -> list:
    """A file present in the host output must be present in the app bundle.

    The reverse is not required: the app may carry nothing extra here. This
    catches a packaging copy regression without inventing zh outputs the
    upstream engine did not emit.
    """
    if not isinstance(host_report, dict) or not isinstance(app_report, dict):
        raise ValueError("language reports must be dictionaries")
    failures = []
    app_files = {path for paths in app_report.get("files", {}).values() for path in paths}
    for language, paths in host_report.get("files", {}).items():
        for path in paths:
            if path not in app_files:
                failures.append(f"host language resource {path} ({language}) is missing from the app")
    return failures


if __name__ == "__main__":
    import json

    report = validate_overlay()
    print(json.dumps({key: value for key, value in report.items()
                      if key != "fontFamilies"}, indent=2, ensure_ascii=False))
    raise SystemExit(1 if report["failures"] else 0)
