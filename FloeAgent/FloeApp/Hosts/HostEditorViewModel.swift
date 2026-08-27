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

    struct VNCConnectionDraft: Identifiable, Hashable {
        var id: UUID
        var displayName: String
        var transport: VNCTransport
        var host: String
        var port: Int
        var password: String = ""
        var existingPasswordRef: SecretReference?
    }

    struct AuxiliaryConnectionDraft: Identifiable, Hashable {
        var id: UUID
        var displayName: String
        var kind: RemoteAuxiliaryConnectionKind
        var host: String = ""
        var port: Int = 23
        var bluetoothPeripheralID: String = ""
        var bluetoothServiceUUID: String = ""
        var bluetoothWriteCharacteristicUUID: String = ""
        var bluetoothNotifyCharacteristicUUID: String = ""
    }

    // MARK: - Editable fields

    @Published var displayName: String = ""
    @Published var address: String = ""
    @Published var port: Int = 22
    @Published var user: String = ""
    @Published var isSSHEnabled = true {
        didSet {
            if !isSSHEnabled { isRemoteExecutionEnvironment = false }
        }
    }
    @Published var authKind: AuthKind = .password
    /// The secret body, held only transiently until saved to Keychain.
    @Published var secretInput: String = ""
    @Published var pinnedFingerprint: String = ""
    @Published var usePinnedPolicy = false
    @Published var deviceKind: RemoteDeviceKind = .unspecified
    @Published var isRemoteExecutionEnvironment = true
    @Published var vncConnections: [VNCConnectionDraft] = []
    @Published var auxiliaryConnections: [AuxiliaryConnectionDraft] = []

    @Published private(set) var isSaving = false
    @Published private(set) var isRevealingSecret = false
    @Published var isSecretVisible = false
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
            deviceKind = existing.deviceKind
            isRemoteExecutionEnvironment = existing.isRemoteExecutionEnvironment
            if case .pinned(let fingerprint) = existing.hostKeyPolicy {
                usePinnedPolicy = true
                pinnedFingerprint = fingerprint
            }
            vncConnections = existing.vncEndpoints.map {
                VNCConnectionDraft(
                    id: $0.id, displayName: $0.displayName,
                    transport: $0.transport, host: $0.host, port: $0.port,
                    existingPasswordRef: $0.passwordRef
                )
            }
            auxiliaryConnections = existing.auxiliaryConnections.map {
                AuxiliaryConnectionDraft(
                    id: $0.id, displayName: $0.displayName, kind: $0.kind,
                    host: $0.host ?? "", port: $0.port ?? ($0.kind == .telnet ? 23 : 0),
                    bluetoothPeripheralID: $0.bluetoothPeripheralID?.uuidString ?? "",
                    bluetoothServiceUUID: $0.bluetoothServiceUUID ?? "",
                    bluetoothWriteCharacteristicUUID: $0.bluetoothWriteCharacteristicUUID ?? "",
                    bluetoothNotifyCharacteristicUUID: $0.bluetoothNotifyCharacteristicUUID ?? ""
                )
            }
            switch existing.auth {
            case .none: isSSHEnabled = false
            case .password: authKind = .password
            case .importedKey: authKind = .importedKey
            case .deviceGeneratedKey: authKind = .deviceKey
            }
        }
    }

    var canSave: Bool {
        let named = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard named else { return false }
        guard isSSHEnabled else {
            return !vncConnections.isEmpty || !auxiliaryConnections.isEmpty
        }
        return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }

    func addVNCConnection() {
        vncConnections.append(VNCConnectionDraft(
            id: UUID(), displayName: "VNC \(vncConnections.count + 1)",
            transport: .direct, host: address, port: 5900
        ))
    }

    func removeVNCConnection(id: UUID) {
        vncConnections.removeAll { $0.id == id }
    }

    func addAuxiliaryConnection(kind: RemoteAuxiliaryConnectionKind) {
        auxiliaryConnections.append(AuxiliaryConnectionDraft(
            id: UUID(),
            displayName: kind == .telnet ? "Telnet" : (kind == .tcp ? "TCP" : "BLE 串口"),
            kind: kind, host: address, port: kind == .telnet ? 23 : 0
        ))
    }

    func removeAuxiliaryConnection(id: UUID) {
        auxiliaryConnections.removeAll { $0.id == id }
    }

    /// Reveals an already-persisted credential only after one centralized
    /// owner-authentication request. The plaintext remains transient view
    /// state and is never logged or copied into the host database.
    func revealStoredSecret() async {
        guard existing != nil, !isRevealingSecret else { return }
        isRevealingSecret = true
        defer { isRevealingSecret = false }
        errorMessage = nil
        do {
            guard try await DeviceOwnerAuthenticator.authenticate(
                reason: "查看已保存的主机凭据"
            ) else { return }
            let data = try await secretStore.readSecret(scope: .hostSSH(hostID))
            guard let value = String(data: data, encoding: .utf8) else {
                throw FloeError.validationFailed("保存的主机凭据不是可显示的文本")
            }
            secretInput = value
            isSecretVisible = true
            FloeLogger(category: .security).info(
                "hostCredentialRevealed host=\(hostID.uuidString) kind=\(authKind.rawValue)"
            )
        } catch {
            errorMessage = error.localizedDescription
            FloeLogger(category: .security).warning(
                "hostCredentialRevealFailed host=\(hostID.uuidString)"
            )
        }
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
            let vncEndpoints = try await buildVNCEndpoints()
            await deleteRemovedVNCSecrets(retaining: Set(vncEndpoints.map(\.id)))
            let auxiliaryConnections = try buildAuxiliaryConnections()
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
                deviceKind: deviceKind,
                isRemoteExecutionEnvironment: isRemoteExecutionEnvironment,
                vncEndpoints: vncEndpoints,
                auxiliaryConnections: auxiliaryConnections
            )
            try await center.saveHost(profile)
            if !isSSHEnabled {
                try? await secretStore.deleteSecret(scope: .hostSSH(hostID))
            }
            // Clear the transient secret from view state after persisting.
            secretInput = ""
            for index in vncConnections.indices { vncConnections[index].password = "" }
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
        guard isSSHEnabled else { return .none }
        let entered = secretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if entered.isEmpty, let existing {
            return existing.auth // keep existing reference
        }
        guard !entered.isEmpty, let data = entered.data(using: .utf8) else {
            throw FloeError.validationFailed("A password or key is required")
        }
        try await secretStore.storeSecret(data, scope: .hostSSH(hostID))
        let synchronizable = SyncControlPreferences.load().savedCredentialsEnabled
        let reference = SecretReference(
            keychainAccount: "host.ssh.\(hostID.uuidString)",
            synchronizable: synchronizable
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

    private func buildVNCEndpoints() async throws -> [VNCEndpoint] {
        var endpoints: [VNCEndpoint] = []
        for draft in vncConnections {
            var passwordRef = draft.existingPasswordRef
            let password = draft.password.trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty, let data = password.data(using: .utf8) {
                try await secretStore.storeSecret(
                    data, scope: .hostVNCConnection(hostID: hostID, connectionID: draft.id)
                )
                passwordRef = SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(draft.id.uuidString)",
                    synchronizable: SyncControlPreferences.load().savedCredentialsEnabled
                )
            }
            let endpoint = VNCEndpoint(
                id: draft.id,
                displayName: draft.displayName.trimmed,
                transport: draft.transport,
                host: draft.host.trimmed,
                port: draft.port,
                passwordRef: passwordRef
            )
            try endpoint.validate()
            endpoints.append(endpoint)
        }
        return endpoints
    }

    private func buildAuxiliaryConnections() throws -> [RemoteAuxiliaryConnection] {
        try auxiliaryConnections.map { draft in
            let connection = RemoteAuxiliaryConnection(
                id: draft.id,
                displayName: draft.displayName.trimmed,
                kind: draft.kind,
                host: draft.kind == .bluetoothSerial ? nil : draft.host.trimmed,
                port: draft.kind == .bluetoothSerial ? nil : draft.port,
                bluetoothPeripheralID: UUID(uuidString: draft.bluetoothPeripheralID),
                bluetoothServiceUUID: draft.bluetoothServiceUUID.trimmed.nilIfEmpty,
                bluetoothWriteCharacteristicUUID: draft.bluetoothWriteCharacteristicUUID.trimmed.nilIfEmpty,
                bluetoothNotifyCharacteristicUUID: draft.bluetoothNotifyCharacteristicUUID.trimmed.nilIfEmpty
            )
            try connection.validate()
            return connection
        }
    }

    private func deleteRemovedVNCSecrets(retaining ids: Set<UUID>) async {
        guard let existing else { return }
        for endpoint in existing.vncEndpoints where !ids.contains(endpoint.id) {
            try? await secretStore.deleteSecret(
                scope: .hostVNCConnection(hostID: hostID, connectionID: endpoint.id)
            )
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
