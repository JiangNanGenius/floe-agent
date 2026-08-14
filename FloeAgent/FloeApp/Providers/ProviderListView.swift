// FloeApp — Provider list.
//
// SPDX-License-Identifier: MPL-2.0
//
// Lists configured providers with model counts and honest secret-sync
// state (including `.waitingForSecret`). Push to the editor to add or
// edit. Secrets never appear here — only sync status.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders
import FloeSyncCore

/// The Providers screen (under More, and surfaced in onboarding).
struct ProviderListView: View {
    @StateObject private var viewModel: ProviderListViewModel

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: ProviderListViewModel(center: center))
    }

    var body: some View {
        Group {
            if viewModel.providers.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("more.providers", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("empty.providers")
                }
            } else {
                providerList
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("more.providers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    ProviderEditorView(center: viewModel.center, existing: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("providers.add")
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private var providerList: some View {
        List {
            ForEach(viewModel.providers) { provider in
                NavigationLink {
                    ProviderEditorView(center: viewModel.center, existing: provider)
                } label: {
                    ProviderRow(
                        provider: provider,
                        modelCount: viewModel.modelCount(for: provider.id),
                        status: viewModel.status(for: provider.id)
                    )
                }
            }
            .onDelete { offsets in
                let targets = offsets.map { viewModel.providers[$0] }
                for provider in targets {
                    Task { await viewModel.delete(provider) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One provider row: kind, base URL, model count, secret-sync status.
private struct ProviderRow: View {
    let provider: ProviderProfile
    let modelCount: Int
    let status: SyncStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(presetName)
                    .font(FloeTheme.Typography.body)
                Spacer()
                if status == .waitingForSecret {
                    Label("providers.waiting_secret", systemImage: "key.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                }
            }
            Text(provider.baseURL.absoluteString)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(modelCount) " + String(localized: "providers.models"))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    private var presetName: String {
        ProviderPreset.preset(for: provider.kind).displayName
    }
}
#endif
