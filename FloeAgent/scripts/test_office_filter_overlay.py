#!/usr/bin/env python3
"""Fail closed on archive corruption or accidental changes to other engine code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from build_office_filter_overlay import archive_members, verify_replacement, verify_replacements, select_linker_archive


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

    def test_multiple_replacements_cannot_hide_missing_or_unrelated_changes(self):
        before = {'export.o': 'old', 'metrics.o': 'old-metrics', 'other.o': 'same'}
        objects = {'export.o': 'new', 'metrics.o': 'new-metrics'}
        after = {**before, **objects}
        verify_replacements(before, after, objects)
        for invalid in (before, {**after, 'metrics.o': 'old-metrics'},
                        {**after, 'other.o': 'changed'},
                        {**after, 'metrics.o': 'wrong'}, {**after, 'extra.o': 'extra'}):
            with self.subTest(after=invalid), self.assertRaises(ValueError):
                verify_replacements(before, invalid, objects)
        with self.assertRaises(ValueError):
            verify_replacements(before, before, {})


class LinkerSelectionTests(unittest.TestCase):
    def fixture(self, base):
        bundle, overlay, output = (base / name for name in ('bundle', 'overlay', 'host'))
        for folder in (bundle / 'prepared', overlay, output):
            folder.mkdir(parents=True)
        patch_file = base / 'filter.patch'
        patch_file.write_bytes(b'pinned patch')
        digest = lambda data: hashlib.sha256(data).hexdigest()
        lock = {'commit': 'fixed', 'patch': patch_file.name, 'patchSHA256': digest(patch_file.read_bytes()),
                'files': {'one.cxx': {'originalSHA256': 'source', 'patchedSHA256': 'patched'}},
                'archive': 'libscfiltlo.a', 'member': 'export.o', 'members': {'export.o': 'one.cxx'}}
        report = {'sourceCommit': lock['commit'], 'patchSHA256': lock['patchSHA256'],
                  'sourceFiles': lock['files'], 'compilePassed': True, 'archiveReplacementPassed': True}
        specs = {}
        for name, obj in [('libscfiltlo.a', 'export.o'), ('libooxlo.a', 'shape.o')]:
            before = b'!<arch>\n' + member(obj, b'old') + member('unrelated.o', b'unchanged')
            after = b'!<arch>\n' + member(obj, b'new') + member('unrelated.o', b'unchanged')
            (bundle / name).write_bytes(before)
            (overlay / name).write_bytes(after)
            spec = {'archive': name, 'originalArchiveSHA256': digest(before), 'members': {obj: 'one.cxx'}}
            result = {'archiveSHA256': digest(after), 'objectSHA256ByMember': {obj: digest(b'new')}}
            if name == 'libscfiltlo.a':
                lock['originalArchiveSHA256'] = spec['originalArchiveSHA256']
                report.update(result, objectSHA256=digest(b'new'))
            else:
                specs[name] = spec
                report['additionalArchives'] = {name: result}
        lock['additionalArchives'] = specs
        lock_file = base / 'lock.json'
        lock_file.write_text(json.dumps(lock))
        (overlay / 'filter-overlay.json').write_text(json.dumps(report))
        (bundle / 'prepared/ios-all-static-libs.list').write_text(
            '\n'.join(str(bundle / name) for name in ('libscfiltlo.a', 'libooxlo.a', 'untouched.a')) + '\n')
        return lock_file, bundle, overlay, output

    def test_both_owned_archives_selected_without_changing_other_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            lock, bundle, overlay, output = self.fixture(Path(directory))
            original_list = (bundle / 'prepared/ios-all-static-libs.list').read_bytes()
            with patch('build_office_filter_overlay.FILTER_LOCK', lock):
                linker, report = select_linker_archive(bundle, overlay, output)
            self.assertEqual(linker.read_text().splitlines(),
                             [str(output.resolve() / 'libscfiltlo.a'), str(output.resolve() / 'libooxlo.a'), str(bundle / 'untouched.a')])
            self.assertEqual(set(report['selectedArchiveSHA256ByName']), {'libscfiltlo.a', 'libooxlo.a'})
            self.assertEqual((bundle / 'prepared/ios-all-static-libs.list').read_bytes(), original_list)

    def test_corrupt_extra_archive_and_unrelated_member_change_rejected(self):
        for mutate_receipt in (False, True):
            with self.subTest(mutate_receipt=mutate_receipt), tempfile.TemporaryDirectory() as directory:
                lock, bundle, overlay, output = self.fixture(Path(directory))
                data = b'!<arch>\n' + member('shape.o', b'new') + member('unrelated.o', b'changed')
                (overlay / 'libooxlo.a').write_bytes(data)
                if mutate_receipt:
                    path = overlay / 'filter-overlay.json'
                    report = json.loads(path.read_text())
                    report['additionalArchives']['libooxlo.a']['archiveSHA256'] = hashlib.sha256(data).hexdigest()
                    path.write_text(json.dumps(report))
                with patch('build_office_filter_overlay.FILTER_LOCK', lock), self.assertRaises(ValueError):
                    select_linker_archive(bundle, overlay, output)
                self.assertEqual(list(output.iterdir()), [])

    def test_missing_duplicate_or_unreported_extra_archive_rejected(self):
        for mode in ('missing', 'duplicate', 'unreported'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                lock, bundle, overlay, output = self.fixture(Path(directory))
                path = bundle / 'prepared/ios-all-static-libs.list'
                if mode == 'missing':
                    path.write_text(str(bundle / 'libscfiltlo.a') + '\n')
                elif mode == 'duplicate':
                    path.write_text(path.read_text() + str(bundle / 'libooxlo.a') + '\n')
                else:
                    path = overlay / 'filter-overlay.json'
                    report = json.loads(path.read_text())
                    del report['additionalArchives']
                    path.write_text(json.dumps(report))
                with patch('build_office_filter_overlay.FILTER_LOCK', lock), self.assertRaises(ValueError):
                    select_linker_archive(bundle, overlay, output)
                self.assertEqual(list(output.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
