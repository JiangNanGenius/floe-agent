// FloeApp — SSH host-key trust (TOFU) sheet.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shows the host key fingerprint for first-use review. The user must
// explicitly trust or reject before the connection proceeds. The fingerprint
// is shown in monospaced evidence type and is selectable for out-of-band
// verification.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSSH

/// TOFU fingerprint review sheet.
struct HostKeyTrustSheet: View {
    let challenge: HostKeyChallenge
    let onResolve: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("trust.host", value: "\(challenge.address):\(challenge.port)")
                    LabeledContent("trust.key_type", value: challenge.keyType)
                }
                Section {
                    Text(challenge.fingerprintSHA256)
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                } header: {
                    Text("trust.fingerprint")
                } footer: {
                    Text("trust.verify.hint")
                }
            }
            .navigationTitle("trust.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("trust.reject", role: .cancel) { resolve(false) }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("trust.trust") { resolve(true) }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
            }
        }
    }

    private func resolve(_ trusted: Bool) {
        onResolve(trusted)
        dismiss()
    }
}
#endif
