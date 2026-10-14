// FloeApp — Provider list.
//
// SPDX-License-Identifier: MPL-2.0
//
// Lists configured providers with model counts and honest secret-sync
// state (including `.waitingForSecret`). Push to the editor to add or
// edit. Secrets never appear here — only sync status.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders
import FloeSyncCore

/// The Providers screen (under More, and surfaced in onboarding).
struct ProviderListView: View {
    @StateObject private var viewModel: ProviderListViewModel
    @State private var presentedEditor: ProviderEditorRoute?
    @State private var showsProviderTypePicker = false

    /// Optional validated catalog plus refresh closure. Both stay nil for
    /// call sites that only support manual provider setup. When present the
    /// catalog search lives inside the editor's provider-field section; there
    /// is deliberately no independent catalog page or top-level route.
    private let catalog: ProviderCatalogIndex?
    private let onRefreshCatalog: (() async -> Void)?

    init(
        center: ConversationCenter,
        catalog: ProviderCatalogIndex? = nil,
        onRefreshCatalog: (() async -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: ProviderListViewModel(center: center))
        self.catalog = catalog
        self.onRefreshCatalog = onRefreshCatalog
    }

    var body: some View {
        Group {
            if viewModel.providers.isEmpty
                && viewModel.imageProviders.isEmpty
                && viewModel.videoProviders.isEmpty
                && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("more.providers", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("empty.providers")
                }
            } else {
                providerList
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("more.providers")
        .toolbar {
            // Single Add entry point: the catalog search is embedded in the
            // editor's provider-field section, so there is no separate
            // top-level "from catalog" route.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsProviderTypePicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("providers.add")
                .accessibilityIdentifier("providers.add")
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .confirmationDialog("providers.provider_list_view.add_model_provider", isPresented: $showsProviderTypePicker) {
            Button("providers.provider_list_view.chat_model_provider") { presentedEditor = .new(.conversation) }
            Button("providers.provider_list_view.image_generation_editing_provider") { presentedEditor = .new(.image) }
            Button("providers.provider_list_view.video_generation_provider") { presentedEditor = .new(.video) }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
        } message: {
            Text("providers.provider_list_view.choose_a_use_first_then_configure")
        }
        .sheet(item: $presentedEditor, onDismiss: {
            Task { await viewModel.load() }
        }) { route in
            NavigationStack {
                ProviderEditorView(
                    center: viewModel.center,
                    existing: route.provider,
                    initialRole: route.role,
                    catalog: catalog,
                    onRefreshCatalog: onRefreshCatalog
                )
            }
            .presentationSizing(.page)
        }
        .alert(
            "providers.delete_failed",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("action.done") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var providerList: some View {
        List {
            if viewModel.remoteSyncRejectionCount > 0 {
                Section {
                    Label("providers.sync.rejected_remote", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(FloeTheme.pending)
                        .accessibilityIdentifier("providers.sync.rejectedRemote")
                    Button {
                        Task { await viewModel.retryRejectedRemoteSync() }
                    } label: {
                        if viewModel.isRetryingRemoteSync {
                            ProgressView()
                        } else {
                            Text("settings.sync.now")
                        }
                    }
                    .disabled(viewModel.isRetryingRemoteSync)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("providers.sync.retryRejectedRemote")
                } footer: {
                    Text("providers.sync.rejected_remote.footer")
                }
            }
            Section("providers.provider_list_view.chat_model_provider") {
                ForEach(viewModel.providers) { provider in
                    providerButton(
                        provider,
                        role: .conversation,
                        modelCount: viewModel.modelCount(for: provider.id)
                    )
                }
            }

            if !viewModel.imageProviders.isEmpty {
                Section {
                    ForEach(viewModel.imageProviders) { provider in
                        providerButton(
                            provider,
                            role: .image,
                            modelCount: viewModel.imageModelCount(for: provider.id)
                        )
                    }
                } header: {
                    Text("providers.provider_list_view.image_model_provider")
                } footer: {
                    Text("providers.provider_list_view.used_for_image_generation_and_editing")
                }
            }

            if !viewModel.videoProviders.isEmpty {
                Section {
                    ForEach(viewModel.videoProviders) { provider in
                        providerButton(
                            provider,
                            role: .video,
                            modelCount: viewModel.videoModelCount(for: provider.id)
                        )
                    }
                } header: {
                    Text("providers.provider_list_view.video_model_provider")
                } footer: {
                    Text("providers.provider_list_view.video_is_an_optional_enhancement_in")
                }
            }

            if let catalog, onRefreshCatalog != nil {
                Section {
                    Button {
                        Task {
                            await onRefreshCatalog?()
                            await viewModel.load()
                        }
                    } label: {
                        Label("providers.catalog.refresh", systemImage: "arrow.clockwise")
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("providers.catalog.refresh")
                } header: {
                    Text("providers.catalog.official")
                } footer: {
                    Text(FloeL10n.l(
                        "providers.catalog.official_footer",
                        catalog.document.source.project,
                        catalog.all.count
                    ))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func providerButton(
        _ provider: ProviderProfile,
        role: ProviderServiceRole,
        modelCount: Int
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                presentedEditor = .existing(provider, role)
            } label: {
                ProviderRow(
                    provider: provider,
                    modelCount: modelCount,
                    status: viewModel.status(for: provider.id)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            Toggle("providers.enabled", isOn: Binding(
                get: { provider.isEnabled },
                set: { enabled in
                    Task { await viewModel.setEnabled(enabled, provider: provider) }
                }
            ))
            .labelsHidden()
            .tint(FloeTheme.primary)
            .accessibilityIdentifier("providers.enabled.\(provider.id.uuidString)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                presentedEditor = .existing(provider, role)
            } label: {
                Label("workspace.workspace_canvas_view.edit", systemImage: "pencil")
            }
            .tint(.blue)
            Button(role: .destructive) {
                Task { await viewModel.delete(provider) }
            } label: {
                Label("workspace.workspace_canvas_view.delete", systemImage: "trash")
            }
        }
    }
}

private enum ProviderEditorRoute: Identifiable {
    case new(ProviderServiceRole)
    case existing(ProviderProfile, ProviderServiceRole)

    var id: String {
        switch self {
        case .new(let role): "new-\(role.rawValue)"
        case .existing(let provider, let role): "\(provider.id.uuidString)-\(role.rawValue)"
        }
    }

    var provider: ProviderProfile? {
        if case .existing(let provider, _) = self { return provider }
        return nil
    }

    var role: ProviderServiceRole? {
        switch self {
        case .new(let role), .existing(_, let role): role
        }
    }
}

/// One provider row: kind, base URL, model count, secret-sync status.
private struct ProviderRow: View {
    let provider: ProviderProfile
    let modelCount: Int
    let status: SyncStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(presetName)
                    .font(FloeTheme.Typography.body)
                Spacer()
                if status == .waitingForSecret {
                    Label("providers.waiting_secret", systemImage: "key.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                }
                if !provider.isEnabled {
                    Text("providers.provider_list_view.disabled")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            Text(provider.baseURL.absoluteString)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(modelCount) " + String(localized: "providers.models"))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .frame(minHeight: FloeTheme.minimumTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var presetName: String {
        provider.displayName ?? ProviderPreset.preset(for: provider.kind).displayName
    }
}
#endif
