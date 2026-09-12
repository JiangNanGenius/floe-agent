import Foundation
import Testing
import FloeSkills

@Suite("Signed model catalog and bundled Skills")
struct SignedCatalogTests {
    @Test func schemaTwoCatalogVerifiesEveryPublishedPackage() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let catalog = try Data(contentsOf: root.appendingPathComponent("skill-hub/catalog.json"))
        let signature = try Data(contentsOf: root.appendingPathComponent("skill-hub/catalog.sig"))
        for id in OfficialSkillHub.skillIDs {
            let package = try OfficialSkillHub.verifiedPackage(catalog: catalog, signature: signature,
                id: id, appVersion: "99.0.0", trustedKeys: OfficialSkillHub.trustedKeys)
            let bytes = try Data(contentsOf: root.appendingPathComponent(package.path))
            #expect(bytes.count == package.size)
        }
        #expect(throws: (any Error).self) {
            try OfficialSkillHub.verifiedPackage(catalog: catalog + Data(" ".utf8), signature: signature,
                id: "floe-video", appVersion: "99.0.0", trustedKeys: OfficialSkillHub.trustedKeys)
        }
    }
}
