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
    @ObservedObject var viewModel: ProviderEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var manualRemoteID = ""
    @State private var manualDisplayName = ""
    @State private var searchText = ""

    private var filteredModels: [ModelProfile] {
        guard !searchText.isEmpty else { return viewModel.candidateModels }
        return viewModel.candidateModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.remoteModelID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !filteredModels.isEmpty {
                    Section("providers.discovered") {
                        ForEach(filteredModels) { model in
                            Toggle(isOn: Binding(
                                get: { viewModel.selectedModelIDs.contains(model.id) },
                                set: { viewModel.setSelection(model.id, isSelected: $0) }
                            )) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.displayName)
                                            .font(FloeTheme.Typography.body)
                                        Text(model.remoteModelID)
                                            .font(FloeTheme.Typography.evidence)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .tint(FloeTheme.primary)
                            .frame(minHeight: FloeTheme.minimumTarget)
                            .accessibilityIdentifier("providers.model.\(model.remoteModelID)")
                            .accessibilityValue(
                                viewModel.selectedModelIDs.contains(model.id)
                                    ? "selected" : "not selected"
                            )
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
                        viewModel.addManualModel(remoteID: manualRemoteID, displayName: manualDisplayName)
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
            .searchable(text: $searchText, prompt: Text("providers.search_models"))
            .refreshable {
                guard viewModel.supportsDiscovery else { return }
                await viewModel.refreshModels()
            }
            .navigationTitle("providers.models_section")
            .toolbar {
                if viewModel.supportsDiscovery {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await viewModel.refreshModels() }
                        } label: {
                            if viewModel.testState == .testing {
                                ProgressView()
                            } else {
                                Label("providers.refresh_models", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.testState == .testing)
                        .accessibilityIdentifier("providers.refresh_models")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .accessibilityIdentifier("action.done")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .failed(let message) = viewModel.testState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
        }
    }
}
#endif
