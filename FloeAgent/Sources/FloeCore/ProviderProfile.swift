// FloeCore — Provider configuration profile.
// See docs/DEVELOPMENT_PLAN.md §2.2, §4.1.

import Foundation

/// Broad provider family, used to pick default endpoints and auth shapes.
public enum ProviderKind: String, Sendable, Codable, CaseIterable, Hashable {
    case openAI
    case anthropic
    case volcengineArk
    case alibabaStudio
    case googleGemini
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
        UUID(uuidString: "A1480001-0000-4000-8000-000000000003")!,
        UUID(uuidString: "A1480001-0000-4000-8000-000000000004")!,
        UUID(uuidString: "A1480001-0000-4000-8000-000000000005")!,
        UUID(uuidString: "A1480001-0000-4000-8000-000000000006")!
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
    /// Stable id of the imported provider catalog entry this profile was
    /// created from (e.g. "deepseek"). `nil` marks a legacy/manual record.
    public var presetID: String?
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
        presetID: String? = nil,
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
        self.presetID = presetID
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
    ///
    /// The rule set lives in `ProviderConfigurationValidation` (shared by
    /// editor preflight, local store and CloudKit apply). This entry point
    /// preserves the exact legacy error strings callers and tests rely on;
    /// callers that need field-level, bilingual reporting should use
    /// `ProviderConfigurationValidation.issues(for:)` directly.
    public func validate() throws {
        try ProviderConfigurationValidation.validate(self)
    }
}

/// Identifies a provider whose base URL is one of the evidenced Kimi Code /
/// Coding Plan API route variants and resolves its verified OpenAI-compatible
/// API root. Grounded in the read-only OpenMinis evidence
/// (OpenMinis/OpenMinis@b4c0661d5631ebab4d1a2e6f3fd4c805d4030a6c,
/// src/ios/Providers/LLMProviderFactory.swift:376-381): the kimiCode default
/// base is `https://api.kimi.com/coding` WITHOUT `/v1`, and the real
/// endpoints live under `/coding/v1/…` — bare `/coding/chat/completions`
/// 404s — so the integration appends `/v1` for that base and honours the
/// caller's own root when `/v1` is already present. Exactly those two
/// variants (case- and trailing-slash-insensitive, HTTPS, no query or
/// fragment) identify a Kimi Code image endpoint. Host alone is NOT enough:
/// other paths on api.kimi.com, the Moonshot platform API
/// (api.moonshot.ai / api.moonshot.cn) and proxies have no upstream
/// image-route evidence and receive no image adapter.
public enum KimiCodeEndpointIdentity {
    public static let apiHosts: Set<String> = ["api.kimi.com"]
    /// The only accepted base path variants (normalized, lowercase, no
    /// trailing slash). The bare host or any other path is unsupported.
    public static let basePathVariants: Set<String> = ["/coding", "/coding/v1"]

    public static func matches(_ provider: ProviderProfile) -> Bool {
        apiRoot(for: provider.baseURL) != nil
    }

    /// The verified API root — always `https://api.kimi.com[:port]/coding/v1`
    /// for a supported base — or nil when host/scheme/path/query/fragment is
    /// not one of the evidenced route variants.
    public static func apiRoot(for provider: ProviderProfile) -> URL? {
        apiRoot(for: provider.baseURL)
    }

    public static func apiRoot(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              apiHosts.contains(host),
              url.query == nil,
              url.fragment == nil else { return nil }
        var path = url.path.lowercased()
        while path.hasSuffix("/") && path != "/" { path = String(path.dropLast()) }
        if path == "/" { path = "" }
        guard basePathVariants.contains(path) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = path.hasSuffix("/v1") ? path : path + "/v1"
        return components.url
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
