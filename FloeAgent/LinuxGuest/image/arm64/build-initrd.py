#!/usr/bin/env python3
"""Build the minimal pinned ARM64 boot CPIO; execute no host commands."""
import argparse
import gzip
import hashlib
import io
import json
import lzma
from pathlib import Path
import stat
import tarfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def deb_tar(path, expected):
    data = path.read_bytes()
    if digest(data) != expected:
        raise ValueError("Debian package checksum mismatch")
    if data[:8] != b"!<arch>\n":
        raise ValueError("Invalid Debian archive")
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        size = int(header[48:58])
        name = header[:16].decode("ascii").strip().rstrip("/")
        payload = data[offset + 60:offset + 60 + size]
        if name.startswith("data.tar"):
            return tarfile.open(fileobj=io.BytesIO(payload), mode="r:*")
        offset += 60 + size + size % 2
    raise ValueError("Missing Debian data archive")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--busybox-deb", type=Path, required=True)
    parser.add_argument("--kernel-deb", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--supervisor", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    pins = json.loads((here / "boot-inputs.json").read_text())
    files = {}
    for directory in ("bin", "dev", "dev/pts", "proc", "sys", "tmp", "run",
                      "mnt", "lib", "lib/modules", "usr", "usr/local",
                      "usr/local/bin", "etc"):
        files[directory] = (stat.S_IFDIR | 0o755, b"", 0, 0)
    busybox = deb_tar(args.busybox_deb, pins["busybox"]["packageSHA256"])
    member = next(m for m in busybox if m.name.endswith("/bin/busybox"))
    data = busybox.extractfile(member).read()
    if digest(data) != pins["busybox"]["binarySHA256"]:
        raise ValueError("BusyBox binary checksum mismatch")
    files["bin/busybox"] = (stat.S_IFREG | 0o755, data, 0, 0)
    files["bin/sh"] = (stat.S_IFLNK | 0o777, b"busybox", 0, 0)
    files["dev/console"] = (stat.S_IFCHR | 0o600, b"", 5, 1)
    files["dev/null"] = (stat.S_IFCHR | 0o666, b"", 1, 3)
    wanted = {Path(item["name"]).name.split("-", 1)[1]: item for item in pins["modules"]}
    kernel = deb_tar(args.kernel_deb, pins["kernelModules"]["packageSHA256"])
    for member in kernel:
        basename = Path(member.name).name.removesuffix(".xz")
        if basename not in wanted:
            continue
        item = wanted.pop(basename)
        data = kernel.extractfile(member).read()
        if member.name.endswith(".xz"):
            data = lzma.decompress(data)
        if digest(data) != item["sha256"]:
            raise ValueError("Kernel module checksum mismatch: " + basename)
        files[item["name"]] = (stat.S_IFREG | 0o644, data, 0, 0)
    if wanted:
        raise ValueError("Missing kernel modules: " + ",".join(wanted))
    for source, target in ((args.runner, "floe-exec"), (args.supervisor, "floe-supervisord")):
        data = source.read_bytes()
        if data[:4] != b"\x7fELF" or int.from_bytes(data[18:20], "little") != 183:
            raise ValueError("Runner must be an ARM64 ELF")
        files["usr/local/bin/" + target] = (stat.S_IFREG | 0o755, data, 0, 0)
    files["init"] = (stat.S_IFREG | 0o755, (here / "init").read_bytes(), 0, 0)
    output = bytearray()
    for inode, (name, (mode, data, major, minor)) in enumerate(
            list(sorted(files.items())) + [("TRAILER!!!", (0, b"", 0, 0))], 1):
        encoded = name.encode() + b"\0"
        values = [inode, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(encoded), 0]
        output.extend(b"070701" + b"".join(("%08x" % v).encode() for v in values) + encoded)
        output.extend(b"\0" * (-len(output) % 4))
        output.extend(data)
        output.extend(b"\0" * (-len(output) % 4))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(gzip.compress(bytes(output), compresslevel=6, mtime=0))
    print(json.dumps({"bytes": args.out.stat().st_size, "sha256": digest(args.out.read_bytes())}))


if __name__ == "__main__":
    main()
