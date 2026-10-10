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
    case general, personalization, internalPrompts, providers, auxiliary, localModels, canvas, webSearch, permissions, appleCapabilities, privacy, execution, backgroundExecution, files, sourceControl, sync, remote, usage, dataManagement, diagnostics

    var id: String { rawValue }

    // Preserve persisted navigation values, not duplicate configuration pages.
    static var visibleCases: [Self] { allCases.filter { $0 != .sourceControl } }

    var title: LocalizedStringKey {
        switch self {
        case .general: "settings.section.general"
        case .personalization: "settings.settings_root_view.memories_personalization"
        case .internalPrompts: "settings.section.internal_prompts"
        case .providers: "settings.section.providers"
        case .auxiliary: "settings.section.auxiliary"
        case .webSearch: "websearch.title"
        case .localModels: "localmodels.title"
        case .canvas: "settings.settings_root_view.canvas"
        case .permissions: "settings.section.permissions"
        case .appleCapabilities: "settings.apple_capabilities_settings_view.apple_capabilities"
        case .privacy: "settings.section.privacy"
        case .execution: "settings.section.execution"
        case .backgroundExecution: "settings.section.background_execution"
        case .files: "settings.section.files"
        case .sourceControl: "settings.git_hub_settings_view.github_source_control"
        case .sync: "settings.section.sync"
        case .remote: "settings.section.remote"
        case .usage: "settings.section.usage"
        case .dataManagement: "settings.data_management_view.data_management"
        case .diagnostics: "settings.section.diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .personalization: "person.crop.circle.badge.checkmark"
        case .internalPrompts: "text.badge.checkmark"
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
    // The settings sheet may be hosted outside the presenting view's
    // environment. Require its dependency at every entry point instead of
    // trapping while constructing the initial detail page.
    @ObservedObject var environment: AppEnvironment
    @State private var selection: SettingsSection? = .general
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        Group {
        if horizontalSizeClass == .regular {
            // iPad: master-detail with a preselected first category so the
            // detail column is never blank.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(SettingsSection.visibleCases, selection: $selection) { section in
                    settingsRowLabel(for: section)
                        .tag(section)
                        .accessibilityIdentifier("settings.section.\(section.rawValue)")
                }
                .navigationTitle(FloeL10n.l("settings.title"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("action.done") { dismiss() }
                    }
                }
                .collapseSidebarOnRightSwipe {
                    withAnimation(.snappy) { columnVisibility = .detailOnly }
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
                List(SettingsSection.visibleCases) { section in
                    NavigationLink(value: section) {
                        settingsRowLabel(for: section)
                    }
                    .accessibilityIdentifier("settings.section.\(section.rawValue)")
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
                .accessibilityIdentifier("settings.sections")
                .navigationTitle(FloeL10n.l("settings.title"))
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
        .environmentObject(environment)
        .alert("settings.settings_root_view.configuration_not_saved", isPresented: Binding(
            get: { environment.settingsCenter.settingsSaveError != nil },
            set: { if !$0 { environment.settingsCenter.clearSettingsSaveError() } }
        )) {
            Button("workspace.workspace_canvas_view.done", role: .cancel) {
                environment.settingsCenter.clearSettingsSaveError()
            }
        } message: {
            Text(environment.settingsCenter.settingsSaveError ?? "settings.settings_root_view.please_try_again")
        }
    }

    /// The on-device model entry carries an explicit Beta marker without
    /// renaming the row itself; cloud models never share that marker.
    @ViewBuilder
    private func settingsRowLabel(for section: SettingsSection) -> some View {
        if section == .localModels {
            HStack {
                Label(section.title, systemImage: section.systemImage)
                Spacer()
                Text("localmodels.beta_badge")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FloeTheme.pending)
                    // Leave room for the compact-list chevron on iPhone.
                    .padding(.trailing, 22)
            }
        } else {
            Label(section.title, systemImage: section.systemImage)
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(
                center: environment.settingsCenter,
                contentUpdates: environment.contentUpdateCenter
            )
        case .personalization:
            MemoryView(center: environment.memoryCenter)
        case .internalPrompts:
            InternalPromptsSettingsView(center: environment.contentUpdateCenter)
        case .providers:
            ProvidersSettingsView(
                center: environment.conversationCenter,
                catalog: environment.contentUpdateCenter.providerCatalogIndex(),
                onRefreshCatalog: { await environment.contentUpdateCenter.refreshProviderCatalog() }
            )
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
            ConnectorsView(sourceControl: environment.sourceControlCenter, mcpCenter: .shared)
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
            Section("settings.usage_statistics_view.model") {
                Picker("settings.settings_root_view.canvas_assistant_model", selection: agentModelBinding) {
                    Text("settings.settings_root_view.inherit_the_agent_default_model").tag(Optional<UUID>.none)
                    ForEach(center.canvasAssistantModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                Picker("settings.settings_root_view.screen_understanding_model", selection: visionModelBinding) {
                    Text("settings.settings_root_view.inherit_the_auxiliary_vision_model").tag(Optional<UUID>.none)
                    ForEach(center.visionModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                LabeledContent("settings.settings_root_view.current_understanding_path") {
                    Text(center.canvasVisionDestinationName() ?? "settings.settings_root_view.not_configured")
                        .foregroundStyle(.secondary)
                }
                Text("settings.settings_root_view.the_canvas_assistant_handles_search_reading")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Pencil") {
                Picker("settings.settings_root_view.double_tap_pencil", selection: $preferences.doubleTapAction) {
                    Text("settings.settings_root_view.switch_to_eraser").tag(CanvasDoubleTapAction.toggleEraser)
                    Text("settings.settings_root_view.open_brush_menu").tag(CanvasDoubleTapAction.showToolPalette)
                    Text("workspace.workspace_canvas_view.new_card").tag(CanvasDoubleTapAction.createCard)
                }
                Toggle("settings.settings_root_view.allow_finger_drawing", isOn: $preferences.fingerDrawingEnabled)
                LabeledContent("settings.settings_root_view.default_thickness") {
                    Slider(value: $preferences.pencilWidth, in: 1...18, step: 0.5)
                        .frame(maxWidth: 260)
                }
            }

            Section("settings.settings_root_view.understand_and_organize") {
                Picker("settings.settings_root_view.default_organization_method", selection: $preferences.understandingMode) {
                    Text("settings.settings_root_view.automatic").tag(CanvasInkUnderstandingMode.automatic)
                    Text("notes.notes_document_editor.text").tag(CanvasInkUnderstandingMode.text)
                    Text("canvas.node.card").tag(CanvasInkUnderstandingMode.cards)
                    Text("settings.settings_root_view.chart").tag(CanvasInkUnderstandingMode.diagram)
                }
                Toggle("settings.settings_root_view.keep_original_strokes_after_organizing", isOn: $preferences.preserveInkAfterConversion)
                Text("settings.settings_root_view.conversion_happens_only_when_you_tap")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("settings.settings_root_view.canvas") {
                Toggle("settings.settings_root_view.show_grid", isOn: $preferences.showGrid)
                Toggle("settings.settings_root_view.snap_to_grid", isOn: $preferences.snapToGrid)
                Toggle("settings.data_management_view.sync_canvases_across_devices", isOn: $syncEnabled)
                Text("settings.settings_root_view.turning_sync_off_only_stops_transfers")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(FloeL10n.l("settings.settings_root_view.canvas"))
        .onChange(of: preferences) { _, value in value.save() }
        .alert("settings.settings_root_view.saving_or_syncing_the_canvas_configuration", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) { Button("workspace.workspace_canvas_view.done", role: .cancel) {} } message: { Text(saveError ?? "") }
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
