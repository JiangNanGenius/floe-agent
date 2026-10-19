#!/usr/bin/env python3
"""Real temporary-Git behavior tests for the Office source preparation.

Every case builds a local upstream repository, a real deployment patch and a
real browser patch, then runs ``prepare_simulator_source.prepare`` against it.
No network, fetch, Office/engine/App build, Simulator or shared checkout is
used; these tests prove preparation behavior only.
"""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PKG_DIR = Path(__file__).resolve().parent.parent / 'office_real_simulator'
sys.path.insert(0, str(PKG_DIR))

import prepare_simulator_source as preparation  # noqa: E402

REPOSITORY = 'https://example.invalid/online.mirror.git'
BROWSER_FILE = 'browser/src/canvas/CanvasSectionContainer.ts'
SECOND_BROWSER_FILE = 'browser/src/canvas/BrowserMapping.ts'
DEPLOYMENT_FILE = 'engine/configure.ac'
UNRELATED_FILE = 'README.notes'

BROWSER_ORIGINAL = '''export class CanvasSectionContainer {
	public multiTouch: boolean = false;
	public onTouchStart(e: TouchEvent) {
		if (this.multiTouch) return;
		this.multiTouch = true;
	}
}
'''
BROWSER_PATCHED = '''export class CanvasSectionContainer {
	public multiTouch: boolean = false;
	public onTouchStart(e: TouchEvent) {
		if (this.multiTouch) return;
		this.multiTouch = true;
		// fixture: the locked browser patch adds one line
		this.seedFirstTouch(e);
	}
}
'''
BROWSER_PATCHED_SECOND = '''export class CanvasSectionContainer {
	public multiTouch: boolean = false;
	public onTouchStart(e: TouchEvent) {
		if (this.multiTouch) return;
		this.multiTouch = true;
		// fixture: the locked browser patch adds one line
		this.seedFirstTouch(e);
		// fixture: the chained patch adds a second line
		this.seedSecondTouch(e);
	}
}
'''
DEPLOYMENT_ORIGINAL = '''AC_INIT([online], [1.0])
if test "$enable_ios_simulator" = "yes"; then
    versionmin=-mios-simulator-version-min=14.5
else
    versionmin=-miphoneos-version-min=14.5
fi
'''
DEPLOYMENT_PATCHED = DEPLOYMENT_ORIGINAL.replace('14.5', '26.0')
UNRELATED_ORIGINAL = 'fixture notes; preparation must never rewrite this file\n'
SECOND_ORIGINAL = '''export class BrowserMapping {
	public static scale = 1;
}
'''
SECOND_PATCHED = '''export class BrowserMapping {
	public static scale = 2;
}
'''


class PreparationFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.build_root = self.base / 'build'
        self.source = self.build_root / 'source'
        self.write((BROWSER_FILE, BROWSER_ORIGINAL),
                   (SECOND_BROWSER_FILE, SECOND_ORIGINAL),
                   (DEPLOYMENT_FILE, DEPLOYMENT_ORIGINAL),
                   (UNRELATED_FILE, UNRELATED_ORIGINAL))
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.com')
        self.git('config', 'user.name', 'Fixture')
        self.git('add', '.')
        self.git('commit', '-qm', 'pinned fixture')
        self.commit = self.git('rev-parse', 'HEAD').stdout.strip()

        contract = self.base / 'contract'
        self.patch_dir = contract / 'patches'
        self.patch_dir.mkdir(parents=True)
        self.deployment_patch = self.patch_dir / 'ios-deployment-target.patch'
        self.browser_patch = self.patch_dir / 'ios-batched-touch-start.patch'
        self.second_patch = self.patch_dir / 'ios-second-browser.patch'
        self.chained_patch = self.patch_dir / 'ios-chained-canvas.patch'
        self.deployment_patch.write_text(
            self.make_patch(DEPLOYMENT_FILE, DEPLOYMENT_ORIGINAL,
                            DEPLOYMENT_PATCHED))
        self.browser_patch.write_text(
            self.make_patch(BROWSER_FILE, BROWSER_ORIGINAL, BROWSER_PATCHED))
        self.second_patch.write_text(
            self.make_patch(SECOND_BROWSER_FILE, SECOND_ORIGINAL,
                            SECOND_PATCHED))
        self.chained_patch.write_text(self.make_chained_patch(
            BROWSER_FILE, BROWSER_PATCHED, BROWSER_PATCHED_SECOND))
        # Keep the committed fixture at the pinned original; the first browser
        # patch is applied by each test that needs it.
        (self.source / BROWSER_FILE).write_text(BROWSER_ORIGINAL)
        self.engine_lock = contract / 'engine.lock.json'
        self.patch_lock = contract / 'browser.patch.lock.json'
        self.write_contracts()

    def write(self, *files):
        for relative, text in files:
            target = self.source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.source, check=True,
                              capture_output=True, text=True)

    def make_patch(self, relative, original, patched):
        target = self.source / relative
        target.write_text(patched)
        diff = self.git('diff', '--', relative).stdout
        target.write_text(original)
        self.assertIn(f'diff --git a/{relative} b/{relative}', diff)
        return diff

    def make_chained_patch(self, relative, before, after):
        """Diff two texts without committing the first patch to HEAD."""
        diff = difflib.unified_diff(
            before.splitlines(True), after.splitlines(True),
            fromfile=f'a/{relative}', tofile=f'b/{relative}', n=3)
        return ''.join(diff)

    def sha_file(self, path):
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()

    def sha_text(self, text):
        return hashlib.sha256(text.encode()).hexdigest()

    def browser_entry(self, **overrides):
        entry = {
            'patch': 'patches/ios-batched-touch-start.patch',
            'patchSHA256': self.sha_file(self.browser_patch),
            'sourceRepository': REPOSITORY,
            'sourceCommit': self.commit,
            'sourceFile': BROWSER_FILE,
            'originalSourceSHA256': self.sha_text(BROWSER_ORIGINAL),
            'patchedSourceSHA256': self.sha_text(BROWSER_PATCHED),
        }
        entry.update(overrides)
        return entry

    def second_entry(self, **overrides):
        entry = {
            'patch': 'patches/ios-second-browser.patch',
            'patchSHA256': self.sha_file(self.second_patch),
            'sourceRepository': REPOSITORY,
            'sourceCommit': self.commit,
            'sourceFile': SECOND_BROWSER_FILE,
            'originalSourceSHA256': self.sha_text(SECOND_ORIGINAL),
            'patchedSourceSHA256': self.sha_text(SECOND_PATCHED),
        }
        entry.update(overrides)
        return entry

    def chained_entry(self, **overrides):
        entry = {
            'patch': 'patches/ios-chained-canvas.patch',
            'patchSHA256': self.sha_file(self.chained_patch),
            'sourceRepository': REPOSITORY,
            'sourceCommit': self.commit,
            'sourceFile': BROWSER_FILE,
            'originalSourceSHA256': self.sha_text(BROWSER_PATCHED),
            'patchedSourceSHA256': self.sha_text(BROWSER_PATCHED_SECOND),
        }
        entry.update(overrides)
        return entry

    def write_contracts(self, browser_entries=None, include_browser_list=True,
                        repository=REPOSITORY, commit=None):
        commit = commit or self.commit
        self.engine_lock.write_text(json.dumps({
            'repository': repository,
            'commit': commit,
            'sourcePatchSHA256': self.sha_file(self.deployment_patch),
        }, indent=2) + '\n')
        lock = {
            'formatVersion': 1,
            'kind': 'preparation fixture',
            'engine': {'repository': repository, 'commit': commit},
        }
        if include_browser_list:
            if browser_entries is None:
                browser_entries = [self.browser_entry(
                    sourceRepository=repository, sourceCommit=commit)]
            lock['browserSourcePatches'] = browser_entries
        self.patch_lock.write_text(json.dumps(lock, indent=2) + '\n')

    def prepare(self):
        return preparation.prepare(
            self.build_root, lock_path=self.engine_lock,
            deployment_patch=self.deployment_patch,
            patch_lock_path=self.patch_lock)

    def snapshot(self):
        return {relative: (self.source / relative).read_bytes()
                for relative in (BROWSER_FILE, SECOND_BROWSER_FILE,
                                 DEPLOYMENT_FILE, UNRELATED_FILE)}

    def changed_paths(self):
        output = self.git('diff', '--name-only', 'HEAD').stdout
        return set(output.splitlines())

    def status_lines(self):
        return set(self.git('status', '--porcelain').stdout.splitlines())

    def assert_only_expected_changes(self):
        self.assertEqual(self.changed_paths(), {BROWSER_FILE, DEPLOYMENT_FILE})
        self.assertEqual(self.status_lines(), {
            f' M {BROWSER_FILE}', f' M {DEPLOYMENT_FILE}'})


class CleanPreparationTests(PreparationFixture):
    def test_clean_apply_writes_patched_sources_and_verified_receipt(self):
        receipt = self.prepare()
        self.assertEqual((self.source / BROWSER_FILE).read_text(),
                         BROWSER_PATCHED)
        self.assertEqual((self.source / DEPLOYMENT_FILE).read_text(),
                         DEPLOYMENT_PATCHED)
        self.assert_only_expected_changes()
        self.assertTrue(receipt['pinnedSourceReady'])
        self.assertEqual(receipt['commit'], self.commit)
        self.assertEqual(receipt['repository'], REPOSITORY)
        self.assertEqual(receipt['deploymentPatchSHA256'],
                         self.sha_file(self.deployment_patch))
        self.assertFalse(receipt['deploymentPatchAlreadyApplied'])
        self.assertEqual(receipt['browserPatchLockSHA256'],
                         self.sha_file(self.patch_lock))
        self.assertEqual(len(receipt['browserSourcePatches']), 1)
        entry = receipt['browserSourcePatches'][0]
        self.assertEqual(entry['patch'], 'patches/ios-batched-touch-start.patch')
        self.assertEqual(entry['patchSHA256'],
                         self.sha_file(self.browser_patch))
        self.assertEqual(entry['sourceRepository'], REPOSITORY)
        self.assertEqual(entry['sourceCommit'], self.commit)
        self.assertEqual(entry['sourceFile'], BROWSER_FILE)
        self.assertEqual(entry['originalSourceSHA256'],
                         self.sha_text(BROWSER_ORIGINAL))
        self.assertEqual(entry['patchedSourceSHA256'],
                         self.sha_text(BROWSER_PATCHED))
        self.assertEqual(entry['verifiedSourceSHA256'],
                         self.sha_text(BROWSER_PATCHED))
        self.assertFalse(entry['alreadyApplied'])

    def test_second_identical_run_is_idempotent(self):
        first = self.prepare()
        before = self.snapshot()
        second = self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assert_only_expected_changes()
        self.assertTrue(second['deploymentPatchAlreadyApplied'])
        entry = second['browserSourcePatches'][0]
        self.assertTrue(entry['alreadyApplied'])
        self.assertEqual(entry['verifiedSourceSHA256'],
                         first['browserSourcePatches'][0]['verifiedSourceSHA256'])
        self.assertTrue(second['pinnedSourceReady'])

    def test_partial_state_with_browser_patch_applied(self):
        self.git('apply', str(self.browser_patch))
        self.assertEqual(self.changed_paths(), {BROWSER_FILE})
        receipt = self.prepare()
        self.assertEqual((self.source / DEPLOYMENT_FILE).read_text(),
                         DEPLOYMENT_PATCHED)
        self.assert_only_expected_changes()
        self.assertFalse(receipt['deploymentPatchAlreadyApplied'])
        self.assertTrue(receipt['browserSourcePatches'][0]['alreadyApplied'])

    def test_partial_state_with_deployment_patch_applied(self):
        self.git('apply', str(self.deployment_patch))
        self.assertEqual(self.changed_paths(), {DEPLOYMENT_FILE})
        receipt = self.prepare()
        self.assertEqual((self.source / BROWSER_FILE).read_text(),
                         BROWSER_PATCHED)
        self.assert_only_expected_changes()
        self.assertTrue(receipt['deploymentPatchAlreadyApplied'])
        self.assertFalse(receipt['browserSourcePatches'][0]['alreadyApplied'])

    def test_multiple_locked_browser_patches_are_independent(self):
        self.git('apply', str(self.second_patch))
        self.write_contracts(browser_entries=[self.browser_entry(),
                                               self.second_entry()])
        receipt = self.prepare()
        self.assertEqual((self.source / BROWSER_FILE).read_text(),
                         BROWSER_PATCHED)
        self.assertEqual((self.source / SECOND_BROWSER_FILE).read_text(),
                         SECOND_PATCHED)
        self.assertEqual((self.source / DEPLOYMENT_FILE).read_text(),
                         DEPLOYMENT_PATCHED)
        self.assertEqual(self.changed_paths(), {
            BROWSER_FILE, SECOND_BROWSER_FILE, DEPLOYMENT_FILE})
        entries = {entry['sourceFile']: entry
                   for entry in receipt['browserSourcePatches']}
        self.assertFalse(entries[BROWSER_FILE]['alreadyApplied'])
        self.assertTrue(entries[SECOND_BROWSER_FILE]['alreadyApplied'])
        self.assertEqual(entries[BROWSER_FILE]['verifiedSourceSHA256'],
                         self.sha_text(BROWSER_PATCHED))
        self.assertEqual(entries[SECOND_BROWSER_FILE]['verifiedSourceSHA256'],
                         self.sha_text(SECOND_PATCHED))

    def test_same_file_chained_patches_apply_in_order(self):
        self.write_contracts(browser_entries=[self.browser_entry(),
                                               self.chained_entry()])
        receipt = self.prepare()
        self.assertEqual((self.source / BROWSER_FILE).read_text(),
                         BROWSER_PATCHED_SECOND)
        self.assertEqual((self.source / DEPLOYMENT_FILE).read_text(),
                         DEPLOYMENT_PATCHED)
        self.assertEqual(self.changed_paths(), {BROWSER_FILE, DEPLOYMENT_FILE})
        self.assertEqual(len(receipt['browserSourcePatches']), 2)
        for entry in receipt['browserSourcePatches']:
            self.assertEqual(entry['verifiedSourceSHA256'],
                             self.sha_text(BROWSER_PATCHED_SECOND))
            self.assertFalse(entry['alreadyApplied'])
        # A rerun recognizes the full chain as already applied.
        second = self.prepare()
        for entry in second['browserSourcePatches']:
            self.assertTrue(entry['alreadyApplied'])
            self.assertEqual(entry['verifiedSourceSHA256'],
                             self.sha_text(BROWSER_PATCHED_SECOND))

    def test_partial_same_file_chain_applies_only_the_remainder(self):
        self.git('apply', str(self.browser_patch))
        self.assertEqual(self.changed_paths(), {BROWSER_FILE})
        self.write_contracts(browser_entries=[self.browser_entry(),
                                               self.chained_entry()])
        receipt = self.prepare()
        self.assertEqual((self.source / BROWSER_FILE).read_text(),
                         BROWSER_PATCHED_SECOND)
        entries = receipt['browserSourcePatches']
        self.assertTrue(entries[0]['alreadyApplied'])
        self.assertFalse(entries[1]['alreadyApplied'])
        self.assertEqual(entries[0]['verifiedSourceSHA256'],
                         self.sha_text(BROWSER_PATCHED_SECOND))
        self.assertEqual(entries[1]['verifiedSourceSHA256'],
                         self.sha_text(BROWSER_PATCHED_SECOND))

    def test_absent_browser_patch_list_keeps_deployment_only_behavior(self):
        self.write_contracts(include_browser_list=False)
        receipt = self.prepare()
        self.assertEqual((self.source / BROWSER_FILE).read_text(),
                         BROWSER_ORIGINAL)
        self.assertEqual((self.source / DEPLOYMENT_FILE).read_text(),
                         DEPLOYMENT_PATCHED)
        self.assertEqual(self.changed_paths(), {DEPLOYMENT_FILE})
        self.assertEqual(receipt['browserSourcePatches'], [])
        self.assertEqual(receipt['browserPatchLockSHA256'],
                         self.sha_file(self.patch_lock))
        self.assertTrue(receipt['pinnedSourceReady'])


class RejectedPreparationTests(PreparationFixture):
    def assert_rejected_without_mutation(self, pattern):
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, pattern):
            self.prepare()
        self.assertEqual(self.snapshot(), before)

    def test_unexpected_tracked_edit_is_rejected_without_mutation(self):
        (self.source / UNRELATED_FILE).write_text('user edit\n')
        self.assert_rejected_without_mutation('unexpected tracked change')

    def test_staged_source_edit_is_rejected_without_mutation(self):
        (self.source / UNRELATED_FILE).write_text('staged user edit\n')
        self.git('add', UNRELATED_FILE)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'staged changes'):
            self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.changed_paths(), {UNRELATED_FILE})

    def test_unknown_browser_source_is_rejected_without_mutation(self):
        (self.source / BROWSER_FILE).write_text(BROWSER_PATCHED + '// user\n')
        self.assert_rejected_without_mutation('not in a known state')

    def test_unknown_deployment_source_is_rejected_without_mutation(self):
        (self.source / DEPLOYMENT_FILE).write_text(
            DEPLOYMENT_ORIGINAL + '# user edit\n')
        self.assert_rejected_without_mutation('not in a known state')

    def test_tampered_patch_digest_is_rejected_without_mutation(self):
        self.browser_patch.write_text(self.browser_patch.read_text() + '\n')
        self.assert_rejected_without_mutation('patch SHA-256 mismatch')

    def test_multi_file_browser_patch_is_rejected_without_mutation(self):
        (self.source / BROWSER_FILE).write_text(BROWSER_PATCHED)
        (self.source / UNRELATED_FILE).write_text('patched by the same patch\n')
        diff = self.git('diff', '--', BROWSER_FILE, UNRELATED_FILE).stdout
        (self.source / BROWSER_FILE).write_text(BROWSER_ORIGINAL)
        (self.source / UNRELATED_FILE).write_text(UNRELATED_ORIGINAL)
        self.browser_patch.write_text(diff)
        self.write_contracts(browser_entries=[self.browser_entry()])
        self.assert_rejected_without_mutation('exactly its sourceFile')

    def test_broken_same_file_chain_is_rejected_without_mutation(self):
        self.write_contracts(browser_entries=[
            self.browser_entry(),
            self.chained_entry(originalSourceSHA256=self.sha_text(BROWSER_ORIGINAL)),
        ])
        self.assert_rejected_without_mutation('does not continue')

    def test_missing_patch_lock_is_rejected_without_mutation(self):
        self.patch_lock.unlink()
        self.assert_rejected_without_mutation(
            'browser patch lock is not a regular file')

    def test_engine_commit_mismatch_is_rejected_without_mutation(self):
        self.write_contracts(commit='1' * 40)
        self.assert_rejected_without_mutation('pinned commit')

    def test_browser_commit_mismatch_is_rejected_without_mutation(self):
        self.write_contracts(browser_entries=[self.browser_entry(
            sourceCommit='0' * 40)])
        self.assert_rejected_without_mutation('sourceCommit differs')

    def test_browser_repository_mismatch_is_rejected_without_mutation(self):
        self.write_contracts(browser_entries=[self.browser_entry(
            sourceRepository='https://example.invalid/other.git')])
        self.assert_rejected_without_mutation('sourceRepository differs')


if __name__ == '__main__':
    unittest.main(verbosity=2)
