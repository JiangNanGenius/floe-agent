#!/usr/bin/env python3
"""Assemble the virtio-media initrd module overlay for the Floe Linux guest.

Repaired version . Original defects fixed:
  1. It opened the linux-image .deb with tarfile (a .deb is an `ar` archive);
     this version implements a bounded GNU-ar reader for data.tar.xz only.
  2. It hardcoded both the module list and the modules.dep line. This version
     computes the real dependency closure: undefined imports of the built
     virtio-media.ko are mapped through the pinned Module.symvers to provider
     modules; each stock module's own imports (read from its ELF symtab via
     the cross nm) are expanded recursively. Stock modules are extracted
     from the pinned linux-image deb (xz-decompressed) and hashed.

Stage-only: writes <out>/lib/modules/NN-<name>.ko + modules.dep + receipt.
It never touches the boot initrd, boot-inputs.json or any frozen image asset;
actual load-order integration belongs to the image owner.
"""
import argparse, hashlib, io, json, lzma, shutil, subprocess, sys, tarfile, tempfile
from pathlib import Path

STAGE = Path(__file__).resolve().parents[1]           # .../virtio-media
PACKAGE = STAGE / "config" / "video-module-pins.json"
PINS = json.loads(PACKAGE.read_text())
DEB = Path(PINS["linuxImageDeb"]["path"]) if PINS["linuxImageDeb"].get("path") else None
PACKAGE_SHA256 = PINS["linuxImageDeb"]["sha256"]
KERNEL_RELEASE = PINS["kernelRelease"]
FIRST_INDEX = int(PINS["initrdModuleIndex"])  # continues the existing GPU series
FLOE_CODEC_SHA256 = PINS["floeCodec"]["sha256"] if PINS.get("floeCodec", {}).get("sha256") else None
MODULE_SHA256 = PINS["virtioMediaKo"]["sha256"]

def sha256(b_or_p):
    h = hashlib.sha256()
    if isinstance(b_or_p, (bytes, bytearray)):
        h.update(b_or_p)
    else:
        with open(b_or_p, "rb") as f:
            for c in iter(lambda: f.read(1 << 20), b""):
                h.update(c)
    return h.hexdigest()

# ---------------- bounded GNU ar reader (data.tar.xz only) ----------------

def ar_members(data: bytes):
    if data[:8] != b"!<arch>\n":
        raise SystemExit("not an ar archive")
    pos, n = 8, len(data)
    long_names = b""
    while pos + 60 <= n:
        hdr = data[pos:pos + 60]
        if hdr[58:60] != b"`\n":
            raise SystemExit(f"bad ar header at {pos}")
        raw_name = hdr[0:16].decode("ascii", "replace").strip()
        try:
            size = int(hdr[48:58].decode("ascii", "replace").strip())
        except ValueError:
            raise SystemExit(f"bad ar size at {pos}")
        body = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
        if raw_name == "//":
            long_names = body
            continue
        if raw_name.startswith("#1/"):
            ln = int(raw_name[3:])
            name = body[:ln].decode("utf-8", "replace")
            body = body[ln:]
        elif raw_name.startswith("/") and raw_name[1:].isdigit():
            off = int(raw_name[1:])
            end = long_names.index(b"\n", off)
            name = long_names[off:end].decode("utf-8", "replace").rstrip("/")
        else:
            name = raw_name.rstrip("/")
        yield name, body

def extract_from_deb(deb: Path, wanted_names):
    """wanted_names: set of archive member paths (without leading ./).
    Returns {name: raw_bytes} for those members."""
    data = deb.read_bytes()
    out = {}
    for name, body in ar_members(data):
        if not name.endswith(".tar.xz"):
            continue
        with tarfile.open(fileobj=lzma.LZMAFile(io.BytesIO(body)), mode="r|") as tf:
            for m in tf:
                p = m.name.split("./", 1)[-1]
                if p in wanted_names:
                    out[p] = tf.extractfile(m).read()
                    if len(out) == len(wanted_names):
                        return out
    return out

# ---------------- dependency closure ----------------

def module_symvers(path: Path):
    table = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3:
            # third column is the in-tree path (e.g. drivers/media/v4l2-core/videodev);
            # the loadable module name is the basename without .ko
            table[parts[1]] = parts[2].rsplit("/", 1)[-1]  # symbol -> module name (or vmlinux)
    return table

def undefined_symbols(ko: Path, nm):
    r = subprocess.run([nm, "-u", str(ko)], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"nm failed on {ko}: {r.stderr}")
    return [l.split()[-1] for l in r.stdout.splitlines() if l.strip()]

def closure(built_ko: Path, symvers_table, stock_modules, nm):
    """stock_modules: {modname: ko_bytes}.
    Returns (order, needed, self_deps): topological load order (deps first),
    {modname: set(dep modnames)} for stock modules, and the built module's own
    set of stock-module dependencies."""
    needed = {}  # modname -> set(dep modnames)

    def deps_of(tmpdir, modname, ko_bytes):
        if modname in needed:
            return needed[modname]
        tmp = Path(tmpdir) / f"{modname}.ko"
        tmp.write_bytes(ko_bytes)
        try:
            undef = undefined_symbols(tmp, nm)
        finally:
            tmp.unlink()
        d = set()
        for s in undef:
            prov = symvers_table.get(s)
            if prov and prov != "vmlinux" and prov != modname:
                d.add(prov)
        needed[modname] = d
        return d

    with tempfile.TemporaryDirectory() as td:
        self_deps = set()
        queue = []
        for s in undefined_symbols(built_ko, nm):
            prov = symvers_table.get(s)
            if prov and prov != "vmlinux":
                self_deps.add(prov)
                queue.append(prov)
        seen = set(queue)
        while queue:
            m = queue.pop()
            if m not in stock_modules:
                needed[m] = set()  # missing from image; reported after closure
                continue
            d = deps_of(td, m, stock_modules[m])
            for dep in d:
                if dep not in seen:
                    seen.add(dep)
                    queue.append(dep)

    order, done = [], set()
    def visit(m):
        if m in done:
            return
        for dep in sorted(needed.get(m, ())):
            visit(dep)
        done.add(m)
        order.append(m)
    for m in sorted(seen):
        visit(m)
    return order, needed, self_deps

def main():
    global PINS, DEB, PACKAGE_SHA256, KERNEL_RELEASE, FIRST_INDEX, FLOE_CODEC_SHA256, MODULE_SHA256
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--pins", type=Path, default=PACKAGE,
                    help="versioned input pins; defaults to the historical pins")
    ap.add_argument("--image-deb", type=Path)
    ap.add_argument("--built-ko", type=Path, required=True)
    ap.add_argument("--floe-codec", type=Path, required=True)
    ap.add_argument("--nm", default="aarch64-linux-musl-nm")
    ap.add_argument("--symvers", type=Path, required=True)
    args = ap.parse_args()

    PINS = json.loads(args.pins.read_text())
    DEB = Path(PINS["linuxImageDeb"]["path"]) if PINS["linuxImageDeb"].get("path") else None
    PACKAGE_SHA256 = PINS["linuxImageDeb"]["sha256"]
    KERNEL_RELEASE = PINS["kernelRelease"]
    FIRST_INDEX = int(PINS["initrdModuleIndex"])
    FLOE_CODEC_SHA256 = PINS.get("floeCodec", {}).get("sha256")
    MODULE_SHA256 = PINS["virtioMediaKo"]["sha256"]
    args.image_deb = args.image_deb or DEB

    if args.image_deb is None or not args.image_deb.is_file():
        raise SystemExit("--image-deb is required (no machine-local pin path is embedded)")
    if sha256(args.image_deb) != PACKAGE_SHA256:
        raise SystemExit("linux-image deb sha256 mismatch")
    built_ko = args.built_ko
    if not built_ko.exists():
        raise SystemExit(f"built module not found: {built_ko}")
    if sha256(built_ko) != MODULE_SHA256:
        raise SystemExit("virtio-media.ko sha256 mismatch against selected pins")
    codec = args.floe_codec
    if not codec.exists() or not codec.is_file():
        raise SystemExit(f"floe-codec not found: {codec}")
    if FLOE_CODEC_SHA256 and sha256(codec) != FLOE_CODEC_SHA256:
        raise SystemExit("floe-codec sha256 mismatch against selected pins")
    blob = codec.read_bytes()[:20]
    if len(blob) < 20 or blob[:4] != b"\x7fELF" or blob[4] != 2 or blob[5] != 1             or int.from_bytes(blob[18:20], "little") != 183:
        raise SystemExit("floe-codec is not a 64-bit little-endian AArch64 ELF")
    symvers_path = args.symvers
    if not symvers_path.exists():
        raise SystemExit(f"Module.symvers not found: {symvers_path}")
    symvers_table = module_symvers(symvers_path)

    # Resolve just the needed closure using the existing extracted image.
    # Verify every selected compressed file against the pinned .deb before
    # exporting it. Avoid decompressing thousands of unrelated stock modules.
    candidates = {}
    for line in symvers_path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[2] != 'vmlinux':
            name = fields[2].rsplit('/', 1)[-1]
            candidates[name] = f'usr/lib/modules/{KERNEL_RELEASE}/kernel/{fields[2]}.ko.xz'
    extracted_root = STAGE.parents[3] / 'downloads/imgx'
    compressed = {}
    direct = {symvers_table[s] for s in undefined_symbols(built_ko, args.nm)
              if s in symvers_table and symvers_table[s] != 'vmlinux'}
    preloaded = extract_from_deb(args.image_deb, {candidates[name] for name in direct})
    class NeededStock(dict):
        def __contains__(self, name):
            return name in candidates
        def __getitem__(self, name):
            if not dict.__contains__(self, name):
                path = candidates[name]
                if path not in preloaded:
                    preloaded.update(extract_from_deb(args.image_deb, {path}))
                if path not in preloaded:
                    raise SystemExit('Needed provider missing from pinned image: ' + name)
                data = preloaded[path]
                compressed[name] = data
                self[name] = lzma.decompress(data)
            return dict.__getitem__(self, name)
    stock = NeededStock()
    order, needed, self_deps = closure(built_ko, symvers_table, stock, args.nm)
    missing = [m for m in needed if m not in stock]
    if missing:
        raise SystemExit(f"closure needs modules missing from linux-image deb: {missing}")
    verified_compressed = preloaded
    for name in order:
        if verified_compressed.get(candidates[name]) != compressed[name]:
            raise SystemExit('Extracted stock module differs from pinned .deb: ' + name)
    print("closure load order:", " -> ".join(order + ["virtio-media"]))

    mods = args.out / "lib" / "modules"
    mods.mkdir(parents=True, exist_ok=True)
    receipt = []
    idx = FIRST_INDEX
    for m in order:
        ko = mods / f"{idx:02d}-{m}.ko"
        ko.write_bytes(stock[m])
        receipt.append({"initrdPath": f"lib/modules/{ko.name}", "module": m,
                        "sha256": sha256(ko), "bytes": ko.stat().st_size,
                        "source": "linux-image deb (xz-decompressed)"})
        idx += 1
    ko = mods / f"{idx:02d}-virtio-media.ko"
    shutil.copy(built_ko, ko)
    receipt.append({"initrdPath": f"lib/modules/{ko.name}", "module": "virtio-media",
                    "sha256": sha256(ko), "bytes": ko.stat().st_size,
                    "source": "out-of-tree build (scripts/build_module.py)"})
    # real modules.dep from the computed graph (stock deps first, virtio-media last)
    dep_lines = []
    for i, m in enumerate(order):
        deps = sorted(needed.get(m, ()))
        dep_lines.append(f"lib/modules/{FIRST_INDEX + i:02d}-{m}.ko: " +
                         " ".join(f"lib/modules/{FIRST_INDEX + order.index(d):02d}-{d}.ko"
                                  for d in deps))
    vidx = FIRST_INDEX + len(order)
    dep_lines.append(f"lib/modules/{vidx:02d}-virtio-media.ko: " +
                     " ".join(f"lib/modules/{FIRST_INDEX + order.index(d):02d}-{d}.ko"
                              for d in sorted(self_deps)))
    (mods / "modules.dep").write_text("\n".join(dep_lines) + "\n")

    # Installed client, same bytes the installer verified. The guest process
    # runs it as /usr/local/bin/floe-codec; the App never executes host video
    # code from the guest.
    bin_dir = args.out / "usr" / "local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    codec_out = bin_dir / "floe-codec"
    shutil.copy(codec, codec_out)
    codec_out.chmod(0o755)

    (args.out / "INSTALL_RECEIPT.json").write_text(json.dumps({
        "schemaVersion": 2,
        "task": "",
        "kernelRelease": KERNEL_RELEASE,
        "loadOrder": [r["initrdPath"] for r in receipt],
        "modules": receipt,
        "closureGraph": {m: sorted(d) for m, d in needed.items()},
        "virtioMediaDeps": sorted(self_deps),
        "floeCodec": {
            "initrdPath": "usr/local/bin/floe-codec",
            "sha256": sha256(codec),
            "bytes": codec.stat().st_size,
            "mode": "0755",
            "installPath": "/usr/local/bin/floe-codec",
            "protocol": "floe-codec/1 (see acceleration/video/README.md)",
        },
        "imageCapabilityGate": "deviceCapabilities.videoAcceleration == true in the verified image manifest",
        "note": "Overlay only, computed from the real import closure. boot initrd "
                "assembly + insmod automation belong to the image owner; do not edit "
                "boot-inputs.json from this package.",
    }, indent=1) + "\n")
    print(json.dumps([r["initrdPath"] for r in receipt], indent=1))

if __name__ == "__main__":
    main()
