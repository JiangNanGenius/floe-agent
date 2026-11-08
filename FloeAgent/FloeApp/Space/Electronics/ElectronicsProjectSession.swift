// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeElectronicsCore
import FloeElectronicsUI

/// Files, the native editor and model tools share this original and session.
@MainActor @Observable final class ElectronicsProjectSession {
    private static var sessions: [UUID: ElectronicsProjectSession] = [:]
    private static var opening: [UUID: Task<ElectronicsProjectSession, Error>] = [:]
    let id: UUID
    let directory: URL
    let workbench: EDWorkbenchSession
    private var publication: Task<Void, Never>?
    private(set) var listingError: String?

    private init(id: UUID, directory: URL, workbench: EDWorkbenchSession) {
        self.id = id; self.directory = directory; self.workbench = workbench
        workbench.onSaved = { [weak self] _ in self?.schedulePublication() }
    }
    static func open(id: UUID, directory: URL) async throws -> ElectronicsProjectSession {
        let root = directory.standardizedFileURL
        guard root == root.resolvingSymlinksInPath() else { throw PersonalContentError.changedDocument }
        if let value = sessions[id], !value.workbench.isClosed {
            guard value.directory == root else { throw PersonalContentError.changedDocument }
            return value
        }
        if let task = opening[id] {
            let value = try await task.value
            guard value.directory == root else { throw PersonalContentError.changedDocument }
            return value
        }
        let task = Task { @MainActor in
            let store = try EDAProjectStore(root: root.appendingPathComponent("Electronics"), projectID: id)
            let workbench = try await EDWorkbenchSession(store: store)
            guard workbench.project.id == id else { throw PersonalContentError.invalidProject }
            return ElectronicsProjectSession(id: id, directory: root, workbench: workbench)
        }
        opening[id] = task
        defer { opening[id] = nil }
        let value = try await task.value
        sessions[id] = value
        return value
    }
    static func existing(id: UUID, directory: URL) throws -> ElectronicsProjectSession? {
        guard let value = sessions[id], !value.workbench.isClosed else { return nil }
        guard value.directory == directory.standardizedFileURL else { throw PersonalContentError.changedDocument }
        return value
    }
    private func schedulePublication() {
        let previous = publication
        publication = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let library = try await PersonalContentService.shared.library()
                let location = try await library.resolve(id)
                guard location.record.kind == .electronics, location.url.standardizedFileURL == directory else {
                    throw PersonalContentError.changedDocument
                }
                try await library.markChanged(id)
                listingError = nil
                NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id)
            } catch {
                listingError = IDELanguageRunText.t("作品已保存，但文件列表暂未更新。请稍后刷新。",
                    "The work was saved, but its file listing could not be updated. Refresh it shortly.")
            }
        }
    }
    func awaitPublication() async { await publication?.value }
    func flushForClose() async -> Bool {
        guard await workbench.flushForClose() else { return false }
        await awaitPublication()
        if Self.sessions[id] === self { Self.sessions[id] = nil }
        return true
    }
    static func prepareForFileAction(id: UUID, directory: URL) async throws {
        guard opening[id] == nil else { throw PersonalFileActionError.busy }
        guard let value = sessions[id] else { return }
        guard value.directory == directory.standardizedFileURL else { throw PersonalContentError.changedDocument }
        guard !value.workbench.busy, !value.workbench.isDirty,
              !value.workbench.isChecking, !value.workbench.isRouting,
              !value.workbench.isFilling, !value.workbench.isExporting else { throw PersonalFileActionError.busy }
        await value.awaitPublication()
        guard opening[id] == nil, sessions[id] === value,
              !value.workbench.busy, !value.workbench.isDirty,
              !value.workbench.isChecking, !value.workbench.isRouting,
              !value.workbench.isFilling, !value.workbench.isExporting else { throw PersonalFileActionError.busy }
        await value.workbench.close()
        guard value.workbench.isClosed, opening[id] == nil, sessions[id] === value else { throw PersonalFileActionError.busy }
        sessions[id] = nil
    }
}
#endif
