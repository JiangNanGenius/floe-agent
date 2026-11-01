// FloeExecution — model-callable SSH host configuration.
//
// The host editor UI owns a rich form, but a model can configure a first-time
// host only if creation, authentication binding and identity verification are
// also callable. This file adds those tool interfaces without replacing the
// existing RemoteHostStore, SSHConnectionService or host-key verifier:
//
//   * ssh.createHost       — create a saved host with SSH auth + endpoints.
//   * ssh.setHostAuth      — bind/change/remove SSH authentication.
//   * ssh.deleteHost       — delete one local profile with an ordered
//                            session → metadata → unshared-credential cleanup.
//   * ssh.verifyHost       — perform a real handshake and request the ONE
//                            canonical first-use identity decision through the
//                            existing task nested-approval continuation.
//
// Secrets enter only through an injected writer/resolver owned by the App.
// A raw user value or an existing `⟨credential:…⟩` reference is handed to that
// executor unchanged; this module never persists or returns the bytes.

import Foundation
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools

/// Persists SSH authentication bytes and returns only a Keychain reference.
/// The executor resolves an existing credential reference or stores a raw
/// setup value; no other layer sees the secret body.
///
/// A conforming executor MUST write a fresh, never-reused Keychain account
/// for every call. The returned reference is the only handle the host profile
/// stores, so a later host-save failure can delete exactly this revision
/// without touching the previous credential.
public typealias SSHAuthCredentialWriter = @Sendable (
    _ hostID: UUID,
    _ credentialInput: Data,
    _ label: String,
    _ method: SSHHostAuthMethodInput
) async throws -> SecretReference

/// Deletes one exact saved credential revision (and its metadata row) after a
/// commit, or a staged revision after a failed host save. Never accepts a
/// host/connection id that could resolve to a different revision.
public typealias SecretReferenceDeleter = @Sendable (_ reference: SecretReference) async throws -> Void

/// Post-commit, best-effort copy into the UI editor's fixed Keychain account
/// so "reveal saved password" keeps working for model-created hosts. The host
/// profile never references this alias; failure never invalidates the commit.
public typealias SSHAuthReferenceCommitter = @Sendable (
    _ hostID: UUID,
    _ reference: SecretReference
) async -> Void

/// Removes the fixed-account UI alias after an explicit SSH-authentication
/// removal. The committed per-revision reference is removed separately.
public typealias SSHAuthLegacyAliasDeleter = @Sendable (_ hostID: UUID) async -> Void

/// Test/transaction seam: production passes nil and uses the real store.
public typealias RemoteHostSaveAction = @Sendable (
    _ host: RemoteHostStore.StoredHost
) async throws -> Void

/// Secret-free result of deleting ONE saved local connection profile.
public struct SSHHostDeletionReceipt: Sendable, Codable, Hashable {
    public var sessionsClosed: Int
    public var credentialsDeleted: Int
    public var credentialsRetained: Int
    public var credentialCleanupPending: Bool
    public var syncDeferred: Bool

    public init(
        sessionsClosed: Int,
        credentialsDeleted: Int,
        credentialsRetained: Int,
        credentialCleanupPending: Bool,
        syncDeferred: Bool
    ) {
        self.sessionsClosed = sessionsClosed
        self.credentialsDeleted = credentialsDeleted
        self.credentialsRetained = credentialsRetained
        self.credentialCleanupPending = credentialCleanupPending
        self.syncDeferred = syncDeferred
    }
}

public struct SSHHostCredentialCleanupResult: Sendable, Codable, Hashable {
    public var deleted: Int
    public var pending: Bool

    public init(deleted: Int, pending: Bool) {
        self.deleted = deleted
        self.pending = pending
    }
}

public typealias SSHHostDeletionAction = @Sendable (UUID) async throws -> SSHHostDeletionReceipt
public typealias SSHHostSessionShutdown = @Sendable (UUID) async -> Int
/// Removes the local host row/config metadata. Returns true when only the
/// outbound sync enqueue failed after the local row was already gone.
public typealias SSHHostMetadataRemoval = @Sendable (UUID) async throws -> Bool
public typealias SSHHostCredentialCleanup = @Sendable (
    _ hostID: UUID,
    _ profile: RemoteHostProfile,
    _ deletable: [SecretReference],
    _ retainedAccounts: Set<String>
) async -> SSHHostCredentialCleanupResult

/// Injected App seams for deleting only this device's saved profile. None of
/// these callbacks may delete anything on the remote system.
public struct SSHHostDeletionHooks: Sendable {
    public var shutdownSessions: SSHHostSessionShutdown
    public var removeMetadata: SSHHostMetadataRemoval
    public var cleanupCredentials: SSHHostCredentialCleanup

    public init(
        shutdownSessions: @escaping SSHHostSessionShutdown,
        removeMetadata: @escaping SSHHostMetadataRemoval,
        cleanupCredentials: @escaping SSHHostCredentialCleanup
    ) {
        self.shutdownSessions = shutdownSessions
        self.removeMetadata = removeMetadata
        self.cleanupCredentials = cleanupCredentials
    }
}

/// Credential references owned by one host. Shared references are never
/// deleted with a single host profile.
public enum SSHHostCredentialReferences {
    /// Accounts owned by any OTHER saved host. Used before deleting an old
    /// reference so a shared credential is never broken by one host's edit.
    static func otherHostAccounts(
        store: RemoteHostStore,
        excluding hostID: UUID
    ) async -> Set<String>? {
        guard let stored = try? await store.hosts() else { return nil }
        var accounts: Set<String> = []
        for row in stored {
            guard let profile = try? RemoteHostProfile(stored: row),
                  profile.id != hostID else { continue }
            for reference in owned(by: profile) {
                accounts.insert(reference.keychainAccount)
            }
        }
        return accounts
    }

    public static func owned(by host: RemoteHostProfile) -> [SecretReference] {
        var references: [SecretReference] = []
        if let auth = SSHHostConfigurationSupport.reference(of: host.auth) {
            references.append(auth)
        }
        references.append(contentsOf: host.vncEndpoints.compactMap(\.passwordRef))
        var seen: Set<String> = []
        return references.filter { seen.insert($0.keychainAccount).inserted }
    }

    /// Owned references minus anything still used by another saved host or a
    /// shared credential card/account.
    public static func deletable(
        ownedBy host: RemoteHostProfile,
        otherHosts: [RemoteHostProfile],
        sharedAccounts: Set<String>
    ) -> [SecretReference] {
        let ownedReferences = owned(by: host)
        let otherAccounts = Set(
            otherHosts.flatMap { owned(by: $0).map(\.keychainAccount) }
        )
        return ownedReferences.filter {
            !otherAccounts.contains($0.keychainAccount)
                && !sharedAccounts.contains($0.keychainAccount)
        }
    }
}

/// Orders one local-profile deletion safely:
///   1. close sessions owned by this host;
///   2. remove the local host row/config metadata (must succeed first);
///   3. delete only this host's still-unshared credential revisions.
/// A metadata failure aborts before any secret cleanup.
public enum SSHHostDeletionCoordinator {
    public static func delete(
        host: RemoteHostProfile,
        otherHosts: [RemoteHostProfile],
        sharedAccounts: Set<String>,
        hooks: SSHHostDeletionHooks
    ) async throws -> SSHHostDeletionReceipt {
        let owned = SSHHostCredentialReferences.owned(by: host)
        let deletable = SSHHostCredentialReferences.deletable(
            ownedBy: host,
            otherHosts: otherHosts,
            sharedAccounts: sharedAccounts
        )
        let retainedAccounts = Set(owned.map(\.keychainAccount))
            .subtracting(deletable.map(\.keychainAccount))

        let sessionsClosed = await hooks.shutdownSessions(host.id)
        let syncDeferred = try await hooks.removeMetadata(host.id)
        let cleanup = await hooks.cleanupCredentials(
            host.id,
            host,
            deletable,
            retainedAccounts
        )
        return SSHHostDeletionReceipt(
            sessionsClosed: sessionsClosed,
            credentialsDeleted: cleanup.deleted,
            credentialsRetained: max(0, owned.count - cleanup.deleted),
            credentialCleanupPending: cleanup.pending,
            syncDeferred: syncDeferred
        )
    }
}

/// Performs one real SSH handshake against a saved profile. The probe must
/// close its connection before returning. Host-key decisions flow through the
/// supplied handler, which is the tool's canonical approval continuation.
public typealias SSHHostConnectionProbe = @Sendable (
    _ profile: RemoteHostProfile,
    _ hostKeyDecision: @escaping HostKeyDecisionHandler
) async throws -> Void

public enum SSHHostAuthMethodInput: String, Decodable, Sendable, CaseIterable {
    case password
    case privateKey
    case deviceKey
    case none

    var requiresCredential: Bool { self != .none }
    var deviceBound: Bool { self == .deviceKey }

    func auth(_ reference: SecretReference?, keyType: SSHAuthMethod.SSHKeyType) throws -> SSHAuthMethod {
        switch self {
        case .none:
            if reference != nil {
                throw FloeError.validationFailed("authMethod none cannot carry a credential")
            }
            return .none
        case .password:
            guard let reference else {
                throw FloeError.validationFailed("password authentication requires credentialInput")
            }
            return .password(reference)
        case .privateKey:
            guard let reference else {
                throw FloeError.validationFailed("privateKey authentication requires credentialInput")
            }
            return .importedKey(reference, keyType: keyType)
        case .deviceKey:
            guard let reference else {
                throw FloeError.validationFailed("deviceKey authentication requires credentialInput")
            }
            return .deviceGeneratedKey(reference, keyType: keyType)
        }
    }
}

public enum SSHHostKeyPolicySelection: String, Decodable, Sendable, CaseIterable {
    case trustOnFirstUse
    case pinned
}

/// Shared response fields and validation for the SSH configuration tools.
enum SSHHostConfigurationSupport {
    static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw FloeError.internalError("Could not encode the SSH host profile")
        }
        return string
    }

    static func policyString(
        _ selection: SSHHostKeyPolicySelection,
        fingerprint: String?
    ) throws -> String {
        let trimmed = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch selection {
        case .trustOnFirstUse:
            guard trimmed.isEmpty else {
                throw FloeError.validationFailed(
                    "pinnedFingerprint requires hostKeyPolicy pinned"
                )
            }
            return "trustOnFirstUse"
        case .pinned:
            guard !trimmed.isEmpty else {
                throw FloeError.validationFailed(
                    "hostKeyPolicy pinned requires a pinnedFingerprint"
                )
            }
            return "pinned:\(trimmed)"
        }
    }

    static func ensureFreshRevision(
        previous: SecretReference?,
        new: SecretReference?
    ) throws {
        guard let previous, let new else { return }
        guard previous.keychainAccount != new.keychainAccount else {
            throw FloeError.invalidConfiguration(
                "The credential writer reused an existing account; a fresh revision account is required"
            )
        }
    }

    static func reference(of auth: SSHAuthMethod) -> SecretReference? {
        switch auth {
        case .none: nil
        case .password(let reference): reference
        case .importedKey(let reference, _): reference
        case .deviceGeneratedKey(let reference, _): reference
        }
    }

    static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func validateAuthInput(
        method: SSHHostAuthMethodInput,
        credentialInput: String?,
        keyType: SSHAuthMethod.SSHKeyType?,
        writerAvailable: Bool
    ) throws {
        if method.requiresCredential {
            guard let credentialInput,
                  !credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloeError.validationFailed(
                    "credentialInput is required for \(method.rawValue) authentication"
                )
            }
            guard writerAvailable else {
                throw FloeError.invalidConfiguration(
                    "Secure SSH credential storage is unavailable"
                )
            }
        } else {
            guard credentialInput?.isEmpty ?? true else {
                throw FloeError.validationFailed(
                    "authMethod none cannot carry credentialInput"
                )
            }
            guard keyType == nil else {
                throw FloeError.validationFailed(
                    "keyType applies only to privateKey or deviceKey authentication"
                )
            }
        }
        if method == .password, keyType != nil {
            throw FloeError.validationFailed(
                "keyType applies only to privateKey or deviceKey authentication"
            )
        }
    }

    /// Resolves the SSH credential input through the native authorization seam
    /// before any Keychain write. A raw setup value passes through; a
    /// placeholder must be proven by the App resolver.
    static func resolveAuthInput(
        method: SSHHostAuthMethodInput,
        credentialInput: String?,
        hostID: UUID,
        runID: UUID,
        toolName: String,
        resolver: CredentialInputResolver?
    ) async throws -> CredentialInputResolution? {
        guard method.requiresCredential else { return nil }
        guard let credentialInput, let data = credentialInput.data(using: .utf8),
              !data.isEmpty else {
            throw FloeError.validationFailed("credentialInput is required")
        }
        return try await SSHHostCredentialInputSupport.resolve(
            data,
            slot: CredentialInputSlot(
                runID: runID,
                toolName: toolName,
                fieldPath: "credentialInput",
                expectedKind: method == .password ? .sshPassword : .sshPrivateKey,
                hostID: hostID
            ),
            resolver: resolver
        )
    }

    static func auth(
        method: SSHHostAuthMethodInput,
        resolution: CredentialInputResolution?,
        keyType: SSHAuthMethod.SSHKeyType?,
        hostID: UUID,
        label: String,
        writer: SSHAuthCredentialWriter?
    ) async throws -> (method: SSHAuthMethod, reference: SecretReference?, wroteCredential: Bool) {
        let key = keyType ?? .ed25519
        guard method.requiresCredential else {
            guard resolution == nil else {
                throw FloeError.validationFailed("authMethod none cannot carry a credential")
            }
            return (.none, nil, false)
        }
        guard let writer else {
            throw FloeError.invalidConfiguration("Secure SSH credential storage is unavailable")
        }
        guard let resolution else {
            throw FloeError.validationFailed("credentialInput is required")
        }
        guard !resolution.secret.isEmpty else {
            throw FloeError.validationFailed("SSH credential must not be empty")
        }
        let reference = try await writer(hostID, resolution.secret, label, method)
        return (try method.auth(reference, keyType: key), reference, true)
    }

    /// Resolves every VNC credential input in one array before the caller
    /// performs its first Keychain write. The key is the exact array index.
    static func resolveVNCInputs(
        _ values: [SSHUpdateHostTool.Arguments.VNCConnection],
        hostID: UUID,
        arrayKey: String,
        runID: UUID,
        toolName: String,
        resolver: CredentialInputResolver?
    ) async throws -> [Int: CredentialInputResolution] {
        var resolutions: [Int: CredentialInputResolution] = [:]
        for (index, value) in values.enumerated() {
            if let resolution = try await resolveVNCInput(
                value,
                hostID: hostID,
                fieldPath: "\(arrayKey).\(index).\(value.credentialFieldKey)",
                runID: runID,
                toolName: toolName,
                resolver: resolver
            ) {
                resolutions[index] = resolution
            }
        }
        return resolutions
    }

    static func resolveVNCInput(
        _ value: SSHUpdateHostTool.Arguments.VNCConnection,
        hostID: UUID,
        fieldPath: String,
        runID: UUID,
        toolName: String,
        resolver: CredentialInputResolver?
    ) async throws -> CredentialInputResolution? {
        guard value.clearPassword != true,
              let credentialInput = value.credentialInput,
              !credentialInput.isEmpty else {
            return nil
        }
        guard let data = credentialInput.data(using: .utf8) else {
            throw FloeError.validationFailed("VNC credentialInput is not UTF-8")
        }
        return try await SSHHostCredentialInputSupport.resolve(
            data,
            slot: CredentialInputSlot(
                runID: runID,
                toolName: toolName,
                fieldPath: fieldPath,
                expectedKind: .vncPassword,
                hostID: hostID
            ),
            resolver: resolver
        )
    }

    static func validateVNCConnections(
        _ connections: [SSHUpdateHostTool.Arguments.VNCConnection]?,
        writerAvailable: Bool
    ) throws {
        for connection in connections ?? [] {
            if connection.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(1...65535).contains(connection.port) {
                throw FloeError.validationFailed("VNC host and port must be valid")
            }
            if let id = connection.id, UUID(uuidString: id) == nil {
                throw FloeError.validationFailed("VNC connection id must be a UUID")
            }
            if connection.clearPassword == true, connection.credentialInput?.isEmpty == false {
                throw FloeError.validationFailed(
                    "A VNC connection cannot set and clear its password together"
                )
            }
            if let credentialInput = connection.credentialInput, !credentialInput.isEmpty,
               !writerAvailable {
                throw FloeError.invalidConfiguration(
                    "Secure VNC credential storage is unavailable"
                )
            }
        }
    }

    static func validateAuxiliaryConnections(
        _ connections: [SSHUpdateHostTool.Arguments.AuxiliaryConnection]?
    ) throws {
        for connection in connections ?? [] {
            if let id = connection.id, UUID(uuidString: id) == nil {
                throw FloeError.validationFailed("connection id must be a UUID")
            }
            switch connection.kind {
            case .telnet, .tcp:
                guard connection.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      let port = connection.port, (1...65535).contains(port) else {
                    throw FloeError.validationFailed("TCP/Telnet host and port must be valid")
                }
            case .bluetoothSerial:
                guard connection.bluetoothPeripheralID.flatMap(UUID.init(uuidString:)) != nil,
                      connection.bluetoothServiceUUID?.isEmpty == false,
                      connection.bluetoothWriteCharacteristicUUID?.isEmpty == false else {
                    throw FloeError.validationFailed("BLE serial metadata is incomplete")
                }
            }
        }
    }

    static func endpoint(
        from value: SSHUpdateHostTool.Arguments.VNCConnection,
        hostID: UUID,
        previous: VNCEndpoint?,
        writer: VNCCredentialWriter?,
        resolution: CredentialInputResolution?
    ) async throws -> (endpoint: VNCEndpoint, newReference: SecretReference?, wroteCredential: Bool) {
        let connectionID = value.id.flatMap(UUID.init(uuidString:)) ?? previous?.id ?? UUID()
        var reference = previous?.passwordRef
        var newReference: SecretReference?
        var wrote = false
        if value.clearPassword == true {
            reference = nil
        } else if let resolution {
            guard let writer else {
                throw FloeError.invalidConfiguration(
                    "Secure VNC credential storage is unavailable"
                )
            }
            guard !resolution.secret.isEmpty else {
                throw FloeError.validationFailed("VNC password must not be empty")
            }
            let written = try await writer(hostID, connectionID, resolution.secret)
            reference = written
            newReference = written
            wrote = true
        }
        return (VNCEndpoint(
            id: connectionID,
            displayName: value.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: value.transport,
            host: value.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: value.port,
            passwordRef: reference
        ), newReference, wrote)
    }

    static func auxiliary(
        from value: SSHUpdateHostTool.Arguments.AuxiliaryConnection,
        previousID: UUID? = nil
    ) -> RemoteAuxiliaryConnection {
        RemoteAuxiliaryConnection(
            id: value.id.flatMap(UUID.init(uuidString:)) ?? previousID ?? UUID(),
            displayName: value.displayName,
            kind: value.kind,
            host: value.host,
            port: value.port,
            bluetoothPeripheralID: value.bluetoothPeripheralID.flatMap(UUID.init(uuidString:)),
            bluetoothServiceUUID: value.bluetoothServiceUUID,
            bluetoothWriteCharacteristicUUID: value.bluetoothWriteCharacteristicUUID,
            bluetoothNotifyCharacteristicUUID: value.bluetoothNotifyCharacteristicUUID
        )
    }

    static func vncMetadata(_ endpoints: [VNCEndpoint]) -> [[String: Any]] {
        endpoints.map { endpoint in
            [
                "id": endpoint.id.uuidString,
                "displayName": endpoint.displayName,
                "transport": endpoint.transport.rawValue,
                "host": endpoint.host,
                "port": endpoint.port,
                "passwordConfigured": endpoint.passwordRef != nil
            ]
        }
    }
}

public struct SSHCreateHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var displayName: String
        public var address: String
        public var port: Int?
        public var user: String
        public var authMethod: SSHHostAuthMethodInput
        public var credentialInput: String?
        public var keyType: SSHAuthMethod.SSHKeyType?
        public var deviceKind: RemoteDeviceKind?
        public var isRemoteExecutionEnvironment: Bool?
        public var hostKeyPolicy: SSHHostKeyPolicySelection?
        public var pinnedFingerprint: String?
        public var vncConnections: [SSHUpdateHostTool.Arguments.VNCConnection]?
        public var auxiliaryConnections: [SSHUpdateHostTool.Arguments.AuxiliaryConnection]?
    }

    public static let name = "ssh.createHost"
    public static let toolDescription =
        "Create a saved remote device for first-time setup, including its SSH authentication and optional VNC/Telnet/TCP/BLE connection metadata. Use ssh.listHosts first to avoid a duplicate. authMethod password, privateKey or deviceKey requires credentialInput: the plaintext supplied for this task, or an existing ordinary Floe credential-card reference. Floe stores it in Keychain and never returns it. authMethod none creates a VNC/Telnet/TCP/BLE-only device. After creation, run ssh.verifyHost to perform a real handshake; a first connection asks the user to approve the host-key fingerprint through the existing task approval card. Later fingerprint changes always fail closed."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "displayName": {"type": "string"},
        "address": {"type": "string"},
        "port": {"type": "integer", "minimum": 1, "maximum": 65535},
        "user": {"type": "string"},
        "authMethod": {"type": "string", "enum": ["password", "privateKey", "deviceKey", "none"]},
        "credentialInput": {"type": "string", "description": "Plaintext for this setup or an existing ordinary Floe credential-card reference"},
        "keyType": {"type": "string", "enum": ["ed25519", "ecdsaP256", "rsa4096"]},
        "deviceKind": {"type": "string", "enum": ["unspecified", "linux", "mac", "windows", "nas", "router", "switchDevice", "appliance", "other"]},
        "isRemoteExecutionEnvironment": {"type": "boolean"},
        "hostKeyPolicy": {"type": "string", "enum": ["trustOnFirstUse", "pinned"]},
        "pinnedFingerprint": {"type": "string"},
        "vncConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "transport": {"type": "string", "enum": ["direct", "sshTunnel"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "credentialInput": {"type": "string"}, "password": {"type": "string"}, "clearPassword": {"type": "boolean"}}, "required": ["displayName", "transport", "host", "port"], "additionalProperties": false}},
        "auxiliaryConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "kind": {"type": "string", "enum": ["telnet", "tcp", "bluetoothSerial"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "bluetoothPeripheralID": {"type": "string"}, "bluetoothServiceUUID": {"type": "string"}, "bluetoothWriteCharacteristicUUID": {"type": "string"}, "bluetoothNotifyCharacteristicUUID": {"type": "string"}}, "required": ["displayName", "kind"], "additionalProperties": false}}
      },
      "required": ["displayName", "address", "user", "authMethod"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .accessesCredentials]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let store: RemoteHostStore
    private let credentialWriter: SSHAuthCredentialWriter?
    private let vncPasswordWriter: VNCPasswordWriter?
    private let secretDeleter: SecretReferenceDeleter?
    private let aliasCommitter: SSHAuthReferenceCommitter?
    private let credentialInputResolver: CredentialInputResolver?
    private let saveHostOverride: RemoteHostSaveAction?
    private let updateObserver: RemoteHostUpdateObserver?

    public init(
        store: RemoteHostStore,
        credentialWriter: SSHAuthCredentialWriter? = nil,
        vncPasswordWriter: VNCPasswordWriter? = nil,
        secretDeleter: SecretReferenceDeleter? = nil,
        aliasCommitter: SSHAuthReferenceCommitter? = nil,
        credentialInputResolver: CredentialInputResolver? = nil,
        updateObserver: RemoteHostUpdateObserver? = nil,
        saveHostOverride: RemoteHostSaveAction? = nil
    ) {
        self.store = store
        self.credentialWriter = credentialWriter
        self.vncPasswordWriter = vncPasswordWriter
        self.secretDeleter = secretDeleter
        self.aliasCommitter = aliasCommitter
        self.credentialInputResolver = credentialInputResolver
        self.updateObserver = updateObserver
        self.saveHostOverride = saveHostOverride
    }

    public func validate(_ args: Arguments) throws {
        guard !args.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("displayName must not be empty")
        }
        guard !args.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("address must not be empty")
        }
        guard !args.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("user must not be empty")
        }
        if let port = args.port, !(1...65535).contains(port) {
            throw FloeError.validationFailed("port must be 1-65535")
        }
        try SSHHostConfigurationSupport.validateAuthInput(
            method: args.authMethod,
            credentialInput: args.credentialInput,
            keyType: args.keyType,
            writerAvailable: credentialWriter != nil
        )
        if args.authMethod == .none, args.isRemoteExecutionEnvironment == true {
            throw FloeError.validationFailed(
                "A remote execution environment requires SSH authentication"
            )
        }
        if let policy = args.hostKeyPolicy {
            _ = try SSHHostConfigurationSupport.policyString(
                policy,
                fingerprint: args.pinnedFingerprint
            )
        } else if args.pinnedFingerprint != nil {
            throw FloeError.validationFailed(
                "pinnedFingerprint requires hostKeyPolicy pinned"
            )
        }
        try SSHHostConfigurationSupport.validateVNCConnections(
            args.vncConnections,
            writerAvailable: vncPasswordWriter != nil
        )
        let writesSecrets = args.authMethod.requiresCredential
            || (args.vncConnections ?? []).contains {
                $0.credentialInput?.isEmpty == false
            }
        if writesSecrets, secretDeleter == nil {
            throw FloeError.invalidConfiguration(
                "Secure credential rollback is unavailable; host creation is disabled"
            )
        }
        try SSHHostConfigurationSupport.validateAuxiliaryConnections(args.auxiliaryConnections)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let traceID = UUID().uuidString
        let startedAt = Date()
        let hostID = UUID()
        let label = args.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = context.executionToolName ?? Self.name
        var stagedReferences: [SecretReference] = []
        var pendingCaptures: [CredentialInputResolution] = []
        var wroteSSHCredential = false
        var committed = false

        do {
            // Resolve every credential reference before the first Keychain
            // write: malformed, foreign, missing or locked inputs must fail
            // without staging or saving anything.
            let sshResolution = try await SSHHostConfigurationSupport.resolveAuthInput(
                method: args.authMethod,
                credentialInput: args.credentialInput,
                hostID: hostID,
                runID: context.runID,
                toolName: toolName,
                resolver: credentialInputResolver
            )
            let vncValues = args.vncConnections ?? []
            let vncResolutions = try await SSHHostConfigurationSupport.resolveVNCInputs(
                vncValues,
                hostID: hostID,
                arrayKey: "vncConnections",
                runID: context.runID,
                toolName: toolName,
                resolver: credentialInputResolver
            )

            let authResult = try await SSHHostConfigurationSupport.auth(
                method: args.authMethod,
                resolution: sshResolution,
                keyType: args.keyType,
                hostID: hostID,
                label: label,
                writer: credentialWriter
            )
            wroteSSHCredential = authResult.wroteCredential
            if let reference = authResult.reference { stagedReferences.append(reference) }
            if let sshResolution { pendingCaptures.append(sshResolution) }

            var endpoints: [VNCEndpoint] = []
            for (index, value) in vncValues.enumerated() {
                let result = try await SSHHostConfigurationSupport.endpoint(
                    from: value,
                    hostID: hostID,
                    previous: nil,
                    writer: vncPasswordWriter,
                    resolution: vncResolutions[index]
                )
                if let resolution = vncResolutions[index] {
                    pendingCaptures.append(resolution)
                }
                if let reference = result.newReference { stagedReferences.append(reference) }
                endpoints.append(result.endpoint)
            }
            let auxiliary = (args.auxiliaryConnections ?? []).map {
                SSHHostConfigurationSupport.auxiliary(from: $0)
            }

            let isRemoteExecution = args.isRemoteExecutionEnvironment
                ?? (args.authMethod != .none)
            let policy: String
            if let selection = args.hostKeyPolicy {
                policy = try SSHHostConfigurationSupport.policyString(
                    selection,
                    fingerprint: args.pinnedFingerprint
                )
            } else {
                policy = "trustOnFirstUse"
            }
            let profile = RemoteHostProfile(
                id: hostID,
                displayName: label,
                address: args.address.trimmingCharacters(in: .whitespacesAndNewlines),
                port: args.port ?? 22,
                user: args.user.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: authResult.method,
                hostKeyPolicy: args.hostKeyPolicy == .pinned
                    ? .pinned(fingerprintSHA256: SSHHostConfigurationSupport.normalizedFingerprint(args.pinnedFingerprint) ?? "")
                    : .trustOnFirstUse,
                deviceKind: args.deviceKind ?? .unspecified,
                isRemoteExecutionEnvironment: isRemoteExecution,
                vncEndpoints: endpoints,
                auxiliaryConnections: auxiliary
            )
            try profile.validate()

            let stored = RemoteHostStore.StoredHost(
                id: profile.id,
                displayName: profile.displayName,
                address: profile.address,
                port: profile.port,
                user: profile.user,
                authJSON: try SSHHostConfigurationSupport.encoded(profile.auth),
                jumpChainJSON: "[]",
                hostKeyPolicy: policy,
                allowsLegacyAlgorithms: false,
                vncEndpointJSON: try endpoints.first.map {
                    try SSHHostConfigurationSupport.encoded($0)
                },
                deviceKind: profile.deviceKind.rawValue,
                isRemoteExecutionEnvironment: profile.isRemoteExecutionEnvironment,
                vncEndpointsJSON: try SSHHostConfigurationSupport.encoded(profile.vncEndpoints),
                auxiliaryConnectionsJSON: try SSHHostConfigurationSupport.encoded(profile.auxiliaryConnections)
            )

            if let saveHostOverride {
                try await saveHostOverride(stored)
            } else {
                try await store.saveHost(stored)
            }
            committed = true

            // The host row is committed. Consume the one-time captures that
            // supplied these exact fields; a failed save above rolled back the
            // staged revisions and left every capture retryable.
            for resolution in pendingCaptures {
                await resolution.consumeAfterCommit()
            }

            if let reference = authResult.reference {
                await aliasCommitter?(hostID, reference)
            }
            if let updateObserver {
                await updateObserver(hostID, Set(endpoints.map(\.id)))
            }
            FloeLogger(category: .ssh).info(
                "sshHostCreated trace=\(traceID) host=\(hostID.uuidString) ssh=\(args.authMethod.rawValue) vnc=\(endpoints.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )

            var response: [String: Any] = [
                "created": true,
                "hostID": hostID.uuidString,
                "displayName": profile.displayName,
                "address": profile.address,
                "port": profile.port,
                "user": profile.user,
                "authMethod": args.authMethod.rawValue,
                "sshEnabled": args.authMethod != .none,
                "credentialStored": wroteSSHCredential,
                "deviceKind": profile.deviceKind.rawValue,
                "isRemoteExecutionEnvironment": profile.isRemoteExecutionEnvironment,
                "hostKeyPolicy": args.hostKeyPolicy?.rawValue ?? "trustOnFirstUse",
                "vncConnections": SSHHostConfigurationSupport.vncMetadata(endpoints),
                "configuredVNCCount": endpoints.count,
                "nextAction": args.authMethod == .none
                    ? "Run ssh.listHosts to confirm the saved connections."
                    : "Run ssh.verifyHost with this hostID to perform the real handshake and approve the first host key."
            ]
            response["pinnedFingerprint"] = SSHHostConfigurationSupport
                .normalizedFingerprint(args.pinnedFingerprint) ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            return ToolExecutionOutput(
                summary: String(decoding: data, as: UTF8.self),
                fullOutputSHA256: digest(data),
                exitStatus: 0
            )
        } catch {
            if !committed {
                await rollBack(references: stagedReferences)
            }
            let nsError = error as NSError
            FloeLogger(category: .ssh).warning(
                "sshHostCreateFailed trace=\(traceID) host=\(hostID.uuidString) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
    }

    private func rollBack(references: [SecretReference]) async {
        guard let secretDeleter else { return }
        var seen: Set<String> = []
        for reference in references
        where seen.insert(reference.keychainAccount).inserted {
            try? await secretDeleter(reference)
        }
    }
}

public struct SSHSetHostAuthTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String
        public var authMethod: SSHHostAuthMethodInput
        public var credentialInput: String?
        public var keyType: SSHAuthMethod.SSHKeyType?
        public var isRemoteExecutionEnvironment: Bool?
    }

    public static let name = "ssh.setHostAuth"
    public static let toolDescription =
        "Bind, change or remove SSH authentication on an existing saved device without touching its VNC, Telnet, TCP or BLE connections. Use ssh.listHosts first. authMethod password, privateKey or deviceKey requires credentialInput: the plaintext supplied for this task, or an existing ordinary Floe credential-card reference. The new secret is staged in a fresh per-revision Keychain account and the previous reference is deleted only after the host row save commits; a failed save rolls back the staged revision and leaves the old one intact. authMethod none removes the saved SSH secret and disables remote execution unless explicitly re-enabled. After a change, run ssh.verifyHost to validate the real handshake."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "hostID": {"type": "string"},
        "authMethod": {"type": "string", "enum": ["password", "privateKey", "deviceKey", "none"]},
        "credentialInput": {"type": "string", "description": "Plaintext for this setup or an existing ordinary Floe credential-card reference"},
        "keyType": {"type": "string", "enum": ["ed25519", "ecdsaP256", "rsa4096"]},
        "isRemoteExecutionEnvironment": {"type": "boolean"}
      },
      "required": ["hostID", "authMethod"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [
        .persistsPersonalData, .accessesCredentials
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let store: RemoteHostStore
    private let credentialWriter: SSHAuthCredentialWriter?
    private let secretDeleter: SecretReferenceDeleter?
    private let aliasCommitter: SSHAuthReferenceCommitter?
    private let aliasDeleter: SSHAuthLegacyAliasDeleter?
    private let credentialInputResolver: CredentialInputResolver?
    private let saveHostOverride: RemoteHostSaveAction?
    private let updateObserver: RemoteHostUpdateObserver?

    public init(
        store: RemoteHostStore,
        credentialWriter: SSHAuthCredentialWriter? = nil,
        secretDeleter: SecretReferenceDeleter? = nil,
        aliasCommitter: SSHAuthReferenceCommitter? = nil,
        aliasDeleter: SSHAuthLegacyAliasDeleter? = nil,
        credentialInputResolver: CredentialInputResolver? = nil,
        updateObserver: RemoteHostUpdateObserver? = nil,
        saveHostOverride: RemoteHostSaveAction? = nil
    ) {
        self.store = store
        self.credentialWriter = credentialWriter
        self.secretDeleter = secretDeleter
        self.aliasCommitter = aliasCommitter
        self.aliasDeleter = aliasDeleter
        self.credentialInputResolver = credentialInputResolver
        self.updateObserver = updateObserver
        self.saveHostOverride = saveHostOverride
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.hostID) != nil else {
            throw FloeError.validationFailed("hostID must be a UUID")
        }
        try SSHHostConfigurationSupport.validateAuthInput(
            method: args.authMethod,
            credentialInput: args.credentialInput,
            keyType: args.keyType,
            writerAvailable: credentialWriter != nil
        )
        guard secretDeleter != nil else {
            throw FloeError.invalidConfiguration(
                "Secure credential cleanup is unavailable; authentication changes are disabled"
            )
        }
        if args.authMethod == .none, args.isRemoteExecutionEnvironment == true {
            throw FloeError.validationFailed(
                "A remote execution environment requires SSH authentication"
            )
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let hostID = UUID(uuidString: args.hostID)!
        let toolName = context.executionToolName ?? Self.name
        guard var host = try await store.host(id: hostID) else {
            throw FloeError.validationFailed("saved host not found")
        }
        let previousAuth = try JSONDecoder().decode(
            SSHAuthMethod.self, from: Data(host.authJSON.utf8)
        )
        let label = host.displayName
        let previousReference = SSHHostConfigurationSupport.reference(of: previousAuth)
        let otherHostAccounts = await SSHHostCredentialReferences.otherHostAccounts(
            store: store,
            excluding: hostID
        )

        // Resolve before the writer stages anything. Missing, locked, foreign
        // or malformed references fail without touching the old credential.
        let resolution = try await SSHHostConfigurationSupport.resolveAuthInput(
            method: args.authMethod,
            credentialInput: args.credentialInput,
            hostID: hostID,
            runID: context.runID,
            toolName: toolName,
            resolver: credentialInputResolver
        )
        let authResult = try await SSHHostConfigurationSupport.auth(
            method: args.authMethod,
            resolution: resolution,
            keyType: args.keyType,
            hostID: hostID,
            label: label,
            writer: credentialWriter
        )
        do {
            try SSHHostConfigurationSupport.ensureFreshRevision(
                previous: previousReference,
                new: authResult.reference
            )
            host.authJSON = try SSHHostConfigurationSupport.encoded(authResult.method)
            if args.authMethod == .none {
                host.isRemoteExecutionEnvironment = false
            } else if let requested = args.isRemoteExecutionEnvironment {
                host.isRemoteExecutionEnvironment = requested
            } else if previousAuth == .none {
                host.isRemoteExecutionEnvironment = true
            }
            try RemoteHostProfile(stored: host).validate()
            if let saveHostOverride {
                try await saveHostOverride(host)
            } else {
                try await store.saveHost(host)
            }
        } catch {
            if let reference = authResult.reference,
               reference.keychainAccount != previousReference?.keychainAccount {
                try? await secretDeleter?(reference)
            }
            throw error
        }

        // The host row is committed. Consume the one-time capture that
        // supplied this exact field; a failed save above left it retryable.
        if let resolution {
            await resolution.consumeAfterCommit()
        }

        var removed = false
        if let previousReference,
           previousReference.keychainAccount != authResult.reference?.keychainAccount,
           let otherHostAccounts,
           !otherHostAccounts.contains(previousReference.keychainAccount) {
            do {
                try await secretDeleter?(previousReference)
                removed = true
            } catch {
                FloeLogger(category: .security).warning(
                    "sshHostAuthSecretRemovalFailed host=\(hostID.uuidString)"
                )
            }
        }
        if args.authMethod == .none {
            await aliasDeleter?(hostID)
        } else if let reference = authResult.reference {
            await aliasCommitter?(hostID, reference)
        }
        if let updateObserver {
            await updateObserver(hostID, [])
        }
        FloeLogger(category: .ssh).info(
            "sshHostAuthUpdated host=\(hostID.uuidString) method=\(args.authMethod.rawValue) removed=\(removed)"
        )

        var response: [String: Any] = [
            "updated": true,
            "hostID": hostID.uuidString,
            "authMethod": args.authMethod.rawValue,
            "sshEnabled": args.authMethod != .none,
            "credentialStored": authResult.wroteCredential,
            "credentialRemoved": removed,
            "previousCredentialRemoved": removed,
            "isRemoteExecutionEnvironment": host.isRemoteExecutionEnvironment ?? true
        ]
        response["nextAction"] = args.authMethod == .none
            ? "SSH authentication removed. VNC and other saved connections are unchanged."
            : "Run ssh.verifyHost with this hostID to validate the handshake and approve a first-use host key."
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: digest(data),
            exitStatus: 0
        )
    }
}

public struct SSHDeleteHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String

        public init(hostID: String) { self.hostID = hostID }
    }

    public static let name = "ssh.deleteHost"
    public static let toolDescription =
        "Delete ONE saved local connection profile by exact hostID. This closes that host's active SSH/VNC sessions, removes only this device's saved host metadata, and then deletes only credential revisions owned solely by this host. It never deletes anything on the remote system and never removes another host, another endpoint or a shared credential reference. If host metadata cannot be removed, no credential is deleted."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"}},"required":["hostID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [
        .persistsPersonalData, .accessesCredentials
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let store: RemoteHostStore
    private let deletion: SSHHostDeletionAction

    public init(store: RemoteHostStore, deletion: @escaping SSHHostDeletionAction) {
        self.store = store
        self.deletion = deletion
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.hostID) != nil else {
            throw FloeError.validationFailed("hostID must be a UUID")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let hostID = UUID(uuidString: args.hostID)!
        guard let stored = try await store.host(id: hostID) else {
            throw FloeError.validationFailed("saved host not found")
        }
        let receipt = try await deletion(hostID)
        FloeLogger(category: .ssh).info(
            "sshHostDeleted host=\(hostID.uuidString) sessions=\(receipt.sessionsClosed) credentialsDeleted=\(receipt.credentialsDeleted) retained=\(receipt.credentialsRetained)"
        )
        var response: [String: Any] = [
            "deleted": true,
            "hostID": hostID.uuidString,
            "displayName": stored.displayName,
            "remoteSystemChanged": false,
            "sessionsClosed": receipt.sessionsClosed,
            "credentialsDeleted": receipt.credentialsDeleted,
            "credentialsRetained": receipt.credentialsRetained,
            "credentialCleanupPending": receipt.credentialCleanupPending,
            "syncDeferred": receipt.syncDeferred
        ]
        response["nextAction"] = receipt.credentialCleanupPending
            ? "The local profile was deleted; some credential cleanup did not complete. Retry cleanup or remove the saved credential from Settings."
            : "The local connection profile and its unshared credentials were removed. Nothing was deleted on the remote device."
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: digest(data),
            exitStatus: 0
        )
    }
}

public struct SSHVerifyHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String

        public init(hostID: String) { self.hostID = hostID }
    }

    public static let name = "ssh.verifyHost"
    public static let toolDescription =
        "Perform a real SSH handshake against a saved host to validate reachability, host identity and the saved authentication. On the first connection to a host, this call waits for one canonical task approval card that shows the exact key type and SHA256 fingerprint; approval pins that key for later connections. A changed fingerprint always fails closed and is never auto-trusted. Background calls without an interactive approval surface fail honestly. This tool does not run a remote command; use ssh.execute after it succeeds."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"}},"required":["hostID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = true

    private let store: RemoteHostStore
    private let probe: SSHHostConnectionProbe

    public init(store: RemoteHostStore, probe: @escaping SSHHostConnectionProbe) {
        self.store = store
        self.probe = probe
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.hostID) != nil else {
            throw FloeError.validationFailed("hostID must be a UUID")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let hostID = UUID(uuidString: args.hostID)!
        guard let stored = try await store.host(id: hostID) else {
            throw FloeError.validationFailed("saved host not found")
        }
        let profile = try RemoteHostProfile(stored: stored)
        guard profile.auth != .none else {
            throw FloeError.invalidConfiguration(
                "This device has no SSH authentication. Bind one with ssh.setHostAuth first."
            )
        }

        let recorder = SSHIdentityDecisionRecorder()
        let approvalReason = Self.approvalReason(profile: profile)
        let decision: HostKeyDecisionHandler = { challenge in
            await recorder.record(challenge: challenge)
            guard let approval = context.nestedApproval else {
                await recorder.record(decision: .unavailable)
                return false
            }
            let outcome = await approval.request(reason: approvalReason(challenge))
            switch outcome {
            case .allowed:
                await recorder.record(decision: .allowed)
                return true
            case .denied:
                await recorder.record(decision: .denied)
                return false
            case .cancelled:
                await recorder.record(decision: .cancelled)
                return false
            case .unavailable:
                await recorder.record(decision: .unavailable)
                return false
            }
        }

        let startedAt = Date()
        do {
            try await probe(profile, decision)
            let state = await recorder.state
            let pinnedFingerprint: String? = {
                if case .pinned(let fingerprint) = profile.hostKeyPolicy { return fingerprint }
                return nil
            }()
            let identity: String
            switch state.decision {
            case .allowed: identity = "approved"
            case .notRequested: identity = pinnedFingerprint == nil ? "alreadyTrusted" : "pinnedMatch"
            case .denied: identity = "denied"
            case .cancelled: identity = "cancelled"
            case .unavailable: identity = "approvalUnavailable"
            }
            var response: [String: Any] = [
                "status": "ok",
                "hostID": profile.id.uuidString,
                "address": profile.address,
                "port": profile.port,
                "user": profile.user,
                "connected": true,
                "authenticated": true,
                "authMethod": Self.authMethodName(profile.auth),
                "hostKeyPolicy": Self.policyName(profile.hostKeyPolicy),
                "identityVerification": identity,
                "identityDecision": state.decision.rawValue,
                "durationMs": Int(Date().timeIntervalSince(startedAt) * 1_000)
            ]
            if let fingerprint = state.challenge?.fingerprintSHA256 ?? pinnedFingerprint {
                response["hostKeyFingerprint"] = fingerprint
            } else {
                response["hostKeyFingerprint"] = NSNull()
            }
            response["hostKeyType"] = state.challenge?.keyType ?? NSNull()
            response["nextAction"] = "The saved host is authenticated. Use ssh.execute for authorized remote commands."
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            return ToolExecutionOutput(
                summary: String(decoding: data, as: UTF8.self),
                fullOutputSHA256: digest(data),
                exitStatus: 0
            )
        } catch is CancellationError {
            throw FloeError.cancelled
        } catch let error as FloeError where error == .cancelled {
            throw error
        } catch {
            let state = await recorder.state
            return Self.failureOutput(
                profile: profile,
                error: error,
                state: state,
                interactiveApprovalAvailable: context.nestedApproval != nil,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
        }
    }

    private static func approvalReason(
        profile: RemoteHostProfile
    ) -> @Sendable (HostKeyChallenge) -> String {
        { challenge in
            if FloeL10n.isChinese {
                return """
                信任这台 SSH 主机吗？
                主机：\(profile.displayName)（\(challenge.address):\(challenge.port)）
                密钥：\(challenge.keyType) \(challenge.fingerprintSHA256)
                这是首次连接。只有在你确认该指纹属于目标设备时才允许。以后指纹变化会直接拒绝连接。
                """
            }
            return """
            Trust this SSH host?
            Host: \(profile.displayName) (\(challenge.address):\(challenge.port))
            Key: \(challenge.keyType) \(challenge.fingerprintSHA256)
            This is the first connection. Approve only if you recognize this fingerprint. A later change is always rejected.
            """
        }
    }

    private static func failureOutput(
        profile: RemoteHostProfile,
        error: Error,
        state: SSHIdentityDecisionRecorder.State,
        interactiveApprovalAvailable: Bool,
        durationMilliseconds: Int
    ) -> ToolExecutionOutput {
        var category = "transportFailed"
        var stage = "transport"
        var retryable = true
        var requiresUserAction = false
        var detail = error.localizedDescription
        var expectedFingerprint: String?
        var receivedFingerprint: String?

        if let sshError = error as? SSHConnectionError {
            switch sshError {
            case .sshNotConfigured:
                category = "configurationMissing"; stage = "configuration"; retryable = false
            case .hostKeyRejected:
                category = "hostKeyRejected"; stage = "hostKeyVerification"; retryable = false
                requiresUserAction = true
            case .hostKeyChanged(let expected, let received):
                category = "hostKeyChanged"; stage = "hostKeyVerification"; retryable = false
                requiresUserAction = true
                expectedFingerprint = expected
                receivedFingerprint = received
            case .invalidCredential, .authenticationFailed:
                category = "authenticationFailed"; stage = "authentication"; retryable = false
            case .invalidHostKey:
                category = "protocolIncompatible"; stage = "hostKeyVerification"; retryable = false
            case .unsupportedKeyType:
                category = "protocolIncompatible"; stage = "authentication"; retryable = false
            case .connectionRefused:
                category = "connectionRefused"; stage = "transport"
            case .hostNotFound:
                category = "networkUnreachable"; stage = "transport"
            case .timedOut:
                category = "timedOut"; stage = "transport"
            case .networkUnreachable:
                category = "networkUnreachable"; stage = "transport"
            case .transport:
                category = "transportFailed"; stage = "transport"
            }
            detail = sshError.localizedDescription
        } else if error is CancellationError {
            category = "cancelled"; stage = "transport"; retryable = false
        }

        let nextAction: String
        switch category {
        case "hostKeyRejected":
            if interactiveApprovalAvailable {
                nextAction = state.decision == .denied
                    ? "The host key was not approved. Compare the fingerprint with the device owner before trying again."
                    : "The host key was not trusted. Call ssh.verifyHost again from an active conversation to receive the approval card."
            } else {
                nextAction = "No interactive approval surface is available in this call. Compare the fingerprint out of band, then run ssh.verifyHost from an active conversation."
            }
        case "hostKeyChanged":
            nextAction = "Do not retry or overwrite. Verify the device identity out of band. A changed host key requires explicit user review before the saved identity is reset."
        case "authenticationFailed":
            nextAction = "Correct the saved authentication with ssh.setHostAuth, then run ssh.verifyHost again."
        default:
            nextAction = "Check the address, port and network path, then retry ssh.verifyHost."
        }

        var response: [String: Any] = [
            "status": "connectionFailed",
            "hostID": profile.id.uuidString,
            "address": profile.address,
            "port": profile.port,
            "user": profile.user,
            "connected": false,
            "authenticated": false,
            "category": category,
            "stage": stage,
            "retryable": retryable,
            "requiresUserAction": requiresUserAction,
            "reason": detail,
            "identityDecision": state.decision.rawValue,
            "hostKeyPolicy": policyName(profile.hostKeyPolicy),
            "durationMs": durationMilliseconds,
            "nextAction": nextAction
        ]
        response["hostKeyFingerprint"] = state.challenge?.fingerprintSHA256 ?? NSNull()
        response["hostKeyType"] = state.challenge?.keyType ?? NSNull()
        response["expectedFingerprint"] = expectedFingerprint ?? NSNull()
        response["receivedFingerprint"] = receivedFingerprint ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]))
            ?? Data(#"{"status":"connectionFailed"}"#.utf8)
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: digest(data),
            exitStatus: 2
        )
    }

    private static func authMethodName(_ auth: SSHAuthMethod) -> String {
        switch auth {
        case .none: "none"
        case .password: "password"
        case .importedKey: "privateKey"
        case .deviceGeneratedKey: "deviceKey"
        }
    }

    private static func policyName(_ policy: HostKeyPolicy) -> String {
        switch policy {
        case .trustOnFirstUse: "trustOnFirstUse"
        case .pinned: "pinned"
        }
    }
}

actor SSHIdentityDecisionRecorder {
    enum Decision: String, Sendable {
        case notRequested
        case allowed
        case denied
        case cancelled
        case unavailable
    }

    struct State: Sendable {
        var challenge: HostKeyChallenge?
        var decision: Decision
    }

    private var challenge: HostKeyChallenge?
    private var decision: Decision = .notRequested

    var state: State { State(challenge: challenge, decision: decision) }

    func record(challenge: HostKeyChallenge) {
        self.challenge = challenge
    }

    func record(decision: Decision) {
        self.decision = decision
    }
}

/// Registers the model-callable SSH host configuration tools. The call site
/// owns the credential writer/resolver and the VNC writers so all saved
/// secrets keep the existing Keychain, vault and host-store semantics.
public func registerSSHHostConfigurationTools(
    registry: ToolRunnerRegistry = .shared,
    store: RemoteHostStore,
    credentialWriter: @escaping SSHAuthCredentialWriter,
    secretDeleter: @escaping SecretReferenceDeleter,
    credentialResolver: @escaping SSHCredentialResolver,
    vncPasswordWriter: @escaping VNCPasswordWriter,
    hostDeletion: @escaping SSHHostDeletionAction,
    updateObserver: RemoteHostUpdateObserver? = nil,
    aliasCommitter: SSHAuthReferenceCommitter? = nil,
    aliasDeleter: SSHAuthLegacyAliasDeleter? = nil,
    credentialInputResolver: CredentialInputResolver? = nil,
    probe: SSHHostConnectionProbe? = nil
) {
    ToolCatalog.register(SSHCreateHostTool.self)
    ToolCatalog.register(SSHSetHostAuthTool.self)
    ToolCatalog.register(SSHDeleteHostTool.self)
    ToolCatalog.register(SSHVerifyHostTool.self)

    registry.register(SSHCreateHostTool(
        store: store,
        credentialWriter: credentialWriter,
        vncPasswordWriter: vncPasswordWriter,
        secretDeleter: secretDeleter,
        aliasCommitter: aliasCommitter,
        credentialInputResolver: credentialInputResolver,
        updateObserver: updateObserver
    ))
    registry.register(SSHSetHostAuthTool(
        store: store,
        credentialWriter: credentialWriter,
        secretDeleter: secretDeleter,
        aliasCommitter: aliasCommitter,
        aliasDeleter: aliasDeleter,
        credentialInputResolver: credentialInputResolver,
        updateObserver: updateObserver
    ))
    registry.register(SSHDeleteHostTool(store: store, deletion: hostDeletion))

    let service = SSHConnectionService(hostStore: store)
    let effectiveProbe = probe ?? { profile, hostKeyDecision in
        let handle = try await service.connect(
            profile: profile,
            credentialResolver: credentialResolver,
            hostKeyDecision: hostKeyDecision
        )
        await handle.close()
    }
    registry.register(SSHVerifyHostTool(store: store, probe: effectiveProbe))
}

private func digest(_ data: Data) -> String {
    FloeDigest.sha256Hex(data)
}
