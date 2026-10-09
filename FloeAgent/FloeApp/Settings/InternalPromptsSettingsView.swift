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
//
// Failure presentation: a failed check — automatic, pull-to-refresh or
// button — is an inline status, never a modal alert; built-in content stays
// active regardless, and the section list keeps showing the compiled
// built-in sections when no signed package is installed.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSkills

struct InternalPromptsSettingsView: View {
    @ObservedObject var center: ContentUpdateCenter

    private static let contentID = "floe.prompts.core"

    /// True when the most recent failure came from an explicit user action
    /// (pull-to-refresh or Check Now); such a failure offers an inline
    /// retry. Background-check failures stay informational only.
    @State private var manualFailure = false

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
            if let error = center.errorMessage {
                inlineErrorSection(error)
            }
            sectionsSection
            fixedRulesSection
        }
        .navigationTitle(FloeL10n.l("settings.section.internal_prompts"))
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
                // The built-in prompts content is versioned independently of
                // the app marketing version; the digest belongs to signed
                // packages only, so the compiled source is named instead.
                LabeledContent("settings.internal_prompts.built_in_version") {
                    Text("v\(center.effectivePromptsVersion())")
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.internal_prompts.built_in_source") {
                    Text(FloeL10n.l("settings.internal_prompts.built_in_source.value"))
                        .font(FloeTheme.Typography.evidence)
                }
            }
            LabeledContent("settings.internal_prompts.available_version") {
                Text(availableDescription)
                    .font(FloeTheme.Typography.evidence)
                    .textSelection(.enabled)
            }
            sourceRow
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

    /// The content feed is the official content hub; the repository, ref and
    /// signed index path are technical details under a disclosure, not the
    /// primary label (and never a "skill feed" — this is declarative content).
    private var sourceRow: some View {
        LabeledContent("settings.internal_prompts.source") {
            Text(FloeL10n.l("settings.internal_prompts.source.value"))
                .font(FloeTheme.Typography.evidence)
        }
        .accessibilityIdentifier("settings.internal_prompts.source")
    }

    private var sourceDetailsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                technicalRow("settings.internal_prompts.source.repository",
                             "\(OfficialContentHub.owner)/\(OfficialContentHub.repository)")
                technicalRow("settings.internal_prompts.source.ref", "main")
                technicalRow("settings.internal_prompts.source.index", OfficialContentHub.indexPath)
                technicalRow("settings.internal_prompts.source.signature", OfficialContentHub.signaturePath)
                if let commit = center.providerCatalogCommit {
                    technicalRow("settings.internal_prompts.source.pinned_commit",
                                 String(commit.prefix(12)))
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text("settings.internal_prompts.source.details")
                .font(FloeTheme.Typography.body)
        }
        .accessibilityIdentifier("settings.internal_prompts.source.details.toggle")
    }

    private func technicalRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(key) {
            Text(value)
                .font(FloeTheme.Typography.evidence)
                .textSelection(.enabled)
        }
        .font(.caption)
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
                    manualFailure = true
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
                        .accessibilityIdentifier("settings.internal_prompts.action.retry")
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("settings.internal_prompts.inline_error")
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
                // No signed package installed (or the network was never
                // available): show the compiled built-in sections, which are
                // exactly what the runtime uses in that state.
                let builtIn = center.builtInPromptSections()
                if builtIn.isEmpty {
                    Text("settings.internal_prompts.sections.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(builtIn, id: \.id) { section in
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
                    sourceDetailsSection
                }
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
                sourceDetailsSection
            }
        } header: {
            Text("settings.internal_prompts.sections.header")
        } footer: {
            Text(sectionsFooter)
        }
    }

    private var sectionsFooter: String {
        if center.promptSections().isEmpty {
            return FloeL10n.l("settings.internal_prompts.sections.footer.built_in")
        }
        return FloeL10n.l("settings.internal_prompts.sections.footer")
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
