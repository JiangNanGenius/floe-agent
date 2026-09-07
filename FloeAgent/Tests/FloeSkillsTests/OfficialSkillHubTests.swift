import Foundation
import Testing
import Crypto
import ZIPFoundation
@testable import FloeSkills

@Suite("Official signed Skill Hub")
struct OfficialSkillHubTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Real published ZIPs match signed catalog and installable package digests")
    func realPackages() throws {
        let catalog = try Data(contentsOf: repository.appendingPathComponent("skill-hub/catalog.json"))
        let signature = try Data(contentsOf: repository.appendingPathComponent("skill-hub/catalog.sig"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for id in OfficialSkillHub.skillIDs {
            let package = try OfficialSkillHub.verifiedPackage(catalog: catalog, signature: signature,
                id: id, appVersion: "99.0.0", trustedKeys: OfficialSkillHub.trustedKeys)
            let zip = try Data(contentsOf: repository.appendingPathComponent(package.path))
            let snapshot = try OfficialSkillHub.unpack(zip, at: temporary.appendingPathComponent(id))
            #expect(snapshot.package.canonicalSHA256 == package.contentDigest)
            #expect(snapshot.package.manifest.id == id)
            #expect(snapshot.package.manifest.version == package.version)
            #expect(zip.count == package.size)
            #expect(throws: OfficialSkillHub.Failure.signature) {
                try SkillUpgradeCandidate(source: OfficialSkillHub.source(), commit: String(repeating: "a", count: 40), installed: snapshot, proposed: snapshot)
            }
        }
    }

    @Test("Unknown keys, changed catalog, unsupported app and foreign source fail closed")
    func trustBoundaries() throws {
        let catalog = try Data(contentsOf: repository.appendingPathComponent("skill-hub/catalog.json"))
        let signature = try Data(contentsOf: repository.appendingPathComponent("skill-hub/catalog.sig"))
        #expect(throws: OfficialSkillHub.Failure.signature) {
            try OfficialSkillHub.verifiedPackage(catalog: catalog, signature: signature,
                id: "floe-pdf", appVersion: "99.0.0", trustedKeys: [:])
        }
        #expect(throws: OfficialSkillHub.Failure.signature) {
            try OfficialSkillHub.verifiedPackage(catalog: catalog + Data(" ".utf8), signature: signature,
                id: "floe-pdf", appVersion: "99.0.0", trustedKeys: OfficialSkillHub.trustedKeys)
        }
        #expect(throws: OfficialSkillHub.Failure.incompatible) {
            try OfficialSkillHub.verifiedPackage(catalog: catalog, signature: signature,
                id: "floe-pdf", appVersion: "1.0.0", trustedKeys: OfficialSkillHub.trustedKeys)
        }
        #expect(throws: OfficialSkillHub.Failure.source) {
            try OfficialSkillHub.validateSource(GitHubSkillSource(owner: "attacker", repository: "floe-agent", ref: "main", path: OfficialSkillHub.catalogPath))
        }
    }

    @Test("Unsafe and case-colliding ZIP entries never materialize files")
    func unsafeZIPs() throws {
        for names in [["../escape"], ["/absolute"], ["SKILL.md", "skill.md"], ["a/../escape"]] {
            let archive = try Archive(data: Data(), accessMode: .create)
            for name in names {
                let bytes = Data("test".utf8)
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                    bytes.subdata(in: Int(position)..<min(Int(position) + size, bytes.count))
                }
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let bytes = try #require(archive.data)
            #expect(throws: (any Error).self) { try OfficialSkillHub.unpack(bytes, at: root) }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test("Remote guide discovers subgroups without activating all tools")
    func remoteGuide() throws {
        let guide = try #require(BundledDomainSkills.all.first { $0.id == "floe-remote" })
        #expect(!guide.exposed)
        #expect(guide.automaticallyLoadedToolNames.isEmpty)
        #expect(guide.toolNames.contains("vnc.observe"))
        #expect(guide.toolNames.contains("remoteHosting.inspect"))
        #expect(guide.toolNames.contains("cloudWorkspace.catalog"))
        #expect(Set(BundledDomainSkills.all.filter(\.exposed).map(\.id)) == OfficialSkillHub.skillIDs)
    }
}
