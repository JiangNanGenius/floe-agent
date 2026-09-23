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
    /// The device's bounded guest admission is already used up. Reported
    /// before a VM is created; no other running guest is ever killed or
    /// stopped to make room, and nothing waits forever for a slot.
    case capacityReached(detail: String)
    /// A stop did not actually stop the VM (the engine run loop did not leave
    /// its last slice inside its budget), so the guest stays quarantined: its
    /// disk is not reused by a new VM and the reserved capacity is retained
    /// until a later stop succeeds.
    case stopFailed(environmentID: String, detail: String)
    case startFailed(String)
    case outputLimitExceeded(limit: Int)
    case timedOut(seconds: TimeInterval)
    case serviceForwardingUnavailable(String)
    case consoleUnavailable(String)
    case invalidConfiguration(String)
    /// The guest image's runner predates protocol 3 (no HELLO/CAPS answer or
    /// a lower protocol): concurrent tokens would corrupt output, so the
    /// channel fails closed until the runner component is updated.
    case runnerUpgradeRequired(required: String, found: String?)
    /// The request asks for two harts but THIS image (kernel/firmware) has
    /// no SMP capability evidence. This is a permanent shape/image mismatch,
    /// reported immediately as an actionable error — distinct from a
    /// temporary quota shortage (which queues). A dual guest is never
    /// silently booted single; only an explicitly authorized caller accepts
    /// a single-hart downgrade.
    case smpUnsupportedByImage(environmentID: String)

    public var errorDescription: String? {
        switch self {
        case .notOwned(let id):
            return "Linux guest for environment \(id) is not owned by this service"
        case .notRunning(let id):
            return "Linux environment \(id) is not running yet; start it before running guest commands"
        case .imageNotQualified(_, let reason):
            return "Linux guest image is not qualified: \(reason)"
        case .guestBusy(let id):
            return "Linux guest \(id) is already running, starting or stopping; wait for the current operation to finish"
        case .capacityReached(let detail):
            return "Linux guest capacity reached: \(detail)"
        case .stopFailed(let id, let detail):
            return "Linux guest \(id) did not stop: \(detail)"
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
        case .runnerUpgradeRequired(let required, let found):
            let detail = found.map { " (guest reported: \($0))" } ?? " (guest runner does not answer capability negotiation)"
            return "The Linux guest runner is too old: this build requires \(required)\(detail). Update the guest image component."
        case .smpUnsupportedByImage(let id):
            return "The Linux image for environment \(id) does not support two cores (no SMP capability); choose a single-core guest or use an SMP-capable image."
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
    /// Upper bound on simultaneously running guest commands (guest table
    /// MAX_CONCURRENT_COMMANDS). Each command gets its own token, pipes, cwd
    /// and process group.
    public var maxConcurrentCommands: Int
    /// Upper bound on simultaneously open interactive PTY sessions (guest
    /// table MAX_CONCURRENT_SESSIONS).
    public var maxConcurrentSessions: Int
    /// Upper bound on simultaneously active guests (running VMs plus starts
    /// in flight). Per-command/session caps do not bound process memory when
    /// every environment has its own VM, so admission is counted and
    /// reserved explicitly. At least two guests must fit at `maxRAMMB` each.
    public var maxActiveGuests: Int
    /// Total guest RAM budget in MB. A start is refused before any VM is
    /// created when its reserved RAM would exceed this; running guests are
    /// never killed to make room.
    public var maxGuestRAMMB: Int
    /// How long the start path waits for the booted runner's FLOE-HELLO
    /// answer before treating it as a legacy (pre-protocol-3) runner. This is
    /// a real guest boot/negotiation budget, not a handshake timeout:
    /// `handle.start()` returns when the VM thread is launched, so a fresh
    /// interpreter boot can take tens of seconds before the runner reads the
    /// console. Default 60s, always finite; a silent runner never hangs a
    /// start. Tests override it with a small value.
    public var runnerProbeTimeout: TimeInterval

    /// - Parameters:
    ///   - defaultRAMMB: default for an environment that declares no RAM
    ///     and where the advisory has no workload evidence: the 256 MiB
    ///     floor covers ordinary shell work. The GuestResourceAdvisory
    ///     recommends a larger shape from declared workload signals; the
    ///     device pool bucket (512 MiB on ≤4 GB devices) is the fleet
    ///     ceiling, not a per-VM default. Changing this is a policy change,
    ///     not proof of the cause of the historical ~182 MiB guest.
    ///   - maxRAMMB: per-VM ceiling matching the approved ladder (2 GiB).
    public init(
        defaultRAMMB: Int = 256,
        maxRAMMB: Int = 2048,
        minRAMMB: Int = 96,
        defaultMaxOutputBytes: Int = 256 * 1024,
        maxOutputBytes: Int = 1024 * 1024,
        maxCommandBytes: Int = 32 * 1024,
        defaultCommandTimeout: TimeInterval = 300,
        maxCommandTimeout: TimeInterval = 1800,
        commandTimeout: TimeInterval = 300,
        interruptGrace: TimeInterval = 2,
        maxServiceForwards: Int = 16,
        maxConcurrentCommands: Int = 8,
        maxConcurrentSessions: Int = 4,
        maxActiveGuests: Int = 4,
        maxGuestRAMMB: Int = 1536,
        runnerProbeTimeout: TimeInterval = 60
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
        self.maxConcurrentCommands = max(1, min(32, maxConcurrentCommands))
        self.maxConcurrentSessions = max(1, min(8, maxConcurrentSessions))
        self.maxActiveGuests = max(1, min(16, maxActiveGuests))
        self.maxGuestRAMMB = max(2 * minRAMMB, min(8 * 1024, maxGuestRAMMB))
        self.runnerProbeTimeout = max(0.2, min(60, runnerProbeTimeout))
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
    /// vCPUs granted by the resource pool (1 or 2). nil defaults to one hart;
    /// the registry sets this from the pool lease/admission at start time.
    /// A dual value is only valid for an image with SMP capability evidence.
    public var vcpus: Int?
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
        vcpus: Int? = nil,
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
        self.vcpus = vcpus
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
        /// The standalone guest runner used to upgrade an existing persistent
        /// disk in place. Deliberately distinct from `disk`: the runner is a
        /// small executable with its own size/digest records, and reusing the
        /// disk role would collide with the base-disk checks and with the
        /// environment disk it is copied into.
        case runner
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

/// A base disk image this manifest may adopt as an existing environment disk.
///
/// An environment disk is a mutable clone of one base disk and its sidecar
/// records the exact image id, SHA-512 and byte count it was cloned from; a
/// later catalog image whose disk differs byte-for-byte would otherwise be a
/// conflict. A runner-only component release ships the same base image with
/// just `/usr/local/bin/floe-exec` replaced, so it declares the exact
/// predecessor here: only an origin that matches all three recorded fields is
/// adopted, the mutable disk and its original `origin.json` stay untouched,
/// and the runner is replaced in-guest from the verified standalone runner
/// artifact. Any other origin is still a conflict and is never overwritten.
public struct LinuxGuestCompatibleDiskOrigin: Sendable, Equatable, Codable {
    public var imageID: String
    public var artifactSHA512: String
    public var artifactBytes: Int64

    public init(imageID: String, artifactSHA512: String, artifactBytes: Int64) {
        self.imageID = imageID
        self.artifactSHA512 = artifactSHA512
        self.artifactBytes = artifactBytes
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
    /// Optional standalone runner binary (`path` relative to the image
    /// directory, `sha512`, `bytes`) plus the exact CAPS payload it answers
    /// (e.g. "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=up";
    /// the `net=` field is the runner's first-boot network state, see
    /// `LinuxGuestNetworkStatus`). When
    /// present, an environment whose persistent disk still boots an older
    /// runner is upgraded in-guest from these verified bytes — never by
    /// wiping the disk.
    public var runnerArtifact: LinuxGuestImageArtifact?
    public var runnerCapabilities: String?
    /// Exact predecessor base images an existing environment disk may have
    /// been cloned from. Absent in older manifests (nil = no adoption).
    public var compatibleOrigins: [LinuxGuestCompatibleDiskOrigin]?

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
        provenance: LinuxGuestImageProvenance? = nil,
        runnerArtifact: LinuxGuestImageArtifact? = nil,
        runnerCapabilities: String? = nil,
        compatibleOrigins: [LinuxGuestCompatibleDiskOrigin]? = nil
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
        self.runnerArtifact = runnerArtifact
        self.runnerCapabilities = runnerCapabilities
        self.compatibleOrigins = compatibleOrigins
    }

    /// The declared artifact paths with their roles, in manifest order.
    public var declaredArtifacts: [(role: LinuxGuestImageArtifact.Role, path: String)] {
        var result: [(LinuxGuestImageArtifact.Role, String)] = [(.bios, biosPath)]
        if let kernelPath { result.append((.kernel, kernelPath)) }
        if let initrdPath { result.append((.initrd, initrdPath)) }
        if let diskPath { result.append((.disk, diskPath)) }
        // The standalone runner is a declared, verified artifact too. When the
        // manifest already carries an explicit runner digest entry the path is
        // listed once; otherwise the runnerArtifact record is the digest.
        if let runnerArtifact,
           !(artifacts?.contains { $0.role == .runner && $0.path == runnerArtifact.path } ?? false) {
            result.append((.runner, runnerArtifact.path))
        }
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
        if let matched = artifacts?.first(where: { $0.role == role }) { return matched }
        // The standalone runner carries its own digest record. Requiring a
        // duplicate entry in `artifacts` would create two sources of truth for
        // the same bytes, so the runnerArtifact record is authoritative when
        // no explicit runner entry exists.
        if role == .runner, let runnerArtifact { return runnerArtifact }
        return nil
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
        if let imageDirectory {
            // Containment first: a declared `..` component or an absolute
            // path outside the image directory is an escape, not merely a
            // missing file.
            let root = imageDirectory.resolvingSymlinksInPath().standardizedFileURL
            for declared in declaredArtifacts {
                if declared.path.contains("\u{0}") {
                    return "artifact path contains NUL: \(declared.path)"
                }
                if declared.path.split(separator: "/").contains("..") {
                    return "artifact path escapes the image directory: \(declared.path)"
                }
                let resolved = artifactURL(declared.path, imageDirectory: imageDirectory)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                if resolved.path != root.path, !resolved.path.hasPrefix(root.path + "/") {
                    return "artifact path escapes the image directory: \(declared.path)"
                }
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
        if let runnerFailure = runnerUpgradeContractFailure() {
            return runnerFailure
        }
        for origin in compatibleOrigins ?? [] {
            let originID = origin.imageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let originDigest = origin.artifactSHA512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if originID.isEmpty || originID.contains("/") || originID.contains("\u{0}") {
                return "compatible disk origin records an invalid image id '\(origin.imageID)'"
            }
            if originDigest.count != 128 || originDigest.contains(where: { !$0.isHexDigit }) {
                return "compatible disk origin for \(originID) is not a SHA-512 hex string"
            }
            if origin.artifactBytes <= 0 {
                return "compatible disk origin for \(originID) records no size"
            }
        }
        return nil
    }

    /// Structural contract for the optional standalone runner upgrade
    /// artifact: a distinct `runner` role (never `disk`), an agreed duplicate
    /// digest entry if the manifest carries one, and a `runnerCapabilities`
    /// payload that declares protocol 3 or newer. Absent in older manifests,
    /// which stay valid.
    private func runnerUpgradeContractFailure() -> String? {
        guard let runnerArtifact else { return nil }
        if runnerArtifact.role != .runner {
            return "runner upgrade artifact declares role '\(runnerArtifact.role.rawValue)'; it must be the distinct 'runner' role, never 'disk'"
        }
        if let duplicate = artifacts?.first(where: { $0.role == .runner }) {
            let duplicateDigest = duplicate.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let runnerDigest = runnerArtifact.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if duplicate.path != runnerArtifact.path
                || duplicate.bytes != runnerArtifact.bytes
                || duplicateDigest != runnerDigest {
                return "runner upgrade artifact and its runner digest entry disagree"
            }
        }
        let capabilities = runnerCapabilities?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if capabilities.isEmpty {
            return "manifest declares a runner upgrade artifact but no runnerCapabilities payload; an in-guest upgrade would have nothing to verify"
        }
        let declaresProtocol = capabilities.split(separator: " ").contains { field in
            guard field.hasPrefix("protocol=") else { return false }
            return (Int(field.dropFirst("protocol=".count)) ?? 0) >= LinuxGuestFraming.requiredProtocol
        }
        if !declaresProtocol {
            return "runnerCapabilities '\(capabilities)' does not declare protocol \(LinuxGuestFraming.requiredProtocol) or newer"
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
    /// Waits for the engine run loop to actually exit and reports running
    /// state truthfully the whole time (isRunning stays true until the VM
    /// thread left its last slice). A later startGuest works immediately
    /// after stopGuest returns.
    func stopGuest(environmentID: String) async
    /// Stops the guest and discards its runtime state while preserving the
    /// environment's persistent disk and shares. Resetting one environment
    /// never touches another environment's guest, disks or forwards; the
    /// next startGuest boots the same image and disk fresh.
    func resetGuest(environmentID: String) async
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

/// First-boot network state the runner reports in its capability answer
/// (`net=up|partial|down`, see LinuxGuest/runner/floe_net.h). `up` means the
/// interface, default route and resolver file were applied and one resolver
/// in the runner's ordered plan (slirp's own 10.0.2.3 alias first) answered a
/// bounded query; `partial` means the interface is configured but no resolver
/// answered; `down` means the interface could not be configured. A runner
/// that predates the field reports nothing and is reported as `nil`
/// (unknown), never as ready.
public enum LinuxGuestNetworkStatus: String, Sendable, Equatable, CaseIterable {
    case up
    case partial
    case down

    /// Parses the `net=` field out of a FLOE-CAPS payload. Unknown or missing
    /// values return nil so a legacy runner is never mistaken for a working
    /// network.
    public static func from(capabilities: String?) -> LinuxGuestNetworkStatus? {
        guard let capabilities else { return nil }
        for field in capabilities.split(separator: " ") where field.hasPrefix("net=") {
            return LinuxGuestNetworkStatus(rawValue: String(field.dropFirst("net=".count)))
        }
        return nil
    }

    /// Only `up` is a working network. `partial` is deliberately not ready:
    /// package managers will fail with name-resolution errors.
    public var isReady: Bool { self == .up }

    /// Honest, non-alarming diagnostic. Localized UI text is separate.
    public var diagnostic: String? {
        switch self {
        case .up: return nil
        case .partial:
            return "the guest interface and route are up but DNS did not answer; apt/pip/npm will fail with name-resolution errors"
        case .down:
            return "the guest network interface could not be configured; apt/pip/npm and guest git fetches will not work"
        }
    }
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
    /// Set by the last resetGuest/stopGuest: describes exactly what the
    /// operation affected (this environment only; disks preserved on reset).
    public var lastResetSharedImpact: String?
    /// Guests currently holding an admission slot (running VMs plus starts in
    /// flight), and the RAM reserved by them. Reported so the UI can explain
    /// a capacity refusal without guessing; nil when the service did not
    /// report capacity.
    public var activeGuestCount: Int?
    public var reservedGuestRAMMB: Int?
    /// Start requests currently waiting in the admission queue (Runtime v2:
    /// at most four VMs run and further requests queue instead of failing).
    /// nil when the service has no queue.
    public var queuedGuestCount: Int?
    /// First-boot network state reported by the running runner. nil means the
    /// runner did not report one (older runner) — an unknown state, not a
    /// working one.
    public var networkStatus: LinuxGuestNetworkStatus?
    /// Non-nil when the environment disk's logical capacity was grown (or
    /// already grew) but the in-guest ext4 filesystem could not be extended
    /// to match. The guest still runs at its previous filesystem capacity;
    /// the UI exposes this as a repair/update state instead of pretending the
    /// full disk is available.
    public var diskResizeFailure: String?

    public init(
        environmentID: String,
        running: Bool,
        imageID: String? = nil,
        ramMB: Int? = nil,
        startedAt: Date? = nil,
        lastError: String? = nil,
        imageInstalled: Bool? = nil,
        imageVerificationFailure: String? = nil,
        imageDistributable: Bool? = nil,
        lastResetSharedImpact: String? = nil,
        activeGuestCount: Int? = nil,
        reservedGuestRAMMB: Int? = nil,
        networkStatus: LinuxGuestNetworkStatus? = nil,
        diskResizeFailure: String? = nil,
        queuedGuestCount: Int? = nil
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
        self.lastResetSharedImpact = lastResetSharedImpact
        self.activeGuestCount = activeGuestCount
        self.reservedGuestRAMMB = reservedGuestRAMMB
        self.networkStatus = networkStatus
        self.diskResizeFailure = diskResizeFailure
        self.queuedGuestCount = queuedGuestCount
    }
}

/// One cumulative CPU-time sample for the host thread that executes emulator
/// slices. The metrics sampler turns two samples into a host-side CPU fraction
/// (a proxy for vCPU usage). Wall time uses a monotonic clock.
public struct LinuxGuestEmulatorCPUSample: Sendable, Equatable {
    public let cpuNanos: UInt64
    public let wallNanos: UInt64

    public init(cpuNanos: UInt64, wallNanos: UInt64) {
        self.cpuNanos = cpuNanos
        self.wallNanos = wallNanos
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
