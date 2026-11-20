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
    /// The native surface and host refreshes share this one visible model.
    /// The service still owns all persisted data and calculation lifetimes.
    let workbenchModel: BiologyWorkbenchModel
    private(set) var record: PersonalContentRecord
    private(set) var directory: URL
    private(set) var project: BiologyProject
    var diagnostic: String?
    private(set) var scientificEnvironmentID: String?
    /// Latest trusted workbench selection handed over when the shared
    /// assistant surface opens. Opening the assistant re-validates the
    /// asset/revision and refreshes the persisted selection through the
    /// existing `BiologyService.select` path (keeping its fine-grained
    /// payload), so the shared conversation reads the real current asset via
    /// the existing studio/biology.read route. This session never starts a
    /// provider run itself.
    private(set) var assistantContext: BiologyAIContext?
    func syncAssistantSelection(_ context: BiologyAIContext) async throws {
        guard context.projectID == projectID else { throw BiologyHostError.changed }
        let token = fence; try await requireCurrent(token)
        let saved = try await host.service.project(projectID)
        try Task.checkCancellation()
        guard active, token.isOpen, fence === token else { throw CancellationError() }
        if let runID = context.selectedRunID {
            guard saved.runs.contains(where: { $0.id == runID && $0.assetID == context.assetID }) else {
                throw BiologyHostError.changed
            }
        }
        if let assetID = context.assetID {
            guard let asset = saved.assets.first(where: { $0.id == assetID && $0.revision == context.assetRevision }) else {
                throw BiologyHostError.changed
            }
            if saved.activeAssetID != assetID {
                let selection = saved.selections?[assetID.uuidString] ?? .object([:])
                _ = try await host.service.select(projectID, assetID: assetID, selection: selection,
                    expectedAssetRevision: asset.revision)
                try await requireCurrent(token)
            }
        } else if context.assetRevision != nil || saved.activeAssetID != nil {
            throw BiologyHostError.changed
        }
        assistantContext = context
    }
    @ObservationIgnored private var lease: PersonalLibraryUsageLease?
    @ObservationIgnored private let fence = BiologyPresentationFence()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    private struct NativeTask {
        let cancel: @MainActor @Sendable () -> Void
        let join: @MainActor @Sendable () async -> Void
    }
    @ObservationIgnored private var nativeTasks: [UUID: NativeTask] = [:]
    @ObservationIgnored private var observer: Task<Void, Never>?

    private init(record: PersonalContentRecord, directory: URL, project: BiologyProject, host: BiologyHostServices) {
        self.record = record; self.directory = directory; self.project = project
        projectID = record.id; self.host = host
        workbenchModel = BiologyWorkbenchModel(service: host.service, projectID: record.id)
    }
    static func open(id: UUID, directory: URL, host: BiologyHostServices) async throws -> BiologyProjectSession {
        while true {
            try Task.checkCancellation()
            if let existing = sessions[id] {
                guard existing.host === host, let closeTask = existing.closeTask else { throw BiologyHostError.alreadyOpen }
                await closeTask.value
                continue // Re-resolve the original and its revision after the previous presentation has left.
            }
            let location = try await host.access.location(id)
            guard location.url.standardizedFileURL == directory.standardizedFileURL else { throw BiologyHostError.changed }
            let project = try await host.store.load(id)
            try Task.checkCancellation()
            guard project.id == location.record.id else { throw BiologyHostError.changed }
            // Another caller may have mounted or started closing during these reads.
            guard sessions[id] == nil else { continue }
            let session = BiologyProjectSession(record: location.record, directory: location.url, project: project, host: host)
            session.lease = try PersonalLibraryFileActions.acquireUse(id: id, directory: location.url)
            session.active = true
            sessions[id] = session
            await session.workbenchModel.refresh()
            guard !Task.isCancelled, session.active, sessions[id] === session else {
                await session.close()
                throw CancellationError()
            }
            session.observe()
            return session
        }
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
                    do {
                        // Canonical content reaches the editor even if the
                        // derived Files metadata projection is temporarily busy.
                        try await refreshFromHost()
                        guard token.isOpen, self.fence === token else { return }
                        try await host.synchronizeMetadata([projectID])
                        let mounted = try await host.access.location(projectID)
                        guard token.isOpen, self.fence === token else { return }
                        record = mounted.record
                        NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: projectID)
                    } catch is CancellationError { return }
                    catch {
                        if token.isOpen, self.fence === token { diagnostic = error.localizedDescription }
                        // A failed metadata/read projection cannot retire the
                        // subscription to later real commits.
                    }
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
        await workbenchModel.refresh()
        try await requireCurrent(token)
    }
    func flushForClose() async -> Bool {
        do { try await refreshFromHost(); return true }
        catch { diagnostic = error.localizedDescription; return false }
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        guard active else { return }
        let pending = Array(nativeTasks.values); nativeTasks.removeAll()
        for task in pending { task.cancel() }
        active = false; fence.close(); observer?.cancel(); observer = nil
        // Only this presentation's feature tasks are cancelled. Calculations,
        // accepted scientific workers and the shared persistent file assistant
        // retain the App's service/task ownership; leaving the editor never
        // cancels them by itself.
        let retirement = Task { @MainActor in
            for task in pending { await task.join() }
            await host.abandonUnusedNativeOwners(projectID: projectID)
            await host.closeConsoleOwner(projectID: projectID)
            lease?.release(); lease = nil
            if Self.sessions[projectID] === self { Self.sessions[projectID] = nil }
        }
        closeTask = retirement
        await retirement.value
        closeTask = nil
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
            let run = try await host.runNativeAnalysis(projectID: projectID, assetID: intent.assetID,
                assetRevision: intent.assetRevision, method: intent.method, options: intent.options,
                environmentID: intent.environmentID, source: source, isCancelled: { !token.isOpen })
            // A region read is the image annotation the user asked to keep.
            // Persist it through the existing select path so the project
            // reopens on the same region and the shared assistant reads the
            // same persisted selection via biology.read.
            if case .imageRegion = intent.source {
                await persistImageRegionAnnotation(assetID: intent.assetID, assetRevision: intent.assetRevision, options: intent.options)
            }
            return run
        }
    }
    /// Best-effort persistence of a just-read image region. The analysis run
    /// remains the authoritative result; a selection conflict never rewrites
    /// it or fails the caller.
    private func persistImageRegionAnnotation(assetID: UUID, assetRevision: UInt64, options: BiologyJSON) async {
        guard let fields = options.object else { return }
        let allowed: Set<String> = ["series", "level", "channel", "slice", "frame", "region"]
        let selection = BiologyJSON.object(fields.filter { allowed.contains($0.key) })
        guard selection.object?.isEmpty == false else { return }
        guard let saved = try? await host.service.project(projectID),
              let asset = saved.assets.first(where: { $0.id == assetID && $0.revision == assetRevision }) else { return }
        _ = try? await host.service.select(projectID, assetID: assetID, selection: selection, expectedAssetRevision: asset.revision)
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
    /// The shared persistent file assistant (StudioCoordinator/StudioAssistantView)
    /// is the only AI surface for this original; it owns conversation binding,
    /// model choice, queueing and lifecycle. This session deliberately starts
    /// no direct provider run, so leaving the editor never cancels assistant work.
    func notePayload(projectID: UUID, assetID: UUID?, runID: UUID?) async throws -> BiologyNotesPayload {
        let token = fence; try await requireCurrent(token)
        guard projectID == self.projectID else { throw BiologyHostError.readOnly }
        let saved = try await host.service.project(projectID)
        let asset = assetID.flatMap { id in saved.assets.first { $0.id == id } }
        let run = runID.flatMap { id in saved.runs.first { $0.id == id } }
        guard (assetID == nil || asset != nil), (runID == nil || run != nil) else { throw BiologyHostError.changed }
        var lines = [saved.title]
        if let asset {
            lines.append("\(asset.title) · \(asset.kind.rawValue) · r\(asset.revision)")
            // Surface the saved annotation (plane/region selection) so the
            // Notes preview and the shared assistant payload show the same
            // persisted selection the workbench reopens with.
            if let selection = saved.selections?[asset.id.uuidString], let fields = selection.object, !fields.isEmpty {
                let summary = String(decoding: (try? BiologyCoding.encode(selection)) ?? Data(), as: UTF8.self)
                lines.append(IDELanguageRunText.t("选区", "Selection") + ": " + String(summary.prefix(2000)))
            }
        }
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
