import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_pdfium_linkage import verify


class PDFiumLinkageTests(unittest.TestCase):
    imports = '''
      0x0419  _FPDF_CloseDocument  (from CPDFium)
      0x0421  _FPDF_LoadMemDocument64  (from CPDFium)
      0x077A  _FPDF_NewXObjectFromPage  (from CPDFium)
      0x077B  _FPDFText_LoadPage  (from CPDFium)
    '''

    def test_single_engine(self):
        self.assertEqual(len(verify(self.imports)), 4)

    def test_rejects_build_172_device_split(self):
        mixed = self.imports.replace('_FPDF_LoadMemDocument64  (from CPDFium)',
                                    '_FPDF_LoadMemDocument64  (from FloeOfficeNative)')
        with self.assertRaisesRegex(ValueError, 'FloeOfficeNative'):
            verify(mixed)

    def test_checks_text_api_too(self):
        with self.assertRaises(ValueError):
            verify(self.imports.replace('_FPDFText_LoadPage  (from CPDFium)',
                                        '_FPDFText_LoadPage  (from FloeOfficeNative)'))

    def test_empty_or_changed_tool_output_is_not_success(self):
        with self.assertRaises(ValueError):
            verify('')


if __name__ == '__main__':
    unittest.main()
