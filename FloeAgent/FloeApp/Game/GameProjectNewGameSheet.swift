// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGameAppIntegration
import FloeGameCore
import FloeGameStarterKit

/// New-game flow: create the owned empty project first, then optionally seed
/// the selected reviewed starter. Import is a separate action in the overview.
/// No external tree is copied into this creation sheet.
struct GameProjectNewGameSheet: View {
    let onCancel: () -> Void
    let onCreated: (PersonalContentRecord) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @State private var title = ""
    @State private var engine: GameEngineID = .godot
    @State private var seedStarter = true
    @State private var busy = false
    @State private var error: String?
    @State private var resourceReadiness: GameRuntimeEngineReadiness?
    @State private var resourceBusy = false
    @State private var resourceError: String?

    private var library: GameEngineLibrary? { environment.gameWorkspaces.library }
    private var requiresRuntimeForStarter: Bool {
        [GameEngineID.phaser, .kaplay, .babylon, .playcanvas].contains(engine)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(IDELanguageRunText.t("名称", "Name")) {
                    TextField(IDELanguageRunText.t("游戏名称", "Game name"), text: $title)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("game.new.title")
                }
                Section(IDELanguageRunText.t("引擎", "Engine")) {
                    if let library {
                        Picker(IDELanguageRunText.t("引擎", "Engine"), selection: $engine) {
                            ForEach(library.entries) { entry in
                                Text(entry.displayName).tag(entry.engine)
                            }
                        }
                        if let entry = library.entries.first(where: { $0.engine == engine }) {
                            Text(entry.entry.value + " · " + entry.readiness.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                            if !entry.prerequisiteSummary.isEmpty {
                                Text(entry.prerequisiteSummary).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let resourceReadiness {
                            LabeledContent(resourceReadiness.displayName,
                                           value: resourceReadiness.statusText)
                                .font(.caption)
                            if resourceBusy {
                                ProgressView(value: environment.gameWorkspaces.runtimeResources
                                    .progress[resourceReadiness.packID] ?? 0)
                                    .progressViewStyle(.linear)
                                Button(IDELanguageRunText.t("取消下载", "Cancel download")) {
                                    Task {
                                        await environment.gameWorkspaces
                                            .cancelRuntimeResourcePreparation(for: engine)
                                        resourceBusy = false
                                    }
                                }.font(.caption)
                            }
                            if resourceReadiness.canDownload || resourceReadiness.canRetry {
                                Button {
                                    Task { await downloadRuntime() }
                                } label: {
                                    HStack {
                                        if resourceBusy { ProgressView().controlSize(.small) }
                                        Text(resourceReadiness.canDownload
                                             ? IDELanguageRunText.t("下载已验证运行资源",
                                                                    "Download verified runtime")
                                             : IDELanguageRunText.t("重试", "Retry"))
                                    }
                                }.disabled(resourceBusy)
                            }
                            if let resourceError {
                                Text(resourceError).font(.caption2).foregroundStyle(.red)
                            }
                        }
                    } else {
                        Text(IDELanguageRunText.t("内置起始目录不可用。检查安装资源后重试。", "The bundled starter catalog is unavailable. Check the installed resources and retry."))
                            .foregroundStyle(.red)
                    }
                    Toggle(IDELanguageRunText.t("立即创建起始文件", "Create starter files now"), isOn: $seedStarter)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Text(IDELanguageRunText.t("先创建独立空工程，再写入起始文件或导入外部工程。未知文件不会被舍弃。", "An independent empty project is created first; starter files or an external import come next. Unknown files are preserved."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(IDELanguageRunText.t("新建游戏", "New game"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("创建", "Create")) {
                        Task { await create() }
                    }.disabled(busy
                        || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (seedStarter && requiresRuntimeForStarter
                            && resourceReadiness?.isReady != true))
                }
            }
            .overlay { if busy { ProgressView(IDELanguageRunText.t("正在创建", "Creating")) } }
            .task(id: engine) { await refreshResourceState() }
        }
    }

    private func refreshResourceState() async {
        await environment.gameWorkspaces.runtimeResources.refresh()
        resourceReadiness = environment.gameWorkspaces.runtimeResources.readiness(for: engine)
        resourceError = nil
    }

    private func downloadRuntime() async {
        resourceBusy = true
        defer { resourceBusy = false }
        do {
            try await environment.gameWorkspaces.prepareRuntimeResource(for: engine)
            await refreshResourceState()
        } catch is CancellationError {
            resourceError = nil
        } catch {
            resourceError = error.localizedDescription
        }
    }

    private func create() async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = IDELanguageRunText.t("请输入名称。", "Enter a name."); return }
        busy = true
        defer { busy = false }
        do {
            if seedStarter && requiresRuntimeForStarter {
                _ = try environment.gameWorkspaces.runtimeResources.requireReady(engine)
            }
            let record = try await PersonalContentService.shared.createGame(title: clean, engine: engine)
            if seedStarter {
                let session = try await environment.gameWorkspaces.openSpaceGame(record: record)
                do {
                    try await session.project.initializeStarter(engine: engine)
                } catch {
                    // The empty project is a real retained asset. Surface the
                    // starter failure; do not pretend files were created.
                    self.error = error.localizedDescription
                    onCreated(record)
                    return
                }
            }
            onCreated(record)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
