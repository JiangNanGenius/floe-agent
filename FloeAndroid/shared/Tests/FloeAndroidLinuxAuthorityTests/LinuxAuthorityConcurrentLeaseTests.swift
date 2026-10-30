// SPDX-License-Identifier: MPL-2.0
//
// G07.3A focused authority regressions (authored, not executed by this job).
//
// The runtime UID now admits a BOUNDED set of independent workloads (two human
// interactive terminals + one shared Agent/run execution slot). These
// tests run the ORIGINAL FloeEnvironments registry/coordinator/resolver on the
// host against synthetic engine-private roots — no device, no backend process,
// no model and no real App data. They pin the admission ceiling, role isolation,
// exact-lease cancellation and the configuration lock; they deliberately do NOT
// claim anything about a real PTY, which belongs to Main's device batch.

import XCTest
import Foundation
import FloeCore
import FloeEnvironments
@testable import FloeAndroidLinuxAuthority

final class LinuxAuthorityConcurrentLeaseTests: XCTestCase {
    private var scratch: URL!
    private var stateRoot: String { scratch.appendingPathComponent("state").path }
    private var workspacesRoot: String { scratch.appendingPathComponent("workspaces").path }
    private var baseRoot: String { scratch.appendingPathComponent("base").path }
    private var authority: FloeLinuxAuthority!
    private let baseRevision = "g073a-concurrency-test-base"

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("FloeAndroidAuthorityConcurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch = base
        authority = FloeLinuxAuthority()
        _ = try await authority.configure(.init(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                               baseRoot: baseRoot, baseRevision: baseRevision))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private func acquire(_ role: LinuxAuthorityLeaseRole, conversation: UUID = UUID(),
                         environment: String? = nil) async throws -> LinuxAuthorityAcquireInfo {
        let request = LinuxAuthorityAcquireRequest(
            projectID: UUID().uuidString,
            runID: UUID().uuidString,
            conversationID: conversation.uuidString,
            environmentID: environment,
            leaseRole: role.rawValue)
        return try await authority.acquire(request)
    }

    private func error(for operation: () async throws -> Any) async -> LinuxAuthorityErrorCode? {
        do { _ = try await operation(); return nil }
        catch let error as LinuxAuthorityError { return error.code }
        catch { return .internalError }
    }

    private func finish(_ info: LinuxAuthorityAcquireInfo, pid: Int) async throws {
        let identity = LinuxAuthorityProcessIdentity(pid: pid, pgid: pid + 1,
                                                     launcherToken: "launch-\(pid)",
                                                     startedAtUnixMillis: 1_760_000_000_000)
        _ = try await authority.markStarted(.init(leaseID: info.leaseID, processIdentity: identity))
        _ = try await authority.complete(.init(leaseID: info.leaseID, processIdentity: identity,
                                              quiescence: .init(exitStatus: 0, reaped: true)))
    }

    func testTwoInteractivePlusOneAgentAreAdmittedConcurrentlyWithDistinctLeases() async throws {
        let first = try await acquire(.interactive)
        let second = try await acquire(.interactive)
        let agent = try await acquire(.agent)

        XCTAssertFalse(first.leaseID == second.leaseID)
        XCTAssertFalse(first.leaseID == agent.leaseID)
        XCTAssertFalse(second.leaseID == agent.leaseID)
        XCTAssertEqual(first.leaseRole, "interactive")
        XCTAssertEqual(second.leaseRole, "interactive")
        XCTAssertEqual(agent.leaseRole, "agent")
        XCTAssertFalse(first.descriptor.environmentID == second.descriptor.environmentID,
                          "two interactive sessions keep independent session environments")

        let handshake = await authority.handshake()
        XCTAssertTrue(handshake.activeLease)
        XCTAssertEqual(handshake.activeLeases, 3)
        XCTAssertEqual(handshake.maxInteractiveLeases, 2)
        XCTAssertEqual(handshake.maxAgentLeases, 1)
        XCTAssertEqual(handshake.maxExecutionLeases, 1)
        XCTAssertEqual(handshake.maxConcurrentRuntimeLeases, 3)

        try await finish(agent, pid: 7001)
        try await finish(first, pid: 7002)
        try await finish(second, pid: 7003)
    }

    func testThirdInteractiveAndSecondAgentAreRefusedBeforeAnyLeaseExists() async throws {
        _ = try await acquire(.interactive)
        _ = try await acquire(.interactive)
        let thirdInteractive = await error { try await self.acquire(.interactive) }
        XCTAssertEqual(thirdInteractive, .leaseBusy)

        let firstAgent = try await acquire(.agent)
        let secondAgent = await error { try await self.acquire(.agent) }
        XCTAssertEqual(secondAgent, .leaseBusy)
        // The approved default SHARES one execution slot between the Agent
        // command and a language/run session; both may not be live at once.
        let runWhileAgent = await error { try await self.acquire(.run) }
        XCTAssertEqual(runWhileAgent, .leaseBusy)

        // Cancelling the FIRST agent (exact lease) must not release or disturb
        // either interactive lease; once its real terminal is attested, a new
        // Agent command can be admitted. Cancel alone NEVER frees the slot.
        let identity = LinuxAuthorityProcessIdentity(pid: 7100, pgid: 7101,
                                                     launcherToken: "launch-7100",
                                                     startedAtUnixMillis: nil)
        _ = try await authority.markStarted(.init(leaseID: firstAgent.leaseID, processIdentity: identity))
        _ = try await authority.cancel(.init(leaseID: firstAgent.leaseID))
        let retained = await error { try await self.acquire(.agent) }
        XCTAssertEqual(retained, .leaseBusy, "a cancelled-but-unreleased lease still owns its slot")
        _ = try await authority.complete(.init(leaseID: firstAgent.leaseID, processIdentity: identity,
                                               quiescence: .init(exitStatus: 0, reaped: true)))
        let replacement = try await acquire(.agent)
        XCTAssertEqual(replacement.leaseRole, "agent")
        try await finish(replacement, pid: 7101)
    }

    func testCancellingOneInteractiveLeaseNeverAffectsTheOther() async throws {
        let first = try await acquire(.interactive)
        let second = try await acquire(.interactive)
        let firstIdentity = LinuxAuthorityProcessIdentity(pid: 7201, pgid: 7202,
                                                          launcherToken: "launch-7201",
                                                          startedAtUnixMillis: nil)
        _ = try await authority.markStarted(.init(leaseID: first.leaseID, processIdentity: firstIdentity))
        _ = try await authority.cancel(.init(leaseID: first.leaseID))

        // The second lease still accepts its own markStarted/complete; the
        // first can only finish through the exact identity + attestation.
        let secondIdentity = LinuxAuthorityProcessIdentity(pid: 7301, pgid: 7302,
                                                           launcherToken: "launch-7301",
                                                           startedAtUnixMillis: nil)
        _ = try await authority.markStarted(.init(leaseID: second.leaseID, processIdentity: secondIdentity))
        _ = try await authority.complete(.init(leaseID: second.leaseID, processIdentity: secondIdentity,
                                               quiescence: .init(exitStatus: 0, reaped: true)))
        let firstComplete = try await authority.complete(.init(
            leaseID: first.leaseID, processIdentity: firstIdentity,
            quiescence: .init(exitStatus: 0, reaped: true)))
        XCTAssertEqual(firstComplete.state, "released")
    }

    func testConfigurationReplacementIsRefusedWhileConcurrentLeasesAreRetained() async throws {
        _ = try await acquire(.interactive)
        _ = try await acquire(.agent)
        let code = await error {
            try await self.authority.configure(.init(stateRoot: self.stateRoot,
                                                     workspacesRoot: self.workspacesRoot,
                                                     baseRoot: self.baseRoot,
                                                     baseRevision: "different-revision"))
        }
        XCTAssertEqual(code, .configurationLockedByLease)
        // An IDENTICAL configure stays an idempotent no-op even while held.
        let identical = try await authority.configure(.init(stateRoot: stateRoot,
                                                            workspacesRoot: workspacesRoot,
                                                            baseRoot: baseRoot,
                                                            baseRevision: baseRevision))
        XCTAssertFalse(identical.replaced)
    }

    func testUnknownRoleIsRejectedBeforeAdmission() async throws {
        let request = LinuxAuthorityAcquireRequest(
            projectID: UUID().uuidString, runID: UUID().uuidString,
            conversationID: UUID().uuidString, environmentID: nil, leaseRole: "root")
        let code = await error { try await self.authority.acquire(request) }
        XCTAssertEqual(code, .invalidIdentifier)
        let handshake = await authority.handshake()
        XCTAssertEqual(handshake.activeLeases, 0)
    }

    func testLegacyRolelessAcquireKeepsSingleAgentAdmission() async throws {
        let project = UUID()
        let first = LinuxAuthorityAcquireRequest(projectID: project.uuidString,
                                                 runID: UUID().uuidString,
                                                 conversationID: UUID().uuidString,
                                                 environmentID: nil)
        _ = try await authority.acquire(first)
        let second = await error { try await self.authority.acquire(first) }
        XCTAssertEqual(second, .leaseBusy,
                       "an un-opted caller keeps the historical single-slot behaviour")
    }
}
