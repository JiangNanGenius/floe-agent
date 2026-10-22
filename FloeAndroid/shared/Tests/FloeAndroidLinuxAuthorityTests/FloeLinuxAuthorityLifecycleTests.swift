// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 focused host checks for the Linux authority lease lifecycle
// (job-9c0066307afe460f). These tests run the ORIGINAL FloeEnvironments
// authority (registry/coordinator/resolver) end-to-end on the macOS host
// against synthetic engine-private roots in a task-owned scratch directory —
// no device, no backend process, no model call, no real App data. Scratch is
// deliberately NOT under the process temp directory: the production root
// policy forbids temp-based roots, and the fixtures must prove that rule.

import XCTest
import Foundation
import FloeCore
import FloeEnvironments
@testable import FloeAndroidLinuxAuthority

// MARK: - Concurrent-call helpers

private func acquireOutcome(_ authority: FloeLinuxAuthority,
                            _ request: LinuxAuthorityAcquireRequest) async -> Result<LinuxAuthorityAcquireInfo, LinuxAuthorityError> {
    do { return .success(try await authority.acquire(request)) }
    catch let error as LinuxAuthorityError { return .failure(error) }
    catch { return .failure(LinuxAuthorityError(code: .internalError, message: "\(error)")) }
}

private func configureOutcome(_ authority: FloeLinuxAuthority,
                              _ request: LinuxAuthorityConfigureRequest) async -> Result<LinuxAuthorityConfigureInfo, LinuxAuthorityError> {
    do { return .success(try await authority.configure(request)) }
    catch let error as LinuxAuthorityError { return .failure(error) }
    catch { return .failure(LinuxAuthorityError(code: .internalError, message: "\(error)")) }
}

private func code(of result: Result<LinuxAuthorityAcquireInfo, LinuxAuthorityError>) -> LinuxAuthorityErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

private func code(of result: Result<LinuxAuthorityConfigureInfo, LinuxAuthorityError>) -> LinuxAuthorityErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

extension LinuxAuthorityAcquireRequest {
    func copySettingRun(_ value: String) -> LinuxAuthorityAcquireRequest {
        LinuxAuthorityAcquireRequest(projectID: projectID, runID: value, conversationID: conversationID, environmentID: environmentID)
    }
    func copySettingEnvironment(_ value: String) -> LinuxAuthorityAcquireRequest {
        LinuxAuthorityAcquireRequest(projectID: projectID, runID: runID, conversationID: conversationID, environmentID: value)
    }
}

final class FloeLinuxAuthorityLifecycleTests: XCTestCase {
    private var scratch: URL!
    private var stateRoot: String { scratch.appendingPathComponent("state").path }
    private var workspacesRoot: String { scratch.appendingPathComponent("workspaces").path }
    private var baseRoot: String { scratch.appendingPathComponent("base").path }
    private var authority: FloeLinuxAuthority!

    private let baseRevision = "g03-r2-test-base"

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("FloeAndroidLinuxAuthorityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch = base
        authority = FloeLinuxAuthority()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func standardConfigure() async throws -> LinuxAuthorityConfigureInfo {
        try await authority.configure(.init(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                            baseRoot: baseRoot, baseRevision: baseRevision))
    }

    private func acquireRequest(project: UUID = UUID(), run: UUID = UUID(),
                                conversation: UUID? = nil, environment: String? = nil) -> LinuxAuthorityAcquireRequest {
        LinuxAuthorityAcquireRequest(projectID: project.uuidString, runID: run.uuidString,
                                     conversationID: conversation?.uuidString, environmentID: environment)
    }

    private func identity(pid: Int = 4242, pgid: Int? = 4200, token: String = "launch-a") -> LinuxAuthorityProcessIdentity {
        LinuxAuthorityProcessIdentity(pid: pid, pgid: pgid, launcherToken: token, startedAtUnixMillis: 1_760_000_000_000)
    }

    private func errorCodes(_ block: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async -> LinuxAuthorityErrorCode? {
        do {
            _ = try await block()
            return nil
        } catch let error as LinuxAuthorityError {
            return error.code
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
            return .internalError
        }
    }

    /// Bound + attest + complete one acquired lease.
    private func completeLease(_ info: LinuxAuthorityAcquireInfo, pid: Int = Int.random(in: 1000...9999)) async throws {
        let process = identity(pid: pid)
        _ = try await authority.markStarted(.init(leaseID: info.leaseID, processIdentity: process))
        _ = try await authority.complete(.init(leaseID: info.leaseID, processIdentity: process,
                                              quiescence: .init(exitStatus: 0, reaped: true)))
    }

    // MARK: - Configuration

    func testConfigureHappyPathEchoesCanonicalRootsAndIsIdempotent() async throws {
        let info = try await standardConfigure()
        XCTAssertEqual(info.stateRoot, LinuxAuthorityRootPolicy.posixRealpath(stateRoot))
        XCTAssertEqual(info.workspacesRoot, LinuxAuthorityRootPolicy.posixRealpath(workspacesRoot))
        XCTAssertEqual(info.baseRoot, LinuxAuthorityRootPolicy.posixRealpath(baseRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot))
        let again = try await authority.configure(.init(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                                        baseRoot: baseRoot, baseRevision: baseRevision))
        XCTAssertEqual(again.replaced, false)
        let list = try await authority.list()
        XCTAssertEqual(list.baseRevision, baseRevision)
        XCTAssertTrue(list.environments.contains { $0.id == EnvironmentRegistry.sharedContainerID
            && $0.kind == "shared" && $0.executionBackend == "linuxPRoot" },
            "the shared container must be created by the ORIGINAL registry with the explicit Android backend")
    }

    func testConfigureRejectsMalformedAndForbiddenRoots() async throws {
        let cases: [(String, String, LinuxAuthorityErrorCode)] = [
            ("Library/Caches/relative-state-root", "relative", .invalidRoot),
            ("./dotted-state-root", "dot-prefixed relative", .invalidRoot),
            (stateRoot + "/", "trailing slash", .invalidRoot),
            (stateRoot + "/../state2", "non-normalized", .invalidRoot),
            ("/tmp/floe-authority-test-root", "tmp ancestor", .rootLocationForbidden),
            ("/private/tmp/floe-authority-test-root", "private tmp ancestor", .rootLocationForbidden),
            ("/data/local/tmp/floe-root", "shell staging ancestor", .rootLocationForbidden),
            ("/storage/emulated/0/floe-root", "external storage ancestor", .rootLocationForbidden),
            ("/sdcard/floe-root", "sdcard ancestor", .rootLocationForbidden),
            ("/mnt/floe-root", "mount ancestor", .rootLocationForbidden),
            ("/data", "bare data dir", .rootLocationForbidden),
            ("/", "filesystem root", .invalidRoot),
            ("/nonexistent-parent-9a7c/child", "missing parent", .rootParentMissing),
            (workspacesRoot, "root equals another root", .rootContainmentViolation),
        ]
        for (badRoot, label, expected) in cases {
            let code = await errorCodes {
                try await self.authority.configure(.init(stateRoot: badRoot, workspacesRoot: self.workspacesRoot,
                                                          baseRoot: self.baseRoot, baseRevision: self.baseRevision))
            }
            XCTAssertEqual(code, expected, "case \(label)")
        }
        // Nothing was ever left configured by the rejected attempts.
        let handshake = await authority.handshake()
        XCTAssertEqual(handshake.configured, false)
        // And no forbidden leaf was created (the /tmp case fails before FS work).
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/floe-authority-test-root"))
    }

    func testConfigureRejectsBadBaseRevision() async {
        let revisions = ["", " ", "a\u{0001}b", String(repeating: "r", count: 65)]
        for revision in revisions {
            let code = await errorCodes {
                try await self.authority.configure(.init(stateRoot: self.stateRoot, workspacesRoot: self.workspacesRoot,
                                                          baseRoot: self.baseRoot, baseRevision: revision))
            }
            XCTAssertEqual(code, .invalidBaseRevision, "revision \(revision.debugDescription)")
        }
    }

    func testConfigureNormalizesSymlinkedRootAndRejectsAncestorContainment() async throws {
        let fileManager = FileManager.default
        let realDir = scratch.appendingPathComponent("real-state", isDirectory: true)
        try fileManager.createDirectory(at: realDir, withIntermediateDirectories: true)
        let linkPath = scratch.appendingPathComponent("state-link").path
        try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: realDir.path)
        // An ancestor symlink is accepted and NORMALIZED to realpath (Android
        // /data/user equivalence stays usable; the authority owns the
        // canonical location it echoes back).
        let info = try await authority.configure(.init(stateRoot: linkPath, workspacesRoot: workspacesRoot,
                                                       baseRoot: baseRoot, baseRevision: baseRevision))
        XCTAssertEqual(info.stateRoot, LinuxAuthorityRootPolicy.posixRealpath(realDir.path))
        try? await standardConfigureUnforced()

        // A root nested inside another configured root is refused.
        let nested = scratch.appendingPathComponent("state/ws-inside-state").path
        let code = await errorCodes {
            try await self.authority.configure(.init(stateRoot: self.stateRoot, workspacesRoot: nested,
                                                      baseRoot: self.baseRoot, baseRevision: self.baseRevision))
        }
        XCTAssertEqual(code, .rootContainmentViolation)
    }

    private func standardConfigureUnforced() async throws {
        _ = try? await authority.configure(.init(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                                 baseRoot: baseRoot, baseRevision: baseRevision))
    }

    // MARK: - Acquisition through the ORIGINAL authority

    func testProjectAcquireCarriesFullDescriptorAuthority() async throws {
        try await standardConfigure()
        let project = UUID()
        let run = UUID()
        let info = try await authority.acquire(acquireRequest(project: project, run: run))
        let descriptor = info.descriptor

        let canonicalWorkspaces = try XCTUnwrap(LinuxAuthorityRootPolicy.posixRealpath(workspacesRoot))
        XCTAssertEqual(descriptor.runID, run.uuidString)
        XCTAssertNil(descriptor.conversationID)
        XCTAssertEqual(descriptor.workspaceRoot, canonicalWorkspaces + "/" + project.uuidString)
        XCTAssertEqual(descriptor.backend, "linuxPRoot")
        XCTAssertEqual(descriptor.baseRevision, baseRevision)
        XCTAssertEqual(descriptor.workspaceID, FloeDigest.sha256Hex(Data(descriptor.workspaceRoot.utf8)))
        XCTAssertFalse(descriptor.environmentID.isEmpty)
        XCTAssertEqual(descriptor.projectContainerID, descriptor.environmentID, "no conversation → the project record itself")

        // The ORIGINAL registry now owns the record; metadata agrees.
        let list = try await authority.list()
        let projectRecord = try XCTUnwrap(list.environments.first { $0.id == descriptor.environmentID })
        XCTAssertEqual(projectRecord.kind, "project")
        XCTAssertEqual(projectRecord.ownerID, descriptor.workspaceID)
        XCTAssertEqual(projectRecord.executionBackend, "linuxPRoot")
        XCTAssertEqual(projectRecord.state, "active")

        // Lookup order (NOT overlay): the writable layer first, then shared,
        // then the base root handed to the original coordinator.
        XCTAssertEqual(descriptor.orderedLayers.last, LinuxAuthorityRootPolicy.posixRealpath(baseRoot))
        XCTAssertGreaterThan(descriptor.orderedLayers.count, 1)
        XCTAssertEqual(descriptor.writableLayer, descriptor.orderedLayers.first)
        XCTAssertTrue(descriptor.home.hasPrefix(descriptor.writableLayer))
        XCTAssertTrue(descriptor.tmp.hasPrefix(descriptor.writableLayer))
        for variable in ["FLOE_ENVIRONMENT_ID", "HOME", "TMPDIR", "PATH", "PYTHONPATH", "NODE_PATH"] {
            XCTAssertNotNil(descriptor.variables[variable], "validated ToolEnvironment variables must survive")
        }
        XCTAssertEqual(descriptor.variables["FLOE_ENVIRONMENT_ID"], descriptor.environmentID)
    }

    func testConversationAcquireYieldsSessionOwnership() async throws {
        try await standardConfigure()
        let conversation = UUID()
        let info = try await authority.acquire(acquireRequest(conversation: conversation))
        let list = try await authority.list()
        let session = try XCTUnwrap(list.environments.first { $0.id == info.descriptor.environmentID })
        XCTAssertEqual(session.kind, "session")
        XCTAssertEqual(session.ownerID, conversation.uuidString)
        XCTAssertEqual(info.descriptor.conversationID, conversation.uuidString)
        XCTAssertNotEqual(info.descriptor.projectContainerID, info.descriptor.environmentID,
                          "the project container is the session's parent, never the session itself")
        try await completeLease(info)
    }

    func testLowercaseCanonicalUUIDInputsNormalizeToUppercaseWorkspace() async throws {
        try await standardConfigure()
        let project = UUID()
        let lower = LinuxAuthorityAcquireRequest(
            projectID: project.uuidString.lowercased(),
            runID: project.uuidString.lowercased(),
            conversationID: nil, environmentID: nil)
        let info = try await authority.acquire(lower)
        XCTAssertEqual((info.descriptor.workspaceRoot as NSString).lastPathComponent, project.uuidString, "canonical uppercase directory")
        XCTAssertEqual(info.descriptor.runID, project.uuidString)
        try await completeLease(info)
    }

    func testNonCanonicalUUIDAndEnvironmentIDSchemataFailClosed() async throws {
        try await standardConfigure()
        let code = await errorCodes {
            try await self.authority.acquire(self.acquireRequest().copySettingRun("not-a-uuid"))
        }
        XCTAssertEqual(code, .invalidUUID)
        let traversal = await errorCodes {
            try await self.authority.acquire(self.acquireRequest().copySettingEnvironment("../../escape"))
        }
        XCTAssertEqual(traversal, .invalidIdentifier)
        let tooLong = await errorCodes {
            try await self.authority.acquire(self.acquireRequest().copySettingEnvironment(String(repeating: "e", count: 65)))
        }
        XCTAssertEqual(tooLong, .invalidIdentifier)
    }

    func testWorkspaceSymlinkEscapeFailsClosed() async throws {
        try await standardConfigure()
        let project = UUID()
        let canonicalWorkspacesForEscape = try XCTUnwrap(LinuxAuthorityRootPolicy.posixRealpath(workspacesRoot))
        let expected = canonicalWorkspacesForEscape + "/" + project.uuidString
        let elsewhere = scratch.appendingPathComponent("escape-target", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // A planted symlink where the canonical workspace must live is NOT an
        // acceptable workspace location (would break owner-hash binding).
        try FileManager.default.createSymbolicLink(atPath: expected, withDestinationPath: elsewhere.path)
        let code = await errorCodes { try await self.authority.acquire(self.acquireRequest(project: project)) }
        XCTAssertEqual(code, .workspaceUnavailable)
    }

    // MARK: - Global one-lease + reentrancy (Main concurrent fixtures)

    func testSecondAcquireIsGloballyBusyWhileLeaseIsHeld() async throws {
        try await standardConfigure()
        let first = try await authority.acquire(acquireRequest())
        let busy = await errorCodes { try await self.authority.acquire(self.acquireRequest()) }
        XCTAssertEqual(busy, .leaseBusy)
        let handshake = await authority.handshake()
        XCTAssertEqual(handshake.activeLease, true)
        XCTAssertEqual(handshake.leaseAdmissionPending, false)
        try await completeLease(first)
        _ = try await authority.acquire(acquireRequest())
    }

    func testConcurrentAcquiresAdmitExactlyOneGlobalLease() async throws {
        try await standardConfigure()
        // Bind Sendable values locally: `async let` may not capture the
        // non-Sendable XCTestCase self (Swift 6 region isolation).
        let target: FloeLinuxAuthority = authority
        let requestA = acquireRequest()
        let requestB = acquireRequest()
        async let first = acquireOutcome(target, requestA)
        async let second = acquireOutcome(target, requestB)
        let outcomes = await [first, second]
        let successes = outcomes.compactMap { outcome -> LinuxAuthorityAcquireInfo? in
            if case .success(let value) = outcome { return value }
            return nil
        }
        let failures = outcomes.compactMap { outcome -> LinuxAuthorityErrorCode? in code(of: outcome) }
        XCTAssertEqual(successes.count, 1, "reservation must precede the resolver await: \(outcomes)")
        XCTAssertEqual(failures, [LinuxAuthorityErrorCode.leaseBusy])
        if let held = successes.first { try await completeLease(held) }
    }

    func testConcurrentAcquireVersusConfigurationReplacementAreExclusive() async throws {
        try await standardConfigure()
        let target: FloeLinuxAuthority = authority
        let acquireRequestValue = acquireRequest()
        let replacement = LinuxAuthorityConfigureRequest(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                                         baseRoot: baseRoot, baseRevision: "g03-r2-mid-replace")
        async let acquireResult = acquireOutcome(target, acquireRequestValue)
        async let configureResult = configureOutcome(target, replacement)
        let (a, c) = await (acquireResult, configureResult)
        let acquireSuccess = code(of: a) == nil
        let configureSuccess = code(of: c) == nil
        XCTAssertNotEqual(acquireSuccess, configureSuccess,
                          "exactly one of acquire/replacement-config may succeed: a-code=\(String(describing: code(of: a))) c-code=\(String(describing: code(of: c)))")
        if let error = code(of: a) {
            XCTAssertEqual(error, LinuxAuthorityErrorCode.configurationInFlight, "acquire must refuse while configure applies")
        }
        if let error = code(of: c) {
            XCTAssertEqual(error, LinuxAuthorityErrorCode.configurationLockedByLease, "replacement must refuse while admission is reserved")
        }
        if acquireSuccess, let held = try? a.get() { try await completeLease(held) }
        let handshake = await authority.handshake()
        XCTAssertEqual(handshake.activeLease, false)
        XCTAssertEqual(handshake.leaseAdmissionPending, false)
        XCTAssertEqual(handshake.configurationInFlight, false)
    }

    // MARK: - Lifecycle: bind, cancel-retain, complete, abandon

    func testFullStartedLeaseLifecycleRetainsUntilAttestedCompletion() async throws {
        try await standardConfigure()
        let info = try await authority.acquire(acquireRequest(conversation: UUID()))
        let leaseID = info.leaseID
        let process = identity()

        _ = try await authority.markStarted(.init(leaseID: leaseID, processIdentity: process))
        // Second bind: idempotent for identical, refused for different.
        _ = try await authority.markStarted(.init(leaseID: leaseID, processIdentity: process))
        let different = await errorCodes {
            try await self.authority.markStarted(.init(leaseID: leaseID, processIdentity: self.identity(pid: 9999)))
        }
        XCTAssertEqual(different, .processIdentityMismatch)

        // Cancellation REQUESTS cooperate but NEVER releases: the lease, the
        // busy slot and the configuration lock all persist.
        let cancel = try await authority.cancel(.init(leaseID: leaseID))
        XCTAssertEqual(cancel.state, "cancelRequested")
        XCTAssertEqual(cancel.started, true)
        XCTAssertEqual(cancel.released, false)
        let busyWhileCancelRetained = await errorCodes { try await self.authority.acquire(self.acquireRequest()) }
        XCTAssertEqual(busyWhileCancelRetained, .leaseBusy)
        let replaceLock = await errorCodes {
            try await self.authority.configure(.init(stateRoot: self.stateRoot, workspacesRoot: self.workspacesRoot,
                                                     baseRoot: self.baseRoot, baseRevision: "locked-revision"))
        }
        XCTAssertEqual(replaceLock, .configurationLockedByLease)

        // Wrong completion paths before the real one.
        let wrongPid = await errorCodes {
            try await self.authority.complete(.init(leaseID: leaseID, processIdentity: self.identity(pid: 1),
                                                    quiescence: .init(exitStatus: 0, reaped: true)))
        }
        XCTAssertEqual(wrongPid, .processIdentityMismatch)
        let notReaped = await errorCodes {
            try await self.authority.complete(.init(leaseID: leaseID, processIdentity: process,
                                                    quiescence: .init(exitStatus: 0, reaped: false)))
        }
        XCTAssertEqual(notReaped, .quiescenceNotAcknowledged)
        let outOfRange = await errorCodes {
            try await self.authority.complete(.init(leaseID: leaseID, processIdentity: process,
                                                    quiescence: .init(exitStatus: 70_000, reaped: true)))
        }
        XCTAssertEqual(outOfRange, .quiescenceNotAcknowledged)
        // A started holder can NEVER be abandoned — the no-process abandon is
        // strictly distinct from attested completion of a started process.
        let abandonAfterStart = await errorCodes { try await self.authority.abandon(.init(leaseID: leaseID)) }
        XCTAssertEqual(abandonAfterStart, .abandonRefusedAfterStart)

        let done = try await authority.complete(.init(leaseID: leaseID, processIdentity: process,
                                                     quiescence: .init(exitStatus: 1, reaped: true)))
        XCTAssertEqual(done.state, "released")
        XCTAssertEqual(done.leaseHandedBack, true)
        // Idempotent retry via the bounded terminal ledger.
        let retry = try await authority.complete(.init(leaseID: leaseID, processIdentity: process,
                                                      quiescence: .init(exitStatus: 1, reaped: true)))
        XCTAssertEqual(retry.leaseHandedBack, false)
        // Slot is free again.
        _ = try await authority.acquire(acquireRequest())
    }

    func testAbandonOnlyForNeverStartedHolders() async throws {
        try await standardConfigure()
        let info = try await authority.acquire(acquireRequest())
        // complete BEFORE any bind: not a completion, must use abandon.
        let earlyComplete = await errorCodes {
            try await self.authority.complete(.init(leaseID: info.leaseID, processIdentity: self.identity(),
                                                    quiescence: .init(exitStatus: 0, reaped: true)))
        }
        XCTAssertEqual(earlyComplete, .leaseNotStarted)

        let abandoned = try await authority.abandon(.init(leaseID: info.leaseID))
        XCTAssertEqual(abandoned.state, "abandoned")
        XCTAssertEqual(abandoned.released, true)
        // Idempotent retry.
        let retry = try await authority.abandon(.init(leaseID: info.leaseID))
        XCTAssertEqual(retry.released, false)
        // Cross-kind terminal use is a typed leaseNotFound.
        let crossed = await errorCodes {
            try await self.authority.complete(.init(leaseID: info.leaseID, processIdentity: self.identity(),
                                                    quiescence: .init(exitStatus: 0, reaped: true)))
        }
        XCTAssertEqual(crossed, .leaseNotFound)
        _ = try await authority.acquire(acquireRequest())
    }

    func testIdentityShapeFailClosedAndUnknownLeases() async throws {
        try await standardConfigure()
        let info = try await authority.acquire(acquireRequest())
        let badPid = await errorCodes {
            try await self.authority.markStarted(.init(leaseID: info.leaseID, processIdentity: self.identity(pid: 0)))
        }
        XCTAssertEqual(badPid, .invalidProcessIdentity)
        let whitespaceToken = await errorCodes {
            try await self.authority.markStarted(.init(leaseID: info.leaseID,
                                                       processIdentity: self.identity(token: "space y")))
        }
        XCTAssertEqual(whitespaceToken, .invalidProcessIdentity)
        let unknown = LinuxAuthorityLeaseRequest(leaseID: UUID().uuidString)
        let unknownCancel = await errorCodes { try await self.authority.cancel(unknown) }
        XCTAssertEqual(unknownCancel, .leaseNotFound)
        let bogus = await errorCodes { try await self.authority.cancel(.init(leaseID: "nope")) }
        XCTAssertEqual(bogus, .invalidUUID)
        _ = try await authority.abandon(.init(leaseID: info.leaseID))
    }

    // MARK: - Explicit environment addressing through the ORIGINAL gates

    func testExplicitEnvironmentAddressingFailsClosedAcrossOwners() async throws {
        try await standardConfigure()
        let conversation = UUID()
        let first = try await authority.acquire(acquireRequest(conversation: conversation))
        let sessionEnvironmentID = first.descriptor.environmentID
        let projectEnvironmentID = first.descriptor.projectContainerID
        try await completeLease(first)

        let unknown = await errorCodes {
            try await self.authority.acquire(self.acquireRequest(environment: "550e8400-e29b-41d4-a716-446655440000"))
        }
        XCTAssertEqual(unknown, .environmentNotFound)

        let nilConversationSession = await errorCodes {
            try await self.authority.acquire(self.acquireRequest(environment: sessionEnvironmentID))
        }
        XCTAssertEqual(nilConversationSession, .sessionRequiresConversation)

        let foreign = await errorCodes {
            try await self.authority.acquire(self.acquireRequest(conversation: UUID(), environment: sessionEnvironmentID))
        }
        XCTAssertEqual(foreign, .foreignConversation)

        let foreignWorkspaceProject = await errorCodes {
            try await self.authority.acquire(self.acquireRequest(project: UUID(), environment: projectEnvironmentID))
        }
        XCTAssertEqual(foreignWorkspaceProject, .authorityRejected,
                       "the ORIGINAL coordinator owner-hash check refuses cross-workspace addressing")
    }

    func testConfigurationReplacementKeepsRegistryContinuityAndBlocksUntilRebuilt() async throws {
        try await standardConfigure()
        let first = try await authority.acquire(acquireRequest())
        let projectID = first.descriptor.environmentID
        let projectWorkspace = (first.descriptor.workspaceRoot as NSString).lastPathComponent
        try await completeLease(first)

        let replaced = try await authority.configure(.init(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                                           baseRoot: baseRoot, baseRevision: "g03-r2-next-base"))
        XCTAssertEqual(replaced.replaced, true)
        let list = try await authority.list()
        XCTAssertEqual(list.baseRevision, "g03-r2-next-base")
        let carried = try XCTUnwrap(list.environments.first { $0.id == projectID },
                                    "the ORIGINAL registry reloaded the SAME record from disk")
        XCTAssertEqual(carried.requiresRebuild, true, "incompatible base revision is the registry's own rebuild gate")
        XCTAssertNotNil(carried.rebuildReason)
        let blocked: LinuxAuthorityErrorCode? = await errorCodes {
            try await self.authority.acquire(self.acquireRequest(project: try XCTUnwrap(UUID(uuidString: projectWorkspace))))
        }
        XCTAssertEqual(blocked, .authorityRejected, "a requiresRebuild record must not acquire")
    }

    // MARK: - Metadata-only list + capability truth over the wire

    func testListOverWireExposesMetadataOnly() async throws {
        try await standardConfigure()
        let info = try await authority.acquire(acquireRequest(conversation: UUID()))
        let request = LinuxAuthorityRequest(version: 1, requestID: "list-1", operation: .list)
        let encoded = try JSONEncoder().encode(request)
        let replyData = await authority.exchange(encoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        let outcome = try XCTUnwrap(object["outcome"] as? [String: Any])
        let ok = try XCTUnwrap(outcome["ok"] as? [String: Any])
        let list = try XCTUnwrap(ok["list"] as? [String: Any])
        let environments = try XCTUnwrap(list["environments"] as? [[String: Any]])
        XCTAssertFalse(environments.isEmpty)
        let allowed: Set<String> = ["id", "kind", "ownerID", "name", "state", "baseRevision",
                                    "requiresRebuild", "rebuildReason", "executionBackend",
                                    "bytes", "packageCount", "parentID", "templateID"]
        for environment in environments {
            XCTAssertEqual(Set(environment.keys).subtracting(allowed), [],
                           "list must never leak layer paths or variables: \(environment.keys)")
            for leak in ["orderedLayers", "variables", "writableLayer", "workspaceRoot"] {
                XCTAssertNil(environment[leak])
            }
        }
        try await completeLease(info)
    }

    func testHandshakeCapabilityTruthStaysFalseWithRecordsPresent() async throws {
        try await standardConfigure()
        let info = try await authority.acquire(acquireRequest())
        let request = LinuxAuthorityRequest(version: 1, requestID: nil, operation: .handshake)
        let reply = await authority.exchange(try JSONEncoder().encode(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let payload = try XCTUnwrap((((object["outcome"] as? [String: Any])?["ok"] as? [String: Any])?["handshake"] as? [String: Any]))
        XCTAssertEqual(payload["execShellReady"] as? Bool, false, "registry existence is NOT exec.shell readiness")
        XCTAssertEqual(payload["activeLease"] as? Bool, true)
        try await completeLease(info)
    }
}
