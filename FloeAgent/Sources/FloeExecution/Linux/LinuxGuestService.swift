// FloeExecution — Linux guest backend contract (TinyEMU RV64).
//
// Floe Linux environments run a real Debian userland inside the pinned
// TinyEMU 2019-12-21 interpreter (ThirdParty/TinyEMU). This file owns the
// protocol, limits and error vocabulary; `TinyEMULinuxCommandService` owns the
// actual VM. The app injects one service through
// `FloePlatformServices.setLinuxCommandService`.
//
// Honesty rules:
//  - `ownsLinuxEnvironment` answers for a Linux environment even while its
//    guest is stopped, so host-side package fallbacks never touch it.
//  - `supports` is true only while that guest is actually running.
//  - A guest image starts only from a manifest whose qualification record
//    says it is qualified; the 2018 demo image is never assumed to be ready.
//
// Sharing rule: one guest per environment, and the same guest serves the
// shell, localPython and localService paths for that environment. The engine
// links one process-wide slirp instance, so at most one guest runs at a time.

import Foundation
import FloeCore
import FloeTools

public enum LinuxGuestError: Error, LocalizedError, Sendable, Equatable {
    case notOwned(environmentID: String)
    case notRunning(environmentID: String)
    case imageNotQualified(environmentID: String, reason: String)
    case guestBusy(environmentID: String)
    case startFailed(String)
    case outputLimitExceeded(limit: Int)
    case timedOut(seconds: TimeInterval)
    case serviceForwardingUnavailable(String)
    case consoleUnavailable(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .notOwned(let id):
            return "Linux guest for environment \(id) is not owned by this service"
        case .notRunning(let id):
            return "Linux environment \(id) is not running yet; start it before running guest commands"
        case .imageNotQualified(_, let reason):
            return "Linux guest image is not qualified: \(reason)"
        case .guestBusy(let id):
            return "Linux guest \(id) is already running; this build runs one guest at a time"
        case .startFailed(let detail):
            return "Linux guest failed to start: \(detail)"
        case .outputLimitExceeded(let limit):
            return "Linux command output exceeded the \(limit) byte limit"
        case .timedOut(let seconds):
            return "Linux command timed out after \(Int(seconds)) seconds"
        case .serviceForwardingUnavailable(let detail):
            return "Linux service forwarding is unavailable: \(detail)"
        case .consoleUnavailable(let detail):
            return "Linux guest console is unavailable: \(detail)"
        case .invalidConfiguration(let detail):
            return "Linux guest configuration is invalid: \(detail)"
        }
    }
}

/// Bounds applied to every guest. The RAM ceiling is deliberately small: the
/// guest is an interpreted RV64 machine sharing memory with the app.
public struct LinuxGuestLimits: Sendable, Equatable {
    public var defaultRAMMB: Int
    public var maxRAMMB: Int
    public var minRAMMB: Int
    /// Per-command output ceiling, and the hard ceiling callers are clamped to.
    public var defaultMaxOutputBytes: Int
    public var maxOutputBytes: Int
    public var maxCommandBytes: Int
    public var defaultCommandTimeout: TimeInterval
    public var maxCommandTimeout: TimeInterval
    /// How long to wait for the guest console to answer a command.
    public var commandTimeout: TimeInterval
    /// How long to wait after an interrupt for the guest runner to close out.
    public var interruptGrace: TimeInterval
    /// Host forwarding table limit (engine FLOE_VM_MAX_HOSTFWD).
    public var maxServiceForwards: Int

    public init(
        defaultRAMMB: Int = 256,
        maxRAMMB: Int = 512,
        minRAMMB: Int = 96,
        defaultMaxOutputBytes: Int = 256 * 1024,
        maxOutputBytes: Int = 1024 * 1024,
        maxCommandBytes: Int = 32 * 1024,
        defaultCommandTimeout: TimeInterval = 300,
        maxCommandTimeout: TimeInterval = 1800,
        commandTimeout: TimeInterval = 300,
        interruptGrace: TimeInterval = 2,
        maxServiceForwards: Int = 16
    ) {
        self.defaultRAMMB = defaultRAMMB
        self.maxRAMMB = maxRAMMB
        self.minRAMMB = minRAMMB
        self.defaultMaxOutputBytes = defaultMaxOutputBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxCommandBytes = maxCommandBytes
        self.defaultCommandTimeout = defaultCommandTimeout
        self.maxCommandTimeout = maxCommandTimeout
        self.commandTimeout = commandTimeout
        self.interruptGrace = interruptGrace
        self.maxServiceForwards = maxServiceForwards
    }

    public static let standard = LinuxGuestLimits()

    public func clampedRAMMB(_ requested: Int?) -> Int {
        max(minRAMMB, min(maxRAMMB, requested ?? defaultRAMMB))
    }

    public func clampedOutputBytes(_ requested: Int?) -> Int {
        max(1024, min(maxOutputBytes, requested ?? defaultMaxOutputBytes))
    }

    public func clampedTimeout(_ requested: TimeInterval?) -> TimeInterval {
        let value = requested.flatMap { $0.isFinite ? $0 : nil } ?? defaultCommandTimeout
        return max(1, min(maxCommandTimeout, value))
    }
}

/// One virtio-9p share exported into the guest. The guest mounts these with
/// `mount -t 9p -o trans=virtio <tag> <mountpoint>`; the tag is the mount tag.
public struct LinuxGuestShare: Sendable, Hashable {
    /// Maximum virtio-9p shares the pinned engine supports.
    public static let maximumShares = 4
    public static let environmentTag = "floe-env"
    public static let workspaceTag = "workspace"

    public var tag: String
    public var hostDirectory: URL

    public init(tag: String, hostDirectory: URL) {
        self.tag = tag
        self.hostDirectory = hostDirectory
    }
}

/// One host→guest TCP/UDP service forward through slirp. A guest service
/// (localService) becomes reachable on the host loopback address.
public struct LinuxGuestServiceForward: Sendable, Hashable {
    public var hostAddress: String
    public var hostPort: UInt16
    public var guestPort: UInt16
    public var isUDP: Bool

    public init(hostAddress: String = "127.0.0.1", hostPort: UInt16, guestPort: UInt16, isUDP: Bool = false) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.isUDP = isUDP
    }
}

/// Everything the guest runtime needs to know about one Floe environment.
/// The app resolves this from the environment registry; a descriptor exists
/// only for environments explicitly declared as Linux guests.
public struct LinuxGuestEnvironmentDescriptor: Sendable {
    public var id: String
    /// Container owner (conversation or workspace UUID string) for ownership
    /// checks and diagnostics; never a credential or a path.
    public var ownerID: String?
    /// Task/run that requested the guest when one is known. Guest sessions
    /// record it so stop-by-task can release exactly its own guest.
    public var taskID: String?
    /// Writable environment layer, shared as the guest's persistent data dir.
    public var writableDirectory: URL?
    /// virtio-9p shares, in deterministic order (tag naming is the app's).
    public var shares: [LinuxGuestShare]
    /// Identifier of the guest image manifest (bios/kernel/rootfs).
    public var imageID: String
    public var ramMB: Int?
    /// Networking is opt-in: the engine has one process-wide slirp instance,
    /// so only one network-enabled guest can exist at a time.
    public var networkEnabled: Bool
    public var serviceForwards: [LinuxGuestServiceForward]

    public init(
        id: String,
        ownerID: String? = nil,
        taskID: String? = nil,
        writableDirectory: URL? = nil,
        shares: [LinuxGuestShare] = [],
        imageID: String,
        ramMB: Int? = nil,
        networkEnabled: Bool = false,
        serviceForwards: [LinuxGuestServiceForward] = []
    ) {
        self.id = id
        self.ownerID = ownerID
        self.taskID = taskID
        self.writableDirectory = writableDirectory
        self.shares = shares
        self.imageID = imageID
        self.ramMB = ramMB
        self.networkEnabled = networkEnabled
        self.serviceForwards = serviceForwards
    }
}

/// App-injected source of Linux guest descriptors. Returning nil means the
/// environment is not a Linux guest this service owns (native environments
/// stay native). Implementations must keep returning the descriptor while the
/// guest is stopped: the shell relies on ownership to avoid host-layer writes.
public protocol LinuxGuestEnvironmentProviding: Sendable {
    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor?
}

/// A guest image manifest. `qualified` records whether a modern-guest
/// qualification run actually produced a working Linux userland for this
/// manifest; unqualified images are reported, never started.
public struct LinuxGuestImage: Sendable, Equatable, Codable {
    public var id: String
    public var biosPath: String
    public var kernelPath: String?
    public var initrdPath: String?
    public var diskPath: String?
    public var diskReadWrite: Bool
    public var cmdline: String?
    public var qualified: Bool
    public var qualificationEvidence: String?

    public init(
        id: String,
        biosPath: String,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        diskPath: String? = nil,
        diskReadWrite: Bool = true,
        cmdline: String? = nil,
        qualified: Bool = false,
        qualificationEvidence: String? = nil
    ) {
        self.id = id
        self.biosPath = biosPath
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.diskPath = diskPath
        self.diskReadWrite = diskReadWrite
        self.cmdline = cmdline
        self.qualified = qualified
        self.qualificationEvidence = qualificationEvidence
    }

    /// Reason string for `LinuxGuestError.imageNotQualified`; nil when the
    /// image may start. Every artifact path must also exist on disk.
    public func qualificationFailure(fileManager: FileManager = .default) -> String? {
        if !qualified {
            let evidence = qualificationEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "no modern Linux qualification run has passed (\(evidence?.isEmpty == false ? evidence! : "no evidence recorded"))"
        }
        for path in [biosPath, kernelPath, initrdPath, diskPath].compactMap({ $0 }) {
            if !fileManager.fileExists(atPath: path) {
                return "image artifact is missing: \(path)"
            }
        }
        return nil
    }
}

/// Resolves guest image ids to manifests. The app supplies a file-backed
/// implementation; tests supply in-memory images.
public protocol LinuxGuestImageResolving: Sendable {
    func linuxGuestImage(id: String) async -> LinuxGuestImage?
}

/// File-backed image catalog: `<root>/<id>/manifest.json`. The root is an
/// app-owned directory; nothing is bundled by default because no qualified
/// modern guest image exists yet.
public struct FileLinuxGuestImageResolver: LinuxGuestImageResolving {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func linuxGuestImage(id: String) async -> LinuxGuestImage? {
        let manifest = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(LinuxGuestImage.self, from: data)
    }
}

/// One interactive guest session's state as seen by the host.
public struct LinuxGuestSessionInfo: Sendable, Equatable {
    public var sessionID: String
    public var alive: Bool
    public var exitCode: Int32?

    public init(sessionID: String, alive: Bool, exitCode: Int32? = nil) {
        self.sessionID = sessionID
        self.alive = alive
        self.exitCode = exitCode
    }
}

/// Lifecycle surface layered on top of `LinuxCommandRunning`. The package UI
/// and shell consume the command protocol; the app uses this to start, stop
/// and delete the guest that owns an environment.
public protocol LinuxGuestControlling: Sendable {
    /// Starts the environment's guest. Returns false when this service does
    /// not own the environment (native environments are untouched). Throws
    /// with an honest reason when the guest cannot start.
    func startGuest(environmentID: String, taskID: String?) async throws -> Bool
    /// Stops (and destroys) the guest; safe to call for any environment.
    func stopGuest(environmentID: String) async
    /// Releases guest state before the environment's data is deleted.
    func deleteGuest(environmentID: String) async
    func guestIsRunning(environmentID: String) async -> Bool
    /// Image/last-error state for honest UI and shell output.
    func guestStatus(environmentID: String) async -> LinuxGuestStatus
    /// Stops guests started by this task id (task ownership teardown).
    func stopGuests(taskID: String) async
    /// Host→guest port forwarding for a running guest.
    func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws
    func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async

    // MARK: interactive sessions (shell.*)

    /// Opens an interactive PTY session inside the guest. `sessionID` is the
    /// shell session identity used by exchange/close/signal.
    func openSession(
        environmentID: String,
        sessionID: String,
        argv: [String],
        workingDirectory: String?,
        columns: Int,
        rows: Int
    ) async throws
    /// Reads buffered terminal output; returns nil output when nothing
    /// arrived before `waitMs` and the session is still alive.
    func readSession(
        sessionID: String,
        maxBytes: Int,
        waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)?
    func writeSession(sessionID: String, text: String) async throws
    func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async
    func resizeSession(sessionID: String, columns: Int, rows: Int) async
    func closeSession(sessionID: String) async
    func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo?
}

/// Runtime status for diagnostics and honest UI states.
public struct LinuxGuestStatus: Sendable, Equatable {
    public var environmentID: String
    public var running: Bool
    public var imageID: String?
    public var ramMB: Int?
    public var startedAt: Date?
    public var lastError: String?

    public init(
        environmentID: String,
        running: Bool,
        imageID: String? = nil,
        ramMB: Int? = nil,
        startedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.environmentID = environmentID
        self.running = running
        self.imageID = imageID
        self.ramMB = ramMB
        self.startedAt = startedAt
        self.lastError = lastError
    }
}

/// Low-level guest console byte pipe. Implemented by the TinyEMU bridge; the
/// command channel and tests depend on this seam only.
public protocol LinuxGuestConsoleTransport: Sendable {
    func write(_ bytes: [UInt8]) async throws
    func close() async
    /// Console output chunks in order. A single consumer iterates it.
    func output() async -> AsyncStream<Data>
}
