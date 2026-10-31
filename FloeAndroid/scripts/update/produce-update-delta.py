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
import zipfile
import zlib

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
# ZIP-aware matcher: raw-byte matching must be independent of the
# absolute file offset.  The v1 producer indexed the base only at multiples of
# 512 and advanced the target in 512-byte steps, so a single 4-byte shift in
# the ZIP layout (or any other pack/alignment change) hid almost every
# identical span.  Anchors below are chosen from content alone: a fixed byte
# class plus a CRC32 low-bit filter on the following ANCHOR_WINDOW bytes.
ANCHOR_CLASS = bytes(range(0x40, 0x50))
ANCHOR_PATTERN = re.compile(b"[" + re.escape(ANCHOR_CLASS) + b"]")
ANCHOR_WINDOW = 16
ANCHOR_FILTER = 0x03          # keep 1/4 of the byte-class candidates
MIN_MATCH = 32                # reject accidental short matches
MAX_ANCHOR_CANDIDATES = 8
MAX_ANCHORS_PER_ENTRY = 4_000_000
MIN_ENTRY_MATCH = 65536


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


def _anchor_positions(data):
    """Content-defined anchor positions (independent of absolute file offset).

    A position is an anchor when its byte is in ANCHOR_CLASS and the CRC32 of
    the next ANCHOR_WINDOW bytes passes the low-bit filter.  Identical content
    therefore yields the same anchors in base and target even when every ZIP
    entry has moved to a different absolute offset.
    """
    positions = []
    if len(data) < ANCHOR_WINDOW:
        return positions
    view = memoryview(data)
    for match in ANCHOR_PATTERN.finditer(data):
        offset = match.start()
        if offset + ANCHOR_WINDOW > len(data):
            break
        if zlib.crc32(view[offset:offset + ANCHOR_WINDOW]) & ANCHOR_FILTER == 0:
            positions.append(offset)
            if len(positions) > MAX_ANCHORS_PER_ENTRY:
                # Pathological repetition: fall back to literal inserts for
                # this entry instead of growing an unbounded dictionary.
                return []
    return positions


def _extend_match(base, target, base_offset, target_offset):
    """Grow an equal run from a verified ANCHOR_WINDOW prefix."""
    limit = min(len(base) - base_offset, len(target) - target_offset)
    length = ANCHOR_WINDOW
    while length < limit:
        step = min(max(length, 64 << 10), limit - length)
        if base[base_offset + length:base_offset + length + step] == \
                target[target_offset + length:target_offset + length + step]:
            length += step
            continue
        while step > 1:
            step //= 2
            if base[base_offset + length:base_offset + length + step] == \
                    target[target_offset + length:target_offset + length + step]:
                length += step
                break
        break
    return length


def _match_bytes(base, target):
    """Return deterministic, non-overlapping (target, base, length) runs."""
    if not target:
        return []
    if base == target:
        return [(0, 0, len(target))]
    index = {}
    for offset in _anchor_positions(base):
        key = zlib.crc32(base[offset:offset + ANCHOR_WINDOW])
        bucket = index.get(key)
        if bucket is None:
            index[key] = [offset]
        elif len(bucket) < MAX_ANCHOR_CANDIDATES:
            bucket.append(offset)
    matches = []
    covered = 0
    for target_offset in _anchor_positions(target):
        if target_offset < covered:
            continue
        key = zlib.crc32(target[target_offset:target_offset + ANCHOR_WINDOW])
        best = None
        for base_offset in index.get(key, ()):
            if base[base_offset:base_offset + ANCHOR_WINDOW] != \
                    target[target_offset:target_offset + ANCHOR_WINDOW]:
                continue
            length = _extend_match(base, target, base_offset, target_offset)
            if length >= MIN_MATCH and (best is None or length > best[2]):
                best = (target_offset, base_offset, length)
        if best is not None:
            matches.append(best)
            covered = best[0] + best[2]
    return matches


def _primitive_ops_for_bytes(base, target, target_abs_offset):
    """COPY base runs, INSERT everything else, for one raw byte span."""
    ops = []
    cursor = 0
    for target_offset, base_offset, length in _match_bytes(base, target):
        if target_offset > cursor:
            ops.append(("insert", target_abs_offset + cursor, target_offset - cursor))
        ops.append(("copy", base_offset, length))
        cursor = target_offset + length
    if cursor < len(target):
        ops.append(("insert", target_abs_offset + cursor, len(target) - cursor))
    return ops


def _merge_primitive_ops(ops):
    """Coalesce adjacent INSERT ranges and contiguous COPY ranges."""
    merged = []
    for kind, offset, length in ops:
        if length <= 0:
            continue
        if merged:
            prev_kind, prev_offset, prev_length = merged[-1]
            if kind == "insert" and prev_kind == "insert" and \
                    prev_offset + prev_length == offset:
                merged[-1] = ("insert", prev_offset, prev_length + length)
                continue
            if kind == "copy" and prev_kind == "copy" and \
                    prev_offset + prev_length == offset:
                # COPY offsets are base-file offsets, not target offsets.
                # Contiguity is still a valid merge because both the base and
                # target cursors advance by the same lengths.
                merged[-1] = ("copy", prev_offset, prev_length + length)
                continue
        merged.append((kind, offset, length))
    return merged


def _emit_ops(plan, target_map, target_size, base_size, matcher_stats):
    copy_count = insert_count = copy_bytes = insert_bytes = 0
    for kind, offset, length in plan:
        if kind == "copy":
            if offset + length > base_size:
                raise ProducerError("internal COPY outside the base file")
            yield ("copy", offset, length)
            copy_count += 1
            copy_bytes += length
        else:
            if offset + length > target_size:
                raise ProducerError("internal INSERT outside the target file")
            yield ("insert", target_map[offset:offset + length])
            insert_count += 1
            insert_bytes += length
    if copy_bytes + insert_bytes != target_size:
        raise ProducerError("plan totals %d do not equal target size %d" %
                            (copy_bytes + insert_bytes, target_size))
    matcher_stats.update({
        "copies": copy_count,
        "copyBytes": copy_bytes,
        "inserts": insert_count,
        "insertBytes": insert_bytes,
    })
    yield ("stats", {
        "copies": copy_count,
        "copyBytes": copy_bytes,
        "inserts": insert_count,
        "insertBytes": insert_bytes,
        "baseSize": base_size,
        "targetSize": target_size,
        "window": ANCHOR_WINDOW,
        "filter": ANCHOR_FILTER,
        "minMatch": MIN_MATCH,
        "matcherName": matcher_stats["matcherName"],
        "matcherStats": matcher_stats,
    })


def build_ops(base_path, target_path, window, stride, max_candidates):
    """Generic non-ZIP fallback used by the producer's unit fixtures.

    The legacy stride grid is intentionally ignored: content-defined anchors
    make the match phase-independent.  The release producer uses
    ``build_zip_ops`` below, which is ZIP-entry aware.
    """
    base_handle = open(base_path, "rb")
    target_handle = open(target_path, "rb")
    base_map = mmap.mmap(base_handle.fileno(), 0, access=mmap.ACCESS_READ)
    target_map = mmap.mmap(target_handle.fileno(), 0, access=mmap.ACCESS_READ)
    try:
        base = base_map[:]
        target = target_map[:]
        base_size = len(base)
        target_size = len(target)
        if base_size <= 0 or target_size <= 0:
            raise ProducerError("empty input")
        plan = _primitive_ops_for_bytes(base, target, 0)
        plan = _merge_primitive_ops(plan)
        stats = {
            "matcherName": "anchor-crc32",
            "baseSize": base_size,
            "matched": bool(_match_bytes(base, target)),
        }
        for item in _emit_ops(plan, target_map, target_size, base_size, stats):
            yield item
    finally:
        base_map.close()
        target_map.close()
        base_handle.close()
        target_handle.close()


def _scan_zip(path):
    """Return (entries, segments, size) for one APK/ZIP.

    Each segment is ("data", entry) or ("gap", absolute_offset, length) and
    the segments cover the whole file exactly once, in file order.
    """
    try:
        with zipfile.ZipFile(path, "r") as archive:
            infos = archive.infolist()
    except zipfile.BadZipFile as failure:
        raise ProducerError("not a readable ZIP/APK: %s" % failure)
    size = file_size(path)
    entries = []
    with open(path, "rb") as handle:
        for info in infos:
            handle.seek(info.header_offset)
            head = handle.read(30)
            if len(head) != 30 or head[:4] != b"PK\x03\x04":
                raise ProducerError("bad local header for %s" % info.filename)
            name_len, extra_len = struct.unpack("<HH", head[26:30])
            data_offset = info.header_offset + 30 + name_len + extra_len
            if data_offset < info.header_offset or data_offset + info.compress_size > size:
                raise ProducerError("entry outside the file: %s" % info.filename)
            entries.append({
                "name": info.filename,
                "method": info.compress_type,
                "flags": info.flag_bits,
                "headerOffset": info.header_offset,
                "dataOffset": data_offset,
                "size": info.compress_size,
                "uncompressedSize": info.file_size,
            })
    entries.sort(key=lambda entry: entry["headerOffset"])
    segments = []
    cursor = 0
    for entry in entries:
        if entry["headerOffset"] < cursor:
            raise ProducerError("overlapping ZIP entries at %s" % entry["name"])
        if entry["headerOffset"] > cursor:
            segments.append(("gap", cursor, entry["headerOffset"] - cursor))
        header_length = entry["dataOffset"] - entry["headerOffset"]
        if header_length < 30:
            raise ProducerError("invalid local header length for %s" % entry["name"])
        segments.append(("gap", entry["headerOffset"], header_length))
        if entry["size"] > 0:
            segments.append(("data", entry))
        cursor = entry["dataOffset"] + entry["size"]
    if cursor > size:
        raise ProducerError("ZIP entries extend past the file")
    if cursor < size:
        segments.append(("gap", cursor, size - cursor))
    covered = 0
    for segment in segments:
        covered += segment[2] if segment[0] == "gap" else segment[1]["size"]
    if covered != size:
        raise ProducerError("ZIP layout does not cover the file")
    return entries, segments, size


def _entry_hashes(path, entries):
    with open(path, "rb") as handle:
        mapped = mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            view = memoryview(mapped)
            for entry in entries:
                if entry["size"]:
                    entry["sha256"] = hashlib.sha256(
                        view[entry["dataOffset"]:entry["dataOffset"] + entry["size"]]
                    ).hexdigest()
                else:
                    entry["sha256"] = hashlib.sha256(b"").hexdigest()
        finally:
            view.release()
            mapped.close()


def build_zip_ops(base_path, target_path):
    """ZIP-entry-aware phase-independent matcher for two APKs."""
    base_entries, base_segments, base_size = _scan_zip(base_path)
    target_entries, target_segments, target_size = _scan_zip(target_path)
    if base_size <= 0 or target_size <= 0:
        raise ProducerError("empty APK input")
    _entry_hashes(base_path, base_entries)
    _entry_hashes(target_path, target_entries)

    base_by_name = {}
    for entry in base_entries:
        base_by_name.setdefault(entry["name"], entry)
    base_by_sha = {}
    for entry in base_entries:
        if entry["size"]:
            base_by_sha.setdefault(entry["sha256"], []).append(entry)

    stats = {
        "matcherName": "zip-anchor-crc32",
        "baseSize": base_size,
        "targetSize": target_size,
        "baseEntries": len(base_entries),
        "targetEntries": len(target_entries),
        "identicalEntries": 0,
        "identicalBytes": 0,
        "anchorEntries": 0,
        "anchorTargetBytes": 0,
        "anchorCopyBytes": 0,
        "gapBytes": 0,
        "uncopiedDataBytes": 0,
    }
    plan = []
    data_copied = 0
    data_inserted = 0
    with open(base_path, "rb") as base_handle, open(target_path, "rb") as target_handle:
        base_map = mmap.mmap(base_handle.fileno(), 0, access=mmap.ACCESS_READ)
        target_map = mmap.mmap(target_handle.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            for segment in target_segments:
                if segment[0] == "gap":
                    _, offset, length = segment
                    plan.append(("insert", offset, length))
                    stats["gapBytes"] += length
                    continue
                entry = segment[1]
                same_name = base_by_name.get(entry["name"])
                candidates = base_by_sha.get(entry["sha256"]) if entry["size"] else None
                chosen = None
                if candidates:
                    chosen = next((c for c in candidates if c["name"] == entry["name"]), candidates[0])
                if chosen is not None and chosen["size"] == entry["size"]:
                    plan.append(("copy", chosen["dataOffset"], entry["size"]))
                    stats["identicalEntries"] += 1
                    stats["identicalBytes"] += entry["size"]
                    data_copied += entry["size"]
                    continue
                if same_name is not None and same_name["method"] == entry["method"] and \
                        entry["size"] >= MIN_ENTRY_MATCH:
                    base_data = base_map[same_name["dataOffset"]:same_name["dataOffset"] + same_name["size"]]
                    target_data = target_map[entry["dataOffset"]:entry["dataOffset"] + entry["size"]]
                    matches = _match_bytes(base_data, target_data)
                    stats["anchorEntries"] += 1
                    stats["anchorTargetBytes"] += entry["size"]
                    cursor = 0
                    for target_offset, base_offset, length in matches:
                        if target_offset > cursor:
                            plan.append(("insert", entry["dataOffset"] + cursor,
                                         target_offset - cursor))
                            data_inserted += target_offset - cursor
                        plan.append(("copy", same_name["dataOffset"] + base_offset, length))
                        data_copied += length
                        stats["anchorCopyBytes"] += length
                        cursor = target_offset + length
                    if cursor < entry["size"]:
                        plan.append(("insert", entry["dataOffset"] + cursor, entry["size"] - cursor))
                        data_inserted += entry["size"] - cursor
                    continue
                plan.append(("insert", entry["dataOffset"], entry["size"]))
                data_inserted += entry["size"]
                stats["uncopiedDataBytes"] += entry["size"]
            plan = _merge_primitive_ops(plan)
            stats["copiedDataBytes"] = data_copied
            stats["insertedDataBytes"] = data_inserted
            for item in _emit_ops(plan, target_map, target_size, base_size, stats):
                yield item
        finally:
            base_map.close()
            target_map.close()


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
        "matcher": {"name": stats["matcherName"], "window": stats["window"],
                    "filter": stats["filter"], "minMatch": stats["minMatch"]},
        "producer": "produce-update-delta.py/2",
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
        "matcherStats": stats.get("matcherStats"),
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
    ops = build_zip_ops(args.base_apk, args.target_apk)
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
        "matcherStats": patch_info["matcherStats"],
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
