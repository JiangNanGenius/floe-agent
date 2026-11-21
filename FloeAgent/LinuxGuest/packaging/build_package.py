#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Package the Linux ARM64 tools for offline installation from the app."""
import argparse
import hashlib
import io
import lzma
import sys
import tarfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "acceleration"
sys.path.insert(0, str(HERE.parents[1] / "scripts"))
from build_floe_repo import ar_member, tar_bytes

PACKAGE = "floe-acceleration-tools"
CONTROL = f"""Package: {PACKAGE}
Version: 1.0-3
Architecture: arm64
Section: utils
Priority: optional
Maintainer: Floe Agent contributors
Depends: libc6, coreutils
Suggests: libegl1, libegl-mesa0, libgles2, ocl-icd-libopencl1, mesa-opencl-icd
Description: Local graphics, video and BLAS tools for the Floe Linux guest
"""

def payload_tar(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        directories = {p for name, _, _ in entries for p in PurePosixPath(name).parents}
        for directory in sorted(directories):
            info = tarfile.TarInfo(str(directory))
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        for name, data, mode in entries:
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), mode
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()

def build(blas, codec):
    entries = []
    def add(source, destination, mode=0o644):
        data = source.read_bytes()
        entries.append(("./" + destination, data, mode))

    for source in (blas / "floe-blas-probe", blas / "libfloe_blas.so", codec):
        header = source.read_bytes()[:20]
        if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\xb7\x00":
            raise ValueError(f"{source.name} must be an arm64 little-endian Linux ELF")

    add(blas / "libfloe_blas.so", "usr/local/lib/floe-acceleration/libfloe_blas.so")
    add(blas / "floe-blas-probe", "usr/local/bin/floe-blas-probe", 0o755)
    add(codec, "usr/local/bin/floe-codec", 0o755)
    add(SOURCE / "floe-accel", "usr/local/bin/floe-accel", 0o755)
    add(SOURCE / "graphics/floe_gl_probe.py", "usr/local/bin/floe-gl-probe", 0o755)
    add(SOURCE / "opencl/tools/floe_opencl_probe.py", "usr/local/bin/floe-opencl-probe", 0o755)
    add(SOURCE / "blas/scripts/floe-blas-run", "usr/local/bin/floe-blas-run", 0o755)
    add(SOURCE / "blas/scripts/floe-blas-shell.sh", "usr/local/lib/floe-acceleration/floe-blas-shell.sh")
    add(SOURCE / "blas/scripts/floe-blas-activate.sh", "usr/local/share/floe-acceleration/floe-blas-activate.sh")
    add(SOURCE / "blas/image/activation/floe-blas.env", "usr/local/share/floe-acceleration/floe-blas.env")
    add(SOURCE / "blender/floe-blender", "usr/local/bin/floe-blender", 0o755)
    for script in ("floe_blender.py", "blender_ops.py"):
        add(SOURCE / "blender" / script, "usr/local/lib/floe/blender/" + script)
    for component, document in (("blas", "LICENSE"), ("blas", "NOTICE"), ("video", "LICENSE"), ("blender", "LICENSE")):
        add(SOURCE / component / document, f"usr/local/share/doc/{PACKAGE}/{component}-{document}")
    entries.sort()
    checksums = "".join(hashlib.md5(data).hexdigest() + "  " + name[2:] + "\n" for name, data, _ in entries)
    control = tar_bytes([("./control", CONTROL.encode(), 0o644), ("./md5sums", checksums.encode(), 0o644)])
    return (b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
            + ar_member("control.tar.xz", lzma.compress(control))
            + ar_member("data.tar.xz", lzma.compress(payload_tar(entries))))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blas", type=Path, required=True, help="build directory containing the provider and probe")
    parser.add_argument("--codec", type=Path, required=True, help="built Linux floe-codec executable")
    parser.add_argument("--output", type=Path, default=HERE / (PACKAGE + ".deb"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    package = build(args.blas, args.codec)
    if args.check:
        if package != args.output.read_bytes():
            sys.exit("Package does not match the supplied ARM64 artifacts and guest sources.")
    else:
        args.output.write_bytes(package)
    print(f"{len(package)} bytes  sha256 {hashlib.sha256(package).hexdigest()}")
