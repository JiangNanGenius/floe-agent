#!/usr/bin/env python3
"""Mutation checks for the independent repeated-save layout comparator."""
import copy
import unittest
from xml.etree import ElementTree as ET

from verify_xlsx_repeated_layout import CLIENT, client_flag, compare, point_geometry


class RepeatedLayoutTests(unittest.TestCase):
    def snapshot(self):
        return {'Notes': {'defaultWidth': '8.5', 'baseWidth': '8',
                          'columns': [(1, 3, '22')],
                          'objects': [{'hmm': {'margin-left': 1699, 'margin-top': 2117,
                                               'width': 6000, 'height': 1800},
                                       'moveWithCells': False, 'sizeWithCells': False,
                                       'vmlImportedMoveWithCells': False,
                                       'vmlImportedSizeWithCells': False}]}}

    def test_equivalent_column_range_splitting_passes(self):
        before = self.snapshot()
        after = copy.deepcopy(before)
        after['Notes']['columns'] = [(1, 1, '22'), (2, 3, '22')]
        self.assertTrue(all(c['passed'] for c in compare(before, after)))

    def test_width_geometry_movement_and_missing_sheet_fail_independently(self):
        before = self.snapshot()
        for change in ('column', 'default', 'geometry', 'movement', 'missing'):
            after = copy.deepcopy(before)
            if change == 'column':
                after['Notes']['columns'] = [(1, 3, '21.21')]
            elif change == 'default':
                after['Notes']['defaultWidth'] = '8.3'
            elif change == 'geometry':
                after['Notes']['objects'][0]['hmm']['height'] -= 1
            elif change == 'movement':
                after['Notes']['objects'][0]['vmlImportedMoveWithCells'] = True
            else:
                after.clear()
            with self.subTest(change=change):
                self.assertTrue(any(not c['passed'] for c in compare(before, after)))

    def test_point_conversion_preserves_native_unit_drift(self):
        first = point_geometry('margin-left:48.1606299212598pt;margin-top:60.0094488188976pt;width:170.07874015748pt;height:51.0236220472441pt')
        second = point_geometry('margin-left:46.459842519685pt;margin-top:60.0094488188976pt;width:164.834645669291pt;height:50.9952755905512pt')
        self.assertEqual(first, dict(zip(('margin-left', 'margin-top', 'width', 'height'), (1699, 2117, 6000, 1800))))
        self.assertEqual(second, dict(zip(('margin-left', 'margin-top', 'width', 'height'), (1639, 2117, 5815, 1799))))

    def test_pinned_excel_vml_absent_and_blank_conventions(self):
        absent = ET.Element(CLIENT + 'ClientData')
        blank = ET.fromstring('<x:ClientData xmlns:x="urn:schemas-microsoft-com:office:excel"><x:MoveWithCells/></x:ClientData>')
        self.assertTrue(client_flag(absent, 'MoveWithCells'))
        self.assertFalse(client_flag(blank, 'MoveWithCells'))


if __name__ == '__main__':
    unittest.main()
