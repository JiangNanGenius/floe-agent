// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGameCore
import FloeRPGDeployment

private final class RPGAssetPickerCopy {
    let directory: URL
    private let id: UUID
    private let service: RPGDeploymentService

    init(directory: URL, id: UUID, service: RPGDeploymentService) {
        self.directory = directory
        self.id = id
        self.service = service
    }

    deinit {
        let service = service, id = id
        Task { try? await service.discardAssetCopy(id) }
    }
}

struct RPGDeploymentAssetsScreen: View {
    let session: GameWorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var service: RPGDeploymentService?
    @State private var context: GameProjectContext?
    @State private var engine: GameEngineID?
    @State private var root: GameRelativePath?
    @State private var sources: [RPGDeploymentSelection] = []
    @State private var selected: RPGDeploymentSelection?
    @State private var listing: RPGDeploymentAssets?
    @State private var copy: RPGAssetPickerCopy?
    @State private var showingPicker = false
    @State private var loading = true
    @State private var exportTask: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if sources.count > 1 {
                    Picker(IDELanguageRunText.t("资源来源", "Source"), selection: $selected) {
                        ForEach(sources, id: \.self) { source in
                            Text(source.path.value).tag(Optional(source))
                        }
                    }.disabled(exportTask != nil)
                } else if let source = sources.first {
                    LabeledContent(IDELanguageRunText.t("资源来源", "Source"), value: source.path.value)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                if loading { ProgressView() }
                else if sources.isEmpty, message == nil {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("没有可导出的部署资源", "No deployment assets to export"),
                              systemImage: "archivebox")
                    } description: {
                        Text(IDELanguageRunText.t("当前游戏中没有此引擎的资源归档或加密图片、音频。散装文件可在 IDE 中查看。",
                                                  "This game has no asset archive or encrypted images or audio for its engine. Loose files are available in the IDE."))
                    }
                } else if let listing {
                    Section {
                        ForEach(listing.files, id: \.path) { file in
                            LabeledContent(file.path.value,
                                           value: ByteCountFormatter.string(fromByteCount: Int64(clamping: file.bytes), countStyle: .file))
                        }
                    } header: {
                        Text(FloeL10n.l("app.rpgdeployment_assets_screen.files", listing.files.count))
                    }
                }
            }
            .navigationTitle(IDELanguageRunText.t("部署资源", "Deployment assets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if exportTask != nil { ProgressView() }
                    else {
                        Button(IDELanguageRunText.t("导出副本", "Export copies"), systemImage: "square.and.arrow.up") {
                            exportTask = Task { await export() }
                        }.disabled(listing?.files.isEmpty != false || loading)
                    }
                }
            }
        }
        .task { await load() }
        .task(id: selected) { await inspect() }
        .onDisappear {
            exportTask?.cancel()
            if !showingPicker { copy = nil }
        }
        .sheet(isPresented: $showingPicker, onDismiss: { copy = nil }) {
            if let directory = copy?.directory {
                OfficeCopyDestinationPicker(url: directory) { saved in
                    showingPicker = false
                    if saved { message = IDELanguageRunText.t("资源副本已保存。", "Asset copies saved.") }
                }
            }
        }
    }

    private func load() async {
        do {
            try await session.project.prepareForHandoff()
            try Task.checkCancellation()
            guard !session.closing, !session.closed, let choice = session.selection,
                  let engine = choice.selectedEngine else { throw RPGDeploymentError.invalidSelection }
            let context = try session.context
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("FloeRPGAssetExports", isDirectory: true)
                .appendingPathComponent(context.projectID.uuidString, isDirectory: true)
            let service = try RPGDeploymentService(repository: session.project.repository, workspace: staging)
            self.service = service
            self.context = context
            self.engine = engine
            root = choice.selectedRoot
            sources = RPGDeploymentService.availableAssets(in: session.project.project, engine: engine,
                                                          selectedRoot: choice.selectedRoot)
            selected = sources.first
            if selected == nil { loading = false }
        } catch {
            guard !Task.isCancelled else { return }
            loading = false
            message = userMessage(error)
        }
    }

    private func check(_ context: GameProjectContext, _ selection: RPGDeploymentSelection) throws {
        try Task.checkCancellation()
        try context.validate(current: session.context)
        guard !session.closed, !session.closing, session.selection?.selectedEngine == engine,
              session.selection?.selectedRoot == root, selected == selection else { throw RPGDeploymentError.invalidSelection }
    }

    private func inspect() async {
        guard let selected, let service, let context, let engine else { return }
        loading = true
        listing = nil
        message = nil
        do {
            try check(context, selected)
            let value = try await service.readAssets(context: context, current: session.context, engine: engine,
                                                     selectedRoot: root, selection: selected, export: false)
            try check(context, selected)
            listing = value
        } catch {
            guard !Task.isCancelled else { return }
            message = userMessage(error)
        }
        loading = false
    }

    private func export() async {
        defer { exportTask = nil }
        guard let selected, let service, let context, let engine else { return }
        do {
            try check(context, selected)
            let value = try await service.readAssets(context: context, current: session.context, engine: engine,
                                                     selectedRoot: root, selection: selected, export: true)
            guard let directory = value.directory else { throw RPGDeploymentError.invalidSelection }
            let ownedCopy = RPGAssetPickerCopy(directory: directory, id: value.id, service: service)
            try check(context, selected)
            copy = ownedCopy
            showingPicker = true
        } catch {
            guard !Task.isCancelled else { return }
            message = userMessage(error)
        }
    }

    private func userMessage(_ error: Error) -> String {
        if let deployment = error as? RPGDeploymentError {
            switch deployment {
            case .missingMediaKey, .invalidMediaKey, .invalidMediaHeader:
                return IDELanguageRunText.t("此工程的媒体配置无法解码这些文件。", "These files could not be decoded with this game's media settings.")
            case .limitExceeded:
                return IDELanguageRunText.t("资源超过单次导出的大小或数量限制。", "This selection exceeds the file or size limit for one export.")
            case .invalidSelection:
                return IDELanguageRunText.t("请重新打开所选 RPG 工程并检查资源格式。", "Reopen the selected RPG game and check the asset format.")
            default: break
            }
        }
        return IDELanguageRunText.t("无法读取所选资源。请重新打开工程并检查原文件。", "The selected assets could not be read. Reopen the project and check the original files.")
    }
}
#endif
