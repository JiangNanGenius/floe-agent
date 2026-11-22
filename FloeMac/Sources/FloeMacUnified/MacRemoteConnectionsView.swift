// SPDX-License-Identifier: MPL-2.0
//
// MacRemoteConnectionsView — embeddable task-side remote connection surface.
//
// One view per task, bound to that task's ``MacTaskRemoteConnectionsOwner``
// and the workbench-shared ``MacRemoteConnectionsCatalog``. It renders the
// saved-host list, explicit Connect / Disconnect / Reconnect actions and the
// live SSH/VNC state. Everything connects only on a user's button press:
// the SSH terminal is the task's existing interactive PTY (system OpenSSH
// host-key and password prompts stay in the terminal), and a VNC password is
// entered per connect and kept in memory only. The coordinator embeds this
// view in the task inspector; no route is added here.

import AppKit
import FloeMacTerminal
import FloeMacVNC
import SwiftUI

public struct MacRemoteConnectionsView: View {

    @ObservedObject public var owner: MacTaskRemoteConnectionsOwner
    @ObservedObject public var catalog: MacRemoteConnectionsCatalog

    @Environment(\.locale) private var locale

    @State private var selection: UUID?
    @State private var showAddHost = false
    @State private var actionError: String?
    @State private var vncPasswords: [UUID: String] = [:]

    public init(owner: MacTaskRemoteConnectionsOwner, catalog: MacRemoteConnectionsCatalog) {
        self.owner = owner
        self.catalog = catalog
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            Divider()
            if catalog.hosts.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    hostList
                        .frame(width: 220)
                    Divider()
                    detailPane
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAddHost) {
            MacRemoteHostEditorView(catalog: catalog)
        }
        .task { await catalog.reload() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("远程连接", "Remote Connections"))
                .font(.headline)
            Spacer()
            Button {
                showAddHost = true
            } label: {
                Label(t("添加主机", "Add Host"), systemImage: "plus")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(t("还没有已保存的主机。", "No saved hosts yet."))
                .foregroundStyle(.secondary)
            Button(t("添加主机", "Add Host")) { showAddHost = true }
                .buttonStyle(.borderedProminent)
            Text(t(
                "保存主机只会记录名称和地址，不会保存密码。SSH 的主机密钥确认和密码输入会在终端中完成；VNC 密码仅在每次连接时输入，并只保留在本机内存中。",
                "Saving a host stores only its name and address, never a password. SSH host-key confirmation and password entry happen in the terminal; a VNC password is entered per connection and stays in this Mac's memory only."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Host list

    private var hostList: some View {
        List(selection: $selection) {
            ForEach(catalog.hosts) { host in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.displayName)
                            .lineLimit(1)
                        Text(hostSummary(host))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    statusDots(for: host)
                }
                .tag(host.id)
                .contextMenu {
                    Button(t("删除主机", "Delete Host"), role: .destructive) {
                        Task { try? await catalog.deleteHost(id: host.id) }
                    }
                }
                .accessibilityIdentifier("remote.host.\(host.id.uuidString)")
            }
        }
    }

    private func hostSummary(_ host: MacRemoteHostProfile) -> String {
        var parts: [String] = []
        if host.hasSSHConnection { parts.append("SSH \(host.address)") }
        if !host.vncEndpoints.isEmpty {
            parts.append(t("\(host.vncEndpoints.count) 个 VNC 端点", "\(host.vncEndpoints.count) VNC endpoint\(host.vncEndpoints.count == 1 ? "" : "s")"))
        }
        return parts.isEmpty ? t("仅元数据", "Metadata only") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusDots(for host: MacRemoteHostProfile) -> some View {
        HStack(spacing: 4) {
            if host.hasSSHConnection {
                Circle()
                    .fill(sshDotColor)
                    .frame(width: 8, height: 8)
                    .help(t("SSH 状态", "SSH state"))
            }
            if !host.vncEndpoints.isEmpty {
                Circle()
                    .fill(vncDotColor)
                    .frame(width: 8, height: 8)
                    .help(t("VNC 状态", "VNC state"))
            }
        }
    }

    private var sshDotColor: Color {
        switch owner.sshState {
        case .running: return .green
        case .stopping: return .orange
        case .exited: return .red
        case .idle: return Color(nsColor: .separatorColor)
        }
    }

    private var vncDotColor: Color {
        switch owner.vncOwner.state {
        case .connected: return .green
        case .connecting, .closing: return .yellow
        case .failed, .closed: return .red
        case .idle: return Color(nsColor: .separatorColor)
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let host = catalog.hosts.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(host.displayName).font(.title3.weight(.semibold))
                    if host.hasSSHConnection {
                        sshSection(host)
                    }
                    ForEach(host.vncEndpoints) { endpoint in
                        vncSection(host: host, endpoint: endpoint)
                    }
                    if !host.hasSSHConnection && host.vncEndpoints.isEmpty {
                        Text(t("此主机没有可连接的端点。", "This host has no connectable endpoints."))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.to.line")
                    .foregroundStyle(.secondary)
                Text(t("选择一个已保存的主机。", "Choose a saved host."))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sshSection(_ host: MacRemoteHostProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(sshDotColor).frame(width: 8, height: 8)
                Text(t("SSH 终端", "SSH Terminal")).font(.headline)
                Spacer()
                Text(sshStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(host.user.isEmpty ? "" : "\(host.user)@")\(host.address):\(host.port)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(t("连接", "Connect")) {
                    Task { await connectSSH(hostID: host.id) }
                }
                .disabled(!canConnectSSH)
                Button(t("断开", "Disconnect")) {
                    Task { await owner.disconnectSSH() }
                }
                .disabled(!canDisconnectSSH)
                Button(t("重新连接", "Reconnect")) {
                    Task { await reconnectSSH() }
                }
                .disabled(!canReconnectSSH)
            }
            .buttonStyle(.bordered)
            Text(t(
                "连接后终端会打开此主机的交互式 SSH。首次连接的主机密钥确认和密码输入显示在终端中，由系统 OpenSSH 完成。",
                "Connecting opens an interactive SSH to this host in the terminal. Host-key confirmation and password entry appear in the terminal through the system OpenSSH."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sectionCard()
    }

    private func vncSection(host: MacRemoteHostProfile, endpoint: MacRemoteVNCEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(vncDotColor).frame(width: 8, height: 8)
                Text(endpoint.displayName).font(.headline)
                Spacer()
                Text(vncStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(endpoint.host):\(endpoint.port)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            SecureField(t("密码（可选）", "Password (optional)"), text: Binding(
                get: { vncPasswords[endpoint.id] ?? "" },
                set: { vncPasswords[endpoint.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(t("连接", "Connect")) {
                    Task { await connectVNC(endpointID: endpoint.id) }
                }
                .disabled(!owner.vncOwner.canConnect)
                Button(t("断开", "Disconnect")) {
                    owner.disconnectVNC()
                }
                .disabled(!owner.vncOwner.state.isActive)
                Button(t("重新连接", "Reconnect")) {
                    Task { await reconnectVNC(endpointID: endpoint.id) }
                }
                .disabled(!canReconnectVNC(endpointID: endpoint.id))
            }
            .buttonStyle(.bordered)
        }
        .sectionCard()
    }

    // MARK: Actions

    private var canConnectSSH: Bool {
        // idle, and exited (the terminal owner resets an exited session on
        // the next start) both accept an explicit new connect.
        switch owner.sshState {
        case .idle, .exited: return true
        case .running, .stopping: return false
        }
    }

    private var canDisconnectSSH: Bool {
        if case .running = owner.sshState { return true }
        if case .stopping = owner.sshState { return true }
        return false
    }

    private var canReconnectSSH: Bool {
        guard owner.lastSSHHostID != nil || owner.activeSSHHostID != nil else { return false }
        return canConnectSSH
    }

    private func canReconnectVNC(endpointID: UUID) -> Bool {
        guard owner.vncOwner.canConnect else { return false }
        guard (owner.lastVNCEndpointID ?? owner.activeVNCEndpointID) == endpointID else { return false }
        return (vncPasswords[endpointID] ?? "").isEmpty == false
    }

    private func connectSSH(hostID: UUID) async {
        actionError = nil
        do {
            try await owner.connectSSH(hostID: hostID)
        } catch {
            actionError = errorMessage(error)
        }
    }

    private func reconnectSSH() async {
        actionError = nil
        do {
            try await owner.reconnectSSH()
        } catch {
            actionError = errorMessage(error)
        }
    }

    private func connectVNC(endpointID: UUID) async {
        actionError = nil
        do {
            try await owner.connectVNC(endpointID: endpointID, password: vncPasswords[endpointID])
        } catch {
            actionError = errorMessage(error)
        }
    }

    private func reconnectVNC(endpointID: UUID) async {
        actionError = nil
        do {
            try await owner.reconnectVNC(password: vncPasswords[endpointID])
        } catch {
            actionError = errorMessage(error)
        }
    }

    private var sshStatusText: String {
        // An interactive OpenSSH PTY starting means the terminal process is
        // running — the user may still be answering the host-key or password
        // prompt. Only a VNC transport reaching `.connected` proves an
        // authenticated connection, so SSH is presented as "started".
        switch owner.sshState {
        case .idle: return t("未启动", "Not started")
        case .running: return t("终端已启动", "Terminal started")
        case .stopping: return t("正在结束…", "Ending…")
        case .exited: return t("已结束", "Ended")
        }
    }

    private var vncStatusText: String {
        switch owner.vncOwner.state {
        case .idle: return t("未连接", "Not connected")
        case .connecting: return t("正在连接…", "Connecting…")
        case .connected: return t("已连接", "Connected")
        case .closing: return t("正在断开…", "Disconnecting…")
        case .closed: return t("已断开", "Disconnected")
        case .failed: return t("连接失败", "Connection failed")
        }
    }

    private func errorMessage(_ error: Error) -> String {
        if let error = error as? MacRemoteConnectionsError { return error.message }
        if let error = error as? MacSSHHostValidationError { return error.message }
        if let error = error as? MacVNCValidationError {
            switch error {
            case .emptyHost: return t("请输入主机名或 IP 地址。", "Enter a host name or IP address.")
            case .invalidHost(let reason): return t("主机无效：\(reason)", "Invalid host: \(reason)")
            case .invalidPort: return t("端口须为 1 至 65535。", "Use a port from 1 to 65535.")
            case .connectionActive: return t("已有连接正在进行；请先断开。", "A connection is active; disconnect it first.")
            case .ownerDrained: return t("会话已结束；请重新打开工具。", "The session was drained; reopen the tool.")
            }
        }
        return t("操作失败，请检查主机设置后重试。", "The action failed. Check the host settings and try again.")
    }

    private func t(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}

// MARK: - Add-host editor

/// Metadata-only host editor. No credential fields exist by design: SSH
/// secrets are handled by the system OpenSSH in the terminal and the VNC
/// password is entered per connection.
struct MacRemoteHostEditorView: View {

    @ObservedObject var catalog: MacRemoteConnectionsCatalog
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var displayName = ""
    @State private var sshAddress = ""
    @State private var sshPort = "22"
    @State private var sshUser = ""
    @State private var vncName = "VNC"
    @State private var vncHost = ""
    @State private var vncPort = "5900"
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("添加主机", "Add Host")).font(.headline)
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }
            }
            .padding()
            Divider()
            Form {
                TextField(t("名称", "Name"), text: $displayName)
                    .textFieldStyle(.roundedBorder)
                Section(t("SSH（可选）", "SSH (optional)")) {
                    TextField(t("主机地址", "Host address"), text: $sshAddress)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField(t("端口", "Port"), text: $sshPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        TextField(t("用户名（可选）", "User (optional)"), text: $sshUser)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Section(t("VNC 端点（可选）", "VNC endpoint (optional)")) {
                    TextField(t("端点名称", "Endpoint name"), text: $vncName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField(t("主机地址", "Host address"), text: $vncHost)
                            .textFieldStyle(.roundedBorder)
                        TextField(t("端口", "Port"), text: $vncPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }
            }
            .formStyle(.grouped)
            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.caption)
                    .padding(.horizontal)
            }
            HStack {
                Spacer()
                Button(t("保存主机", "Save Host")) { Task { await save() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 430)
    }

    private func save() async {
        saveError = nil
        var endpoints: [MacRemoteVNCEndpoint] = []
        if !vncHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endpoints.append(MacRemoteVNCEndpoint(
                displayName: vncName,
                host: vncHost,
                port: Int(vncPort.trimmingCharacters(in: .whitespaces)) ?? 5900
            ))
        }
        let profile = MacRemoteHostProfile(
            displayName: displayName,
            address: sshAddress,
            port: Int(sshPort.trimmingCharacters(in: .whitespaces)) ?? 22,
            user: sshUser,
            vncEndpoints: endpoints
        )
        do {
            try await catalog.addHost(profile)
            dismiss()
        } catch let error as MacRemoteConnectionsError {
            saveError = error.message
        } catch {
            saveError = t("保存失败，请检查填写内容。", "Saving failed. Check the entered values.")
        }
    }

    private func t(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}

private extension View {
    func sectionCard() -> some View {
        padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
