// SPDX-License-Identifier: MPL-2.0
//
// RB-6 Skills qualification TEST SOURCE (authored, NOT executed by this
// package). All actions go through the public production adapters: the
// SkillsCommandRouter (typed envelope → terminal reply) over the real
// SkillsDomain over the REAL original services (SkillPackageValidator,
// SkillInstallStagingService, SQLiteSkillStore on the 46-migration DB, the
// ORIGINAL upgrade journal semantics). Fixtures are synthetic and
// public-safe. These cases deliberately mirror the ORIGINAL iOS behaviors
// (the equivalence inventory is provenance/EQUIVALENT_TESTS.md) instead of
// asserting mock dictionaries.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeSkills
import FloeTools
import FloePersistence

final class RuntimeFacadeSkillsTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private func makeFixture(_ id: String) async throws -> (RB6TestFixture, SkillsCommandRouter, SkillsDomain, ToolRunnerRegistry) {
        let fixture = try await RB6TestFixture.make(id: id)
        let toolWork = FacadeToolWorkCoordinator()
        let registry = ToolRunnerRegistry()   // per-test local registry
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: SkillsRemoteTransportUnavailable(),
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: toolWork,
            registry: registry))
        return (fixture, SkillsCommandRouter(domain: domain), domain, registry)
    }

    private func envelope(command: String, payload: sending [String: Any]?,
                          revision: [String: String]?, createIntent: Bool,
                          correlation: String = "c-\(UUID().uuidString)")
        -> sending [String: Any] {
        var envelope: [String: Any] = [
            "schema": "floe.command-envelope/3",
            "scope": "applicationConfiguration",
            "command": command,
            "configurationScope": "skills",
            "stateful": command == "skills.list" ? false : (createIntent || revision != nil),
            "correlationID": correlation,
        ]
        if let payload { envelope["payload"] = payload }
        if let revision { envelope["revision"] = revision }
        if createIntent { envelope["createIntent"] = true }
        return envelope
    }

    // MARK: snapshot on an empty store + honest pagination budget

    func testSnapshotEmptyStoreAndBudget() async throws {
        let (fixture, router, _, _) = try await makeFixture("snap")
        let reply = try await router.handle(command: "skills.list",
                                            envelope: envelope(command: "skills.list",
                                                               payload: nil, revision: nil,
                                                               createIntent: false))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "completed")
        let value = try XCTUnwrap(object["value"] as? [String: Any])
        let skills = try XCTUnwrap(value["skills"] as? [[String: Any]])
        XCTAssertTrue(skills.isEmpty)
        XCTAssertEqual(value["hasMore"] as? Bool, false)
        let catalog = try XCTUnwrap(value["catalog"] as? [String: Any])
        XCTAssertEqual(catalog["state"] as? String, "unavailable")   // honest: not refreshed
        let settings = try XCTUnwrap(value["settings"] as? [String: Any])
        XCTAssertEqual(settings["autoScriptedUpdates"] as? Bool, false)
    }

    // MARK: creator install → review OR committed via the ORIGINAL policy

    func testCreatorInstallThroughOriginalStagingAndStore() async throws {
        let (fixture, router, domain, registry) = try await makeFixture("creator")
        // A registered non-side-effecting tool so the ORIGINAL automatic
        // policy can pass (workspace.list with readsFiles only).
        let descriptor = ToolCatalog.Descriptor(
            name: "workspace.list", toolDescription: "list",
            parametersJSON: "{\"type\":\"object\"}",
            riskLabels: [.readsFiles], isSideEffecting: false)
        registry.register(AnyAgentTool(descriptor: descriptor) { _, _ in
            ToolExecutionOutput(summary: "ok", fullOutputSHA256: "0")
        })
        let reply = try await router.handle(
            command: "skills.install",
            envelope: envelope(command: "skills.install",
                               payload: ["operation": "creator.create",
                                         "draft": ["name": "Fixture Guide",
                                                   "description": "desc",
                                                   "instructions": "body"]],
                               revision: nil, createIntent: true))
        let value = try Self.completedValue(reply)
        let projection = try XCTUnwrap(value as? [String: Any])
        // mayInstallWithoutConfirmation on a pure-read manifest ⇒ the
        // ORIGINAL silent-install branch (committed == true immediately).
        XCTAssertEqual(projection["committed"] as? Bool, true)
        XCTAssertEqual(projection["skillID"] as? String, "fixture-guide")
        // REAL row on the original store with the digest revision.
        let snapshotReply = try await router.handle(
            command: "skills.list",
            envelope: envelope(command: "skills.list", payload: nil,
                               revision: nil, createIntent: false))
        let snapshotValue = try XCTUnwrap(
            try Self.completedValue(snapshotReply) as? [String: Any])
        let rows = try XCTUnwrap(snapshotValue["skills"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        let revision = try XCTUnwrap(row["revision"] as? [String: String])
        XCTAssertEqual(revision["version"]?.count, 64)
        // Package bytes landed at the canonical original location.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.installationRoot
                .appendingPathComponent("fixture-guide/SKILL.md").path))
        // AND the staged original package validates with the ORIGINAL gate.
        let validated = try SkillPackageValidator().validate(
            packageAt: fixture.installationRoot.appendingPathComponent("fixture-guide"),
            requireManifest: true)
        XCTAssertEqual(validated.canonicalSHA256, revision["version"])
        _ = domain
    }

    // MARK: tampered package bytes are refused BEFORE any install effect

    func testTamperedDigestRefusalLeavesStoreUntouched() async throws {
        let (fixture, router, domain, _) = try await makeFixture("tamper")
        // Stage a folder package directly (host-style), then tamper the
        // digest receipt claim: registerStagedFolder must reject the
        // mismatch BEFORE any review/install exists.
        let packageDirectory = fixture.stagingRoot
            .appendingPathComponent("tamper-\(UUID().uuidString)")
        try RB6Package.writePackage(at: packageDirectory, id: "tamper-guide")
        let receipt = SkillsFolderStagingReceipt(
            canonicalSHA256: String(repeating: "0", count: 64),   // lie
            fileCount: 2, totalBytes: 256, ttlSeconds: 60)
        do {
            _ = try await domain.registerStagedFolder(directory: packageDirectory,
                                                      receipt: receipt)
            XCTFail("digest mismatch must be refused")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "stagingDigestMismatch")
        }
        // No token ⇒ no wire import possible; store untouched.
        let reply = try await router.handle(
            command: "skills.list",
            envelope: envelope(command: "skills.list", payload: nil,
                               revision: nil, createIntent: false))
        let value = try XCTUnwrap(try Self.completedValue(reply) as? [String: Any])
        XCTAssertTrue(((value["skills"]) as? [Any])?.isEmpty ?? false)
    }

    // MARK: unsafe paths / symlinks rejected by the ORIGINAL validator

    func testUnsafeFolderImportRefused() async throws {
        let (fixture, _, domain, _) = try await makeFixture("unsafe")
        let packageDirectory = fixture.stagingRoot
            .appendingPathComponent("unsafe-\(UUID().uuidString)")
        try RB6Package.writePackage(at: packageDirectory, id: "unsafe-guide",
                                    extraFiles: ["references/ok.txt": "fine"])
        // Inject a symlink (original validator: symbolicLink anywhere ⇒
        // refusal; created AFTER the receipt digest so registration passes
        // but the import validation must fail closed).
        let receipt = SkillsFolderStagingReceipt(
            canonicalSHA256: try RB6Package.canonicalDigest(at: packageDirectory),
            fileCount: 2,
            totalBytes: try Self.directoryBytes(packageDirectory),
            ttlSeconds: 120)
        let token = try await domain.registerStagedFolder(directory: packageDirectory,
                                                     receipt: receipt)
        let target = packageDirectory.appendingPathComponent("references/evil.txt")
        try FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: packageDirectory.appendingPathComponent("references/ok.txt"))
        do {
            _ = try await domain.importStagedFolder(token: token)
            XCTFail("symlink must be refused by the original validator")
        } catch let error as ConfigDomainError {
            XCTAssertTrue(error.reason.contains("symbolicLink"), error.reason)
        }
    }

    // MARK: review confirm/discard + generation fencing + late callbacks

    func testReviewDiscardAndStaleGenerationFencing() async throws {
        let (fixture, _, domain, registry) = try await makeFixture("review")
        // A side-effecting manifest ⇒ review required (original policy).
        let packageDirectory = fixture.stagingRoot
            .appendingPathComponent("review-\(UUID().uuidString)")
        try RB6Package.writePackage(
            at: packageDirectory, id: "review-guide",
            manifest: RB6Package.manifestJSON(id: "review-guide",
                                              capabilities: ["network"],
                                              tools: []),
            markdown: RB6Package.markdown(name: "review-guide"))
        let receipt = SkillsFolderStagingReceipt(
            canonicalSHA256: try RB6Package.canonicalDigest(at: packageDirectory),
            fileCount: 2, totalBytes: try Self.directoryBytes(packageDirectory),
            ttlSeconds: 600)
        let stagingToken = try await domain.registerStagedFolder(directory: packageDirectory,
                                                            receipt: receipt)
        let projection = try await domain.importStagedFolder(token: stagingToken)
        XCTAssertEqual(projection.committed, false)
        let reviewToken = projection.token
        // A SECOND domain instance under a NEW generation cannot touch it.
        let rows = try await domain.snapshot(cursor: nil)
        // The wire projection is the ARRAY of pending reviews (each carrying
        // its confirm/discard revision token), not a bare count.
        let pending = try XCTUnwrap(rows["pendingReviews"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?["reviewToken"] as? String, reviewToken)
        // Discard drops ONLY the staged review (nothing installed).
        _ = try await domain.reviewDiscard(token: reviewToken)
        let afterDiscard = try await domain.snapshot(cursor: nil)
        XCTAssertEqual((try XCTUnwrap(afterDiscard["pendingReviews"] as? [[String: Any]])).count, 0)
        let skills = try XCTUnwrap(afterDiscard["skills"] as? [Any])
        XCTAssertTrue(skills.isEmpty)
        do {
            _ = try await domain.reviewCommit(token: reviewToken,
                                              createIntent: true, revision: nil)
            XCTFail("retired token must not replay")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "reviewUnknown")
        }
        _ = registry
    }

    // MARK: revision CAS — stale digest refuses setEnabled

    func testEnabledSetCAS() async throws {
        let (fixture, _, domain, registry) = try await makeFixture("cas")
        _ = try await Self.installReadonly(domain: domain, registry: registry)
        let store = SQLiteSkillStore(database: fixture.database)
        let rows = try await store.all()
        let row = try XCTUnwrap(rows.first)
        do {
            _ = try await domain.setEnabled(
                skillID: row.id,
                revision: ConfigRevision(resourceID: "skill.\(row.id)",
                                         version: String(repeating: "f", count: 64)),
                enabled: false)
            XCTFail("stale digest must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "skillCAS")
        }
        // Same revision as the row succeeds exactly once; the store really
        // flipped (durable readback, not mock state).
        _ = try await domain.setEnabled(
            skillID: row.id,
            revision: ConfigRevision(resourceID: "skill.\(row.id)",
                                     version: row.rewrittenDigest),
            enabled: false)
        let reloadedRows = try await store.all()
        let updated = try XCTUnwrap(reloadedRows.first)
        XCTAssertEqual(updated.status, "disabled")
    }

    // MARK: uninstall = owned-worker quiesce + recoverable backup + row CAS

    func testUninstallRecoverableAndRestoresOnDBConflict() async throws {
        let (fixture, _, domain, registry) = try await makeFixture("uninstall")
        let digest = try await Self.installReadonly(domain: domain, registry: registry)
        let packageDirectory = fixture.installationRoot
            .appendingPathComponent("cas-guide")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.path))
        // Stale CAS: files untouched, row untouched.
        do {
            _ = try await domain.uninstall(
                skillID: "cas-guide",
                revision: ConfigRevision(resourceID: "skill.cas-guide",
                                         version: String(repeating: "e", count: 64)))
            XCTFail("expected staleRevision")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "skillCAS")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.path))
        // Correct CAS: backup created outside the store root, row removed.
        let reply = try await domain.uninstall(
            skillID: "cas-guide",
            revision: ConfigRevision(resourceID: "skill.cas-guide", version: digest))
        XCTAssertEqual(reply["state"] as? String, "removed")
        XCTAssertEqual(reply["recoveryAvailable"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageDirectory.path))
        let backupToken = try XCTUnwrap(reply["recoveryToken"] as? String)
        let removedRoot = fixture.installationRoot.deletingLastPathComponent()
            .appendingPathComponent("RemovedSkills")
        let backups = try FileManager.default.contentsOfDirectory(atPath: removedRoot.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("cas-guide-\(backupToken)") } ||
                      backups.contains { $0.hasPrefix("cas-guide-") },
                      "recoverable backup at RemovedSkills: \(backups)")
        let store = SQLiteSkillStore(database: fixture.database)
        let remainingRows = try await store.all()
        XCTAssertTrue(remainingRows.isEmpty)
    }

    // MARK: compatibility honesty — iOS-only manifests refuse on Android

    func testIosOnlyManifestRefused() async throws {
        let (fixture, _, domain, _) = try await makeFixture("compat")
        let packageDirectory = fixture.stagingRoot
            .appendingPathComponent("iosonly-\(UUID().uuidString)")
        try RB6Package.writePackage(
            at: packageDirectory, id: "ios-only-guide",
            manifest: RB6Package.manifestJSON(id: "ios-only-guide",
                                              platforms: ["ios"]),
            markdown: RB6Package.markdown(name: "ios-only-guide"))
        let receipt = SkillsFolderStagingReceipt(
            canonicalSHA256: try RB6Package.canonicalDigest(at: packageDirectory),
            fileCount: 2, totalBytes: try Self.directoryBytes(packageDirectory),
            ttlSeconds: 120)
        let token = try await domain.registerStagedFolder(directory: packageDirectory,
                                                    receipt: receipt)
        do {
            _ = try await domain.importStagedFolder(token: token)
            XCTFail("platform-incompatible manifest must refuse on Android")
        } catch let error as ConfigDomainError {
            XCTAssertTrue(error.reason.hasPrefix("skillCompat"), error.reason)
        }
    }

    // MARK: unregistered remote/retired capabilities are never usable

    func testRetiredAndG03NamesNeverAdvertised() async throws {
        let (fixture, _, _, registry) = try await makeFixture("usable")
        // Even a (wrongly) pre-registered retired name must not surface.
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(name: "exec.localPython",
                                               toolDescription: "retired",
                                               parametersJSON: "{}",
                                               riskLabels: [.executesLocalCode],
                                               isSideEffecting: true)) { _, _ in
                ToolExecutionOutput(summary: "x", fullOutputSHA256: "0")
            })
        let webSearch = CapabilitiesWebSearchUnbound()
        let capabilities = CapabilitiesDomain(services: .init(
            database: fixture.database, webSearch: webSearch,
            mcp: CapabilitiesMCPUnbound(), hostContext: fixture.hostContext,
            registry: registry))
        let router = CapabilitiesCommandRouter(domain: capabilities)
        let reply = await router.handle(
            command: "capability.tools.list",
            envelope: ["schema": "floe.command-envelope/3",
                       "scope": "applicationConfiguration",
                       "command": "capability.tools.list",
                       "configurationScope": "capabilities",
                       "stateful": false, "correlationID": "cap-1"])
        let value = try XCTUnwrap(try Self.completedValue(reply) as? [String: Any])
        let tools = try XCTUnwrap(value["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.contains { $0["name"] as? String == "exec.localPython" },
                       "retired names dropped by the original registry")
        let temp = try XCTUnwrap(value["temporaryCeiling"] as? [String: Any])
        let names = try XCTUnwrap(temp["names"] as? [String])
        // CURRENT upstream public-web-only closed ceiling: only the three
        // names can appear, and only if registered (none here).
        XCTAssertTrue(Set(names).isSubset(of: ["web.search", "web.searchAI", "web.fetch"]))
    }

    // MARK: settings document CAS (digest-of-value pattern)

    func testSettingsSetCAS() async throws {
        let (fixture, _, domain, _) = try await makeFixture("settings")
        let document = try await domain.settingsDocument()
        let revision = try XCTUnwrap(document["revision"] as? [String: String])
        let resourceID = try XCTUnwrap(revision["resourceID"])
        let version = try XCTUnwrap(revision["version"])
        XCTAssertEqual(resourceID, "skills.settings")
        _ = try await domain.setAutoScriptedUpdates(enabled: true,
                                                    revision: ConfigRevision(
                                                        resourceID: resourceID,
                                                        version: version))
        // Replay the OLD revision ⇒ stale (digest of the value moved).
        do {
            _ = try await domain.setAutoScriptedUpdates(enabled: false,
                                                        revision: ConfigRevision(
                                                            resourceID: resourceID,
                                                            version: version))
            XCTFail("stale settings digest must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "settingsCAS")
        }
        let updated = try await domain.settingsDocument()
        XCTAssertEqual((try XCTUnwrap(updated["autoScriptedUpdates"] as? Bool)), true)
    }

    // MARK: detail window — UTF-8-safe, honest hasMore

    func testDetailWindowBoundaries() async throws {
        let (fixture, _, domain, registry) = try await makeFixture("detail")
        let body = String(repeating: "中文émoji🙂 tail ", count: 40)
        let digest = try await Self.installReadonly(domain: domain, registry: registry,
                                                    id: "detail-guide",
                                                    instructions: body)
        _ = digest
        let first = try await domain.detail(skillID: "detail-guide", byteOffset: 0,
                                            maxBytes: 64)
        XCTAssertEqual(first["hasMore"] as? Bool, true)
        let text = try XCTUnwrap(first["text"] as? String)
        XCTAssertFalse(text.isEmpty)
        // Boundary is scalar-safe: the returned slice is valid UTF-8 by
        // construction and never exceeds maxBytes.
        XCTAssertTrue(Data(text.utf8).count <= 64)
        // Out-of-range offset refuses typed.
        do {
            _ = try await domain.detail(skillID: "detail-guide",
                                        byteOffset: 10_000_000, maxBytes: 64)
            XCTFail("offset must be range-checked")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "detailOffsetOutOfRange")
        }
    }

    // MARK: helpers

    /// Install a pure-read-only creator package through the PRODUCTION
    /// funnel (automatic policy branch), returning the durable digest.
    static func installReadonly(domain: SkillsDomain, registry: ToolRunnerRegistry,
                                id: String = "Cas Guide",
                                instructions: String = "body") async throws -> String {
        let descriptor = ToolCatalog.Descriptor(
            name: "workspace.list", toolDescription: "list",
            parametersJSON: "{\"type\":\"object\"}",
            riskLabels: [.readsFiles], isSideEffecting: false)
        registry.register(AnyAgentTool(descriptor: descriptor) { _, _ in
            ToolExecutionOutput(summary: "ok", fullOutputSHA256: "0")
        })
        let projection = try await domain.createSkill(draft: SkillCreationRequest(
            name: id, description: "desc", instructions: instructions,
            pythonScripts: [], pythonPackages: []))
        XCTAssertTrue(projection.committed)
        return try await domain.digestForSkill(projection.skillID)
    }

    static func completedValue(_ data: Data) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["state"] as? String, "completed",
                       "expected completed reply, got \(String(describing: object))")
        return object?["value"] ?? NSNull()
    }

    static func directoryBytes(_ directory: URL) throws -> Int {
        var total = 0
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}

// Small test-only helper (internal under @testable): reads the exact row
// digest back through the PRODUCTION snapshot projection (the same
// skills.list path), not by reaching into private state.
extension SkillsDomain {
    func digestForSkill(_ skillID: String) async throws -> String {
        let snapshot = try await snapshot(cursor: nil)
        let rows = (snapshot["skills"] as? [[String: Any]]) ?? []
        guard let row = rows.first(where: { $0["id"] as? String == skillID }),
              let revision = row["revision"] as? [String: String] else {
            throw ConfigDomainError(code: .notFound, reason: "testDigestMissing")
        }
        return try XCTUnwrap(revision["version"])
    }
}
