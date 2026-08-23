// FloeApp — Host list (Hosts tab root).
//
// SPDX-License-Identifier: MPL-2.0
//
// Host CRUD + connect (SSH terminal / VNC). Honest per-host session
// status. The TOFU trust sheet is presented when the center surfaces a
// pending host-key prompt.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloeSSH

/// The Hosts tab root.
struct HostListView: View {
    @StateObject private var viewModel: HostListViewModel
    @ObservedObject var center: RemoteSessionCenter

    @State private var activeTerminalSession: UUID?
    @State private var activeVNCSession: UUID?
    @State private var agentUpdateCandidate: RemoteHostProfile?
    @State private var advancedLinkCandidate: RemoteHostProfile?

    init(center: RemoteSessionCenter) {
        self.center = center
        _viewModel = StateObject(wrappedValue: HostListViewModel(center: center))
    }

    var body: some View {
        Group {
            if viewModel.hosts.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("tab.hosts", systemImage: "server.rack")
                } description: {
                    Text("empty.hosts")
                }
            } else {
                hostList
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("tab.hosts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    HostEditorView(center: center, existing: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("hosts.add")
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: pendingTrustBinding) { trust in
            HostKeyTrustSheet(challenge: trust.challenge) { trusted in
                center.resolveTrust(trusted)
            }
        }
        .navigationDestination(item: $activeTerminalSession) { sessionID in
            TerminalView(sessionID: sessionID, center: center)
        }
        .navigationDestination(item: $activeVNCSession) { sessionID in
            VNCView(sessionID: sessionID, center: center)
        }
        .confirmationDialog(
            "更新 Floe 守护程序？",
            isPresented: Binding(
                get: { agentUpdateCandidate != nil },
                set: { if !$0 { agentUpdateCandidate = nil } }
            ),
            presenting: agentUpdateCandidate
        ) { host in
            Button("更新 \(host.displayName.isEmpty ? host.address : host.displayName)") {
                agentUpdateCandidate = nil
                Task { await viewModel.updateRemoteAgent(on: host) }
            }
            Button("取消", role: .cancel) { agentUpdateCandidate = nil }
        } message: { _ in
            Text("将通过已验证的 SSH 安装与当前 Floe 版本配套的守护程序；更新失败会自动回滚。")
        }
        .confirmationDialog(
            "为本设备建立高级链路？",
            isPresented: Binding(get: { advancedLinkCandidate != nil }, set: { if !$0 { advancedLinkCandidate = nil } }),
            presenting: advancedLinkCandidate
        ) { host in
            Button("配对 \(host.displayName.isEmpty ? host.address : host.displayName)") {
                advancedLinkCandidate = nil
                Task { await viewModel.pairAdvancedLink(on: host) }
            }
            Button("取消", role: .cancel) { advancedLinkCandidate = nil }
        } message: { _ in
            Text("通过已验证 SSH 创建本设备专属证书；私钥只保存在本设备。之后日常任务走 mTLS，SSH 仅用于救援。")
        }
        .alert(
            "主机操作",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil || viewModel.statusMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; viewModel.statusMessage = nil } }
            )
        ) {
            Button("好") {
                viewModel.errorMessage = nil
                viewModel.statusMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? viewModel.statusMessage ?? "")
        }
    }

    /// Bridges the center's @Published pendingTrust into a sheet binding.
    private var pendingTrustBinding: Binding<RemoteSessionCenter.PendingHostKeyTrust?> {
        Binding(
            get: { center.pendingTrust },
            set: { _ in } // resolved only via resolveTrust
        )
    }

    private var hostList: some View {
        List {
            ForEach(viewModel.hosts) { host in
                HostRow(
                    host: host,
                    sessions: viewModel.sessions(for: host.id),
                    isConnecting: viewModel.connectingHostID == host.id,
                    isUpdatingAgent: viewModel.updatingAgentHostID == host.id,
                    isPairingAgent: viewModel.pairingAgentHostID == host.id,
                    onConnectTerminal: { connectTerminal(host) },
                    onConnectVNC: { connectVNC(host) },
                    onUpdateAgent: { agentUpdateCandidate = host },
                    onPairAdvancedLink: { advancedLinkCandidate = host }
                )
            }
            .onDelete { offsets in
                let targets = offsets.map { viewModel.hosts[$0] }
                for host in targets {
                    Task { await viewModel.delete(host) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func connectTerminal(_ host: RemoteHostProfile) {
        Task {
            if let sessionID = await viewModel.connectTerminal(to: host) {
                activeTerminalSession = sessionID
            }
        }
    }

    private func connectVNC(_ host: RemoteHostProfile) {
        Task {
            if let sessionID = await viewModel.connectVNC(to: host) {
                activeVNCSession = sessionID
            }
        }
    }
}

/// One host row: name/address, session status, connect buttons.
private struct HostRow: View {
    let host: RemoteHostProfile
    let sessions: [RemoteSessionSnapshot]
    let isConnecting: Bool
    let isUpdatingAgent: Bool
    let isPairingAgent: Bool
    let onConnectTerminal: () -> Void
    let onConnectVNC: () -> Void
    let onUpdateAgent: () -> Void
    let onPairAdvancedLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName.isEmpty ? host.address : host.displayName)
                        .font(FloeTheme.Typography.body)
                    Text("\(host.user)@\(host.address):\(host.port)")
                        .font(FloeTheme.Typography.evidence)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isConnecting || isUpdatingAgent || isPairingAgent {
                    ProgressView()
                } else if let session = sessions.first {
                    SessionDot(state: session.record.state)
                }
            }
            HStack(spacing: 12) {
                Button {
                    onConnectTerminal()
                } label: {
                    Label("hosts.terminal", systemImage: "terminal")
                        .font(FloeTheme.Typography.metadata)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: FloeTheme.minimumTarget)

                if host.vncEndpoint != nil {
                    Button {
                        onConnectVNC()
                    } label: {
                        Label("hosts.vnc", systemImage: "display")
                            .font(FloeTheme.Typography.metadata)
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: FloeTheme.minimumTarget)
                }

                Button {
                    onUpdateAgent()
                } label: {
                    Label("更新守护程序", systemImage: "arrow.triangle.2.circlepath")
                        .font(FloeTheme.Typography.metadata)
                }
                .buttonStyle(.bordered)
                .disabled(isConnecting || isUpdatingAgent || isPairingAgent)
                .frame(minHeight: FloeTheme.minimumTarget)

                Button(action: onPairAdvancedLink) {
                    Label("配对高级链路", systemImage: "lock.shield")
                        .font(FloeTheme.Typography.metadata)
                }
                .buttonStyle(.bordered)
                .disabled(isConnecting || isUpdatingAgent || isPairingAgent)
                .frame(minHeight: FloeTheme.minimumTarget)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small honest session-state dot.
private struct SessionDot: View {
    let state: RemoteSessionRecord.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityLabel(accessibilityText)
    }

    private var color: Color {
        switch state {
        case .connected: FloeTheme.success
        case .connecting: FloeTheme.primary
        case .suspended: FloeTheme.pending
        case .disconnected: FloeTheme.destructive
        case .unknown: FloeTheme.unknown
        }
    }

    private var accessibilityText: String {
        switch state {
        case .connected: String(localized: "session.connected")
        case .connecting: String(localized: "session.connecting")
        case .suspended: String(localized: "session.suspended")
        case .disconnected: String(localized: "state.disconnected")
        case .unknown: String(localized: "state.unknown")
        }
    }
}
#endif
