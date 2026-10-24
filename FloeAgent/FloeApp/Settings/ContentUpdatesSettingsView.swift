// FloeApp — Content updates settings.
//
// SPDX-License-Identifier: MPL-2.0
//
// Policy and per-kind lifecycle for remotely updateable signed declarative
// content (prompts/providers/models/help/templates) plus the provider
// catalog. ContentUpdateCenter owns feed verification, version policy,
// dependency ordering and staged installs; this view only renders its state
// and forwards user intent. No networking or verification happens here.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSkills
import FloeProviders

struct ContentUpdatesSettingsView: View {
    @ObservedObject var center: ContentUpdateCenter

    /// True when the most recent failure came from an explicit user action;
    /// such a failure offers an inline retry. Background failures stay
    /// informational.
    @State private var manualFailure = false

    var body: some View {
        Form {
            policySection
            if let error = center.errorMessage {
                inlineErrorSection(error)
            }
            contentSections
            providerCatalogSection
            searchProviderCatalogSection
        }
        .navigationTitle(FloeL10n.l("settings.section.updates"))
        .task {
            center.load()
            manualFailure = false
            // A normal visit respects the cooldown/backoff; only explicit
            // user actions force a check.
            await center.checkAutomaticallyIfDue()
        }
        .refreshable {
            manualFailure = true
            await center.checkForUpdates(force: true)
        }
        .accessibilityIdentifier("settings.content_updates")
    }

    // MARK: - Inline (nonmodal) failure status

    private func inlineErrorSection(_ message: String) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .textSelection(.enabled)
                    Text(FloeL10n.l("settings.content_updates.error.built_in_active"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if manualFailure {
                        Button("settings.content_updates.error.retry") {
                            Task { await center.checkForUpdates(force: true) }
                        }
                        .font(.caption)
                        .accessibilityIdentifier("settings.content_updates.action.retry")
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("settings.content_updates.inline_error")
    }

    // MARK: - Policy

    private var policySection: some View {
        Section {
            Toggle("settings.content_updates.toggle.auto_checks", isOn: $center.automaticChecksEnabled)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("settings.content_updates.toggle.auto_checks")
            Toggle("settings.content_updates.toggle.auto_apply", isOn: $center.autoUpdateDeclarativeContent)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("settings.content_updates.toggle.auto_apply")
            Toggle("settings.content_updates.toggle.auto_install_scripts", isOn: $center.autoInstallScriptedSkills)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("settings.content_updates.toggle.auto_install_scripts")
            Text("settings.content_updates.scripts_warning")
                .font(.caption)
                .foregroundStyle(FloeTheme.pending)
            Toggle("settings.content_updates.toggle.wifi_only", isOn: $center.automaticDownloadOnWiFiOnly)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("settings.content_updates.toggle.wifi_only")
        } header: {
            Text("settings.content_updates.policy.header")
        }
    }

    // MARK: - Per-kind content

    private var contentSections: some View {
        ForEach(SignedContentKind.allCases, id: \.self) { kind in
            Section {
                let ids = entryIDs(for: kind)
                if kind == .prompts {
                    NavigationLink {
                        InternalPromptsSettingsView(center: center)
                    } label: {
                        Text("settings.content_updates.prompts")
                    }
                    .accessibilityIdentifier("settings.updates.prompts")
                }
                if ids.isEmpty && kind != .prompts {
                    Text("settings.content_updates.kind.none")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ids, id: \.self) { id in
                        entryRow(id: id, kind: kind)
                    }
                }
            } header: {
                Text(kindTitle(kind))
            }
        }
    }

    private func entryIDs(for kind: SignedContentKind) -> [String] {
        var ids = Set(center.installed.values.filter { $0.kind == kind.rawValue }.map(\.id))
        ids.formUnion(center.available.values.filter { $0.entry.kind == kind }.map(\.id))
        if kind == .prompts { ids.remove("floe.prompts.core") }
        ids.remove(ContentUpdateCenter.searchProviderPackageID)
        return ids.sorted()
    }

    private func entryRow(id: String, kind: SignedContentKind) -> some View {
        let record = center.installed[id]
        let availableContent = center.available[id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entryTitle(id: id, kind: kind))
                    .font(.body)
                Spacer()
            }
            Text(FloeL10n.l(availableContent?.decision.isUpdate == true
                 ? "settings.content_updates.status.update"
                 : record != nil ? "settings.content_updates.status.installed"
                 : "settings.content_updates.not_installed"))
                .font(.caption)
                .foregroundStyle(.secondary)
            actionRow(id: id, availableContent: availableContent)
            DisclosureGroup("settings.content_updates.details") {
                LabeledContent("settings.content_updates.installed") {
                    Text(record.map { "v\($0.version)" }
                         ?? FloeL10n.l("settings.content_updates.not_installed"))
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.content_updates.available") {
                    Text(availableDescription(availableContent))
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let entry = availableContent?.entry, !entry.releaseNotes.isEmpty {
                    releaseNotesView(entry)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("settings.content_updates.entry.\(id)")
    }

    @ViewBuilder
    private func releaseNotesView(_ entry: SignedContentEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.content_updates.release_notes")
                .font(.caption.weight(.semibold))
            if let en = entry.releaseNotes["en"], !en.isEmpty {
                Text(FloeL10n.l("settings.general.language.en") + ": " + en)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let zh = entry.releaseNotes["zh-Hans"], !zh.isEmpty {
                Text(FloeL10n.l("settings.general.language.zh_hans") + ": " + zh)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func actionRow(
        id: String,
        availableContent: ContentUpdateCenter.AvailableContent?
    ) -> some View {
        if center.installingIDs.contains(id) {
            HStack(spacing: 8) {
                ProgressView()
                Text("settings.content_updates.installing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: FloeTheme.minimumTarget)
        } else if availableContent?.decision.isUpdate == true || center.canRollback(id) {
            HStack(spacing: 12) {
                if availableContent?.decision.isUpdate == true {
                    Button("settings.content_updates.action.install") {
                        Task { await center.install(id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.content_updates.action.install.\(id)")
                }
                if center.canRollback(id) {
                    Button("settings.content_updates.action.rollback", role: .destructive) {
                        Task { await center.rollback(id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.content_updates.action.rollback.\(id)")
                }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
        }
    }

    // MARK: - Provider catalog

    private var providerCatalogSection: some View {
        Section {
            if let index = center.providerCatalogIndex() {
                LabeledContent("settings.content_updates.catalog.project") {
                    Text(index.document.source.project)
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.content_updates.catalog.digest") {
                    Text(String(index.document.source.documentSHA256.prefix(16)) + "\u{2026}")
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.content_updates.catalog.fetched_at") {
                    Text(index.document.source.fetchedAt)
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                Text(FloeL10n.l("settings.content_updates.catalog.provider_count", index.all.count))
                    .textSelection(.enabled)
            } else {
                Text("settings.content_updates.catalog.unavailable")
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await center.refreshProviderCatalog() }
            } label: {
                if center.isChecking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("settings.content_updates.catalog.refreshing")
                    }
                } else {
                    Label("settings.content_updates.catalog.refresh", systemImage: "arrow.clockwise")
                }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            .disabled(center.isChecking)
            .accessibilityIdentifier("settings.content_updates.catalog.refresh")
        } header: {
            Text("settings.content_updates.catalog.header")
        } footer: {
            Text("settings.content_updates.catalog.note")
        }
    }

    // MARK: - Search provider catalog

    /// State of the independently versioned signed search-provider catalog
    /// (`floe.search.providers`). The add page's refresh button delegates to
    /// the same owner; this section only renders the effective version and
    /// forwards the explicit action.
    private var searchProviderCatalogSection: some View {
        Section {
            if let catalog = center.searchProviderCatalog() {
                LabeledContent("settings.content_updates.search_catalog.version") {
                    Text("v\(catalog.version)")
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.content_updates.installed") {
                    if let installed = center.installed[ContentUpdateCenter.searchProviderPackageID] {
                        Text("v\(installed.version)")
                            .font(FloeTheme.Typography.evidence)
                    } else {
                        Text("settings.content_updates.search_catalog.built_in")
                            .font(FloeTheme.Typography.evidence)
                    }
                }
                if let available = center.available[ContentUpdateCenter.searchProviderPackageID] {
                    LabeledContent("settings.content_updates.available") {
                        Text("v\(available.entry.version) \u{00B7} \(decisionText(available.decision))")
                            .font(FloeTheme.Typography.evidence)
                    }
                }
            } else {
                Text("settings.content_updates.catalog.unavailable")
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await center.refreshSearchProviderCatalog() }
            } label: {
                if center.isChecking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("settings.content_updates.catalog.refreshing")
                    }
                } else {
                    Label("settings.content_updates.catalog.refresh", systemImage: "arrow.clockwise")
                }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            .disabled(center.isChecking)
            .accessibilityIdentifier("settings.content_updates.search_catalog.refresh")
        } header: {
            Text("settings.content_updates.search_catalog.header")
        }
    }

    // MARK: - Titles and decisions

    private func entryTitle(id: String, kind: SignedContentKind) -> LocalizedStringKey {
        switch id {
        case "floe.help.quickstart": "settings.content_updates.name.help"
        case "floe.models.catalog-metadata": "settings.content_updates.name.models"
        case "floe.providers.compatibility": "settings.content_updates.name.compatibility"
        case "floe.templates.report": "settings.content_updates.name.report"
        default: kindTitle(kind)
        }
    }

    private func kindTitle(_ kind: SignedContentKind) -> LocalizedStringKey {
        switch kind {
        case .prompts: "settings.content_updates.kind.prompts"
        case .providers: "settings.content_updates.kind.providers"
        case .models: "settings.content_updates.kind.models"
        case .help: "settings.content_updates.kind.help"
        case .templates: "settings.content_updates.kind.templates"
        }
    }

    private func availableDescription(
        _ availableContent: ContentUpdateCenter.AvailableContent?
    ) -> String {
        guard let availableContent else {
            return FloeL10n.l("settings.content_updates.not_available")
        }
        return "v\(availableContent.entry.version) \u{00B7} \(decisionText(availableContent.decision))"
    }

    private func decisionText(_ decision: ContentUpdateDecision) -> String {
        switch decision {
        case .upToDate:
            return FloeL10n.l("settings.content_updates.decision.up_to_date")
        case .update:
            return FloeL10n.l("settings.content_updates.decision.update")
        case .blocked(let reason, _):
            return blockedText(reason)
        }
    }

    private func blockedText(_ reason: ContentUpdateBlockReason) -> String {
        switch reason {
        case .downgrade:
            return FloeL10n.l("settings.content_updates.decision.blocked.downgrade")
        case .sameVersionDifferentContent:
            return FloeL10n.l("settings.content_updates.decision.blocked.same_version")
        case .incompatibleApp:
            return FloeL10n.l("settings.content_updates.decision.blocked.incompatible_app")
        case .missingDependency:
            return FloeL10n.l("settings.content_updates.decision.blocked.missing_dependency")
        case .pinned:
            return FloeL10n.l("settings.content_updates.decision.blocked.pinned")
        case .feedFailure:
            return FloeL10n.l("settings.content_updates.decision.blocked.invalid")
        }
    }
}
#endif
