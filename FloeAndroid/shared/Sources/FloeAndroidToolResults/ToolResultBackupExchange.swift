// SPDX-License-Identifier: MPL-2.0
//
// C07 × C02 — durable tool-result retention backed up and restored through
// the REAL result engine.
//
// The backup carries the post-redaction bytes the tool layer actually
// produced, under the trusted task/run/call identity. Restore never copies a
// raw store record into a live directory: it decodes the archived record,
// verifies its byte count and digest, then calls the store's public
// `capture` API with NEW task/run/call ids and verifies the returned receipt
// and a read-back before reporting success. No tool is executed and no
// previously authorized command is replayed.
import Foundation
import Crypto

// MARK: - Wire record

/// One retained tool result in a backup package. `textBase64` is the exact
/// post-redaction UTF-8 byte string; `sha256` is the digest of those bytes.
public struct ToolResultBackupRecord: Codable, Sendable, Equatable {
    public var taskID: UUID
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var status: String
    public var textBase64: String
    public var byteCount: Int
    public var sha256: String
    public var originalDigest: String?
    public var executionReportedTruncation: Bool
    public var retentionTruncated: Bool
    public var capturedAt: Date

    public init(taskID: UUID, runID: UUID, callID: String,
                toolName: String, status: String, textBase64: String,
                byteCount: Int, sha256: String, originalDigest: String?,
                executionReportedTruncation: Bool,
                retentionTruncated: Bool, capturedAt: Date) {
        self.taskID = taskID
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.textBase64 = textBase64
        self.byteCount = byteCount
        self.sha256 = sha256
        self.originalDigest = originalDigest
        self.executionReportedTruncation = executionReportedTruncation
        self.retentionTruncated = retentionTruncated
        self.capturedAt = capturedAt
    }

    /// Deterministic line encoding used by `data/tool-results.jsonl`.
    public static func encodeLine(_ record: ToolResultBackupRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data: Data
        do { data = try encoder.encode(record) }
        catch { throw ToolResultBackupExchangeError.invalidRecord("encode") }
        guard data.count <= ToolResultBackupExchange.maximumRecordLineBytes else {
            throw ToolResultBackupExchangeError.invalidRecord("tooLarge")
        }
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> ToolResultBackupRecord {
        guard !data.isEmpty,
              data.count <= ToolResultBackupExchange.maximumRecordLineBytes else {
            throw ToolResultBackupExchangeError.invalidRecord("lineSize")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(ToolResultBackupRecord.self, from: data) }
        catch { throw ToolResultBackupExchangeError.invalidRecord("decode") }
    }

    public func validate() throws {
        guard !callID.isEmpty, callID.count <= 200,
              callID.utf8.count <= 800,
              toolName.utf8.count <= 2_048,
              status.utf8.count <= 2_048,
              byteCount >= 0,
              byteCount <= ToolResultBackupExchange.maximumBytesPerRecord,
              sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              originalDigest.map({ $0.count == 64
                  && $0.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) }) ?? true,
              let data = Data(base64Encoded: textBase64, options: []),
              data.count == byteCount,
              ToolResultBackupExchange.digest(data) == sha256 else {
            throw ToolResultBackupExchangeError.invalidRecord("identity")
        }
    }
}

// MARK: - Export

public struct ToolResultBackupExport: Sendable, Equatable {
    public var records: [ToolResultBackupRecord]
    public var excludedLegacyCalls: Int
    public var excludedNonDurable: Int
    public var excludedUnreadable: Int
    public var totalBytes: Int64

    public init(records: [ToolResultBackupRecord],
                excludedLegacyCalls: Int = 0,
                excludedNonDurable: Int = 0,
                excludedUnreadable: Int = 0,
                totalBytes: Int64 = 0) {
        self.records = records
        self.excludedLegacyCalls = excludedLegacyCalls
        self.excludedNonDurable = excludedNonDurable
        self.excludedUnreadable = excludedUnreadable
        self.totalBytes = totalBytes
    }
}

public struct ToolResultRestoredCapture: Sendable, Equatable {
    public var ref: String
    public var runID: UUID
    public var callID: String
    public var byteCount: Int
    public var sha256: String
    public var originalDigest: String?
    public var readbackVerified: Bool

    public init(ref: String, runID: UUID, callID: String, byteCount: Int,
                sha256: String, originalDigest: String?,
                readbackVerified: Bool) {
        self.ref = ref
        self.runID = runID
        self.callID = callID
        self.byteCount = byteCount
        self.sha256 = sha256
        self.originalDigest = originalDigest
        self.readbackVerified = readbackVerified
    }
}

public enum ToolResultBackupExchangeError: Error, Equatable, Sendable {
    case invalidRecord(String)
    case identityMissing(String)
    case captureRejected(String)
    case notDurable
    case retentionChanged
    case readbackMismatch
    case taskFenced
}

public enum ToolResultBackupExchange {
    /// A retained result is at most 8 MiB of text; base64 plus JSON metadata
    /// stays below this line bound.
    public static let maximumBytesPerRecord = 8 * 1_024 * 1_024
    public static let maximumRecordLineBytes = 12 * 1_024 * 1_024
    public static let maximumRecordsPerTask = 64

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Enumerates the durable records of one trusted task. Generated file
    /// names are the full SHA-256 of `runID\0callID`; the store's public
    /// `retainedCapture(ref:)` resolves/validates the record itself.
    /// A missing body for a generated name is reported, never silently
    /// dropped. RAM-only records are counted separately and cannot be
    /// carried by definition.
    public static func export(
        store: ToolResultCaptureStore,
        storeRoot: URL,
        conversationID: UUID
    ) async -> ToolResultBackupExport {
        let directory = storeRoot.appendingPathComponent(
            conversationID.uuidString, isDirectory: true)
        var refs: [String] = []
        var unreadable = 0
        var nonDurable = 0
        if let values = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) {
            for url in values {
                guard url.pathExtension.lowercased() == "json" else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                guard name.count == 64,
                      name.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                    unreadable += 1
                    continue
                }
                refs.append("tr_" + String(name.prefix(24)))
            }
        }
        refs.sort()
        var records: [ToolResultBackupRecord] = []
        var totalBytes: Int64 = 0
        var seen = Set<String>()
        for ref in refs {
            guard !seen.contains(ref) else { continue }
            seen.insert(ref)
            guard let capture = await store.retainedCapture(
                conversationID: conversationID, ref: ref) else {
                unreadable += 1
                continue
            }
            guard capture.durability == .durable else {
                // A record that only exists in RAM cannot be carried. Count
                // it as non-durable rather than claiming it is backed up.
                nonDurable += 1
                continue
            }
            let data = Data(capture.text.utf8)
            let sha = digest(data)
            guard sha == capture.sha256,
                  data.count <= maximumBytesPerRecord else {
                unreadable += 1
                continue
            }
            do {
                let record = ToolResultBackupRecord(
                    taskID: conversationID,
                    runID: capture.runID,
                    callID: capture.callID,
                    toolName: capture.toolName,
                    status: capture.status,
                    textBase64: data.base64EncodedString(),
                    byteCount: data.count,
                    sha256: sha,
                    originalDigest: capture.originalDigest,
                    executionReportedTruncation:
                        capture.executionReportedTruncation,
                    retentionTruncated: capture.retentionTruncated,
                    capturedAt: capture.capturedAt)
                try record.validate()
                records.append(record)
                totalBytes += Int64(data.count)
            } catch {
                unreadable += 1
            }
        }
        records.sort {
            if $0.runID != $1.runID { return $0.runID.uuidString < $1.runID.uuidString }
            return $0.callID < $1.callID
        }
        // RAM-only entries beyond the durable index are reported too. The
        // bounded task index is enough to count them; a durable task never
        // carries them into a package.
        let index = await store.taskIndex(
            conversationID: conversationID, limit: 50)
        if case .index(let rows, _) = index {
            for row in rows
            where row.durability != .durable && !seen.contains(row.ref) {
                nonDurable += 1
            }
        }
        return ToolResultBackupExport(
            records: records,
            excludedLegacyCalls: 0,
            excludedNonDurable: nonDurable,
            excludedUnreadable: unreadable,
            totalBytes: totalBytes)
    }

    /// Restores archived records through `ToolResultCaptureStore.capture`.
    /// Every new identity must map exactly; unmapped or mismatched bytes fail
    /// the whole restore so the caller can roll back.
    public static func restore(
        records: [ToolResultBackupRecord],
        store: ToolResultCaptureStore,
        destinationTaskID: UUID,
        runMap: [UUID: UUID],
        callMap: [String: String]
    ) async throws -> [ToolResultRestoredCapture] {
        var receipts: [ToolResultRestoredCapture] = []
        receipts.reserveCapacity(records.count)
        for record in records {
            try record.validate()
            guard let newRun = runMap[record.runID],
                  let newCall = callMap[record.callID] else {
                throw ToolResultBackupExchangeError.identityMissing(
                    record.callID)
            }
            guard let data = Data(base64Encoded: record.textBase64, options: []),
                  let text = String(data: data, encoding: .utf8) else {
                throw ToolResultBackupExchangeError.invalidRecord("text")
            }
            let expectedRef = ToolResultCaptureStore.reference(
                runID: newRun, callID: newCall)
            let receipt = await store.capture(
                conversationID: destinationTaskID,
                runID: newRun,
                callID: newCall,
                toolName: record.toolName,
                status: record.status,
                text: text,
                temporary: false,
                executionReportedTruncation:
                    record.executionReportedTruncation,
                originalDigest: record.originalDigest)
            guard receipt.outcome == .retained else {
                switch receipt.outcome {
                case .taskFenced:
                    throw ToolResultBackupExchangeError.taskFenced
                default:
                    throw ToolResultBackupExchangeError.captureRejected(
                        receipt.outcome.rawValue)
                }
            }
            guard receipt.durability == .durable else {
                throw ToolResultBackupExchangeError.notDurable
            }
            guard receipt.retentionTruncated == false,
                  receipt.retainedBytes == record.byteCount,
                  receipt.totalBytes == record.byteCount,
                  receipt.sha256 == record.sha256,
                  receipt.ref == expectedRef else {
                throw ToolResultBackupExchangeError.retentionChanged
            }
            receipts.append(ToolResultRestoredCapture(
                ref: receipt.ref,
                runID: newRun,
                callID: newCall,
                byteCount: record.byteCount,
                sha256: record.sha256,
                originalDigest: record.originalDigest,
                readbackVerified: false))
        }
        return receipts
    }

    /// Reads the exact bytes back through the store and compares the full
    /// digest. A mismatch fails; a RAM-only answer is acceptable only because
    /// `restore` already proved the durable write, so the bytes are also
    /// persisted. This never executes a tool.
    public static func verifyReadback(
        receipts: [ToolResultRestoredCapture],
        store: ToolResultCaptureStore,
        conversationID: UUID
    ) async throws -> [ToolResultRestoredCapture] {
        var verified: [ToolResultRestoredCapture] = []
        verified.reserveCapacity(receipts.count)
        for var receipt in receipts {
            guard let capture = await store.retainedCapture(
                conversationID: conversationID, ref: receipt.ref),
                  capture.runID == receipt.runID,
                  capture.callID == receipt.callID,
                  capture.durability == .durable else {
                throw ToolResultBackupExchangeError.readbackMismatch
            }
            let data = Data(capture.text.utf8)
            guard data.count == receipt.byteCount,
                  digest(data) == receipt.sha256 else {
                throw ToolResultBackupExchangeError.readbackMismatch
            }
            receipt.readbackVerified = true
            verified.append(receipt)
        }
        return verified
    }

    /// Used by the restore journal to remove exactly the records this restore
    /// created. The caller passes only NEW task ids it owns; the store fences
    /// the task and reports whether the durable directory is gone.
    public static func rollback(
        conversationIDs: [UUID],
        store: ToolResultCaptureStore
    ) async -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for conversationID in conversationIDs {
            let purge = await store.purge(conversationID: conversationID)
            result[conversationID] = purge.succeeded
        }
        return result
    }
}
