// FloeApp — Internal prompts settings.
//
// SPDX-License-Identifier: MPL-2.0
//
// Read-only review surface for the signed `floe.prompts.core` package plus
// the lifecycle actions (check/install/rollback) for that one content id.
// ContentUpdateCenter owns verification, version policy, install and
// rollback; this view renders its state and never parses, verifies or
// compares versions itself. The safety/permission rules below are compiled
// into the app and are deliberately not editable or remotely updateable.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSkills

struct InternalPromptsSettingsView: View {
    @ObservedObject var center: ContentUpdateCenter

    private static let contentID = "floe.prompts.core"

    private var installedRecord: ContentUpdateCenter.InstalledRecord? {
        center.installed[Self.contentID]
    }

    private var availableContent: ContentUpdateCenter.AvailableContent? {
        center.available[Self.contentID]
    }

    private var isInstalling: Bool {
        center.installingIDs.contains(Self.contentID)
    }

    var body: some View {
        Form {
            statusSection
            sectionsSection
            fixedRulesSection
        }
        .navigationTitle(FloeL10n.l("settings.section.internal_prompts"))
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
        .accessibilityIdentifier("settings.internal_prompts")
    }

    // MARK: - Lifecycle status

    private var statusSection: some View {
        Section {
            LabeledContent("settings.internal_prompts.installed_version") {
                Text(installedRecord.map { "v\($0.version)" }
                     ?? FloeL10n.l("settings.content_updates.not_installed"))
                    .font(FloeTheme.Typography.evidence)
                    .textSelection(.enabled)
            }
            if let record = installedRecord {
                LabeledContent("settings.internal_prompts.digest") {
                    Text(String(record.digest.prefix(16)) + "\u{2026}")
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.internal_prompts.source_revision") {
                    Text(record.sourceRevision.isEmpty
                         ? FloeL10n.l("settings.content_updates.not_available")
                         : String(record.sourceRevision.prefix(12)))
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
            } else {
                LabeledContent("settings.internal_prompts.built_in_version") {
                    Text("v\(center.appVersion)")
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("settings.internal_prompts.available_version") {
                Text(availableDescription)
                    .font(FloeTheme.Typography.evidence)
                    .textSelection(.enabled)
            }
            LabeledContent("settings.internal_prompts.source_index") {
                Text(OfficialContentHub.indexPath)
                    .font(FloeTheme.Typography.evidence)
                    .textSelection(.enabled)
            }
            actionRow
            if let last = center.lastCheck {
                Text(FloeL10n.l(
                    "settings.content_updates.last_check",
                    last.formatted(date: .abbreviated, time: .shortened)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Toggle("settings.internal_prompts.auto_update", isOn: $center.autoUpdateDeclarativeContent)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("settings.internal_prompts.toggle.auto_update")
            Text("settings.internal_prompts.auto_update_note")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("settings.internal_prompts.status.header")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if isInstalling {
                ProgressView()
                Text("settings.content_updates.installing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if availableContent?.decision.isUpdate == true {
                    Button("settings.content_updates.action.install") {
                        Task { await center.install(Self.contentID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.internal_prompts.action.install")
                }
                if installedRecord?.previousVersion != nil {
                    Button("settings.content_updates.action.rollback", role: .destructive) {
                        Task { await center.rollback(Self.contentID) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.internal_prompts.action.rollback")
                }
                Button("settings.content_updates.check_now") {
                    Task { await center.checkForUpdates(force: true) }
                }
                .buttonStyle(.bordered)
                .disabled(center.isChecking)
                .accessibilityIdentifier("settings.internal_prompts.action.check")
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    private var availableDescription: String {
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

    // MARK: - Published sections (read-only)

    private var promptLocale: String {
        FloeL10n.currentLanguageCode == "zh-Hans" ? "zh-Hans" : "en"
    }

    private func localizedText(_ values: [String: String]) -> String {
        values[promptLocale] ?? values["en"] ?? values.values.first ?? ""
    }

    private var sectionsSection: some View {
        Section {
            let sections = center.promptSections()
            if sections.isEmpty {
                Text("settings.internal_prompts.sections.empty")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections, id: \.id) { section in
                    DisclosureGroup {
                        Text(localizedText(section.body))
                            .font(FloeTheme.Typography.body)
                            .textSelection(.enabled)
                    } label: {
                        Text(localizedText(section.title))
                            .font(FloeTheme.Typography.section)
                    }
                    .accessibilityIdentifier("settings.internal_prompts.section.\(section.id)")
                }
            }
        } header: {
            Text("settings.internal_prompts.sections.header")
        } footer: {
            Text("settings.internal_prompts.sections.footer")
        }
    }

    // MARK: - Fixed code-owned rules

    private var fixedRulesSection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ruleRow("settings.internal_prompts.fixed_rules.permission")
                    ruleRow("settings.internal_prompts.fixed_rules.tool_protocol")
                    ruleRow("settings.internal_prompts.fixed_rules.truthfulness")
                    ruleRow("settings.internal_prompts.fixed_rules.recovery")
                }
                .padding(.vertical, 4)
            } label: {
                Text("settings.internal_prompts.fixed_rules.header")
            }
            .accessibilityIdentifier("settings.internal_prompts.fixed_rules")
        } footer: {
            Text("settings.internal_prompts.fixed_rules.note")
        }
    }

    private func ruleRow(_ key: LocalizedStringKey) -> some View {
        Label(key, systemImage: "lock.fill")
            .font(FloeTheme.Typography.body)
    }
}
#endif
