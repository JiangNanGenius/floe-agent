// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — durable on-disk journal.
//
// One JSON record per enhancement job lives under
// `<mediaRoot>/Enhancements/.jobs/<jobID>.json`, written staged (`.part` +
// atomic replace) exactly like the workbench export recovery journal. This is
// NOT a second job database: the authoritative runtime state for interpolation
// is the original BackgroundJobService record; the journal freezes the
// enhancement contract (request, measured source facts, progress, receipt and
// the cloud remote job ID) so a relaunch can settle terminal state honestly
// and the UI can render progress without re-deriving anything.
import Foundation
import FloeCore

public struct G09R2EnhancementRecord: Codable, Sendable, Equatable {
    public var jobID: String
    public var projectID: UUID
    public var state: G09R2EnhancementJobState
    public var request: G09R2EnhancementRequestDTO
    public var sourceFacts: G09R2MediaProbeFacts
    /// The original durable exec.shell job for interpolation, when started.
    public var shellJobID: UUID?
    /// The cloud backend's own request ID, captured at dispatch and retained
    /// for unknown-outcome settlement and cancellation — per job, never
    /// shared across calls.
    public var remoteRequestID: String?
    /// The validated accepted handle (response/status/cancel URLs) persisted
    /// BEFORE the first poll; legacy records may carry only the request ID
    /// above, in which case the canonical owner/alias URLs are derived per
    /// the official fal-js parser.
    public var remoteHandle: G09R2SuperResolutionAcceptedHandle?
    public var lastProgress: G09R2EnhancementProgress?
    public var receipt: G09R2EnhancementReceipt?
    public var errorCode: String?
    public var errorDetail: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(jobID: String, projectID: UUID,
                state: G09R2EnhancementJobState,
                request: G09R2EnhancementRequestDTO,
                sourceFacts: G09R2MediaProbeFacts,
                shellJobID: UUID? = nil,
                remoteRequestID: String? = nil,
                remoteHandle: G09R2SuperResolutionAcceptedHandle? = nil,
                lastProgress: G09R2EnhancementProgress? = nil,
                receipt: G09R2EnhancementReceipt? = nil,
                errorCode: String? = nil, errorDetail: String? = nil,
                createdAt: Date, updatedAt: Date) {
        self.jobID = jobID
        self.projectID = projectID
        self.state = state
        self.request = request
        self.sourceFacts = sourceFacts
        self.shellJobID = shellJobID
        self.remoteRequestID = remoteRequestID
        self.remoteHandle = remoteHandle
        self.lastProgress = lastProgress
        self.receipt = receipt
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum G09R2EnhancementJournalError: Error, Sendable, Equatable {
    case invalidJobID
    case writeFailed
    case corruptRecord
}

/// Filesystem journal. All reads/writes are confined to the
/// `Enhancements/.jobs` directory beneath the trusted media root.
public struct G09R2EnhancementJournal: Sendable {
    private static let ioLock = NSLock()
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root.standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private var jobsDirectory: URL {
        root.appendingPathComponent("Enhancements/.jobs", isDirectory: true)
    }

    private func fileURL(jobID: String) throws -> URL {
        guard !jobID.isEmpty, jobID.count <= 64,
              jobID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            throw G09R2EnhancementJournalError.invalidJobID
        }
        return jobsDirectory.appendingPathComponent("\(jobID).json")
    }

    private func writeLocked(record: G09R2EnhancementRecord) throws {
        let url = try fileURL(jobID: record.jobID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Foundation atomic replacement preserves the previous journal on failure.
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func write(record: G09R2EnhancementRecord) async throws {
        try Self.ioLock.withLock { try writeLocked(record: record) }
    }

    private func readLocked(jobID: String) throws -> G09R2EnhancementRecord? {
        let url = try fileURL(jobID: jobID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(G09R2EnhancementRecord.self, from: Data(contentsOf: url))
        } catch {
            throw G09R2EnhancementJournalError.corruptRecord
        }
    }

    public func read(jobID: String) async throws -> G09R2EnhancementRecord? {
        try Self.ioLock.withLock { try readLocked(jobID: jobID) }
    }

    /// Serialized read-modify-write keeps progress from erasing an accepted handle.
    public func update(jobID: String,
                       _ mutation: @Sendable (inout G09R2EnhancementRecord) -> Void) async throws {
        try Self.ioLock.withLock {
            guard var record = try readLocked(jobID: jobID) else {
                throw G09R2EnhancementJournalError.corruptRecord
            }
            mutation(&record)
            try writeLocked(record: record)
        }
    }

    /// Active, non-terminal jobs for one project (newest first). Used by the
    /// UI to re-attach to in-flight work after a configuration change.
    public func activeRecords(projectID: UUID) async throws
        -> [G09R2EnhancementRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: jobsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var records: [G09R2EnhancementRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(
                      G09R2EnhancementRecord.self, from: data),
                  record.projectID == projectID,
                  !record.state.isTerminal else { continue }
            records.append(record)
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }
}
