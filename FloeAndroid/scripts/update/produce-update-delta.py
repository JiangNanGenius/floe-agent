#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Produce the FloePatch v1 delta between two exact signed Full APKs.

This is the release-side producer for the GitHub (Full) in-app updater. It is
NOT part of the Android build: it reads the exact prior public APK and the
exact new public APK, verifies both identities with the pinned SDK tools,
writes one binary patch and one JSON manifest, and proves the patch by
re-applying it to the base and comparing the reconstructed bytes.

Format: ``FloePatch v1`` (see ``UpdateDeltaApplier.kt`` in the App source).

    magic          11 bytes  b"FLOEPATCH1\\n"
    header length  u32 LE
    header         UTF-8 JSON, bounded, strict keys
    op records (streamed, exactly until END):
        0x01 COPY    u64 LE baseOffset, u32 LE length
        0x02 INSERT  u32 LE length, then <length> raw bytes
        0x00 END     u64 LE total written

The App verifies the installed base APK's SHA-256 and size before applying,
verifies the patch's SHA-256 from the release's ``SHA256SUMS`` before applying,
streams the reconstruction into a private staging file with a bounded buffer,
and re-verifies the final SHA-256, size, package, versionCode, signer, ABI and
minSdk with the same install-admission policy as the full APK. A failed or
unhelpful patch is discarded and the full APK path is offered instead.

Reproducibility: no timestamps, no absolute paths and no environment data are
written into the patch or manifest; the matching parameters are part of the
header and the manifest. Running the producer twice on the same inputs
produces byte-identical outputs.

Usage:
    python3 scripts/update/produce-update-delta.py \\
        --base-apk /path/Floe-Android-0.1.0-alpha.16-full-arm64-v8a.apk \\
        --target-apk /path/Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk \\
        --base-version-name 0.1.0-alpha.16 --base-version-code 18 \\
        --target-version-name 0.1.0-alpha.17 --target-version-code 19 \\
        --release-tag android/v0.1.0-alpha.17 \\
        --sums /path/SHA256SUMS \\
        --out-dir /path/delta-out

Exit status:
    0  patch + manifest written, round-trip verified, patch is beneficial
    1  input/identity/tool failure (nothing written)
    2  usage error
    3  patch generated but not beneficial (> --max-ratio of the target APK);
       only PRODUCER_REPORT.json is written unless --allow-not-beneficial
"""

import argparse
import hashlib
import json
import mmap
import os
import re
import struct
import subprocess
import sys
import tempfile

MAGIC = b"FLOEPATCH1\n"
FORMAT_VERSION = 1
OP_END = 0x00
OP_COPY = 0x01
OP_INSERT = 0x02
MANIFEST_NAME = "update-delta-v1.json"
SCHEMA = "floe.android.update.delta/1"
CHANNEL = "full-arm64-v8a"
MAX_MANIFEST_BYTES = 64 * 1024
MAX_APK_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_WINDOW = 2048
DEFAULT_STRIDE = 512


class ProducerError(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def discover_java_home():
    explicit = os.environ.get("JAVA_HOME")
    if explicit and os.path.isfile(os.path.join(explicit, "bin", "java")):
        return explicit
    here = os.path.abspath(os.path.dirname(__file__))
    for _ in range(8):
        candidate = os.path.join(here, "Local", "Private", "android-toolchains", "jdk")
        if os.path.isdir(candidate):
            for name in sorted(os.listdir(candidate), reverse=True):
                home = os.path.join(candidate, name, "Contents", "Home")
                if os.path.isfile(os.path.join(home, "bin", "java")):
                    return home
        parent = os.path.dirname(here)
        if parent == here:
            break
        here = parent
    return None


def discover_sdk_tool(name):
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if not sdk:
        here = os.path.abspath(os.path.dirname(__file__))
        for _ in range(8):
            candidate = os.path.join(here, "Local", "Private", "android-toolchains", "android-sdk")
            if os.path.isdir(candidate):
                sdk = candidate
                break
            parent = os.path.dirname(here)
            if parent == here:
                break
            here = parent
    if not sdk:
        return None
    build_tools = os.path.join(sdk, "build-tools")
    if not os.path.isdir(build_tools):
        return None

    def version_key(text):
        return [int(part) for part in re.findall(r"\d+", text)] or [0]

    for version in sorted(os.listdir(build_tools), key=version_key, reverse=True):
        candidate = os.path.join(build_tools, version, name)
        if os.path.isfile(candidate):
            return candidate
    return None


def run_tool(command, env=None):
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        check=False,
    )
    if completed.returncode != 0:
        raise ProducerError(
            "tool failed (%d): %s\n%s"
            % (completed.returncode, " ".join(command), completed.stdout.decode("utf-8", "replace"))
        )
    return completed.stdout.decode("utf-8", "replace")


def read_identity(path, aapt2, apksigner, java_home):
    badging = run_tool([aapt2, "dump", "badging", path])
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'", badging, re.M)
    if not package:
        raise ProducerError("aapt2 did not report package/versionCode/versionName for %s" % path)
    native = re.search(r"^native-code: (.+)$", badging, re.M)
    abis = re.findall(r"'([^']+)'", native.group(1)) if native else []
    # aapt2 prints ``minSdkVersion`` (aapt1 printed ``sdkVersion``); accept both
    # so the producer stays correct across SDK tool revisions.
    min_sdk = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.M)
    debuggable = re.search(r"^application-debuggable$", badging, re.M)
    env = dict(os.environ)
    if java_home:
        env["JAVA_HOME"] = java_home
        env["PATH"] = os.path.join(java_home, "bin") + os.pathsep + env.get("PATH", "")
    signer_output = run_tool([apksigner, "verify", "--print-certs", path], env=env)
    signers = sorted(
        {
            match.group(1).lower()
            for match in re.finditer(r"certificate SHA-256 digest: ([0-9a-fA-F]{64})", signer_output)
        }
    )
    if not signers:
        raise ProducerError("apksigner reported no signer certificate for %s" % path)
    return {
        "package": package.group(1),
        "versionCode": int(package.group(2)),
        "versionName": package.group(3),
        "minSdk": int(min_sdk.group(1)) if min_sdk else 0,
        "abis": abis,
        "signerSha256": signers,
        "debuggable": bool(debuggable),
    }


def parse_sums(path):
    entries = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = re.match(r"^([0-9a-fA-F]{64})[ \t]+\*?(.+)$", line)
            if not match:
                continue
            name = match.group(2).strip()
            if not name or "/" in name or "\\" in name:
                continue
            entries[name] = match.group(1).lower()
    return entries


def file_size(path):
    return os.path.getsize(path)


def build_ops(base_path, target_path, window, stride, max_candidates):
    """Yield COPY(offset, length) and INSERT(bytes) ops plus running totals."""
    base_handle = open(base_path, "rb")
    target_handle = open(target_path, "rb")
    base_map = mmap.mmap(base_handle.fileno(), 0, access=mmap.ACCESS_READ)
    target_map = mmap.mmap(target_handle.fileno(), 0, access=mmap.ACCESS_READ)
    base = memoryview(base_map)
    target = memoryview(target_map)
    base_size = len(base)
    target_size = len(target)
    if base_size <= 0 or target_size <= 0:
        raise ProducerError("empty APK input")
    if window <= 0 or stride <= 0 or window < stride:
        raise ProducerError("invalid matcher parameters")

    def digest(view):
        return hashlib.blake2b(view, digest_size=12).digest()

    index = {}
    offset = 0
    while offset + window <= base_size:
        key = digest(base[offset:offset + window])
        bucket = index.get(key)
        if bucket is None:
            index[key] = [offset]
        elif len(bucket) < max_candidates:
            bucket.append(offset)
        offset += stride

    pending = bytearray()
    position = 0
    copy_count = 0
    insert_count = 0
    copy_bytes = 0
    insert_bytes = 0

    def flush_pending():
        nonlocal insert_count, insert_bytes
        if not pending:
            return None
        chunk = bytes(pending)
        pending.clear()
        insert_count += 1
        insert_bytes += len(chunk)
        return chunk

    while position < target_size:
        matched = False
        if position + window <= target_size:
            key = digest(target[position:position + window])
            for candidate in index.get(key, ()):
                if base[candidate:candidate + window] != target[position:position + window]:
                    continue
                maximum = min(base_size - candidate, target_size - position)
                length = window
                while length < maximum:
                    step = min(1 << 20, maximum - length)
                    if base[candidate + length:candidate + length + step] == \
                            target[position + length:position + length + step]:
                        length += step
                        continue
                    step = min(4096, maximum - length)
                    while step > 0 and base[candidate + length:candidate + length + step] != \
                            target[position + length:position + length + step]:
                        step //= 2
                    if step == 0:
                        break
                    length += step
                if length < window:
                    continue
                chunk = flush_pending()
                if chunk is not None:
                    yield ("insert", chunk)
                yield ("copy", candidate, length)
                copy_count += 1
                copy_bytes += length
                position += length
                matched = True
                break
        if matched:
            continue
        step = min(stride, target_size - position)
        pending.extend(target[position:position + step])
        position += step
        if len(pending) >= (4 * 1024 * 1024):
            chunk = flush_pending()
            if chunk is not None:
                yield ("insert", chunk)

    chunk = flush_pending()
    if chunk is not None:
        yield ("insert", chunk)

    base.release()
    target.release()
    base_map.close()
    target_map.close()
    base_handle.close()
    target_handle.close()
    yield ("stats", {
        "copies": copy_count,
        "copyBytes": copy_bytes,
        "inserts": insert_count,
        "insertBytes": insert_bytes,
        "baseSize": base_size,
        "targetSize": target_size,
        "window": window,
        "stride": stride,
        "maxCandidates": max_candidates,
    })


def write_patch(ops, patch_path, base_sha, base_size, target_sha, target_size):
    """Write the patch with a deterministic header; returns final stats."""
    ops_temp = patch_path + ".ops.tmp"
    copy_count = insert_count = copy_bytes = insert_bytes = 0
    with open(ops_temp, "wb") as handle:
        stats = None
        for op in ops:
            if op[0] == "copy":
                _, offset, length = op
                handle.write(struct.pack("<BQI", OP_COPY, offset, length))
                copy_count += 1
                copy_bytes += length
            elif op[0] == "insert":
                chunk = op[1]
                handle.write(struct.pack("<BI", OP_INSERT, len(chunk)))
                handle.write(chunk)
                insert_count += 1
                insert_bytes += len(chunk)
            elif op[0] == "stats":
                stats = op[1]
                break
        if stats is None:
            raise ProducerError("matcher produced no stats")
        handle.write(struct.pack("<BQ", OP_END, copy_bytes + insert_bytes))
        handle.flush()
        os.fsync(handle.fileno())
    if copy_bytes + insert_bytes != target_size:
        raise ProducerError(
            "op totals %d do not equal target size %d" % (copy_bytes + insert_bytes, target_size)
        )
    header = {
        "format": "floepatch",
        "formatVersion": FORMAT_VERSION,
        "base": {"sha256": base_sha, "sizeBytes": base_size},
        "target": {"sha256": target_sha, "sizeBytes": target_size},
        "ops": {
            "copies": copy_count,
            "copyBytes": copy_bytes,
            "inserts": insert_count,
            "insertBytes": insert_bytes,
        },
        "matcher": {"name": "block-blake2b", "window": stats["window"], "stride": stats["stride"]},
        "producer": "produce-update-delta.py/1",
    }
    encoded = json.dumps(header, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_MANIFEST_BYTES:
        raise ProducerError("patch header is unexpectedly large")
    with open(patch_path, "wb") as out:
        out.write(MAGIC)
        out.write(struct.pack("<I", len(encoded)))
        out.write(encoded)
        with open(ops_temp, "rb") as ops_handle:
            while True:
                chunk = ops_handle.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
        out.flush()
        os.fsync(out.fileno())
    os.unlink(ops_temp)
    return {
        "patchSizeBytes": file_size(patch_path),
        "patchSha256": sha256_file(patch_path),
        "ops": header["ops"],
        "matcher": header["matcher"],
    }


def apply_patch(patch_path, base_path, output_path, expected_target_sha, expected_target_size,
                expected_base_sha=None, expected_base_size=None):
    """Reference applier used by the producer's own round-trip proof."""
    with open(patch_path, "rb") as patch:
        if patch.read(len(MAGIC)) != MAGIC:
            raise ProducerError("bad patch magic")
        raw = patch.read(4)
        if len(raw) != 4:
            raise ProducerError("truncated header length")
        header_length = struct.unpack("<I", raw)[0]
        if header_length <= 0 or header_length > MAX_MANIFEST_BYTES:
            raise ProducerError("bad header length")
        header = json.loads(patch.read(header_length).decode("utf-8"))
        if header.get("format") != "floepatch" or header.get("formatVersion") != FORMAT_VERSION:
            raise ProducerError("unsupported patch format")
        base_meta = header["base"]
        target_meta = header["target"]
        if base_meta["sha256"] != expected_base_sha or base_meta["sizeBytes"] != expected_base_size:
            raise ProducerError("patch base does not match the expected base")
        if target_meta["sha256"] != expected_target_sha or target_meta["sizeBytes"] != expected_target_size:
            raise ProducerError("patch target does not match the expected target")
        digest = hashlib.sha256()
        written = 0
        with open(base_path, "rb") as base, open(output_path, "wb") as out:
            while True:
                kind = patch.read(1)
                if not kind:
                    raise ProducerError("patch ended before END record")
                if kind == b"\x00":
                    total = struct.unpack("<Q", patch.read(8))[0]
                    if total != written:
                        raise ProducerError("END total disagrees with written bytes")
                    break
                if kind == b"\x01":
                    offset, length = struct.unpack("<QI", patch.read(12))
                    if offset + length > expected_base_size:
                        raise ProducerError("COPY outside the base file")
                    base.seek(offset)
                    remaining = length
                    while remaining > 0:
                        chunk = base.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ProducerError("short base read")
                        out.write(chunk)
                        digest.update(chunk)
                        written += len(chunk)
                        remaining -= len(chunk)
                elif kind == b"\x02":
                    length = struct.unpack("<I", patch.read(4))[0]
                    remaining = length
                    while remaining > 0:
                        chunk = patch.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ProducerError("truncated INSERT payload")
                        out.write(chunk)
                        digest.update(chunk)
                        written += len(chunk)
                        remaining -= len(chunk)
                else:
                    raise ProducerError("unknown opcode %r" % kind)
                if written > expected_target_size:
                    raise ProducerError("patch produced more than the target size")
        if written != expected_target_size:
            raise ProducerError("patch produced %d bytes, expected %d" % (written, expected_target_size))
        actual = digest.hexdigest()
        if actual != expected_target_sha:
            raise ProducerError("reconstructed SHA-256 mismatch: %s" % actual)
        if file_size(output_path) != expected_target_size:
            raise ProducerError("reconstructed size mismatch")
    return {"targetSha256": expected_target_sha, "targetSizeBytes": expected_target_size}


def patch_asset_name(target_version, base_version):
    safe = re.compile(r"[^0-9A-Za-z._-]+")
    name = "Floe-Android-%s-from-%s.delta" % (
        safe.sub("_", target_version),
        safe.sub("_", base_version),
    )
    if len(name) > 150:
        raise ProducerError("patch asset name would be too long")
    return name


def main(argv):
    parser = argparse.ArgumentParser(description="Produce a FloePatch v1 delta for the GitHub Full APK updater")
    parser.add_argument("--base-apk", required=True)
    parser.add_argument("--target-apk", required=True)
    parser.add_argument("--base-version-name", required=True)
    parser.add_argument("--base-version-code", required=True, type=int)
    parser.add_argument("--target-version-name", required=True)
    parser.add_argument("--target-version-code", required=True, type=int)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--package", default="com.floe.agent.full")
    parser.add_argument("--channel", default=CHANNEL)
    parser.add_argument("--sums", default=None,
                        help="SHA256SUMS that already lists the target APK (required for a release; optional for a local measurement)")
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--aapt2", default=None)
    parser.add_argument("--apksigner", default=None)
    parser.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    parser.add_argument("--stride", type=int, default=DEFAULT_STRIDE)
    parser.add_argument("--max-candidates", type=int, default=4)
    parser.add_argument("--max-ratio", type=float, default=0.80,
                        help="refuse to publish a patch larger than this fraction of the target APK")
    parser.add_argument("--check", action="store_true", help="verify inputs only; write nothing")
    parser.add_argument("--allow-not-beneficial", action="store_true",
                        help="still write patch+manifest when the ratio is above --max-ratio")
    args = parser.parse_args(argv)

    aapt2 = args.aapt2 or discover_sdk_tool("aapt2")
    apksigner = args.apksigner or discover_sdk_tool("apksigner")
    if not aapt2 or not os.path.isfile(aapt2):
        raise ProducerError("aapt2 not found; pass --aapt2 or set ANDROID_SDK_ROOT")
    if not apksigner or not os.path.isfile(apksigner):
        raise ProducerError("apksigner not found; pass --apksigner or set ANDROID_SDK_ROOT")
    java_home = discover_java_home()

    for path in (args.base_apk, args.target_apk):
        if not os.path.isfile(path):
            raise ProducerError("missing input: %s" % path)
        if file_size(path) > MAX_APK_BYTES:
            raise ProducerError("input exceeds the updater's APK size bound: %s" % path)

    base_identity = read_identity(args.base_apk, aapt2, apksigner, java_home)
    target_identity = read_identity(args.target_apk, aapt2, apksigner, java_home)
    if base_identity["package"] != args.package or target_identity["package"] != args.package:
        raise ProducerError("package name mismatch: %s / %s" % (base_identity["package"], target_identity["package"]))
    if base_identity["versionName"] != args.base_version_name or base_identity["versionCode"] != args.base_version_code:
        raise ProducerError("base APK identity does not match --base-version-name/--base-version-code")
    if target_identity["versionName"] != args.target_version_name or target_identity["versionCode"] != args.target_version_code:
        raise ProducerError("target APK identity does not match --target-version-name/--target-version-code")
    if target_identity["versionCode"] <= base_identity["versionCode"]:
        raise ProducerError("target versionCode must be strictly higher than the base")
    if base_identity["signerSha256"] != target_identity["signerSha256"]:
        raise ProducerError("base and target are not signed by the same certificate set")
    if "arm64-v8a" not in target_identity["abis"]:
        raise ProducerError("target APK does not carry arm64-v8a libraries")
    if target_identity["debuggable"]:
        raise ProducerError("target APK is debuggable; refusing to produce a release delta")

    base_sha = sha256_file(args.base_apk)
    target_sha = sha256_file(args.target_apk)
    base_size = file_size(args.base_apk)
    target_size = file_size(args.target_apk)

    sums = {}
    if args.sums:
        sums = parse_sums(args.sums)
        apk_name = os.path.basename(args.target_apk)
        if sums.get(apk_name) != target_sha:
            raise ProducerError("SHA256SUMS does not bind the target APK name/hash")
        base_name = os.path.basename(args.base_apk)
        if base_name in sums and sums[base_name] != base_sha:
            raise ProducerError("SHA256SUMS records a different hash for the base APK")

    summary = {
        "schema": SCHEMA,
        "channel": args.channel,
        "package": args.package,
        "releaseTag": args.release_tag,
        "base": {
            "apkName": os.path.basename(args.base_apk),
            "sha256": base_sha,
            "sizeBytes": base_size,
            "versionName": base_identity["versionName"],
            "versionCode": base_identity["versionCode"],
            "minSdk": base_identity["minSdk"],
            "abis": base_identity["abis"],
        },
        "target": {
            "apkName": os.path.basename(args.target_apk),
            "sha256": target_sha,
            "sizeBytes": target_size,
            "versionName": target_identity["versionName"],
            "versionCode": target_identity["versionCode"],
            "minSdk": target_identity["minSdk"],
            "abis": target_identity["abis"],
            "signerSha256": target_identity["signerSha256"],
        },
    }

    if args.check:
        print(json.dumps({"status": "INPUTS_VERIFIED", "base": summary["base"], "target": summary["target"]},
                         indent=2, sort_keys=True))
        return 0

    os.makedirs(args.out_dir, exist_ok=True)
    patch_name = patch_asset_name(args.target_version_name, args.base_version_name)
    patch_path = os.path.join(args.out_dir, patch_name)

    import time
    started = time.time()
    ops = build_ops(args.base_apk, args.target_apk, args.window, args.stride, args.max_candidates)
    patch_info = write_patch(ops, patch_path, base_sha, base_size, target_sha, target_size)
    elapsed = time.time() - started

    proof_path = os.path.join(args.out_dir, ".roundtrip-proof.apk")
    try:
        proof = apply_patch(
            patch_path, args.base_apk, proof_path,
            expected_target_sha=target_sha,
            expected_target_size=target_size,
            expected_base_sha=base_sha,
            expected_base_size=base_size,
        )
    finally:
        if os.path.exists(proof_path):
            os.unlink(proof_path)

    ratio = patch_info["patchSizeBytes"] / float(target_size)
    beneficial = ratio <= args.max_ratio
    report = {
        "status": "PATCH_VERIFIED" if beneficial else "PATCH_NOT_BENEFICIAL",
        "beneficial": beneficial,
        "maxRatio": args.max_ratio,
        "patch": {
            "assetName": patch_name,
            "sha256": patch_info["patchSha256"],
            "sizeBytes": patch_info["patchSizeBytes"],
            "ratioOfTarget": round(ratio, 6),
        },
        "fullApk": {"sizeBytes": target_size, "sha256": target_sha, "apkName": os.path.basename(args.target_apk)},
        "baseApk": {"sizeBytes": base_size, "sha256": base_sha, "apkName": os.path.basename(args.base_apk)},
        "ops": patch_info["ops"],
        "matcher": patch_info["matcher"],
        "elapsedSeconds": round(elapsed, 3),
        "roundTrip": proof,
        "toolchain": {"aapt2": aapt2, "apksigner": apksigner, "javaHome": java_home},
        "inputs": summary,
    }

    if not beneficial and not args.allow_not_beneficial:
        with open(os.path.join(args.out_dir, "PRODUCER_REPORT.json"), "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.unlink(patch_path)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 3

    manifest = {
        "schema": SCHEMA,
        "channel": args.channel,
        "package": args.package,
        "releaseTag": args.release_tag,
        "base": {key: summary["base"][key] for key in
                 ("apkName", "sha256", "sizeBytes", "versionName", "versionCode")},
        "target": {key: summary["target"][key] for key in
                   ("apkName", "sha256", "sizeBytes", "versionName", "versionCode", "minSdk", "abis", "signerSha256")},
        "patch": {
            "format": "floepatch",
            "version": FORMAT_VERSION,
            "assetName": patch_name,
            "sizeBytes": patch_info["patchSizeBytes"],
            "sha256": patch_info["patchSha256"],
        },
    }
    manifest_text = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    manifest_path = os.path.join(args.out_dir, MANIFEST_NAME)
    with open(manifest_path, "w", encoding="utf-8") as handle:
        handle.write(manifest_text)
    report["manifest"] = {"assetName": MANIFEST_NAME, "sha256": sha256_file(manifest_path),
                          "sizeBytes": file_size(manifest_path)}
    with open(os.path.join(args.out_dir, "SHA256SUMS.entries"), "w", encoding="utf-8") as handle:
        handle.write("%s  %s\n" % (patch_info["patchSha256"], patch_name))
        handle.write("%s  %s\n" % (report["manifest"]["sha256"], MANIFEST_NAME))
    with open(os.path.join(args.out_dir, "PRODUCER_REPORT.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ProducerError as failure:
        sys.stderr.write("produce-update-delta: %s\n" % failure)
        sys.exit(1)
