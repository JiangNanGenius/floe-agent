// FloeSkills — transactional store for signed declarative content.
//
// One actor owns every content byte and the single active manifest:
//   * packages are staged into immutable, digest-addressed version dirs;
//   * a batch is validated as a whole, staged as a whole, and only then
//     committed by one atomic manifest write;
//   * a failed commit removes only the new staging dirs, so the previous
//     active versions stay exactly as they were (no half-upgrade);
//   * rollback re-points the manifest at a retained real package (never a
//     synthesized entry);
//   * run snapshots freeze id → directory so a running task keeps its
//     versions even if the active manifest later moves.
//
// No network and no UI state live here. The app facade performs authenticated
// fetches on the main actor and hands verified bytes to this actor; ZIP
// extraction, hashing, manifest IO and pruning never run on the UI thread.

import Foundation
import FloeCore

public struct ContentUpdateState: Codable, Sendable, Equatable {
    public struct StoredEntry: Codable, Sendable, Equatable {
        public var entry: SignedContentEntry
        /// Version directory relative to the store root.
        public var directory: String
        public var installedAt: Date

        public init(entry: SignedContentEntry, directory: String, installedAt: Date) {
            self.entry = entry
            self.directory = directory
            self.installedAt = installedAt
        }
    }

    public struct RunSnapshot: Codable, Sendable, Equatable {
        /// id → active version directory at snapshot time.
        public var directories: [String: String]
        /// id → built-in baseline version that was authoritative for this run
        /// (app-owned content with no installed package). A later app upgrade
        /// must not silently substitute its new bundle for a recovered run.
        public var builtInVersions: [String: String]?
        /// id → frozen built-in bytes directory in the store, so recovery
        /// reads the exact bytes the run started with even after the app
        /// bundle changed.
        public var builtInDirectories: [String: String]?
        public var createdAt: Date

        public init(
            directories: [String: String],
            builtInVersions: [String: String]? = nil,
            builtInDirectories: [String: String]? = nil,
            createdAt: Date
        ) {
            self.directories = directories
            self.builtInVersions = builtInVersions
            self.builtInDirectories = builtInDirectories
            self.createdAt = createdAt
        }
    }

    public var schemaVersion: Int = 1
    public var revision: Int = 0
    public var entries: [String: StoredEntry] = [:]
    /// Newest-first retained previous versions per id. Dirs are never deleted
    /// while they are referenced by an entry, history or a run snapshot.
    public var history: [String: [StoredEntry]] = [:]
    public var pinned: [String: String] = [:]
    public var runSnapshots: [String: RunSnapshot] = [:]
    /// Every id@version digest ever activated on this device. A same-version
    /// different digest is immutable even after rollback or deactivation, so
    /// a previously published version can never be replaced later.
    public var seenLedger: [String: [String: String]]?
    /// Set after a failed check; the facade stops automatic retries until it.
    public var retryAfter: Date?

    public init() {}

    public var ledger: [String: [String: String]] {
        get { seenLedger ?? [:] }
        set { seenLedger = newValue }
    }
}

public enum ContentUpdateStoreError: Error, Equatable, LocalizedError {
    case storage(String)
    case corruptState(String)
    case conflict(String)
    case staging(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .storage(let detail): "Content storage unavailable: \(detail)"
        case .corruptState(let detail): "Content state is unreadable: \(detail)"
        case .conflict(let reason): "Content update rejected: \(reason)"
        case .staging(let detail): "Content staging failed: \(detail)"
        case .persistence(let detail): "Content update could not be saved: \(detail)"
        }
    }
}

public actor ContentUpdateStore {
    public struct BatchItem: Sendable {
        public let entry: SignedContentEntry
        public let zip: Data
        public init(entry: SignedContentEntry, zip: Data) {
            self.entry = entry
            self.zip = zip
        }
    }

    public struct PlannedItem: Sendable {
        public let entry: SignedContentEntry
        public let decision: ContentUpdateDecision
    }

    public struct Plan: Sendable {
        public var items: [String: PlannedItem]
        public var orderedIDs: [String]
    }

    nonisolated public let root: URL
    private let stateURL: URL
    private let versionsURL: URL
    private var state: ContentUpdateState
    private static let maximumHistory = 5

    public init(root: URL) throws {
        self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw ContentUpdateStoreError.storage(error.localizedDescription)
        }
        self.stateURL = root.appendingPathComponent("active.json", isDirectory: false)
        self.versionsURL = root.appendingPathComponent("versions", isDirectory: true)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                let data = try Data(contentsOf: stateURL)
                let decoded = try JSONDecoder().decode(ContentUpdateState.self, from: data)
                guard decoded.schemaVersion == 1 else {
                    throw ContentUpdateStoreError.corruptState("unsupported schema \(decoded.schemaVersion)")
                }
                self.state = decoded
            } catch let error as ContentUpdateStoreError {
                throw error
            } catch {
                throw ContentUpdateStoreError.corruptState(error.localizedDescription)
            }
        } else {
            self.state = ContentUpdateState()
        }
        // Pruning is safe: anything not referenced by the manifest, retained
        // history or a run snapshot is an abandoned stage. Run snapshots are
        // never time-pruned; they are released only through explicit task
        // lifecycle calls.
        Self.pruneUnreferenced(root: root, versionsURL: versionsURL, state: self.state)
        Self.backfillLedger(state: &self.state)
    }

    // MARK: - State access

    public func currentState() -> ContentUpdateState { state }

    @discardableResult
    public func reload() -> ContentUpdateState { state }

    // MARK: - Feed verification (off the UI thread)

    public func verifyFeed(
        index: Data,
        signature: Data,
        trustedKeys: [String: Data],
        allowedKinds: Set<SignedContentKind> = Set(SignedContentKind.allCases)
    ) throws -> SignedContentFeed {
        try SignedContentFeedVerifier.verify(
            feed: index, signature: signature, trustedKeys: trustedKeys, allowedKinds: allowedKinds
        )
    }

    /// Dependency-ordered plan. A dependency counts as satisfied only when it
    /// is already active or selected for activation in this same plan; a feed
    /// id that is merely present without an installable version blocks its
    /// dependents instead of pretending to satisfy them.
    public func plan(feed: SignedContentFeed, appVersion: String) throws -> Plan {
        var satisfied = Set(state.entries.keys)
        var items: [String: PlannedItem] = [:]
        var ordered: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: feed.entries.map { ($0.id, $0) })
        var visiting: Set<String> = []

        func decide(_ entry: SignedContentEntry) throws {
            guard !items.keys.contains(entry.id) else { return }
            guard visiting.insert(entry.id).inserted else {
                throw ContentUpdateStoreError.conflict("dependency cycle at \(entry.id)")
            }
            defer { visiting.remove(entry.id) }
            for dependency in entry.dependencies where state.entries[dependency] == nil {
                if let dependencyEntry = byID[dependency] {
                    try decide(dependencyEntry)
                }
            }
            let current = state.entries[entry.id]
            let decision = (try? ContentVersionPolicy.decide(
                entry: entry,
                installedVersion: current?.entry.version,
                installedDigest: current?.entry.contentDigest,
                appVersion: appVersion,
                pinnedVersion: state.pinned[entry.id],
                availableDependencyIDs: satisfied
            )) ?? .blocked(reason: .feedFailure, version: entry.version)
            items[entry.id] = PlannedItem(entry: entry, decision: decision)
            ordered.append(entry.id)
            if decision.isUpdate { satisfied.insert(entry.id) }
        }

        for entry in feed.entries { try decide(entry) }
        return Plan(items: items, orderedIDs: ordered)
    }

    // MARK: - Commit

    /// Validates the whole batch against the current state, stages every
    /// package, then commits with one atomic manifest write. Any failure
    /// leaves the previous state and bytes active.
    @discardableResult
    public func commit(
        _ batch: [BatchItem],
        appVersion: String,
        allowedCapabilities: Set<String>,
        domainValidate: @escaping @Sendable (SignedContentEntry, [String: Data]) throws -> Void
    ) throws -> ContentUpdateState {
        guard !batch.isEmpty else { return state }
        var seen: Set<String> = []
        for item in batch {
            guard seen.insert(item.entry.id).inserted else {
                throw ContentUpdateStoreError.conflict("duplicate entry \(item.entry.id) in one batch")
            }
        }
        let batchIDs = Set(batch.map(\.entry.id))
        let ledger = state.ledger

        // 1. Whole-batch validation before any bytes are written.
        for item in batch {
            let entry = item.entry
            guard entry.isCompatible(appVersion: appVersion) else {
                throw ContentUpdateStoreError.conflict("incompatibleApp \(entry.id)@\(entry.version)")
            }
            for capability in entry.requiredCapabilities {
                guard SkillCapability(rawValue: capability) != nil,
                      capability != SkillCapability.credentials.rawValue,
                      allowedCapabilities.contains(capability) else {
                    throw ContentUpdateStoreError.conflict("unsupported capability \(capability) for \(entry.id)")
                }
            }
            for dependency in entry.dependencies {
                guard state.entries[dependency] != nil || batchIDs.contains(dependency) else {
                    throw ContentUpdateStoreError.conflict("missingDependency \(dependency) for \(entry.id)")
                }
            }
            // Published bytes are immutable for the lifetime of the device,
            // including versions that were rolled back or deactivated.
            if let previouslySeen = ledger[entry.id]?[entry.version],
               previouslySeen != entry.contentDigest.lowercased() {
                throw ContentUpdateStoreError.conflict("immutableVersion \(entry.id)@\(entry.version)")
            }
            if let current = state.entries[entry.id] {
                guard let remote = try? SignedContentVersion(entry.version),
                      let installed = try? SignedContentVersion(current.entry.version) else {
                    throw ContentUpdateStoreError.conflict("invalid version \(entry.id)")
                }
                if remote < installed {
                    throw ContentUpdateStoreError.conflict("downgrade \(entry.id) \(entry.version) < \(current.entry.version)")
                }
                if remote == installed, current.entry.contentDigest != entry.contentDigest {
                    throw ContentUpdateStoreError.conflict("immutableVersion \(entry.id)@\(entry.version)")
                }
                if let pinned = state.pinned[entry.id], pinned == current.entry.version, remote > installed {
                    throw ContentUpdateStoreError.conflict("pinned \(entry.id)@\(pinned)")
                }
            }
        }

        // 2. Stage every package into an immutable version directory.
        var stagedDirectories: [String: String] = [:]
        var createdDirectories: [URL] = []
        do {
            for item in batch {
                let entry = item.entry
                let digest = entry.contentDigest.lowercased()
                let folder = "versions/\(entry.id)/\(entry.version)-\(digest.prefix(12))"
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                if FileManager.default.fileExists(atPath: directory.path) {
                    // A reused directory still goes through the domain codec:
                    // schema validation must never be skipped just because the
                    // bytes were already staged once.
                    let files = try Self.readFiles(at: directory)
                    guard SignedContentArchive.canonicalDigest(files) == digest else {
                        throw ContentUpdateStoreError.staging("existing dir digest mismatch \(entry.id)")
                    }
                    try domainValidate(entry, files)
                } else {
                    try FileManager.default.createDirectory(
                        at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    createdDirectories.append(directory)
                    let files = try SignedContentInstaller.stage(
                        zip: item.zip, entry: entry, at: directory,
                        domainValidate: domainValidate
                    ).files
                    guard SignedContentArchive.canonicalDigest(files) == digest else {
                        throw ContentUpdateStoreError.staging("digest mismatch \(entry.id)")
                    }
                }
                stagedDirectories[entry.id] = folder
            }
        } catch {
            for directory in createdDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }

        // 3. One manifest write commits the batch.
        var next = state
        let now = Date()
        for item in batch {
            let entry = item.entry
            let folder = stagedDirectories[entry.id] ?? ""
            if let current = state.entries[entry.id] {
                if current.entry.version == entry.version,
                   current.entry.contentDigest == entry.contentDigest {
                    continue
                }
                var history = next.history[entry.id] ?? []
                if !history.contains(where: {
                    $0.entry.version == current.entry.version && $0.entry.contentDigest == current.entry.contentDigest
                }) {
                    history.insert(current, at: 0)
                }
                next.history[entry.id] = Array(history.prefix(Self.maximumHistory))
            }
            next.entries[entry.id] = ContentUpdateState.StoredEntry(
                entry: entry, directory: folder, installedAt: now
            )
        }
        var nextLedger = next.ledger
        for item in batch {
            var versions = nextLedger[item.entry.id] ?? [:]
            versions[item.entry.version] = item.entry.contentDigest.lowercased()
            nextLedger[item.entry.id] = versions
        }
        next.ledger = nextLedger
        next.revision += 1
        next.retryAfter = nil
        do {
            try write(next)
        } catch {
            for directory in createdDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
        state = next
        return state
    }

    // MARK: - Rollback / pin / built-in takeover

    @discardableResult
    public func rollback(id: String, appVersion: String, toVersion: String? = nil) throws -> ContentUpdateState {
        let current = state.entries[id]
        let candidates = (state.history[id] ?? []).filter {
            toVersion == nil || $0.entry.version == toVersion
        }
        guard let target = candidates.first else {
            throw ContentUpdateStoreError.conflict("no retained version to roll back to for \(id)")
        }
        // Restoring old bytes must satisfy the same app-compatibility and
        // dependency contract as a forward install; a device that no longer
        // meets the contract fails closed instead of running mismatched
        // content.
        guard target.entry.isCompatible(appVersion: appVersion) else {
            throw ContentUpdateStoreError.conflict("incompatibleApp rollback \(id)@\(target.entry.version)")
        }
        for dependency in target.entry.dependencies {
            guard state.entries[dependency] != nil else {
                throw ContentUpdateStoreError.conflict("missingDependency \(dependency) for rollback \(id)")
            }
        }
        if let recorded = state.ledger[id]?[target.entry.version],
           recorded != target.entry.contentDigest.lowercased() {
            throw ContentUpdateStoreError.conflict("immutableVersion rollback \(id)@\(target.entry.version)")
        }
        let directory = try Self.resolve(directory: target.directory, under: root)
        let files = try Self.readFiles(at: directory)
        guard SignedContentArchive.canonicalDigest(files) == target.entry.contentDigest.lowercased() else {
            throw ContentUpdateStoreError.staging("rollback bytes no longer match \(id)")
        }
        var next = state
        var history = next.history[id] ?? []
        history.removeAll { $0.entry.version == target.entry.version && $0.entry.contentDigest == target.entry.contentDigest }
        if let current,
           !history.contains(where: {
               $0.entry.version == current.entry.version && $0.entry.contentDigest == current.entry.contentDigest
           }) {
            history.insert(current, at: 0)
        }
        next.history[id] = Array(history.prefix(Self.maximumHistory))
        next.entries[id] = target
        // Explicit rollback from an active version pins the restored version
        // so automatic updates do not immediately re-apply the reverted
        // release. A restore from history after deactivation is not a user
        // pin and follows normal policy afterwards.
        if current != nil {
            next.pinned[id] = target.entry.version
        }
        next.revision += 1
        try write(next)
        state = next
        return state
    }

    @discardableResult
    public func setPinned(id: String, version: String?) throws -> ContentUpdateState {
        var next = state
        if let version {
            next.pinned[id] = version
        } else {
            next.pinned.removeValue(forKey: id)
        }
        next.revision += 1
        try write(next)
        state = next
        return state
    }

    /// App-bundle takeover: a newer built-in baseline deactivates the
    /// installed copy (retained in history) so the app-owned version wins.
    @discardableResult
    public func deactivate(id: String) throws -> ContentUpdateState {
        guard let current = state.entries[id] else { return state }
        var next = state
        var history = next.history[id] ?? []
        if !history.contains(where: {
            $0.entry.version == current.entry.version && $0.entry.contentDigest == current.entry.contentDigest
        }) {
            history.insert(current, at: 0)
        }
        next.history[id] = Array(history.prefix(Self.maximumHistory))
        next.entries.removeValue(forKey: id)
        next.revision += 1
        try write(next)
        state = next
        return state
    }

    // MARK: - Retry policy persistence

    @discardableResult
    public func recordCheckFailure(retryAfter: Date) throws -> ContentUpdateState {
        var next = state
        next.retryAfter = retryAfter
        try write(next)
        state = next
        return state
    }

    @discardableResult
    public func recordCheckSuccess() throws -> ContentUpdateState {
        guard state.retryAfter != nil else { return state }
        var next = state
        next.retryAfter = nil
        next.revision += 1
        try write(next)
        state = next
        return state
    }

    // MARK: - Run snapshots and reads

    /// Freezes the active versions for a run. Repeated calls return the same
    /// snapshot, so a resumed run keeps its original content. `builtInVersions`
    /// records which app-owned baselines were authoritative, so an app upgrade
    /// cannot silently substitute a new bundle during recovery.
    ///
    /// Snapshots are released only through `releaseRunSnapshot` (task terminal
    /// or deletion); they are never time-pruned while a task may still resume.
    @discardableResult
    public func runSnapshot(
        runID: UUID,
        builtInVersions: [String: String] = [:],
        builtInPayloads: [String: Data] = [:]
    ) throws -> ContentUpdateState.RunSnapshot {
        let key = runID.uuidString
        if let snapshot = state.runSnapshots[key] { return snapshot }
        var builtInDirectories: [String: String] = [:]
        for (id, payload) in builtInPayloads {
            let digest = SignedContentArchive.sha256Hex(payload)
            let folder = "builtins/\(id)/\(digest.prefix(12))"
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    try payload.write(to: directory.appendingPathComponent("payload"), options: .atomic)
                } catch {
                    throw ContentUpdateStoreError.staging("built-in freeze failed: \(error.localizedDescription)")
                }
            }
            builtInDirectories[id] = folder
        }
        let snapshot = ContentUpdateState.RunSnapshot(
            directories: state.entries.mapValues(\.directory),
            builtInVersions: builtInVersions.isEmpty ? nil : builtInVersions,
            builtInDirectories: builtInDirectories.isEmpty ? nil : builtInDirectories,
            createdAt: Date()
        )
        var next = state
        next.runSnapshots[key] = snapshot
        try write(next)
        state = next
        return snapshot
    }

    /// Releases one run's frozen content after the task reached a terminal
    /// state or was deleted. Unreferenced version dirs are pruned on the next
    /// launch; bytes stay until then.
    @discardableResult
    public func releaseRunSnapshot(runID: UUID) throws -> ContentUpdateState {
        let key = runID.uuidString
        guard state.runSnapshots[key] != nil else { return state }
        var next = state
        next.runSnapshots.removeValue(forKey: key)
        next.revision += 1
        try write(next)
        state = next
        return state
    }

    public func files(directory: String) throws -> [String: Data] {
        try Self.readFiles(at: Self.resolve(directory: directory, under: root))
    }

    public func files(id: String) throws -> [String: Data] {
        guard let stored = state.entries[id] else {
            throw ContentUpdateStoreError.conflict("nothing installed for \(id)")
        }
        return try files(directory: stored.directory)
    }

    /// Reads one file from the active version of `id`, if present. The
    /// relative path is constrained to the package root; state metadata can
    /// never escape it.
    public func file(id: String, relativePath: String) throws -> Data? {
        let files = try files(id: id)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              !relativePath.split(separator: "/").contains("..") else {
            throw ContentUpdateStoreError.staging("unsafe relative path")
        }
        return files[relativePath]
    }

    /// Resolves a manifest-stored relative directory under the store root.
    /// Paths from `active.json` are untrusted input: absolute paths, `..`,
    /// backslashes and empty components all fail closed.
    static func resolve(directory: String, under root: URL) throws -> URL {
        guard !directory.isEmpty,
              !directory.hasPrefix("/"),
              !directory.contains("\\"),
              !directory.contains("\0"),
              directory.split(separator: "/").allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ContentUpdateStoreError.corruptState("unsafe directory reference")
        }
        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(directory).standardizedFileURL
        let prefix = rootURL.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw ContentUpdateStoreError.corruptState("directory escapes store root")
        }
        return candidate
    }

    // MARK: - IO

    private func write(_ next: ContentUpdateState) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            throw ContentUpdateStoreError.persistence(error.localizedDescription)
        }
    }

    /// Bounded read shared by staging verification, rollback and file access.
    /// File size is checked from metadata before any bytes are read, and every
    /// path must stay under the package root.
    public static func readFiles(at root: URL) throws -> [String: Data] {
        let rootURL = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            throw ContentUpdateStoreError.staging("cannot read \(rootURL.lastPathComponent)")
        }
        var files: [String: Data] = [:]
        var total = 0
        let prefix = rootURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw ContentUpdateStoreError.staging("symlink in package")
            }
            guard values.isRegularFile == true else { continue }
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else {
                throw ContentUpdateStoreError.staging("path escapes root")
            }
            let size = values.fileSize ?? 0
            guard size <= 2 * 1_024 * 1_024,
                  total + size <= 8 * 1_024 * 1_024,
                  files.count < 128 else {
                throw ContentUpdateStoreError.staging("package exceeds read bounds")
            }
            let data = try Data(contentsOf: standardized, options: [.mappedIfSafe])
            total += data.count
            guard total <= 8 * 1_024 * 1_024 else {
                throw ContentUpdateStoreError.staging("package exceeds read bounds")
            }
            files[String(standardized.path.dropFirst(prefix.count))] = data
        }
        guard !files.isEmpty else {
            throw ContentUpdateStoreError.staging("empty package directory")
        }
        return files
    }

    /// Existing manifests predate the ledger; reconstruct it from active and
    /// retained versions so immutability applies immediately after upgrade.
    private static func backfillLedger(state: inout ContentUpdateState) {
        var ledger = state.ledger
        for entry in state.entries.values {
            ledger[entry.entry.id, default: [:]][entry.entry.version] = entry.entry.contentDigest.lowercased()
        }
        for list in state.history.values {
            for stored in list {
                ledger[stored.entry.id, default: [:]][stored.entry.version] = stored.entry.contentDigest.lowercased()
            }
        }
        state.ledger = ledger
    }

    private static func pruneUnreferenced(root: URL, versionsURL: URL, state: ContentUpdateState) {
        var referenced: Set<String> = []
        for stored in state.entries.values { referenced.insert(stored.directory) }
        for list in state.history.values {
            for stored in list { referenced.insert(stored.directory) }
        }
        for snapshot in state.runSnapshots.values {
            for directory in snapshot.directories.values { referenced.insert(directory) }
            for directory in (snapshot.builtInDirectories ?? [:]).values { referenced.insert(directory) }
        }
        let roots = [versionsURL, root.appendingPathComponent("builtins", isDirectory: true)]
        let rootPrefix = root.standardizedFileURL.path + "/"
        for scanRoot in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPrefix, with: "")
                guard relative.split(separator: "/").count == 3 else { continue }
                if !referenced.contains(relative) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
