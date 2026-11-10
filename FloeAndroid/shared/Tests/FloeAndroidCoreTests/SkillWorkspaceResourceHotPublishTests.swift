// SPDX-License-Identifier: MPL-2.0
//
// N07 R1 repair — hot resource publish into the LIVE task Linux workspace.
// REAL contract tests (authored, NOT executed by this lane; no compiler or
// XCTest run is claimed). The production seams only: a REAL validated
// package fixture, a REAL temporary workspace, resolver/prober/publisher
// closures answering the production shapes, and — for the wire mapping —
// the REAL C02LiveGuestResourcePublisher over a REAL LinuxShellMailbox
// driven through the same claim/describe/takePayload/complete C-ABI the
// trusted Kotlin pump uses. No fake successful transport: every visibility
// answer is injected honestly like the mailbox probe would return it, and
// the cold path assertions stay byte-identical to the pre-repair contract.
import XCTest
import Foundation
import FloeCore
@testable import FloeAndroidCore
import FloeAndroidShellTools
import FloeSkills
import FloeTools

/// Scripted probe: answers in order (nil = no live session answered), and
/// records every exact relativePath it was asked about.
private actor ScriptedProber: SkillGuestVisibilityProbing {
    private var answers: [Bool?]
    private(set) var asked: [String] = []
    init(answers: [Bool?]) { self.answers = answers }
    func isPathVisible(workspaceRoot: URL, relativePath: String,
                       conversationID: UUID?, cancellation: CancellationToken) async -> Bool? {
        asked.append(relativePath)
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst()
    }
    func askedPaths() -> [String] { asked }
}

/// Scripted publisher: one outcome, and records every exact request.
private actor ScriptedPublisher: SkillGuestResourcePublishing {
    private let outcome: SkillGuestPublishOutcome
    private let beforeReply: (@Sendable () async -> Void)?
    private(set) var requests: [(workspaceRoot: URL, runID: UUID, conversationID: UUID?)] = []
    init(outcome: SkillGuestPublishOutcome, beforeReply: (@Sendable () async -> Void)? = nil) {
        self.outcome = outcome
        self.beforeReply = beforeReply
    }
    func publishStagedBundle(workspaceRoot: URL, runID: UUID,
                             conversationID: UUID?,
                             cancellation: CancellationToken) async -> SkillGuestPublishOutcome {
        requests.append((workspaceRoot, runID, conversationID))
        await beforeReply?()
        return outcome
    }
    func requestCount() -> Int { requests.count }
    func firstRequest() -> (workspaceRoot: URL, runID: UUID, conversationID: UUID?)? {
        requests.first
    }
}

private actor ResolverCallCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

final class SkillWorkspaceResourceHotPublishTests: XCTestCase, @unchecked Sendable {

    private var root: URL!
    private var workspace: URL!
    private var packages: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-hotpublish-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        packages = root.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    /// One REAL digest-validated package + snapshot (the validator remains
    /// the authority for what a package may contain).
    private func makeSnapshot(id: String) throws -> (snapshot: SkillContentSnapshot, digest: String) {
        let package = packages.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let skillBytes = Data(("---\nname: \(id)\ndescription: hot publish fixture\n---\n\nbody\n").utf8)
        try skillBytes.write(to: package.appendingPathComponent("SKILL.md"), options: .atomic)
        let scriptBytes = Data("#!/bin/sh\necho ok\n".utf8)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("scripts"),
                                                withIntermediateDirectories: true)
        try scriptBytes.write(to: package.appendingPathComponent("scripts/run.sh"), options: .atomic)
        let manifest = SkillManifest(id: id, version: "1.0.0",
                                     capabilities: ["workspace.read", "execution.remote"],
                                     tools: ["exec.shell"], platforms: ["linux"],
                                     scriptRuntime: .remote)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: package.appendingPathComponent("floe.json"), options: .atomic)
        let digest = try SkillPackageValidator.canonicalDigest(
            files: ["SKILL.md": skillBytes, "scripts/run.sh": scriptBytes, "floe.json": manifestBytes])
        return (try SkillContentSnapshot(root: package, expectedDigest: digest), digest)
    }

    private func context(workspaceRoot: URL? = nil, token: CancellationToken = CancellationToken())
        -> SkillResourceContext {
        SkillResourceContext(
            runID: UUID(), conversationID: UUID(), environmentID: "env-1",
            workspaceRootURL: workspaceRoot ?? workspace,
            temporaryReadOnly: false, cancellation: token)
    }

    private func localResolver(root: URL? = nil, guest: String = "/workspace")
        -> @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution {
        { _, _ in .local(workspaceRoot: root ?? self.workspace, guestWorkspaceRoot: guest) }
    }

    private func stagedLeaf(_ digest: String, id: String = "hot-guide") -> URL {
        workspace.appendingPathComponent(".floe/skills/\(id)@\(digest)", isDirectory: true)
    }

    private func bundle(of snapshot: SkillContentSnapshot) -> SkillStagingBundle? {
        SkillWorkspaceResourceStager.stagingBundle(
            manifestID: snapshot.package.manifest.id,
            digest: snapshot.package.canonicalSHA256,
            declaredFiles: snapshot.package.files,
            bytes: snapshot.files)
    }

    // MARK: - Hot publish: visible after a definitive false

    func testHotPublishMakesBundleVisibleAndReprobes() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "hot-guide")
        let runID = UUID(), conversationID = UUID()
        let prober = ScriptedProber(answers: [false, true])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: runID, conversationID: conversationID, context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertTrue(bundle.visibleInGuest)
        XCTAssertEqual(bundle.guestRoot, "/workspace/.floe/skills/hot-guide@\(digest)")
        // The publisher ran ONCE with the exact trusted facts of this read.
        let requests = await publisher.requestCount()
        XCTAssertEqual(requests, 1)
        let request = await publisher.firstRequest()
        XCTAssertEqual(request?.workspaceRoot.resolvingSymlinksInPath().standardizedFileURL,
                       workspace.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(request?.runID, runID)
        XCTAssertEqual(request?.conversationID, conversationID)
        // The probe answered twice: the definitive false, then the
        // post-publish confirmation — both for the exact staged tree.
        let asked = await prober.askedPaths()
        XCTAssertEqual(asked, [".floe/skills/hot-guide@\(digest)", ".floe/skills/hot-guide@\(digest)"])
        // The Core-side tree is real and verified (no data loss on publish).
        XCTAssertTrue(SkillWorkspaceResourceStager.verify(
            stagedRoot: stagedLeaf(digest), bundle: self.bundle(of: snapshot)!))
    }

    func testReusePathAlsoHotPublishesIntoTheLiveWorkspace() async throws {
        // R1's exact shape: a bundle staged earlier (cold, invisible), then a
        // later exact read while the same-task session is live must publish,
        // not hand back another not-yet-visible path.
        let (snapshot, digest) = try makeSnapshot(id: "hot-guide")
        let coldProber = ScriptedProber(answers: [nil])
        let cold = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: coldProber, publishVisibility: nil)
        let first = await cold.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let firstBundle) = first else {
            return XCTFail("cold stage failed: \(first)")
        }
        XCTAssertFalse(firstBundle.visibleInGuest)

        let hotProber = ScriptedProber(answers: [false, true])
        let publisher = ScriptedPublisher(outcome: .applied)
        let hot = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: hotProber, publishVisibility: publisher)
        let second = await hot.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let secondBundle) = second else {
            return XCTFail("hot reuse stage failed: \(second)")
        }
        XCTAssertTrue(secondBundle.visibleInGuest)
        let published = await publisher.requestCount()
        XCTAssertEqual(published, 1)
        XCTAssertTrue(SkillWorkspaceResourceStager.verify(
            stagedRoot: stagedLeaf(digest), bundle: bundle(of: snapshot)!))
    }

    // MARK: - Live publish failure: actionable failure, never a ready path

    func testLiveRefusalIsAnActionableFailureAndKeepsTheCoreBytes() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [false, false])
        let publisher = ScriptedPublisher(outcome: .refused(reason: "budgetExceeded"))
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected actionable failure, got \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix("liveWorkspaceSyncRefused"),
                      "reason was: \(reason)")
        XCTAssertTrue(reason.contains("budgetExceeded"), "reason was: \(reason)")
        // The staged Core-side tree is untouched and verified: a later
        // import boundary still materializes it; nothing was deleted.
        XCTAssertTrue(SkillWorkspaceResourceStager.verify(
            stagedRoot: stagedLeaf(digest), bundle: bundle(of: snapshot)!))
        // The model-facing footer never prints a guest path on this failure.
        let footer = SkillWorkspaceResourceStager.resourceFooter(
            id: "hot-guide", pinnedSHA256: snapshot.package.canonicalSHA256,
            declaredFiles: snapshot.package.files, outcome: outcome)
        XCTAssertTrue(footer.contains("staged=false"))
        XCTAssertFalse(footer.contains("guestRoot="))
    }

    func testUnconfirmedPublishWithUnconfirmedReprobeIsActionableFailure() async throws {
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [false, nil])
        let publisher = ScriptedPublisher(outcome: .unconfirmed)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected actionable failure, got \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix("liveWorkspaceSyncUnconfirmed"),
                      "reason was: \(reason)")
    }

    func testAppliedButProbeStillFalseIsActionableFailure() async throws {
        // The engine claimed the transfer, but the live probe cannot verify
        // it: the model must NOT be told the resource is available.
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [false, false])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected actionable failure, got \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix("liveWorkspaceSyncUnconfirmed"),
                      "reason was: \(reason)")
        XCTAssertTrue(reason.contains("appliedNotVisible"), "reason was: \(reason)")
    }

    // MARK: - Probe authority wins over an uncertain publish

    func testProbeConfirmationWinsOverUnconfirmedPublish() async throws {
        // The transfer's outcome is unknown, but the live probe CAN see the
        // tree (a concurrent import boundary materialized it): the probe is
        // the only visibility authority, so the read reports visible.
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [false, true])
        let publisher = ScriptedPublisher(outcome: .unconfirmed)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertTrue(bundle.visibleInGuest)
    }

    // MARK: - Workspace settled between probe and publish: staged-for-first-use

    func testSettledWorkspaceBetweenProbeAndPublishIsStagedForFirstUse() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [false])
        let publisher = ScriptedPublisher(outcome: .noLiveWorkspace)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged-for-first-use, got \(outcome)")
        }
        XCTAssertFalse(bundle.visibleInGuest)
        XCTAssertEqual(bundle.guestRoot, "/workspace/.floe/skills/hot-guide@\(digest)")
        let asked = await prober.askedPaths()
        XCTAssertEqual(asked.count, 1, "no re-probe after a settled-workspace answer")
    }

    // MARK: - Fail-closed boundaries

    func testLiveWorkspaceWithoutPublisherFailsClosed() async throws {
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [false])
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: nil)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected fail-closed refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.liveWorkspacePublishUnavailable)
    }

    func testNoLiveSessionKeepsColdPathAndNeverPublishes() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [nil])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertFalse(bundle.visibleInGuest)
        let published = await publisher.requestCount()
        XCTAssertEqual(published, 0, "no live workspace: the publish transport is never invoked")
        let footer = SkillWorkspaceResourceStager.resourceFooter(
            id: "hot-guide", pinnedSHA256: digest,
            declaredFiles: snapshot.package.files, outcome: outcome)
        XCTAssertTrue(footer.contains("next workspace import boundary"))
    }

    func testVisibleProbeNeverPublishes() async throws {
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let prober = ScriptedProber(answers: [true])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(), probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertTrue(bundle.visibleInGuest)
        let published = await publisher.requestCount()
        XCTAssertEqual(published, 0)
    }

    // MARK: - Fences around the publish

    func testPrePublishRebindRefusesBeforeAnyPublish() async throws {
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let rebound = root.appendingPathComponent("ReboundWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: rebound, withIntermediateDirectories: true)
        let calls = ResolverCallCounter()
        let prober = ScriptedProber(answers: [false])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in
                let call = await calls.next()
                // Calls 1 (initial) and 2 (pre-rename fence) answer the
                // original root; call 3 is the pre-publish revalidation,
                // which observes the rebound root and must refuse.
                return call <= 2
                    ? .local(workspaceRoot: self.workspace, guestWorkspaceRoot: "/workspace")
                    : .local(workspaceRoot: rebound, guestWorkspaceRoot: "/workspace")
            },
            probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.taskWorkspaceUnavailable)
        let published = await publisher.requestCount()
        XCTAssertEqual(published, 0, "a rebound root never publishes")
        let resolved = await calls.count
        XCTAssertGreaterThanOrEqual(resolved, 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rebound.appendingPathComponent(".floe").path))
    }

    func testLostTargetBeforePublishRefusesHonestly() async throws {
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let calls = ResolverCallCounter()
        let prober = ScriptedProber(answers: [false])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in
                let call = await calls.next()
                return call <= 2
                    ? .local(workspaceRoot: self.workspace, guestWorkspaceRoot: "/workspace")
                    : .unavailable(reason: SkillStageReason.noLocalExecutionTarget)
            },
            probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.noLocalExecutionTarget)
        let published = await publisher.requestCount()
        XCTAssertEqual(published, 0)
    }

    func testCancellationBetweenProbeAndPublishNeverPublishes() async throws {
        let (snapshot, _) = try makeSnapshot(id: "hot-guide")
        let token = CancellationToken()
        let calls = ResolverCallCounter()
        let prober = ScriptedProber(answers: [false])
        let publisher = ScriptedPublisher(outcome: .applied)
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in
                // Calls 1 (initial) and 2 (pre-rename fence) proceed; call 3
                // is the pre-publish revalidation — cancel there, between the
                // probe's definitive false and the publish itself.
                let call = await calls.next()
                if call >= 3 { token.cancel() }
                return .local(workspaceRoot: self.workspace, guestWorkspaceRoot: "/workspace")
            },
            probeVisibility: prober, publishVisibility: publisher)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(),
            context: context(token: token))
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected cancellation, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.cancelled)
        let published = await publisher.requestCount()
        XCTAssertEqual(published, 0)
    }

    // MARK: - Integration box: the publisher follows the generation fence

    func testIntegrationPublisherIsGenerationFenced() async {
        let epoch = UInt64(Date().timeIntervalSince1970)
        let publisher = ScriptedPublisher(outcome: .applied)
        let prober = ScriptedProber(answers: [true])
        let runtime = C02SkillResourceStagingIntegration.install(
            epoch: epoch,
            resolve: { _, _ in .unavailable(reason: "unused") },
            prober: prober,
            publisher: publisher,
            liveEpoch: { epoch })
        defer { C02SkillResourceStagingIntegration.uninstall(epoch: epoch) }
        XCTAssertNotNil(runtime.resourcePublisher())
        XCTAssertTrue(runtime.isLive())
        guard let capturedPublisher = runtime.resourcePublisher(),
              let capturedProber = runtime.visibilityProber() else {
            return XCTFail("Expected live publisher and prober")
        }

        // The live epoch moves on: the SAME runtime object now withholds the
        // publisher (a retired generation can never publish).
        let movedEpoch = epoch &+ 1
        let newer = C02SkillResourceStagingIntegration.install(
            epoch: movedEpoch,
            resolve: { _, _ in .unavailable(reason: "unused") },
            prober: nil,
            publisher: nil,
            liveEpoch: { movedEpoch &+ 1 })
        defer { C02SkillResourceStagingIntegration.uninstall(epoch: movedEpoch) }
        XCTAssertNil(runtime.resourcePublisher())
        XCTAssertNil(newer.resourcePublisher())
        XCTAssertTrue(C02SkillResourceStagingIntegration.current === newer)
        let result = await capturedPublisher.publishStagedBundle(workspaceRoot: workspace,
            runID: UUID(), conversationID: UUID(), cancellation: CancellationToken())
        let visible = await capturedProber.isPathVisible(workspaceRoot: workspace,
            relativePath: ".floe/skills/retired", conversationID: UUID(), cancellation: CancellationToken())
        let published = await publisher.requestCount()
        let probed = await prober.askedPaths()
        XCTAssertEqual(result, .unconfirmed)
        XCTAssertNil(visible)
        XCTAssertEqual(published, 0)
        XCTAssertTrue(probed.isEmpty)
    }

    func testCapturedPublisherDiscardsReplyAfterGenerationMoves() async {
        let epoch: UInt64 = 621
        let publisher = ScriptedPublisher(outcome: .applied, beforeReply: {
            _ = C02SkillResourceStagingIntegration.install(epoch: epoch + 1,
                resolve: { _, _ in .unavailable(reason: "unused") }, prober: nil,
                liveEpoch: { epoch + 1 })
        })
        let runtime = C02SkillResourceStagingIntegration.install(epoch: epoch,
            resolve: { _, _ in .unavailable(reason: "unused") }, prober: nil,
            publisher: publisher, liveEpoch: { epoch })
        defer { C02SkillResourceStagingIntegration.uninstall(epoch: epoch + 1) }
        guard let captured = runtime.resourcePublisher() else {
            return XCTFail("Expected a live publisher")
        }
        let result = await captured.publishStagedBundle(workspaceRoot: workspace, runID: UUID(),
            conversationID: UUID(), cancellation: CancellationToken())
        let dispatched = await publisher.requestCount()
        XCTAssertEqual(dispatched, 1)
        XCTAssertEqual(result, .unconfirmed)
    }

    func testProductionPublisherCannotEnqueueIntoANewerMailbox() async {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 42))
        let publisher = C02LiveGuestResourcePublisher(mailbox: mailbox, acceptedEpoch: 41)
        let result = await publisher.publishStagedBundle(workspaceRoot: workspace, runID: UUID(),
            conversationID: UUID(), cancellation: CancellationToken())
        XCTAssertEqual(result, .unconfirmed)
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)
    }

    // MARK: - REAL publisher over a REAL mailbox (wire contract)

    private func makeMailbox() -> LinuxShellMailbox {
        LinuxShellMailbox(sleeper: { nanoseconds in
            try? await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
        })
    }

    /// Claim + drain one ticket on the "host" side, returning (claim, operation, payload).
    private func claimOne(_ mailbox: LinuxShellMailbox) throws -> (claim: Int64, operation: String, payload: [String: Any]) {
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        var buffer = [CChar](repeating: 0, count: 128)
        let written = mailbox.describe(claim: claim, buffer: &buffer, capacity: 128)
        XCTAssertGreaterThan(written, 0)
        let described = try XCTUnwrap(String(cString: buffer))
        let operation = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(described.utf8))) as? [String: Any])?["operation"] as? String)
        let length = mailbox.payloadLength(claim: claim)
        var payloadBuffer = [UInt8](repeating: 0, count: Int(max(0, length)))
        if length > 0 {
            XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &payloadBuffer, capacity: length), length)
        }
        let object = try JSONSerialization.jsonObject(with: Data(payloadBuffer)) as? [String: Any] ?? [:]
        return (claim, operation, object)
    }

    private func complete(_ mailbox: LinuxShellMailbox, claim: Int64, status: Int32, json: String) {
        var data = Data(json.utf8)
        data.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: claim, status: status,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(data.count)), 0)
        }
    }

    func testPublisherWireShapeAndAppliedMapping() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 41))
        let publisher = C02LiveGuestResourcePublisher(mailbox: mailbox, acceptedEpoch: 41)
        let runID = UUID()
        let replyTask = Task {
            await publisher.publishStagedBundle(
                workspaceRoot: workspace, runID: runID, conversationID: UUID(),
                cancellation: CancellationToken())
        }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "workspace.syncInputs")
        XCTAssertEqual(Set(host.payload.keys), ["projectID", "runID"],
                       "the sync wire payload is exactly {projectID, runID}")
        XCTAssertEqual(host.payload["projectID"] as? String,
                       LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: workspace).uuidString)
        XCTAssertEqual(host.payload["runID"] as? String, runID.uuidString)
        complete(mailbox, claim: host.claim, status: 0, json: #"{"state":"ok","created":2,"retained":5}"#)
        let outcome = await replyTask.value
        XCTAssertEqual(outcome, .applied)
    }

    func testPublisherMapsSettledWorkspaceToStagedForFirstUse() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 42))
        let publisher = C02LiveGuestResourcePublisher(mailbox: mailbox)
        let replyTask = Task {
            await publisher.publishStagedBundle(
                workspaceRoot: workspace, runID: UUID(), conversationID: nil,
                cancellation: CancellationToken())
        }
        let host = try claimOne(mailbox)
        complete(mailbox, claim: host.claim, status: 0,
                 json: #"{"state":"refused","code":"workspaceNotLive"}"#)
        let outcome = await replyTask.value
        XCTAssertEqual(outcome, .noLiveWorkspace)
    }

    func testPublisherMapsBoundedRefusals() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 43))
        let publisher = C02LiveGuestResourcePublisher(mailbox: mailbox)
        let replyTask = Task {
            await publisher.publishStagedBundle(
                workspaceRoot: workspace, runID: UUID(), conversationID: nil,
                cancellation: CancellationToken())
        }
        let host = try claimOne(mailbox)
        complete(mailbox, claim: host.claim, status: 0,
                 json: #"{"state":"refused","code":"budgetExceeded"}"#)
        let outcome = await replyTask.value
        XCTAssertEqual(outcome, .refused(reason: "budgetExceeded"))
    }

    func testPublisherMapsFailedClaimAndMalformedReplyToUnconfirmed() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 44))
        let publisher = C02LiveGuestResourcePublisher(mailbox: mailbox)
        let failedTask = Task {
            await publisher.publishStagedBundle(
                workspaceRoot: workspace, runID: UUID(), conversationID: nil,
                cancellation: CancellationToken())
        }
        let failed = try claimOne(mailbox)
        complete(mailbox, claim: failed.claim, status: 1, json: #"{"code":"runtime_unavailable"}"#)
        let failedOutcome = await failedTask.value
        XCTAssertEqual(failedOutcome, .unconfirmed)

        let malformedTask = Task {
            await publisher.publishStagedBundle(
                workspaceRoot: workspace, runID: UUID(), conversationID: nil,
                cancellation: CancellationToken())
        }
        let malformed = try claimOne(mailbox)
        complete(mailbox, claim: malformed.claim, status: 0, json: #"{"state":"weird"}"#)
        let malformedOutcome = await malformedTask.value
        XCTAssertEqual(malformedOutcome, .unconfirmed)
    }

    func testPublisherCancellationNeverReachesTheWire() async throws {
        let mailbox = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 45))
        let publisher = C02LiveGuestResourcePublisher(mailbox: mailbox)
        let token = CancellationToken()
        token.cancel()
        let outcome = await publisher.publishStagedBundle(
            workspaceRoot: workspace, runID: UUID(), conversationID: nil,
            cancellation: token)
        XCTAssertEqual(outcome, .unconfirmed)
        // Nothing was queued: the host sees no claim at all.
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 100), 0)
    }
}
