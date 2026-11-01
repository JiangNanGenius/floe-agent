// FloeApp — remote host configuration adapters.
//
// SPDX-License-Identifier: MPL-2.0
//
// Model-callable SSH/VNC configuration needs exactly the same storage,
// Keychain and host-store semantics as the Settings form. This center owns
// those adapters so AppEnvironment only has to register the runners; it does
// not create a second credential store, a second host store or a second
// approval path. Raw chat input and `⟨credential:…⟩` references are resolved
// only inside the executor: a same-run/tool/field normalizer capture or a real
// unbound ordinary vault card, never another task's capture, a Skill-bound
// secret or a device-pairing key. The saved profile receives only a
// SecretReference.
//
// Every credential write uses a fresh Keychain account ("per revision"). The
// previous reference is deleted only after the host row save commits; a save
// failure deletes exactly the staged reference and leaves the old credential
// untouched. This is why the adapter exposes a reference-keyed deleter rather
// than a host/connection-keyed one.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloePersistence
import FloeSecurity
import FloeSSH
import FloeSync
import FloeTools
import FloeVNC

@MainActor
final class RemoteHostConfigurationCenter {
    private let hostStore: RemoteHostStore
    private let credentialVault: CredentialVaultService
    private let credentialStore: CredentialStore
    /// Optional proof that an ordinary vault card is not currently shared
    /// with a Skill configuration. Production passes the shared store; when it
    /// is absent, explicit card reuse fails closed rather than copying a card
    /// whose bindings cannot be verified.
    private let skillConfigurationStore: SkillConfigurationStore?

    init(
        hostStore: RemoteHostStore,
        credentialVault: CredentialVaultService,
        credentialStore: CredentialStore,
        skillConfigurationStore: SkillConfigurationStore? = nil
    ) {
        self.hostStore = hostStore
        self.credentialVault = credentialVault
        self.credentialStore = credentialStore
        self.skillConfigurationStore = skillConfigurationStore
    }

    // MARK: - Registration

    /// Registers `ssh.createHost`, `ssh.setHostAuth` and `ssh.verifyHost`.
    /// `ssh.verifyHost` uses its own `ToolContext.nestedApproval` handle for
    /// the first-use host-key decision, so no extra App approval callback is
    /// required. Pass the same VNC writer and reference deleter used by
    /// `ssh.updateHost` so one endpoint cannot acquire two Keychain
    /// conventions.
    func registerSSHHostTools(
        registry: ToolRunnerRegistry = .shared,
        sessionCenter: RemoteSessionCenter,
        vncPasswordWriter: VNCCredentialWriter? = nil,
        secretDeleter: SecretReferenceDeleter? = nil,
        hostDeletion: SSHHostDeletionAction? = nil
    ) {
        let observer: RemoteHostUpdateObserver = { [weak sessionCenter] hostID, endpointIDs in
            await sessionCenter?.agentDidUpdateHost(
                hostID: hostID,
                vncEndpointIDs: endpointIDs
            )
        }
        registerSSHHostConfigurationTools(
            registry: registry,
            store: hostStore,
            credentialWriter: makeSSHCredentialWriter(),
            secretDeleter: secretDeleter ?? makeCredentialReferenceDeleter(),
            credentialResolver: makeSSHCredentialResolver(),
            vncPasswordWriter: vncPasswordWriter ?? makeVNCCredentialWriter(),
            hostDeletion: hostDeletion ?? { [weak sessionCenter] hostID in
                guard let sessionCenter else {
                    throw FloeError.invalidConfiguration("Host deletion is unavailable")
                }
                return try await sessionCenter.deleteHost(id: hostID)
            },
            updateObserver: observer,
            aliasCommitter: makeSSHAuthAliasCommitter(),
            aliasDeleter: makeSSHAuthAliasDeleter(),
            credentialInputResolver: makeCredentialInputResolver()
        )
    }

    // MARK: - Credential-input authorization

    /// Resolves the ONE credential field the tool is filling, using the
    /// canonical run/tool/field provenance supplied by the tool. Raw setup
    /// values pass through; a same-run normalizer capture is read exactly once
    /// and consumed after commit; an explicit ordinary vault card is reused
    /// only when it is not Skill/device-bound, is kind/host-scope compatible
    /// and is not shared with a Skill configuration.
    func makeCredentialInputResolver() -> CredentialInputResolver {
        let vault = credentialVault
        let bindings = skillConfigurationStore
        return { input, slot in
            try await Self.resolveCredentialInput(
                input,
                slot: slot,
                vault: vault,
                skillConfigurationStore: bindings
            )
        }
    }

    // MARK: - SSH credentials

    /// Writes a fresh `host.ssh.<hostID>.<revision>` item and returns its
    /// reference. The metadata row carries the kind implied by the auth
    /// method, so a password → private-key → device-key change cannot keep a
    /// stale `.sshPassword` classification.
    func makeSSHCredentialWriter() -> SSHAuthCredentialWriter {
        let vault = credentialVault
        return { hostID, credentialInput, label, method in
            // The tool resolves an authorized reference into bytes before it
            // calls this writer. A placeholder reaching this boundary was not
            // resolved and must never be stored as literal secret text.
            try Self.rejectLiteralReference(credentialInput)
            let secret = credentialInput
            guard !secret.isEmpty else {
                throw FloeError.validationFailed("SSH credential must not be empty")
            }
            let reference = try Self.storeRevision(
                secret,
                account: Self.sshRevisionAccount(hostID)
            )
            let kind: CredentialKind = method == .password ? .sshPassword : .sshPrivateKey
            try? await vault.registerExisting(
                account: reference.keychainAccount,
                kind: kind,
                label: label,
                hostID: hostID,
                synchronizable: reference.synchronizable,
                deviceBound: method == .deviceKey
            )
            return reference
        }
    }

    /// Deletes exactly one revision (and its metadata row). The tool calls
    /// this for a staged reference after a failed host save, or for the old
    /// reference only after the new host row has committed.
    func makeCredentialReferenceDeleter() -> SecretReferenceDeleter {
        let credentials = credentialStore
        return { reference in
            try Self.deleteKeychainRevision(reference)
            await Self.deleteMetadata(
                account: reference.keychainAccount,
                store: credentials
            )
        }
    }

    /// Executor-only reference read used by the real SSH handshake. The
    /// result never leaves the connection service.
    func makeSSHCredentialResolver() -> SSHCredentialResolver {
        { reference in
            guard let data = KeychainSecretStore().readSecret(reference: reference) else {
                throw SSHConnectionError.invalidCredential
            }
            return data
        }
    }

    /// Best-effort copy into the Settings editor's fixed account so "reveal
    /// saved password" keeps working. The host profile never references this
    /// alias; a failure cannot invalidate the committed revision.
    func makeSSHAuthAliasCommitter() -> SSHAuthReferenceCommitter {
        let credentials = credentialStore
        let vault = credentialVault
        return { hostID, reference in
            guard let data = KeychainSecretStore().readSecret(reference: reference) else { return }
            let synchronizable = SyncControlPreferences.load().savedCredentialsEnabled
            let store = KeychainStore(
                service: KeychainSecretStore.defaultService,
                synchronizable: synchronizable
            )
            do {
                try store.store(account: Self.sshAliasAccount(hostID), secret: data)
                try? KeychainStore(
                    service: KeychainSecretStore.defaultService,
                    synchronizable: !synchronizable
                ).delete(account: Self.sshAliasAccount(hostID))
            } catch {
                // The committed revision remains authoritative.
                return
            }
            // Keep the fixed-account metadata row aligned with the committed
            // revision so a method change cannot leave a stale kind.
            let records = (try? await credentials.records(owner: nil)) ?? []
            guard let source = records.first(where: {
                $0.keychainAccount == reference.keychainAccount
            }) else { return }
            if var alias = records.first(where: {
                $0.keychainAccount == Self.sshAliasAccount(hostID)
            }) {
                alias.kind = source.kind
                alias.hostID = hostID
                alias.label = source.label
                alias.synchronizable = synchronizable
                alias.deviceBound = source.deviceBound
                alias.updatedAt = Date()
                try? await credentials.save(alias)
            } else {
                try? await vault.registerExisting(
                    account: Self.sshAliasAccount(hostID),
                    kind: source.kind,
                    label: source.label,
                    hostID: hostID,
                    synchronizable: synchronizable,
                    deviceBound: source.deviceBound
                )
            }
        }
    }

    /// Removes the fixed UI alias after an explicit SSH-authentication
    /// removal. The committed per-revision reference is deleted separately by
    /// the tool.
    func makeSSHAuthAliasDeleter() -> SSHAuthLegacyAliasDeleter {
        let credentials = credentialStore
        return { hostID in
            let account = Self.sshAliasAccount(hostID)
            for synchronizable in [true, false] {
                try? KeychainStore(
                    service: KeychainSecretStore.defaultService,
                    synchronizable: synchronizable
                ).delete(account: account)
            }
            await Self.deleteMetadata(account: account, store: credentials)
        }
    }

    // MARK: - VNC credentials

    /// Writes a fresh `host.vnc.<hostID>.<connectionID>.<revision>` item and
    /// returns its reference. The previous endpoint reference stays valid
    /// until the caller commits the host row and deletes it explicitly.
    func makeVNCCredentialWriter() -> VNCCredentialWriter {
        let vault = credentialVault
        let hosts = hostStore
        return { hostID, connectionID, credentialInput in
            // The tool resolves an authorized reference into bytes before it
            // calls this writer. A placeholder reaching this boundary was not
            // resolved and must never be stored as literal secret text.
            try Self.rejectLiteralReference(credentialInput)
            let secret = credentialInput
            guard !secret.isEmpty else {
                throw FloeError.validationFailed("VNC password must not be empty")
            }
            let reference = try Self.storeRevision(
                secret,
                account: Self.vncRevisionAccount(hostID, connectionID)
            )
            let hostLabel = (try? await hosts.host(id: hostID))?.displayName ?? "VNC"
            try? await vault.registerExisting(
                account: reference.keychainAccount,
                kind: .vncPassword,
                label: "\(hostLabel) VNC",
                hostID: hostID,
                synchronizable: reference.synchronizable
            )
            return reference
        }
    }

    // MARK: - Helpers

    nonisolated private static func sshAliasAccount(_ hostID: UUID) -> String {
        "host.ssh.\(hostID.uuidString)"
    }

    nonisolated private static func sshRevisionAccount(_ hostID: UUID) -> String {
        "host.ssh.\(hostID.uuidString).\(UUID().uuidString)"
    }

    nonisolated private static func vncRevisionAccount(_ hostID: UUID, _ connectionID: UUID) -> String {
        "host.vnc.\(hostID.uuidString).\(connectionID.uuidString).\(UUID().uuidString)"
    }

    /// Stores one never-reused item, verifies the exact bytes, and returns the
    /// reference. A failed read-back removes the staged item before throwing.
    nonisolated private static func storeRevision(
        _ secret: Data,
        account: String
    ) throws -> SecretReference {
        let synchronizable = SyncControlPreferences.load().savedCredentialsEnabled
        let store = KeychainStore(
            service: KeychainSecretStore.defaultService,
            synchronizable: synchronizable
        )
        try store.store(account: account, secret: secret)
        do {
            guard try store.read(account: account) == secret else {
                throw FloeError.internalError("Credential read-back did not match the staged bytes")
            }
        } catch {
            try? store.delete(account: account)
            try? KeychainStore(
                service: KeychainSecretStore.defaultService,
                synchronizable: !synchronizable
            ).delete(account: account)
            throw error
        }
        return SecretReference(keychainAccount: account, synchronizable: synchronizable)
    }

    /// Deletes the item from the declared namespace and its fallback so a
    /// previous sync-preference change cannot leave a stale copy behind.
    nonisolated private static func deleteKeychainRevision(_ reference: SecretReference) throws {
        var firstError: Error?
        for synchronizable in [reference.synchronizable, !reference.synchronizable] {
            do {
                try KeychainStore(
                    service: KeychainSecretStore.defaultService,
                    synchronizable: synchronizable
                ).delete(account: reference.keychainAccount)
            } catch KeychainStoreError.itemNotFound {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// A writer must only ever receive resolved bytes. Reaching this boundary
    /// with a placeholder means the native authorization seam did not run, so
    /// refuse instead of storing the reference text as the secret.
    nonisolated private static func rejectLiteralReference(_ input: Data) throws {
        guard let text = String(data: input, encoding: .utf8) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("⟨credential") else {
            throw FloeError.unauthorized
        }
    }

    /// Resolves one credential field with its native provenance. The four
    /// accepted cases are intentionally narrow:
    ///
    /// 1. a raw setup value (no placeholder marker) passes through;
    /// 2. this exact run/tool/field normalizer capture is read once and its
    ///    temporary record is consumed only after the host row commits;
    /// 3. a real ordinary user vault card may be reused explicitly when it is
    ///    not Skill-bound, not device-bound, kind/host-scope compatible and
    ///    not shared with a Skill configuration;
    /// 4. everything else fails closed before any host or credential write.
    nonisolated private static func resolveCredentialInput(
        _ input: Data,
        slot: CredentialInputSlot,
        vault: CredentialVaultService,
        skillConfigurationStore: SkillConfigurationStore?
    ) async throws -> CredentialInputResolution {
        guard let text = String(data: input, encoding: .utf8) else {
            return CredentialInputResolution(secret: input)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("⟨credential") else {
            return CredentialInputResolution(secret: input)
        }
        guard trimmed.hasPrefix("⟨credential"),
              let credentialID = CredentialCaptureReference.credentialID(from: trimmed) else {
            throw FloeError.validationFailed("Credential reference is malformed")
        }
        guard let record = try await vault.metadata(CredentialHandle(id: credentialID)) else {
            throw FloeError.unauthorized
        }
        if CredentialCaptureReference.isAuthorizedCapture(
            record,
            runID: slot.runID,
            toolName: slot.toolName,
            fieldPath: slot.fieldPath
        ) {
            guard !record.deviceBound else { throw FloeError.unauthorized }
            let secret = try await vault.resolveForApprovedUse(CredentialHandle(id: credentialID))
            guard !secret.isEmpty else {
                throw FloeError.validationFailed("The captured credential is empty")
            }
            // A normalizer capture can contain a malformed placeholder that
            // was not recognized as a reference. Never stage it as a secret.
            try rejectLiteralReference(secret)
            return CredentialInputResolution(secret: secret) {
                do {
                    try await vault.delete(CredentialHandle(id: credentialID))
                } catch {
                    FloeLogger(category: .security).warning(
                        "sshCredentialCaptureCleanupFailed"
                    )
                }
            }
        }
        // A normalizer capture from another run, tool or field is never a
        // reusable user card, even if the model knows its opaque id.
        if record.origin?.hasPrefix(CredentialCaptureReference.originPrefix) == true {
            throw FloeError.unauthorized
        }
        // Explicit ordinary user-card reuse only. Skill-owned, ingress and
        // device-pairing records are not ordinary vault cards.
        guard record.owner == .vault, !record.deviceBound else {
            throw FloeError.unauthorized
        }
        guard record.origin == nil || record.origin == CredentialCardService.toolName else {
            throw FloeError.unauthorized
        }
        guard record.hostID == nil || record.hostID == slot.hostID else {
            throw FloeError.unauthorized
        }
        guard isCompatibleKind(record.kind, expected: slot.expectedKind) else {
            throw FloeError.unauthorized
        }
        // Without the binding store we cannot prove an ordinary-looking card
        // is not shared with a Skill profile, so explicit reuse fails closed.
        guard let skillConfigurationStore else {
            throw FloeError.unauthorized
        }
        let bindings: [(profileID: UUID, fieldKey: String)]
        do {
            bindings = try await skillConfigurationStore.bindingReferences(
                credentialID: credentialID
            )
        } catch {
            throw FloeError.unauthorized
        }
        guard bindings.isEmpty else { throw FloeError.unauthorized }
        let secret = try await vault.resolveForApprovedUse(CredentialHandle(id: credentialID))
        guard !secret.isEmpty else {
            throw FloeError.validationFailed("The credential is empty")
        }
        try rejectLiteralReference(secret)
        return CredentialInputResolution(secret: secret)
    }

    /// Kind compatibility for explicit card reuse. A password-shaped card can
    /// also be an explicitly chosen generic secret; key material and unrelated
    /// credential categories (provider/website tokens) are not interchangeable.
    /// A same-run normalizer capture is authorized by its exact
    /// run/tool/field origin instead: the normalizer cannot know the SSH auth
    /// method for a generic `credentialInput`, so it may label a private-key
    /// capture as an SSH password before the tool sees the requested method.
    nonisolated private static func isCompatibleKind(
        _ kind: CredentialKind,
        expected: CredentialKind
    ) -> Bool {
        switch expected {
        case .sshPassword, .vncPassword:
            return kind == expected || kind == .genericToken
        default:
            return kind == expected
        }
    }

    /// Removes only the metadata row for this exact Keychain account. Shared
    /// credential cards and other hosts are untouched.
    nonisolated private static func deleteMetadata(
        account: String,
        store: CredentialStore
    ) async {
        guard let records = try? await store.records(owner: nil) else { return }
        for record in records where record.keychainAccount == account {
            try? await store.delete(id: record.id)
        }
    }
}
#endif
