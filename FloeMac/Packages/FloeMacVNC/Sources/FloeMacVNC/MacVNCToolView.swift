// SPDX-License-Identifier: MPL-2.0
//
// Public UI contract for the Mac toolbox VNC remote desktop.
//
// - `MacVNCToolView()` stands alone: it creates its own session owner and is
//   suitable for embedding anywhere.
// - `MacVNCToolView(owner:)` binds a coordinator-owned `MacVNCSessionOwner`
//   so the toolbox keeps close/resume state across appearances; the
//   coordinator calls `drain()` when genuinely leaving (window close, OTA).
//
// Connections open only when a person presses Connect. Dismissing the view
// closes the connection but leaves the owner resumable.

import SwiftUI

public struct MacVNCToolView: View {
    @StateObject private var defaultOwner: MacVNCSessionOwner
    private let externalOwner: MacVNCSessionOwner?

    @Environment(\.locale) private var locale

    @State private var host = ""
    @State private var port = "5900"
    @State private var password = ""
    @State private var validationMessage: String?

    /// Self-contained tool view with its own session owner.
    public init() {
        _defaultOwner = StateObject(wrappedValue: MacVNCSessionOwner())
        externalOwner = nil
    }

    /// Toolbox-integrated tool view bound to a coordinator-owned owner.
    public init(owner: MacVNCSessionOwner) {
        // The default owner stays inert when an external owner is supplied.
        _defaultOwner = StateObject(wrappedValue: MacVNCSessionOwner())
        externalOwner = owner
    }

    private var owner: MacVNCSessionOwner { externalOwner ?? defaultOwner }

    public var body: some View {
        VStack(spacing: 0) {
            if owner.state.isActive {
                statusBar
                Divider()
                remoteArea
            } else {
                connectionForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(owner.state.isActive ? 1 : 0))
        .onAppear(perform: prefill)
        .onDisappear { owner.close() }
    }

    // MARK: - Connection form (idle / closed / failed)

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("远程桌面 (VNC)", "Remote Desktop (VNC)"))
                .font(.title2.weight(.semibold))
            Text(t("连接到你配置的 VNC 服务器。密码只保存在本机内存中。",
                   "Connect to a VNC server you configure. The password stays in this Mac's memory only."))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(t("主机名或 IP 地址", "Host name or IP address"), text: $host)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                TextField(t("端口", "Port"), text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                SecureField(t("密码（可选）", "Password (optional)"), text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Button(t("连接", "Connect")) { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!owner.canConnect)
                if !owner.isSettled {
                    ProgressView().controlSize(.small)
                    Text(t("正在断开…", "Disconnecting…")).foregroundStyle(.secondary)
                }
            }
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.red)
            }
            if let failure = owner.lastFailure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle(for: .failed(failure))).foregroundStyle(.orange)
                    Text(failure.message).foregroundStyle(.secondary)
                    if failure.retryable {
                        Text(t("检查目标后你可以重试。", "You can retry after checking the target."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Active session

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(statusTitle(for: owner.state))
                .font(.callout)
            if let config = owner.lastConfiguration {
                Text("\(config.host):\(config.port)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Label("\(Int(owner.framesPerSecond)) FPS", systemImage: "speedometer")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(t("断开", "Disconnect")) { owner.close() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect)
    }

    @ViewBuilder
    private var remoteArea: some View {
        if let surface = owner.displaySurface {
            MacVNCRemoteSurface(surface: surface)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(owner.state == .connecting
                     ? t("正在连接…", "Connecting…")
                     : t("正在断开…", "Disconnecting…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func prefill() {
        guard let config = owner.lastConfiguration else { return }
        host = config.host
        port = String(config.port)
        password = config.password ?? ""
    }

    private func connect() {
        validationMessage = nil
        let parsedPort = Int(port.trimmingCharacters(in: .whitespaces)) ?? -1
        let config = MacVNCConfiguration(
            host: host,
            port: parsedPort,
            password: password.isEmpty ? nil : password
        )
        do {
            try owner.connect(using: config)
        } catch let error as MacVNCValidationError {
            switch error {
            case .emptyHost:
                validationMessage = t("请输入主机名或 IP 地址。", "Enter a host name or IP address.")
            case .invalidHost(let reason):
                validationMessage = t("主机无效：\(reason)", "Invalid host: \(reason)")
            case .invalidPort:
                validationMessage = t("端口须为 1 至 65535。", "Use a port from 1 to 65535.")
            case .connectionActive:
                validationMessage = t("已有连接正在进行；请先断开。", "A connection is active; disconnect it first.")
            case .ownerDrained:
                validationMessage = t("会话已结束；请重新打开工具。", "The session was drained; reopen the tool.")
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    // MARK: - Presentation

    private func statusTitle(for state: MacVNCConnectionState) -> String {
        switch state {
        case .idle: t("未连接", "Not connected")
        case .connecting: t("正在连接…", "Connecting…")
        case .connected: t("已连接", "Connected")
        case .closing: t("正在断开…", "Disconnecting…")
        case .closed: t("已断开", "Disconnected")
        case .failed: t("连接失败", "Connection failed")
        }
    }

    private var statusColor: Color {
        switch owner.state {
        case .connected: .green
        case .connecting, .closing: .yellow
        case .failed, .closed: .red
        case .idle: .gray
        }
    }

    private func t(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}
