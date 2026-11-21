// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeProviders
import SwiftUI

// FloeMacUnified — Unified supplier selector for the Mac provider editor.
//
// ONE searchable selector for the add/edit provider form, mirroring the iPad
// `ProviderCatalogPicker` (FloeAgent/FloeApp/Providers/ProviderCatalogAddView.swift):
// the built-in provider presets and the verified official catalog entries
// appear in the same list, searched locally together. Search is pure local
// computation on the effective catalog index — typing never performs network
// I/O. Rows carry no credentials; selecting hands the choice back to the
// editor, which owns duplicate checks, custom-name preservation and prefill.
//
// The catalog bytes themselves (signed fetch, verification, atomic install,
// bundled fallback) live in the shared `FloeMacOfficialCatalogs` service and
// the `HostAgentWorkspace` catalog entrypoints; this file only renders and
// searches the effective `ProviderCatalogIndex` through the shared schema and
// filter contracts (`ProviderCatalogIndex.validated(from:)`, `search(query:
// filter:configuredPresetIDs:)`, `ProviderFormSpecResolver.isCatalogEntry`).

/// Unified, locally searchable supplier picker for the Mac provider editor.
struct MacProviderCatalogPicker: View {
    /// Product role of the editor session. Catalog results are filtered to
    /// entries a shipped adapter can really serve for this role, so an
    /// image/video add can never pick a chat-only gateway into a dead
    /// configuration.
    let role: ProviderCatalogServiceRole
    /// Built-in presets valid for the editor's service role.
    let presets: [ProviderPreset]
    /// Currently selected preset (marked in the built-in section).
    var selectedPresetID: ProviderTemplateID?
    /// Currently selected catalog entry identity, when anchored to one.
    var selectedCatalogID: String?
    /// Effective verified catalog index (active signed install, else bundled).
    let catalog: ProviderCatalogIndex?
    /// presetIDs of already saved providers, used for the configured badge.
    let configuredPresetIDs: Set<String>
    /// True while a signed catalog refresh is running.
    let isRefreshing: Bool
    /// Last refresh failure, kept visible until dismissed or retried.
    let errorMessage: String?
    /// Optional async refresh of the official catalog through the workspace.
    let onRefresh: (() async -> Void)?
    /// Called for selectable catalog rows. Unsupported rows never call this.
    let onSelect: (ProviderCatalogEntry) -> Void
    /// Called for a built-in preset choice (including manual/custom).
    let onSelectPreset: (ProviderPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: ProviderCatalogFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("mac.provider.catalog.title").font(.headline)
                Spacer(minLength: 8)
                if catalog != nil, onRefresh != nil {
                    Button {
                        guard !isRefreshing else { return }
                        Task { await onRefresh?() }
                    } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(Text("mac.provider.catalog.refresh"))
                        } else {
                            Label("mac.provider.catalog.refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityIdentifier("providers.catalog.refresh")
                }
                Button("mac.provider.catalog.close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("providers.catalog.cancel")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("mac.provider.catalog.searchPlaceholder", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("providers.catalog.search")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Picker("mac.provider.catalog.filterLabel", selection: $filter) {
                ForEach(visibleFilters, id: \.self) { filterKind in
                    Text(filterLabel(filterKind)).tag(filterKind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityLabel("mac.provider.catalog.filterLabel")
            .accessibilityIdentifier("providers.catalog.filter")

            Divider()

            if let errorMessage, !errorMessage.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(FloeTheme.pending)
                        Text("mac.provider.catalog.refreshFailed \(errorMessage)")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button("mac.provider.catalog.retry") {
                            Task { await onRefresh?() }
                        }
                        .disabled(isRefreshing)
                        Text("mac.provider.catalog.manualHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("providers.catalog.error")
                Divider()
            }

            List {
                if !matchingPresets.isEmpty {
                    Section {
                        ForEach(matchingPresets) { preset in
                            presetRow(preset)
                        }
                    } header: {
                        Text("mac.provider.catalog.builtin")
                    }
                }
                if let catalog {
                    Section {
                        if results.isEmpty && matchingPresets.isEmpty {
                            emptyResults
                        } else if results.isEmpty {
                            Text("mac.provider.catalog.noMatch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minHeight: FloeTheme.minimumTarget, alignment: .leading)
                        } else {
                            ForEach(results) { entry in
                                row(entry)
                            }
                        }
                    } header: {
                        Text("mac.provider.catalog.official")
                    } footer: {
                        catalogFooter(catalog)
                    }
                } else if matchingPresets.isEmpty {
                    emptyResults
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 540, minHeight: 440)
    }

    // MARK: - Search results (pure local)

    /// Built-in presets matching the current query by display name or host.
    /// Manual/custom stays present for an explicit, non-catalog choice.
    private var matchingPresets: [ProviderPreset] {
        MacProviderCatalogSearch.matchingPresets(presets, query: query)
    }

    /// Segment options valid for the editor's role. On-device entries only
    /// exist for the conversation role; media roles never show that segment.
    private var visibleFilters: [ProviderCatalogFilter] {
        switch role {
        case .conversation:
            ProviderCatalogFilter.allCases
        case .image, .video:
            ProviderCatalogFilter.allCases.filter { $0 != .local }
        }
    }

    private var results: [ProviderCatalogEntry] {
        guard let catalog else { return [] }
        let matches = catalog.search(
            query: query,
            filter: filter,
            configuredPresetIDs: configuredPresetIDs
        )
        switch role {
        case .conversation:
            return matches
        case .image, .video:
            // Only entries whose shipped adapter contract can really serve
            // this media role with verified (or account-listable) identifiers.
            return matches.filter {
                ProviderFormSpecResolver.isCatalogEntry($0, eligibleFor: role)
            }
        }
    }

    // MARK: - Footer

    private func catalogFooter(_ catalog: ProviderCatalogIndex) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("mac.provider.catalog.providerCount \(catalog.offeredProviderCount)")
            Text("mac.provider.catalog.documentHash \(MacProviderCatalogSearch.shortDocumentSHA256(catalog))")
            Text("mac.provider.catalog.fetchedAt \(catalog.document.source.fetchedAt)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Rows

    /// One built-in preset choice, marked when it is the current selection.
    private func presetRow(_ preset: ProviderPreset) -> some View {
        Button {
            onSelectPreset(preset)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(protocolName(preset.defaultProtocol))
                        Text(verbatim: "·")
                        Text(verbatim: preset.defaultBaseURL.host ?? "—")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if preset.id == selectedPresetID, selectedCatalogID == nil {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FloeTheme.primary)
                }
            }
            .padding(.vertical, 3)
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
                        .font(.body)
                        .foregroundStyle(.primary)
                    if configuredPresetIDs.contains(entry.presetID) {
                        badge("mac.provider.catalog.configuredBadge", color: FloeTheme.primary)
                    }
                    if entry.availability == .unsupported {
                        badge("mac.provider.catalog.unsupportedBadge", color: .secondary)
                    }
                    Spacer(minLength: 0)
                    if entry.presetID == selectedCatalogID {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FloeTheme.primary)
                    }
                }
                if let alias = MacProviderCatalogSearch.matchingAlias(entry, query: query) {
                    Text("mac.provider.catalog.alias \(alias)")
                        .font(.caption)
                        .foregroundStyle(FloeTheme.primary)
                }
                HStack(spacing: 4) {
                    Text(protocolName(entry.defaultProtocol))
                    Text(verbatim: "·")
                    Text(verbatim: ProviderPreset.preset(for: entry.kind, baseURL: entry.baseURL).displayName)
                    Text(verbatim: "·")
                    Text(verbatim: entry.baseURL?.host ?? "—")
                    Text(verbatim: "·")
                    Text("mac.provider.catalog.modelsCount \(entry.models.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !serviceRoleLabels(entry).isEmpty {
                    Text("mac.provider.catalog.alsoServes \(serviceRoleLabels(entry).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(FloeTheme.success)
                }
                if entry.availability == .unsupported, let reason = entry.unsupportedReason {
                    Text(Self.localizedUnsupportedReason(reason))
                        .font(.caption)
                        .foregroundStyle(FloeTheme.pending)
                }
            }
            .padding(.vertical, 3)
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
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var emptyResults: some View {
        ContentUnavailableView {
            Label("mac.provider.catalog.emptyTitle", systemImage: "magnifyingglass")
        } description: {
            Text("mac.provider.catalog.emptyHint")
        }
    }

    // MARK: - Labels

    /// Product-role tokens a shipped adapter can really serve for this entry,
    /// so the row states actual capability ("text", "images", "video")
    /// instead of a model-name guess or a provider-wide vision claim.
    private func serviceRoleLabels(_ entry: ProviderCatalogEntry) -> [String] {
        ProviderServiceOfferResolver.resolvedOffers(
            for: entry.kind,
            presetID: entry.presetID,
            baseURL: entry.baseURL,
            authStyle: entry.authStyle,
            availability: entry.availability,
            declared: entry.serviceOffers
        )
        .filter(\.isUsable)
        .map {
            switch $0.role {
            case .conversation: String(localized: "mac.provider.catalog.supportText")
            case .image: String(localized: "mac.provider.catalog.supportImages")
            case .video: String(localized: "mac.provider.catalog.supportVideo")
            }
        }
    }

    /// Known capability-failure reasons map to localized strings (matched on
    /// stable tokens so minor catalog wording edits do not break the mapping);
    /// unknown reasons stay readable through a localized wrapper with the raw
    /// detail, never a bare English string.
    static func localizedUnsupportedReason(_ reason: String) -> String {
        let normalized = reason.lowercased()
        let key: String.LocalizationValue
        if normalized.contains("oauth device flow") {
            key = "mac.provider.catalog.unsupported.oauthDeviceFlow"
        } else if normalized.contains("deployment-specific endpoint") || normalized.contains("api-version") {
            key = "mac.provider.catalog.unsupported.deploymentEndpoint"
        } else if normalized.contains("sigv4") {
            key = "mac.provider.catalog.unsupported.sigv4"
        } else if normalized.contains("service-account") || normalized.contains("service account") {
            key = "mac.provider.catalog.unsupported.serviceAccount"
        } else {
            return String(localized: "mac.provider.catalog.unsupported.generic \(String(reason.prefix(120)))")
        }
        return String(localized: key)
    }

    private func filterLabel(_ filter: ProviderCatalogFilter) -> LocalizedStringKey {
        switch filter {
        case .all: "mac.provider.catalog.filter.all"
        case .configured: "mac.provider.catalog.filter.configured"
        case .available: "mac.provider.catalog.filter.available"
        case .local: "mac.provider.catalog.filter.local"
        }
    }

    private func protocolName(_ protocolKind: ModelProtocol) -> LocalizedStringKey {
        switch protocolKind {
        case .openAIResponses: "mac.provider.catalog.protocol.openaiResponses"
        case .openAIChatCompletions: "mac.provider.catalog.protocol.openaiChat"
        case .anthropicMessages: "mac.provider.catalog.protocol.anthropic"
        }
    }
}

// MARK: - Pure search helpers

/// Pure, side-effect-free local search helpers shared by the supplier picker.
/// Mirroring the iPad selector's contracts keeps ranking and normalization
/// identical across platforms: typing never performs network I/O and identical
/// inputs produce identical results.
enum MacProviderCatalogSearch {
    /// Built-in presets matching the query by display name or default host.
    static func matchingPresets(_ presets: [ProviderPreset], query: String) -> [ProviderPreset] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return presets }
        let needle = ProviderCatalogIndex.normalized(trimmed)
        return presets.filter { preset in
            ProviderCatalogIndex.normalized(preset.displayName).contains(needle)
                || ProviderCatalogIndex.normalized(preset.defaultBaseURL.host ?? "").contains(needle)
        }
    }

    /// The alias the current query matches (substring, normalized), if the
    /// match was not on the display name itself.
    static func matchingAlias(_ entry: ProviderCatalogEntry, query: String) -> String? {
        let normalized = ProviderCatalogIndex.normalized(query)
        guard !normalized.isEmpty else { return nil }
        return entry.aliases.first {
            ProviderCatalogIndex.normalized($0).contains(normalized)
        }
    }

    /// Short display form of the pinned source document hash.
    static func shortDocumentSHA256(_ catalog: ProviderCatalogIndex) -> String {
        String(catalog.document.source.documentSHA256.prefix(12))
    }
}
