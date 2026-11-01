import Foundation
import Security
import IDevice
import BridgeCore

/// Stores the RemotePairing record in the Keychain. It exists on disk only
/// while the Rust FFI call is live, in a 0600 file with complete file
/// protection, and is deleted as soon as the worker returns.
final class BridgePairingStore: @unchecked Sendable {
    private let service = "org.floeagent.iosbridge.pairing"
    private let account = "remote-pairing"
    private let lock = NSLock()

    var isImported: Bool {
        guard let data = loadData(),
              (try? JSONDecoder().decode(StoredRecord.self, from: data)) != nil else {
            return false
        }
        return true
    }

    var importedAt: Date? {
        guard let data = loadData() else { return nil }
        return (try? JSONDecoder().decode(StoredRecord.self, from: data))?.importedAt
    }

    private struct StoredRecord: Codable {
        var record: Data
        var importedAt: Date
    }

    func importFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Self.readBounded(url: url, maximumBytes: 262_144)
        } catch {
            throw BridgePairingError.unreadable("The file could not be read or is larger than 256 KiB.")
        }
        guard !data.isEmpty else {
            throw BridgePairingError.invalid("The pairing record is empty.")
        }
        try validate(data)
        let record = StoredRecord(record: data, importedAt: Date())
        let encoded = try JSONEncoder().encode(record)
        try saveData(encoded)
        BridgeLog.shared.append("pairing_imported bytes=\(data.count) shape=valid")
    }

    /// Validates with the exact parser the mount uses, so a record that passes
    /// here is one the FFI can read.
    func validate(_ data: Data) throws {
        var handle: OpaquePointer?
        let error = data.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rp_pairing_file_from_bytes(base, UInt(raw.count), &handle)
        }
        if let error {
            // Never echo parser text: malformed input may contain fragments of
            // a secret. Keep only a bounded category in the local log.
            let code = error.pointee.code
            idevice_error_free(error)
            if let handle { rp_pairing_file_free(handle) }
            BridgeLog.shared.append("pairing_parser_rejected code=\(code)")
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dictionary = plist as? [String: Any],
               dictionary["HostID"] != nil || dictionary["HostCertificate"] != nil {
                throw BridgePairingError.invalid(
                    "This is a lockdown pairing file, not a RemotePairing record. Import StikDebug's pairingFile.plist or an idevice_pair Remote pairing file."
                )
            }
            throw BridgePairingError.invalid(
                "The file is not a valid RemotePairing record (public_key, private_key and identifier are required)."
            )
        }
        guard let handle else {
            throw BridgePairingError.invalid("The RemotePairing parser returned no record.")
        }
        rp_pairing_file_free(handle)
    }

    /// Writes a short-lived FFI input file. The caller must keep it until the
    /// worker thread has returned; the mount code deletes it in a defer.
    func stageForFFI() throws -> URL {
        guard let encoded = loadData(),
              let record = try? JSONDecoder().decode(StoredRecord.self, from: encoded) else {
            throw BridgePairingError.notImported
        }
        try FileManager.default.createDirectory(
            at: BridgePaths.pairingStagingDirectory,
            withIntermediateDirectories: true
        )
        let url = BridgePaths.pairingStagingDirectory
            .appendingPathComponent("pairing-\(UUID().uuidString).plist")
        try BridgeAtomicFile.write(record.record, to: url, protection: .complete)
        #if os(iOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey]
        let isComplete = (protection as? FileProtectionType) == .complete ||
            (protection as? String) == "NSFileProtectionComplete"
        guard isComplete else {
            try? FileManager.default.removeItem(at: url)
            throw BridgePairingError.protectionUnavailable
        }
        #endif
        return url
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery() as CFDictionary)
        BridgeLog.shared.append("pairing_removed")
    }

    private func loadData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return data
    }

    /// Update in place so a failed replacement leaves the previous valid
    /// record intact. Add only when no item exists.
    private func saveData(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrSynchronizable as String] = false
            attributes[kSecValueData as String] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw BridgePairingError.keychain(status)
        }
    }

    private static func readBounded(url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maximumBytes else {
            throw BridgePairingError.invalid("The pairing record exceeds the 256 KiB import limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw BridgePairingError.invalid("The pairing record exceeds the 256 KiB import limit.")
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum BridgePairingError: LocalizedError {
    case unreadable(String)
    case invalid(String)
    case notImported
    case keychain(OSStatus)
    case protectionUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return "Could not read the pairing file: \(message)"
        case .invalid(let message):
            return message
        case .notImported:
            return "Import a RemotePairing file first."
        case .keychain(let status):
            return "Keychain error \(status); the pairing record was not stored."
        case .protectionUnavailable:
            return "The staging file could not be created with complete file protection."
        }
    }
}
