// FloeApp — Model picker (discovery results + manual fallback).
//
// SPDX-License-Identifier: MPL-2.0
//
// Shows `/models` discovery results and offers a manual-model fallback
// when discovery is unsupported or returned nothing. Selecting/adding a
// model stages it for save in the provider editor.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

/// A sheet listing discovered models plus a manual-entry fallback.
struct ModelPickerView: View {
    let models: [ModelProfile]
    let onAddManual: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manualRemoteID = ""
    @State private var manualDisplayName = ""

    var body: some View {
        NavigationStack {
            List {
                if !models.isEmpty {
                    Section("providers.discovered") {
                        ForEach(models) { model in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(FloeTheme.Typography.body)
                                Text(model.remoteModelID)
                                    .font(FloeTheme.Typography.evidence)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: FloeTheme.minimumTarget)
                        }
                    }
                }
                Section {
                    TextField("providers.model_id", text: $manualRemoteID)
                        .textInputAutocapitalization(.never)
                        .font(FloeTheme.Typography.evidence)
                    TextField("providers.model_name", text: $manualDisplayName)
                        .textInputAutocapitalization(.never)
                    Button("providers.add_model") {
                        onAddManual(manualRemoteID, manualDisplayName)
                        manualRemoteID = ""
                        manualDisplayName = ""
                    }
                    .disabled(manualRemoteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: FloeTheme.minimumTarget)
                } header: {
                    Text("providers.manual_entry")
                } footer: {
                    Text("providers.manual_fallback.hint")
                }
            }
            .navigationTitle("providers.models_section")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
            }
        }
    }
}
#endif
