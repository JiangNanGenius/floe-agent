// FloeApp — Host editor.
//
// SPDX-License-Identifier: MPL-2.0
//
// Add/edit a host: address/port/user, auth method, host-key policy,
// optional VNC endpoint. Secrets are written to Keychain only; the form
// never displays a stored secret.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSSH

/// The host editor form.
struct HostEditorView: View {
    @StateObject private var viewModel: HostEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(center: RemoteSessionCenter, existing: RemoteHostProfile?) {
        _viewModel = StateObject(
            wrappedValue: HostEditorViewModel(center: center, existing: existing)
        )
    }

    var body: some View {
        Form {
            deviceSection
            sshSection
            vncSection
            auxiliaryConnectionsSection
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                }
            }
        }
        .navigationTitle(viewModel.existing == nil
            ? LocalizedStringKey("hosts.add")
            : LocalizedStringKey("hosts.edit"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") { save() }
                    .disabled(!viewModel.canSave || viewModel.isSaving)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
    }

    private var deviceSection: some View {
        Section {
            TextField("设备名称", text: $viewModel.displayName)
            Picker("设备类型", selection: $viewModel.deviceKind) {
                Text("未指定").tag(RemoteDeviceKind.unspecified)
                Text("Linux 主机").tag(RemoteDeviceKind.linux)
                Text("Mac").tag(RemoteDeviceKind.mac)
                Text("Windows 主机").tag(RemoteDeviceKind.windows)
                Text("NAS").tag(RemoteDeviceKind.nas)
                Text("路由器").tag(RemoteDeviceKind.router)
                Text("交换机").tag(RemoteDeviceKind.switchDevice)
                Text("网络设备").tag(RemoteDeviceKind.appliance)
                Text("其他设备").tag(RemoteDeviceKind.other)
            }
            Toggle("作为远端执行环境", isOn: $viewModel.isRemoteExecutionEnvironment)
                .disabled(!viewModel.isSSHEnabled)
        } header: {
            Text("设备")
        } footer: {
            Text(viewModel.isRemoteExecutionEnvironment
                ? "运行远端任务前会自动检查并维护 Floe 守护程序。"
                : "设备类型仅供参考；协议配置决定可用能力。未启用远端执行时不会安装 Floe 守护程序。")
        }
    }

    private var connectionSection: some View {
        Section("hosts.connection") {
            TextField("hosts.address", text: $viewModel.address)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(FloeTheme.Typography.evidence)
            TextField("hosts.port", value: $viewModel.port, format: .number)
                .keyboardType(.numberPad)
            TextField("hosts.user", text: $viewModel.user)
                .textInputAutocapitalization(.never)
        }
    }

    @ViewBuilder
    private var sshSection: some View {
        Section {
            Toggle("SSH 连接", isOn: $viewModel.isSSHEnabled)
        } footer: {
            Text("SSH 是设备可选的连接方式；仅 VNC、Telnet、TCP 或 BLE 串口设备无需启用。")
        }
        if viewModel.isSSHEnabled {
            connectionSection
            authSection
            hostKeySection
        }
    }

    private var authSection: some View {
        Section {
            Picker("hosts.auth", selection: $viewModel.authKind) {
                Text("hosts.auth.password").tag(HostEditorViewModel.AuthKind.password)
                Text("hosts.auth.imported_key").tag(HostEditorViewModel.AuthKind.importedKey)
                Text("hosts.auth.device_key").tag(HostEditorViewModel.AuthKind.deviceKey)
            }
            HStack {
                Group {
                    if viewModel.isSecretVisible {
                        TextField(secretFieldLabel, text: $viewModel.secretInput)
                    } else {
                        SecureField(secretFieldLabel, text: $viewModel.secretInput)
                    }
                }
                .textInputAutocapitalization(.never)
                if viewModel.existing != nil {
                    Button {
                        if viewModel.isSecretVisible {
                            viewModel.isSecretVisible = false
                        } else if viewModel.secretInput.isEmpty {
                            Task { await viewModel.revealStoredSecret() }
                        } else {
                            viewModel.isSecretVisible = true
                        }
                    } label: {
                        if viewModel.isRevealingSecret {
                            ProgressView()
                        } else {
                            Image(systemName: viewModel.isSecretVisible ? "eye.slash" : "eye")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRevealingSecret)
                    .accessibilityLabel(viewModel.isSecretVisible ? "隐藏主机凭据" : "验证身份并查看主机凭据")
                }
            }
        } header: {
            Text("hosts.authentication")
        } footer: {
            Text("hosts.secret.hint")
        }
    }

    private var secretFieldLabel: LocalizedStringKey {
        switch viewModel.authKind {
        case .password: "hosts.auth.password"
        case .importedKey, .deviceKey: "hosts.private_key"
        }
    }

    private var hostKeySection: some View {
        Section {
            Toggle("hosts.pin_fingerprint", isOn: $viewModel.usePinnedPolicy)
            if viewModel.usePinnedPolicy {
                TextField("hosts.fingerprint", text: $viewModel.pinnedFingerprint)
                    .textInputAutocapitalization(.never)
                    .font(FloeTheme.Typography.evidence)
            }
        } header: {
            Text("hosts.host_key")
        } footer: {
            Text("hosts.tofu.hint")
        }
    }

    private var vncSection: some View {
        Section {
            ForEach($viewModel.vncConnections) { $connection in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("连接名称", text: $connection.displayName)
                        Button(role: .destructive) {
                            viewModel.removeVNCConnection(id: connection.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    Picker("连接方式", selection: $connection.transport) {
                        Text("直接 VNC").tag(VNCTransport.direct)
                        Text("VNC 经 SSH 隧道").tag(VNCTransport.sshTunnel)
                    }
                    TextField(
                        connection.transport == .direct ? "VNC 地址" : "SSH 目标侧地址",
                        text: $connection.host
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField("hosts.vnc_port", value: $connection.port, format: .number)
                        .keyboardType(.numberPad)
                    SecureField("hosts.vnc_password", text: $connection.password)
                        .textInputAutocapitalization(.never)
                }
            }
            Button {
                viewModel.addVNCConnection()
            } label: {
                Label("添加 VNC 连接", systemImage: "plus")
            }
        } header: {
            Text("VNC 连接")
        } footer: {
            Text("同一设备可同时保存普通 VNC 和 SSH 隧道 VNC；凭据只保存在钥匙串。")
        }
    }

    private var auxiliaryConnectionsSection: some View {
        Section {
            ForEach($viewModel.auxiliaryConnections) { $connection in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("连接名称", text: $connection.displayName)
                        Button(role: .destructive) {
                            viewModel.removeAuxiliaryConnection(id: connection.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    LabeledContent("协议", value: connectionKindTitle(connection.kind))
                    if connection.kind == .bluetoothSerial {
                        TextField("BLE 外设 UUID", text: $connection.bluetoothPeripheralID)
                        TextField("服务 UUID", text: $connection.bluetoothServiceUUID)
                        TextField("写入特征 UUID", text: $connection.bluetoothWriteCharacteristicUUID)
                        TextField("通知特征 UUID（可选）", text: $connection.bluetoothNotifyCharacteristicUUID)
                    } else {
                        TextField("地址", text: $connection.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("端口", value: $connection.port, format: .number)
                            .keyboardType(.numberPad)
                    }
                }
            }
            Menu {
                Button("Telnet") { viewModel.addAuxiliaryConnection(kind: .telnet) }
                Button("普通 TCP") { viewModel.addAuxiliaryConnection(kind: .tcp) }
                Button("BLE 串口") { viewModel.addAuxiliaryConnection(kind: .bluetoothSerial) }
            } label: {
                Label("添加其他连接", systemImage: "plus")
            }
        } header: {
            Text("其他连接")
        } footer: {
            Text("BLE 串口使用设备公开的 GATT 服务；传统蓝牙 SPP 仅适用于厂商开放的 MFi 配件。")
        }
    }

    private func connectionKindTitle(_ kind: RemoteAuxiliaryConnectionKind) -> String {
        switch kind {
        case .telnet: "Telnet"
        case .tcp: "TCP"
        case .bluetoothSerial: "BLE 串口"
        }
    }

    private func save() {
        Task {
            if await viewModel.save() {
                dismiss()
            }
        }
    }
}
#endif
