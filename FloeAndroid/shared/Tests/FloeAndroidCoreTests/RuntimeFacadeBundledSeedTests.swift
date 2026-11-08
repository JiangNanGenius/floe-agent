// SPDX-License-Identifier: MPL-2.0
//
// N07-platform-guides67 (job-21d5d72113e9417f): skills-domain seeding
// regression source — the app-bundled Android guides must reach the
// model-facing path (skill.list/skill.search/skill.read) with truthful
// content, and user intent (edits, disable, removal, other sources) must
// survive seeding. Authored, NOT executed by this package; the primary
// owner runs the suite during grouped qualification. Fixture pattern and
// boundaries mirror RuntimeFacadeSkillsTests (RB6TestFixture).
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeSkills
import FloeTools
import FloePersistence
import GRDB

final class RuntimeFacadeBundledSeedTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private func makeDomain(_ id: String) async throws -> (RB6TestFixture, SkillsDomain) {
        let fixture = try await RB6TestFixture.make(id: id)
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: SkillsRemoteTransportUnavailable(),
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: ToolRunnerRegistry()))
        return (fixture, domain)
    }

    // MARK: fresh seed surfaces the guides

    func testFreshSeedInstallsEveryGuideEnabled() async throws {
        let (fixture, domain) = try await makeDomain("bundled-fresh")
        let outcomes = await domain.seedBundledDomainGuides()
        XCTAssertEqual(Set(outcomes.keys),
                       Set(AndroidBundledSkillGuides.all.map(\.id)))
        for (id, outcome) in outcomes {
            XCTAssertEqual(outcome, "installed", "\(id) must install on a fresh root")
        }
        let rows = try await domain.readManaged(id: nil)
        XCTAssertEqual(rows.count, AndroidBundledSkillGuides.all.count)
        XCTAssertTrue(rows.allSatisfy { $0.enabled })
        XCTAssertTrue(rows.allSatisfy { $0.digest == $0.currentDigest && !$0.digest.isEmpty })
        // Truthful, distinct app-bundled identity — never a fabricated hub
        // receipt or a signed-source binding.
        let store = SQLiteSkillStore(database: fixture.database)
        for id in AndroidBundledSkillGuides.all.map(\.id) {
            let persisted = await store.skill(id: id)
            let row = try XCTUnwrap(persisted)
            XCTAssertEqual(row.sourceURL, AndroidBundledSkillGuides.sourceURL(for: id))
            XCTAssertEqual(row.rewrittenDigest, row.sourceDigest,
                           "an unmodified bundled guide matches its source bytes")
            XCTAssertEqual(row.rewriteModelID, "bundled-seed")
            XCTAssertNil(row.sourceTrackingJSON)
        }
    }

    func testSeededPdfReadIsAndroidTrueAndRegistryBound() async throws {
        let (_, domain) = try await makeDomain("bundled-pdf-read")
        _ = await domain.seedBundledDomainGuides()
        let rows = try await domain.readManaged(id: "floe-pdf")
        let row = try XCTUnwrap(rows.first)
        let markdown = try XCTUnwrap(row.markdown)
        XCTAssertTrue(markdown.contains("exec.shell"),
                      "PDF guide names the real task-Linux path")
        XCTAssertTrue(markdown.contains("pypdf"))
        XCTAssertFalse(markdown.contains("document.pdf."),
                       "no iOS-native editor alias may reach the model")
        XCTAssertFalse(markdown.lowercased().contains("desktop is required"))
        let required = try XCTUnwrap(row.requiredToolNames)
        XCTAssertTrue(required.contains("exec.shell"))
        XCTAssertFalse(required.contains { $0.hasPrefix("document.pdf.") },
                       "requiredToolNames must stay registry-true")
    }

    func testSkillSearchDiscoversSeededGuides() async throws {
        let (_, domain) = try await makeDomain("bundled-search")
        _ = await domain.seedBundledDomainGuides()
        let search = SkillSearchTool(manager: SkillsDomainManagingFacade(domain: domain))
        let output = try await search.execute(
            DiscoveryQueries(query: "pdf"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        XCTAssertTrue(output.summary.contains("floe-pdf"),
                      "the bundled PDF guide is discoverable by alias")
    }

    // MARK: idempotence + user intent

    func testSecondSeedPassLeavesEverythingUnchanged() async throws {
        let (_, domain) = try await makeDomain("bundled-idem")
        let first = await domain.seedBundledDomainGuides()
        XCTAssertTrue(first.values.allSatisfy { $0 == "installed" })
        let rowsBefore = try await domain.readManaged(id: nil)
        let digestsBefore = Dictionary(uniqueKeysWithValues: rowsBefore.map { ($0.id, $0.digest) })
        let second = await domain.seedBundledDomainGuides()
        XCTAssertTrue(second.values.allSatisfy { $0 == "unchanged" },
                      "a content-identical pass must be a no-op")
        let rowsAfter = try await domain.readManaged(id: nil)
        XCTAssertEqual(rowsAfter.count, rowsBefore.count)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rowsAfter.map { ($0.id, $0.digest) }),
                       digestsBefore)
    }

    func testUserEditedBundledGuideIsRespected() async throws {
        let (fixture, domain) = try await makeDomain("bundled-edited")
        _ = await domain.seedBundledDomainGuides()
        let seeded = try await domain.readManaged(id: "floe-pdf")
        let row = try XCTUnwrap(seeded.first)
        // A local instruction revision (rewritten digest != source digest).
        let edited = "# User revision\nKeep my copy.\n"
        let editedDigest = SHA256.hash(data: Data(edited.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let store = SQLiteSkillStore(database: fixture.database)
        try await store.updateInstructions(id: "floe-pdf", markdown: edited,
                                           digest: editedDigest,
                                           expectedDigest: row.digest)
        let outcome = await domain.seedBundledDomainGuides()
        XCTAssertEqual(outcome["floe-pdf"], "userModified")
        let after = try await domain.readManaged(id: "floe-pdf")
        XCTAssertEqual(after.first?.digest, editedDigest,
                       "the user's edited copy is never overwritten")
        XCTAssertEqual(after.first?.markdown, edited)
    }

    func testUserDisabledGuideStaysDisabledAcrossSeeding() async throws {
        let (_, domain) = try await makeDomain("bundled-disabled")
        _ = await domain.seedBundledDomainGuides()
        let seeded = try await domain.readManaged(id: "floe-pdf")
        let row = try XCTUnwrap(seeded.first)
        _ = try await domain.setEnabled(
            skillID: "floe-pdf",
            revision: ConfigRevision(resourceID: "skill.floe-pdf", version: row.digest),
            enabled: false)
        let outcome = await domain.seedBundledDomainGuides()
        XCTAssertEqual(outcome["floe-pdf"], "unchanged")
        let after = try await domain.readManaged(id: "floe-pdf")
        XCTAssertEqual(after.first?.enabled, false,
                       "a content-identical seed never re-enables a disabled guide")
    }

    func testExplicitRemovalMarkerSuppressesReseedUntilRestore() async throws {
        let (fixture, domain) = try await makeDomain("bundled-removed")
        _ = await domain.seedBundledDomainGuides()
        for id in ["floe-pdf", "floe-shell"] {
            let seeded = try await domain.readManaged(id: id)
            let row = try XCTUnwrap(seeded.first)
            let reply = try await domain.uninstall(
                skillID: id,
                revision: ConfigRevision(resourceID: "skill.\(id)", version: row.digest))
            XCTAssertEqual(reply["state"] as? String, "removed")
        }
        // Both visible and hidden guides preserve explicit removal.
        let outcome = await domain.seedBundledDomainGuides()
        for id in ["floe-pdf", "floe-shell"] {
            XCTAssertEqual(outcome[id], "userRemoved")
            let removed = try await domain.readManaged(id: id)
            XCTAssertTrue(removed.isEmpty)
        }
        // Use the same explicit restore service operation as the host.
        let restored = await domain.seedBundledDomainGuides(restoringRemoved: true)
        for id in ["floe-pdf", "floe-shell"] {
            XCTAssertEqual(restored[id], "installed")
            let after = try await domain.readManaged(id: id)
            XCTAssertEqual(after.first?.enabled, true)
        }
    }

    func testUserManagedIdentityIsNeverReplacedBySeeding() async throws {
        let (fixture, domain) = try await makeDomain("bundled-usermanaged")
        _ = await domain.seedBundledDomainGuides()
        // A row whose source is a verified hub/community package — even one
        // that shares a bundled id — keeps its identity (original policy:
        // app bundles never replace a GitHub/user-managed source).
        try await fixture.database.writer { db in
            try db.execute(sql: "UPDATE skills SET source_url = ? WHERE id = ?",
                           arguments: ["https://github.com/example/floe-pdf", "floe-pdf"])
        }
        let before = try await domain.readManaged(id: "floe-pdf")
        let digestBefore = try XCTUnwrap(before.first?.digest)
        let outcome = await domain.seedBundledDomainGuides()
        XCTAssertEqual(outcome["floe-pdf"], "userManaged")
        let after = try await domain.readManaged(id: "floe-pdf")
        XCTAssertEqual(after.first?.digest, digestBefore,
                       "a user-managed package is never overwritten by the app bundle")
    }
}
