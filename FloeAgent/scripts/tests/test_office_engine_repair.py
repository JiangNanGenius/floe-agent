#!/usr/bin/env python3
"""Regression and fail-closed negative tests for the engine archive repair.

Everything here is synthetic: a tiny git source checkout, a hand-built BSD ar
archive with a ``__.SYMDEF`` table and a fake ``virdev.o`` member, and a
fixture engine.patch.lock.json.  The compiles are mocked to return fixed
bytes, so the suite exercises the producer's gates (identity, toolchain,
layout, single-member replacement, manifest binding, receipt contract) without
a multi-GB engine or Xcode runs.  The tracked production values themselves are
validated separately by the local qualification runs recorded in
Local/Private/build241/ppt-production.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

import office_engine_repair as repair  # noqa: E402


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


ORIGINAL_SOURCE = b'// pinned fake engine source\nint floe_repair_probe() { return 1; }\n'
PATCHED_SOURCE = b'// pinned fake engine source\nint floe_repair_probe() { return 2; }\n'

FAKE_PATCH = b"""--- a/engine/vcl/source/gdi/virdev.cxx
+++ b/engine/vcl/source/gdi/virdev.cxx
@@ -1,2 +1,2 @@
 // pinned fake engine source
-int floe_repair_probe() { return 1; }
+int floe_repair_probe() { return 2; }
"""


class SyntheticBundle:
    """A repairable bundle: git source + ar archive + manifest."""

    def __init__(self, root: Path):
        self.root = root
        self.source = root / 'engine-src'
        self.bundle = root / 'bundle'
        self.lock = root / 'engine.patch.lock.json'
        self.patch = root / 'patches/fake-repair.patch'
        self.sim_run_id = '36792170654'
        self.sim_artifact_sha = sha256(b'fake-staged-engine-tarball')
        self.extra_bytes = b'extra verified input file\n'
        self._build()

    def _git(self, *args):
        subprocess.run(['git', '-C', str(self.source), *args],
                       check=True, capture_output=True)

    def _build(self):
        src_file = 'engine/vcl/source/gdi/virdev.cxx'
        (self.source / 'engine/vcl/source/gdi').mkdir(parents=True)
        (self.source / 'engine/include/fake').mkdir(parents=True)
        (self.source / src_file).write_bytes(ORIGINAL_SOURCE)
        self._git('init', '-q')
        self._git('add', '-A')
        self._git('-c', 'user.email=t@example.com', '-c', 'user.name=t',
                  'commit', '-q', '-m', 'pinned')
        self.commit = subprocess.check_output(
            ['git', '-C', str(self.source), 'rev-parse', 'HEAD'],
            text=True).strip()

        self.patch.parent.mkdir(parents=True)
        self.patch.write_bytes(FAKE_PATCH)

        program = self.bundle / 'source/engine/instdir/program'
        program.mkdir(parents=True)
        self.archive = program / 'libvcllo.a'
        # cctools ar drops members that are not real mach-o objects, so the
        # fixture compiles tiny genuine objects (fast, hermetic otherwise).
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            sources = {
                'alpha.c': 'int floe_alpha(void){return 1;}\n',
                'virdev.c': 'int floe_repair_probe(void){return 1;}\n',
                'omega.c': 'int floe_omega(void){return 2;}\n',
            }
            for name, code in sources.items():
                (tmp / name).write_text(code)
                subprocess.run(['cc', '-c', str(tmp / name), '-o',
                                str(tmp / (Path(name).stem + '.o'))],
                               check=True, capture_output=True)
            subprocess.run(['ar', '-rc', str(self.archive),
                            str(tmp / 'alpha.o'), str(tmp / 'virdev.o'),
                            str(tmp / 'omega.o')], check=True, capture_output=True)
            subprocess.run(['ranlib', str(self.archive)], check=True,
                           capture_output=True)
            patched_source = tmp / 'virdev_patched.c'
            patched_source.write_text(
                'int floe_repair_probe(void){return 2;}\n')
            patched_object_path = tmp / 'virdev_patched.o'
            subprocess.run(['cc', '-c', str(patched_source), '-o',
                            str(patched_object_path)],
                           check=True, capture_output=True)
            self.patched_object = patched_object_path.read_bytes()
        members_list = repair.read_ar_members(self.archive)
        self.member = next(m for m in members_list if m.name == 'virdev.o')
        self.symdef = members_list[0]
        self.order = [m.name for m in members_list]
        original_member = repair.read_member(self.archive, self.member)
        self.member_mtime = self.member.mtime

        self.lock.write_text(json.dumps({
            'formatVersion': 1,
            'engine': {'repository': 'r', 'commit': self.commit},
            'repair': {
                'patch': 'patches/fake-repair.patch',
                'patchSHA256': sha256(FAKE_PATCH),
                'upstreamRepository': 'u',
                'upstreamCommit': 'deadbeef',
                'sourceFile': src_file,
                'originalSourceSHA256': sha256(ORIGINAL_SOURCE),
                'patchedSourceSHA256': sha256(PATCHED_SOURCE),
            },
            'platforms': {
                'IOSSIMULATOR': self._platform_section(original_member),
            },
        }, indent=2) + '\n')

        manifest = {
            'formatVersion': 2,
            'sourceCommit': self.commit,
            'files': [
                {'path': 'source/engine/instdir/program/libvcllo.a',
                 'size': self.archive.stat().st_size,
                 'sha256': sha256(self.archive.read_bytes())},
                {'path': 'extra-input.txt',
                 'size': len(self.extra_bytes),
                 'sha256': sha256(self.extra_bytes)},
            ],
            'linkerInputs': ['source/engine/instdir/program/libvcllo.a'],
            'linkerArchives': ['source/engine/instdir/program/libvcllo.a'],
        }
        self.bundle.mkdir(parents=True, exist_ok=True)
        (self.bundle / 'extra-input.txt').write_bytes(self.extra_bytes)
        (self.bundle / 'bundle-manifest.json').write_text(
            json.dumps(manifest, indent=2) + '\n')
        # The restore report is the real evidence the producer consumes; the
        # tracked input section alone is never accepted as provenance.
        (self.bundle / 'restore-report.json').write_text(json.dumps({
            'archive': str(self.root / 'staged-engine.zip'),
            'destination': str(self.bundle),
            'sourceCommit': self.commit,
            'restoredEntries': len(manifest['files']),
            'linkerInputs': 1,
            'platformSamples': [{'archive': 'source/engine/instdir/program/libvcllo.a',
                                 'simulatorOnly': True}],
            'platformSampleSize': 1,
            'allSampledObjectsIOSSIMULATOR': True,
            'restoreVerified': True,
            'provenanceBound': True,
            'provenanceArtifactSHA256': self.sim_artifact_sha,
            'provenanceXcodeVersion': 'Xcode 27.0; Build version 27A266a',
            'provenanceSDKVersion': '27.0',
            'reusedRun': True,
            'hostKind': 'upstream-mobile-host-only',
            'engineArchiveManifestRewrite': {'present': False},
            'baseEngineRunID': self.sim_run_id,
            'engineArtifactName': 'office-real-simulator-engine',
            'consumedBy': 'office_floe_simulator.restore_staged_engine',
        }, indent=2) + '\n')

    def _platform_section(self, original_member):
        patched_object = self.patched_object
        return {
            'platform': 'IOSSIMULATOR',
            'input': {
                'kind': 'office-real-simulator-engine',
                'runID': self.sim_run_id,
                'artifactName': 'office-real-simulator-engine',
                'artifactSHA256': self.sim_artifact_sha,
                'outerArtifactName': 'staged-engine.zip',
                'outerArtifactSHA256': sha256(b'fake-outer-zip'),
            },
            'archiveBundlePath': 'source/engine/instdir/program/libvcllo.a',
            'archive': {
                'originalSHA256': sha256(self.archive.read_bytes()),
                'patchedSHA256': 'PENDING',
                'symdefMTime': self.symdef.mtime,
            },
            'member': {
                'name': 'virdev.o',
                'position': self.order.index('virdev.o') + 1,
                'count': len(self.order),
                'mtime': self.member.mtime,
                'uid': os.getuid(),
                'gid': os.getgid(),
                'mode': '644',
                'originalSHA256': sha256(original_member),
                'patchedSHA256': sha256(patched_object),
            },
            'compile': {
                'sdk': 'iphonesimulator',
                'sdkVersion': '27.0',
                'sdkBuildVersion': '24A430',
                'xcodeVersion': 'Xcode 27.0; Build version 27A266a',
                'target': 'arm64-apple-ios26.0-simulator',
                'flags': ['-ffake'],
                'sourceIncludes': ['engine/include'],
                'bundleIncludes': [],
            },
        }

    def finalize_lock(self):
        """Record the real patched archive SHA (authoring-style).

        Performed on a scratch copy of the archive so the bundle itself stays
        in the original state the producer expects.
        """
        import shutil as sh
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / 'libvcllo.a'
            sh.copyfile(self.archive, scratch)
            members = repair.read_ar_members(scratch)
            symdef = members[0]
            replacement = Path(tmp) / 'virdev.o'
            replacement.write_bytes(self.patched_object)
            import os
            os.chmod(replacement, 0o644)
            os.utime(replacement, (self.member.mtime, self.member.mtime))
            subprocess.run(['ar', 'r', str(scratch), str(replacement)],
                           check=True, capture_output=True)
            subprocess.run(['ranlib', str(scratch)], check=True, capture_output=True)
            repair.rewrite_member_mtime(scratch, repair.read_ar_members(scratch)[0],
                                        self.symdef.mtime)
            patched_sha = sha256(scratch.read_bytes())
        lock = json.loads(self.lock.read_text())
        lock['platforms']['IOSSIMULATOR']['archive']['patchedSHA256'] = patched_sha
        self.lock.write_text(json.dumps(lock, indent=2) + '\n')


class RepairGateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.fixture = SyntheticBundle(Path(self._tmp.name) / 'fx')

    def run_apply(self):
        with mock.patch.object(repair, 'run_compile') as run_compile, \
             mock.patch.object(repair, 'build_compile_command') as build_command:
            def fake_compile(command, log_path):
                output = Path(command[command.index('-o') + 1])
                if 'pristine' in output.name:
                    output.write_bytes(
                        repair.read_member(self.fixture.archive,
                                           self.fixture.member))
                else:
                    output.write_bytes(self.fixture.patched_object)
            run_compile.side_effect = fake_compile
            build_command.side_effect = lambda *a, **k: ['fake', '-o', str(a[4])]
            with mock.patch.object(repair, 'check_toolchain',
                                   return_value=([], {'xcodeVersion': 'X',
                                                      'sdkVersion': '27.0',
                                                      'sdkBuildVersion': '24A430',
                                                      'sdkPath': '/s'})):
                return repair.apply(self.fixture.bundle, self.fixture.source,
                                    self.fixture.lock, 'IOSSIMULATOR')

    def test_ar_reader_walks_bsd_longname_archive(self):
        members = repair.read_ar_members(self.fixture.archive)
        self.assertTrue(members[0].name.startswith('__.SYMDEF'))
        self.assertEqual([m.name for m in members], self.fixture.order)
        target = next(m for m in members if m.name == 'virdev.o')
        self.assertEqual(target.mtime, self.fixture.member_mtime)
        self.assertTrue(target.header_offset < target.offset)

    def test_check_classifies_original_and_is_read_only(self):
        lock, section, _ = repair.load_lock(self.fixture.lock, 'IOSSIMULATOR')
        before = {str(p): p.stat().st_mtime_ns
                  for p in self.fixture.bundle.rglob('*')}
        report = repair.repair_state(self.fixture.bundle, section, lock)
        self.assertEqual(report['state'], 'original')
        self.assertTrue(report['memberVerified'])
        after = {str(p): p.stat().st_mtime_ns
                 for p in self.fixture.bundle.rglob('*')}
        self.assertEqual(before, after)

    def test_full_apply_replaces_exactly_one_member(self):
        self.fixture.finalize_lock()
        receipt = self.run_apply()
        self.assertTrue(receipt['compile']['pristineRecompileByteIdentical'])
        members = repair.read_ar_members(self.fixture.archive)
        self.assertEqual([m.name for m in members], self.fixture.order)
        patched = next(m for m in members if m.name == 'virdev.o')
        self.assertEqual(repair.digest_bytes(repair.read_member(
            self.fixture.archive, patched)),
            sha256(self.fixture.patched_object))
        # The replaced member header pins the locked mtime for reproducibility.
        self.assertEqual(patched.mtime, self.fixture.member.mtime)
        # The bundle manifest now matches the archive, and the whole bundle
        # passes the standard verification.
        lock, section, _ = repair.load_lock(self.fixture.lock, 'IOSSIMULATOR')
        report = repair.repair_state(self.fixture.bundle, section, lock)
        self.assertEqual(report['state'], 'patched')
        self.assertTrue(report['manifestEntryMatchesArchive'])

    def test_refuses_to_reapply_over_patched_archive(self):
        self.fixture.finalize_lock()
        self.run_apply()
        with self.assertRaises(repair.RepairError):
            self.run_apply()

    def test_fails_closed_on_unrelated_member_change(self):
        # If the replacement step silently touched a NON-target member (here
        # simulated by injecting an extra omega.o replacement during ar r),
        # the producer's whole-archive audit must refuse the result.
        import os
        with tempfile.TemporaryDirectory() as tmp:
            omega2 = Path(tmp) / 'omega.o'
            omega2.write_bytes(self.fixture.patched_object)  # foreign bytes
            os.utime(omega2, (self.fixture.member.mtime, self.fixture.member.mtime))
            real_run = subprocess.run

            def sabotage(command, **kwargs):
                result = real_run(command, **kwargs)
                if command[:2] == ['ar', 'r'] and 'virdev.o' in ' '.join(command):
                    real_run(['ar', 'r', command[2], str(omega2)], check=True,
                             capture_output=True)
                return result

            with mock.patch.object(repair.subprocess, 'run', side_effect=sabotage):
                with self.assertRaises(repair.RepairError) as raised:
                    self.run_apply()
            self.assertRegex(
                str(raised.exception),
                'unrelated archive members|member order or count changed')

    def _flip_victim_command(self, archive_path):
        """Sabotage hook: flip one byte in an unrelated member, same length."""
        real_run = subprocess.run

        def sabotage(command, **kwargs):
            result = real_run(command, **kwargs)
            if command[:2] == ['ar', 'r'] and Path(command[2]).resolve() == \
                    Path(archive_path).resolve():
                members = repair.read_ar_members(archive_path)
                victim = next(member for member in members
                              if member.name not in ('virdev.o',)
                              and not member.name.startswith('__.SYMDEF'))
                data = bytearray(archive_path.read_bytes())
                # Mid-content byte: same length and headers, but touch no
                # mach-o magic/symbol metadata that ranlib consumes.
                data[victim.offset + victim.size // 2] ^= 0xFF
                archive_path.write_bytes(bytes(data))
            return result

        return sabotage

    def test_unrelated_same_length_tamper_rejected_even_with_adjusted_whole_sha(self):
        """The member audit must be independent of the whole-archive hash.

        One byte of an unrelated member is flipped without changing any length
        or ar header, and the tracked patched-archive SHA is then adjusted to
        the tampered result: the whole-hash gate would pass, so only the
        pre-mutation per-member snapshot can reject the tampered archive.
        """
        self.fixture.finalize_lock()
        # Second fixture copied BEFORE the first tamper: the same deterministic
        # sabotage then produces byte-identical archives.
        second_root = Path(self._tmp.name) / 'fx2'
        shutil.copytree(self.fixture.root, second_root)
        second = SyntheticBundle.__new__(SyntheticBundle)
        second.root = second_root
        second.source = second_root / 'engine-src'
        second.bundle = second_root / 'bundle'
        second.lock = second_root / 'engine.patch.lock.json'
        second.patch = second_root / 'patches/fake-repair.patch'
        second.sim_run_id = self.fixture.sim_run_id
        second.sim_artifact_sha = self.fixture.sim_artifact_sha
        second.extra_bytes = self.fixture.extra_bytes
        second.archive = second.bundle / 'source/engine/instdir/program/libvcllo.a'
        second.patched_object = self.fixture.patched_object
        member_list = repair.read_ar_members(second.archive)
        second.member = next(m for m in member_list if m.name == 'virdev.o')
        second.symdef = member_list[0]
        second.order = [m.name for m in member_list]
        second.member_mtime = second.member.mtime

        with mock.patch.object(repair.subprocess, 'run',
                               side_effect=self._flip_victim_command(self.fixture.archive)):
            with self.assertRaisesRegex(repair.RepairError,
                                        'unrelated archive members changed'):
                self.run_apply()
        tampered_sha = sha256(self.fixture.archive.read_bytes())

        lock_data = json.loads(second.lock.read_text())
        section = lock_data['platforms']['IOSSIMULATOR']
        section['archive']['patchedSHA256'] = tampered_sha
        second.lock.write_text(json.dumps(lock_data, indent=2) + '\n')

        with mock.patch.object(repair.subprocess, 'run',
                               side_effect=self._flip_victim_command(second.archive)):
            with mock.patch.object(repair, 'run_compile') as run_compile, \
                 mock.patch.object(repair, 'build_compile_command') as build_command:
                def fake_compile(command, log_path):
                    output = Path(command[command.index('-o') + 1])
                    if 'pristine' in output.name:
                        output.write_bytes(repair.read_member(
                            second.archive, second.member))
                    else:
                        output.write_bytes(second.patched_object)
                run_compile.side_effect = fake_compile
                build_command.side_effect = lambda *a, **k: ['fake', '-o', str(a[4])]
                with mock.patch.object(repair, 'check_toolchain',
                                       return_value=([], {'xcodeVersion': 'X',
                                                          'sdkVersion': '27.0',
                                                          'sdkBuildVersion': '24A430',
                                                          'sdkPath': '/s'})):
                    with self.assertRaisesRegex(
                            repair.RepairError,
                            'unrelated archive members changed'):
                        repair.apply(second.bundle, second.source, second.lock,
                                     'IOSSIMULATOR')
        # The adjusted whole-archive SHA really is the tampered archive's hash:
        # the rejection happened in the member audit, not the whole-hash gate.
        self.assertEqual(sha256(second.archive.read_bytes()), tampered_sha)

    def test_input_evidence_missing_or_mismatched_rejected(self):
        self.fixture.finalize_lock()
        report_path = self.fixture.bundle / 'restore-report.json'
        original = report_path.read_text()
        report_path.unlink()
        with self.assertRaisesRegex(repair.RepairError, 'restore report missing'):
            self.run_apply()
        report = json.loads(original)
        report['provenanceArtifactSHA256'] = '0' * 64
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        with self.assertRaisesRegex(repair.RepairError, 'provenanceArtifactSHA256'):
            self.run_apply()
        report = json.loads(original)
        report['baseEngineRunID'] = '1'
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        with self.assertRaisesRegex(repair.RepairError, 'baseEngineRunID'):
            self.run_apply()
        report = json.loads(original)
        report['restoreVerified'] = False
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        with self.assertRaisesRegex(repair.RepairError, 'restoreVerified'):
            self.run_apply()
        report_path.write_text(original)

    def test_input_manifest_tamper_rejected_before_mutation(self):
        self.fixture.finalize_lock()
        before = self.fixture.archive.read_bytes()
        (self.fixture.bundle / 'extra-input.txt').write_bytes(b'tampered\n')
        with self.assertRaisesRegex(repair.RepairError, 'Changed or missing file'):
            self.run_apply()
        # The archive was not mutated: the complete input manifest is verified
        # before anything is touched.
        self.assertEqual(self.fixture.archive.read_bytes(), before)

    def _write_canonical_receipt(self, bundle, lock_path,
                                 platform='IOSSIMULATOR'):
        lock, section, _ = repair.load_lock(lock_path, platform)
        expected = repair.expected_manifest_block(lock, section)
        receipt = {
            'platform': expected['platform'],
            'repair': {key: expected[key] for key in (
                'patchSHA256', 'upstreamCommit', 'sourceFile',
                'originalSourceSHA256', 'patchedSourceSHA256')},
            'compile': {'sdk': expected['sdk'], 'target': expected['target']},
            'archive': {
                'bundlePath': expected['archiveBundlePath'],
                'originalSHA256': expected['originalArchiveSHA256'],
                'patchedSHA256': expected['patchedArchiveSHA256'],
                'memberCount': expected['member']['count'],
                'member': {
                    'name': expected['member']['name'],
                    'position': expected['member']['position'],
                    'originalSHA256': expected['member']['originalSHA256'],
                    'patchedSHA256': expected['member']['patchedSHA256'],
                },
            },
            'lock': {'sha256': expected['lockSHA256']},
        }
        (bundle / repair.RECEIPT_NAME).write_text(
            json.dumps(receipt, indent=2) + '\n')
        return expected

    def test_aux_bundle_evidence_and_header_closure(self):
        self.fixture.finalize_lock()
        aux = Path(self._tmp.name) / 'aux'
        shutil.copytree(self.fixture.bundle, aux)
        # The aux engine is the repaired simulator engine: point the simulator
        # contract at this archive and record the canonical repair receipt.
        aux_archive = aux / 'source/engine/instdir/program/libvcllo.a'
        lock_data = json.loads(self.fixture.lock.read_text())
        sim = lock_data['platforms']['IOSSIMULATOR']
        sim['archive']['patchedSHA256'] = sha256(aux_archive.read_bytes())
        self.fixture.lock.write_text(json.dumps(lock_data, indent=2) + '\n')
        expected = self._write_canonical_receipt(aux, self.fixture.lock)
        section = {
            'auxiliaryInput': {'runID': self.fixture.sim_run_id,
                               'artifactSHA256': self.fixture.sim_artifact_sha},
            'compile': {'auxiliaryIncludes': ['aux-root']},
        }
        lock = json.loads(self.fixture.lock.read_text())
        evidence = repair.check_aux_bundle(section, aux, lock, self.fixture.lock)
        self.assertEqual(evidence['runID'], self.fixture.sim_run_id)
        self.assertEqual(evidence['artifactSHA256'], self.fixture.sim_artifact_sha)
        self.assertEqual(evidence['engineRepairReceipt']['patchedArchiveSHA256'],
                         expected['patchedArchiveSHA256'])
        self.assertGreaterEqual(evidence['manifestFilesVerified'], 2)

        # Missing/wrong restore evidence must be rejected.
        report_path = aux / 'restore-report.json'
        report = json.loads(report_path.read_text())
        report['baseEngineRunID'] = '1'
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        with self.assertRaisesRegex(repair.RepairError, 'baseEngineRunID'):
            repair.check_aux_bundle(section, aux, lock, self.fixture.lock)

        # Header closure: real dependency paths must be manifest-covered.
        root = aux / 'aux-root'
        root.mkdir()
        header = root / 'hb.h'
        header.write_bytes(b'#define FLOE_AUX 1\n')
        manifest_path = aux / 'bundle-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files'].append({'path': 'aux-root'})
        manifest['files'].append({
            'path': 'aux-root/hb.h', 'size': header.stat().st_size,
            'sha256': sha256(header.read_bytes())})
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        depfile = Path(self._tmp.name) / 'pristine.d'
        depfile.write_text(f'{aux}/object.o: {header}\n')
        closure = repair.verify_auxiliary_closure(
            {'compile': {'auxiliaryIncludes': ['aux-root']}}, aux, depfile)
        self.assertEqual([item['path'] for item in closure], ['aux-root/hb.h'])
        self.assertEqual(closure[0]['sha256'], sha256(header.read_bytes()))
        header.write_bytes(b'#define FLOE_AUX 2\n')
        with self.assertRaisesRegex(repair.RepairError, 'differs from the verified'):
            repair.verify_auxiliary_closure(
                {'compile': {'auxiliaryIncludes': ['aux-root']}}, aux, depfile)
        header.write_bytes(b'#define FLOE_AUX 1\n')
        unlisted = root / 'other.h'
        unlisted.write_bytes(b'#define FLOE_OTHER 1\n')
        depfile.write_text(f'{aux}/object.o: {unlisted}\n')
        with self.assertRaisesRegex(repair.RepairError, 'not covered by the verified'):
            repair.verify_auxiliary_closure(
                {'compile': {'auxiliaryIncludes': ['aux-root']}}, aux, depfile)
        depfile.write_text(f'{aux}/object.o:\n')
        with self.assertRaisesRegex(repair.RepairError, 'no header under the locked'):
            repair.verify_auxiliary_closure(
                {'compile': {'auxiliaryIncludes': ['aux-root']}}, aux, depfile)

    def test_fails_closed_on_member_position_drift(self):
        lock_data = json.loads(self.fixture.lock.read_text())
        section = lock_data['platforms']['IOSSIMULATOR']
        section['member']['position'] = section['member']['position'] + 1
        self.fixture.lock.write_text(json.dumps(lock_data, indent=2))
        with self.assertRaisesRegex(repair.RepairError, 'position'):
            repair.apply(self.fixture.bundle, self.fixture.source,
                         self.fixture.lock, 'IOSSIMULATOR')

    def test_fails_closed_on_member_count_drift(self):
        lock_data = json.loads(self.fixture.lock.read_text())
        lock_data['platforms']['IOSSIMULATOR']['member']['count'] += 5
        self.fixture.lock.write_text(json.dumps(lock_data, indent=2))
        with self.assertRaisesRegex(repair.RepairError, 'member count'):
            repair.apply(self.fixture.bundle, self.fixture.source,
                         self.fixture.lock, 'IOSSIMULATOR')

    def test_fails_closed_on_source_hash_mismatch(self):
        src = self.fixture.source / 'engine/vcl/source/gdi/virdev.cxx'
        src.write_bytes(b'// tampered worktree, commit unchanged\n')
        with self.assertRaisesRegex(repair.RepairError, 'differs from the lock'):
            repair.apply(self.fixture.bundle, self.fixture.source,
                         self.fixture.lock, 'IOSSIMULATOR')

    def test_fails_closed_on_engine_commit_mismatch(self):
        src = self.fixture.source / 'engine/vcl/source/gdi/virdev.cxx'
        src.write_bytes(b'// tampered\n')
        subprocess.run(['git', '-C', str(self.fixture.source), 'add', '-A'],
                       check=True)
        subprocess.run(['git', '-C', str(self.fixture.source), '-c',
                        'user.email=t@example.com', '-c', 'user.name=t',
                        'commit', '-q', '-m', 'tamper'], check=True)
        with self.assertRaisesRegex(repair.RepairError, 'commit'):
            repair.apply(self.fixture.bundle, self.fixture.source,
                         self.fixture.lock, 'IOSSIMULATOR')

    def _git_commit_tamper(self):
        subprocess.run(['git', '-C', str(self.fixture.source), 'add', '-A'],
                       check=True)
        subprocess.run(['git', '-C', str(self.fixture.source), '-c',
                        'user.email=t@example.com', '-c', 'user.name=t',
                        'commit', '-q', '-m', 'tamper'], check=True)

    def test_fails_closed_on_patch_checksum_mismatch(self):
        self.fixture.patch.write_bytes(self.fixture.patch.read_bytes() + b'#x')
        with self.assertRaisesRegex(repair.RepairError, 'checksum'):
            repair.apply(self.fixture.bundle, self.fixture.source,
                         self.fixture.lock, 'IOSSIMULATOR')

    def test_fails_closed_on_patched_source_divergence(self):
        # The locked patched-source hash must describe exactly what the tracked
        # patch produces; a drifted expectation fails before any compile.
        lock_data = json.loads(self.fixture.lock.read_text())
        lock_data['repair']['patchedSourceSHA256'] = '0' * 64
        self.fixture.lock.write_text(json.dumps(lock_data, indent=2))
        with self.assertRaisesRegex(repair.RepairError,
                                    'locked patched source'):
            self.run_apply()

    def test_fails_closed_on_pristine_recompile_divergence(self):
        with mock.patch.object(repair, 'run_compile') as run_compile, \
             mock.patch.object(repair, 'build_compile_command') as build_command:
            run_compile.side_effect = lambda command, log: Path(
                command[command.index('-o') + 1]).write_bytes(b'garbage')
            build_command.side_effect = lambda *a, **k: ['x', '-o', str(a[4])]
            with mock.patch.object(repair, 'check_toolchain',
                                   return_value=([], {'xcodeVersion': 'X'})):
                with self.assertRaisesRegex(repair.RepairError,
                                            'byte-identical'):
                    repair.apply(self.fixture.bundle, self.fixture.source,
                                 self.fixture.lock, 'IOSSIMULATOR')

    def test_fails_closed_on_bundle_manifest_commit_drift(self):
        manifest_path = self.fixture.bundle / 'bundle-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['sourceCommit'] = '0' * 40
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        with self.assertRaisesRegex(repair.RepairError, 'sourceCommit'):
            repair.apply(self.fixture.bundle, self.fixture.source,
                         self.fixture.lock, 'IOSSIMULATOR')

    def test_fails_closed_on_missing_platform_contract(self):
        with self.assertRaisesRegex(repair.RepairError, 'no engine repair contract'):
            repair.load_lock(self.fixture.lock, 'IOS')

    def test_manifest_block_requires_receipt_matching_lock(self):
        self.fixture.finalize_lock()
        lock, section, _ = repair.load_lock(self.fixture.lock, 'IOSSIMULATOR')
        with self.assertRaisesRegex(repair.RepairError, 'no engine-repair.json'):
            repair.manifest_block(self.fixture.bundle,
                                  lock_path=self.fixture.lock,
                                  platform='IOSSIMULATOR')
        self.run_apply()
        block = repair.manifest_block(self.fixture.bundle,
                                      lock_path=self.fixture.lock,
                                      platform='IOSSIMULATOR')
        self.assertEqual(block['member']['patchedSHA256'],
                         sha256(self.fixture.patched_object))
        # A lock edit (stale provenance) must break the block comparison.
        lock_data = json.loads(self.fixture.lock.read_text())
        lock_data['platforms']['IOSSIMULATOR']['member']['patchedSHA256'] = \
            '0' * 64
        self.fixture.lock.write_text(json.dumps(lock_data, indent=2))
        with self.assertRaisesRegex(repair.RepairError, 'disagrees'):
            repair.manifest_block(self.fixture.bundle,
                                  lock_path=self.fixture.lock,
                                  platform='IOSSIMULATOR')

    def test_unsafe_paths_rejected(self):
        with self.assertRaises(ValueError):
            from verify_office_engine import contained
            contained(self.fixture.bundle, '../escape.txt')
        with self.assertRaises(ValueError):
            contained(self.fixture.bundle, '/absolute.txt')

    def test_toolchain_comparison_uses_locked_identity(self):
        section = {'compile': {'sdk': 'iphonesimulator',
                               'sdkVersion': '27.0',
                               'sdkBuildVersion': '24A430',
                               'xcodeVersion': 'Xcode 27.0; Build version 27A266a'},
                   'platform': 'IOSSIMULATOR'}
        with mock.patch.object(repair.subprocess, 'check_output',
                               return_value='24A999\n'), \
             mock.patch.object(repair.subprocess, 'run') as run:
            run.return_value = subprocess.CompletedProcess(
                args=[], returncode=0, stdout='Xcode 27.0\nBuild version 27A266a\n')
            failures, _ = repair.check_toolchain(section)
            self.assertTrue(any('SDK build' in f for f in failures))


if __name__ == '__main__':
    unittest.main()
