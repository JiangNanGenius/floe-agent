import Foundation
import Security
import CryptoKit

/// Separate service names keep App and companion keys in their own Keychain
/// namespaces. No shared-access-group entitlement or synchronizable secret.
public enum BridgeKeychain {
    public static func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BridgeFailure.authentication }
        return data
    }
    public static func save(_ data: Data, service: String, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BridgeFailure.authentication }
        } else if status != errSecSuccess { throw BridgeFailure.authentication }
    }
    public static func remove(service: String, account: String) throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeFailure.authentication }
    }
    public static func signingKey(service: String) throws -> Curve25519.Signing.PrivateKey {
        if let data = try read(service: service, account: "identity-v1") {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        try save(key.rawRepresentation, service: service, account: "identity-v1")
        return key
    }
}
