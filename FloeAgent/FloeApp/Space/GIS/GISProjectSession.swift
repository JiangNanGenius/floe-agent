// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeGISKit
import FloeHeavyEditorSupport

/// UI and tools hold this one durable Space original. Preview never opens it.
@MainActor @Observable final class GISProjectSession {
    private static var sessions: [UUID: GISProjectSession] = [:]
    private static var opening: [UUID: Task<GISProjectSession, Error>] = [:]
    let id: UUID
    let directory: URL
    let controller: HeavyEditorController
    private var sourceFile: PersonalPreviewFile
    private var sourceRevision: UInt64
    private var sourceSHA256: String
    private(set) var isClosed = false
    private(set) var isRefreshing = false
    private var hasPresentation = false
    private var modelUses = Set<UUID>()
    private var exported: [String: (url: URL, receipt: HeavyEditorExportReceipt)] = [:]
    private(set) var listingError: String?
    var exportURLs: [URL] { exported.values.map(\.url).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }

    private init(id: UUID, directory: URL, controller: HeavyEditorController, saved: GISProjectSavedSnapshot) {
        self.id = id; self.directory = directory; self.controller = controller
        sourceFile = saved.file; sourceRevision = saved.document.revision; sourceSHA256 = saved.sha256
    }
    static func open(id: UUID, directory: URL) async throws -> GISProjectSession {
        let root = directory.standardizedFileURL
        guard root == root.resolvingSymlinksInPath() else { throw PersonalContentError.changedDocument }
        if let value = sessions[id], !value.isClosed {
            guard value.directory == root else { throw PersonalContentError.changedDocument }
            try await value.requireOriginal(); return value
        }
        if let pending = opening[id] {
            let value = try await pending.value
            guard value.directory == root else { throw PersonalContentError.changedDocument }
            return value
        }
        let pending = Task { @MainActor in
            // Existence and identity are mandatory. describe/query never create originals.
            let saved = try await personalPreviewOffMain { try GISProjectOriginal.read(id: id, directory: root) }
            let owner = GISProjectSessionHooks()
            let hooks = HeavyEditorHostHooks(authorize: { request in
                guard let session = await owner.session else { throw PersonalContentError.changedDocument }
                try await session.authorize(request)
            }, didSave: { document in
                guard let session = await owner.session else { return }
                await session.saved(document)
            }, export: { projectID, artifact in
                guard let session = await owner.session else { throw PersonalContentError.changedDocument }
                return try await session.export(projectID: projectID, artifact: artifact)
            })
            let controller = try await GISWorkbench.open(directory: GISProjectOriginal.root(in: root), documentID: id, owner: .space(id), hooks: hooks)
            guard controller.document == saved.document else { throw HeavyEditorError.revisionConflict }
            try saved.validate()
            let session = GISProjectSession(id: id, directory: root, controller: controller, saved: saved)
            await owner.attach(session)
            try await session.requireOriginal()
            try await controller.waitUntilReady()
            return session
        }
        opening[id] = pending
        defer { opening[id] = nil }
        let result = try await pending.value
        sessions[id] = result
        return result
    }
    private func location() async throws -> (record: PersonalContentRecord, url: URL) {
        guard !isClosed else { throw PersonalContentError.changedDocument }
        try PersonalLibraryFileActions.requireAvailable(id)
        let value = try await PersonalContentService.shared.library().resolve(id)
        guard value.record.kind == .geography, value.url.standardizedFileURL == directory,
              !value.record.needsRecovery else { throw PersonalContentError.changedDocument }
        try PersonalLibraryFileActions.requireAvailable(id)
        return value
    }
    func requireOriginal() async throws {
        _ = try await location()
        guard sourceRevision == controller.document.revision else { throw HeavyEditorError.revisionConflict }
        // This is a live O_NOFOLLOW/fstat identity check, not a cached success.
        // Atomic replacement or an in-place change invalidates the saved SHA
        // pin, without decoding/re-hashing raster samples for every UI tap.
        try sourceFile.validate()
        _ = try await location(); try sourceFile.validate(); try Task.checkCancellation()
    }
    private func authorize(_ request: HeavyEditorAccessRequest) async throws {
        guard request.documentID == id, request.owner == .space(id), request.revision == controller.document.revision else { throw HeavyEditorError.wrongDocument }
        guard !isRefreshing || (request.access == .read && request.command == "document.presentation") else { throw PersonalFileActionError.busy }
        try await requireOriginal()
    }
    private func saved(_ document: HeavyEditorDocument) async {
        do {
            try await refreshSourcePin(document)
            try await requireOriginal()
            try await PersonalContentService.shared.library().markChanged(id, title: document.title)
            listingError = nil
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id)
        } catch {
            listingError = IDELanguageRunText.t("地图已保存，文件列表暂未更新。请稍后刷新。", "The map was saved; refresh the file list shortly.")
        }
    }
    private func refreshSourcePin(_ document: HeavyEditorDocument) async throws {
        let projectID = id, root = directory
        let saved = try await personalPreviewOffMain { try GISProjectOriginal.read(id: projectID, directory: root) }
        guard saved.document == document else { throw HeavyEditorError.revisionConflict }
        try saved.validate()
        sourceFile = saved.file; sourceRevision = document.revision; sourceSHA256 = saved.sha256
    }
    private func export(projectID: UUID, artifact: HeavyEditorArtifact) async throws -> HeavyEditorExportReceipt {
        guard projectID == id else { throw HeavyEditorError.wrongDocument }
        try await requireOriginal(); try Task.checkCancellation()
        let folder = directory.appendingPathComponent("GIS/Exports/" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(artifact.name)
        do {
            try artifact.data.write(to: file, options: .withoutOverwriting)
            let saved = try PersonalPreviewFile(root: directory, url: file, maximumBytes: max(1, artifact.data.count))
            guard try saved.data() == artifact.data else { throw PersonalContentError.changedDocument }
            try await requireOriginal(); try saved.validate(); try Task.checkCancellation()
            let token = "gis:" + id.uuidString.lowercased() + ":export:" + UUID().uuidString.lowercased()
            let receipt = try HeavyEditorExportReceipt(fileID: token, artifact: artifact)
            exported[token] = (file, receipt)
            return receipt
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    func exportFile(_ receipt: HeavyEditorExportReceipt) throws -> URL {
        guard let value = exported[receipt.fileID], value.receipt.sha256 == receipt.sha256,
              value.receipt.byteCount == receipt.byteCount, value.receipt.name == receipt.name else { throw PersonalContentError.missingDocument }
        let file = try PersonalPreviewFile(root: directory, url: value.url, maximumBytes: max(1, receipt.byteCount))
        guard file.identity.size == receipt.byteCount else { throw PersonalContentError.changedDocument }
        try file.verifyHash(receipt.sha256); return value.url
    }
    func originalSHA256() throws -> String {
        guard sourceRevision == controller.document.revision else { throw HeavyEditorError.revisionConflict }
        try sourceFile.validate(); return sourceSHA256
    }
    func retainModelUse() throws -> UUID {
        guard !isClosed else { throw PersonalContentError.changedDocument }
        guard !isRefreshing else { throw PersonalFileActionError.busy }
        let token = UUID(); modelUses.insert(token); return token
    }
    /// Single-command describe runs outside the controller's operation queue.
    /// Wait for a presentation refresh or another command to settle instead of
    /// failing the schema read as "editor not ready", but keep the wait bounded
    /// and never adopt work for a closed/replaced original.
    func retainModelUseWhenSettled(timeout: Duration = .seconds(8)) async throws -> UUID {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            guard !isClosed else { throw PersonalContentError.changedDocument }
            try Task.checkCancellation()
            if !isRefreshing, !controller.isWorking {
                let token = UUID(); modelUses.insert(token); return token
            }
            guard ContinuousClock.now < deadline else { throw HeavyEditorError.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func releaseModelUse(_ token: UUID) { modelUses.remove(token); closeIfUnused() }
    func beginPresentation() throws {
        guard !isClosed else { throw PersonalContentError.changedDocument }
        guard !hasPresentation, !isRefreshing else { throw PersonalFileActionError.busy }
        hasPresentation = true
    }
    private func closeIfUnused() {
        guard !isClosed, !isRefreshing, !hasPresentation, modelUses.isEmpty, !controller.isWorking else { return }
        isClosed = true; controller.cancel()
        if Self.sessions[id] === self { Self.sessions[id] = nil }
    }
    func refresh() async throws {
        guard !isClosed else { throw PersonalContentError.changedDocument }
        guard !isRefreshing, !controller.isWorking, modelUses.isEmpty else { throw PersonalFileActionError.busy }
        isRefreshing = true
        defer { isRefreshing = false; closeIfUnused() }
        do {
            _ = try await location()
            let projectID = id, root = directory
            let saved = try await personalPreviewOffMain { try GISProjectOriginal.read(id: projectID, directory: root) }
            _ = try await location(); try saved.validate()
            // reload() assigns its new document before invoking our normal
            // presentation authorization. Bind only this verified same-ID,
            // same-location snapshot first; all other operations stay fenced.
            sourceFile = saved.file; sourceRevision = saved.document.revision; sourceSHA256 = saved.sha256
            try await controller.reload()
            guard controller.document == saved.document else { throw HeavyEditorError.revisionConflict }
            try await requireOriginal(); try saved.validate()
            listingError = nil
        } catch {
            // A racing commit or failed reload may have changed the controller.
            // Never leave that controller paired with another revision's pin.
            // Its immutable disk original remains untouched; next open creates
            // a fresh session, and this surface can still close without saving.
            isClosed = true; hasPresentation = false; controller.cancel()
            if Self.sessions[id] === self { Self.sessions[id] = nil }
            await controller.endPresentation()
            listingError = IDELanguageRunText.t("地图已改变，请关闭后重新打开。", "The map changed. Close and reopen it.")
            throw error
        }
    }
    /// The current live camera as the same presentation projection the native
    /// view reads. Only an actual center/zoom change needs a view-committing
    /// document.save on close; content commits already refreshed the source pin.
    private func presentationViewMatchesSaved() -> Bool {
        let content = controller.document.content
        let current = controller.presentation["view"], saved = (content["data"] == .null ? content : content["data"])["view"]
        let center = current["center"].array.compactMap(\.number), savedCenter = saved["center"].array.compactMap(\.number)
        guard center.count == 2, center.allSatisfy(\.isFinite) else { return false }
        let zoom = current["zoom"].number ?? 2, savedZoom = saved["zoom"].number ?? 2
        let base = savedCenter.count == 2 ? savedCenter : [0, 20]
        return abs(center[0] - base[0]) < 1e-9 && abs(center[1] - base[1]) < 1e-9 && abs(zoom - savedZoom) < 1e-9
    }
    func flushForClose() async -> Bool {
        if isClosed { await controller.endPresentation(); return true }
        guard !isRefreshing, !controller.isWorking, modelUses.isEmpty else { return false }
        do {
            // Closing an untouched map must not append a bare revision. Ask
            // the live page for its current camera first; a moved view still
            // commits exactly as before, and the CAS/source pin remain.
            try await controller.refreshPresentation()
            if controller.document.revision != sourceRevision || !presentationViewMatchesSaved() {
                try await controller.save()
            }
            try await requireOriginal()
            guard !controller.isWorking, modelUses.isEmpty else { return false }
            await controller.endPresentation()
            hasPresentation = false; closeIfUnused()
            return true
        } catch { listingError = error.localizedDescription; return false }
    }
    /// Dismissal does not stop a service-owned model edit. Its use lease still
    /// prevents moving/deleting this original until the actual invocation ends.
    func presentationEnded() async { hasPresentation = false; await controller.endPresentation(); closeIfUnused() }
    /// Explicit Continue from the native leave decision only. Every model edit
    /// commits through the existing controller/host hook; this is not a flush
    /// receipt and does not release or transfer that model's original lease.
    func endPresentationKeepingModelWork() async -> Bool {
        guard !isClosed, !isRefreshing, !modelUses.isEmpty else { return false }
        do {
            try await requireOriginal()
            guard !isClosed, !isRefreshing, !modelUses.isEmpty else { return false }
            await presentationEnded()
            return true
        } catch { listingError = error.localizedDescription; return false }
    }
    static func prepareForFileAction(id: UUID, directory: URL) async throws {
        guard opening[id] == nil else { throw PersonalFileActionError.busy }
        guard let value = sessions[id], !value.isClosed else { return }
        guard value.directory == directory.standardizedFileURL, !value.isRefreshing, !value.controller.isWorking, value.modelUses.isEmpty else { throw PersonalFileActionError.busy }
        await value.controller.endPresentation(); value.controller.cancel(); value.isClosed = true
        sessions[id] = nil
    }
}

/// Hooks do not retain a view or a ToolContext from whichever window opened first.
private actor GISProjectSessionHooks {
    weak var session: GISProjectSession?
    func attach(_ session: GISProjectSession) { self.session = session }
}
#endif
