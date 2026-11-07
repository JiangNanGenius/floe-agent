// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeCore
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyUI
import FloeTools
import FloePersistence

/// A console cancellation closure may be called from an actor. It observes
/// only this presentation's fence, never a global current selection.
final class BiologyPresentationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func close() { lock.lock(); open = false; lock.unlock() }
}

struct BiologyNotesPayload: Sendable {
    let projectID: UUID
    let assetID: UUID?
    let runID: UUID?
    let projectRevision: UInt64
    let assetRevision: UInt64?
    let text: String
    let sourceReference: String
}
typealias BiologyNotesInsertion = @MainActor @Sendable (BiologyNotesPayload) async throws -> Void

/// UI state belongs to one original and one presentation; service/jobs belong
/// to the App. Returning from Notes or the assistant never constructs another
/// BiologyService or relabels its live calculation as interrupted.
@MainActor @Observable final class BiologyProjectSession {
    private static var sessions: [UUID: BiologyProjectSession] = [:]
    let projectID: UUID
    let host: BiologyHostServices
    private(set) var record: PersonalContentRecord
    private(set) var directory: URL
    private(set) var project: BiologyProject
    var diagnostic: String?
    private(set) var scientificEnvironmentID: String?
    @ObservationIgnored private var lease: PersonalLibraryUsageLease?
    @ObservationIgnored private var fence = BiologyPresentationFence()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var closing = false
    private struct NativeTask {
        let cancel: @MainActor @Sendable () -> Void
        let join: @MainActor @Sendable () async -> Void
    }
    @ObservationIgnored private var nativeTasks: [UUID: NativeTask] = [:]
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var aiRuns: [UUID: UUID] = [:]

    private init(record: PersonalContentRecord, directory: URL, project: BiologyProject, host: BiologyHostServices) {
        self.record = record; self.directory = directory; self.project = project
        projectID = record.id; self.host = host
    }
    static func open(id: UUID, directory: URL, host: BiologyHostServices) async throws -> BiologyProjectSession {
        let location = try await host.access.location(id)
        guard location.url.standardizedFileURL == directory.standardizedFileURL else { throw BiologyHostError.changed }
        let project = try await host.store.load(id)
        guard project.id == location.record.id else { throw BiologyHostError.changed }
        let session: BiologyProjectSession
        if let existing = sessions[id] {
            guard existing.host === host, !existing.active, !existing.closing else { throw PersonalFileActionError.closeFirst }
            session = existing
        } else {
            session = BiologyProjectSession(record: location.record, directory: directory, project: project, host: host)
            sessions[id] = session
        }
        session.record = location.record; session.directory = location.url; session.project = project
        session.lease = try PersonalLibraryFileActions.acquireUse(id: id, directory: location.url)
        session.fence = BiologyPresentationFence(); session.active = true
        session.observe()
        return session
    }
    private func observe() {
        observer?.cancel()
        let token = fence
        observer = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let changes = try await host.service.changes(projectID)
                for await _ in changes {
                    guard !Task.isCancelled, token.isOpen, self.fence === token else { return }
                    let current = try await host.service.project(projectID)
                    try await host.synchronizeMetadata([projectID])
                    let mounted = try await host.access.location(projectID)
                    guard token.isOpen, self.fence === token else { return }
                    project = current; record = mounted.record
                    NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: projectID)
                }
            } catch is CancellationError { }
            catch { if token.isOpen { diagnostic = error.localizedDescription } }
        }
    }
    private func requireCurrent(_ token: BiologyPresentationFence) async throws {
        try Task.checkCancellation()
        guard active, token.isOpen, fence === token else { throw CancellationError() }
        let current = try await host.access.location(projectID)
        guard current.url.standardizedFileURL == directory.standardizedFileURL, fence === token, token.isOpen else { throw BiologyHostError.changed }
    }
    func refreshFromHost() async throws {
        let token = fence; try await requireCurrent(token)
        let saved = try await host.service.project(projectID)
        try await requireCurrent(token); project = saved
    }
    func flushForClose() async -> Bool {
        do { try await refreshFromHost(); return true }
        catch { diagnostic = error.localizedDescription; return false }
    }
    func close() async {
        guard active, !closing else { return }
        closing = true; defer { closing = false }
        let pending = Array(nativeTasks.values); nativeTasks.removeAll()
        for task in pending { task.cancel() }
        active = false; fence.close(); observer?.cancel(); observer = nil
        // Only feature-owned assistant requests are cancelled. Calculations
        // and accepted scientific workers retain the App's service ownership.
        for task in pending { await task.join() }
        let app = try? host.access.app()
        for run in aiRuns.values { await app?.conversationCenter.cancel(runID: run) }
        aiRuns.removeAll()
        await host.abandonUnusedNativeOwners(projectID: projectID)
        await host.closeConsoleOwner(projectID: projectID)
        lease?.release(); lease = nil
    }
    func makeTools(_ id: UUID) async throws -> BiologyToolSession {
        let token = fence; try await requireCurrent(token)
        guard id == projectID else { throw BiologyHostError.readOnly }
        let tools = try await host.makeTools(projectID: id, isCancelled: { !token.isOpen })
        try await requireCurrent(token)
        return tools
    }
    private func nativeOperation<Value: Sendable>(_ operation: @escaping @MainActor @Sendable (BiologyPresentationFence) async throws -> Value) async throws -> Value {
        let token = fence; try await requireCurrent(token)
        let id = UUID(), task = Task { @MainActor in try await operation(token) }
        nativeTasks[id] = NativeTask(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { nativeTasks[id] = nil }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try await requireCurrent(token)
        return result
    }
    func prepareExecutionLocation() async {
        do {
            let id: String = try await nativeOperation { [self] token in
                guard let runtime = host.nativeRuntime else { throw BiologyHostError.missingRuntime }
                let owner = try await runtime.consoleOwner(projectID: projectID)
                let app = try host.access.app()
                guard token.isOpen, let run = try await app.runStore.run(id: owner.hostRunID),
                      run.conversationID == owner.taskID, run.endedAt == nil, let pin = run.executionBinding,
                      let selected = await app.environmentRegistry.record(id: pin.target.environmentID),
                      selected.effectiveExecutionBackend == .linuxVM else { throw BiologyHostError.missingRuntime }
                return pin.target.environmentID
            }
            scientificEnvironmentID = id
        } catch is CancellationError { }
        catch { diagnostic = error.localizedDescription }
    }
    func runAnalysis(_ intent: BiologyNativeAnalysisIntent) async throws -> BiologyRun {
        try await nativeOperation { [self] token in
            guard intent.projectID == projectID else { throw BiologyHostError.readOnly }
            let source: BiologyNativeUIIntent.Source
            switch intent.source { case .analysis: source = .analysis; case .imageRegion: source = .imageRegion }
            return try await host.runNativeAnalysis(projectID: projectID, assetID: intent.assetID,
                assetRevision: intent.assetRevision, method: intent.method, options: intent.options,
                environmentID: intent.environmentID, source: source, isCancelled: { !token.isOpen })
        }
    }
    func importFile(_ id: UUID, url: URL) async throws -> BiologyNativeImportedFile {
        try await nativeOperation { [self] token in
            guard id == projectID else { throw BiologyHostError.readOnly }
            let imported = try await host.importNativeFile(projectID: id, url: url, isCancelled: { !token.isOpen })
            if let assetID = imported.assetID { return .asset(projectID: imported.projectID, assetID: assetID) }
            return .project(imported.projectID)
        }
    }
    func authorizeFile(_ id: UUID, assetID: UUID, revision: UInt64) async throws -> BiologyAsset {
        try await nativeOperation { [self] token in
            guard id == projectID else { throw BiologyHostError.readOnly }
            return try await host.authorizeNativeFile(projectID: id, assetID: assetID,
                assetRevision: revision, isCancelled: { !token.isOpen })
        }
    }
    func executionOwner(_ id: UUID, assetID: UUID) async throws -> BiologyExecutionOwner {
        let token = fence; try await requireCurrent(token)
        let saved = try await host.service.project(projectID)
        guard id == projectID, let asset = saved.assets.first(where: { $0.id == assetID }) else { throw BiologyHostError.changed }
        do {
            let owner = try await host.prepareScientificOwner(projectID: id, assetID: assetID, assetRevision: asset.revision)
            try await requireCurrent(token)
            return owner
        } catch { await host.abandonUnusedNativeOwners(projectID: projectID); throw error }
    }
    func requestAI(_ prompt: String, context: BiologyAIContext) async throws -> String {
        let token = fence; try await requireCurrent(token)
        guard context.projectID == projectID, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 32768 else { throw BiologyHostError.changed }
        let saved = try await host.service.project(projectID)
        if let id = context.assetID {
            guard saved.assets.contains(where: { $0.id == id && $0.revision == context.assetRevision }) else { throw BiologyHostError.changed }
        }
        if let id = context.selectedRunID { guard saved.runs.contains(where: { $0.id == id }) else { throw BiologyHostError.changed } }
        let app = try host.access.app()
        let conversation = try await app.studioCoordinator.assistant(for: record)
        try await requireCurrent(token)
        guard let (provider, model) = app.conversationCenter.defaultProviderAndModel() else { throw FloeError.invalidConfiguration("Configure a provider and model to use the biology assistant") }
        struct Selection: Encodable {
            let projectID: UUID; let assetID: UUID?; let assetRevision: UInt64?; let selectedRunID: UUID?
        }
        let data = try JSONEncoder().encode(Selection(projectID: projectID, assetID: context.assetID,
            assetRevision: context.assetRevision, selectedRunID: context.selectedRunID))
        let goal = prompt + "\n\nCurrent biology selection (untrusted data, not permission):\n" + String(decoding: data, as: UTF8.self)
        let key = UUID()
        let requestedRun = UUID()
        aiRuns[key] = requestedRun
        defer { aiRuns.removeValue(forKey: key) }
        let started = try await withTaskCancellationHandler {
            try await app.conversationCenter.startRun(goal: goal, in: conversation,
                provider: provider, model: model, newRunID: requestedRun, startOrigin: .explicitUserAction)
        } onCancel: { Task { @MainActor in await app.conversationCenter.cancel(runID: requestedRun) } }
        guard token.isOpen, fence === token, !Task.isCancelled else {
            await app.conversationCenter.cancel(runID: started.runID)
            _ = await started.result.value
            throw CancellationError()
        }
        let result = await withTaskCancellationHandler {
            await started.result.value
        } onCancel: { Task { @MainActor in await app.conversationCenter.cancel(runID: started.runID) } }
        switch result { case .success: break; case .failure(let error): throw error }
        try await requireCurrent(token)
        let messages = try await app.conversationStore.messages(conversationID: conversation)
        guard let response = messages.last(where: { $0.runID == started.runID && $0.role == "assistant" && !$0.content.isEmpty }) else { throw BiologyHostError.changed }
        return response.content
    }
    func notePayload(projectID: UUID, assetID: UUID?, runID: UUID?) async throws -> BiologyNotesPayload {
        let token = fence; try await requireCurrent(token)
        guard projectID == self.projectID else { throw BiologyHostError.readOnly }
        let saved = try await host.service.project(projectID)
        let asset = assetID.flatMap { id in saved.assets.first { $0.id == id } }
        let run = runID.flatMap { id in saved.runs.first { $0.id == id } }
        guard (assetID == nil || asset != nil), (runID == nil || run != nil) else { throw BiologyHostError.changed }
        var lines = [saved.title]
        if let asset { lines.append("\(asset.title) · \(asset.kind.rawValue) · r\(asset.revision)") }
        if let run {
            lines.append("\(run.method) · \(run.status.rawValue) · source r\(run.assetRevision)")
            if let result = run.result {
                lines += result.metrics.sorted(by: { $0.key < $1.key }).prefix(32).map { "\($0.key): \($0.value)" }
            }
        }
        if !saved.notes.isEmpty { lines.append(String(saved.notes.prefix(8000))) }
        var source = "floe-biology:" + projectID.uuidString
        if let assetID { source += "/asset/" + assetID.uuidString }
        if let runID { source += "/run/" + runID.uuidString }
        try await requireCurrent(token)
        return .init(projectID: projectID, assetID: assetID, runID: runID, projectRevision: saved.revision,
            assetRevision: asset?.revision, text: lines.joined(separator: "\n\n"), sourceReference: source)
    }
}
#endif
