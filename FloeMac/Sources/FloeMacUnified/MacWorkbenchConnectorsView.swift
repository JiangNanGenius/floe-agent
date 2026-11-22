// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import FloeTools

/// Connector settings for the one configured MCP connection: add or replace
/// the endpoint, enable it deliberately, read the honest status, test
/// discovery, and disable or revoke it. Credential schemes are not accepted
/// on this surface; a server that requires one fails honestly at discovery.
public struct MacWorkbenchConnectorsView: View {
    @ObservedObject public var service: MacWorkbenchConnectorsService

    @State private var name: String = ""
    @State private var endpoint: String = ""
    @State private var allowInsecureHTTP = false
    @State private var saveError: String?
    @State private var confirmsRevoke = false

    public init(service: MacWorkbenchConnectorsService) {
        self.service = service
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MacWorkbenchText.t("MCP 连接器", "MCP Connector")).font(.headline)
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            Divider()
            Form {
                if service.configuration == nil {
                    addSection
                } else {
                    configuredSection
                }
                if let saveError {
                    Section {
                        Text(saveError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workbench.connectors.view")
        .task { await service.restore() }
        .alert(MacWorkbenchText.t("撤销连接器？", "Revoke Connector?"), isPresented: $confirmsRevoke) {
            Button(MacWorkbenchText.t("撤销", "Revoke"), role: .destructive) {
                Task {
                    do { try await service.revoke() }
                    catch { saveError = MacWorkbenchConnectorsService.boundedFailureMessage(error) }
                }
            }
            Button(MacWorkbenchText.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(MacWorkbenchText.t("将断开连接并删除此连接的配置。", "The connection will be disconnected and its configuration deleted."))
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("workbench.connectors.status")
    }

    private var statusColor: Color {
        switch service.status {
        case .ready: .green
        case .discovering: .blue
        case .failed: .red
        case .enabledUntested: .orange
        case .disabled, .unconfigured: .secondary
        }
    }

    private var statusTitle: String {
        switch service.status {
        case .unconfigured: MacWorkbenchText.t("未配置", "Not configured")
        case .disabled: MacWorkbenchText.t("已停用", "Disabled")
        case .enabledUntested: MacWorkbenchText.t("已启用 · 未测试", "Enabled · Not tested")
        case .discovering: MacWorkbenchText.t("正在测试…", "Testing…")
        case .ready(let count): MacWorkbenchText.t("就绪 · \(count) 个工具", "Ready · \(count) tools")
        case .failed: MacWorkbenchText.t("失败", "Failed")
        }
    }

    // MARK: Add

    @ViewBuilder
    private var addSection: some View {
        Section(MacWorkbenchText.t("添加连接", "Add Connection")) {
            TextField(MacWorkbenchText.t("名称", "Name"), text: $name)
                .accessibilityIdentifier("workbench.connectors.name")
            TextField(MacWorkbenchText.t("端点 (https://…)", "Endpoint (https://…)"), text: $endpoint)
                .accessibilityIdentifier("workbench.connectors.endpoint")
            if endpoint.hasPrefix("http://") {
                Toggle(MacWorkbenchText.t("允许明文 HTTP（仅可信本地服务器）",
                                        "Allow plain HTTP (trusted local servers only)"),
                       isOn: $allowInsecureHTTP)
            }
            HStack {
                Spacer()
                Button(MacWorkbenchText.t("保存并启用", "Save & Enable")) {
                    Task { await save(enabled: true) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("workbench.connectors.save")
            }
            Text(MacWorkbenchText.t("仅支持无需凭据的服务器；连接不会被自动调用，工具经审批后才会执行。",
                                    "Only credential-free servers are supported here. The connection is never invoked automatically; tools run only through approval."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Configured

    @ViewBuilder
    private var configuredSection: some View {
        Section(MacWorkbenchText.t("当前连接", "Current Connection")) {
            if let config = service.configuration {
                LabeledContent(MacWorkbenchText.t("名称", "Name"), value: config.server.displayName)
                LabeledContent(MacWorkbenchText.t("端点", "Endpoint"), value: config.server.endpoint.absoluteString)
            }
            Toggle(MacWorkbenchText.t("启用", "Enabled"), isOn: enabledBinding)
                .accessibilityIdentifier("workbench.connectors.enabled")
            HStack {
                Button(MacWorkbenchText.t("测试发现", "Test Discovery")) {
                    Task { await service.testDiscovery() }
                }
                .disabled(service.configuration?.server.enabled != true
                          || service.status == .discovering)
                .accessibilityIdentifier("workbench.connectors.test")
                Spacer()
                if case .ready(let count) = service.status {
                    Text(MacWorkbenchText.t("已发现 \(count) 个工具，已发布到任务作用域。",
                                            "\(count) tool(s) discovered and published to the task scope."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let message) = service.status {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(MacWorkbenchText.t("撤销连接", "Revoke Connection"), role: .destructive) {
                    confirmsRevoke = true
                }
                .accessibilityIdentifier("workbench.connectors.revoke")
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { service.configuration?.server.enabled == true }, set: { enabled in
            Task {
                do { try await service.setEnabled(enabled) }
                catch { saveError = error.localizedDescription }
            }
        })
    }

    private func save(enabled: Bool) async {
        saveError = nil
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)) else {
            saveError = MacWorkbenchText.t("端点不是有效 URL。", "The endpoint is not a valid URL.")
            return
        }
        let server = MCPServerConfiguration(
            displayName: name.trimmingCharacters(in: .whitespaces),
            endpoint: url,
            enabled: enabled,
            allowInsecureHTTP: allowInsecureHTTP && url.scheme?.lowercased() == "http"
        )
        do {
            try await service.configure(server: server)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
