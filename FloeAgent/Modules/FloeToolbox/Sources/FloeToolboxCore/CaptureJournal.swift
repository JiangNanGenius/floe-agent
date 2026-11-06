import Foundation
import Darwin

/// Production hosts supply their existing transactional store. The file
/// implementation remains available for component hosts and local snapshots.
public protocol CaptureRepository: Sendable {
    func load(captureID: UUID, ownerID: UUID) async throws -> CaptureState?
    func commit(_ next: CaptureState, expectedRevision: UInt64) async throws
    func saveSnapshot(_ state: CaptureState) async throws -> URL
}

/// A local qualification repository. Production may adapt this boundary to existing SQLite/CAS services.
public final class FileCaptureRepository: CaptureRepository, Sendable {
    public let root: URL
    private let maximumFileBytes = 128 * 1024 * 1024
    public init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw ToolboxError.invalid("explicit capture root") }
        let standardized = root.standardizedFileURL
        try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        guard standardized.resolvingSymlinksInPath().path == standardized.path else { throw ToolboxError.invalid("symlink capture root") }
        self.root = standardized
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let fd = Darwin.open(root.appendingPathComponent(".capture.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ToolboxError.invalid("capture lock") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ToolboxError.invalid("capture lock") }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }
    private func path(_ id: UUID) -> URL { root.appendingPathComponent("capture-\(id.uuidString).json") }
    private func read(_ url: URL) throws -> CaptureState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true, let size = info.fileSize,
              size <= maximumFileBytes else { throw ToolboxError.corruptStore }
        let value: CaptureState
        do { value = try JSONDecoder().decode(CaptureState.self, from: Data(contentsOf: url)) }
        catch { throw ToolboxError.corruptStore }
        guard value.version == 1, value.records.count <= 100_000,
              value.records.allSatisfy({ $0.bytes.count <= 1024 * 1024 && $0.originalByteCount >= $0.bytes.count && $0.notes.count <= 16 }),
              value.retainedBytes <= 64 * 1024 * 1024 else { throw ToolboxError.corruptStore }
        var previous: UInt64 = 0
        for record in value.records {
            guard record.sequence > previous else { throw ToolboxError.corruptStore }; previous = record.sequence
        }
        guard value.nextSequence > previous else { throw ToolboxError.corruptStore }
        return value
    }
    public func load(captureID: UUID, ownerID: UUID) throws -> CaptureState? {
        try locked {
            let state = try read(path(captureID))
            if let state, state.captureID != captureID || state.ownerID != ownerID { throw ToolboxError.denied }
            return state
        }
    }
    public func commit(_ next: CaptureState, expectedRevision: UInt64) throws {
        try locked {
            let current = try read(path(next.captureID))
            guard current?.ownerID == nil || current?.ownerID == next.ownerID else { throw ToolboxError.denied }
            guard expectedRevision < UInt64.max, (current?.revision ?? 0) == expectedRevision,
                  next.revision == expectedRevision + 1 else { throw ToolboxError.revisionConflict }
            let bytes = try JSONEncoder().encode(next)
            guard bytes.count <= maximumFileBytes else { throw ToolboxError.limit("capture file") }
            let destination = path(next.captureID)
            if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ToolboxError.invalid("capture symlink") }
            try bytes.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    public func saveSnapshot(_ state: CaptureState) throws -> URL {
        try locked {
            let file = root.appendingPathComponent("snapshot-\(UUID().uuidString).json")
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        }
    }
}

public struct CaptureEvent: Sendable {
    public var bytes: Data
    public var direction: CaptureDirection
    public var layer: CaptureLayer
    public var origin: CaptureOrigin
    public var timestamp: Date?
    public var originalByteCount: Int
    public var redacted: Bool
    public var notes: [String]
    public init(bytes: Data, direction: CaptureDirection, layer: CaptureLayer = .applicationBytes,
                origin: CaptureOrigin = .liveSession, timestamp: Date? = Date(), originalByteCount: Int? = nil,
                redacted: Bool = false, notes: [String] = []) {
        self.bytes = bytes; self.direction = direction; self.layer = layer; self.origin = origin
        self.timestamp = timestamp; self.originalByteCount = originalByteCount ?? bytes.count
        self.redacted = redacted; self.notes = notes
    }
}

public actor CaptureJournal {
    public nonisolated let ownerID: UUID
    public nonisolated let captureID: UUID
    private let repository: any CaptureRepository
    private let limits: CaptureLimits
    private let redactor: CaptureRedactor
    private var state: CaptureState
    private var writing = false
    private var writers: [CheckedContinuation<Void, Never>] = []

    private func beginWrite() async throws {
        guard writing else { writing = true; return }
        guard writers.count < 8 else { throw ToolboxError.limit("pending capture commits") }
        await withCheckedContinuation { writers.append($0) }
    }
    private func endWrite() {
        if writers.isEmpty { writing = false }
        else { writers.removeFirst().resume() }
    }
    public init(ownerID: UUID, captureID: UUID = UUID(), repository: FileCaptureRepository, limits: CaptureLimits,
                redactor: CaptureRedactor = CaptureRedactor()) throws {
        self.ownerID = ownerID; self.captureID = captureID; self.repository = repository; self.limits = limits
        self.state = try repository.load(captureID: captureID, ownerID: ownerID) ?? CaptureState(captureID: captureID, ownerID: ownerID)
        self.redactor = redactor
    }
    public init(ownerID: UUID, captureID: UUID = UUID(), repository: any CaptureRepository, limits: CaptureLimits,
                redactor: CaptureRedactor = CaptureRedactor()) async throws {
        self.ownerID = ownerID; self.captureID = captureID; self.repository = repository; self.limits = limits
        self.state = try await repository.load(captureID: captureID, ownerID: ownerID) ?? CaptureState(captureID: captureID, ownerID: ownerID)
        self.redactor = redactor
    }
    public func snapshot() -> CaptureState { state }
    public func reload() async throws {
        try await beginWrite(); defer { endWrite() }
        state = try await repository.load(captureID: captureID, ownerID: ownerID) ?? CaptureState(captureID: captureID, ownerID: ownerID)
    }
    public func append(_ events: [CaptureEvent]) async throws {
        try await beginWrite(); defer { endWrite() }
        guard events.count <= limits.maximumRecords, state.revision < UInt64.max,
              UInt64(events.count) < UInt64.max - state.nextSequence else { throw ToolboxError.limit("capture batch or sequence") }
        var next = state
        for event in events {
            guard event.originalByteCount >= event.bytes.count, event.notes.count <= 16,
                  event.notes.allSatisfy({ $0.utf8.count <= 2048 }) else { throw ToolboxError.invalid("capture event") }
            let safe = redactor.sanitize(event.bytes, wireProtocol: .raw)
            let data = Data(safe.bytes.prefix(limits.maximumRecordBytes))
            var notes = event.notes.map { redactor.sanitizeText($0) } + safe.notes
            if data.count < safe.bytes.count { notes = Array(notes.prefix(15)) + ["Record byte limit reached"] }
            next.records.append(CaptureRecord(sequence: next.nextSequence, timestamp: event.timestamp,
                direction: event.direction, layer: event.layer, origin: event.origin, bytes: data,
                originalByteCount: event.originalByteCount, redacted: event.redacted || safe.redacted, notes: Array(notes.prefix(16))))
            next.nextSequence += 1
        }
        var drop = 0, bytes = next.retainedBytes
        while next.records.count - drop > limits.maximumRecords || bytes > limits.maximumBytes {
            bytes -= next.records[drop].bytes.count; drop += 1
        }
        if drop > 0 {
            guard next.droppedRecords <= UInt64.max - UInt64(drop) else { throw ToolboxError.limit("dropped record counter") }
            next.records = Array(next.records.dropFirst(drop)); next.droppedRecords += UInt64(drop)
        }
        next.revision += 1
        try await repository.commit(next, expectedRevision: state.revision)
        state = next
    }
    public func saveSnapshot() async throws -> URL { try await repository.saveSnapshot(state) }
    /// Application events are exported as events, never fabricated IP packets or PCAP files.
    public func exportJSONLines() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result = Data()
        let header = ["format": "floe.capture.jsonl", "version": "1", "captureID": captureID.uuidString,
                      "droppedRecords": String(state.droppedRecords)]
        result.append(try encoder.encode(header)); result.append(0x0a)
        for record in state.records { result.append(try encoder.encode(record)); result.append(0x0a) }
        return result
    }
}

/// Host-provided known secret bytes are checked before any persistence or AI extraction.
public struct CaptureRedactor: Sendable {
    private let knownSecrets: [Data]
    public init(knownSecrets: [Data] = []) { self.knownSecrets = knownSecrets.filter { !$0.isEmpty } }
    public func sanitize(_ data: Data, wireProtocol: SerialProtocol) -> CaptureEvent {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        let credentialLike = ["authorization:", "cookie:", "set-cookie:", "\"password\"", "\"token\"", "\"api_key\"", "\"secret\"",
                              "password=", "password:", "token=", "api_key=", "apikey=", "secret=", "bearer "].contains { text.contains($0) }
        let sensitiveMQTT = [.mqtt311, .mqtt5].contains(wireProtocol) && data.first.map { [1, 15].contains($0 >> 4) } == true
        if credentialLike || sensitiveMQTT || knownSecrets.contains(where: { data.range(of: $0) != nil }) {
            return CaptureEvent(bytes: Data(), direction: .observation, originalByteCount: data.count,
                                redacted: true, notes: ["Credential-bearing payload omitted before persistence"])
        }
        return CaptureEvent(bytes: data, direction: .observation)
    }
    public func sanitizeText(_ text: String) -> String {
        let event = sanitize(Data(text.utf8), wireProtocol: .raw)
        return event.redacted ? "[Sensitive content omitted]" : text
    }
}
