#!/usr/bin/env python3
"""Derive one patched OCCT static slice by a single-object archive backport.

The pinned upstream OCCT slice is the base input.  Exactly one member,
``Standard_Type.cxx.o``, is compiled from the exact reviewed overlay source
against the pinned OCCT headers and the declared Xcode/SDK/target/Release
C++17 flags.  That object replaces the base member, ``ranlib`` rebuilds the
symbol index, and the result is verified to have:

* the same member count and member order as the pinned base archive;
* every non-index, non-target member record byte-for-byte identical;
* a valid regenerated symbol index whose offsets name real member starts;
* the expected arm64 architecture, Mach-O platform and minimum OS;
* the same Standard_Type RTTI/API symbol set as the base object, including
  the vtable, type-info and type-info-name data symbols.

This is deliberately a *surgical reconstruction*, not a full 47-toolkit OCCT
rebuild.  The full source and patch are retained beside the recipe; the
base archive remains the upstream integrity anchor.

The script writes both the derived archive and a JSON receipt.  It never
installs over a live vendor file: ``bootstrap.py`` verifies the outputs and
performs its own atomic install.

Python 3.8+, standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import derivation_common as dc  # noqa: E402
import occt_archive as oa  # noqa: E402

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_OBJECT = 1
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2
PLATFORM_IOSSIMULATOR = 7
PRODUCER_PATH = "relink/derivations/derive_standard_type_slice.py"


class DeriveError(Exception):
    """Actionable derivation failure."""


def _run(argv, timeout, env=None, cwd=None):
    try:
        return subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, env=env, cwd=cwd,
        )
    except OSError as exc:
        raise DeriveError("cannot run %r: %s" % (argv[0], exc))
    except subprocess.TimeoutExpired:
        raise DeriveError("command timed out after %s seconds: %s"
                          % (timeout, argv[0]))


def _text(data):
    return data.decode("utf-8", "replace").strip()


def _tool(name, developer_dir):
    if developer_dir:
        candidate = os.path.join(
            developer_dir, "Toolchains", "XcodeDefault.xctoolchain", "usr", "bin", name
        )
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which(name)
    if found:
        return found
    raise DeriveError("required tool %r was not found; set DEVELOPER_DIR to a "
                      "full Xcode installation" % name)


def _xcrun(developer_dir, args, timeout=60):
    # xcrun is the system dispatcher, not an executable inside Xcode's
    # Developer/usr/bin. Select the requested Xcode through its environment.
    xcrun = shutil.which("xcrun")
    if not xcrun:
        raise DeriveError("xcrun was not found; set DEVELOPER_DIR to a full Xcode installation")
    environment = dict(os.environ)
    if developer_dir:
        environment["DEVELOPER_DIR"] = developer_dir
    result = _run([xcrun] + list(args), timeout, env=environment)
    if result.returncode != 0:
        raise DeriveError("xcrun %s failed: %s" % (" ".join(args), _text(result.stderr)[:400]))
    return _text(result.stdout)


def _xcode_identity(developer_dir):
    xcodebuild = os.path.join(developer_dir, "usr", "bin", "xcodebuild") if developer_dir else shutil.which("xcodebuild")
    if not xcodebuild:
        return "unknown", "unknown"
    result = _run([xcodebuild, "-version"], 60)
    if result.returncode != 0:
        return "unknown", "unknown"
    text = _text(result.stdout)
    version_match = re.search(r"Xcode\s+([0-9][^\s]*)", text)
    build_match = re.search(r"Build version\s+([0-9A-Za-z]+)", text)
    return (version_match.group(1) if version_match else "unknown",
            build_match.group(1) if build_match else "unknown")


def resolve_toolchain(recipe, slice_cfg, clangxx=None, ranlib=None, nm=None,
                      sdk_path=None, sdk_version=None, xcode_version=None,
                      xcode_build=None, clang_version=None, timeout=120):
    """Resolve the local Apple toolchain and return receipt metadata + paths."""
    developer_dir = os.environ.get("DEVELOPER_DIR")
    clangxx = clangxx or _tool("clang++", developer_dir)
    ranlib = ranlib or _tool("ranlib", developer_dir)
    nm = nm or shutil.which("nm") or _tool("nm", developer_dir)
    sdk = slice_cfg["sdk"]
    if not sdk_path:
        sdk_path = _xcrun(developer_dir, ["--sdk", sdk, "--show-sdk-path"], timeout)
    if not sdk_version:
        sdk_version = _xcrun(developer_dir, ["--sdk", sdk, "--show-sdk-version"], timeout)
    if not xcode_version or not xcode_build:
        detected_version, detected_build = _xcode_identity(developer_dir)
        xcode_version = xcode_version or detected_version
        xcode_build = xcode_build or detected_build
    if not clang_version:
        result = _run([clangxx, "--version"], timeout)
        if result.returncode != 0:
            raise DeriveError("clang++ --version failed: %s" % _text(result.stderr)[:400])
        clang_version = _text(result.stdout)
    if not os.path.isdir(sdk_path):
        raise DeriveError("selected SDK path does not exist: %s" % sdk_path)
    metadata = {
        "xcodeVersion": xcode_version,
        "xcodeBuild": xcode_build,
        "sdkVersion": sdk_version,
        "sdkName": sdk,
        "sdkPath": sdk_path,
        "clangVersion": clang_version,
        "target": slice_cfg["target"],
        "compileFlags": list(recipe["build"]["compileFlags"]),
        "commandTemplate": [
            "<CLANGXX>",
            "-target", slice_cfg["target"],
        ] + list(recipe["build"]["compileFlags"]) + [
            "-isysroot", "<SDK>",
            "-I", "<HEADERS>",
            "-c", "<SOURCE>",
            "-o", "<OBJECT>",
        ],
    }
    paths = {"clangxx": clangxx, "ranlib": ranlib, "nm": nm, "sdkPath": sdk_path}
    return metadata, paths


def _headers_metadata(package_root, recipe):
    identity = dc.headers_identity(package_root, recipe)
    if identity is None:
        return {}
    build = recipe.get("build") or {}
    expected_tree = build.get("headersTreeSha256")
    if expected_tree:
        if (identity["headersTreeSha256"] != expected_tree
                or identity["headersFileCount"] != build.get("headersFileCount")):
            raise DeriveError(
                "pinned OCCT headers tree does not match the recipe "
                "(tree %s/%s, files %s/%s)"
                % (identity["headersTreeSha256"], expected_tree,
                   identity["headersFileCount"], build.get("headersFileCount"))
            )
    return identity


def _version_string(encoded):
    major = encoded >> 16
    minor = (encoded >> 8) & 0xFF
    patch = encoded & 0xFF
    if patch:
        return "%d.%d.%d" % (major, minor, patch)
    return "%d.%d" % (major, minor)


def parse_macho_object(path):
    """Read the Mach-O object header and LC_BUILD_VERSION."""
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < 32:
        raise DeriveError("compiled object is too small to be Mach-O: %d bytes" % len(data))
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise DeriveError("compiled object is not a 64-bit Mach-O file (magic 0x%08x)" % magic)
    cputype, _cpusubtype, filetype, ncmds, sizeofcmds, _flags, _reserved = \
        struct.unpack_from("<IIIIIII", data, 4)
    if filetype != MH_OBJECT:
        raise DeriveError("compiled file is not a Mach-O object (filetype %d)" % filetype)
    if cputype != CPU_TYPE_ARM64:
        raise DeriveError("compiled object is not arm64 (cputype 0x%08x)" % cputype)
    if 32 + sizeofcmds > len(data):
        raise DeriveError("Mach-O load commands extend past the object")
    offset = 32
    build = None
    legacy = None
    for _ in range(ncmds):
        if offset + 8 > 32 + sizeofcmds:
            raise DeriveError("Mach-O load command table is malformed")
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or offset + cmdsize > 32 + sizeofcmds:
            raise DeriveError("Mach-O load command has an invalid size")
        if cmd == LC_BUILD_VERSION:
            if cmdsize < 24:
                raise DeriveError("LC_BUILD_VERSION is truncated")
            platform, minos, sdk, _ntools = struct.unpack_from("<IIII", data, offset + 8)
            build = {"platform": platform, "minos": minos, "sdk": sdk}
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            if cmdsize < 16:
                raise DeriveError("LC_VERSION_MIN_IPHONEOS is truncated")
            version, sdk = struct.unpack_from("<II", data, offset + 8)
            legacy = {"platform": PLATFORM_IOS, "minos": version, "sdk": sdk}
        offset += cmdsize
    chosen = build or legacy
    if not chosen:
        raise DeriveError("compiled object carries no LC_BUILD_VERSION/min-version command")
    return {
        "arch": "arm64",
        "platform": chosen["platform"],
        "platformName": {PLATFORM_IOS: "IOS", PLATFORM_IOSSIMULATOR: "IOSSIMULATOR"}.get(
            chosen["platform"], "PLATFORM_%d" % chosen["platform"]),
        "minos": _version_string(chosen["minos"]),
        "sdk": _version_string(chosen["sdk"]),
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def list_symbols(nm, object_path, timeout=120):
    defined_result = _run([nm, "-gU", object_path], timeout)
    undefined_result = _run([nm, "-u", object_path], timeout)
    if defined_result.returncode != 0:
        raise DeriveError("nm -gU failed: %s" % _text(defined_result.stderr)[:400])
    if undefined_result.returncode != 0:
        raise DeriveError("nm -u failed: %s" % _text(undefined_result.stderr)[:400])

    def last_tokens(text):
        symbols = []
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            symbols.append(stripped.split()[-1])
        return sorted(set(symbols))

    return {
        "defined": last_tokens(_text(defined_result.stdout)),
        "undefined": last_tokens(_text(undefined_result.stdout)),
    }


def _public_filtered(defined, recipe):
    pattern = re.compile(recipe["member"]["publicSymbolPattern"])
    return sorted(symbol for symbol in defined if pattern.match(symbol))


def _public_set_hash(symbols):
    return hashlib.sha256(("\n".join(sorted(symbols)) + "\n").encode()).hexdigest()


def validate_object_symbols(recipe, base_symbols, object_symbols):
    defined = set(object_symbols["defined"])
    undefined = set(object_symbols["undefined"])
    if defined & undefined:
        raise DeriveError("compiled object lists the same symbol as defined and undefined")
    base_public = _public_filtered(base_symbols["defined"], recipe)
    object_public = _public_filtered(object_symbols["defined"], recipe)
    if not base_public:
        raise DeriveError(
            "the pinned base object has no symbols matching the public ABI pattern"
        )
    if base_public != object_public:
        base_set, object_set = set(base_public), set(object_public)
        detail = []
        if base_set - object_set:
            detail.append("missing %s" % ", ".join(sorted(base_set - object_set)[:3]))
        if object_set - base_set:
            detail.append("new %s" % ", ".join(sorted(object_set - base_set)[:3]))
        raise DeriveError(
            "Standard_Type public API set differs from the pinned base object (%s)"
            % "; ".join(detail)
        )
    expected = recipe["member"].get("expectedPublicSymbols")
    if expected is not None and object_public != sorted(expected):
        raise DeriveError(
            "compiled object Standard_Type public API set does not match the recipe's "
            "recorded actual set"
        )
    leaked = sorted(set(object_public) & undefined)
    if leaked:
        raise DeriveError("compiled object leaves public API symbols undefined: %s"
                          % ", ".join(leaked[:4]))
    return base_public, object_public


def compile_object(package_root, recipe, slice_cfg, overlay_path, workdir,
                   tools, timeout):
    """Compile the exact overlay source with the declared Apple toolchain."""
    source_name = recipe["build"]["sourceFileName"]
    object_name = recipe["build"]["objectFileName"]
    source_path = os.path.join(workdir, source_name)
    object_path = os.path.join(workdir, object_name)
    shutil.copyfile(overlay_path, source_path)
    headers_path = dc.resolve_relative(package_root, recipe["build"]["headersPath"],
                                       "recipe.build.headersPath")
    if not os.path.isdir(headers_path):
        raise DeriveError("pinned OCCT headers directory is missing: %s" % headers_path)
    argv = [
        tools["clangxx"],
        "-target", slice_cfg["target"],
    ] + list(recipe["build"]["compileFlags"]) + [
        "-isysroot", tools["sdkPath"],
        "-I", headers_path,
        "-c", source_path,
        "-o", object_path,
    ]
    env = dict(os.environ)
    if "DEVELOPER_DIR" in os.environ:
        env["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
    result = _run(argv, timeout, env=env, cwd=workdir)
    stderr = _text(result.stderr)
    if result.returncode != 0:
        snippet = stderr[-1200:]
        raise DeriveError("compiling %s failed (exit %d):\n%s"
                          % (source_name, result.returncode, snippet))
    if not os.path.isfile(object_path):
        raise DeriveError("compiler reported success but produced no object")
    # The source is compiled from a temporary directory; no absolute host path
    # may leak into the object (there is no debug info in a Release object).
    with open(object_path, "rb") as handle:
        object_bytes = handle.read()
    for forbidden in (workdir.encode("utf-8"), package_root.encode("utf-8")):
        if forbidden and forbidden in object_bytes:
            raise DeriveError("compiled object embeds an absolute build path")
    template = [
        "<CLANGXX>",
        "-target", slice_cfg["target"],
    ] + list(recipe["build"]["compileFlags"]) + [
        "-isysroot", "<SDK>",
        "-I", "<HEADERS>",
        "-c", "<SOURCE>",
        "-o", "<OBJECT>",
    ]
    return object_path, template, stderr


def _write_receipt(path, receipt):
    directory = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(directory):
        raise DeriveError("receipt directory does not exist: %s" % directory)
    handle, temporary = tempfile.mkstemp(prefix=".floecad-receipt-", suffix=".json",
                                         dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(receipt, out, indent=2, sort_keys=True)
            out.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def derive_slice(package_root, recipe_path, slice_name, base_path, output_path,
                 receipt_path, recipe_sha256=None, toolchain=None, tool_paths=None,
                 object_producer=None, symbol_lister=None, index_provider=None,
                 timeout=900, produced_at=None):
    """Derive and verify one slice.  Returns a compact result dictionary."""
    expected_recipe_sha = recipe_sha256 or oa.sha256_file(recipe_path)
    recipe = dc.load_recipe(recipe_path, expected_recipe_sha,
                            _recipe_id_from_file(recipe_path))
    slice_name, slice_cfg = dc.slice_config(recipe, slice_name=slice_name)

    # Source inputs must be the exact reviewed bytes, independent of Git state.
    source_paths = {}
    for key in ("baseSource", "overlaySource", "patch"):
        item = recipe["occt"][key]
        path = dc.resolve_relative(package_root, item["path"], "recipe.occt.%s.path" % key)
        if not os.path.isfile(path):
            raise DeriveError("required %s is missing: %s" % (key, path))
        size = os.path.getsize(path)
        sha = oa.sha256_file(path)
        if size != item["size"] or sha != item["sha256"]:
            raise DeriveError(
                "%s does not match the recipe (size %d/%d, sha256 %s/%s)"
                % (key, size, item["size"], sha, item["sha256"])
            )
        source_paths[key] = path

    # The base archive must be the exact pinned upstream slice.
    base_size = os.path.getsize(base_path)
    base_sha = oa.sha256_file(base_path)
    if base_size != slice_cfg["baseSize"] or base_sha != slice_cfg["baseSha256"]:
        raise DeriveError(
            "base archive does not match the pinned manifest entry "
            "(size %d/%d, sha256 %s/%s)"
            % (base_size, slice_cfg["baseSize"], base_sha, slice_cfg["baseSha256"])
        )
    try:
        base_members = oa.read_archive(base_path)
        base_summary = oa.archive_summary(base_members, recipe["member"]["name"])
        oa.parse_symbol_index(base_members)
    except oa.ArchiveError as exc:
        raise DeriveError("base archive is not the expected BSD ar slice: %s" % exc)
    for field in ("memberCount", "memberOrderSha256",
                  "nonTargetMembersDigestSha256", "indexMemberSize",
                  "indexPayloadSize", "indexPayloadSha256", "targetPayloadSize",
                  "targetPayloadSha256"):
        if base_summary[field] != slice_cfg["base" + field[0].upper() + field[1:]]:
            raise DeriveError("base archive %s does not match the recipe pin" % field)
    base_target = oa.find_member(base_members, recipe["member"]["name"])

    if toolchain is None:
        toolchain, resolved_paths = resolve_toolchain(recipe, slice_cfg, timeout=timeout)
        tool_paths = resolved_paths
    if tool_paths is None:
        tool_paths = {"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"}

    headers_metadata = _headers_metadata(package_root, recipe)
    workdir = tempfile.mkdtemp(prefix=".floecad-derive-", dir=os.path.dirname(os.path.abspath(output_path)))
    try:
        base_object_path = os.path.join(workdir, ".base-Standard_Type.cxx.o")
        with open(base_object_path, "wb") as handle:
            handle.write(base_target.payload)
        lister = symbol_lister or (lambda path: list_symbols(tool_paths["nm"], path, timeout))
        base_symbols = lister(base_object_path)

        if object_producer is None:
            object_path, command_template, compile_stderr = compile_object(
                package_root, recipe, slice_cfg, source_paths["overlaySource"],
                workdir, {"clangxx": tool_paths["clangxx"],
                          "sdkPath": tool_paths["sdkPath"]}, timeout)
        else:
            object_path, command_template, compile_stderr = object_producer(
                package_root, recipe, slice_cfg, source_paths["overlaySource"],
                workdir, toolchain, tool_paths)
        object_info = parse_macho_object(object_path)
        if object_info["arch"] != slice_cfg["arch"]:
            raise DeriveError("compiled object architecture %s does not match %s"
                              % (object_info["arch"], slice_cfg["arch"]))
        if object_info["platformName"] != slice_cfg["machoPlatform"]:
            raise DeriveError("compiled object platform %s does not match %s"
                              % (object_info["platformName"], slice_cfg["machoPlatform"]))
        if object_info["minos"] != slice_cfg["minos"]:
            raise DeriveError("compiled object minimum OS %s does not match %s"
                              % (object_info["minos"], slice_cfg["minos"]))
        recorded_sdk = toolchain.get("sdkVersion")
        if recorded_sdk and object_info["sdk"] != recorded_sdk:
            raise DeriveError(
                "compiled object SDK %s does not match the recorded toolchain SDK %s"
                % (object_info["sdk"], recorded_sdk)
            )
        object_symbols = lister(object_path)
        base_public, object_public = validate_object_symbols(recipe, base_symbols, object_symbols)
        public_hash = hashlib.sha256(("\n".join(object_public) + "\n").encode()).hexdigest()

        with open(object_path, "rb") as handle:
            object_bytes = handle.read()
        try:
            splice_report = oa.splice_member(
                base_members, recipe["member"]["name"], object_bytes, output_path,
                ranlib_path=tool_paths["ranlib"], timeout=timeout,
                index_provider=index_provider,
            )
        except oa.ArchiveError as exc:
            raise DeriveError("archive reconstruction failed: %s" % exc)
        summary = splice_report["summary"]
        # The index legitimately changes with the replacement object; only the
        # base-invariant member identity fields must match the pinned base.
        for field in ("memberCount", "memberOrderSha256",
                      "nonTargetMembersDigestSha256"):
            expected = slice_cfg["base" + field[0].upper() + field[1:]]
            if summary[field] != expected:
                raise DeriveError("reconstructed archive %s does not match the pinned base" % field)
        result_size = os.path.getsize(output_path)
        result_sha = oa.sha256_file(output_path)
        member_result = {
            "size": len(object_bytes),
            "sha256": hashlib.sha256(object_bytes).hexdigest(),
            "definedSymbols": object_symbols["defined"],
            "undefinedSymbols": object_symbols["undefined"],
            "basePublicSymbols": base_public,
            "objectPublicSymbols": object_public,
            "basePublicSymbolSetSha256": _public_set_hash(base_public),
            "publicSymbolSetSha256": public_hash,
        }
        receipt_toolchain = dict(toolchain)
        receipt_toolchain.update(headers_metadata)
        receipt = dc.build_receipt(
            recipe, slice_name, result_size, result_sha, member_result,
            summary, receipt_toolchain,
            {"baseSource": recipe["occt"]["baseSource"]["sha256"],
             "overlaySource": recipe["occt"]["overlaySource"]["sha256"],
             "patch": recipe["occt"]["patch"]["sha256"]},
            produced_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            oa.sha256_file(os.path.abspath(__file__)),
        )
        sanitized_diagnostics = compile_stderr.replace(workdir, "<WORK>").replace(
            package_root, "<PACKAGE>"
        )
        receipt["toolchain"]["compileCommandTemplate"] = command_template
        receipt["member"]["compileDiagnosticsSha256"] = hashlib.sha256(
            sanitized_diagnostics.encode()
        ).hexdigest()
        receipt["member"]["compileDiagnostics"] = sanitized_diagnostics
        _write_receipt(receipt_path, receipt)
        return {
            "slice": slice_name,
            "installPath": slice_cfg["installPath"],
            "output": output_path,
            "receipt": receipt_path,
            "size": result_size,
            "sha256": result_sha,
            "toolchain": receipt["toolchain"],
            "summary": summary,
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _recipe_id_from_file(recipe_path):
    try:
        with open(recipe_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        raise DeriveError("recipe not found: %s" % recipe_path)
    except (OSError, json.JSONDecodeError) as exc:
        raise DeriveError("cannot read recipe %s: %s" % (recipe_path, exc))
    if not isinstance(data, dict) or not isinstance(data.get("id"), str):
        raise DeriveError("recipe is missing its id")
    return data["id"]


def record_existing_slice(package_root, recipe_path, slice_name, base_path,
                          object_path, archive_path, receipt_path,
                          recipe_sha256=None, toolchain=None, tool_paths=None,
                          symbol_lister=None, index_provider=None,
                          produced_at=None, timeout=900, provenance_note=None):
    """Record a receipt for an existing, already-qualified object/archive pair.

    This does not compile or install anything.  It proves that the tracked
    recipe deterministically reproduces the supplied archive from the pinned
    base plus the supplied object, validates the object/ABI facts, and writes
    the same receipt shape as a normal derivation.  It exists so an actual
    qualified artifact produced by the release owner can be bound without a
    redundant rebuild; it is never a way to bless arbitrary bytes.
    """
    expected_recipe_sha = recipe_sha256 or oa.sha256_file(recipe_path)
    recipe = dc.load_recipe(recipe_path, expected_recipe_sha,
                            _recipe_id_from_file(recipe_path))
    slice_name, slice_cfg = dc.slice_config(recipe, slice_name=slice_name)
    if toolchain is None:
        toolchain, resolved = resolve_toolchain(recipe, slice_cfg, timeout=timeout)
        tool_paths = resolved
    if tool_paths is None:
        tool_paths = {"ranlib": "/usr/bin/ranlib", "nm": "/usr/bin/nm"}

    for key in ("baseSource", "overlaySource", "patch"):
        item = recipe["occt"][key]
        path = dc.resolve_relative(package_root, item["path"], "recipe.occt.%s.path" % key)
        if (not os.path.isfile(path) or os.path.getsize(path) != item["size"]
                or oa.sha256_file(path) != item["sha256"]):
            raise DeriveError("%s does not match the tracked recipe" % key)

    base_size = os.path.getsize(base_path)
    base_sha = oa.sha256_file(base_path)
    if base_size != slice_cfg["baseSize"] or base_sha != slice_cfg["baseSha256"]:
        raise DeriveError("base archive does not match the pinned manifest entry")
    try:
        base_members = oa.read_archive(base_path)
        base_summary = oa.archive_summary(base_members, recipe["member"]["name"])
        oa.parse_symbol_index(base_members)
    except oa.ArchiveError as exc:
        raise DeriveError("base archive is not the expected BSD ar slice: %s" % exc)
    for field in ("memberCount", "memberOrderSha256",
                  "nonTargetMembersDigestSha256", "indexMemberSize",
                  "indexPayloadSize", "indexPayloadSha256", "targetPayloadSize",
                  "targetPayloadSha256"):
        expected = slice_cfg["base" + field[0].upper() + field[1:]]
        if base_summary[field] != expected:
            raise DeriveError("base archive %s does not match the recipe pin" % field)
    base_target = oa.find_member(base_members, recipe["member"]["name"])

    if not os.path.isfile(object_path):
        raise DeriveError("object file not found: %s" % object_path)
    with open(object_path, "rb") as handle:
        object_bytes = handle.read()
    object_info = parse_macho_object(object_path)
    if object_info["arch"] != slice_cfg["arch"]:
        raise DeriveError("object architecture does not match the slice")
    if object_info["platformName"] != slice_cfg["machoPlatform"]:
        raise DeriveError("object platform does not match the slice")
    if object_info["minos"] != slice_cfg["minos"]:
        raise DeriveError("object minimum OS does not match the slice")
    recorded_sdk = toolchain.get("sdkVersion")
    if recorded_sdk and object_info["sdk"] != recorded_sdk:
        raise DeriveError("object SDK %s does not match the recorded toolchain SDK %s"
                          % (object_info["sdk"], recorded_sdk))

    lister = symbol_lister or (lambda path: list_symbols(tool_paths["nm"], path, timeout))
    headers_metadata = _headers_metadata(package_root, recipe)
    workdir = tempfile.mkdtemp(prefix=".floecad-record-",
                               dir=os.path.dirname(os.path.abspath(receipt_path)))
    try:
        base_object_path = os.path.join(workdir, ".base-Standard_Type.cxx.o")
        with open(base_object_path, "wb") as handle:
            handle.write(base_target.payload)
        base_symbols = lister(base_object_path)
        object_symbols = lister(object_path)
        base_public, object_public = validate_object_symbols(
            recipe, base_symbols, object_symbols
        )
        member_result = {
            "size": len(object_bytes),
            "sha256": hashlib.sha256(object_bytes).hexdigest(),
            "definedSymbols": object_symbols["defined"],
            "undefinedSymbols": object_symbols["undefined"],
            "basePublicSymbols": base_public,
            "objectPublicSymbols": object_public,
            "basePublicSymbolSetSha256": _public_set_hash(base_public),
            "publicSymbolSetSha256": _public_set_hash(object_public),
        }
        reproduced = os.path.join(workdir, "reproduced.a")
        try:
            oa.splice_member(
                base_members, recipe["member"]["name"], object_bytes, reproduced,
                ranlib_path=tool_paths["ranlib"], timeout=timeout,
                index_provider=index_provider,
            )
        except oa.ArchiveError as exc:
            raise DeriveError("archive reconstruction failed: %s" % exc)
        archive_size = os.path.getsize(archive_path)
        archive_sha = oa.sha256_file(archive_path)
        if (oa.sha256_file(reproduced) != archive_sha
                or os.path.getsize(reproduced) != archive_size):
            raise DeriveError(
                "the tracked recipe does not reproduce the supplied archive; "
                "refusing to record it"
            )
        try:
            existing = oa.read_archive(archive_path)
            oa.verify_against_base(
                base_members, existing, recipe["member"]["name"], object_bytes
            )
            summary = oa.archive_summary(existing, recipe["member"]["name"])
        except oa.ArchiveError as exc:
            raise DeriveError("supplied archive fails member verification: %s" % exc)
        receipt_toolchain = dict(toolchain)
        receipt_toolchain.update(headers_metadata)
        receipt = dc.build_receipt(
            recipe, slice_name, archive_size, archive_sha, member_result,
            summary, receipt_toolchain,
            {"baseSource": recipe["occt"]["baseSource"]["sha256"],
             "overlaySource": recipe["occt"]["overlaySource"]["sha256"],
             "patch": recipe["occt"]["patch"]["sha256"]},
            produced_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            oa.sha256_file(os.path.abspath(__file__)),
        )
        receipt["toolchain"]["compileCommandTemplate"] = toolchain.get(
            "commandTemplate", []
        )
        receipt["member"]["compileDiagnosticsSha256"] = hashlib.sha256(b"").hexdigest()
        receipt["member"]["compileDiagnostics"] = ""
        receipt["provenance"] = {
            "mode": "recorded-existing-artifact",
            "note": provenance_note or (
                "Recorded from an existing qualified object/archive; no compile "
                "or install was performed by the recorder."
            ),
        }
        _write_receipt(receipt_path, receipt)
        return {
            "slice": slice_name,
            "archive": archive_path,
            "receipt": receipt_path,
            "size": archive_size,
            "sha256": archive_sha,
            "toolchain": receipt["toolchain"],
            "summary": summary,
            "publicSymbols": object_public,
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def verify_slice(package_root, recipe_path, slice_name, archive_path, receipt_path,
                 recipe_sha256=None):
    """Read-only receipt/archive verification for an already-derived slice."""
    expected = recipe_sha256 or oa.sha256_file(recipe_path)
    recipe = dc.load_recipe(recipe_path, expected, _recipe_id_from_file(recipe_path))
    slice_name, slice_cfg = dc.slice_config(recipe, slice_name=slice_name)
    try:
        with open(receipt_path, "r", encoding="utf-8") as handle:
            receipt = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise DeriveError("cannot read receipt %s: %s" % (receipt_path, exc))
    size = os.path.getsize(archive_path)
    sha = oa.sha256_file(archive_path)
    artifact = {"installPath": slice_cfg["installPath"],
                "size": slice_cfg["baseSize"], "sha256": slice_cfg["baseSha256"]}
    problems, qualified = dc.validate_receipt(recipe, artifact, receipt, size, sha)
    archive_problems, summary = dc.verify_installed_archive(
        archive_path, recipe, slice_cfg, receipt
    )
    problems.extend(archive_problems)
    result = {
        "slice": slice_name,
        "archive": archive_path,
        "size": size,
        "sha256": sha,
        "qualifiedToolchain": qualified,
        "toolchain": dc.toolchain_summary(receipt),
        "problems": problems,
        "summary": summary,
    }
    return result, problems


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Derive/verify the OCCT Standard_Type single-object backport."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    derive = sub.add_parser("derive")
    derive.add_argument("--package-root", required=True)
    derive.add_argument("--recipe", required=True)
    derive.add_argument("--recipe-sha256", default=None)
    derive.add_argument("--slice", required=True)
    derive.add_argument("--base", required=True)
    derive.add_argument("--output", required=True)
    derive.add_argument("--receipt", required=True)
    derive.add_argument("--timeout", type=int, default=900)
    derive.add_argument("--clangxx", default=None)
    derive.add_argument("--ranlib", default=None)
    derive.add_argument("--nm", default=None)
    derive.add_argument("--sdk-path", default=None)
    derive.add_argument("--sdk-version", default=None)
    derive.add_argument("--xcode-version", default=None)
    derive.add_argument("--xcode-build", default=None)
    derive.add_argument("--clang-version", default=None)

    verify = sub.add_parser("verify")
    verify.add_argument("--package-root", required=True)
    verify.add_argument("--recipe", required=True)
    verify.add_argument("--slice", required=True)
    verify.add_argument("--archive", required=True)
    verify.add_argument("--receipt", required=True)
    verify.add_argument("--recipe-sha256", default=None)

    record = sub.add_parser(
        "record",
        help="bind an existing qualified object/archive to the tracked recipe "
             "without recompiling or installing",
    )
    record.add_argument("--package-root", required=True)
    record.add_argument("--recipe", required=True)
    record.add_argument("--recipe-sha256", default=None)
    record.add_argument("--slice", required=True)
    record.add_argument("--base", required=True)
    record.add_argument("--object", required=True)
    record.add_argument("--archive", required=True)
    record.add_argument("--receipt", required=True)
    record.add_argument("--toolchain-json", required=True)
    record.add_argument("--provenance-note", default=None)
    record.add_argument("--timeout", type=int, default=900)

    inspect = sub.add_parser("inspect")
    inspect.add_argument("archive")
    inspect.add_argument("--target", default="Standard_Type.cxx.o")

    args = parser.parse_args(argv)
    try:
        if args.command == "inspect":
            members = oa.read_archive(args.archive)
            print(json.dumps({
                "summary": oa.archive_summary(members, args.target),
                "symbolIndex": oa.parse_symbol_index(members),
            }, indent=2, sort_keys=True))
            return 0
        if args.command == "verify":
            result, problems = verify_slice(
                args.package_root, args.recipe, args.slice, args.archive,
                args.receipt, args.recipe_sha256,
            )
            print(json.dumps(result, indent=2, sort_keys=True))
            return 0 if not problems else 2
        if args.command == "record":
            try:
                with open(args.toolchain_json, "r", encoding="utf-8") as handle:
                    toolchain = json.load(handle)
            except (OSError, json.JSONDecodeError) as exc:
                raise DeriveError("cannot read --toolchain-json: %s" % exc)
            if not isinstance(toolchain, dict):
                raise DeriveError("--toolchain-json must contain a JSON object")
            result = record_existing_slice(
                args.package_root, args.recipe, args.slice, args.base,
                args.object, args.archive, args.receipt,
                recipe_sha256=args.recipe_sha256, toolchain=toolchain,
                produced_at=None, timeout=args.timeout,
                provenance_note=args.provenance_note,
            )
            print(json.dumps({key: result[key] for key in
                              ("slice", "archive", "receipt", "size", "sha256",
                               "toolchain", "publicSymbols")},
                             indent=2, sort_keys=True))
            return 0
        # derive
        recipe_id = _recipe_id_from_file(args.recipe)
        expected = args.recipe_sha256 or oa.sha256_file(args.recipe)
        recipe = dc.load_recipe(args.recipe, expected, recipe_id)
        slice_name, slice_cfg = dc.slice_config(recipe, slice_name=args.slice)
        toolchain, tool_paths = resolve_toolchain(
            recipe, slice_cfg, clangxx=args.clangxx, ranlib=args.ranlib, nm=args.nm,
            sdk_path=args.sdk_path, sdk_version=args.sdk_version,
            xcode_version=args.xcode_version, xcode_build=args.xcode_build,
            clang_version=args.clang_version, timeout=args.timeout,
        )
        result = derive_slice(
            args.package_root, args.recipe, args.slice, args.base, args.output,
            args.receipt, recipe_sha256=expected, toolchain=toolchain,
            tool_paths=tool_paths, timeout=args.timeout,
        )
        print(json.dumps({key: result[key] for key in
                          ("slice", "installPath", "output", "receipt", "size",
                           "sha256", "toolchain")}, indent=2, sort_keys=True))
        return 0
    except (DeriveError, dc.DerivationError, oa.ArchiveError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
