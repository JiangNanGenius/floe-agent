#!/usr/bin/env python3
"""Build the virtio-media guest kernel module for Debian 6.12.107+deb13-arm64.

Repaired version. Original defects fixed:
  1. .deb files are `ar` archives, not tar: the original called
     tarfile.open() on them and crashed with tarfile.ReadError
     (the original failure remains in the primary's private evidence).
     This version never unpacks the 150 MB source deb: it reuses the
     already-extracted pinned kernel tree READ-ONLY and the pinned standalone
     config/Module.symvers downloads.
  2. The original wrote module objects into the stage driver dir (external
     disk, against internalSSD policy). The driver is copied into an
     internal-SSD module object tree (<scratch>/modsrc/virtio-media) with a
     sha256 manifest, and the .ko is produced there.
  3. LOCALVERSION was not pinned; it is now exactly "+deb13-arm64" on every
     make invocation so UTS_RELEASE == 6.12.107+deb13-arm64.
  4. The original asserted "any cross compiler works" and tried an invalid
     CROSS_COMPILE=clang-. Toolchain facts are now PROBED at runtime
     (compiler/make versions recorded in the receipt). Default toolchain:
     aarch64-linux-musl-gcc from Homebrew (aarch64-unknown-linux-musl 15.2.0),
     gmake >= 4 (system GNU Make 3.81 is too old for kernel 6.12).
  5. The hardcoded "depends" string is replaced by the real .modinfo values.

Darwin host tools: modpost/mk_elfconfig include glibc <elf.h> and
<byteswap.h> which macOS lacks. Compat headers are injected via
KBUILD_HOSTCFLAGS from <scratch>/host-include (copied from the pinned musl
cross-toolchain sysroot + one task-written byteswap.h; see host-include/
PROVENANCE.txt). The kernel source tree itself is never modified.

BTF: CONFIG_DEBUG_INFO_BTF_MODULES=y, but Kbuild's cmd_btf_ko skips BTF when
no vmlinux exists in the O= dir (external module builds), so the .ko carries
no BTF section. Stock Debian modules ship BTF; loading does not require it.

Inputs (pinned, sha256 in config/build-inputs.json + this script):
  downloads/linux-source-6.12_6.12.107-1_all.deb
  downloads/linux-headers-6.12.107+deb13-arm64_6.12.107-1_arm64.deb
  downloads/config-6.12.107+deb13-arm64
  downloads/Module.symvers-6.12.107+deb13-arm64
  kernel source tree (read-only reuse): ~/Library/Caches/CodexBuild/FloeAgent/virtual-video/kernel-src/tree/linux-source-6.12

Run only inside the primary's authorized shared-native build window.
"""
import argparse, hashlib, io, json, os, re, shutil, subprocess, sys, tarfile
from pathlib import Path

STAGE = Path(__file__).resolve().parents[1]
DEFAULT_DL = STAGE.parents[3] / "downloads"  # guest/downloads
KERNEL_TREE = Path(os.environ.get(
    "FVM_KERNEL_TREE",
    Path.home() / "Library/Caches/CodexBuild/FloeAgent/virtual-video/kernel-src/tree/linux-source-6.12"))
DEFAULT_SCRATCH = Path.home() / "Library/Caches/CodexBuild/FloeAgent/virtual-video/module-build"
EXPECTED_VERMAGIC = "6.12.107+deb13-arm64 SMP mod_unload modversions aarch64"
LOCALVERSION = "+deb13-arm64"

PINNED = {
    "linuxSource": ("linux-source-6.12_6.12.107-1_all.deb",
                    "775b9ef84d7fa7927ccebfec33fbbe9aeb2482ebf9a92c771aafd33fb6e2ee27"),
    "linuxHeaders": ("linux-headers-6.12.107+deb13-arm64_6.12.107-1_arm64.deb",
                     "20cc55bde5ceae6411b7554d5fffc937f2df022bf47b6df9cad32b51cb1219f3"),
    "config": ("config-6.12.107+deb13-arm64",
               "44342a19e3a31c01fa4119e92325c50226741454a2e20db8453c1dd27e050f9d"),
    "moduleSymvers": ("Module.symvers-6.12.107+deb13-arm64",
                      "4e1420af601b02700a9624ddf10ffc81aebb4934dc811b600d1b2368a5ae3a2a"),
}

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def run(cmd, log=None, env=None, cwd=None):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    e = dict(os.environ, **env) if env else None
    if log:
        with open(log, "a") as lf:
            lf.write("+ " + " ".join(str(c) for c in cmd) + "\n")
            lf.flush()
            r = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT, env=e, cwd=cwd)
    else:
        r = subprocess.run(cmd, env=e, cwd=cwd)
    if r.returncode != 0:
        raise SystemExit(f"command failed ({r.returncode}): {cmd[0]} ... (see {log})" if log
                         else f"command failed ({r.returncode}): {cmd}")
    return r

def out(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def restore_stock_generated(headers_deb, outdir):
    """Use the target kernel's generated ABI, not host-probed Kconfig output.

    modules_prepare may change options based on this compiler/host (including
    BTF_MODULES, which changes struct module). Native host tools may be reused,
    but module C must see the exact generated headers from the pinned Debian
    kernel. External M= modules intentionally does not synchronize Kconfig.
    """
    raw = headers_deb.read_bytes()
    if hashlib.sha256(raw).hexdigest() != PINNED['linuxHeaders'][1] or raw[:8] != b'!<arch>\n':
        raise SystemExit('Pinned headers .deb changed')
    prefix = 'usr/src/linux-headers-6.12.107+deb13-arm64/'
    manifest = {}
    offset = 8
    while offset + 60 <= len(raw):
        header = raw[offset:offset + 60]
        if header[58:60] != b'`\n':
            raise SystemExit('Invalid .deb ar header')
        size = int(header[48:58].decode().strip())
        name = header[:16].decode().strip().rstrip('/')
        payload = raw[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
        if not name.startswith('data.tar'):
            continue
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:*') as archive:
            for member in archive:
                entry = member.name.removeprefix('./')
                if not member.isfile() or not entry.startswith(prefix):
                    continue
                relative = entry[len(prefix):]
                if not (relative.startswith('include/generated/') or relative.startswith('arch/arm64/include/generated/')
                        or relative in ['include/config/auto.conf', 'include/config/kernel.release']):
                    continue
                if Path(relative).is_absolute() or '..' in Path(relative).parts:
                    raise SystemExit('Unsafe stock header member')
                data = archive.extractfile(member).read()
                dest = outdir / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
                manifest[relative] = hashlib.sha256(data).hexdigest()
    for required in ['include/generated/autoconf.h', 'include/generated/asm-offsets.h',
                     'include/config/auto.conf', 'include/config/kernel.release', 'include/generated/utsrelease.h']:
        if required not in manifest:
            raise SystemExit('Missing stock kernel ABI metadata: ' + required)
    return manifest

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--downloads", type=Path, default=DEFAULT_DL)
    ap.add_argument("--scratch", type=Path, default=DEFAULT_SCRATCH)
    ap.add_argument("--kernel-tree", type=Path, default=KERNEL_TREE)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--cc", default="aarch64-linux-musl-gcc",
                    help="cross compiler basename (must accept -ffreestanding kernel flags)")
    args = ap.parse_args()

    scratch = args.scratch.resolve()
    outdir = scratch / "kbuild-out"          # O= object dir (internal SSD)
    hostinc = scratch / "host-include"       # Darwin host compat headers
    modsrc = scratch / "modsrc" / "virtio-media"
    logs = STAGE / "evidence" / "logs"
    logs.mkdir(parents=True, exist_ok=True)

    # ---- 0. pinned input verification (hashes, never unpack the debs) ----
    verified = {}
    for key, (fname, want) in PINNED.items():
        p = args.downloads / fname
        if not p.exists():
            raise SystemExit(f"missing pinned input: {p}")
        got = sha256(p)
        if got != want:
            raise SystemExit(f"sha256 mismatch for {fname}: {got} != {want}")
        verified[key] = {"file": fname, "sha256": got}
        print(f"verified {key}: {fname} {got[:16]}...")

    # ---- 1. kernel source tree identity (read-only reuse) ----
    k = args.kernel_tree.resolve()
    mk = (k / "Makefile").read_text()
    m = re.search(r"^VERSION = (\d+)\nPATCHLEVEL = (\d+)\nSUBLEVEL = (\d+)", mk, re.M)
    if not m or (int(m.group(1)), int(m.group(2)), int(m.group(3))) != (6, 12, 107):
        raise SystemExit(f"kernel tree is not 6.12.107: {k}")
    if (k / ".config").exists() or (k / "include" / "generated").exists():
        raise SystemExit(f"kernel tree is not pristine/read-only layout: {k}")
    tree_identity = {
        "path": str(k),
        "releaseFromMakefile": "6.12.107",
        "Makefile.sha256": sha256(k / "Makefile"),
        "scriptsMakefile.sha256": sha256(k / "scripts" / "Makefile"),
        "modpost_c.sha256": sha256(k / "scripts" / "mod" / "modpost.c"),
    }
    print(f"kernel tree OK (read-only reuse): {k}")

    # ---- 2. toolchains (probe, do not assert) ----
    gmake = shutil.which("gmake")
    if not gmake:
        raise SystemExit("gmake (GNU make >= 4) not found; kernel 6.12 refuses make 3.81")
    gv = out([gmake, "--version"]).stdout.splitlines()[0]
    if not re.search(r"(?:\D|^)([4-9]\d*)\.", gv):
        raise SystemExit(f"gmake too old: {gv}")
    cc = shutil.which(args.cc)
    if not cc:
        raise SystemExit(f"cross compiler not found: {args.cc}")
    cv = out([cc, "--version"]).stdout.splitlines()[0]
    nm = shutil.which(args.cc.replace("-gcc", "-nm")) or shutil.which("aarch64-linux-musl-nm")
    readelf = shutil.which(args.cc.replace("-gcc", "-readelf")) or shutil.which("aarch64-linux-musl-readelf")
    hostcc_v = out(["cc", "--version"]).stdout.splitlines()[0]
    print(f"gmake: {gv}\ncross: {cv}\nhost cc: {hostcc_v}")
    cross = args.cc
    cross_prefix = cross[:-4] + "-" if cross.endswith("-gcc") else cross + "-"

    # Darwin host fixes, injected via KBUILD_USERHOSTCFLAGS (a make command-line
    # variable that flows INTO the top Makefile's own
    #   KBUILD_HOSTCFLAGS := $(KBUILD_USERHOSTCFLAGS) ... -I $(srctree)/scripts/include
    # composition). Unlike overriding KBUILD_HOSTCFLAGS/HOST_EXTRACFLAGS, this
    # keeps every kernel Makefile's own `HOST_EXTRACFLAGS += ...` effective
    # (dtc libfdt, selinux uapi, ipe includes).
    #   -I hostinc            elf.h/byteswap.h compat (modpost, sorttable, ...)
    #   -I generated uapi     selinux genheaders/mdp need <asm/types.h>
    #   -I brew openssl       sign-file (CONFIG_MODULE_SIG_FORMAT=y) needs libcrypto
    host_cflags = (f"-I{hostinc} "
                   f"-I{outdir}/include/generated/uapi "
                   f"-I{outdir}/arch/arm64/include/generated/uapi "
                   f"-I{k}/arch/arm64/include/uapi "
                   f"-I/opt/homebrew/opt/openssl/include")
    make_hostc = f"KBUILD_USERHOSTCFLAGS={host_cflags}"
    # The macOS SDK defines uuid_t as an array; scripts/mod/file2alias.c
    # defines its own struct uuid_t. The compat header is injected into the
    # FILE2ALIAS TU ONLY via the kernel's per-target host-cflags hook
    # (scripts/Makefile.host appends $(HOSTCFLAGS_$(target-stem).o)); it is
    # deliberately NOT part of the global host flags.
    make_f2a = f"HOSTCFLAGS_file2alias.o=-include {hostinc}/fvm-darwin-compat.h"
    env = {
        "ARCH": "arm64",
        "CROSS_COMPILE": cross_prefix,
        "LOCALVERSION": LOCALVERSION,
        # sign-file links libcrypto via pkg-config; brew openssl is keg-only.
        "PKG_CONFIG_PATH": "/opt/homebrew/opt/openssl/lib/pkgconfig",
    }

    # ---- 3. seed O= dir with the exact Debian build state ----
    outdir.mkdir(parents=True, exist_ok=True)

    def seed(name, fname, want):
        dst = outdir / name
        if not dst.exists() or sha256(dst) != want:
            shutil.copy(args.downloads / fname, dst)
        if sha256(dst) != want:
            raise SystemExit(f"failed to seed {name} into {outdir}")

    seed(".config", *PINNED["config"])
    seed("Module.symvers", *PINNED["moduleSymvers"])
    assert sha256(outdir / ".config") == PINNED["config"][1]
    assert sha256(outdir / "Module.symvers") == PINNED["moduleSymvers"][1]

    # ---- 4. modules_prepare (generates include/generated + host tools in O=) ----
    if not (outdir / "include" / "generated" / "autoconf.h").exists() or \
       not (outdir / "scripts" / "mod" / "modpost").exists():
        run([gmake, "-C", str(k), f"O={outdir}", f"-j{args.jobs}", make_hostc, make_f2a, "modules_prepare"],
            log=logs / "modules_prepare.log", env=env)

    stock_generated = restore_stock_generated(args.downloads / PINNED['linuxHeaders'][0], outdir)
    kr = (outdir / 'include/config/kernel.release').read_text().strip()
    print("kernelrelease:", kr)
    if kr != "6.12.107+deb13-arm64":
        raise SystemExit(f"kernelrelease mismatch: {kr}")

    # ---- 5. copy driver into internal-SSD module object tree (manifest) ----
    stage_drv = STAGE / "driver"
    if modsrc.exists():
        shutil.rmtree(modsrc)
    modsrc.mkdir(parents=True)
    manifest = {}
    for f in sorted(stage_drv.iterdir()):
        if f.is_file():
            shutil.copy2(f, modsrc / f.name)
            manifest[f.name] = sha256(modsrc / f.name)
    expected = {f.name: sha256(f) for f in sorted(stage_drv.iterdir()) if f.is_file()}
    if manifest != expected:
        raise SystemExit("modsrc manifest mismatch after copy")
    (modsrc / "MANIFEST.json").write_text(json.dumps(manifest, indent=1) + "\n")

    # ---- 6. build the module ----
    run([gmake, "-C", str(k), f"O={outdir}", f"-j{args.jobs}", make_hostc, make_f2a,
         f"M={modsrc}", "modules"], log=logs / "module-build.log", env=env)
    for relative, expected in stock_generated.items():
        if sha256(outdir / relative) != expected:
            raise SystemExit('Kbuild changed stock generated ABI metadata: ' + relative)

    # ---- 7. post-checks ----
    ko = modsrc / "virtio-media.ko"
    if not ko.exists():
        raise SystemExit(f"module not produced: {ko}")
    eh = out([readelf, "-h", str(ko)]).stdout
    if "AArch64" not in eh or "Relocatable" not in eh:
        raise SystemExit("virtio-media.ko is not an AArch64 relocatable ELF:\n" + eh)

    # .modinfo is a NUL-separated "key=value" string section; -p prints
    # `[ off] key=value' lines (unlike -x which dumps raw hex).
    modinfo = out([readelf, "-p", ".modinfo", str(ko)]).stdout
    fields = {}
    for m in re.finditer(r"^\s*\[\s*[0-9a-fx]+\]\s*([a-zA-Z0-9_]+)=(.*?)\s*$",
                         modinfo, re.M):
        fields[m.group(1)] = m.group(2)
    vermagic = fields.get("vermagic", "")
    print("vermagic:", vermagic)
    if vermagic != EXPECTED_VERMAGIC:
        raise SystemExit(f"vermagic mismatch: {vermagic!r} != {EXPECTED_VERMAGIC!r}")
    depends = fields.get("depends", "")
    print("depends (from .modinfo):", depends or "(none)")

    nmout = out([nm, "-u", str(ko)]).stdout
    undef = [l.split()[-1] for l in nmout.splitlines() if l.strip()]

    symvers = {}
    for line in (outdir / "Module.symvers").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3:
            raw = parts[2]
            symvers[parts[1]] = {"crc": parts[0], "module": raw,
                                 "moduleName": raw.rsplit("/", 1)[-1]}
    imports = []
    missing = []
    for s in undef:
        e = symvers.get(s)
        if e:
            imports.append({"symbol": s, "crc": e["crc"], "provider": e["module"],
                            "providerModule": e["moduleName"]})
        else:
            missing.append(s)
    depmods = sorted({i["providerModule"] for i in imports if i["providerModule"] != "vmlinux"})
    print(f"undefined imports: {len(undef)} ({len(missing)} not in Module.symvers)")
    if missing:
        raise SystemExit("unresolvable imports (not in pinned Module.symvers): " + ", ".join(missing))

    crc_syms = out([nm, str(ko)]).stdout
    versioned = len(re.findall(r"__crc_", crc_syms))

    receipt = {
        "schemaVersion": 2,
        "component": "virtio-media guest module",
        "kernelRelease": kr,
        "module": "virtio-media.ko",
        "path": str(ko),
        "sha256": sha256(ko),
        "bytes": ko.stat().st_size,
        "compiler": cv,
        "gmake": gv,
        "hostcc": hostcc_v,
        "crossCompile": cross_prefix,
        "localversion": LOCALVERSION,
        "kbuildUserHostCflags": host_cflags,
        "kbuildFile2aliasFlags": make_f2a.split("=",1)[1],
        "kernelTree": tree_identity,
        "pinnedInputs": verified,
        "stockGeneratedHeaders": stock_generated,
        "stockGeneratedABIRecheckedAfterBuild": True,
        "modinfo": {k2: v for k2, v in fields.items() if k2 in
                    ("vermagic", "depends", "license", "name", "intree", "retpoline")},
        "vermagicCheck": {"expected": EXPECTED_VERMAGIC, "actual": vermagic,
                          "match": vermagic == EXPECTED_VERMAGIC},
        "undefinedImports": imports,
        "importsNotInModuleSymvers": missing,
        "versionedSymbolRefs": versioned,
        "dependencyModulesFromImports": depmods,
        "dependsFromModinfo": depends,
        "btf": "skipped by Kbuild (no vmlinux in O= dir; CONFIG_DEBUG_INFO_BTF_MODULES=y)",
        "moduleSigning": "unsigned (CONFIG_MODULE_SIG_ALL=y signs in-tree modules only; "
                         "CONFIG_MODULE_SIG_FORCE is not set so unsigned loads with taint)",
        "logs": [str(logs / "modules_prepare.log"), str(logs / "module-build.log")],
        "notes": "Compile/link stage only. insmod, /dev/video*, codec decode/encode "
                 "are the primary's runtime stage and are NOT claimed here.",
    }
    (STAGE / "evidence").mkdir(exist_ok=True)
    rec_path = STAGE / "evidence" / "module-build-receipt.json"
    rec_path.write_text(json.dumps(receipt, indent=1) + "\n")
    print("receipt:", rec_path)
    print("MODULE_BUILT", ko)

if __name__ == "__main__":
    main()
