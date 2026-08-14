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
            connectionSection
            authSection
            hostKeySection
            vncSection
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

    private var connectionSection: some View {
        Section("hosts.connection") {
            TextField("hosts.display_name", text: $viewModel.displayName)
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

    private var authSection: some View {
        Section {
            Picker("hosts.auth", selection: $viewModel.authKind) {
                Text("hosts.auth.password").tag(HostEditorViewModel.AuthKind.password)
                Text("hosts.auth.imported_key").tag(HostEditorViewModel.AuthKind.importedKey)
                Text("hosts.auth.device_key").tag(HostEditorViewModel.AuthKind.deviceKey)
            }
            SecureField(secretFieldLabel, text: $viewModel.secretInput)
                .textInputAutocapitalization(.never)
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
            Toggle("hosts.enable_vnc", isOn: $viewModel.hasVNC)
            if viewModel.hasVNC {
                TextField("hosts.vnc_port", value: $viewModel.vncPort, format: .number)
                    .keyboardType(.numberPad)
                SecureField("hosts.vnc_password", text: $viewModel.vncPassword)
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("hosts.vnc_section")
        } footer: {
            Text("hosts.vnc.hint")
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
