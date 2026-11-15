// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeExecution
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeGameRGSSHostLinux
import FloeTools

final class RGSSLinuxGuestOwnedJobServiceTests: XCTestCase {
    func testStartStatusAndStopUseOnlyTheOwnedReceipt() async throws {
        let host = FakeLinuxGuestHost()
        let workspace = try temporaryDirectory()
        let log = workspace.appendingPathComponent("run.log")
        try Data().write(to: log)
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)
        ])
        let service = RGSSLinuxGuestOwnedJobService(
            host: host,
            pathMap: { _ in map },
            timeout: 5)
        let owner = UUID()
        let jobID = UUID()
        let launch = RGSSGuestJobLaunch(
            environmentID: "env-1", ownerToken: owner, jobID: jobID,
            argv: ["/floe/env/opt/floe/rgss/bin/tapir-x", "-d", "/workspace/run"],
            workingDirectory: "/workspace/run",
            logFile: log,
            environment: ["DISPLAY": ":0", "HOME": "/floe/env/home", "PWD": "/workspace/run"])
        let handle = try await service.startOwnedJob(launch)
        XCTAssertEqual(handle.jobID, jobID)
        XCTAssertEqual(handle.ownerToken, owner)
        let spawned = await host.spawned
        XCTAssertEqual(spawned?.argv, launch.argv)
        XCTAssertEqual(spawned?.workingDirectory, "/workspace/run")
        XCTAssertEqual(spawned?.logPath, "/workspace/run.log")

        let status = try await service.jobStatus(handle)
        XCTAssertEqual(status.state, .running(frameRevision: 0))

        try await service.stopOwnedJob(handle)
        let stopCount = await host.stopCount
        XCTAssertEqual(stopCount, 1)
        let stopReceiptPID = await host.lastStopReceipt?.pid
        XCTAssertEqual(stopReceiptPID, 44)
    }

    func testUnrecognizedArgsFailClosedWithoutSpawning() async throws {
        let host = FakeLinuxGuestHost()
        let workspace = try temporaryDirectory()
        let log = workspace.appendingPathComponent("run.log")
        try Data().write(to: log)
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)
        ])
        let service = RGSSLinuxGuestOwnedJobService(host: host, pathMap: { _ in map })
        let launch = RGSSGuestJobLaunch(
            environmentID: "env-1", ownerToken: UUID(), jobID: UUID(),
            argv: ["/bin/sh", "-c", "curl evil"],
            workingDirectory: "/workspace/run", logFile: log,
            environment: ["DISPLAY": ":0", "HOME": "/floe/env/home", "PWD": "/workspace/run"])
        do {
            _ = try await service.startOwnedJob(launch)
            XCTFail("shell argv must be rejected")
        } catch let error as RGSSLinuxGuestJobError {
            guard case .invalidLaunch = error else { return XCTFail("unexpected \(error)") }
        }
        let spawnCount = await host.spawnCount
        XCTAssertEqual(spawnCount, 0)
    }

    func testStopRejectsAHandleWithAnotherOwner() async throws {
        let host = FakeLinuxGuestHost()
        let workspace = try temporaryDirectory()
        let log = workspace.appendingPathComponent("run.log")
        try Data().write(to: log)
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)
        ])
        let service = RGSSLinuxGuestOwnedJobService(host: host, pathMap: { _ in map })
        let jobID = UUID()
        let launch = RGSSGuestJobLaunch(
            environmentID: "env-1", ownerToken: UUID(), jobID: jobID,
            argv: ["/floe/env/opt/floe/rgss/bin/tapir-v", "-d", "/workspace/run"],
            workingDirectory: "/workspace/run", logFile: log,
            environment: ["DISPLAY": ":0", "HOME": "/floe/env/home", "PWD": "/workspace/run"])
        _ = try await service.startOwnedJob(launch)
        do {
            try await service.stopOwnedJob(RGSSGuestJobHandle(jobID: jobID, ownerToken: UUID()))
            XCTFail("a different owner must not stop the job")
        } catch let error as RGSSLinuxGuestJobError {
            XCTAssertEqual(error, .notOwned)
        }
        let stopCount = await host.stopCount
        XCTAssertEqual(stopCount, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rgss-linux-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FakeLinuxGuestHost: LinuxGuestLocalServiceHosting {
    struct Spawn: Sendable, Equatable {
        let argv: [String]
        let workingDirectory: String?
        let logPath: String
    }
    private(set) var spawned: Spawn?
    private(set) var spawnCount = 0
    private(set) var stopCount = 0
    private(set) var lastStopReceipt: LinuxGuestServiceProcessReceipt?
    private var state: LinuxGuestServiceProcessState = .running

    func supports(environmentID: String) async -> Bool { true }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }

    func run(environmentID: String, argv: [String], workingDirectory: String?,
             standardInput: String?, timeout: TimeInterval, maxOutputBytes: Int,
             cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        .init(stdout: "", stderr: "", exitCode: 0)
    }
    func run(environmentID: String, argv: [String], workingDirectory: String?,
             standardInput: String?, deadline: ShellExecutionDeadline,
             maxOutputBytes: Int,
             cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        .init(stdout: "", stderr: "", exitCode: 0)
    }

    func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor? {
        nil
    }
    func guestSpawn(environmentID: String, argv: [String], workingDirectory: String?,
                    logPath: String, timeout: TimeInterval,
                    cancellation: CancellationToken?) async throws -> Int32 {
        44
    }
    func guestServiceAlive(environmentID: String, pid: Int32,
                           timeout: TimeInterval) async throws -> Bool {
        state == .running
    }
    func guestKillService(environmentID: String, pid: Int32,
                          timeout: TimeInterval) async throws -> Bool { true }
    func guestEnsureForward(environmentID: String,
                            forward: LinuxGuestServiceForward) async throws {}
    func guestRemoveForward(environmentID: String,
                            forward: LinuxGuestServiceForward) async {}

    func guestSpawnOwnedService(environmentID: String, argv: [String],
                                workingDirectory: String?, logPath: String,
                                timeout: TimeInterval,
                                cancellation: CancellationToken?) async throws
        -> LinuxGuestServiceProcessReceipt {
        spawnCount += 1
        spawned = Spawn(argv: argv, workingDirectory: workingDirectory, logPath: logPath)
        return LinuxGuestServiceProcessReceipt(
            environmentID: environmentID, generation: 1, pid: 44)
    }
    func guestOwnedServiceState(_ process: LinuxGuestServiceProcessReceipt,
                                timeout: TimeInterval) async throws
        -> LinuxGuestServiceProcessState {
        state
    }
    func guestStopOwnedService(_ process: LinuxGuestServiceProcessReceipt,
                               timeout: TimeInterval) async throws -> Bool {
        stopCount += 1
        lastStopReceipt = process
        state = .exited
        return true
    }
    func guestEnsureOwnedServiceForward(_ process: LinuxGuestServiceProcessReceipt,
                                        forward: LinuxGuestServiceForward) async throws {}
    func guestReleaseOwnedService(_ process: LinuxGuestServiceProcessReceipt,
                                  forward: LinuxGuestServiceForward) async -> Bool { true }
}
