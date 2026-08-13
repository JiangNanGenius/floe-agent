// FloeSSH — Remote host profiles and run lifecycle (iOS-only target).
// See blazing-aurora-darwin.md §5.10. Citadel/SwiftNIO integration lands
// in M3; M1 ships the value types and lifecycle semantics:
//   heartbeatTimeout = 45s; a disconnect without helper ⇒ .unknown,
//   NEVER .paused.

import Foundation
import FloeCore

/// Configuration for one SSH host.
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
    public var vncEndpoint: VNCEndpoint?

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
        vncEndpoint: VNCEndpoint? = nil
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
        self.vncEndpoint = vncEndpoint
    }

    public func validate() throws {
        guard !address.isEmpty else {
            throw FloeError.validationFailed("Host address required")
        }
        guard (1...65535).contains(port) else {
            throw FloeError.validationFailed("Port must be 1-65535")
        }
        guard !user.isEmpty else {
            throw FloeError.validationFailed("SSH user required")
        }
        guard jumpChain.count <= Self.maxJumpHops else {
            throw FloeError.validationFailed("Jump chain exceeds \(Self.maxJumpHops) hops")
        }
    }
}

/// SSH authentication. Secrets live in the Keychain; only references here.
public enum SSHAuthMethod: Sendable, Codable, Hashable {
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

/// Optional VNC endpoint reachable over the SSH connection.
public struct VNCEndpoint: Sendable, Codable, Hashable {
    public var host: String
    public var port: Int
    /// Reference to the VNC password in the Keychain.
    public var passwordRef: SecretReference?

    public init(host: String = "localhost", port: Int = 5900, passwordRef: SecretReference? = nil) {
        self.host = host
        self.port = port
        self.passwordRef = passwordRef
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
