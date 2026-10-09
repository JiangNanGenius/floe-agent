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

    var body: some View {
        Form {
            policySection
            contentSections
            providerCatalogSection
        }
        .navigationTitle(FloeL10n.l("settings.content_updates.title"))
        .task {
            center.load()
            await center.checkForUpdates(force: true)
        }
        .refreshable { await center.checkForUpdates(force: true) }
        .alert("settings.content_updates.error.title", isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button("workspace.workspace_canvas_view.done", role: .cancel) {}
        } message: {
            Text(center.errorMessage ?? "")
        }
        .accessibilityIdentifier("settings.content_updates")
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
        } footer: {
            Text("settings.content_updates.policy.footer")
        }
    }

    // MARK: - Per-kind content

    private var contentSections: some View {
        ForEach(SignedContentKind.allCases, id: \.self) { kind in
            Section {
                let ids = entryIDs(for: kind)
                if ids.isEmpty {
                    Text("settings.content_updates.kind.none")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ids, id: \.self) { id in
                        entryRow(id: id)
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
        return ids.sorted()
    }

    private func entryRow(id: String) -> some View {
        let record = center.installed[id]
        let availableContent = center.available[id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(id)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if center.pinnedVersions[id] != nil {
                    Text("settings.content_updates.pinned_badge")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FloeTheme.pending)
                }
            }
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
            if let entry = availableContent?.entry, !entry.releaseNotes.isEmpty {
                releaseNotesView(entry)
            }
            actionRow(id: id, record: record, availableContent: availableContent)
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
        record: ContentUpdateCenter.InstalledRecord?,
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
        } else {
            HStack(spacing: 12) {
                if availableContent?.decision.isUpdate == true {
                    Button("settings.content_updates.action.install") {
                        Task { await center.install(id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.content_updates.action.install.\(id)")
                }
                if let record, record.previousVersion != nil {
                    Button("settings.content_updates.action.rollback", role: .destructive) {
                        Task { await center.rollback(id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.content_updates.action.rollback.\(id)")
                }
                if let record {
                    Button(pinTitle(id)) {
                        center.setPinned(id, version: center.pinnedVersions[id] == nil ? record.version : nil)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.content_updates.action.pin.\(id)")
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

    // MARK: - Titles and decisions

    private func kindTitle(_ kind: SignedContentKind) -> LocalizedStringKey {
        switch kind {
        case .prompts: "settings.content_updates.kind.prompts"
        case .providers: "settings.content_updates.kind.providers"
        case .models: "settings.content_updates.kind.models"
        case .help: "settings.content_updates.kind.help"
        case .templates: "settings.content_updates.kind.templates"
        }
    }

    private func pinTitle(_ id: String) -> LocalizedStringKey {
        center.pinnedVersions[id] == nil
            ? "settings.content_updates.action.pin"
            : "settings.content_updates.action.unpin"
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
