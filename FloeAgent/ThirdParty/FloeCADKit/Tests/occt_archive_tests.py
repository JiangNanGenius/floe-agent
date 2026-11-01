#!/usr/bin/env python3
"""Hermetic tests for the BSD ar surgery used by the Standard_Type backport.

Run:
    python3 Tests/occt_archive_tests.py

Optional real-slice bridge (read-only on the slices; writes only to a task
temporary directory, deletes it afterwards):

    FLOE_OCCT_REAL_DEVICE=/path/to/libOCCT-OS64.a \
    FLOE_OCCT_REAL_SIMULATOR=/path/to/libOCCT-SIMULATORARM64.a \
    python3 Tests/occt_archive_tests.py

The real-slice test replaces the target member with another *real* member for
structural verification only.  It is not the compiled Standard_Type backport,
is never linked or run, and proves no runtime result.
"""

import hashlib
import os
import shutil
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PACKAGE, "relink", "derivations"))

import occt_archive as oa  # noqa: E402

TARGET = "Standard_Type.cxx.o"
INDEX = "__.SYMDEF"


def _record(name, payload, mtime=b"0", uid=b"0", gid=b"0", mode=b"100644"):
    name_bytes = name.encode("ascii")
    name_len = len(name_bytes) + 1
    name_field = ("#1/%d" % name_len).ljust(16).encode("ascii")
    area = name_bytes.ljust(name_len, b"\x00")
    data = area + payload
    size = len(data)
    header = (
        name_field
        + mtime.ljust(12)
        + uid.ljust(6)
        + gid.ljust(6)
        + mode.ljust(8)
        + str(size).encode("ascii").ljust(10)
        + b"`\n"
    )
    return header + data + (b"\n" if size % 2 else b"")


def _empty_index_payload():
    return struct.pack("<II", 0, 0)


def make_archive(path, members, index_payload=None):
    """Write a minimal BSD ar: index first, then (name, payload) members."""
    if index_payload is None:
        index_payload = _empty_index_payload()
    with open(path, "wb") as handle:
        handle.write(b"!<arch>\n")
        handle.write(_record(INDEX, index_payload))
        for name, payload in members:
            handle.write(_record(name, payload))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class TestArchiveParsing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="floe-archive-test-")
        self.path = os.path.join(self.tmp, "fixture.a")
        self.members = [
            ("Alpha.cxx.o", b"A" * 100),
            (TARGET, b"BASE" * 50),
            ("Beta.cxx.o", b"B" * 102),  # record data size is odd -> pad byte
        ]
        make_archive(self.path, self.members)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_roundtrip_names_payloads_and_offsets(self):
        members = oa.read_archive(self.path)
        self.assertEqual([m.name for m in members], [INDEX] + [n for n, _ in self.members])
        self.assertEqual([m.payload for m in members[1:]],
                         [p for _, p in self.members])
        self.assertEqual(members[0].offset, 8)
        for member in members:
            self.assertEqual(member.header, _record(member.name, member.payload)[:60])
        self.assertEqual(members[3].pad, b"\n")
        self.assertEqual(members[2].pad, b"")

    def test_summary_pins_target_and_non_target_members(self):
        members = oa.read_archive(self.path)
        summary = oa.archive_summary(members, TARGET)
        self.assertEqual(summary["memberCount"], 4)
        self.assertEqual(summary["targetPayloadSha256"], sha256(b"BASE" * 50))
        self.assertEqual(summary["indexMemberSize"], len(_record(INDEX, _empty_index_payload())) - 60)
        # The digest is order/name/payload based, not header based.
        self.assertEqual(summary["nonTargetMembersDigestSha256"],
                         oa.archive_summary(oa.read_archive(self.path), TARGET)[
                             "nonTargetMembersDigestSha256"])

    def test_missing_or_duplicate_members_are_refused(self):
        duplicate = os.path.join(self.tmp, "duplicate.a")
        make_archive(duplicate, self.members + [(TARGET, b"again")])
        with self.assertRaises(oa.ArchiveError):
            oa.find_member(oa.read_archive(duplicate), TARGET)
        missing = os.path.join(self.tmp, "missing.a")
        make_archive(missing, [("Only.cxx.o", b"x")])
        with self.assertRaises(oa.ArchiveError):
            oa.find_member(oa.read_archive(missing), TARGET)

    def test_bad_magic_and_truncation_are_refused(self):
        bad = os.path.join(self.tmp, "bad.a")
        with open(bad, "wb") as handle:
            handle.write(b"not-an-archive")
        with self.assertRaises(oa.ArchiveError):
            oa.read_archive(bad)
        truncated = os.path.join(self.tmp, "truncated.a")
        data = open(self.path, "rb").read()
        with open(truncated, "wb") as handle:
            handle.write(data[:-7])
        with self.assertRaises(oa.ArchiveError):
            oa.read_archive(truncated)

    def test_symbol_index_zero_entries(self):
        members = oa.read_archive(self.path)
        self.assertEqual(oa.parse_symbol_index(members),
                         {"entryCount": 0, "tableSize": 0, "stringTableSize": 0})

    def test_symbol_index_with_invalid_member_offset_is_refused(self):
        payload = (struct.pack("<I", 8)
                   + struct.pack("<II", 0, 12345)
                   + struct.pack("<I", 4)
                   + b"\x00\x00\x00\x00")
        path = os.path.join(self.tmp, "bad-index.a")
        make_archive(path, self.members, index_payload=payload)
        with self.assertRaises(oa.ArchiveError):
            oa.parse_symbol_index(oa.read_archive(path))

    def test_symbol_index_with_bad_layout_is_refused(self):
        payload = struct.pack("<I", 7) + b"\x00" * 3
        path = os.path.join(self.tmp, "bad-layout.a")
        make_archive(path, self.members, index_payload=payload)
        with self.assertRaises(oa.ArchiveError):
            oa.parse_symbol_index(oa.read_archive(path))


class TestSplice(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="floe-splice-test-")
        self.base = os.path.join(self.tmp, "base.a")
        self.members = [
            ("Alpha.cxx.o", b"A" * 100),
            (TARGET, b"BASE" * 50),
            ("Beta.cxx.o", b"B" * 101),
            ("Gamma.cxx.o", b"G" * 32),
        ]
        make_archive(self.base, self.members)
        self.base_members = oa.read_archive(self.base)
        self.replacement = b"NEW-OBJECT" * 37

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _splice(self, name, replacement=None, index_provider=None):
        output = os.path.join(self.tmp, name)
        report = oa.splice_member(
            self.base_members, TARGET,
            self.replacement if replacement is None else replacement,
            output, index_provider=index_provider or (lambda path: _empty_index_payload()),
        )
        return output, report

    def test_only_target_and_index_change(self):
        output, report = self._splice("derived.a")
        result = oa.read_archive(output)
        base_target = oa.find_member(self.base_members, TARGET)
        result_target = oa.find_member(result, TARGET)
        self.assertEqual(result_target.payload, self.replacement)
        normalized = b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6) + b"644".ljust(8)
        self.assertEqual(result_target.header[16:48], normalized)
        self.assertEqual(result_target.header[0:16], base_target.header[0:16])
        self.assertEqual(result_target.header[48:58].strip(),
                         str(len(result_target.data)).encode())
        normalized = b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6) + b"644".ljust(8)
        for base_member, result_member in zip(self.base_members, result):
            if base_member.name == INDEX:
                continue
            self.assertEqual(result_member.header[16:48], normalized)
            if base_member.name == TARGET:
                continue
            self.assertEqual(base_member.payload, result_member.payload)
        self.assertEqual(report["unchangedNonTargetMemberPayloads"], 3)
        self.assertEqual(
            oa.archive_summary(result, TARGET)["nonTargetMembersDigestSha256"],
            oa.archive_summary(self.base_members, TARGET)["nonTargetMembersDigestSha256"],
        )
        oa.parse_symbol_index(result)

    def test_deterministic_for_same_base_and_object(self):
        first, _ = self._splice("first.a")
        second, _ = self._splice("second.a")
        self.assertEqual(oa.sha256_file(first), oa.sha256_file(second))
        index = oa.find_index(oa.read_archive(first))
        self.assertEqual(index.header[16:28].strip(), b"0")
        self.assertEqual(index.header[28:34].strip(), b"0")
        self.assertEqual(index.header[34:40].strip(), b"0")

    def test_verify_detects_changed_non_target_member(self):
        output, _ = self._splice("tampered.a")
        data = bytearray(open(output, "rb").read())
        # Flip one byte inside Gamma's payload (after its name area and header).
        gamma = oa.find_member(oa.read_archive(output), "Gamma.cxx.o")
        data[gamma.offset + 60 + 12] ^= 0xFF
        with open(output, "wb") as handle:
            handle.write(data)
        with self.assertRaises(oa.ArchiveError):
            oa.verify_against_base(
                self.base_members, oa.read_archive(output), TARGET, self.replacement
            )

    def test_verify_detects_wrong_replacement(self):
        output, _ = self._splice("wrong.a")
        with self.assertRaises(oa.ArchiveError):
            oa.verify_against_base(
                self.base_members, oa.read_archive(output), TARGET, b"other-object"
            )

    def test_empty_replacement_is_refused(self):
        with self.assertRaises(oa.ArchiveError):
            self._splice("empty.a", replacement=b"")


class _RealSliceMixin:
    """Shared real-archive structural check; no compile, link or execution."""

    def _exercise_real_slice(self, path):
        if not path or not os.path.exists(path):
            self.skipTest("real slice path is not present")
        original_hash = oa.sha256_file(path)
        members = oa.read_archive(path)
        target = oa.find_member(members, TARGET)
        donors = [m for m in members if m.name.endswith(".cxx.o") and m.name != TARGET]
        self.assertTrue(donors, "real slice has no donor object member")
        donor = donors[0].payload
        work = tempfile.mkdtemp(prefix="floe-occt-real-")
        try:
            first = os.path.join(work, "first.a")
            second = os.path.join(work, "second.a")
            report = oa.splice_member(members, TARGET, donor, first)
            self.assertEqual(report["unchangedNonTargetMemberPayloads"], len(members) - 2)
            self.assertEqual(
                report["summary"]["nonTargetMembersDigestSha256"],
                oa.archive_summary(members, TARGET)["nonTargetMembersDigestSha256"],
            )
            oa.splice_member(members, TARGET, donor, second)
            self.assertEqual(oa.sha256_file(first), oa.sha256_file(second))
            self.assertEqual(oa.sha256_file(path), original_hash)
            result = oa.read_archive(first)
            self.assertEqual(len(result), len(members))
            self.assertEqual(oa.find_member(result, TARGET).payload, donor)
        finally:
            shutil.rmtree(work, ignore_errors=True)


class TestRealSimulatorSlice(_RealSliceMixin, unittest.TestCase):
    def test_structural_splice(self):
        self._exercise_real_slice(os.environ.get("FLOE_OCCT_REAL_SIMULATOR"))


class TestRealDeviceSlice(_RealSliceMixin, unittest.TestCase):
    def test_structural_splice(self):
        self._exercise_real_slice(os.environ.get("FLOE_OCCT_REAL_DEVICE"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
