import XCTest
import Foundation
import FloeSkills
import FloeAndroidDataExchange

final class AndroidSkillSourceBackupPolicyTests: XCTestCase {
    private func binding() throws -> String {
        let source = try GitHubSkillSource(owner: "octo-org", repository: "community",
                                           ref: "feature/next", path: "pkg/SKILL.md")
        let value = try SkillGitHubBinding(source: source,
                                           installedCommit: String(repeating: "a", count: 40),
                                           installedContentDigest: String(repeating: "b", count: 64))
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    func testOnlyValidatedSourceMetadataCrossesTheExistingSettingsFilter() throws {
        let key = C07SkillSourceSettings.prefix + "fixture"
        let json = try binding()
        let filtered = C07SettingsPolicy.sanitize([
            key: json, "skills.unreviewed": "{}", "github.token": "\"synthetic\"",
            "ui.theme": "\"dark\"",
        ])
        XCTAssertNotNil(filtered[key])
        XCTAssertEqual(filtered["ui.theme"], "\"dark\"")
        XCTAssertNil(filtered["skills.unreviewed"])
        XCTAssertNil(filtered["github.token"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object["token"] = "synthetic-must-not-export"
        let untrusted = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertTrue(C07SettingsPolicy.sanitize([key: untrusted]).isEmpty)
    }

    func testRestoreRemapsOwnerAndDropsInstalledEvidence() throws {
        let oldKey = C07SkillSourceSettings.prefix + "fixture"
        let restoredKey = C07SkillSourceSettings.prefix + "restored-fixture"
        let result = C07SkillSourceSettings.remappedForRestore(
            [oldKey: try binding(), "ui.theme": "\"dark\""]
        ) { $0 == "fixture" ? "restored-fixture" : nil }
        XCTAssertEqual(result.omitted, 0)
        XCTAssertNil(result.values[oldKey])
        XCTAssertEqual(result.values["ui.theme"], "\"dark\"")
        let json = try XCTUnwrap(result.values[restoredKey])
        let value = try JSONDecoder().decode(SkillGitHubBinding.self, from: Data(json.utf8))
        XCTAssertEqual(value.source.repository, "community")
        XCTAssertEqual(value.source.ref, "feature/next")
        XCTAssertNil(value.installedCommit)
        XCTAssertNil(value.installedContentDigest)
    }

    func testMissingOrInvalidTargetMappingIsOmittedInsteadOfUsingOldIdentity() throws {
        let input = [C07SkillSourceSettings.prefix + "fixture": try binding()]
        let missing = C07SkillSourceSettings.remappedForRestore(input) { _ in nil }
        XCTAssertTrue(missing.values.isEmpty)
        XCTAssertEqual(missing.omitted, 1)
        let invalid = C07SkillSourceSettings.remappedForRestore(input) { _ in "../another-skill" }
        XCTAssertTrue(invalid.values.isEmpty)
        XCTAssertEqual(invalid.omitted, 1)
    }

    func testNestedCredentialAndTraversalFieldsCannotBecomeSourceIntent() throws {
        let key = C07SkillSourceSettings.prefix + "fixture"
        for source in [
            "{\"owner\":\"octo-org\",\"repository\":\"repo\",\"ref\":\"main\",\"path\":\"SKILL.md\",\"authorization\":\"synthetic\"}",
            "{\"owner\":\"octo-org\",\"repository\":\"repo\",\"ref\":\"main\",\"path\":\"../SKILL.md\"}",
        ] {
            XCTAssertTrue(C07SettingsPolicy.sanitize([key: "{\"source\":\(source)}"]).isEmpty)
        }
        XCTAssertFalse(C07SettingsPolicy.isAllowedKey(C07SkillSourceSettings.prefix + "../fixture"))
    }

    func testAmbiguousMappingKeepsNeitherSourcesIntent() throws {
        let json = try binding()
        let result = C07SkillSourceSettings.remappedForRestore([
            C07SkillSourceSettings.prefix + "first": json,
            C07SkillSourceSettings.prefix + "second": json,
        ]) { _ in "one-target" }
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertEqual(result.omitted, 2)
    }

    func testActualRestoredIdentityUsesTheNormalSkillIdentifierGrammar() throws {
        let id = C07SkillSourceSettings.freshRestoredSkillID(
            UUID(uuidString: "ABCD1234-ABCD-1234-ABCD-123456789ABC")!)
        XCTAssertEqual(id, "restored-abcd1234-abcd-1234-abcd-123456789abc")
        XCTAssertNoThrow(try SkillIdentifier.validate(id))
        let values = C07SkillSourceSettings.remappedForRestore(
            [C07SkillSourceSettings.prefix + "fixture": try binding()]
        ) { _ in id }
        XCTAssertNotNil(values.values[C07SkillSourceSettings.prefix + id])
        XCTAssertEqual(values.omitted, 0)
    }
}
