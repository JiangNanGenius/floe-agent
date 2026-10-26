// FloePersistenceTests — official Skill publication identity ledger.
//
// Locks the transactional version-management boundary:
//   * the curated identity commits in the SAME write transaction as the
//     skill metadata; a same id+version / different contentDigest conflict
//     throws and rolls the whole skill write back (no partially-updated row,
//     no silent "[] because the store failed", no post-success best-effort
//     write that can be lost);
//   * installs predating the ledger are honestly migrated from typed receipt
//     facts via the seed API — and a contradiction inside a seed batch
//     aborts the entire batch rather than writing half of it;
//   * a malformed stored row is surfaced as ledger damage and refuses
//     curated commits, instead of degrading to an unknown/empty ledger that
//     would permit same-version replacement;
//   * non-curated saves never touch the table, and retained identities are
//     unbounded (no silent eviction under the "ever observed" wording).

import Foundation
import Testing
import FloeCore
import GRDB
@testable import FloePersistence

private func makeStore() async throws -> (SQLiteSkillStore, DatabaseManager) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-official-ledger-\(UUID().uuidString).sqlite")
    let manager = try DatabaseManager(path: url)
    try await manager.migrate()
    return (SQLiteSkillStore(database: manager), manager)
}

private func skill(
    id: String = "data-five",
    version: String = "1.0.0",
    digest: String,
    status: String = "enabled"
) -> PersistedSkill {
    PersistedSkill(
        id: id, name: id, version: version, status: status,
        skillMarkdown: "---\nname: \(id)\ndescription: x\n---\nbody\n",
        manifestJSON: "{}",
        sourceURL: "https://github.com/JiangNanGenius/floe-skill-hub",
        rewrittenDigest: digest,
        rewriteModelID: "hub-reviewed-\(digest.prefix(8))",
        compatibilityReportJSON: "{}"
    )
}

private let digestA = String(repeating: "a", count: 64)
private let digestB = String(repeating: "b", count: 64)
private let commitX = String(repeating: "1", count: 40)
private let commitY = String(repeating: "2", count: 40)

private func publication(
    id: String = "data-five",
    version: String = "1.0.0",
    digest: String = digestA,
    commit: String? = commitX
) -> OfficialSkillPublicationRecord {
    OfficialSkillPublicationRecord(
        skillID: id, version: version, contentDigest: digest, publicationCommit: commit
    )
}

@Suite("FloePersistence.OfficialSkillVersionLedger", .serialized)
struct OfficialSkillVersionLedgerTests {
    @Test func curatedIdentityCommitsWithMetadataAndConflictRollsBackEverything() async throws {
        let (store, _) = try await makeStore()
        try await store.save(skill(digest: digestA), grantCapabilities: ["workspace.read"],
                             officialPublication: publication())
        let seen = try await store.officialPublication(id: "data-five", version: "1.0.0")
        #expect(seen?.contentDigest == digestA)
        // A freshly signed replacement package: same id+semver, different
        // digest, AND a metadata change (version field edit) that must not
        // survive the rolled-back transaction.
        do {
            try await store.save(
                skill(digest: digestB),   // would overwrite the row digest
                grantCapabilities: ["workspace.read"],
                officialPublication: publication(digest: digestB, commit: commitY)
            )
            Issue.record("same-version replacement must conflict")
        } catch let conflict as OfficialSkillPublicationConflict {
            #expect(conflict.seenDigest == digestA)
            #expect(conflict.candidateDigest == digestB)
        }
        // Transaction rollback: the skills row still carries the original
        // bytes; the ledger still records the original digest.
        let rows = try await store.all()
        #expect(rows.first(where: { $0.id == "data-five" })?.rewrittenDigest == digestA)
        let after = try await store.officialPublication(id: "data-five", version: "1.0.0")
        #expect(after?.contentDigest == digestA)
        #expect(after?.publicationCommit == commitX)
    }

    @Test func identicalDigestIsIdempotentAndRefreshesCommit() async throws {
        let (store, _) = try await makeStore()
        try await store.save(skill(digest: digestA), officialPublication: publication())
        try await store.save(skill(digest: digestA),
                             officialPublication: publication(commit: commitY))
        let seen = try await store.officialPublication(id: "data-five", version: "1.0.0")
        #expect(seen?.contentDigest == digestA)
        #expect(seen?.publicationCommit == commitY)
        #expect(try await store.countOfficialPublications() == 1)
    }

    @Test func publicationMustBindTheExactSavedSkill() async throws {
        let (store, manager) = try await makeStore()
        do {
            try await store.save(skill(digest: digestA), officialPublication: publication(id: "other-skill"))
            Issue.record("A publication for another skill must not commit")
        } catch is OfficialSkillPublicationCandidateInvalid {}
        #expect(try await store.all().isEmpty)
        #expect(try await store.countOfficialPublications() == 0)
        try await manager.close()
    }

    @Test func publicationVersionsMatchTheStrictOfficialFeedPolicy() {
        for valid in ["0.0.0", "1.2.3", "301.20.0"] {
            #expect(OfficialSkillPublicationLedgerRules.isValidVersion(valid))
        }
        for invalid in ["01.0.0", "1.02.3", "1.2.03", "1.2", "1.2.3-beta", "1.2.3+meta", "1.2." + String(repeating: "9", count: 80)] {
            #expect(!OfficialSkillPublicationLedgerRules.isValidVersion(invalid))
        }
    }

    @Test func nonCuratedSavesNeverTouchTheLedger() async throws {
        let (store, _) = try await makeStore()
        try await store.save(skill(digest: digestB)) // external/user install
        #expect(try await store.countOfficialPublications() == 0)
        #expect(try await store.officialPublication(id: "data-five", version: "1.0.0") == nil)
    }

    @Test func preExistingCuratedInstallsMigrateViaSeed() async throws {
        let (store, _) = try await makeStore()
        // Simulate a Build-301 install: rows exist, no ledger table content.
        try await store.save(skill(digest: digestA))
        try await store.save(skill(id: "citation", version: "2.0.0", digest: digestB))
        #expect(try await store.countOfficialPublications() == 0)
        try await store.seedOfficialPublications([
            publication(),
            OfficialSkillPublicationRecord(
                skillID: "citation", version: "2.0.0", contentDigest: digestB,
                publicationCommit: commitY
            )
        ])
        #expect(try await store.countOfficialPublications() == 2)
        let migrated = try await store.officialPublication(id: "citation", version: "2.0.0")
        #expect(migrated?.contentDigest == digestB)
        // Re-seeding the same facts is idempotent.
        try await store.seedOfficialPublications([publication()])
        #expect(try await store.countOfficialPublications() == 2)
    }

    @Test func seedBatchConflictAbortsTheWholeMigration() async throws {
        let (store, _) = try await makeStore()
        try await store.seedOfficialPublications([publication()])
        // A batch mixing one brand-new identity with one contradicting the
        // retained digest: nothing from the batch may land.
        do {
            try await store.seedOfficialPublications([
                OfficialSkillPublicationRecord(skillID: "fresh-skill", version: "1.0.0",
                                               contentDigest: digestB, publicationCommit: nil),
                OfficialSkillPublicationRecord(skillID: "data-five", version: "1.0.0",
                                               contentDigest: String(repeating: "9", count: 64),
                                               publicationCommit: nil)
            ])
            Issue.record("contradicting seed must throw")
        } catch is OfficialSkillPublicationConflict {
            // expected
        }
        #expect(try await store.officialPublication(id: "fresh-skill", version: "1.0.0") == nil)
        #expect(try await store.officialPublication(id: "data-five", version: "1.0.0")?.contentDigest == digestA)
    }

    @Test func damagedLedgerRefusesCuratedCommutesInsteadOfSilentUnknown() async throws {
        let (store, manager) = try await makeStore()
        try await store.save(skill(digest: digestA), officialPublication: publication())
        // Corrupt the stored digest directly (simulates damage/tampering).
        try await manager.writer { db in
            try db.execute(sql: "UPDATE official_skill_publications SET content_digest = 'short' WHERE skill_id = ? AND version = ?",
                           arguments: ["data-five", "1.0.0"])
        }
        await #expect(throws: OfficialSkillPublicationLedgerDamage.self) {
            _ = try await store.officialPublication(id: "data-five", version: "1.0.0")
        }
        // A curated commit through the damaged row fails closed (it can NOT
        // degrade to "no known identity => allow replacement").
        await #expect(throws: OfficialSkillPublicationLedgerDamage.self) {
            try await store.save(skill(digest: digestB), officialPublication: publication(digest: digestB))
        }
        // And the skill row was not written despite the failure.
        #expect(try await store.all().first(where: { $0.id == "data-five" })?.rewrittenDigest == digestA)
    }

    @Test func nonCanonicalCandidateIsRejectedBeforeWrite() async throws {
        let (store, _) = try await makeStore()
        await #expect(throws: OfficialSkillPublicationCandidateInvalid.self) {
            try await store.save(skill(digest: digestA),
                                 officialPublication: publication(digest: "NOT-A-DIGEST"))
        }
        #expect(try await store.all().isEmpty)
    }

    @Test func retainedIdentitiesAreNotEvicted() async throws {
        let (store, _) = try await makeStore()
        let batch: [OfficialSkillPublicationRecord] = (1...301).map { index in
            OfficialSkillPublicationRecord(
                skillID: "skill-\(index)", version: "1.0.0",
                contentDigest: String(format: "%064x", index), publicationCommit: nil
            )
        }
        try await store.seedOfficialPublications(batch)
        #expect(try await store.countOfficialPublications() == 301)
        let last = try await store.officialPublication(id: "skill-301", version: "1.0.0")
        #expect(last?.contentDigest == String(format: "%064x", 301))
    }
}
