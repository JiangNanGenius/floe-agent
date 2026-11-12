// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

public struct EDALibraryInstalledVersion: Codable, Hashable, Sendable {
    public let packageID: String
    public let version: String
    public let sha256: String
    public let title: String
    public let partCount: Int
    public init(packageID: String, version: String, sha256: String, title: String, partCount: Int) {
        self.packageID = packageID; self.version = version; self.sha256 = sha256; self.title = title; self.partCount = partCount
    }
}
public struct EDALibraryPreferences: Codable, Hashable, Sendable {
    public var favorites: [String] = []
    public var recent: [String] = []
    public init() {}
    public static func key(packageID: String, partID: String) -> String { packageID + "/" + partID }
}
public struct EDALibraryInventory: Codable, Hashable, Sendable {
    public var schemaVersion = 1
    public var revision: UInt64 = 0
    public var installed: [EDALibraryInstalledVersion] = []
    public var activeVersions: [String: String] = [:]
    public var preferences = EDALibraryPreferences()
    public var consumedContentSHA256: [String: String]? = nil
    public init() {}
}

/// User libraries are separate from project snapshots and immutable bundle
/// resources. Each version has its own hash-addressed file. Installing a new
/// version changes only the library pointer, never an existing EDA original.
public actor EDALibraryStore {
    public nonisolated let root: URL
    private let device: dev_t
    private let inode: ino_t
    public init(root: URL) throws {
        guard root.isFileURL, root.standardizedFileURL.path == root.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw EDAError.invalid("library directory identity")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw EDAError.invalid("library directory") }
        self.root = root.standardizedFileURL; device = info.st_dev; inode = info.st_ino
    }
    public func inventory() async throws -> EDALibraryInventory { try await locked { try readInventory($0) } }
    public func package(id: String, version: String? = nil) async throws -> EDALibraryPackage {
        try await locked { directory in
            let index = try readInventory(directory)
            guard let version = version ?? index.activeVersions[id],
                  let item = index.installed.first(where: { $0.packageID == id && $0.version == version }) else { throw EDAError.missing("installed library version") }
            return try readPackage(item, in: directory)
        }
    }
    /// A single file-lock snapshot supplies both UI and model discovery.
    public func catalog() async throws -> EDALibraryCatalog {
        try await locked { directory in
            let index = try readInventory(directory)
            var entries: [EDALibraryEntry] = [], sourceBytes = 0
            for (id, version) in index.activeVersions.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                guard let record = index.installed.first(where: { $0.packageID == id && $0.version == version }) else { throw EDAError.invalid("active library version") }
                let value = try readPackage(record, in: directory)
                sourceBytes += value.sourcePayloads.values.reduce(0) { $0 + $1.count }
                guard sourceBytes <= 128 * 1_024 * 1_024, entries.count + value.parts.count <= 100_000 else { throw EDAError.invalid("active library catalog budget") }
                entries += value.parts.map { .init(reference: .init(packageID: id, version: version, packageSHA256: record.sha256, partID: $0.id), part: $0) }
            }
            return .init(inventoryRevision: index.revision, entries: entries, preferences: index.preferences)
        }
    }
    public func snapshot(_ reference: EDALibraryReference) async throws -> EDALibrarySnapshot {
        let package = try await package(id: reference.packageID, version: reference.version)
        let snapshot = try EDALibrarySnapshot(package: package, partID: reference.partID)
        guard snapshot.packageSHA256 == reference.packageSHA256 else { throw EDAError.invalid("library reference checksum") }
        return snapshot
    }
    private func readPackage(_ item: EDALibraryInstalledVersion, in directory: Int32) throws -> EDALibraryPackage {
        let packages = try openDirectory("packages", in: directory, create: false); defer { close(packages) }
        let bytes = try read(item.sha256 + ".json", in: packages, maximum: 256 * 1_024 * 1_024)
        guard EDALibraryDigest.sha256(bytes) == item.sha256 else { throw EDAError.invalid("installed library checksum") }
        let value = try EDALibraryPackage.decode(bytes)
        guard value.id == item.packageID, value.version == item.version else { throw EDAError.invalid("installed library identity") }
        return value
    }
    @discardableResult public func install(_ package: EDALibraryPackage, expectedInventoryRevision: UInt64? = nil, activate: Bool = true, deliveredContentSHA256: String? = nil,
                                           cancelled: @Sendable () -> Bool = { false }) async throws -> EDALibraryInstalledVersion {
        try package.validate()
        let bytes = try EDALibraryDigest.encoded(package)
        guard bytes.count <= 256 * 1_024 * 1_024 else { throw EDAError.invalid("library package size") }
        let hash = EDALibraryDigest.sha256(bytes)
        if let deliveredContentSHA256, !EDALibraryDigest.validSHA256(deliveredContentSHA256) { throw EDAError.invalid("delivered library content hash") }
        return try await locked { directory in
            var index = try readInventory(directory)
            if let expectedInventoryRevision, index.revision != expectedInventoryRevision {
                throw EDAError.staleRevision(expected: expectedInventoryRevision, actual: index.revision)
            }
            if let existing = index.installed.first(where: { $0.packageID == package.id && $0.version == package.version }), existing.sha256 != hash {
                throw EDAError.duplicate("immutable library version has different bytes; import as a new version or library")
            }
            guard !cancelled(), !Task.isCancelled else { throw EDAError.cancelled }
            if let deliveredContentSHA256, index.consumedContentSHA256?[package.id] == deliveredContentSHA256 {
                guard let record = index.installed.first(where: { $0.packageID == package.id && $0.version == package.version && $0.sha256 == hash }) else { throw EDAError.invalid("delivered library receipt has no matching immutable version") }
                _ = try readPackage(record, in: directory)
                // A repeated delivery must preserve a later explicit user
                // version choice, rather than continually reactivating latest.
                return record
            }
            let packages = try openDirectory("packages", in: directory, create: true); defer { close(packages) }
            let name = hash + ".json"
            var info = stat()
            if fstatat(packages, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard try read(name, in: packages, maximum: 256 * 1_024 * 1_024) == bytes else { throw EDAError.invalid("library blob changed") }
            } else {
                guard errno == ENOENT else { throw posix() }
                try write(bytes, name: name, in: packages, replacing: false)
            }
            let record = EDALibraryInstalledVersion(packageID: package.id, version: package.version, sha256: hash,
                title: package.title, partCount: package.parts.count)
            if !index.installed.contains(record) { index.installed.append(record) }
            if activate {
                var prospective = index
                prospective.activeVersions[package.id] = package.version
                try validateCatalogBudget(prospective, replacing: package, in: directory)
                index.activeVersions[package.id] = package.version
            }
            if let deliveredContentSHA256 { index.consumedContentSHA256 = (index.consumedContentSHA256 ?? [:]).merging([package.id: deliveredContentSHA256]) { _, new in new } }
            guard !cancelled(), !Task.isCancelled else { throw EDAError.cancelled }
            try saveInventory(&index, in: directory)
            return record
        }
    }
    public func setFavorite(packageID: String, partID: String, enabled: Bool) async throws {
        try await preferences { value in
            let key = EDALibraryPreferences.key(packageID: packageID, partID: partID)
            value.favorites.removeAll { $0 == key }
            if enabled { value.favorites.append(key); value.favorites.sort() }
        }
    }
    public func recordUse(packageID: String, partID: String) async throws {
        try await preferences { value in
            let key = EDALibraryPreferences.key(packageID: packageID, partID: partID)
            value.recent.removeAll { $0 == key }; value.recent.insert(key, at: 0)
            if value.recent.count > 100 { value.recent.removeLast(value.recent.count - 100) }
        }
    }
    private func preferences(_ change: (inout EDALibraryPreferences) throws -> Void) async throws {
        try await locked { directory in
            var index = try readInventory(directory); try change(&index.preferences)
            guard index.preferences.favorites.count <= 10_000 else { throw EDAError.invalid("favorite limit") }
            try saveInventory(&index, in: directory)
        }
    }
    /// The catalog aggregates every active package under fixed budgets. A new
    /// remote part with a large retained original must not activate an index
    /// that makes every previously usable library unreadable. The prospective
    /// check runs under the store lock/CAS before the active index is saved.
    private func validateCatalogBudget(_ index: EDALibraryInventory, replacing package: EDALibraryPackage,
                                       in directory: Int32) throws {
        var sourceBytes = 0, partCount = 0
        for (id, version) in index.activeVersions.sorted(by: { $0.key < $1.key }) {
            let bytes: Int, parts: Int
            if id == package.id, version == package.version {
                bytes = package.sourcePayloads.values.reduce(0) { $0 + $1.count }
                parts = package.parts.count
            } else {
                guard let record = index.installed.first(where: { $0.packageID == id && $0.version == version }) else {
                    throw EDAError.invalid("active library version")
                }
                let value = try readPackage(record, in: directory)
                bytes = value.sourcePayloads.values.reduce(0) { $0 + $1.count }
                parts = value.parts.count
            }
            guard bytes <= 128 * 1_024 * 1_024 - sourceBytes,
                  parts <= 100_000 - partCount else {
                throw EDAError.invalid("active library catalog budget")
            }
            sourceBytes += bytes; partCount += parts
        }
    }
    private func readInventory(_ directory: Int32) throws -> EDALibraryInventory {
        var info = stat()
        if fstatat(directory, "index.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw posix() }; return .init()
        }
        let value = try JSONDecoder().decode(EDALibraryInventory.self, from: read("index.json", in: directory, maximum: 4 * 1_024 * 1_024))
        guard value.schemaVersion == 1, value.installed.count <= 4_096,
              Set(value.installed.map { $0.packageID + "/" + $0.version }).count == value.installed.count,
              value.installed.allSatisfy({ EDALibraryDigest.validSHA256($0.sha256) }),
              value.activeVersions.allSatisfy({ key, version in value.installed.contains { $0.packageID == key && $0.version == version } }),
              value.preferences.recent.count <= 100, value.preferences.favorites.count <= 10_000,
              (value.consumedContentSHA256?.count ?? 0) <= 4_096,
              (value.consumedContentSHA256 ?? [:]).values.allSatisfy(EDALibraryDigest.validSHA256) else { throw EDAError.invalid("library index integrity") }
        return value
    }
    private func saveInventory(_ index: inout EDALibraryInventory, in directory: Int32) throws {
        guard index.revision < UInt64.max, index.installed.count <= 4_096 else { throw EDAError.invalid("library index budget") }
        index.revision += 1
        let bytes = try EDALibraryDigest.encoded(index)
        try write(bytes, name: "index.json", in: directory, replacing: true)
        guard try read("index.json", in: directory, maximum: 4 * 1_024 * 1_024) == bytes else { throw EDAError.invalid("library index readback") }
    }
    private func openDirectory(_ name: String, in parent: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw posix() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posix() }; return fd
    }
    private func read(_ name: String, in directory: Int32, maximum: Int) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw posix() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= maximum else { throw EDAError.invalid("bounded regular library file") }
        var data = Data()
        while let block = try file.read(upToCount: min(1_048_576, maximum + 1 - data.count)), !block.isEmpty {
            data.append(block); guard data.count <= maximum else { throw EDAError.invalid("library read budget") }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw EDAError.invalid("library original changed during read")
        }
        return data
    }
    private func write(_ bytes: Data, name: String, in directory: Int32, replacing: Bool) throws {
        let pending = ".pending-" + UUID().uuidString
        let fd = openat(directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posix() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(directory, pending, 0) }
        try file.write(contentsOf: bytes); try file.synchronize(); try Task.checkCancellation()
        if replacing {
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw EDAError.invalid("library destination replaced") }
                guard renameat(directory, pending, directory, name) == 0 else { throw posix() }
            } else {
                guard errno == ENOENT, linkat(directory, pending, directory, name, 0) == 0 else { throw posix() }
            }
        } else { guard linkat(directory, pending, directory, name, 0) == 0 else { throw posix() } }
        guard fsync(directory) == 0 else { throw posix() }
    }
    // Serialize first-open/create within this process. Each operation still
    // owns a separate descriptor and the OS lock coordinates other processes.
    private static let lockFileCreation = NSLock()
    private nonisolated static func openLock(in directory: Int32) throws -> Int32 {
        try lockFileCreation.withLock {
            let value = openat(directory, ".library.lock", O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0o600)
            guard value >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var info = stat()
            guard fstat(value, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(value); throw EDAError.invalid("regular library lock")
            }
            return value
        }
    }
    private func locked<T>(_ action: (Int32) throws -> T) async throws -> T {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posix() }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_ino == inode, info.st_dev == device else { throw EDAError.invalid("library root replaced") }
        let lock = try Self.openLock(in: fd); defer { close(lock) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw posix() }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw EDAError.invalid("library lock timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { _ = flock(lock, LOCK_UN) }
        try Task.checkCancellation()
        // Recheck after waiting; a replaced root cannot accept a late commit.
        var current = stat()
        guard lstat(root.path, &current) == 0, current.st_ino == inode, current.st_dev == device,
              (current.st_mode & S_IFMT) == S_IFDIR else { throw EDAError.invalid("library root replaced") }
        return try action(fd)
    }
    private func posix(operation: String = #function, line: UInt = #line) -> NSError {
        let code = Int(errno)
        return NSError(domain: NSPOSIXErrorDomain, code: code,
            userInfo: [NSDebugDescriptionErrorKey: "EDALibraryStore.\(operation):\(line)"])
    }
}
