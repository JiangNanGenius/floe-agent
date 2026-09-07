#!/usr/bin/env python3
"""Pinned build-time pure dependencies; never a runtime native installer."""
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

BASE = "https://files.pythonhosted.org/packages/"
PACKAGES = [
    ("ec/57/56b9bcc3c9c6a792fcbaf139543cee77261f3651ca9da0c93f5c1221264b/python_dateutil-2.9.0.post0-py2.py3-none-any.whl", "a8b2bc7bffae282281c8140a97d3aa9c14da0b136dfe83f850eea9a5f7470427"),
    ("b7/ce/149a00dd41f10bc29e5921b496af8b574d8413afcd5e30dfa0ed46c2cc5e/six-1.17.0-py2.py3-none-any.whl", "4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274"),
    ("e5/6d/b53b99a9f2766d095985947a5782f1702cabb129a34f7a802d7197af832f/tzdata-2026.3-py2.py3-none-any.whl", "dc096730c87af6cab1b171c9d532be840741ff5d459015e7f6947bd7d7e54931"),
]
root = Path(__file__).resolve().parent.parent / "FloeApp/Resources/python/lib/python3.13/site-packages"
root.mkdir(parents=True, exist_ok=True)
for path, sha in PACKAGES:
    with urllib.request.urlopen(BASE + path, timeout=60) as response:
        data = response.read(8_388_609)
    if len(data) > 8_388_608 or hashlib.sha256(data).hexdigest() != sha:
        raise RuntimeError("Pure dependency digest mismatch")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            name = Path(entry.filename)
            if name.is_absolute() or ".." in name.parts or name.suffix in {".so", ".dylib", ".a"}:
                raise RuntimeError("Unsafe pure dependency")
        archive.extractall(root)
    print("Bundled pinned " + Path(path).name)
