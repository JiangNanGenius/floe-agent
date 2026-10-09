// SPDX-License-Identifier: MPL-2.0
// FloeApp — durable registry for long-running native CAD jobs.
//
// `cad.document status` / `cancel` (and the native `.floecad` task surface)
// need an honest, recoverable record of long operations: export, import,
// assembly interference, script applies and mesh booleans. Records persist as
// JSON under Application Support so a relaunch can report what happened; a
// record still marked `running` at load is downgraded to `interrupted`
// (recovery never claims a job completed). Cancellation is a request: the
// owning Task is cancelled, but the final state records whether the operation
// actually observed it or finished first.
//

import Foundation
import FloeWorkbench

actor NativeCADTaskRegistry {
    static let shared = NativeCADTaskRegistry()

    enum State: String, Codable, Sendable {
        case running, completed, failed, cancelled, interrupted
    }

    /// Full job ownership: environment + owner identity + the exact canonical
    /// document. `status`/`cancel` require an exact match, so one task cannot
    /// inspect or cancel another task's or another document's jobs.
    struct Ownership: Codable, Sendable, Equatable {
        var environmentID: String?
        var ownerKind: String?
        var ownerID: UUID?
        var documentPath: String

        init(environmentID: String?, ownerKind: String?, ownerID: UUID?, documentPath: String) {
            self.environmentID = environmentID
            self.ownerKind = ownerKind
            self.ownerID = ownerID
            self.documentPath = documentPath
        }

        init(access: CadDocumentAccess, documentPath: String) {
            self.environmentID = access.environmentID
            self.ownerKind = access.ownerKind
            self.ownerID = access.ownerID
            self.documentPath = documentPath
        }
    }

    enum CancelOutcome: Sendable, Equatable {
        case cancelled(Record)
        case notFound
        case unauthorized
        case notRunning(Record)
    }

    struct Record: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var kind: String
        var ownership: Ownership
        var state: State
        var detail: String?
        var createdAt: Date
        var updatedAt: Date
    }

    private var records: [UUID: Record] = [:]
    private var order: [UUID] = []
    private var cancelRequests: Set<UUID> = []
    private let fileURL: URL?
    private let maximumRecords = 200

    init(fileURL: URL? = NativeCADTaskRegistry.defaultFileURL()) {
        self.fileURL = fileURL
        // Recovery runs inline: an actor initializer cannot call isolated
        // methods, and a job found "running" after a relaunch is downgraded to
        // "interrupted" — recovery never claims it completed.
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        var recoveredInterrupted = false
        for var record in envelope.records {
            if record.state == .running {
                record.state = .interrupted
                record.detail = "the app ended while this job was running; it was not completed"
                record.updatedAt = Date()
                recoveredInterrupted = true
            }
            records[record.id] = record
            order.append(record.id)
        }
        if recoveredInterrupted {
            var recovered: [Record] = []
            for id in order {
                if let record = records[id] { recovered.append(record) }
            }
            if let encoded = try? JSONEncoder().encode(Envelope(records: recovered)) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? encoded.write(to: fileURL, options: [.atomic])
            }
        }
    }

    static func defaultFileURL() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true) else { return nil }
        let directory = support.appendingPathComponent("FloeAgent/CAD", isDirectory: true)
        return directory.appendingPathComponent("native-tasks.json")
    }

    // MARK: Lifecycle

    @discardableResult
    func begin(kind: String, ownership: Ownership) -> UUID {
        let record = Record(id: UUID(), kind: kind, ownership: ownership,
                            state: .running, detail: nil,
                            createdAt: Date(), updatedAt: Date())
        records[record.id] = record
        order.append(record.id)
        trim()
        persist()
        return record.id
    }

    /// Completes a record unless a cancel request already finalised it; a
    /// cancel that the operation observed wins, and completion AFTER a cancel
    /// request is recorded as cancelled-with-detail rather than silently
    /// flipping the user's request into a success.
    func finish(id: UUID, state: State, detail: String?) {
        guard var record = records[id] else { return }
        if record.state == .cancelled {
            record.detail = "cancel requested; operation ended: \(detail ?? state.rawValue)"
        } else {
            record.state = state
            record.detail = detail
        }
        record.updatedAt = Date()
        records[id] = record
        cancelRequests.remove(id)
        persist()
    }

    /// Cancels only when the caller presents the EXACT ownership recorded for
    /// the job. A foreign owner/document gets `.unauthorized` and no state
    /// change (and cannot even learn whether the id exists: both unknown and
    /// foreign ids answer `notFound`/`unauthorized` without record data).
    func requestCancel(id: UUID, ownership: Ownership) -> CancelOutcome {
        guard let record = records[id] else { return .notFound }
        guard record.ownership == ownership else { return .unauthorized }
        guard record.state == .running else { return .notRunning(record) }
        var updated = record
        updated.state = .cancelled
        updated.detail = "cancellation requested"
        updated.updatedAt = Date()
        records[id] = updated
        cancelRequests.insert(id)
        persist()
        return .cancelled(updated)
    }

    func isCancellationRequested(id: UUID) -> Bool {
        cancelRequests.contains(id) || records[id]?.state == .cancelled
    }

    /// Status is scoped to one exact ownership: without an id it lists only
    /// that ownership's records; with an id a mismatch returns nothing rather
    /// than leaking another owner's/document's job.
    func status(id: UUID?, ownership: Ownership) -> [Record] {
        if let id {
            guard let record = records[id], record.ownership == ownership else { return [] }
            return [record]
        }
        return order.reversed().compactMap { recordID -> Record? in
            guard let record = records[recordID], record.ownership == ownership else { return nil }
            return record
        }
    }

    // MARK: Persistence

    private struct Envelope: Codable {
        var records: [Record]
    }

    private func trim() {
        while order.count > maximumRecords, let first = order.first {
            records[first] = nil
            order.removeFirst()
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let envelope = Envelope(records: order.compactMap { records[$0] })
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
