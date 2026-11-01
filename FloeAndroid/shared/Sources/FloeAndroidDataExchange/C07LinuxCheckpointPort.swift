// SPDX-License-Identifier: MPL-2.0
//
// C07 -> C01 Linux environment checkpoint seam.
//
// A resolved Linux environment is owned by the C01 Linux authority (its UID,
// rootfs/overlay, jobs and runtime). C07 must NOT walk a host directory or
// copy a guest image as "data". This protocol is the honest port: C01 exports
// its own already-verified checkpoint artifacts and imports them as NEW
// environment identities, with an explicit old→new mapping and exact
// rollback. C07 owns the package plumbing only.
//
// No implementation is installed by this package. When absent, the backup
// manifest declares `linuxCheckpointPort: "unavailable"` with a reason and
// the UI does not claim environment portability.
import Foundation

public enum C07LinuxCheckpointWire {
    public static let version = 1
    public static let maximumEnvironments = 32
    public static let maximumFilesPerEnvironment = 4_096
    public static let maximumFileBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    public static let maximumEnvironmentBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
}

public struct C07LinuxCheckpointFileSource: Sendable, Equatable {
    public var relativePath: String
    public var url: URL
    public var byteCount: Int64
    public var sha256: String

    public init(relativePath: String, url: URL, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Serialized as the environment's `metadata.json` artifact. Contains no
/// secret and no host-absolute path.
public struct C07LinuxEnvironmentDescriptor: Codable, Sendable, Equatable {
    public var environmentID: UUID
    public var name: String
    public var runtimeKind: String
    public var checkpointFormat: String
    public var metadataJSON: String

    public init(environmentID: UUID, name: String, runtimeKind: String,
                checkpointFormat: String, metadataJSON: String) {
        self.environmentID = environmentID
        self.name = name
        self.runtimeKind = runtimeKind
        self.checkpointFormat = checkpointFormat
        self.metadataJSON = metadataJSON
    }
}

public struct C07LinuxEnvironmentExport: Sendable, Equatable {
    public var environmentID: UUID
    public var name: String
    public var runtimeKind: String
    public var checkpointFormat: String
    /// Non-secret environment metadata (resolution/backend/runtime generation).
    /// Never a credential, token, device key or host directory path.
    public var metadataJSON: String
    public var files: [C07LinuxCheckpointFileSource]

    public init(environmentID: UUID, name: String, runtimeKind: String,
                checkpointFormat: String, metadataJSON: String,
                files: [C07LinuxCheckpointFileSource]) {
        self.environmentID = environmentID
        self.name = String(name.prefix(240))
        self.runtimeKind = String(runtimeKind.prefix(64))
        self.checkpointFormat = String(checkpointFormat.prefix(64))
        self.metadataJSON = String(metadataJSON.prefix(65_536))
        self.files = Array(files.prefix(
            C07LinuxCheckpointWire.maximumFilesPerEnvironment))
    }
}

/// C01-owned implementation. Methods must use the real environment/checkpoint
/// authority and real UID ownership; throwing is the correct answer when the
/// authority is unavailable or the format is unsupported.
public protocol C07LinuxCheckpointPort: Sendable {
    var portVersion: Int { get }
    func exportEnvironments() async throws -> [C07LinuxEnvironmentExport]
    /// Allocates the new environment identities without mutating anything.
    /// The returned map is oldUUIDString -> newUUIDString and must cover
    /// every export. C07 journals this map before import.
    func planEnvironmentIdentities(_ exports: [C07LinuxEnvironmentExport])
        async throws -> [String: String]
    /// Imports with the already-journaled identities. Must fail closed when
    /// an identity is already owned by something else.
    func importEnvironments(_ exports: [C07LinuxEnvironmentExport],
                            stagedFiles: [String: URL],
                            identityMap: [String: String]) async throws
    /// Deletes only the exact environments created by importEnvironments.
    func rollbackEnvironments(ids: [UUID]) async throws
}

public enum C07LinuxCheckpointPortRegistry {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var port: (any C07LinuxCheckpointPort)?
    }

    private static let box = Box()

    public static func install(_ port: any C07LinuxCheckpointPort) {
        box.lock.lock(); defer { box.lock.unlock() }
        box.port = port
    }

    public static func uninstall() {
        box.lock.lock(); defer { box.lock.unlock() }
        box.port = nil
    }

    public static var installed: (any C07LinuxCheckpointPort)? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.port
    }

    public static var isAvailable: Bool {
        guard let port = installed else { return false }
        return port.portVersion >= C07LinuxCheckpointWire.version
    }
}
