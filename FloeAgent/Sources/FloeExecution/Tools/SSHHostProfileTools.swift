import Foundation
import Crypto
import FloeCore
import FloeSecurity
import FloeTools
import FloePersistence
import FloeSSH

public typealias VNCCredentialWriter = @Sendable (
    _ hostID: UUID,
    _ connectionID: UUID,
    _ credentialInput: Data
) async throws -> SecretReference

/// Source-compatible alias for integrations that still use the old name.
public typealias VNCPasswordWriter = VNCCredentialWriter

public typealias VNCPasswordDeleter = @Sendable (
    _ hostID: UUID,
    _ connectionID: UUID
) async throws -> Void

public typealias RemoteHostUpdateObserver = @Sendable (
    _ hostID: UUID,
    _ changedVNCEndpointIDs: Set<UUID>
) async -> Void

// MARK: - Native credential-input authorization

/// Native-only description of the exact credential slot a model-callable tool
/// is about to fill. The tool builds this from its canonical `ToolContext`
/// (`runID` / `executionToolName`) and the exact argument path that
/// `CredentialArgumentNormalizer` used. It is never Codable: model arguments
/// cannot supply it, and the resolver must never infer it from the value.
public struct CredentialInputSlot: Sendable, Hashable {
    public var runID: UUID
    public var toolName: String
    public var fieldPath: String
    public var expectedKind: CredentialKind
    public var hostID: UUID?

    public init(
        runID: UUID,
        toolName: String,
        fieldPath: String,
        expectedKind: CredentialKind,
        hostID: UUID?
    ) {
        self.runID = runID
        self.toolName = toolName
        self.fieldPath = fieldPath
        self.expectedKind = expectedKind
        self.hostID = hostID
    }
}

/// Bytes ready for the per-revision writer, plus a one-time cleanup action.
/// A raw setup value or explicit ordinary vault-card reuse carries a no-op
/// action. A same-run normalizer capture carries an action that deletes
/// exactly that temporary capture, and the tool runs it only after the host
/// row commits so a failed save leaves the capture retryable.
public struct CredentialInputResolution: Sendable {
    public let secret: Data
    private let consumeAction: @Sendable () async -> Void

    public init(secret: Data) {
        self.secret = secret
        self.consumeAction = {}
    }

    public init(
        secret: Data,
        consume: @escaping @Sendable () async -> Void
    ) {
        self.secret = secret
        self.consumeAction = consume
    }

    /// Runs once, after the host row has committed. Callers must not invoke
    /// this for an unresolved or failed write.
    public func consumeAfterCommit() async {
        await consumeAction()
    }
}

/// App-owned resolver for one credential input. The tool always passes the
/// canonical slot and the exact input bytes; the executor verifies provenance,
/// reads the secret and returns it together with its one-time cleanup action.
public typealias CredentialInputResolver = @Sendable (
    _ input: Data,
    _ slot: CredentialInputSlot
) async throws -> CredentialInputResolution

enum SSHHostCredentialInputSupport {
    /// Fails closed on any unresolved placeholder. Raw setup values pass
    /// through unchanged and never require a resolver. A malformed placeholder
    /// is rejected even when a resolver is present, before any Keychain write.
    static func resolve(
        _ input: Data,
        slot: CredentialInputSlot,
        resolver: CredentialInputResolver?
    ) async throws -> CredentialInputResolution {
        if let text = String(data: input, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("⟨credential") {
                // Only one whole-value, well-formed placeholder is accepted;
                // an embedded or truncated marker is malformed, never a raw
                // secret and never a reference to resolve.
                guard trimmed.hasPrefix("⟨credential"),
                      SecretIngressScanner.credentialID(from: trimmed) != nil else {
                    throw FloeError.validationFailed("Credential reference is malformed")
                }
                guard let resolver else {
                    throw FloeError.unauthorized
                }
                return try await resolver(input, slot)
            }
        }
        return CredentialInputResolution(secret: input)
    }
}

public struct SSHListHostsTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "ssh.listHosts"
    public static let toolDescription = "List saved remote devices, their stable IDs, roles, authentication method (never a credential), host-key policy and SSH/VNC/Telnet/TCP/BLE connection metadata. Use this before selecting, creating or editing a device. Credentials are never returned."
    public static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let store: RemoteHostStore

    public init(store: RemoteHostStore) { self.store = store }
    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let traceID = UUID().uuidString
        let startedAt = Date()
        let storedHosts = try await store.hosts()
        let defaultID = storedHosts.first { host in
            guard host.isRemoteExecutionEnvironment ?? true,
                  let auth = try? JSONDecoder().decode(
                    SSHAuthMethod.self,
                    from: Data(host.authJSON.utf8)
                  ) else { return false }
            return auth != .none
        }?.id
        let hosts: [[String: Any]] = storedHosts.map { host in
            let auth = try? JSONDecoder().decode(SSHAuthMethod.self, from: Data(host.authJSON.utf8))
            var endpoints = (try? JSONDecoder().decode(
                [VNCEndpoint].self,
                from: Data((host.vncEndpointsJSON ?? "[]").utf8)
            )) ?? []
            if endpoints.isEmpty, let legacyJSON = host.vncEndpointJSON,
               let legacy = try? JSONDecoder().decode(VNCEndpoint.self, from: Data(legacyJSON.utf8)) {
                endpoints = [legacy]
            }
            let vncConnections: [[String: Any]] = endpoints.map { endpoint in
                ["id": endpoint.id.uuidString,
                 "displayName": endpoint.displayName,
                 "transport": endpoint.transport.rawValue,
                 "host": endpoint.host,
                 "port": endpoint.port,
                 "passwordConfigured": endpoint.passwordRef != nil]
            }
            let auxiliary = (try? JSONSerialization.jsonObject(
                with: Data((host.auxiliaryConnectionsJSON ?? "[]").utf8)
            )) as? [Any] ?? []
            let pinned = host.hostKeyPolicy.hasPrefix("pinned:")
            return ["id": host.id.uuidString, "name": host.displayName, "address": host.address,
                    "port": host.port, "user": host.user, "default": host.id == defaultID,
                    "sshEnabled": auth.map { $0 != .none } ?? false,
                    "authMethod": Self.authMethodName(auth),
                    "hostKeyPolicy": pinned ? "pinned" : "trustOnFirstUse",
                    "pinnedFingerprint": pinned
                        ? String(host.hostKeyPolicy.dropFirst("pinned:".count)) : NSNull(),
                    "deviceKind": host.deviceKind ?? "unspecified",
                    "remoteExecutionEnvironment": host.isRemoteExecutionEnvironment ?? true,
                    "vncConnections": vncConnections,
                    "otherConnections": auxiliary]
        }
        FloeLogger(category: .ssh).info(
            "sshHostListFinished trace=\(traceID) count=\(hosts.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        let data = try JSONSerialization.data(withJSONObject: ["hosts": hosts], options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: digest(data), exitStatus: 0)
    }

    private static func authMethodName(_ auth: SSHAuthMethod?) -> String {
        guard let auth else { return "invalid" }
        switch auth {
        case .none: return "none"
        case .password: return "password"
        case .importedKey: return "privateKey"
        case .deviceGeneratedKey: return "deviceKey"
        }
    }
}

public struct SSHUpdateHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public struct VNCConnection: Decodable, Sendable {
            public var id: String?
            public var displayName: String
            public var transport: VNCTransport
            public var host: String
            public var port: Int
            /// A credential-vault placeholder resolved directly into Keychain,
            /// a raw setup value accepted only at the executor boundary, or an
            /// existing Floe credential reference.
            public var credentialInput: String?
            public var clearPassword: Bool?
            /// Exact JSON key that supplied `credentialInput`:
            /// `credentialInput` for the current field or `password` for the
            /// legacy alias. The tool uses it only to reconstruct the exact
            /// argument path the normalizer recorded. Never model authority.
            public var credentialFieldKey: String

            private enum CodingKeys: String, CodingKey {
                case id, displayName, transport, host, port
                case credentialInput, password, clearPassword
            }

            public init(
                id: String? = nil,
                displayName: String,
                transport: VNCTransport,
                host: String,
                port: Int,
                credentialInput: String? = nil,
                clearPassword: Bool? = nil,
                credentialFieldKey: String = "credentialInput"
            ) {
                self.id = id
                self.displayName = displayName
                self.transport = transport
                self.host = host
                self.port = port
                self.credentialInput = credentialInput
                self.clearPassword = clearPassword
                self.credentialFieldKey = credentialFieldKey
            }

            public init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decodeIfPresent(String.self, forKey: .id)
                displayName = try values.decode(String.self, forKey: .displayName)
                transport = try values.decode(VNCTransport.self, forKey: .transport)
                host = try values.decode(String.self, forKey: .host)
                port = try values.decode(Int.self, forKey: .port)
                let current = try values.decodeIfPresent(String.self, forKey: .credentialInput)
                let legacy = try values.decodeIfPresent(String.self, forKey: .password)
                if let current, let legacy, current != legacy {
                    throw DecodingError.dataCorruptedError(
                        forKey: .credentialInput,
                        in: values,
                        debugDescription: "credentialInput and legacy password disagree"
                    )
                }
                credentialInput = current ?? legacy
                credentialFieldKey = current == nil && legacy != nil
                    ? "password" : "credentialInput"
                clearPassword = try values.decodeIfPresent(Bool.self, forKey: .clearPassword)
            }
        }

        public struct AuxiliaryConnection: Decodable, Sendable {
            public var id: String?
            public var displayName: String
            public var kind: RemoteAuxiliaryConnectionKind
            public var host: String?
            public var port: Int?
            public var bluetoothPeripheralID: String?
            public var bluetoothServiceUUID: String?
            public var bluetoothWriteCharacteristicUUID: String?
            public var bluetoothNotifyCharacteristicUUID: String?

            public init(
                id: String? = nil,
                displayName: String,
                kind: RemoteAuxiliaryConnectionKind,
                host: String? = nil,
                port: Int? = nil,
                bluetoothPeripheralID: String? = nil,
                bluetoothServiceUUID: String? = nil,
                bluetoothWriteCharacteristicUUID: String? = nil,
                bluetoothNotifyCharacteristicUUID: String? = nil
            ) {
                self.id = id
                self.displayName = displayName
                self.kind = kind
                self.host = host
                self.port = port
                self.bluetoothPeripheralID = bluetoothPeripheralID
                self.bluetoothServiceUUID = bluetoothServiceUUID
                self.bluetoothWriteCharacteristicUUID = bluetoothWriteCharacteristicUUID
                self.bluetoothNotifyCharacteristicUUID = bluetoothNotifyCharacteristicUUID
            }
        }

        public var hostID: String
        public var displayName: String?
        public var address: String?
        public var port: Int?
        public var user: String?
        public var isSSHEnabled: Bool?
        public var deviceKind: RemoteDeviceKind?
        public var isRemoteExecutionEnvironment: Bool?
        public var hostKeyPolicy: SSHHostKeyPolicySelection?
        public var pinnedFingerprint: String?
        /// Full replacement of the VNC connection group. Omitted entries are
        /// removed (and their saved credentials deleted) for compatibility.
        public var vncConnections: [VNCConnection]?
        /// Non-destructive merge operations. They preserve every endpoint not
        /// named here. Do not combine with `vncConnections` in one call.
        public var addVNCConnections: [VNCConnection]?
        public var updateVNCConnections: [VNCConnection]?
        public var removeVNCConnectionIDs: [String]?
        /// Full replacement of the auxiliary connection group.
        public var auxiliaryConnections: [AuxiliaryConnection]?
        public var addAuxiliaryConnections: [AuxiliaryConnection]?
        public var updateAuxiliaryConnections: [AuxiliaryConnection]?
        public var removeAuxiliaryConnectionIDs: [String]?
    }
    public static let name = "ssh.updateHost"
    public static let toolDescription = "Edit a saved device. Use ssh.listHosts first. Omitted fields are preserved; authentication is changed only with ssh.setHostAuth. For connections, either supply the full `vncConnections`/`auxiliaryConnections` array (replacement, omitted entries are removed) or use add/update/remove operations, which preserve every connection they do not name. Never mix replacement and operations for one connection group. A new VNC credentialInput may be the plaintext supplied or generated for the current task, or an existing ordinary Floe credential-card reference. Floe stores the value in Keychain and never returns it. Leave credentialInput and clearPassword omitted to preserve an existing credential. hostKeyPolicy pinned requires pinnedFingerprint."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "hostID": {"type": "string"},
        "displayName": {"type": "string"},
        "address": {"type": "string"},
        "port": {"type": "integer", "minimum": 1, "maximum": 65535},
        "user": {"type": "string"},
        "isSSHEnabled": {"type": "boolean"},
        "deviceKind": {"type": "string", "enum": ["unspecified", "linux", "mac", "windows", "nas", "router", "switchDevice", "appliance", "other"]},
        "isRemoteExecutionEnvironment": {"type": "boolean"},
        "hostKeyPolicy": {"type": "string", "enum": ["trustOnFirstUse", "pinned"]},
        "pinnedFingerprint": {"type": "string"},
        "vncConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "transport": {"type": "string", "enum": ["direct", "sshTunnel"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "credentialInput": {"type": "string", "description": "Plaintext for this setup or an existing ordinary Floe credential-card reference"}, "password": {"type": "string", "description": "Deprecated alias for credentialInput"}, "clearPassword": {"type": "boolean"}}, "required": ["displayName", "transport", "host", "port"], "additionalProperties": false}},
        "addVNCConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "transport": {"type": "string", "enum": ["direct", "sshTunnel"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "credentialInput": {"type": "string"}, "password": {"type": "string"}, "clearPassword": {"type": "boolean"}}, "required": ["displayName", "transport", "host", "port"], "additionalProperties": false}},
        "updateVNCConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "transport": {"type": "string", "enum": ["direct", "sshTunnel"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "credentialInput": {"type": "string"}, "password": {"type": "string"}, "clearPassword": {"type": "boolean"}}, "required": ["id", "displayName", "transport", "host", "port"], "additionalProperties": false}},
        "removeVNCConnectionIDs": {"type": "array", "items": {"type": "string"}},
        "auxiliaryConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "kind": {"type": "string", "enum": ["telnet", "tcp", "bluetoothSerial"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "bluetoothPeripheralID": {"type": "string"}, "bluetoothServiceUUID": {"type": "string"}, "bluetoothWriteCharacteristicUUID": {"type": "string"}, "bluetoothNotifyCharacteristicUUID": {"type": "string"}}, "required": ["displayName", "kind"], "additionalProperties": false}},
        "addAuxiliaryConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "kind": {"type": "string", "enum": ["telnet", "tcp", "bluetoothSerial"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "bluetoothPeripheralID": {"type": "string"}, "bluetoothServiceUUID": {"type": "string"}, "bluetoothWriteCharacteristicUUID": {"type": "string"}, "bluetoothNotifyCharacteristicUUID": {"type": "string"}}, "required": ["displayName", "kind"], "additionalProperties": false}},
        "updateAuxiliaryConnections": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "displayName": {"type": "string"}, "kind": {"type": "string", "enum": ["telnet", "tcp", "bluetoothSerial"]}, "host": {"type": "string"}, "port": {"type": "integer", "minimum": 1, "maximum": 65535}, "bluetoothPeripheralID": {"type": "string"}, "bluetoothServiceUUID": {"type": "string"}, "bluetoothWriteCharacteristicUUID": {"type": "string"}, "bluetoothNotifyCharacteristicUUID": {"type": "string"}}, "required": ["id", "displayName", "kind"], "additionalProperties": false}},
        "removeAuxiliaryConnectionIDs": {"type": "array", "items": {"type": "string"}}
      },
      "required": ["hostID"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [
        .persistsPersonalData, .networkAccess, .accessesCredentials
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    private let store: RemoteHostStore
    private let passwordWriter: VNCPasswordWriter?
    private let secretDeleter: SecretReferenceDeleter?
    private let aliasDeleter: SSHAuthLegacyAliasDeleter?
    private let credentialInputResolver: CredentialInputResolver?
    private let saveHostOverride: RemoteHostSaveAction?
    private let updateObserver: RemoteHostUpdateObserver?

    public init(
        store: RemoteHostStore,
        passwordWriter: VNCPasswordWriter? = nil,
        passwordDeleter: VNCPasswordDeleter? = nil,
        secretDeleter: SecretReferenceDeleter? = nil,
        aliasDeleter: SSHAuthLegacyAliasDeleter? = nil,
        credentialInputResolver: CredentialInputResolver? = nil,
        updateObserver: RemoteHostUpdateObserver? = nil,
        saveHostOverride: RemoteHostSaveAction? = nil
    ) {
        self.store = store
        self.passwordWriter = passwordWriter
        _ = passwordDeleter // legacy connection-keyed seam; not used
        self.secretDeleter = secretDeleter
        self.aliasDeleter = aliasDeleter
        self.credentialInputResolver = credentialInputResolver
        self.updateObserver = updateObserver
        self.saveHostOverride = saveHostOverride
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.hostID) != nil else { throw FloeError.validationFailed("hostID must be a UUID") }
        if let port = args.port, !(1...65535).contains(port) { throw FloeError.validationFailed("port must be 1-65535") }
        if let address = args.address, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("address must not be empty")
        }
        if let user = args.user, user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("user must not be empty")
        }
        if args.isSSHEnabled == false, args.isRemoteExecutionEnvironment == true {
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
            throw FloeError.validationFailed("pinnedFingerprint requires hostKeyPolicy pinned")
        }

        let vncReplacement = args.vncConnections != nil
        let vncOperations = args.addVNCConnections != nil
            || args.updateVNCConnections != nil
            || args.removeVNCConnectionIDs != nil
        if vncReplacement, vncOperations {
            throw FloeError.validationFailed(
                "Use either the vncConnections replacement array or the add/update/remove VNC operations, not both"
            )
        }
        let auxiliaryReplacement = args.auxiliaryConnections != nil
        let auxiliaryOperations = args.addAuxiliaryConnections != nil
            || args.updateAuxiliaryConnections != nil
            || args.removeAuxiliaryConnectionIDs != nil
        if auxiliaryReplacement, auxiliaryOperations {
            throw FloeError.validationFailed(
                "Use either the auxiliaryConnections replacement array or the add/update/remove auxiliary operations, not both"
            )
        }

        let vncValues = (args.vncConnections ?? [])
            + (args.addVNCConnections ?? [])
            + (args.updateVNCConnections ?? [])
        for endpoint in vncValues {
            if endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1...65535).contains(endpoint.port) {
                throw FloeError.validationFailed("VNC host and port must be valid")
            }
            if let id = endpoint.id, UUID(uuidString: id) == nil {
                throw FloeError.validationFailed("VNC connection id must be a UUID")
            }
            if endpoint.clearPassword == true, endpoint.credentialInput?.isEmpty == false {
                throw FloeError.validationFailed("A VNC connection cannot set and clear its password together")
            }
            if let credentialInput = endpoint.credentialInput, !credentialInput.isEmpty {
                guard passwordWriter != nil else {
                    throw FloeError.invalidConfiguration("Secure VNC credential storage is unavailable")
                }
            }
        }
        for endpoint in args.updateVNCConnections ?? [] {
            guard endpoint.id != nil else {
                throw FloeError.validationFailed("Every updated VNC connection requires its id")
            }
        }
        for raw in args.removeVNCConnectionIDs ?? [] {
            guard UUID(uuidString: raw) != nil else {
                throw FloeError.validationFailed("removeVNCConnectionIDs entries must be UUIDs")
            }
        }

        let auxiliaryValues = (args.auxiliaryConnections ?? [])
            + (args.addAuxiliaryConnections ?? [])
            + (args.updateAuxiliaryConnections ?? [])
        try SSHHostConfigurationSupport.validateAuxiliaryConnections(auxiliaryValues)
        for connection in args.updateAuxiliaryConnections ?? [] {
            guard connection.id != nil else {
                throw FloeError.validationFailed("Every updated auxiliary connection requires its id")
            }
        }
        for raw in args.removeAuxiliaryConnectionIDs ?? [] {
            guard UUID(uuidString: raw) != nil else {
                throw FloeError.validationFailed("removeAuxiliaryConnectionIDs entries must be UUIDs")
            }
        }
        let touchesVNCCredentials = args.vncConnections != nil
            || args.addVNCConnections != nil
            || args.updateVNCConnections != nil
            || args.removeVNCConnectionIDs != nil
        if (touchesVNCCredentials || args.isSSHEnabled == false), secretDeleter == nil {
            throw FloeError.invalidConfiguration(
                "Secure credential cleanup is unavailable; connection and SSH changes are disabled"
            )
        }
        if args.isSSHEnabled == false, aliasDeleter == nil {
            throw FloeError.invalidConfiguration(
                "Secure credential cleanup is unavailable; disabling SSH is disabled"
            )
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let traceID = UUID().uuidString
        let startedAt = Date()
        let id = UUID(uuidString: args.hostID)!
        let toolName = context.executionToolName ?? Self.name
        let changedFields = [args.displayName == nil ? nil : "displayName", args.address == nil ? nil : "address",
                             args.port == nil ? nil : "port", args.user == nil ? nil : "user",
                             args.isSSHEnabled == nil ? nil : "sshEnabled",
                             args.deviceKind == nil ? nil : "deviceKind",
                             args.isRemoteExecutionEnvironment == nil ? nil : "remoteExecutionEnvironment",
                             args.hostKeyPolicy == nil ? nil : "hostKeyPolicy",
                             args.vncConnections == nil ? nil : "vncConnections",
                             args.addVNCConnections == nil ? nil : "addVNCConnections",
                             args.updateVNCConnections == nil ? nil : "updateVNCConnections",
                             args.removeVNCConnectionIDs == nil ? nil : "removeVNCConnectionIDs",
                             args.auxiliaryConnections == nil ? nil : "auxiliaryConnections",
                             args.addAuxiliaryConnections == nil ? nil : "addAuxiliaryConnections",
                             args.updateAuxiliaryConnections == nil ? nil : "updateAuxiliaryConnections",
                             args.removeAuxiliaryConnectionIDs == nil ? nil : "removeAuxiliaryConnectionIDs"].compactMap { $0 }
        FloeLogger(category: .ssh).info(
            "sshHostUpdateStarted trace=\(traceID) host=\(id.uuidString) fields=\(changedFields.joined(separator: ","))"
        )
        guard var host = try await store.host(id: id) else {
            FloeLogger(category: .ssh).warning(
                "sshHostUpdateFailed trace=\(traceID) host=\(id.uuidString) reason=notFound"
            )
            throw FloeError.validationFailed("paired host not found")
        }
        let previousAuth = try JSONDecoder().decode(
            SSHAuthMethod.self, from: Data(host.authJSON.utf8)
        )
        if let value = args.displayName { host.displayName = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args.address { host.address = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args.port { host.port = value }
        if let value = args.user { host.user = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var removedSSHCredential = false
        if args.isSSHEnabled == false {
            host.authJSON = String(decoding: try JSONEncoder().encode(SSHAuthMethod.none), as: UTF8.self)
            host.isRemoteExecutionEnvironment = false
            removedSSHCredential = previousAuth != .none
        } else if args.isSSHEnabled == true {
            guard previousAuth != .none else {
                throw FloeError.validationFailed(
                    "Bind SSH authentication with ssh.setHostAuth before enabling SSH"
                )
            }
        }
        if let value = args.deviceKind { host.deviceKind = value.rawValue }
        if let value = args.isRemoteExecutionEnvironment { host.isRemoteExecutionEnvironment = value }
        if let policy = args.hostKeyPolicy {
            host.hostKeyPolicy = try SSHHostConfigurationSupport.policyString(
                policy,
                fingerprint: args.pinnedFingerprint
            )
        } else if let fingerprint = args.pinnedFingerprint {
            host.hostKeyPolicy = try SSHHostConfigurationSupport.policyString(
                .pinned,
                fingerprint: fingerprint
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var removedCredentialIDs: Set<UUID> = []
        var updatedCredentialCount = 0
        var changedEndpointIDs: Set<UUID> = []
        var vncChanged = false
        var stagedReferences: [SecretReference] = []
        var pendingCaptures: [CredentialInputResolution] = []
        var oldReferencesToDelete: [SecretReference] = []
        var auxiliaryChanged = false
        var configuredAuxiliaryCount = 0

        var previous = ((try? JSONDecoder().decode(
            [VNCEndpoint].self,
            from: Data((host.vncEndpointsJSON ?? "[]").utf8)
        )) ?? [])
        if previous.isEmpty,
           let legacyJSON = host.vncEndpointJSON,
           let legacy = try? JSONDecoder().decode(VNCEndpoint.self, from: Data(legacyJSON.utf8)) {
            previous = [legacy]
        }

        do {
            if let values = args.vncConnections {
                // Resolve every reference before the first Keychain write so a
                // malformed, foreign, missing or locked reference cannot cause
                // a partial credential mutation.
                let resolutions = try await SSHHostConfigurationSupport.resolveVNCInputs(
                    values,
                    hostID: id,
                    arrayKey: "vncConnections",
                    runID: context.runID,
                    toolName: toolName,
                    resolver: credentialInputResolver
                )
                let retainedIDs = Set(values.compactMap { $0.id.flatMap(UUID.init(uuidString:)) })
                let dropped = previous.filter {
                    !retainedIDs.contains($0.id) && $0.passwordRef != nil
                }
                removedCredentialIDs.formUnion(dropped.map(\.id))
                oldReferencesToDelete.append(contentsOf: dropped.compactMap(\.passwordRef))
                var endpoints: [VNCEndpoint] = []
                for (index, value) in values.enumerated() {
                    let prior = value.id.flatMap(UUID.init(uuidString:)).flatMap { identifier in
                        previous.first(where: { $0.id == identifier })
                    }
                    let result = try await SSHHostConfigurationSupport.endpoint(
                        from: value,
                        hostID: id,
                        previous: prior,
                        writer: passwordWriter,
                        resolution: resolutions[index]
                    )
                    if let resolution = resolutions[index] {
                        pendingCaptures.append(resolution)
                    }
                    try SSHHostConfigurationSupport.ensureFreshRevision(
                        previous: prior?.passwordRef,
                        new: result.newReference
                    )
                    if let reference = result.newReference {
                        stagedReferences.append(reference)
                        updatedCredentialCount += 1
                        if let old = prior?.passwordRef { oldReferencesToDelete.append(old) }
                    }
                    if value.clearPassword == true, let previousReference = prior?.passwordRef {
                        removedCredentialIDs.insert(result.endpoint.id)
                        oldReferencesToDelete.append(previousReference)
                    }
                    endpoints.append(result.endpoint)
                }
                host.vncEndpointsJSON = String(decoding: try encoder.encode(endpoints), as: UTF8.self)
                host.vncEndpointJSON = try endpoints.first.map {
                    String(decoding: try encoder.encode($0), as: UTF8.self)
                }
                changedEndpointIDs = Set(endpoints.map(\.id)).union(removedCredentialIDs)
                vncChanged = true
            } else if args.addVNCConnections != nil
                        || args.updateVNCConnections != nil
                        || args.removeVNCConnectionIDs != nil {
                let updates = args.updateVNCConnections ?? []
                let adds = args.addVNCConnections ?? []
                let deleteIDs = Set((args.removeVNCConnectionIDs ?? []).compactMap(UUID.init(uuidString:)))
                let updateIDs = updates.compactMap { $0.id.flatMap(UUID.init(uuidString:)) }
                let addIDs = adds.compactMap { $0.id.flatMap(UUID.init(uuidString:)) }
                guard updateIDs.count == updates.count, addIDs.count == adds.count else {
                    throw FloeError.validationFailed("VNC operation ids must be UUIDs")
                }
                guard Set(updateIDs).count == updateIDs.count,
                      Set(addIDs).count == addIDs.count else {
                    throw FloeError.validationFailed("Duplicate VNC connection id in one operation list")
                }
                let existingIDs = Set(previous.map(\.id))
                for updateID in updateIDs where !existingIDs.contains(updateID) {
                    throw FloeError.validationFailed(
                        "VNC connection \(updateID.uuidString) is not configured on this host"
                    )
                }
                for deleteID in deleteIDs where !existingIDs.contains(deleteID) {
                    throw FloeError.validationFailed(
                        "VNC connection \(deleteID.uuidString) is not configured on this host"
                    )
                }
                for addID in addIDs where existingIDs.contains(addID) {
                    throw FloeError.validationFailed(
                        "VNC connection \(addID.uuidString) already exists; update it instead"
                    )
                }
                guard deleteIDs.isDisjoint(with: updateIDs),
                      Set(addIDs).isDisjoint(with: updateIDs),
                      Set(addIDs).isDisjoint(with: deleteIDs) else {
                    throw FloeError.validationFailed(
                        "A VNC connection cannot be added, updated and removed in one call"
                    )
                }

                // Resolve every reference before the first Keychain write so a
                // malformed, foreign, missing or locked reference cannot cause
                // a partial credential mutation.
                let updateResolutions = try await SSHHostConfigurationSupport.resolveVNCInputs(
                    updates,
                    hostID: id,
                    arrayKey: "updateVNCConnections",
                    runID: context.runID,
                    toolName: toolName,
                    resolver: credentialInputResolver
                )
                let addResolutions = try await SSHHostConfigurationSupport.resolveVNCInputs(
                    adds,
                    hostID: id,
                    arrayKey: "addVNCConnections",
                    runID: context.runID,
                    toolName: toolName,
                    resolver: credentialInputResolver
                )

                for deleteID in deleteIDs {
                    if let index = previous.firstIndex(where: { $0.id == deleteID }) {
                        if let reference = previous[index].passwordRef {
                            removedCredentialIDs.insert(deleteID)
                            oldReferencesToDelete.append(reference)
                        }
                        previous.remove(at: index)
                    }
                }
                for (index, value) in updates.enumerated() {
                    let connectionID = UUID(uuidString: value.id!)!
                    guard let previousIndex = previous.firstIndex(where: { $0.id == connectionID }) else {
                        throw FloeError.validationFailed("VNC connection \(connectionID.uuidString) is not configured on this host")
                    }
                    let prior = previous[previousIndex]
                    let result = try await SSHHostConfigurationSupport.endpoint(
                        from: value,
                        hostID: id,
                        previous: prior,
                        writer: passwordWriter,
                        resolution: updateResolutions[index]
                    )
                    if let resolution = updateResolutions[index] {
                        pendingCaptures.append(resolution)
                    }
                    try SSHHostConfigurationSupport.ensureFreshRevision(
                        previous: prior.passwordRef,
                        new: result.newReference
                    )
                    if let reference = result.newReference {
                        stagedReferences.append(reference)
                        updatedCredentialCount += 1
                        if let old = prior.passwordRef { oldReferencesToDelete.append(old) }
                    }
                    if value.clearPassword == true, let previousReference = prior.passwordRef {
                        removedCredentialIDs.insert(connectionID)
                        oldReferencesToDelete.append(previousReference)
                    }
                    previous[previousIndex] = result.endpoint
                    changedEndpointIDs.insert(connectionID)
                }
                for (index, value) in adds.enumerated() {
                    let result = try await SSHHostConfigurationSupport.endpoint(
                        from: value,
                        hostID: id,
                        previous: nil,
                        writer: passwordWriter,
                        resolution: addResolutions[index]
                    )
                    if let resolution = addResolutions[index] {
                        pendingCaptures.append(resolution)
                    }
                    if let reference = result.newReference {
                        stagedReferences.append(reference)
                        updatedCredentialCount += 1
                    }
                    previous.append(result.endpoint)
                    changedEndpointIDs.insert(result.endpoint.id)
                }
                changedEndpointIDs.formUnion(deleteIDs)
                host.vncEndpointsJSON = String(decoding: try encoder.encode(previous), as: UTF8.self)
                host.vncEndpointJSON = try previous.first.map {
                    String(decoding: try encoder.encode($0), as: UTF8.self)
                }
                vncChanged = true
            }

            var previousAuxiliary = (try? JSONDecoder().decode(
                [RemoteAuxiliaryConnection].self,
                from: Data((host.auxiliaryConnectionsJSON ?? "[]").utf8)
            )) ?? []
            if let values = args.auxiliaryConnections {
                let connections = values.map { value in
                    SSHHostConfigurationSupport.auxiliary(from: value)
                }
                host.auxiliaryConnectionsJSON = String(decoding: try encoder.encode(connections), as: UTF8.self)
                configuredAuxiliaryCount = connections.count
                auxiliaryChanged = true
            } else if args.addAuxiliaryConnections != nil
                        || args.updateAuxiliaryConnections != nil
                        || args.removeAuxiliaryConnectionIDs != nil {
                let updates = args.updateAuxiliaryConnections ?? []
                let adds = args.addAuxiliaryConnections ?? []
                let deleteIDs = Set((args.removeAuxiliaryConnectionIDs ?? []).compactMap(UUID.init(uuidString:)))
                let updateIDs = updates.compactMap { $0.id.flatMap(UUID.init(uuidString:)) }
                let addIDs = adds.compactMap { $0.id.flatMap(UUID.init(uuidString:)) }
                guard updateIDs.count == updates.count, addIDs.count == adds.count,
                      Set(updateIDs).count == updateIDs.count,
                      Set(addIDs).count == addIDs.count else {
                    throw FloeError.validationFailed("Auxiliary operation ids must be unique UUIDs")
                }
                let existingIDs = Set(previousAuxiliary.map(\.id))
                for updateID in updateIDs where !existingIDs.contains(updateID) {
                    throw FloeError.validationFailed("Auxiliary connection \(updateID.uuidString) is not configured on this host")
                }
                for deleteID in deleteIDs where !existingIDs.contains(deleteID) {
                    throw FloeError.validationFailed("Auxiliary connection \(deleteID.uuidString) is not configured on this host")
                }
                for addID in addIDs where existingIDs.contains(addID) {
                    throw FloeError.validationFailed("Auxiliary connection \(addID.uuidString) already exists; update it instead")
                }
                guard deleteIDs.isDisjoint(with: updateIDs),
                      Set(addIDs).isDisjoint(with: updateIDs),
                      Set(addIDs).isDisjoint(with: deleteIDs) else {
                    throw FloeError.validationFailed("An auxiliary connection cannot be added, updated and removed in one call")
                }
                previousAuxiliary.removeAll { deleteIDs.contains($0.id) }
                for value in updates {
                    let connectionID = UUID(uuidString: value.id!)!
                    guard let index = previousAuxiliary.firstIndex(where: { $0.id == connectionID }) else {
                        throw FloeError.validationFailed("Auxiliary connection \(connectionID.uuidString) is not configured on this host")
                    }
                    previousAuxiliary[index] = SSHHostConfigurationSupport.auxiliary(
                        from: value,
                        previousID: connectionID
                    )
                }
                for value in adds {
                    previousAuxiliary.append(SSHHostConfigurationSupport.auxiliary(from: value))
                }
                host.auxiliaryConnectionsJSON = String(decoding: try encoder.encode(previousAuxiliary), as: UTF8.self)
                configuredAuxiliaryCount = previousAuxiliary.count
                auxiliaryChanged = true
            }

            if removedSSHCredential,
               let previousReference = SSHHostConfigurationSupport.reference(of: previousAuth) {
                oldReferencesToDelete.append(previousReference)
            }
            try RemoteHostProfile(stored: host).validate()
            if let saveHostOverride {
                try await saveHostOverride(host)
            } else {
                try await store.saveHost(host)
            }
        } catch {
            await rollBack(stagedReferences)
            let nsError = error as NSError
            FloeLogger(category: .ssh).warning(
                "sshHostUpdateFailed trace=\(traceID) host=\(id.uuidString) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }

        // The host row is committed. Only now consume the one-time captures
        // that supplied these exact fields; a failed save above left every
        // capture untouched and retryable.
        for resolution in pendingCaptures {
            await resolution.consumeAfterCommit()
        }

        let otherHostAccounts = await SSHHostCredentialReferences.otherHostAccounts(
            store: store,
            excluding: id
        )
        // The replacement-array path leaves `previous` as the original
        // endpoints. Cleanup must use the validated final profile for both
        // update styles, or replaced/omitted secrets look falsely retained.
        let committedProfile = try RemoteHostProfile(stored: host)
        let committedAccounts = Set(SSHHostCredentialReferences.owned(by: committedProfile).map(\.keychainAccount))
        var removedVNCCredentialCount = 0
        var scheduledVNCCredentialCount = 0
        var sshSecretRemoved = false
        let previousAuthReference = SSHHostConfigurationSupport.reference(of: previousAuth)
        var seenRemovedAccounts: Set<String> = []
        if let secretDeleter {
            for reference in oldReferencesToDelete {
                guard seenRemovedAccounts.insert(reference.keychainAccount).inserted,
                      !committedAccounts.contains(reference.keychainAccount),
                      (otherHostAccounts?.contains(reference.keychainAccount) == false) else { continue }
                if reference.keychainAccount.hasPrefix("host.vnc.") {
                    scheduledVNCCredentialCount += 1
                }
                do {
                    try await secretDeleter(reference)
                    if reference.keychainAccount.hasPrefix("host.vnc.") {
                        removedVNCCredentialCount += 1
                    }
                    if reference.keychainAccount == previousAuthReference?.keychainAccount {
                        sshSecretRemoved = true
                    }
                } catch {
                    FloeLogger(category: .security).warning(
                        "sshHostCredentialRemovalFailed host=\(id.uuidString)"
                    )
                }
            }
        }
        if removedSSHCredential {
            await aliasDeleter?(id)
        }
        if let updateObserver {
            await updateObserver(id, changedEndpointIDs)
        }
        FloeLogger(category: .ssh).info(
            "sshHostUpdateFinished trace=\(traceID) host=\(id.uuidString) fields=\(changedFields.joined(separator: ",")) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        var response: [String: Any] = ["updated": true, "hostID": id.uuidString]
        if vncChanged {
            let saved = ((try? JSONDecoder().decode(
                [VNCEndpoint].self,
                from: Data((host.vncEndpointsJSON ?? "[]").utf8)
            )) ?? [])
            response["vncConnections"] = SSHHostConfigurationSupport.vncMetadata(saved)
            // Keep a compact prerequisite signal near the start of the sorted
            // result. The Harness ledger intentionally stores only a bounded
            // excerpt, while a host may contain many named VNC endpoints.
            response["configuredVNCCount"] = saved.count
            response["credentialsUpdated"] = updatedCredentialCount
            response["credentialsRemoved"] = removedVNCCredentialCount
            response["credentialsScheduledForRemoval"] = scheduledVNCCredentialCount
        }
        if auxiliaryChanged {
            response["configuredAuxiliaryCount"] = configuredAuxiliaryCount
        }
        if removedSSHCredential {
            response["sshCredentialRemoved"] = sshSecretRemoved
        }
        if args.hostKeyPolicy != nil || args.pinnedFingerprint != nil {
            let pinned = host.hostKeyPolicy.hasPrefix("pinned:")
            response["hostKeyPolicy"] = pinned ? "pinned" : "trustOnFirstUse"
            if pinned {
                response["pinnedFingerprint"] = String(host.hostKeyPolicy.dropFirst("pinned:".count))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: digest(data), exitStatus: 0)
    }

    private func rollBack(_ references: [SecretReference]) async {
        guard let secretDeleter else { return }
        var seen: Set<String> = []
        for reference in references where seen.insert(reference.keychainAccount).inserted {
            try? await secretDeleter(reference)
        }
    }
}

private func digest(_ data: Data) -> String {
    FloeDigest.sha256Hex(data)
}
