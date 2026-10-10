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
    @State private var showsCatalogAdd = false
    /// Entry chosen in the catalog sheet; the editor is presented from the
    /// sheet's onDismiss so the two sheets never overlap.
    @State private var pendingCatalogSelection: ProviderCatalogEntry?

    /// Optional validated catalog plus refresh closure. Both stay nil for
    /// call sites that only support manual provider setup.
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCatalogAdd = true
                } label: {
                    Label("providers.add_from_catalog", systemImage: "books.vertical")
                }
                .disabled(catalog == nil)
                .accessibilityIdentifier("providers.add_from_catalog")
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .confirmationDialog("providers.provider_list_view.add_model_provider", isPresented: $showsProviderTypePicker) {
            if catalog != nil {
                // Discovery lives in the same catalog sheet as the toolbar
                // route; no second editor is created.
                Button("providers.add_from_catalog") { showsCatalogAdd = true }
                    .accessibilityIdentifier("providers.add_from_catalog.menu")
            }
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
                    initialCatalogEntry: route.catalogEntry
                )
            }
            .presentationSizing(.page)
        }
        .sheet(isPresented: $showsCatalogAdd, onDismiss: {
            // Hop once so the editor sheet presents after the catalog sheet
            // has fully finished dismissing.
            Task { @MainActor in presentPendingCatalogSelection() }
        }) {
            if let catalog {
                ProviderCatalogAddView(
                    catalog: catalog,
                    configuredPresetIDs: Set(
                        viewModel.center.configuredProviders.compactMap(\.presetID)
                    ),
                    onRefresh: onRefreshCatalog,
                    onSelect: { entry in
                        pendingCatalogSelection = entry
                        showsCatalogAdd = false
                    }
                )
                // Page-sized presentation (same as the editor sheet) keeps
                // search and filters visible instead of a compact sheet
                // dominated by the keyboard.
                .presentationSizing(.page)
            }
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

    // MARK: - Catalog selection

    /// Presents the editor for the catalog entry chosen in the sheet. An
    /// existing provider with the same presetID or normalized base-URL host
    /// is edited instead, so saved credentials and models are never
    /// duplicated or overwritten by a catalog add.
    private func presentPendingCatalogSelection() {
        guard let entry = pendingCatalogSelection else { return }
        pendingCatalogSelection = nil
        if let existing = existingProvider(for: entry) {
            presentedEditor = .existing(
                existing,
                ProviderServiceRole.infer(
                    from: viewModel.center.configuredModelsByProvider[existing.id] ?? []
                )
            )
        } else {
            presentedEditor = .newFromCatalog(entry, Self.serviceRole(for: entry))
        }
    }

    private func existingProvider(for entry: ProviderCatalogEntry) -> ProviderProfile? {
        if let match = viewModel.center.configuredProviders.first(where: {
            $0.presetID == entry.presetID
        }) {
            return match
        }
        guard let host = Self.normalizedHost(entry.baseURL) else { return nil }
        return viewModel.center.configuredProviders.first(where: {
            Self.normalizedHost($0.baseURL) == host
        })
    }

    private static func normalizedHost(_ url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Google Gemini entries are image-only in Floe; every other catalog
    /// entry starts as a conversation provider.
    private static func serviceRole(for entry: ProviderCatalogEntry) -> ProviderServiceRole {
        entry.kind == .googleGemini ? .image : .conversation
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
    case newFromCatalog(ProviderCatalogEntry, ProviderServiceRole)

    var id: String {
        switch self {
        case .new(let role): "new-\(role.rawValue)"
        case .existing(let provider, let role): "\(provider.id.uuidString)-\(role.rawValue)"
        case .newFromCatalog(let entry, let role):
            "catalog-\(entry.presetID)-\(role.rawValue)"
        }
    }

    var provider: ProviderProfile? {
        if case .existing(let provider, _) = self { return provider }
        return nil
    }

    var role: ProviderServiceRole? {
        switch self {
        case .new(let role), .existing(_, let role), .newFromCatalog(_, let role): role
        }
    }

    var catalogEntry: ProviderCatalogEntry? {
        if case .newFromCatalog(let entry, _) = self { return entry }
        return nil
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
