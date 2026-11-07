// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

public struct EDAStoredProject: Sendable, Equatable {
    public let project: EDAProject
    public let digest: String
    public init(project: EDAProject, digest: String) { self.project = project; self.digest = digest }
}

/// A store is bound to an original chosen by the host. Model-supplied paths
/// never construct one. All readers/writers of this package share its lock.
public actor EDAProjectStore {
    public nonisolated let root: URL
    public nonisolated let projectID: UUID
    private let maximumBytes: Int
    private let readOnly: Bool
    public init(root: URL, projectID: UUID, readOnly: Bool = false, maximumBytes: Int = 64 * 1024 * 1024) throws {
        guard root.isFileURL, maximumBytes > 0, maximumBytes <= 512 * 1024 * 1024 else { throw EDAError.invalid("store location") }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory), directory.boolValue else {
            throw EDAError.missing("project directory")
        }
        self.root = canonical; self.projectID = projectID; self.maximumBytes = maximumBytes; self.readOnly = readOnly
    }
    public static func create(root: URL, project: EDAProject) async throws -> EDAProjectStore {
        try EDAValidation.validate(project)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let store = try EDAProjectStore(root: root, projectID: project.id)
        try await store.createOriginal(project)
        return store
    }
    public func load() async throws -> EDAStoredProject {
        try await locked { directory in try decode(read("project.json", in: directory)) }
    }
    public func save(_ project: EDAProject, expectedRevision: UInt64, expectedDigest: String) async throws -> EDAStoredProject {
        guard !readOnly else { throw EDAError.readOnly }
        guard project.id == projectID else { throw EDAError.invalid("project identity") }
        try EDAValidation.validate(project)
        let bytes = try encoded(project)
        return try await locked { directory in
            let oldBytes = try read("project.json", in: directory), old = try decode(oldBytes)
            guard old.project.revision == expectedRevision, old.digest == expectedDigest else {
                throw EDAError.staleRevision(expected: expectedRevision, actual: old.project.revision)
            }
            if project == old.project { return old }
            guard project.revision > old.project.revision else { throw EDAError.invalid("non-increasing revision") }
            try Task.checkCancellation()
            try preserveHistory(oldBytes, snapshot: old, directory: directory)
            try write(bytes, name: "project.json", directory: directory, replacing: true)
            return try decode(read("project.json", in: directory))
        }
    }
    public func history() async throws -> [EDAStoredProject] {
        try await locked { directory in
            let historyFD = openat(directory, "history", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if historyFD < 0 {
                if errno == ENOENT { return [] }; throw posixError()
            }
            defer { close(historyFD) }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("history").path)
                .filter { $0.range(of: #"^[0-9]{20}-[0-9a-f]{64}\.json$"#, options: .regularExpression) != nil }
                .sorted().suffix(100)
            return try names.map { try decode(read($0, in: historyFD)) }
        }
    }
    private func createOriginal(_ project: EDAProject) async throws {
        guard !readOnly, project.id == projectID else { throw EDAError.invalid("project identity") }
        let bytes = try encoded(project)
        try await locked { directory in
            var info = stat()
            if fstatat(directory, "project.json", &info, AT_SYMLINK_NOFOLLOW) == 0 { throw EDAError.duplicate("project original") }
            guard errno == ENOENT else { throw posixError() }
            try Task.checkCancellation()
            try write(bytes, name: "project.json", directory: directory, replacing: false)
        }
    }
    private func encoded(_ project: EDAProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(project)
        guard bytes.count <= maximumBytes else { throw EDAError.invalid("project byte limit") }
        return bytes
    }
    private func decode(_ bytes: Data) throws -> EDAStoredProject {
        guard bytes.count <= maximumBytes else { throw EDAError.invalid("project byte limit") }
        let project = try JSONDecoder().decode(EDAProject.self, from: bytes)
        guard project.id == projectID else { throw EDAError.invalid("project identity") }
        try EDAValidation.validate(project)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(project: project, digest: digest)
    }
    private func read(_ name: String, in directory: Int32) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw EDAError.invalid("regular project file") }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, maximumBytes + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= maximumBytes else { throw EDAError.invalid("project byte limit") }
        }
        return result
    }
    private func write(_ bytes: Data, name: String, directory: Int32, replacing: Bool) throws {
        let pending = ".pending-" + UUID().uuidString + ".json"
        let descriptor = openat(directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directory, pending, 0) }
        try handle.write(contentsOf: bytes); try handle.synchronize()
        try Task.checkCancellation()
        if replacing {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else { throw EDAError.invalid("original replaced") }
            guard renameat(directory, pending, directory, name) == 0 else { throw posixError() }
        } else {
            // Atomic creation cannot replace an existing original, including
            // a concurrently inserted file or symlink.
            guard linkat(directory, pending, directory, name, 0) == 0 else { throw posixError() }
        }
        _ = fsync(directory)
    }
    private func preserveHistory(_ bytes: Data, snapshot: EDAStoredProject, directory: Int32) throws {
        if mkdirat(directory, "history", 0o700) != 0, errno != EEXIST { throw posixError() }
        let historyFD = openat(directory, "history", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard historyFD >= 0 else { throw posixError() }; defer { close(historyFD) }
        let name = String(format: "%020llu", snapshot.project.revision) + "-" + snapshot.digest + ".json"
        var info = stat()
        if fstatat(historyFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard try read(name, in: historyFD) == bytes else { throw EDAError.invalid("history conflict") }
        } else {
            guard errno == ENOENT else { throw posixError() }
            try write(bytes, name: name, directory: historyFD, replacing: false)
        }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func locked<T: Sendable>(_ body: (Int32) throws -> T) async throws -> T {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw posixError() }; defer { close(directory) }
        let flags = (readOnly ? O_RDONLY : O_RDWR | O_CREAT) | O_NOFOLLOW | O_NONBLOCK
        let descriptor = openat(directory, ".floe-eda.lock", flags, 0o600)
        guard descriptor >= 0 else { throw posixError() }; defer { close(descriptor) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else {
            throw EDAError.invalid("regular project lock")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while flock(descriptor, (readOnly ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw posixError() }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw EDAError.invalid("project lock timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try body(directory)
    }
}
