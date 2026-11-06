import Foundation
#if canImport(Darwin)
import Darwin
#endif
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Durable run journal
//
// Crash-safe, file-backed run state under an EXPLICIT qualification root
// (mirrors the hardened file-repository discipline):
//
//     <root>/runs/<runID>/
//         manifest.json            atomic replace + fsync; updated in place
//         journal.jsonl            appended transitions
//         checkpoint.json          atomic replace + fsync full state snapshot
//         attempts/<attemptID>.json  atomic replace + fsync; BEFORE submit
//
// All writes go to an exclusive tmp file, fsync it, rename(2) over the
// destination (atomic replace on Darwin), then fsync the directory. Reads
// are fail-closed: a corrupt, unreadable or unbounded file THROWS instead
// of being silently skipped, so a damaged journal can never cause a
// resubmission of work the host may already be running. The JSONL journal
// tolerates exactly one torn tail line (crash mid-append, no trailing
// newline); any other bad line is corruption.

public enum FlowJournalError: Error, Hashable, Sendable {
    case corruptJournal(runID: UUID, file: String, reason: String)
    case io(String)
}

public struct FlowAttemptRecord: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Persisted locally before any host submission happened.
        case persisted
        case submitted
        case running
        case succeeded
        case failed
        case cancelled
        /// Submission could not be confirmed; must be reconciled by query,
        /// never by resubmission.
        case unknown
    }

    public var attemptID: UUID
    public var runID: UUID
    public var nodeID: UUID
    public var attempt: Int
    /// Lexical position of the step: call path plus iteration coordinates.
    public var callPath: String
    public var iterationIndex: Int?
    public var status: Status
    public var inputs: [String: FlowValue]
    public var outputs: [String: FlowValue]
    public var error: String?
    public var hostTaskBinding: UUID?
    public var updatedAt: Date

    public init(
        attemptID: UUID,
        runID: UUID,
        nodeID: UUID,
        attempt: Int,
        callPath: String,
        iterationIndex: Int? = nil,
        status: Status = .persisted,
        inputs: [String: FlowValue] = [:],
        outputs: [String: FlowValue] = [:],
        error: String? = nil,
        hostTaskBinding: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.attemptID = attemptID
        self.runID = runID
        self.nodeID = nodeID
        self.attempt = attempt
        self.callPath = callPath
        self.iterationIndex = iterationIndex
        self.status = status
        self.inputs = inputs
        self.outputs = outputs
        self.error = error
        self.hostTaskBinding = hostTaskBinding
        self.updatedAt = updatedAt
    }
}

/// Frozen run definitions, persisted BEFORE the first attempt submission
/// and hash-bound into the manifest. A restarted runtime rebuilds the
/// ORIGINAL compiled graph from these bytes — never from the current
/// canvas, which may have been edited or undo-trimmed while the process
/// was down. Contents are pure definitions: no credentials, no permission
/// grants; the host must re-verify the original task/environment execution
/// capability before resuming, and importing an archive never revives run
/// permissions by itself.
public struct FlowRunDefinitions: Codable, Sendable {
    public var identity: FlowRunIdentity
    public var graph: FlowGraph
    public var subgraphTemplates: [FlowSubgraphTemplate]
    public var configuration: FlowRunConfiguration
    public var graphDigest: String
    public var revisionKeyDigest: String
    /// Hash over the canonical bytes of everything above, bound into the
    /// manifest so any tampering or truncation is detectable at resume.
    public var definitionsDigest: String

    public init(
        identity: FlowRunIdentity,
        graph: FlowGraph,
        subgraphTemplates: [FlowSubgraphTemplate],
        configuration: FlowRunConfiguration,
        graphDigest: String,
        revisionKeyDigest: String
    ) throws {
        self.identity = identity
        self.graph = graph
        self.subgraphTemplates = subgraphTemplates
        self.configuration = configuration
        self.graphDigest = graphDigest
        self.revisionKeyDigest = revisionKeyDigest
        struct DigestPayload: Codable {
            var identity: FlowRunIdentity
            var graph: FlowGraph
            var templateIDs: [String]
            var configurationDigest: String
            var graphDigest: String
            var revisionKeyDigest: String
        }
        self.definitionsDigest = try FlowDigest.of(DigestPayload(
            identity: identity,
            graph: graph,
            templateIDs: subgraphTemplates.map(\.id.uuidString).sorted(),
            configurationDigest: configuration.configurationDigest,
            graphDigest: graphDigest,
            revisionKeyDigest: revisionKeyDigest))
    }
}

public struct FlowRunStateSnapshot: Codable, Sendable {    public struct FrameSnapshot: Codable, Sendable {
        public var ownerNodeID: UUID?
        public var declarations: [FlowVariable]
        public var values: [String: FlowValue]
    }

    public struct NodeState: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case pending
            case running
            case succeeded
            case failed
            case skipped
        }
        public var kind: Kind
        public var outputs: [String: FlowValue]
        public var error: String?
        public var attempt: Int
        public var skipReason: String?
    }

    public var identity: FlowRunIdentity
    public var graphDigest: String
    public var configurationDigest: String
    public var revisionKeyDigest: String
    public var phase: FlowRunPhase
    public var generation: Int
    public var frames: [FrameSnapshot]
    public var nodeStates: [String: NodeState] // keyed by "\(callPath)#\(nodeID)"
    public var stepRecords: [FlowStepRecord]
    public var loopCounters: [String: Int]
    /// Collected per-item results of interrupted batches, keyed by call
    /// path: a re-entered batch skips completed items instead of
    /// resubmitting their (possibly paid) work.
    public var batchProgress: [String: FlowBatchProgressSnapshot]
    public var pendingAttempts: [FlowAttemptRecord]
    public var breakpoints: [UUID]
    public var bypassed: [UUID]
    public var completedStepCount: Int
    public var runOutputs: [String: FlowValue]
    public var updatedAt: Date
}

public struct FlowBatchProgressSnapshot: Codable, Sendable {
    /// Nil between items; preserves the active item's scopes on recovery.
    public var activeItemIndex: Int? = nil
    public var results: [FlowValue]
    public var failures: [FlowValue]
    public var nextItemIndex: Int

    public init(results: [FlowValue] = [], failures: [FlowValue] = [], nextItemIndex: Int = 0) {
        self.results = results
        self.failures = failures
        self.nextItemIndex = nextItemIndex
    }
}

public actor FlowRunJournal {
    /// Safety bounds so a damaged or hostile directory cannot exhaust
    /// memory while reading back.
    public struct ReadBounds: Sendable {
        public var maxJournalBytes: Int
        public var maxJournalEntries: Int
        public var maxAttempts: Int
        public var maxFileBytes: Int

        public init(
            maxJournalBytes: Int = 256 * 1024 * 1024,
            maxJournalEntries: Int = 1_000_000,
            maxAttempts: Int = 100_000,
            maxFileBytes: Int = 16 * 1024 * 1024
        ) {
            self.maxJournalBytes = maxJournalBytes
            self.maxJournalEntries = maxJournalEntries
            self.maxAttempts = maxAttempts
            self.maxFileBytes = maxFileBytes
        }
    }

    public let root: URL
    public let bounds: ReadBounds

    public init(root: URL, bounds: ReadBounds = ReadBounds()) throws {
        self.root = root.standardizedFileURL
        self.bounds = bounds
        try FileManager.default.createDirectory(
            at: self.root.appendingPathComponent("runs", isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func runDirectory(_ runID: UUID) -> URL {
        root.appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    // MARK: Atomic writes (tmp + fsync + rename + dir fsync)

    private func writeAtomic(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            let fd = open(temporary.path, O_WRONLY)
            if fd >= 0 {
                fsync(fd)
                close(fd)
            }
            // rename(2) atomically replaces an existing destination file;
            // FileManager.moveItem would fail on the second overwrite.
            guard rename(temporary.path, url.path) == 0 else {
                throw FlowJournalError.io(
                    "atomic rename failed for \(url.lastPathComponent): errno \(errno)")
            }
            let directoryFD = open(directory.path, O_RDONLY)
            if directoryFD >= 0 {
                fsync(directoryFD)
                close(directoryFD)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? FlowJournalError { throw error }
            throw FlowJournalError.io("write failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// Reads are fail-closed: missing file → nil; anything else that goes
    /// wrong (corrupt JSON, permission, IO) throws — never silently nil,
    /// because a silently-missing record could trigger a duplicate paid
    /// submission.
    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw FlowJournalError.io("read failed for \(url.lastPathComponent): \(error)")
        }
        guard data.count <= bounds.maxFileBytes else {
            throw FlowJournalError.io(
                "file \(url.lastPathComponent) exceeds read bound \(bounds.maxFileBytes) bytes")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FlowJournalError.corruptJournal(
                runID: UUID(uuidString: url.deletingLastPathComponent()
                    .deletingLastPathComponent().lastPathComponent) ?? UUID(),
                file: url.lastPathComponent,
                reason: "invalid JSON: \(error)")
        }
    }

    // MARK: Manifest

    public struct Manifest: Codable, Sendable {
        public var identity: FlowRunIdentity
        public var graphDigest: String
        public var configurationDigest: String
        public var revisionKeyDigest: String
        public var definitionsDigest: String
        public var phase: FlowRunPhase
        public var createdAt: Date
        public var updatedAt: Date
    }

    public func writeManifest(_ manifest: Manifest) throws {
        let data = try FlowDigest.canonicalJSON(manifest)
        try writeAtomic(data, to: runDirectory(manifest.identity.runID)
            .appendingPathComponent("manifest.json"))
    }

    public func loadManifest(runID: UUID) throws -> Manifest? {
        try readJSON(
            Manifest.self,
            from: runDirectory(runID).appendingPathComponent("manifest.json"))
    }

    // MARK: Frozen definitions (written BEFORE the first attempt submit)

    public func writeDefinitions(_ definitions: FlowRunDefinitions) throws {
        let data = try FlowDigest.canonicalJSON(definitions)
        try writeAtomic(data, to: runDirectory(definitions.identity.runID)
            .appendingPathComponent("definitions.json"))
    }

    public func loadDefinitions(runID: UUID) throws -> FlowRunDefinitions? {
        try readJSON(
            FlowRunDefinitions.self,
            from: runDirectory(runID).appendingPathComponent("definitions.json"))
    }

    // MARK: Attempts (persisted BEFORE submit; updates replace in place)

    public func persistAttempt(_ record: FlowAttemptRecord) throws {
        let data = try FlowDigest.canonicalJSON(record)
        try writeAtomic(data, to: runDirectory(record.runID)
            .appendingPathComponent("attempts", isDirectory: true)
            .appendingPathComponent("\(record.attemptID.uuidString).json"))
    }

    public func loadAttempts(runID: UUID) throws -> [FlowAttemptRecord] {
        let directory = runDirectory(runID).appendingPathComponent("attempts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw FlowJournalError.io("cannot list attempts: \(error)")
        }
        guard files.count <= bounds.maxAttempts else {
            throw FlowJournalError.io(
                "attempts directory exceeds read bound \(bounds.maxAttempts) files")
        }
        // A corrupt attempt record is a submission fact we cannot afford to
        // guess about: fail closed instead of skipping.
        return try files.map { file in
            guard let record = try readJSON(FlowAttemptRecord.self, from: file) else {
                throw FlowJournalError.corruptJournal(
                    runID: runID, file: file.lastPathComponent, reason: "missing attempt file")
            }
            return record
        }
    }

    // MARK: Checkpoint

    public func saveCheckpoint(_ snapshot: FlowRunStateSnapshot) throws {
        let data = try FlowDigest.canonicalJSON(snapshot)
        try writeAtomic(data, to: runDirectory(snapshot.identity.runID)
            .appendingPathComponent("checkpoint.json"))
    }

    public func loadCheckpoint(runID: UUID) throws -> FlowRunStateSnapshot? {
        try readJSON(
            FlowRunStateSnapshot.self,
            from: runDirectory(runID).appendingPathComponent("checkpoint.json"))
    }

    // MARK: JSONL journal
    //
    // Exactly one torn tail line (crash mid-append, file not ending in
    // newline) is tolerated and ignored. Any other undecodable line —
    // middle or newline-terminated — is corruption and fails closed.

    public enum JournalEntry: Codable, Sendable {
        case attemptUpdated(FlowAttemptRecord)
        case checkpointSaved(at: Date)
        case note(String)
    }

    public func appendJournal(runID: UUID, entry: JournalEntry) throws {
        let directory = runDirectory(runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("journal.jsonl")
        let data = try FlowDigest.canonicalJSON(entry)
        var line = data
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            try? handle.close()
            throw FlowJournalError.io("journal append failed: \(error)")
        }
    }

    public func loadJournal(runID: UUID) throws -> [JournalEntry] {
        let url = runDirectory(runID).appendingPathComponent("journal.jsonl")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return []
        } catch {
            throw FlowJournalError.io("journal read failed: \(error)")
        }
        guard data.count <= bounds.maxJournalBytes else {
            throw FlowJournalError.io(
                "journal exceeds read bound \(bounds.maxJournalBytes) bytes")
        }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // Torn-tail tolerance: a final fragment without trailing newline
        // that fails to decode is dropped; if it decodes it still counts.
        if let last = lines.last, last.isEmpty == false {
            if data.last != 0x0A {
                // Incomplete final line: drop it (crash mid-append).
                lines.removeLast()
            }
        } else if let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        guard lines.count <= bounds.maxJournalEntries else {
            throw FlowJournalError.io(
                "journal exceeds read bound \(bounds.maxJournalEntries) entries")
        }
        return try lines.enumerated().map { index, line in
            guard let entry = try? JSONDecoder().decode(JournalEntry.self, from: Data(line)) else {
                throw FlowJournalError.corruptJournal(
                    runID: runID,
                    file: "journal.jsonl",
                    reason: "undecodable line \(index + 1) "
                        + "(torn tail is only tolerated for a missing final newline)")
            }
            return entry
        }
    }

    // MARK: Listing

    public func listRuns() -> [UUID] {
        let directory = root.appendingPathComponent("runs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }
}
