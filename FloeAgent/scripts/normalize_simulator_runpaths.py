#!/usr/bin/env python3
"""Make an explicitly owned iOS Simulator .app independent of mutable products.

Only absolute PackageFrameworks LC_RPATH commands are removed. All Mach-O
images are checked before any change; dependencies must resolve in this bundle
or the platform libraries. Device/macOS images, escaping symlinks and hardlinks
are refused. install_name_tool only runs on private staged copies. Signing is
always ad-hoc and never consults a developer signing identity. Three exact
Xcode-injected test libraries are allowed only at a verified .xctest root.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile


class InvalidBundle(ValueError):
    pass


LC_RPATH = 0x8000001C
DYLIB_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20}
BUNDLE_SUFFIXES = {".app", ".appex", ".framework", ".xctest", ".bundle"}
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
          b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
          b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}
SIGNATURE_ORIGIN_FLAGS = 0x2 | 0x20000  # CS_ADHOC / CS_LINKER_SIGNED are provenance, not behavior.
TEST_RUNTIME = {
    "@rpath/XCTest.framework/XCTest": "Developer/Library/Frameworks/XCTest.framework/XCTest",
    "@rpath/Testing.framework/Testing": "Developer/Library/Frameworks/Testing.framework/Testing",
    "@rpath/libXCTestSwiftSupport.dylib": "Developer/usr/lib/libXCTestSwiftSupport.dylib",
}


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def _digest_range(data, start, size):
    digest = hashlib.sha256()
    for offset in range(start, start + size, 8 * 1024 * 1024):
        digest.update(data[offset:min(offset + 8 * 1024 * 1024, start + size)])
    return digest.hexdigest()


def read_macho(path):
    """Return per-slice load facts and instruction-section hashes, or None."""
    with path.open("rb") as stream:
        magic = stream.read(4)
        if magic not in MAGICS:
            return None  # Static archives and resources are never rewritten.
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            def checked(offset, size, limit=len(data)):
                if offset < 0 or size < 0 or offset + size > limit:
                    raise InvalidBundle(f"Truncated Mach-O: {path.name}")

            slices = [(0, len(data))]
            if magic in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
                         b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}:
                endian = ">" if magic[:2] == b"\xca\xfe" else "<"
                wide = magic in {b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
                checked(0, 8)
                count = struct.unpack_from(endian + "I", data, 4)[0]
                if not 1 <= count <= 64:
                    raise InvalidBundle("Invalid universal Mach-O slice count")
                width = 32 if wide else 20
                checked(8, count * width)
                slices = []
                for index in range(count):
                    fields = struct.unpack_from(endian + ("IIQQII" if wide else "IIIII"),
                                                data, 8 + index * width)
                    start, size = fields[2:4]
                    checked(start, size)
                    if start < 8 + count * width or any(
                            start < other + length and other < start + size
                            for other, length in slices):
                        raise InvalidBundle("Overlapping universal Mach-O slices")
                    slices.append((start, size))
            images = []
            for start, length in slices:
                signature = data[start:start + 4]
                endian = "<" if signature in {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"} else ">"
                wide = signature in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
                if signature not in MAGICS or signature in {
                        b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
                        b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}:
                    raise InvalidBundle("Invalid thin Mach-O slice")
                header_size = 32 if wide else 28
                checked(start, header_size, start + length)
                cpu, subtype, filetype, count, size = struct.unpack_from(endian + "IIIII", data, start + 4)
                if count > 65536 or size > 16 * 1024 * 1024:
                    raise InvalidBundle("Unreasonable Mach-O command table")
                commands_start, commands_end = start + header_size, start + header_size + size
                checked(commands_start, size, start + length)
                result = {"cpu": cpu, "subtype": subtype, "filetype": filetype,
                          "rpaths": [], "dependencies": [], "platforms": [],
                          "uuids": [], "installName": None, "codeSections": []}
                offset = commands_start
                for _ in range(count):
                    checked(offset, 8, commands_end)
                    command, command_size = struct.unpack_from(endian + "II", data, offset)
                    if command_size < 8 or command_size % 4:
                        raise InvalidBundle("Invalid Mach-O load command size")
                    checked(offset, command_size, commands_end)
                    if command == LC_RPATH or command in DYLIB_COMMANDS or command == 0xD:
                        checked(offset, 12, offset + command_size)
                        string_offset = struct.unpack_from(endian + "I", data, offset + 8)[0]
                        if not 12 <= string_offset < command_size:
                            raise InvalidBundle("Invalid Mach-O command string")
                        end = data.find(b"\0", offset + string_offset, offset + command_size)
                        if end < 0:
                            raise InvalidBundle("Unterminated Mach-O command string")
                        value = data[offset + string_offset:end].decode("utf-8")
                        if command == LC_RPATH:
                            result["rpaths"].append(value)
                        elif command == 0xD:
                            result["installName"] = value
                        else:
                            result["dependencies"].append({"name": value, "weak": command == 0x80000018})
                    elif command == 0x32:
                        checked(offset, 24, offset + command_size)
                        result["platforms"].append(struct.unpack_from(endian + "I", data, offset + 8)[0])
                    elif command == 0x1B:
                        checked(offset, 24, offset + command_size)
                        result["uuids"].append(data[offset + 8:offset + 24].hex())
                    elif command in {0x1, 0x19}:
                        segment_wide = command == 0x19
                        segment_size, section_size = (72, 80) if segment_wide else (56, 68)
                        checked(offset, segment_size, offset + command_size)
                        sections = struct.unpack_from(endian + "I", data, offset + (64 if segment_wide else 48))[0]
                        checked(offset + segment_size, sections * section_size, offset + command_size)
                        for index in range(sections):
                            section = offset + segment_size + index * section_size
                            name = data[section:section + 16].split(b"\0", 1)[0].decode("utf-8")
                            segment = data[section + 16:section + 32].split(b"\0", 1)[0].decode("utf-8")
                            section_length = struct.unpack_from(endian + ("Q" if segment_wide else "I"),
                                                                data, section + (40 if segment_wide else 36))[0]
                            section_offset = struct.unpack_from(endian + "I", data, section + (48 if segment_wide else 40))[0]
                            flags = struct.unpack_from(endian + "I", data, section + (64 if segment_wide else 56))[0]
                            if name == "__text" or flags & (0x80000000 | 0x400):
                                checked(start + section_offset, section_length, start + length)
                                result["codeSections"].append({"segment": segment, "section": name,
                                                              "size": section_length,
                                                              "sha256": _digest_range(data, start + section_offset, section_length)})
                    offset += command_size
                if offset != commands_end:
                    raise InvalidBundle("Inconsistent Mach-O command table")
                images.append(result)
            return images


def is_system(path):
    return str(path).startswith(("/System/Library/", "/usr/lib/"))


def mutable_rpath(value):
    return value.startswith("/") and "PackageFrameworks" in Path(value).parts


def validate_rpath(value):
    if mutable_rpath(value):
        return
    if value.startswith("/"):
        if not is_system(Path(os.path.normpath(value))):
            raise InvalidBundle(f"Non-system absolute runpath needs explicit repair: {value}")
    elif not any(value == token or value.startswith(token + "/")
                 for token in ("@loader_path", "@executable_path")):
        raise InvalidBundle(f"Unsupported relative runpath: {value}")


def inspect_bundle(app, owner_root):
    app, owner_root = Path(os.path.abspath(app)), Path(os.path.abspath(owner_root))
    if (not owner_root.is_dir() or owner_root == Path("/") or owner_root.resolve() != owner_root
            or app.resolve() != app or not app.is_relative_to(owner_root) or app == owner_root
            or app.suffix != ".app" or not app.is_dir()):
        raise InvalidBundle("Pass a real .app inside its explicit, non-aliased owner root")
    images, stats = {}, {}
    bundle_device = app.stat().st_dev
    for base, directories, files in os.walk(app, followlinks=False):
        for name in directories + files:
            path = Path(base) / name
            if path.is_symlink():
                if not path.resolve().is_relative_to(app) or not path.exists():
                    raise InvalidBundle(f"Escaping or dangling symlink: {path.relative_to(app)}")
            elif not path.is_dir() and not path.is_file():
                raise InvalidBundle(f"Special file in bundle: {path.relative_to(app)}")
            elif path.stat().st_dev != bundle_device:
                raise InvalidBundle(f"Mounted filesystem inside bundle: {path.relative_to(app)}")
        for name in files:
            path = Path(base) / name
            if path.is_symlink():
                continue
            stat = path.stat()
            if stat.st_nlink != 1:
                raise InvalidBundle(f"Hardlinked file; make an independent bundle copy: {path.relative_to(app)}")
            stats[path] = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
            parsed = read_macho(path)
            if parsed is not None:
                for image in parsed:
                    if image["platforms"] != [7] or image["filetype"] not in {2, 6, 8}:
                        raise InvalidBundle(f"Only iOS Simulator executable/dylib/bundle images are accepted: {path.relative_to(app)}")
                    for value in image["rpaths"]:
                        validate_rpath(value)
                removable = [{value for value in image["rpaths"] if mutable_rpath(value)} for image in parsed]
                if any(values != removable[0] for values in removable[1:]):
                    raise InvalidBundle("Universal slices have different mutable runpaths; refusing partial repair")
                images[path] = parsed
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    executable = info.get("CFBundleExecutable", "")
    if (info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]
            or info.get("DTPlatformName") != "iphonesimulator"
            or not info.get("CFBundleIdentifier") or Path(executable).name != executable
            or not executable or app / executable not in images
            or any(image["filetype"] != 2 for image in images[app / executable])):
        raise InvalidBundle("The main bundle is not an identified iOS Simulator app")
    return app, images, stats, app / executable


def official_test_runtime(name, cpu):
    platform = Path(_run(["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-platform-path"]).stdout.strip()).resolve()
    if platform.name != "iPhoneSimulator.platform" or not platform.is_dir():
        raise InvalidBundle("Cannot verify the current Simulator test runtime")
    path = (platform / TEST_RUNTIME[name]).resolve()
    if not path.is_relative_to(platform) or not path.is_file():
        raise InvalidBundle(f"Official Simulator test runtime is missing: {name}")
    slices = read_macho(path)
    matching = [image for image in slices or [] if image["cpu"] == cpu and image["platforms"] == [7]]
    if len(matching) != 1:
        raise InvalidBundle(f"Official test runtime platform/architecture mismatch: {name}")
    return {"path": str(path), "sha256": digest_file(path), "image": matching[0]}


def dependency_closure(app, images, main):
    """Resolve the post-repair loader chains; never consult mutable products."""
    resolved, visited = [], set()

    def expand(value, loader, executable_dir):
        for token, root in (("@loader_path", loader.parent), ("@executable_path", executable_dir)):
            if value == token or value.startswith(token + "/"):
                return (root / value[len(token):].lstrip("/")).resolve()
        if value.startswith("/"):
            return Path(os.path.normpath(value))
        raise InvalidBundle(f"Unsupported dependency path: {value}")

    def runpaths(image, loader, executable_dir):
        paths = [expand(value, loader, executable_dir) for value in image["rpaths"] if not mutable_rpath(value)]
        if any(not path.is_relative_to(app) and not is_system(path) for path in paths):
            raise InvalidBundle(f"Relative runpath escapes bundle: {loader.relative_to(app)}")
        return paths

    def walk(loader, cpu, executable_dir, inherited):
        key = (loader, cpu, executable_dir)
        if key in visited:
            return
        visited.add(key)
        matches = [image for image in images[loader] if image["cpu"] == cpu]
        if len(matches) != 1:
            raise InvalidBundle(f"Missing or ambiguous dependency architecture: {loader.relative_to(app)}")
        image = matches[0]
        paths = list(dict.fromkeys(runpaths(image, loader, executable_dir) + inherited))
        for dependency in image["dependencies"]:
            name = dependency["name"]
            if name.startswith("@rpath/"):
                candidates = [path / name[len("@rpath/"):] for path in paths]
            else:
                candidates = [expand(name, loader, executable_dir)]
            target, system = None, False
            for candidate in candidates:
                # Platform install names refer to the Simulator runtime/cache,
                # not this host's filesystem (whose frameworks may be symlinks
                # into a macOS Cryptex).
                candidate = Path(os.path.normpath(candidate))
                if is_system(candidate):
                    # Swift dylibs can be supplied by the Simulator dyld cache.
                    # A similarly named application framework is never assumed
                    # to exist in /usr/lib/swift just because that RPATH exists.
                    if not name.startswith("@") or (candidate.parent == Path("/usr/lib/swift")
                                                    and candidate.name.startswith("libswift")
                                                    and candidate.suffix == ".dylib"):
                        target, system = candidate, True
                        break
                    continue
                candidate = candidate.resolve()
                if not candidate.is_relative_to(app):
                    raise InvalidBundle(f"Dependency escapes bundle: {name}")
                if candidate in images:
                    target = candidate
                    break
            if target is None:
                # Only an actual .xctest executable may use these three exact
                # Xcode-injected libraries. Business libraries and main/appex
                # dependencies still require complete closure inside the app.
                if (name in TEST_RUNTIME and image["filetype"] == 8 and loader.parent.suffix == ".xctest"
                        and plistlib.loads((loader.parent / "Info.plist").read_bytes()).get("CFBundleExecutable") == loader.name):
                    runtime = official_test_runtime(name, cpu)
                    resolved.append({"loader": str(loader.relative_to(app)), "cpu": cpu, "name": name,
                                     "requiresXcodeTestRuntime": True, "officialRuntime": runtime})
                    continue
                if dependency["weak"]:
                    resolved.append({"loader": str(loader.relative_to(app)), "cpu": cpu,
                                     "name": name, "weakMissing": True})
                    continue
                raise InvalidBundle(f"Unresolved bundled dependency in {loader.relative_to(app)}: {name}")
            resolved.append({"loader": str(loader.relative_to(app)), "cpu": cpu, "name": name,
                             "target": str(target if system else target.relative_to(app)), "system": system})
            if not system:
                walk(target, cpu, executable_dir, paths)

    roots = [path for path, slices in images.items() if slices[0]["filetype"] in {2, 8}]
    for root in sorted(roots):
        for image in images[root]:
            executable_dir = root.parent if image["filetype"] == 2 else main.parent
            inherited = [] if image["filetype"] == 2 else runpaths(images[main][0], main, main.parent)
            walk(root, image["cpu"], executable_dir, inherited)
    # Also verify embedded images only opened later via dlopen.
    for path, slices in images.items():
        host = next((parent for parent in path.parents if parent.suffix in {".appex", ".xctest"}), app)
        host_main = next((root for root in roots if root.parent == host), main)
        executable_dir = host if host.suffix == ".appex" else app
        for image in slices:
            inherited = runpaths(images[host_main][0], host_main, executable_dir)
            walk(path, image["cpu"], executable_dir, inherited)
    return resolved


def _run(arguments):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise InvalidBundle(f"{Path(arguments[0]).name} failed: {result.stderr.strip()}")
    return result


def code_targets(path, app):
    containers = [parent for parent in path.parents if parent.is_relative_to(app)
                  and parent.suffix in BUNDLE_SUFFIXES]
    if not containers:
        raise InvalidBundle("Code is outside the app")
    nearest = containers[0]
    info_path = nearest / "Info.plist"
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    targets = containers[:]
    if nearest.suffix != ".framework" and path != nearest / info.get("CFBundleExecutable", ""):
        targets.insert(0, path)  # A loose debug/compatibility dylib needs its own signature.
    return targets


def _signature_valid(target, deep=False):
    command = ["/usr/bin/codesign", "--verify", "--strict"]
    if deep:
        command.append("--deep")
    return subprocess.run(command + [str(target)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0


def signature_profile(target):
    result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", "--entitlements", "-", "--xml", str(target)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        return None  # Unsigned code receives an ad-hoc signature.
    text = result.stderr.decode("utf-8")
    identifier = re.search(r"^Identifier=(.+)$", text, re.MULTILINE)
    flags = re.search(r"\bflags=(0x[0-9a-fA-F]+)", text)
    if not identifier or not flags:
        raise InvalidBundle("Cannot preserve the existing code signature metadata")
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else None
    return {"identifier": identifier.group(1), "flags": int(flags.group(1), 16),
            "entitlements": entitlements}


def resource_hashes(app, images):
    return {str(path.relative_to(app)): digest_file(path)
            for path in sorted(app.rglob("*")) if path.is_file() and not path.is_symlink() and path not in images}


def normalize(app, owner_root, *, check=False, seal_bundle=False):
    app, before, stats, main = inspect_bundle(app, owner_root)
    closure = dependency_closure(app, before, main)
    changes = {path: sorted({value for image in slices for value in image["rpaths"] if mutable_rpath(value)})
               for path, slices in before.items() if any(mutable_rpath(value) for image in slices for value in image["rpaths"])}
    report = {"app": str(app), "checkOnly": check, "sealBundle": seal_bundle,
              "imageCount": len(before), "changedImages": [], "signedTargets": [],
              "imagesBefore": {str(path.relative_to(app)): value for path, value in before.items()},
              "dependencies": closure}
    if check:
        report["wouldChange"] = [str(path.relative_to(app)) for path in changes]
        return report
    all_targets = {target for path in before for target in code_targets(path, app)}
    # install_name_tool can discard a linker signature. Capture metadata before
    # it runs; --preserve-metadata after the edit cannot recover that metadata.
    profiles = {target: signature_profile(target) for target in sorted(all_targets)}
    resources_before = resource_hashes(app, before)
    staged = {}
    try:
        # Complete validation/staging before replacing any original image.
        for path, values in changes.items():
            descriptor, temporary = tempfile.mkstemp(prefix=".floe-rpath-", dir=path.parent)
            os.close(descriptor)
            temporary = Path(temporary)
            staged[path] = temporary
            shutil.copy2(path, temporary)
            _run(["/usr/bin/xcrun", "install_name_tool", *[item for value in values for item in ("-delete_rpath", value)], str(temporary)])
            expected = [{**image, "rpaths": [value for value in image["rpaths"] if not mutable_rpath(value)]}
                        for image in before[path]]
            if read_macho(temporary) != expected:
                raise InvalidBundle(f"Code or load facts changed unexpectedly: {path.relative_to(app)}")
            report["changedImages"].append({"path": str(path.relative_to(app)), "removedRunpaths": values,
                                             "beforeSHA256": digest_file(path)})
        for path in changes:
            current = path.stat()
            if path.is_symlink() or current.st_nlink != 1 or (
                    current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != stats[path]:
                raise InvalidBundle("Bundle changed during normalization; refusing replacement")
        for path, temporary in staged.items():
            os.replace(temporary, path)
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)

    targets = {target for path in changes for target in code_targets(path, app)}
    if seal_bundle and (changes or not _signature_valid(app, deep=True)):
        for target in all_targets:
            if not _signature_valid(target):
                targets.add(target)
                targets.update(parent for parent in target.parents if parent.is_relative_to(app)
                               and parent.suffix in BUNDLE_SUFFIXES)
    for target in sorted(targets, key=lambda path: (-len(path.parts), str(path))):
        profile = profiles[target]
        with tempfile.TemporaryDirectory(prefix="floe-simulator-sign-") as scratch:
            command = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none"]
            if profile:
                command += ["--identifier", profile["identifier"], "--options", hex(profile["flags"] & ~SIGNATURE_ORIGIN_FLAGS)]
                if profile["entitlements"] is not None:
                    entitlements = Path(scratch) / "entitlements.plist"
                    entitlements.write_bytes(plistlib.dumps(profile["entitlements"]))
                    command += ["--entitlements", str(entitlements)]
            _run(command + [str(target)])
        after_profile = signature_profile(target)
        if (not after_profile or not after_profile["flags"] & 0x2
                or (profile and (after_profile["identifier"] != profile["identifier"]
                                 or after_profile["entitlements"] != profile["entitlements"]
                                 or after_profile["flags"] & ~SIGNATURE_ORIGIN_FLAGS != profile["flags"] & ~SIGNATURE_ORIGIN_FLAGS))):
            raise InvalidBundle(f"Signature metadata was not preserved: {target.relative_to(app)}")
        if not _signature_valid(target):
            raise InvalidBundle(f"Ad-hoc signature verification failed: {target.relative_to(app)}")
        report["signedTargets"].append(str(target.relative_to(app)))
        report.setdefault("signatureActions", []).append({"target": str(target.relative_to(app)),
                                                          "before": profile, "after": after_profile})
    if seal_bundle and not _signature_valid(app, deep=True):
        raise InvalidBundle("The normalized app did not pass strict deep signature verification")
    for path, original in before.items():
        expected = [{**image, "rpaths": [value for value in image["rpaths"] if not mutable_rpath(value)]}
                    for image in original]
        if read_macho(path) != expected:
            raise InvalidBundle(f"Post-signing code or load facts changed: {path.relative_to(app)}")
    for change in report["changedImages"]:
        change["afterSHA256"] = digest_file(app / change["path"])
    resources_after = resource_hashes(app, before)
    resource_changes = [{"path": path, "beforeSHA256": resources_before.get(path),
                         "afterSHA256": resources_after.get(path)}
                        for path in sorted(resources_before.keys() | resources_after.keys())
                        if resources_before.get(path) != resources_after.get(path)]
    if any(Path(change["path"]).parts[-2:] != ("_CodeSignature", "CodeResources") for change in resource_changes):
        raise InvalidBundle("A non-signature resource changed during normalization")
    report["resourceChanges"] = resource_changes
    report["strictBundleSignatureVerified"] = seal_bundle
    report["codeSectionsUnchanged"] = True
    report["mainExecutable"] = str(main.relative_to(app))
    report["mainExecutableSHA256"] = digest_file(main)
    report["bundleIdentifier"] = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    report["normalAppDependenciesClosed"] = True
    report["requiresXcodeTestRuntime"] = [entry for entry in closure if entry.get("requiresXcodeTestRuntime")]
    report["scriptSHA256"] = digest_file(Path(__file__).resolve())
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--owner-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true", help="Validate and describe the repair without writing")
    parser.add_argument("--seal-bundle", action="store_true", help="Also seal previously unsealed Simulator code, ad-hoc only")
    parser.add_argument("--report", type=Path, help="Write detailed JSON outside the app")
    args = parser.parse_args()
    try:
        if args.report:
            report_path = Path(os.path.abspath(args.report))
            if (report_path.resolve().is_relative_to(args.app.resolve())
                    or not report_path.parent.is_dir() or report_path.parent.resolve() != report_path.parent or report_path.is_symlink()
                    or (report_path.exists() and (not report_path.is_file() or report_path.stat().st_nlink != 1))):
                raise InvalidBundle("The report must be a non-aliased file outside the signed app")
        report = normalize(args.app, args.owner_root, check=args.check, seal_bundle=args.seal_bundle)
        if args.report:
            descriptor, temporary = tempfile.mkstemp(prefix=".floe-simulator-receipt-", dir=report_path.parent)
            try:
                with os.fdopen(descriptor, "w") as stream:
                    stream.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
                os.replace(temporary, report_path)
            finally:
                Path(temporary).unlink(missing_ok=True)
        print(json.dumps({"imageCount": report["imageCount"], "wouldChangeImages": len(report["wouldChange"]), "checkOnly": True}
                         if args.check else {"imageCount": report["imageCount"],
                                            "changedImages": len(report["changedImages"]),
                                            "signedTargets": len(report["signedTargets"]),
                                            "strictBundleSignatureVerified": report["strictBundleSignatureVerified"]}))
        return 0
    except (InvalidBundle, OSError, ValueError, struct.error) as error:
        print(f"normalize_simulator_runpaths: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
