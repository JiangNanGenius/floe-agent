#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeSkills
import FloePersistence
@testable import FloeApp

@MainActor
@Suite("Official installed Skill version migration", .serialized)
struct OfficialSkillMigrationTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    private func row(id: String = "migration-fixture", digest: String) -> PersistedSkill {
        PersistedSkill(id: id, name: id, version: "1.0.0", skillMarkdown: "# Fixture",
            manifestJSON: "{}", rewrittenDigest: digest,
            compatibilityReportJSON: migrationReceiptJSON(contentDigest: digest, entryID: id, entryVersion: "1.0.0"))
    }

    @Test func automaticDependencyAuthorityRequiresLiveOfficialBytesAndGrants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = SkillManifest(id: "migration-fixture", version: "1.0.0",
            capabilities: [SkillCapability.remoteExecution.rawValue], tools: ["exec.shell"], scriptRuntime: .remote)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("floe.json"))
        try Data("---\nname: migration-fixture\ndescription: Fixture\n---\n# Fixture\n".utf8)
            .write(to: root.appendingPathComponent("SKILL.md"))
        let declaration = #"{"schemaVersion":1,"profiles":[{"id":"linux","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"apt","name":"hello","version":"2.10-5","purpose":"Fixture","required":true}]}]}"#
        try Data(declaration.utf8).write(to: root.appendingPathComponent(SkillDependency.packagePath))
        let validated = try SkillPackageValidator().validate(packageAt: root)
        let snapshot = try SkillContentSnapshot(root: root, expectedDigest: validated.canonicalSHA256)
        let installed = row(digest: validated.canonicalSHA256)
        let grants: Set<String> = [SkillCapability.remoteExecution.rawValue]
        #expect(SkillsCenter.dependencyAuthority(row: installed, snapshot: snapshot, grantedCapabilities: grants) != nil)
        #expect(SkillsCenter.dependencyAuthority(row: installed, snapshot: snapshot, grantedCapabilities: []) == nil)
        var disabled = installed; disabled.status = "disabled"
        #expect(SkillsCenter.dependencyAuthority(row: disabled, snapshot: snapshot, grantedCapabilities: grants) == nil)
        var external = installed; external.compatibilityReportJSON = "{}"
        #expect(SkillsCenter.dependencyAuthority(row: external, snapshot: snapshot, grantedCapabilities: grants) == nil)
        var changed = installed; changed.rewrittenDigest = b
        #expect(SkillsCenter.dependencyAuthority(row: changed, snapshot: snapshot, grantedCapabilities: grants) == nil)
    }

    @Test func separateDatabasesAndPartialLedgersAlwaysReconcileRetainedReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "second"] {
            let database = try DatabaseManager(path: root.appendingPathComponent(name + ".sqlite"))
            try await database.migrate()
            let store = SQLiteSkillStore(database: database)
            let old = row(digest: a)
            try await store.save(old) // Pre-301 installed row; no ledger identity yet.
            try await store.seedOfficialPublications([OfficialSkillPublicationRecord(
                skillID: "unrelated", version: "1.0.0", contentDigest: b, publicationCommit: nil)])
            try await SkillsCenter.seedOfficialPublicationIdentities(rows: try await store.all(), store: store)
            #expect(try await store.officialPublication(id: old.id, version: old.version)?.contentDigest == a)
            // This is the same pre-commit migration used before install, even
            // when no Skills screen has loaded in this process/database.
            do {
                try await store.save(row(digest: b), officialPublication: OfficialSkillPublicationRecord(
                    skillID: old.id, version: old.version, contentDigest: b, publicationCommit: nil))
                Issue.record("Same-version replacement bypassed migrated receipt")
            } catch is OfficialSkillPublicationConflict {}
            #expect(try await store.all().first(where: { $0.id == old.id })?.rewrittenDigest == a)
        }
    }

    @Test func contradictoryRetainedReceiptsFailAtomicallyAndRemainRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseManager(path: root.appendingPathComponent("migration.sqlite"))
        try await database.migrate()
        let store = SQLiteSkillStore(database: database)
        do {
            try await SkillsCenter.seedOfficialPublicationIdentities(rows: [row(digest: a), row(digest: b)], store: store)
            Issue.record("Conflicting current/backup receipt must fail")
        } catch is OfficialSkillPublicationConflict {}
        #expect(try await store.countOfficialPublications() == 0)
        try await SkillsCenter.seedOfficialPublicationIdentities(rows: [row(digest: a)], store: store)
        #expect(try await store.countOfficialPublications() == 1)
    }

    @Test func externalOrMismatchedReceiptDoesNotCreateOfficialIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseManager(path: root.appendingPathComponent("external.sqlite"))
        try await database.migrate()
        let store = SQLiteSkillStore(database: database)
        var external = row(digest: a)
        external.compatibilityReportJSON = "{}"
        var changed = row(digest: a)
        changed.rewrittenDigest = b
        try await SkillsCenter.seedOfficialPublicationIdentities(rows: [external, changed], store: store)
        #expect(try await store.countOfficialPublications() == 0)
    }
}

private func migrationReceiptJSON(contentDigest: String, entryID: String, entryVersion: String) -> String {
    let object: [String: Any] = [
        "receiptSchemaVersion": 1,
        "channel": "ios",
        "feedStatus": "production",
        "hubRepository": CuratedSkillHub.hubRepository,
        "publisher": CuratedSkillHub.publisher,
        "feedSignatureKeyID": CuratedSkillHub.productionKeyID,
        "auditedSourceCommit": String(repeating: "d", count: 40),
        "publicationCommit": String(repeating: "2", count: 40),
        "catalogSHA256": String(repeating: "b", count: 64),
        "catalogByteCount": 100,
        "entryID": entryID,
        "entryVersion": entryVersion,
        "packagePath": "packages/\(entryID).zip",
        "packageSize": 1,
        "packageSHA256": String(repeating: "a", count: 64),
        "contentDigest": contentDigest,
        "containsScripts": false,
        "reviewPath": "reviews/\(entryID).json",
        "reviewSHA256": String(repeating: "c", count: 64),
        "reviewKeyID": CuratedSkillHub.productionKeyID,
        "reviewStage": "static-content-reviewed",
        "reviewDecision": "approve",
        "reviewedAt": "2026-10-26T00:00:00Z",
        "reviewer": "fixture",
        "permissionDelta": [
            "requiredCapabilities": [], "requiredTools": [], "requiredPythonPackageSpecs": [],
            "missingCapabilities": [], "missingTools": [], "missingPythonPackageSpecs": []
        ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: ["curatedHubReceipt": object], options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
#endif
