import io
from pathlib import Path
import tempfile
import unittest
import zipfile

from verify_pptx_chart_data import inspect


def archive(parts):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as package:
        for name, content in parts.items():
            package.writestr(name, content)
    return stream.getvalue()


class ChartDataTests(unittest.TestCase):
    def fixture(self, *, value=12, formula='Sheet1!$B$2', missing=False):
        workbook = archive({
            'xl/workbook.xml': '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" r:id="s1"/></sheets></workbook>',
            'xl/_rels/workbook.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="s1" Target="worksheets/sheet1.xml"/></Relationships>',
            'xl/worksheets/sheet1.xml': f'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="2"><c r="B2"><v>{value}</v></c></row></sheetData></worksheet>'})
        parts = {
            'ppt/charts/chart1.xml': f'<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart><c:numRef><c:f>{formula}</c:f><c:numCache><c:ptCount val="1"/><c:pt idx="0"><c:v>12</c:v></c:pt></c:numCache></c:numRef></c:chart><c:externalData r:id="data"/></c:chartSpace>',
            'ppt/charts/_rels/chart1.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="data" Target="../embeddings/data.xlsx" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/package"/></Relationships>'}
        if not missing:
            parts['ppt/embeddings/data.xlsx'] = workbook
        return archive(parts)

    def check(self, **options):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.pptx'
            path.write_bytes(self.fixture(**options))
            return inspect(path)

    def test_real_workbook_matches_cache(self):
        self.assertTrue(self.check()['allNamedChecksPassed'])

    def test_stale_workbook_rejected_even_when_chart_cache_is_correct(self):
        result = self.check(value=99)
        self.assertFalse(result['allNamedChecksPassed'])
        self.assertEqual(result['checks'][-1]['workbookValues'], [99])
        self.assertEqual(result['checks'][-1]['cacheValues'], [12])

    def test_relationship_without_payload_is_not_preservation(self):
        self.assertFalse(self.check(missing=True)['allNamedChecksPassed'])

    def test_internal_model_labels_and_missing_sheet_are_not_cell_references(self):
        for formula in ('0', 'label 0', 'categories', 'Missing!$B$2', 'Sheet1!$XFE$2'):
            with self.subTest(formula=formula):
                self.assertFalse(self.check(formula=formula)['allNamedChecksPassed'])


if __name__ == '__main__':
    unittest.main()
