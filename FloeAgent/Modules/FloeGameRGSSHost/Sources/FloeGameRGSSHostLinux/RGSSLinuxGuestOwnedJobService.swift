// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeExecution
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeTools

public enum RGSSLinuxGuestJobError: Error, Equatable, Sendable {
    case invalidLaunch(String)
    case identityMismatch
    case notOwned
    case livenessUnavailable(String)
    case stopUnconfirmed(String)
}

/// Concrete `RGSSGuestJobService` over the App's existing owned guest process
/// lifecycle (`LinuxGuestLocalServiceHosting`). It does not create a shell,
/// service forward, VM or environment. The fixed argv is passed as an array;
/// it is never joined into a shell string.
public actor RGSSLinuxGuestOwnedJobService: RGSSGuestJobService {
    private struct Record: Sendable {
        let handle: RGSSGuestJobHandle
        let receipt: LinuxGuestServiceProcessReceipt
        let environmentID: String
        let startedAt: Date
    }

    private let host: any LinuxGuestLocalServiceHosting
    private let pathMap: @Sendable (String) async -> LinuxGuestPathMap?
    private let timeout: TimeInterval
    private var records: [UUID: Record] = [:]

    public init(
        host: any LinuxGuestLocalServiceHosting,
        pathMap: @escaping @Sendable (String) async -> LinuxGuestPathMap?,
        timeout: TimeInterval = 30
    ) {
        self.host = host
        self.pathMap = pathMap
        self.timeout = max(1, min(timeout, 120))
    }

    public func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle {
        guard launch.environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              launch.ownerToken != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw RGSSLinuxGuestJobError.invalidLaunch("environment/owner identity")
        }
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
              let home = launch.environment["HOME"], home.hasPrefix("/"),
              let pwd = launch.environment["PWD"], pwd == launch.workingDirectory else {
            throw RGSSLinuxGuestJobError.invalidLaunch("DISPLAY/HOME/PWD")
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
              let logGuest = map.guestPath(forHostPath: launch.logFile.path) else {
            throw RGSSLinuxGuestJobError.invalidLaunch("log path is outside the guest shares")
        }
        let receipt = try await host.guestSpawnOwnedService(
            environmentID: launch.environmentID,
            argv: launch.argv,
            workingDirectory: launch.workingDirectory,
            logPath: logGuest,
            timeout: timeout,
            cancellation: CancellationToken())
        let handle = RGSSGuestJobHandle(jobID: launch.jobID, ownerToken: launch.ownerToken)
        records[launch.jobID] = Record(
            handle: handle, receipt: receipt, environmentID: launch.environmentID,
            startedAt: Date())
        return handle
    }

    public func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        guard let record = records[handle.jobID],
              record.handle.ownerToken == handle.ownerToken,
              record.handle == handle else {
            throw RGSSLinuxGuestJobError.notOwned
        }
        let elapsed = UInt64(max(0, Date().timeIntervalSince(record.startedAt) * 1_000))
        do {
            let state = try await host.guestOwnedServiceState(record.receipt, timeout: timeout)
            switch state {
            case .running:
                // The job port observes process liveness, not guest frames. A
                // frame count of 0 is honest; the display owner owns pixels.
                return .init(handle: handle, state: .running(frameRevision: 0),
                             elapsedMilliseconds: elapsed)
            case .exited:
                return .init(handle: handle, state: .stopped,
                             elapsedMilliseconds: elapsed)
            case .environmentGone:
                return .init(handle: handle,
                             state: .failed("the Linux environment is no longer running"),
                             elapsedMilliseconds: elapsed)
            }
        } catch {
            throw RGSSLinuxGuestJobError.livenessUnavailable(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    public func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws {
        guard let record = records[handle.jobID],
              record.handle.ownerToken == handle.ownerToken,
              record.handle == handle else {
            throw RGSSLinuxGuestJobError.notOwned
        }
        do {
            let stopped = try await host.guestStopOwnedService(record.receipt, timeout: timeout)
            guard stopped else {
                throw RGSSLinuxGuestJobError.stopUnconfirmed("the guest did not confirm process exit")
            }
            records.removeValue(forKey: handle.jobID)
        } catch let error as RGSSLinuxGuestJobError {
            throw error
        } catch {
            throw RGSSLinuxGuestJobError.stopUnconfirmed(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
