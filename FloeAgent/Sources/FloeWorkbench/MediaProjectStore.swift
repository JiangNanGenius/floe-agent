// FloeWorkbench — Persistent project store.
//
// Projects are Floe-owned versioned JSON documents (stable UUID project ID),
// written atomically with compare-and-swap on revision. Undo/redo history is
// persisted WITH the project (see MediaProjectMemento) so reopening a
// workbench keeps its undo stack. Transaction semantics live in
// `MediaTransactions`; this actor owns load/save, migration and revision CAS.
//
// `commit(_:expectedRevision:)` validates and applies a command sequence via
// the shared engine, then persists the result with compare-and-swap: a
// concurrent manual change on disk rejects the whole commit, which is how
// stale AI proposals lose without mutating anything.

import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native hosts can hold an independent workspace/security-scope lease for
/// one write and verify its ownership immediately before durable commit.
/// A permit is host-issued; project metadata and tool arguments cannot make it.
public struct MediaProjectWritePermit: Sendable {
    public let validate: @Sendable () throws -> Void
    public let release: @Sendable () -> Void
    public init(validate: @escaping @Sendable () throws -> Void, release: @escaping @Sendable () -> Void) {
        self.validate = validate
        self.release = release
    }
}

public actor MediaProjectStore {
    public struct Limits: Sendable {
        public var maximumDocumentBytes: Int
        public var undoDepth: Int
        public init(maximumDocumentBytes: Int = 8 * 1024 * 1024, undoDepth: Int = 100) {
            self.maximumDocumentBytes = maximumDocumentBytes
            self.undoDepth = undoDepth
        }
    }

    nonisolated let directory: URL
    private let limits: Limits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let legacyMigrator: (@Sendable (URL) async throws -> MediaProject?)?
    private let acquireWritePermit: (@Sendable (UUID) async throws -> MediaProjectWritePermit)?
    public nonisolated let writePermitIdentity: String?
    public nonisolated let hasWritePermitProvider: Bool
#if DEBUG
    private var beforeCommitForTesting: (@Sendable () throws -> Void)?
    func setBeforeCommitForTesting(_ hook: (@Sendable () throws -> Void)?) {
        beforeCommitForTesting = hook
    }
#endif

    /// Canonical absolute path of the directory this store persists its
    /// `media-project-<uuid>.json` records into. Read-only identity: the app
    /// hands EXACTLY this value to the runtime's typed mutable-target
    /// contract (`TypedMutationContract.mediaProjectStoreKey`), so lease
    /// keys, the runtime-authority canonical target and the approval
    /// classification can never diverge from the real producer — including a
    /// custom/injected store directory chosen at init. It is never an
    /// authorization to write: the store's own atomic compare-and-swap
    /// commits remain the only writer.
    public nonisolated var storeRootPath: String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public init(directory: URL, limits: Limits = Limits(),
                legacyMigrator: (@Sendable (URL) async throws -> MediaProject?)? = nil,
                acquireWritePermit: (@Sendable (UUID) async throws -> MediaProjectWritePermit)? = nil,
                writePermitIdentity: String? = nil) {
        self.directory = directory
        self.limits = limits
        self.legacyMigrator = legacyMigrator
        self.acquireWritePermit = acquireWritePermit
        self.hasWritePermitProvider = acquireWritePermit != nil
        self.writePermitIdentity = acquireWritePermit == nil ? nil : writePermitIdentity
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: Paths

    public static func projectFileName(id: UUID) -> String {
        "media-project-\(id.uuidString.lowercased()).json"
    }

    public nonisolated func projectURL(id: UUID) -> URL {
        directory.appendingPathComponent(Self.projectFileName(id: id))
    }

    public struct ProjectSummary: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var name: String
        public var kind: MediaProjectKind
        public var revision: Int64
        public var updatedAt: Date
        public var ownerKind: String
        public var ownerID: UUID?
        public var environmentID: String?
        public var workspacePath: String?

        public init(id: UUID, name: String, kind: MediaProjectKind, revision: Int64,
                    updatedAt: Date, ownerKind: String, ownerID: UUID?,
                    environmentID: String?, workspacePath: String?) {
            self.id = id
            self.name = name
            self.kind = kind
            self.revision = revision
            self.updatedAt = updatedAt
            self.ownerKind = ownerKind
            self.ownerID = ownerID
            self.environmentID = environmentID
            self.workspacePath = workspacePath
        }
    }

    public func loadProject(at url: URL) async throws -> MediaProject? {
        if FileManager.default.fileExists(atPath: url.path) {
            return try readProject(from: url)
        }
        if let legacyMigrator, let migrated = try await legacyMigrator(url) {
            try await persist(migrated, expectedRevision: nil)
            return migrated
        }
        return nil
    }

    public func loadProject(id: UUID) async throws -> MediaProject? {
        let url = projectURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readProject(from: url)
    }

    public func listProjects() async throws -> [ProjectSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [ProjectSummary] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("media-project-") {
            guard let data = try? Data(contentsOf: entry),
                  let project = try? decoder.decode(MediaProject.self, from: data) else { continue }
            result.append(ProjectSummary(id: project.id, name: project.name, kind: project.kind,
                                         revision: project.revision, updatedAt: project.updatedAt,
                                         ownerKind: project.ownerKind, ownerID: project.ownerID,
                                         environmentID: project.environmentID,
                                         workspacePath: project.taskWorkspacePath))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func readProject(from url: URL) throws -> MediaProject {
        let data = try Data(contentsOf: url)
        guard data.count <= limits.maximumDocumentBytes else {
            throw FloeError.validationFailed("Project document exceeds \(limits.maximumDocumentBytes) bytes")
        }
        var project = try decoder.decode(MediaProject.self, from: data)
        if project.prepared?.schemaVersion == MediaPreparedCompounds.schemaVersion { try MediaPreparedIntegrity.validateEnvelope(project) }
        project.recoveryWarnings = MigrationSupport.recoveryWarnings(for: project)
        return project
    }

    // MARK: Persistence

    /// Atomically writes with optional compare-and-swap on revision. All
    /// transaction logic lives in the nonisolated `MediaTransactions` engine
    /// so the UI and model tool share draft-then-commit semantics without
    /// crossing actor boundaries with mutable state.
    ///
    /// Every write is additionally guarded against regression: a document
    /// with an older revision can never replace a newer one, and an equal
    /// revision must carry identical durable content. `expectedRevision`
    /// binds a caller to the exact base it loaded; omitting it is a claim of
    /// "this is the newest state I know of", never permission to roll back.
    @discardableResult
    public func save(_ project: MediaProject, expectedRevision: Int64? = nil) async throws -> URL {
        try await persist(project, expectedRevision: expectedRevision)
    }

    /// Native asset staging must hold the same owner lease as the eventual
    /// document commit, including if its presenting view disappears.
    public func beginOperationPermit(projectID: UUID) async throws -> MediaProjectWritePermit? {
        let permit = try await acquireWritePermit?(projectID)
        do { try permit?.validate(); return permit }
        catch { permit?.release(); throw error }
    }

    /// Creates a persisted fork of `id`: new identity, parent linkage, fresh
    /// undo/redo history, and reused immutable asset references. Callers bind
    /// an explicit "make variant" node or a copied node to the returned fork;
    /// the original project and its files are untouched.
    public func forkProject(id: UUID, nameSuffix: String = "variant") async throws -> MediaProject {
        guard let parent = try await loadProject(id: id) else {
            throw FloeError.notFound("project \(id.uuidString)")
        }
        var fork = parent
        fork.id = UUID()
        fork.name = "\(parent.name) · \(nameSuffix)"
        fork.createdAt = Date()
        fork.updatedAt = Date()
        fork.parentProjectID = parent.id
        fork.undoHistory = []
        fork.redoHistory = []
        if var prepared = fork.prepared {
            // A fork is a new document identity. Reuse the immutable asset
            // references and typed content, but bind the prepared document to
            // the fork identity/revision and start with an empty journal; the
            // parent's edit groups must not be undoable against the child.
            prepared.id = fork.id
            for ti in prepared.trackGraph.tracks.indices { for ci in prepared.trackGraph.tracks[ti].clips.indices {
                if var compound=prepared.trackGraph.tracks[ti].clips[ci].compound { compound.source.id=fork.id;compound.needsRender=true;prepared.trackGraph.tracks[ti].clips[ci].compound=compound }
            } }
            prepared.name = fork.name
            prepared.kind = fork.kind
            prepared.revision = fork.revision
            prepared.updatedAt = fork.updatedAt
            fork.prepared = prepared
            fork.preparedJournal = MediaPreparedJournal()
        }
        try await save(fork, expectedRevision: nil)
        return fork
    }

    private func persist(_ project: MediaProject, expectedRevision: Int64?) async throws -> URL {
        let permit = try await acquireWritePermit?(project.id)
        defer { permit?.release() }
        try permit?.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Different store actors may address the same project. Hold one
        // stable, never-replaced lock inode across the complete read/CAS/write
        // sequence; actor isolation alone only serializes one store instance.
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw FloeError.validationFailed("Media project directory is unavailable or was replaced") }
        defer { close(directoryFD) }
        var original = stat()
        guard fstat(directoryFD, &original) == 0, (original.st_mode & S_IFMT) == S_IFDIR else {
            throw FloeError.validationFailed("Media project directory is unavailable")
        }
        // The lock must not live in a user/guest-writable workspace. Replacing
        // a lock inode there would split two writers into separate lock domains.
        let lockRoot = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/MediaProjectLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
        let lockRootFD = open(lockRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lockRootFD >= 0 else { throw FloeError.validationFailed("Media project lock directory is unavailable") }
        defer { close(lockRootFD) }
        let lockName = "\(original.st_dev)-\(original.st_ino)-\(project.id.uuidString.lowercased()).lock"
        let lockFD = openat(lockRootFD, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else { throw FloeError.validationFailed("Media project lock is unavailable") }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG, lockInfo.st_nlink == 1 else {
            throw FloeError.validationFailed("Media project lock is invalid")
        }
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw FloeError.validationFailed("Media project lock could not be acquired")
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        try Task.checkCancellation()
        try permit?.validate()
        try verifyDirectory(original, descriptor: directoryFD)
        var currentLock = stat()
        guard fstatat(lockRootFD, lockName, &currentLock, AT_SYMLINK_NOFOLLOW) == 0,
              currentLock.st_dev == lockInfo.st_dev, currentLock.st_ino == lockInfo.st_ino,
              currentLock.st_nlink == 1 else {
            throw FloeError.validationFailed("Media project lock changed; reopen the project")
        }
#if canImport(Darwin)
        guard permit != nil else {
            return try persistLocked(project, expectedRevision: expectedRevision, directoryFD: directoryFD,
                                     directoryIdentity: original, permit: nil)
        }
        // Coordinate the actual write with File Provider / document
        // presenters. If coordination is unavailable, keep the original and
        // return an actionable error rather than writing around the provider.
        var coordinationError: NSError?
        var coordinatedResult: Result<URL, Error>?
        NSFileCoordinator().coordinate(writingItemAt: directory, options: .forMerging, error: &coordinationError) { coordinated in
            coordinatedResult = Result {
                guard coordinated.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw FloeError.validationFailed("The project location changed. Reopen it and retry.")
                }
                try permit?.validate()
                return try persistLocked(project, expectedRevision: expectedRevision, directoryFD: directoryFD,
                                         directoryIdentity: original, permit: permit)
            }
        }
        // A committed operation remains committed even if coordination later
        // reports an error; never invite a blind repeat after real success.
        if let coordinatedResult { return try coordinatedResult.get() }
        if coordinationError != nil { throw FloeError.validationFailed("The project location is unavailable. Reopen it or make it available offline, then retry.") }
        throw FloeError.validationFailed("The project could not be coordinated. Reopen it and retry.")
#else
        return try persistLocked(project, expectedRevision: expectedRevision, directoryFD: directoryFD, directoryIdentity: original, permit: permit)
#endif
    }

    private func verifyDirectory(_ expected: stat, descriptor: Int32) throws {
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(directory.path, &current) == 0,
              (current.st_mode & S_IFMT) == S_IFDIR,
              opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino,
              current.st_dev == expected.st_dev, current.st_ino == expected.st_ino else {
            throw FloeError.validationFailed("Media project directory moved or changed; reopen the project")
        }
    }

    private func sameVersion(_ first: stat, _ second: stat) -> Bool {
        guard first.st_dev == second.st_dev, first.st_ino == second.st_ino, first.st_size == second.st_size else { return false }
#if canImport(Darwin)
        return first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
#else
        return first.st_mtim.tv_sec == second.st_mtim.tv_sec && first.st_mtim.tv_nsec == second.st_mtim.tv_nsec
            && first.st_ctim.tv_sec == second.st_ctim.tv_sec && first.st_ctim.tv_nsec == second.st_ctim.tv_nsec
#endif
    }

    private func readBounded(_ descriptor: Int32, expected: stat) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var bytes = Data()
        while bytes.count <= limits.maximumDocumentBytes {
            let remaining = limits.maximumDocumentBytes + 1 - bytes.count
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        var after = stat()
        guard bytes.count <= limits.maximumDocumentBytes, Int64(bytes.count) == expected.st_size,
              fstat(descriptor, &after) == 0, sameVersion(expected, after) else {
            throw FloeError.validationFailed("Media project changed while reading; reopen it and try again")
        }
        return bytes
    }

    private func persistLocked(_ project: MediaProject, expectedRevision: Int64?, directoryFD: Int32,
                               directoryIdentity: stat, permit: MediaProjectWritePermit?) throws -> URL {
        let url = projectURL(id: project.id)
        let filename = Self.projectFileName(id: project.id)
        let existingFD = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let onDisk: MediaProject?
        var existingIdentity: stat?
        var existingBytes: Data?
        if existingFD >= 0 {
            defer { close(existingFD) }
            var info = stat()
            guard fstat(existingFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= Int64(limits.maximumDocumentBytes) else {
                throw FloeError.validationFailed("Media project is unavailable or invalid")
            }
            existingIdentity = info
            let bytes = try readBounded(existingFD, expected: info)
            existingBytes = bytes
            var loaded = try decoder.decode(MediaProject.self, from: bytes)
            if loaded.prepared?.schemaVersion == MediaPreparedCompounds.schemaVersion { try MediaPreparedIntegrity.validateEnvelope(loaded) }
            loaded.recoveryWarnings = MigrationSupport.recoveryWarnings(for: loaded)
            onDisk = loaded
        } else if errno == ENOENT {
            onDisk = nil
        } else {
            throw FloeError.validationFailed("Media project is unavailable or was replaced")
        }
        if project.prepared != nil {
            // A prepared write must remain coherent with the v1 envelope and
            // carry a valid journal. Fail closed before touching the file.
            try MediaPreparedIntegrity.validateEnvelope(project)
        }
        if let onDisk {
            if onDisk.prepared != nil {
                try MediaPreparedIntegrity.validateEnvelope(onDisk)
            }
            // Never let an older build/schema replace a newer document.
            guard project.schemaVersion >= onDisk.schemaVersion else {
                throw FloeError.validationFailed(
                    "Project schema conflict: refusing to replace schema v\(onDisk.schemaVersion) with v\(project.schemaVersion)")
            }
            // A v2 document can never be silently dropped or replaced by a
            // v1-only projection (old autosave, copied snapshot, downgrade).
            if onDisk.prepared != nil && project.prepared == nil {
                throw FloeError.validationFailed(
                    "Prepared project conflict: refusing to drop prepared v2 content")
            }
            if project.prepared != nil
                && !MediaPreparedIntegrity.v1ProjectionEqual(project, onDisk)
                && !MediaPreparedIntegrity.allowsPreparedCanvasTransition(project, from:onDisk) {
                throw FloeError.validationFailed(
                    "Prepared project conflict: v1 content changed without a prepared-document transaction")
            }
            // No-regression defense shared by every write path, including a
            // UI autosave that carries no transaction base of its own: an
            // older snapshot must never overwrite a newer document, and an
            // equal revision must match the durable content exactly. An
            // equal revision with different content is a real conflict
            // (undo/redo advance the revision, so legitimate history never
            // needs to reuse a revision number).
            guard project.revision >= onDisk.revision else {
                throw FloeError.validationFailed(
                    "Project revision conflict: refusing to replace revision \(onDisk.revision) with stale revision \(project.revision)")
            }
            if project.revision == onDisk.revision,
               try canonicalDocumentData(project) != canonicalDocumentData(onDisk) {
                throw FloeError.validationFailed(
                    "Project revision conflict: the document changed contents at revision \(project.revision)")
            }
            if let expectedRevision, onDisk.revision != expectedRevision {
                throw FloeError.validationFailed("Project revision conflict: document changed since the transaction started")
            }
        } else if expectedRevision != nil {
            // A caller that loaded a base document never expects it to be
            // gone; silently recreating a deleted document would hide data
            // loss. Brand-new projects pass `nil` and remain valid.
            throw FloeError.validationFailed(
                "Project revision conflict: the base document is missing")
        }
        let data = try encoder.encode(project)
        guard data.count <= limits.maximumDocumentBytes else {
            throw FloeError.validationFailed("Project document exceeds \(limits.maximumDocumentBytes) bytes")
        }
        let staging = ".floe-project-\(UUID().uuidString).tmp"
        let stagingFD = openat(directoryFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard stagingFD >= 0 else { throw FloeError.validationFailed("Unable to stage the media project") }
        defer { close(stagingFD); _ = unlinkat(directoryFD, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(stagingFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FloeError.validationFailed("Unable to save the media project") }
                offset += count
            }
        }
#if DEBUG
        try beforeCommitForTesting?()
#endif
        try verifyDirectory(directoryIdentity, descriptor: directoryFD)
        try permit?.validate()
        var current = stat()
        let present = fstatat(directoryFD, filename, &current, AT_SYMLINK_NOFOLLOW) == 0
        if let original = existingIdentity {
            guard present, (current.st_mode & S_IFMT) == S_IFREG,
                  sameVersion(original, current) else {
                throw FloeError.validationFailed("Media project changed; reopen it and try again")
            }
            let currentFD = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard currentFD >= 0 else { throw FloeError.validationFailed("Media project changed; reopen it and try again") }
            defer { close(currentFD) }
            var opened = stat()
            guard let existingBytes, fstat(currentFD, &opened) == 0, sameVersion(original, opened),
                  try readBounded(currentFD, expected: opened) == existingBytes else {
                throw FloeError.validationFailed("Media project changed; reopen it and try again")
            }
        } else if present || errno != ENOENT {
            throw FloeError.validationFailed("Media project changed; reopen it and try again")
        }
        guard renameat(directoryFD, staging, directoryFD, filename) == 0 else {
            throw FloeError.validationFailed("Unable to commit the media project; reopen it and try again")
        }
        return url
    }

    /// Durable identity of a revision. Load-time recovery warnings are
    /// recomputed from the document on every open, so they are excluded from
    /// the comparison; everything the user can edit stays in.
    private func canonicalDocumentData(_ project: MediaProject) throws -> Data {
        try Self.canonicalContentData(project)
    }

    /// Deterministic durable-content projection shared by every reader of a
    /// project document: the store's compare-and-swap guards and the app's
    /// "is this draft already saved" check both go through this one codec, so
    /// neither side can drift into a private, non-canonical encoding.
    ///
    /// It matches the bytes this store writes (sorted keys, ISO-8601 dates) and
    /// therefore normalizes the sub-second date precision an in-memory draft
    /// carries against the whole-second dates a document read back from disk
    /// carries: the same durable content always canonicalizes identically.
    /// Only load-derived `recoveryWarnings` are excluded (they are recomputed
    /// on every open and are not user edit state).
    ///
    /// Throws instead of returning an unfaithful value, so callers can fail
    /// closed rather than treating "could not encode" as "unchanged".
    public nonisolated static func canonicalContentData(_ project: MediaProject) throws -> Data {
        var canonical = project
        canonical.recoveryWarnings = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(canonical)
    }
}
