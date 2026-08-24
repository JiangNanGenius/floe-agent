import Foundation
import FloeCore
import FloeSecurity

/// Device-local GitHub credential storage. The token is never represented by
/// a published UI model, persisted in SQLite, synchronized, or placed in a
/// repository URL.
public struct GitHubCredentialStore: Sendable {
    public static let service = "org.floeagent.ios.github"
    public static let account = "github.primary"

    private let keychain: KeychainStore

    public init() {
        keychain = KeychainStore(service: Self.service, synchronizable: false)
    }

    public func save(token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 20, value.count <= 512, !value.contains(where: { $0.isWhitespace }) else {
            throw FloeError.validationFailed("GitHub token format is invalid")
        }
        try keychain.store(account: Self.account, secret: Data(value.utf8))
    }

    public func token() throws -> String? {
        do {
            let data = try keychain.read(account: Self.account)
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw FloeError.storageCorrupted("GitHub credential is not UTF-8")
            }
            return value
        } catch KeychainStoreError.itemNotFound {
            return nil
        }
    }

    public func delete() throws {
        do {
            try keychain.delete(account: Self.account)
        } catch KeychainStoreError.itemNotFound {
            // Disconnect is intentionally idempotent.
        }
    }
}
