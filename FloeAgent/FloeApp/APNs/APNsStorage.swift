// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Security
import FloeSecurity

struct APNsStateStore: Sendable {
    let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/Push")
    }
    func load() throws -> APNsPersistentState {
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              (properties.fileSize ?? Int.max) <= 131_072 else { throw APNsServiceError.storage }
        let state = try JSONDecoder().decode(APNsPersistentState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1, state.preferences.revision >= 0, state.seen.count <= 512 else { throw APNsServiceError.storage }
        return state
    }
    func save(_ state: APNsPersistentState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        guard bytes.count <= 131_072 else { throw APNsServiceError.storage }
        try bytes.write(to: directory.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct APNsCredentialVault: Sendable {
    private let vault = KeychainStore(service: "org.floeagent.ios.push-installation",
        synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly)
    func secret(installationID: UUID, create: Bool) throws -> Data? {
        let account = installationID.uuidString.lowercased() + "/credential"
        do { return try vault.read(account: account) }
        catch KeychainStoreError.itemNotFound {
            guard create else { return nil }
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw APNsServiceError.storage }
            try vault.store(account: account, secret: bytes)
            return bytes
        }
    }
    func token(installationID: UUID) throws -> Data? {
        do { return try vault.read(account: installationID.uuidString.lowercased() + "/token") }
        catch KeychainStoreError.itemNotFound { return nil }
    }
    func saveToken(_ token: Data, installationID: UUID) throws {
        try vault.store(account: installationID.uuidString.lowercased() + "/token", secret: token)
    }
}
#endif
