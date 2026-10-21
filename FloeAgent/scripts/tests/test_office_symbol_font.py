"""Prepared source/fixture contracts; native rendering is a separate App gate."""
import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from xml.etree import ElementTree as ET
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('office_symbol_fixture', SCRIPTS / 'test_office_symbol_font.py')
symbol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(symbol)


class SymbolFixtureTests(unittest.TestCase):
    def test_original_symbol_and_ordinary_body_pua_are_distinct_and_unmodified(self):
        data = symbol.fixture_bytes()
        ns = {'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for name in archive.namelist():
                ET.fromstring(archive.read(name))
            slide = ET.fromstring(archive.read('ppt/slides/slide1.xml'))
        paragraphs = slide.findall('.//a:p', ns)
        self.assertEqual(len(paragraphs), 3)
        self.assertEqual(paragraphs[0].find('a:pPr/a:buFont', ns).attrib['typeface'], 'Symbol')
        self.assertEqual(paragraphs[0].find('a:pPr/a:buChar', ns).attrib['char'], '\uf0b7')
        self.assertEqual(paragraphs[1].find('a:pPr/a:buChar', ns).attrib['char'], '\u2022')
        self.assertIsNotNone(paragraphs[2].find('a:pPr/a:buNone', ns))
        self.assertEqual(paragraphs[2].find('a:r/a:t', ns).text, 'BODY PUA \uf0b7 KEEP')
        self.assertEqual(hashlib.sha256(data).digest(), hashlib.sha256(symbol.fixture_bytes()).digest())

    def test_patch_changes_only_the_existing_platform_guard(self):
        patch = (symbol.LOCK.parent / 'patches/ios-symbol-font-recoding.patch').read_text()
        self.assertEqual([line for line in patch.splitlines() if line.startswith('-') and not line.startswith('---')], ['-#ifdef MACOSX'])
        self.assertEqual([line for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++')], ['+#if defined(MACOSX) || defined(IOS)'])


if __name__ == '__main__':
    unittest.main()
