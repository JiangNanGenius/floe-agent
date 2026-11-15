#!/usr/bin/env python3
"""Prepare pinned JS resources for the independent component host, or check them read-only.

The App will use its existing download/resource service; this is a development helper.
No native code is downloaded and no engine code is executed by this script.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import tempfile
import urllib.request

PHASER = "a9965625f49cf366584f454556b039e06e8adad6"
EXPECTED = {
    "phaser.js": "2e1bc84f885ab5c62b11ebb72492bb334159ac5678b664c7cb2942fc979e44e3",
    "LICENSE.phaser.md": "c3123cd25de4eccf1fd5a5a0a6fc872299116d1dbbb48b00f2554a4c35220a65",
    "THIRD-PARTY-NOTICES.txt": "fd57bb945a3993569b6eae1833d25e9eb1e2a988cca541ba8dc770b0b7b7792b",
}


def verify(root):
    for name, digest in EXPECTED.items():
        path = root / name
        if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("Resource missing or changed: " + name)


def fetch(url, git_blob, maximum):
    with urllib.request.urlopen(url, timeout=45) as response:
        data = response.read(maximum + 1)
    blob = hashlib.sha1(("blob " + str(len(data)) + "\0").encode() + data).hexdigest()
    if len(data) > maximum or blob != git_blob:
        raise ValueError("Upstream size or pinned Git blob mismatch: " + url)
    return data


def prepare(target):
    if target.exists():
        raise FileExistsError("Destination exists; use --check to verify it without writing")
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".phaser-resource-", dir=target.parent))
    try:
        base = "https://raw.githubusercontent.com/phaserjs/phaser/" + PHASER + "/"
        engine = fetch(base + "dist/phaser-arcade-physics.min.js", "dcd17e9119c1e9f2e2932aed32aa1bbd05f199e0", 1_500_000)
        license = fetch(base + "LICENSE.md", "48792fed249c6ac1ef1b491f4b22dc8f30af7c12", 10_000)
        source = fetch(base + "dist/phaser-arcade-physics.js", "c904fe3fc4719c8f8c1e586d9452e20a864c78dc", 8_000_000).decode()
        emitter_url = "https://raw.githubusercontent.com/primus/eventemitter3/5.0.1/LICENSE"
        emitter_license = fetch(emitter_url, "abcbd54e5eefdac272de763e774ca75825ca55ce", 10_000)
        comments = sorted(set(block for block in re.findall(r"/\*.*?\*/", source, re.S)
                              if re.search(r"copyright|@license|permission to|redistributions of", block, re.I)))
        notices = ("Notices retained from Phaser 3.90.0 Arcade distribution, source commit " + PHASER
            + ".\nNo Spine or Matter engine is included in this distribution.\n\nEventEmitter3 5.0.1\nSource: "
            + emitter_url + "\n\n" + emitter_license.decode()
            + "\n\nOriginal upstream copyright and license comment blocks\n\n"
            + "\n\n".join(comments) + "\n").encode()
        for name, data in {"phaser.js": engine, "LICENSE.phaser.md": license, "THIRD-PARTY-NOTICES.txt": notices}.items():
            (stage / name).write_bytes(data)
        verify(stage)
        manifest = {"engine": "phaser", "version": "3.90.0", "sourceCommit": PHASER,
                    "distribution": "Arcade physics", "sourceBaseURL": base,
                    "files": EXPECTED, "upstreamNoticeBlocks": len(comments),
                    "eventEmitterVersion": "5.0.1", "nativeCode": False}
        (stage / "resource-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        stage.rename(target)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Read-only local verification; no network or writes")
    args = parser.parse_args()
    if not args.output.is_absolute():
        parser.error("Use an explicit absolute resource directory")
    if args.check:
        verify(args.output)
    else:
        prepare(args.output)
    print(json.dumps({"result": "verified", "engine": "phaser", "version": "3.90.0", "readOnly": args.check}))
