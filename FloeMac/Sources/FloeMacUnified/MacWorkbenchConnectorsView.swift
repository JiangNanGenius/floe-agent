// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import FloeTools

/// Connector settings for the user's MCP connections, mirroring the iPad
/// `MCPServersView` / `MCPServerEditor`: a list of configured servers with
/// honest per-server health, an editor sheet supporting none / Bearer /
/// custom-header authentication with Keychain-backed credentials, per-tool
/// enable switches, explicit discovery testing, and disable/remove. English
/// and Simplified Chinese stay aligned through `MacWorkbenchText`.
public struct MacWorkbenchConnectorsView: View {
    @ObservedObject public var service: MacWorkbenchConnectorsService

    @State private var editing: MacWorkbenchConnectorEditorTarget?
    @State private var actionError: String?

    public init(service: MacWorkbenchConnectorsService) {
        self.service = service
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MacWorkbenchText.t("MCP 连接器", "MCP Connector")).font(.headline)
                Spacer()
                Button(MacWorkbenchText.t("添加服务器", "Add Server")) {
                    editing = .new
                }
                .accessibilityIdentifier("workbench.connectors.add")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            Divider()
            Form {
                if let restoreError = service.restoreError {
                    Section {
                        Text(restoreError).font(.caption).foregroundStyle(.red)
                    } header: {
                        Text(MacWorkbenchText.t("读取设置失败", "Settings Read Failed"))
                    }
                }
                if service.servers.isEmpty {
                    Section {
                        ContentUnavailableView(
                            MacWorkbenchText.t("尚未添加 MCP 服务器", "No MCP Server Added Yet"),
                            systemImage: "network",
                            description: Text(MacWorkbenchText.t(
                                "添加标准 Streamable HTTP 远程工具服务器。",
                                "Add a standard Streamable-HTTP remote tools server."))
                        )
                    }
                }
                ForEach(service.servers) { server in
                    Section {
                        serverRow(server)
                    } header: {
                        Text(verbatim: server.displayName)
                    } footer: {
                        if let originNote = advertisedNote(for: server) {
                            Text(originNote).font(.caption2)
                        }
                    }
                }
                if let actionError {
                    Section {
                        Text(actionError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workbench.connectors.view")
        .task { await service.restore() }
        .sheet(item: $editing) { target in
            MacWorkbenchConnectorEditorSheet(
                service: service,
                serverID: target.serverID,
                actionError: $actionError
            )
        }
    }

    // MARK: Server row

    @ViewBuilder
    private func serverRow(_ server: MCPServerConfiguration) -> some View {
        HStack(spacing: 12) {
            Image(systemName: stateIcon(service.statusByID[server.id]))
                .foregroundStyle(stateColor(service.statusByID[server.id]))
            VStack(alignment: .leading, spacing: 3) {
                Text(server.endpoint.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(stateText(service.statusByID[server.id]))
                    .font(.caption2).foregroundStyle(.secondary)
                if server.authentication != .none {
                    Label(
                        MacWorkbenchText.t("凭据保存在本机钥匙串", "Credential stored in this Mac's Keychain"),
                        systemImage: "key.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(MacWorkbenchText.t("启用", "Enabled"), isOn: enabledBinding(for: server))
                .labelsHidden()
                .accessibilityIdentifier("workbench.connectors.enabled.\(server.id.uuidString)")
        }
        HStack {
            Button(MacWorkbenchText.t("测试发现", "Test Discovery")) {
                Task { await service.testDiscovery(serverID: server.id) }
            }
            .disabled(!server.enabled || service.statusByID[server.id] == .discovering)
            .accessibilityIdentifier("workbench.connectors.test.\(server.id.uuidString)")
            Spacer()
            if case .ready(let count) = service.statusByID[server.id] {
                Text(MacWorkbenchText.t("已发现 \(count) 个工具", "Discovered \(count) tool(s)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if case .failed(let message) = service.statusByID[server.id] {
            Text(message).font(.caption).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button(MacWorkbenchText.t("编辑服务器…", "Edit Server…")) {
                editing = .existing(server.id)
            }
            Button(MacWorkbenchText.t("移除服务器", "Remove Server"), role: .destructive) {
                Task {
                    do { try await service.remove(serverID: server.id) }
                    catch { actionError = MacWorkbenchConnectorsService.boundedFailureMessage(error) }
                }
            }
            .accessibilityIdentifier("workbench.connectors.remove.\(server.id.uuidString)")
        }
    }

    private func advertisedNote(for server: MCPServerConfiguration) -> String? {
        let advertised = service.toolOrigins.values.filter { $0.serverID == server.id }.count
        let discovered = service.discoveredToolsByID[server.id]?.count ?? 0
        guard advertised > 0 else {
            return discovered > 0
                ? MacWorkbenchText.t("工具已发现但未进入当前任务范围（超出预算或已停用）。",
                                     "Tools discovered but not in the current task scope (over budget or disabled).")
                : nil
        }
        guard discovered > advertised else { return nil }
        return MacWorkbenchText.t("已发布 \(advertised)/\(discovered) 个工具到任务范围。",
                                  "Advertising \(advertised)/\(discovered) tool(s) to the task scope.")
    }

    private func enabledBinding(for server: MCPServerConfiguration) -> Binding<Bool> {
        Binding(get: { server.enabled }, set: { enabled in
            Task {
                do { try await service.setEnabled(enabled, serverID: server.id) }
                catch { actionError = MacWorkbenchConnectorsService.boundedFailureMessage(error) }
            }
        })
    }

    // MARK: Presentation helpers

    private func stateText(_ state: MacWorkbenchConnectorStatus?) -> String {
        switch state {
        case .none, .unconfigured: MacWorkbenchText.t("未配置", "Not configured")
        case .disabled: MacWorkbenchText.t("已停用", "Disabled")
        case .enabledUntested: MacWorkbenchText.t("已启用 · 未测试", "Enabled · Not tested")
        case .discovering: MacWorkbenchText.t("正在测试…", "Testing…")
        case .ready(let count): MacWorkbenchText.t("就绪 · \(count) 个工具", "Ready · \(count) tools")
        case .failed: MacWorkbenchText.t("失败", "Failed")
        }
    }

    private func stateIcon(_ state: MacWorkbenchConnectorStatus?) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .discovering: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .disabled, .enabledUntested: "circle.lefthalf.filled"
        case .none, .unconfigured: "circle"
        }
    }

    private func stateColor(_ state: MacWorkbenchConnectorStatus?) -> Color {
        switch state {
        case .ready: .green
        case .discovering: .blue
        case .failed: .red
        case .enabledUntested: .orange
        case .disabled, .none, .unconfigured: .secondary
        }
    }
}

// MARK: - Editor sheet

enum MacWorkbenchConnectorEditorTarget: Identifiable {
    case new
    case existing(UUID)

    var serverID: UUID? {
        switch self {
        case .new: nil
        case .existing(let id): id
        }
    }

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let id): id.uuidString
        }
    }
}

/// The server editor: identity, endpoint, authentication scheme + credential,
/// network security, per-tool switches, and health diagnostics. All durable
/// effects flow through `MacWorkbenchConnectorsService.configure`.
struct MacWorkbenchConnectorEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: MacWorkbenchConnectorsService
    let serverID: UUID?
    @Binding var actionError: String?

    @State private var displayName = ""
    @State private var endpointText = ""
    @State private var enabled = true
    @State private var authentication: MCPServerConfiguration.Authentication = .none
    @State private var credentialHeaderName = "Authorization"
    @State private var credential = ""
    @State private var allowInsecureHTTP = false
    @State private var disabledRemoteToolNames: Set<String> = []
    @State private var isSaving = false
    @State private var validationMessage: String?

    init(service: MacWorkbenchConnectorsService, serverID: UUID?, actionError: Binding<String?>) {
        self.service = service
        self.serverID = serverID
        self._actionError = actionError
        if let serverID, let server = service.servers.first(where: { $0.id == serverID }) {
            _displayName = State(initialValue: server.displayName)
            _endpointText = State(initialValue: server.endpoint.absoluteString)
            _enabled = State(initialValue: server.enabled)
            _authentication = State(initialValue: server.authentication)
            _credentialHeaderName = State(initialValue: server.credentialHeaderName)
            _allowInsecureHTTP = State(initialValue: server.allowInsecureHTTP)
            _disabledRemoteToolNames = State(initialValue: server.disabledRemoteToolNames)
        }
    }

    private var hasStoredCredential: Bool {
        guard let serverID,
              let server = service.servers.first(where: { $0.id == serverID }),
              server.authentication != .none else { return false }
        // Synchronous display hint; the authoritative read happens on save.
        return server.authentication == authentication
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(MacWorkbenchText.t("名称", "Name"), text: $displayName)
                        .accessibilityIdentifier("workbench.connectors.editor.name")
                    TextField(MacWorkbenchText.t("端点 (https://…)", "Endpoint (https://…)"), text: $endpointText)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("workbench.connectors.editor.endpoint")
                    Toggle(MacWorkbenchText.t("启用", "Enabled"), isOn: $enabled)
                } header: {
                    Text(MacWorkbenchText.t("服务器", "Server"))
                } footer: {
                    Text(MacWorkbenchText.t(
                        "连接不会被自动调用；发现工具经审批后才会在任务中执行。",
                        "The connection is never invoked automatically; discovered tools run through approval."))
                }

                Section(MacWorkbenchText.t("身份验证", "Authentication")) {
                    Picker(MacWorkbenchText.t("方式", "Method"), selection: $authentication) {
                        Text(MacWorkbenchText.t("无", "None")).tag(MCPServerConfiguration.Authentication.none)
                        Text("Bearer Token").tag(MCPServerConfiguration.Authentication.bearerToken)
                        Text(MacWorkbenchText.t("自定义请求头", "Custom Header"))
                            .tag(MCPServerConfiguration.Authentication.customHeader)
                    }
                    if authentication == .customHeader {
                        TextField(MacWorkbenchText.t("请求头名称", "Header name"), text: $credentialHeaderName)
                            .autocorrectionDisabled()
                    }
                    if authentication != .none {
                        SecureField(
                            hasStoredCredential
                                ? MacWorkbenchText.t("输入新凭据以替换", "Enter a new credential to replace it")
                                : MacWorkbenchText.t("凭据", "Credential"),
                            text: $credential
                        )
                        .accessibilityIdentifier("workbench.connectors.editor.credential")
                        if hasStoredCredential {
                            Label(MacWorkbenchText.t("凭据已保存在本机钥匙串。更改端点或验证方式后需要重新输入。",
                                                     "Credential stored on this Mac's Keychain. Re-enter it after changing the endpoint or method."),
                                  systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(MacWorkbenchText.t("网络安全", "Network Security")) {
                    Toggle(MacWorkbenchText.t("允许明文 HTTP（仅可信本地服务器）",
                                            "Allow plain HTTP (trusted local servers only)"),
                           isOn: $allowInsecureHTTP)
                }

                if let serverID,
                   let tools = service.discoveredToolsByID[serverID], !tools.isEmpty {
                    Section {
                        ForEach(tools, id: \.remoteName) { tool in
                            Toggle(isOn: Binding(
                                get: { !disabledRemoteToolNames.contains(tool.remoteName) },
                                set: { newValue in
                                    if newValue { disabledRemoteToolNames.remove(tool.remoteName) }
                                    else { disabledRemoteToolNames.insert(tool.remoteName) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.displayName ?? tool.remoteName)
                                    Text(tool.toolDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } header: {
                        Text(MacWorkbenchText.t("工具", "Tools"))
                    } footer: {
                        Text(MacWorkbenchText.t(
                            "停用的工具不会发布到任务范围；任务范围的工具总数有上限，超出预算的工具保持已发现状态。",
                            "Disabled tools are not published to the task scope; the total advertised tool count is bounded and over-budget tools stay discovered."))
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(displayName.isEmpty
                             ? MacWorkbenchText.t("添加 MCP 服务器", "Add MCP Server")
                             : displayName)
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MacWorkbenchText.t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(MacWorkbenchText.t("保存并连接", "Save & Connect")) { save() }
                        .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || endpointText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("workbench.connectors.editor.save")
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        actionError = nil
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = MacWorkbenchText.t("端点不是有效 URL。", "The endpoint is not a valid URL.")
            return
        }
        let server = MCPServerConfiguration(
            id: serverID ?? UUID(),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint,
            enabled: enabled,
            allowInsecureHTTP: allowInsecureHTTP && endpoint.scheme?.lowercased() == "http",
            authentication: authentication,
            credentialHeaderName: credentialHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            disabledRemoteToolNames: disabledRemoteToolNames
        )
        isSaving = true
        Task {
            do {
                try await service.configure(
                    server: server,
                    credential: credential.isEmpty ? nil : credential
                )
                dismiss()
            } catch {
                validationMessage = MacWorkbenchConnectorsService.boundedFailureMessage(error)
                isSaving = false
            }
        }
    }
}
