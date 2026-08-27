// FloeApp — Optional first-run provider and model setup wizard.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome, features, provider, connection, discovery, capabilities, summary

        var title: LocalizedStringKey {
            switch self {
            case .welcome: "setup.step.welcome"
            case .features: "setup.step.features"
            case .provider: "setup.step.provider"
            case .connection: "setup.step.connection"
            case .discovery: "setup.step.models"
            case .capabilities: "setup.step.capabilities"
            case .summary: "setup.step.summary"
            }
        }
    }

    @StateObject private var viewModel: OnboardingViewModel
    @StateObject private var editor: ProviderEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    @State private var editingModel: ModelProfile?
    @State private var manualRemoteID = ""
    @State private var manualDisplayName = ""

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(center: center))
        _editor = StateObject(wrappedValue: ProviderEditorViewModel(
            center: center,
            existing: center.providers.first
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                navigationBar
            }
            .background(FloeTheme.groupedSurface)
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("setup.skip") { skip() }
                        .accessibilityIdentifier("setup.skip")
                }
            }
            .task {
                await viewModel.load()
                await editor.load()
            }
            .sheet(item: $editingModel) { model in
                ModelEditorView(
                    model: model,
                    isDefault: editor.defaultModelID == model.id,
                    onMakeDefault: { editor.setDefaultModel(model.id) }
                ) { editor.updateModel($0) }
            }
        }
    }

    private var progress: some View {
        ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
            .tint(FloeTheme.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .accessibilityLabel("setup.progress")
            .accessibilityValue("\(step.rawValue + 1)/\(Step.allCases.count)")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .features: featuresStep
        case .provider: providerStep
        case .connection: connectionStep
        case .discovery: discoveryStep
        case .capabilities: capabilitiesStep
        case .summary: summaryStep
        }
    }

    private var welcomeStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(FloeTheme.brandGradient).frame(width: 82, height: 82)
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 42, weight: .medium)).foregroundStyle(.white)
                }
                VStack(spacing: 8) {
                    Text("onboarding.title").font(.largeTitle.bold())
                    Text("onboarding.subtitle")
                        .font(FloeTheme.Typography.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 16) {
                    onboardingPoint("cloud.sun", "setup.point.cloud_or_local")
                    Divider()
                    onboardingPoint("switch.2", "setup.point.progressive")
                    Divider()
                    onboardingPoint("gearshape.2", "setup.point.change_anytime")
                }
                .padding(20)
                .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 22))
            }
            .frame(maxWidth: 560)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private func onboardingPoint(_ icon: String, _ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(.primary)
    }

    private var featuresStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("setup.features.intro")
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                setupFeature(
                    "cloud.sun",
                    title: "setup.features.models.title",
                    detail: "setup.features.models.detail"
                )
                setupFeature(
                    "eye.trianglebadge.exclamationmark",
                    title: "setup.features.auxiliary.title",
                    detail: "setup.features.auxiliary.detail"
                )
                setupFeature(
                    "network",
                    title: "setup.features.connections.title",
                    detail: "setup.features.connections.detail"
                )
                setupFeature(
                    "externaldrive.connected.to.line.below",
                    title: "setup.features.workspaces.title",
                    detail: "setup.features.workspaces.detail"
                )
                setupFeature(
                    "square.and.pencil",
                    title: "setup.features.canvas.title",
                    detail: "setup.features.canvas.detail"
                )
                setupFeature(
                    "checkmark.shield",
                    title: "setup.features.safety.title",
                    detail: "setup.features.safety.detail"
                )
                setupFeature(
                    "pip",
                    title: "setup.features.background.title",
                    detail: "setup.features.background.detail"
                )
                setupFeature(
                    "chart.bar.doc.horizontal",
                    title: "setup.features.operations.title",
                    detail: "setup.features.operations.detail"
                )

                Label("setup.features.local_hint", systemImage: "info.circle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("setup.features")
    }

    private func setupFeature(
        _ icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(FloeTheme.primary)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var providerStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(ProviderPreset.chatPresets) { preset in
                    Button { editor.applyPreset(preset) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: providerIcon(preset.kind))
                                .font(.title2).foregroundStyle(FloeTheme.primary)
                                .frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.displayName).font(.headline)
                                Text(protocolSummary(preset.supportedProtocols))
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: editor.selectedPreset.id == preset.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(editor.selectedPreset.id == preset.id
                                                 ? FloeTheme.primary : .secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(editor.selectedPreset.id == preset.id
                                        ? FloeTheme.primary.opacity(0.7) : Color.primary.opacity(0.08))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 620)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var connectionStep: some View {
        Form {
            Section("providers.protocol") {
                Picker("providers.protocol", selection: $editor.selectedProtocol) {
                    ForEach(editor.availableProtocols, id: \.self) {
                        Text(protocolName($0)).tag($0)
                    }
                }
                .disabled(editor.availableProtocols.count == 1)
            }
            Section("providers.endpoint") {
                TextField("providers.base_url", text: $editor.baseURLString)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("providers.headers_placeholder", text: $editor.nonSecretHeadersText, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never)
                if URL(string: editor.baseURLString)?.scheme == "http" {
                    Toggle("providers.allow_plain_http", isOn: $editor.allowsPlainHTTP)
                }
            }
            Section("providers.credentials") {
                SecureField("providers.api_key", text: $editor.apiKey)
                    .textInputAutocapitalization(.never)
                Toggle("providers.sync_keychain", isOn: $editor.syncEnabled)
            }
            if case .failed(let message) = editor.testState {
                Section { Text(message).foregroundStyle(FloeTheme.destructive) }
            }
        }
        .formStyle(.grouped)
    }

    private var discoveryStep: some View {
        List {
            if editor.candidateModels.isEmpty {
                ContentUnavailableView(
                    "setup.models.none",
                    systemImage: "magnifyingglass",
                    description: Text("setup.models.none.hint")
                )
            } else {
                Section("setup.models.available") {
                    ForEach(editor.candidateModels) { model in
                        Button { editor.toggleSelection(model.id) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                    Text(model.remoteModelID)
                                        .font(FloeTheme.Typography.evidence).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: editor.selectedModelIDs.contains(model.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(editor.selectedModelIDs.contains(model.id)
                                                     ? FloeTheme.primary : .secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section("setup.models.manual") {
                TextField("model.remote_id", text: $manualRemoteID).textInputAutocapitalization(.never)
                TextField("setup.models.display_name_optional", text: $manualDisplayName)
                Button("providers.add_model") {
                    editor.addManualModel(remoteID: manualRemoteID, displayName: manualDisplayName)
                    manualRemoteID = ""
                    manualDisplayName = ""
                }
                .disabled(manualRemoteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var capabilitiesStep: some View {
        List {
            Section {
                Text("setup.capabilities.hint")
                    .font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
            }
            Section("setup.models.selected") {
                ForEach(editor.selectedModels) { model in
                    HStack {
                        Button { editingModel = model } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName)
                                Text(capabilitySummary(model.capabilities))
                                    .font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { editor.setDefaultModel(model.id) } label: {
                            Image(systemName: editor.defaultModelID == model.id
                                  ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(editor.defaultModelID == model.id
                                            ? "model.default" : "model.set_default")
                    }
                }
            }
        }
    }

    private var summaryStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64)).foregroundStyle(FloeTheme.success)
                Text("setup.summary.ready").font(.title.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Label(editor.selectedPreset.displayName, systemImage: "network")
                    Label(protocolName(editor.selectedProtocol), systemImage: "point.3.connected.trianglepath.dotted")
                    Label {
                        HStack(spacing: 4) {
                            Text(editor.selectedModels.count.formatted())
                            Text("setup.summary.models_selected")
                        }
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    if let id = editor.defaultModelID,
                       let model = editor.selectedModels.first(where: { $0.id == id }) {
                        Label {
                            HStack(spacing: 4) {
                                Text("model.default")
                                Text("· \(model.displayName)")
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 520, alignment: .leading)
                .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 8) {
                    Text("setup.summary.next_steps")
                        .font(.headline)
                    Label("setup.summary.auxiliary", systemImage: "eye")
                    Label("setup.summary.apple_search", systemImage: "apple.logo")
                    Label("setup.summary.remote_background", systemImage: "server.rack")
                    Label("setup.summary.canvas_mcp", systemImage: "square.and.pencil")
                    Label("setup.summary.sync_diagnostics", systemImage: "stethoscope")
                }
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: 520, alignment: .leading)
                .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var navigationBar: some View {
        HStack {
            if step != .welcome {
                Button("action.back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            Button(step == .summary ? "setup.finish" : step == .connection ? "setup.test_continue" : "setup.continue") {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || editor.testState == .testing || editor.isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(FloeTheme.chromeMaterial)
    }

    private var canContinue: Bool {
        switch step {
        case .discovery: !editor.selectedModels.isEmpty
        case .capabilities: editor.defaultModelID != nil
        default: true
        }
    }

    private func advance() {
        Task {
            if step == .connection {
                await editor.testConnection()
                guard case .succeeded = editor.testState else { return }
            }
            if step == .discovery, editor.defaultModelID == nil {
                editor.defaultModelID = editor.selectedModels.first?.id
            }
            if step == .summary {
                if await editor.save() { dismiss() }
            } else {
                step = Step(rawValue: step.rawValue + 1) ?? .summary
            }
        }
    }

    private func skip() {
        Task {
            await viewModel.markSkipped()
            dismiss()
        }
    }

    private func providerIcon(_ kind: ProviderKind) -> String {
        switch kind {
        case .openAI: "sparkles"
        case .anthropic: "a.circle"
        case .volcengineArk: "flame"
        case .alibabaStudio: "cloud"
        case .googleGemini: "photo.on.rectangle.angled"
        case .local: "iphone"
        case .custom: "slider.horizontal.3"
        }
    }

    private func protocolName(_ value: ModelProtocol) -> String {
        switch value {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }

    private func protocolSummary(_ values: [ModelProtocol]) -> String {
        values.map(protocolName).joined(separator: " · ")
    }

    private func capabilitySummary(_ value: ModelCapabilities) -> String {
        var items = ["Text"]
        if value.contains(.vision) { items.append("Vision") }
        if value.contains(.tools) { items.append("Tools") }
        if value.contains(.approval) { items.append("Approval") }
        return items.joined(separator: " · ")
    }
}
#endif
