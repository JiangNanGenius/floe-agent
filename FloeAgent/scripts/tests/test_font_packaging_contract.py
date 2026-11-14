#!/usr/bin/env python3
"""Focused contract tests for single-copy bundled font packaging.

Run from the repository root:
    python3 FloeAgent/scripts/tests/test_font_packaging_contract.py

The tests import the real embed/verifier modules, build small temporary App
trees and assert the packaging invariant the release gate checks on a built
artifact. They do not parse real font binaries, register CoreText fonts or
claim Office rendering; those stay artifact/device evidence.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

TEST_ROOT = Path(__file__).resolve().parent
SCRIPTS = Path(os.environ.get('FLOE_SCRIPTS_DIR', TEST_ROOT.parent))
REGISTRAR = Path(os.environ.get(
    'FLOE_REGISTRAR_PATH',
    SCRIPTS.parent / 'FloeApp/Fonts/BundledFontRegistrar.swift'))
FONT_EXT = {'.ttf', '.otf', '.ttc', '.otc'}


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sys.path.insert(0, str(SCRIPTS))
dependency_scripts = os.environ.get('FLOE_DEPENDENCY_SCRIPTS')
if dependency_scripts:
    sys.path.append(dependency_scripts)
EMBED = load(SCRIPTS / 'embed_office_host.py', 'floe_embed_office_host_contract')
VERIFY = load(SCRIPTS / 'verify_font_single_copy.py', 'floe_verify_font_single_copy_contract')


def write_font(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def make_source(root: Path) -> Path:
    source = root / 'source'
    write_font(source / 'family-a' / 'A-Regular.ttf', b'font-a-regular' * 100)
    write_font(source / 'family-a' / 'A-Bold.ttf', b'font-a-bold' * 100)
    (source / 'family-a' / 'LICENSE.txt').write_text('FAMILY A LICENSE\n', encoding='utf-8')
    write_font(source / 'family-b' / 'B-Regular.otf', b'font-b-regular' * 100)
    (source / 'family-b' / 'LICENSE.txt').write_text('FAMILY B LICENSE\n', encoding='utf-8')
    return source


class FontPackagingContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix='floe-font-contract-')
        self.root = Path(self.temp.name)
        self.source = make_source(self.root)
        self.original_bundled = EMBED.BUNDLED_FONTS
        EMBED.BUNDLED_FONTS = self.source

    def tearDown(self) -> None:
        EMBED.BUNDLED_FONTS = self.original_bundled
        self.temp.cleanup()

    def make_app(self, *, copy_bundled_fonts: bool) -> Path:
        app = self.root / 'Floe Agent.app'
        for font in sorted(self.source.rglob('*')):
            if font.suffix.lower() not in FONT_EXT or not font.is_file():
                continue
            relative = font.relative_to(self.source)
            if copy_bundled_fonts:
                target = app / 'Bundled' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(font.read_bytes())
            license_path = font.parent / 'LICENSE.txt'
            if license_path.is_file():
                bundled_license = app / 'Bundled' / font.parent.name / 'LICENSE.txt'
                bundled_license.parent.mkdir(parents=True, exist_ok=True)
                bundled_license.write_bytes(license_path.read_bytes())
        engine = app / 'program/resource/common/fonts'
        engine.mkdir(parents=True, exist_ok=True)
        (engine / 'opens___.ttf').write_bytes(b'host-owned-font')
        return app

    def test_stage_prunes_the_bundled_copy_and_keeps_licenses(self) -> None:
        app = self.make_app(copy_bundled_fonts=True)
        staged = EMBED.embed_bundled_fonts(app)
        self.assertEqual(staged, 3)
        engine = sorted(p.name for p in (app / 'program/resource/common/fonts').iterdir()
                        if p.suffix.lower() in FONT_EXT)
        self.assertEqual(engine, ['A-Bold.ttf', 'A-Regular.ttf', 'B-Regular.otf', 'opens___.ttf'])
        bundled_fonts = [p for p in (app / 'Bundled').rglob('*') if p.suffix.lower() in FONT_EXT]
        self.assertEqual(bundled_fonts, [])
        self.assertTrue((app / 'Bundled/family-a/LICENSE.txt').is_file())
        self.assertTrue((app / 'Bundled/family-b/LICENSE.txt').is_file())
        self.assertEqual(EMBED.embed_bundled_fonts(app), 3)
        self.assertFalse([p for p in (app / 'Bundled').rglob('*') if p.suffix.lower() in FONT_EXT])

    def test_verifier_passes_only_after_dedup(self) -> None:
        app = self.make_app(copy_bundled_fonts=True)
        engine = app / 'program/resource/common/fonts'
        for font in sorted(self.source.rglob('*')):
            if font.suffix.lower() in FONT_EXT and font.is_file():
                (engine / font.name).write_bytes(font.read_bytes())
        before = VERIFY.audit(app, self.source, False)
        self.assertFalse(before['pass'])
        self.assertEqual(len(before['duplicates']), 3)
        EMBED.prune_bundled_font_copies(app)
        after = VERIFY.audit(app, self.source, False)
        self.assertTrue(after['pass'], after['problems'])
        self.assertEqual(after['bundledFontFiles'], 0)
        self.assertTrue(all(item['present'] and item['matchesSource'] for item in after['licenses']))

    def test_verifier_rejects_a_duplicate_in_another_app_resource(self) -> None:
        app = self.make_app(copy_bundled_fonts=False)
        EMBED.embed_bundled_fonts(app)
        extra = app / 'EngineeringViewers/MiSans-Regular.ttf'
        extra.parent.mkdir(parents=True, exist_ok=True)
        source_font = self.source / 'family-a/A-Regular.ttf'
        extra.write_bytes(source_font.read_bytes())
        self.assertTrue(VERIFY.audit(app, self.source, False)['pass'])
        strict = VERIFY.audit(app, self.source, True)
        self.assertFalse(strict['pass'])
        self.assertIn('EngineeringViewers/MiSans-Regular.ttf',
                      strict['outsideAuditedRoots'][VERIFY.sha256_file(source_font)])

    def test_simulator_without_office_host_still_stages_fonts(self) -> None:
        app = self.make_app(copy_bundled_fonts=True)
        with tempfile.TemporaryDirectory(prefix='floe-font-main-') as temp:
            build_dir = Path(temp)
            target_app = build_dir / 'Floe Agent.app'
            target_app.mkdir(parents=True)
            for relative in ('Bundled', 'program'):
                source = app / relative
                if source.is_dir():
                    for path in source.rglob('*'):
                        if not path.is_file():
                            continue
                        target = target_app / relative / path.relative_to(source)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(path.read_bytes())
            environment = {
                'PLATFORM_NAME': 'iphonesimulator',
                'TARGET_BUILD_DIR': str(build_dir),
                'WRAPPER_NAME': target_app.name,
                'FLOE_OFFICE_SIM_HOST_DIR': '',
            }
            previous = {key: os.environ.get(key) for key in environment}
            os.environ.update(environment)
            output = io.StringIO()
            try:
                with contextlib.redirect_stdout(output):
                    EMBED.main()
            finally:
                for key, value in previous.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
            captured = output.getvalue()
            facts = json.loads(captured[captured.index('{'):])
            self.assertFalse(facts['embeddedFramework'])
            self.assertTrue(facts['officeHostSkipped'])
            self.assertEqual(facts['bundledFonts'], 3)
            staged = [p for p in (target_app / 'program/resource/common/fonts').rglob('*')
                      if p.suffix.lower() in FONT_EXT]
            # Three staged families plus the fixture's host-owned font.
            self.assertEqual(len(staged), 4)
            self.assertFalse([p for p in (target_app / 'Bundled').rglob('*')
                              if p.suffix.lower() in FONT_EXT])


class RegistrarContract(unittest.TestCase):
    def test_registrar_uses_the_engine_directory_before_the_fallback(self) -> None:
        source = REGISTRAR.read_text(encoding='utf-8')
        self.assertIn('program/resource/common/fonts', source)
        self.assertIn('appRoot.appendingPathComponent("Bundled", isDirectory: true)', source)
        self.assertIn('existingFontRoots(in: Bundle.main.bundleURL)', source)
        self.assertIn('roots.flatMap(stagedFontURLs)', source)
        self.assertIn('CoreTextFontRegistration.register(url: url)', source)
        self.assertIn('outcome == .failed', source)

    def test_embed_script_enforces_the_single_copy_invariant(self) -> None:
        source = (SCRIPTS / 'embed_office_host.py').read_text(encoding='utf-8')
        self.assertIn("ENGINE_FONT_DIR = ('program', 'resource', 'common', 'fonts')", source)
        self.assertIn('def prune_bundled_font_copies', source)
        self.assertIn('duplicate App font copies remain after staging', source)
        self.assertIn('duplicate App font pruning refuses a symlinked font', source)
        self.assertIn("if not host_dir:", source)
        self.assertIn("'bundledFonts': embed_bundled_fonts(app)", source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
