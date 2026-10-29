import Foundation
import Testing
@testable import FloeSkills

@Suite("Mac original Skill identities")
struct MacOriginalSkillTests {
    @Test("A Mac receipt never invents Linux archive or review evidence")
    func originalReceipt() throws {
        let request = try SkillHubInstallRequest(id: "original-guide", publicationCommit: String(repeating: "a", count: 40))
        let receipt = MacOriginalSkillInstallReceipt(skillID: "original-guide", version: "1.0.0",
            contentDigest: String(repeating: "b", count: 64), catalogDigest: String(repeating: "c", count: 64),
            publicationCommit: String(repeating: "a", count: 40), sourceCommit: String(repeating: "d", count: 40),
            sourceRepository: "owner/repository", fileCount: 3, totalBytes: 1024,
            installedPath: "/Users/example/Library/Application Support/Floe Bridge/Skills/original-guide/1.0.0-123")
        try receipt.verify(against: request)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        #expect(object["target"] as? String == "macos-original")
        #expect(object["packageSHA256"] == nil)
        #expect(object["reviewDigest"] == nil)
        #expect(throws: (any Error).self) { try receipt.verify(against: SkillHubInstallRequest(id: "other-guide")) }
    }
    @Test("Unsafe or unauthenticated feeds cannot become empty successful catalogs")
    func unsignedFeedRefused() {
        #expect(throws: (any Error).self) {
            try MacOriginalSkillCatalog.verified(bytes: Data("{\"schemaVersion\":1,\"channel\":\"macos-original\",\"entries\":[]}".utf8), signature: Data())
        }
    }
}
