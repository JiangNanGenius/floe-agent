// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

public protocol DiagramRepository: Sendable {
    func create(_ document: DiagramDocument) async throws
    func load(_ id: UUID) async throws -> DiagramDocument
    func commit(_ batch: DiagramEditBatch, context: DiagramEditContext) async throws -> DiagramDocument
    func undo(_ id: UUID, expectedRevision: Int, redo: Bool) async throws -> DiagramDocument
    func history(_ id: UUID) async throws -> DiagramHistoryState
}
public struct DiagramHistoryState: Sendable, Equatable {
    public var canUndo: Bool
    public var canRedo: Bool
    public init(canUndo: Bool, canRedo: Bool) { self.canUndo = canUndo; self.canRedo = canRedo }
}
public enum DiagramCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func requestFingerprint(_ batch: DiagramEditBatch) throws -> String {
        func canonical(_ value: Any, key: String = "") -> Any {
            if let object = value as? [String: Any] { return object.mapValues { canonical($0) } .reduce(into: [String: Any]()) { result, entry in result[entry.key] = canonical(object[entry.key]!, key: entry.key) } }
            if let list = value as? [Any] {
                let normalized = list.map { canonical($0) }
                if key == "ids", let strings = normalized as? [String] { return strings.sorted() }
                return normalized
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: encode(batch))
        return digest(try JSONSerialization.data(withJSONObject: canonical(object), options: [.sortedKeys]))
    }
}

private struct DiagramRecord: Codable, Sendable {
    var document: DiagramDocument
    var undo: [DiagramDocument] = []
    var redo: [DiagramDocument] = []
    /// Exact request fingerprints survive undo and branch edits; retries return the current authoritative snapshot.
    var receipts: [UUID: String] = [:]
    mutating func commit(_ batch: DiagramEditBatch, context: DiagramEditContext, historyLimit: Int) throws -> DiagramDocument {
        let fingerprint = try DiagramCodec.requestFingerprint(batch)
        if let prior = receipts[batch.requestID] {
            guard prior == fingerprint else { throw DiagramError.duplicateRequest }
            return document
        }
        let after = try DiagramEditEngine.applying(batch, to: document, context: context)
        undo.append(document); if undo.count > historyLimit { undo.removeFirst(undo.count - historyLimit) }
        redo.removeAll(); document = after; receipts[batch.requestID] = fingerprint
        return document
    }
    mutating func restore(expectedRevision: Int, isRedo: Bool, historyLimit: Int) throws -> DiagramDocument {
        guard expectedRevision == document.revision else { throw DiagramError.conflict(expected: expectedRevision, actual: document.revision) }
        var restored: DiagramDocument
        if isRedo {
            guard let value = redo.popLast() else { throw DiagramError.invalid("nothing to redo") }
            restored = value; undo.append(document)
        } else {
            guard let value = undo.popLast() else { throw DiagramError.invalid("nothing to undo") }
            restored = value; redo.append(document)
        }
        if undo.count > historyLimit { undo.removeFirst(undo.count - historyLimit) }
        if redo.count > historyLimit { redo.removeFirst(redo.count - historyLimit) }
        restored.revision = document.revision + 1; document = restored; try document.validate()
        return document
    }
    var history: DiagramHistoryState { .init(canUndo: !undo.isEmpty, canRedo: !redo.isEmpty) }
}

public actor InMemoryDiagramRepository: DiagramRepository {
    private var records: [UUID: DiagramRecord] = [:]
    private let historyLimit: Int
    public init(historyLimit: Int = 32) { self.historyLimit = max(1, min(1_000, historyLimit)) }
    public func create(_ document: DiagramDocument) throws {
        try document.validate()
        guard records[document.id] == nil else { throw DiagramError.invalid("document already exists") }
        records[document.id] = .init(document: document)
    }
    public func load(_ id: UUID) throws -> DiagramDocument {
        guard let record = records[id] else { throw DiagramError.notFound(id) }; return record.document
    }
    public func commit(_ batch: DiagramEditBatch, context: DiagramEditContext = .init()) throws -> DiagramDocument {
        try Task.checkCancellation()
        guard var record = records[batch.documentID] else { throw DiagramError.notFound(batch.documentID) }
        let after = try record.commit(batch, context: context, historyLimit: historyLimit)
        records[batch.documentID] = record; return after
    }
    public func undo(_ id: UUID, expectedRevision: Int, redo: Bool = false) throws -> DiagramDocument {
        guard var record = records[id] else { throw DiagramError.notFound(id) }
        let after = try record.restore(expectedRevision: expectedRevision, isRedo: redo, historyLimit: historyLimit)
        records[id] = record; return after
    }
    public func history(_ id: UUID) throws -> DiagramHistoryState {
        guard let record = records[id] else { throw DiagramError.notFound(id) }; return record.history
    }
}

/// Independent demo/file implementation. Production hosts adapt DiagramRepository to their existing transaction service.
/// Cross-instance/process CAS is protected by a per-document flock; immutable replacement never truncates the old record.
public actor FileDiagramRepository: DiagramRepository {
    public let directory: URL
    private let historyLimit: Int
    private let maximumRecordBytes: Int
    public init(directory: URL, historyLimit: Int = 32, maximumRecordBytes: Int = 256 * 1_024 * 1_024) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), maximumRecordBytes > 0 else { throw DiagramError.invalid("explicit file repository root required") }
        self.directory = directory.standardizedFileURL; self.historyLimit = max(1, min(1_000, historyLimit)); self.maximumRecordBytes = maximumRecordBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard values[.type] as? FileAttributeType == .typeDirectory else { throw DiagramError.invalid("repository root must be a real directory") }
    }
    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func withLock<T>(_ id: UUID, _ operation: () throws -> T) throws -> T {
        let lockURL = directory.appendingPathComponent(id.uuidString + ".lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DiagramError.io("open document lock") }
        defer { _ = Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw DiagramError.io("document lock") } }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }
    private func read(_ id: UUID) throws -> DiagramRecord {
        let url = recordURL(id)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw DiagramError.notFound(id) }
            throw DiagramError.io("open document")
        }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximumRecordBytes else { throw DiagramError.corruptRecord }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw DiagramError.io("read document") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumRecordBytes else { throw DiagramError.corruptRecord }
        }
        let record: DiagramRecord
        do { record = try DiagramCodec.decode(DiagramRecord.self, from: data) }
        catch { throw DiagramError.corruptRecord }
        guard record.document.id == id else { throw DiagramError.corruptRecord }
        try record.document.validate()
        return record
    }
    private func write(_ record: DiagramRecord) throws {
        let data = try DiagramCodec.encode(record)
        guard data.count <= maximumRecordBytes else { throw DiagramError.invalid("file repository record limit") }
        try DiagramAtomicFile.write(data, to: recordURL(record.document.id))
    }
    public func create(_ document: DiagramDocument) throws {
        try document.validate()
        try withLock(document.id) {
            guard !FileManager.default.fileExists(atPath: recordURL(document.id).path) else { throw DiagramError.invalid("document already exists") }
            try write(.init(document: document))
        }
    }
    public func load(_ id: UUID) throws -> DiagramDocument { try withLock(id) { try read(id).document } }
    public func commit(_ batch: DiagramEditBatch, context: DiagramEditContext = .init()) throws -> DiagramDocument {
        try Task.checkCancellation()
        return try withLock(batch.documentID) {
            var record = try read(batch.documentID)
            let beforeRevision = record.document.revision
            let after = try record.commit(batch, context: context, historyLimit: historyLimit)
            try Task.checkCancellation()
            if beforeRevision != after.revision { try write(record) }
            return after
        }
    }
    public func undo(_ id: UUID, expectedRevision: Int, redo: Bool = false) throws -> DiagramDocument {
        try withLock(id) {
            var record = try read(id)
            let after = try record.restore(expectedRevision: expectedRevision, isRedo: redo, historyLimit: historyLimit)
            try write(record); return after
        }
    }
    public func history(_ id: UUID) throws -> DiagramHistoryState { try withLock(id) { try read(id).history } }
}

public enum DiagramAtomicFile {
    /// Caller owns any required file/provider coordination. Parent directory must already exist.
    public static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw DiagramError.invalid("explicit output URL required") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".diagram-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DiagramError.io("stage output") }
        var open = true
        defer { if open { _ = Darwin.close(fd) }; _ = unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw DiagramError.io("write staged output") }
                guard count > 0 else { throw DiagramError.io("short write") }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw DiagramError.io("flush staged output") }
        _ = Darwin.close(fd); open = false
        guard rename(temporary.path, url.path) == 0 else { throw DiagramError.io("replace output") }
        let directoryFD = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); _ = Darwin.close(directoryFD) }
    }
}

public actor DiagramSession {
    public let documentID: UUID
    public let repository: any DiagramRepository
    private var generation = 0
    private var isClosed = false
    public init(documentID: UUID, repository: any DiagramRepository) { self.documentID = documentID; self.repository = repository }
    private func check(_ token: Int) throws {
        guard !isClosed else { throw DiagramError.closed }
        guard token == generation else { throw DiagramError.cancelled }
        try Task.checkCancellation()
    }
    public func snapshot() async throws -> DiagramDocument {
        let token = generation; try check(token)
        let result = try await repository.load(documentID); try check(token); return result
    }
    public func commit(_ batch: DiagramEditBatch, context: DiagramEditContext = .init()) async throws -> DiagramDocument {
        let token = generation; try check(token)
        guard batch.documentID == documentID else { throw DiagramError.notFound(batch.documentID) }
        let result = try await repository.commit(batch, context: context); try check(token); return result
    }
    public func undo(expectedRevision: Int, redo: Bool = false) async throws -> DiagramDocument {
        let token = generation; try check(token)
        let result = try await repository.undo(documentID, expectedRevision: expectedRevision, redo: redo); try check(token); return result
    }
    /// Fences asynchronous results; it never redirects an in-flight commit to another document.
    public func cancelPendingResults() { generation += 1 }
    public func close() { isClosed = true; generation += 1 }
}
