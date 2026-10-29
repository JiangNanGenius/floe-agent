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

    private var filteredOfficialPresets: [MediaModelDescriptor] {
        let listedIDs = Set(viewModel.candidateModels.map(\.remoteModelID))
        return viewModel.officialMediaPresets.filter { descriptor in
            !listedIDs.contains(descriptor.remoteModelID)
                && (searchText.isEmpty
                    || descriptor.displayName.localizedCaseInsensitiveContains(searchText)
                    || descriptor.remoteModelID.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !filteredOfficialPresets.isEmpty {
                    Section("providers.model_picker_view.official_models") {
                        ForEach(filteredOfficialPresets) { descriptor in
                            Button {
                                viewModel.addOfficialMediaPreset(descriptor)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(descriptor.displayName)
                                            .foregroundStyle(.primary)
                                        Text(descriptor.remoteModelID)
                                            .font(FloeTheme.Typography.evidence)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if viewModel.candidateModels.contains(where: {
                                        $0.remoteModelID == descriptor.remoteModelID
                                            && viewModel.selectedModelIDs.contains($0.id)
                                    }) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(FloeTheme.primary)
                                    } else {
                                        Image(systemName: "plus.circle")
                                    }
                                }
                            }
                        }
                    }
                }
                if !filteredModels.isEmpty {
                    // Candidates also include saved/manual/catalog entries.
                    // Their presence is not evidence of account discovery.
                    Section("providers.models_section") {
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
                    // Only call this "not supported" when discovery is
                    // actually unavailable; when models were discovered, the
                    // manual row is an additional fallback, not the only path.
                    if !viewModel.supportsDiscovery {
                        Text("providers.manual_fallback.hint")
                    } else {
                        Text("providers.manual_entry.hint")
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text("providers.search_models"))
            .refreshable {
                guard viewModel.supportsModelListingRefresh else { return }
                await viewModel.refreshModels()
            }
            .navigationTitle("providers.models_section")
            .toolbar {
                if viewModel.supportsModelListingRefresh {
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
