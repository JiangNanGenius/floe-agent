"""Real PTY lifecycle checks; never touches the user's configured agent state."""
import base64
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest


class ShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.TemporaryDirectory(prefix="floe-shell-test-")
        cls.old_environment = dict(os.environ)
        for name in ("CLOUD", "STATE", "CONFIG"):
            os.environ[f"FLOE_{name}_ROOT"] = str(Path(cls.root.name) / name)
        os.environ["SHELL"] = "/bin/sh"
        source = Path(__file__).resolve().parents[1] / "Sources/FloeExecution/Resources/RemoteAgent/floe_remote_agent.py"
        spec = importlib.util.spec_from_file_location("shell_test_agent", source)
        cls.agent = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.agent)

    def tearDown(self):
        for key, entry in list(self.agent.SHELLS.items()):
            self.agent.shell_close(key, entry["device_id"])

    @classmethod
    def tearDownClass(cls):
        os.environ.clear()
        os.environ.update(cls.old_environment)
        cls.root.cleanup()

    def test_exchange_and_owner(self):
        key = self.agent.shell_open({}, "a")["shell_id"]
        with self.assertRaisesRegex(ValueError, "another device"):
            self.agent.shell_io(key, {}, "b")
        with self.assertRaisesRegex(ValueError, "another device"):
            self.agent.shell_close(key, "b")
        result = self.agent.shell_io(key, {"input_base64": base64.b64encode(b"printf 'floe-%s\\n' verified\n").decode()}, "a")
        self.assertIn(b"floe-verified", base64.b64decode(result["data_base64"]))

    def test_close_is_bounded_and_repeatable(self):
        key = self.agent.shell_open({}, "a")["shell_id"]
        self.agent.shell_io(key, {"input_base64": base64.b64encode(b"trap '' HUP TERM\n").decode()}, "a")
        start = time.monotonic()
        self.assertTrue(self.agent.shell_close(key, "a")["ok"])
        self.assertLess(time.monotonic() - start, 2)
        self.assertTrue(self.agent.shell_close(key, "a")["ok"])

    def test_expiry_without_client_poll(self):
        key = self.agent.shell_open({}, "a")["shell_id"]
        self.agent.SHELLS[key]["created"] -= self.agent.SHELL_MAX_AGE + 1
        self.agent.shell_cleanup()
        self.assertNotIn(key, self.agent.SHELLS)

    def test_per_device_limit(self):
        for _ in range(self.agent.SHELL_MAX_PER_DEVICE):
            self.agent.shell_open({}, "a")
        with self.assertRaisesRegex(ValueError, "limit"):
            self.agent.shell_open({}, "a")
        self.assertIn("shell_id", self.agent.shell_open({}, "b"))


if __name__ == "__main__":
    unittest.main()
