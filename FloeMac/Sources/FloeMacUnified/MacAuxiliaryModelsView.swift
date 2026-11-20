// SPDX-License-Identifier: MPL-2.0
import FloeCore
import SwiftUI

enum MacAuxiliaryRole: CaseIterable {
    case text, vision

    func selection(in preferences: ModelSelectionPreferences) -> UUID? {
        switch self {
        case .text: preferences.generalAuxiliaryLLMModelID
        case .vision: preferences.visionModelID
        }
    }

    func accepts(_ model: ModelProfile) -> Bool {
        switch self {
        case .text: model.supportsGeneralAuxiliaryLLM
        case .vision: model.supportsAuxiliaryVisionSurface
        }
    }
}

struct MacAuxiliaryModelsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("mac.aux.title").font(.headline).padding()
            controls
        }.frame(minWidth: 440, minHeight: 340)
        #if FLOE_MAC_HOST_SMOKE
        .onAppear { workspace.smokeAuxiliaryModelsMounted = true }
        .onDisappear { workspace.smokeAuxiliaryModelsMounted = false }
        #endif
    }

    private var controls: some View {
        Form {
            Section {
                picker(.text, label: "mac.aux.text", fallback: "mac.aux.follow")
            } footer: { Text("mac.aux.text.detail") }
            Section {
                picker(.vision, label: "mac.aux.vision", fallback: "mac.aux.none")
                Toggle("mac.aux.reasoning", isOn: $workspace.auxiliaryVisionReasoning)
                    .disabled(workspace.selectedAuxiliary(.vision) == nil)
            } footer: { Text("mac.aux.vision.detail") }
            Section {
                Picker("mac.aux.reviewer", selection: Binding(get: { workspace.approvalModelID },
                       set: workspace.setApprovalModelID)) {
                    Text("mac.aux.none").tag(UUID?.none)
                    ForEach(workspace.providers.filter { $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsApprovalSurface }, id: \.model.id) {
                        Text(label($0)).tag(Optional($0.model.id))
                    }
                }.disabled(workspace.savingApprovalMode)
            } footer: { Text("mac.aux.reviewer.detail") }

        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.auxiliaryModels")
    }

    private func picker(_ role: MacAuxiliaryRole, label title: LocalizedStringKey, fallback: LocalizedStringKey) -> some View {
        Picker(title, selection: Binding(get: { role.selection(in: workspace.auxiliaryPreferences) },
                                         set: { workspace.setAuxiliaryModel($0, for: role) })) {
            Text(fallback).tag(UUID?.none)
            if let saved = role.selection(in: workspace.auxiliaryPreferences), workspace.selectedAuxiliary(role) == nil {
                Text("mac.aux.unavailable").tag(Optional(saved))
            }
            ForEach(workspace.auxiliaryCandidates(role), id: \.model.id) {
                Text(label($0)).tag(Optional($0.model.id))
            }
        }
    }

    private func label(_ record: HostAgentProvider) -> String {
        [record.profile.displayName ?? record.profile.baseURL.host ?? record.profile.kind.rawValue,
         record.model.displayName].joined(separator: " · ")
    }
}
