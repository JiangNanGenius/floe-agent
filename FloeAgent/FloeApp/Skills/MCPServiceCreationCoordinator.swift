#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloePersistence
import FloeSecurity

struct MCPServiceCreationDraft: Codable, Hashable, Sendable {
    var name = ""
    var details = ""
    var workspaceID: UUID?
    var environmentID: String?
    var port = "8080"
}

struct MCPServiceCreationRequest: Codable, Equatable, Sendable {
    var name: String
    var details: String
    var workspaceID: UUID
    var environmentID: String
    var port: Int
}

struct MCPServiceCreationBinding: Codable, Equatable, Sendable {
    var root: URL
    var projectRelativePath: String
    var providerID: UUID
    var modelID: UUID
    var modelName: String
}

struct MCPServiceCreationServiceEvent: Sendable {
    enum Kind: Sendable { case ended, unavailable }
    var operationID: UUID
    var jobID: UUID
    var kind: Kind
}

struct MCPServiceCreationReceipt: Codable, Equatable, Sendable {
    var conversationID: UUID
    var runID: UUID
    var serviceJobID: UUID
    var environmentID: String
    var endpoint: URL
    var smokeDigest: String
    var verifiedAt: Date
}

struct MCPServiceCreationRecord: Codable, Identifiable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing, generating, building, starting, verifying, ready, saving, added
        case stopping, stopped, failed, interrupted
        var isProcessing: Bool {
            switch self {
            case .preparing, .generating, .building, .starting, .verifying, .saving, .stopping: true
            default: false
            }
        }
        var titleKey: String { "skills.mcp.creation.phase." + rawValue }
    }
    var id: UUID
    var conversationID: UUID
    var runID: UUID
    var connectionID: UUID
    var request: MCPServiceCreationRequest
    var binding: MCPServiceCreationBinding?
    var buildJobID: UUID?
    var serviceJobID: UUID?
    var receipt: MCPServiceCreationReceipt?
    var savedConnectionID: UUID?
    var phase: Phase
    var error: String?
    var updatedAt: Date

    init(request: MCPServiceCreationRequest) {
        id = UUID(); conversationID = UUID(); runID = UUID(); connectionID = UUID()
        self.request = request; phase = .preparing; updatedAt = Date()
    }

    /// Public-facing state is never sufficient evidence to save a connection.
    var canSave: Bool {
        guard phase == .ready, let receipt, let serviceJobID else { return false }
        return receipt.conversationID == conversationID && receipt.runID == runID
            && receipt.serviceJobID == serviceJobID && receipt.environmentID == request.environmentID
    }
}

@MainActor
protocol MCPServiceCreationBackend: AnyObject {
    func resolve(_ record: MCPServiceCreationRecord) async throws -> MCPServiceCreationBinding
    func prepare(_ record: MCPServiceCreationRecord, template: MCPServiceTemplate.VerifiedPackage) async throws
    /// Uses a persisted run if present; never repeats a possibly accepted request.
    func generate(_ record: MCPServiceCreationRecord) async throws
    func submitBuild(_ record: MCPServiceCreationRecord) async throws -> UUID
    func waitForBuild(_ record: MCPServiceCreationRecord) async throws
    func submitService(_ record: MCPServiceCreationRecord) async throws -> UUID
    func waitForEndpoint(_ record: MCPServiceCreationRecord) async throws -> URL
    func verify(_ record: MCPServiceCreationRecord, endpoint: URL) async throws -> MCPServiceCreationReceipt
    func saveConnection(_ record: MCPServiceCreationRecord) async throws -> UUID
    func savedConnectionID(_ record: MCPServiceCreationRecord) -> UUID?
    /// Does not return until owned work is actually settled, or throws honestly.
    func stop(_ record: MCPServiceCreationRecord) async throws
    func release(_ record: MCPServiceCreationRecord)
}

/// App-owned orchestration over existing runs/jobs. Sheets are observers;
/// this object must be retained by AppEnvironment, not constructed by a view.
@MainActor
final class MCPServiceCreationCoordinator: ObservableObject {
    @Published private(set) var records: [MCPServiceCreationRecord] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var actionError: String?
    @Published var draft = MCPServiceCreationDraft()
    @Published private(set) var isLoaded = false
    @Published private(set) var isStopping = false
    private let backend: any MCPServiceCreationBackend
    private let settings: any SettingsStore
    private let templateLoader: () throws -> MCPServiceTemplate.VerifiedPackage
    private var operation: Task<Void, Never>?
    private var saving: Task<UUID, Error>?
    private var epoch: UInt64 = 0
    private var loadingTask: Task<Void, Never>?
    private var launching = false
    private var pendingWrite: Task<Void, Error>?
    private static let prefix = "mcp.creation.operation."
    private static let draftKey = "mcp.creation.draft.v1"

    init(backend: any MCPServiceCreationBackend, settings: any SettingsStore,
         templateLoader: @escaping () throws -> MCPServiceTemplate.VerifiedPackage = { try MCPServiceTemplate.load() }) {
        self.backend = backend; self.settings = settings; self.templateLoader = templateLoader
    }
    var selected: MCPServiceCreationRecord? { records.first { $0.id == selectedID } }
    var isWorking: Bool { isStopping || selected?.phase.isProcessing == true }

    func load() async {
        guard !isLoaded else { return }
        if let loadingTask { await loadingTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.loadingTask = nil }
            do {
                let saved = try await self.settings.value(forKey: Self.draftKey, as: MCPServiceCreationDraft.self)
                let rows = try await self.settings.allValues()
                var restored = try rows.filter { $0.key.hasPrefix(Self.prefix) }.map { _, value in
                    try JSONDecoder().decode(MCPServiceCreationRecord.self, from: Data(value.utf8))
                }.sorted { $0.updatedAt > $1.updatedAt }
                // An install/manager commit can win process death before
                // this feature's metadata write. Read that real receipt first.
                for index in restored.indices {
                    if let id = self.backend.savedConnectionID(restored[index]) {
                        restored[index].phase = .added
                        restored[index].savedConnectionID = id
                        restored[index].error = nil
                        try await self.persist(restored[index])
                    } else if restored[index].phase.isProcessing || restored[index].phase == .ready {
                        // Process death does not prove execution continued.
                        restored[index].phase = .interrupted
                        restored[index].error = FloeL10n.l("skills.mcp.creation.interrupted")
                        try await self.persist(restored[index])
                    }
                }
                if let saved { self.draft = saved }
                self.records = restored; self.selectedID = restored.first?.id
                self.isLoaded = true
            } catch { self.actionError = error.localizedDescription }
        }
        loadingTask = task
        await task.value
    }

    func saveDraft() async {
        guard isLoaded else { return }
        var snapshot = draft
        snapshot.name = SecretIngressScanner.scan(snapshot.name).sanitizedText
        snapshot.details = SecretIngressScanner.scan(snapshot.details).sanitizedText
        let previous = pendingWrite, settings = self.settings
        let write = Task {
            _ = await previous?.result
            try await settings.setValue(snapshot, forKey: Self.draftKey)
        }
        pendingWrite = write
        do { try await write.value }
        catch { actionError = error.localizedDescription }
    }

    func startDraft() async {
        await load()
        guard isLoaded else { return }
        guard let workspaceID = draft.workspaceID, let environmentID = draft.environmentID,
              let port = Int(draft.port) else {
            actionError = FloeL10n.l("skills.mcp.creation.complete_fields"); return
        }
        await saveDraft()
        await start(.init(name: draft.name, details: draft.details,
                          workspaceID: workspaceID, environmentID: environmentID, port: port))
    }

    func select(_ id: UUID) {
        guard operation == nil, saving == nil, !launching, !isStopping else { return }
        if records.contains(where: { $0.id == id }) { selectedID = id }
    }

    func start(_ request: MCPServiceCreationRequest) async {
        guard operation == nil, saving == nil, !launching, !isStopping else { return }
        launching = true
        defer { launching = false }
        await load()
        guard isLoaded else { return }
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.environmentID.isEmpty, (1024...65535).contains(request.port) else {
            actionError = FloeL10n.l("skills.mcp.creation.complete_fields"); return
        }
        var record = MCPServiceCreationRecord(request: request)
        // Free-form source remains in the ordinary conversation after launch;
        // this feature's non-secret recovery metadata only stores redacted input.
        record.request.details = SecretIngressScanner.scan(request.details).sanitizedText
        record.request.name = SecretIngressScanner.scan(request.name).sanitizedText
        records.insert(record, at: 0); selectedID = record.id; actionError = nil
        do { try await persist(record) }
        catch { records.removeAll { $0.id == record.id }; selectedID = nil; actionError = error.localizedDescription; return }
        guard selected?.id == record.id, selected?.phase == .preparing else { return }
        begin(record)
    }

    func resumeSelected() {
        guard operation == nil, saving == nil, !isStopping, let record = selected,
              [.failed, .interrupted].contains(record.phase) else { return }
        // Backend methods attach to known IDs/idempotency keys, validate their
        // current receipts and never reconstruct a different owner/run.
        begin(record)
    }

    private func begin(_ initial: MCPServiceCreationRecord) {
        epoch &+= 1
        let generation = epoch
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == generation { self.operation = nil } }
            var record = initial
            do {
                let template = try self.templateLoader()
                record = try await self.publish(record, phase: .preparing, generation: generation)
                if record.binding == nil {
                    record.binding = try await self.backend.resolve(record)
                    record = try await self.publish(record, phase: .preparing, generation: generation)
                }
                try await self.backend.prepare(record, template: template)
                record = try await self.publish(record, phase: .generating, generation: generation)
                try await self.backend.generate(record)
                record = try await self.publish(record, phase: .building, generation: generation)
                record.buildJobID = try await self.backend.submitBuild(record)
                record = try await self.publish(record, phase: .building, generation: generation)
                try await self.backend.waitForBuild(record)
                record = try await self.publish(record, phase: .starting, generation: generation)
                record.serviceJobID = try await self.backend.submitService(record)
                record = try await self.publish(record, phase: .starting, generation: generation)
                let endpoint = try await self.backend.waitForEndpoint(record)
                record = try await self.publish(record, phase: .verifying, generation: generation)
                let receipt = try await self.backend.verify(record, endpoint: endpoint)
                guard receipt.conversationID == record.conversationID, receipt.runID == record.runID,
                      receipt.serviceJobID == record.serviceJobID,
                      receipt.environmentID == record.request.environmentID,
                      receipt.endpoint == endpoint, receipt.smokeDigest.count == 64,
                      receipt.smokeDigest.allSatisfy(\.isHexDigit) else {
                    throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.owner_changed"))
                }
                record.receipt = receipt
                _ = try await self.publish(record, phase: .ready, generation: generation)
            } catch is CancellationError {
                // Explicit cancel owns stop/settlement and the final state.
            } catch {
                guard self.epoch == generation, self.selected?.id == record.id,
                      self.selected?.phase != .stopping else { return }
                record.error = error.localizedDescription
                do { _ = try await self.publish(record, phase: .failed, generation: generation) }
                catch { self.actionError = error.localizedDescription }
            }
        }
    }

    private func publish(_ record: MCPServiceCreationRecord, phase: MCPServiceCreationRecord.Phase,
                         generation: UInt64) async throws -> MCPServiceCreationRecord {
        try Task.checkCancellation()
        guard epoch == generation, records.contains(where: { $0.id == record.id }),
              records.first(where: { $0.id == record.id })?.phase != .stopping else { throw CancellationError() }
        var next = record; next.phase = phase; next.updatedAt = Date()
        if phase != .failed { next.error = nil }
        try await persist(next)
        // Persist can yield. A stop/new operation must fence the late callback.
        guard epoch == generation,
              records.first(where: { $0.id == record.id })?.phase != .stopping else { throw CancellationError() }
        replace(next)
        return next
    }

    func saveSelected() async {
        guard operation == nil, saving == nil, !launching, !isStopping, let record = selected, record.canSave else { return }
        var pending = record; pending.phase = .saving; pending.updatedAt = Date()
        replace(pending)
        do { try await persist(pending) }
        catch { replace(record); actionError = error.localizedDescription; return }
        guard selected?.id == record.id, selected?.phase == .saving else { return }
        let task = Task { try await backend.saveConnection(record) }
        saving = task
        do {
            let id = try await task.value
            guard id == record.connectionID else {
                throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.owner_changed"))
            }
            var committed = record; committed.savedConnectionID = id; committed.phase = .added
            committed.updatedAt = Date(); committed.error = nil
            // A committed configuration wins cancellation or a feature-
            // metadata write failure; never relabel it as an uncommitted save.
            replace(committed)
            do { try await persist(committed) }
            catch { actionError = error.localizedDescription }
        } catch {
            if selected?.phase != .stopping {
                var failed = record; failed.error = error.localizedDescription; failed.phase = .failed
                do { try await persist(failed); replace(failed) }
                catch { actionError = error.localizedDescription }
            }
        }
        saving = nil
    }

    func cancelSelected() async {
        guard !isStopping, var record = selected, record.savedConnectionID == nil,
              record.phase != .stopped, record.phase != .added else { return }
        // Persistent stopping means ownership is unresolved, not that a stop
        // request is still running. A failed request must remain retryable.
        isStopping = true
        defer { isStopping = false }
        actionError = nil
        epoch &+= 1
        let running = operation
        record.phase = .stopping; record.updatedAt = Date(); replace(record)
        do { try await persist(record) }
        catch { actionError = error.localizedDescription }
        running?.cancel()
        if let saving {
            saving.cancel()
            let result = await saving.result
            if case .success(let id) = result {
                record.savedConnectionID = id; record.phase = .added; record.updatedAt = Date()
                replace(record)
                do { try await persist(record) }
                catch { actionError = error.localizedDescription }
                self.saving = nil; return
            }
        }
        do {
            try await backend.stop(record)
            await running?.value
            record.phase = .stopped; record.error = nil; record.updatedAt = Date()
            try await persist(record); replace(record)
            backend.release(record)
        } catch { actionError = error.localizedDescription }
        operation = nil
    }

    func receive(_ event: MCPServiceCreationServiceEvent) async {
        guard let index = records.firstIndex(where: { $0.id == event.operationID }),
              records[index].serviceJobID == event.jobID,
              [.starting, .verifying, .ready].contains(records[index].phase) else { return }
        var record = records[index]
        if selectedID == record.id {
            epoch &+= 1
            operation?.cancel(); operation = nil
        }
        record.phase = event.kind == .ended ? .failed : .interrupted
        record.error = FloeL10n.l(event.kind == .ended
            ? "skills.mcp.creation.service_stopped" : "skills.mcp.creation.status_unavailable")
        record.updatedAt = Date(); replace(record)
        do { try await persist(record) }
        catch { actionError = error.localizedDescription }
    }

    private func replace(_ record: MCPServiceCreationRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
    }
    private func persist(_ record: MCPServiceCreationRecord) async throws {
        // A view can cancel while an earlier settings write is suspended.
        // Serialize actual writes in the same order as actor state changes,
        // so an old phase cannot land after the stop/commit receipt.
        let previous = pendingWrite
        let settings = self.settings
        let write = Task {
            _ = await previous?.result
            try await settings.setValue(record, forKey: Self.prefix + record.id.uuidString)
        }
        pendingWrite = write
        try await write.value
    }
}
#endif
