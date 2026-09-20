// FloeExecution — verified image → engine-ready runtime boot files.
//
// `<image root>/<id>` holds the immutable, verified qualification artifact:
// manifests declare their paths relative to that directory and the verifier
// hashes the bytes there before a start is allowed. The TinyEMU engine only
// receives C paths, though, and it must not be handed relative paths (the app
// has no usable cwd) nor the shared base disk (a booted guest writes its own
// APT state; writing the qualification bytes would corrupt verification and
// every environment). This type is the one translation from a verified
// manifest to what the engine can actually boot:
//
//  - bios/kernel/initrd resolve to absolute, regular files inside the image
//    directory; they are used in place, so the verified bytes are the booted
//    bytes and the manifest digests stay meaningful;
//  - the disk is copied once per environment into
//    `<writableDirectory>/LinuxGuest/disks/<environmentID>/disk.img` through a
//    sibling staging file and an atomic rename, then reused across restarts so
//    packages installed in the guest survive a stop/start;
//  - a sidecar records the origin image id and the declared base digest. An
//    existing environment disk prepared from a different verified base is a
//    conflict: it is reported, never silently overwritten, because it is the
//    user's environment state.
//
// Failed or cancelled preparations only ever remove their own staging files;
// the verified base and an already promoted environment disk are untouched.

import Darwin
import Foundation
import FloeCore

/// Preparation failures for one guest start. Every case names the missing or
/// conflicting path so the caller can report an honest reason; nothing here
/// falls back to a temporary directory.
enum LinuxGuestRuntimeImageError: Error, LocalizedError, Sendable, Equatable {
    case artifactUnavailable(role: String, path: String, reason: String)
    case artifactEscapesImageDirectory(role: String, path: String)
    case writableRootMissing(environmentID: String, path: String)
    case diskPreparationFailed(path: String, reason: String)
    case diskOriginConflict(disk: String, existing: String, verified: String)

    var errorDescription: String? {
        switch self {
        case .artifactUnavailable(let role, let path, let reason):
            return "Linux guest \(role) is unavailable at \(path): \(reason)"
        case .artifactEscapesImageDirectory(let role, let path):
            return "Linux guest \(role) escapes the verified image directory: \(path)"
        case .writableRootMissing(let environmentID, let path):
            return "Linux environment \(environmentID) has no persistent writable root (\(path)); refusing to create the guest disk in a temporary location"
        case .diskPreparationFailed(let path, let reason):
            return "cannot prepare the Linux guest disk at \(path): \(reason)"
        case .diskOriginConflict(let disk, let existing, let verified):
            return "Linux environment disk \(disk) was created from \(existing), the verified image is \(verified), and the manifest declares no compatible predecessor origin; refusing to overwrite the environment state"
        }
    }
}

/// Sidecar next to one environment disk. `artifactSHA512` is the digest the
/// verified manifest declared for the base disk when this environment disk was
/// first copied; later starts compare against that record — never against a
/// re-hash of the (intentionally mutated) environment copy.
struct LinuxGuestRuntimeDiskOrigin: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var imageID: String
    var artifactSHA512: String
    var artifactBytes: Int64
    var createdAt: Date

    init(
        imageID: String,
        artifactSHA512: String,
        artifactBytes: Int64,
        createdAt: Date = Date()
    ) {
        self.version = Self.currentVersion
        self.imageID = imageID
        self.artifactSHA512 = artifactSHA512
        self.artifactBytes = artifactBytes
        self.createdAt = createdAt
    }

    var summary: String {
        "image \(imageID) (\(artifactSHA512.prefix(16))…, \(artifactBytes) bytes)"
    }
}

/// Runner-upgrade ledger next to one environment disk. The disk is a mutable
/// clone of a verified base image, so replacing the base image's runner does
/// NOT update the runner inside this disk; after the in-guest upgrade runs,
/// the guest-reported runner capability line is recorded here and later
/// starts skip the upgrade when it matches the current image's expectation.
struct LinuxGuestRuntimeRunnerState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// CAPS line the guest runner reported (e.g. "runner=2.0.0 protocol=3 …").
    var runnerCapabilities: String
    var upgradedAt: Date

    init(runnerCapabilities: String, upgradedAt: Date = Date()) {
        self.version = Self.currentVersion
        self.runnerCapabilities = runnerCapabilities
        self.upgradedAt = upgradedAt
    }
}

/// Turns a verified manifest into engine-ready paths. Stateless and
/// synchronous: the registry calls it inside the actor that already owns
/// digest verification, so nothing here re-verifies the base bytes.
struct LinuxGuestRuntimeImagePreparer: Sendable {
    /// Directory name under the environment's writable root. The disk lives
    /// below `<environmentID>` so even environments that share one writable
    /// layer cannot share package state.
    static let writableDirectoryName = "LinuxGuest"
    static let diskFileName = "disk.img"
    static let originFileName = "origin.json"
    static let runnerStateFileName = "runner.json"

    init() {}

    /// Directory that holds one environment's writable guest disk and its
    /// sidecars. Shared by prepare() and the runner-upgrade ledger.
    public static func environmentDiskDirectory(writableDirectory: URL, environmentID: String) -> URL {
        writableDirectory.standardizedFileURL
            .appendingPathComponent(writableDirectoryName, isDirectory: true)
            .appendingPathComponent("disks", isDirectory: true)
            .appendingPathComponent(environmentID, isDirectory: true)
    }

    // MARK: runner upgrade ledger

    /// The runner capability line recorded for this environment's disk, nil
    /// when the ledger is absent/unreadable (treated as "unknown — check the
    /// guest", never as "new").
    public static func recordedRunnerCapabilities(
        writableDirectory: URL,
        environmentID: String,
        fileManager: FileManager = .default
    ) -> String? {
        let url = environmentDiskDirectory(writableDirectory: writableDirectory, environmentID: environmentID)
            .appendingPathComponent(runnerStateFileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LinuxGuestRuntimeRunnerState.self, from: data),
              state.version == LinuxGuestRuntimeRunnerState.currentVersion else { return nil }
        return state.runnerCapabilities
    }

    /// Records the runner capability line the guest reported after a
    /// successful in-guest runner upgrade. Atomic write; a crash leaves the
    /// previous ledger (the next start re-checks the guest, which is safe).
    public static func recordRunnerCapabilities(
        _ capabilities: String,
        writableDirectory: URL,
        environmentID: String,
        fileManager: FileManager = .default
    ) throws {
        let directory = environmentDiskDirectory(writableDirectory: writableDirectory, environmentID: environmentID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(runnerStateFileName)
        let state = LinuxGuestRuntimeRunnerState(runnerCapabilities: capabilities)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    // MARK: verified artifact bytes

    /// Resolves one declared artifact path to a regular file inside the
    /// verified image directory and returns its bytes only after the size and
    /// SHA-512 recorded for it match. Shared by disk preparation and the
    /// in-guest runner upgrade so neither loads a path, symlink or byte count
    /// that the verifier never checked. The caller may still hold its own copy
    /// of the digest check, but the checks are the same on both paths.
    static func loadVerifiedArtifact(
        _ artifact: LinuxGuestImageArtifact,
        imageDirectory: URL,
        role: String,
        fileManager: FileManager = .default
    ) throws -> Data {
        let url = try Self.resolveArtifact(
            path: artifact.path,
            role: role,
            imageDirectory: imageDirectory,
            fileManager: fileManager
        )
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: url.path,
                reason: "cannot read the \(role): \(error.localizedDescription)"
            )
        }
        guard Int64(data.count) == artifact.bytes else {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: url.path,
                reason: "\(role) size mismatch: manifest declares \(artifact.bytes) bytes, the file has \(data.count)"
            )
        }
        let expected = artifact.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actual = FloeDigest.sha512Hex(data)
        guard actual == expected else {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: url.path,
                reason: "\(role) SHA-512 mismatch; the file bytes do not match the verified manifest"
            )
        }
        return data
    }

    /// Returns a copy of `image` whose boot paths are absolute files inside
    /// `imageDirectory` and whose disk (when declared) is the environment's
    /// own writable copy under `writableDirectory`.
    func prepare(
        image: LinuxGuestImage,
        imageDirectory: URL,
        environmentID: String,
        writableDirectory: URL?,
        fileManager: FileManager = .default
    ) throws -> LinuxGuestImage {
        try Task.checkCancellation()
        var runtime = image
        runtime.biosPath = try Self.resolveArtifact(
            path: image.biosPath,
            role: "bios",
            imageDirectory: imageDirectory,
            fileManager: fileManager
        ).path
        if let kernelPath = image.kernelPath {
            runtime.kernelPath = try Self.resolveArtifact(
                path: kernelPath,
                role: "kernel",
                imageDirectory: imageDirectory,
                fileManager: fileManager
            ).path
        }
        if let initrdPath = image.initrdPath {
            runtime.initrdPath = try Self.resolveArtifact(
                path: initrdPath,
                role: "initrd",
                imageDirectory: imageDirectory,
                fileManager: fileManager
            ).path
        }
        if let diskPath = image.diskPath {
            runtime.diskPath = try prepareEnvironmentDisk(
                diskPath: diskPath,
                image: image,
                imageDirectory: imageDirectory,
                environmentID: environmentID,
                writableDirectory: writableDirectory,
                fileManager: fileManager
            ).path
        }
        // A start that was cancelled while the disk was being prepared must
        // not hand a VM to the caller. A disk promoted just before this check
        // is complete and is simply reused by the next attempt.
        try Task.checkCancellation()
        return runtime
    }

    // MARK: internals

    /// Absolute path of one declared artifact. The manifest path may be
    /// relative (portable form) or absolute (local images); either way it must
    /// resolve to a regular file inside the verified image directory. Static
    /// and shared so the runner-upgrade path applies the same containment,
    /// symlink and regular-file checks as the boot artifacts.
    static func resolveArtifact(
        path: String,
        role: String,
        imageDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !path.isEmpty, !path.contains("\u{0}") else {
            throw LinuxGuestRuntimeImageError.artifactUnavailable(
                role: role,
                path: path,
                reason: "empty or invalid path"
            )
        }
        let declared = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : imageDirectory.appendingPathComponent(path)
        // A symlink artifact could point at bytes that were never verified.
        if (try? declared.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw LinuxGuestRuntimeImageError.artifactUnavailable(
                role: role,
                path: path,
                reason: "the artifact is a symbolic link"
            )
        }
        let root = imageDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = declared.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw LinuxGuestRuntimeImageError.artifactEscapesImageDirectory(role: role, path: path)
        }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw LinuxGuestRuntimeImageError.artifactUnavailable(
                role: role,
                path: resolved.path,
                reason: "not a regular file"
            )
        }
        return resolved
    }

    /// Prepares (once) or reuses the environment's writable disk.
    private func prepareEnvironmentDisk(
        diskPath: String,
        image: LinuxGuestImage,
        imageDirectory: URL,
        environmentID: String,
        writableDirectory: URL?,
        fileManager: FileManager
    ) throws -> URL {
        let base = try Self.resolveArtifact(
            path: diskPath,
            role: "disk",
            imageDirectory: imageDirectory,
            fileManager: fileManager
        )
        guard let declared = image.artifactDigest(role: .disk) else {
            throw LinuxGuestRuntimeImageError.artifactUnavailable(
                role: "disk",
                path: base.path,
                reason: "manifest records no disk digest"
            )
        }
        guard let writableDirectory, isSafePathComponent(environmentID) else {
            throw LinuxGuestRuntimeImageError.writableRootMissing(
                environmentID: environmentID,
                path: writableDirectory?.path ?? "<none>"
            )
        }
        let root = writableDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinuxGuestRuntimeImageError.writableRootMissing(
                environmentID: environmentID,
                path: root.path
            )
        }

        let directory = root
            .appendingPathComponent(Self.writableDirectoryName, isDirectory: true)
            .appendingPathComponent("disks", isDirectory: true)
            .appendingPathComponent(environmentID, isDirectory: true)
        let disk = directory.appendingPathComponent(Self.diskFileName)
        let originURL = directory.appendingPathComponent(Self.originFileName)

        if fileManager.fileExists(atPath: disk.path) {
            return try reuseExistingDisk(
                disk: disk,
                originURL: originURL,
                image: image,
                declared: declared,
                fileManager: fileManager
            )
        }

        try Task.checkCancellation()
        let stagingDisk = directory.appendingPathComponent("disk.staging-\(UUID().uuidString).img")
        let stagingOrigin = directory.appendingPathComponent("origin.staging-\(UUID().uuidString).json")
        defer {
            // Promotion renames the staging files away; whatever is left after
            // a failure or cancellation is this attempt's own scratch data.
            try? fileManager.removeItem(at: stagingDisk)
            try? fileManager.removeItem(at: stagingOrigin)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            let origin = LinuxGuestRuntimeDiskOrigin(
                imageID: image.id,
                artifactSHA512: declared.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                artifactBytes: declared.bytes
            )
            try Self.encodeOrigin(origin).write(to: stagingOrigin, options: .atomic)
            try Task.checkCancellation()
            try stageCopy(from: base, to: stagingDisk, fileManager: fileManager)
            try verifyStagedCopy(staging: stagingDisk, base: base, fileManager: fileManager)
            try Task.checkCancellation()

            // Promote the sidecar first: a crash between the two renames
            // leaves an origin without a disk, which the next start simply
            // replaces with a fresh copy. A disk without an origin would be an
            // unrecognized environment state and must be reported instead.
            try promote(stagingOrigin, to: originURL, role: "origin")
            do {
                try promote(stagingDisk, to: disk, role: "disk")
            } catch {
                try? fileManager.removeItem(at: originURL)
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LinuxGuestRuntimeImageError {
            throw error
        } catch {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: disk.path,
                reason: error.localizedDescription
            )
        }
        return disk
    }

    private func reuseExistingDisk(
        disk: URL,
        originURL: URL,
        image: LinuxGuestImage,
        declared: LinuxGuestImageArtifact,
        fileManager: FileManager
    ) throws -> URL {
        let verifiedDigest = declared.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let verified = "image \(image.id) (\(verifiedDigest.prefix(16))…)"
        guard let values = try? disk.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: disk.path,
                reason: "the existing environment disk is not a regular file"
            )
        }
        var origin: LinuxGuestRuntimeDiskOrigin?
        if let data = try? Data(contentsOf: originURL) {
            origin = try? Self.decodeOrigin(data)
        }
        if let origin, origin.version == LinuxGuestRuntimeDiskOrigin.currentVersion {
            if origin.imageID == image.id, origin.artifactSHA512 == verifiedDigest {
                return disk
            }
            // Runner-only component release: the manifest names the exact
            // predecessor base image(s) whose disks it may adopt. All three
            // recorded fields must match; the mutable disk and its original
            // origin.json stay exactly as they are (the origin is the honest
            // record of the bytes this disk was cloned from, and the runner is
            // replaced in-guest from the verified standalone artifact).
            if acceptsOrigin(origin, image: image) {
                return disk
            }
        }
        throw LinuxGuestRuntimeImageError.diskOriginConflict(
            disk: disk.path,
            existing: origin?.summary ?? "an unrecorded base",
            verified: verified
        )
    }

    /// True when the environment disk's recorded origin matches one of the
    /// manifest's declared compatible predecessors exactly (image id,
    /// SHA-512 and byte count). An unrelated origin never matches.
    private func acceptsOrigin(_ origin: LinuxGuestRuntimeDiskOrigin, image: LinuxGuestImage) -> Bool {
        guard let origins = image.compatibleOrigins, !origins.isEmpty else { return false }
        let originDigest = origin.artifactSHA512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return origins.contains { candidate in
            candidate.imageID.trimmingCharacters(in: .whitespacesAndNewlines) == origin.imageID
                && candidate.artifactSHA512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == originDigest
                && candidate.artifactBytes == origin.artifactBytes
        }
    }

    /// Copies the verified base to a sibling staging file. An APFS clone is
    /// preferred: it is O(1), copy-on-write, and later guest writes never
    /// reach the verified base. Filesystems without clone support fall back to
    /// an ordinary byte copy.
    private func stageCopy(from base: URL, to staging: URL, fileManager: FileManager) throws {
        if clonefile(base.path, staging.path, 0) == 0 {
            return
        }
        try fileManager.copyItem(at: base, to: staging)
    }

    /// A copy is as trustworthy as its length; re-hashing the whole disk on
    /// every first start would double the (already performed) verification
    /// cost without adding a guarantee the verifier has not already provided.
    private func verifyStagedCopy(staging: URL, base: URL, fileManager: FileManager) throws {
        let baseSize = (try? base.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let stagedSize = (try? staging.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let baseSize, let stagedSize, baseSize == stagedSize else {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: staging.path,
                reason: "staged copy size does not match the verified base"
            )
        }
        // Best-effort durability before the rename exposes the file; a
        // filesystem that cannot synchronize the handle still keeps the
        // staging/promote ordering.
        if let handle = try? FileHandle(forWritingTo: staging) {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    /// Same-directory rename; POSIX rename atomically replaces the sidecar and
    /// never exposes a partially copied disk.
    private func promote(_ staging: URL, to destination: URL, role: String) throws {
        guard rename(staging.path, destination.path) == 0 else {
            throw LinuxGuestRuntimeImageError.diskPreparationFailed(
                path: destination.path,
                reason: "cannot promote \(role): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("\u{0}") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 1, let only = components.first else { return false }
        return only != "." && only != ".."
    }

    /// JSONEncoder/JSONDecoder are not Sendable, so every caller builds its
    /// own; these values are tiny and only touched during preparation.
    private static func encodeOrigin(_ origin: LinuxGuestRuntimeDiskOrigin) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(origin)
    }

    private static func decodeOrigin(_ data: Data) throws -> LinuxGuestRuntimeDiskOrigin {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LinuxGuestRuntimeDiskOrigin.self, from: data)
    }
}
