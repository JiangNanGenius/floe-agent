#!/usr/bin/env python3
"""Prepare pinned narrative/fantasy-console engine resources for the independent
FloeGameNarrativeKit component host, or verify them read-only.

Engines and pins:
  inkjs      2.4.0   npm tarball (MIT)             engine + compiler dist
  sugarcube  2.37.3  GitHub release zip (BSD-2)    Twine 2 story format runtime
  wasm4      2.7.1   npm tarball (ISC)             official web runtime bundle
  tic80      v1.4.1  reviewed source rebuild + exact corresponding source (MIT/LGPL and original notices)
  microstudio 80594cff51312b32db874a33d928876b23ab7718  GitHub raw (MIT)  web runtime modules

The App will use its existing download/resource service; this is a development
helper. No engine code is executed by this script. `--check` is read-only and
never downloads or rewrites anything.
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent

INKJS_VERSION = "2.4.0"
SUGARCUBE_VERSION = "2.37.3"
WASM4_VERSION = "2.7.1"
TIC80_VERSION = "v1.4.1"
MICROSTUDIO_COMMIT = "80594cff51312b32db874a33d928876b23ab7718"

INKJS_TARBALL = "https://registry.npmjs.org/inkjs/-/inkjs-2.4.0.tgz"
SUGARCUBE_ZIP = ("https://github.com/tmedwards/sugarcube-2/releases/download/v2.37.3/"
                 "sugarcube-2.37.3-for-twine-2.1-local.zip")
WASM4_TARBALL = "https://registry.npmjs.org/wasm4/-/wasm4-2.7.1.tgz"
TIC80_TARBALL = "https://github.com/nesbox/TIC-80/releases/download/v1.4.1/tic80-v1.4-players.tar.gz"
TIC80_LICENSE = "https://raw.githubusercontent.com/nesbox/TIC-80/v1.4.1/LICENSE"
MICROSTUDIO_RAW = ("https://raw.githubusercontent.com/pmgl/microstudio/"
                   + MICROSTUDIO_COMMIT + "/static/js/")
MICROSTUDIO_LICENSE = ("https://raw.githubusercontent.com/pmgl/microstudio/"
                       + MICROSTUDIO_COMMIT + "/LICENSE.txt")

# (destination relative path, sha256, source description)
FIXED = {
    "tic80/source/TIC80-EXACT-CORRESPONDING-SOURCE.zip": ("5717a89efbb1604e0bbc903154827efe973e306cec7b9ed7882e0b3e3548d08e", "exact complete source and relink companion"),
    "tic80/source/CURRENT-BUILD-AND-RELINK.json": ("34d17969bc251feec9ff944c1f637fa8982dd4eaf0ff41ef1fae1ca6a19749cb", "current source build receipt"),
    "inkjs/inkjs.js": ("23d707b76e9b759a25803c193da8e32e04f727dd13a54ed1df8a6a59dd909b9e", "npm:inkjs@2.4.0 dist/ink-full.js"),
    "inkjs/LICENSE.inkjs.txt": ("040e957a77e3e19432e265cb549d5c3b4ca6f3551e24d22b81785ffd1bc2b67b", "npm:inkjs@2.4.0 LICENSE.md"),
    "sugarcube/sugarcube-format.js": ("64ccdac806a162d250273aba3c39aee85765fedab4cf70e6176154a8c34b8820", "sugarcube-2.37.3-for-twine-2.1-local.zip format.js"),
    "sugarcube/LICENSE.sugarcube.txt": ("bb227ad97f6422347e1e64ad9211d40215e92edf47940c1382973c2a27eb8b27", "sugarcube-2.37.3-for-twine-2.1-local.zip LICENSE"),
    "wasm4/wasm4.js": ("266557b8523c0d6af73e506e326fbc7fcdf4a45c23420afb553f9ce8f4156c8b", "npm:wasm4@2.7.1 assets/runtime/slim/wasm4.js"),
    "wasm4/wasm4.css": ("98b8f8fccb57578e57361a03df2522eab6457363508a76f3b5cef1520e332aac", "npm:wasm4@2.7.1 assets/runtime/slim/wasm4.css"),
    "wasm4/LICENSE.wasm4.txt": ("57dece2bb0324db24532eba37aa2f9103e2f7f96bfbfea535358bf66ba5a1f1b", "npm:wasm4@2.7.1 LICENSE.txt"),
    "tic80/tic80.js": ("71c7afcb770410bb01806f268203839e91578fb81d6ca4b86ca8972de532c02d", "reviewed source rebuild; resource revision 1.4.1-floe-cleared-assets-1"),
    "tic80/tic80js.wasm": ("9fc28f31dd953eb5350cab5823f4e2dd063516895a0d356d3b5312d6673b8f0c", "reviewed source rebuild; resource revision 1.4.1-floe-cleared-assets-1"),
    "tic80/LICENSE.tic80.txt": ("f78d627327e763b070de95b2da58c5f040343a5290961d7fc88c578ae4c59f33", "TIC-80 LICENSE @ v1.4.1"),
    "microstudio/LICENSE.microstudio.txt": ("0089ad4274aa599e2809e721a580e8f652a6a0397875f82fe12a2877db12d602", "pmgl/microstudio LICENSE.txt @ " + MICROSTUDIO_COMMIT),
}

# Selected transitive notices that must travel with conditional artifacts.
# These are not engine downloads; they are the license owner's frozen local
# augmentation bundle (files/ plus tic80/source/SOURCE-OFFER.md and archives).
LICENSE_BUNDLES = {
    "tic80": {
        "topLevel": "MIT (top-level TIC-80)",
        "selected": [
            "GPL-3.0-or-later", "LGPL-2.1-or-later (blip_buf)", "BSD-3-Clause",
            "0BSD", "Zlib", "libpng-2.0", "MIT", "MiniScript2-MIT",
            "Gravity-MIT", "miniaudio-MIT-0-or-Unlicense",
            "Unlicense / Public-Domain",
        ],
        "files": [
            "tic80/THIRD-PARTY-NOTICES.md",
            "tic80/source/SOURCE-OFFER.md",
            "tic80/LICENSES/0BSD.txt", "tic80/LICENSES/BSD-3-Clause.txt",
            "tic80/LICENSES/GPL-3.0-or-later.txt", "tic80/LICENSES/Gravity-MIT.txt",
            "tic80/LICENSES/LGPL-2.1-or-later-blip_buf.txt",
            "tic80/LICENSES/LGPL-2.1-or-later.txt",
            "tic80/LICENSES/LicenseRef-Public-Domain.txt", "tic80/LICENSES/MIT.txt",
            "tic80/LICENSES/MiniScript2-MIT.txt", "tic80/LICENSES/Unlicense.txt",
            "tic80/LICENSES/Zlib.txt", "tic80/LICENSES/libpng-2.0.txt",
            "tic80/LICENSES/miniaudio-MIT-0-or-Unlicense.txt",
        ],
    },
    "wasm4": {
        "topLevel": "ISC (top-level WASM-4)",
        "selected": ["Lit 3.1.2 BSD-3-Clause", "Press Start 2P OFL-1.1"],
        "files": ["wasm4/THIRD-PARTY-NOTICES.txt", "wasm4/LIT-3.1.2-BSD-3-Clause.txt",
                  "wasm4/PRESS-START-2P-OFL-1.1.txt"],
    },
    "sugarcube": {
        "topLevel": "BSD-2-Clause (top-level SugarCube)",
        "selected": ["jQuery 3.7.1 MIT", "jQuery throttle/debounce MIT",
                     "es5-shim MIT", "es6-shim MIT", "imagesLoaded MIT",
                     "EvEmitter MIT", "seedrandom MIT", "normalize.css MIT",
                     "lz-string MIT", "FileSaver MIT", "classList Unlicense"],
        "files": [
            "sugarcube/THIRD-PARTY-NOTICES.txt",
            "sugarcube/licenses/FileSaver-MIT.txt",
            "sugarcube/licenses/classList-Unlicense.txt",
            "sugarcube/licenses/es5-shim-4.5.14-LICENSE.txt",
            "sugarcube/licenses/es6-shim-0.35.4-LICENSE.txt",
            "sugarcube/licenses/ev-emitter-1.1.0-MIT.txt",
            "sugarcube/licenses/imagesLoaded-4.1.4-MIT.txt",
            "sugarcube/licenses/jquery-3.7.1-LICENSE.txt",
            "sugarcube/licenses/jquery-throttle-debounce-1.1-LICENSE.txt",
            "sugarcube/licenses/lz-string-1.5.0-LICENSE.txt",
            "sugarcube/licenses/normalize.css-3.0.3-LICENSE.txt",
            "sugarcube/licenses/seedrandom-3.0.5-MIT.txt",
        ],
    },
}

# Frozen SHA-256 receipt for the selected notice/source bundle. `--check`
# verifies every present file; a partially applied bundle is a failure.
AUGMENTATION_HASHES = {
    "tic80/LICENSES/0BSD.txt": "e3f18c71e10d673590eb9856c1d79dd3b4b0d65404efb5e8584dbede7edd608b",
    "tic80/LICENSES/BSD-3-Clause.txt": "5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d",
    "tic80/LICENSES/GPL-3.0-or-later.txt": "fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0",
    "tic80/LICENSES/Gravity-MIT.txt": "640152b59af917876ef4728ddb7f8824e42b6fbab8ee6fd5ba59cfd8c1e21e74",
    "tic80/LICENSES/LGPL-2.1-or-later-blip_buf.txt": "319daefe38ebeead3df178e5937898a52d67c0c795f54f1c0bb10ac3b9cffb63",
    "tic80/LICENSES/LGPL-2.1-or-later.txt": "5749785c8bdefafcb5d798270ed0a967036fe2ca63dcedade1627565dfef81d2",
    "tic80/LICENSES/LicenseRef-Public-Domain.txt": "407aad5685ffaa4f6fd27b89cde6606629bf081da5bc156841ed22dae998544a",
    "tic80/LICENSES/MIT.txt": "b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5",
    "tic80/LICENSES/MiniScript2-MIT.txt": "9ead32bdfceaaf8a62992d936e529bee491f1fab1dc28bf9a35383acb2843e70",
    "tic80/LICENSES/Unlicense.txt": "0bdebfeda07d45dada625ae1317c6f833186e798b171d0db640bcf32e92a8240",
    "tic80/LICENSES/Zlib.txt": "bfb1112d49db5b1daecdfef24bd7e2f3ea0bafb33aa67aa0ab51e2bf8407c03d",
    "tic80/LICENSES/libpng-2.0.txt": "f207d0f7375b977f76ce2437962c1c12a646f15cda3df48d5472ac95eb68e8ff",
    "tic80/LICENSES/miniaudio-MIT-0-or-Unlicense.txt": "bd3d6cac4cc7cedde4d51c00a8e157ecdc675b6b98d201945c66fc62728e7e9d",
    "tic80/THIRD-PARTY-NOTICES.md": "ce637ceabf8794820a9a328189cea9cb3310e4179c490b2bb8babd7628edf567",
    "tic80/source/SOURCE-OFFER.md": "066b181f1cca08ec5b85adaf064438fc281bbe58e0f8934c6d0e4f395f461d78",
    "tic80/source/TIC-80-b3dbd59-source.tar.gz": "d5d95c1e591602ce9574d363fadaab60cc5433e368c07a1745a288040c21e569",
    "tic80/source/TIC80-SUBMODULE-PINS.json": "65ba3e857571f0f1738300bb1c04e06120bdd8d769070f9c36d046ae90e4edab",
    "tic80/source/blip-buf-330226d-source.tar.gz": "e86870ecb4b7c3feac6afbf5ddd0aff809e14b2d16d9bde251b712fd4ecd6d99",
    "wasm4/LIT-3.1.2-BSD-3-Clause.txt": "45d31799d0db956cc3eb5469346abbd9b7025babc5ff29fab10d7095da992ef1",
    "wasm4/PRESS-START-2P-OFL-1.1.txt": "1ce424c20a36bc74b3001ed50f34c0e2d91a6d8ba941f2dacc7587d6c36a1ae7",
    "wasm4/THIRD-PARTY-NOTICES.txt": "0dc82dd67d5a6e704ad06d9c3b9dc8e15a3f84e5739992f054740b8b40ba86b5",
    "sugarcube/THIRD-PARTY-NOTICES.txt": "ccfc10de3c1ea3c1fa7c49473b1ef79d51f251febde5e763b86f5a4be9e81a1c",
    "sugarcube/licenses/FileSaver-MIT.txt": "2d1d7a93b46e4274355ac2904428707c4ee47ee8c6029fa394ebf405648d3f63",
    "sugarcube/licenses/classList-Unlicense.txt": "ca2abdf695884c77ea4b4a5b64ca7b732d9d9dbade4eebc1c2e76c53e9e3bc83",
    "sugarcube/licenses/es5-shim-4.5.14-LICENSE.txt": "68f7e459f79180b490520f06eddb1715650d5f1af5583ff3f8447e795b2a6a2f",
    "sugarcube/licenses/es6-shim-0.35.4-LICENSE.txt": "ac03daa0b0495dcff2c6c6541a2b5808c32ea14ddf8804709dcfdb3f7a46543e",
    "sugarcube/licenses/ev-emitter-1.1.0-MIT.txt": "67d7aeb3eec70dfb944c9de5bacd4b14997ff584a500544475b943779332c2c3",
    "sugarcube/licenses/imagesLoaded-4.1.4-MIT.txt": "19f5e29a01e16cfd404b3bf8ca2c2f338c5abb7b215efc9ddd898a6d1e74e71d",
    "sugarcube/licenses/jquery-3.7.1-LICENSE.txt": "d4db9ebe6f29f5168eac45ad713f055623ac5d0dcd5ba92da23d650ae012020d",
    "sugarcube/licenses/jquery-throttle-debounce-1.1-LICENSE.txt": "1c53a0aa7fd459dab0d144cdc89a13686597ddbcf106fb9dee81435d3d8631be",
    "sugarcube/licenses/lz-string-1.5.0-LICENSE.txt": "433fc9dfe659dbfb1e91eed8351f13651e97bfa3ac6d03394c3d63f61d4bbc80",
    "sugarcube/licenses/normalize.css-3.0.3-LICENSE.txt": "8781bc9996713938f6baea8a10c8426f9ae06778e562fafe5353669ae6c05f07",
    "sugarcube/licenses/seedrandom-3.0.5-MIT.txt": "d83e5c9638599ddc8a5e685332d08630db89bfc96ab0967f890295897151757b",
}

MICROSTUDIO_FILES = {
    # key: relative path under microstudio/ in the resource pack
    "microstudio/util/canvas2d.js": "486848b7848bfb1aff9d93619c6421b014e921c2aa61a7bbd32f6e44ab7adc40",
    "microstudio/languages/microscript/random.js": "e7905e3caa83bf41aeb7791355b6ceea80d3c487e92a2ad645f9f1ba2070a5b2",
    "microstudio/languages/microscript/v2/compiler.js": "9b8ae09e4593882c1954a9894f92327a3a2346d458cc9351ae36c8fbb14ceb8b",
    "microstudio/languages/microscript/v2/parser.js": "592754d0918d51dee9af9ca78bf9e538bb8ffba605b3a9fcfe5d2e5b3928c11a",
    "microstudio/languages/microscript/v2/processor.js": "038b339f9ec5f3fb29a7e569cfff1f4f4b830d53623dc72a6ad7e25c831493af",
    "microstudio/languages/microscript/v2/program.js": "ce0443a500a6427597c70aa7ec74004b1927330ce0370dfbc12cfef62aebf74c",
    "microstudio/languages/microscript/v2/routine.js": "df8986459bcbf28e8684fd70bd299d77c5e60c03b9775d99e83080ffa4f387d3",
    "microstudio/languages/microscript/v2/runner.js": "e7bed23cdcca74f4095682b20dd6a67eb91c282a0aee7ecf889f57ecf277ef24",
    "microstudio/languages/microscript/v2/token.js": "abe0e32bf31e16b59e90a25b679ea59dcdfac8a713c93728609daa77e152922c",
    "microstudio/languages/microscript/v2/tokenizer.js": "c638d77a74d07a9d848fc688efce24217a95ba60bad394e8456b93554000b886",
    "microstudio/languages/microscript/v2/transpiler.js": "d33c75b805cff10794da465b69834b9143e61445d6e90f8dc31d62528e7d2fe6",
    "microstudio/runtime/microvm.js": "fcae85477a1dd880a3e852216c137eef7d655013cf61173f3cb7ed61e0dc9bb3",
    "microstudio/runtime/mpserverconnection.js": "c5544bc7e041af6c7e8c40dd0e5055eeb7896f6ebca23a0c41db1c41f6ee7d87",
    "microstudio/runtime/runtime.js": "70fbd90915e6ffafe315090889fcf58427d7ad6f9bc20f42e006d0f6ef3fe014",
    "microstudio/runtime/watcher.js": "2803280853f71260fa773553a28823691ee838f829007b4ff23b7368ae1882db",
    "microstudio/runtime/projectinterface.js": "a267f54d4910cb39ffe6a59e9027a5518896cd5554f22a0d396dcd59b76a1c7b",
    "microstudio/runtime/timemachine.js": "db3c636d99c96d7ac661ded7a8e4e81a54b82f56b0cb17733b09993eba098b8e",
    "microstudio/runtime/assetmanager.js": "5cc15dca4ccf8f0222a464a923ef073b694961bcda3d0cb5dceb33375fa0d3ea",
    "microstudio/runtime/keyboard.js": "31e0f9a624cd25fd45371c8908de0d3866d36faff18eee1821f9d4e1b3b9c5b2",
    "microstudio/runtime/gamepad.js": "e8a2c4adf5b06812fb443a398c0e95aea00d0ffda106943b8a4931dfa0313de1",
    "microstudio/runtime/sprite.js": "7d220a70dc33032e1ae45baac631d57ea1c2178fcfa58fc6446fe85a408978fe",
    "microstudio/runtime/msimage.js": "ccf0f2ac3202259bda4c7e70213f43042c7f84af03fb765804447e5d2651d5b8",
    "microstudio/runtime/map.js": "0db80ef280a4076be36b1b312d3f29175bc45d783446eb3eab72973e58ac2dde",
    "microstudio/runtime/audio/audio.js": "8b4c792ed931b6c9711e9951439a9813139cc63c62cd11eaf1ddb238e4c770d2",
    "microstudio/runtime/audio/beeper.js": "b582ba48bb76fd455e8c73e9ac9e691ef08ea980d12c65a8a0366fe305bfba6d",
    "microstudio/runtime/audio/sound.js": "4db0f771160b9a159f3ebb44cf558744350782136ab784f5144a6de7bd91ee7c",
    "microstudio/runtime/audio/music.js": "bd822d4cd60384997db8a42fafe94969b37ce7f2526ca5bd8d13a468a21d263a",
    "microstudio/runtime/screen.js": "a7e0a691fb31fcfb26f2c1fc7f588532604018e26744fd40bbaf965269022e81",
    "microstudio/play/player.js": "e99d44eb73d63c99a6c441e5d065f87ef9d45e5fd6a0825682d08dbfb892120b",
    "microstudio/play/playerclient.js": "590dcab14317b29bf0e8776b55c1cc1875e359eb987a380e8521b5e1c0e3a8bf",
}

# microStudio "microengine.js" bundle order, mirroring pmgl/microstudio's
# server/concatenator.js `player_js` (canvas2d default player) exactly.
MICROSTUDIO_ENGINE_ORDER = [
    "microstudio/util/canvas2d.js",
    "microstudio/languages/microscript/random.js",
    "microstudio/runtime/mpserverconnection.js",
    "microstudio/runtime/microvm.js",
    "microstudio/runtime/runtime.js",
    "microstudio/runtime/watcher.js",
    "microstudio/runtime/projectinterface.js",
    "microstudio/runtime/timemachine.js",
    "microstudio/runtime/screen.js",
    "microstudio/runtime/assetmanager.js",
    "microstudio/runtime/keyboard.js",
    "microstudio/runtime/gamepad.js",
    "microstudio/runtime/sprite.js",
    "microstudio/runtime/msimage.js",
    "microstudio/runtime/map.js",
    "microstudio/runtime/audio/audio.js",
    "microstudio/runtime/audio/beeper.js",
    "microstudio/runtime/audio/sound.js",
    "microstudio/runtime/audio/music.js",
    "microstudio/play/player.js",
    "microstudio/play/playerclient.js",
]

# microScript v2 language scripts, loaded before microengine (concatenator language_engines).
MICROSTUDIO_LANGUAGE_ORDER = [
    "microstudio/languages/microscript/v2/token.js",
    "microstudio/languages/microscript/v2/tokenizer.js",
    "microstudio/languages/microscript/v2/parser.js",
    "microstudio/languages/microscript/v2/program.js",
    "microstudio/languages/microscript/v2/routine.js",
    "microstudio/languages/microscript/v2/processor.js",
    "microstudio/languages/microscript/v2/transpiler.js",
    "microstudio/languages/microscript/v2/runner.js",
    "microstudio/languages/microscript/v2/compiler.js",
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _check_pins() -> None:
    pins = [digest for digest, _src in FIXED.values()] + list(MICROSTUDIO_FILES.values())
    for digest in pins:
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("Malformed pinned sha256: " + digest)


_check_pins()


def fetch(url: str, maximum: int = 64 * 1024 * 1024) -> bytes:
    last = None
    for _attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=90) as response:
                data = response.read(maximum + 1)
            if len(data) > maximum:
                raise ValueError("Upstream exceeds maximum size: " + url)
            return data
        except Exception as error:  # transient network/rate-limit; retry
            last = error
    raise last


def verify(root: Path) -> list:
    problems = []
    for rel, (digest, _src) in FIXED.items():
        path = root / rel
        if not path.is_file() or path.is_symlink() or sha256(path.read_bytes()) != digest:
            problems.append(rel)
    for rel, digest in MICROSTUDIO_FILES.items():
        path = root / rel
        if not path.is_file() or path.is_symlink() or sha256(path.read_bytes()) != digest:
            problems.append(rel)
    bundle = root / "microstudio/microengine.js"
    if bundle.is_file():
        if sha256(bundle.read_bytes()) != microengine_digest(root):
            problems.append("microstudio/microengine.js")
    else:
        problems.append("microstudio/microengine.js")
    # A partially applied selected-notice bundle is always a failure. A pack
    # with none of these files is a truthful top-license-only pack; adapters for
    # conditional engines then fail closed instead of claiming the bundle.
    present = [rel for rel in AUGMENTATION_HASHES if (root / rel).exists()]
    if present:
        for rel, digest in AUGMENTATION_HASHES.items():
            path = root / rel
            if not path.is_file() or path.is_symlink() or sha256(path.read_bytes()) != digest:
                problems.append(rel)
    return problems


def microengine_digest(root: Path) -> str:
    hasher = hashlib.sha256()
    for rel in MICROSTUDIO_ENGINE_ORDER:
        hasher.update((root / rel).read_bytes())
        hasher.update(b"\n")
    return hasher.hexdigest()


def extract_zip(data: bytes, name: str) -> bytes:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        return archive.read(name)


def extract_tar(data: bytes, name: str) -> bytes:
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        wanted = name.removeprefix("./")
        for member in archive.getmembers():
            if member.name.removeprefix("./") == wanted:
                return archive.extractfile(member).read()
        raise KeyError("filename %r not found" % name)


def prepare(target: Path, augmentation: Optional[Path] = None, reviewed_tic80: Optional[Path] = None) -> None:
    if reviewed_tic80 is None or not (reviewed_tic80 / "tic80").is_dir():
        raise ValueError("Provide --reviewed-tic80-pack with the pinned rebuilt runtime and complete source companion")
    if target.exists():
        raise FileExistsError("Destination exists; use --check to verify it without writing")
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".narrative-resource-", dir=target.parent))
    try:
        shutil.copytree(reviewed_tic80 / "tic80", stage / "tic80")
        for rel, (_digest, _src) in FIXED.items():
            if rel.startswith("tic80/"): continue
            destination = stage / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(fetch_fixed(rel))
        for rel in MICROSTUDIO_FILES:
            destination = stage / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(fetch(MICROSTUDIO_RAW + rel.removeprefix("microstudio/")))
        # Assemble the exact microengine.js bundle the official exporter produces.
        bundle = b"".join((stage / rel).read_bytes() + b"\n" for rel in MICROSTUDIO_ENGINE_ORDER)
        (stage / "microstudio/microengine.js").write_bytes(bundle)
        if augmentation is not None:
            for engine in ("wasm4", "sugarcube"):
                source = augmentation / engine / "files"
                if source.is_dir():
                    shutil.copytree(source, stage / engine, dirs_exist_ok=True)
        problems = verify(stage)
        if problems:
            raise ValueError("Prepared resources failed verification: " + ", ".join(problems))
        bundle_present = {
            name: all((stage / rel).is_file() for rel in bundle["files"])
            for name, bundle in LICENSE_BUNDLES.items()
        }
        manifest = {
            "engine": "narrative-collection", "preparedOffline": True, "nativeCode": False,
            "licenses": {
                "inkjs": "MIT",
                "sugarcube": ("BSD-2-Clause (top-level SugarCube) + selected: "
                              + ", ".join(LICENSE_BUNDLES["sugarcube"]["selected"])
                              if bundle_present["sugarcube"] else
                              "BSD-2-Clause (top-level SugarCube only; selected bundle not present)"),
                "wasm4": ("ISC (top-level WASM-4) + selected: "
                          + ", ".join(LICENSE_BUNDLES["wasm4"]["selected"])
                          if bundle_present["wasm4"] else
                          "ISC (top-level WASM-4 only; selected bundle not present)"),
                "tic80": ("MIT (top-level TIC-80) + selected: "
                          + ", ".join(LICENSE_BUNDLES["tic80"]["selected"])
                          if bundle_present["tic80"] else
                          "MIT (top-level TIC-80 only; selected bundle not present)"),
                "microstudio": "MIT",
            },
            "licenseBundles": LICENSE_BUNDLES,
            "licenseBundlePresent": bundle_present,
            "augmentationHashes": AUGMENTATION_HASHES,
            "versions": {"inkjs": INKJS_VERSION, "sugarcube": SUGARCUBE_VERSION,
                         "wasm4": WASM4_VERSION, "tic80": TIC80_VERSION,
                         "microstudio": MICROSTUDIO_COMMIT},
            "microstudioEngineOrder": MICROSTUDIO_ENGINE_ORDER,
            "microstudioLanguageOrder": MICROSTUDIO_LANGUAGE_ORDER,
        }
        (stage / "resource-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        stage.rename(target)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def fetch_fixed(rel: str) -> bytes:
    if rel.startswith("inkjs/"):
        data = fetch(INKJS_TARBALL)
        inner = "package/dist/ink-full.js" if rel.endswith("inkjs.js") else "package/LICENSE.md"
        return extract_tar(data, inner)
    if rel.startswith("sugarcube/"):
        data = fetch(SUGARCUBE_ZIP)
        inner = "sugarcube-2/format.js" if rel.endswith(".js") else "sugarcube-2/LICENSE"
        return extract_zip(data, inner)
    if rel.startswith("wasm4/"):
        data = fetch(WASM4_TARBALL)
        inner = {"wasm4/wasm4.js": "package/assets/runtime/slim/wasm4.js",
                 "wasm4/wasm4.css": "package/assets/runtime/slim/wasm4.css",
                 "wasm4/LICENSE.wasm4.txt": "package/LICENSE.txt"}[rel]
        return extract_tar(data, inner)
    if rel.startswith("tic80/"):
        raise ValueError("TIC-80 requires the reviewed rebuilt pack; upstream player fallback is disabled")
    if rel.startswith("microstudio/"):
        return fetch(MICROSTUDIO_LICENSE)
    raise ValueError("Unknown fixed resource: " + rel)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Read-only local verification; no network or writes")
    parser.add_argument("--augmentation", type=Path,
                        help="Optional frozen local augmentation bundle (files/ + tic80/source/)")
    parser.add_argument("--reviewed-tic80-pack", type=Path,
                        help="Prepared resource pack containing the reviewed rebuilt TIC-80 and complete source")
    args = parser.parse_args()
    if not args.output.is_absolute():
        parser.error("Use an explicit absolute resource directory")
    if args.check:
        problems = verify(args.output)
        if problems:
            raise SystemExit("Resource missing or changed: " + ", ".join(problems))
        print(json.dumps({"result": "verified", "readOnly": True,
                          "files": len(FIXED) + len(MICROSTUDIO_FILES) + 1}))
    else:
        prepare(args.output, args.augmentation, args.reviewed_tic80_pack)
        print(json.dumps({"result": "prepared", "readOnly": False,
                          "files": len(FIXED) + len(MICROSTUDIO_FILES) + 1}))
