import Foundation
import Security

import BridgeCore

/// Keychain-backed per-client key storage for the Bridge host.
///
/// One generic-password item per client (service + client id) keeps a raw key
/// out of flat files and out of any public metadata snapshot. The item stores
/// the key and its non-secret client record together; `BridgeRPCClientRecord`
/// never includes key material.
public final class BridgeRPCKeychainClientStore: BridgeRPCClientStore, @unchecked Sendable {
    private let service: String
    private let nonceAccount = "__nonce_state_v1__"
    private let lock = BridgeRPCLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(service: String = "org.floeagent.iosbridge.rpc.clients") {
        self.service = service
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder
    }

    public func loadClients() throws -> [BridgeRPCStoredClient] {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw BridgeRPCStoreError.unavailable("keychain:\(status)")
        }
        let dataItems: [Data]
        if let data = result as? Data {
            dataItems = [data]
        } else if let array = result as? [Data] {
            dataItems = array
        } else if let array = result as? [[String: Any]] {
            dataItems = array.compactMap { $0[kSecValueData as String] as? Data }
        } else {
            throw BridgeRPCStoreError.corrupt
        }
        var clients: [BridgeRPCStoredClient] = []
        for data in dataItems {
            guard let client = try? decoder.decode(BridgeRPCStoredClient.self, from: data) else {
                // The nonce-state item is intentionally not a client record.
                continue
            }
            clients.append(client)
        }
        return clients
    }

    public func loadNonces() throws -> [String: [String: Int]] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try loadItem(account: nonceAccount) else { return [:] }
        do {
            return try decoder.decode([String: [String: Int]].self, from: data)
        } catch {
            throw BridgeRPCStoreError.corrupt
        }
    }

    public func saveNonces(_ nonces: [String: [String: Int]]) throws {
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do {
            data = try encoder.encode(nonces)
        } catch {
            throw BridgeRPCStoreError.corrupt
        }
        try writeItem(account: nonceAccount, data: data)
    }

    public func upsertClient(_ client: BridgeRPCStoredClient) throws {
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do {
            data = try encoder.encode(client)
        } catch {
            throw BridgeRPCStoreError.corrupt
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: client.clientID,
            kSecAttrSynchronizable as String: false,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BridgeRPCStoreError.unavailable("keychain:\(updateStatus)")
        }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BridgeRPCStoreError.unavailable("keychain:\(addStatus)")
        }
    }

    public func removeClient(clientID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientID,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeRPCStoreError.unavailable("keychain:\(status)")
        }
    }

    public func removeAllClients() throws {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeRPCStoreError.unavailable("keychain:\(status)")
        }
    }

    // MARK: - Item helpers

    private func loadItem(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw BridgeRPCStoreError.unavailable("keychain:\(status)")
        }
        guard let data = result as? Data else { throw BridgeRPCStoreError.corrupt }
        return data
    }

    private func writeItem(account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BridgeRPCStoreError.unavailable("keychain:\(updateStatus)")
        }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BridgeRPCStoreError.unavailable("keychain:\(addStatus)")
        }
    }
}
