// SPDX-License-Identifier: MPL-2.0
//
// N02 claimed task-workspace APK staging — REAL contract tests (authored,
// NOT executed by this lane; no compiler or XCTest run is claimed).
//
// Coverage maps to the completion seam decisions:
//   * PURE policy — CURRENT-run + CURRENT-environment selection, explicit
//     migrated-target (same-runID repin) negatives, post-command
//     no-live-writer snapshot eligibility;
//   * CURRENT-EXPORT receipt scan over a REAL transfer-tree fixture — the
//     one-shot positive, failed-export (conflict/aborted/incomplete)
//     negatives, stale-epoch / foreign-project / other-run negatives, and
//     newest-receipt selection;
//   * STAGER end state over a REAL claimed mailbox ticket — exported
//     snapshot after a completed one-shot (no manual PTY), live-session
//     paging over a fake transport, mid-transfer cancel/fence, path guard
//     mirroring the Kotlin parser, abandoned-inbox sweep.
//
// Every fixture is synthetic/public: temp directories, fake transports and
// fake resolvers only — no device, ADB, root, real APK, private content,
// credential or network target is touched.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeAndroidShellTools
import FloeAndroidWorkspaceTools
@testable import FloeAndroidCore

final class PlatformToolWorkspaceApkStagingTests: XCTestCase, @unchecked Sendable {

    private let taskID = UUID(uuidString: "31000000-0000-4000-8000-000000000031")!
    private let runID = UUID(uuidString: "41000000-0000-4000-8000-000000000041")!
    private let otherRunID = UUID(uuidString: "42000000-0000-4000-8000-000000000042")!
    private let grantID = UUID(uuidString: "51000000-0000-4000-8000-000000000051")!
    private let hostID = UUID(uuidString: "61000000-0000-4000-8000-000000000061")!
    private let epoch: UInt64 = 7

    private var ownedRoot: URL!
    private var workspaceRoot: URL!
    private var transferRoot: URL!
    private var claimedMailboxes: [PlatformToolHostMailbox] = []

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("N02WorkspaceApkStaging-\(UUID().uuidString)",
                                    isDirectory: true)
        ownedRoot = base.appendingPathComponent("owned", isDirectory: true)
        workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true)
        transferRoot = base.appendingPathComponent("WorkspaceTransfers", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workspaceRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: ownedRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for mailbox in claimedMailboxes { mailbox.close(epoch: epoch) }
        claimedMailboxes.removeAll()
        if let ownedRoot {
            try? FileManager.default.removeItem(
                at: ownedRoot.deletingLastPathComponent())
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private final class EpochBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64?
        init(_ value: UInt64?) { self.value = value }
        var current: UInt64? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: UInt64?) { lock.lock(); value = newValue; lock.unlock() }
    }

    private var emptySchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    }

    private func makeEntry(name: String, sideEffecting: Bool = true) -> [String: Any] {
        [
            "name": name,
            "description": "Synthetic public platform tool.",
            "schema": emptySchema,
            "riskLabels": ["writesFiles"],
            "effect": "mutating",
            "isSideEffecting": sideEffecting,
            "hostScope": true,
            "executionBoundary": "mainRunOnly",
            "supportsConcurrentBatchDispatch": false,
        ]
    }

    private func catalogData(_ tools: [[String: Any]]) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["version": 1, "tools": tools], options: [.sortedKeys])
    }

    private func availabilityData(_ names: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: names, options: [.sortedKeys])
    }

    /// A REAL claimed `system.packages.stage` ticket over a REAL test
    /// mailbox: production currency/deadline behavior, isolated registry.
    private func makeClaim(
        tool: String = PlatformToolWorkspaceApkLimits.stageToolName,
        cancel: CancellationToken = CancellationToken()
    ) async -> (mailbox: PlatformToolHostMailbox, context: PlatformToolClaimContext) {
        let registry = ToolRunnerRegistry()
        let box = EpochBox(epoch)
        let mailbox = PlatformToolHostMailbox(
            registry: registry, currentEpoch: { box.current })
        claimedMailboxes.append(mailbox)
        let entryJSON = catalogData([makeEntry(name: tool)])
        XCTAssertEqual(mailbox.bind(epoch: epoch, catalogJSON: entryJSON), 0)
        XCTAssertEqual(mailbox.setAvailability(
            epoch: epoch, namesJSON: availabilityData([tool])), 0)
        XCTAssertTrue(mailbox.bindWorkspaceApkInbox(
            ownedRootPath: ownedRoot.path, epoch: epoch))
        let entry = try! PlatformToolCatalogParser.parse(entryJSON).entries[0]
        let owner = PlatformToolOwner(
            taskID: taskID, runID: runID, epoch: epoch,
            toolCallID: "call-1", toolIdempotencyKey: "idem-1",
            clientSessionID: "session-1", approvalGrantID: grantID,
            scope: .host(hostID))
        let submit = Task {
            try? await mailbox.submit(
                entry: entry, argumentsJSON: Data("{}".utf8),
                owner: owner, cancellation: cancel)
        }
        var claim: Int64 = 0
        for _ in 0..<100 {
            claim = mailbox.nextClaim(timeoutMillis: 20)
            if claim > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(claim, 0)
        let context = try! XCTUnwrap(mailbox.claimedContext(claim: claim))
        _ = submit // retained; the ticket stays claimed for the test lifetime
        return (mailbox, context)
    }

    private struct FakeResolver: PlatformToolWorkspaceApkSourceResolving {
        let outcome: PlatformToolWorkspaceApkResolution
        func resolve(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkResolution {
            outcome
        }
    }

    private actor ChangingResolver: PlatformToolWorkspaceApkSourceResolving {
        let first: PlatformToolWorkspaceApkSource
        let second: PlatformToolWorkspaceApkSource
        private var calls = 0
        init(first: PlatformToolWorkspaceApkSource, second: PlatformToolWorkspaceApkSource) {
            self.first = first
            self.second = second
        }
        func resolve(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkResolution {
            calls += 1
            return .source(calls == 1 ? first : second)
        }
    }

    private struct EmptyTargetResolver: PlatformToolWorkspaceApkTargetResolving {
        func currentTarget(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkTargetFacts? {
            nil
        }
    }

    func testTargetCompositionRejectsLateInstallAndRetiredEpoch() {
        PlatformToolWorkspaceApkTargetComposition.resetForTesting()
        defer { PlatformToolWorkspaceApkTargetComposition.resetForTesting() }
        PlatformToolWorkspaceApkTargetComposition.install(epoch: 20, resolver: EmptyTargetResolver())
        PlatformToolWorkspaceApkTargetComposition.install(epoch: 19, resolver: EmptyTargetResolver())
        XCTAssertNotNil(PlatformToolWorkspaceApkTargetComposition.current(epoch: 20))
        XCTAssertNil(PlatformToolWorkspaceApkTargetComposition.current(epoch: 19))
        PlatformToolWorkspaceApkTargetComposition.uninstall(epoch: 19)
        XCTAssertNotNil(PlatformToolWorkspaceApkTargetComposition.current(epoch: 20))
        PlatformToolWorkspaceApkTargetComposition.uninstall(epoch: 20)
        PlatformToolWorkspaceApkTargetComposition.install(epoch: 20, resolver: EmptyTargetResolver())
        XCTAssertNil(PlatformToolWorkspaceApkTargetComposition.current(epoch: 20))
    }

    private struct FakeTransport: LinuxLiveFilesTransport {
        let pages: [Int64: LinuxLiveFilePage]
        let size: Int64
        let mtimeMillis: Int64
        let revision: String
        var onServe: (@Sendable () -> Void)? = nil

        func filesTree(_ request: LinuxLiveFilesRequest, timeoutMillis: Int) async throws -> LinuxLiveTreeSnapshot {
            throw LinuxLiveFilesError.refused("treeUnsupported")
        }

        func filesRead(_ request: LinuxLiveFilesRequest, timeoutMillis: Int) async throws -> LinuxLiveFilePage {
            onServe?()
            guard let page = pages[request.offset] else {
                throw LinuxLiveFilesError.refused("notFound")
            }
            return page
        }
    }

    private func pagedContent(_ content: Data, pageBytes: Int) -> (transport: FakeTransport, pages: Int) {
        var pages: [Int64: LinuxLiveFilePage] = [:]
        var offset: Int64 = 0
        var index = 0
        let total = content.count
        while offset < total || (total == 0 && index == 0) {
            let end = min(offset + Int64(pageBytes), Int64(total))
            let chunk = content.subdata(in: Int(offset)..<Int(end))
            let truncated = end < Int64(total)
            pages[offset] = LinuxLiveFilePage(
                path: "app.apk", offset: offset, bytes: chunk.count,
                size: Int64(total), mtimeMillis: 1_700_000_000_000,
                digest: FloeDigest.sha256Hex(chunk), content: chunk,
                truncated: truncated, generation: "gen-1",
                consistencyToken: FloeDigest.sha256Hex(Data("tok-\(index)".utf8)),
                fileRevision: "rev-1")
            offset = end
            index += 1
            if total == 0 { break }
        }
        return (FakeTransport(pages: pages, size: Int64(total),
                              mtimeMillis: 1_700_000_000_000, revision: "rev-1"), index)
    }

    private func writeApk(_ bytes: Data, relativePath: String = "app.apk") {
        let url = workspaceRoot.appendingPathComponent(relativePath, isDirectory: false)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! bytes.write(to: url)
    }

    // MARK: - Pure policy: CURRENT run + CURRENT environment selection

    private func facts(sessionID: String, run: UUID?, conversation: UUID?,
                       environment: String = "env-current", generation: String = "gen-1",
                       owner: Bool = false, running: Bool = true,
                       released: Bool = false) -> PlatformToolWorkspaceApkSessionFacts {
        PlatformToolWorkspaceApkSessionFacts(
            sessionID: sessionID, runID: run, conversationID: conversation,
            environmentID: environment, runtimeGeneration: generation,
            workspaceOwner: owner, running: running, leaseReleased: released)
    }

    func testPolicySelectsUniqueWorkspaceOwnerOfCurrentRunAndEnvironment() {
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-current",
            sessions: [
                facts(sessionID: "s-owner", run: runID, conversation: taskID, owner: true),
                facts(sessionID: "s-participant", run: runID, conversation: taskID),
            ])
        XCTAssertEqual(decision, .live(sessionID: "s-owner",
                                       environmentID: "env-current", generation: "gen-1"))
    }

    func testPolicyMigratedTargetSelectsNewEnvironmentSession() {
        // Explicit migration re-pinned this nonterminal run: a session of the
        // CURRENT run admitted under the NEW environment is selected.
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-new",
            sessions: [
                facts(sessionID: "s-new", run: runID, conversation: taskID,
                      environment: "env-new", owner: true),
            ])
        XCTAssertEqual(decision, .live(sessionID: "s-new",
                                       environmentID: "env-new", generation: "gen-1"))
    }

    func testPolicySameRunIDOldEnvironmentSessionIsNeverSelected() {
        // Migrated-target negative: same runID (commitMigration re-pins
        // nonterminal runs), OLD environment. It must NOT be read from, and
        // while it stays live it is an un-exported writer, so the snapshot
        // path refuses too.
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-new",
            sessions: [
                facts(sessionID: "s-old", run: runID, conversation: taskID,
                      environment: "env-old", owner: true),
            ])
        XCTAssertEqual(decision, .refuse(.unavailable))
    }

    func testPolicyPostCommandNoWriterChoosesExportedSnapshot() {
        // The ordinary acceptance shape: the one-shot exec completed, the
        // backend removed the session, nothing is live.
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-current",
            sessions: [])
        XCTAssertEqual(decision, .useExportedSnapshot)
    }

    func testPolicyLiveWriterOfAnotherRunRefusesSnapshot() {
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-current",
            sessions: [
                facts(sessionID: "s-other-run", run: otherRunID,
                      conversation: taskID, environment: "env-current"),
            ])
        XCTAssertEqual(decision, .refuse(.unavailable))
    }

    func testPolicyRefusesAmbiguousParticipantsWithoutOwner() {
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-current",
            sessions: [
                facts(sessionID: "s-1", run: runID, conversation: taskID),
                facts(sessionID: "s-2", run: runID, conversation: taskID),
            ])
        XCTAssertEqual(decision, .refuse(.unavailable))
    }

    func testPolicyRefusesMultipleProvenOwners() {
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-current",
            sessions: [
                facts(sessionID: "s-1", run: runID, conversation: taskID, owner: true),
                facts(sessionID: "s-2", run: runID, conversation: taskID, owner: true),
            ])
        XCTAssertEqual(decision, .refuse(.unavailable))
    }

    func testPolicyIgnoresForeignConversationAndReleasedSessions() {
        let foreign = UUID(uuidString: "32000000-0000-4000-8000-000000000032")!
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(),
            targetEnvironmentID: "env-current",
            sessions: [
                facts(sessionID: "s-foreign", run: runID, conversation: foreign,
                      owner: true),
                facts(sessionID: "s-released", run: runID, conversation: taskID,
                      owner: true, released: true),
                facts(sessionID: "s-terminal", run: runID, conversation: taskID,
                      owner: true, running: false, released: true),
            ])
        XCTAssertEqual(decision, .useExportedSnapshot)
    }

    func testPolicyRefusesTerminalSessionUntilItsExportLeaseIsReleased() {
        let decision = PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner(), targetEnvironmentID: "env-current",
            sessions: [facts(sessionID: "s-exporting", run: runID,
                             conversation: taskID, owner: true, running: false)])
        XCTAssertEqual(decision, .refuse(.unavailable))
    }

    private func owner() -> PlatformToolOwner {
        PlatformToolOwner(
            taskID: taskID, runID: runID, epoch: epoch,
            toolCallID: "call-1", toolIdempotencyKey: "idem-1",
            clientSessionID: "session-1", approvalGrantID: grantID,
            scope: .host(hostID))
    }

    // MARK: - Current-export receipt scan over a REAL transfer tree

    private func writeTerminalSession(
        key: String, projectID: String, run: UUID, rootEpoch: UInt64,
        result: String, partial: Bool = false, terminal: Bool = true,
        indexMtime: Date? = nil
    ) {
        let dir = transferRoot.appendingPathComponent("sessions/\(key)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var marker = WorkspaceOwnerMarker(
            sessionKey: key, grantID: grantID.uuidString.lowercased(),
            projectID: projectID, runID: run.uuidString,
            rootEpoch: rootEpoch, createdAtSeconds: 1_700_000_000)
        try! marker.writeDurable(to: dir.appendingPathComponent("owner.json").path)
        if terminal { try! marker.markTerminal(at: dir.appendingPathComponent("owner.json").path) }
        let index: [String: Any] = [
            "record": "terminalIndex", "sessionKey": key,
            "projectID": projectID, "runID": run.uuidString,
            "result": result, "partial": partial,
        ]
        let indexURL = dir.appendingPathComponent("index.json")
        try! JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: indexURL)
        if let indexMtime {
            try! FileManager.default.setAttributes(
                [.modificationDate: indexMtime], ofItemAtPath: indexURL.path)
        }
    }

    private let projectKey = "71000000-0000-4000-8000-000000000071"
    private var projectIDString: String { projectKey }

    func testReceiptScanAcceptsNewestSyncedTerminalIndex() {
        // The one-shot positive: the completed command's export synced for
        // THIS run, the CURRENT workspace project and the LIVE epoch.
        let key = String(repeating: "a", count: 32)
        writeTerminalSession(key: key, projectID: projectIDString, run: runID,
                             rootEpoch: epoch, result: "synced")
        let receipt = PlatformToolWorkspaceApkProductionResolver
            .scanCurrentSyncedTerminalReceipt(
                transferRoot: transferRoot.path, liveEpoch: epoch,
                workspaceKey: projectIDString, runID: runID)
        XCTAssertEqual(receipt?.sessionKey, key)
        XCTAssertEqual(receipt?.projectID, projectIDString)
        XCTAssertEqual(receipt?.runID, runID.uuidString)
        XCTAssertEqual(receipt?.rootEpoch, epoch)
        XCTAssertEqual(receipt?.indexDigest.count, 64)
    }

    func testReceiptScanRefusesFailedExportConflictWithNoWriter() {
        // No-writer-after-failed-export negative: even with zero live
        // sessions, a conflict result is NEVER current-export proof.
        writeTerminalSession(key: String(repeating: "b", count: 32),
                             projectID: projectIDString, run: runID,
                             rootEpoch: epoch, result: "conflict")
        XCTAssertNil(PlatformToolWorkspaceApkProductionResolver
            .scanCurrentSyncedTerminalReceipt(
                transferRoot: transferRoot.path, liveEpoch: epoch,
                workspaceKey: projectIDString, runID: runID))
    }

    func testReceiptScanRefusesAbortedAndPartialAndIncompleteReceipts() {
        for (result, partial) in [("aborted", false), ("synced", true), ("receiptIncomplete", true)] {
            let key = String(repeating: "c", count: 32)
            writeTerminalSession(key: key, projectID: projectIDString, run: runID,
                                 rootEpoch: epoch, result: result, partial: partial)
            XCTAssertNil(PlatformToolWorkspaceApkProductionResolver
                .scanCurrentSyncedTerminalReceipt(
                    transferRoot: transferRoot.path, liveEpoch: epoch,
                    workspaceKey: projectIDString, runID: runID),
                "result=\(result) partial=\(partial) must refuse")
            try! FileManager.default.removeItem(
                at: transferRoot.appendingPathComponent("sessions/\(key)", isDirectory: true))
        }
    }

    func testReceiptScanRefusesStaleEpochForeignProjectAndOtherRun() {
        writeTerminalSession(key: String(repeating: "d", count: 32),
                             projectID: projectIDString, run: runID,
                             rootEpoch: epoch - 1, result: "synced")
        writeTerminalSession(key: String(repeating: "e", count: 32),
                             projectID: "72000000-0000-4000-8000-000000000072", run: runID,
                             rootEpoch: epoch, result: "synced")
        writeTerminalSession(key: String(repeating: "f", count: 32),
                             projectID: projectIDString, run: otherRunID,
                             rootEpoch: epoch, result: "synced")
        writeTerminalSession(key: String(repeating: "0", count: 32),
                             projectID: projectIDString, run: runID,
                             rootEpoch: epoch, result: "synced", terminal: false)
        XCTAssertNil(PlatformToolWorkspaceApkProductionResolver
            .scanCurrentSyncedTerminalReceipt(
                transferRoot: transferRoot.path, liveEpoch: epoch,
                workspaceKey: projectIDString, runID: runID))
    }

    func testReceiptScanPicksNewestMatchingSyncedReceipt() {
        let olderKey = String(repeating: "1", count: 32)
        let newerKey = String(repeating: "2", count: 32)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(3_600)
        writeTerminalSession(key: olderKey, projectID: projectIDString, run: runID,
                             rootEpoch: epoch, result: "synced", indexMtime: old)
        writeTerminalSession(key: newerKey, projectID: projectIDString, run: runID,
                             rootEpoch: epoch, result: "synced", indexMtime: new)
        let receipt = PlatformToolWorkspaceApkProductionResolver
            .scanCurrentSyncedTerminalReceipt(
                transferRoot: transferRoot.path, liveEpoch: epoch,
                workspaceKey: projectIDString, runID: runID)
        XCTAssertEqual(receipt?.sessionKey, newerKey)
    }

    // MARK: - Stager end state over a REAL claimed ticket

    func testReceiptScanNeverFallsBackPastANewerFailedExportWithinOneSecond() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        writeTerminalSession(key: String(repeating: "3", count: 32),
                             projectID: projectIDString, run: runID, rootEpoch: epoch,
                             result: "synced", indexMtime: instant.addingTimeInterval(0.1))
        writeTerminalSession(key: String(repeating: "4", count: 32),
                             projectID: projectIDString, run: runID, rootEpoch: epoch,
                             result: "conflict", indexMtime: instant.addingTimeInterval(0.8))
        XCTAssertNil(PlatformToolWorkspaceApkProductionResolver.scanCurrentSyncedTerminalReceipt(
            transferRoot: transferRoot.path, liveEpoch: epoch,
            workspaceKey: projectIDString, runID: runID))
    }

    func testReceiptScanAcceptsRecoveryOnlyAfterANewerSuccessfulExport() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        writeTerminalSession(key: String(repeating: "5", count: 32),
                             projectID: projectIDString, run: runID, rootEpoch: epoch,
                             result: "conflict", indexMtime: instant)
        let key = String(repeating: "6", count: 32)
        writeTerminalSession(key: key, projectID: projectIDString, run: runID,
                             rootEpoch: epoch, result: "synced",
                             indexMtime: instant.addingTimeInterval(1))
        XCTAssertEqual(PlatformToolWorkspaceApkProductionResolver.scanCurrentSyncedTerminalReceipt(
            transferRoot: transferRoot.path, liveEpoch: epoch,
            workspaceKey: projectIDString, runID: runID)?.sessionKey, key)
    }

    func testReceiptScanRefusesIndistinguishableNewestExports() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        for character in ["7", "8"] {
            writeTerminalSession(key: String(repeating: character, count: 32),
                                 projectID: projectIDString, run: runID,
                                 rootEpoch: epoch, result: "synced", indexMtime: instant)
        }
        XCTAssertNil(PlatformToolWorkspaceApkProductionResolver.scanCurrentSyncedTerminalReceipt(
            transferRoot: transferRoot.path, liveEpoch: epoch,
            workspaceKey: projectIDString, runID: runID))
    }

    func testStageExportedSnapshotAfterCompletedOneShotNoManualPTY() async {
        // THE acceptance flow: exec.shell downloaded the APK and completed;
        // no manual PTY exists; the current-export receipt proved current;
        // staging reads the exported snapshot and commits digest-named bytes.
        let bytes = Data((0..<60_000).map { UInt8($0 % 251) })
        writeApk(bytes)
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("app.apk".utf8),
            resolver: resolver, transport: nil, inbox: inbox,
            liveConversationProbe: { false },
            epochReader: { self.epoch })
        guard case .success(let metadata) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(metadata.sha256, FloeDigest.sha256Hex(bytes))
        XCTAssertEqual(metadata.sizeBytes, Int64(bytes.count))
        XCTAssertEqual(metadata.absolutePath,
                       inbox!.path + "/" + metadata.sha256 + ".apk")
        XCTAssertEqual(try! Data(contentsOf: URL(fileURLWithPath: metadata.absolutePath)),
                       bytes)
        // Reply shape: bounded metadata JSON only.
        let reply = try! JSONSerialization.jsonObject(
            with: Data(PlatformToolWorkspaceApkStager.replyJSON(metadata)!.utf8)) as! [String: Any]
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["sha256"] as? String, metadata.sha256)
        // No partial litter.
        let names = try! FileManager.default.contentsOfDirectory(atPath: inbox!.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
    }

    func testStageExportedRefusesWhenPostReadProbeFindsAWriter() async {
        let bytes = Data((0..<1_000).map { UInt8($0 % 251) })
        writeApk(bytes)
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("app.apk".utf8),
            resolver: resolver, transport: nil, inbox: inbox,
            liveConversationProbe: { true },   // a session became live mid-read
            epochReader: { self.epoch })
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged, got \(result)")
        }
        let names = try! FileManager.default.contentsOfDirectory(atPath: inbox!.path)
        XCTAssertTrue(names.allSatisfy { !$0.hasSuffix(".part") && !$0.hasSuffix(".apk") },
                      "partial must be discarded, nothing committed")
    }

    func testStageExportedRefusesMissingSourceAndCleansPartial() async {
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("missing.apk".utf8),
            resolver: resolver, transport: nil, inbox: inbox,
            liveConversationProbe: { false },
            epochReader: { self.epoch })
        guard case .failure(.notFound) = result else {
            return XCTFail("expected notFound, got \(result)")
        }
        let names = try! FileManager.default.contentsOfDirectory(atPath: inbox!.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
    }

    func testStageExportedRefusesSymlinkSource() async {
        let bytes = Data((0..<500).map { UInt8($0 % 251) })
        writeApk(bytes)
        let link = workspaceRoot.appendingPathComponent("linked.apk")
        try! FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: workspaceRoot.appendingPathComponent("app.apk"))
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("linked.apk".utf8),
            resolver: resolver, transport: nil, inbox: inbox,
            liveConversationProbe: { false },
            epochReader: { self.epoch })
        // O_NOFOLLOW: a symlink shape never stages (ELOOP -> invalidArguments).
        guard case .failure(.invalidArguments) = result else {
            return XCTFail("expected invalidArguments, got \(result)")
        }
    }

    func testStageExportedRefusesIntermediateDirectorySymlinks() async throws {
        let outside = ownedRoot.deletingLastPathComponent()
            .appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("other-task-bytes".utf8).write(to: outside.appendingPathComponent("source.apk"))
        try FileManager.default.createSymbolicLink(
            at: workspaceRoot.appendingPathComponent("alias"), withDestinationURL: outside)
        let (mailbox, context) = await makeClaim()
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context, relativePathUTF8: Data("alias/source.apk".utf8),
            resolver: FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
                workspaceKey: projectIDString,
                origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path)))),
            transport: nil, inbox: mailbox.workspaceApkInboxBinding(),
            liveConversationProbe: { false }, epochReader: { self.epoch })
        guard case .failure(.invalidArguments) = result else {
            return XCTFail("intermediate symlink escaped the workspace: \(result)")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: mailbox.workspaceApkInboxBinding()!.path).isEmpty)
    }

    func testStageExportedRefusesSameSizePathReplacement() async throws {
        let original = Data(repeating: 0x31, count: 2048)
        let replacement = Data(repeating: 0x32, count: original.count)
        writeApk(original)
        let (mailbox, context) = await makeClaim()
        let sourcePath = workspaceRoot.appendingPathComponent("app.apk")
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context, relativePathUTF8: Data("app.apk".utf8),
            resolver: FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
                workspaceKey: projectIDString,
                origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path)))),
            transport: nil, inbox: mailbox.workspaceApkInboxBinding(),
            liveConversationProbe: {
                try! replacement.write(to: sourcePath, options: .atomic)
                return false
            }, epochReader: { self.epoch })
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("an old open inode was committed after path replacement: \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: sourcePath), replacement)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: mailbox.workspaceApkInboxBinding()!.path).isEmpty)
    }

    func testStageRefusesTargetRepinBeforePublication() async throws {
        writeApk(Data(repeating: 0x33, count: 2048))
        let (mailbox, context) = await makeClaim()
        let origin = PlatformToolWorkspaceApkSource.Origin.exportedSnapshot(
            workspaceRootPath: workspaceRoot.path)
        let rootHash = FloeDigest.sha256Hex(Data(workspaceRoot.path.utf8))
        let initial = PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString, origin: origin,
            target: PlatformToolWorkspaceApkTargetFacts(
                environmentID: "same-environment", shellRootHash: rootHash,
                revision: 1, localLinux: true))
        let replacement = PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString, origin: origin,
            target: PlatformToolWorkspaceApkTargetFacts(
                environmentID: "same-environment", shellRootHash: rootHash,
                revision: 2, localLinux: true))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context, relativePathUTF8: Data("app.apk".utf8),
            resolver: ChangingResolver(first: initial, second: replacement),
            transport: nil, inbox: mailbox.workspaceApkInboxBinding(),
            liveConversationProbe: { false }, epochReader: { self.epoch })
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("a source from an earlier target revision was published: \(result)")
        }
    }

    func testStageLiveStreamsPagedContentOverFakeTransport() async {
        let content = Data((0..<50_000).map { UInt8($0 % 253) })
        let (transport, pageCount) = pagedContent(content, pageBytes: 24 * 1024)
        XCTAssertGreaterThan(pageCount, 1)
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .liveSession(sessionID: "engine-1", environmentID: "env-current",
                                 generation: "gen-1"))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("app.apk".utf8),
            resolver: resolver, transport: transport, inbox: inbox,
            epochReader: { self.epoch })
        guard case .success(let metadata) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(metadata.sha256, FloeDigest.sha256Hex(content))
        XCTAssertEqual(metadata.sizeBytes, Int64(content.count))
    }

    func testStageLiveRefusesRacedPageDigest() async {
        let content = Data((0..<50_000).map { UInt8($0 % 253) })
        let pageBytes = 24 * 1024
        var (transport, pageCount) = pagedContent(content, pageBytes: pageBytes)
        XCTAssertGreaterThan(pageCount, 1)
        // Corrupt the second page digest: the transfer must refuse mid-loop.
        var pages = transport.pages
        if let second = pages[Int64(pageBytes)] {
            pages[Int64(pageBytes)] = LinuxLiveFilePage(
                path: second.path, offset: second.offset, bytes: second.bytes,
                size: second.size, mtimeMillis: second.mtimeMillis,
                digest: String(repeating: "0", count: 64), content: second.content,
                truncated: second.truncated, generation: second.generation,
                consistencyToken: second.consistencyToken,
                fileRevision: second.fileRevision)
        }
        transport = FakeTransport(pages: pages, size: transport.size,
                                  mtimeMillis: transport.mtimeMillis,
                                  revision: transport.revision)
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .liveSession(sessionID: "engine-1", environmentID: "env-current",
                                 generation: "gen-1"))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("app.apk".utf8),
            resolver: resolver, transport: transport, inbox: inbox,
            epochReader: { self.epoch })
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged, got \(result)")
        }
        let names = try! FileManager.default.contentsOfDirectory(atPath: inbox!.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
    }

    func testStageCancelledMidTransferDiscardsPartial() async {
        let content = Data((0..<50_000).map { UInt8($0 % 253) })
        let cancel = CancellationToken()
        var (transport, _) = pagedContent(content, pageBytes: 24 * 1024)
        transport = FakeTransport(
            pages: transport.pages, size: transport.size,
            mtimeMillis: transport.mtimeMillis, revision: transport.revision,
            onServe: { cancel.cancel() })
        let (mailbox, context) = await makeClaim(cancel: cancel)
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: self.projectIDString,
            origin: .liveSession(sessionID: "engine-1", environmentID: "env-current",
                                 generation: "gen-1"))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("app.apk".utf8),
            resolver: resolver, transport: transport, inbox: inbox,
            epochReader: { self.epoch })
        guard case .failure(.cancelled) = result else {
            return XCTFail("expected cancelled, got \(result)")
        }
        let names = try! FileManager.default.contentsOfDirectory(atPath: inbox!.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
    }

    // MARK: - Path guard (mirror of the Kotlin parser; grants nothing)

    func testPathGuardRefusesWidenedShapes() async {
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .refused(.noConfig))
        let bad = [
            "/absolute/app.apk",
            "../app.apk",
            "a/../../app.apk",
            "a/./b.apk",
            "a//b.apk",
            "a\\b.apk",
            "app.txt",
            "a/" + String(repeating: "x", count: 256) + "/app.apk",
            String(repeating: "seg/", count: 33) + "app.apk",
            "app.apk\0junk",
        ]
        for path in bad {
            let result = await PlatformToolWorkspaceApkStager.stage(
                context: context,
                relativePathUTF8: Data(path.utf8),
                resolver: resolver, transport: nil, inbox: inbox,
                epochReader: { self.epoch })
            guard case .failure(.invalidArguments) = result else {
                return XCTFail("expected invalidArguments for \(path), got \(result)")
            }
        }
        // Empty input and non-UTF8 refuse too.
        for data in [Data(), Data([0xFF, 0xFE])] {
            let result = await PlatformToolWorkspaceApkStager.stage(
                context: context,
                relativePathUTF8: data,
                resolver: resolver, transport: nil, inbox: inbox,
                epochReader: { self.epoch })
            guard case .failure(.invalidArguments) = result else {
                return XCTFail("expected invalidArguments for non-UTF8/empty, got \(result)")
            }
        }
    }

    func testPathGuardAcceptsNestedApk() async {
        let bytes = Data((0..<100).map { UInt8($0) })
        writeApk(bytes, relativePath: "nested/dir/app.apk")
        let (mailbox, context) = await makeClaim()
        let inbox = mailbox.workspaceApkInboxBinding()
        let resolver = FakeResolver(outcome: .source(PlatformToolWorkspaceApkSource(
            workspaceKey: projectIDString,
            origin: .exportedSnapshot(workspaceRootPath: workspaceRoot.path))))
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: Data("nested/dir/app.apk".utf8),
            resolver: resolver, transport: nil, inbox: inbox,
            liveConversationProbe: { false },
            epochReader: { self.epoch })
        guard case .success(let metadata) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(metadata.sha256, FloeDigest.sha256Hex(bytes))
    }

    // MARK: - Mailbox additions (context, currency, inbox binding)

    func testClaimedContextIsMintedOnlyForLiveClaimedTicket() async {
        let (mailbox, context) = await makeClaim()
        XCTAssertEqual(context.claim > 0, true)
        XCTAssertEqual(context.toolName, PlatformToolWorkspaceApkLimits.stageToolName)
        XCTAssertEqual(context.owner.taskID, taskID)
        XCTAssertEqual(context.currency(), .current)
        XCTAssertFalse(context.expired)
        // Settled / unknown claims refuse.
        XCTAssertNil(mailbox.claimedContext(claim: context.claim + 999))
        XCTAssertEqual(mailbox.complete(claim: context.claim, status: 1,
                                        value: Data(#"{"code":"cancelled"}"#.utf8)), 0)
        XCTAssertEqual(context.currency(), .fenced)
    }

    func testClaimCurrencyReportsCancelVersusFence() async {
        let cancel = CancellationToken()
        let (_, context) = await makeClaim(cancel: cancel)
        XCTAssertEqual(context.currency(), .current)
        cancel.cancel()
        XCTAssertEqual(context.currency(), .cancelled)
    }

    func testInboxBindIsGenerationScopedAndRefusesSymlinkComponents() {
        let box = EpochBox(epoch)
        let mailbox = PlatformToolHostMailbox(
            registry: ToolRunnerRegistry(), currentEpoch: { box.current })
        // A non-standardized (traversal) path fails RuntimeStorageRoot
        // validation before any filesystem effect.
        XCTAssertFalse(mailbox.bindWorkspaceApkInbox(
            ownedRootPath: ownedRoot.path + "/../escape", epoch: epoch))
        XCTAssertTrue(mailbox.bindWorkspaceApkInbox(
            ownedRootPath: ownedRoot.path, epoch: epoch))
        // Same-epoch idempotent rebind of the identical root.
        XCTAssertTrue(mailbox.bindWorkspaceApkInbox(
            ownedRootPath: ownedRoot.path, epoch: epoch))
        // A symlinked FloeAgent component refuses.
        let evilBase = ownedRoot.deletingLastPathComponent()
            .appendingPathComponent("evil-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: evilBase, withIntermediateDirectories: true)
        let symlinkTarget = evilBase.deletingLastPathComponent()
            .appendingPathComponent("symlink-target-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: symlinkTarget, withIntermediateDirectories: true)
        let evilFloe = evilBase.appendingPathComponent("FloeAgent", isDirectory: false)
        try! FileManager.default.createSymbolicLink(
            at: evilFloe, withDestinationURL: symlinkTarget)
        XCTAssertFalse(mailbox.bindWorkspaceApkInbox(
            ownedRootPath: evilBase.path, epoch: epoch))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: symlinkTarget.appendingPathComponent("WorkspaceApkInbox").path))
        // Epoch fence: a different epoch refuses and retires cleanly.
        XCTAssertNotNil(mailbox.workspaceApkInboxBinding())
        mailbox.retireWorkspaceApkInbox(epoch: epoch)
        XCTAssertNil(mailbox.workspaceApkInboxBinding())
    }

    // MARK: - Abandoned-inbox sweep

    func testSweepRemovesOnlyOwnedStaleFiles() throws {
        let inbox = PlatformToolWorkspaceApkInboxBinding(
            path: ownedRoot.appendingPathComponent("FloeAgent/WorkspaceApkInbox").path,
            epoch: epoch)
        try! FileManager.default.createDirectory(
            at: URL(fileURLWithPath: inbox.path, isDirectory: true),
            withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -(25 * 60 * 60))
        let recent = Date()
        let names = [
            ".stage-9-old.part",
            String(repeating: "a", count: 64) + ".apk",
            "foreign.txt",
            ".stage-9-fresh.part",
            String(repeating: "b", count: 63) + ".apk",   // wrong length: not owned
        ]
        for (index, name) in names.enumerated() {
            let url = URL(fileURLWithPath: inbox.path, isDirectory: true)
                .appendingPathComponent(name)
            try! Data([UInt8(index)]).write(to: url)
            try! FileManager.default.setAttributes(
                [.modificationDate: index < 2 ? old : recent], ofItemAtPath: url.path)
        }
        let removed = PlatformToolWorkspaceApkStager.sweepAbandoned(
            inbox: inbox, now: Date(), epochReader: { self.epoch })
        XCTAssertEqual(removed, [".stage-9-old.part",
                                 String(repeating: "a", count: 64) + ".apk"])
        let remaining = try! FileManager.default.contentsOfDirectory(atPath: inbox.path)
        XCTAssertEqual(Set(remaining), ["foreign.txt", ".stage-9-fresh.part",
                                        String(repeating: "b", count: 63) + ".apk"])
        // Epoch fence: sweep is a no-op under a stale epoch.
        let fenced = PlatformToolWorkspaceApkStager.sweepAbandoned(
            inbox: inbox, now: Date(), epochReader: { self.epoch + 1 })
        XCTAssertTrue(fenced.isEmpty)
    }
}
