import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('select_simulator', Path(__file__).resolve().parents[1] / 'select_test_simulator.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SimulatorSelectionTests(unittest.TestCase):
    def select(self, devices):
        return module.select_device({'devices': devices}, 26, 'iPad mini (A17 Pro)')

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
