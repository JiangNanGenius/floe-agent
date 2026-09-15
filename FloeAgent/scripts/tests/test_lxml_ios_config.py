import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("lxml_config", Path(__file__).resolve().parents[1] / "lxml_ios_config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class TargetSelectionTests(unittest.TestCase):
    def test_device_and_simulator_never_share_native_libraries(self):
        device = config.settings("ios-17.0-arm64-iphoneos", Path("/candidate"), True)
        simulator = config.settings("ios-17.0-arm64-iphonesimulator", Path("/candidate"), True)
        self.assertIn("/floe-native/iphoneos/lib", device["--libs"])
        self.assertNotIn("iphonesimulator", device["--libs"])
        self.assertIn("/floe-native/iphonesimulator/lib", simulator["--libs"])
        self.assertIn("/include/libxml2", device["--cflags"])

    def test_host_or_unsupported_architecture_fails_before_linking(self):
        for platform in ("macosx-15.0-arm64", "ios-17.0-x86_64-iphonesimulator", "linux-aarch64", ""):
            with self.subTest(platform=platform), self.assertRaises(ValueError):
                config.settings(platform, Path("/candidate"), False)


if __name__ == "__main__":
    unittest.main()
