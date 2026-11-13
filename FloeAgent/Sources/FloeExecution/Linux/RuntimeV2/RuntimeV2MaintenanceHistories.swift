// Native-only grouped ownership for one fixed legacy domain. No disk-body IO.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RuntimeV2MaintenanceBootstrapFailure: Error, Sendable, Equatable {
    public enum Code: String, Sendable, Equatable {
        case rootUnavailable = "root_unavailable"
        case rootIdentityMismatch = "root_identity_mismatch"
        case historyUnreadable = "history_unreadable"
        case historyShapeUnknown = "history_shape_unknown"
        case historiesAmbiguous = "histories_ambiguous"
        case historyConflict = "history_conflict"
        case historySetChanged = "history_set_changed"
        case nativeLockUnavailable = "native_lock_unavailable"
    }
    public enum RootCheck: String, Sendable, Equatable {
        case unmeasured, unavailable, mismatch, verified
    }
    public let code: Code
    public let rootCheck: RootCheck
    public let histories: Int
    public let pending: Int
    public let posixErrno: Int32?
    init(_ code: Code, rootCheck: RootCheck, histories: Int = 0, pending: Int = 0, posixErrno: Int32? = nil) {
        self.code = code; self.rootCheck = rootCheck
        self.histories = histories; self.pending = pending; self.posixErrno = posixErrno
    }
    /// Diagnostic-only closed vocabulary: never paths, IDs, content or permission.
    public var diagnosticText: String {
        "legacyMaintenanceBootstrap code=\(code.rawValue) rootCheck=\(rootCheck.rawValue) histories=\(histories) pending=\(pending) errno=\(posixErrno.map { String($0) } ?? "unrecorded")"
    }
}

/// Constructed only by native discovery of the fixed authority sibling. A
/// historical directory is kept intact; this value cannot be built by tools.
public struct RuntimeV2MaintenanceHistoryLayout: Sendable {
    public let primaryDirectory: URL
    public let directories: [URL]
    public let historicalDirectories: [URL]
    public let pendingIntentCount: Int
    let domain: RuntimeV2MaintenanceDomain
    let rootDevice: UInt64
    let rootInode: UInt64
    let parent: URL
    let anchor: URL
    let namespaceNames: Set<String>
    let existingDirectoryIdentities: [String: RuntimeV2MaintenanceLockIdentity]

    func checkRoot() throws {
        guard domain.matchesRecordedRoot(domain.root.path, device: rootDevice, inode: rootInode) else {
            throw RuntimeV2MaintenanceBootstrapFailure(.rootIdentityMismatch, rootCheck: .mismatch,
                                                       histories: historicalDirectories.count)
        }
    }

    func prepareNativeDirectories() throws -> RuntimeV2MaintenanceHistoryLayout {
        try checkRoot()
        var protectedIdentities = existingDirectoryIdentities
        if mkdir(parent.path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified, posixErrno: errno)
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified) }
        defer { close(parentFD) }
        for directory in directories {
            let name = directory.lastPathComponent
            if existingDirectoryIdentities[name] == nil {
                // Only the fixed current-key namespace can be new. mkdirat
                // cannot follow an old namespace or a caller-selected path.
                guard name == domain.domainKey else { throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified) }
                if mkdirat(parentFD, name, mode_t(0o700)) != 0 && errno != EEXIST {
                    throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified, posixErrno: errno)
                }
            }
            let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified) }
            defer { close(fd) }
            var info = stat(); var named = stat()
            guard fstat(fd, &info) == 0, fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_dev == named.st_dev, info.st_ino == named.st_ino else {
                throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
            }
            if let identity = existingDirectoryIdentities[name] {
                guard identity.device == UInt64(bitPattern: Int64(info.st_dev)), identity.inode == UInt64(info.st_ino) else {
                    throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
                }
            }
            protectedIdentities[name] = .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
        }
        return RuntimeV2MaintenanceHistoryLayout(primaryDirectory: primaryDirectory, directories: directories,
            historicalDirectories: historicalDirectories, pendingIntentCount: pendingIntentCount,
            domain: domain, rootDevice: rootDevice, rootInode: rootInode,
            parent: parent, anchor: anchor, namespaceNames: namespaceNames, existingDirectoryIdentities: protectedIdentities)
    }

}

/// Recognize only metadata which this native recovery service can leave in a
/// namespace without its own intent. These receipts are historical CONTENT,
/// never current closure permission; the namespace still joins every flock.
private enum RuntimeV2IntentlessAuthorityMetadata {
    struct Budget {
        var receipts = 0
        var bytes = 0
    }

    private static func refuse() -> RuntimeV2MaintenanceBootstrapFailure {
        .init(.historyShapeUnknown, rootCheck: .verified)
    }

    private static func same(_ before: stat, _ after: stat) -> Bool {
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_nlink == after.st_nlink,
              before.st_uid == after.st_uid, before.st_gid == after.st_gid,
              before.st_size == after.st_size else { return false }
        #if canImport(Darwin)
        return before.st_flags == after.st_flags
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        #else
        return before.st_mtim.tv_sec == after.st_mtim.tv_sec
            && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
            && before.st_ctim.tv_sec == after.st_ctim.tv_sec
            && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
        #endif
    }

    private static func names(in directory: Int32, limit: Int) throws -> [String] {
        // A separate open description avoids changing a held directory's
        // readdir position when its cohort is revalidated more than once.
        let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refuse() }
        guard let stream = fdopendir(fd) else { close(fd); throw refuse() }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw refuse() }
                return result
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            guard result.count < limit else { throw refuse() }
            result.append(name)
        }
    }

    static func validate(namespaceFD: Int32, namespace: String,
                         rootDevice: UInt64, rootInode: UInt64, budget: inout Budget) throws {
        var before = stat(); var after = stat()
        guard fstat(namespaceFD, &before) == 0 else { throw refuse() }
        for name in try names(in: namespaceFD, limit: 3) {
            if name == "closed-receipts" {
                try receipts(namespaceFD: namespaceFD, namespace: namespace,
                             rootDevice: rootDevice, rootInode: rootInode, budget: &budget)
            } else {
                var info = stat()
                guard ["admission.lock", "maintenance.lock"].contains(name),
                      fstatat(namespaceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw refuse() }
            }
        }
        guard fstat(namespaceFD, &after) == 0, same(before, after) else { throw refuse() }
    }

    private static func receipts(namespaceFD: Int32, namespace: String,
                                 rootDevice: UInt64, rootInode: UInt64, budget: inout Budget) throws {
        let fd = openat(namespaceFD, "closed-receipts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refuse() }
        defer { close(fd) }
        var before = stat(); var named = stat(); var after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
              fstatat(namespaceFD, "closed-receipts", &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, named) else { throw refuse() }
        for name in try names(in: fd, limit: 512) {
            // UUID-shaped native names only, before opening any payload.
            guard name.utf8.count == 86, name.hasPrefix("closure-"), name.hasSuffix(".json"),
                  budget.receipts < 512 else { throw refuse() }
            let receiptFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard receiptFD >= 0 else { throw refuse() }
            defer { close(receiptFD) }
            var info = stat(); var second = stat(); var entry = stat()
            guard fstat(receiptFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_size > 0, info.st_size <= 65_536,
                  budget.bytes <= 8 * 1_024 * 1_024 - Int(info.st_size) else { throw refuse() }
            budget.receipts += 1; budget.bytes += Int(info.st_size)
            var data = Data(count: Int(info.st_size))
            try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                var offset = 0
                while offset < bytes.count {
                    let count = read(receiptFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw refuse() }
                    offset += count
                }
            }
            guard fstat(receiptFD, &second) == 0, fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  same(info, second), same(info, entry) else { throw refuse() }
            try validateReceipt(data, name: name, namespace: namespace, rootDevice: rootDevice, rootInode: rootInode)
        }
        guard fstat(fd, &after) == 0, fstatat(namespaceFD, "closed-receipts", &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(before, named) else { throw refuse() }
    }

    private static func validateReceipt(_ data: Data, name: String, namespace: String,
                                        rootDevice: UInt64, rootInode: UInt64) throws {
        let keys: Set<String> = ["version", "proofID", "isConvergenceProof", "domainKey", "rootDevice", "rootInode",
            "incarnation", "sourceGeneration", "intentID", "holdGeneration", "historicalLeaseEnvironmentIDs",
            "historicalRegistryLeaseEnvironmentIDs", "ownerEvidenceFingerprint", "legacyRegistryFingerprint",
            "inspectedDescriptorSlots", "readOnlyMetadataDescriptors"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys else { throw refuse() }
        let receipt = try JSONDecoder().decode(RuntimeV2RecoveryClosedReceipt.self, from: data)
        func uuid(_ value: String) -> Bool {
            value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value.lowercased()
        }
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let environments = receipt.historicalLeaseEnvironmentIDs + receipt.historicalRegistryLeaseEnvironmentIDs
        guard receipt.version == 1, receipt.isConvergenceProof,
              receipt.domainKey == namespace, digest(namespace),
              receipt.rootDevice == rootDevice, receipt.rootInode == rootInode,
              rootDevice != 0, rootInode != 0,
              uuid(receipt.intentID), uuid(receipt.proofID), uuid(receipt.incarnation),
              name == "closure-" + receipt.intentID + "-" + receipt.proofID + ".json",
              receipt.holdGeneration > 0,
              digest(receipt.ownerEvidenceFingerprint), digest(receipt.legacyRegistryFingerprint),
              environments.count <= 2_048,
              environments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) && !$0.contains(where: { $0.isNewline }) }),
              receipt.inspectedDescriptorSlots > 0, receipt.inspectedDescriptorSlots <= 16_384,
              receipt.readOnlyMetadataDescriptors >= 0,
              receipt.readOnlyMetadataDescriptors <= receipt.inspectedDescriptorSlots else { throw refuse() }
        // Do NOT install this receipt in RuntimeV2RecoveryClosureAuthority.
        // A new session still requires fresh live owner/FD/registry evidence.
    }
}

extension RuntimeV2MaintenanceDomain {
    /// Unlike the strict single-history compatibility API, this does not pick
    /// a historical owner. Every matching history is returned and protected.
    public func authorityHistoryLayout() throws -> RuntimeV2MaintenanceHistoryLayout {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw RuntimeV2MaintenanceBootstrapFailure(.rootUnavailable, rootCheck: .unavailable, posixErrno: errno)
        }
        defer { close(rootFD) }
        var identity = stat(); var namedRoot = stat()
        guard fstat(rootFD, &identity) == 0, lstat(root.path, &namedRoot) == 0,
              identity.st_mode & S_IFMT == S_IFDIR,
              identity.st_dev == namedRoot.st_dev, identity.st_ino == namedRoot.st_ino else {
            throw RuntimeV2MaintenanceBootstrapFailure(.rootUnavailable, rootCheck: .unavailable, posixErrno: errno)
        }
        let device = UInt64(bitPattern: Int64(identity.st_dev)), inode = UInt64(identity.st_ino)
        let parent = root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority", isDirectory: true)
        let fresh = parent.appendingPathComponent(domainKey, isDirectory: true)
        let anchorName = ".physical-" + FloeDigest.sha256Hex(Data("\(device):\(inode)".utf8)) + ".lock"
        let anchor = parent.appendingPathComponent(anchorName)
        var directories: [URL] = [], histories: [URL] = []
        var identities: [String: RuntimeV2MaintenanceLockIdentity] = [:]
        var ids = Set<String>(), pendingTargets = Set<String>(), pending = 0
        var receiptBudget = RuntimeV2IntentlessAuthorityMetadata.Budget()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parentFD >= 0 {
            var parentIdentity = stat()
            guard fstat(parentFD, &parentIdentity) == 0, let stream = fdopendir(parentFD) else {
                close(parentFD)
                throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified)
            }
            defer { closedir(stream) }
            var count = 0
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified) }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= 129 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified) }
                if name == anchorName {
                    var info = stat()
                    guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                        throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified)
                    }
                    continue
                }
                guard name.utf8.count == 64,
                      name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified)
                }
                let child = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified) }
                defer { close(child) }
                var before = stat(); var after = stat()
                guard fstat(child, &before) == 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified) }
                let directory = parent.appendingPathComponent(name, isDirectory: true)
                let record: RuntimeV2MaintenanceIntentRecord?
                do { record = try RuntimeV2MaintenanceCoordinator.readHistoryIntent(directory: directory) }
                catch { throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified, histories: histories.count, pending: pending) }
                if let record {
                    guard matchesRecordedRoot(record.domainRoot, device: record.domainDevice, inode: record.domainInode) else {
                        throw RuntimeV2MaintenanceBootstrapFailure(.rootIdentityMismatch, rootCheck: .mismatch,
                                                                  histories: histories.count + 1, pending: pending)
                    }
                    guard ids.insert(record.intentID).inserted else {
                        throw RuntimeV2MaintenanceBootstrapFailure(.historyConflict, rootCheck: .verified, histories: histories.count + 1, pending: pending)
                    }
                    if record.phase.isBlocking {
                        pending += 1
                        if let target = record.targetRelativePath, !pendingTargets.insert(target).inserted {
                            throw RuntimeV2MaintenanceBootstrapFailure(.historyConflict, rootCheck: .verified,
                                                                      histories: histories.count + 1, pending: pending)
                        }
                    }
                    histories.append(directory)
                } else {
                    // Service-produced convergence receipts can outlive the
                    // history being recovered in another namespace. They are
                    // only known metadata shape, never evidence of idleness.
                    do {
                        try RuntimeV2IntentlessAuthorityMetadata.validate(namespaceFD: child, namespace: name,
                            rootDevice: device, rootInode: inode, budget: &receiptBudget)
                    } catch {
                        throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified,
                            histories: histories.count, pending: pending)
                    }
                }
                guard fstatat(parentFD, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                      before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
                    throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
                }
                identities[name] = .init(device: UInt64(bitPattern: Int64(before.st_dev)), inode: UInt64(before.st_ino))
                directories.append(directory)
            }
            var after = stat()
            guard lstat(parent.path, &after) == 0, after.st_mode & S_IFMT == S_IFDIR,
                  parentIdentity.st_dev == after.st_dev, parentIdentity.st_ino == after.st_ino else {
                throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
            }
        } else if errno != ENOENT {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified, posixErrno: errno)
        }
        if !directories.contains(fresh) { directories.append(fresh) }
        directories.sort { $0.path < $1.path }; histories.sort { $0.path < $1.path }
        // Preserve340's unique-owner primary; multi-history never chooses a
        // first/latest history as authoritative for future operations.
        let primary = histories.count == 1 ? histories[0] : fresh
        let result = RuntimeV2MaintenanceHistoryLayout(primaryDirectory: primary, directories: directories,
            historicalDirectories: histories, pendingIntentCount: pending,
            domain: self, rootDevice: device, rootInode: inode,
            parent: parent, anchor: anchor, namespaceNames: Set(directories.map(\.lastPathComponent)),
            existingDirectoryIdentities: identities)
        try result.checkRoot()
        return result
    }
}

/// Retains every original lock description and directory inode. Claims receive
/// a dup of the anchor; dropping a wrapper never releases a partial lock set.
final class RuntimeV2MaintenanceHistoryLocks: @unchecked Sendable {
    private let mutex = NSLock()
    private let layout: RuntimeV2MaintenanceHistoryLayout
    private var locks: [(url: URL, fd: Int32, identity: RuntimeV2MaintenanceLockIdentity)] = []
    private var directories: [(url: URL, fd: Int32, identity: RuntimeV2MaintenanceLockIdentity)] = []
    private var anchorFD: Int32 = -1

    private init(layout: RuntimeV2MaintenanceHistoryLayout) { self.layout = layout }
    deinit {
        for row in locks { close(row.fd) }
        for row in directories { close(row.fd) }
    }
    static func acquire(_ layout: RuntimeV2MaintenanceHistoryLayout, operation: Int32) throws -> RuntimeV2MaintenanceHistoryLocks {
        try layout.checkRoot()
        let owner = RuntimeV2MaintenanceHistoryLocks(layout: layout)
        var urls: [URL] = [layout.anchor]
        for directory in layout.directories {
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified) }
            var info = stat()
            guard fstat(fd, &info) == 0, let expected = layout.existingDirectoryIdentities[directory.lastPathComponent],
                  expected.device == UInt64(bitPattern: Int64(info.st_dev)), expected.inode == UInt64(info.st_ino) else {
                close(fd); throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
            }
            owner.directories.append((directory, fd, .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))))
            urls.append(directory.appendingPathComponent("maintenance.lock"))
            var old = stat()
            let oldURL = directory.appendingPathComponent("admission.lock")
            if lstat(oldURL.path, &old) == 0 { urls.append(oldURL) }
            else if errno != ENOENT { throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified) }
        }
        // The shared physical anchor ALWAYS precedes sorted namespace locks.
        urls = [layout.anchor] + Array(Set(urls.dropFirst())).sorted { $0.path < $1.path }
        for url in urls {
            let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.nativeLockUnavailable, rootCheck: .verified, posixErrno: errno) }
            var info = stat(); var named = stat()
            guard fstat(fd, &info) == 0, lstat(url.path, &named) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_dev == named.st_dev, info.st_ino == named.st_ino,
                  flock(fd, operation | LOCK_NB) == 0 else {
                let code = errno; close(fd)
                throw RuntimeV2MaintenanceBootstrapFailure(.nativeLockUnavailable, rootCheck: .verified, posixErrno: code)
            }
            owner.locks.append((url, fd, .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))))
            if url == layout.anchor { owner.anchorFD = fd }
        }
        try owner.validate()
        return owner
    }
    func duplicateAnchor() throws -> Int32 {
        try mutex.withLock {
            let fd = dup(anchorFD)
            guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                if fd >= 0 { close(fd) }
                throw RuntimeV2MaintenanceError.crossProcessOwner("group anchor unavailable")
            }
            return fd
        }
    }
    func validate() throws {
        try mutex.withLock {
            try layout.checkRoot()
            for row in locks + directories {
                var opened = stat(); var named = stat()
                guard fstat(row.fd, &opened) == 0, lstat(row.url.path, &named) == 0,
                      UInt64(bitPattern: Int64(opened.st_dev)) == row.identity.device,
                      UInt64(opened.st_ino) == row.identity.inode,
                      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                    throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
                }
            }
            var receiptBudget = RuntimeV2IntentlessAuthorityMetadata.Budget()
            for row in directories {
                if try RuntimeV2MaintenanceCoordinator.readHistoryIntent(directory: row.url) == nil {
                    // Recheck beneath the actual held cohort as well. A new
                    // unknown journal cannot arrive after discovery unnoticed.
                    try RuntimeV2IntentlessAuthorityMetadata.validate(namespaceFD: row.fd,
                        namespace: row.url.lastPathComponent, rootDevice: layout.rootDevice,
                        rootInode: layout.rootInode, budget: &receiptBudget)
                }
            }
            let fd = open(layout.parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified) }
            guard let stream = fdopendir(fd) else { close(fd); throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified) }
            defer { closedir(stream) }
            var names = Set<String>(); var count = 0
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified) }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= 129 else { throw RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified) }
                names.insert(name)
            }
            guard names == layout.namespaceNames.union([layout.anchor.lastPathComponent]) else {
                throw RuntimeV2MaintenanceBootstrapFailure(.historySetChanged, rootCheck: .verified)
            }
        }
    }
}
