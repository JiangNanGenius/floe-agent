"""Real subprocess cancellation regression; all state is isolated in a temporary directory."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest


class CancellationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.TemporaryDirectory(prefix="floe-cancel-test-")
        for name in ("CLOUD", "STATE", "CONFIG"):
            os.environ[f"FLOE_{name}_ROOT"] = str(Path(cls.root.name) / name)
        source = Path(__file__).resolve().parents[1] / "Sources/FloeExecution/Resources/RemoteAgent/floe_remote_agent.py"
        spec = importlib.util.spec_from_file_location("floe_test_agent", source)
        cls.agent = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.agent)

    @classmethod
    def tearDownClass(cls):
        cls.root.cleanup()

    def launch(self, task_id, command):
        return self.agent.launch_task({"task_id": task_id, "command": command,
                                      "target": {"kind": "host"}, "explicit_host_authority": True}, "device-a")

    def wait(self, task_id):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            record = self.agent.task_record(task_id)
            if record["state"] in ("cancelled", "succeeded", "failed"):
                return record
            time.sleep(0.03)
        self.fail("runner did not produce a terminal result")

    def test_cancel_and_repeated_request(self):
        self.launch("cancel", "sleep 30")
        self.assertEqual(self.agent.cancel_task("cancel", "device-a")["state"], "cancelRequested")
        self.agent.cancel_task("cancel", "device-a")
        result = self.wait("cancel")
        self.assertEqual(result["state"], "cancelled")
        self.assertEqual(self.agent.cancel_task("cancel", "device-a"), result)

    def test_completed_result_preserved(self):
        self.launch("completed", "exit 0")
        result = self.wait("completed")
        self.assertEqual(result["state"], "succeeded")
        self.assertEqual(self.agent.cancel_task("completed", "device-a"), result)

    def test_other_device_rejected(self):
        self.launch("ownership", "sleep 30")
        try:
            with self.assertRaisesRegex(ValueError, "another device"):
                self.agent.cancel_task("ownership", "device-b")
            self.assertFalse((self.agent.task_dir("ownership") / "cancel.request").exists())
        finally:
            self.agent.cancel_task("ownership", "device-a")
            self.wait("ownership")

    def test_legacy_pid_never_signalled(self):
        directory = self.agent.task_dir("legacy")
        directory.mkdir()
        self.agent.atomic_json(directory / "task.json", {"id": "legacy", "pid": os.getpid(), "device_id": "device-a"})
        with self.assertRaisesRegex(ValueError, "legacy"):
            self.agent.cancel_task("legacy", "device-a")
        self.assertFalse((directory / "cancel.request").exists())

    def test_path_traversal_rejected(self):
        with self.assertRaises(ValueError):
            self.agent.cancel_task("../escape")


if __name__ == "__main__":
    unittest.main()
