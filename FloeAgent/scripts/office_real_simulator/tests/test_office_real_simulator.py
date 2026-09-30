#!/usr/bin/env python3
"""Lightweight, network-free checks for the real simulator qualification.

Run: python3 -m unittest discover -s scripts/office_real_simulator/tests
or:  python3 scripts/office_real_simulator/tests/test_office_real_simulator.py

These validate pinned inputs and local logic only; they never execute a build
and must not claim a simulator result.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

PKG_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = PKG_DIR.parent.parent.parent
sys.path.insert(0, str(PKG_DIR))
sys.path.insert(0, str(REPO_ROOT / 'FloeAgent/scripts'))

import check_persistence  # noqa: E402
import discover_products  # noqa: E402
import extract_receipt  # noqa: E402
import make_fixture  # noqa: E402
import qualification_ui_test  # noqa: E402
import restore_simulator_bundle  # noqa: E402
import sim_paths  # noqa: E402
import staged_layout  # noqa: E402

WORKFLOW = REPO_ROOT / '.github/workflows/office-real-simulator.yml'


class FixtureTests(unittest.TestCase):
    def test_deterministic(self):
        first = make_fixture.build_bytes()
        second = make_fixture.build_bytes()
        self.assertEqual(first, second)
        facts = make_fixture.validate(first)
        self.assertEqual(facts['slideCount'], sim_paths.FIXTURE_SLIDE_COUNT)

    def test_pinned_hash(self):
        import hashlib
        digest = hashlib.sha256(make_fixture.build_bytes()).hexdigest()
        self.assertEqual(digest, sim_paths.FIXTURE_SHA256)

    def test_write_and_validate(self):
        with tempfile.TemporaryDirectory() as tmp:
            receipt = make_fixture.write_fixture(Path(tmp) / 'f.pptx')
            self.assertTrue(receipt['synthetic'])
            self.assertFalse(receipt['userContent'])
            self.assertEqual(receipt['slideCount'], 2)
            self.assertEqual(receipt['basename'], 'f.pptx')

    def test_expected_hash_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                make_fixture.write_fixture(Path(tmp) / 'f.pptx', 'deadbeef')

    def test_malformed_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / 'b.pptx'
            bad.write_bytes(b'not a zip')
            with self.assertRaises(Exception):
                make_fixture.validate(bad.read_bytes())


class PinnedInputsTests(unittest.TestCase):
    def test_deployment_patch_covers_simulator(self):
        lock = json.loads(sim_paths.LOCK_PATH.read_text())
        patch = sim_paths.DEPLOYMENT_PATCH.read_text()
        self.assertIn('ios-simulator-version-min=26.0', patch)
        import hashlib
        digest = hashlib.sha256(patch.encode()).hexdigest()
        self.assertEqual(digest, lock['sourcePatchSHA256'])

    def test_disk_safety_aligned_with_lock(self):
        lock = json.loads(sim_paths.LOCK_PATH.read_text())
        self.assertEqual(sim_paths.RESERVE_GIB, lock['buildReserveGiB'])
        self.assertEqual(sim_paths.MINIMUM_FREE_GIB, lock['minimumFreeGiB'])

    def test_pinned_commit(self):
        lock = json.loads(sim_paths.LOCK_PATH.read_text())
        self.assertEqual(lock['platform'], 'iphoneos-arm64')
        self.assertEqual(lock['commit'],
                         '27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc')


class StagedLayoutTests(unittest.TestCase):
    """The real gh/download-artifact layout: contents directly in the dir."""

    def make_flat(self, tmp):
        staged = Path(tmp) / 'staged'
        staged.mkdir()
        (staged / sim_paths.STAGED_ENGINE_TAR).write_bytes(b'tarball')
        (staged / sim_paths.STAGED_PROVENANCE).write_text('{}')
        (staged / sim_paths.STAGED_QUALIFICATION).write_text('{}')
        return staged

    def test_flat_layout_resolves(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = self.make_flat(tmp)
            facts = staged_layout.resolve(staged)
            self.assertEqual(Path(facts['engineTarball']).resolve(),
                             (staged / sim_paths.STAGED_ENGINE_TAR).resolve())
            self.assertEqual(Path(facts['provenance']).resolve(),
                             (staged / sim_paths.STAGED_PROVENANCE).resolve())
            self.assertEqual(facts['layout'], 'flat-artifact-contents')
            self.assertFalse(facts['nestedLegacyDirectoryPresent'])

    def test_missing_files_fail_with_listing(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / 'staged'
            staged.mkdir()
            (staged / 'disk-preflight.log').write_text('x')
            with self.assertRaises(staged_layout.StagedLayoutError) as ctx:
                staged_layout.resolve(staged)
            message = str(ctx.exception)
            self.assertIn(sim_paths.STAGED_ENGINE_TAR, message)
            self.assertIn('disk-preflight.log', message)

    def test_legacy_nested_layout_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / 'staged'
            nested = staged / staged_layout.LEGACY_NESTED_DIR
            nested.mkdir(parents=True)
            (nested / sim_paths.STAGED_ENGINE_TAR).write_bytes(b'tarball')
            (nested / sim_paths.STAGED_PROVENANCE).write_text('{}')
            with self.assertRaises(staged_layout.StagedLayoutError) as ctx:
                staged_layout.resolve(staged)
            self.assertIn('layout mismatch', str(ctx.exception))

    def test_github_output_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = self.make_flat(tmp)
            output = Path(tmp) / 'out.txt'
            facts = staged_layout.resolve(staged)
            staged_layout._write_github_output(output, facts)
            text = output.read_text()
            self.assertIn('engineTarball=', text)
            self.assertIn('provenance=', text)


class ProductDiscoveryTests(unittest.TestCase):
    def make_products(self, tmp, app_bundle_id=sim_paths.HOST_BUNDLE_ID,
                      target_bundle_id=None):
        products = Path(tmp) / 'Products'
        config = products / 'Debug-iphonesimulator'
        app = config / 'Mobile.app'
        app.mkdir(parents=True)
        (app / 'Mobile').write_text('binary')
        with (app / 'Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': app_bundle_id,
                           'CFBundleExecutable': 'Mobile'}, stream)
        target = config / 'Mobile.app'
        if target_bundle_id is not None:
            # A second, wrong app that must never be silently chosen.
            wrong = config / 'Other.app'
            wrong.mkdir()
            with (wrong / 'Info.plist').open('wb') as stream:
                plistlib.dump({'CFBundleIdentifier': target_bundle_id}, stream)
        runner = config / 'MobileUITests-Runner.app'
        runner.mkdir()
        with (runner / 'Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier':
                           app_bundle_id + '.MobileUITests.xctrunner'}, stream)
        xctestrun = {
            'MobileUITests': {
                'TestBundlePath':
                    '__TESTHOST__/PlugIns/MobileUITests.xctest',
                'TestHostPath':
                    '__TESTROOT__/Debug-iphonesimulator/MobileUITests-Runner.app',
                'TestHostBundleIdentifier':
                    app_bundle_id + '.MobileUITests.xctrunner',
                'UITargetAppPath': '__TESTROOT__/Debug-iphonesimulator/Mobile.app',
                'UITargetAppMainBundleIdentifier': app_bundle_id,
                'IsUITestBundle': True,
            }
        }
        xctestrun_path = products / 'Mobile_iphonesimulator27.0-arm64.xctestrun'
        with xctestrun_path.open('wb') as stream:
            plistlib.dump(xctestrun, stream)
        return products, app, runner

    def test_finds_nested_product_and_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            products, app, runner = self.make_products(tmp)
            receipt = discover_products.discover(products)
            self.assertEqual(Path(receipt['appPath']).resolve(), app.resolve())
            self.assertEqual(Path(receipt['runnerAppPath']).resolve(),
                             runner.resolve())
            self.assertEqual(receipt['runnerBundleIdentifier'],
                             sim_paths.HOST_BUNDLE_ID + '.MobileUITests.xctrunner')

    def test_wrong_bundle_id_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            products, _, _ = self.make_products(
                tmp, app_bundle_id='com.example.not-floe')
            with self.assertRaises(discover_products.ProductDiscoveryError):
                discover_products.discover(products)

    def test_missing_xctestrun_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            products = Path(tmp) / 'Products'
            (products / 'Debug-iphonesimulator/Mobile.app').mkdir(parents=True)
            with self.assertRaises(discover_products.ProductDiscoveryError):
                discover_products.discover(products)

    def test_mismatched_target_app_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            products, _, _ = self.make_products(tmp)
            # Point UITargetAppPath at an app with the wrong identity.
            wrong = products / 'Debug-iphonesimulator/Other.app'
            wrong.mkdir()
            with (wrong / 'Info.plist').open('wb') as stream:
                plistlib.dump({'CFBundleIdentifier': 'com.example.other'}, stream)
            xctestrun_path = next(products.glob('*.xctestrun'))
            xctestrun = plistlib.loads(xctestrun_path.read_bytes())
            xctestrun['MobileUITests']['UITargetAppPath'] = \
                '__TESTROOT__/Debug-iphonesimulator/Other.app'
            with xctestrun_path.open('wb') as stream:
                plistlib.dump(xctestrun, stream)
            with self.assertRaises(discover_products.ProductDiscoveryError):
                discover_products.discover(products)


class ReceiptSeparationTests(unittest.TestCase):
    def make_manifest(self, tmp, name=sim_paths.RECEIPT_ATTACHMENT_NAME):
        attachments = Path(tmp) / 'screenshots'
        attachments.mkdir()
        receipt_file = attachments / f'{name}_ABC.json'
        receipt_file.write_text(json.dumps(
            {'phases': [{'phase': p, 'ok': True}
                        for p in check_persistence.EXPECTED_PHASES]}))
        manifest = [{
            'testIdentifier': 'FloeRealSimulatorQualification',
            'attachments': [
                {'exportedFileName': receipt_file.name,
                 'suggestedHumanReadableName': name,
                 'isAssociatedWithFailure': False,
                 'configurationName': 'Test Scheme',
                 'deviceName': 'iPad', 'deviceId': 'x'},
                {'exportedFileName': 'Screenshot_01-preview.png',
                 'suggestedHumanReadableName': '01-preview',
                 'isAssociatedWithFailure': False,
                 'configurationName': 'Test Scheme',
                 'deviceName': 'iPad', 'deviceId': 'x'},
            ],
        }]
        (attachments / 'manifest.json').write_text(json.dumps(manifest))
        return attachments, receipt_file

    def test_attachment_preferred_over_runner_container(self):
        with tempfile.TemporaryDirectory() as tmp:
            attachments, receipt_file = self.make_manifest(tmp)
            output = Path(tmp) / 'receipt.json'
            report = extract_receipt.extract(str(attachments), None, None,
                                             str(output), None)
            self.assertTrue(report['found'])
            self.assertEqual(report['source'], 'xcresult-attachment')
            self.assertTrue(output.is_file())

    def test_runner_container_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp) / 'container'
            docs = container / 'Documents'
            docs.mkdir(parents=True)
            receipt = {'phases': [{'phase': p, 'ok': True}
                                  for p in check_persistence.EXPECTED_PHASES]}
            (docs / sim_paths.RECEIPT_FILENAME).write_text(json.dumps(receipt))
            original = extract_receipt.runner_container
            extract_receipt.runner_container = lambda sim, runner: (container, '')
            try:
                output = Path(tmp) / 'receipt.json'
                report = extract_receipt.extract(None, 'SIM', 'runner.id',
                                                 str(output), None)
            finally:
                extract_receipt.runner_container = original
            self.assertTrue(report['found'])
            self.assertEqual(report['source'], 'runner-container')
            self.assertTrue(output.is_file())

    def test_suffixed_attachment_name_still_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            attachments, receipt_file = self.make_manifest(
                tmp, name=sim_paths.RECEIPT_ATTACHMENT_NAME + '_0')
            report = extract_receipt.extract(str(attachments), None, None, None, None)
            self.assertTrue(report['found'])
            self.assertEqual(Path(report['path']).resolve(),
                             receipt_file.resolve())

    def test_missing_everywhere_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = extract_receipt.extract(str(Path(tmp) / 'nope'), None, None,
                                             str(Path(tmp) / 'out.json'), None)
            self.assertFalse(report['found'])
            self.assertFalse((Path(tmp) / 'out.json').exists())
            self.assertTrue(report['searched'])

    def test_persistence_gate_requires_receipt_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = check_persistence.check_persistence(
                'SIM', 'seed', str(Path(tmp) / 'missing.json'))
            self.assertFalse(result['persistencePassed'])
            self.assertTrue(result['blockingFailures'])


class ReceiptGateTests(unittest.TestCase):
    def good_receipt(self):
        return {'fixture': sim_paths.FIXTURE_BASENAME,
                'phases': [{'phase': name, 'ok': True}
                           for name in check_persistence.EXPECTED_PHASES]}

    def test_good_receipt_passes(self):
        ok, failures = check_persistence.validate_receipt(self.good_receipt())
        self.assertTrue(ok, failures)

    def test_exact_phase_count(self):
        self.assertEqual(len(check_persistence.EXPECTED_PHASES), 11)
        self.assertEqual(check_persistence.EXPECTED_PHASES,
                         sim_paths.SCENARIO_PHASES)

    def test_missing_or_empty_receipt_fails(self):
        for receipt in (None, {}, [], {'phases': []}, {'phases': None}):
            ok, failures = check_persistence.validate_receipt(receipt)
            self.assertFalse(ok, receipt)
            self.assertTrue(failures)

    def test_exact_phase_coverage_required(self):
        receipt = self.good_receipt()
        receipt['phases'] = receipt['phases'][1:]  # drop preview-open
        ok, failures = check_persistence.validate_receipt(receipt)
        self.assertFalse(ok)
        self.assertIn('missing phases', ' '.join(failures))

        receipt = self.good_receipt()
        receipt['phases'].append({'phase': 'mystery', 'ok': True})
        ok, failures = check_persistence.validate_receipt(receipt)
        self.assertFalse(ok)
        self.assertIn('unexpected phases', ' '.join(failures))

    def test_failed_phase_fails(self):
        receipt = self.good_receipt()
        receipt['phases'][3]['ok'] = False
        ok, failures = check_persistence.validate_receipt(receipt)
        self.assertFalse(ok)
        self.assertIn('phases not ok', ' '.join(failures))


class PlatformGateTests(unittest.TestCase):
    """Fake tool outputs prove the parser; vtool cannot read .a archives."""

    def fake_tools(self, archive, vtool=(0, '  platform IOSSIMULATOR\n'),
                   lipo=(0, 'arm64\n')):
        def run(command, cwd=None):
            if command[:2] == ['lipo', '-archs']:
                return lipo
            if command[:2] == ['ar', 'x'] and cwd:
                (Path(cwd) / 'a.o').write_bytes(b'fake')
                return 0, ''
            if command[0] == 'vtool':
                return vtool
            return 1, f'unexpected command {command}'

        return run

    def test_arm64_simulator_archive_passes(self):
        import stage_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'libx.a'
            archive.write_bytes(b'not real')
            ok, facts = stage_simulator_engine.archive_simulator_facts(
                archive, runner=self.fake_tools(archive))
            self.assertTrue(ok, facts)
            self.assertTrue(facts['simulatorOnly'])
            self.assertEqual(facts['archiveArchitectures'], ['arm64'])
            self.assertGreaterEqual(facts['memberSampleCount'], 1)

    def test_vtool_failure_rejected(self):
        import stage_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'libx.a'
            archive.write_bytes(b'not real')
            ok, facts = stage_simulator_engine.archive_simulator_facts(
                archive, runner=self.fake_tools(archive, vtool=(1, 'file is not mach-o\n')))
            self.assertFalse(ok)
            self.assertIn('vtool failed', str(facts))

    def test_device_platform_rejected(self):
        import stage_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'libx.a'
            archive.write_bytes(b'not real')
            ok, facts = stage_simulator_engine.archive_simulator_facts(
                archive, runner=self.fake_tools(archive, vtool=(0, '  platform IOS\n')))
            self.assertFalse(ok)
            self.assertIn('platforms', str(facts))

    def test_x86_64_archive_rejected(self):
        import stage_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'libx.a'
            archive.write_bytes(b'not real')
            ok, facts = stage_simulator_engine.archive_simulator_facts(
                archive, runner=self.fake_tools(archive, lipo=(0, 'x86_64\n')))
            self.assertFalse(ok)
            self.assertIn('architectures', str(facts))

    def test_empty_member_fails(self):
        import stage_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'libx.a'
            archive.write_bytes(b'not real')

            def run(command, cwd=None):
                if command[:2] == ['lipo', '-archs']:
                    return 0, 'arm64\n'
                if command[:2] == ['ar', 'x'] and cwd:
                    return 0, ''  # extracts nothing
                return 1, 'unexpected'

            ok, facts = stage_simulator_engine.archive_simulator_facts(
                archive, runner=run)
            self.assertFalse(ok)
            self.assertIn('no object members', str(facts))

    def test_pick_samples(self):
        import stage_simulator_engine
        archives = [f'source/engine/lib{i}.a' for i in range(40)]
        samples = stage_simulator_engine.pick_samples(archives)
        self.assertTrue(samples)
        self.assertLessEqual(len(samples), stage_simulator_engine.SAMPLE_SIZE)
        self.assertEqual(samples, sorted(samples))
        self.assertEqual(stage_simulator_engine.pick_samples([]), [])


class ProvenanceBindingTests(unittest.TestCase):
    def make_lock(self, tmp, commit='abc', patch='p', repository='repo'):
        lock = {'commit': commit, 'sourcePatchSHA256': patch,
                'repository': repository}
        path = Path(tmp) / 'engine.lock.json'
        path.write_text(json.dumps(lock))
        return lock, path

    def provenance(self, sha, size, **overrides):
        data = {
            'artifactSHA256': sha,
            'artifactSize': size,
            'sourceCommit': 'abc',
            'repository': 'repo',
            'deploymentPatchSHA256': 'p',
            'platform': 'iphonesimulator',
            'arch': 'arm64',
            'sdkVersion': '27.0',
            'sdkBuildVersion': '27A',
            'xcodeVersion': 'Xcode 27.0',
            'deploymentTarget': '26.0',
            'platformSampleSize': 1,
            'allSampledObjectsIOSSIMULATOR': True,
        }
        data.update(overrides)
        return data

    def test_valid_provenance_binds(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'engine.tar.gz'
            archive.write_bytes(b'payload')
            sha = restore_simulator_bundle.artifact_sha256(archive)
            lock = {'commit': 'abc', 'sourcePatchSHA256': 'p',
                    'repository': 'repo'}
            failures = restore_simulator_bundle.verify_provenance(
                archive, self.provenance(sha, 7), lock)
            self.assertEqual(failures, [])

    def test_hash_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'engine.tar.gz'
            archive.write_bytes(b'payload')
            lock = {'commit': 'abc', 'sourcePatchSHA256': 'p',
                    'repository': 'repo'}
            failures = restore_simulator_bundle.verify_provenance(
                archive, self.provenance('00', 7), lock)
            self.assertTrue(any('SHA-256' in item for item in failures))

    def test_pin_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'engine.tar.gz'
            archive.write_bytes(b'payload')
            sha = restore_simulator_bundle.artifact_sha256(archive)
            lock = {'commit': 'abc', 'sourcePatchSHA256': 'p',
                    'repository': 'repo'}
            for override in ({'sourceCommit': 'other'},
                             {'deploymentPatchSHA256': 'other'},
                             {'repository': 'other'},
                             {'platform': 'iphoneos'},
                             {'arch': 'x86_64'},
                             {'platformSampleSize': 0},
                             {'allSampledObjectsIOSSIMULATOR': False},
                             {'xcodeVersion': ''}):
                failures = restore_simulator_bundle.verify_provenance(
                    archive, self.provenance(sha, 7, **override), lock)
                self.assertTrue(failures, override)

    def test_multiline_xcode_identity_matches_reuse(self):
        provenance = {'xcodeVersion': 'Xcode 27.0; Build version 27A5237l;',
                      'sdkVersion': '27.0'}
        failures = restore_simulator_bundle.verify_current_toolchain(
            provenance, 'Xcode 27.0\nBuild version 27A5237l\n', '27.0')
        self.assertEqual(failures, [])

    def test_toolchain_identity_for_reuse(self):
        provenance = self.provenance('sha', 1)
        failures = restore_simulator_bundle.verify_current_toolchain(
            provenance, 'Xcode 27.0', '27.0')
        self.assertEqual(failures, [])
        failures = restore_simulator_bundle.verify_current_toolchain(
            provenance, 'Xcode 26.0', '26.0')
        self.assertEqual(len(failures), 2)

    def test_embedded_qualification_mismatch(self):
        provenance = self.provenance('sha', 1)
        lock = {'commit': 'abc', 'sourcePatchSHA256': 'p', 'repository': 'repo'}
        qualification = {'commit': 'abc', 'sdkVersion': '26.0',
                         'sdkBuildVersion': '27A', 'xcodeVersion': 'Xcode 27.0'}
        failures = restore_simulator_bundle.verify_embedded_qualification(
            qualification, provenance, lock)
        self.assertTrue(failures)


class RestoreEndToEndTests(unittest.TestCase):
    def make_archive(self, tmp, lock, provenance_overrides=None,
                     manifest_overrides=None, with_symlink=False,
                     with_engine_list=False):
        root = Path(tmp) / 'pkg'
        (root / 'source/engine').mkdir(parents=True)
        archive_member = root / 'source/engine/libx.a'
        archive_member.write_bytes(b'fake-archive')
        import hashlib
        digest = hashlib.sha256(archive_member.read_bytes()).hexdigest()
        qualification = {'commit': lock['commit'], 'sdkVersion': '27.0',
                         'sdkBuildVersion': '27A', 'xcodeVersion': 'Xcode 27.0'}
        (root / 'qualification.json').write_text(json.dumps(qualification))
        manifest = {
            'formatVersion': 2,
            'sourceCommit': lock['commit'],
            'linkerInputs': ['source/engine/libx.a'],
            'linkerArchives': ['source/engine/libx.a'],
            'files': [
                {'path': 'source', 'directory': True},
                {'path': 'source/engine/libx.a', 'size': len(b'fake-archive'),
                 'sha256': digest},
            ],
        }
        if with_engine_list:
            # The real upstream list carries old-runner-absolute paths and .o
            # inputs; the package retains the 1:1 linkerInputs order.
            list_dir = root / 'source/engine/workdir/CustomTarget/ios'
            list_dir.mkdir(parents=True)
            object_member = root / 'source/engine/liby.o'
            object_member.write_bytes(b'fake-object')
            old_root = '/old/runner/work/_temp/floe-office-sim'
            list_path = list_dir / 'ios-all-static-libs.list'
            list_path.write_bytes(
                f'{old_root}/source/engine/libx.a\n'
                f'{old_root}/source/engine/liby.o\n'.encode())
            for path, data in (
                    ('source/engine/liby.o', b'fake-object'),
                    ('source/engine/workdir/CustomTarget/ios/'
                     'ios-all-static-libs.list', list_path.read_bytes())):
                manifest['files'].append({
                    'path': path, 'size': len(data),
                    'sha256': hashlib.sha256(data).hexdigest()})
            manifest['linkerInputs'] = ['source/engine/libx.a',
                                        'source/engine/liby.o']
        if with_symlink:
            (root / 'source/lobuilddir-symlink').symlink_to('engine', target_is_directory=True)
            manifest['files'].append({'path': 'source/lobuilddir-symlink', 'symlink': 'engine'})
        if manifest_overrides:
            manifest.update(manifest_overrides)
        tarball = Path(tmp) / 'engine.tar.gz'
        with tarfile.open(tarball, 'w:gz') as archive:
            archive.add(root / 'qualification.json', arcname='qualification.json')
            data = json.dumps(manifest).encode()
            info = tarfile.TarInfo('bundle-manifest.json')
            info.size = len(data)
            archive.addfile(info, __import__('io').BytesIO(data))
            archive.add(root / 'source', arcname='source')
        sha = restore_simulator_bundle.artifact_sha256(tarball)
        provenance = {
            'artifactSHA256': sha, 'artifactSize': tarball.stat().st_size,
            'sourceCommit': lock['commit'], 'repository': lock['repository'],
            'deploymentPatchSHA256': lock['sourcePatchSHA256'],
            'platform': 'iphonesimulator', 'arch': 'arm64',
            'sdkVersion': '27.0', 'sdkBuildVersion': '27A',
            'xcodeVersion': 'Xcode 27.0', 'deploymentTarget': '26.0',
            'platformSampleSize': 1, 'allSampledObjectsIOSSIMULATOR': True,
        }
        if provenance_overrides:
            provenance.update(provenance_overrides)
        provenance_path = Path(tmp) / 'simulator-provenance.json'
        provenance_path.write_text(json.dumps(provenance))
        return tarball, provenance_path, provenance

    def lock(self):
        return {'commit': 'abc', 'sourcePatchSHA256': 'p', 'repository': 'repo'}

    def test_restore_binds_and_verifies(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tarball, provenance_path, _ = self.make_archive(tmp, self.lock())
            destination = Path(tmp) / 'restored'
            with mock.patch.object(restore_simulator_bundle,
                                   'archive_simulator_facts',
                                   return_value=(True, {'simulatorOnly': True})), \
                 mock.patch.object(restore_simulator_bundle, 'LOCK_PATH',
                                   Path(tmp) / 'lock.json'):
                (Path(tmp) / 'lock.json').write_text(json.dumps(self.lock()))
                report = restore_simulator_bundle.restore(
                    tarball, destination, provenance_path)
            self.assertTrue(report['restoreVerified'])
            self.assertTrue(report['provenanceBound'])
            self.assertTrue((destination / 'source/engine/libx.a').is_file())
            self.assertEqual(report['allSampledObjectsIOSSIMULATOR'], True)

    def test_restore_preserves_internal_directory_symlink(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tarball, provenance_path, _ = self.make_archive(tmp, self.lock(), with_symlink=True)
            destination = Path(tmp) / 'restored'
            lock_path = Path(tmp) / 'lock.json'
            lock_path.write_text(json.dumps(self.lock()))
            with mock.patch.object(restore_simulator_bundle, 'archive_simulator_facts',
                                   return_value=(True, {'simulatorOnly': True})), \
                 mock.patch.object(restore_simulator_bundle, 'LOCK_PATH', lock_path):
                restore_simulator_bundle.restore(tarball, destination, provenance_path)
            link = destination / 'source/lobuilddir-symlink'
            self.assertTrue(link.is_symlink())
            self.assertEqual(os.readlink(link), 'engine')
            self.assertTrue((link / 'libx.a').is_file())

    def test_containment_rejects_escaping_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'destination'
            root.mkdir()
            (root / 'escape').symlink_to('../outside')
            with self.assertRaises(restore_simulator_bundle.RestoreError):
                restore_simulator_bundle.contained(root, 'escape')

    def test_restore_rejects_bad_provenance_before_extract(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tarball, provenance_path, _ = self.make_archive(
                tmp, self.lock(), provenance_overrides={'sourceCommit': 'evil'})
            destination = Path(tmp) / 'restored'
            with mock.patch.object(restore_simulator_bundle, 'LOCK_PATH',
                                   Path(tmp) / 'lock.json'):
                (Path(tmp) / 'lock.json').write_text(json.dumps(self.lock()))
                with self.assertRaises(restore_simulator_bundle.RestoreError):
                    restore_simulator_bundle.restore(tarball, destination,
                                                     provenance_path)
            self.assertFalse(destination.exists())

    def test_restore_reuse_toolchain_identity(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tarball, provenance_path, _ = self.make_archive(tmp, self.lock())
            with mock.patch.object(restore_simulator_bundle, 'LOCK_PATH',
                                   Path(tmp) / 'lock.json'):
                (Path(tmp) / 'lock.json').write_text(json.dumps(self.lock()))
                with self.assertRaises(restore_simulator_bundle.RestoreError):
                    restore_simulator_bundle.restore(
                        tarball, Path(tmp) / 'restored', provenance_path,
                        reuse=True, expect_xcode='Xcode 99.0',
                        expect_sdk='27.0')

    def test_restore_rejects_empty_linker_sample(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tarball, provenance_path, _ = self.make_archive(
                tmp, self.lock(), manifest_overrides={'linkerArchives': []})
            with mock.patch.object(restore_simulator_bundle, 'LOCK_PATH',
                                   Path(tmp) / 'lock.json'):
                (Path(tmp) / 'lock.json').write_text(json.dumps(self.lock()))
                with self.assertRaises(restore_simulator_bundle.RestoreError):
                    restore_simulator_bundle.restore(
                        tarball, Path(tmp) / 'restored', provenance_path)

    def test_restore_rewrites_engine_manifest_for_destination(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tarball, provenance_path, _ = self.make_archive(
                tmp, self.lock(), with_engine_list=True)
            destination = Path(tmp) / 'restored'
            lock_path = Path(tmp) / 'lock.json'
            lock_path.write_text(json.dumps(self.lock()))
            with mock.patch.object(restore_simulator_bundle,
                                   'archive_simulator_facts',
                                   return_value=(True, {'simulatorOnly': True})), \
                 mock.patch.object(restore_simulator_bundle, 'LOCK_PATH',
                                   lock_path):
                report = restore_simulator_bundle.restore(
                    tarball, destination, provenance_path)
            rewritten = (destination / 'source/engine/workdir/CustomTarget/ios/'
                         'ios-all-static-libs.list').read_text().splitlines()
            self.assertEqual(rewritten, [
                str((destination / 'source/engine/libx.a').resolve()),
                str((destination / 'source/engine/liby.o').resolve()),
            ])
            rewrite = report['engineArchiveManifestRewrite']
            self.assertTrue(rewrite['present'])
            self.assertTrue(rewrite['pairingUsed'])
            self.assertEqual(rewrite['rewrittenRoot'], str(destination.resolve()))


class GeneratedScenarioTests(unittest.TestCase):
    def test_swift_scenario_tokens(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source'
            receipt = qualification_ui_test.generate(source)
            swift = Path(receipt['generated']).read_text()
            for token in ('Online Editor', 'Edit document', 'Insert Slide',
                          f'idleSeconds: TimeInterval = {sim_paths.IDLE_SECONDS}',
                          'FloeRealSimulatorQualification',
                          sim_paths.RECEIPT_ATTACHMENT_NAME,
                          'defer {', 'XCTAttachment', 'attachReceipt()',
                          'preview-close', 'reopen-before-edit', 'leave-edit',
                          'nativeSequence'):
                self.assertIn(token, swift)
            self.assertNotIn('try!', swift)
            self.assertNotIn('try?', swift)
            for phase in sim_paths.SCENARIO_PHASES:
                self.assertIn(f'"{phase}"', swift)


class ReuseWorkflowTests(unittest.TestCase):
    """Structural checks on the workflow's reuse and layout handling."""

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.text = WORKFLOW.read_text()

    def test_build_stage_skipped_on_reuse(self):
        build = str(self.workflow['jobs']['build-stage'].get('if', ''))
        self.assertIn('reuse_staged_run_id', build)

    def test_runtime_allows_skipped_build(self):
        runtime = self.workflow['jobs']['runtime']
        condition = str(runtime.get('if', ''))
        self.assertIn('!cancelled()', condition)
        self.assertIn('skipped', condition)
        self.assertEqual(runtime['needs'], 'build-stage')

    def test_flat_download_path_and_no_legacy_dir(self):
        runtime_steps = self.workflow['jobs']['runtime']['steps']
        checkout = next(
            step for step in runtime_steps
            if step.get('uses', '').startswith('actions/download-artifact'))
        self.assertTrue(checkout['with']['path'].endswith('/staged'))
        self.assertIn('run-id', checkout['with'])
        # The old workflow referenced a directory that gh never creates.
        self.assertNotIn('staged/office-real-sim-engine-bundle', self.text)

    def test_provenance_and_toolchain_binding_wired(self):
        runtime_steps = self.workflow['jobs']['runtime']['steps']
        restore = next(step for step in runtime_steps
                       if step.get('name', '').startswith('Restore'))
        self.assertIn('--provenance', restore['run'])
        self.assertIn('--reuse', restore['run'])
        self.assertIn('--expect-xcode', restore['run'])
        self.assertIn('--expect-sdk', restore['run'])

    def test_receipt_extraction_and_source_wired(self):
        runtime_steps = self.workflow['jobs']['runtime']['steps']
        extract = next(step for step in runtime_steps
                       if step.get('name', '').startswith('Extract the phase receipt'))
        self.assertIn('extract_receipt.py', extract['run'])
        persistence = next(step for step in runtime_steps
                           if step.get('name', '').startswith('Persistence gate'))
        self.assertIn('--receipt', persistence['run'])
        self.assertIn('--receipt-source', persistence['run'])

    def test_product_outputs_wired_to_workflow(self):
        runtime_steps = self.workflow['jobs']['runtime']['steps']
        discover = next(step for step in runtime_steps
                        if 'discover_products.py' in step.get('run', ''))
        self.assertEqual(discover.get('id'), 'products')
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'out.txt'
            discover_products._write_github_output(output, {
                'appPath': '/a/Mobile.app',
                'xctestrunPath': '/a/x.xctestrun',
                'runnerAppPath': '/a/Runner.app',
                'runnerBundleIdentifier': 'x.runner',
            })
            keys = {line.split('=')[0] for line in output.read_text().splitlines()}
        self.assertEqual(keys, {'app_path', 'xctestrun_path', 'runner_app_path',
                                'runner_bundle_id'})
        for key in keys:
            self.assertIn(f'steps.products.outputs.{key}', self.text)

    def test_simulator_selection_pipes_inventory_and_name(self):
        runtime_steps = self.workflow['jobs']['runtime']['steps']
        select = next(step for step in runtime_steps
                      if step.get('name', '').startswith('Select or create'))
        self.assertIn('simctl list devices -j', select['run'])
        self.assertIn('--name', select['run'])
        self.assertIn('--family iPad', select['run'])


class RenderGateTests(unittest.TestCase):
    def test_blank_and_marked_frames(self):
        from PIL import Image
        import check_render
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            blank = Image.new('RGB', (400, 300), (255, 255, 255))
            marked = Image.new('RGB', (400, 300), (255, 255, 255))
            for x in range(50, 150):
                for y in range(50, 80):
                    marked.putpixel((x, y), (29, 78, 216))
            names = {
                'Screenshot 01-preview.png': marked,
                'Screenshot 02-edit.png': marked,
                'Screenshot 03-idle-120s.png': marked,
                'Screenshot 04-reopen.png': marked,
            }
            for name, image in names.items():
                image.save(tmp / name)
            result = check_render.check_render(tmp)
            self.assertTrue(result['renderPassed'], result['failures'])

            blank.save(tmp / 'Screenshot 01-preview.png')
            result = check_render.check_render(tmp)
            self.assertFalse(result['renderPassed'])


def probe_payload(executable, lxml='5.4.0', polib='1.2.0', imports_ok=True,
                  import_error=None, prefix=None, base_prefix='/base/python',
                  pyvenv_cfg=True):
    if prefix is None:
        prefix = str(Path(executable).parent.parent)
    payload = {
        'executable': executable,
        'whichPython3': executable,
        'prefix': prefix,
        'basePrefix': base_prefix,
        'baseExecutable': base_prefix,
        'pyvenvCfg': pyvenv_cfg,
        'versions': {'lxml': lxml, 'polib': polib},
        'importsOk': imports_ok,
    }
    if import_error:
        payload['importError'] = import_error
    return json.dumps(payload)


class ChildPythonBindingTests(unittest.TestCase):
    """The child `python3` (the one configure actually invokes) is the venv."""

    def make_venv_bin(self, tmp):
        bin_dir = Path(tmp) / 'office-python/bin'
        bin_dir.mkdir(parents=True)
        python3 = bin_dir / 'python3'
        python3.write_text('#!/bin/sh\n')
        return bin_dir, str(python3.resolve())

    def test_child_path_selects_prepared_python(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, expected = self.make_venv_bin(tmp)
            seen = []

            def runner(command, env):
                seen.append((list(command), dict(env)))
                return 0, probe_payload(expected)

            report = build_simulator_engine.verify_child_python(
                bin_dir, runner=runner, base_env={'PATH': '/usr/bin'})
            self.assertTrue(report['passed'], report['failures'])
            self.assertEqual(report['configurePython3'], expected)
            self.assertEqual(report['lxmlVersion'], '5.4.0')
            self.assertEqual(report['polibVersion'], '1.2.0')
            for command, env in seen:
                first = env['PATH'].split(os.pathsep)[0]
                self.assertEqual(os.path.realpath(first),
                                 os.path.realpath(str(bin_dir)), env['PATH'])
                self.assertEqual(env['FLOE_OFFICE_PYTHON_BIN'],
                                 os.path.abspath(str(bin_dir)))
            self.assertTrue(any(command[:2] == ['/usr/bin/env', 'python3']
                                for command, _ in seen),
                            'the exact configure mechanism must be probed')

    def test_configure_resolving_elsewhere_fails(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, expected = self.make_venv_bin(tmp)

            def runner(command, env):
                if command[:2] == ['/usr/bin/env', 'python3']:
                    return 0, probe_payload('/usr/bin/python3')
                return 0, probe_payload(expected)

            report = build_simulator_engine.verify_child_python(
                bin_dir, runner=runner, base_env={'PATH': '/usr/bin'})
            self.assertFalse(report['passed'])
            self.assertIn('prepared venv bin', ' '.join(report['failures']))

    def test_same_resolved_executable_but_base_prefix_rejected(self):
        # The coordinator's review case: base and venv interpreters can share
        # a resolved executable (venv python is a symlink) while site-packages
        # differ; identity must come from sys.prefix/pyvenv.cfg, not realpath.
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, expected = self.make_venv_bin(tmp)

            def runner(command, env):
                return 0, probe_payload(expected, prefix='/base/python',
                                        base_prefix='/base/python',
                                        pyvenv_cfg=False)

            report = build_simulator_engine.verify_child_python(
                bin_dir, runner=runner, base_env={'PATH': '/usr/bin'})
            self.assertFalse(report['passed'])
            joined = ' '.join(report['failures'])
            self.assertIn('no pyvenv.cfg', joined)
            self.assertIn('base interpreter', joined)

    def test_prefix_mismatch_rejected(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, expected = self.make_venv_bin(tmp)

            def runner(command, env):
                return 0, probe_payload(expected, prefix='/somewhere/else')

            report = build_simulator_engine.verify_child_python(
                bin_dir, runner=runner, base_env={'PATH': '/usr/bin'})
            self.assertFalse(report['passed'])
            self.assertIn('sys.prefix', ' '.join(report['failures']))

    def test_missing_lxml_fails_before_build(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, expected = self.make_venv_bin(tmp)

            def runner(command, env):
                return 0, probe_payload(expected, imports_ok=False,
                                        import_error='ModuleNotFoundError: No module named lxml')

            report = build_simulator_engine.verify_child_python(
                bin_dir, runner=runner, base_env={'PATH': '/usr/bin'})
            self.assertFalse(report['passed'])
            self.assertIn('cannot import lxml/polib', ' '.join(report['failures']))

    def test_unpinned_version_fails(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir, expected = self.make_venv_bin(tmp)

            def runner(command, env):
                return 0, probe_payload(expected, lxml='5.3.0')

            report = build_simulator_engine.verify_child_python(
                bin_dir, runner=runner, base_env={'PATH': '/usr/bin'})
            self.assertFalse(report['passed'])
            self.assertIn('lxml version', ' '.join(report['failures']))

    def test_preflight_fails_closed_on_python_check(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'build'
            source = root / 'source'
            (source / 'engine').mkdir(parents=True)
            (source / 'engine/configure.ac').write_text('AC_INIT\n')
            with mock.patch.object(build_simulator_engine, 'sdk_info',
                                   return_value={'sdkPath': '/sdk',
                                                 'sdkVersion': '27.0',
                                                 'sdkBuildVersion': '24A430'}), \
                 mock.patch.object(build_simulator_engine, 'toolchain_info',
                                   return_value={'clang': 'c', 'xcodebuild': 'x',
                                                 'xcodeVersion': 'Xcode 27.0'}):
                report = build_simulator_engine.preflight(
                    root, source, python_bin='/venv/bin',
                    python_check={'passed': False,
                                  'failures': ['no lxml for python3']})
            self.assertFalse(report['preflightPassed'])
            self.assertFalse(report['pythonEnvironmentReady'])
            self.assertIn('no lxml for python3', report['pythonEnvironmentFailures'])


class RealVenvBindingTests(unittest.TestCase):
    """Real venv + real subprocesses: the symlinked venv bin must win.

    ``venv/bin/python`` is a symlink to the base interpreter, so a realpath
    based default_python_bin silently selects the base bin (the original
    review defect).  No network or heavy dependency: the venv gets controlled
    lxml/polib fixture packages with the pinned dist-info versions, and the
    probe runs exactly as the build driver runs it.
    """

    def make_fixture_venv(self, tmp):
        venv = Path(tmp) / 'venv'
        subprocess.run([sys.executable, '-m', 'venv', '--without-pip',
                        str(venv)], check=True)
        purelib = subprocess.run(
            [str(venv / 'bin/python'), '-c',
             "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
            check=True, capture_output=True, text=True).stdout.strip()
        for name, version in (('lxml', '5.4.0'), ('polib', '1.2.0')):
            package = Path(purelib) / name
            package.mkdir(parents=True)
            (package / '__init__.py').write_text(f"__version__ = '{version}'\n")
            dist = Path(purelib) / f'{name}-{version}.dist-info'
            dist.mkdir()
            (dist / 'METADATA').write_text(
                f'Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n')
        return venv

    def test_symlinked_venv_python_is_selected_and_verified(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as tmp:
            venv = self.make_fixture_venv(tmp)
            report = build_simulator_engine.verify_child_python(venv / 'bin')
            self.assertTrue(report['passed'], report['failures'])
            self.assertEqual(report['lxmlVersion'], '5.4.0')
            self.assertEqual(report['polibVersion'], '1.2.0')
            self.assertEqual(
                os.path.realpath(os.path.dirname(report['configurePython3'])),
                os.path.realpath(str(venv / 'bin')))

            script = (
                'import json, sys; sys.path.insert(0, %r); '
                'import build_simulator_engine as b; '
                'bin_dir = b.default_python_bin(); '
                'print(json.dumps({"default": bin_dir, '
                '"check": b.verify_child_python(bin_dir)}))'
                % str(PKG_DIR)
            )
            child = subprocess.run([str(venv / 'bin/python'), '-c', script],
                                   check=True, capture_output=True, text=True)
            payload = json.loads(child.stdout.strip().splitlines()[-1])
            self.assertEqual(os.path.realpath(payload['default']),
                             os.path.realpath(str(venv / 'bin')))
            self.assertNotEqual(os.path.realpath(payload['default']),
                                os.path.realpath(str(Path(sys.executable).parent)))
            self.assertTrue(payload['check']['passed'],
                            payload['check'].get('failures'))


class PhaseProgressTests(unittest.TestCase):
    def test_stagnant_log_and_own_process_tree_are_measured_separately(self):
        import build_simulator_engine
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'engine.log'
            log.write_text('unchanged')
            result = SimpleNamespace(returncode=0, stdout=(
                '100 1 0.0 S\n101 100 45.0 R\n102 101 55.0 R\n'
                '900 1 99.0 R\n'))
            with mock.patch.object(build_simulator_engine.subprocess, 'run',
                                   return_value=result):
                stagnant = build_simulator_engine.phase_progress(
                    'engine-build', 100, log, 120, log.stat().st_size)
                self.assertEqual(stagnant['logDeltaBytes'], 0)
                self.assertEqual(stagnant['processCount'], 3)
                self.assertEqual(stagnant['treeCPUPercent'], 100.0)
                log.write_text('unchanged plus new output')
                growth = build_simulator_engine.phase_progress(
                    'engine-build', 100, log, 180, stagnant['logBytes'])
                self.assertGreater(growth['logDeltaBytes'], 0)

    def test_failed_process_probe_is_unknown_not_zero(self):
        import build_simulator_engine
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'engine.log'
            log.write_text('output')
            with mock.patch.object(build_simulator_engine.subprocess, 'run',
                                   side_effect=OSError('unavailable')):
                snapshot = build_simulator_engine.phase_progress(
                    'engine-build', 100, log, 60, 0)
            self.assertIsNone(snapshot['treeCPUPercent'])
            self.assertIsNone(snapshot['processCount'])


class EngineManifestTests(unittest.TestCase):
    """The real pinned list format: absolute runner-root paths plus .o files."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        import engine_manifest
        self.module = engine_manifest
        engine = self.root / 'source/engine'
        engine.mkdir(parents=True)
        (engine / 'libsc.a').write_bytes(b'a')
        (engine / 'workdir/LinkTarget').mkdir(parents=True)
        (engine / 'workdir/LinkTarget/liboox.a').write_bytes(b'b')
        (engine / 'workdir/obj').mkdir(parents=True)
        (engine / 'workdir/obj/builtins.o').write_bytes(b'c')

    def test_canonicalize_absolute_and_engine_relative(self):
        lines = [
            str(self.root / 'source/engine/libsc.a'),
            'workdir/LinkTarget/liboox.a',
            str(self.root / 'source/engine/workdir/obj/builtins.o'),
        ]
        canonical = self.module.canonicalize(self.root, lines)
        self.assertEqual(canonical, [
            'source/engine/libsc.a',
            'source/engine/workdir/LinkTarget/liboox.a',
            'source/engine/workdir/obj/builtins.o',
        ])

    def test_canonicalize_rejects_outside_root(self):
        with self.assertRaises(self.module.ManifestError):
            self.module.canonicalize(self.root, ['/etc/hosts'])

    def test_canonicalize_rejects_missing_unsupported_and_empty(self):
        with self.assertRaises(self.module.ManifestError):
            self.module.canonicalize(self.root, ['/old/runner/libx.a'])
        dynamic = self.root / 'source/engine/libfoo.dylib'
        dynamic.write_bytes(b'd')
        with self.assertRaises(self.module.ManifestError):
            self.module.canonicalize(self.root, [str(dynamic)])
        with self.assertRaises(self.module.ManifestError):
            self.module.canonicalize(self.root, [])

    def test_rewrite_uses_linker_input_order_for_old_root(self):
        dest = self.root / 'dest'
        (dest / 'source/engine/workdir/obj').mkdir(parents=True)
        (dest / 'source/engine/libsc.a').write_bytes(b'a')
        (dest / 'source/engine/workdir/obj/builtins.o').write_bytes(b'c')
        raw = (b'/old/runner/work/_temp/floe-office-sim/source/engine/libsc.a\n'
               b'/old/runner/work/_temp/floe-office-sim/source/engine/workdir/'
               b'obj/builtins.o\n')
        rewritten, evidence = self.module.rewrite_for_destination(
            dest, raw,
            ['source/engine/libsc.a', 'source/engine/workdir/obj/builtins.o'])
        self.assertEqual(rewritten.decode().splitlines(), [
            str((dest / 'source/engine/libsc.a').resolve()),
            str((dest / 'source/engine/workdir/obj/builtins.o').resolve()),
        ])
        self.assertTrue(evidence['pairingUsed'])

    def test_rewrite_falls_back_to_resolution_and_fails_closed(self):
        dest = self.root / 'dest2'
        (dest / 'source/engine').mkdir(parents=True)
        (dest / 'source/engine/libsc.a').write_bytes(b'a')
        rewritten, evidence = self.module.rewrite_for_destination(
            dest, b'source/engine/libsc.a\n', None)
        self.assertEqual(rewritten.decode().strip(),
                         str((dest / 'source/engine/libsc.a').resolve()))
        self.assertFalse(evidence['pairingUsed'])
        with self.assertRaises(self.module.ManifestError):
            self.module.rewrite_for_destination(dest, b'/old/runner/libx.a\n', None)


class CoreCheckpointTests(unittest.TestCase):
    """Synthetic completed-core checkpoint contract; no real engine is built."""

    EXPECT_XCODE = 'Xcode 27.0\nBuild version 27A266a\n'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lock = {'commit': 'abc', 'sourcePatchSHA256': 'p',
                     'repository': 'repo', 'buildReserveGiB': 6,
                     'minimumFreeGiB': 12, 'platform': 'iphoneos-arm64'}
        self.lock_path = self.root / 'engine.lock.json'
        self.lock_path.write_text(json.dumps(self.lock))
        import checkpoint_simulator_core
        import resume_simulator_core
        self.checkpoint_module = checkpoint_simulator_core
        self.resume_module = resume_simulator_core
        patcher = mock.patch.object(checkpoint_simulator_core, 'LOCK_PATH',
                                    self.lock_path)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(resume_simulator_core, 'LOCK_PATH',
                                    self.lock_path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_runner(self, vtool=(0, '  platform IOSSIMULATOR\n'),
                    lipo=(0, 'arm64\n')):
        def run(command, cwd=None):
            command = list(command)
            if command[:2] == ['lipo', '-archs']:
                return lipo
            if command[:2] == ['ar', 'x'] and cwd:
                (Path(cwd) / 'a.o').write_bytes(b'fake')
                return 0, ''
            if command[0] == 'vtool':
                return vtool
            return 1, f'unexpected command {command}'
        return run

    def make_build_root(self, native_build_passed=False,
                        engine_build_completed=True, platform='iphonesimulator-arm64',
                        commit='abc'):
        root = self.root / f'build-{len(list(self.root.glob("build-*")))}'
        engine = root / 'source/engine'
        (engine / 'workdir/CustomTarget/ios').mkdir(parents=True)
        (engine / 'config_host').mkdir(parents=True)
        (engine / 'config_host/config_host.mk').write_text('# config\n')
        # Exact editor-configure inputs verified against the pinned
        # online.mirror configure.ac (CHK_FILE_VAR / setuprc / config_host.mk).
        (engine / 'config_host.mk').write_text('export ENABLE_DBGUTIL=\n')
        (engine / 'instdir/program').mkdir(parents=True)
        (engine / 'instdir/program/setuprc').write_text('[Version]\n')
        poco = engine / 'workdir/UnpackedTarball/poco/include/Poco'
        poco.mkdir(parents=True)
        (poco / 'Poco.h').write_text('// poco\n')
        zstd = engine / 'workdir/UnpackedTarball/zstd/lib'
        zstd.mkdir(parents=True)
        (zstd / 'zstd.h').write_text('// zstd\n')
        # The REAL upstream list mixes absolute runner-root paths (from
        # engine/bin/lo-all-static-libs) with engine-relative entries, and it
        # includes individual .o inputs as well as .a archives.
        absolute_archive = engine / 'workdir/LinkTarget/StaticLibrary/libsc.a'
        absolute_archive.parent.mkdir(parents=True, exist_ok=True)
        absolute_archive.write_bytes(b'archive-sc')
        (engine / 'workdir/LinkTarget/StaticLibrary/libPocoFoundation.a').write_bytes(b'poco')
        (engine / 'workdir/LinkTarget/StaticLibrary/libzstd.a').write_bytes(b'zstd')
        engine_relative = Path('workdir/LinkTarget/StaticLibrary/liboox.a')
        (engine / engine_relative).write_bytes(b'archive-oox')
        object_input = engine / ('workdir/UnpackedTarball/nss/nss/lib/'
                                 'ckfw/builtins/out/builtins.o')
        object_input.parent.mkdir(parents=True, exist_ok=True)
        object_input.write_bytes(b'object-builtins')
        manifest = engine / 'workdir/CustomTarget/ios/ios-all-static-libs.list'
        raw_lines = [
            str(absolute_archive),
            str(engine_relative),
            str(object_input),
        ]
        manifest.write_text('\n'.join(raw_lines) + '\n')
        # A portable relative symlink inside a packed subtree.
        (engine / 'workdir/UnpackedTarball/zlib').mkdir(parents=True)
        (engine / 'workdir/UnpackedTarball/zlib/zlib.h').write_text('/* z */\n')
        (engine / 'include').mkdir()
        (engine / 'include/zlib.h').symlink_to(
            '../workdir/UnpackedTarball/zlib/zlib.h')
        qualification = {
            'commit': commit,
            'platform': platform,
            'sdkVersion': '27.0',
            'sdkBuildVersion': '24A430',
            'xcodeVersion': 'Xcode 27.0; Build version 27A266a;',
            'engineBuildCompleted': engine_build_completed,
            'nativeBuildPassed': native_build_passed,
            'phases': {'engine-configure': {'seconds': 55.7},
                       'engine-build': {'seconds': 10512.9}},
            'stage': 'engine-build',
        }
        (root / 'qualification.json').write_text(json.dumps(qualification))
        return root

    def create(self, root):
        return self.checkpoint_module.create_checkpoint(
            root, root / 'core-checkpoint', runner=self.fake_runner())

    def make_prepared_destination(self, name='dest'):
        dest = self.root / name
        (dest / 'source/engine').mkdir(parents=True)
        (dest / 'source/engine/configure.ac').write_text('AC_INIT\n')
        return dest

    def test_cli_create_and_default_restore_use_real_tool_adapter(self):
        import contextlib
        import io
        import stage_simulator_engine
        from types import SimpleNamespace
        root = self.make_build_root()
        output = root / 'core-checkpoint'
        calls = []
        fake = self.fake_runner()

        # Keep the actual CLI -> default runner -> subprocess boundary. The
        # prior injected-runner tests hid run 36729016248's None callback.
        def subprocess_adapter(command, cwd=None, **kwargs):
            calls.append(list(command))
            code, text = fake(command, cwd=cwd)
            return SimpleNamespace(returncode=code, stdout=text, stderr='')

        with mock.patch.object(stage_simulator_engine.subprocess, 'run',
                               side_effect=subprocess_adapter), \
                mock.patch.object(sys, 'argv', ['checkpoint_simulator_core.py',
                                               str(root), '--output-dir', str(output)]), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.checkpoint_module.main()
            record = json.loads(stdout.getvalue())
            dest = self.make_prepared_destination('default-tools')
            self.resume_module.restore_checkpoint(
                output / sim_paths.CORE_CHECKPOINT_TAR,
                output / sim_paths.CORE_CHECKPOINT_JSON, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430')
        self.assertTrue(record['allSampledObjectsIOSSIMULATOR'])
        self.assertFalse(record['nativeBuildPassed'])
        self.assertTrue(any(command[0] == 'lipo' for command in calls))
        self.assertTrue(any(command[0] == 'ar' for command in calls))
        self.assertTrue(any(command[0] == 'vtool' for command in calls))

    def test_unverified_retention_does_not_follow_links_or_qualify(self):
        import retain_unverified_core
        from types import SimpleNamespace
        root = self.make_build_root()
        git = root / 'source/.git'
        git.mkdir()
        (git / 'config').write_text('excluded')
        outside = self.root / 'outside.txt'
        outside.write_text('synthetic unrelated data')
        (root / 'source/outside-link').symlink_to(outside)
        output = self.root / 'quarantine'
        with mock.patch.object(retain_unverified_core.shutil, 'disk_usage',
                               return_value=SimpleNamespace(free=20 * 1024**3)):
            record = retain_unverified_core.retain(root, output)
        self.assertFalse(record['reuseAllowed'])
        self.assertFalse(record['nativeBuildPassed'])
        self.assertFalse(record['finalQualification'])
        archive_path = output / 'unverified-core.tar.gz'
        with tarfile.open(archive_path) as archive:
            self.assertNotIn('source/.git/config', archive.getnames())
            self.assertTrue(archive.getmember('source/outside-link').issym())
            self.assertNotIn('outside.txt', archive.getnames())
            self.assertIn('source/engine/workdir/LinkTarget/StaticLibrary/libsc.a',
                          archive.getnames())
        self.assertEqual(hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                         record['archiveSHA256'])
        failures = self.resume_module.verify_checkpoint_record(
            archive_path, record, self.lock)
        self.assertTrue(any('checkpoint kind' in failure for failure in failures))

    def test_unverified_retention_refuses_incomplete_or_recursive_root(self):
        import retain_unverified_core
        root = self.make_build_root(engine_build_completed=False)
        with self.assertRaisesRegex(ValueError, 'no completed'):
            retain_unverified_core.retain(root, self.root / 'quarantine')
        root = self.make_build_root()
        with self.assertRaisesRegex(ValueError, 'outside the build root'):
            retain_unverified_core.retain(root, root / 'recursive-output')

    def test_create_and_restore_round_trip(self):
        root = self.make_build_root()
        raw_manifest = (root / 'source/engine/workdir/CustomTarget/ios/'
                        'ios-all-static-libs.list').read_bytes()
        record = self.create(root)
        self.assertEqual(record['checkpointKind'],
                         sim_paths.CORE_CHECKPOINT_KIND)
        self.assertTrue(record['engineBuildCompleted'])
        self.assertFalse(record['nativeBuildPassed'])
        self.assertFalse(record['finalQualification'])
        self.assertFalse(record['editorPhasesExecuted'])
        self.assertGreater(record['checkpointSize'], 0)
        self.assertEqual(record['nativeBuildPassed'], False)
        self.assertEqual(record['engineArchiveSuffixes'], ['.a', '.o'])
        self.assertEqual(record['engineArchiveManifestOriginalSHA256'],
                         hashlib.sha256(raw_manifest).hexdigest())
        self.assertNotEqual(record['engineArchiveManifestOriginalSHA256'],
                            record['engineArchiveManifestCanonicalSHA256'])
        self.assertIsNone(record['engineArchiveManifestRewrittenSHA256'])
        archive = root / 'core-checkpoint' / sim_paths.CORE_CHECKPOINT_TAR
        checkpoint = root / 'core-checkpoint' / sim_paths.CORE_CHECKPOINT_JSON
        self.assertTrue(archive.is_file())
        member_name = 'source/engine/workdir/CustomTarget/ios/ios-all-static-libs.list'
        with tarfile.open(archive) as tar:
            names = set(tar.getnames())
            self.assertIn(sim_paths.CORE_CHECKPOINT_MANIFEST, names)
            self.assertIn(sim_paths.CORE_CHECKPOINT_QUALIFICATION, names)
            self.assertIn(member_name, names)
            self.assertIn(member_name + '.original', names)
            self.assertIn('qualification.json', names)
            canonical = tar.extractfile(member_name).read()
            original = tar.extractfile(member_name + '.original').read()
        self.assertEqual(original, raw_manifest)
        self.assertTrue(canonical.endswith(b'\n'))
        canonical_lines = canonical.decode().splitlines()
        self.assertEqual(canonical_lines, [
            'source/engine/workdir/LinkTarget/StaticLibrary/libsc.a',
            'source/engine/workdir/LinkTarget/StaticLibrary/liboox.a',
            'source/engine/workdir/UnpackedTarball/nss/nss/lib/ckfw/'
            'builtins/out/builtins.o',
        ])
        self.assertNotIn(str(root).encode(), canonical)

        dest = self.make_prepared_destination()
        report = self.resume_module.restore_checkpoint(
            archive, checkpoint, dest,
            expect_xcode='Xcode 27.0\nBuild version 27A266a\n',
            expect_sdk='27.0', expect_sdk_build='24A430',
            runner=self.fake_runner())
        self.assertEqual(report['checkpointKind'],
                         sim_paths.CORE_CHECKPOINT_KIND)
        self.assertFalse(report['engineConfigureRerun'])
        self.assertFalse(report['engineBuildRerun'])
        self.assertTrue(report['editorPhasesOnly'])
        self.assertTrue(report['engineBuildCompleted'])
        self.assertEqual(report['resumePhases'], list(sim_paths.EDITOR_PHASES))
        self.assertTrue((dest / sim_paths.CORE_RESUME_REPORT).is_file())
        qualification = json.loads((dest / 'qualification.json').read_text())
        self.assertTrue(qualification['engineBuildCompleted'])
        self.assertFalse(qualification['nativeBuildPassed'])
        link = dest / 'source/engine/include/zlib.h'
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link),
                         '../workdir/UnpackedTarball/zlib/zlib.h')
        restored_list = (dest / 'source/engine/workdir/CustomTarget/ios/'
                         'ios-all-static-libs.list')
        rewritten_lines = restored_list.read_text().splitlines()
        self.assertTrue(all(Path(line).is_absolute() for line in rewritten_lines))
        for line in rewritten_lines:
            self.assertTrue(Path(line).exists(), line)
        self.assertEqual(
            report['engineArchiveManifestRewrittenSHA256'],
            hashlib.sha256(restored_list.read_bytes()).hexdigest())
        self.assertEqual(report['engineArchiveManifestOriginalSHA256'],
                         record['engineArchiveManifestOriginalSHA256'])
        self.assertEqual(report['engineArchiveManifestCanonicalSHA256'],
                         record['engineArchiveManifestCanonicalSHA256'])
        self.assertTrue(report['manifestRewritten'])
        self.assertEqual(report['sdkBuildVersion'], '24A430')
        self.assertEqual(report['expectSDKBuild'], '24A430')
        self.assertTrue(report['toolchainVerified'])
        self.assertTrue((dest / 'source/engine/workdir/UnpackedTarball/nss/nss/'
                         'lib/ckfw/builtins/out/builtins.o').is_file())
        self.assertEqual(
            (dest / 'source/engine/workdir/CustomTarget/ios/'
                   'ios-all-static-libs.list.original').read_bytes(),
            raw_manifest)
        loaded = self.resume_module.load_resume_report(dest)
        self.assertIsNotNone(loaded)
        self.assertFalse(loaded['engineBuildRerun'])
        self.assertTrue(loaded['manifestRewritten'])

    def test_optional_unbuilt_dependency_link_is_audited_in_checkpoint(self):
        root = self.make_build_root()
        optional = root / 'source/engine/workdir/UnpackedTarball/zxing/zint/backend'
        optional.parent.mkdir(parents=True)
        optional.symlink_to('../../zint/backend')
        record = self.create(root)
        self.assertEqual(len(record['omittedOptionalLinks']), 1)
        self.assertEqual(record['omittedOptionalLinks'][0]['path'],
                         str(optional.relative_to(root)))
        with tarfile.open(root / 'core-checkpoint' / sim_paths.CORE_CHECKPOINT_TAR) as archive:
            manifest = json.load(archive.extractfile(sim_paths.CORE_CHECKPOINT_MANIFEST))
            self.assertEqual(manifest['omittedOptionalLinks'], record['omittedOptionalLinks'])
            self.assertNotIn(str(optional.relative_to(root)), archive.getnames())

    def test_missing_header_link_cannot_be_omitted(self):
        root = self.make_build_root()
        header = root / 'source/engine/workdir/UnpackedTarball/zlib/missing.h'
        header.symlink_to('absent.h')
        with self.assertRaisesRegex(self.checkpoint_module.CheckpointError, 'required dependency'):
            self.create(root)

    def test_required_subtree_dangling_nonheader_link_cannot_be_omitted(self):
        root = self.make_build_root()
        link = root / 'source/engine/instdir/missing-resource'
        link.symlink_to('absent')
        with self.assertRaisesRegex(self.checkpoint_module.CheckpointError, 'required dependency'):
            self.create(root)

    def test_missing_header_target_without_header_link_suffix_still_fails(self):
        root = self.make_build_root()
        link = root / 'source/engine/workdir/UnpackedTarball/zlib/alias'
        link.symlink_to('absent.h')
        with self.assertRaisesRegex(self.checkpoint_module.CheckpointError, 'required dependency'):
            self.create(root)

    def test_optional_dangling_outside_link_still_fails(self):
        root = self.make_build_root()
        link = root / 'source/engine/workdir/UnpackedTarball/zlib/optional'
        link.symlink_to(self.root / 'missing-external')
        with self.assertRaisesRegex(self.checkpoint_module.CheckpointError, 'escapes'):
            self.create(root)

    def raw_recovery_fixture(self):
        import retain_unverified_core
        from types import SimpleNamespace
        root = self.make_build_root().resolve()
        path = root / 'qualification.json'
        q = json.loads(path.read_text())
        q['phases']['engine-build']['log'] = str(root / 'qualification-logs/engine-build.log')
        path.write_text(json.dumps(q))
        output = self.root / 'raw-backup'
        with mock.patch.object(retain_unverified_core.shutil, 'disk_usage',
                               return_value=SimpleNamespace(free=20 * 1024**3)), \
                mock.patch.dict(os.environ, {'GITHUB_RUN_ID': '123', 'GITHUB_SHA': 'reviewed-sha'}):
            record = retain_unverified_core.retain(root, output)
        shutil.rmtree(root)
        return root, output, record

    def recover_raw(self, root, output, record, **overrides):
        import recover_unverified_core
        from types import SimpleNamespace
        args = dict(expect_run='123', expect_source='reviewed-sha',
                    expect_sha=record['archiveSHA256'], expect_size=record['archiveSize'],
                    toolchain={'sdkVersion': '27.0', 'sdkBuildVersion': '24A430',
                               'xcodeVersion': 'Xcode 27.0; Build version 27A266a'},
                    runner=self.fake_runner())
        args.update(overrides)
        with mock.patch.object(recover_unverified_core, 'LOCK_PATH', self.lock_path), \
                mock.patch.object(recover_unverified_core.shutil, 'disk_usage',
                                  return_value=SimpleNamespace(free=20 * 1024**3)):
            return recover_unverified_core.recover(
                output / 'unverified-core.tar.gz', output / 'unverified-core.json',
                root, self.root / 'converted-checkpoint', **args)

    def test_reviewed_raw_conversion_passes_normal_checkpoint_and_restore(self):
        root, output, raw = self.raw_recovery_fixture()
        result = self.recover_raw(root, output, raw)
        self.assertFalse(result['engineBuildRerun'])
        self.assertFalse(result['nativeBuildPassed'])
        self.assertFalse(result['finalQualification'])
        checkpoint = self.root / 'converted-checkpoint'
        self.resume_module.restore_checkpoint(
            checkpoint / sim_paths.CORE_CHECKPOINT_TAR,
            checkpoint / sim_paths.CORE_CHECKPOINT_JSON,
            self.make_prepared_destination(), expect_xcode=self.EXPECT_XCODE,
            expect_sdk='27.0', expect_sdk_build='24A430', runner=self.fake_runner())

    def test_raw_conversion_rejects_source_run_hash_and_size_mismatch(self):
        root, output, raw = self.raw_recovery_fixture()
        for args in ({'expect_run': '456'}, {'expect_source': 'other'},
                     {'expect_sha': '0' * 64}, {'expect_size': 1}):
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, 'binding mismatch'):
                self.recover_raw(root, output, raw, **args)
        self.assertFalse(root.exists())

    def test_raw_conversion_rejects_toolchain_or_platform_mismatch(self):
        root, output, raw = self.raw_recovery_fixture()
        with self.assertRaisesRegex(ValueError, 'toolchain mismatch'):
            self.recover_raw(root, output, raw, toolchain={
                'sdkVersion': '27.0', 'sdkBuildVersion': 'different',
                'xcodeVersion': 'Xcode 27.0; Build version 27A266a'})
        with self.assertRaisesRegex(self.checkpoint_module.CheckpointError, 'platform/arch gate'):
            self.recover_raw(root, output, raw, runner=self.fake_runner(vtool=(0, 'platform IOS')))

    def test_raw_conversion_refuses_changed_tar_even_with_matching_record(self):
        root, output, raw = self.raw_recovery_fixture()
        with (output / 'unverified-core.tar.gz').open('ab') as stream:
            stream.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash/size mismatch'):
            self.recover_raw(root, output, raw)

    def test_raw_member_safety_rejects_duplicates_traversal_special_and_link_ancestors(self):
        import recover_unverified_core as recovery
        directory = tarfile.TarInfo('source')
        directory.type = tarfile.DIRTYPE
        regular = tarfile.TarInfo('source/file')
        symlink = tarfile.TarInfo('source/link')
        symlink.type = tarfile.SYMTYPE
        symlink.linkname = 'file'
        child = tarfile.TarInfo('source/link/child')
        special = tarfile.TarInfo('source/device')
        special.type = tarfile.CHRTYPE
        traversal = tarfile.TarInfo('source/../outside')
        for members in ([directory, regular, regular], [traversal], [special],
                        [directory, regular, symlink, child]):
            with self.subTest(members=members), self.assertRaises(ValueError):
                recovery.inspect_members(members, self.root)

    def test_raw_links_only_convert_contained_absolute_and_relative_targets(self):
        import recover_unverified_core as recovery
        link = tarfile.TarInfo('source/include/header.h')
        link.type = tarfile.SYMTYPE
        for target in ('../engine/header.h', str(self.root / 'source/engine/header.h')):
            link.linkname = target
            self.assertEqual(recovery.link_target(link, self.root), 'source/engine/header.h')
        for target in ('../../../escape', '/external/path',
                       str(self.root) + '/../external'):
            link.linkname = target
            with self.subTest(target=target), self.assertRaises(ValueError):
                recovery.link_target(link, self.root)

    def test_raw_missing_or_symlink_hardlink_target_refused(self):
        import recover_unverified_core as recovery
        link = tarfile.TarInfo('source/hardlink')
        link.type = tarfile.LNKTYPE
        link.linkname = 'source/missing'
        with self.assertRaisesRegex(ValueError, 'not a regular'):
            recovery.inspect_members([link], self.root)

    def test_create_refuses_final_qualification(self):
        root = self.make_build_root(native_build_passed=True)
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_before_engine_build_completed(self):
        root = self.make_build_root(engine_build_completed=False)
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_wrong_source_commit(self):
        root = self.make_build_root(commit='other')
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_wrong_platform(self):
        root = self.make_build_root(platform='iphoneos-arm64')
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_empty_engine_manifest(self):
        root = self.make_build_root()
        (root / 'source/engine/workdir/CustomTarget/ios/'
                'ios-all-static-libs.list').write_text('\n')
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_device_platform_sample(self):
        root = self.make_build_root()
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.checkpoint_module.create_checkpoint(
                root, root / 'core-checkpoint',
                runner=self.fake_runner(vtool=(0, '  platform IOS\n')))

    def _append_manifest_line(self, root, line):
        manifest = (root / 'source/engine/workdir/CustomTarget/ios/'
                    'ios-all-static-libs.list')
        manifest.write_text(manifest.read_text() + line + '\n')

    def test_create_refuses_entry_outside_build_root(self):
        root = self.make_build_root()
        self._append_manifest_line(root, '/etc/hosts')
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_missing_entry(self):
        root = self.make_build_root()
        self._append_manifest_line(root, '/nonexistent/runner/source/engine/libx.a')
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_unsupported_suffix(self):
        root = self.make_build_root()
        dynamic = root / 'source/engine/libfoo.dylib'
        dynamic.write_bytes(b'dylib')
        self._append_manifest_line(root, str(dynamic))
        with self.assertRaises(self.checkpoint_module.CheckpointError):
            self.create(root)

    def test_create_refuses_missing_editor_configure_input(self):
        root = self.make_build_root()
        (root / 'source/engine/config_host.mk').unlink()
        with self.assertRaises(self.checkpoint_module.CheckpointError) as ctx:
            self.create(root)
        self.assertIn('editor-configure inputs', str(ctx.exception))

    def _record_and_archive(self):
        root = self.make_build_root()
        self.create(root)
        checkpoint_path = root / 'core-checkpoint' / sim_paths.CORE_CHECKPOINT_JSON
        return (root / 'core-checkpoint' / sim_paths.CORE_CHECKPOINT_TAR,
                checkpoint_path, json.loads(checkpoint_path.read_text()))

    def test_restore_rejects_hash_mismatch(self):
        archive, checkpoint_path, _ = self._record_and_archive()
        with archive.open('ab') as stream:
            stream.write(b'tamper')
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())

    def test_restore_rejects_manifest_hash_mismatch(self):
        archive, checkpoint_path, record = self._record_and_archive()
        record['coreManifestSHA256'] = '0' * 64
        checkpoint_path.write_text(json.dumps(record))
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())

    def test_restore_rejects_canonical_manifest_hash_mismatch(self):
        archive, checkpoint_path, record = self._record_and_archive()
        record['engineArchiveManifestCanonicalSHA256'] = '0' * 64
        checkpoint_path.write_text(json.dumps(record))
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())

    def test_restore_rejects_tampered_member(self):
        import io
        archive, checkpoint_path, record = self._record_and_archive()
        tampered = archive.with_suffix('.tampered')
        target = 'source/engine/config_host/config_host.mk'
        with tarfile.open(archive) as source_tar, \
                tarfile.open(tampered, 'w:gz') as target_tar:
            for member in source_tar.getmembers():
                if member.name == target:
                    data = b'# replaced\n'
                    member.size = len(data)
                    target_tar.addfile(member, io.BytesIO(data))
                elif member.isfile():
                    target_tar.addfile(member, source_tar.extractfile(member))
                else:
                    target_tar.addfile(member)
        tampered.replace(archive)
        record['checkpointSHA256'] = self.resume_module.artifact_sha256(archive)
        record['checkpointSize'] = archive.stat().st_size
        checkpoint_path.write_text(json.dumps(record))
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError) as ctx:
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())
        self.assertIn('hash/size mismatch', str(ctx.exception))

    def test_restore_rejects_wrong_source_commit(self):
        archive, checkpoint_path, record = self._record_and_archive()
        record['sourceCommit'] = 'evil'
        checkpoint_path.write_text(json.dumps(record))
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())

    def test_restore_rejects_wrong_platform_and_arch(self):
        for override in ({'platform': 'iphoneos'}, {'arch': 'x86_64'},
                         {'checkpointKind': 'staged-engine'},
                         {'nativeBuildPassed': True},
                         {'finalQualification': True},
                         {'editorPhasesExecuted': True},
                         {'engineBuildCompleted': False}):
            archive, checkpoint_path, record = self._record_and_archive()
            record.update(override)
            checkpoint_path.write_text(json.dumps(record))
            dest = self.make_prepared_destination('dest-' + list(override)[0])
            with self.assertRaises(self.resume_module.CheckpointError, msg=override):
                self.resume_module.restore_checkpoint(
                    archive, checkpoint_path, dest,
                    expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                    expect_sdk_build='24A430',
                    runner=self.fake_runner())

    def test_restore_rejects_wrong_runner_toolchain(self):
        archive, checkpoint_path, _ = self._record_and_archive()
        cases = (
            ('Xcode 27.0\nBuild version 27A266a\n', '27.0', '26A999'),  # same SDK
            ('Xcode 99.0\nBuild version 27A266a\n', '27.0', '24A430'),
            ('Xcode 27.0\nBuild version 27A266a\n', '26.0', '24A430'),
        )
        for xcode, sdk, sdk_build in cases:
            dest = self.make_prepared_destination(
                ('dest-' + xcode + '-' + sdk + '-' + sdk_build).replace(' ', ''))
            with self.assertRaises(self.resume_module.CheckpointError, msg=(xcode, sdk, sdk_build)):
                self.resume_module.restore_checkpoint(
                    archive, checkpoint_path, dest,
                    expect_xcode=xcode, expect_sdk=sdk,
                    expect_sdk_build=sdk_build,
                    runner=self.fake_runner())

    def test_restore_rejects_same_sdk_version_different_build(self):
        # The coordinator's review case: equal SDK version is not toolchain
        # identity; the actual SDK build must match.
        archive, checkpoint_path, record = self._record_and_archive()
        record['sdkBuildVersion'] = '24A430'
        checkpoint_path.write_text(json.dumps(record))
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError) as ctx:
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='25B111', runner=self.fake_runner())
        self.assertIn('SDK build', str(ctx.exception))

    def test_restore_refuses_existing_engine_outputs(self):
        archive, checkpoint_path, _ = self._record_and_archive()
        dest = self.make_prepared_destination()
        (dest / 'source/engine/workdir/CustomTarget/ios').mkdir(parents=True)
        (dest / 'source/engine/workdir/CustomTarget/ios/'
                'ios-all-static-libs.list').write_text('x\n')
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())

    def test_restore_refuses_partial_qualification(self):
        archive, checkpoint_path, _ = self._record_and_archive()
        dest = self.make_prepared_destination()
        (dest / 'qualification.json').write_text('{}')
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())

    def test_tar_member_validation(self):
        import io
        evil = self.root / 'evil.tar'
        with tarfile.open(evil, 'w:gz') as archive:
            for name, link, kind in (('../escape', None, 'file'),
                                     ('/abs/path', None, 'file'),
                                     ('safe/dir', '/etc', 'symlink'),
                                     ('safe/dir2', '../../outside', 'symlink')):
                info = tarfile.TarInfo(name)
                if kind == 'file':
                    info.size = 1
                    archive.addfile(info, io.BytesIO(b'x'))
                else:
                    info.type = tarfile.SYMTYPE
                    info.linkname = link
                    archive.addfile(info)
        with tarfile.open(evil) as archive:
            failures = self.resume_module.validate_tar_members(
                archive.getmembers(), self.root / 'dest')
        self.assertEqual(len(failures), 4, failures)

    def test_restore_rejects_escaping_archive(self):
        import io
        archive, checkpoint_path, record = self._record_and_archive()
        evil = archive.with_suffix('.evil')
        with tarfile.open(archive) as source_tar, \
                tarfile.open(evil, 'w:gz') as target_tar:
            for member in source_tar.getmembers():
                if member.name == 'source/engine/include/zlib.h' and member.issym():
                    member.linkname = '../../../../outside'
                target_tar.addfile(
                    member,
                    source_tar.extractfile(member) if member.isfile() else None)
        evil.replace(archive)
        record['checkpointSHA256'] = self.resume_module.artifact_sha256(archive)
        record['checkpointSize'] = archive.stat().st_size
        checkpoint_path.write_text(json.dumps(record))
        dest = self.make_prepared_destination()
        with self.assertRaises(self.resume_module.CheckpointError):
            self.resume_module.restore_checkpoint(
                archive, checkpoint_path, dest,
                expect_xcode=self.EXPECT_XCODE, expect_sdk='27.0',
                expect_sdk_build='24A430',
                runner=self.fake_runner())


class CoreResumePlanTests(unittest.TestCase):
    """A resumed build never plans engine phases, even for --phases all."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lock = {'commit': 'abc', 'sourcePatchSHA256': 'p',
                     'repository': 'repo'}
        self.lock_path = self.root / 'engine.lock.json'
        self.lock_path.write_text(json.dumps(self.lock))
        import build_simulator_engine
        import resume_simulator_core
        self.module = build_simulator_engine
        self.resume_module = resume_simulator_core
        patcher = mock.patch.object(resume_simulator_core, 'LOCK_PATH',
                                    self.lock_path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def make_resumed_root(self):
        root = self.root / 'resumed'
        source = root / 'source'
        (source / 'engine').mkdir(parents=True)
        (source / 'engine/configure.ac').write_text('AC_INIT\n')
        manifest = source / 'engine/workdir/CustomTarget/ios'
        manifest.mkdir(parents=True)
        (source / 'engine/libx.a').write_bytes(b'x')
        # The resumed root retains the exact editor-configure inputs.
        (source / 'engine/config_host.mk').write_text('export ENABLE_DBGUTIL=\n')
        (source / 'engine/instdir/program').mkdir(parents=True)
        (source / 'engine/instdir/program/setuprc').write_text('[Version]\n')
        (source / 'engine/workdir/UnpackedTarball/poco/include/Poco').mkdir(
            parents=True)
        (source / 'engine/workdir/UnpackedTarball/poco/include/Poco/'
                'Poco.h').write_text('// poco\n')
        (source / 'engine/workdir/UnpackedTarball/zstd/lib').mkdir(parents=True)
        (source / 'engine/workdir/UnpackedTarball/zstd/lib/zstd.h').write_text(
            '// zstd\n')
        (source / 'engine/workdir/LinkTarget/StaticLibrary').mkdir(parents=True)
        (source / 'engine/workdir/LinkTarget/StaticLibrary/'
                'libPocoFoundation.a').write_bytes(b'poco')
        (source / 'engine/workdir/LinkTarget/StaticLibrary/'
                'libzstd.a').write_bytes(b'zstd')
        # The resumed root carries the destination-absolute (rewritten) list.
        (manifest / 'ios-all-static-libs.list').write_text(
            str((source / 'engine/libx.a').resolve()) + '\n')
        subprocess.run(['git', 'init', '-q', str(source)], check=True)
        subprocess.run(['git', '-C', str(source), 'config', 'user.email',
                        'test@example.com'], check=True)
        subprocess.run(['git', '-C', str(source), 'config', 'user.name',
                        'Test'], check=True)
        subprocess.run(['git', '-C', str(source), 'commit', '-q',
                        '--allow-empty', '-m', 'prepared'], check=True)
        manifest_bytes = (manifest / 'ios-all-static-libs.list').read_bytes()
        report = {
            'checkpointKind': sim_paths.CORE_CHECKPOINT_KIND,
            'checkpointSHA256': 'sha',
            'sourceCommit': 'abc',
            'platform': 'iphonesimulator',
            'arch': 'arm64',
            'engineConfigureRerun': False,
            'engineBuildRerun': False,
            'editorPhasesOnly': True,
            'toolchainVerified': True,
            'coreManifestVerified': True,
            'engineBuildCompleted': True,
            'manifestRewritten': True,
            'engineArchiveManifestRewrittenSHA256':
                hashlib.sha256(manifest_bytes).hexdigest(),
        }
        (root / sim_paths.CORE_RESUME_REPORT).write_text(json.dumps(report))
        (root / 'qualification.json').write_text(json.dumps({
            'commit': 'abc', 'platform': 'iphonesimulator-arm64',
            'engineBuildCompleted': True, 'nativeBuildPassed': False,
            'phases': {'engine-configure': {'seconds': 1},
                       'engine-build': {'seconds': 2}},
        }))
        return root

    def test_resume_plan_excludes_engine_phases(self):
        resume = {'checkpointKind': sim_paths.CORE_CHECKPOINT_KIND}
        self.assertEqual(self.module.resume_phase_plan(resume),
                         list(sim_paths.EDITOR_PHASES))
        self.assertEqual(self.module.resume_phase_plan(None), None)

    def test_build_with_resume_never_runs_engine_phases(self):
        root = self.make_resumed_root()
        recorded = []

        def fake_phase_runner(name, cwd, command, qualification_path, log_dir,
                              env):
            recorded.append(name)

        with mock.patch.object(self.module, 'verify_child_python',
                               return_value={'passed': True,
                                             'failures': [],
                                             'pythonBin': '/venv/bin'}), \
             mock.patch.object(self.module, 'REQUIRED_TOOLS', ()), \
             mock.patch.object(self.module, 'sdk_info',
                               return_value={'sdkPath': '/sdk',
                                             'sdkVersion': '27.0',
                                             'sdkBuildVersion': '24A430'}), \
             mock.patch.object(self.module, 'toolchain_info',
                               return_value={'clang': 'c',
                                             'xcodebuild': 'x',
                                             'xcodeVersion': 'Xcode 27.0'}):
            report = self.module.build(root, mode='all',
                                       phase_runner=fake_phase_runner)
        self.assertEqual(recorded, list(sim_paths.EDITOR_PHASES))
        self.assertFalse(report['enginePhasesRerun'])
        self.assertEqual(report['phasePlan'], list(sim_paths.EDITOR_PHASES))
        self.assertTrue(report['resumedFromCheckpoint']['engineBuildRerun']
                        is False)

    def test_fresh_all_checks_editor_inputs_after_engine_build(self):
        from contextlib import ExitStack
        root = self.make_resumed_root()
        (root / sim_paths.CORE_RESUME_REPORT).unlink()
        (root / 'qualification.json').unlink()
        for relative in sim_paths.EDITOR_CONFIGURE_INPUTS:
            (root / relative).unlink()
        recorded = []

        def fake_phase_runner(name, cwd, command, qualification_path, log_dir,
                              env):
            recorded.append(name)
            if name == 'engine-build':
                for relative in sim_paths.EDITOR_CONFIGURE_INPUTS:
                    (root / relative).write_bytes(b'generated by engine build')
            if name == 'editor-autogen':
                self.assertTrue(all((root / relative).is_file()
                                    for relative in sim_paths.EDITOR_CONFIGURE_INPUTS))

        with ExitStack() as patches:
            patches.enter_context(mock.patch.object(
                self.module, 'verify_child_python',
                return_value={'passed': True, 'failures': [],
                              'pythonBin': '/venv/bin'}))
            patches.enter_context(mock.patch.object(self.module, 'REQUIRED_TOOLS', ()))
            patches.enter_context(mock.patch.object(
                self.module, 'sdk_info', return_value={'sdkPath': '/sdk',
                    'sdkVersion': '27.0', 'sdkBuildVersion': '24A430'}))
            patches.enter_context(mock.patch.object(
                self.module, 'toolchain_info', return_value={'xcodeVersion': 'Xcode 27.0'}))
            report = self.module.build(root, mode='all', phase_runner=fake_phase_runner)
        self.assertEqual(recorded, list(sim_paths.ENGINE_PHASES + sim_paths.EDITOR_PHASES))
        self.assertTrue(report['engineBuildCompleted'])
        self.assertTrue(report['nativeBuildPassed'])

    def test_editor_mode_without_core_refuses(self):
        root = self.root / 'no-core'
        source = root / 'source'
        (source / 'engine').mkdir(parents=True)
        (source / 'engine/configure.ac').write_text('AC_INIT\n')
        subprocess.run(['git', 'init', '-q', str(source)], check=True)
        subprocess.run(['git', '-C', str(source), 'config', 'user.email',
                        'test@example.com'], check=True)
        subprocess.run(['git', '-C', str(source), 'config', 'user.name',
                        'Test'], check=True)
        subprocess.run(['git', '-C', str(source), 'commit', '-q',
                        '--allow-empty', '-m', 'prepared'], check=True)
        with mock.patch.object(self.module, 'verify_child_python',
                               return_value={'passed': True,
                                             'failures': [],
                                             'pythonBin': '/venv/bin'}), \
             mock.patch.object(self.module, 'REQUIRED_TOOLS', ()), \
             mock.patch.object(self.module, 'sdk_info',
                               return_value={'sdkPath': '/sdk',
                                             'sdkVersion': '27.0',
                                             'sdkBuildVersion': '24A430'}), \
             mock.patch.object(self.module, 'toolchain_info',
                               return_value={'clang': 'c',
                                             'xcodebuild': 'x',
                                             'xcodeVersion': 'Xcode 27.0'}):
            with self.assertRaises(RuntimeError):
                self.module.build(root, mode='editor',
                                  phase_runner=lambda *args: None)


class CheckpointWorkflowContractTests(unittest.TestCase):
    """The workflow must preserve the core before editor configure can fail."""

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.text = WORKFLOW.read_text()
        cls.steps = cls.workflow['jobs']['build-stage']['steps']
        cls.names = [step.get('name', '') for step in cls.steps]

    def step_index(self, name):
        return self.names.index(name)

    def test_resume_core_input_declared(self):
        inputs = self.workflow[True]['workflow_dispatch']['inputs']
        self.assertIn('resume_core_run_id', inputs)

    def test_venv_on_github_path(self):
        helpers = next(step for step in self.steps
                       if step.get('name') == 'Python build helpers')
        self.assertIn('GITHUB_PATH', helpers['run'])

    def test_cheap_preflight_before_engine_build(self):
        preflight_index = self.step_index(
            'Cheap dependency preflight before the heavy core build')
        engine_index = self.step_index(
            'Build the REAL engine core for iphonesimulator (disk-reserve watchdog)')
        self.assertLess(preflight_index, engine_index)
        self.assertIn('--preflight-only', self.steps[preflight_index]['run'])
        self.assertIn('--python-bin', self.steps[preflight_index]['run'])

    def test_unverified_fallback_preserves_data_without_unlocking_editor(self):
        retain = self.steps[self.step_index(
            'Quarantine completed core if checkpoint retention failed')]
        upload = self.steps[self.step_index(
            'Preserve unverified core for manual recovery only')]
        self.assertIn("steps.engine.outcome == 'success'", retain['if'])
        self.assertIn("steps.checkpoint.outcome != 'success'", retain['if'])
        self.assertIn("steps.preserve_checkpoint.outcome != 'success'", retain['if'])
        self.assertIn('!cancelled()', retain['if'])
        self.assertIn('retain_unverified_core.py', retain['run'])
        self.assertEqual(upload['with']['name'],
                         'office-real-simulator-unverified-core')
        editor = self.steps[self.step_index(
            'Build the editor/browser from the completed core')]
        self.assertNotIn('retain_raw_core', editor['if'])

    def test_default_checkpoint_cli_tools_checked_before_expensive_build(self):
        index = self.step_index(
            'Verify real checkpoint CLI and platform tools before the core')
        self.assertLess(index, self.step_index(
            'Build the REAL engine core for iphonesimulator (disk-reserve watchdog)'))
        self.assertIn('verify_checkpoint_tools.py', self.steps[index]['run'])
        self.assertIn('checkpoint-tool-preflight.json', self.steps[index]['run'])

    def test_checkpoint_created_and_uploaded_before_editor(self):
        checkpoint_index = self.step_index(
            'Create the completed-core checkpoint before editor phases')
        upload_index = self.step_index(
            'Preserve the completed-core checkpoint as an artifact')
        editor_index = self.step_index(
            'Build the editor/browser from the completed core')
        self.assertLess(self.step_index(
            'Build the REAL engine core for iphonesimulator (disk-reserve watchdog)'),
            checkpoint_index)
        self.assertLess(checkpoint_index, editor_index)
        self.assertLess(upload_index, editor_index)
        checkpoint_step = self.steps[checkpoint_index]
        self.assertIn('checkpoint_simulator_core.py', checkpoint_step['run'])
        upload = self.steps[upload_index]
        self.assertEqual(upload['with']['name'],
                         sim_paths.CORE_CHECKPOINT_ARTIFACT)
        self.assertEqual(upload['with']['if-no-files-found'], 'error')
        self.assertEqual(upload.get('id'), 'preserve_checkpoint')

    def test_engine_step_split_from_editor_step(self):
        engine_step = self.steps[self.step_index(
            'Build the REAL engine core for iphonesimulator (disk-reserve watchdog)')]
        editor_step = self.steps[self.step_index(
            'Build the editor/browser from the completed core')]
        self.assertIn('--phases engine', engine_step['run'])
        self.assertIn('--phases editor', editor_step['run'])
        # The editor must run after either a preserved fresh checkpoint or a
        # validated restore.
        condition = str(editor_step['if'])
        self.assertIn('steps.engine.outcome', condition)
        self.assertIn('steps.checkpoint.outcome', condition)
        self.assertIn('steps.preserve_checkpoint.outcome', condition)
        self.assertIn('steps.restore_core.outcome', condition)

    def editor_runs(self, engine, checkpoint, upload, restore, cancelled=False):
        """Evaluate the real editor `if` expression with step outcomes."""
        editor = self.steps[self.step_index(
            'Build the editor/browser from the completed core')]
        expression = str(editor['if']).strip()
        self.assertTrue(expression.startswith('${{') and expression.endswith('}}'),
                        expression)
        body = expression[3:-2].strip()
        for step_id, value in (('engine', engine), ('checkpoint', checkpoint),
                               ('preserve_checkpoint', upload),
                               ('restore_core', restore)):
            body = body.replace(f"steps.{step_id}.outcome == 'success'",
                                str(bool(value)))
        body = body.replace('!cancelled()', str(not cancelled))
        body = body.replace('&&', ' and ').replace('||', ' or ')
        return bool(eval(body))  # noqa: S307 - test-only, our own literal

    def test_editor_blocked_when_checkpoint_or_upload_fails(self):
        editor_step = self.steps[self.step_index(
            'Build the editor/browser from the completed core')]
        condition = str(editor_step['if'])
        # No success()/always() bypass, and each fresh-core prerequisite is an
        # explicit success conjunction so a failed checkpoint creation or a
        # failed artifact upload skips the editor.
        self.assertNotIn('always()', condition)
        self.assertIn("steps.engine.outcome == 'success'", condition)
        self.assertIn("steps.checkpoint.outcome == 'success'", condition)
        self.assertIn("steps.preserve_checkpoint.outcome == 'success'", condition)
        # Truth table: a failed checkpoint creation or a failed checkpoint
        # artifact upload must not let the editor proceed.
        self.assertFalse(self.editor_runs(True, False, False, False))
        self.assertFalse(self.editor_runs(True, True, False, False))
        self.assertFalse(self.editor_runs(True, False, True, False))
        self.assertFalse(self.editor_runs(False, False, False, False))
        self.assertFalse(self.editor_runs(True, True, True, False, cancelled=True))
        self.assertTrue(self.editor_runs(True, True, True, False))
        # A validated restore (resume path) is the only other entry point.
        self.assertTrue(self.editor_runs(False, False, False, True))
        self.assertFalse(self.editor_runs(False, False, False, False))

    def test_wget_provisioned_before_preflight(self):
        brew_step = next(step for step in self.steps
                         if step.get('name') == 'Prepare native build toolchain')
        self.assertIn('wget', brew_step['run'])
        self.assertLess(self.names.index('Prepare native build toolchain'),
                        self.names.index(
                            'Cheap dependency preflight before the heavy core build'))

    def test_resume_download_and_restore_wired(self):
        download = next(step for step in self.steps
                        if step.get('name', '').startswith('Download the completed-core'))
        self.assertEqual(download['with']['name'],
                         sim_paths.CORE_CHECKPOINT_ARTIFACT)
        self.assertIn('resume_core_run_id', download['if'])
        restore = next(step for step in self.steps
                       if step.get('name', '').startswith('Restore the completed core'))
        self.assertIn('resume_simulator_core.py', restore['run'])
        self.assertIn('--expect-xcode', restore['run'])
        self.assertIn('--expect-sdk', restore['run'])
        # SDK build identity, not just the version.
        self.assertIn('--expect-sdk-build', restore['run'])
        self.assertIn('--show-sdk-build-version', restore['run'])
        self.assertIn('resume_core_run_id', restore['if'])

    def test_checkpoint_artifact_not_reused_for_staged_engine(self):
        # The recovery checkpoint is a separate deliverable; the runtime still
        # consumes only the final staged engine artifact.
        runtime_steps = self.workflow['jobs']['runtime']['steps']
        download = next(step for step in runtime_steps
                        if step.get('uses', '').startswith('actions/download-artifact'))
        self.assertEqual(download['with']['name'],
                         'office-real-simulator-engine')


if __name__ == '__main__':
    unittest.main(verbosity=2)
