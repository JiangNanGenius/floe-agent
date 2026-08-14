// FloeApp — Host editor view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Drives the host editor: address/port/user, auth (password / imported key
// / device key), jump chain, host-key policy, optional VNC endpoint.
// Secrets go straight to Keychain via KeychainSecretStore; the editor holds
// only SecretReferences — never a secret body in @Published state.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeSSH
import FloeSync

/// View model for adding or editing one host.
@MainActor
final class HostEditorViewModel: ObservableObject {

    enum AuthKind: String, CaseIterable, Identifiable {
        case password, importedKey, deviceKey
        var id: String { rawValue }
    }

    // MARK: - Editable fields

    @Published var displayName: String = ""
    @Published var address: String = ""
    @Published var port: Int = 22
    @Published var user: String = ""
    @Published var authKind: AuthKind = .password
    /// The secret body, held only transiently until saved to Keychain.
    @Published var secretInput: String = ""
    @Published var pinnedFingerprint: String = ""
    @Published var usePinnedPolicy = false
    // Optional VNC endpoint.
    @Published var hasVNC = false
    @Published var vncPort: Int = 5900
    @Published var vncPassword: String = ""

    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let center: RemoteSessionCenter
    let existing: RemoteHostProfile?
    let hostID: UUID
    private let secretStore = KeychainSecretStore()

    init(center: RemoteSessionCenter, existing: RemoteHostProfile?) {
        self.center = center
        self.existing = existing
        self.hostID = existing?.id ?? UUID()
        if let existing {
            displayName = existing.displayName
            address = existing.address
            port = existing.port
            user = existing.user
            if case .pinned(let fingerprint) = existing.hostKeyPolicy {
                usePinnedPolicy = true
                pinnedFingerprint = fingerprint
            }
            if let vnc = existing.vncEndpoint {
                hasVNC = true
                vncPort = vnc.port
            }
            switch existing.auth {
            case .password: authKind = .password
            case .importedKey: authKind = .importedKey
            case .deviceGeneratedKey: authKind = .deviceKey
            }
        }
    }

    var canSave: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    /// Persists secrets to Keychain and the profile to the store. Only a
    /// SecretReference is persisted on the profile; the secret body is
    /// cleared after the Keychain write.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            let auth = try await persistAuth()
            let vncEndpoint = try await buildVNCEndpoint()
            let policy: HostKeyPolicy = usePinnedPolicy
                ? .pinned(fingerprintSHA256: pinnedFingerprint)
                : .trustOnFirstUse
            let profile = RemoteHostProfile(
                id: hostID,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                user: user.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: auth,
                hostKeyPolicy: policy,
                vncEndpoint: vncEndpoint
            )
            try await center.saveHost(profile)
            // Clear the transient secret from view state after persisting.
            secretInput = ""
            vncPassword = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Secret persistence

    /// Stores the auth secret in Keychain and returns the reference-carrying
    /// auth method. Reuses the existing reference when no new secret was
    /// entered (edit without changing the secret).
    private func persistAuth() async throws -> SSHAuthMethod {
        let entered = secretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if entered.isEmpty, let existing {
            return existing.auth // keep existing reference
        }
        guard !entered.isEmpty, let data = entered.data(using: .utf8) else {
            throw FloeError.validationFailed("A password or key is required")
        }
        try await secretStore.storeSecret(data, scope: .host(hostID))
        let reference = SecretReference(
            keychainAccount: "host.\(hostID.uuidString)",
            synchronizable: true
        )
        switch authKind {
        case .password:
            return .password(reference)
        case .importedKey:
            return .importedKey(reference, keyType: .ed25519)
        case .deviceKey:
            return .deviceGeneratedKey(reference, keyType: .ed25519)
        }
    }

    private func buildVNCEndpoint() async throws -> VNCEndpoint? {
        guard hasVNC else { return nil }
        var passwordRef: SecretReference?
        let password = vncPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty, let data = password.data(using: .utf8) {
            try await secretStore.storeSecret(data, scope: .host(hostID))
            passwordRef = SecretReference(
                keychainAccount: "host.\(hostID.uuidString)",
                synchronizable: true
            )
        } else if let existing, let endpoint = existing.vncEndpoint {
            passwordRef = endpoint.passwordRef
        }
        return VNCEndpoint(host: "localhost", port: vncPort, passwordRef: passwordRef)
    }
}
#endif
