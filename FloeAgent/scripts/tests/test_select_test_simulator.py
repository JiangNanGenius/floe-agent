import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('select_simulator', Path(__file__).resolve().parents[1] / 'select_test_simulator.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

IPHONE27 = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'


def iphone(udid, name='iPhone 17 Pro', **kwargs):
    return dict(name=name, udid=udid, **kwargs)


def ipad(udid, **kwargs):
    return dict(name='iPad mini (A17 Pro)', udid=udid, **kwargs)


RUNTIMES = {
    'runtimes': [
        {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-6', 'isAvailable': True},
        {'identifier': IPHONE27, 'isAvailable': True},
        {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-1-beta', 'isAvailable': False},
    ]
}

DEVICE_TYPES = {
    'devicetypes': [
        {'name': 'iPhone 16', 'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', 'productFamily': 'iPhone'},
        {'name': 'iPhone 17 Pro', 'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'productFamily': 'iPhone'},
        {'name': 'iPad mini (A17 Pro)', 'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17Pro', 'productFamily': 'iPad'},
    ]
}


class SimulatorSelectionTests(unittest.TestCase):
    def select(self, devices, sdk_major=26, name='iPad mini (A17 Pro)', family=None):
        return module.select_device({'devices': devices}, sdk_major, name, family)

    def device(self, identifier, **kwargs):
        return dict(name='iPad mini (A17 Pro)', udid=identifier, **kwargs)

    def test_select_latest_matching_major_not_other_sdk(self):
        self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [self.device('old')], 'com.apple.CoreSimulator.SimRuntime.iOS-26-6': [self.device('current')], 'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device('wrong')]}), 'current')

    def test_duplicate_names_prefer_booted_and_are_order_independent(self):
        devices = [self.device('a', state='Booted'), self.device('z', state='Shutdown')]
        for order in (devices, list(reversed(devices))):
            self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-26-6': order}), 'a')

    def test_unavailable_device_excluded(self):
        self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-26-6': [self.device('z', isAvailable=False), self.device('a', isAvailable=True)]}), 'a')

    def test_no_match_fails_explicitly(self):
        with self.assertRaisesRegex(ValueError, 'No available'):
            self.select({'com.apple.CoreSimulator.SimRuntime.tvOS-26-0': [self.device('wrong')]})

    def test_exact_name_preferred_over_family_fallback(self):
        devices = {
            'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
                iphone('exact'),
                iphone('other', name='iPhone 16e'),
            ],
        }
        self.assertEqual(self.select(devices, 27, 'iPhone 17 Pro', family='iPhone'), 'exact')

    def test_missing_exact_name_falls_back_to_family_on_same_major(self):
        devices = {
            IPHONE27: [iphone('fallback', name='iPhone 16e'), ipad('ipad1')],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-6': [iphone('old')],
        }
        self.assertEqual(self.select(devices, 27, 'iPhone 17 Pro', family='iPhone'), 'fallback')

    def test_family_fallback_never_crosses_sdk_major(self):
        # The only iPhone anywhere is on iOS 26; requesting iOS 27 must not
        # silently downgrade the leg to another SDK.
        devices = {'com.apple.CoreSimulator.SimRuntime.iOS-26-6': [iphone('old')]}
        with self.assertRaisesRegex(ValueError, 'No available iPhone 17 Pro or other iPhone simulator for iOS 27'):
            self.select(devices, 27, 'iPhone 17 Pro', family='iPhone')

    def test_other_family_is_not_an_iphone(self):
        devices = {IPHONE27: [ipad('ipad1')]}
        with self.assertRaisesRegex(ValueError, 'No available'):
            self.select(devices, 27, 'iPhone 17 Pro', family='iPhone')

    def test_unavailable_family_devices_are_filtered(self):
        devices = {IPHONE27: [iphone('z', name='iPhone 16e', isAvailable=False)]}
        with self.assertRaisesRegex(ValueError, 'No available'):
            self.select(devices, 27, 'iPhone 17 Pro', family='iPhone')

    def test_renamed_ipad_cannot_satisfy_iphone_request(self):
        devices = {IPHONE27: [iphone('wrong', deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17Pro')]}
        with self.assertRaisesRegex(ValueError, 'No available'):
            self.select(devices, 27, 'iPhone 17 Pro', family='iPhone')

    def test_custom_named_iphone_uses_actual_device_type(self):
        devices = {IPHONE27: [iphone('actual', name='QA phone', deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.iPhone-16')]}
        self.assertEqual(self.select(devices, 27, 'iPhone 17 Pro', family='iPhone'), 'actual')

    def test_behavior_without_family_is_unchanged(self):
        devices = {IPHONE27: [iphone('other', name='iPhone 16e')]}
        with self.assertRaisesRegex(ValueError, 'No available iPhone 17 Pro simulator for iOS 27'):
            self.select(devices, 27, 'iPhone 17 Pro')


class FakeRunner:
    """Answers simctl list calls and records create attempts."""

    def __init__(self, created_udid='created-udid', fail_types=(), runtimes=None, devicetypes=None):
        self.created_udid = created_udid
        self.fail_types = set(fail_types)
        self.runtimes = runtimes if runtimes is not None else RUNTIMES
        self.devicetypes = devicetypes if devicetypes is not None else DEVICE_TYPES
        self.create_attempts = []

    def __call__(self, command):
        self.last_command = command
        if command[:3] == ['xcrun', 'simctl', 'list']:
            topic = command[3]
            payload = self.runtimes if topic == 'runtimes' else self.devicetypes
            return 0, __import__('json').dumps(payload)
        if command[:3] == ['xcrun', 'simctl', 'create']:
            self.create_attempts.append(command)
            type_id = command[4]
            if type_id in self.fail_types:
                return 69, 'invalid device type'
            return 0, self.created_udid + '\n'
        raise AssertionError(f'unexpected command: {command}')


class SimulatorCreationTests(unittest.TestCase):
    def test_create_uses_newest_available_runtime_of_requested_major(self):
        runner = FakeRunner()
        udid = module.create_family_device('iPhone 17 Pro', 27, 'iPhone', runner=runner)
        self.assertEqual(udid, 'created-udid')
        self.assertEqual(len(runner.create_attempts), 1)
        create = runner.create_attempts[0]
        self.assertEqual(create[4], 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
        # iOS-27-1-beta is unavailable and iOS 26 must never host an iOS 27 leg.
        self.assertEqual(create[5], IPHONE27)

    def test_create_prefers_exact_type_then_tries_family_in_order(self):
        runner = FakeRunner(fail_types={'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'})
        udid = module.create_family_device('iPhone 17 Pro', 27, 'iPhone', runner=runner)
        self.assertEqual(udid, 'created-udid')
        self.assertEqual(runner.create_attempts[-1][3], 'iPhone 16 Floe CI')
        attempted = [attempt[4] for attempt in runner.create_attempts]
        self.assertEqual(attempted, [
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
            'com.apple.CoreSimulator.SimDeviceType.iPhone-16',
        ])

    def test_create_never_uses_another_family_type(self):
        runner = FakeRunner(fail_types={
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
            'com.apple.CoreSimulator.SimDeviceType.iPhone-16',
        })
        with self.assertRaisesRegex(ValueError, 'Could not create'):
            module.create_family_device('iPhone 17 Pro', 27, 'iPhone', runner=runner)
        self.assertNotIn('com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17Pro',
                         [attempt[4] for attempt in runner.create_attempts])

    def test_create_fails_when_no_runtime_of_the_major_is_available(self):
        runner = FakeRunner(runtimes={'runtimes': [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-6', 'isAvailable': True},
        ]})
        with self.assertRaisesRegex(ValueError, 'No available iOS 27 runtime'):
            module.create_family_device('iPhone 17 Pro', 27, 'iPhone', runner=runner)
        self.assertEqual(runner.create_attempts, [])

    def test_create_fails_when_family_type_is_missing(self):
        runner = FakeRunner(devicetypes={'devicetypes': [
            {'name': 'iPad mini (A17 Pro)', 'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17Pro', 'productFamily': 'iPad'},
        ]})
        with self.assertRaisesRegex(ValueError, 'No available iPhone simulator device type'):
            module.create_family_device('iPhone 17 Pro', 27, 'iPhone', runner=runner)


MINI_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro'
CANON_UDID = '00000000-0000-4000-8000-000000000001'


def canonical_config(tmpdir, **overrides):
    import json
    from pathlib import Path
    config = {
        'policy': module.CANONICAL_POLICY,
        'deviceUDID': CANON_UDID,
        'deviceName': 'Synthetic Canonical iPad',
        'deviceType': MINI_TYPE,
        'sdkMajor': 27,
        'family': 'iPad',
    }
    config.update(overrides)
    path = Path(tmpdir) / 'device.json'
    path.write_text(json.dumps(config))
    return path


def live_inventory(udid=CANON_UDID, *, available=True, deleted=False,
                   runtime=IPHONE27, device_type=MINI_TYPE):
    return {'devices': {runtime: [{
        'udid': udid, 'name': 'Synthetic Canonical iPad', 'state': 'Shutdown',
        'isAvailable': available, 'isDeleted': deleted,
        'deviceTypeIdentifier': device_type,
    }]}}


class CanonicalSingleDeviceTests(unittest.TestCase):
    def test_resolve_returns_pinned_existing_device(self):
        config = dict(policy=module.CANONICAL_POLICY, deviceUDID=CANON_UDID,
                      sdkMajor=27, deviceType=MINI_TYPE)
        self.assertEqual(module.resolve_canonical_device(
            config, live_inventory()), CANON_UDID)

    def test_missing_pinned_device_is_actionable_and_never_creates(self):
        config = dict(policy=module.CANONICAL_POLICY, deviceUDID=CANON_UDID,
                      sdkMajor=27)
        with self.assertRaisesRegex(ValueError, 'not present.*Do not create'):
            module.resolve_canonical_device(
                config, {'devices': {IPHONE27: [{'udid': 'OTHER',
                                                 'isAvailable': True}]}})

    def test_unavailable_or_deleted_pinned_device_is_rejected(self):
        config = dict(policy=module.CANONICAL_POLICY, deviceUDID=CANON_UDID,
                      sdkMajor=27)
        for kwargs in ({'available': False}, {'deleted': True}):
            with self.subTest(**kwargs):
                with self.assertRaisesRegex(ValueError, 'unavailable'):
                    module.resolve_canonical_device(
                        config, live_inventory(**kwargs))

    def test_pinned_device_on_wrong_sdk_major_is_not_resolved(self):
        config = dict(policy=module.CANONICAL_POLICY, deviceUDID=CANON_UDID,
                      sdkMajor=27)
        with self.assertRaisesRegex(ValueError, 'not present on an iOS 27'):
            module.resolve_canonical_device(
                config, live_inventory(
                    runtime='com.apple.CoreSimulator.SimRuntime.iOS-26-6'))

    def test_device_type_change_is_rejected(self):
        config = dict(policy=module.CANONICAL_POLICY, deviceUDID=CANON_UDID,
                      sdkMajor=27, deviceType=MINI_TYPE)
        with self.assertRaisesRegex(ValueError, 'device type changed'):
            module.resolve_canonical_device(
                config, live_inventory(device_type='com.apple.CoreSimulator'
                                                  '.SimDeviceType.iPad-9th-generation'))

    def test_missing_config_fails_with_creation_prohibition(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'nothing is created'):
                module.load_canonical_config(Path(tmp) / 'device.json')

    def test_bad_config_is_rejected(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp, policy='anything-else')
            with self.assertRaisesRegex(ValueError, 'expected'):
                module.load_canonical_config(path)
            path = canonical_config(tmp)
            path.write_text(json.dumps({'deviceUDID': 'x'}))
            with self.assertRaisesRegex(ValueError, 'policy'):
                module.load_canonical_config(path)
            path = canonical_config(tmp)
            config = json.loads(path.read_text())
            del config['deviceUDID']
            path.write_text(json.dumps(config))
            with self.assertRaisesRegex(ValueError, 'missing deviceUDID'):
                module.load_canonical_config(path)
            path = canonical_config(tmp)
            path.write_text('[1, 2, 3]')
            with self.assertRaisesRegex(ValueError, 'JSON object'):
                module.load_canonical_config(path)

    def test_legacy_create_blocker_states(self):
        import json
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'device.json'
            with mock.patch.dict(os.environ, {module.CANONICAL_CONFIG_ENV: str(path)}):
                path.write_text('"just a string"')
                self.assertIn('JSON object', module.legacy_create_blocker())
                path.write_text(json.dumps({'policy': module.CANONICAL_POLICY,
                                            'deviceUDID': 'X', 'deviceName': 'Y'}))
                self.assertIn('disabled on this host', module.legacy_create_blocker())
                path.write_text(json.dumps({'policy': 'other'}))
                self.assertIsNone(module.legacy_create_blocker())
            with mock.patch.dict(os.environ,
                                 {module.CANONICAL_CONFIG_ENV:
                                  str(Path(tmp) / 'absent.json')}):
                self.assertIsNone(module.legacy_create_blocker())

    def test_config_path_priority(self):
        import os
        from pathlib import Path
        from unittest import mock
        explicit = Path('/tmp/explicit-device.json')
        with mock.patch.dict(os.environ,
                             {module.CANONICAL_CONFIG_ENV: '/tmp/env-device.json'}):
            self.assertEqual(module.canonical_config_path(explicit), explicit)
            self.assertEqual(str(module.canonical_config_path(None)),
                             '/tmp/env-device.json')
        with mock.patch.dict(os.environ, clear=False):
            os.environ.pop(module.CANONICAL_CONFIG_ENV, None)
            self.assertTrue(
                str(module.canonical_config_path(None)).endswith(
                    'Local/Private/simulator-single-device-20261018/device.json'))

    def test_lock_is_exclusive_and_released_on_close(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            config = module.load_canonical_config(path)
            fd = module.acquire_device_lock(config, path)
            try:
                with self.assertRaisesRegex(ValueError, 'held by another'):
                    module.acquire_device_lock(config, path)
            finally:
                os.close(fd)
            fd2 = module.acquire_device_lock(config, path)
            os.close(fd2)

    def test_lock_wait_polls_with_bounded_sleep_and_succeeds_after_release(self):
        import os
        import threading
        import time
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            config = module.load_canonical_config(path)
            holder_fd = module.acquire_device_lock(config, path)
            real_sleep = time.sleep
            durations = []

            def recording_sleep(seconds):
                durations.append(seconds)
                real_sleep(0.05)

            def release_soon():
                real_sleep(0.3)
                os.close(holder_fd)

            thread = threading.Thread(target=release_soon)
            thread.start()
            try:
                with mock.patch.object(time, 'sleep', recording_sleep):
                    started = time.monotonic()
                    fd = module.acquire_device_lock(config, path, wait_seconds=4)
                    elapsed = time.monotonic() - started
                os.close(fd)
            finally:
                thread.join()
            self.assertTrue(
                durations, 'the retry branch must sleep between polls, not busy-spin')
            self.assertTrue(all(duration == 0.5 for duration in durations),
                            durations)
            self.assertGreaterEqual(elapsed, 0.2)
            self.assertLess(elapsed, 4)

class FakeSimctlListRunner:
    """Answers only the read-only 'simctl list devices -j' call."""

    def __init__(self, inventory):
        self.inventory = inventory
        self.calls = []

    def __call__(self, command):
        self.calls.append(list(command))
        if command[:4] == ['xcrun', 'simctl', 'list', 'devices']:
            return 0, json.dumps(self.inventory)
        raise AssertionError(f'unexpected simctl call: {command}')


class CanonicalMainModeTests(unittest.TestCase):
    def test_canonical_prints_pinned_udid_from_piped_inventory(self):
        import io
        import json
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            captured = io.StringIO()
            with mock.patch('sys.stdin', io.StringIO(json.dumps(live_inventory()))), \
                    mock.patch('sys.stdout', captured):
                code = module.main(argv=['--canonical', '--config', str(path)])
            self.assertEqual(code, 0)
            self.assertEqual(captured.getvalue().strip(), CANON_UDID)

    def test_canonical_rejects_mixed_flags(self):
        import io
        from unittest import mock
        with mock.patch('sys.stderr', new_callable=io.StringIO) as err:
            with self.assertRaises(SystemExit) as exit_state:
                module.main(argv=['--canonical', '--sdk-major', '27',
                                  '--name', 'iPad mini (A17 Pro)'])
        self.assertEqual(exit_state.exception.code, 1)
        self.assertIn('used alone', err.getvalue())

    def test_with_lock_validates_live_inventory_then_exports_udid(self):
        import os
        import sys
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            out_file = Path(tmp) / 'udid.txt'
            runner = FakeSimctlListRunner(live_inventory())
            with mock.patch.dict(os.environ, {'FLOE_TEST_UDID_FILE': str(out_file)}):
                code = module.main(
                    argv=['--canonical', '--config', str(path), '--with-lock',
                          sys.executable, '-c',
                          'import os,pathlib;'
                          'pathlib.Path(os.environ["FLOE_TEST_UDID_FILE"]).write_text('
                          'os.environ["FLOE_SIMULATOR_UDID"])'],
                    runner=runner)
            self.assertEqual(code, 0)
            self.assertEqual(out_file.read_text(), CANON_UDID)
            # Only the read-only inventory call was issued: never create/boot.
            self.assertEqual(runner.calls,
                             [['xcrun', 'simctl', 'list', 'devices', '-j']])

    def test_with_lock_fails_before_child_when_device_missing(self):
        import io
        import sys
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            marker = Path(tmp) / 'child-ran'
            runner = FakeSimctlListRunner({'devices': {}})
            captured = io.StringIO()
            with mock.patch('sys.stderr', captured):
                with self.assertRaises(SystemExit) as exit_state:
                    module.main(
                        argv=['--canonical', '--config', str(path), '--with-lock',
                              sys.executable, '-c',
                              f'import pathlib;pathlib.Path({str(marker)!r}).touch()'],
                        runner=runner)
            self.assertEqual(exit_state.exception.code, 1)
            self.assertIn('not present', captured.getvalue())
            self.assertFalse(marker.exists())

    def test_with_lock_fails_before_child_when_device_unavailable(self):
        import io
        import sys
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            marker = Path(tmp) / 'child-ran'
            runner = FakeSimctlListRunner(live_inventory(available=False))
            captured = io.StringIO()
            with mock.patch('sys.stderr', captured):
                with self.assertRaises(SystemExit) as exit_state:
                    module.main(
                        argv=['--canonical', '--config', str(path), '--with-lock',
                              sys.executable, '-c',
                              f'import pathlib;pathlib.Path({str(marker)!r}).touch()'],
                        runner=runner)
            self.assertEqual(exit_state.exception.code, 1)
            self.assertIn('unavailable', captured.getvalue())
            self.assertFalse(marker.exists())

    def test_with_lock_blocks_while_another_holder_holds_the_lock(self):
        import io
        import os
        import sys
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            config = module.load_canonical_config(path)
            holder_fd = module.acquire_device_lock(config, path)
            runner = FakeSimctlListRunner(live_inventory())
            try:
                captured = io.StringIO()
                with mock.patch('sys.stderr', captured):
                    with self.assertRaises(SystemExit) as exit_state:
                        module.main(argv=['--canonical', '--config', str(path),
                                          '--with-lock', sys.executable,
                                          '-c', 'pass'], runner=runner)
                self.assertEqual(exit_state.exception.code, 1)
                self.assertIn('held by another', captured.getvalue())
            finally:
                os.close(holder_fd)
            # After release the same wrapper proceeds.
            self.assertEqual(module.main(
                argv=['--canonical', '--config', str(path), '--with-lock',
                      sys.executable, '-c', 'pass'], runner=runner), 0)

    def test_legacy_create_fails_closed_when_local_policy_exists(self):
        import io
        import os
        import json
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            path = canonical_config(tmp)
            runner = FakeSimctlListRunner(live_inventory())
            captured = io.StringIO()
            with mock.patch.dict(os.environ, {module.CANONICAL_CONFIG_ENV: str(path)}), \
                    mock.patch('sys.stdin', io.StringIO(json.dumps(
                        {'devices': {}}))), \
                    mock.patch('sys.stderr', captured):
                with self.assertRaises(SystemExit) as exit_state:
                    module.main(argv=['--sdk-major', '27',
                                      '--name', 'iPad mini (A17 Pro)',
                                      '--family', 'iPad', '--create'], runner=runner)
            self.assertEqual(exit_state.exception.code, 1)
            self.assertIn('disabled on this host', captured.getvalue())
            self.assertEqual(runner.calls, [])

    def test_legacy_create_still_works_without_a_policy_file(self):
        import io
        import json
        import os
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            absent = str(Path(tmp) / 'absent-device.json')
            runner = FakeRunner()
            captured = io.StringIO()
            with mock.patch.dict(os.environ, {module.CANONICAL_CONFIG_ENV: absent}), \
                    mock.patch('sys.stdin', io.StringIO(json.dumps({'devices': {}}))):
                with mock.patch('sys.stdout', captured):
                    code = module.main(argv=['--sdk-major', '27',
                                             '--name', 'iPad mini (A17 Pro)',
                                             '--family', 'iPad', '--create'],
                                       runner=runner)
            self.assertEqual(code, 0)
            self.assertEqual(captured.getvalue().strip(), 'created-udid')
            self.assertEqual(len(runner.create_attempts), 1)


if __name__ == '__main__':
    unittest.main()
