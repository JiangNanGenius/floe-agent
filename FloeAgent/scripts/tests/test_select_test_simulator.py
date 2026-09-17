import importlib.util
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


if __name__ == '__main__':
    unittest.main()
