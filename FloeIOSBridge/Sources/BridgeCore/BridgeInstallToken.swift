import Foundation
import Security

/// Random per-install token protecting the prototype file channel and the
/// opt-in read-only LAN diagnostics endpoint.
///
/// The token is stored in the Keychain with `AfterFirstUnlockThisDeviceOnly`,
/// never in the container, defaults, logs or status files. Verification uses a
/// constant-time comparison; a missing token fails closed.
public enum BridgeInstallToken {
    public static let service = "org.floeagent.iosbridge.prototype"
    public static let fileChannelAccount = "file-channel-token"
    public static let lanAccount = "lan-diagnostics-token"
    public static let tokenByteCount = 32
    public static let canonicalTokenLength = 43

    public enum TokenError: LocalizedError {
        case randomFailure
        case keychain(OSStatus)
        case missing

        public var errorDescription: String? {
            switch self {
            case .randomFailure:
                return "The system random generator failed."
            case .keychain(let status):
                return "Keychain error \(status)."
            case .missing:
                return "No prototype token is stored yet."
            }
        }
    }

    /// Rotation failures deliberately carry no token material.
    public enum RotationError: LocalizedError, Equatable {
        case invalidReplacement
        case unchangedReplacement

        public var errorDescription: String? {
            switch self {
            case .invalidReplacement:
                return "The replacement token is not a canonical 32-byte base64url value."
            case .unchangedReplacement:
                return "The replacement token must differ from the current token."
            }
        }
    }

    public static func load(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw TokenError.missing }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw TokenError.keychain(status)
        }
        return value
    }

    @discardableResult
    public static func loadOrCreate(account: String) throws -> String {
        do {
            return try load(account: account)
        } catch TokenError.missing {
            let token = try generate()
            try save(token, account: account)
            return token
        }
    }

    public static func save(_ token: String, account: String) throws {
        guard let data = token.data(using: .utf8), !data.isEmpty else {
            throw TokenError.missing
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TokenError.keychain(status) }
    }

    public static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    public static func generate(byteCount: Int = tokenByteCount) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TokenError.randomFailure
        }
        return base64URL(Data(bytes))
    }

    /// True only for the unpadded base64url encoding of exactly 32 bytes.
    /// Length, alphabet, padding, decoded size and canonical trailing bits are
    /// all checked; malformed values are never repaired or truncated.
    public static func isCanonical(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count == canonicalTokenLength else { return false }
        for byte in bytes {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F:
                continue
            default:
                return false
            }
        }
        var padded = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded, options: []),
              data.count == tokenByteCount else {
            return false
        }
        return base64URL(data) == token
    }

    /// Pure rotation pre-check used before any Keychain write. The current
    /// token is optional because a first install may not have created one yet.
    @discardableResult
    public static func validateReplacement(_ replacement: String, current: String?) throws -> String {
        guard isCanonical(replacement) else { throw RotationError.invalidReplacement }
        if let current, constantTimeEquals(replacement, current) {
            throw RotationError.unchangedReplacement
        }
        return replacement
    }

    /// Replaces the stored token through the existing single-item Keychain
    /// update. Validation happens before any write, so a malformed or unchanged
    /// replacement cannot invalidate the old key. No token is returned or
    /// logged; callers reload the Keychain value after success.
    public static func rotate(account: String, replacementToken: String? = nil) throws {
        let current: String?
        do {
            current = try load(account: account)
        } catch TokenError.missing {
            current = nil
        }
        let candidate: String
        if let replacementToken {
            candidate = try validateReplacement(replacementToken, current: current)
        } else {
            candidate = try generate()
            if let current, constantTimeEquals(candidate, current) {
                throw RotationError.unchangedReplacement
            }
        }
        try save(candidate, account: account)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison for equal-length secrets. A length mismatch is
    /// rejected without revealing the expected length beyond the boolean.
    public static func constantTimeEquals(_ candidate: String, _ expected: String) -> Bool {
        let candidateBytes = Array(candidate.utf8)
        let expectedBytes = Array(expected.utf8)
        guard candidateBytes.count == expectedBytes.count, !expectedBytes.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in 0..<expectedBytes.count {
            difference |= candidateBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }
}
