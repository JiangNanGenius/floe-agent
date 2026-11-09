"""Offline checks of the independent single-package publication verifier."""
import copy
import unittest

import verify_selected_publication as review


class SelectedPublicationTests(unittest.TestCase):
    def fixture(self):
        before = dict(schemaVersion=1, publisher="JiangNanGenius", generatedAt="before", entries=[
            dict(id=review.COMPATIBILITY_ID, version="1.1.2", sha256="old-provider",
                 path="content-hub/packages/floe.providers.compatibility/1.1.2/floe.providers.compatibility.zip"),
            dict(id="floe.search.providers", version="1.1.0", sha256="old-search",
                 path="content-hub/packages/floe.search.providers/1.1.0/floe.search.providers.zip"),
        ])
        after = copy.deepcopy(before)
        after["generatedAt"] = "after"
        after["entries"][0].update(version="1.1.6", sha256="new-provider",
            path="content-hub/packages/floe.providers.compatibility/1.1.6/floe.providers.compatibility.zip")
        return before, after

    def test_only_selected_entry_and_optional_new_archive_are_allowed(self):
        before, after = self.fixture()
        changes = "M\tcontent-hub/index.json\nM\tcontent-hub/index.sig\n"
        review.verify(before, after, changes, review.COMPATIBILITY_ID)
        review.verify(before, after, changes + "A\t" + after["entries"][0]["path"], review.COMPATIBILITY_ID)

    def test_full_publish_cannot_promote_an_unselected_staged_package(self):
        before, after = self.fixture()
        after["entries"][1]["version"] = "1.2.1"
        with self.assertRaisesRegex(ValueError, "unselected package entry"):
            review.verify(before, after, "M\tcontent-hub/index.json", review.COMPATIBILITY_ID)

    def test_unselected_paths_and_immutable_archive_rewrites_are_rejected(self):
        before, after = self.fixture()
        for change in (
            "A\tcontent-hub/packages/floe.search.providers/1.2.1/floe.search.providers.zip",
            "M\t" + before["entries"][0]["path"],
            "M\t" + after["entries"][0]["path"],
            "D\tcontent-hub/index.sig", "M\tskill-hub/catalog.json",
        ):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "unselected path"):
                review.verify(before, after, change, review.COMPATIBILITY_ID)

    def test_missing_duplicate_or_rewritten_package_identity_is_rejected(self):
        before, after = self.fixture()
        for mutate, reason in (
            (lambda data: data["entries"].pop(), "added or removed"),
            (lambda data: data["entries"].append(data["entries"][0]), "duplicate"),
            (lambda data: data["entries"][0].update(version="1.1.2"), "rewrote"),
            (lambda data: data["entries"][0].update(path="other.zip"), "not canonical"),
        ):
            changed = copy.deepcopy(after)
            mutate(changed)
            with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, reason):
                review.verify(before, changed, "", review.COMPATIBILITY_ID)


if __name__ == "__main__":
    unittest.main()
