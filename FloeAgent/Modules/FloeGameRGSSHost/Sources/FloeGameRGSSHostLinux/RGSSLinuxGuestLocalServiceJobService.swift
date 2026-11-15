// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeExecution
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeTools

/// Alternative `RGSSGuestJobService` over the App's existing
/// `LinuxGuestLocalServiceControlling` facade (`exec.localService`), for hosts
/// that expose the facade rather than the registry-level owned-process API.
///
/// It creates a fixed, host-staged launcher inside the owned run directory:
///
///   #!/bin/sh
///   set -eu
///   exec "$1" -d "$2"
///
/// The engine path and run directory are validated guest paths passed as
/// separate argv entries. There is no model/project text in the command, no
/// shell interpolation of project data and no additional execution alias.
public actor RGSSLinuxGuestLocalServiceJobService: RGSSGuestJobService {
    private struct Record: Sendable {
        let jobHandle: RGSSGuestJobHandle
        let serviceHandle: LinuxGuestLocalServiceHandle
    }

    private let services: any LinuxGuestLocalServiceControlling
    private let pathMap: @Sendable (String) async -> LinuxGuestPathMap?
    private var records: [UUID: Record] = [:]

    public init(
        services: any LinuxGuestLocalServiceControlling,
        pathMap: @escaping @Sendable (String) async -> LinuxGuestPathMap?
    ) {
        self.services = services
        self.pathMap = pathMap
    }

    public func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle {
        let allowedRunRoots = ["/workspace/", "/floe/env/"]
        guard launch.argv.count == 3,
              launch.argv[1] == "-d",
              launch.argv[0].hasPrefix(RGSSGuestEngineInstall.guestRoot + "/bin/tapir-"),
              allowedRunRoots.contains(where: { launch.argv[2].hasPrefix($0) }),
              launch.argv[2] == launch.workingDirectory,
              !launch.argv[0].contains(".."), !launch.argv[2].contains("..") else {
            throw RGSSLinuxGuestJobError.invalidLaunch(
                "expected [tapir-*, -d, <workspace|env>/run] with matching working directory")
        }
        guard let display = launch.environment["DISPLAY"],
              display.range(of: #"^:[0-9]{1,2}(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let home = launch.environment["HOME"], home.hasPrefix("/") else {
            throw RGSSLinuxGuestJobError.invalidLaunch("DISPLAY/HOME")
        }
        let allowedEnvironment: Set<String> = [
            "DISPLAY", "HOME", "PWD", "LD_LIBRARY_PATH", "LANG", "LC_ALL",
            "SDL_AUDIODRIVER", "SDL_VIDEODRIVER", "LIBGL_ALWAYS_SOFTWARE",
        ]
        guard launch.environment.keys.allSatisfy({ allowedEnvironment.contains($0) }) else {
            throw RGSSLinuxGuestJobError.invalidLaunch("unsupported run environment key")
        }
        if let library = launch.environment["LD_LIBRARY_PATH"] {
            guard library.split(separator: ":", omittingEmptySubsequences: false)
                .allSatisfy({ $0.hasPrefix("/") }) else {
                throw RGSSLinuxGuestJobError.invalidLaunch("LD_LIBRARY_PATH")
            }
        }
        guard records[launch.jobID] == nil,
              let map = await pathMap(launch.environmentID),
              let runHost = map.hostPath(forGuestPath: launch.workingDirectory),
              map.guestPath(forHostPath: launch.logFile.path) != nil else {
            throw RGSSLinuxGuestJobError.invalidLaunch(
                "run/log path is outside the environment's declared shares")
        }
        let launcher = runHost.appendingPathComponent("floe-rgss-launch.sh")
        let script = """
        #!/bin/sh
        set -eu
        engine="$1"
        project="$2"
        exec "$engine" -d "$project"
        """
        do {
            try FileManager.default.createDirectory(at: runHost, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: launcher, options: [.atomic])
        } catch {
            throw RGSSLinuxGuestJobError.invalidLaunch("cannot stage the fixed game launcher")
        }
        let request = LinuxGuestLocalServiceRequest(
            entry: launcher.path,
            runtime: .shell,
            arguments: [launch.argv[0], launch.argv[2]],
            workingDirectory: runHost.path,
            port: Self.port(for: launch.jobID),
            logFile: launch.logFile,
            environment: launch.environment)
        let serviceHandle = try await services.startLocalService(
            environmentID: launch.environmentID,
            request: request,
            cancellation: CancellationToken())
        guard serviceHandle.environmentID == launch.environmentID,
              serviceHandle.port == request.port else {
            await services.stopLocalService(serviceHandle)
            throw RGSSLinuxGuestJobError.identityMismatch
        }
        let handle = RGSSGuestJobHandle(jobID: launch.jobID, ownerToken: launch.ownerToken)
        records[launch.jobID] = Record(jobHandle: handle, serviceHandle: serviceHandle)
        return handle
    }

    public func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        guard let record = records[handle.jobID],
              record.jobHandle == handle else {
            throw RGSSLinuxGuestJobError.notOwned
        }
        let snapshot = await services.localServiceSnapshot(record.serviceHandle)
        let elapsed = UInt64(max(0, Date().timeIntervalSince(record.serviceHandle.startedAt) * 1_000))
        switch snapshot.state {
        case "running":
            return .init(handle: handle, state: .running(frameRevision: 0),
                         elapsedMilliseconds: elapsed)
        case "starting", "stopping":
            return .init(handle: handle, state: .starting,
                         elapsedMilliseconds: elapsed)
        case "stopped", "notFound":
            return .init(handle: handle, state: .stopped,
                         elapsedMilliseconds: elapsed)
        case "failed":
            return .init(handle: handle,
                         state: .failed(snapshot.lastError ?? "the guest game service failed"),
                         elapsedMilliseconds: elapsed)
        case "unavailable":
            throw RGSSLinuxGuestJobError.livenessUnavailable(
                snapshot.lastError ?? "the guest service probe is unavailable")
        default:
            throw RGSSLinuxGuestJobError.livenessUnavailable(
                "unknown guest service state \(snapshot.state)")
        }
    }

    public func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws {
        guard let record = records[handle.jobID],
              record.jobHandle == handle else {
            throw RGSSLinuxGuestJobError.notOwned
        }
        await services.stopLocalService(record.serviceHandle)
        let snapshot = await services.localServiceSnapshot(record.serviceHandle)
        switch snapshot.state {
        case "stopped", "notFound":
            records.removeValue(forKey: handle.jobID)
        case "unavailable", "failed":
            throw RGSSLinuxGuestJobError.stopUnconfirmed(
                snapshot.lastError ?? snapshot.state)
        default:
            throw RGSSLinuxGuestJobError.stopUnconfirmed(
                snapshot.lastError ?? "the guest game service did not stop (\(snapshot.state))")
        }
    }

    private static func port(for jobID: UUID) -> Int {
        let prefix = jobID.uuidString.replacingOccurrences(of: "-", with: "").prefix(4)
        let value = Int(prefix, radix: 16) ?? 0
        return 40_000 + (value % 15_000)
    }
}
