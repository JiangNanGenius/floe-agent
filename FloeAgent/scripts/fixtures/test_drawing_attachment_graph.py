#!/usr/bin/env python3
"""Mutation checks for XLSX display/attachment graph validation."""
import io
import unittest
import zipfile
from xml.etree import ElementTree as ET

from verify_drawing_attachment import spreadsheet_display_checks, SHEET, REL, DRAWING, VML


class SpreadsheetDisplayGraphTests(unittest.TestCase):
    def fixture(self):
        sheet = f'''<worksheet xmlns="{SHEET}" xmlns:r="{REL}" xmlns:xdr="{DRAWING}">
          <legacyDrawing r:id="vml"/><oleObjects><oleObject shapeId="1040">
          <objectPr r:id="preview"><anchor><from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff>
          <xdr:row>4</xdr:row><xdr:rowOff>0</xdr:rowOff></from>
          <to><xdr:col>3</xdr:col><xdr:colOff>500</xdr:colOff>
          <xdr:row>8</xdr:row><xdr:rowOff>500</xdr:rowOff></to></anchor></objectPr>
          </oleObject></oleObjects></worksheet>'''
        return {
            'xl/worksheets/sheet2.xml': sheet.encode(),
            'xl/worksheets/_rels/sheet2.xml.rels': f'''<Relationships>
              <Relationship Id="vml" Type="{REL}/vmlDrawing" Target="../drawings/vmlDrawing1.vml"/>
              <Relationship Id="preview" Type="{REL}/image" Target="../media/image1.png"/>
              </Relationships>'''.encode(),
            'xl/drawings/vmlDrawing1.vml': f'''<xml xmlns:v="{VML}" xmlns:r="{REL}">
              <v:shapetype id="_x0000_t75"/><v:shape id="_x0000_s1040" type="#_x0000_t75"><v:imagedata r:id="image"/></v:shape></xml>'''.encode(),
            'xl/drawings/_rels/vmlDrawing1.vml.rels': f'''<Relationships>
              <Relationship Id="image" Type="{REL}/image" Target="../media/image1.png"/>
              </Relationships>'''.encode(),
            'xl/media/image1.png': b'synthetic image bytes; this check does not validate rendering',
        }

    def inspect(self, files):
        output, checks = io.BytesIO(), []
        with zipfile.ZipFile(output, 'w') as package:
            for name, value in files.items():
                package.writestr(name, value)
        with zipfile.ZipFile(output) as package:
            name = 'xl/worksheets/sheet2.xml'
            obj = ET.fromstring(files[name]).find(f'.//{{{SHEET}}}oleObject')
            spreadsheet_display_checks(package, name, obj,
                lambda label, expected, actual: checks.append((label, expected == actual)), 'object', [1, 4])
        return checks

    def test_connected_graph_and_selected_cell_pass(self):
        self.assertTrue(all(passed for _, passed in self.inspect(self.fixture())))

    def test_missing_preview_and_unrelated_shape_fail(self):
        files = self.fixture()
        del files['xl/media/image1.png']
        self.assertFalse(all(passed for _, passed in self.inspect(files)))
        files = self.fixture()
        path = 'xl/drawings/vmlDrawing1.vml'
        files[path] = files[path].replace(b'_x0000_s1040', b'_x0000_s1041')
        self.assertIn(('object exactly one corresponding VML shape', False), self.inspect(files))

    def test_ooxml_escaped_legacy_identifiers_fail(self):
        path = 'xl/drawings/vmlDrawing1.vml'
        files = self.fixture()
        files[path] = files[path].replace(b'id="_x0000_s', b'id="_x005F_x0000_s')
        self.assertIn(('object exactly one corresponding VML shape', False), self.inspect(files))
        files = self.fixture()
        files[path] = files[path].replace(b'type="#_x0000_t', b'type="#_x005F_x0000_t')
        self.assertIn(('object exactly one corresponding VML shape type', False), self.inspect(files))

    def test_wrong_cell_and_external_image_fail(self):
        files = self.fixture()
        name = 'xl/worksheets/sheet2.xml'
        files[name] = files[name].replace(b'<xdr:row>4', b'<xdr:row>3')
        self.assertIn(('object selected starting cell and zero offsets', False), self.inspect(files))
        files = self.fixture()
        name = 'xl/drawings/_rels/vmlDrawing1.vml.rels'
        files[name] = files[name].replace(b'Id="image"', b'Id="image" TargetMode="External"')
        self.assertIn(('object nonempty VML preview image', False), self.inspect(files))


if __name__ == '__main__':
    unittest.main()
