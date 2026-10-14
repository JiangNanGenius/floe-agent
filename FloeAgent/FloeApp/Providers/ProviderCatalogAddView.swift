// FloeApp — Embedded unified supplier selector.
//
// SPDX-License-Identifier: MPL-2.0
//
// ONE searchable selector for the add/edit provider form (anchored popover on
// iPad, adaptive sheet on iPhone): the built-in provider presets and the
// verified catalog entries appear in the same list, searched locally together.
// It is presented by tapping the provider/supplier FIELD itself — there is no
// separate "add from catalog" row or top-level catalog page. Search is pure
// local computation on the passed index: typing never performs network I/O.
// Rows carry no credentials; selecting hands the choice back to the editor,
// which owns duplicate checks, custom-name preservation and prefill.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

/// Compact, searchable supplier selector embedded in the provider editor.
struct ProviderCatalogPicker: View {
    /// Built-in presets valid for the editor's service role.
    let presets: [ProviderPreset]
    /// Currently selected preset (marked in the built-in section).
    let selectedPresetID: ProviderTemplateID
    /// Verified catalog index, when available. Without it the selector still
    /// offers every built-in preset.
    let catalog: ProviderCatalogIndex?
    /// presetIDs of already saved providers, used for the configured badge.
    let configuredPresetIDs: Set<String>
    /// Optional async refresh of the official catalog. Errors are owned by
    /// the caller's existing content-update error surface.
    let onRefresh: (() async -> Void)?
    /// Called for selectable catalog rows. Unsupported rows never call this.
    let onSelect: (ProviderCatalogEntry) -> Void
    /// Called for a built-in preset choice (including manual/custom).
    let onSelectPreset: (ProviderPreset) -> Void

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

                if !matchingPresets.isEmpty {
                    Section {
                        ForEach(matchingPresets) { preset in
                            presetRow(preset)
                        }
                    } header: {
                        Text("providers.supplier_picker.builtin")
                    }
                }

                if let catalog {
                    Section {
                        if results.isEmpty && matchingPresets.isEmpty {
                            emptyResults
                        } else if results.isEmpty {
                            Text("providers.supplier_picker.no_matching_catalog")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(results) { entry in
                                row(entry)
                            }
                        }
                    } header: {
                        Text("providers.catalog.official")
                    } footer: {
                        catalogFooter(catalog)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // A persistent search bar stays visible above the scrolling list,
            // so search and selection happen inside the same supplier popup.
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("providers.catalog.search_placeholder")
            )
            .accessibilityIdentifier("providers.catalog.search")
            .navigationTitle("providers.supplier_picker.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("providers.catalog.cancel")
                }
                if onRefresh != nil, catalog != nil {
                    ToolbarItem(placement: .primaryAction) {
                        refreshButton
                    }
                }
            }
        }
    }

    /// Built-in presets matching the current query by display name or host.
    /// Manual/custom stays present for an explicit, non-catalog choice.
    private var matchingPresets: [ProviderPreset] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return presets }
        let needle = ProviderCatalogIndex.normalized(trimmed)
        return presets.filter { preset in
            ProviderCatalogIndex.normalized(preset.displayName).contains(needle)
                || ProviderCatalogIndex.normalized(preset.defaultBaseURL.host ?? "").contains(needle)
        }
    }

    // MARK: - Search results (pure local)

    private var results: [ProviderCatalogEntry] {
        guard let catalog else { return [] }
        return catalog.search(
            query: query,
            filter: filter,
            configuredPresetIDs: configuredPresetIDs
        )
    }

    // MARK: - Footer

    private func catalogFooter(_ catalog: ProviderCatalogIndex) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FloeL10n.l("providers.catalog.provider_count", catalog.all.count))
            Text(FloeL10n.l("providers.catalog.document_hash", shortDocumentSHA256(catalog)))
            Text(FloeL10n.l("providers.catalog.fetched_at", catalog.document.source.fetchedAt))
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(.secondary)
    }

    /// Short display form of the pinned source document hash.
    private func shortDocumentSHA256(_ catalog: ProviderCatalogIndex) -> String {
        String(catalog.document.source.sha256Prefix)
    }

    // MARK: - Rows

    /// One built-in preset choice, marked when it is the current selection.
    private func presetRow(_ preset: ProviderPreset) -> some View {
        Button {
            onSelectPreset(preset)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.displayName)
                        .font(FloeTheme.Typography.body)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(protocolName(preset.defaultProtocol))
                        Text("·")
                        Text(preset.defaultBaseURL.host ?? "—")
                    }
                    .font(FloeTheme.Typography.evidence)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if preset.id == selectedPresetID {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FloeTheme.primary)
                }
            }
            .padding(.vertical, 2)
            .frame(minHeight: FloeTheme.minimumTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("providers.supplier.preset.\(preset.id.rawValue)")
    }

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
                if !serviceRoleLabels(entry).isEmpty {
                    Text(FloeL10n.l(
                        "providers.catalog.also_serves",
                        serviceRoleLabels(entry).joined(separator: ", ")
                    ))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.success)
                }
                if entry.availability == .unsupported,
                   let reason = entry.unsupportedReason {
                    Text(Self.localizedUnsupportedReason(reason))
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

    /// Media roles a shipped adapter can really serve for this entry, so the
    /// row shows actual capability instead of a model-name guess.
    private func serviceRoleLabels(_ entry: ProviderCatalogEntry) -> [String] {
        ProviderServiceOfferResolver.resolvedOffers(
            for: entry.kind,
            baseURL: entry.baseURL,
            authStyle: entry.authStyle,
            availability: entry.availability,
            declared: entry.serviceOffers
        )
        .filter(\.isUsable)
        .map {
            switch $0.role {
            case .conversation: FloeL10n.l("providers.provider_service_role.chat_model")
            case .image: FloeL10n.l("providers.provider_service_role.image_generation_and_editing")
            case .video: FloeL10n.l("providers.provider_service_role.video_generation_extra")
            }
        }
    }

    /// Known capability-failure reasons map to localized strings (matched on
    /// stable tokens so minor catalog wording edits do not break the mapping);
    /// unknown reasons stay readable through a localized wrapper with the
    /// raw detail, never a bare English string.
    static func localizedUnsupportedReason(_ reason: String) -> String {
        let normalized = reason.lowercased()
        let key: String
        if normalized.contains("oauth device flow") {
            key = "providers.catalog.unsupported.oauth_device_flow"
        } else if normalized.contains("deployment-specific endpoint") || normalized.contains("api-version") {
            key = "providers.catalog.unsupported.deployment_endpoint"
        } else if normalized.contains("sigv4") {
            key = "providers.catalog.unsupported.sigv4"
        } else if normalized.contains("service-account") || normalized.contains("service account") {
            key = "providers.catalog.unsupported.service_account"
        } else {
            return FloeL10n.l(
                "providers.catalog.unsupported.generic",
                String(reason.prefix(120))
            )
        }
        return FloeL10n.l(key)
    }

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

private extension ProviderCatalogDocument.Source {
    /// Short hash prefix used by the picker footer; kept here so the picker
    /// does not duplicate string slicing logic.
    var sha256Prefix: String { String(documentSHA256.prefix(12)) }
}
#endif
