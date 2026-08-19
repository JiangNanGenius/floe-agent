// FloeApp — Write-token storage for the feedback upload service.
//
// The server requires `Authorization: Bearer <WRITE_TOKEN>` for feedback
// uploads. The token is entered once in Settings and stored in Keychain
// (never hardcoded in the IPA). This is the client half of the server's
// `requireWrite` check.

import Foundation
import FloeCore
import FloeSync

enum FeedbackTokenStore {
    private static let service = "org.floeagent.ios.secrets"
    private static let account = "feedback.writeToken"

    /// Reads the write token from Keychain, if set.
    static func readToken() -> String? {
        let store = KeychainStore(service: service, synchronizable: false)
        guard let data = try? store.read(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the write token to Keychain.
    static func saveToken(_ token: String) throws {
        let store = KeychainStore(service: service, synchronizable: false)
        try store.store(account: account, secret: Data(token.utf8))
    }

    /// Deletes the write token.
    static func deleteToken() {
        let store = KeychainStore(service: service, synchronizable: false)
        try? store.delete(account: account)
    }
}
