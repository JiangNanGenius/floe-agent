// FloeApp — Add from provider catalog.
//
// SPDX-License-Identifier: MPL-2.0
//
// A searchable sheet over the bundled/verified ProviderCatalogIndex. Search is
// pure local computation on the passed index: typing never performs network
// I/O. Rows carry no credentials; selecting an available entry hands the
// catalog entry back to the caller, which owns duplicate checks and the editor
// prefill.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

/// Sheet listing official catalog providers with local search and filters.
struct ProviderCatalogAddView: View {
    let catalog: ProviderCatalogIndex
    /// presetIDs of already saved providers, used for the configured badge.
    let configuredPresetIDs: Set<String>
    /// Optional async refresh of the official catalog. Errors are owned by
    /// the caller's existing content-update error surface.
    let onRefresh: (() async -> Void)?
    /// Called for selectable rows. Unsupported rows never call this.
    let onSelect: (ProviderCatalogEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: ProviderCatalogFilter = .all
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("providers.catalog.filter_label", selection: $filter) {
                        ForEach(ProviderCatalogFilter.allCases, id: \.self) { filterKind in
                            Text(filterLabel(filterKind)).tag(filterKind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("providers.catalog.filter_label")
                    .accessibilityIdentifier("providers.catalog.filter")
                }

                Section {
                    if results.isEmpty {
                        emptyResults
                    } else {
                        ForEach(results) { entry in
                            row(entry)
                        }
                    }
                } header: {
                    catalogHeader
                } footer: {
                    catalogFooter
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("providers.catalog.title")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("providers.catalog.search_placeholder")
            )
            .accessibilityIdentifier("providers.catalog.search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("providers.catalog.cancel")
                }
                if onRefresh != nil {
                    ToolbarItem(placement: .primaryAction) {
                        refreshButton
                    }
                }
            }
        }
    }

    // MARK: - Search results (pure local)

    private var results: [ProviderCatalogEntry] {
        catalog.search(
            query: query,
            filter: filter,
            configuredPresetIDs: configuredPresetIDs
        )
    }

    // MARK: - Header / footer

    private var catalogHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("providers.catalog.official", systemImage: "books.vertical")
            Text(catalog.document.source.project)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    private var catalogFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FloeL10n.l("providers.catalog.provider_count", catalog.all.count))
            Text(FloeL10n.l("providers.catalog.document_hash", shortDocumentSHA256))
            Text(FloeL10n.l("providers.catalog.fetched_at", catalog.document.source.fetchedAt))
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(.secondary)
    }

    /// Short display form of the pinned source document hash.
    private var shortDocumentSHA256: String {
        String(catalog.document.source.documentSHA256.prefix(12))
    }

    // MARK: - Rows

    private func row(_ entry: ProviderCatalogEntry) -> some View {
        Button {
            onSelect(entry)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(FloeTheme.Typography.body)
                        .foregroundStyle(.primary)
                    if configuredPresetIDs.contains(entry.presetID) {
                        badge("providers.catalog.configured_badge", color: FloeTheme.primary)
                    }
                    if entry.availability == .unsupported {
                        badge("providers.catalog.unsupported_badge", color: .secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let alias = matchingAlias(entry) {
                    Text(FloeL10n.l("providers.catalog.alias", alias))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.primary)
                }
                HStack(spacing: 4) {
                    Text(protocolName(entry.defaultProtocol))
                    Text("·")
                    Text(ProviderPreset.preset(for: entry.kind).displayName)
                    Text("·")
                    Text(entry.baseURL?.host ?? "—")
                    Text("·")
                    Text(FloeL10n.l("providers.catalog.models_count", entry.models.count))
                }
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if entry.availability == .unsupported,
                   let reason = entry.unsupportedReason {
                    Text(reason)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                }
            }
            .padding(.vertical, 2)
            .frame(minHeight: FloeTheme.minimumTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.availability == .unsupported)
        .accessibilityIdentifier("providers.catalog.row.\(entry.presetID)")
    }

    private func badge(_ key: LocalizedStringKey, color: Color) -> some View {
        Text(key)
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var emptyResults: some View {
        ContentUnavailableView {
            Label("providers.catalog.empty_title", systemImage: "magnifyingglass")
        } description: {
            Text("providers.catalog.empty_hint")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Refresh

    private var refreshButton: some View {
        Button {
            guard !isRefreshing, let onRefresh else { return }
            isRefreshing = true
            Task {
                await onRefresh()
                isRefreshing = false
            }
        } label: {
            if isRefreshing {
                ProgressView()
                    .accessibilityLabel(Text("providers.catalog.refresh"))
            } else {
                Label("providers.catalog.refresh", systemImage: "arrow.clockwise")
            }
        }
        .disabled(isRefreshing)
        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        .accessibilityIdentifier("providers.catalog.refresh")
    }

    // MARK: - Labels

    private func filterLabel(_ filter: ProviderCatalogFilter) -> LocalizedStringKey {
        switch filter {
        case .all: "providers.catalog.filter.all"
        case .configured: "providers.catalog.filter.configured"
        case .available: "providers.catalog.filter.available"
        case .local: "providers.catalog.filter.local"
        }
    }

    private func protocolName(_ protocolKind: ModelProtocol) -> LocalizedStringKey {
        switch protocolKind {
        case .openAIResponses: "providers.catalog.protocol.openai_responses"
        case .openAIChatCompletions: "providers.catalog.protocol.openai_chat"
        case .anthropicMessages: "providers.catalog.protocol.anthropic"
        }
    }

    /// The alias that the current query matches (substring, normalized), if
    /// the match was not on the display name itself.
    private func matchingAlias(_ entry: ProviderCatalogEntry) -> String? {
        let normalized = ProviderCatalogIndex.normalized(query)
        guard !normalized.isEmpty else { return nil }
        return entry.aliases.first {
            ProviderCatalogIndex.normalized($0).contains(normalized)
        }
    }
}
#endif
