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

/// Keychain protection class requested for a stored item.
public enum KeychainAccessibility: Sendable, Hashable {
    /// Historical default: readable after first unlock and eligible for
    /// iCloud Keychain when the item itself is marked synchronizable.
    case whenUnlocked
    /// Device-bound item: never migrates to another device or a backup.
    /// Used for skill connection credentials (for example iOS Bridge pairing).
    case whenUnlockedThisDeviceOnly
}

/// Errors specific to secret storage.
public enum KeychainStoreError: Error, Sendable, Hashable {
    case itemNotFound
    case duplicateItem
    /// The item exists but the protection class cannot be read right now
    /// (for example a locked device). Never a reason to delete or replace it.
    case interactionNotAllowed
    case unexpectedStatus(String)
}

/// CRUD over generic-password Keychain items holding raw secret bytes.
public struct KeychainStore: Sendable {
    /// Keychain service namespace, e.g. "org.floeagent.ios.providers".
    public var service: String
    /// Maps to `kSecAttrSynchronizable`.
    public var synchronizable: Bool
    /// Protection class applied on write. Existing callers keep the historic
    /// `WhenUnlocked` default; device-bound skill credentials opt in to
    /// `WhenUnlockedThisDeviceOnly`.
    public var accessibility: KeychainAccessibility

    public init(
        service: String,
        synchronizable: Bool = true,
        accessibility: KeychainAccessibility = .whenUnlocked
    ) {
        self.service = service
        self.synchronizable = synchronizable
        self.accessibility = accessibility
    }

    #if canImport(Security)

    public func store(account: String, secret: Data) throws {
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = accessibilityValue
        query[kSecValueData as String] = secret
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Update the existing item in place. The protection class is
            // updated too, so rewriting an older item can upgrade it to a
            // device-bound class without changing its account or service.
            let updateQuery = baseQuery(account: account, includeAccessible: false)
            let attributes: [String: Any] = [
                kSecValueData as String: secret,
                kSecAttrAccessible as String: accessibilityValue
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw Self.error(for: updateStatus, operation: "update")
            }
        default:
            throw Self.error(for: status, operation: "add")
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
            throw Self.error(for: status, operation: "read")
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

    private var accessibilityValue: CFString {
        switch accessibility {
        case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
        case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }

    private static func error(for status: OSStatus, operation: String) -> KeychainStoreError {
        if status == errSecInteractionNotAllowed {
            return .interactionNotAllowed
        }
        return .unexpectedStatus("\(operation): \(status)")
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
