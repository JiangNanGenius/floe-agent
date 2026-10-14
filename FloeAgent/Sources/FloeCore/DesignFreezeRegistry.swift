import Foundation

// FloeCore — Durable design freeze registry.
//
// While a design task has an unadopted candidate (or a confirmed, not yet
// applied 重构), the ORIGINAL source of its typed target must not be
// overwritten by ordinary workspace writes — from the model's workspace file
// tools, from any host-side native writer, or from an arbitrary Linux guest
// command reaching the same bytes through the workspace share. Candidates
// stage isolated bytes and the trusted adoption path commits atomically
// with its own frozen-SHA optimistic gate; until that happens the original
// is frozen.
//
// This registry is the shared, module-level authority every write layer
// consults. The hot read (`protection(for:)`) is a synchronous, lock-held
// lookup because workspace mutation methods are synchronous; writes persist
// atomically and REPORT persistence failure (a freeze that exists only in
// memory is not a freeze — a required launch fence must verify the on-disk
// record and fail closed when it cannot be persisted).
//
// - FloeWorkspace's `WorkspaceFileService` mutation methods take an optional
//   checker invoked with the RESOLVED (canonical) target URL before any
//   bytes move; the workspace tools wire it to this registry.
// - The trusted design commit port releases ONLY the adopting conversation's
//   exact entry after a verified commit; directory originals lift through
//   `releaseIfResolved` once no pending candidate remains.
//
// Identity is canonical, not lexical: URLs are symlink-resolved and
// standardized before comparison, and — because a hard link or a replaced
// file can alias or dodge a path — every protection also records the
// (device, inode) identity of the frozen file and mutations are rejected
// when EITHER the canonical path OR the file identity matches. Directory
// originals (a webroot) protect every EXISTING regular file inside the
// tree, and any mutation of an ANCESTOR of a protected path (deleting or
// renaming the containing directory) is rejected too. A model therefore
// cannot bypass the freeze with `../` traversal, a symlink swap, removing
// and recreating the file (the inode changes), renaming the parent
// directory, or writing a sibling through a hard link.
//
// One source may be frozen by SEVERAL tasks at once (two conversations
// bound to the same original): entries are per (canonical path, owner
// conversation), so one task adopting/rejecting/ending never lifts a freeze
// another pending task still needs.

/// One frozen original source, owned by one conversation.
public struct DesignFreezeProtection: Sendable, Equatable, Codable {
    /// Canonical (symlink-resolved, standardized) absolute path of the
    /// frozen source on this device. May be a regular file (an original
    /// document) or a directory (a webroot original — every existing
    /// regular file in the tree is then frozen).
    public var canonicalPath: String
    /// Conversation (task) whose design binding froze the source.
    public var conversationID: String
    /// SHA-256 of the frozen bytes at freeze time (audit + recovery copy);
    /// empty for directory originals (per-file digests live on the design
    /// revisions).
    public var frozenSHA256: String
    /// POSIX (device, inode) identity of the frozen file, when it existed
    /// at freeze time. A mutation is rejected when the target's live
    /// identity matches even if the path text changed.
    public var fileDevice: UInt64?
    public var fileInode: UInt64?
    /// Directory originals: the site-relative paths of every regular file
    /// that existed INSIDE the tree at freeze time. Overwriting (or
    /// recreating) one of these is rejected; NEW paths inside the webroot
    /// stay open for staging. nil for file originals.
    public var frozenChildren: [String]?
    public var createdAt: Date

    public init(
        canonicalPath: String,
        conversationID: String,
        frozenSHA256: String,
        fileDevice: UInt64? = nil,
        fileInode: UInt64? = nil,
        frozenChildren: [String]? = nil,
        createdAt: Date = Date()
    ) {
        self.canonicalPath = canonicalPath
        self.conversationID = conversationID
        self.frozenSHA256 = frozenSHA256
        self.fileDevice = fileDevice
        self.fileInode = fileInode
        self.frozenChildren = frozenChildren
        self.createdAt = createdAt
    }
}

/// Rejection raised by the write gate. Distinct from optimistic-concurrency
/// `.conflict`: the file did not change — the write is forbidden until the
/// design decision (adopt/reject) releases it.
public enum DesignFreezeError: Error, Sendable, Equatable {
    /// The target is a frozen design original. The payload tells the writer
    /// which task froze it and how to stage a candidate instead.
    case sourceFrozen(
        path: String,
        conversationID: String,
        reason: String
    )
}

extension DesignFreezeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceFrozen(let path, let conversationID, let reason):
            return "Design source is frozen: \(path) is protected by design task \(conversationID). \(reason)"
        }
    }
}

/// Whether a protection survived the trip to durable storage. A required
/// launch fence treats `.memoryOnly` as establishment failure and fails
/// closed (and removes the in-memory entry, so a non-persisted freeze can
/// never linger and block the user's own edits).
public enum DesignFreezePersistence: Sendable, Equatable {
    case persisted
    case memoryOnly(saveError: String)
}

/// Process-wide registry of frozen design originals. Synchronous reads so
/// the workspace write path (which is synchronous) can consult it on every
/// mutation; writes re-persist the small JSON backing atomically.
public final class DesignFreezeRegistry: @unchecked Sendable {
    public static let shared = DesignFreezeRegistry()

    /// Small JSON-file backing. Atomic staged writes; tolerant reads
    /// (missing/corrupt file = no protections, never fabricated). `save`
    /// RETURNS the persistence error instead of hiding it: durability is a
    /// safety property here, not a convenience.
    public struct Store: Sendable {
        public let directory: URL

        public init(directory: URL) {
            self.directory = directory
        }

        public static func applicationSupport() -> Store {
            let root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FloeAgent", isDirectory: true)
            return Store(directory: root ?? FileManager.default.temporaryDirectory)
        }

        fileprivate var fileURL: URL {
            directory.appendingPathComponent("DesignFreezeRegistry.json")
        }

        public func load() -> [DesignFreezeProtection] {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([DesignFreezeProtection].self, from: data)) ?? []
        }

        /// Atomically replaces the backing file. Returns nil on success and
        /// the caught error on failure; the in-memory registry still
        /// protects this process, but callers that REQUIRE durability
        /// (the launch fence) must treat a non-nil result as failure.
        @discardableResult
        public func save(_ protections: [DesignFreezeProtection]) -> Error? {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(protections)
                let staging = directory.appendingPathComponent(
                    ".freeze-\(UUID().uuidString.lowercased()).staging")
                try data.write(to: staging, options: .atomic)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: fileURL)
                }
                return nil
            } catch {
                return error
            }
        }
    }

    private let lock = NSLock()
    private let store: Store
    /// Entries keyed by (canonical path, owner conversation): one source may
    /// be frozen by several tasks at once, and each owner's release is
    /// independent.
    private var protections: [String: DesignFreezeProtection] = [:]

    public init(store: Store = .applicationSupport()) {
        self.store = store
        self.protections = Dictionary(
            uniqueKeysWithValues: store.load().map {
                (Self.compositeKey(canonicalPath: $0.canonicalPath, conversationID: $0.conversationID), $0)
            })
    }

    static func compositeKey(canonicalPath: String, conversationID: String) -> String {
        "\(canonicalPath)\n\(conversationID.lowercased())"
    }

    /// Canonicalizes a URL the same way every write layer must: resolve
    /// symlinks, standardize, drop the trailing slash.
    public static func canonicalPath(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// (device, inode) identity of a live file, when it exists.
    public static func fileIdentity(of url: URL) -> (device: UInt64, inode: UInt64)? {
        var statBuffer = stat()
        guard stat(url.path, &statBuffer) == 0 else { return nil }
        return (UInt64(statBuffer.st_dev), UInt64(statBuffer.st_ino))
    }

    /// Whether the live file at `url` is a regular file (directory
    /// originals protect only regular files inside the tree; creating NEW
    /// paths inside a frozen webroot stays open as staging space).
    static func isRegularFile(_ url: URL) -> Bool {
        var statBuffer = stat()
        guard stat(url.path, &statBuffer) == 0 else { return false }
        return (statBuffer.st_mode & S_IFMT) == S_IFREG
    }

    /// Freezes `url` for `conversationID`. Idempotent for the same
    /// (source, conversation); a DIFFERENT conversation freezing the same
    /// source adds an independent owner entry. A directory original records
    /// its freeze-time file listing (bounded) so NEW paths inside the
    /// webroot stay writable while existing originals stay frozen. Returns
    /// whether the entry persisted durably — `.memoryOnly` means this
    /// process is protected but the record did NOT reach disk (required
    /// launch fences must fail closed; the hot propose-time path may
    /// continue and re-persist on the next successful mutation).
    @discardableResult
    public func protect(
        _ url: URL,
        conversationID: String,
        frozenSHA256: String
    ) -> DesignFreezePersistence {
        let canonical = Self.canonicalPath(of: url)
        let owner = conversationID.lowercased()
        let identity = Self.fileIdentity(of: url)
        let isDirectory = Self.isDirectory(canonical)
        let children = isDirectory ? Self.directoryListing(root: canonical) : nil
        let protection = DesignFreezeProtection(
            canonicalPath: canonical,
            conversationID: owner,
            frozenSHA256: frozenSHA256,
            fileDevice: identity?.device,
            fileInode: identity?.inode,
            frozenChildren: children
        )
        lock.lock()
        protections[Self.compositeKey(canonicalPath: canonical, conversationID: owner)] = protection
        let snapshot = Array(protections.values)
        lock.unlock()
        if let error = store.save(snapshot) {
            return .memoryOnly(saveError: String(describing: error))
        }
        return .persisted
    }

    /// Bounded freeze-time listing of a webroot's regular files, as
    /// root-relative POSIX paths. Beyond the bound the WHOLE tree is
    /// treated as frozen (fail closed) by `directoryProtectionCovers`.
    static let directoryListingBound = 4_096

    static func directoryListing(root: String) -> [String]? {
        var listing: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefixLength = root.hasSuffix("/") ? root.count : root.count + 1
        // FileManager may hand back deeper-resolved paths than URL
        // canonicalization (macOS /var → /private/var): compare through a
        // fully resolved root so the freeze-time listing matches the
        // canonical paths the write gate resolves later.
        let resolvedRoot = fullyResolvedPath(root)
        let resolvedPrefixLength = resolvedRoot.hasSuffix("/")
            ? resolvedRoot.count : resolvedRoot.count + 1
        for case let item as URL in enumerator {
            if listing.count >= directoryListingBound { return nil }
            do {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let itemPath = item.standardizedFileURL.path
                let relative: String
                if itemPath.hasPrefix(root) {
                    relative = String(itemPath.dropFirst(prefixLength))
                } else {
                    let resolvedItem = fullyResolvedPath(itemPath)
                    guard resolvedItem.hasPrefix(resolvedRoot) else { continue }
                    relative = String(resolvedItem.dropFirst(resolvedPrefixLength))
                }
                guard !relative.isEmpty else { continue }
                listing.append(relative)
            } catch {
                continue
            }
        }
        return listing.sorted()
    }

    /// realpath(3)-based full resolution (URL/NSString symlink resolution
    /// intentionally keeps leading /private components unresolved; the
    /// directory enumerator does not, so matching needs the deeper form).
    static func fullyResolvedPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// Releases frozen sources at `url` for ONE owner conversation (a
    /// verified adoption, a rejection, a task ending). With a nil
    /// conversationID every owner of the exact path is released (launch
    /// reconciliation). Only the EXACT canonical path is released here: a
    /// directory original's tree-wide freeze lifts through
    /// `releaseIfResolved`/`unprotectAll` once no pending candidate remains,
    /// so a single file adoption can never unprotect siblings that still
    /// have pending candidates.
    @discardableResult
    public func unprotect(_ url: URL, conversationID: String? = nil) -> Int {
        let canonical = Self.canonicalPath(of: url)
        let owner = conversationID?.lowercased()
        lock.lock()
        let keys = protections.values
            .filter { entry in
                guard entry.canonicalPath == canonical else { return false }
                return owner == nil || entry.conversationID == owner
            }
            .map { Self.compositeKey(canonicalPath: $0.canonicalPath, conversationID: $0.conversationID) }
        guard !keys.isEmpty else {
            lock.unlock()
            return 0
        }
        for key in keys { protections.removeValue(forKey: key) }
        let snapshot = Array(protections.values)
        lock.unlock()
        _ = store.save(snapshot)
        return keys.count
    }

    /// Whether the live path is a directory (directory originals protect
    /// their whole tree of existing regular files).
    static func isDirectory(_ path: String) -> Bool {
        var statBuffer = stat()
        guard stat(path, &statBuffer) == 0 else { return false }
        return (statBuffer.st_mode & S_IFMT) == S_IFDIR
    }

    /// Whether a directory protection covers the target file: the target
    /// lives inside the frozen webroot AND was one of the files that
    /// existed at freeze time (or the listing is unavailable because the
    /// tree exceeded the bound — fail closed). NEW paths inside the webroot
    /// stay open for staging.
    static func directoryProtectionCovers(
        entry: DesignFreezeProtection,
        canonicalTarget: String
    ) -> Bool {
        guard isDirectory(entry.canonicalPath) else { return false }
        let root = entry.canonicalPath.hasSuffix("/")
            ? entry.canonicalPath
            : entry.canonicalPath + "/"
        guard canonicalTarget.hasPrefix(root) else { return false }
        guard let children = entry.frozenChildren else { return true }
        let relative = String(canonicalTarget.dropFirst(root.count))
        return children.contains(relative)
    }

    /// Releases every freeze owned by a conversation (task ended, design
    /// cancelled, candidate rejected, verified adoption with nothing
    /// pending). Other owners of the same source keep their freezes.
    public func unprotectAll(conversationID: String) {
        let owner = conversationID.lowercased()
        lock.lock()
        let before = protections.count
        protections = protections.filter { $0.value.conversationID != owner }
        let changed = protections.count != before
        let snapshot = Array(protections.values)
        lock.unlock()
        if changed { _ = store.save(snapshot) }
    }

    /// The protection governing `url`, when any. Matches:
    /// - the exact canonical path (any owner);
    /// - the live (device, inode) identity — a replaced file or hard link
    ///   cannot dodge the freeze;
    /// - a directory original whose tree contains this EXISTING regular
    ///   file (new paths inside a frozen webroot stay open for staging);
    /// - an ANCESTOR relationship in either direction is NOT included here —
    ///   deleting/renaming a parent directory is rejected through
    ///   `protection(ancestorOf:)` so ordinary sibling writes stay open.
    public func protection(for url: URL) -> DesignFreezeProtection? {
        let canonical = Self.canonicalPath(of: url)
        lock.lock()
        let values = Array(protections.values)
        lock.unlock()
        if let exact = values.first(where: { $0.canonicalPath == canonical }) {
            return exact
        }
        if let identity = Self.fileIdentity(of: url) {
            if let byIdentity = values.first(where: {
                $0.fileDevice != nil
                    && $0.fileDevice == identity.device
                    && $0.fileInode == identity.inode
            }) {
                return byIdentity
            }
        }
        if Self.isRegularFile(url) {
            return values.first(where: {
                Self.directoryProtectionCovers(entry: $0, canonicalTarget: canonical)
            })
        }
        return nil
    }

    /// Any protection at or UNDER `url` — used to reject mutations of an
    /// ANCESTOR (deleting or renaming the directory that holds a frozen
    /// original would move/remove it under a new path, dodging both the
    /// path and the inode check at the directory level).
    public func protection(ancestorOf url: URL) -> DesignFreezeProtection? {
        let canonical = Self.canonicalPath(of: url)
        let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
        lock.lock()
        let values = Array(protections.values)
        lock.unlock()
        return values.first(where: {
            $0.canonicalPath == canonical
                || $0.canonicalPath.hasPrefix(prefix)
                || Self.directoryProtectionCovers(entry: $0, canonicalTarget: canonical)
        })
    }

    public func allProtections() -> [DesignFreezeProtection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(protections.values)
    }

    /// Durable round-trip proof for the launch fence: re-reads the backing
    /// store and confirms the EXACT (path, owner) entry is on disk with the
    /// frozen digest. In-memory presence alone is never accepted as proof.
    public func verifyPersisted(_ url: URL, conversationID: String) -> Bool {
        let canonical = Self.canonicalPath(of: url)
        let owner = conversationID.lowercased()
        return store.load().contains {
            $0.canonicalPath == canonical && $0.conversationID == owner
        }
    }

    /// Drops protections whose predicate fails (launch reconciliation:
    /// conversation deleted, envelope terminal...). Returns the removed ones.
    @discardableResult
    public func removeWhere(_ predicate: (DesignFreezeProtection) -> Bool) -> [DesignFreezeProtection] {
        lock.lock()
        let removed = protections.values.filter(predicate)
        guard !removed.isEmpty else {
            lock.unlock()
            return []
        }
        let keys = Set(removed.map {
            Self.compositeKey(canonicalPath: $0.canonicalPath, conversationID: $0.conversationID)
        })
        protections = protections.filter { !keys.contains($0.key) }
        let snapshot = Array(protections.values)
        lock.unlock()
        _ = store.save(snapshot)
        return removed
    }
}
