// FloeApp — Optional first-run provider and model setup wizard.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome, provider, connection, discovery, capabilities, summary

        var title: LocalizedStringKey {
            switch self {
            case .welcome: "setup.step.welcome"
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
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
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
                    onboardingPoint("person.crop.circle.badge.checkmark", "setup.point.no_account")
                    Divider()
                    onboardingPoint("key.horizontal", "setup.point.keychain")
                    Divider()
                    onboardingPoint("rectangle.grid.2x2", "setup.point.explore")
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

    private var providerStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(ProviderPreset.all) { preset in
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
            Section("Protocol") {
                Picker("Protocol", selection: $editor.selectedProtocol) {
                    ForEach(editor.availableProtocols, id: \.self) {
                        Text(protocolName($0)).tag($0)
                    }
                }
                .disabled(editor.availableProtocols.count == 1)
            }
            Section("Endpoint") {
                TextField("Base URL", text: $editor.baseURLString)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Additional non-secret headers", text: $editor.nonSecretHeadersText, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never)
                if URL(string: editor.baseURLString)?.scheme == "http" {
                    Toggle("Allow private-network HTTP", isOn: $editor.allowsPlainHTTP)
                }
            }
            Section("Credentials") {
                SecureField("API key", text: $editor.apiKey)
                    .textInputAutocapitalization(.never)
                Toggle("Sync API key with iCloud Keychain", isOn: $editor.syncEnabled)
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
                    "No models discovered",
                    systemImage: "magnifyingglass",
                    description: Text("Add a model ID manually below.")
                )
            } else {
                Section("Available models") {
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
            Section("Add manually") {
                TextField("Model ID", text: $manualRemoteID).textInputAutocapitalization(.never)
                TextField("Display name (optional)", text: $manualDisplayName)
                Button("Add model") {
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
                Text("Each model keeps its own vision, tool, approval and token-limit settings.")
                    .font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
            }
            Section("Selected models") {
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
                                            ? "Default model" : "Set as default")
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
                Text("Your configuration is ready").font(.title.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Label(editor.selectedPreset.displayName, systemImage: "network")
                    Label(protocolName(editor.selectedProtocol), systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(editor.selectedModels.count) models selected", systemImage: "cpu")
                    if let id = editor.defaultModelID,
                       let model = editor.selectedModels.first(where: { $0.id == id }) {
                        Label("Default: \(model.displayName)", systemImage: "checkmark.circle")
                    }
                }
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
