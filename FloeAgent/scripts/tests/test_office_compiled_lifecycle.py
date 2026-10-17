#!/usr/bin/env python3
"""Small synthetic receipt tests; never Office compile/render evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import office_compiled_lifecycle as lifecycle
import build_office_native_host as producer
import pin_office_host_artifact as pinning
import bootstrap_office_host as bootstrap

spec = importlib.util.spec_from_file_location('transport_fixture', Path(__file__).with_name('test_local_office_transport.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class CompiledLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.LocalOfficeTransportTests('test_valid_local_fixture_preserves_bytes_and_false_capabilities')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        compiled_patch = f.base / 'patches/compiled.patch'
        compiled_patch.write_text('synthetic compiled patch, never executed')
        contract = {'sourceFile': 'engine/vcl/source/app/svdata.cxx',
            'originalSHA256': '1' * 64, 'patchedSHA256': '2' * 64,
            'archive': 'source/engine/instdir/program/libvcllo.a',
            'members': {'svdata.o': 'engine/vcl/source/app/svdata.cxx'},
            'patch': 'patches/compiled.patch', 'patchSHA256': pinning.digest(compiled_patch)}
        f.lock['embeddedLifecycleOverlay']['compiledMembers'] = {'IOS': contract, 'IOSSIMULATOR': copy.deepcopy(contract)}
        # Existing pin legitimately precedes the new component. The embedding
        # identity is unrelated to compiled lifecycle and still must match.
        f.lock['qualifiedHostArtifact']['overlaySHA256'] = f.lock['embeddingOverlay']['sha256']
        self.lock_path = f.base / 'engine.lock.json'
        self.block = {**lifecycle.identity(f.lock, 'IOS', lock_path=self.lock_path),
            'originalArchiveSHA256': '6' * 64, 'archiveSHA256': '7' * 64,
            'objectSHA256ByMember': {'svdata.o': '8' * 64}, 'linkerListSHA256': '9' * 64}
        f.manifest['embeddedLifecycleMember'] = copy.deepcopy(self.block)
        f.manifest['platformOriginalArchives'] = {'sdk': 'iphoneos', 'archives': {'libvcllo.a': '6' * 64}}
        self.commit_contract()

    def commit_contract(self):
        f = self.fixture
        self.lock_path.write_text(json.dumps(f.lock))
        f.git('add', '.')
        f.git('-c', 'user.name=Transport fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'synthetic compiled contract')
        f.source = f.git('rev-parse', 'HEAD').strip()

    def test_current_transport_accepts_complete_block_without_rewriting_zip(self):
        f = self.fixture
        sha = f.pack(); before = f.archive.read_bytes()
        f.validate(sha)
        self.assertEqual(f.archive.read_bytes(), before)
        self.assertEqual(lifecycle.validate(self.block, f.lock, 'IOS', lock_path=self.lock_path), self.block)

    def test_current_transport_rejects_missing_wrong_platform_patch_source_and_member(self):
        f = self.fixture
        variants = [None]
        for key, value in [('platform', 'IOSSIMULATOR'), ('compiledPatchSHA256', '0' * 64),
                           ('originalSourceSHA256', '0' * 64), ('patchedSourceSHA256', '0' * 64),
                           ('members', {'other.o': self.block['sourceFile']}),
                           ('objectSHA256ByMember', {}), ('compilePassed', 1), ('schemaVersion', 2)]:
            bad = copy.deepcopy(self.block); bad[key] = value; variants.append(bad)
        for bad in variants:
            with self.subTest(block=bad):
                if bad is None: f.manifest.pop('embeddedLifecycleMember', None)
                else: f.manifest['embeddedLifecycleMember'] = bad
                f.pack()
                with self.assertRaisesRegex(ValueError, 'Compiled embedded lifecycle'):
                    f.validate()

    def test_real_compiled_patch_bytes_checked_before_any_build(self):
        f = self.fixture
        (f.base / 'patches/compiled.patch').write_text('changed patch bytes')
        with patch.object(producer.subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'compiled patch bytes'):
                producer.select_lifecycle_archive(f.root, f.root / 'producer', 'IOS', self.lock_path, engine_source=f.root)
            command.assert_not_called()
        # Commit the mismatched bytes in this synthetic checkout so the
        # separate dirty-source fence does not hide the patch-hash assertion.
        self.commit_contract()
        f.pack()
        with self.assertRaisesRegex(ValueError, 'compiled patch bytes'):
            f.validate()

    def test_pin_records_full_block_and_bootstrap_requires_exact_restored_block(self):
        f = self.fixture
        f.pack()
        with patch.object(pinning, 'HOST_SOURCES', f.base / 'FloeOfficeNative'), \
             patch.object(pinning, 'arguments', types.SimpleNamespace(artifact_run_id=None, artifact_commit=None), create=True):
            self.assertEqual(pinning.apply(self.lock_path, f.archive, 'synthetic test, not Office qualification'), 0)
        lock, pin = bootstrap.checked_lock(self.lock_path)
        self.assertEqual(pin['embeddedLifecycleMember'], self.block)
        bootstrap.verify_installed(f.host, lock, pin)
        changed = copy.deepcopy(self.block); changed['objectSHA256ByMember']['svdata.o'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'restored receipt differs'):
            lifecycle.validate(changed, lock, 'IOS', expected=pin['embeddedLifecycleMember'])

    def test_new_pin_rejects_absent_member_without_mutating_lock(self):
        f = self.fixture
        f.manifest.pop('embeddedLifecycleMember');f.pack()
        original = self.lock_path.read_bytes()
        with patch.object(pinning, 'HOST_SOURCES', f.base / 'FloeOfficeNative'):
            self.assertEqual(pinning.apply(self.lock_path, f.archive, 'rejected fixture'), 1)
        self.assertEqual(self.lock_path.read_bytes(), original)

    def test_legacy_device_pin_remains_development_only(self):
        f = self.fixture
        _, pin = bootstrap.checked_lock(self.lock_path)
        self.assertNotIn('embeddedLifecycleMember', pin)
        # Current-source transport cannot inherit that old-pin exemption.
        f.manifest.pop('embeddedLifecycleMember');f.pack()
        with self.assertRaisesRegex(ValueError, 'required compiled member'):
            f.validate()

    def test_simulator_new_block_checks_platform_original_archive(self):
        f = self.fixture
        block = {**self.block, **lifecycle.identity(f.lock, 'IOSSIMULATOR', lock_path=self.lock_path)}
        lifecycle.validate(block, f.lock, 'IOSSIMULATOR', original_archives={'libvcllo.a': '6' * 64})
        with self.assertRaisesRegex(ValueError, 'original archive differs'):
            lifecycle.validate(block, f.lock, 'IOSSIMULATOR', original_archives={'libvcllo.a': '0' * 64})

    def test_historical_simulator_cannot_downgrade_versioned_or_unknown_block(self):
        f = self.fixture
        legacy = {k: copy.deepcopy(v) for k, v in self.block.items()
                  if k in ('platform', 'archive', 'originalArchiveSHA256', 'archiveSHA256',
                           'objectSHA256ByMember', 'members', 'linkerListSHA256', 'patchSHA256', 'sourceCommit')}
        legacy['platform'] = 'IOSSIMULATOR'
        lifecycle.validate_legacy_simulator(legacy, f.lock, {'libvcllo.a': '6' * 64})
        for extra in ({'schemaVersion': 0}, {'schemaVersion': 1}, {'compiledPatchSHA256': '0' * 64}):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                lifecycle.validate_legacy_simulator({**legacy, **extra}, f.lock, {'libvcllo.a': '6' * 64})


class MultiArchiveLifecycleTests(unittest.TestCase):
    """Synthetic contracts/linkmaps only; no native execution or Office claims."""
    def setUp(self):
        case = CompiledLifecycleTests('test_current_transport_accepts_complete_block_without_rewriting_zip')
        case.setUp(); self.addCleanup(case.doCleanups)
        self.case = case; self.f = f = case.fixture
        patch_path = f.base / 'patches/sal.patch'; patch_path.write_text('synthetic SAL patch')
        child = {'sourceFile': 'engine/sal/osl/unx/thread.cxx', 'originalSHA256': 'a' * 64,
                 'patchedSHA256': 'b' * 64, 'patch': 'patches/sal.patch',
                 'patchSHA256': pinning.digest(patch_path),
                 'archive': 'source/engine/instdir/program/libsallo.a',
                 'members': {'thread.o': 'engine/sal/osl/unx/thread.cxx'},
                 'compileOverrides': {'flags': ['-DSAL_DLLIMPLEMENTATION'], 'sourceIncludes': ['engine/sal/inc']}}
        self.child_spec = child
        for platform in ('IOS', 'IOSSIMULATOR'):
            f.lock['embeddedLifecycleOverlay']['compiledMembers'][platform]['additionalArchives'] = {'libsallo.a': copy.deepcopy(child)}
        self.child = {**lifecycle.identity(lifecycle.single_lock(f.lock, 'IOS', child), 'IOS'),
                      'originalArchiveSHA256': 'c' * 64, 'archiveSHA256': 'd' * 64,
                      'objectSHA256ByMember': {'thread.o': 'e' * 64}, 'linkerListSHA256': 'f' * 64}
        self.block = {**case.block, 'schemaVersion': 2, 'additionalArchives': {'libsallo.a': self.child}}
        self.block['linkOwnership'] = {'linkMapSHA256': '0' * 64, 'linkerListSHA256': '9' * 64,
            'archives': {name: {'archiveSHA256': item['archiveSHA256'], 'objectSHA256ByMember': item['objectSHA256ByMember']}
                         for name, item in {'libvcllo.a': self.block, 'libsallo.a': self.child}.items()},
            'preparedObjects': {name: {'preparedSourceSHA256': spec['preparedSHA256'],
                                     'objectSHA256': '5' * 64, 'objectName': Path(name).stem + '.o'}
                                for name, spec in f.lock['embeddedLifecycleOverlay']['files'].items()}}
        f.manifest['embeddedLifecycleMember'] = self.block
        f.manifest['platformOriginalArchives']['archives']['libsallo.a'] = 'c' * 64
        case.commit_contract()

    def test_multi_archive_transport_pin_and_restore_are_exact(self):
        f = self.f; sha = f.pack(); original = f.archive.read_bytes()
        f.validate(sha); self.assertEqual(original, f.archive.read_bytes())
        with patch.object(pinning, 'HOST_SOURCES', f.base / 'FloeOfficeNative'), patch.object(pinning, 'arguments', types.SimpleNamespace(artifact_run_id=None, artifact_commit=None), create=True):
            self.assertEqual(pinning.apply(self.case.lock_path, f.archive, 'synthetic multi archive'), 0)
        lock, pin = bootstrap.checked_lock(self.case.lock_path)
        self.assertEqual(pin['embeddedLifecycleMember'], self.block)
        bootstrap.verify_installed(f.host, lock, pin)

    def test_missing_sal_downgrade_wrong_source_platform_or_link_ownership_rejected(self):
        for mutate in (
            lambda b: b.update(schemaVersion=1), lambda b: b['additionalArchives'].clear(),
            lambda b: b['additionalArchives']['libsallo.a'].update(platform='IOSSIMULATOR'),
            lambda b: b['additionalArchives']['libsallo.a'].update(patchedSourceSHA256='0'*64),
            lambda b: b['additionalArchives']['libsallo.a'].update(compilePassed=1),
            lambda b: b['linkOwnership']['archives']['libsallo.a'].update(archiveSHA256='0'*64),
            lambda b: b['linkOwnership']['preparedObjects'].clear(),
            lambda b: b['linkOwnership'].update(linkMapSHA256='not-a-hash')):
            bad = copy.deepcopy(self.block); mutate(bad)
            with self.subTest(block=bad), self.assertRaises(ValueError):
                lifecycle.validate(bad, self.f.lock, 'IOS', original_archives={'libvcllo.a':'6'*64, 'libsallo.a':'c'*64})
        with self.assertRaisesRegex(ValueError, 'original archive'):
            lifecycle.validate(self.block, self.f.lock, 'IOS', original_archives={'libvcllo.a':'6'*64, 'libsallo.a':'0'*64})

    def test_extra_patch_checked_and_compiler_inputs_bounded(self):
        f = self.f
        for overrides in ({'flags': ['-fplugin=evil']}, {'flags': ['@response']},
                          {'sourceIncludes': ['../escape']}, {'sourceIncludes': ['wsd']},
                          {'sdk': 'macosx'}):
            lock = copy.deepcopy(f.lock)
            lock['embeddedLifecycleOverlay']['compiledMembers']['IOS']['additionalArchives']['libsallo.a']['compileOverrides'] = overrides
            with self.subTest(overrides=overrides), self.assertRaises(ValueError): lifecycle.identity(lock, 'IOS')
        (f.base / 'patches/sal.patch').write_text('tampered SAL patch')
        with patch.object(producer.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'compiled patch bytes'):
                producer.select_lifecycle_archive(f.root, f.root / 'producer', 'IOS', self.case.lock_path, engine_source=f.root)
            run.assert_not_called()

    def test_actual_linkmap_paths_and_objects_measured_not_boolean_claim(self):
        f = self.f; output = f.root / 'native-synthetic'; output.mkdir()
        objects = output / 'objects/Native.build/Objects-normal/arm64'; objects.mkdir(parents=True)
        lines=[]; inputs=[]
        for name, block in {'libvcllo.a':self.block, 'libsallo.a':self.child}.items():
            archive = output / name; archive.write_bytes(name.encode()); inputs.append(str(archive.resolve()))
            block['archiveSHA256'] = pinning.digest(archive)
            for member in block['members']: lines.append('[  1] ' + str(archive.resolve()) + '(' + member + ')')
        for name, spec in f.lock['embeddedLifecycleOverlay']['files'].items():
            source = output / 'source' / name; source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('synthetic prepared ' + name); spec['preparedSHA256'] = pinning.digest(source)
            obj = objects / (Path(name).stem + '.o'); obj.write_bytes(name.encode()); lines.append('[  2] ' + str(obj))
        linkmap = output / 'objects/FloeOfficeNative-LinkMap-normal-arm64.txt'; linkmap.write_text('\n'.join(lines))
        linker = output / 'linker.list'; linker.write_text('\n'.join(inputs))
        report = {'embeddedLifecycleMember':self.block, 'platformOriginalArchives':f.manifest['platformOriginalArchives']}
        producer.lifecycle_link_ownership(report, f.root, output, f.lock, 'IOS', linker)
        self.assertEqual(self.block['linkOwnership']['linkMapSHA256'], pinning.digest(linkmap))
        linkmap.write_text('missing actual archive member')
        with self.assertRaisesRegex(ValueError, 'absent/ambiguous'):
            producer.lifecycle_link_ownership(report, f.root, output, f.lock, 'IOS', linker)


if __name__ == '__main__':
    unittest.main()
