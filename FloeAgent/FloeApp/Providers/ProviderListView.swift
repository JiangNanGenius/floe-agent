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
    @State private var showsProviderTypePicker = false

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: ProviderListViewModel(center: center))
    }

    var body: some View {
        Group {
            if viewModel.providers.isEmpty
                && viewModel.imageProviders.isEmpty
                && viewModel.videoProviders.isEmpty
                && !viewModel.isLoading {
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
                    showsProviderTypePicker = true
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
        .confirmationDialog("添加模型服务商", isPresented: $showsProviderTypePicker) {
            Button("对话模型服务商") { presentedEditor = .new(.conversation) }
            Button("图片生成/编辑服务商") { presentedEditor = .new(.image) }
            Button("视频生成服务商") { presentedEditor = .new(.video) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("先选择用途，再配置端点、凭据和模型能力。")
        }
        .sheet(item: $presentedEditor, onDismiss: {
            Task { await viewModel.load() }
        }) { route in
            NavigationStack {
                ProviderEditorView(
                    center: viewModel.center,
                    existing: route.provider,
                    initialRole: route.role
                )
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
                    providerButton(
                        provider,
                        role: .conversation,
                        modelCount: viewModel.modelCount(for: provider.id)
                    )
                }
            }

            if !viewModel.imageProviders.isEmpty {
                Section {
                    ForEach(viewModel.imageProviders) { provider in
                        providerButton(
                            provider,
                            role: .image,
                            modelCount: viewModel.imageModelCount(for: provider.id)
                        )
                    }
                } header: {
                    Text("图像模型服务商")
                } footer: {
                    Text("用于图片生成与编辑；默认路由在“辅助模型”中设置。")
                }
            }

            if !viewModel.videoProviders.isEmpty {
                Section {
                    ForEach(viewModel.videoProviders) { provider in
                        providerButton(
                            provider,
                            role: .video,
                            modelCount: viewModel.videoModelCount(for: provider.id)
                        )
                    }
                } header: {
                    Text("视频模型服务商")
                } footer: {
                    Text("视频是创意模式的可选增强，不影响私人画布和图片创作。")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func providerButton(
        _ provider: ProviderProfile,
        role: ProviderServiceRole,
        modelCount: Int
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                presentedEditor = .existing(provider, role)
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
            Toggle("providers.enabled", isOn: Binding(
                get: { provider.isEnabled },
                set: { enabled in
                    Task { await viewModel.setEnabled(enabled, provider: provider) }
                }
            ))
            .labelsHidden()
            .tint(FloeTheme.primary)
            .accessibilityIdentifier("providers.enabled.\(provider.id.uuidString)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                presentedEditor = .existing(provider, role)
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
    case new(ProviderServiceRole)
    case existing(ProviderProfile, ProviderServiceRole)

    var id: String {
        switch self {
        case .new(let role): "new-\(role.rawValue)"
        case .existing(let provider, let role): "\(provider.id.uuidString)-\(role.rawValue)"
        }
    }

    var provider: ProviderProfile? {
        if case .existing(let provider, _) = self { return provider }
        return nil
    }

    var role: ProviderServiceRole? {
        switch self {
        case .new(let role), .existing(_, let role): role
        }
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
                if !provider.isEnabled {
                    Text("已停用")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
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
