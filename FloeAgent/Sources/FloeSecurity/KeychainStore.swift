// FloeSecurity — Keychain secret storage.
//
// Real implementation behind `#if canImport(Security)` (compiles on macOS
// and iOS); a deterministic in-memory stub on platforms without
// Security.framework so cross-platform tests can exercise callers.

import Foundation
import FloeCore

#if canImport(Security)
import Security
#endif

/// Conformance for the settings-center probe. Same-module extension keeps
/// the conformance canonical; the protocol itself is declared in FloeCore.
extension KeychainStore: KeychainProbeStore {}

/// Errors specific to secret storage.
public enum KeychainStoreError: Error, Sendable, Hashable {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(String)
}

/// CRUD over generic-password Keychain items holding raw secret bytes.
public struct KeychainStore: Sendable {
    /// Keychain service namespace, e.g. "org.floeagent.ios.providers".
    public var service: String
    /// Maps to `kSecAttrSynchronizable`.
    public var synchronizable: Bool

    public init(service: String, synchronizable: Bool = true) {
        self.service = service
        self.synchronizable = synchronizable
    }

    #if canImport(Security)

    public func store(account: String, secret: Data) throws {
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecValueData as String] = secret
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Update existing item instead.
            let updateQuery = baseQuery(account: account, includeAccessible: false)
            let attributes: [String: Any] = [kSecValueData as String: secret]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus("update: \(updateStatus)")
            }
        default:
            throw KeychainStoreError.unexpectedStatus("add: \(status)")
        }
    }

    public func read(account: String) throws -> Data {
        var query = baseQuery(account: account, includeAccessible: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.unexpectedStatus("read: result not Data")
            }
            return data
        case errSecItemNotFound:
            throw KeychainStoreError.itemNotFound
        default:
            throw KeychainStoreError.unexpectedStatus("read: \(status)")
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account, includeAccessible: false) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainStoreError.unexpectedStatus("delete: \(status)")
        }
    }

    private func baseQuery(account: String, includeAccessible: Bool = true) -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
        _ = includeAccessible // accessibility is applied by the caller when writing
        return query
    }

    #else

    // MARK: - Stub implementation (Linux / platforms without Security.framework)

    public func store(account: String, secret: Data) throws {
        KeychainStubStorage.shared.store(service: service, account: account, secret: secret)
    }

    public func read(account: String) throws -> Data {
        guard let data = KeychainStubStorage.shared.read(service: service, account: account) else {
            throw KeychainStoreError.itemNotFound
        }
        return data
    }

    public func delete(account: String) throws {
        KeychainStubStorage.shared.delete(service: service, account: account)
    }

    #endif
}

#if !canImport(Security)
/// Process-wide in-memory stand-in for the Keychain on stub platforms.
final class KeychainStubStorage: @unchecked Sendable {
    static let shared = KeychainStubStorage()

    private var items: [String: Data] = [:]
    private let lock = NSLock()

    private init() {}

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    func store(service: String, account: String, secret: Data) {
        lock.lock()
        items[key(service: service, account: account)] = secret
        lock.unlock()
    }

    func read(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service: service, account: account)]
    }

    func delete(service: String, account: String) {
        lock.lock()
        items.removeValue(forKey: key(service: service, account: account))
        lock.unlock()
    }
}
#endif
