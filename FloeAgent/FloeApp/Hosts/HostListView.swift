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

import FloeCore
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
        .background(FloeTheme.groupedSurface)
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
        .confirmationDialog("hosts.host_list_view.update_the_floe_daemon",
            isPresented: Binding(
                get: { agentUpdateCandidate != nil },
                set: { if !$0 { agentUpdateCandidate = nil } }
            ),
            presenting: agentUpdateCandidate
        ) { host in
            Button(FloeL10n.l("hosts.host_list_view.update", host.displayName.isEmpty ? host.address : host.displayName)) {
                agentUpdateCandidate = nil
                Task { await viewModel.updateRemoteAgent(on: host) }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { agentUpdateCandidate = nil }
        } message: { _ in
            Text("hosts.host_list_view.installs_the_daemon_matching_the_current")
        }
        .confirmationDialog("hosts.host_list_view.set_up_an_advanced_link_for",
            isPresented: Binding(get: { advancedLinkCandidate != nil }, set: { if !$0 { advancedLinkCandidate = nil } }),
            presenting: advancedLinkCandidate
        ) { host in
            Button(FloeL10n.l("hosts.host_list_view.pair", host.displayName.isEmpty ? host.address : host.displayName)) {
                advancedLinkCandidate = nil
                Task { await viewModel.pairAdvancedLink(on: host) }
            }
            Button("workspace.workspace_canvas_view.cancel", role: .cancel) { advancedLinkCandidate = nil }
        } message: { _ in
            Text("hosts.host_list_view.creates_a_device_specific_certificate_over")
        }
        .alert("hosts.host_list_view.host_actions",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil || viewModel.statusMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; viewModel.statusMessage = nil } }
            )
        ) {
            Button("workspace.office_document_editor_view.ok") {
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
                    center: center,
                    sessions: viewModel.sessions(for: host.id),
                    isConnecting: viewModel.connectingHostID == host.id,
                    isUpdatingAgent: viewModel.updatingAgentHostID == host.id,
                    isPairingAgent: viewModel.pairingAgentHostID == host.id,
                    onConnectTerminal: { connectTerminal(host) },
                    onConnectVNC: { endpoint in connectVNC(host, endpoint: endpoint) },
                    onUpdateAgent: { agentUpdateCandidate = host },
                    onPairAdvancedLink: { advancedLinkCandidate = host }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onDelete { offsets in
                let targets = offsets.map { viewModel.hosts[$0] }
                for host in targets {
                    Task { await viewModel.delete(host) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(FloeTheme.groupedSurface)
    }

    private func connectTerminal(_ host: RemoteHostProfile) {
        Task {
            if let sessionID = await viewModel.connectTerminal(to: host) {
                activeTerminalSession = sessionID
            }
        }
    }

    private func connectVNC(_ host: RemoteHostProfile, endpoint: VNCEndpoint) {
        Task {
            if let sessionID = await viewModel.connectVNC(to: host, endpoint: endpoint) {
                activeVNCSession = sessionID
            }
        }
    }
}

/// One adaptive host card shared by Settings and the chat terminal inspector.
/// Secondary maintenance actions live in one overflow menu so narrow columns
/// never compress labels into the vertical stacks seen in the old UI.
private struct HostRow: View {
    let host: RemoteHostProfile
    let center: RemoteSessionCenter
    let sessions: [RemoteSessionSnapshot]
    let isConnecting: Bool
    let isUpdatingAgent: Bool
    let isPairingAgent: Bool
    let onConnectTerminal: () -> Void
    let onConnectVNC: (VNCEndpoint) -> Void
    let onUpdateAgent: () -> Void
    let onPairAdvancedLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName.isEmpty ? host.address : host.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(host.hasSSHConnection
                        ? FloeL10n.l("hosts.host_list_view.ssh", host.user, host.address, host.port)
                        : "hosts.host_list_view.ssh_not_configured")
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

            if !deviceSummary.isEmpty {
                Label(deviceSummary, systemImage: deviceIcon)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                NavigationLink {
                    HostEditorView(center: center, existing: host)
                } label: {
                    actionLabel("workspace.workspace_canvas_view.edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                if host.hasSSHConnection {
                    Button {
                        onConnectTerminal()
                    } label: {
                        actionLabel("hosts.terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                }

                if !host.vncEndpoints.isEmpty {
                    Menu {
                        ForEach(host.vncEndpoints) { endpoint in
                            Button {
                                onConnectVNC(endpoint)
                            } label: {
                                Label(
                                    endpoint.displayName,
                                    systemImage: endpoint.transport == .direct ? "network" : "lock.shield"
                                )
                            }
                        }
                    } label: {
                        actionLabel("hosts.vnc", systemImage: "display")
                    }
                    .buttonStyle(.bordered)
                }

                if host.hasSSHConnection {
                    Spacer(minLength: 0)
                    Menu {
                        if host.isRemoteExecutionEnvironment {
                            Button(action: onUpdateAgent) {
                                Label("hosts.host_list_view.update_floe_daemon", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        Button(action: onPairAdvancedLink) {
                            Label("hosts.host_list_view.pair_advanced_link", systemImage: "lock.shield")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isConnecting || isUpdatingAgent || isPairingAgent)
                    .accessibilityLabel("hosts.host_list_view.more_host_actions")
                }
            }
        }
        .padding(14)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(FloeTheme.Typography.metadata.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 28)
    }

    private var deviceIcon: String {
        switch host.deviceKind {
        case .linux, .windows: "desktopcomputer"
        case .mac: "macmini"
        case .nas: "externaldrive.connected.to.line.below"
        case .router, .switchDevice: "network"
        case .appliance: "cpu"
        case .unspecified, .other: "server.rack"
        }
    }

    private var deviceSummary: String {
        let type: String = switch host.deviceKind {
        case .unspecified: ""
        case .linux: "Linux"
        case .mac: "Mac"
        case .windows: "Windows"
        case .nas: "NAS"
        case .router: FloeL10n.l("hosts.host_editor_view.router")
        case .switchDevice: FloeL10n.l("hosts.host_editor_view.switch")
        case .appliance: FloeL10n.l("hosts.host_editor_view.network_device")
        case .other: FloeL10n.l("hosts.host_editor_view.other_devices")
        }
        let role = host.isRemoteExecutionEnvironment ? FloeL10n.l("hosts.host_list_view.remote_execution_environment") : FloeL10n.l("hosts.host_list_view.debug_target")
        let extra = host.auxiliaryConnections.map { $0.kind.rawValue }.joined(separator: " · ")
        return [type, role, extra].filter { !$0.isEmpty }.joined(separator: " · ")
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
