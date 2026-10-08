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

import FloeCore
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
            TextField("hosts.host_editor_view.device_name", text: $viewModel.displayName)
            Picker("hosts.host_editor_view.device_type", selection: $viewModel.deviceKind) {
                Text("hosts.host_editor_view.unspecified").tag(RemoteDeviceKind.unspecified)
                Text("hosts.host_editor_view.linux_host").tag(RemoteDeviceKind.linux)
                Text("Mac").tag(RemoteDeviceKind.mac)
                Text("hosts.host_editor_view.windows_host").tag(RemoteDeviceKind.windows)
                Text("NAS").tag(RemoteDeviceKind.nas)
                Text("hosts.host_editor_view.router").tag(RemoteDeviceKind.router)
                Text("hosts.host_editor_view.switch").tag(RemoteDeviceKind.switchDevice)
                Text("hosts.host_editor_view.network_device").tag(RemoteDeviceKind.appliance)
                Text("hosts.host_editor_view.other_devices").tag(RemoteDeviceKind.other)
            }
            Toggle("hosts.host_editor_view.as_a_remote_execution_environment", isOn: $viewModel.isRemoteExecutionEnvironment)
                .disabled(!viewModel.isSSHEnabled)
        } header: {
            Text("settings.diagnostics.device")
        } footer: {
            Text(viewModel.isRemoteExecutionEnvironment
                ? "hosts.host_editor_view.the_floe_daemon_is_automatically_checked"
                : "hosts.host_editor_view.device_type_is_informational_only_the")
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
            Toggle("hosts.host_editor_view.ssh_connection", isOn: $viewModel.isSSHEnabled)
        } footer: {
            Text("hosts.host_editor_view.ssh_is_an_optional_connection_method")
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
                    .accessibilityLabel(viewModel.isSecretVisible ? "hosts.host_editor_view.hide_host_credentials" : "hosts.host_editor_view.verify_identity_to_view_host_credentials")
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
                        TextField("hosts.host_editor_view.connection_name", text: $connection.displayName)
                        Button(role: .destructive) {
                            viewModel.removeVNCConnection(id: connection.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    Picker("hosts.host_editor_view.connection_method", selection: $connection.transport) {
                        Text("hosts.host_editor_view.direct_vnc").tag(VNCTransport.direct)
                        Text("hosts.host_editor_view.vnc_over_ssh_tunnel").tag(VNCTransport.sshTunnel)
                    }
                    TextField(
                        connection.transport == .direct ? "hosts.host_editor_view.vnc_address" : "hosts.host_editor_view.ssh_target_side_address",
                        text: $connection.host
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField("hosts.vnc_port", value: $connection.port, format: .number)
                        .keyboardType(.numberPad)
                    SecureField(
                        connection.existingPasswordRef == nil
                            ? "hosts.host_editor_view.set_vnc_password"
                            : "hosts.host_editor_view.enter_a_new_password_to_replace",
                        text: $connection.password
                    )
                        .textInputAutocapitalization(.never)
                    Label(
                        connection.existingPasswordRef == nil
                            ? "hosts.host_editor_view.password_not_configured"
                            : "hosts.host_editor_view.password_saved_securely",
                        systemImage: connection.existingPasswordRef == nil
                            ? "exclamationmark.triangle"
                            : "checkmark.shield"
                    )
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(
                        connection.existingPasswordRef == nil
                            ? FloeTheme.destructive
                            : Color.secondary
                    )
                }
            }
            Button {
                viewModel.addVNCConnection()
            } label: {
                Label("hosts.enable_vnc", systemImage: "plus")
            }
        } header: {
            Text("hosts.host_editor_view.vnc_connection")
        } footer: {
            Text("hosts.host_editor_view.one_device_can_store_both_plain")
        }
    }

    private var auxiliaryConnectionsSection: some View {
        Section {
            ForEach($viewModel.auxiliaryConnections) { $connection in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("hosts.host_editor_view.connection_name", text: $connection.displayName)
                        Button(role: .destructive) {
                            viewModel.removeAuxiliaryConnection(id: connection.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    LabeledContent("workspace.file_inspector_view.protocol", value: connectionKindTitle(connection.kind))
                    if connection.kind == .bluetoothSerial {
                        TextField("hosts.host_editor_view.ble_peripheral_uuid", text: $connection.bluetoothPeripheralID)
                        TextField("hosts.host_editor_view.service_uuid", text: $connection.bluetoothServiceUUID)
                        TextField("hosts.host_editor_view.write_characteristic_uuid", text: $connection.bluetoothWriteCharacteristicUUID)
                        TextField("hosts.host_editor_view.notify_characteristic_uuid_optional", text: $connection.bluetoothNotifyCharacteristicUUID)
                    } else {
                        TextField("hosts.address", text: $connection.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("hosts.host_editor_view.port", value: $connection.port, format: .number)
                            .keyboardType(.numberPad)
                    }
                }
            }
            Menu {
                Button("Telnet") { viewModel.addAuxiliaryConnection(kind: .telnet) }
                Button("hosts.host_editor_view.plain_tcp") { viewModel.addAuxiliaryConnection(kind: .tcp) }
                Button("hosts.host_editor_view.ble_serial") { viewModel.addAuxiliaryConnection(kind: .bluetoothSerial) }
            } label: {
                Label("hosts.host_editor_view.add_another_connection", systemImage: "plus")
            }
        } header: {
            Text("hosts.host_editor_view.other_connections")
        } footer: {
            Text("hosts.host_editor_view.ble_serial_uses_the_device_s")
        }
    }

    private func connectionKindTitle(_ kind: RemoteAuxiliaryConnectionKind) -> String {
        switch kind {
        case .telnet: "Telnet"
        case .tcp: "TCP"
        case .bluetoothSerial: FloeL10n.l("hosts.host_editor_view.ble_serial")
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
