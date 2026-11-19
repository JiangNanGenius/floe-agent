// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeGameCore
import FloeGameWebKit
import FloeGameTouch
import FloeGameTouchUI
import FloeGameDeveloperCore
import FloeGameDeveloperUI
import FloeGameRGSSHostCore
import FloeVNC

struct GameProjectPlayScreen: View {
    let session: GameWorkspaceSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var play: GamePlayCoordinator?
    @State private var controls: GameProjectRGSSRunPresentation?
    @State private var vnc: VNCSession?
    @State private var developer: GameDeveloperSession?
    @State private var showSaves = false
    @State private var showDeveloper = false
    @State private var stopping = false
    @State private var resolveControlDraft = false
    @State private var error: String?

    var body: some View {
        Group {
            if let presentation = play?.webPresentation {
                GameProjectWebPlayerSurface(presentation: presentation,
                    title: session.record?.title ?? "Game") { receipt in
                    if receipt.closeAcknowledged { dismiss() }
                }
            } else {
                guestScreen
            }
        }
        .task { await prepare() }
        .onDisappear {
            controls?.requestInputEnabled(false)
            Task { await play?.detachViewer() }
        }
        .interactiveDismissDisabled()
    }

    private var guestScreen: some View {
        NavigationStack {
            Group {
                if let controls {
                    GameRGSSControlsViewport(presentation: controls, vnc: vnc)
                        .id(controls.jobID)
                } else if let guest = play?.rgssPlay {
                    GameRGSSStartingView(guest: guest) { await prepare() }
                } else {
                    ProgressView(copy("正在准备试玩", "Preparing play"))
                }
            }
            .navigationTitle(session.record?.title ?? "Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("关闭", "Close")) { Task { await close() } }
                        .disabled(stopping)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if controls != nil {
                        Button(copy("存档", "Saves"), systemImage: "internaldrive") { showSaves = true }
                        Button(copy("调试", "Debug"), systemImage: "slider.horizontal.3") {
                            Task { await openDeveloper() }
                        }.disabled(controls?.play.phase != .running)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $showSaves) {
                if let controls { GameRGSSSavePanel(session: controls.play).id(controls.jobID) }
            }
            .sheet(isPresented: $showDeveloper) {
                if let developer {
                    NavigationStack {
                        GameDeveloperMenuPanel(session: developer)
                            .navigationTitle(copy("调试／作弊", "Debug / cheats"))
                            .toolbar { ToolbarItem(placement: .cancellationAction) {
                                Button(copy("关闭", "Close")) { showDeveloper = false }
                            } }
                    }
                }
            }
            .onChange(of: showSaves) { _, _ in updateInput() }
            .onChange(of: showDeveloper) { _, _ in updateInput() }
            .onChange(of: session.lastLaunchRequest?.id) { _, id in
                guard controls?.play.request.id != id else { return }
                controls?.requestInputEnabled(false)
                controls = nil; vnc = nil
                Task { await prepare() }
            }
            .confirmationDialog(copy("保存键位修改？", "Save control changes?"),
                isPresented: $resolveControlDraft, titleVisibility: .visible) {
                Button(copy("保存并关闭", "Save and close")) {
                    Task { if await controls?.saveControls() == true { dismiss() } }
                }
                Button(copy("放弃修改并关闭", "Discard and close"), role: .destructive) {
                    Task { await controls?.discardControlChanges(); dismiss() }
                }
                Button(copy("取消", "Cancel"), role: .cancel) {}
            }
        }
    }

    private func copy(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private func updateInput() { controls?.setCovered(showSaves || showDeveloper) }

    private func prepare() async {
        let coordinator = environment.gameWorkspaces.playCoordinator(for: session)
        play = coordinator
        guard let guest = session.rgssPlay else { return }
        do {
            if guest.phase == .detached { try await coordinator.reattachViewer() }
            guard guest.phase == .running else { return }
            let prepared = try await coordinator.prepareRGSSControls()
            let host = try await environment.gameWorkspaces.rgssHost(for: session)
            let viewer = try host.vncSession(for: try session.project.context)
            guard session.rgssPlay === guest, guest.session?.jobID == prepared.jobID else {
                throw RGSSGuestRunError.staleSession
            }
            vnc = viewer; controls = prepared
            updateInput()
        } catch { self.error = error.localizedDescription }
    }

    private func close() async {
        guard let play else { dismiss(); return }
        stopping = true
        let receipt = await play.stop()
        stopping = false
        guard receipt.stopConfirmed == true || (receipt.runID == nil && !play.isRunning) else {
            error = copy("尚未确认游戏停止，请重试关闭。", "The game has not confirmed stopping. Retry Close.")
            return
        }
        if controls?.hasControlChanges == true { resolveControlDraft = true }
        else { dismiss() }
    }

    private func openDeveloper() async {
        guard let guest = controls?.play else { return }
        do { developer = try await guest.openDeveloperMenu(); showDeveloper = true }
        catch { self.error = error.localizedDescription }
    }
}

private struct GameRGSSStartingView: View {
    @ObservedObject var guest: RGSSGuestPlaySession
    let onReady: @MainActor () async -> Void
    var body: some View {
        Group {
            if case .failed(let message) = guest.phase {
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("无法启动试玩", "Could not start play"), systemImage: "exclamationmark.triangle")
                } description: { Text(message) }
            } else { ProgressView(IDELanguageRunText.t("正在准备试玩", "Preparing play")) }
        }
        .task(id: guest.phase) {
            if guest.phase == .running || guest.phase == .detached { await onReady() }
        }
    }
}

private struct GameRGSSControlsViewport: View {
    @Bindable var presentation: GameProjectRGSSRunPresentation
    let vnc: VNCSession?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false
    @State private var resolveDraft = false

    var body: some View {
        ZStack {
            Color.black
            if let vnc { VNCViewer(session: vnc).allowsHitTesting(!presentation.editingLayout) }
            else { ProgressView(copy("正在连接画面", "Connecting display")) }
            GameTouchControlsView(service: presentation.input, editingLayout: presentation.editingLayout,
                layoutProfile: presentation.draftProfile,
                onMove: { id, point in presentation.moveControl(id, to: point) },
                onFinishLayout: { Task {
                    if await presentation.saveControls() { presentation.editingLayout = false }
                } })
                .allowsHitTesting(!presentation.stopping && presentation.play.phase == .running)
            if presentation.play.phase == .stopped {
                Text(copy("游戏已停止", "Game stopped")).font(.headline).padding(12)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button(copy("键位", "Controls"), systemImage: "keyboard") {
                if showControls && presentation.hasControlChanges { resolveDraft = true }
                else { showControls.toggle() }
            }
        } }
        .inspector(isPresented: Binding(get: { showControls }, set: { visible in
            if !visible && presentation.hasControlChanges { resolveDraft = true }
            else { showControls = visible }
        })) {
            GameTouchSettingsView(profile: $presentation.draftProfile,
                editingLayout: $presentation.editingLayout, saving: presentation.savingControls,
                defaults: presentation.defaultProfile,
                onArrange: { showControls = false },
                onSave: { _ in Task { _ = await presentation.saveControls() } })
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .onChange(of: presentation.draftProfile) { _, value in
            guard !presentation.editingLayout else { return }
            Task { await presentation.previewControls(value) }
        }
        .onChange(of: showControls) { _, _ in updateInput() }
        .onChange(of: presentation.editingLayout) { _, _ in updateInput() }
        .onChange(of: scenePhase) { _, _ in updateInput() }
        .onAppear { updateInput() }
        .onDisappear { presentation.requestInputEnabled(false) }
        .confirmationDialog(copy("保存键位修改？", "Save control changes?"),
            isPresented: $resolveDraft, titleVisibility: .visible) {
            Button(copy("保存", "Save")) {
                Task { if await presentation.saveControls() { showControls = false } }
            }
            Button(copy("放弃修改", "Discard"), role: .destructive) {
                Task { await presentation.discardControlChanges(); showControls = false }
            }
            Button(copy("取消", "Cancel"), role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let error = presentation.controlsError {
                Text(error).font(.caption).padding(8).background(.regularMaterial)
            }
        }
    }
    private func copy(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private func updateInput() {
        presentation.requestInputEnabled(scenePhase == .active && !showControls && !presentation.editingLayout)
    }
}

/// Requires the transactional save-manager delta in the adoption graph.
/// Mutations target the stopped run's owned save layer, never source files.
struct GameRGSSSavePanel: View {
    @ObservedObject var session: RGSSGuestPlaySession
    @Environment(\.dismiss) private var dismiss
    @State private var saves: [RGSSGuestSaveDescriptor] = []
    @State private var rawBackups: [RGSSGuestSaveRawBackupDescriptor] = []
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var hasCheckpoint = false
    @State private var checkpointSupported = false
    @State private var importing = false
    @State private var pendingImport: URL?
    @State private var pendingImportSHA256: String?
    @State private var restoringRawBackup: RGSSGuestSaveRawBackupDescriptor?
    @State private var restoringRawExpectedSHA256: String?
    @State private var deleting: RGSSGuestSaveDescriptor?
    @State private var renaming: RGSSGuestSaveDescriptor?
    @State private var newName = ""
    @State private var confirmingRestore = false
    @State private var exporting = false
    @State private var exportName = "Save"
    @State private var document: GameRGSSSaveDocument?

    private var canMutate: Bool { session.phase == .stopped && !busy }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if saves.isEmpty {
                        ContentUnavailableView(copy("没有存档", "No saves"), systemImage: "internaldrive")
                    }
                    ForEach(saves) { save in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(save.name).font(.body.monospaced())
                                Text(ByteCountFormatter.string(fromByteCount: Int64(save.bytes), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(copy("导出文件", "Export file"), systemImage: "square.and.arrow.up") {
                                    Task { await export(save) }
                                }
                                Button(copy("重命名", "Rename"), systemImage: "pencil") {
                                    newName = save.name; renaming = save
                                }.disabled(!canMutate)
                                Button(copy("删除", "Delete"), systemImage: "trash", role: .destructive) {
                                    deleting = save
                                }.disabled(!canMutate)
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                            }.disabled(busy)
                        }
                    }
                } footer: {
                    Text(copy("这里管理已收集的存档。停止游戏后更新列表；导入或恢复的存档在下次试玩时使用。",
                              "These are the collected saves. The list updates after stopping. Imported or restored saves are used on the next run."))
                }
                if !rawBackups.isEmpty {
                    Section(copy("替换前的备份", "Replacement backups")) {
                        ForEach(rawBackups) { backup in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backup.name).font(.body.monospaced())
                                    Text(backup.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(copy("恢复", "Restore")) {
                                    restoringRawExpectedSHA256 = saves.first { $0.name == backup.name }?.sha256
                                    restoringRawBackup = backup
                                }.disabled(!canMutate)
                            }
                        }
                    }
                }
                if let status { Text(status).foregroundStyle(.secondary) }
            }
            .navigationTitle(copy("存档管理", "Save manager"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("关闭", "Close")) { dismiss() }.disabled(busy)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(copy("导入", "Import"), systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(!canMutate)
                    Menu {
                        Button(copy("刷新", "Refresh"), systemImage: "arrow.clockwise") {
                            Task { await refresh() }
                        }
                        Button(copy("创建备份", "Create backup"), systemImage: "internaldrive.badge.plus") {
                            Task { await backup() }
                        }.disabled(!canMutate || !checkpointSupported)
                        Button(copy("恢复备份", "Restore backup"), systemImage: "clock.arrow.circlepath") {
                            confirmingRestore = true
                        }.disabled(!canMutate || !hasCheckpoint)
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .disabled(busy)
                }
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .overlay { if busy { ProgressView().padding(16).background(.regularMaterial, in: Capsule()) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): Task { await chooseImport(url) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                          defaultFilename: exportName) { result in
                document = nil
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
            .confirmationDialog(copy("替换同名存档？", "Replace this save?"),
                isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                titleVisibility: .visible) {
                Button(copy("备份后替换", "Back up and replace"), role: .destructive) {
                    if let url = pendingImport { Task { await importSave(url, replace: true) } }
                }
                Button(copy("取消", "Cancel"), role: .cancel) { pendingImport = nil }
            } message: {
                Text(copy("会先备份同名原文件；存档已被修改时将停止替换。",
                          "The original file is backed up first. Replacement stops if the save has changed."))
            }
            .confirmationDialog(copy("恢复这份文件备份？", "Restore this file backup?"),
                isPresented: Binding(get: { restoringRawBackup != nil },
                                     set: { if !$0 { restoringRawBackup = nil } }),
                titleVisibility: .visible, presenting: restoringRawBackup) { backup in
                Button(copy("恢复", "Restore"), role: .destructive) { Task { await restoreRaw(backup) } }
                Button(copy("取消", "Cancel"), role: .cancel) { restoringRawBackup = nil }
            } message: { _ in
                Text(copy("将替换当前同名存档，其他存档保留。", "The matching save is replaced. Other saves are retained."))
            }
            .confirmationDialog(copy("删除这个存档？", "Delete this save?"),
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible, presenting: deleting) { save in
                Button(copy("删除", "Delete"), role: .destructive) { Task { await delete(save) } }
                Button(copy("取消", "Cancel"), role: .cancel) { deleting = nil }
            }
            .confirmationDialog(copy("恢复备份？", "Restore backup?"),
                isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button(copy("恢复", "Restore"), role: .destructive) { Task { await restore() } }
                Button(copy("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(copy("备份中的同名存档会替换当前版本；其他存档保留。",
                          "Matching saves are replaced by the backup. Other saves are retained."))
            }
            .alert(copy("重命名存档", "Rename save"),
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(copy("文件名", "Filename"), text: $newName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(copy("保存", "Save")) { if let save = renaming { Task { await rename(save) } } }
                Button(copy("取消", "Cancel"), role: .cancel) { renaming = nil }
            }
            .alert(copy("操作未完成", "Could not complete"),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(copy("好", "OK")) { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(busy)
    }

    private func copy(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private func manager() throws -> RGSSGuestSaveManager {
        guard let manager = session.saveManager else { throw RGSSGuestRunError.stagedRunMissing }
        return manager
    }
    private func requireStopped() throws {
        guard session.phase == .stopped else {
            throw FloeError.validationFailed(copy("请先停止游戏，再修改存档。", "Stop the game before changing saves."))
        }
    }
    private func requireCompletion(_ receipt: RGSSGuestSaveMutationReceipt) throws {
        guard receipt.outcome != .requiresRetry else {
            throw FloeError.validationFailed(copy("操作尚未完成，文件已保留，请重试。",
                                                 "The operation is incomplete. Files are retained; retry to finish."))
        }
    }
    private func refresh() async {
        do {
            let manager = try manager()
            saves = try await manager.list()
            rawBackups = try await manager.listRawBackups()
            let repository = await manager.checkpointRepository
            checkpointSupported = repository != nil
            if let repository { hasCheckpoint = try await repository.load() != nil }
            else { hasCheckpoint = false }
        } catch { self.error = error.localizedDescription }
    }
    private func verify(_ save: RGSSGuestSaveDescriptor, manager: RGSSGuestSaveManager) async throws -> Data {
        let data = try await manager.read(save.name)
        let actual = GameDigest.sha256(data)
        guard actual == save.sha256 else {
            throw FloeError.validationFailed(copy("存档已更新，请刷新列表后再操作。", "The save changed. Refresh the list and try again."))
        }
        return data
    }
    private func export(_ save: RGSSGuestSaveDescriptor) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            document = GameRGSSSaveDocument(data: try await verify(save, manager: try manager()))
            exportName = save.name; exporting = true
        } catch { self.error = error.localizedDescription }
    }
    private func chooseImport(_ url: URL) async {
        do {
            try requireStopped()
            let current = try await manager().list()
            if let existing = current.first(where: { $0.name == url.lastPathComponent }) {
                pendingImportSHA256 = existing.sha256; pendingImport = url
            }
            else { await importSave(url, replace: false) }
        } catch { self.error = error.localizedDescription }
    }
    private func importSave(_ url: URL, replace: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try requireStopped()
            let manager = try manager()
            if replace {
                guard let expected = pendingImportSHA256 else { throw RGSSGuestRunError.savePreconditionFailed(url.lastPathComponent) }
                let receipt = try await manager.importFile(from: url, expectedSHA256: expected, keepBackup: true)
                try requireCompletion(receipt)
            } else {
                try requireCompletion(try await manager.importFile(from: url, policy: .rejectExisting))
            }
            pendingImport = nil; status = copy("已导入，下次试玩生效。", "Imported. It will be used on the next run.")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func delete(_ save: RGSSGuestSaveDescriptor) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try requireStopped(); let manager = try manager()
            try requireCompletion(try await manager.delete(save.name, expectedSHA256: save.sha256))
            deleting = nil; await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func rename(_ save: RGSSGuestSaveDescriptor) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try requireStopped(); let manager = try manager()
            let receipt = try await manager.renameTransaction(save.name, to: newName, expectedSHA256: save.sha256)
            if receipt.outcome == .requiresRetry {
                status = copy("重命名尚未完成，文件均已保留，可重试。", "Rename is incomplete. Both files are retained; retry to finish.")
            } else { renaming = nil }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func backup() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try requireStopped()
            guard try await manager().checkpoint() != nil else {
                throw FloeError.validationFailed(copy("当前存档不支持此备份方式。", "This save layer does not support checkpoints."))
            }
            status = copy("已创建备份。", "Backup created."); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func restore() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try requireStopped()
            let receipt = try await manager().restoreCheckpointTransaction()
            try requireCompletion(receipt)
            status = copy("已恢复备份，下次试玩生效。", "Backup restored. It will be used on the next run.") + " (\(receipt.changedNames.count))"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func restoreRaw(_ backup: RGSSGuestSaveRawBackupDescriptor) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try requireStopped()
            let receipt = try await manager().restoreRawBackup(id: backup.id,
                                                               expectedSHA256: restoringRawExpectedSHA256)
            try requireCompletion(receipt)
            restoringRawBackup = nil
            status = copy("已恢复文件备份，下次试玩生效。", "File backup restored. It will be used on the next run.")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

private struct GameRGSSSaveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
