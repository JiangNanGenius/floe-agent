// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — durable Canvas asset-reference journal.
//
// Reference changes are journaled under `FloeAgent/CanvasRecovery` and are
// applied through the EXISTING CreativeAssetStore op receipts. The journal is
// the on-disk intent; the SQLite receipt is the authority for "applied
// exactly once". Positive deltas are applied before negative deltas, and a
// replayed journal entry is a recorded no-op, never a double increment or a
// premature decrement.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct G09AssetJournalOperation: Codable, Sendable, Equatable {
    public var opID: String
    public var assetID: UUID
    public var delta: Int
    public var appliedAt: Date?

    public init(opID: String, assetID: UUID, delta: Int, appliedAt: Date? = nil) {
        self.opID = opID
        self.assetID = assetID
        self.delta = delta
        self.appliedAt = appliedAt
    }
}

public struct G09AssetJournalDTO: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var canvasID: UUID
    public var operations: [G09AssetJournalOperation]
    public var updatedAt: Date

    public init(canvasID: UUID, operations: [G09AssetJournalOperation] = [],
                updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.canvasID = canvasID
        self.operations = operations
        self.updatedAt = updatedAt
    }
}

public struct G09RecoveryCounts: Sendable, Equatable {
    public var applied: Int
    public var pending: Int
    public var warnings: [String]
}

public actor G09CreativeRecovery {
    private let root: RuntimeStorageRoot
    private let fileManager = FileManager.default

    public init(root: RuntimeStorageRoot) {
        self.root = root
    }

    public nonisolated var directoryPath: String {
        root.artifactStoreURL.appendingPathComponent("CanvasRecovery", isDirectory: true).path
    }

    public nonisolated func journalURL(canvasID: UUID) -> URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("\(canvasID.uuidString).json")
    }

    public func state(canvasID: UUID) -> G09RecoveryCounts {
        do {
            let journal = try loadJournal(canvasID: canvasID)
            let applied = journal.operations.filter { $0.appliedAt != nil }.count
            return G09RecoveryCounts(
                applied: applied, pending: journal.operations.count - applied,
                warnings: journal.operations.contains(where: { $0.appliedAt == nil })
                    ? ["pendingReferenceOperations"] : [])
        } catch G09CreativeError.corruptProject {
            return G09RecoveryCounts(applied: 0, pending: 0,
                                     warnings: ["corruptReferenceJournal"])
        } catch {
            return G09RecoveryCounts(applied: 0, pending: 0, warnings: [])
        }
    }

    /// Applies every pending operation exactly once. A journal that cannot be
    /// decoded is preserved byte-for-byte and surfaced as a recoverable
    /// warning: no reference count is guessed from unreadable intent.
    public func recover(canvasID: UUID, host: G09CreativeAssetHost,
                        now: Date = Date()) async throws -> G09RecoveryCounts {
        var journal = try loadJournal(canvasID: canvasID)
        return try await applyPending(&journal, host: host, now: now)
    }

    public func apply(canvasID: UUID, operations: [G09AssetReferenceOperationDTO],
                      host: G09CreativeAssetHost, now: Date = Date()) async throws -> G09RecoveryCounts {
        guard operations.count <= G09CreativeLimits.recoveryOperations else {
            throw G09CreativeError.invalidPayload("tooManyReferenceOperations")
        }
        var journal = try loadJournal(canvasID: canvasID)
        var indexByID: [String: Int] = [:]
        for (index, operation) in journal.operations.enumerated() {
            indexByID[operation.opID] = index
        }
        for operation in operations {
            guard G09CreativeWire.safeOperationID(operation.opID),
                  operation.delta != 0,
                  abs(operation.delta) <= 1_000 else {
                throw G09CreativeError.invalidPayload("invalidReferenceOperation")
            }
            if let index = indexByID[operation.opID] {
                let existing = journal.operations[index]
                guard existing.assetID == operation.assetID,
                      existing.delta == operation.delta else {
                    throw G09CreativeError.revisionConflict
                }
                continue
            }
            journal.operations.append(G09AssetJournalOperation(
                opID: operation.opID, assetID: operation.assetID,
                delta: operation.delta))
            indexByID[operation.opID] = journal.operations.count - 1
        }
        guard journal.operations.count <= G09CreativeLimits.recoveryOperations else {
            throw G09CreativeError.invalidPayload("referenceJournalFull")
        }
        return try await applyPending(&journal, host: host, now: now)
    }

    private func applyPending(_ journal: inout G09AssetJournalDTO,
                              host: G09CreativeAssetHost,
                              now: Date) async throws -> G09RecoveryCounts {
        // Increment before decrement: a crash can only over-retain bytes, and
        // deferred physical reclamation means over-retention is safe.
        let ordered = journal.operations.indices.sorted { lhs, rhs in
            let left = journal.operations[lhs]
            let right = journal.operations[rhs]
            if (left.appliedAt != nil) != (right.appliedAt != nil) {
                return left.appliedAt == nil
            }
            if (left.delta > 0) != (right.delta > 0) { return left.delta > 0 }
            return lhs < rhs
        }
        for index in ordered {
            guard journal.operations[index].appliedAt == nil else { continue }
            let operation = journal.operations[index]
            do {
                try await host.applyReferenceOp(
                    opID: operation.opID, assetID: operation.assetID,
                    delta: operation.delta)
            } catch {
                try? persist(journal)
                throw G09CreativeError.map(error)
            }
            journal.operations[index].appliedAt = now
            journal.updatedAt = now
            // Persist after each real DB receipt. If the process dies before
            // this write, the DB receipt makes the replay a no-op.
            try persist(journal)
        }
        let applied = journal.operations.filter { $0.appliedAt != nil }.count
        return G09RecoveryCounts(applied: applied, pending: journal.operations.count - applied,
                                 warnings: [])
    }

    public func loadJournal(canvasID: UUID) throws -> G09AssetJournalDTO {
        let url = journalURL(canvasID: canvasID)
        guard fileManager.fileExists(atPath: url.path) else {
            return G09AssetJournalDTO(canvasID: canvasID)
        }
        guard let data = try? Data(contentsOf: url),
              let journal = try? G09CreativeWire.decoder().decode(
                G09AssetJournalDTO.self, from: data) else {
            throw G09CreativeError.corruptProject
        }
        guard journal.schemaVersion == G09AssetJournalDTO.currentSchemaVersion,
              journal.canvasID == canvasID else {
            throw G09CreativeError.corruptProject
        }
        return journal
    }

    private func persist(_ journal: G09AssetJournalDTO) throws {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try G09CreativeWire.encoder().encode(journal)
            let url = journalURL(canvasID: journal.canvasID)
            let temporary = directory.appendingPathComponent(
                ".floe-journal-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: [])
            try fsyncFile(temporary)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.writeFailed
        }
    }

    private func fsyncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw G09CreativeError.writeFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw G09CreativeError.writeFailed }
    }
}
