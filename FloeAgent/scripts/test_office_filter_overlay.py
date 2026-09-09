#!/usr/bin/env python3
"""Fail closed on archive corruption or accidental changes to other engine code."""
import hashlib
from pathlib import Path
import tempfile
import unittest

from build_office_filter_overlay import archive_members, verify_replacement


def member(name, payload):
    raw_name = name.encode()
    data = raw_name + payload
    header = (('#1/' + str(len(raw_name))).ljust(16) + '0'.ljust(12)
              + '0'.ljust(6) + '0'.ljust(6) + '100644'.ljust(8)
              + str(len(data)).ljust(10) + '`\n').encode()
    return header + data + (b'\n' if len(data) % 2 else b'')


class ArchiveReplacementTests(unittest.TestCase):
    def read(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lib.a'
            path.write_bytes(data)
            return archive_members(path)

    def test_bsd_names_padding_and_symbol_index(self):
        data = b'!<arch>\n' + member('__.SYMDEF SORTED', b'index')
        data += member('export.o', b'abc') + member('unrelated.o', b'unchanged')
        self.assertEqual(self.read(data), {
            'export.o': hashlib.sha256(b'abc').hexdigest(),
            'unrelated.o': hashlib.sha256(b'unchanged').hexdigest()})

    def test_truncated_and_duplicate_members_rejected(self):
        data = b'!<arch>\n' + member('export.o', b'abc')
        for invalid in (data[:-2], data + member('export.o', b'other'), b'invalid'):
            with self.subTest(data=invalid), self.assertRaises(ValueError):
                self.read(invalid)

    def test_only_requested_member_can_change(self):
        before = {'export.o': 'old', 'other.o': 'same'}
        verify_replacement(before, {'export.o': 'new', 'other.o': 'same'}, 'export.o', 'new')
        for invalid in ({'export.o': 'new', 'other.o': 'changed'},
                        {'export.o': 'new'}, {**before, 'extra.o': 'extra'}, before):
            with self.subTest(after=invalid), self.assertRaises(ValueError):
                verify_replacement(before, invalid, 'export.o', 'new')


if __name__ == '__main__':
    unittest.main()
