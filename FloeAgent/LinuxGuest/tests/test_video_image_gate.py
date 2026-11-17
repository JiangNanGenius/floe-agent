"""A video-enabled image must expose the verified codec to project roots."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GATE = Path(__file__).resolve().parents[1] / "virtio-media/boot_overlay/image_gate.py"


class ProjectCodecGateTests(unittest.TestCase):
    def test_video_manifest_requires_matching_project_codec(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            overlay, base = root / "overlay", root / "base"
            client = overlay / "usr/local/bin/floe-codec"
            client.parent.mkdir(parents=True)
            modules = overlay / "lib/modules"
            modules.mkdir(parents=True)
            (modules / "modules.dep").write_text("")
            # Minimal ELF header is enough for this metadata contract test.
            elf = bytearray(20)
            elf[:6] = b"\x7fELF\x02\x01"
            elf[18:20] = (183).to_bytes(2, "little")
            client.write_bytes(elf)
            client.chmod(0o755)
            (overlay / "INSTALL_RECEIPT.json").write_text(json.dumps({
                "kernelRelease": "6.12.107+deb13-arm64",
                "modules": [],
                "floeCodec": {"sha256": hashlib.sha256(elf).hexdigest()},
            }))
            manifest = root / "manifest.json"
            manifest.write_text('{"deviceCapabilities":{"videoAcceleration":true}}')

            def check(*args):
                result = subprocess.run(
                    [sys.executable, str(GATE), "--overlay", str(overlay),
                     "--manifest", str(manifest), *args],
                    capture_output=True, text=True, check=False,
                )
                return result.returncode, json.loads(result.stdout)

            code, report = check()
            self.assertNotEqual(code, 0)
            self.assertIn("requires --base-root", " ".join(report["errors"]))
            code, report = check("--base-root", str(base))
            self.assertNotEqual(code, 0)
            self.assertIn("missing /base/usr/local/bin/floe-codec", report["errors"])
            installed = base / "usr/local/bin/floe-codec"
            installed.parent.mkdir(parents=True)
            installed.write_bytes(elf)
            installed.chmod(0o755)
            code, report = check("--base-root", str(base))
            self.assertEqual(code, 0, report)
            self.assertIn("project-client-installed", report["checks"])
            installed.write_bytes(elf + b"changed")
            code, report = check("--base-root", str(base))
            self.assertNotEqual(code, 0)
            self.assertIn("project floe-codec differs from the verified overlay client", report["errors"])


if __name__ == "__main__":
    unittest.main()
