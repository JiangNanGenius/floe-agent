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
    @State private var presentedEditor: ProviderEditorRoute?

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: ProviderListViewModel(center: center))
    }

    var body: some View {
        Group {
            if viewModel.providers.isEmpty && viewModel.imageOnlyProviders.isEmpty && !viewModel.isLoading {
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
                Button {
                    presentedEditor = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("providers.add")
                .accessibilityIdentifier("providers.add")
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $presentedEditor, onDismiss: {
            Task { await viewModel.load() }
        }) { route in
            NavigationStack {
                ProviderEditorView(center: viewModel.center, existing: route.provider)
            }
            .presentationSizing(.page)
        }
        .alert(
            "providers.delete_failed",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("action.done") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var providerList: some View {
        List {
            Section("对话模型服务商") {
                ForEach(viewModel.providers) { provider in
                    providerButton(provider, modelCount: viewModel.modelCount(for: provider.id))
                }
            }

            if !viewModel.imageOnlyProviders.isEmpty {
                Section {
                    ForEach(viewModel.imageOnlyProviders) { provider in
                        providerButton(
                            provider,
                            modelCount: viewModel.auxiliaryModelCount(for: provider.id)
                        )
                    }
                } header: {
                    Text("图像模型服务商")
                } footer: {
                    Text("这些端点只供读图、图片生成或编辑使用；路由在“辅助模型”中设置。")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func providerButton(_ provider: ProviderProfile, modelCount: Int) -> some View {
        Button {
            presentedEditor = .existing(provider)
        } label: {
            ProviderRow(
                provider: provider,
                modelCount: modelCount,
                status: viewModel.status(for: provider.id)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                presentedEditor = .existing(provider)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.blue)
            Button(role: .destructive) {
                Task { await viewModel.delete(provider) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private enum ProviderEditorRoute: Identifiable {
    case new
    case existing(ProviderProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let provider): provider.id.uuidString
        }
    }

    var provider: ProviderProfile? {
        if case .existing(let provider) = self { return provider }
        return nil
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var presetName: String {
        provider.displayName ?? ProviderPreset.preset(for: provider.kind).displayName
    }
}
#endif
