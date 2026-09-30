#!/usr/bin/env python3
"""Lightweight, network-free checks for the real simulator qualification.

Run: python3 -m unittest discover -s scripts/office_real_simulator/tests
or:  python3 scripts/office_real_simulator/tests/test_office_real_simulator.py

These validate pinned inputs and local logic only; they never execute a build
and must not claim a simulator result.
"""
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
                     manifest_overrides=None, with_symlink=False):
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
