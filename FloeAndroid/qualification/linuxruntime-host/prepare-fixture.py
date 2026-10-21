#!/usr/bin/env python3
"""Convert the pinned Debian qualification fixture; no host extraction."""
import argparse, copy, gzip, hashlib, json, pathlib, tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
expected = "4baa32280cc70b67e2c650777c1d974349f0cdf23afaabc305ad3bc6182b8df8"
assert hashlib.sha256(args.source.read_bytes()).hexdigest() == expected, "source SHA256 mismatch"
assert not args.output.exists(), "refusing to overwrite an existing fixture"
args.output.parent.mkdir(parents=True, exist_ok=True)
prefix = "debian-bookworm-aarch64/"
with tarfile.open(args.source, "r:xz") as source, args.output.open("xb") as output:
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as target:
            for entry in source:
                if entry.name == prefix[:-1]:
                    continue
                assert entry.name.startswith(prefix), "unexpected archive prefix"
                if not (entry.isfile() or entry.isdir() or entry.issym() or entry.islnk()):
                    continue  # Device nodes/FIFOs have no role in this App fixture.
                payload = source.extractfile(entry) if entry.isfile() else None
                entry = copy.copy(entry)
                entry.name = entry.name[len(prefix):]
                assert ".." not in pathlib.PurePosixPath(entry.name).parts
                if entry.islnk():
                    assert entry.linkname.startswith(prefix), "unexpected hardlink prefix"
                    entry.linkname = entry.linkname[len(prefix):]
                entry.uid = entry.gid = entry.mtime = 0
                entry.uname = entry.gname = "root"
                entry.mode &= 0o777
                entry.pax_headers = {}
                target.addfile(entry, payload)
print(json.dumps({"sourceSha256": expected, "fixtureSha256": hashlib.sha256(args.output.read_bytes()).hexdigest(), "bytes": args.output.stat().st_size}))
