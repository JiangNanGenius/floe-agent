// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import FloeHeavyEditorSupport
import FloeScoreKit

@MainActor @Observable final class MusicNotationSession {
    let parentID: UUID
    let root: URL
    private weak var parent: MusicProjectSession?
    private let playback: MusicNotationPlayback
    private(set) var controller: HeavyEditorController?
    private(set) var identity = UUID()
    private var opening: Task<HeavyEditorController, any Error>?
    private var exported: [String: URL] = [:]
    private var audioInvocation: UUID?
    @ObservationIgnored private var clockRefresh: Task<Void, Never>?
    var isBusy: Bool { opening != nil || controller?.isWorking == true || playback.isBusy }
    init(parent: MusicProjectSession) {
        self.parent = parent; parentID = parent.id; root = parent.root.standardizedFileURL.resolvingSymlinksInPath()
        playback = MusicNotationPlayback(parent: parent, authority: parent.notationAudioAuthority,
            renderer: parent.notationRenderer, ownerToken: parent.notationOwnerToken)
    }
    func openController(allowCreation: Bool = true, initialTitle: String? = nil, refreshTransport: Bool = true,
                        authorizeCreation: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> HeavyEditorController {
        if let controller {
            if refreshTransport { _ = try await controller.execute("score.playback.control", arguments: .object(["action": .string("status")])) }
            return controller
        }
        if let opening { return try await opening.value }
        let generation = identity
        let task = Task { @MainActor [self] in
            try await requireParent()
            let directory = MusicNotationPackage.notationRoot(root)
            if !FileManager.default.fileExists(atPath: directory.path) {
                guard allowCreation else { throw PersonalContentError.missingDocument }
                try await authorizeCreation?()
                // Stage the original and binding together. Revocation/cancellation
                // before the never-overwrite move cannot leave a half-created score.
                let staging = root.appendingPathComponent(".notation-create-" + UUID().uuidString)
                let stagedOriginal = MusicNotationPackage.notationRoot(staging)
                defer { try? FileManager.default.removeItem(at: staging) }
                let store = try HeavyEditorProjectStore(directory: stagedOriginal, documentID: parentID, kind: .score)
                try await store.create(ScoreWorkbench.makeDocument(title: initialTitle ?? parent?.document.name ?? "Score", id: parentID))
                try MusicNotationPackage.encoded(MusicNotationBinding(musicProjectID: parentID, scoreDocumentID: parentID))
                    .write(to: stagedOriginal.appendingPathComponent("Binding.json"), options: .withoutOverwriting)
                _ = try MusicNotationPackage.readOriginal(root: staging, parentID: parentID)
                guard identity == generation else { throw CancellationError() }
                try await requireParent(); try await authorizeCreation?(); try Task.checkCancellation()
                try FileManager.default.moveItem(at: stagedOriginal, to: directory)
            }
            // A partially created original is recoverable only under the exact
            // parent identity; no imported path or title can attach it elsewhere.
            let bindingURL = directory.appendingPathComponent("Binding.json")
            if !FileManager.default.fileExists(atPath: bindingURL.path) {
                guard allowCreation else { throw PersonalContentError.invalidProject }
                let doc = try JSONDecoder().decode(HeavyEditorDocument.self,
                    from: MusicNotationPackage.regularData(directory.appendingPathComponent("Document.json")))
                try MusicNotationPackage.validateScore(doc, parentID: parentID)
                guard identity == generation else { throw CancellationError() }
                try await requireParent(); try await authorizeCreation?(); try Task.checkCancellation()
                try MusicNotationPackage.encoded(MusicNotationBinding(musicProjectID: parentID, scoreDocumentID: parentID))
                    .write(to: bindingURL, options: .withoutOverwriting)
            }
            _ = try MusicNotationPackage.readOriginal(root: root, parentID: parentID)
            let hooks = HeavyEditorHostHooks(authorize: { [weak self] request in
                guard let self else { throw PersonalContentError.changedDocument }
                try await self.authorize(request, generation: generation)
            }, didSave: { [weak self] document in
                await self?.saved(document, generation: generation)
            }, export: { [weak self] _, artifact in
                guard let self else { throw PersonalContentError.changedDocument }
                return try await self.export(artifact, generation: generation)
            })
            let adapter = ScorePlaybackAdapter(transport: { [weak self] request in
                guard let self else { throw PersonalContentError.changedDocument }
                return try await self.transport(request, generation: generation)
            }, stop: { [weak self] in await self?.stopAudio(generation: generation) },
               scopedTransport: { [weak self] id, request in
                guard let self else { throw PersonalContentError.changedDocument }
                return try await self.transport(request, generation: generation, invocation: id)
            }, cancelInvocation: { [weak self] id, _ in
                await self?.cancelTransport(id, generation: generation)
            })
            let value = try await ScoreWorkbench.open(directory: directory, documentID: parentID,
                owner: .music(parentID), hooks: hooks, playback: adapter)
            try await value.waitUntilReady()
            guard identity == generation else { throw CancellationError() }
            controller = value
            return value
        }
        opening = task
        defer { if identity == generation { opening = nil } }
        return try await task.value
    }
    private func requireParent() async throws {
        guard let parent, parent.id == parentID, !parent.notationRestoring else { throw PersonalContentError.changedDocument }
        _ = try MusicNotationPackage.directoryIdentity(root)
        let location = try await PersonalContentService.shared.library().resolve(parentID)
        guard location.record.kind == .music,
              location.url.appendingPathComponent("Music").standardizedFileURL.resolvingSymlinksInPath() == root else { throw PersonalContentError.changedDocument }
    }
    private func authorize(_ request: HeavyEditorAccessRequest, generation: UUID) async throws {
        guard identity == generation, request.documentID == parentID, request.owner == .music(parentID) else { throw PersonalContentError.changedDocument }
        try await requireParent()
        if request.access == .edit || request.access == .importFile {
            guard let parent, !parent.saving, !parent.notationImporting, !parent.isRendering, !parent.isRecording, !parent.isMIDIRecording else {
                throw HeavyEditorError.engine(WorkbenchText.t("请先完成当前保存、导出或录音。", "Finish the current save, export or recording first."))
            }
        }
    }
    private func saved(_ document: HeavyEditorDocument, generation: UUID) async {
        guard identity == generation, document.id == parentID else { return }
        do {
            try await requireParent()
            let saved = try MusicNotationPackage.readOriginal(root: root, parentID: parentID)
            guard saved?.document == document else { throw PersonalContentError.changedDocument }
            let library = try await PersonalContentService.shared.library()
            try await library.markChanged(parentID)
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: parentID)
        } catch { parent?.diagnostic = WorkbenchText.t("乐谱已保存，文件列表暂未更新。", "The score was saved; its file listing could not be updated.") }
    }
    private func export(_ artifact: HeavyEditorArtifact, generation: UUID) async throws -> HeavyEditorExportReceipt {
        guard identity == generation else { throw PersonalContentError.changedDocument }
        try await requireParent()
        let token = UUID().uuidString.lowercased(), directory = root.appendingPathComponent("Exports/notation-" + token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(artifact.name)
        do {
            try artifact.data.write(to: file, options: .withoutOverwriting)
            let read = try MusicNotationPackage.regularData(file, maximum: max(MusicNotationPackage.maximumDocumentBytes, artifact.data.count))
            guard identity == generation, read == artifact.data else { throw PersonalContentError.changedDocument }
            let fileID = "music:" + parentID.uuidString.lowercased() + ":notation-export:" + token
            exported[fileID] = file; parent?.registerNotationExport(file)
            return try HeavyEditorExportReceipt(fileID: fileID, artifact: artifact)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func exportURL(fileID: String) throws -> URL {
        guard let file = exported[fileID] else { throw PersonalContentError.missingDocument }
        _ = try MusicNotationPackage.regularData(file)
        return file
    }
    private func transport(_ request: EditorJSON, generation: UUID, invocation: UUID = UUID()) async throws -> EditorJSON {
        guard identity == generation else { throw PersonalContentError.changedDocument }
        try await requireParent()
        // A native UUID, never a model field, owns only audio this invocation
        // changes. Status does not adopt a prior UI or AI playback owner.
        if ["start", "pause", "stop", "seek"].contains(request["action"].string ?? "status") { audioInvocation = invocation }
        return try await playback.run(request)
    }
    private func cancelTransport(_ invocation: UUID, generation: UUID) {
        guard identity == generation, audioInvocation == invocation else { return }
        stopAudio()
    }
    func stopAudio() {
        audioInvocation = nil
        playback.stop()
        guard clockRefresh == nil, let controller, controller.isReady else { return }
        let generation = identity
        clockRefresh = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            defer { if self.identity == generation { self.clockRefresh = nil } }
            guard self.identity == generation, let controller, self.controller === controller else { return }
            _ = try? await controller.execute("score.playback.control", arguments: .object(["action": .string("status")]))
        }
    }
    private func stopAudio(generation: UUID) { if identity == generation { stopAudio() } }
    func invalidateForRestore() {
        identity = UUID(); opening?.cancel(); opening = nil; clockRefresh?.cancel(); clockRefresh = nil
        controller?.cancel(); controller = nil; audioInvocation = nil; playback.stop()
    }
}

extension MusicProjectSession {
    func openNotation() async throws -> MusicNotationSession {
        guard !notationRestoring else { throw PersonalContentError.changedDocument }
        if let notation { return notation }
        let value = MusicNotationSession(parent: self)
        notation = value
        return value
    }
    func restoreNotationBackup(source: URL, expected: MusicNotationSnapshot) {
        guard notationRestoreTask == nil, !notationImporting else { return }
        notationImporting = true
        notationRestoreTask = Task { @MainActor [self] in
            defer { notationImporting = false; notationRestoreTask = nil }
            do { try await MusicNotationRestore.restore(source, session: self, expected: expected) }
            catch is CancellationError {} catch { diagnostic = error.localizedDescription }
        }
    }
    func cancelNotationRestore() { notationRestoreTask?.cancel() }
    func notationBackupSnapshot() throws -> MusicNotationSnapshot {
        guard !saving, !notationImporting, !isRendering, !isRecording, !isMIDIRecording, notation?.isBusy != true else { throw PersonalFileActionError.busy }
        return try MusicNotationPackage.capture(root: root, parentID: id)
    }
}

@MainActor struct MusicNotationWorkbench: View {
    @Bindable var session: MusicProjectSession
    var onAssistant: (() -> Void)?
    let onClose: () -> Void
    @State private var failure: String?
    @State private var openRequest: UUID?
    var body: some View {
        Group {
            if let controller = session.notation?.controller {
                ScoreEditorView(controller: controller, onClose: onClose,
                    closeLabel: WorkbenchText.t("返回编曲", "Back to arrangement"))
            } else if let failure {
                ContentUnavailableView {
                    Label(WorkbenchText.t("无法打开乐谱", "Unable to open score"), systemImage: "music.note.list")
                } description: {
                    Text(WorkbenchText.t("原件仍保存在音乐工程中，请重试。", "The original remains in the music project. Try again."))
                    DisclosureGroup(WorkbenchText.t("详情", "Details")) { Text(failure).textSelection(.enabled) }
                } actions: { Button(WorkbenchText.t("重试", "Retry")) { Task { await open() } } }
            } else { ProgressView(WorkbenchText.t("正在打开乐谱…", "Opening score…")) }
        }
        .task(id: session.notation?.identity) { await open() }
        .accessibilityIdentifier("music.notation.workbench")
    }
    private func open() async {
        let request = UUID(); openRequest = request
        var requestedService: MusicNotationSession?
        var serviceIdentity: UUID?
        do {
            failure = nil
            let service = try await session.openNotation()
            requestedService = service; serviceIdentity = service.identity
            let controller = try await service.openController()
            try Task.checkCancellation()
            guard openRequest == request, session.notation === service, service.identity == serviceIdentity else { return }
            controller.onAssistant = onAssistant
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, openRequest == request else { return }
            if let requestedService, requestedService.identity != serviceIdentity { return }
            failure = error.localizedDescription
        }
    }
}
#endif
