// SPDX-License-Identifier: MPL-2.0
//
// n07-skill-snapshots69 — durable per-run pinned Skill snapshot TEST SOURCE
// (authored, NOT executed by this lane; no compiler or XCTest run is
// claimed). Meaningful contract cases against the REAL production seams:
// SkillsDomain.readManaged(id:runID:) over the REAL original stores (RB6
// fixture), the SkillRunSnapshotStore ownership rules, and the
// conversation-deletion release port. Not implementation-mirror tests.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeSkills
import FloeTools
import FloePersistence

final class RuntimeFacadeSkillRunSnapshotTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    // MARK: - Fixture

    private struct Harness {
        let fixture: RB6TestFixture
        let domain: SkillsDomain
        let registry: ToolRunnerRegistry
    }

    /// One committed creator install (the ORIGINAL staging+store chain) so
    /// an exact enabled row with real package bytes exists to pin.
    private func makeInstalled(_ id: String) async throws -> Harness {
        let fixture = try await RB6TestFixture.make(id: id)
        let registry = ToolRunnerRegistry()
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: SkillsRemoteTransportUnavailable(),
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: registry))
        registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
            name: "workspace.list", toolDescription: "list",
            parametersJSON: "{\"type\":\"object\"}",
            riskLabels: [.readsFiles], isSideEffecting: false)) { _, _ in
            ToolExecutionOutput(summary: "ok", fullOutputSHA256: "0")
        })
        let router = SkillsCommandRouter(domain: domain)
        let reply = try await router.handle(
            command: "skills.install",
            envelope: [
                "schema": "floe.command-envelope/3",
                "scope": "applicationConfiguration",
                "command": "skills.install",
                "configurationScope": "skills",
                "stateful": true,
                "correlationID": "c-\(UUID().uuidString)",
                "payload": ["operation": "creator.create",
                            "draft": ["name": "Fixture Guide",
                                      "description": "desc",
                                      "instructions": "body one"]],
                "createIntent": true,
            ])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        print("HOST69_CREATOR_REPLY " + String(decoding: reply, as: UTF8.self))
        XCTAssertEqual(object["state"] as? String, "completed", String(decoding: reply, as: UTF8.self))
        return Harness(fixture: fixture, domain: domain, registry: registry)
    }

    private func revision(_ digest: String, _ id: String) -> ConfigRevision {
        ConfigRevision(resourceID: "skill.\(id)", version: digest)
    }

    @discardableResult
    private func updateBody(_ harness: Harness, digest: String, body: String) async throws -> String {
        // The tool-layer approval gate is intentionally bypassed: the domain
        // manage path is what the gate protects, and this lane tests read
        // pinning, not approval.
        try await harness.domain.manageViaTool(.init(
            action: .update, id: "fixture-guide", expectedDigest: digest,
            instructions: body))
        let rows = try await harness.domain.readManaged(id: nil)
        return try XCTUnwrap(rows.first?.currentDigest)
    }

    // MARK: 1. The REAL tool path: page 2 of a run paginates the PINNED
    // bytes even when the install changed between the pages.

    func testSkillReadPaginationNeverCombinesRevisionsAcrossUpgrade() async throws {
        let harness = try await makeInstalled("pin-pagination")
        let registry = ToolRunnerRegistry()
        registerSkillTools(registry: registry,
                           creator: SkillsDomainCreatingFacade(domain: harness.domain),
                           manager: SkillsDomainManagingFacade(domain: harness.domain))
        let runner = try XCTUnwrap(registry.runner(named: "skill.read"))
        let runID = UUID()

        // The installed body is replaced with a long, DISTINCTIVE revision.
        // SKILL.md = frontmatter (48 chars) + 72 alpha chars + 240 omega
        // chars, so page 1 (0..120) ends inside alpha and page 2 (120..240)
        // is exactly the omega region.
        let listed = try await harness.domain.readManaged(id: "fixture-guide")
        let digestOne = try XCTUnwrap(listed.first?.currentDigest)
        let longBody = String(repeating: "alpha ", count: 12) + String(repeating: "omega ", count: 40)
        _ = try await updateBody(harness, digest: digestOne, body: longBody)

        struct Page: Decodable { let digest: String; let markdown: String?; let nextOffset: Int? }
        func page(_ arguments: String) async throws -> Page {
            let output = try await runner.execute(
                argumentsJSON: Data(arguments.utf8),
                context: ToolContext(runID: runID, cancellation: CancellationToken()))
            let rows = try JSONDecoder().decode([Page].self, from: Data(output.summary.utf8))
            return try XCTUnwrap(rows.first)
        }
        let first = try await page(#"{"id":"fixture-guide","offset":0,"limit":120}"#)
        XCTAssertTrue(first.markdown?.hasPrefix("---") == true)
        XCTAssertTrue(first.markdown?.contains("alpha") == true)
        // Mid-run upgrade to a completely different text.
        let digestTwo = try await updateBody(harness, digest: first.digest, body: String(repeating: "zulu ", count: 120))
        XCTAssertNotEqual(first.digest, digestTwo)

        // Page 2 of the SAME run: the pinned alpha/omega bytes continue (the
        // post-upgrade "zulu" revision can never leak in), the digest stays
        // the first revision, and the current installed CAS remains visible
        // for skill.manage.
        let second = try await page(#"{"id":"fixture-guide","offset":120,"limit":120}"#)
        XCTAssertEqual(second.digest, first.digest)
        XCTAssertTrue(second.markdown?.contains("omega") == true)
        XCTAssertFalse(second.markdown?.contains("zulu") == true)
        let listedAfter = try await harness.domain.readManaged(id: "fixture-guide")
        XCTAssertEqual(listedAfter.first?.currentDigest, digestTwo)
    }

    func testSameRunKeepsPinnedBytesWhileNewRunSeesCurrentInstall() async throws {
        let harness = try await makeInstalled("pin-same-run")
        let runID = UUID()
        let first = try await harness.domain.readManaged(id: "fixture-guide", runID: runID)
        let digestOne = try XCTUnwrap(first.first?.digest)
        let digestTwo = try await updateBody(harness, digest: digestOne, body: "body two")

        let continued = try await harness.domain.readManaged(id: "fixture-guide", runID: runID)
        let continuedRow = try XCTUnwrap(continued.first)
        XCTAssertEqual(continuedRow.digest, digestOne)
        XCTAssertTrue(continuedRow.markdown?.contains("body one") == true)
        XCTAssertEqual(continuedRow.currentDigest, digestTwo)
        let pinnedIDs = await harness.domain.pinnedRunSkillSnapshotRunIDs()
        XCTAssertEqual(pinnedIDs, [runID])

        let newRun = UUID()
        let fresh = try await harness.domain.readManaged(id: "fixture-guide", runID: newRun)
        let freshRow = try XCTUnwrap(fresh.first)
        XCTAssertEqual(freshRow.digest, digestTwo)
        XCTAssertTrue(freshRow.markdown?.contains("body two") == true)
        XCTAssertEqual(freshRow.currentDigest, digestTwo)
        let allPinnedIDs = await harness.domain.pinnedRunSkillSnapshotRunIDs()
        XCTAssertEqual(Set(allPinnedIDs), [runID, newRun])
    }

    // MARK: 2. Process recovery: a rebuilt domain over the SAME root serves
    // the original pin instead of the newer install.

    func testRecoveredDomainServesOriginalPinnedBytes() async throws {
        let harness = try await makeInstalled("pin-recovery")
        let runID = UUID()
        let first = try await harness.domain.readManaged(id: "fixture-guide", runID: runID)
        let digestOne = try XCTUnwrap(first.first?.digest)
        let digestTwo = try await updateBody(harness, digest: digestOne, body: "body two")

        // Simulate process restart: a NEW domain over the SAME database and
        // installation root (same accepted generation binding).
        let recovered = try SkillsDomain(services: .init(
            database: harness.fixture.database,
            installationRoot: harness.fixture.installationRoot,
            stagingRoot: harness.fixture.stagingRoot,
            hostContext: harness.fixture.hostContext,
            transport: SkillsRemoteTransportUnavailable(),
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: harness.fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: harness.registry))
        let resumed = try await recovered.readManaged(id: "fixture-guide", runID: runID)
        let resumedRow = try XCTUnwrap(resumed.first)
        XCTAssertEqual(resumedRow.digest, digestOne)
        XCTAssertTrue(resumedRow.markdown?.contains("body one") == true)
        XCTAssertEqual(resumedRow.currentDigest, digestTwo)
    }

    // MARK: 3. Disabled user intent stays authoritative; no pin is created.

    func testDisabledExactReadReturnsMetadataOnlyAndNeverPins() async throws {
        let harness = try await makeInstalled("pin-disabled")
        let listed = try await harness.domain.readManaged(id: "fixture-guide")
        let digest = try XCTUnwrap(listed.first?.currentDigest)
        _ = try await harness.domain.setEnabled(
            skillID: "fixture-guide",
            revision: revision(digest, "fixture-guide"), enabled: false)
        let runID = UUID()
        let read = try await harness.domain.readManaged(id: "fixture-guide", runID: runID)
        let row = try XCTUnwrap(read.first)
        XCTAssertFalse(row.enabled)
        XCTAssertNil(row.markdown)
        XCTAssertNil(row.requiredToolNames)
        XCTAssertEqual(row.digest, digest)
        // A disabled read must not pin anything for the run.
        let disabledIDs = await harness.domain.pinnedRunSkillSnapshotRunIDs()
        XCTAssertEqual(disabledIDs, [])
        // Re-enabling lets the SAME run pin the current bytes.
        let reenabledDigest = try await updateBody(harness, digest: digest, body: "body three")
        _ = try await harness.domain.setEnabled(
            skillID: "fixture-guide",
            revision: revision(reenabledDigest, "fixture-guide"), enabled: true)
        let repinned = try await harness.domain.readManaged(id: "fixture-guide", runID: runID)
        XCTAssertTrue(repinned.first?.markdown?.contains("body three") == true)
        let reenabledIDs = await harness.domain.pinnedRunSkillSnapshotRunIDs()
        XCTAssertEqual(reenabledIDs, [runID])
    }

    // MARK: 4. Task deletion releases only the deleted task's run trees.

    func testConversationDeleteReleasesExactlyTheOwnedRunSnapshots() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let cleaning = RecordingRunSnapshotCleaning()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle,
                                           runSnapshotCleaning: cleaning)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "snapshot task")
        let ownedRun = UUID()
        let foreignRun = UUID()
        try await RB3TestBed.seedRun(stores.database, conversationID: record.id, id: ownedRun)
        // Another conversation's run id must never be passed to the port.
        let other = try await RB3TestBed.seedOrdinary(stores, title: "other task")
        try await RB3TestBed.seedRun(stores.database, conversationID: other.id, id: foreignRun)

        let rev = try await RB3TestBed.revision(stores.database, record.id)
        _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
        XCTAssertEqual(cleaning.released, [ownedRun])
        XCTAssertFalse(cleaning.released.contains(foreignRun))
    }
}

// MARK: - SkillRunSnapshotStore ownership contract (pure FloeSkills)

final class SkillRunSnapshotStoreTests: XCTestCase {

    private var root: URL!
    private var install: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-snapstore-\(UUID().uuidString)")
        install = root.appendingPathComponent("FloeAgent/Skills")
        try! FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeManifestPackage(id: String, body: String, tools: [String]) throws -> (URL, String, SkillManifest) {
        let package = install.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let skillBytes = Data(("---\nname: \(id)\ndescription: store fixture\n---\n\n" + body).utf8)
        try skillBytes.write(to: package.appendingPathComponent("SKILL.md"), options: .atomic)
        let manifest = SkillManifest(id: id, version: "1.0.0",
                                     capabilities: ["workspace.read"],
                                     tools: tools, platforms: ["linux"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: package.appendingPathComponent("floe.json"), options: .atomic)
        let digest = try SkillPackageValidator.canonicalDigest(
            files: ["SKILL.md": skillBytes, "floe.json": manifestBytes])
        return (package, digest, manifest)
    }

    func testTamperedPinnedBytesRefuseClosedWithoutTouchingCurrentInstall() throws {
        let (package, digest, manifest) = try writeManifestPackage(
            id: "store-guide", body: "original", tools: ["workspace.list"])
        let store = SkillRunSnapshotStore(installationRoot: install)
        let runID = UUID()
        let pinned = try store.pinnedSnapshot(currentInstallRoot: package,
                                              expectedDigest: digest,
                                              manifestOverride: manifest,
                                              runID: runID, skillID: "store-guide")
        XCTAssertTrue(String(decoding: pinned.files["SKILL.md"] ?? Data(), as: UTF8.self)
            .hasSuffix("original"))

        // Tamper with the PINNED tree only; the current install is untouched.
        let pinnedPackage = install
            .appendingPathComponent(".run-snapshots/\(runID.uuidString)/store-guide/package")
        try Data("attacker".utf8)
            .write(to: pinnedPackage.appendingPathComponent("SKILL.md"), options: .atomic)
        XCTAssertThrowsError(try store.pinnedSnapshot(
            currentInstallRoot: package, expectedDigest: digest,
            manifestOverride: manifest, runID: runID, skillID: "store-guide")) { error in
            XCTAssertTrue(error is SkillValidationError)
        }
        // The current install still validates (nothing fell back or mixed).
        let current = try SkillContentSnapshot(root: package, expectedDigest: digest,
                                               manifestOverride: manifest)
        XCTAssertTrue(String(decoding: current.files["SKILL.md"] ?? Data(), as: UTF8.self)
            .hasSuffix("original"))
    }

    func testCorruptDigestAndForeignMarkerRefuseAndAreNeverDeleted() throws {
        let (package, digest, manifest) = try writeManifestPackage(
            id: "store-guide", body: "original", tools: ["workspace.list"])
        let store = SkillRunSnapshotStore(installationRoot: install)
        let runID = UUID()
        _ = try store.pinnedSnapshot(currentInstallRoot: package, expectedDigest: digest,
                                     manifestOverride: manifest, runID: runID, skillID: "store-guide")
        let directory = install.appendingPathComponent(".run-snapshots/\(runID.uuidString)/store-guide")
        try Data("deadbeef".utf8)
            .write(to: directory.appendingPathComponent("digest"), options: .atomic)
        XCTAssertThrowsError(try store.pinnedSnapshot(
            currentInstallRoot: package, expectedDigest: digest,
            manifestOverride: manifest, runID: runID, skillID: "store-guide"))
        // Corrupt entries are retained (never deleted) and refused.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        // A foreign marker is not ownership: release refuses, tree stays.
        try Data("migration:\(runID.uuidString)".utf8)
            .write(to: directory.appendingPathComponent(SkillRunSnapshotStore.ownerMarkerComponent),
                   options: .atomic)
        XCTAssertEqual(store.release(runID: runID), .notOwned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMigrationMarkedSiblingIsNeverListedOrReleased() throws {
        let (package, digest, manifest) = try writeManifestPackage(
            id: "store-guide", body: "original", tools: ["workspace.list"])
        let store = SkillRunSnapshotStore(installationRoot: install)
        let runID = UUID()
        _ = try store.pinnedSnapshot(currentInstallRoot: package, expectedDigest: digest,
                                     manifestOverride: manifest, runID: runID, skillID: "store-guide")
        XCTAssertEqual(store.pinnedRunIDs(), [runID])

        // A migration preparation tree sharing the runs root (its own UUID
        // directory with the migration marker) is never a real-run pin.
        let migrationID = UUID()
        let migration = install.appendingPathComponent(".run-snapshots/\(migrationID.uuidString)")
        try FileManager.default.createDirectory(at: migration, withIntermediateDirectories: true)
        try Data("migration:\(migrationID.uuidString)".utf8)
            .write(to: migration.appendingPathComponent(".floe-migration-owner"), options: .atomic)
        XCTAssertEqual(store.pinnedRunIDs(), [runID])
        XCTAssertEqual(store.release(runID: migrationID), .notOwned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.path))

        // A marker sharing a real run's UUID still belongs to migration.
        let sharedMarker = install.appendingPathComponent(
            ".run-snapshots/\(runID.uuidString)/.floe-migration-owner")
        try Data("migration:\(runID.uuidString)".utf8).write(to: sharedMarker, options: .atomic)
        XCTAssertEqual(store.release(runID: runID), .notOwned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedMarker.path))
        try FileManager.default.removeItem(at: sharedMarker)

        // With no foreign entries, releasing the real run removes its tree.
        XCTAssertEqual(store.release(runID: runID), .released)
        XCTAssertEqual(store.pinnedRunIDs(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.path))
    }

    func testManifestLessPinRecoversPinnedManifestNotCurrentRow() throws {
        // Traditional manifest-less package: digest covers files only; the
        // sidecar manifest is persisted WITH the pin so recovery interprets
        // the pinned bytes with the PINNED manifest, never the current row's.
        let package = install.appendingPathComponent("trad-guide")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let bodyBytes = Data("---\nname: trad-guide\ndescription: traditional\n---\n\nbody A\n".utf8)
        try bodyBytes.write(to: package.appendingPathComponent("SKILL.md"), options: .atomic)
        let digestA = try SkillPackageValidator.canonicalDigest(files: [
            "SKILL.md": bodyBytes])
        let manifestA = SkillManifest(id: "trad-guide", version: "1.0.0",
                                      capabilities: ["workspace.read"],
                                      tools: ["workspace.list"], platforms: ["linux"])
        let store = SkillRunSnapshotStore(installationRoot: install)
        let runID = UUID()
        let pinnedA = try store.pinnedSnapshot(currentInstallRoot: package,
                                               expectedDigest: digestA,
                                               manifestOverride: manifestA,
                                               runID: runID, skillID: "trad-guide")
        XCTAssertEqual(pinnedA.package.manifest.version, "1.0.0")

        // The row "upgraded": current sidecar now claims version 9.9.9. The
        // recovered pin MUST still report the pinned manifest.
        let manifestB = SkillManifest(id: "trad-guide", version: "9.9.9",
                                      capabilities: ["device.write"],
                                      tools: ["phone.act"], platforms: ["linux"])
        let recovered = try store.pinnedSnapshot(currentInstallRoot: package,
                                                 expectedDigest: digestA,
                                                 manifestOverride: manifestB,
                                                 runID: runID, skillID: "trad-guide")
        XCTAssertEqual(recovered.package.manifest.version, "1.0.0")
        XCTAssertEqual(recovered.package.manifest.tools, ["workspace.list"])
        XCTAssertEqual(recovered.files["SKILL.md"], bodyBytes)
    }
}

// MARK: - Deletion port recorder

final class RecordingRunSnapshotCleaning: ConversationRunSnapshotCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _released: [UUID] = []
    var released: [UUID] { lock.withLock { _released } }
    func releaseSnapshots(runIDs: [UUID]) async {
        lock.withLock { _released.append(contentsOf: runIDs) }
    }
}
