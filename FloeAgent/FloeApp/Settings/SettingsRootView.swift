// FloeApp — Settings center shell.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5. iPad uses a NavigationSplitView
// (category list left, detail right — never an empty detail column; the
// first category is selected by default). iPhone uses the standard
// NavigationStack push flow. Every category is routed.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// One settings category in the settings center.
enum SettingsSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case general, personalization, providers, auxiliary, localModels, canvas, webSearch, permissions, appleCapabilities, privacy, execution, backgroundExecution, files, sourceControl, sync, remote, usage, dataManagement, diagnostics

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "settings.section.general"
        case .personalization: "记忆与个性化"
        case .providers: "settings.section.providers"
        case .auxiliary: "settings.section.auxiliary"
        case .webSearch: "websearch.title"
        case .localModels: "localmodels.title"
        case .canvas: "画布"
        case .permissions: "settings.section.permissions"
        case .appleCapabilities: "Apple 能力"
        case .privacy: "settings.section.privacy"
        case .execution: "settings.section.execution"
        case .backgroundExecution: "settings.section.background_execution"
        case .files: "settings.section.files"
        case .sourceControl: "GitHub 与源码管理"
        case .sync: "settings.section.sync"
        case .remote: "settings.section.remote"
        case .usage: "settings.section.usage"
        case .dataManagement: "数据管理"
        case .diagnostics: "settings.section.diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .personalization: "person.crop.circle.badge.checkmark"
        case .providers: "antenna.radiowaves.left.and.right"
        case .auxiliary: "photo.badge.plus"
        case .webSearch: "magnifyingglass"
        case .localModels: "cpu"
        case .canvas: "scribble.variable"
        case .permissions: "checkmark.shield"
        case .appleCapabilities: "apple.logo"
        case .privacy: "hand.raised"
        case .execution: "terminal"
        case .backgroundExecution: "pip"
        case .files: "folder"
        case .sourceControl: "arrow.triangle.branch"
        case .sync: "icloud"
        case .remote: "server.rack"
        case .usage: "chart.bar"
        case .dataManagement: "archivebox"
        case .diagnostics: "stethoscope"
        }
    }
}

/// Settings shell: category list + per-category detail.
struct SettingsRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selection: SettingsSection? = .general

    var body: some View {
        Group {
        if horizontalSizeClass == .regular {
            // iPad: master-detail with a preselected first category so the
            // detail column is never blank.
            NavigationSplitView {
                List(SettingsSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("settings.section.\(section.rawValue)")
                }
                .navigationTitle("settings.title")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("action.done") { dismiss() }
                    }
                }
            } detail: {
                // Wrap the detail column in a NavigationStack so NavigationLink
                // inside detail views (e.g. MemoryView's 用户画像/SOUL.md) can
                // push. Without this the links are silently dropped on iPad.
                NavigationStack {
                    detailView(for: selection ?? .general)
                }
            }
        } else {
            // The settings sheet has no outer navigation container. Own the
            // compact stack here so the same screen works both from the sheet
            // and from More without relying on an ancestor implementation
            // detail.
            NavigationStack {
                List(SettingsSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .accessibilityIdentifier("settings.section.\(section.rawValue)")
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
                .navigationTitle("settings.title")
                .navigationDestination(for: SettingsSection.self) { section in
                    detailView(for: section)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("action.done") { dismiss() }
                    }
                }
            }
        }
        }
        .alert("配置未保存", isPresented: Binding(
            get: { environment.settingsCenter.settingsSaveError != nil },
            set: { if !$0 { environment.settingsCenter.clearSettingsSaveError() } }
        )) {
            Button("完成", role: .cancel) {
                environment.settingsCenter.clearSettingsSaveError()
            }
        } message: {
            Text(environment.settingsCenter.settingsSaveError ?? "请稍后重试。")
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(center: environment.settingsCenter)
        case .personalization:
            MemoryView(center: environment.memoryCenter)
        case .providers:
            ProvidersSettingsView(center: environment.conversationCenter)
        case .auxiliary:
            AuxiliarySettingsView(center: environment.conversationCenter)
        case .webSearch:
            WebSearchSettingsView(center: environment.webSearchSettingsCenter)
        case .localModels:
            LocalModelsSettingsView(center: environment.localModelsCenter)
        case .canvas:
            CanvasSettingsView(center: environment.conversationCenter)
        case .permissions:
            AgentPermissionsView(center: environment.settingsCenter)
        case .appleCapabilities:
            AppleCapabilitiesSettingsView()
        case .privacy:
            PrivacySecurityView(center: environment.settingsCenter)
        case .execution:
            ExecutionEnvironmentView(center: environment.settingsCenter)
        case .backgroundExecution:
            BackgroundExecutionSettingsView(
                center: environment.settingsCenter,
                videoService: environment.backgroundVideoService
            )
        case .files:
            FilesSettingsView(center: environment.settingsCenter)
        case .sourceControl:
            GitHubSettingsView(center: environment.sourceControlCenter)
        case .sync:
            SyncSettingsView(center: environment.settingsCenter)
        case .remote:
            RemoteSettingsView(center: environment.settingsCenter)
        case .usage:
            UsageStatisticsView()
        case .dataManagement:
            DataManagementView(
                environment: environment,
                conversationCenter: environment.conversationCenter
            )
        case .diagnostics:
            DiagnosticsAboutView(center: environment.settingsCenter)
        }
    }
}

private struct CanvasSettingsView: View {
    @ObservedObject var center: ConversationCenter
    @AppStorage("creative.canvas.sync.enabled") private var syncEnabled = true
    @State private var preferences = CanvasPreferences.load()
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("模型") {
                Picker("画布助手模型", selection: agentModelBinding) {
                    Text("继承 Agent 默认模型").tag(Optional<UUID>.none)
                    ForEach(center.canvasAssistantModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                Picker("画面理解模型", selection: visionModelBinding) {
                    Text("继承辅助视觉模型").tag(Optional<UUID>.none)
                    ForEach(center.visionModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                LabeledContent("当前理解路径") {
                    Text(center.canvasVisionDestinationName() ?? "尚未配置")
                        .foregroundStyle(.secondary)
                }
                Text("画布助手负责搜索、读取素材与调用生成工具；画面理解模型负责识别笔迹、草图和非多模态模型无法读取的视觉内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Pencil") {
                Picker("双击 Pencil", selection: $preferences.doubleTapAction) {
                    Text("切换橡皮").tag(CanvasDoubleTapAction.toggleEraser)
                    Text("打开画笔菜单").tag(CanvasDoubleTapAction.showToolPalette)
                    Text("新建卡片").tag(CanvasDoubleTapAction.createCard)
                }
                Toggle("允许手指绘画", isOn: $preferences.fingerDrawingEnabled)
                LabeledContent("默认粗细") {
                    Slider(value: $preferences.pencilWidth, in: 1...18, step: 0.5)
                        .frame(maxWidth: 260)
                }
            }

            Section("理解与整理") {
                Picker("默认整理方式", selection: $preferences.understandingMode) {
                    Text("自动判断").tag(CanvasInkUnderstandingMode.automatic)
                    Text("文字").tag(CanvasInkUnderstandingMode.text)
                    Text("卡片").tag(CanvasInkUnderstandingMode.cards)
                    Text("图表").tag(CanvasInkUnderstandingMode.diagram)
                }
                Toggle("整理后保留原笔迹", isOn: $preferences.preserveInkAfterConversion)
                Text("只有在你点“理解并整理”或接受“转为卡片”建议时才会转换，原始手写不会被自动替换。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("画布") {
                Toggle("显示网格", isOn: $preferences.showGrid)
                Toggle("吸附到网格", isOn: $preferences.snapToGrid)
                Toggle("跨设备同步画布", isOn: $syncEnabled)
                Text("关闭同步只停止传输，不会删除已上传的画布或素材。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("画布")
        .onChange(of: preferences) { _, value in value.save() }
        .alert("画布配置保存或同步失败", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) { Button("完成", role: .cancel) {} } message: { Text(saveError ?? "") }
    }

    private var agentModelBinding: Binding<UUID?> {
        Binding(
            get: { center.modelPreferences.canvasAgentModelID },
            set: { modelID in
                var value = center.modelPreferences
                value.canvasAgentModelID = modelID
                Task {
                    do { try await center.saveModelPreferences(value) }
                    catch { saveError = SecretRedactor.redact(error.localizedDescription) }
                }
            }
        )
    }

    private var visionModelBinding: Binding<UUID?> {
        Binding(
            get: { center.modelPreferences.canvasVisionModelID },
            set: { modelID in
                var value = center.modelPreferences
                value.canvasVisionModelID = modelID
                Task {
                    do { try await center.saveModelPreferences(value) }
                    catch { saveError = SecretRedactor.redact(error.localizedDescription) }
                }
            }
        )
    }
}
#endif
