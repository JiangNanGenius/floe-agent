// FloeApp — Setup guide section content.
//
// SPDX-License-Identifier: MPL-2.0
//
// Each of the ten product sections carries the common decisions inline and
// opens the app's REAL editor for the complex ones, then comes back to the
// same step. Nothing here re-implements a service: every control writes
// through the owner the app already uses, and every resource row mirrors the
// job that owner already owns.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders
import FloeModels
import FloeExecution
import FloeLocalModels
import FloeLocalModelCatalog
import FloeAgentRuntime

// MARK: - Dispatch

struct SetupGuideSectionView: View {
    let section: SetupGuideSection
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        Group {
            switch section {
            case .chatModels: SetupChatModelsSection(model: model)
            case .creation: SetupCreationSection(model: model)
            case .webSearch: SetupWebSearchSection(model: model)
            case .voice: SetupVoiceSection(model: model)
            case .files: SetupFilesSection(model: model)
            case .personalization: SetupPersonalizationSection(model: model)
            case .permissions: SetupPermissionsSection(model: model)
            case .background: SetupBackgroundSection(model: model)
            case .syncStorage: SetupSyncStorageSection(model: model)
            case .skills: SetupSkillsSection(model: model)
            case .summary: SetupSummarySection(model: model)
            }
        }
    }
}

// MARK: - 1. Chat & Models

struct SetupChatModelsSection: View {
    @ObservedObject var model: SetupGuideModel
    @State private var showsModelPicker = false

    private var center: ConversationCenter { model.center }
    private var environment: AppEnvironment { center.environment }

    var body: some View {
        List {
            Section {
                SetupPresetPicker(model: model)
            } header: {
                Text("setup.preset.start")
            } footer: {
                Text("setup.preset.footer")
            }

            Section {
                if chatProviders.isEmpty {
                    Text("setup.chat.none")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chatProviders) { provider in
                        NavigationLink {
                            ProviderEditorView(center: center, existing: provider)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(providerName(provider))
                                        .font(.body)
                                    Text("setup.chat.provider.models")
                                        + Text(verbatim: " · " + modelCount(provider.id))
                                        .font(FloeTheme.Typography.metadata)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if provider.id == resolvedProviderID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(FloeTheme.primary)
                                }
                            }
                            .frame(minHeight: FloeTheme.minimumTarget)
                        }
                        .accessibilityIdentifier("setup.chat.provider.\(provider.id.uuidString)")
                    }
                }
                NavigationLink {
                    // Adding always starts empty: no stored configuration and
                    // no secret are loaded into a blank form.
                    ProviderEditorView(center: center, existing: nil)
                } label: {
                    Label("setup.chat.add_provider", systemImage: "plus.circle")
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
                .accessibilityIdentifier("setup.chat.addProvider")
            } header: {
                Text("setup.chat.providers")
            } footer: {
                Text("setup.chat.providers.footer")
            }

            Section {
                if center.availableAgentModels.isEmpty {
                    Text("setup.chat.no_models")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("setup.chat.main_model", selection: mainModelSelection) {
                        ForEach(center.availableAgentModels) { candidate in
                            Text(candidate.displayName).tag(Optional(candidate.id))
                        }
                    }
                    .accessibilityIdentifier("setup.chat.mainModel")
                }
            } header: {
                Text("setup.chat.answers")
            } footer: {
                Text("setup.chat.main_model.footer")
            }

            // The helper roles the app already routes. They stay here, in
            // ordinary product words, instead of being buried under creation.
            Section {
                auxiliaryPicker(
                    titleKey: "setup.role.generalHelper",
                    selection: generalHelperSelection,
                    candidates: generalHelperCandidates,
                    role: .generalHelper
                )
                auxiliaryPicker(
                    titleKey: "setup.role.packageReview",
                    selection: packageReviewSelection,
                    candidates: center.approvalModels,
                    role: .packageReview
                )
                Toggle(isOn: verifyAnswerBinding) {
                    Text("settings.general_settings_view.review_the_final_answer_before_completion")
                }
                .accessibilityIdentifier("setup.chat.verifyAnswer")
            } header: {
                Text("setup.chat.helpers")
            } footer: {
                Text("setup.chat.helpers.footer")
            }

            Section {
                onDeviceRows
                NavigationLink {
                    LocalModelsSettingsView(center: environment.localModelsCenter)
                } label: {
                    Label("localmodels.title", systemImage: "cpu")
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
                .accessibilityIdentifier("setup.chat.localModels")
            } header: {
                Text("setup.chat.on_device")
            } footer: {
                Text("setup.chat.on_device.footer")
            }

            Section {
                Toggle(isOn: appleIntelligenceBinding) {
                    Text("setup.chat.apple_intelligence")
                }
                .accessibilityIdentifier("setup.chat.appleIntelligence")
                Text("setup.chat.apple_intelligence.footer")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } header: {
                Text("localmodels.system_section")
            }
        }
        .listStyle(.insetGrouped)
        .task { await model.refreshFacts() }
    }

    /// Chat suppliers only. The on-device provider has its own surface below,
    /// the same split the shipped provider list uses.
    private var chatProviders: [ProviderProfile] {
        center.providers.filter { $0.kind != .local }
    }

    private var resolvedProviderID: UUID? {
        center.defaultProviderAndModel()?.provider.id
    }

    private func providerName(_ provider: ProviderProfile) -> String {
        provider.displayName?.isEmpty == false
            ? provider.displayName!
            : ProviderPreset.preset(for: provider.kind).displayName
    }

    private func modelCount(_ providerID: UUID) -> String {
        "\(center.configuredModelsByProvider[providerID]?.filter(\.isEnabled).count ?? 0)"
    }

    /// The stored default is authoritative; changing it writes through the
    /// same preference service Settings uses. Choosing a model here never
    /// ends the guide: the user still walks the remaining sections.
    private var mainModelSelection: Binding<UUID?> {
        Binding(
            get: { center.modelPreferences.defaultAgentModelID },
            set: { value in
                guard let value, value != center.modelPreferences.defaultAgentModelID else { return }
                Task { await model.setMainModel(value) }
            }
        )
    }

    private var verifyAnswerBinding: Binding<Bool> {
        Binding(
            get: { environment.settingsCenter.verifyFinalAnswer },
            set: { value in Task { await environment.settingsCenter.setVerifyFinalAnswer(value) } }
        )
    }

    private var generalHelperCandidates: [ModelProfile] {
        center.modelsByProvider.values.flatMap { $0 }
            .filter { $0.isEnabled && $0.supportsGeneralAuxiliaryLLM }
            .sorted { $0.displayName < $1.displayName }
    }

    private var generalHelperSelection: Binding<UUID?> {
        roleSelection(\.generalAuxiliaryLLMModelID, role: .generalHelper, candidates: generalHelperCandidates)
    }

    private var packageReviewSelection: Binding<UUID?> {
        roleSelection(\.packageReviewModelID, role: .packageReview, candidates: center.approvalModels)
    }

    private var appleIntelligenceBinding: Binding<Bool> {
        Binding(
            get: { environment.localModelsCenter.isEnabled(
                remoteModelID: AppleFoundationModelIdentity.remoteModelID
            ) },
            set: { environment.localModelsCenter.setEnabled(
                remoteModelID: AppleFoundationModelIdentity.remoteModelID,
                isEnabled: $0
            ) }
        )
    }

    private func roleSelection(
        _ keyPath: KeyPath<ModelSelectionPreferences, UUID?>,
        role: SetupGuideAuxiliaryRole,
        candidates: [ModelProfile]
    ) -> Binding<UUID?> {
        Binding(
            get: { center.modelPreferences[keyPath: keyPath] },
            set: { value in
                // A selection that leaves the verified candidate set is not a
                // real route; keep the current value instead of inventing one.
                if let value, !candidates.contains(where: { $0.id == value }) { return }
                Task { await model.setAuxiliaryRole(role, modelID: value) }
            }
        )
    }

    @ViewBuilder
    private func auxiliaryPicker(
        titleKey: LocalizedStringKey,
        selection: Binding<UUID?>,
        candidates: [ModelProfile],
        role: SetupGuideAuxiliaryRole
    ) -> some View {
        if candidates.isEmpty {
            SetupPickingRow(titleKey: titleKey, valueKey: "setup.role.not_available")
                .accessibilityIdentifier("setup.role.\(role.rawValue).empty")
        } else {
            Picker(titleKey, selection: selection) {
                Text("setup.role.follow_main").tag(Optional<UUID>.none)
                ForEach(candidates) { candidate in
                    Text(candidate.displayName).tag(Optional(candidate.id))
                }
            }
            .accessibilityIdentifier("setup.role.\(role.rawValue)")
        }
    }

    @ViewBuilder
    private var onDeviceRows: some View {
        let rows = model.resources.rows(kind: .onDeviceModel)
        if rows.isEmpty {
            SetupPickingRow(titleKey: "setup.chat.on_device.none_installed",
                            valueKey: "setup.chat.on_device.none_installed.value")
        } else {
            ForEach(rows) { row in
                SetupResourceRowView(
                    row: row,
                    prepare: {
                        guard let entry = entry(for: row.jobSubjectID) else { return }
                        model.resources.prepareOnDeviceModel(entry)
                    },
                    retry: {
                        guard let entry = entry(for: row.jobSubjectID) else { return }
                        model.resources.prepareOnDeviceModel(entry)
                    },
                    cancel: {
                        guard let entry = entry(for: row.jobSubjectID) else { return }
                        model.resources.cancelOnDeviceModel(entry)
                    }
                )
            }
        }
    }

    private func entry(for id: String?) -> LocalModelCatalogEntry? {
        guard let id else { return nil }
        return CuratedLocalModelCatalog.entries.first { $0.id == id }
    }
}

// MARK: - Preset picker

/// The picker only records a starting point and pre-fills choices the user has
/// not made. It cannot skip a section and cannot undo a saved decision.
struct SetupPresetPicker: View {
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SetupGuidePreset.allCases) { preset in
                Button {
                    model.select(preset: preset)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: preset.systemImage)
                            .font(.title3)
                            .foregroundStyle(FloeTheme.primary)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(LocalizedStringKey(preset.titleKey)).font(.headline)
                                if preset == .everyday {
                                    Text("setup.preset.recommended")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(FloeTheme.primary)
                                }
                            }
                            Text(LocalizedStringKey(preset.detailKey))
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.state.preset == preset {
                                SetupPresetPlanSummary(plan: model.plan,
                                                         applied: model.appliedRoutes)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: model.state.preset == preset
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.state.preset == preset
                                             ? FloeTheme.primary : Color.secondary)
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setup.preset.\(preset.rawValue)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Says what the preset actually did, using the real device facts. An empty
/// result is stated plainly rather than hidden.
private struct SetupPresetPlanSummary: View {
    let plan: SetupGuidePresetPlan
    /// What the writer really committed. A route the planner liked but could
    /// not apply is never announced as filled.
    let applied: [SetupGuideRoute]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !applied.isEmpty {
                Text("setup.preset.filled \(routeList(applied))")
            }
            if !plan.suggested.isEmpty {
                Text("setup.preset.suggests \(routeList(plan.suggested))")
            }
            if !plan.keptExisting.isEmpty {
                Text("setup.preset.kept \(routeList(plan.keptExisting))")
            }
            if !plan.unavailable.isEmpty {
                Text("setup.preset.unavailable \(routeList(plan.unavailable))")
            }
            if applied.isEmpty && plan.suggested.isEmpty {
                Text("setup.preset.nothing")
            }
        }
        .font(.caption2)
        .foregroundStyle(FloeTheme.primary)
        .accessibilityIdentifier("setup.preset.plan")
    }

    private func routeList(_ routes: [SetupGuideRoute]) -> String {
        routes.map { FloeL10n.l($0.titleKey) }.joined(separator: ", ")
    }
}
#endif
