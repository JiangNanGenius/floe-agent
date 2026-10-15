// FloeApp — Provider editor.
//
// SPDX-License-Identifier: MPL-2.0
//
// Add/edit a provider: preset picker, base URL, API key (Keychain-only),
// non-secret headers, plain-HTTP acknowledgement, iCloud Keychain sync
// toggle, Test connection with model discovery, and a manual-model
// fallback editor. Shows `.waitingForSecret` honestly when configuration
// synced but the secret hasn't.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

/// The provider editor form.
struct ProviderEditorView: View {
    @StateObject private var viewModel: ProviderEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showModelPicker = false
    @State private var editingModel: ModelProfile?
    @State private var showsCatalogPicker = false
    /// Distinct-connection offer opened as its own visible editor (different
    /// endpoint/auth): never merged into this provider's connection.
    @State private var separateOfferRoute: SeparateOfferRoute?
    private let catalog: ProviderCatalogIndex?
    private let onRefreshCatalog: (() async -> Void)?

    init(
        center: ConversationCenter,
        existing: ProviderProfile?,
        initialRole: ProviderServiceRole? = nil,
        initialCatalogEntry: ProviderCatalogEntry? = nil,
        catalog: ProviderCatalogIndex? = nil,
        onRefreshCatalog: (() async -> Void)? = nil,
        serviceOfferEndpointOverride: URL? = nil,
        serviceOfferSeedModels: [String] = []
    ) {
        _viewModel = StateObject(
            wrappedValue: ProviderEditorViewModel(
                center: center,
                existing: existing,
                initialRole: initialRole,
                catalogEntry: initialCatalogEntry,
                catalog: catalog,
                serviceOfferEndpointOverride: serviceOfferEndpointOverride,
                serviceOfferSeedModels: serviceOfferSeedModels
            )
        )
        self.catalog = catalog
        self.onRefreshCatalog = onRefreshCatalog
    }

    var body: some View {
        Form {
            Section("providers.provider_editor_view.service_purpose") {
                Label(viewModel.serviceRole.title, systemImage: viewModel.serviceRole.icon)
                if viewModel.serviceRole == .video {
                    Text("providers.provider_editor_view.video_models_are_an_optional_enhancement")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            presetSection
            serviceOffersSection
            protocolSection
            endpointSection
            credentialsSection
            compatibilitySection
            syncSection
            testSection
            modelsSection
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                }
            }
            if viewModel.lastSaveSyncPending {
                Section {
                    Label("providers.save.saved_local_sync_pending", systemImage: "icloud.slash")
                        .foregroundStyle(FloeTheme.pending)
                        .accessibilityIdentifier("providers.save.syncPending")
                    if let detail = viewModel.lastSaveSyncError, !detail.isEmpty {
                        Text(detail)
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await viewModel.retrySync() }
                    } label: {
                        if viewModel.isRetryingSync {
                            ProgressView()
                        } else {
                            Text("providers.save.retry_sync")
                        }
                    }
                    .disabled(viewModel.isRetryingSync)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("providers.save.retrySync")
                    Button("providers.save.done") { dismiss() }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("providers.save.doneAfterPending")
                } footer: {
                    Text("providers.save.saved_local_sync_pending.footer")
                }
            }
        }
        .navigationTitle(viewModel.existing == nil
            ? LocalizedStringKey("providers.add")
            : LocalizedStringKey("providers.edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("action.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { save() } label: {
                    if viewModel.isSaving {
                        // Visible in-flight state so repeated taps are
                        // discouraged and the user sees the write running.
                        ProgressView()
                    } else {
                        Text("action.save")
                    }
                }
                    .disabled(viewModel.isSaving)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("action.save")
            }
        }
        // A save failure is shown immediately regardless of form scroll
        // position (the inline section at the bottom could be off-screen).
        // Only a Save-path error opens this alert; connection-test and
        // discovery failures keep their inline context.
        .alert(
            "providers.save_failed",
            isPresented: Binding(
                get: { viewModel.saveErrorMessage != nil },
                set: { presented in if !presented { viewModel.saveErrorMessage = nil } }
            )
        ) {
            Button("providers.save_failed.ok", role: .cancel) {}
        } message: {
            Text(viewModel.saveErrorMessage ?? "")
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(viewModel: viewModel)
        }
        .sheet(item: $editingModel) { model in
            ModelEditorView(
                model: model,
                serviceRole: viewModel.serviceRole,
                isDefault: viewModel.defaultModelID == model.id,
                onMakeDefault: { viewModel.setDefaultModel(model.id) }
            ) { updated in viewModel.updateModel(updated) }
        }
        .sheet(item: $separateOfferRoute) { route in
            NavigationStack {
                ProviderEditorView(
                    center: viewModel.center,
                    existing: nil,
                    initialRole: route.role,
                    initialCatalogEntry: route.entry,
                    catalog: catalog,
                    onRefreshCatalog: onRefreshCatalog,
                    serviceOfferEndpointOverride: route.endpoint,
                    serviceOfferSeedModels: route.models
                )
            }
            .presentationSizing(.page)
        }
        // One-time native confirmation after selecting a multi-role vendor.
        // A dismissal that is not a confirmation records the decline.
        .sheet(item: $viewModel.pendingServiceOfferPrompt, onDismiss: {
            viewModel.dismissServiceOfferPrompt()
        }) { prompt in
            ServiceOfferPromptSheet(
                prompt: prompt,
                onConfirm: { viewModel.confirmServiceOfferSelection($0) },
                onDecline: { viewModel.declineServiceOfferPrompt() }
            )
        }
    }

    private var protocolSection: some View {
        Section("providers.protocol") {
            Picker("providers.protocol", selection: $viewModel.selectedProtocol) {
                ForEach(viewModel.availableProtocols, id: \.self) { protocolKind in
                    Text(protocolKind.displayName).tag(protocolKind)
                }
            }
            .disabled(viewModel.availableProtocols.count == 1)
        }
    }

    // MARK: - Preset

    private var presetSection: some View {
        Section {
            Toggle("providers.enabled", isOn: $viewModel.enabled)
            TextField("providers.display_name", text: $viewModel.displayName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("providers.display_name")
            // ONE unified supplier field: tapping the field itself opens the
            // searchable selector where the built-in presets and the verified
            // catalog entries live together (plus an explicit manual/custom
            // choice). There is deliberately no separate preset picker row and
            // no "add from catalog" button/page.
            Button {
                showsCatalogPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text("providers.supplier_field")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(viewModel.selectedPreset.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("providers.supplier_field")
            .popover(isPresented: $showsCatalogPicker) {
                ProviderCatalogPicker(
                    presets: viewModel.availablePresets,
                    selectedPresetID: viewModel.selectedPreset.id,
                    catalog: catalog,
                    configuredPresetIDs: Set(
                        viewModel.center.configuredProviders.compactMap(\.presetID)
                    ),
                    onRefresh: onRefreshCatalog,
                    onSelect: { entry in
                        viewModel.applyCatalogEntry(entry)
                        showsCatalogPicker = false
                    },
                    onSelectPreset: { preset in
                        viewModel.applyPreset(preset)
                        viewModel.supplierSelectionDidComplete()
                        showsCatalogPicker = false
                    }
                )
                // A List/NavigationStack has no intrinsic popover size; an
                // explicit compact-pad frame keeps the search field and rows
                // visible (the iPhone adaptation presents a sheet and fills
                // it). `.presentationSizing(.page)` alone collapsed the
                // popover to ~68pt in the Simulator.
                .frame(minWidth: 420, idealWidth: 520, minHeight: 540, idealHeight: 680)
                .presentationSizing(.page)
            }
        }
    }

    // MARK: - Optional additional service roles

    /// Inline status ONLY: undecided roles never appear here (they are raised
    /// once through the transient confirmation sheet). This section shows the
    /// roles already opted into, their discovery progress/errors, and declared
    /// offers that cannot share this connection.
    @ViewBuilder
    private var serviceOffersSection: some View {
        let visible = viewModel.serviceOffers.filter { offer in
            offer.isEnabled
                || !offer.isUsable
                || offer.connection == .distinct
                || viewModel.serviceOfferDiscoveryState[offer.role] != nil
        }
        if !visible.isEmpty {
            Section {
                ForEach(visible) { offer in
                    serviceOfferRow(offer)
                }
            } header: {
                Text("providers.service_offers.title")
            } footer: {
                Text("providers.service_offers.footer")
            }
        }
    }

    @ViewBuilder
    private func serviceOfferRow(_ offer: ProviderServiceOfferState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if offer.isUsable, offer.connection == .shared {
                Toggle(isOn: Binding(
                    get: { offer.isEnabled },
                    set: { viewModel.setServiceOfferEnabled(offer.role, isEnabled: $0) }
                )) {
                    HStack {
                        Label(offer.role.title, systemImage: offer.role.icon)
                        if case .testing = viewModel.serviceOfferDiscoveryState[offer.role] {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .tint(FloeTheme.primary)
                .disabled(viewModel.serviceOfferDiscoveryState[offer.role] == .testing)
                .accessibilityIdentifier("providers.service_offers.\(offer.role.rawValue)")
                if !offer.models.isEmpty {
                    Text(FloeL10n.l("providers.service_offers.model_count", offer.models.count))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                if let error = viewModel.serviceOfferDiscoveryError[offer.role], !error.isEmpty {
                    Text(error)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                }
            } else {
                Label(offer.role.title, systemImage: offer.role.icon)
                    .foregroundStyle(.secondary)
                if let reason = offer.reason {
                    Text(reason)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                }
                if offer.isUsable, offer.connection == .distinct, catalog != nil,
                   let entry = viewModel.catalogEntryForSeparateOffer {
                    // Different endpoint/auth: visible distinct settings, not a
                    // shared credential.
                    Button("providers.service_offers.configure_separately") {
                        separateOfferRoute = SeparateOfferRoute(
                            entry: entry,
                            role: offer.role,
                            endpoint: offer.endpoint,
                            models: offer.models
                        )
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("providers.service_offers.separate.\(offer.role.rawValue)")
                }
            }
            if let note = offer.note, !note.isEmpty {
                Text(note)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Native, transient one-time confirmation raised after selecting a
    /// multi-role vendor: the initiating role is fixed, extras are opt-in.
    private struct ServiceOfferPromptSheet: View {
        let prompt: ProviderServiceOfferPrompt
        let onConfirm: (Set<ProviderServiceRole>) -> Void
        let onDecline: () -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var selectedRoles: Set<ProviderServiceRole> = []

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Label(
                            FloeL10n.l("providers.service_offers.current_role", prompt.primaryRole.title),
                            systemImage: prompt.primaryRole.icon
                        )
                        .foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(prompt.offers) { offer in
                            Toggle(isOn: Binding(
                                get: { selectedRoles.contains(offer.role) },
                                set: { enabled in
                                    if enabled { selectedRoles.insert(offer.role) }
                                    else { selectedRoles.remove(offer.role) }
                                }
                            )) {
                                Label(offer.role.title, systemImage: offer.role.icon)
                            }
                            .tint(FloeTheme.primary)
                            .accessibilityIdentifier("providers.service_offers.prompt.\(offer.role.rawValue)")
                            if offer.requiresDiscovery {
                                Text("providers.service_offers.requires_discovery")
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            } else if !offer.models.isEmpty {
                                Text(FloeL10n.l("providers.service_offers.model_count", offer.models.count))
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("providers.service_offers.footer")
                    }
                }
                .navigationTitle("providers.service_offers.additional_uses")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("providers.service_offers.not_now") {
                            onDecline()
                            dismiss()
                        }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("providers.service_offers.not_now")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("providers.service_offers.configure") {
                            onConfirm(selectedRoles)
                            dismiss()
                        }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("providers.service_offers.confirm")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Endpoint

    private var endpointSection: some View {
        Section {
            TextField("providers.base_url", text: $viewModel.baseURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(FloeTheme.Typography.evidence)
            TextField("providers.headers_placeholder", text: $viewModel.nonSecretHeadersText, axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .font(FloeTheme.Typography.evidence)
            if viewModel.selectedPreset.defaultBaseURL.scheme == "http" {
                Toggle("providers.allow_plain_http", isOn: $viewModel.allowsPlainHTTP)
            }
        } header: {
            Text("providers.endpoint")
        } footer: {
            Text("providers.headers_hint")
        }
    }

    // MARK: - Credentials (Keychain only)

    private var credentialsSection: some View {
        Section {
            HStack {
                if viewModel.showingAPIKey {
                    TextField("providers.api_key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("providers.api_key")
                } else {
                    SecureField("providers.api_key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("providers.api_key")
                }
                Button {
                    if viewModel.showingAPIKey {
                        viewModel.showingAPIKey = false
                    } else {
                        Task { await viewModel.authenticateAndRevealAPIKey() }
                    }
                } label: {
                    Image(systemName: viewModel.showingAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.showingAPIKey ? "providers.provider_editor_view.hide_api_key" : "providers.provider_editor_view.show_api_key")
            }
            if viewModel.secretStatus == .waitingForSecret {
                Label("providers.waiting_secret.hint", systemImage: "key.fill")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
            }
            if let message = viewModel.connectionCredentialRequirementMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
                    .accessibilityIdentifier("providers.validation.endpointChanged")
            }
        } header: {
            Text("providers.credentials")
        } footer: {
            Text("providers.api_key.hint")
        }
    }

    // MARK: - Compatibility

    /// Some providers (DeepSeek, certain gateways) reject tool names with
    /// dots (`workspace.createFile`). This toggle converts tool names to
    /// underscores (`workspace_createFile`) for this provider only.
    private var compatibilitySection: some View {
        Section {
            Toggle("providers.tool_name_compatibility", isOn: $viewModel.toolNameCompatibility)
        } footer: {
            Text("providers.tool_name_compatibility.hint")
        }
    }

    // MARK: - iCloud Keychain sync

    private var syncSection: some View {
        Section {
            Toggle("providers.sync_keychain", isOn: $viewModel.syncEnabled)
        } footer: {
            Text("providers.sync_keychain.hint")
        }
    }

    // MARK: - Test connection

    private var testSection: some View {
        Section {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    Text("providers.test_connection")
                    Spacer()
                    switch viewModel.testState {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                    case .succeeded(let count):
                        Label(
                            String(localized: "providers.test_ok") + " (\(count))",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(FloeTheme.success)
                    case .failed:
                        Label("providers.test_failed", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(FloeTheme.destructive)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }
            .disabled(viewModel.testState == .testing)
            .accessibilityIdentifier("providers.test_connection")
            if case .failed(let message) = viewModel.testState {
                Text(message)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.destructive)
            }
        }
    }

    // MARK: - Models (discovered + manual fallback)

    private var modelsSection: some View {
        Section {
            if viewModel.selectedModels.isEmpty {
                Text("providers.no_models")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.selectedModels) { model in
                    modelRow(model)
                }
            }
            Button("providers.manage_models") { showModelPicker = true }
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("providers.manage_models")
            if viewModel.supportsDiscovery {
                Button {
                    Task { await viewModel.refreshModels() }
                } label: {
                    Label("providers.refresh_models", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.testState == .testing)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("providers.refresh_models")
            }
        } header: {
            Text("providers.models_section")
        } footer: {
            // The "not supported" footer is shown only when the endpoint
            // genuinely lacks discovery; discovered endpoints get the neutral
            // manual-add hint instead (model picker keeps both paths).
            if !viewModel.supportsDiscovery {
                Text("providers.manual_fallback.hint")
            } else {
                Text("providers.manual_entry.hint")
            }
        }
    }

    private func modelRow(_ model: ModelProfile) -> some View {
        HStack {
            Button {
                editingModel = model
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(FloeTheme.Typography.body)
                        Text(model.remoteModelID)
                            .font(FloeTheme.Typography.evidence)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.defaultModelID == model.id {
                        Text("model.default")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.primary)
                    }
                    if !model.isVisibleInPrimaryPicker {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("model.hidden_from_primary_picker.badge"))
                    }
                    // Per-model image input, verified by catalog metadata and
                    // actually carried by the saved row: never a provider-wide
                    // vision claim.
                    if viewModel.catalogVerifiedImageInput(for: model) {
                        Image(systemName: "photo")
                            .foregroundStyle(FloeTheme.primary)
                            .accessibilityLabel(Text("model.capability.vision"))
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Toggle("model.enabled", isOn: Binding(
                get: {
                    viewModel.candidateModels.first(where: { $0.id == model.id })?.isEnabled
                        ?? model.isEnabled
                },
                set: { viewModel.setModelEnabled(model.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .tint(FloeTheme.primary)
            .accessibilityIdentifier("providers.model.enabled.\(model.remoteModelID)")
        }
        .contextMenu {
            Button("model.set_default") { viewModel.setDefaultModel(model.id) }
            Button(model.isVisibleInPrimaryPicker
                   ? "model.hide_from_primary_picker"
                   : "model.show_in_primary_picker") {
                viewModel.setModelHiddenFromPrimaryPicker(
                    model.id,
                    isHidden: model.isVisibleInPrimaryPicker
                )
            }
        }
    }

    // MARK: - Save

    private func save() {
        Task {
            if await viewModel.save() {
                // A local commit whose CloudKit enqueue failed stays on this
                // sheet with the explicit pending banner + retry instead of
                // dismissing as an unqualified success.
                if !viewModel.lastSaveSyncPending {
                    dismiss()
                }
            }
        }
    }
}

private extension ModelProtocol {
    var displayName: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

/// A distinct-connection offer opened as its own provider editor.
private struct SeparateOfferRoute: Identifiable {
    let entry: ProviderCatalogEntry
    let role: ProviderServiceRole
    let endpoint: URL?
    /// Verified catalog identifiers pre-staged in the separate editor so the
    /// new connection is usable without local guessing.
    let models: [String]

    var id: String { "\(entry.presetID)-\(role.rawValue)" }
}
#endif
