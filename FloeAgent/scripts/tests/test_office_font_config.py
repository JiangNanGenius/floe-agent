#!/usr/bin/env python3
"""Focused checks for the Floe Office font-substitution configuration (R4).

These tests exercise real sfnt name tables of the staged licensed fonts, the
real overlay XML, and — when the pinned vendor artifact is present — the real
`share/registry/main.xcd` schema and data. They prove:

* every item path follows the pinned VCL registry hierarchy
  (`FontSubstitutions` set of `LocalizedFontSubstitutions` locale members, each
  a set of `LFonts` alias records) and the previous locale-less/root-set forms
  are rejected;
* alias keys are stored in the exact normalized form the pinned engine looks
  up (fontdefs.cxx GetEnglishSearchFontName / fontcfg.cxx getSubstInfo);
* every substitution target resolves to a real installed font *family*, not a
  PostScript filename (the two differ for every bundled family);
* every common Chinese/Latin alias a document can name has a Floe override
  whose first target is a bundled licensed family;
* the overlay's `oor:op="fuse"` node additions create missing aliases under
  the existing locale without replacing sibling aliases or locales, and
  property overrides keep the vendor's other `LFonts` properties;
* merging the overlay into a vendor `coolkitconfig.xcu` is idempotent and
  preserves every vendor item.
"""
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import office_font_config as config  # noqa: E402

VENDOR_COOLKITCONFIG = (
    config.ROOT
    / "Vendor/Office/35668651442/OfficeNativeHost/OfficeRuntimeResources/coolkitconfig.xcu"
)
# The pinned compiled registry; byte-identical (1563bff4…c066) in every
# downloaded host artifact and in the shipped Build 232 IPA.
VENDOR_MAIN_XCD = VENDOR_COOLKITCONFIG.parent / "share/registry/main.xcd"

EMPTY_ITEMS = b'<?xml version="1.0" encoding="UTF-8"?>\n<oor:items ' \
              b'xmlns:oor="http://openoffice.org/2001/registry"></oor:items>\n'

SUBS_PATH = ("/org.openoffice.VCL/FontSubstitutions/"
             "org.openoffice.VCL:LocalizedFontSubstitutions['en']")


def write_overlay(folder, body: str) -> Path:
    path = Path(folder) / "overlay.xcu"
    path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<oor:items xmlns:oor="http://openoffice.org/2001/registry" '
        'xmlns:xs="http://www.w3.org/2001/XMLSchema">\n'
        f"{body}\n</oor:items>\n", encoding="utf-8")
    return path


class FontNameNormalizationTests(unittest.TestCase):
    def test_ascii_normalization_matches_engine_reader(self):
        cases = {
            "Source Han Sans SC": "sourcehansanssc",
            "Source Han Serif SC": "sourcehanserifsc",
            "LXGW WenKai": "lxgwwenkai",
            "Sarasa Mono SC": "sarasamonosc",
            "Sarasa-Mono-SC-Regular": "sarasamonoscregular",
            "Times New Roman": "timesnewroman",
            "Courier New": "couriernew",
            "Calibri ": "calibri",
            "Microsoft YaHei": "microsoftyahei",
            "Alibaba PuHuiTi 3.0": "alibabapuhuiti30",
            "  Microsoft  YaHei  ": "microsoftyahei",
            "宋体": "宋体",
        }
        for name, expected in cases.items():
            self.assertEqual(config.normalize_font_name(name), expected, name)

    def test_localized_names_resolve_to_engine_ascii_keys(self):
        # Mirror of the pinned fontdefs.cxx dictionary entries that matter for
        # the aliases Floe configures. The engine normalizes the requested name
        # through this table before the substitution lookup, so a document
        # naming 宋体 queries `simsun` and never the CJK characters.
        cases = {
            "宋体": "simsun",
            "新宋体": "nsimsun",
            "黑体": "simhei",
            "楷体": "simkai",
            "微软雅黑": "microsoftyahei",
            "微软正黑体": "microsoftjhenghei",
            "方正仿宋": "fzfangsong",
            "方正楷体": "fzkai",
            "新细明体": "pmingliu",
        }
        for name, expected in cases.items():
            self.assertEqual(config.english_search_name(name), expected, name)

    def test_every_overlay_alias_is_stored_normalized(self):
        for item in config.load_overlay():
            parsed = config.parse_vcl_font_path(item["path"])
            if parsed["alias"]:
                self.assertEqual(config.normalize_font_name(parsed["alias"]), parsed["alias"],
                                 f"alias {parsed['alias']!r} is not normalized")
            for node in item["nodes"]:
                self.assertEqual(config.normalize_font_name(node["name"]), node["name"],
                                 f"new alias {node['name']!r} is not normalized")


class OverlayPathHierarchyTests(unittest.TestCase):
    def test_overlay_paths_follow_the_pinned_locale_and_alias_hierarchy(self):
        items = config.load_overlay()
        self.assertTrue(items)
        overrides, additions = [], []
        for item in items:
            parsed = config.parse_vcl_font_path(item["path"])
            self.assertIsNone(parsed["error"], parsed)
            self.assertEqual(parsed["kind"], "FontSubstitutions")
            self.assertEqual(parsed["locale"], config.ENGINE_SUBSTITUTION_FALLBACK_LOCALE,
                             item["path"])
            if parsed["alias"] is not None:
                overrides.append(parsed["alias"])
                self.assertFalse(item["nodes"], item["path"])
            else:
                additions.extend(node["name"] for node in item["nodes"])
                self.assertFalse(item["props"], item["path"])
        self.assertEqual(set(config.overlay_aliases()), set(overrides) | set(additions))
        report = config.validate_overlay(font_dirs=[config.BUNDLED_FONTS])
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["locales"], [config.ENGINE_SUBSTITUTION_FALLBACK_LOCALE])
        self.assertEqual(set(report["aliasOverrides"]), set(overrides))
        self.assertEqual(set(report["aliasAdditions"]), set(additions))
        self.assertTrue(overrides and additions)

    def test_previous_locale_less_path_forms_are_rejected(self):
        legacy_paths = {
            # The audited wrong form: a root-set member that would be a locale.
            "/org.openoffice.VCL/org.openoffice.VCL:FontSubstitutions['simsun']",
            # A set member that omits the locale entirely.
            "/org.openoffice.VCL/FontSubstitutions/org.openoffice.VCL:LFonts['simsun']",
            # The set root itself.
            "/org.openoffice.VCL/FontSubstitutions",
            # The wrong template at the locale position.
            "/org.openoffice.VCL/FontSubstitutions/org.openoffice.VCL:FontSubstitutions['en']",
        }
        for path in legacy_paths:
            parsed = config.parse_vcl_font_path(path)
            self.assertIsNone(parsed["kind"], path)
            self.assertTrue(parsed["error"], path)
        legacy = (
            '  <item oor:path="/org.openoffice.VCL/org.openoffice.VCL:FontSubstitutions[\'simsun\']">\n'
            '    <prop oor:name="SubstFonts" oor:op="replace" oor:type="xs:string">'
            "<value>Source Han Serif SC</value></prop>\n"
            "  </item>")
        with tempfile.TemporaryDirectory(prefix="floe-font-legacy-") as folder:
            path = write_overlay(folder, legacy)
            report = config.validate_overlay(path, font_dirs=[config.BUNDLED_FONTS])
            self.assertEqual(config.overlay_aliases(path), set())
        self.assertTrue(report["failures"])
        self.assertEqual(report["aliases"], {})

    def test_locale_set_children_and_ops_are_restricted(self):
        # Properties on the locale set are ignored by the pinned reader, and an
        # alias node must be additive (fuse); a replace node would wipe an
        # existing alias record.
        cases = {
            "prop on locale set": (
                f'  <item oor:path="{SUBS_PATH}">\n'
                '    <prop oor:name="SubstFonts" oor:op="replace" oor:type="xs:string">'
                "<value>Source Han Serif SC</value></prop>\n  </item>"),
            "replace alias node": (
                f'  <item oor:path="{SUBS_PATH}">\n'
                '    <node oor:name="newalias" oor:op="replace">\n'
                '      <prop oor:name="SubstFonts" oor:op="replace" oor:type="xs:string">'
                "<value>Source Han Serif SC</value></prop>\n    </node>\n  </item>"),
            "alias item with node child": (
                f'  <item oor:path="{SUBS_PATH}/org.openoffice.VCL:LFonts[\'simsun\']">\n'
                '    <node oor:name="extra" oor:op="fuse"/>\n  </item>'),
        }
        for label, body in cases.items():
            with self.subTest(label):
                with tempfile.TemporaryDirectory(prefix="floe-font-ops-") as folder:
                    path = write_overlay(folder, body)
                    report = config.validate_overlay(path, font_dirs=[config.BUNDLED_FONTS])
                self.assertTrue(report["failures"], f"{label}: expected a failure")

    def test_default_fonts_paths_follow_the_localized_schema(self):
        good = ("/org.openoffice.VCL/DefaultFonts/"
                "org.openoffice.VCL:LocalizedDefaultFonts['en']")
        parsed = config.parse_vcl_font_path(good)
        self.assertEqual((parsed["kind"], parsed["locale"], parsed["alias"], parsed["error"]),
                         ("DefaultFonts", "en", None, None))
        for bad in ("/org.openoffice.VCL/org.openoffice.VCL:DefaultFonts['en']",
                    "/org.openoffice.VCL/DefaultFonts",
                    "/org.openoffice.VCL/DefaultFonts/en/org.openoffice.VCL:LFonts['simsun']"):
            self.assertIsNone(config.parse_vcl_font_path(bad)["kind"], bad)
        body = (f'  <item oor:path="{good}">\n'
                '    <prop oor:name="CJK_TEXT" oor:op="fuse" oor:type="xs:string">'
                "<value>Source Han Serif SC</value></prop>\n  </item>")
        with tempfile.TemporaryDirectory(prefix="floe-font-defaults-") as folder:
            path = write_overlay(folder, body)
            report = config.validate_overlay(path, font_dirs=[config.BUNDLED_FONTS])
            self.assertEqual(report["failures"], [])
            unknown = write_overlay(folder, body.replace("CJK_TEXT", "NOT_A_KEY"))
            bad_report = config.validate_overlay(unknown, font_dirs=[config.BUNDLED_FONTS])
        self.assertTrue(bad_report["failures"])

    def test_real_vendor_default_fonts_item_uses_that_hierarchy(self):
        if not VENDOR_COOLKITCONFIG.is_file():
            self.skipTest("pinned vendor coolkitconfig.xcu is not downloaded")
        text = VENDOR_COOLKITCONFIG.read_text(encoding="utf-8")
        paths = re.findall(r'oor:path="([^"]*DefaultFonts[^"]*)"', text)
        self.assertTrue(paths, "vendor coolkitconfig.xcu has no DefaultFonts item")
        for item_path in paths:
            parsed = config.parse_vcl_font_path(item_path)
            self.assertEqual((parsed["kind"], parsed["locale"], parsed["error"]),
                             ("DefaultFonts", "en", None), item_path)


class PinnedVendorTableTests(unittest.TestCase):
    """Checks against the real pinned share/registry/main.xcd when present."""

    @classmethod
    def setUpClass(cls):
        if not VENDOR_MAIN_XCD.is_file():
            raise unittest.SkipTest("pinned vendor main.xcd is not downloaded in this checkout")

    def test_pinned_schema_declares_the_locale_hierarchy(self):
        facts = config.vcl_font_facts(VENDOR_MAIN_XCD)
        self.assertEqual(facts["fontSubstitutionsNodeType"], "LocalizedFontSubstitutions")
        self.assertEqual(facts["localizedFontSubstitutionsNodeType"], "LFonts")
        self.assertEqual(facts["defaultFontsNodeType"], "LocalizedDefaultFonts")
        self.assertTrue(facts["localizedDefaultFontsExtensible"])
        for prop in ("SubstFonts", "SubstFontsMS", "FontWeight", "FontWidth", "FontType"):
            self.assertIn(prop, facts["lfontsProps"])
        self.assertEqual(list(facts["locales"]), [config.ENGINE_SUBSTITUTION_FALLBACK_LOCALE])

    def test_overlay_validates_against_the_pinned_table(self):
        report = config.validate_overlay(font_dirs=[config.BUNDLED_FONTS],
                                         vendor_config=VENDOR_MAIN_XCD)
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["aliases"].keys() >= config.REQUIRED_SUBSTITUTIONS.keys(), True)
        self.assertTrue(report["aliasOverrides"] and report["aliasAdditions"])
        self.assertEqual(set(report["aliasOverrides"]) | set(report["aliasAdditions"]),
                         set(config.overlay_aliases()))
        locales = config.vcl_font_facts(VENDOR_MAIN_XCD)["locales"]
        for alias in report["aliasOverrides"]:
            self.assertIn(alias, locales[config.ENGINE_SUBSTITUTION_FALLBACK_LOCALE], alias)
        for alias in report["aliasAdditions"]:
            self.assertNotIn(alias, locales[config.ENGINE_SUBSTITUTION_FALLBACK_LOCALE], alias)

    def test_merge_semantics_retain_vendor_locales_and_unrelated_aliases(self):
        sim = config.simulate_font_overlay(VENDOR_MAIN_XCD)
        vendor = sim["vendor"]
        # The merge never introduces a locale or drops one.
        self.assertEqual(sim["locales"], sorted(vendor["locales"]))
        self.assertEqual(sim["vendorAliasCount"], 320)
        self.assertEqual(sim["mergedAliasCount"], sim["vendorAliasCount"] + len(sim["added"]))
        self.assertTrue(sim["added"] and sim["overridden"])
        substitutions = vendor["substitutions"]
        for alias in sim["retained"]:
            for locale, aliases in substitutions.items():
                if alias in aliases:
                    self.assertEqual(sim["merged"][locale][alias], aliases[alias], alias)
        # A property override touches only SubstFonts; vendor LFonts properties stay.
        for alias in sim["overridden"]:
            for locale, aliases in substitutions.items():
                if alias in aliases:
                    before = {k: v for k, v in aliases[alias].items() if k != "SubstFonts"}
                    after = {k: v for k, v in sim["merged"][locale][alias].items() if k != "SubstFonts"}
                    self.assertEqual(after, before, alias)
        self.assertEqual(sim["merged"]["en"]["simsun"]["SubstFonts"],
                         "Source Han Serif SC;Source Han Sans SC")
        for alias in sim["added"]:
            self.assertIn(alias, sim["merged"]["en"])
            self.assertTrue(sim["merged"]["en"][alias].get("SubstFonts"), alias)


class OverlayValidationTests(unittest.TestCase):
    def test_overlay_validates_against_real_staged_fonts(self):
        report = config.validate_overlay(font_dirs=[config.BUNDLED_FONTS])
        self.assertEqual(report["failures"], [])
        self.assertGreaterEqual(report["aliasCount"], len(config.REQUIRED_SUBSTITUTIONS))

    def test_required_aliases_resolve_to_expected_bundled_families(self):
        report = config.validate_overlay(font_dirs=[config.BUNDLED_FONTS])
        aliases = report["aliases"]
        for alias, expected in config.REQUIRED_SUBSTITUTIONS.items():
            self.assertIn(alias, aliases, f"missing substitution for {alias}")
            self.assertEqual(aliases[alias][0], expected,
                             f"{alias} must resolve to {expected}, got {aliases[alias]}")

    def test_targets_are_families_not_postscript_names(self):
        facts = config.staged_font_facts([config.BUNDLED_FONTS])
        families = {entry["family"] for entry in facts.values()}
        postscript = {ps for entry in facts.values() for ps in entry["postscript"]}
        self.assertIn("Source Han Serif SC", families)
        self.assertIn("SourceHanSerifSC-Regular", postscript)
        self.assertNotIn("SourceHanSerifSC-Regular", families)

        overlay_text = config.OVERLAY.read_text(encoding="utf-8")
        for name in postscript:
            normalized = config.normalize_font_name(name)
            self.assertNotIn(f">{name}<", overlay_text,
                             f"overlay must not target PostScript name {name}")
            if normalized != config.normalize_font_name("Sarasa-Mono-SC-Regular"):
                self.assertNotIn(normalized, {
                    target.strip() for item in config.load_overlay()
                    for prop in item["props"] if prop["name"] == "SubstFonts"
                    for target in prop["value"].split(";") if target.strip()
                })

    def test_every_target_is_a_real_family_or_engine_bundled_family(self):
        report = config.validate_overlay(font_dirs=[config.BUNDLED_FONTS])
        for item in config.load_overlay():
            for prop in item["props"] + [prop for node in item["nodes"] for prop in node["props"]]:
                if prop["name"] != "SubstFonts":
                    continue
                for target in (value.strip() for value in prop["value"].split(";")):
                    if not target:
                        continue
                    normalized = config.normalize_font_name(target)
                    self.assertIn(normalized,
                                  set(report["fontFamilies"]) | set(config.KNOWN_ENGINE_BUNDLED_FAMILIES),
                                  f"target {target!r} resolves to no installed family")

    def test_properties_and_operations_are_schema_backed(self):
        for item in config.load_overlay():
            for prop in item["props"] + [prop for node in item["nodes"] for prop in node["props"]]:
                self.assertIn(prop["name"], config.ALLOWED_SUBST_PROPS)
                self.assertIn(prop["op"], ("", "replace", "fuse"))
            for node in item["nodes"]:
                self.assertEqual(node["op"], "fuse",
                                 f"{node['name']} must be an additive fuse node")


class MergeTests(unittest.TestCase):
    def test_merge_is_idempotent_and_preserves_vendor_items(self):
        original = (VENDOR_COOLKITCONFIG.read_bytes() if VENDOR_COOLKITCONFIG.is_file()
                    else b'<?xml version="1.0" encoding="UTF-8"?>\n<oor:items '
                         b'xmlns:oor="http://openoffice.org/2001/registry">\n'
                         b'<item oor:path="/org.openoffice.Office.Common/Misc">'
                         b'<prop oor:name="UseLocking" oor:op="fuse"><value>false</value></prop>'
                         b'</item>\n</oor:items>\n')
        first, facts = config.merge_font_config(original)
        second, _ = config.merge_font_config(first)
        self.assertEqual(first, second, "merge must not duplicate the Floe block")
        self.assertEqual(first.decode("utf-8").count(config.BEGIN_MARK), 1)
        text = first.decode("utf-8")
        self.assertIn('<item oor:path="/org.openoffice.Office.Common/Misc">', text)
        self.assertIn("UseLocking", text)
        ET.fromstring(text)  # merged file stays well-formed XML
        self.assertGreater(facts["fontSubstitutionAliases"], 0)

    def test_merged_config_exposes_normalized_alias_targets(self):
        original = (VENDOR_COOLKITCONFIG.read_bytes() if VENDOR_COOLKITCONFIG.is_file()
                    else EMPTY_ITEMS)
        merged, _ = config.merge_font_config(original)
        with tempfile.TemporaryDirectory(prefix="floe-font-config-") as folder:
            path = Path(folder) / "coolkitconfig.xcu"
            path.write_bytes(merged)
            substitutions = config.configured_substitutions(path)
        self.assertEqual(substitutions["simsun"][0], "Source Han Serif SC")
        self.assertEqual(substitutions["microsoftyahei"][0], "Source Han Sans SC")
        self.assertEqual(substitutions["calibri"][0], "Carlito")
        for alias in config.REQUIRED_SUBSTITUTIONS:
            self.assertIn(alias, substitutions, f"merged config lost {alias}")

    def test_merged_config_gate_rejects_the_previous_locale_less_form(self):
        legacy = (
            '  <item oor:path="/org.openoffice.VCL/org.openoffice.VCL:FontSubstitutions[\'simsun\']">\n'
            '    <prop oor:name="SubstFonts" oor:op="replace" oor:type="xs:string">'
            "<value>Source Han Serif SC</value></prop>\n  </item>")
        with tempfile.TemporaryDirectory(prefix="floe-font-legacy-merge-") as folder:
            overlay = write_overlay(folder, legacy)
            merged, _ = config.merge_font_config(EMPTY_ITEMS, path=overlay)
            merged_path = Path(folder) / "coolkitconfig.xcu"
            merged_path.write_bytes(merged)
            self.assertEqual(config.configured_substitutions(merged_path), {})
            report = config.validate_merged_config(merged_path, font_dirs=[config.BUNDLED_FONTS],
                                                   path=overlay)
        self.assertTrue(report["failures"])
        self.assertEqual(report["expectedAliases"], 0)


class EmbedPayloadTests(unittest.TestCase):
    """The real embed-time path: merged config in, resolved facts out."""

    def make_app(self, folder, merged):
        app = Path(folder) / "Floe Agent.app"
        app.mkdir(parents=True)
        (app / "coolkitconfig.xcu").write_bytes(merged)
        return app

    def test_repaired_app_reports_resolved_aliases_and_old_host_is_reported(self):
        import embed_office_host

        with tempfile.TemporaryDirectory(prefix="floe-office-embed-") as folder:
            root = Path(folder)
            original = (VENDOR_COOLKITCONFIG.read_bytes() if VENDOR_COOLKITCONFIG.is_file()
                        else EMPTY_ITEMS)
            merged, _ = config.merge_font_config(original)
            app = self.make_app(root, merged)
            (app / "share/registry").mkdir(parents=True)
            (app / "share/registry/Langpack-en-US.xcd").write_bytes(b"<x/>")
            host_resources = root / "host-resources"
            (host_resources / "share/registry").mkdir(parents=True)
            (host_resources / "share/registry/Langpack-en-US.xcd").write_bytes(b"<x/>")
            facts = embed_office_host.verify_font_and_language_payload(
                app, host_resources, font_dirs=[config.BUNDLED_FONTS])
            self.assertTrue(facts["fontSubstitutionsPresent"])
            self.assertTrue(facts["fontSubstitutionsRepaired"])
            self.assertGreaterEqual(facts["fontSubstitutionAliases"],
                                    len(config.REQUIRED_SUBSTITUTIONS))
            self.assertEqual(facts["languageResourceGap"], ["zh-CN", "zh-TW"])

            # An artifact that predates the overlay is reported, never mistaken
            # for a repaired one, and the embed step does not fail on it.
            old_app = self.make_app(root / "old", original)
            (old_app / "share/registry").mkdir(parents=True)
            (old_app / "share/registry/Langpack-en-US.xcd").write_bytes(b"<x/>")
            old_facts = embed_office_host.verify_font_and_language_payload(
                old_app, host_resources, font_dirs=[config.BUNDLED_FONTS])
            self.assertFalse(old_facts["fontSubstitutionsPresent"])
            self.assertIn("re-pinned host is required", old_facts["fontSubstitutionNote"])

    def test_language_resource_copy_regression_fails_embed(self):
        import embed_office_host

        with tempfile.TemporaryDirectory(prefix="floe-office-embed-") as folder:
            root = Path(folder)
            host_resources = root / "host-resources"
            (host_resources / "share/registry").mkdir(parents=True)
            (host_resources / "share/registry/Langpack-en-US.xcd").write_bytes(b"<x/>")
            (host_resources / "share/registry/Langpack-zh-CN.xcd").write_bytes(b"<x/>")
            app = self.make_app(root, b'<oor:items xmlns:oor="http://openoffice.org/2001/registry"/>')
            (app / "share/registry").mkdir(parents=True)
            (app / "share/registry/Langpack-en-US.xcd").write_bytes(b"<x/>")
            with self.assertRaises(ValueError):
                embed_office_host.verify_font_and_language_payload(
                    app, host_resources, font_dirs=[config.BUNDLED_FONTS])


if __name__ == "__main__":
    unittest.main(verbosity=2)
