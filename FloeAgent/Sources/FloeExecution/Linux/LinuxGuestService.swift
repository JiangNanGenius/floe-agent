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

/// Guest mount points for the two Floe shares. These are part of the contract
/// with the guest runner (`FloeAgent/LinuxGuest/runner/floe_exec.c`), which
/// mounts `floe-env` at `/floe/env` and `workspace` at `/workspace` before it
/// reads commands; changing them requires changing both sides together.
public enum LinuxGuestMountPoint {
    public static let environment = "/floe/env"
    public static let workspace = "/workspace"
}

/// Maps host paths to guest paths using the environment's 9p shares. Every
/// host path handed to the guest (cwd, entry script, log file, Python target)
/// goes through this type, so the guest never receives a host path and the
/// host never accepts a guest path outside a declared share.
public struct LinuxGuestPathMap: Sendable {
    private let entries: [(host: String, guest: String)]

    public init(shares: [LinuxGuestShare]) {
        var entries: [(host: String, guest: String)] = []
        for share in shares {
            let host = share.hostDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let guest: String
            switch share.tag {
            case LinuxGuestShare.environmentTag: guest = LinuxGuestMountPoint.environment
            case LinuxGuestShare.workspaceTag: guest = LinuxGuestMountPoint.workspace
            default: guest = "/floe/" + share.tag
            }
            entries.append((host, guest))
        }
        // Longest host prefix wins so a share nested under another one still
        // maps to its own mount point.
        self.entries = entries.sorted { $0.host.count > $1.host.count }
    }

    /// Guest path for a host path inside one of the shares, nil otherwise.
    /// `..` components are rejected instead of normalized into an escape.
    public func guestPath(forHostPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard !path.split(separator: "/").contains("..") else { return nil }
        let host = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        for entry in entries {
            if host == entry.host { return entry.guest }
            if host.hasPrefix(entry.host + "/") {
                return entry.guest + String(host.dropFirst(entry.host.count))
            }
        }
        return nil
    }

    /// Host URL for a guest path under one of the mount points, nil otherwise.
    public func hostPath(forGuestPath path: String) -> URL? {
        guard !path.split(separator: "/").contains("..") else { return nil }
        for entry in entries {
            if path == entry.guest { return URL(fileURLWithPath: entry.host, isDirectory: true) }
            if path.hasPrefix(entry.guest + "/") {
                let relative = String(path.dropFirst(entry.guest.count + 1))
                return URL(fileURLWithPath: entry.host, isDirectory: true).appendingPathComponent(relative)
            }
        }
        return nil
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Guest root of the environment write layer, when the descriptor shares it.
    public var environmentGuestRoot: String? {
        entries.first { $0.guest == LinuxGuestMountPoint.environment }?.guest
    }

    /// Guest root of the workspace, when the descriptor shares it.
    public var workspaceGuestRoot: String? {
        entries.first { $0.guest == LinuxGuestMountPoint.workspace }?.guest
    }
}

/// Encodes environment variables as a raw `env KEY=VALUE …` prefix. Keys and
/// values are validated so an environment dictionary can never smuggle NULs
/// or framing bytes into a guest command line.
public enum LinuxGuestEnvironmentEncoding {
    public static func argv(_ variables: [String: String]) -> [String]? {
        let allowed = variables.filter { key, value in
            guard !value.contains("\u{0}") else { return false }
            guard let first = key.first, first.isLetter || first == "_" else { return false }
            return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        guard !allowed.isEmpty else { return nil }
        return allowed.keys.sorted().map { "\($0)=\(allowed[$0]!)" }
    }
}

/// Optional capability for services that can map host paths to their guest
/// shares. `exec.localPython` and the shell use it to hand the guest a cwd and
/// Python target instead of a macOS path the guest cannot see.
public protocol LinuxGuestPathMapping: Sendable {
    func linuxGuestPathMap(environmentID: String) async -> LinuxGuestPathMap?
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

/// A guest image manifest. `qualified` alone is never trusted: a startable
/// image must also carry a qualification record (`qualificationRun` plus a
/// SHA-512 digest for every artifact), and the resolver hashes the actual
/// bytes before the registry starts the guest. A user-edited `qualified: true`
/// without matching digests is reported as unqualified.
public struct LinuxGuestImageArtifact: Sendable, Equatable, Codable {
    public enum Role: String, Codable, Sendable {
        case bios
        case kernel
        case initrd
        case disk
    }

    public var role: Role
    public var path: String
    public var sha512: String
    public var bytes: Int64

    public init(role: Role, path: String, sha512: String, bytes: Int64) {
        self.role = role
        self.path = path
        self.sha512 = sha512
        self.bytes = bytes
    }
}

/// Provenance of a guest image. Distributing an image is a separate decision
/// from running one locally: a GPL-derived guest userland needs its source and
/// build configuration to be published, so the official download entry only
/// accepts an image whose manifest carries this record *and* whose archive
/// digest is pinned by this build.
public struct LinuxGuestImageProvenance: Sendable, Equatable, Codable {
    public var sourceURL: String?
    public var buildConfigurationURL: String?
    public var license: String?
    /// False unless the corresponding source and license obligations are
    /// published for exactly this image.
    public var distributionAllowed: Bool

    public init(
        sourceURL: String? = nil,
        buildConfigurationURL: String? = nil,
        license: String? = nil,
        distributionAllowed: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.buildConfigurationURL = buildConfigurationURL
        self.license = license
        self.distributionAllowed = distributionAllowed
    }
}

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
    /// Identifier of the qualification run that produced the digests below
    /// (workflow run URL or id). Required for a startable image.
    public var qualificationRun: String?
    /// SHA-512 bound artifact list. Required for a startable image.
    public var artifacts: [LinuxGuestImageArtifact]?
    public var provenance: LinuxGuestImageProvenance?

    public init(
        id: String,
        biosPath: String,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        diskPath: String? = nil,
        diskReadWrite: Bool = true,
        cmdline: String? = nil,
        qualified: Bool = false,
        qualificationEvidence: String? = nil,
        qualificationRun: String? = nil,
        artifacts: [LinuxGuestImageArtifact]? = nil,
        provenance: LinuxGuestImageProvenance? = nil
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
        self.qualificationRun = qualificationRun
        self.artifacts = artifacts
        self.provenance = provenance
    }

    /// The declared artifact paths with their roles, in manifest order.
    public var declaredArtifacts: [(role: LinuxGuestImageArtifact.Role, path: String)] {
        var result: [(LinuxGuestImageArtifact.Role, String)] = [(.bios, biosPath)]
        if let kernelPath { result.append((.kernel, kernelPath)) }
        if let initrdPath { result.append((.initrd, initrdPath)) }
        if let diskPath { result.append((.disk, diskPath)) }
        return result
    }

    /// Artifact URL for a declared path. Relative paths resolve inside the
    /// image directory (the portable, distributable form); absolute paths are
    /// kept for locally built images and must still verify inside the
    /// directory. Nothing is normalized out of the image directory silently:
    /// the verifier rejects escapes.
    public func artifactURL(_ path: String, imageDirectory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return imageDirectory.appendingPathComponent(path)
    }

    public func artifactDigest(role: LinuxGuestImageArtifact.Role) -> LinuxGuestImageArtifact? {
        artifacts?.first { $0.role == role }
    }

    /// Structural qualification check: `qualified`, a named qualification run,
    /// a digest for every declared artifact, and existing regular files. The
    /// digest bytes themselves are verified by `LinuxGuestImageVerifier`,
    /// which knows the image root; this function must not be used alone as
    /// proof that an image is startable.
    public func qualificationFailure(imageDirectory: URL? = nil, fileManager: FileManager = .default) -> String? {
        if !qualified {
            let evidence = qualificationEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "no modern Linux qualification run has passed (\(evidence?.isEmpty == false ? evidence! : "no evidence recorded"))"
        }
        let run = qualificationRun?.trimmingCharacters(in: .whitespacesAndNewlines)
        if run?.isEmpty != false {
            return "manifest claims qualified but records no qualification run id"
        }
        guard let artifacts, !artifacts.isEmpty else {
            return "manifest claims qualified but carries no artifact digests; import the image through a verified archive"
        }
        for declared in declaredArtifacts {
            guard let digest = artifactDigest(role: declared.role) else {
                return "manifest has no \(declared.role.rawValue) digest; a partial image cannot start"
            }
            if digest.path != declared.path {
                return "\(declared.role.rawValue) digest path does not match the manifest path"
            }
            let normalized = digest.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.count != 128 || normalized.contains(where: { !$0.isHexDigit }) {
                return "\(declared.role.rawValue) digest is not a SHA-512 hex string"
            }
            if digest.bytes <= 0 {
                return "\(declared.role.rawValue) digest records no size"
            }
        }
        for declared in declaredArtifacts {
            let url: URL
            if let imageDirectory {
                url = artifactURL(declared.path, imageDirectory: imageDirectory)
            } else {
                url = URL(fileURLWithPath: declared.path)
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return "image artifact is missing: \(url.path)"
            }
        }
        return nil
    }

    /// The cmdline the guest must boot with. The Floe runner is injected as
    /// the guest init; a manifest that only configures console/root gets it
    /// appended so a qualified image always enters the command channel. If the
    /// manifest already names an init, it is left untouched (verified images
    /// must point at the runner).
    public var effectiveCmdline: String {
        LinuxGuestBootArguments.commandLine(
            base: cmdline,
            runnerPath: Self.runnerGuestPath,
            epoch: Int64(Date().timeIntervalSince1970)
        )
    }

    /// Absolute guest path of the injected Floe runner.
    public static let runnerGuestPath = "/usr/local/bin/floe-exec"
}

/// Resolves guest image ids to manifests. The app supplies a file-backed
/// implementation; tests supply in-memory images.
public protocol LinuxGuestImageResolving: Sendable {
    func linuxGuestImage(id: String) async -> LinuxGuestImage?
    /// Root the manifest paths are relative to / contained in. nil means the
    /// resolver cannot verify digests (in-memory test images).
    var imageRoot: URL? { get }
    /// nil when the resolver cannot verify digests; otherwise the reason the
    /// image must not start (missing artifact, digest mismatch, path escape).
    func linuxGuestImageVerificationFailure(id: String) async -> String?
}

public extension LinuxGuestImageResolving {
    var imageRoot: URL? { nil }
    func linuxGuestImageVerificationFailure(id: String) async -> String? { nil }
}

/// File-backed image catalog: `<root>/<id>/manifest.json`. The resolver is an
/// actor because verification hashes the artifacts once per changed file and
/// caches the result; nothing is bundled by default because no qualified
/// modern guest image exists yet.
public actor FileLinuxGuestImageResolver: LinuxGuestImageResolving {
    public nonisolated let root: URL
    private let verifier: LinuxGuestImageVerifier

    public init(root: URL, verifier: LinuxGuestImageVerifier = LinuxGuestImageVerifier()) {
        self.root = root
        self.verifier = verifier
    }

    public nonisolated var imageRoot: URL? { root }

    public func linuxGuestImage(id: String) async -> LinuxGuestImage? {
        let manifest = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(LinuxGuestImage.self, from: data)
    }

    public func linuxGuestImageVerificationFailure(id: String) async -> String? {
        guard let image = await linuxGuestImage(id: id) else {
            return "no guest image manifest for id '\(id)'"
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        return await verifier.verificationFailure(image: image, imageDirectory: directory)
    }

    /// Drops cached digest verification for one image (after import/removal).
    public func invalidate(id: String) async {
        await verifier.invalidate(id: id)
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
    /// Image state independent of any start attempt, so the UI can explain an
    /// unqualified/missing image before the user tries to start the guest.
    public var imageInstalled: Bool?
    public var imageVerificationFailure: String?
    public var imageDistributable: Bool?

    public init(
        environmentID: String,
        running: Bool,
        imageID: String? = nil,
        ramMB: Int? = nil,
        startedAt: Date? = nil,
        lastError: String? = nil,
        imageInstalled: Bool? = nil,
        imageVerificationFailure: String? = nil,
        imageDistributable: Bool? = nil
    ) {
        self.environmentID = environmentID
        self.running = running
        self.imageID = imageID
        self.ramMB = ramMB
        self.startedAt = startedAt
        self.lastError = lastError
        self.imageInstalled = imageInstalled
        self.imageVerificationFailure = imageVerificationFailure
        self.imageDistributable = imageDistributable
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

/// The fallback kernel has no RTC. Supply a fresh wall clock at each boot so
/// HTTPS and package signature dates use the device's time, not the image date.
/// The guest PID1 consumes this numeric parameter before accepting commands.
enum LinuxGuestBootArguments {
    static func commandLine(base: String?, runnerPath: String, epoch: Int64) -> String {
        let configured = base ?? "console=hvc0 root=/dev/vda rw loglevel=4"
        var fields = configured.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.hasPrefix("floe.epoch=") }
        if !fields.contains(where: { $0.hasPrefix("init=") }) {
            fields.append("init=" + runnerPath)
        }
        fields.append("floe.epoch=" + String(epoch))
        return fields.joined(separator: " ")
    }
}
