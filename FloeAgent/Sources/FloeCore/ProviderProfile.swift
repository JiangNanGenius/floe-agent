// FloeCore — Provider configuration profile.
// See docs/DEVELOPMENT_PLAN.md §2.2, §4.1.

import Foundation

/// Broad provider family, used to pick default endpoints and auth shapes.
public enum ProviderKind: String, Sendable, Codable, CaseIterable, Hashable {
    case openAI
    case anthropic
    case volcengineArk
    case alibabaStudio
    case local
    case custom
}

/// Reference to a Keychain item holding a secret. The secret itself is never
/// stored in the database or CloudKit; only this reference is.
public struct SecretReference: Sendable, Codable, Hashable {
    /// Keychain account identifier.
    public var keychainAccount: String
    /// Whether the Keychain item syncs via iCloud Keychain.
    public var synchronizable: Bool

    public init(keychainAccount: String, synchronizable: Bool) {
        self.keychainAccount = keychainAccount
        self.synchronizable = synchronizable
    }
}

/// Configuration for one model provider endpoint.
public struct ProviderProfile: Sendable, Codable, Identifiable, Hashable {
    /// Stable identity of Floe's device-local inference provider. Records
    /// using this identity are persisted locally for relational integrity but
    /// are deliberately excluded from CloudKit configuration sync.
    public static let onDeviceProviderID = UUID(
        uuidString: "A1480000-0000-4000-8000-000000000001"
    )!
    public static let onDeviceModelIDs: Set<UUID> = [
        UUID(uuidString: "A1480001-0000-4000-8000-000000000001")!,
        UUID(uuidString: "A1480001-0000-4000-8000-000000000002")!,
        UUID(uuidString: "A1480001-0000-4000-8000-000000000003")!
    ]

    public var id: UUID
    public var kind: ProviderKind
    /// Wire protocol the endpoint speaks. May differ from `kind` for
    /// OpenAI-compatible third-party gateways.
    public var wireProtocol: ModelProtocol
    public var baseURL: URL
    /// User-facing display name (e.g. "DeepSeek", "公司网关"). Defaults to the
    /// preset/kind label when unset; never sent on the wire.
    public var displayName: String?
    /// Reference to the API key in Keychain. `nil` means unauthenticated
    /// endpoint (e.g. local inference).
    public var secretRef: SecretReference?
    public var region: String?
    /// Non-secret headers sent with every request (e.g. organization IDs).
    public var nonSecretHeaders: [String: String]
    public var isEnabled: Bool
    /// `true` only after the user has acknowledged the risk of plain HTTP
    /// to a localhost or private-network endpoint.
    public var allowsPlainHTTP: Bool
    /// When true, tool names sent to this provider have dots replaced with
    /// underscores (e.g. `workspace.createFile` → `workspace_createFile`).
    /// Needed for providers like DeepSeek that enforce `^[a-zA-Z0-9_-]+$`.
    public var toolNameCompatibility: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// CloudKit optimistic-locking revision, incremented per sync.
    public var syncRevision: Int64

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        wireProtocol: ModelProtocol,
        baseURL: URL,
        displayName: String? = nil,
        secretRef: SecretReference? = nil,
        region: String? = nil,
        nonSecretHeaders: [String: String] = [:],
        isEnabled: Bool = true,
        allowsPlainHTTP: Bool = false,
        toolNameCompatibility: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncRevision: Int64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.wireProtocol = wireProtocol
        self.baseURL = baseURL
        self.displayName = displayName
        self.secretRef = secretRef
        self.region = region
        self.nonSecretHeaders = nonSecretHeaders
        self.isEnabled = isEnabled
        self.allowsPlainHTTP = allowsPlainHTTP
        self.toolNameCompatibility = toolNameCompatibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
    }

    /// Validates invariants enforced by the security model.
    /// - Throws: `FloeError.invalidConfiguration` on violation.
    public func validate() throws {
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.utf8.count <= 256,
                  !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw FloeError.invalidConfiguration(
                    "Provider display name must be 1...256 bytes without control characters"
                )
            }
        }
        guard baseURL.user == nil, baseURL.password == nil else {
            throw FloeError.invalidConfiguration(
                "Endpoint credentials belong in Keychain, not in the URL"
            )
        }
        let forbiddenHeaders: Set<String> = [
            "authorization", "proxy-authorization", "x-api-key", "api-key",
            "x-auth-token", "x-amz-security-token", "cookie", "set-cookie"
        ]
        if let forbidden = nonSecretHeaders.keys.first(where: {
            forbiddenHeaders.contains($0.lowercased())
        }) {
            throw FloeError.invalidConfiguration(
                "\(forbidden) may contain a secret and cannot be stored as a non-secret header"
            )
        }
        let scheme = baseURL.scheme?.lowercased() ?? ""
        if scheme == "http" {
            guard allowsPlainHTTP else {
                throw FloeError.invalidConfiguration(
                    "Plain HTTP requires explicit allowsPlainHTTP acknowledgement"
                )
            }
            guard baseURL.isLocalOrPrivateNetwork else {
                throw FloeError.invalidConfiguration(
                    "Plain HTTP is only permitted for localhost or private-network endpoints"
                )
            }
        } else if scheme != "https" {
            throw FloeError.invalidConfiguration("Endpoint must use http or https scheme")
        }
    }
}

extension URL {
    /// True for localhost, loopback, and RFC 1918 / link-local addresses.
    public var isLocalOrPrivateNetwork: Bool {
        guard let host = self.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "0.0.0.0"
            || host.hasSuffix(".local") { return true }
        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
        if host.hasPrefix("127.") { return true }
        if host.hasPrefix("10.") { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("169.254.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
