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
// The direct Present editor uses the same store through the App-owned
// `NativeCADEditorAnimationExportRecovery` sink; that record keeps the exact
// UI choices and source identity, never the temporary export URL.
//

import Foundation
import FloeCAD
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

    /// Where an export was going when it was interrupted. The tool path writes
    /// a workspace-relative path; the direct Present export renders into a
    /// temporary file and then asks the user through the system export picker,
    /// so its saved name must never be treated as a permanent path.
    enum AnimationExportDestination: String, Codable, Sendable, Equatable {
        case workspaceRelative = "workspace_relative"
        case exportPicker = "export_picker"
    }

    /// Exact source identity captured before a direct Present frame loop. A
    /// pending autosave may advance revision/hash during the exporter's own
    /// prepare step, so `changeCount` is the live-edit fence used before the
    /// loop; revision/hash remain honest request-time metadata for recovery.
    struct AnimationExportSource: Codable, Sendable, Equatable {
        var revision: Int
        var contentSHA256: String
        var changeCount: Int
        var clipID: UUID?
        var clipDuration: Double
    }

    /// Saved intent for an explicitly requested export. This is enough to
    /// offer the same choices after interruption, but never authorizes a new
    /// write or represents a resumable encoder checkpoint. A new invocation
    /// must resolve the current document, permissions and output again.
    struct AnimationExportRequest: Codable, Sendable, Equatable {
        var relativeOutput: String
        var options: CadAnimationExportOptions
        /// Nil keeps the historical tool/workspace-path record shape. The
        /// direct Present path always writes `.exportPicker`.
        var destination: AnimationExportDestination? = nil
        var source: AnimationExportSource? = nil
        /// Exact UI choices for re-offering the options sheet. The production
        /// `options` above remain the single settings authority.
        var nativeOptions: CADAnimationExportRecoveryOptions? = nil
        /// Display name only; never a permanent output URL.
        var suggestedFilename: String? = nil
    }

    struct Record: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var kind: String
        var ownership: Ownership
        var state: State
        var detail: String?
        var createdAt: Date
        var updatedAt: Date
        /// Optional so old records continue to decode without migration or
        /// inventing settings they never recorded.
        var animationExport: AnimationExportRequest? = nil
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

    /// Do not start a long export if its recovery intent could not be saved.
    /// Save a complete atomic envelope before handing out its live task id;
    /// a failed write restores the prior in-memory index as well.
    func beginAnimationExport(ownership: Ownership,
                               request: AnimationExportRequest) throws -> UUID {
        let previousRecords = records
        let previousOrder = order
        let record = Record(id: UUID(), kind: "animation-export", ownership: ownership,
                            state: .running, detail: nil,
                            createdAt: Date(), updatedAt: Date(),
                            animationExport: request)
        records[record.id] = record
        order.append(record.id)
        trim()
        do {
            try persistRequired()
        } catch {
            records = previousRecords
            order = previousOrder
            throw error
        }
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

    /// Dismissing recovery metadata is not a request to cancel live work. Only
    /// the exact owner's interrupted record may be changed, and the previous
    /// state survives an atomic-save failure.
    func dismissInterruptedAnimationExport(id: UUID, ownership: Ownership) throws {
        guard let original = records[id], original.ownership == ownership,
              original.kind == "animation-export", original.state == .interrupted else {
            throw CADAnimationExportRecoveryError.recordUnavailable
        }
        var dismissed = original
        dismissed.state = .cancelled
        dismissed.detail = "interrupted export dismissed by the user"
        dismissed.updatedAt = Date()
        records[id] = dismissed
        do {
            try persistRequired()
        } catch {
            records[id] = original
            throw error
        }
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
        try? persistRequired()
    }

    private func persistRequired() throws {
        guard let fileURL else {
            throw CocoaError(.fileWriteUnknown)
        }
        let envelope = Envelope(records: order.compactMap { records[$0] })
        let data = try JSONEncoder().encode(envelope)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// App-owned adapter for the direct Present MP4 export (X30). The Floe App
/// installs exactly one of these on each `FloeCADDocument` it owns; the
/// standalone package has no adapter and keeps its historical behavior. Every
/// call is bound to the canonical document path captured at install time, so a
/// stale/session-swapped presentation cannot write a record for another file.
/// The tool export path never calls this adapter; it keeps its own
/// `CadDocumentCenter.exportAnimation` record and never double-records.
final class NativeCADEditorAnimationExportRecovery: CADAnimationExportRecoverySink,
    @unchecked Sendable {
    private let registry: NativeCADTaskRegistry
    private let canonicalDocumentPath: String
    private let finishLock = NSLock()
    private var finishedIDs: Set<UUID> = []

    init(documentURL: URL,
         registry: NativeCADTaskRegistry = .shared) {
        self.registry = registry
        self.canonicalDocumentPath = Self.canonicalPath(documentURL)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isCurrentDocument(_ url: URL) -> Bool {
        Self.canonicalPath(url) == canonicalDocumentPath
    }

    private var ownership: NativeCADTaskRegistry.Ownership {
        NativeCADTaskRegistry.Ownership(
            environmentID: nil,
            ownerKind: "native-editor",
            ownerID: nil,
            documentPath: canonicalDocumentPath)
    }

    private static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = (trimmed.isEmpty ? "CAD animation.mp4" : trimmed)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        name = String(name.prefix(200))
        if !name.lowercased().hasSuffix(".mp4") { name += ".mp4" }
        return name
    }

    func beginAnimationExport(
        _ request: CADAnimationExportRecoveryRequest
    ) async throws -> UUID {
        guard isCurrentDocument(request.documentURL) else {
            throw CADAnimationExportRecoveryError.documentMismatch
        }
        let name = Self.displayName(request.suggestedFilename)
        let options = request.options
        // The exact production settings travel with the UI choices; this
        // mirrors `CADAnimationExportOptions.exportSettings()` without
        // importing the SwiftUI sheet into the registry.
        let toolOptions = CadAnimationExportOptions(
            width: options.width,
            height: options.height,
            frameRate: options.frameRate,
            codec: options.codec,
            bitrate: options.bitrate,
            overwrite: options.overwrite,
            posterEnabled: options.posterEnabled)
        let record = NativeCADTaskRegistry.AnimationExportRequest(
            relativeOutput: name,
            options: toolOptions,
            destination: .exportPicker,
            source: NativeCADTaskRegistry.AnimationExportSource(
                revision: request.sourceRevision,
                contentSHA256: request.sourceContentSHA256,
                changeCount: request.sourceChangeCount,
                clipID: request.clipID,
                clipDuration: request.clipDuration),
            nativeOptions: options,
            suggestedFilename: name)
        return try await registry.beginAnimationExport(
            ownership: ownership, request: record)
    }

    func finishAnimationExport(
        id: UUID,
        outcome: CADAnimationExportRecoveryOutcome,
        detail: String?
    ) async {
        guard !(await registry.status(id: id, ownership: ownership)).isEmpty else { return }
        // The Present session already guards this, but the adapter keeps its
        // own terminal set so a future/repeated caller cannot rewrite a
        // completed or cancelled record with a late status.
        let firstFinish = finishLock.withLock {
            finishedIDs.insert(id).inserted
        }
        guard firstFinish else { return }
        let state: NativeCADTaskRegistry.State
        switch outcome {
        case .completed: state = .completed
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        await registry.finish(id: id, state: state, detail: detail)
    }

    func lastInterruptedAnimationExport(
        documentURL: URL
    ) async -> CADAnimationExportRecoverySummary? {
        guard isCurrentDocument(documentURL) else { return nil }
        let rows = await registry.status(id: nil, ownership: ownership)
        // Only the NEWEST native-editor export may surface. A successful or
        // cancelled retry therefore replaces an older interrupted notice
        // instead of nagging the user forever.
        guard let record = rows.first(where: {
                  $0.kind == "animation-export"
                      && $0.animationExport?.nativeOptions != nil
              }),
              record.state == .interrupted,
              let request = record.animationExport,
              let nativeOptions = request.nativeOptions,
              let source = request.source,
              let clipID = source.clipID else { return nil }
        return CADAnimationExportRecoverySummary(
            id: record.id,
            options: nativeOptions,
            sourceRevision: source.revision,
            sourceContentSHA256: source.contentSHA256,
            sourceChangeCount: source.changeCount,
            clipID: clipID,
            clipDuration: source.clipDuration,
            suggestedFilename: request.suggestedFilename ?? request.relativeOutput,
            updatedAt: record.updatedAt,
            detail: record.detail)
    }

    func dismissInterruptedAnimationExport(id: UUID, documentURL: URL) async throws {
        guard isCurrentDocument(documentURL) else {
            throw CADAnimationExportRecoveryError.documentMismatch
        }
        try await registry.dismissInterruptedAnimationExport(id: id, ownership: ownership)
    }
}
