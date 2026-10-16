#!/usr/bin/env python3
"""Normalize the build 156 distribution bundle before signing.

The source archives remain pinned and untouched. Reviewed non-iOS pnpm addons,
libssh2 1.11.0 architecture/metadata and dash deployment metadata are normalized.
Every embedded deployment command is checked; unreviewed inconsistencies fail.

Build 275 adds required-reason privacy manifests for every embedded executable
(the app, the Screen Share appex and the prebuilt frameworks). Framework
manifests are injected from controlled sources at each bundle root without
touching a single executable byte; unknown frameworks or undeclared API use
fail the packaging. The shell/text frameworks must come from the reviewed
privacy rebuild (`scripts/privacy-rebuild/rebuild_shell_frameworks.py`) because
their pinned v3.0.2 binaries call statfs/fstatfs for mount flags and I/O sizes
— required-reason DiskSpace APIs whose data they never use and for which no
approved reason exists.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess

ADDONS = {
    "NodeTools/pnpm/dist/reflink.darwin-arm64-MYEHQQCP.node": "ddf457202f296ba0e8b1749e3066ada08f9c5a543369d3a9467786ff1516bfe0",
    "NodeTools/pnpm/dist/reflink.darwin-x64-CDTBYYIZ.node": "77231e00dfff9edfe476af2a30404740c0a44b14845445c1ed8594e2758f8875",
    "NodeTools/pnpm/dist/reflink.win32-arm64-msvc-IYGSKCGJ.node": "6e2597d13f461fb697303fb27308ef2ab29afe1e793523d6b40ca7644f84daa3",
    "NodeTools/pnpm/dist/reflink.win32-x64-msvc-5E6AAURT.node": "92cf1e61db1c58de603d228717dd32362da45f63ae32fe0b75bed4135132d65d",
    "NodeTools/pnpm/dist/vendor/fastlist-0.3.0-x86.exe": "017411f3b0b5c0402cc3b2cb87c32c6fc71abd82e5b17ea6108990096c75a65d",
    "NodeTools/pnpm/dist/vendor/fastlist-0.3.0-x64.exe": "d1a71f9ac1728082c1b276392725c3e010b98714888579b99152e401abedbf11",
}
SSH = "Frameworks/libssh2.framework"
MACHO = {bytes.fromhex(v) for v in ("cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}

# --- required-reason privacy manifests -------------------------------------

PRIVACY_MANIFEST_ROOT = (Path(__file__).resolve().parents[1]
                         / "FloeApp/Resources/PrivacyManifests/EmbeddedFrameworks")
REBUILT_FRAMEWORKS_ENV = "FLOE_PRIVACY_REBUILT_FRAMEWORKS"
REBUILT_PRIVACY_GENERATOR = "floe-ios_system-privacy-rebuild-v1"

# Apple's approved reason codes per category (fetched 2026-10-16 from
# NSPrivacyAccessedAPITypeReasons). A manifest may only use these values.
APPROVED_REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# Mach-O undefined symbols. `getattrlist` is listed by Apple under both
# FileTimestamp and DiskSpace; Floe's getattrlist call sites read file metadata
# (clone/private size, directory link count), so it maps to FileTimestamp.
SYMBOL_CATEGORIES = {
    "_stat": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_fstat": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_fstatat": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_lstat": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_getattrlist": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_getattrlistbulk": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_fgetattrlist": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_getattrlistat": "NSPrivacyAccessedAPICategoryFileTimestamp",
    "_statfs": "NSPrivacyAccessedAPICategoryDiskSpace",
    "_fstatfs": "NSPrivacyAccessedAPICategoryDiskSpace",
    "_statvfs": "NSPrivacyAccessedAPICategoryDiskSpace",
    "_fstatvfs": "NSPrivacyAccessedAPICategoryDiskSpace",
    "_mach_absolute_time": "NSPrivacyAccessedAPICategorySystemBootTime",
    "_mach_continuous_time": "NSPrivacyAccessedAPICategorySystemBootTime",
    "_OBJC_CLASS_$_NSUserDefaults": "NSPrivacyAccessedAPICategoryUserDefaults",
    "_activeInputModes": "NSPrivacyAccessedAPICategoryActiveKeyboards",
}

# Raw key/selector strings for APIs that are reached without a unique symbol.
STRING_CATEGORIES = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        "NSURLContentModificationDateKey", "NSURLCreationDateKey", "NSFileModificationDate",
        "fileModificationDate",
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "NSURLVolumeAvailableCapacityForImportantUsageKey",
        "NSURLVolumeAvailableCapacityForOpportunisticUsageKey",
        "NSURLVolumeAvailableCapacityKey", "NSURLVolumeTotalCapacityKey",
        "NSFileSystemFreeSize", "NSFileSystemSize",
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": ("systemUptime",),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ("activeInputModes",),
}

DISK_SPACE_SYMBOLS = frozenset(name for name, category in SYMBOL_CATEGORIES.items()
                               if category == "NSPrivacyAccessedAPICategoryDiskSpace")
FILE_TIMESTAMP_SYMBOLS = frozenset(name for name, category in SYMBOL_CATEGORIES.items()
                                   if category == "NSPrivacyAccessedAPICategoryFileTimestamp")
REBUILT_TARGETS = {"shell": "shell.framework", "text": "text.framework"}

# Every framework that can appear in Frameworks/ must be reviewed here. The
# value is the controlled manifest directory under PRIVACY_MANIFEST_ROOT, or
# None for a framework whose binary uses no required-reason API at all
# (verified by symbol and key-string scan). Anything else fails closed.
REVIEWED_EMBEDDED_FRAMEWORKS = {
    "CPDFium.framework": "CPDFium",
    "FloeOfficeNative.framework": "FloeOfficeNative",
    "RoyalVNCKit.framework": "RoyalVNCKit",
    "awk.framework": None,
    "curl_ios.framework": "curl_ios",
    "dash.framework": "dash",
    "dashA.framework": "dash",
    "dashB.framework": "dash",
    "dashC.framework": "dash",
    "dashD.framework": "dash",
    "dashE.framework": "dash",
    "files.framework": "files",
    "ios_system.framework": "ios_system",
    "libssh2.framework": None,
    "llama.framework": None,
    "openssl.framework": "openssl",
    "shell.framework": "shell",
    "tar.framework": "tar",
    "text.framework": "text",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def macho_slices(data):
    """Return the Mach-O images inside a thin or universal binary."""
    if len(data) < 8:
        return []
    if struct.unpack_from("<I", data, 0)[0] in (0xFEEDFACF, 0xFEEDFACE):
        return [data]
    if struct.unpack_from(">I", data, 0)[0] in (0xCAFEBABE, 0xCAFEBABF):
        magic = struct.unpack_from(">I", data, 0)[0]
        wide = magic == 0xCAFEBABF
        count = struct.unpack_from(">I", data, 4)[0]
        width = 32 if wide else 20
        slices = []
        for index in range(min(count, 64)):
            if 8 + (index + 1) * width > len(data):
                break
            fields = struct.unpack_from(">IIQQII" if wide else ">IIIII", data, 8 + index * width)
            offset, size = fields[2], fields[3]
            if offset + size <= len(data):
                slices.append(data[offset:offset + size])
        return slices
    return []


def thin_undefined_symbols(data):
    """Undefined external symbol names of one little-endian Mach-O image."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] not in (0xFEEDFACF, 0xFEEDFACE):
        return set()
    sixty_four = struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32 if sixty_four else 28
    symtab = None
    for _ in range(ncmds):
        if offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == 0x2 and offset + 24 <= len(data):
            symtab = struct.unpack_from("<IIII", data, offset + 8)  # symoff nsyms stroff strsize
        if cmdsize < 8:
            break
        offset += cmdsize
    if not symtab:
        return set()
    symoff, nsyms, stroff, strsize = symtab
    entry = 16 if sixty_four else 12
    if stroff + strsize > len(data) or symoff + nsyms * entry > len(data):
        return set()
    names = set()
    for index in range(nsyms):
        base = symoff + index * entry
        n_strx = struct.unpack_from("<I", data, base)[0]
        n_type = data[base + 4]
        if (n_type & 0x0E) != 0 or (n_type & 0x01) == 0 or n_strx == 0 or n_strx >= strsize:
            continue
        start = stroff + n_strx
        end = data.find(b"\0", start, stroff + strsize)
        if end < 0:
            continue
        names.add(data[start:end].decode("utf-8", "replace"))
    return names


def macho_undefined_symbols(data):
    names = set()
    for image in macho_slices(data):
        names.update(thin_undefined_symbols(image))
    return names


def required_reason_categories(data):
    """Categories the binary statically references (symbols plus raw key strings)."""
    categories = {}
    symbols = macho_undefined_symbols(data)
    for symbol, category in SYMBOL_CATEGORIES.items():
        if symbol in symbols:
            categories.setdefault(category, set()).add(symbol)
    for category, needles in STRING_CATEGORIES.items():
        found = [needle for needle in needles if needle.encode() in data]
        if found:
            categories.setdefault(category, set()).update(found)
    return categories


def validate_manifest(manifest, path):
    if not isinstance(manifest, dict):
        raise ValueError(f"Privacy manifest is not a plist dictionary: {path}")
    api_types = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(api_types, list):
        raise ValueError(f"NSPrivacyAccessedAPITypes must be an array: {path}")
    for entry in api_types:
        if not isinstance(entry, dict):
            raise ValueError(f"Privacy manifest API entry is not a dictionary: {path}")
        category = entry.get("NSPrivacyAccessedAPIType")
        if category not in APPROVED_REASONS:
            raise ValueError(f"Unknown privacy API category {category!r}: {path}")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(reasons, list) or not reasons:
            raise ValueError(f"Privacy manifest declares no reason for {category}: {path}")
        unknown = set(reasons) - APPROVED_REASONS[category]
        if unknown:
            raise ValueError(f"Unapproved reason(s) {sorted(unknown)} for {category}: {path}")
    if "NSPrivacyTracking" in manifest and not isinstance(manifest["NSPrivacyTracking"], bool):
        raise ValueError(f"NSPrivacyTracking must be a boolean: {path}")
    return manifest


def declared_categories(manifest):
    return {entry.get("NSPrivacyAccessedAPIType")
            for entry in manifest.get("NSPrivacyAccessedAPITypes", [])
            if isinstance(entry, dict)}


def manifest_from(path):
    manifest = validate_manifest(plistlib.loads(Path(path).read_bytes()), path)
    return manifest, Path(path).read_bytes()


def rebuilt_frameworks_error(framework):
    return (f"{framework} still calls statfs/fstatfs, a required-reason DiskSpace API whose "
            f"data this framework never uses and no approved reason covers. Rebuild it with "
            f"scripts/privacy-rebuild/rebuild_shell_frameworks.py and pass the rebuilt directory "
            f"via --rebuilt-frameworks (or {REBUILT_FRAMEWORKS_ENV}).")


def apply_rebuilt_privacy_frameworks(app, directory):
    """Substitute the reviewed shell/text privacy rebuilds before signing."""
    directory = Path(directory)
    provenance_path = directory / "PROVENANCE.json"
    if not provenance_path.is_file():
        raise ValueError(f"--rebuilt-frameworks directory has no PROVENANCE.json: {directory}")
    provenance = json.loads(provenance_path.read_text())
    if provenance.get("generator") != REBUILT_PRIVACY_GENERATOR:
        raise ValueError(f"Unexpected privacy rebuild generator: {provenance.get('generator')!r}")
    targets = provenance.get("targets")
    if not isinstance(targets, dict) or set(targets) != set(REBUILT_TARGETS):
        raise ValueError("Privacy rebuild provenance must describe exactly shell and text")
    report = []
    for target, framework_name in REBUILT_TARGETS.items():
        entry = targets[target]
        artifact = directory / entry["framework"]
        binary = artifact / entry["executable"]
        plist = artifact / "Info.plist"
        if sha(binary.read_bytes()) != entry.get("executableSHA256"):
            raise ValueError(f"Rebuilt {target} binary does not match its provenance")
        if sha(plist.read_bytes()) != entry.get("infoPlistSHA256"):
            raise ValueError(f"Rebuilt {target} Info.plist does not match its provenance")
        embedded = app / "Frameworks" / framework_name
        embedded_binary = embedded / entry["executable"]
        if not embedded_binary.is_file():
            raise ValueError(f"App has no embedded {framework_name} to substitute")
        pinned_symbols = macho_undefined_symbols(embedded_binary.read_bytes())
        rebuilt_symbols = macho_undefined_symbols(binary.read_bytes())
        pinned_exports = sorted(macho_exported_names(embedded_binary.read_bytes()))
        rebuilt_exports = sorted(macho_exported_names(binary.read_bytes()))
        if pinned_exports != rebuilt_exports:
            raise ValueError(f"Rebuilt {target} is not ABI-compatible: exported symbols changed")
        remaining = sorted(rebuilt_symbols & DISK_SPACE_SYMBOLS)
        if remaining:
            raise ValueError(f"Rebuilt {target} still imports {remaining}")
        if not (rebuilt_symbols & FILE_TIMESTAMP_SYMBOLS):
            raise ValueError(f"Rebuilt {target} lost its FileTimestamp imports")
        pinned_before = sha(embedded_binary.read_bytes())
        shutil.copyfile(binary, embedded_binary)
        shutil.copyfile(plist, embedded / "Info.plist")
        if sha(embedded_binary.read_bytes()) != entry["executableSHA256"]:
            raise ValueError(f"{framework_name} binary changed during substitution")
        report.append({
            "framework": framework_name,
            "pinned_executable_sha256": pinned_before,
            "rebuilt_executable_sha256": entry["executableSHA256"],
            "rebuilt_info_plist_sha256": entry["infoPlistSHA256"],
            "exported_symbols": len(rebuilt_exports),
            "required_reason_symbols": sorted(rebuilt_symbols & (DISK_SPACE_SYMBOLS | FILE_TIMESTAMP_SYMBOLS)),
            "provenance": "scripts/privacy-rebuild",
        })
    return report


def macho_exported_names(data):
    """Exported symbol names (N_EXT defined) of a thin or universal binary."""
    names = set()
    for image in macho_slices(data):
        if len(image) < 32 or struct.unpack_from("<I", image, 0)[0] not in (0xFEEDFACF, 0xFEEDFACE):
            continue
        sixty_four = struct.unpack_from("<I", image, 0)[0] == 0xFEEDFACF
        ncmds = struct.unpack_from("<I", image, 16)[0]
        offset = 32 if sixty_four else 28
        symtab = None
        for _ in range(ncmds):
            if offset + 8 > len(image):
                break
            cmd, cmdsize = struct.unpack_from("<II", image, offset)
            if cmd == 0x2 and offset + 24 <= len(image):
                symtab = struct.unpack_from("<IIII", image, offset + 8)
            if cmdsize < 8:
                break
            offset += cmdsize
        if not symtab:
            continue
        symoff, nsyms, stroff, strsize = symtab
        entry_size = 16 if sixty_four else 12
        if stroff + strsize > len(image) or symoff + nsyms * entry_size > len(image):
            continue
        for index in range(nsyms):
            base = symoff + index * entry_size
            n_strx = struct.unpack_from("<I", image, base)[0]
            n_type = image[base + 4]
            n_sect = image[base + 5]
            if (n_type & 0x01) == 0 or (n_type & 0x0E) != 0x0E or n_sect == 0:
                continue
            if n_strx == 0 or n_strx >= strsize:
                continue
            start = stroff + n_strx
            end = image.find(b"\0", start, stroff + strsize)
            if end >= 0:
                names.add(image[start:end].decode("utf-8", "replace"))
    return names


def verify_embedded_privacy_manifests(app, bundle_infos):
    """Inject controlled framework manifests and verify every executable's use."""
    frameworks, declared, injected = [], [], []
    for plist_path, info, executable in bundle_infos:
        bundle = plist_path.parent
        categories = required_reason_categories(executable.read_bytes())
        manifest_path = bundle / "PrivacyInfo.xcprivacy"
        if bundle.parent == app / "Frameworks":
            name = bundle.name
            if name not in REVIEWED_EMBEDDED_FRAMEWORKS:
                raise ValueError(f"Unreviewed embedded framework {name}; add it to "
                                 "REVIEWED_EMBEDDED_FRAMEWORKS or prove it uses no "
                                 "required-reason API")
            source_name = REVIEWED_EMBEDDED_FRAMEWORKS[name]
            if source_name is None:
                if categories:
                    raise ValueError(f"{name} is reviewed as clean but now uses "
                                     f"{sorted(categories)}")
            else:
                source = PRIVACY_MANIFEST_ROOT / source_name / "PrivacyInfo.xcprivacy"
                manifest, expected_bytes = manifest_from(source)
                missing = set(categories) - declared_categories(manifest)
                if missing:
                    detail = f"{name} uses {sorted(missing)} but its controlled manifest does not declare it"
                    if missing == {"NSPrivacyAccessedAPICategoryDiskSpace"} and name in REBUILT_TARGETS.values():
                        detail += ". " + rebuilt_frameworks_error(name)
                    raise ValueError(detail)
                before = sha(executable.read_bytes())
                if not manifest_path.exists() or manifest_path.read_bytes() != expected_bytes:
                    manifest_path.write_bytes(expected_bytes)
                after = sha(executable.read_bytes())
                if before != after:
                    raise ValueError(f"{name} executable changed during manifest injection")
                injected.append({"path": str(manifest_path.relative_to(app)),
                                 "sha256": sha(expected_bytes),
                                 "executable_sha256": after})
                frameworks.append({"path": str(bundle.relative_to(app)), "categories": sorted(categories),
                                   "executable_sha256": after,
                                   "manifest_sha256": sha(expected_bytes)})
        else:
            if manifest_path.exists():
                manifest, manifest_bytes = manifest_from(manifest_path)
                missing = set(categories) - declared_categories(manifest)
                if missing:
                    raise ValueError(f"{bundle.name} uses {sorted(missing)} but "
                                     f"{manifest_path.name} does not declare it")
                declared.append({"path": str(bundle.relative_to(app)), "categories": sorted(categories),
                                 "manifest_sha256": sha(manifest_bytes)})
            elif categories:
                raise ValueError(f"{bundle.name} uses {sorted(categories)} but has no "
                                 "PrivacyInfo.xcprivacy")
    return {"frameworks": frameworks, "injected": injected, "declared_bundles": declared}



def arm64_slice(data):
    """Return the existing generic arm64 slice, without rewriting its bytes."""
    magic = data[:4]
    if magic == bytes.fromhex("cffaedfe"):
        cpu, subtype = struct.unpack_from("<II", data, 4)
        if cpu != 0x100000C or subtype & 0xFFFFFF != 0:
            raise ValueError("Expected generic arm64 Mach-O")
        return data
    if magic not in (bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")):
        raise ValueError("Unsupported universal Mach-O format")
    count = struct.unpack_from(">I", data, 4)[0]
    wide = magic == bytes.fromhex("cafebabf")
    width = 32 if wide else 20
    if not 1 <= count <= 16 or len(data) < 8 + count * width:
        raise ValueError("Invalid universal Mach-O table")
    result = None
    for i in range(count):
        fields = struct.unpack_from(">IIQQII" if wide else ">IIIII", data, 8 + i * width)
        cpu, subtype, offset, size = fields[:4]
        if offset < 8 + count * width or offset + size > len(data):
            raise ValueError("Universal Mach-O slice exceeds file bounds")
        if cpu == 0x100000C and subtype & 0xFFFFFF == 0:
            if result is not None:
                raise ValueError("Duplicate arm64 slice")
            result = data[offset:offset + size]
    if result is None:
        raise ValueError("Missing generic arm64 slice")
    return result


def build_settings(binary):
    output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
    settings = []
    for block in re.split(r"Load command \d+", output)[1:]:
        if re.search(r"cmd LC_BUILD_VERSION\b", block):
            platform = re.findall(r"^\s*platform\s+(\S+)", block, re.M)
            minimum = re.findall(r"^\s*minos\s+(\S+)", block, re.M)
            if platform != ["IOS"]: raise ValueError(f"Non-iOS executable: {binary}")
        elif "cmd LC_VERSION_MIN_IPHONEOS" in block:
            minimum = re.findall(r"^\s*version\s+(\S+)", block, re.M)
        else:
            raise ValueError(f"Unrecognized deployment command: {binary}")
        sdk = re.findall(r"^\s*sdk\s+(\S+)", block, re.M)
        if len(minimum) != 1 or len(sdk) != 1:
            raise ValueError(f"Missing deployment metadata: {binary}")
        settings.append((minimum[0], sdk[0]))
    if not settings: raise ValueError(f"No deployment command: {binary}")
    return settings


def version_tuple(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value): raise ValueError("Invalid deployment version")
    values = tuple(map(int, value.split(".")))
    return values + (0,) * (3 - len(values))


def normalize(app, report_path, *, addon_hashes=ADDONS, rebuilt_frameworks=None):
    app = Path(app).resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Expected an existing application bundle")
    removals = []
    for relative, expected in addon_hashes.items():
        p = app / relative
        if p.exists():
            if p.is_symlink() or sha(p.read_bytes()) != expected:
                raise ValueError(f"Unreviewed addon bytes: {relative}")
            removals.append(p)

    # The reviewed privacy rebuilds (shell/text without statfs) replace the
    # pinned framework binaries before any other validation sees the bundle.
    rebuilt_report = []
    if rebuilt_frameworks:
        rebuilt_report = apply_rebuilt_privacy_frameworks(app, rebuilt_frameworks)

    # Validate all metadata and native resource locations before making changes.
    executables = set()
    ssh_plist = None
    ssh_info = None
    bundle_infos = []
    for p in app.rglob("Info.plist"):
        if p.parent.suffix not in (".app", ".appex", ".framework"):
            continue
        info = plistlib.loads(p.read_bytes())
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name or Path(name).name != name:
            raise ValueError(f"Invalid bundle executable: {p.relative_to(app)}")
        executable = p.parent / name
        if not executable.is_file() or executable.is_symlink():
            raise ValueError(f"Missing bundle executable: {p.relative_to(app)}")
        executables.add(executable)
        bundle_infos.append((p, info, executable))
        minimum = info.get("MinimumOSVersion")
        if p.parent == app / SSH:
            if info.get("CFBundleShortVersionString") != "1.11.0" or info.get("CFBundleIdentifier") != "org.libssh2":
                raise ValueError("libssh2 package changed; review normalization policy")
            ssh_plist, ssh_info = p, info
            if minimum == "ios_version_min":
                continue
        if not isinstance(minimum, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum):
            raise ValueError(f"Invalid MinimumOSVersion: {p.relative_to(app)}")
    for p in app.rglob("*"):
        if not p.is_file() or p in executables or p in removals:
            continue
        with p.open("rb") as f:
            magic = f.read(4)
        # Mach-O is loadable Apple code. Foreign-format supplier data (such as
        # pip's Windows script templates) is not an Apple executable and must
        # not be removed by a broad file-extension rule.
        if magic in MACHO:
            raise ValueError(f"Standalone native binary: {p.relative_to(app)}")

    # Compare every embedded bundle against its actual deployment load commands.
    dash_updates = []
    deployment_checks = []
    for p, info, binary in bundle_infos:
        settings = build_settings(binary)
        minimum = "14.0" if p == ssh_plist and info["MinimumOSVersion"] == "ios_version_min" else info["MinimumOSVersion"]
        name = p.parent.stem
        if p.parent.parent == app / "Frameworks" and name in ("dash", "dashA", "dashB", "dashC", "dashD", "dashE"):
            if (info.get("CFBundleIdentifier") != "dev.floe." + name or info.get("CFBundleShortVersionString") != "1.0"
                    or len(set(settings)) != 1 or settings[0][0] != "26.0" or minimum not in ("14.0", "26.0")):
                raise ValueError("Changed dash framework requires packaging review")
            minimum, sdk = settings[0]
            updated = dict(info, MinimumOSVersion=minimum, DTSDKName="iphoneos" + sdk, DTPlatformVersion=sdk)
            stale = [key for key in ("BuildMachineOSBuild", "DTPlatformBuild", "DTSDKBuild", "DTXcode", "DTXcodeBuild") if key in updated]
            for key in stale: updated.pop(key)  # Old vendor-template build provenance is not this binary's provenance.
            dash_updates.append((p, updated, {"path": str(p.parent.relative_to(app)), "minimum_os_before": info["MinimumOSVersion"],
                                 "minimum_os_after": minimum, "actual_sdk": sdk, "removed_stale_build_metadata": stale, "executable_sha256_unchanged": sha(binary.read_bytes())}))
        if any(version_tuple(minimum) < version_tuple(actual) for actual, _ in settings):
            raise ValueError(f"MinimumOSVersion understates executable deployment: {p.relative_to(app)}")
        deployment_checks.append({"path": str(p.relative_to(app)), "minimum_os": minimum, "binary_versions": settings})

    ssh_change = None
    if ssh_plist is not None:
        binary = ssh_plist.parent / ssh_info["CFBundleExecutable"]
        original = binary.read_bytes()
        active = arm64_slice(original)
        build = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", str(binary)], text=True)
        if (re.findall(r"^\s*platform\s+(\S+)", build, re.M) != ["IOS"]
                or re.findall(r"^\s*minos\s+(\S+)", build, re.M) != ["14.0"]
                or re.findall(r"^\s*sdk\s+(\S+)", build, re.M) != ["16.2"]):
            raise ValueError("Unexpected libssh2 load commands; do not invent SDK metadata")
        arches = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        if set(arches) not in ({"arm64"}, {"arm64", "arm64e"}):
            raise ValueError(f"Unexpected libssh2 architectures: {arches}")
        if ssh_info["MinimumOSVersion"] not in ("ios_version_min", "14.0"):
            raise ValueError("Unexpected libssh2 minimum OS")
        ssh_change = {"path": SSH, "arm64_sha256": sha(active), "architectures_before": arches,
                      "architectures_after": ["arm64"], "minimum_os_before": ssh_info["MinimumOSVersion"],
                      "minimum_os_after": "14.0", "recorded_sdk_unchanged": "16.2"}
        # Write the already-existing slice directly: exact bytes, no relinking
        # or SDK spoofing. Signing happens only after this transformation.
        if original != active:
            temporary = binary.with_name(binary.name + ".arm64-stage")
            temporary.write_bytes(active)
            temporary.chmod(stat.S_IMODE(binary.stat().st_mode))
            temporary.replace(binary)
        if sha(binary.read_bytes()) != sha(active):
            raise ValueError("arm64 content changed during normalization")
        if subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split() != ["arm64"]:
            raise ValueError("Unexpected normalized architecture")
        ssh_info["MinimumOSVersion"] = "14.0"
        ssh_plist.write_bytes(plistlib.dumps(ssh_info))
    for p, info, _ in dash_updates:
        p.write_bytes(plistlib.dumps(info))
    for p in removals:
        p.unlink()
    privacy_report = verify_embedded_privacy_manifests(app, bundle_infos)
    report = {"policy": "build156-app-store-bundle-v2", "removed_non_ios_addons": [str(p.relative_to(app)) for p in removals],
              "libssh2": ssh_change, "dash_frameworks": [entry for _, _, entry in dash_updates],
              "deployment_checks": deployment_checks, "validated_bundle_executables": len(executables),
              "rebuilt_privacy_frameworks": rebuilt_report,
              "privacy_manifests": privacy_report}
    Path(report_path).write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--rebuilt-frameworks", default=None,
                        help="directory produced by scripts/privacy-rebuild/rebuild_shell_frameworks.py "
                             f"(defaults to ${REBUILT_FRAMEWORKS_ENV})")
    args = parser.parse_args()
    rebuilt = args.rebuilt_frameworks or os.environ.get(REBUILT_FRAMEWORKS_ENV)
    print(json.dumps(normalize(args.app, args.report, rebuilt_frameworks=rebuilt), indent=2))
