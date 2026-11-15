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

final class RGSSLinuxGuestLocalServiceJobServiceTests: XCTestCase {
    func testFixedLauncherRunsThroughLocalService() async throws {
        let root = try temporaryDirectory()
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: root)
        ])
        let host = FakeLocalServiceController()
        let service = RGSSLinuxGuestLocalServiceJobService(
            services: host, pathMap: { _ in map })
        let log = root.appendingPathComponent("run.log")
        try Data().write(to: log)
        let launch = RGSSGuestJobLaunch(
            environmentID: "env-1", ownerToken: UUID(), jobID: UUID(),
            argv: ["/floe/env/opt/floe/rgss/bin/tapir-x", "-d", "/workspace/run"],
            workingDirectory: "/workspace/run", logFile: log,
            environment: ["DISPLAY": ":0", "HOME": "/floe/env/home", "PWD": "/workspace/run"])
        let handle = try await service.startOwnedJob(launch)
        XCTAssertEqual(handle.jobID, launch.jobID)
        let request = await host.lastRequest
        XCTAssertEqual(request?.runtime, .shell)
        XCTAssertEqual(request?.arguments, [launch.argv[0], launch.argv[2]])
        XCTAssertEqual(request?.workingDirectory, root.appendingPathComponent("run").path)
        let launcher = root.appendingPathComponent("run/floe-rgss-launch.sh")
        let script = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(script.contains("exec \"$engine\" -d \"$project\""))
        XCTAssertFalse(script.contains("tapir-x"), "project data is not interpolated into the script")

        let status = try await service.jobStatus(handle)
        XCTAssertEqual(status.state, .running(frameRevision: 0))
        try await service.stopOwnedJob(handle)
        let stopCount = await host.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testInvalidShellArgumentsAreRejectedBeforeServiceStart() async throws {
        let root = try temporaryDirectory()
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: root)
        ])
        let host = FakeLocalServiceController()
        let service = RGSSLinuxGuestLocalServiceJobService(
            services: host, pathMap: { _ in map })
        let launch = RGSSGuestJobLaunch(
            environmentID: "env-1", ownerToken: UUID(), jobID: UUID(),
            argv: ["/bin/sh", "-c", "curl evil"], workingDirectory: "/workspace/run",
            logFile: root.appendingPathComponent("run.log"),
            environment: ["DISPLAY": ":0", "HOME": "/floe/env/home", "PWD": "/workspace/run"])
        do {
            _ = try await service.startOwnedJob(launch)
            XCTFail("shell argv must be rejected")
        } catch let error as RGSSLinuxGuestJobError {
            guard case .invalidLaunch = error else { return XCTFail("unexpected \(error)") }
        }
        let count = await host.startCount
        XCTAssertEqual(count, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rgss-local-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FakeLocalServiceController: LinuxGuestLocalServiceControlling {
    private(set) var lastRequest: LinuxGuestLocalServiceRequest?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var state = "running"

    func startLocalService(environmentID: String,
                           request: LinuxGuestLocalServiceRequest,
                           cancellation: CancellationToken?) async throws
        -> LinuxGuestLocalServiceHandle {
        startCount += 1
        lastRequest = request
        return LinuxGuestLocalServiceHandle(
            token: UUID().uuidString, environmentID: environmentID,
            runtime: request.runtime, pid: 77, port: request.port,
            forward: LinuxGuestServiceForward(hostPort: UInt16(request.port),
                                              guestPort: UInt16(request.port)),
            logHostPath: request.logFile.path,
            logGuestPath: "/workspace/run.log",
            startedAt: Date())
    }

    func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async
        -> LinuxGuestLocalServiceSnapshot {
        .init(state: state, pid: 77, alive: state == "running")
    }

    func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async {
        stopCount += 1
        state = "stopped"
    }

    func stopLocalServices(environmentID: String) async {}
    func activeLocalServiceCount(environmentID: String) async -> Int { 0 }
}
