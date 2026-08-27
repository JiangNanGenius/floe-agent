// FloeSSH — Remote host profiles and run lifecycle (iOS-only target).
// See blazing-aurora-darwin.md §5.10. Citadel/SwiftNIO integration lands
// in M3; M1 ships the value types and lifecycle semantics:
//   heartbeatTimeout = 45s; a disconnect without helper ⇒ .unknown,
//   NEVER .paused.

import Foundation
import FloeCore
import FloePersistence

/// Configuration for one remote device. SSH is optional; VNC, Telnet, raw
/// TCP and BLE serial connections may exist independently.
public struct RemoteHostProfile: Sendable, Codable, Identifiable, Hashable {
    /// Maximum jump chain depth enforced at validation.
    public static let maxJumpHops = 5

    public var id: UUID
    public var displayName: String
    public var address: String
    public var port: Int
    public var user: String
    public var auth: SSHAuthMethod
    public var jumpChain: [JumpHop]
    public var hostKeyPolicy: HostKeyPolicy
    public var allowsLegacyAlgorithms: Bool
    public var deviceKind: RemoteDeviceKind
    public var isRemoteExecutionEnvironment: Bool
    public var vncEndpoints: [VNCEndpoint]
    public var auxiliaryConnections: [RemoteAuxiliaryConnection]

    /// Compatibility projection for older call sites and synced profiles.
    public var vncEndpoint: VNCEndpoint? { vncEndpoints.first }
    public var hasSSHConnection: Bool { auth != .none }

    public init(
        id: UUID = UUID(),
        displayName: String,
        address: String,
        port: Int = 22,
        user: String,
        auth: SSHAuthMethod,
        jumpChain: [JumpHop] = [],
        hostKeyPolicy: HostKeyPolicy = .trustOnFirstUse,
        allowsLegacyAlgorithms: Bool = false,
        deviceKind: RemoteDeviceKind = .unspecified,
        isRemoteExecutionEnvironment: Bool = true,
        vncEndpoint: VNCEndpoint? = nil,
        vncEndpoints: [VNCEndpoint]? = nil,
        auxiliaryConnections: [RemoteAuxiliaryConnection] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.user = user
        self.auth = auth
        self.jumpChain = jumpChain
        self.hostKeyPolicy = hostKeyPolicy
        self.allowsLegacyAlgorithms = allowsLegacyAlgorithms
        self.deviceKind = deviceKind
        self.isRemoteExecutionEnvironment = isRemoteExecutionEnvironment
        self.vncEndpoints = vncEndpoints ?? vncEndpoint.map { [$0] } ?? []
        self.auxiliaryConnections = auxiliaryConnections
    }

    public func validate() throws {
        if auth != .none {
            guard !address.isEmpty else {
                throw FloeError.validationFailed("SSH address required")
            }
            guard (1...65535).contains(port) else {
                throw FloeError.validationFailed("SSH port must be 1-65535")
            }
            guard !user.isEmpty else {
                throw FloeError.validationFailed("SSH user required")
            }
        } else if isRemoteExecutionEnvironment {
            throw FloeError.validationFailed("A remote execution environment requires SSH")
        }
        guard jumpChain.count <= Self.maxJumpHops else {
            throw FloeError.validationFailed("Jump chain exceeds \(Self.maxJumpHops) hops")
        }
        for endpoint in vncEndpoints {
            try endpoint.validate()
        }
        for connection in auxiliaryConnections {
            try connection.validate()
        }
    }
}

/// Optional product-facing device classification. It is descriptive only;
/// configured protocols and live probing remain the capability authority.
public enum RemoteDeviceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case unspecified
    case linux
    case mac
    case windows
    case nas
    case router
    case switchDevice
    case appliance
    case other
}

/// SSH authentication. Secrets live in the Keychain; only references here.
public enum SSHAuthMethod: Sendable, Codable, Hashable {
    /// Device metadata exists without an SSH connection. This is valid for
    /// VNC-only, Telnet/TCP-only and BLE serial devices.
    case none
    case password(SecretReference)
    case importedKey(SecretReference, keyType: SSHKeyType)
    case deviceGeneratedKey(SecretReference, keyType: SSHKeyType)

    public enum SSHKeyType: String, Sendable, Codable, Hashable {
        case ed25519
        case ecdsaP256
        case rsa4096
    }
}

/// Host key verification policy.
public enum HostKeyPolicy: Sendable, Codable, Hashable {
    /// Accept on first connect, pin thereafter (TOFU).
    case trustOnFirstUse
    /// Require an exact SHA256 fingerprint match.
    case pinned(fingerprintSHA256: String)
}

/// One hop in a ProxyJump chain.
public struct JumpHop: Sendable, Codable, Hashable {
    public var address: String
    public var port: Int
    public var user: String
    public var auth: SSHAuthMethod

    public init(address: String, port: Int = 22, user: String, auth: SSHAuthMethod) {
        self.address = address
        self.port = port
        self.user = user
        self.auth = auth
    }
}

public enum VNCTransport: String, Sendable, Codable, CaseIterable, Hashable {
    case direct
    case sshTunnel
}

/// One named VNC connection. A device may expose direct and SSH-tunnel
/// endpoints at the same time.
public struct VNCEndpoint: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var transport: VNCTransport
    public var host: String
    public var port: Int
    /// Reference to the VNC password in the Keychain.
    public var passwordRef: SecretReference?

    public init(
        id: UUID = UUID(),
        displayName: String = "VNC",
        transport: VNCTransport = .sshTunnel,
        host: String = "localhost",
        port: Int = 5900,
        passwordRef: SecretReference? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.host = host
        self.port = port
        self.passwordRef = passwordRef
    }

    public func validate() throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("VNC address required")
        }
        guard (1...65535).contains(port) else {
            throw FloeError.validationFailed("VNC port must be 1-65535")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, transport, host, port, passwordRef
    }

    /// Old profiles contained only host/port/passwordRef and always meant an
    /// SSH tunnel. Missing fields deliberately decode to that behavior.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? "VNC"
        transport = try values.decodeIfPresent(VNCTransport.self, forKey: .transport) ?? .sshTunnel
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 5900
        passwordRef = try values.decodeIfPresent(SecretReference.self, forKey: .passwordRef)
    }
}

public enum RemoteAuxiliaryConnectionKind: String, Sendable, Codable, CaseIterable, Hashable {
    case telnet
    case tcp
    case bluetoothSerial
}

/// Non-SSH connection metadata. No secret body is ever stored here.
public struct RemoteAuxiliaryConnection: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var kind: RemoteAuxiliaryConnectionKind
    public var host: String?
    public var port: Int?
    public var bluetoothPeripheralID: UUID?
    public var bluetoothServiceUUID: String?
    public var bluetoothWriteCharacteristicUUID: String?
    public var bluetoothNotifyCharacteristicUUID: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: RemoteAuxiliaryConnectionKind,
        host: String? = nil,
        port: Int? = nil,
        bluetoothPeripheralID: UUID? = nil,
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

    public func validate() throws {
        switch kind {
        case .telnet, .tcp:
            guard let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloeError.validationFailed("TCP/Telnet address required")
            }
            guard let port, (1...65535).contains(port) else {
                throw FloeError.validationFailed("TCP/Telnet port must be 1-65535")
            }
        case .bluetoothSerial:
            guard bluetoothPeripheralID != nil,
                  bluetoothServiceUUID?.isEmpty == false,
                  bluetoothWriteCharacteristicUUID?.isEmpty == false else {
                throw FloeError.validationFailed("BLE serial peripheral, service and write characteristic are required")
            }
        }
    }
}

/// One remote command run over SSH.
public struct RemoteRun: Sendable, Codable, Identifiable, Hashable {
    /// Heartbeats older than this mark the run disconnected.
    public static let heartbeatTimeout: TimeInterval = 45

    public var id: UUID
    public var hostID: UUID
    public var lifecycle: RemoteRunLifecycle
    /// Helper-assigned session identifier (tmux-style reconnection key).
    public var remoteSessionID: String?
    public var lastHeartbeatAt: Date?
    /// Byte offset into the remote output log; resume pulls from here.
    public var outputCursor: Int64
    public var exitStatus: Int32?
    public var auditEntryID: UUID?
    /// True when the open-source helper manages the remote session.
    public var helperManaged: Bool

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        lifecycle: RemoteRunLifecycle = .starting,
        remoteSessionID: String? = nil,
        lastHeartbeatAt: Date? = nil,
        outputCursor: Int64 = 0,
        exitStatus: Int32? = nil,
        auditEntryID: UUID? = nil,
        helperManaged: Bool = false
    ) {
        self.id = id
        self.hostID = hostID
        self.lifecycle = lifecycle
        self.remoteSessionID = remoteSessionID
        self.lastHeartbeatAt = lastHeartbeatAt
        self.outputCursor = outputCursor
        self.exitStatus = exitStatus
        self.auditEntryID = auditEntryID
        self.helperManaged = helperManaged
    }

    /// Derives lifecycle from heartbeat age. Without helper management a
    /// disconnect surfaces `.unknown` — never `.paused` (hard product rule).
    public func derivedLifecycle(at now: Date = Date()) -> RemoteRunLifecycle {
        switch lifecycle {
        case .exited, .failed, .cancelled:
            return lifecycle
        default:
            guard let lastHeartbeatAt else { return lifecycle }
            if now.timeIntervalSince(lastHeartbeatAt) > Self.heartbeatTimeout {
                return helperManaged ? .disconnected : .unknown
            }
            return lifecycle
        }
    }
}

/// Remote run lifecycle states.
public enum RemoteRunLifecycle: String, Sendable, Codable, Hashable {
    case starting
    case running
    /// Helper-managed session lost transport; resumable via outputCursor.
    case disconnected
    /// Unmanaged session lost transport; fate unknowable. Surfaced to the
    /// user explicitly — never reported as paused.
    case unknown
    case exited
    case failed
    case cancelled
}

public extension RemoteHostProfile {
    /// Reconstructs a profile from a persisted host row. The auth, jump
    /// chain and VNC endpoint JSON are decoded; secrets remain references.
    init(stored: RemoteHostStore.StoredHost) throws {
        let decoder = JSONDecoder()
        let auth = try decoder.decode(SSHAuthMethod.self, from: Data(stored.authJSON.utf8))
        let jumpChain = try decoder.decode([JumpHop].self, from: Data(stored.jumpChainJSON.utf8))
        let vncEndpoints: [VNCEndpoint]
        if let json = stored.vncEndpointsJSON,
           let decoded = try? decoder.decode([VNCEndpoint].self, from: Data(json.utf8)),
           !decoded.isEmpty {
            vncEndpoints = decoded
        } else if let json = stored.vncEndpointJSON {
            vncEndpoints = [try decoder.decode(VNCEndpoint.self, from: Data(json.utf8))]
        } else {
            vncEndpoints = []
        }
        let auxiliaryConnections = try stored.auxiliaryConnectionsJSON.flatMap {
            try decoder.decode([RemoteAuxiliaryConnection].self, from: Data($0.utf8))
        } ?? []
        let policy: HostKeyPolicy
        if stored.hostKeyPolicy.hasPrefix("pinned:") {
            policy = .pinned(fingerprintSHA256: String(stored.hostKeyPolicy.dropFirst("pinned:".count)))
        } else {
            policy = .trustOnFirstUse
        }
        self.init(
            id: stored.id,
            displayName: stored.displayName,
            address: stored.address,
            port: stored.port,
            user: stored.user,
            auth: auth,
            jumpChain: jumpChain,
            hostKeyPolicy: policy,
            allowsLegacyAlgorithms: stored.allowsLegacyAlgorithms,
            deviceKind: RemoteDeviceKind(rawValue: stored.deviceKind ?? "") ?? .unspecified,
            isRemoteExecutionEnvironment: stored.isRemoteExecutionEnvironment ?? true,
            vncEndpoints: vncEndpoints,
            auxiliaryConnections: auxiliaryConnections
        )
    }
}
