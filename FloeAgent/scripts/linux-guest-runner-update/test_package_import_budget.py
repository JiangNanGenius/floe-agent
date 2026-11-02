#!/usr/bin/env python3
"""Producer metadata boundaries against the actual App's archive contract.

No large image is created by these focused checks. Real ZIP CRC/digest and
guest execution are separate qualification steps.
"""
import copy
from pathlib import Path
import unittest

import pipeline_contract


class CatalogArchiveBudgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store_source = (Path(__file__).resolve().parents[2] /
            "Sources/FloeExecution/Linux/LinuxGuestImageStore.swift").read_text()

    def fixture(self, disk_bytes=16 * 1024 ** 3):
        disk = {"name": "disk.img", "bytes": disk_bytes, "sha512": "a" * 128}
        members = [disk, {"name": "manifest.json", "bytes": 8_000, "sha512": "b" * 128},
                   {"name": "floe-exec-riscv64", "bytes": 619_064, "sha512": "c" * 128}]
        manifest = {"qualified": True, "artifacts": [
            {"role": "disk", "path": disk["name"], "bytes": disk_bytes, "sha512": disk["sha512"]}]}
        return manifest, members

    def budget(self, manifest, members, archive_bytes=566_000_000):
        return pipeline_contract.catalog_archive_budget(
            self.store_source, manifest, members, archive_bytes)

    def testCurrentSixteenGiBSparseImageUsesCatalogContract(self):
        result = self.budget(*self.fixture())
        self.assertTrue(result["requiresCatalogIDAndArchiveDigestPin"])
        self.assertTrue(result["exceedsUnknownArchiveBudget"])
        self.assertGreater(result["extractedBytes"], result["standardUnknownArchiveBytes"])
        self.assertLessEqual(result["extractedBytes"], result["extractionBudget"])

    def testSmallImageDoesNotClaimItExceedsUnknownImportBudget(self):
        result = self.budget(*self.fixture(1_000_000))
        self.assertFalse(result["exceedsUnknownArchiveBudget"])
        self.assertTrue(result["requiresCatalogIDAndArchiveDigestPin"])

    def testUnknownOrUnboundManifestNeverGetsTrustedBudget(self):
        for field, value in [("qualified", False), ("artifacts", [])]:
            manifest, members = self.fixture()
            manifest[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.budget(manifest, members)

    def testActualMemberSizeAndDigestMustMatchDeclaration(self):
        for field, value in [("bytes", 12), ("sha512", "d" * 128)]:
            manifest, members = self.fixture()
            manifest["artifacts"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.budget(manifest, members)

    def testTrustedCeilingStillIncludesHeadroom(self):
        current = self.budget(*self.fixture())
        headroom = current["extractionBudget"] - current["declaredArtifactBytes"]
        limit = current["maxDeclaredExtractedBytes"]
        self.assertEqual(self.budget(*self.fixture(limit - headroom))["extractionBudget"], limit)
        with self.assertRaises(ValueError):
            self.budget(*self.fixture(limit - headroom + 1))

    def testUndeclaredPayloadCannotExceedManifestBudget(self):
        manifest, members = self.fixture()
        members.append({"name": "unexpected", "bytes": 128 * 1024 ** 2, "sha512": "d" * 128})
        with self.assertRaises(ValueError):
            self.budget(manifest, members)

    def testCompressedCeilingDuplicateMembersAndOverflowAreRejected(self):
        manifest, members = self.fixture()
        with self.assertRaises(ValueError):
            self.budget(manifest, members, archive_bytes=2 * 1024 ** 3 + 1)
        with self.assertRaises(ValueError):
            self.budget(manifest, members + [copy.deepcopy(members[0])])
        with self.assertRaises(ValueError):
            self.budget(*self.fixture(2 ** 63))

    def testMissingCurrentAppContractFailsClosed(self):
        with self.assertRaises(ValueError):
            pipeline_contract.catalog_archive_budget("// no import contract", *self.fixture(), 100)


if __name__ == "__main__":
    unittest.main()
